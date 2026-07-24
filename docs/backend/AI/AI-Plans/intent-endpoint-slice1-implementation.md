# Intent endpoint — `POST /spots/recommend-by-intent` (Slice 1: embedding-first)

_Date: 2026-07-05 · Status: in progress · Scope: the embedding-core slice of the Phase-2 intent
endpoint (LLM facet parser deferred to Slice 2). Consumes the shipped `review_digest_embedding`
substrate from
[`spot-digest-embedding-supersedes-per-review-rag.md`](./spot-digest-embedding-supersedes-per-review-rag.md)._

## Context

The Phase-2 review substrate is shipped: every summarized spot now carries a spot-level
`review_digest_embedding` (vibe/occasion/atmosphere, 1536-d) plus a structured `review_noise`
column, alongside the Phase-1 `taste_embedding` (cuisine/dietary/identity). The one unbuilt
piece of Phase 2 is the endpoint that *consumes* them at request time —
`POST /spots/recommend-by-intent` — which lets a user type free text ("quiet romantic date
night", "lively waterfront seafood") and get review-informed spot rankings. Its mechanic is
already validated read-only by `scripts/srvn_digest_probe.py`.

The full design (in `docs/plans/AI-Plans/spot-digest-embedding-supersedes-per-review-rag.md`,
"Intended future integration") has two layers: an **embedding core** (embed the query once,
blend cosine vs both spot vectors, geo/price filter) and a request-time **LLM facet parser**
(structured hard filters: price cap, explicit-noise, dietary evidence). This plan builds
**Slice 1 = the embedding core** — a real, working endpoint on the proven `/spots/recommended`
two-stage template — and defers the LLM parser to Slice 2 (outlined at the end). The design
itself frames the parser as "an enhancement, never a single point of failure," so shipping the
core first is low-risk and gets a usable endpoint fast.

**Scope decisions:**
- **Embedding-first for Slice 1**; LLM parser + hard filters = Slice 2.
- **`@jwt_required(optional=True)`** — public search; add a personalization term only when a
  token resolves to a user with a `taste_embedding` (matches the design's "+ s_personal if
  logged in"). Intent search is useful logged-out.
- **Reuse `PagedSpotsSchema`** (`{data, paging}`) — no new caveats/meta envelope.
- **No exposure feature flag** — a net-new path; exposure is controlled by whether the client
  calls it. (One **testing** flag exists: `SRVN_INTENT_SEED_ONLY`, default off — when on, restricts
  recall to the synthetic `SEED_FAKE_` catalog so the endpoint can be validated against fake data.)

## What the endpoint does (request → ranked spots)

1. Validate + embed the query **once** via `OpenAIEmbeddingClient.embed_batch([query])`, using
   the **conversational (ZDR) key** so free-text user queries stay on the zero-retention
   project — same compliance posture as the digests. (Correctness only needs the same *model*,
   `SRVN_EMBEDDING_MODEL`; the ZDR key is the compliance requirement. Do **not** copy the
   probe, which uses the taste-graph key.)
2. **Stage-1 SQL recall** (geo-bounded, pool cap 200): `ST_DWithin` within radius, OUTER-join
   `SrvnSpotTasteFeatures`, order by `LEAST(taste_dist, review_dist)` so a spot recalls if
   **either** vector matches the query.
3. **Stage-2 Python rerank**: `score_intent_candidate` per candidate, blending two query-cosine
   terms + distance/price/popularity + optional personal term; renormalize over active terms.
4. Sort, paginate, `lazy_refresh_spot` + `SpotController.prepare_spots_for_response`,
   `paginate_results`.

## Files

**New**
- `ressy_backend/routes/srvn_recommend_by_intent.py` — new `intent_blueprint`
  (`Blueprint("SpotsIntent", url_prefix="/spots")`), the route, Stage-1 `LEAST` recall, a lazy
  embed-client factory, degradation. A dedicated file keeps every request-time line touching
  `review_digest_embedding` in one auditable place (compliance). Registration = 2 lines in
  `app.py`, mirroring `srvn_taste_profile_blueprint`. Two blueprints may share
  `url_prefix="/spots"` — routes are namespaced by blueprint name.
- `ressy_backend/schemas/spot.py` → add `SpotsIntentRequestSchema`.
- `tests/srvn_backend/api/test_srvn_recommend_by_intent.py`
- `tests/srvn_backend/services/srvn_taste_graph/test_scoring_intent.py`

**Modified**
- `ressy_backend/services/srvn_taste_graph/scoring.py` — add `score_intent_candidate` + `_IW_*`
  weights + a shared `_spot_taste_sim` helper. **Do not touch `score_candidate`** — the
  `/spots/recommended` path must stay byte-for-byte identical (review signal must never enter it).
- `ressy_backend/app.py` — register `intent_blueprint`.

## Scoring — sibling pure function in `scoring.py`

A **sibling** function, not an extension of `score_candidate`. Decisive reason: compliance —
`score_candidate` reads only `features.taste_embedding` and has no concept of the review vector;
a separate function makes it *structurally impossible* for the recommended path to touch review
signal. It also has no cuisine-Jaccard/cold-start branch (the query is always present) and an
independent weight table. All real helpers (`_cosine_similarity`, `_score_price`, distance decay,
popularity guard) are shared.

```python
def score_intent_candidate(
    features, user, profile, *,
    query_vector, distance_m, popularity_signal, pool_max_popularity, occasion=None,
) -> float
```

**Terms + weights:**

| term | weight | value | drop when |
|---|---|---|---|
| `s_query_taste`  | `_IW_QUERY_TASTE=0.30`  | `cos(query, features.taste_embedding)` | features/vec None / `embedding_model != current` / cosine None |
| `s_review_match` | `_IW_REVIEW_MATCH=0.30` | `cos(query, features.review_digest_embedding)` | features/vec None / cosine None — **no model gate** |
| `s_distance`     | `_IW_DISTANCE=0.20`     | `exp(-dist/2000)` | always active |
| `s_popularity`   | `_IW_POPULARITY=0.10`   | `log1p(pop)/log1p(pool_max)` | `pool_max<=0 → 0.0` |
| `s_price`        | `_IW_PRICE=0.05`        | `_score_price(user, features)` | never dropped; **`1.0` when `user is None`** |
| `s_personal`     | `_IW_PERSONAL=0.05`     | `cos(profile.taste_embedding, features.taste_embedding)` | profile/vec None or model mismatch |

Renormalize over active components (`score = sum(w*v)/sum(w)`), reuse `_OCCASION_BONUS`, clamp
`[0,1]`. Factor `_spot_taste_sim(vec, features)` so `s_query_taste` and `s_personal` share one
model gate. **Guards:** `user is None` must not crash `_score_price`; cold-vector (both query
vectors NULL) → distance/price/popularity only, finite.

`s_price`/`s_personal` are *personalization* signals (logged-in only); query-stated hard
constraints (price cap, explicit noise, dietary) are deliberately Slice 2 — embeddings average,
so hard constraints must live outside the embedding (same reason `review_noise` is its own column).

## Stage-1 recall ORDER BY

Build `origin_geog`/`spot_geog`/`distance_col`/`within` exactly as `_personalized_candidates`
(`spot.py:487-492`). Then:

```python
taste_dist  = SrvnSpotTasteFeatures.taste_embedding.cosine_distance(qvec)
review_dist = SrvnSpotTasteFeatures.review_digest_embedding.cosine_distance(qvec)
order_by = [func.least(taste_dist, review_dist).asc().nullslast(), distance_col.asc()]
# OUTER-join features; filter within + Spot.deleted_at.is_(None); .limit(_INTENT_CANDIDATE_POOL_SIZE=200)
```

Postgres `LEAST` ignores NULLs → a spot recalls on whichever vector it has; NULL only when both
NULL → `nullslast`. `LEAST`-of-two can't use a single-column HNSW index, but the `ST_DWithin`
geo prefilter bounds the set (same shape as the existing personalized Stage-1). `LEAST` beats the
probe's digest-only order because it doesn't starve the pool while digest coverage ramps.

## Request schema — `SpotsIntentRequestSchema`

`latitude`/`longitude` `Float(required=True)`; `query` `String(required=True,
validate=validate.Length(min=1, max=512))`; `radius`/`limit`/`offset` mirror
`SpotsNearbyRequestSchema` defaults; `occasion` `String(allow_none=True)`. `@blp.arguments(...,
location="json")`. Also `query.strip()` → `abort(400)` if empty. Response = `PagedSpotsSchema`.

## Degradation + failure modes

- **Embed fails/times out → 503 + `Retry-After`, never lexical** (catch
  `openai.APIConnectionError/APITimeoutError/RateLimitError/APIStatusError`). Missing-key
  `RuntimeError` → 503 (no `Retry-After`). Register `@blp.alt_response(503, ...)`.
- **No spots in radius → 200 empty.**
- **Zero digests in DB → taste/geo-ranked results** (`LEAST` recalls on taste; Stage-2 drops
  only `s_review_match`).
- **No request-time caching in Slice 1** (obvious Slice-2 optimization).

## Embed-client injection seam

Lazy module-level factory in the route module (mirrors `review_summarizer._get_default_embedding_client`),
using the conversational (ZDR) key. Tests monkeypatch it to a `FakeClient` returning a
deterministic 1536-d `_vec(...)`.

## Tests

**API** — `test_srvn_recommend_by_intent.py` (modeled on `test_srvn_recommended_personalized.py`;
inject fake embedding client): review-vibe ordering; taste axis when no digest; either-vector
recall; anonymous 200 (no `s_personal` crash); authenticated personal signal; embed failure →
503+`Retry-After` (not a 200 lexical result); no spots → 200 empty; empty/whitespace query → 400;
total capped to pool; **cross-endpoint guard** — a digest-only-aligned spot is *not* promoted by
`/spots/recommended`.

**Scoring unit** — `test_scoring_intent.py` (`SimpleNamespace` stand-ins, monkeypatch
`_current_embedding_model`): full 6-term path; `s_query_taste` drop on model-mismatch/NULL;
`s_review_match` present even on model-mismatch (the asymmetry) and dropped on NULL; `s_personal`
drop; **`user=None` → price 1.0, no crash**; cold-vector; `pool_max<=0` guard; clamp; determinism.

## Verification

1. `poetry run pytest tests/srvn_backend/services/srvn_taste_graph/test_scoring_intent.py
   tests/srvn_backend/api/test_srvn_recommend_by_intent.py` — green.
2. Full suite green (esp. `test_srvn_recommended_*` + `test_scoring.py` — proves `/recommended`
   untouched).
3. Manual: `poetry run python scripts/srvn_digest_probe.py "quiet romantic date night"` baseline,
   then `POST /spots/recommend-by-intent` with/without a JWT — ranking tracks the probe.
4. Compliance: same query on `/spots/recommended` vs `/recommend-by-intent` for a digest-only
   spot — ranks in intent, not in recommended.

## Known follow-ups (Slice 2)

- Digest-embedding model staleness: `review_digest_embedding` has no per-row model column, so an
  `SRVN_EMBEDDING_MODEL` swap silently cross-compares. Slice 2: add `review_digest_embedding_model`
  and gate `s_review_match` on it.
- Renormalize-drop doesn't penalize a query-unmatchable spot; `nullslast` mitigates for Slice 1.
- **The LLM facet parser** (`intent_parser.py`): free text → facet object (`search_text`,
  `cuisine`, `price_max`, `atmosphere`, `occasion`, `dietary`, `open_now`); `search_text` feeds
  the embedding, facets drive explicit-only hard filters/boosts (noise only on an explicit
  atmosphere token; review-derived dietary as a soft boost, never a hard exclude). Degradable,
  cached by normalized query.
