# Request-time AI recommendation pipeline — "date night, jazz bar" scenario

> **Companion to**: [`srvn-user-taste-graph.md`](./srvn-user-taste-graph.md) (Phase 1 foundation). This plan describes the request-time AI tier that layers on top — free-text intent endpoint, LLM rerank+explain, latency budget for the "date night, jazz bar"-style UX.

## Context

User scenario: someone opens the app, types `"date night, looking for jazz music bar"`, expects 20 personalized restaurant recommendations with AI-generated "why this matches" blurbs. Each spot has ~1000 reviews; eventually also Instagram and TikTok posts per spot.

The blocker question: **can this be processed quickly and passed to AI for analysis?**

Hard reality first: the literal "dump 20 spots × 1000 reviews + social posts to AI" approach is impossible. Math: 20,000 reviews × ~250 tokens ≈ **5M tokens** — exceeds every model's context window (Claude 4.7 Opus 1M is the biggest, still 5× too small), would cost $15–75/request, and inference alone would take 30–60s. The naive shape is broken at every dimension: context, cost, and latency.

The right shape is **heavy precomputation + tight request-time retrieval + selective AI synthesis on a curated payload**. With that shape, **end-to-end p50 is ~400ms to first paint and ~2–3s to AI explanations streaming in**, fully achievable on the existing Postgres + Redis + APScheduler stack plus (later) ClickHouse for social signals.

This plan covers both horizons:
- **End-state architecture** (Phase 3, social ingestion live)
- **Phase 1 minimum increment** (ships now, demonstrates the shape with internal data only)

## Bottom-line answer

Yes, fast and AI-assisted is achievable. The trick is that the AI **never touches 20K reviews at request time**. It sees:
- A ~50-token user query
- A ~50-token structured intent (extracted in Stage 1)
- ~20 candidate cards, each ~200–300 tokens of precomputed summary

Total prompt: ~5–8K tokens. Cost per request: ~$0.001–0.01. Latency: p50 ~400ms to first paint, ~2s to full AI blurbs streamed.

## User story (end-state — what Maya experiences)

**Persona.** Maya, Tuesday 6:47pm, in Brooklyn. Anniversary tomorrow. She's a returning srvn user — already has location permission, an established taste profile (Italian + Japanese leanings, no allergens, prefers $$$, history of saving small speakeasies and listening rooms).

**Timestamped flow** (every time is wall-clock from search tap):

| Time | What Maya does | What she sees | What the system is doing |
|---|---|---|---|
| 0.00s | Opens app, taps search bar | Suggested vibes chips: `brunch`, `happy hour`, `date night`, `birthday`, recent searches | Idle |
| 0.05s | Taps `date night` chip, then types `, looking for jazz music bar`, hits Search | Search field with full query | UI dispatches POST `/spots/recommend-by-intent` |
| 0.05–0.40s | (waiting) | Shimmer skeleton — 6 rounded card placeholders | Stage 1A intent parser (haiku) + Stage 1B query embed (OpenAI) running in parallel; Stage 2 Postgres SQL fires when both return |
| **~0.45s** | (waiting) | **★ First paint ★** — 20 spot cards rendered. Each shows: photo, name + cuisine, distance + walk time, rating, precomputed `taste_summary_text` (1 sentence), one precomputed top review snippet (italicized quote), subtle ✨ shimmer placeholder labeled "Why this matches" | First-paint payload was synchronous JSON; cards are usable right now. Client immediately opens SSE channel to `/recommend-by-intent/{request_id}/stream` for AI blurbs |
| ~1.0s | Starts scanning cards, reading taste summaries | Same 20 cards | Reranker LLM (Stage 4a) is running on top 20 |
| ~1.5s | (still reading) | Cards smoothly reorder. Top 3 now have their "Why this matches" blurbs filled in. Subtle highlight animation on positions that changed | Reranker returned; first 3 explainer calls (Stage 4b) finished in parallel |
| ~2.0s | Taps card #2 to see details | Reading detail view | Top 5 blurbs all rendered; remaining 15 streaming in the background |
| ~3.5s | Detail view open (separate request path) | Full spot detail: hours, menu, photos, all reviews, save/book CTAs | Detail endpoint served from Postgres; social posts (Phase 3) lazy-loaded from ClickHouse on tab switch |
| ~4–5s | Maya scrolls back to list | All 20 cards now have blurbs | All Stage 4b explainer streams complete |
| variable | Taps Save | Save confirmed (haptic) | UserSavedSpot row written synchronously (~50ms); user-signals recompute queued for next 6h tick |

**The whole experience feels "AI-powered" — and is — but the LLM is doing very little work per request.** It generates structured intent (~50 tokens out), reranks 20 cards (~1K tokens out), and writes 20 short blurbs (~100 tokens each, parallelized). Total tokens-out per search: ~3.5K. The "5M tokens of review data" never enters a prompt.

**Acceptance criteria** (testable, drive the verification section):

- AC-1: Time from search-tap to first paint of 20 cards ≤ 700ms at p95 (warm cache); ≤ 1.2s at p99.
- AC-2: All cards on first paint have `taste_summary_text` and at least one review snippet populated. No card shows an empty body.
- AC-3: Top 3 "Why this matches" blurbs appear within 2s of first paint at p95.
- AC-4: If Stage 4 (rerank+explain) errors or times out, the 20 first-paint cards remain usable; the ✨ placeholders fade away silently, no error toast.
- AC-5: A repeated identical query within 1h hits the Redis intent-parse and query-embed caches → first paint ≤ 300ms p95.
- AC-6: Save action persists synchronously; next search session reflects the new save in scoring (even before the 6h signal tick, via a thin in-request signal boost for spots saved within the last 24h — see §6 spec).
- AC-7: Cold-start user (no taste profile) gets a usable result set — drop the `s_user_taste` weight, renormalize, do NOT block on an onboarding wall mid-session.

**Edge cases** (each is a discrete test in `test_recommend_by_intent.py`):

1. **No results in radius** — query yields zero candidates within 5mi. Card list shows a single empty-state card: *"No spots match 'jazz music bar' within 5 miles."* + a `[Search wider]` button that re-runs at 25mi. Don't silently widen — that would surprise the user.
2. **Intent parser returns malformed JSON** — fall back to embedding-only retrieval (skip the `occasions @>` and `vibe_tags &&` filters, rely on `query_vector` cosine alone). User sees same UX, possibly slightly different ranking. Logged as a parser-fallback metric.
3. **Query embed call fails** — return 503 with `Retry-After: 5`. UI shows: *"Search is having trouble right now — try again in a moment."* Do NOT silently fall back to lexical FTS — the user typed a semantic query and would not realize the results aren't actually semantic.
4. **Stage 4 entirely unavailable** (LLM provider down) — first paint succeeds normally; SSE channel returns immediately with `{status: "explanations_unavailable"}`. Cards keep their precomputed taste summaries, the ✨ placeholders disappear. The product still works, just less magical.
5. **Repeat query** — query "date night, jazz music bar" cache-hits both the intent parser (Redis key `srvn:intent:{sha1(q)}`) and the query embed (Redis key `srvn:query_embed:{sha1(q)}`). Stage 1 collapses to ~10ms. p50 first paint drops to ~250ms.
6. **User in a brand-new city** (no local saves, no local taste history) — taste features still apply (cuisine, dietary, allergen carry across geographies); only the location-specific affinity terms are absent. Cold-start fallback handles this without UX difference.

**What the user story proves about the architecture:**
- Maya waits ≤ 500ms to see *something usable*, not just spinners.
- AI-generated content is a **progressive enhancement layered on top of precomputed content**, never a blocker for first paint.
- Every Stage-4 failure mode degrades to "still useful," never "broken."
- The fast path doesn't depend on social signals being present — Phase 1 ships the full UX shape, social data enriches it later without changing the contract.

## End-state architecture (Phase 3 — what we're aiming at)

```
POST /spots/recommend-by-intent
{ lat, lon, query: "date night, jazz music bar", radius? }

T+0ms    │ Stage 1 — parallel intent prep (two LLM/embed calls in parallel)
         ├─ 1A. Intent parser  (haiku / gpt-4o-mini, ~150–300ms)
         │     IN:  "date night, jazz music bar"
         │     OUT: { occasion: "date_night",
         │            vibe_tags: ["jazz", "live_music", "intimate"],
         │            price_signal: "$$$–$$$$",
         │            time_of_day: "evening" }
         │
         └─ 1B. Query embedder  (text-embedding-3-small, ~80–200ms)
               OUT: query_vector[1536]

T+~300ms │ Stage 2 — candidate retrieval (single Postgres query, no LLM)
         │  Combined SQL:
         │    SELECT FROM spots s
         │      JOIN srvn_spot_taste_features f USING (spot_id)
         │     WHERE ST_DWithin(s.location, $loc, $radius)        -- PostGIS
         │       AND f.occasions @> ARRAY[$occasion]              -- JSONB GIN
         │       AND f.vibe_tags && $extracted_vibe_tags          -- array overlap
         │     ORDER BY (
         │       0.35 * (1 - f.taste_embedding <=> $query_vector) -- query↔spot
         │       0.20 * (1 - f.taste_embedding <=> $user_taste)   -- user↔spot (existing §5)
         │       0.15 * vibe_match_score                          -- structured
         │       0.10 * social_signal_score                       -- ClickHouse rollup (Ph3)
         │       0.10 * occasion_fit_score
         │       0.10 * (1 - distance_norm)
         │     ) DESC LIMIT 50;
         │  Returns 50 candidates with precomputed: taste_summary_text,
         │  top_review_snippets[], social_summary_text, vibe_tags, features.
         │  Latency: 50–200ms (PostGIS + pgvector HNSW + GIN, properly indexed)

T+~500ms │ Stage 3 — FIRST PAINT (synchronous JSON response, top 20)
         │  Client renders cards with: name, distance, rating,
         │  taste_summary_text (precomputed), top_review_snippet (precomputed),
         │  social_summary_text (precomputed).
         │  ★ USER SEES RESULTS HERE. p50 ≈ 400–500ms. ★

T+~500ms │ Stage 4 — AI rerank + explain (streamed over SSE, separate channel)
async    │  Client immediately opens GET /spots/recommend-by-intent/{id}/stream
         │
         │  4a. Reranker (~800–1500ms, single LLM call):
         │      IN:  intent + 20 candidate cards (~5K tokens)
         │      OUT: reordered top 20 + 1-sentence reason each (~1K tokens)
         │      Model: haiku or gpt-4o-mini (cheap, fast)
         │
         │  4b. Per-spot explainer for top 5 in parallel, rest sequential:
         │      IN per spot: intent + spot card (~400 tokens)
         │      OUT: 2–3 sentence "why this matches your jazz/date-night vibe"
         │      Model: haiku, parallel = ~1s wall time for 5
         │      Streams to client as each completes
         │
         │  Total Stage 4 wall: ~2–3s. Client UI fills in reorder + blurbs progressively.
```

**Latency budget summary** (p50, end-state, warm cache):

| Stage | Latency | Cumulative | What the user sees |
|---|---|---|---|
| 1A Intent parse + 1B Query embed (parallel) | ~250ms | 250ms | Loading spinner |
| 2 Candidate retrieval | ~150ms | 400ms | Loading spinner |
| 3 First paint (JSON) | ~50ms | **~450ms** | **Spot cards rendered** |
| 4a Rerank streams | +1000ms | ~1.5s | Cards reorder |
| 4b Explainer streams (top 5 done) | +1500ms | ~2–3s | "Why this matches" blurbs |
| 4b Remaining 15 explanations | +2s | ~4–5s | Last blurbs trickle in |

## What gets PRECOMPUTED (the entire reason this is fast)

Per spot, computed by extended §6 workers — these are the new precomputed fields beyond what the taste-graph spec writes today:

| Field | Refresh cadence | Source | Owner job |
|---|---|---|---|
| `taste_embedding` (existing §7) | 15m (changes only) | Internal taste_text | `srvn_refresh_taste_embeddings` |
| `taste_summary_text` (new, ~200 chars) | Daily | LLM compression of taste_text + top features | extend `srvn_refresh_spot_features` |
| `top_review_snippets` (new, JSONB, 5 entries) | Nightly | Internal + OpenTable reviews, ranked by informativeness | extend `srvn_refresh_spot_features` |
| `vibe_tags` (existing planned, §5a) | Daily | Controlled vocab from review/social mentions | extend `srvn_refresh_spot_features` |
| `occasion_fit_scores` (existing planned) | Daily | JSONB per occasion from review aggregation | `srvn_refresh_spot_features` |
| `social_summary_text` (new, Phase 3) | Nightly | LLM compression of ClickHouse social rollups | new `srvn_refresh_social_summaries` |
| `social_signal_score` (new, Phase 3) | Every 4–6h | ClickHouse mention velocity + sentiment | new `srvn_refresh_social_scores` |
| `representative_image_urls` (new, Phase 3) | Nightly | Top 3 images by engagement from social/reviews | new `srvn_refresh_social_images` |

Per user (existing §6 worker, no changes needed): `user_taste_embedding`, `user_taste_signals`.

**The pattern**: heavy LLM/aggregation work is asynchronous, batched, hash-skipped. Request-time only does retrieval + tight LLM synthesis on already-curated text. The AI never re-reads raw reviews.

## What changes vs. the taste-graph spec

The taste-graph spec is in good shape for this. End-state needs three additions:

1. **§7 (Embedding strategy)** — add a "query embedding" subsection: text-embedding-3-small at request time on the user's typed query, target latency ~150ms, cached for ~60s on Redis by query hash for repeat queries.
2. **§5 (Scoring)** — extend the formula with a `s_query_match = 1 - cosine(query_vec, spot_taste_emb)` term, weight ~0.35 when a query is present (recomputed weights renormalized). Without a query, fall back to current scoring.
3. **New §9 (Request-time AI synthesis)** — describes the rerank + explain pipeline, SSE streaming, per-call budgets, latency contract (p50 ≤ 500ms first paint, p95 ≤ 3s full explanations).

Phase 1 minimum increment (below) does not need (3); it only needs (1) and (2) plus the precomputed `taste_summary_text` field.

## Phase 1 minimum increment (ships now, no social data)

Smallest end-to-end slice that demonstrates the architecture and delivers real value without waiting for social ingestion:

### Endpoint
```
POST /spots/recommend-by-intent
{ latitude, longitude, query: "date night, jazz music bar", radius?, limit? }
```

### Stages (synchronous, no streaming yet)

1. **1A Intent parse** — new `services/srvn_taste_graph/intent_parser.py` wraps a haiku call. Returns `{ occasion, vibe_tags, price_signal, time_of_day }`. ~200ms. Cached on Redis by query string hash for 1h.
2. **1B Query embed** — reuse the `EmbeddingClient` Protocol from §7. Add `embed_query(text) -> vector` to the interface; the existing OpenAI impl handles it with a single-element batch. ~150ms. Cached on Redis by query hash for 1h.
3. **2 Candidate retrieval** — extend `Spot.find_nearby` (or new `find_nearby_with_intent`) in `ressy_backend/models/spot.py` to accept `query_vector` and `intent_struct`, apply the new scoring formula (§5 extension), return top 20.
4. **3 Response** — return 20 spots with `taste_summary_text` per spot. No request-time LLM rerank or explain yet. The precomputed `taste_summary_text` is the AI synthesis at this stage — it's just precomputed nightly instead of streamed at request time.

### What's deferred to Phase 2/3

- Stage 4a (reranker LLM): defer to Phase 2 — requires SSE infrastructure (srvn-backend has zero streaming today, this is greenfield).
- Stage 4b (per-spot explainer): defer to Phase 2.
- Social signal scoring + summary: defer to Phase 3 (requires ClickHouse, Meta/TikTok API ingestion workers).
- OpenTable review ingestion: independent of this plan; lands whenever the data pipeline does. Once present, `top_review_snippets` selection naturally includes them via `Review.external_source`.

### Phase 1 latency budget (realistic)

| Stage | Latency | Cumulative |
|---|---|---|
| 1A Intent parse (haiku, single call) | ~250ms | 250ms |
| 1B Query embed (OpenAI 3-small) | ~150ms | parallel with 1A |
| 2 Candidate SQL | ~150ms | 400ms |
| 3 Response serialization | ~50ms | **~450ms** |

p50 ~500ms, p95 ~1s. No streaming complexity, no LLM in the slow path, AI synthesis is precomputed and served from Postgres.

## Concrete spec diffs for Phase 1 increment

Three edits to `docs/plans/AI-Plans/srvn-user-taste-graph.md` when the Phase 1 increment is actually built:

**Diff A — §5 scoring formula** — add `s_query_match` term, with a comment noting it's only applied when a query is present:
```
s_query_match  = 1 - cosine(query_vector, spot.taste_embedding)
                 ONLY APPLIED when intent endpoint is hit; falls back to current
                 formula on the lat/lon-only /spots/recommended path.
weights when query present:
  0.35 * s_query_match + 0.15 * s_user_taste + 0.15 * s_occasion_fit + 0.10 * s_distance + ... (existing renormalized)
```

**Diff B — §7 add query-embedding subsection**:
```
**Query embedding at request time.** The intent endpoint embeds the user's typed
query via the same EmbeddingClient.embed_query(text) method (single-element batch).
Cached on Redis with key srvn:query_embed:{sha1(query)} for 1h. Tagged
metadata={"surface":"srvn_intent_query"} for separate billing attribution.
Cost: ~$0.0000016 per query. Worst case 1M intent queries/day = $1.60/day.
```

**Diff C — §3 add new file** in the file list:
```
intent_parser.py    # haiku wrapper, query → {occasion, vibe_tags, price, time_of_day}
```

And §6 worker `srvn_refresh_spot_features` adds writing `taste_summary_text` (~200 chars, LLM-compressed from features) per spot, daily.

## Critical files (for Phase 1 increment)

- `docs/plans/AI-Plans/srvn-user-taste-graph.md` — three small edits above
- `ressy_backend/routes/spot.py` — new blueprint or new route alongside `get_recommended_spots`
- `ressy_backend/services/srvn_taste_graph/embedding_client.py` — add `embed_query(text)` method to Protocol + OpenAI impl
- `ressy_backend/services/srvn_taste_graph/intent_parser.py` (NEW, ~60 lines) — haiku wrapper with structured-output schema
- `ressy_backend/models/spot.py` — extend `Spot.find_nearby` to accept query_vector + intent_struct
- `ressy_backend/services/srvn_taste_graph/spot_features_extractor.py` — add `taste_summary_text` LLM compression step
- `ressy_backend/config.py` — add `SRVN_GPT_5_NANO_MODEL` (default `claude-haiku-4-5`), `SRVN_QUERY_EMBED_CACHE_TTL` (default 3600s)

## Phase 2 — Group dining extension

The single-diner pipeline above doesn't handle events with multiple participants (couples on date night, friends-nights, office offsites). The `Event` + `EventParticipant` tables already exist in srvn-backend; the taste-graph spec explicitly marks group dining as Phase 2+ scope. This section sketches the request-time extensions.

### What stays the same

- Stage 1A intent parsing (`{occasion, vibe_tags, price_signal, time_of_day}` from query string)
- Stage 1B query embedding (cached on Redis)
- Stage 3 first paint shape (cards with `taste_summary_text` + review snippets)
- Stage 4 rerank + explain mechanics

### What changes

**Endpoint shape**:
```
POST /events/{event_id}/recommend-by-intent
{ query?, radius?, limit? }
```
Group context (participants, merged constraints, occasion) is loaded from the Event. The `query` is an optional refinement ("the event is a birthday but they want karaoke").

**Group taste merging** (new `services/srvn_taste_graph/group_taste_merger.py`):

| Dimension | Merge rule | Reasoning |
|---|---|---|
| Allergens | UNION across participants | Safety: anyone allergic → group filters out |
| `allergen_handling` | MAX (`block` > `warn`) | Strictest mode wins |
| Dietary preferences | STRICTEST wins (vegan > vegetarian > pescatarian > omnivore) | One vegan → group needs vegan-friendly |
| `dietary_strictness` | MAX (`strict` > `soft`) | Same logic |
| Price comfort range | MIN ceiling, MAX floor (intersection) | Don't exceed anyone's ceiling |
| Cuisine affinity | Weighted union; cuisines liked by ≥2 participants get a 1.5× boost | Reward overlap, not lowest-common-denominator |
| Occasion | From `Event.occasion`, not merged from individuals | Group has one shared occasion |
| Group taste embedding | Centroid of participants' `taste_embedding`, L2-normalized | Cheap, defensible. Optionally weight the requesting user (event creator / search-triggerer) 1.2× as de facto host |
| Cold-start participant | Drop from centroid; if all cold, skip user-taste term entirely | Don't punish the group for one missing profile |

The merged result is cached at `srvn:group_taste:{event_id}:{sha1(sorted participant_ids)}` for 1h. Re-computed if the participant set changes (cache key derives from participant IDs, so changes invalidate naturally).

**Scoring formula adjustments to §5**:
- Replace `s_user_taste = 1 - cosine(user_taste_emb, spot_taste_emb)` with `s_group_taste = 1 - cosine(group_centroid_emb, spot_taste_emb)`. Same weight slot.
- Add a hard-filter step before scoring: `s_no_dealbreakers` — exclude any spot whose `allergen_warnings` HIGH-tier entries intersect the merged allergen set, OR whose `dietary_flags` don't satisfy the strictest dietary preference. This is a boolean exclusion, not a continuous score.

**Per-spot explainer prompt** (when Phase 2 AI tier is built — see below):
```
You're explaining why {spot_name} matches a group of {N} diners for {occasion}.
Group constraints: {merged_dietary}, avoiding {merged_allergens}, price tier {merged_price}.
Common taste signals: {top_overlapping_cuisines}.
The user who typed the search additionally prefers: {individual_taste_summary}.
Write 2-3 sentences. Use "the group" rather than "you".
```

### New files for Phase 2 group dining

- `ressy_backend/services/srvn_taste_graph/group_taste_merger.py` — merge rules + centroid embedding + Redis cache
- `ressy_backend/routes/event_recommendations.py` — `/events/{id}/recommend-by-intent` Smorest blueprint
- `tests/srvn_backend/services/test_group_taste_merger.py` — merge correctness (UNION on allergens, STRICTEST on dietary, MIN/MAX on price, cuisine overlap boost), cold-start handling, host-weighting if implemented
- `tests/srvn_backend/api/test_event_recommend_by_intent.py` — full API test with seeded multi-participant events covering: 4-person group with mixed cuisines, 2-person with conflicting dietary (vegan + omnivore), allergen UNION correctness, optional query refinement on top of event context

### Edge cases specific to group dining

1. **Large groups (>8 participants)** — centroid averaging loses signal. Phase 2 caps at the centroid approach; if telemetry shows large groups suffer (low click-through, frequent re-search), add k-means clustering of participant tastes in Phase 2.5 and return recs that satisfy the largest cluster while respecting all-group dealbreakers.
2. **Conflicting dietary** — strict vegan + omnivore in the same group. Strictest wins → vegan filter applied. The Phase 2 explainer (if shipped) should call this out: *"This vegetarian spot accommodates the group's vegan member, with substantial dishes for omnivores too."*
3. **Allergen + dietary intersection** — peanut-allergic participant in a group looking for Thai. The §5b allergen scan and dietary scoring compose correctly without special-casing — both filters run independently against the merged constraint sets.
4. **Empty result for group** — degrades the same way as single-diner per §5b graceful-degradation cascade: drop strict dietary filter first, widen radius next, never relax the allergen filter regardless of how empty the result set becomes.
5. **Participant joins/leaves mid-search session** — group taste cache invalidates because the cache key includes the sorted participant ID hash. Next request recomputes the centroid.

### Dependencies on prior milestones

Phase 2 group dining cannot ship until:
- All of Milestone 1 (foundation) is in production — every participant needs a populated `srvn_user_taste_profile`.
- Milestone 2 steps 12–13 (`embed_query()` + intent parser) shipped — the endpoint still uses an optional refinement query.
- Confirmed that `Event.dietary_constraints_merged` is actually populated (the taste-graph spec mentions it but if the field is nullable/unused today, add a compute-on-read helper or a backfill before this can ship).
- (Optional) verified whether `EventParticipant` has a `role` field for host weighting; if not, fall back to weighting the user who triggered the search.

### What NOT to do in Phase 2 group dining

- Don't ask every participant to validate their taste profile when joining an event. Use the existing profile silently; the merge handles missing and cold-start cases gracefully.
- Don't store the merged group taste vector as a column on `Event`. It changes whenever participants join/leave, would need its own invalidation pipeline, and offers no real performance win over Redis-cached compute-on-read.
- Don't model "group preferences" as a separate first-class entity (no `group_taste_profile` table). Groups are sparse and ephemeral; signal lives in individual profiles, group is a compose-on-read operation.
- Don't extend the per-spot explainer prompt to handle groups before the single-diner explainer ships in Phase 2 AI tier. Group is the harder case to evaluate; ship the single-diner version first to validate the prompt template, then extend.
- Don't try to merge intents from multiple participants (e.g., "everyone types what they want and we combine"). The intent (occasion + vibe) belongs to the event, not the participants. If multiple people want to express preferences, that's a voting/decision UX problem, not a recommendation-engine problem.

## End-state architecture (Phase 3) — what gets added later

Not building now, but the seam is preserved:

- **SSE streaming**: new `services/srvn_taste_graph/sse_streamer.py` plus a Flask `Response(stream_with_context(...))` pattern. Greenfield in srvn — no precedent.
- **Reranker LLM** (Stage 4a): added behind a `SRVN_RECOMMEND_RERANK_ENABLED` flag. Single haiku call on candidate list.
- **Per-spot explainer LLM** (Stage 4b): parallel haiku calls with `asyncio.gather` (or threadpool, depending on Flask sync/async story). Throttled to top 5–10.
- **Social signal scoring**: ClickHouse client + worker that pulls daily rollups into `srvn_spot_taste_features.social_signal_score`. Per the §11b roadmap (folded into spec separately).
- **Social summary LLM job**: nightly, compresses social mentions per spot into ~200-char `social_summary_text`. Same shape as `taste_summary_text`.

## Things to NOT do

- Don't try to send raw reviews to the LLM at request time. The token math is broken (5M tokens for 20 spots × 1000 reviews); the only viable shape is precomputed summaries + snippets.
- Don't build SSE streaming for Phase 1. Synchronous JSON is fine when the AI work is precomputed. Streaming only matters when you have request-time LLM calls in Stage 4.
- Don't reuse `conversation_service.py`'s pattern (per-request FAISS rebuild). That pattern is appropriate for chatbot conversation context but catastrophic for a recommendation endpoint — it's the exact anti-pattern this plan is built to avoid.
- Don't add a per-request LLM call to the existing `/spots/recommended` endpoint. Add a new `/spots/recommend-by-intent` route. Keeps the structured-only path free of LLM latency for clients that don't need it.
- Don't precompute `taste_summary_text` with `text-embedding-3-large` thinking "bigger model = better summary." It's a generation task, not an embedding task. Use haiku (fast, cheap, good enough for 200-char summaries).
- Don't ingest social media without licensed/official APIs. Scraping Instagram/TikTok violates ToS, gets IP-banned, and creates compliance liability that swamps any feature value. Meta Graph API and TikTok Display API are the legitimate paths.

## Verification (Phase 1 increment)

1. **Latency contract** — load test with 100 concurrent intent requests against a representative dataset (50k spots). p50 ≤ 500ms, p95 ≤ 1s. If p95 > 1s, the bottleneck is almost certainly the haiku intent-parse call — measure each stage independently and consider intent-cache warmup or a smaller intent vocabulary.
2. **Cache hit rate** — after a week of real traffic, `srvn:query_embed:*` cache hit rate should be ≥ 30% (queries cluster heavily — "date night", "brunch", "happy hour" recur). If lower, the cache TTL is too short or the query normalization (lowercase, strip punctuation, sort tokens) needs work.
3. **Quality A/B** — compare ranking quality on intent queries against the current `/spots/recommended` (distance-only) using internal queries. NDCG@10 on a labeled set should improve materially. If it doesn't, the intent parser is failing to extract useful structure — inspect parser outputs on representative queries.
4. **Cost ceiling** — `SRVN_INTENT_DAILY_BUDGET` Redis counter modeled on the existing `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` circuit breaker. Default 100k intent calls/day at $0.0001/call (haiku w/ small prompt) = $10/day worst case. If exceeded, fall back to lexical search (existing `/spots/search` FTS path).
5. **Failure modes** — intent parser returns malformed JSON: response falls back to embedding-only retrieval (skip the `occasions @> $occasion` filter, rely on `query_vector` cosine). Query embed fails: return 503 with retry-after, do not silently degrade to lexical (would surprise the user with worse results than they're used to).
6. **Test coverage** — extend §8 with:
   - `test_intent_parser.py` — fixture queries → expected structured intents; malformed-output fallback; haiku call mocked
   - `test_recommend_by_intent.py` (API test) — full route with seeded data, asserts cards include `taste_summary_text` and ordering reflects query+intent
   - `test_query_embed_cache.py` — Redis cache hit/miss, TTL respected, normalization (lowercase + strip) makes "Date Night" and "date night" share a cache key
