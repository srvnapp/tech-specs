# Phase 3 — Taste enrichment v2 (implementation plan)

_Date: 2026-07-12 · Status: **shipped** (updated 2026-07-18 — 3A #214, 3B #216, 3D #217; 3C
dropped; re-extract-after-re-digest fix #219) · Scope: raise the data quality of
`srvn_spot_taste_features` by mining the already-ingested review digest, add an explicit
`vibe` endpoint facet, and expand the cuisine taxonomy._

## Context

Phase 2 shipped `/spots/recommend-by-intent`, and Slice 2 gave it facet enforcement that reads
`occasion_tags`, `dietary_flags`, `cuisines`, `price_tier`, and `review_noise`. But
`extract_features()` (`services/srvn_taste_graph/spot_features_extractor.py`) populates the
structured columns from **Google Places only**: `occasion_tags` is at most `["group"]`,
`dietary_flags` at most `["vegetarian_options"]`, there is no ambiance signal, and
`allergen_warnings` is hard-coded `[]`. So the endpoint's occasion/dietary/cuisine bonuses
almost never fire — ranking leans entirely on embeddings.

Meanwhile the review summarizer (`review_summarizer.py`) already distills each spot's reviews
into `review_digest_json` with real signal (`vibe`, `noise`, `dietary_notes`, `occasion_fit`,
`standout_dishes`), but only `noise` is lifted into a structured column (`review_noise`); the
rest only feeds the `review_digest_embedding`.

**Phase 3 lifts that review signal into the structured, filterable columns** so the facets
already built have data to bite on, and adds a matching `vibe` facet to the endpoint. It is
mostly about *what gets written* to `srvn_spot_taste_features`; only the `vibe` facet (3D)
touches the endpoint. It merges cleanly alongside Phase 4.

### Decisions locked with the user (2026-07-12)
- **Option B** — the summarizer emits controlled enum arrays **directly in its schema** (higher
  recall than deterministically parsing free text), accepting a one-time corpus **re-digest**.
- **Scope: three slices** — 3A cuisine taxonomy, 3B review-mined tags, 3D explicit `vibe` facet.
- **3C (medium-tier allergen scan) is DROPPED** — not being implemented. Consequently 3B's digest
  schema does **not** add `allergen_mentions` (a field with no consumer would be dead weight, like
  `service`). Trade-off: if allergen surfacing is ever revived, it will need its **own** re-digest
  (a schema-version bump) — it can't piggyback on 3B's re-digest anymore.
- **`service`** digest field: **kept** — unused today, but left untouched (not dropped).
- **`standout_dishes`**: **left embedding-only** — dish queries already get fuzzy lift via
  `review_digest_embedding`; no `signature_dishes` column and no dish facet this phase.

## Current state (verified 2026-07-12)

| Signal | Written today by | From | Gap |
|---|---|---|---|
| `cuisines` / `primary_cuisine` | `extract_features` | `Spot.types` via `normalize_cuisines` | taxonomy aliases thin |
| `price_tier` | `extract_features` | `Spot.info["price_level"]` | fine |
| `dietary_flags` | `extract_features` | `Spot.info["serves_vegetarian_food"]` only | no review-mined flags |
| `occasion_tags` | `extract_features` | `Spot.info["good_for_groups"]` → `["group"]` only | no review-mined occasions |
| `vibe_tags` | — | — | **column does not exist** |
| `allergen_warnings` | `extract_features` | hard-coded `[]` | **no medium-tier scan** |
| `review_noise` | `review_summarizer` | `review_digest_json["noise"]` (enum) | already done ✅ |
| `review_digest_json` | `review_summarizer` | LLM digest of review corpus | present, under-exploited |

`review_digest_json` shape today (from `review_summarizer_client._DIGEST_SCHEMA`):
`vibe` (free text), `noise` (enum quiet/moderate/lively/loud/unknown), `service` (free text,
**unused**), `dietary_notes` (free text), `occasion_fit` (free text), `standout_dishes` (array,
feeds the `review_digest_embedding` via `_digest_embed_text`).

## Cost-critical insight: the re-digest is one-time — bundle all schema changes

Every change to `_DIGEST_SCHEMA` forces the summarizer to re-run its LLM over every spot's review
corpus (real OpenAI spend, throttled by the existing `_DAILY_TOKEN_BUDGET` breaker, so it rolls
out over several days). **We must not re-digest twice.** 3B's new fields (`occasion_tags`,
`vibe_tags`, `dietary_flags`) all land in a **single digest-schema version bump / single re-digest
wave**. (Budget note, updated 2026-07-18: the GCP trial credit expired 2026-07-10 and
`SRVN_SEED_MONTHLY_CALL_CAP` is back at its `950` default in `.env` — there is no credit
backstop anymore; digest spend is OpenAI and stays governed by the `_DAILY_TOKEN_BUDGET`
breaker.)

---

## Slice 3A — Cuisine taxonomy expansion (isolated, cheap; ship first)

- `taste_taxonomies.py` — widen `CUISINE_ALIASES` (regional → canonical, e.g. `sichuan→chinese`,
  `neapolitan→italian`, `izakaya→japanese`, `taqueria→mexican`); add genuinely-missing
  `CanonicalCuisine` members found by the `Spot.types` distribution measurement.
- Bump `CURRENT_TASTE_TAXONOMY_VERSION` **3 → 4**.
- Near-zero re-embed: `extract_features` restamps the version but only clears
  `embedding_updated_at` when the rebuilt `taste_text` **hash** changes (hash-skip). Only spots
  whose canonical label actually changes pay an embed.
- Tests: extend `test_taste_taxonomies.py` (aliases normalize, idempotency, version == 4).

> **Two version bumps across 3A+3B is intentional and cheap (decision: keep two).** Each slice
> changes the rendered `taste_text`, so each bumps the version to force the worker to re-check all
> rows. But the worker's `_consider()` hash-skip (`embedding_worker.py:261-275`) **restamps
> unchanged rows with no OpenAI call** and re-embeds only rows whose text actually changed. So the
> two bumps cost two bounded DB **restamp sweeps**, not two re-embeds — the embedding-token spend
> is the same as a single bump. Consolidating to one bump was considered and rejected (it would
> delay 3A's cuisine re-embed until 3B ships).

---

## Slice 3B — Review-mined structured tags (core)

### Schema + taxonomy
- **New column** `srvn_spot_taste_features.vibe_tags` — match the existing `cuisines` column type
  + `server_default '[]'` + GIN index; Alembic migration backfills empty `[]`.
- **New column** `srvn_spot_taste_features.review_digest_schema_version` (SmallInteger) — the
  re-digest trigger.
- **New** `CanonicalVibe` enum + `VIBE_ALIASES` + `normalize_vibes()` in `taste_taxonomies.py`
  (e.g. `cozy`, `romantic`, `trendy`, `upscale`, `rustic`, `intimate`, `outdoor`, `minimalist`).
  Extend `OCCASION_ALIASES` / `DIETARY_FLAG_ALIASES` with review-phrasing forms.
- Bump `CURRENT_TASTE_TAXONOMY_VERSION` (→ 5 if 3A already merged, else fold into one bump).

### Digest schema (the one re-digest) — `review_summarizer_client.py`
- Extend `_DIGEST_SCHEMA.digest_json` with enum arrays **`occasion_tags`, `vibe_tags`,
  `dietary_flags`**, sourced from the taxonomy enum member values
  so schema ↔ taxonomy stay in sync (import the enums). Keep the existing free-text
  `vibe`/`occasion_fit`/`dietary_notes` (the embedding string still uses them). Leave `service`
  and `standout_dishes` **unchanged** (per decision). Strict mode → add every new key to
  `required`, keep `additionalProperties: false`.
- Update the system prompt: fill each array **explicitly-only** (mirror the intent parser's rule),
  choosing only from the provided enum values, empty when not evidenced.
- Add `CURRENT_REVIEW_DIGEST_SCHEMA_VERSION` constant.

### Re-digest trigger — `review_summarizer.py`
- Add the schema version to the skip guard (today
  `corpus_hash == features.review_corpus_hash and features.review_digest_model == model`): also
  require `features.review_digest_schema_version == CURRENT_REVIEW_DIGEST_SCHEMA_VERSION`. Stamp
  it on write. Bumping the constant forces a full re-digest, rate-limited by the existing
  `_DAILY_TOKEN_BUDGET` breaker. The summarizer writes the structured arrays **into
  `review_digest_json` only** — it does **not** touch the shared structured columns.

### Consumption — `spot_features_extractor.py`
- In `extract_features`, read `features.review_digest_json` and **UNION** its structured arrays
  with the Places-derived tags (dedup via the `normalize_*` helpers), writing the shared columns
  `occasion_tags` / `vibe_tags` / `dietary_flags`. `extract_features` stays the single writer of
  those columns; a spot with no digest behaves exactly as today.
- Fold `vibe_tags` into `build_spot_taste_text` (`text_builder.py`) as a new clause → changes
  `taste_text` for spots with reviews → one-time re-embed each (via the hash-skip trigger).

### Tests
`test_spot_features_extractor.py` (digest arrays → columns; UNION with Places dedups; no digest →
unchanged; `vibe_tags` change flips `embedding_updated_at` to NULL, idempotent otherwise),
`test_text_builder.py` (`vibe_tags` renders; empty → no clause), `test_taste_taxonomies.py`.

---

## Slice 3D — Explicit `vibe` endpoint facet (endpoint change; depends on 3B)

The only slice that touches the endpoint. After 3B, `vibe_tags` already helps ranking via the
embedding; 3D lets an explicit vibe in the query (*"cozy romantic spot"*) apply a **soft bonus**,
mirroring the existing cuisine/dietary bonuses. Vibe is subjective → soft additive bonus,
**never a hard filter** (the objective `atmosphere → review_noise` filter stays as-is).

- `intent_parser.py` — add a `vibe` field to `ParsedIntent` + `_INTENT_SCHEMA` (nullable string or
  array of `CanonicalVibe` values); `_coerce_facets` normalizes it. Update the prompt to
  **disambiguate `atmosphere` (noise: quiet/loud) from `vibe` (ambiance: cozy/romantic/trendy)** so
  the two facets don't collide.
- `scoring.py` — `score_intent_candidate` gains an optional `vibe` param + additive soft bonus
  matched against `features.vibe_tags` (same additive-after-renormalize pattern as
  `dietary`/`cuisine`; no-op when unset/unmatched; `[0,1]` clamp holds).
- `routes/srvn_recommend_by_intent.py` — thread `facets.vibe` into the `score_intent_candidate`
  call. No new config (reuses the existing parser model/effort).
- Tests: `test_intent_parser.py` (vibe parsed + normalized; atmosphere vs vibe distinct),
  `test_scoring_intent.py` (vibe bonus on match, no-op otherwise, clamp),
  `test_srvn_recommend_by_intent.py` (a `vibe` query boosts matching spots without excluding others).

> **Slice 3C (medium-tier allergen scan) was dropped** — see the decisions section. No
> `SRVN_REVIEW_ALLERGEN_FLAGS`, no `allergen_mentions` schema field, no allergen scanner. The
> existing high-confidence Places allergen path is unchanged; reviving review-derived allergen
> surfacing later would require its own re-digest.

---

## Worked example (one spot, 3B)

Reviews: *"intimate little spot, perfect for a date, great vegan options."*

`review_digest_json` after re-digest gains: `occasion_tags:["date_night"]`,
`vibe_tags:["intimate","romantic"]`, `dietary_flags:["vegan_options"]`.

Structured columns after `extract_features`:

| Column | Before 3B | After 3B |
|---|---|---|
| `occasion_tags` | `[]` | `["date_night"]` |
| `vibe_tags` | *(no column)* | `["intimate","romantic"]` |
| `dietary_flags` | `[]` | `["vegan_options"]` |
| `taste_text` | `Italian. Price tier 2.` | `Italian. Price tier 2. Occasion: date_night. Vibe: intimate, romantic. Dietary: vegan_options.` |

Endpoint effect: *"romantic vegan date spot"* now fires the occasion + dietary bonuses (no data
before), 3D adds the vibe bonus, and the richer `taste_text` sharpens the embedding match.

## Critical files
- `ressy_backend/services/srvn_taste_graph/taste_taxonomies.py` — cuisine aliases, `CanonicalVibe`, version bumps
- `ressy_backend/services/srvn_taste_graph/review_summarizer_client.py` — `_DIGEST_SCHEMA` enum arrays + prompt + schema-version constant
- `ressy_backend/services/srvn_taste_graph/review_summarizer.py` — schema-version in skip guard
- `ressy_backend/services/srvn_taste_graph/spot_features_extractor.py` — read digest, UNION into shared columns
- `ressy_backend/services/srvn_taste_graph/text_builder.py` — `vibe_tags` clause in `build_spot_taste_text`
- `ressy_backend/models/srvn_spot_taste_features.py` + Alembic migration — `vibe_tags`, `review_digest_schema_version` columns
- `ressy_backend/services/srvn_taste_graph/intent_parser.py` — `vibe` facet (3D)
- `ressy_backend/services/srvn_taste_graph/scoring.py` — `vibe` soft bonus (3D)
- `ressy_backend/routes/srvn_recommend_by_intent.py` — thread `facets.vibe` (3D)

## Rollout order
1. **3A** — cheap, de-risks the version-bump mechanics. **✅ shipped** (aliases + version 3→4 + tests).
2. **3B schema + re-digest** — **✅ shipped** (#216; plus #219, which re-extracts spot features
   after a re-digest). The re-digest wave rolls out under the budget breaker; expect a one-time
   re-embed wave for spots with digests.
3. **3D** vibe facet — **✅ shipped** (#217).

## Verification
- Pure-Python (always): `poetry run pytest tests/srvn_backend/services/srvn_taste_graph/test_taste_taxonomies.py test_spot_features_extractor.py test_text_builder.py test_intent_parser.py test_scoring_intent.py`.
- API/DB (needs `RESSY_TESTING=1` + `TEST_DATABASE_URL`): summarizer + extractor sweep + `test_srvn_recommend_by_intent.py`.
- Pre-3B measurement (also informs any 3A alias follow-up): `SELECT unnest(types) t, count(*) FROM spots GROUP BY t ORDER BY 2 DESC`.
- Post-3B (staging): re-digest populates the new digest_json arrays; NULL/empty rate on
  `occasion_tags`/`vibe_tags`/`dietary_flags` drops for spots with a digest; digest-less spots unchanged.
- Post-3D: a `vibe` query (*"cozy romantic spot"*) reorders toward matching `vibe_tags` **without
  excluding** non-matching spots; the `atmosphere`/noise filter is unaffected.

## Open items
- **✅ Re-digest wave complete on the synthetic catalog — verified 2026-07-18.** All 20
  digest-bearing spots — currently all `SEED_FAKE_` synthetic spots (testing runs with the
  `SRVN_INTENT_SEED_ONLY` scope); **no real spot has a digest yet** — are on
  `review_digest_schema_version = 1` (current), with the re-extracted columns populated: 20/20
  `occasion_tags`, 17/20 `vibe_tags`, 17/20 `dietary_flags` (shortfalls consistent with the
  explicitly-only prompt rule — empty when not evidenced). The 3B pipeline (re-digest →
  re-extract → facet columns) is mechanically verified end-to-end.
- **Real-spot facet coverage is still pending vendor review ingestion.** Until vendor review
  text is bought and digested for real spots, real spots have no review digest, no
  `review_digest_embedding`, and empty review-mined facets — in normal (non-seed-only) mode
  they rank on Places-derived tags + `taste_embedding` only. This is a data/procurement step,
  not code. (GCP note: the trial credit expired 2026-07-10; `SRVN_SEED_MONTHLY_CALL_CAP` is
  back at `950` in `.env`, confirmed 2026-07-18. Review digestion is OpenAI spend, unaffected
  by the Google cap.)
