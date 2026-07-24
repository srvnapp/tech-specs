# srvn — spot-level review-digest embedding (supersedes per-review RAG)

_Date: 2026-07-01 · **Status (upd. 2026-07-05): substrate shipped (PRs #209–210)** — the
`review_digest_embedding` + `review_noise` columns and HNSW index, the summarizer's
digest-embed step, and the retirement of the per-review embedding surface all landed.
**Still pending: the `/spots/recommend-by-intent` endpoint** specified in "Intended future
integration" below (out of scope for the shipped substrate slice). · Scope: replaces the
deferred per-review vector-search slice of Phase 2 with a single spot-level
`review_digest_embedding`._

Supersedes the per-review-RAG mechanism in
[`phase2-review-ingestion-and-rag.md`](./phase2-review-ingestion-and-rag.md) (its §2
`review_rag.py`, §4 `srvn_embed_spot_reviews`, §5 Stage-4 RAG, the `EMBED_MAX` config,
and the `srvn_spot_reviews.embedding`/HNSW schema). Builds on the shipped
[`srvn-review-summarizer-implementation.md`](./srvn-review-summarizer-implementation.md).

---

## Context — why this change

The review-summarizer slice (PRs #204–208) is fully shipped: the offline pipeline now
produces, per spot, a structured `review_digest_json` (vibe, noise, service,
occasion_fit, dietary_notes, standout_dishes), a prose `review_digest_text`, and curated
`top_review_snippets` on `srvn_spot_taste_features`.

The **one remaining unbuilt piece** of the Phase-2 review plan was `review_rag.py` —
request-time **per-review** pgvector search (one 1536-d vector per review, HNSW on
`srvn_spot_reviews.embedding`). We are **dropping that mechanism.** Two reasons:

1. **Storage/compute.** Per-review vectors are the pipeline's real cost. Toronto alone is
   ~414–442k reviews → ~2.5 GB of raw vectors (+1.5–3× HNSW overhead) on a 10 GiB box —
   untenable, and multi-metro makes it impossible. (The plan already tried to cap this
   with a separate `EMBED_MAX`; this goes to zero review vectors.)
2. **The digest is now enough for spot-level search.** `review_digest_json` captures the
   vibe/occasion/atmosphere signal an intent query ("cozy date night, drinks") needs — at
   **one vector per spot** (~5.8k vectors ≈ 35 MB for Toronto, ~70× smaller).

**Intended outcome:** a spot-level, review-informed vector search that fits the current
DB box, with `review_rag.py` and the per-review embedding path retired.

**Settled decisions:**
- Use a **dedicated** `review_digest_embedding` column, **not** folded into the existing
  `taste_embedding` (compliance + coupling — see below).
- **Promote `noise`** to a structured column for hard filtering; keep vibe/occasion in the
  embedding. (`occasion_fit` normalization deferred — it's free text; noise is a clean
  enum.) **The hard filter is applied only when the intent parser extracts an explicit
  atmosphere/volume constraint — never inferred from occasion** (see the integration section
  for the gating rule). Absent an explicit ask, noise is left unconstrained; the vibe/noise
  language still lives in `review_digest_embedding`, so an explicit "lively" ranks lively
  spots up via cosine without any structured filter.
- **No per-row embedding-model column** — the embedding always uses `SRVN_EMBEDDING_MODEL`
  (reused everywhere), and it's written in the same pass as the digest so
  `review_digest_updated_at` already timestamps it.

## Why a dedicated column, not `taste_embedding`

`build_spot_taste_text` (`ressy_backend/services/srvn_taste_graph/text_builder.py`) feeds
`taste_embedding` from **controlled sources only** — normalized cuisine/dietary/occasion
taxonomies, price/rating, vibe booleans, and Google's own `editorial_summary`. It contains
**zero purchased-vendor-review content** by design. That separation is the settled
compliance line (`phase2 §3/§7.3`: reviews are for the intent endpoint only, never the
`taste_text`/`taste_embedding` that powers `/spots/recommended`). The digest is a
derivative of purchased reviews, so folding it into `taste_embedding` would collapse that
line and make `/spots/recommended` drift with review purchases + LLM changes. A separate
column consumed only by the (future) intent endpoint keeps `/spots/recommended` untouched
and compliant.

## Scope of this slice

Lands the **substrate** (dark), mirroring how the rest of Phase 2 shipped: add the
spot-level digest embedding + structured noise, and retire the per-review embedding
surface. **Consuming it at request time is the separate future intent-endpoint slice**
(`/spots/recommend-by-intent`, roadmap Phase 2) — out of scope here, but the intended
integration is documented at the end so the shape is fixed.

## Changes

### 1. Migration (`migrations/versions/`) — schema delta

Add to `srvn_spot_taste_features`:
- `review_digest_embedding  Vector(1536)`  nullable
- `review_noise  String(16)`  nullable (values from the digest enum:
  `quiet|moderate|lively|loud|unknown`)
- HNSW index `ix_srvn_spot_taste_features_review_digest_embedding_hnsw`
  (`vector_cosine_ops`) — mirror the existing `taste_embedding` HNSW block at
  `models/srvn_spot_taste_features.py:77-80`.

Retire the per-review vector surface (safe: `srvn_spot_reviews` is **empty in prod** —
ingest is dark, `SRVN_REVIEW_INGEST_ENABLED=false`):
- Drop index `ix_srvn_spot_reviews_embedding_hnsw` and columns `embedding`,
  `embedding_model`, `embedding_updated_at` from `srvn_spot_reviews`.
- Provide a symmetric `downgrade()` that recreates them.

### 2. Model updates
- `ressy_backend/models/srvn_spot_taste_features.py` — add the two columns + HNSW index
  (mirror `taste_embedding` at lines 43, 77-80).
- `ressy_backend/models/srvn_spot_review.py` — remove `embedding` / `embedding_model` /
  `embedding_updated_at` (lines 48-52) and the `ix_srvn_spot_reviews_embedding_hnsw` index
  (lines 62-67). Keep everything else (source_rank, content_hash, etc.).

### 3. Summarizer grows a digest-embedding step
`ressy_backend/services/srvn_taste_graph/review_summarizer.py` (`summarize_spot_reviews`):
- Accept an injected `embedding_client=None` (default to `OpenAIEmbeddingClient`, reusing
  `embedding_client.py` — `embed_batch`, `OPENAI_BATCH_MAX`).
- New `_digest_embed_text(digest_json) -> str`: stable serialization, e.g.
  `"Vibe: {vibe}. Occasion: {occasion_fit}. Noise: {noise}. Dietary: {dietary_notes}.
  Dishes: {', '.join(standout_dishes)}."` (fixed field order → deterministic).
- After writing the digest for a spot, embed that text and write `review_digest_embedding`
  and `review_noise = digest_json["noise"]`. Model is always `SRVN_EMBEDDING_MODEL`; no
  per-row model/updated_at columns.
- **Embed-backfill on hash-skip:** on the digest hash-skip path, if
  `review_digest_embedding IS NULL` (a spot digested before this feature, or after an
  embedding-model migration nulled it), still compute + write the embedding + noise
  **without** re-calling the LLM. Otherwise skip the embed too — re-embedding happens only
  when the digest changes or the embedding is missing. ~$0 ongoing.
- Reuse the shared taste-embed daily token budget (token volume is tiny: one short string
  per spot). Commit-per-spot stays as-is.

### 4. Retire per-review embedding code
- Delete `refresh_review_embeddings` (`review_ingestor.py:530`) and its now-unused helper
  references; remove its export from `srvn_taste_graph/__init__.py`.
- Remove the `embed` subcommand from `ressy_backend/commands/srvn_review_ingest_command.py`.
- Do **not** create `review_rag.py`.

### 5. Config
- No new required knobs. Digest embedding reuses `SRVN_EMBEDDING_MODEL` +
  `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET`.
- Endpoint-time knobs (`SRVN_INTENT_REVIEW_TOPK`, `SRVN_INTENT_REVIEW_RAG_ENABLED`) are
  dropped; a future `s_review_match` weight lands with the endpoint.

### 6. Embedding-model migration handling
No per-row embedding-model column, so a `SRVN_EMBEDDING_MODEL` swap can't self-detect
digest-embedding drift. Fold it into the existing Phase-1 §7a blue/green playbook: when
that migration re-embeds the taste corpus, also
`UPDATE srvn_spot_taste_features SET review_digest_embedding = NULL` for affected spots and
run `summarize` — the embed-backfill path (§3) regenerates them in the new model space
without re-calling the LLM.

## Tests (`poetry run pytest`)
- Extend `tests/.../test_review_summarize_sweep.py` (`@pytest.mark.api`): inject a fake
  embedding client; assert `review_digest_embedding` is written and `review_noise` copied
  from `digest_json["noise"]`; hash-skip with the embedding already present makes no embed
  client call; hash-skip with a NULL embedding backfills it (no LLM call).
- Migration test (mirror `tests/srvn_backend/test_srvn_review_ingestion_migration.py`):
  `upgrade head` adds the two features columns + HNSW index and removes the
  `srvn_spot_reviews` embedding column/index; `downgrade -1` reverses both.
- Remove/replace the `embed`-subcommand assertions in
  `tests/.../test_srvn_review_ingest_command.py`.

## Verification
1. `flask srvn-reviews summarize --max 3` → `review_digest_text` set **and**
   `review_digest_embedding` non-null, `review_noise` populated for each digested spot.
2. Re-run immediately → `spots_skipped_hash` increments; the digest embed is skipped when
   already present, but a spot with a digest and NULL embedding gets backfilled.
3. `\d srvn_spot_taste_features` shows `review_digest_embedding` + `review_noise` + HNSW
   index; `\d srvn_spot_reviews` shows the embedding column/index gone.
4. Storage sanity: one review-digest vector per digested spot (not per review).

## Intended future integration (out of scope, documented to fix the shape)
When `/spots/recommend-by-intent` is built: embed the intent query once (`embed_query`,
same `text-embedding-3-small` space), then a spot-level cosine search that **blends**
`taste_embedding` (cuisine/dietary/taste) with `review_digest_embedding`
(vibe/occasion/atmosphere) via a new `s_review_match` term in `scoring.py`.
`/spots/recommended` continues to use `taste_embedding` only — unchanged.

### How the two embeddings are used (query → ranked spots)

The endpoint embeds the **query once**, then compares that single query vector against
**both** spot vectors *separately*, yielding **two similarity scores** that enter the
weighted sum as **independent terms** — it does **not** concatenate the vectors or average
them into one spot vector. Note the shift from `/spots/recommended`: today's `s_embedding`
term is **user ↔ spot** (the user's stored `taste_embedding` vs the spot's); the intent
endpoint's comparison is **query ↔ spot**, adding two terms:

- **`s_query_taste`** = `cos(q_vec, taste_embedding)` — query vs the spot's controlled
  identity (cuisine/dietary/price/editorial). On *"lively waterfront seafood for a group"*
  this fires on **"seafood."**
- **`s_review_match`** = `cos(q_vec, review_digest_embedding)` — query vs the spot's
  review-derived vibe (vibe/occasion/atmosphere). Same query, this fires on
  **"lively / waterfront."**

Same query vector to both; each spot vector responds to the facet it encodes, so the query
never has to be split for the embeddings. **Why two terms, not one merged vector:**
(1) independent weighting (`w_query_taste` vs `w_review`) — a merged vector locks the ratio;
(2) compliance — `taste_embedding` stays the sole driver of `/spots/recommended`, the review
signal is an additional endpoint-local term (the reason for the dedicated column); (3) null
handling for free — `scoring.py`'s existing *renormalize-over-active-components* design drops
`s_review_match` and renormalizes when `review_digest_embedding IS NULL`, so an un-summarized
spot still ranks on taste/distance/price (a merged vector can't degrade gracefully).

```
"lively waterfront seafood for a group"
   │
   1. Intent parser (LLM) → structured facets + clean query text
   │     cuisine=seafood · occasion=group · atmosphere=lively · (no price, no dietary)
   │
   2. Embed the query text once → q_vec  (text-embedding-3-small, same space)
   │
   3. RECALL (SQL): geo ST_DWithin  +  HARD filters from explicit facets only
   │     (price cap, noise-if-explicit) — each with its NULL policy
   │
   4. SCORE each candidate (pure fn, per spot), weighted sum of active terms:
   │     s_query_taste   = cos(q_vec, taste_embedding)
   │     s_review_match  = cos(q_vec, review_digest_embedding)   ← drop + renorm if NULL
   │     s_distance      = exp(-dist / 2000)
   │     s_price, s_popularity, ...
   │     (+ s_personal   = cos(user.taste_embedding, taste_embedding)  if logged in)
   │     (+ occasion / noise / dietary-evidence boosts from facets — all soft)
   │
   5. Rank by score → top N
```

```
score = w_query_taste · s_query_taste
      + w_review      · s_review_match
      + w_distance    · s_distance
      + w_price       · s_price
      + w_popularity  · s_popularity
      + w_personal    · s_personal        (only if user logged in)
      → renormalized over whichever terms are non-null, then occasion/noise boosts applied
```

The embeddings do the **fuzzy semantic** match (two weighted cosine terms); the parsed
facets do the **sharp** match (hard filters + boosts, operating *outside* the embeddings so a
strong cuisine hit can't average away the occasion signal). Combining both is exactly what a
raw single-vector cosine search over `review_digest_embedding` alone cannot do.

### Step 1 — the intent facet object (how it's produced)

The flow's step 1 produces a **structured facet object**; everything downstream
(resolve-vs-profile → filters → scoring) consumes *that object*, not raw text. The object is
the **stable contract**.

**Decision (MVP): an LLM free-text parser produces the facet object.** The user types a
natural-language query and a request-time LLM call parses it into the facet object via strict
Structured Outputs (same pattern as `review_summarizer_client.py`). This is the one genuine
request-time LLM dependency in the endpoint, so design it accordingly:

- **Small, fast model, low effort** (e.g. `gpt-5-nano`/`mini`, `minimal`/`low`) — a short
  query in, a small object out — to stay inside the ~500 ms first-paint budget.
- **Non-fatal / degradable.** If the parse call errors or times out, fall back to
  embedding-only (+ profile facets) and still return results. The parser is an *enhancement*,
  never a single point of failure.
- **Cache by normalized query** so repeated/near-identical queries don't re-hit the LLM.
- **Compliance:** sends the user's own query text to OpenAI (lower-sensitivity than the
  purchased review corpus, but still outbound) — note which key/ZDR posture it uses.

Because the facet object is a stable contract, a **structured-selector UI** (cuisine / price /
vibe chips) can later produce the *same* object with zero downstream changes — but the MVP is
free-text + LLM.

**Facet object schema** (strict; all keys required; `null` = "unstated" → eligible for the
profile fallback in step 2):

```jsonc
{
  "search_text":  "string",                 // cleaned text for the EMBEDDING (hard-constraint words stripped)
  "cuisine":      "string | null",
  "price_max":    "1 | 2 | 3 | 4 | null",   // 1=cheap … 4=very expensive
  "atmosphere":   "quiet | lively | null",
  "occasion":     "string | null",
  "dietary":      ["string", ...],          // [] if none stated
  "open_now":     "boolean | null"
}
```

The free-text → facet mapping looks like this. The system prompt tells the parser: *use
`null` for anything not explicitly stated — never infer; do NOT infer `atmosphere` from
`occasion`; `search_text` = the query with hard-constraint words (price, dietary, open-now)
removed.*

Example 1 — **IN** (user text):
```
somewhere lively for a group dinner tonight, really good seafood, nothing too pricey
```
**OUT**:
```json
{
  "search_text": "lively seafood spot for a group dinner",
  "cuisine": "seafood",
  "price_max": 2,
  "atmosphere": "lively",
  "occasion": "group",
  "dietary": [],
  "open_now": true
}
```
`search_text` dropped *"nothing too pricey"* (that became `price_max: 2`) but kept the
vibe/cuisine words — so the embedding matches on semantics while price is enforced
structurally.

Example 2 — **IN** (the "never infer" rule):
```
korean food for date night
```
**OUT**:
```json
{
  "search_text": "korean food for a date",
  "cuisine": "korean",
  "price_max": null,
  "atmosphere": null,
  "occasion": "date",
  "dietary": [],
  "open_now": null
}
```
`atmosphere` returns **`null`, not `quiet`** — "date night" implies nothing about volume. That
`null` is what routes noise to the profile fallback (or leaves it unconstrained). This is the
`review_noise` gating rule below, enforced at the schema level.

**What never touches the LLM:** the profile does **not** go in — resolution (query-vs-profile)
is deterministic code in step 2; the parser doesn't embed, rank, or see spots. Its only job is
`text → facet object + search_text`. Keeping the profile out also means the parse can be cached
purely by query text.

### `review_noise` gating rule (do not skip)
`review_noise` is a **conditionally-applied hard filter/boost, defaulting off.** It is
applied **only when the intent parser extracts an explicit atmosphere/volume constraint**
from the query — it is **never inferred from occasion.** This is a correctness rule, not a
tuning knob:

- **Occasion ≠ atmosphere.** The parser MUST keep these as separate facets. An `occasion`
  value (`date night`, `birthday`, `business lunch`) must **not** populate the `noise`
  constraint. "Date night" says nothing about whether the user wants quiet or lively — a
  great date can be either — so it must not penalize `lively`/`loud` spots.
- **Only explicit atmosphere tokens set the filter:** "quiet", "somewhere we can talk",
  "not too loud" → require/boost `quiet`; "lively", "buzzy", "somewhere with energy" →
  require/boost `lively`/`loud`. If the parser emits no atmosphere facet, **`review_noise`
  is not referenced at all** — noise stays free.
- **Non-explicit noise preference still works via the embedding.** The vibe/noise language
  is baked into `review_digest_embedding`, so "lively date" already ranks lively spots up
  through cosine similarity. The structured `review_noise` column exists purely for the
  **hard** case ("must be quiet") that cosine averaging would otherwise soften — not to
  impose an atmosphere the user never asked for.

The earlier `"quiet date"` shorthand for this filter was ambiguous (it could be misread as
`date ⇒ quiet`); the rule above supersedes it. The illustrative case is an **explicit**
"quiet" token, not the occasion.

### Dietary via reviews (not allergens)

Structured dietary/allergen data on spots is thin — `dietary_flags` carries only
`vegetarian_options` (Places), and `allergen_warnings` is empty (`spot_features_extractor.py`
writes `[]`; the review scanner was deferred). So dietary matching leans on the **reviews**
instead — but **only for dietary *preference* (vegan/vegetarian/GF), and allergens are out of
scope.**

Reviews are a **soft, lower-confidence** signal: fine for nudging dietary preference, but not a
basis for allergen claims — we have **no verified or authoritative allergen data**, and won't
manufacture it from casual review mentions. Allergens are **parked** until a proper
(menu/official) source exists; the endpoint makes no allergen guarantee, hard or soft.

**Worked example.** User searches **"vegan dinner spot"**; three spots have digests:

| spot | `review_digest_json.dietary_notes` (what reviews said) | `review_dietary` (promoted array) |
|---|---|---|
| **Green Fork** | *"Extensive vegan & vegetarian menu, clearly labeled plant-based dishes."* | `["vegan","vegetarian"]` |
| **Nonna's Table** | *""* (reviewers never mentioned dietary) | `[]` |
| **The Salt Cellar** | *"Limited options for non-meat eaters; mostly steak and seafood."* | `[]` |

**Path 1 — soft & free today, via `s_review_match`.** `dietary_notes` is already baked into
`review_digest_embedding` (the `Dietary: {dietary_notes}` slice of `_digest_embed_text`), so
scoring "vegan dinner spot" against it *already* nudges ranking with zero new code:

```
Green Fork    s_review_match ≈ 0.55   ← "extensive vegan menu" pulls it up
Nonna's Table s_review_match ≈ 0.30   ← silent, stays neutral
Salt Cellar   s_review_match ≈ 0.18   ← "limited non-meat" pushes it down
```

Note it even downranks Salt Cellar correctly, because the LLM digest captured the *negative* —
something a keyword `LIKE '%vegan%'` over raw review text could not.

**Path 2 — optional promoted `review_dietary` column (labeled boost/filter).** The soft nudge
can't drive a UI toggle or a badge. For that, have the summarizer emit a structured
`review_dietary` array alongside `dietary_notes` (same promotion pattern as `review_noise`),
then: **boost** `review_dietary @> ['vegan']`; **badge** "✓ vegan options — mentioned in
reviews"; **soft filter** a "vegan" chip ranks matches first but still shows the rest.

**The rule — review-derived dietary is *evidence, not a guarantee* → soft, never a hard
exclude on absence.** Nonna's `review_dietary` is `[]` because *no one wrote about dietary*,
**not** because it lacks vegan food — it may satisfy the query perfectly.

```
has vegan evidence  → boost / badge
no evidence (empty) → keep it, just don't boost   ← NEVER hard-exclude
```

Hard-dropping every empty `review_dietary` would delete Nonna's for a query it might satisfy —
absence of evidence ≠ evidence of absence (the same NULL policy as everywhere else). Any "vegan
only" filter is therefore a *ranking* preference labeled "review-sourced, not confirmed," never
a hard delete. This is exactly the **medium-tier** evidence the Phase-1 allergen plan
anticipated (high-tier = official/Places; medium-tier = review heuristic): usable as a boost,
labeled lower-confidence, never authoritative. **Allergens stay parked** — they get neither
Path 1 nor Path 2.
