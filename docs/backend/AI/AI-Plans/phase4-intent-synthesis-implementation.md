# Phase 4 — Intent-endpoint AI synthesis (implementation plan)

_Date: 2026-07-18 · Status: draft, scope locked 2026-07-18 · Scope: convert
`POST /spots/recommend-by-intent` into a single SSE response that flushes the math-ranked
first paint in <1s, then streams one combined LLM rerank + explanation pass (top 10) over
the same connection. Group dining (the roadmap's old 4b) is **removed**; there are no
feature flags and no daily token budget._

## Context

Phase 2/3 shipped `/spots/recommend-by-intent` (`ressy_backend/routes/srvn_recommend_by_intent.py`):
parse facets (degradable, gpt-5-nano) → embed query (required, 503 on failure) → Stage-1 SQL
recall (pool 200, `_intent_candidates`) → `score_intent_candidate` rerank → page. That response
returns in well under a second — it is the **first paint** and must never regress.

The limitation: no LLM ever looks at the ranked spots. The scoring math knows a spot's digest
is *near* the query in embedding space but can't reason about trade-offs ("they asked for quiet
and romantic — reviewers call this place loud on weekends") and can't tell the user *why* a spot
is on the list. Phase 4 adds that judgment layer without ever making the user wait for it.

Serving reality that shapes the design (verified 2026-07-18):

- gunicorn **eventlet** workers (`app.py:1-7` monkey-patches socket+select; prod `-w 1`,
  `Dockerfile:30`) — a held SSE connection and in-stream OpenAI (httpx) calls are cheap green I/O.
  This is the app's first streaming endpoint (zero prior `stream_with_context` / `text/event-stream`).
- **JWT header auth keeps working**: the client initiates the POST with full header control (it is
  not a browser `EventSource` on a second GET), so `@jwt_required()` stays as-is. No token in URLs.
- **DB pool is tiny** (pool_size=5 + max_overflow=2 per process; managed PG ≈22 usable) — the
  generator must release the DB session before the LLM call so no connection is pinned for ~5s.
- nginx `location /` does **not** disable proxy buffering; the endpoint path needs its own block
  with `proxy_buffering off` (mirror the `/socket.io` block, `nginx/conf.d/local.conf:35-44`).

## Decisions locked with the user (2026-07-18)

- **Single endpoint, converted to SSE** — the existing POST becomes a streaming response; no
  second endpoint, no `request_id`, no Redis context handoff, no capability token. **Breaking
  response-contract change requiring a coordinated frontend release** (the RN client switches its
  search call to an SSE consumer, e.g. `react-native-sse`, which supports POST + headers + body).
- **Single combined LLM call** — one model reranks and explains in one pass, returning the
  **top 10** with a grounded explanation each (supersedes the roadmap's two-stage
  reranker + per-spot explainer).
- **No feature flags** — ships always-on; the model choice is a plain config var.
- **No daily token budget** — the synthesis call runs on every search unconditionally. Spend
  scales linearly with traffic (~2¢/search), monitored via the `srvn_recommend_synthesis`
  billing tag on the OpenAI dashboard.
- **Cards carry the digest + the latest 50 raw reviews per spot** — maximum evidence for the
  model (~75k input tokens/call, ~$0.02, synthesis frames at ~5–6s p95). The review fetch happens
  *after* the results frame is flushed, so first paint is unaffected. `SrvnSpotReview` rows are
  PII-stripped at ingest and already flow to OpenAI via the summarizer — same compliance posture.
- **Prompt exclusions**: the `open_now` facet is stripped (dead facet — nothing consumes it and
  cards carry no opening hours); diner grounding is **dietaries + dietary_strictness only**
  (allergens/allergen_handling deliberately excluded).
- **Group dining (old 4b) removed** — `group_taste_merger.py` and
  `POST /events/{event_id}/recommend-by-intent` are no longer planned.
- **Pagination removed (added 2026-07-18, post-Slice-2 review)** — `limit`/`offset` are gone
  from the request schema and the `results` frame is `{"data": [...]}` (no paging envelope).
  The endpoint surfaces exactly `SYNTHESIS_CANDIDATE_COUNT = 10` spots — the same set the
  synthesis judges — so every surfaced spot is eligible for an explanation and the rerank can
  never reference an unsurfaced id. Trade-off accepted: the LLM no longer sees pool ranks
  11–20, giving up promote-from-below in exchange for a fully-annotated, gap-free response.

## Endpoint contract (after conversion)

`POST /spots/recommend-by-intent` — same request schema (`SpotsIntentRequestSchema`), same
`@jwt_required()`; response becomes `text/event-stream` (headers `Cache-Control: no-cache`,
`X-Accel-Buffering: no`). Frame sequence:

```
: connected                      ← immediate comment frame (flushes proxy buffers)

event: results                   ← the math-ranked top-10 spots as one frame, <1s
data: {"data": [...spots...]}    (no paging envelope — pagination removed 2026-07-18)

                                 (server then: fetches latest 50 reviews for those 10
                                  candidates, releases the DB session, calls the LLM)

event: rerank                    ← after the synthesis LLM call (after results)
data: {"order": [<full repaired permutation of the surfaced ids>],
       "reasons": {"<spot_id>": "<explanation>", ...}}

event: explanation               ← one per ranked pick (≤10), same data as reasons
data: {"spot_id": 6272, "text": "..."}

event: done
data: {"status": "ok" | "degraded"}
```

- Pre-flush errors (missing lat/lng 400, auth 401, embed failure 503 + `Retry-After`) remain plain
  HTTP error responses — they occur before any frame is written, semantics unchanged.
- Post-flush failures never break the stream: a synthesis-LLM failure
  (refusal / `finish_reason=length` / bad JSON / OpenAI transport error / no-key `RuntimeError`)
  → log + `done degraded`. The user always has the `results` frame; the stream never 503s.
- No heartbeat, no `Last-Event-ID`, no replay: a dropped connection re-runs the search.
- The generator flushes `results`, runs the bounded review fetch while the session is still open,
  then **releases the DB session** before the LLM call.
- The client renders on `results` and enhances in place when `rerank`/`explanation` arrive; it
  must close the connection on `done`.

## The synthesis call (single LLM pass)

- **Input**: the user's query + parsed facets (minus `open_now`), the top-`min(10, pool)`
  candidate cards in first-paint score order (`SYNTHESIS_CANDIDATE_COUNT` — identical to the
  surfaced set since the 2026-07-18 pagination removal), and the diner grounding line.
- **Card**: spot_id, name, rank, score, distance_m, price_tier, cuisines, the ~600-char digest
  rendered from `review_digest_json` (vibe/noise/dietary_notes/occasion_fit/standout_dishes),
  **plus the latest 50 reviews** — `{text (capped 600 chars, mirroring the summarizer's
  `_MAX_REVIEW_CHARS`), rating, published_at date}` — fetched post-results-flush via one
  window-function query over `SrvnSpotReview`
  (`row_number() OVER (PARTITION BY spot_id ORDER BY published_at DESC NULLS LAST, id DESC) <= 50`,
  candidate ids only, `deleted_at IS NULL`; the partial index
  `ix_srvn_spot_reviews_spot_id_active` covers it). Spots with no reviews get an empty list; the
  digest is the distilled overview, the raw reviews the citable evidence.
- **Task** (system prompt): select and order the **top 10** by fit to the stated intent; 1–2
  grounded sentences per pick citing only card facts (digest or review quotes); acknowledge stated
  diets without ever guaranteeing dietary suitability; thin/empty evidence gets shorter,
  non-fabricated explanations (every real — non-`SEED_FAKE_` — spot has no digest and no reviews
  until vendor ingestion covers it).
- **Output** (strict Structured Outputs, `additionalProperties:false`, all keys required):
  `{"ranking": [{"spot_id": int, "explanation": str}, ...]}`, ≤10 entries.
- **Repair** (pure `_repair_ranking(ranking, input_ids)`): drop hallucinated/duplicate ids; the
  emitted `order` = model picks + unchosen candidates appended in first-paint score order — a
  strict permutation of the input, so the model can select and shuffle but never lose or invent
  spots. Explanations exist only for the picks.
- **Model**: `SRVN_GPT_5_MINI_MODEL`, default **gpt-5-mini** (decision 2026-07-18: reuse the
  digest's prose-model knob rather than adding a dedicated `SRVN_RECOMMEND_SYNTH_MODEL` var —
  same model either way; gpt-5-nano is the cost lever, moving both; split a dedicated var back
  out if synthesis ever needs its own cost/latency point). `reasoning_effort` pinned `"minimal"` at the factory;
  billing tag `user="srvn_recommend_synthesis"`; key resolution
  `CONFIG.OPENAI_API_CONVERSATIONAL_KEY or CONFIG.OPENAI_API_KEY`.
- **Latency/cost** (updated 2026-07-18 for the 10-card set): ~40k input / ~800 output tokens
  (10 cards × up to 50 reviews × ~75 tokens) →
  synthesis frames at p95 ~4–6s after the results frame; ~$0.01/request at gpt-5-mini rates.
  Acceptable because the user is already browsing first-paint results while it runs. Per-request
  `usage_total_tokens` is logged for observability; there is **no budget cap** by decision.

## Slices

Each slice is one PR and ships with tests (repo rule). Patterns to mirror: the LLM client shape
from `intent_parser.py` (Protocol + `OpenAI...Client(*, client=None, api_key=None, model=None,
reasoning_effort=None, max_retries=2)`, strict `json_schema`, `...Refused` exception, lazy module
factory monkeypatched in tests).

### Slice 1 — SSE conversion (no LLM yet)

- `ressy_backend/routes/srvn_recommend_by_intent.py` — convert the route to
  `Response(stream_with_context(gen()), mimetype="text/event-stream")` emitting
  `: connected` → `results` → `done ok`; keep `(score, spot, features, distance_m)` tuples through
  scoring; release the DB session after the `results` frame is built. smorest: keep
  `@intent_blueprint.arguments(...)`, drop the `@response` schema decorator (SSE can't be
  modeled), keep `alt_response` docs for 400/401/503, dump the results payload manually via
  `PagedSpotsSchema().dump(...)`.
- New `ressy_backend/services/srvn_taste_graph/intent_synthesis.py` — `_sse_comment()` /
  `_sse_event(name, data)` formatters; `build_candidate_cards(top)` (plumbed for Slice 2).
- `nginx/conf.d/local.conf` — `location /spots/recommend-by-intent { proxy_buffering off; ... }`
  mirroring the socket.io block.
- **Tests**: adapt every existing test in `tests/srvn_backend/api/test_srvn_recommend_by_intent.py`
  to a shared `_parse_sse(text)` helper (the stream terminates, so
  `response.get_data(as_text=True)` fully drains it); assertions redirect to the parsed `results`
  frame — the payload shape inside it is unchanged. New: frame order, `content_type`, pre-flush
  400/503 still plain HTTP errors.
- **This is the breaking-contract slice — coordinate the frontend's switch to an SSE consumer in
  the same release.**

### Slice 2 — the synthesis call

- New `ressy_backend/services/srvn_taste_graph/intent_synthesis_client.py` — `SynthesisClient`
  Protocol `synthesize(*, query: str, facets: dict, candidates: list[dict], diner_context: str)
  -> SynthesisResult`; frozen `SynthesisResult(ranking: list[tuple[int, str]],
  usage_total_tokens: int, model_id: str)`; `OpenAISynthesisClient`; strict `_SYNTH_SCHEMA`;
  `SynthesisRefused`; the grounded-only system prompt per the spec above.
- `intent_synthesis.py` — `_load_latest_reviews(session, spot_ids, per_spot=50) ->
  dict[int, list[dict]]` (the window-function query; text capped at 600 chars);
  `_get_synthesis_client()` lazy factory (pins `minimal`; tests monkeypatch here); pure
  `_repair_ranking`; `run_synthesis(query, facets, cards, diner) -> Iterator[tuple[str, dict]]`
  yielding `rerank` → `explanation`×N → `done`, exception taxonomy mirroring `_parse_intent_safe`.
- Route generator: flush `results` → fetch reviews → release session → chain `run_synthesis`.
- `ressy_backend/config.py` — no new var (decision 2026-07-18: the client reads the existing
  `SRVN_GPT_5_MINI_MODEL`). Per-stage ms + token-usage logging.
- **Tests**: unit client matrix (happy / refusal / `finish_reason=length` / bad JSON /
  missing key ⇒ `RuntimeError`); `_repair_ranking` edges (hallucinated id, duplicate, >10 entries,
  empty); `_load_latest_reviews` (latest-50 by `published_at DESC NULLS LAST`, char capping,
  soft-deleted excluded, review-less spots ⇒ empty list); API full flow with a fake client
  (`results` → `rerank` permutation of the top-20 ids → ≤10 `explanation` frames → `done ok`;
  cards received by the fake include the seeded reviews); degrade-on-raise (`results` +
  `done degraded`, HTTP 200); diner grounding excludes allergens and facets exclude `open_now`
  (assert on what the fake received).

## Verification

- `poetry run pytest` pure suites; api-marked with `RESSY_TESTING=1 TEST_DATABASE_URL=...`.
- Curl smoke through nginx:
  `curl -N -X POST http://localhost/spots/recommend-by-intent -H "Authorization: Bearer $TOK"
  -H "Content-Type: application/json" -d '{"latitude":..., "longitude":..., "query":"quiet romantic seafood"}'`
  — `results` frame in <1s, synthesis frames ~5–6s later, `done` closes. Frames must arrive
  **incrementally** (this is the proxy-buffering check).
- Degrade drill: unset the OpenAI key ⇒ `results` frame intact + `done degraded`.
- Latency: per-stage ms logging (review-fetch ms, LLM ms); measure synthesis-frame p95 on the seed
  catalog against the ~5–6s expectation; `gpt-5-nano` and a lower per-spot review count are the
  levers if it drifts.
- DB-pool check: confirm the session is released after the review fetch and before the LLM call
  (no idle connection held during synthesis under concurrent streams).

## Open items

- **Frontend coordination is a hard dependency of Slice 1** (the search call switches to an SSE
  consumer; `react-native-sse` supports POST/headers/body).
- Prod ingress must disable response buffering for this path (only dev nginx is in-repo) — verify
  at deploy.
- Dropped connection = full re-run (results + LLM re-spend); acceptable for a ~6s window.
- **Unbounded spend accepted**: no daily cap means synthesis cost tracks traffic 1:1 (~2¢/search)
  with no backstop against bursts or client retry loops. Watch the `srvn_recommend_synthesis`
  billing tag; the summarizer-style Redis day-counter breaker (`review_summarizer.py`) can be
  added back in an afternoon if a surprise appears.
- Cost/latency dial: 50 reviews/spot is the chosen maximum-evidence setting. If economics bite at
  scale, the levers are the per-spot review count (module constant), `gpt-5-nano`, or digest-only
  cards — all env/constant changes, no redesign.
- `ParsedIntent.open_now` remains parsed-but-unconsumed everywhere (and stripped from the
  synthesis prompt). A real server-side open-now filter (`Spot.regular_opening_hours` +
  `timezone` in `_intent_candidates`) is a separate future slice.
- Real-spot reviews/digests still pending vendor ingestion — until then real spots stream thin
  explanations; the prompt tolerates empty evidence.

## Critical files

- `ressy_backend/routes/srvn_recommend_by_intent.py` — SSE conversion + generator flow
- `ressy_backend/services/srvn_taste_graph/intent_synthesis.py` — frames, cards, review fetch, `run_synthesis` (new)
- `ressy_backend/services/srvn_taste_graph/intent_synthesis_client.py` — the LLM client (new; mirrors `intent_parser.py`)
- `ressy_backend/models/srvn_spot_review.py` — `SrvnSpotReview` (latest-50 source; PII-stripped)
- `ressy_backend/services/srvn_taste_graph/intent_parser.py` — client/Protocol/strict-schema pattern to mirror
- `ressy_backend/config.py` — `SRVN_GPT_5_MINI_MODEL` (shared prose-model knob; no new var)
- `nginx/conf.d/local.conf` — stream location, `proxy_buffering off`
- `tests/srvn_backend/api/test_srvn_recommend_by_intent.py` — existing suite adapted to SSE frames
