# srvn User Taste Graph — Roadmap + Phase 1

> **Companion plan**: see [`request-time-ai-pipeline.md`](./request-time-ai-pipeline.md) for the request-time AI synthesis tier — free-text intent endpoint (`/spots/recommend-by-intent`), LLM rerank+explain, and the latency budget for an end-to-end "type a vibe, get cards in <500ms" UX. That plan layers on top of this Phase 1 foundation.

## Context

We're building toward an "AI-Powered Dining Concierge": a chatbot that gives each user personalized restaurant recommendations grounded in their tastes. To get there we first need a **user taste graph** — structured + derived signals that capture what each user actually likes — that we can later embed, store, and feed into LLM tool-use.

Today the codebase has only two preference fields (`User.cuisines`, `User.dietaries` as flat string arrays) and a `/spots/recommended` endpoint that is **distance-only** (zero personalization). Behavioral signals exist (saves, reviews, event votes, follows) but are not aggregated, normalized, or projected into any user representation. There is no persistent vector store; `conversation_service.py` rebuilds FAISS in memory per request.

This plan covers (a) the phased roadmap and (b) the concrete Phase 1 PR — the data foundation plus a personalized `/spots/recommended`. The chatbot is explicitly out of Phase 1.

User-confirmed constraints: light onboarding additions only, pgvector + APScheduler (no new infra), Phase 1 includes personalized recs.

---

## Roadmap

| Phase | Scope | Outcome |
|---|---|---|
| **1 (this PR)** | Schema, extended onboarding, signal aggregation worker, personalized `/spots/recommended` | Users get personalized nearby recs; foundation for everything below |
| 2 | Spot taste enrichment v2 — better cuisine taxonomy, dietary-flag inference quality, ambiance/occasion signals from reviews | Higher-quality matching; fewer cold misses |
| 3 | Persistent embedding store reused for chat — retire per-request FAISS in `conversation_service.py`; reuse `srvn_spot_taste_features.taste_embedding` for retrieval | Stable, cheap RAG substrate |
| 4 | Concierge chatbot — tool-use over taste graph + spot search; conversation memory; taste-aware system prompts | The product north star |

---

## Phase 1 — Concrete Deliverables

### Naming
All NEW tables, columns, services, files, modules, jobs use the `srvn_` prefix per the project rule. Existing `ressy_backend/` package path stays.

### 0. Prerequisite — pgvector-enabled Postgres image (lands first, separate commit)

The current `docker-compose.yaml:56` runs `postgis/postgis:16-3.4`, which does **not** ship pgvector. Without this step the Alembic migration's `CREATE EXTENSION vector` will fail on every dev machine and on any future CI runner. There is no `.github/workflows/` today; "CI" is whatever runs `pytest -m api` against the docker-compose Postgres, so dev image == CI image.

**Deliverable**: a custom Postgres image that has BOTH PostGIS (already required) AND pgvector.

Pick one (recommend option A):

- **(A) Extend the existing PostGIS image with pgvector** — new `docker/postgres/Dockerfile`:
  ```Dockerfile
  FROM postgis/postgis:16-3.4
  RUN apt-get update \
      && apt-get install -y --no-install-recommends postgresql-16-pgvector \
      && rm -rf /var/lib/apt/lists/*
  ```
  Update `docker-compose.yaml:55-61` to `build: ./docker/postgres` instead of `image: postgis/postgis:16-3.4`. Tag the built image (e.g. `srvn-postgres:dev`) so it's reusable by ad-hoc `pytest` runs.
- **(B) Switch base** to `pgvector/pgvector:pg16` and install postgis on top — symmetric but inverts which extension is "native"; more diff in the compose file.

**Files touched** (this commit, before the Alembic revision lands):
- `docker/postgres/Dockerfile` (new)
- `docker-compose.yaml` (replace `image:` with `build:` for the postgres service; keep volume + ports unchanged)
- `README.md` (one-line note: rebuild Postgres image with `docker compose build postgres` after pulling)

**Verification before the schema commit**:
```
docker compose down -v
docker compose build postgres
docker compose up -d postgres
docker compose exec postgres bash -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;" -c "\dx"'
```
Expected output includes both `postgis` and `vector` rows in `\dx`.

Only after this commit lands and devs have rebuilt the postgres container does the database migration in section 1 below get merged.

### 1. Database (new Alembic revision)

```
CREATE EXTENSION IF NOT EXISTS vector;

srvn_user_taste_profile (1:1 with users)
  user_id            INT PK FK→users.id ON DELETE CASCADE
  allergens          ARRAY(String)              SAFETY column; gates allergen filter (§5b). Distinct semantics from dietaries.
  allergen_handling  String(16)                 'warn' | 'block', default 'warn'. Block only auto-excludes on HIGH-tier signals (§5b).
  price_comfort      JSONB                      {"min":1,"max":3,"preferred":2}
  occasions          ARRAY(String)              date_night/family/business/solo/casual
  dietary_strictness String(16)                 'strict' | 'soft' | NULL  -- governs DIETARIES only, never allergens
  ambiance_prefs     ARRAY(String)
  taste_text         Text                       audit trail of what we embedded
  taste_text_hash    String(16)                 SHA-256 prefix; if unchanged on recompute, skip the OpenAI call (§7)
  taste_embedding    vector(1536)               ACTIVE-generation vector; nullable; populated by worker
  taste_embedding_next vector(1536)             NEXT-generation vector during a model migration ONLY (§7a). NULL otherwise.
  embedding_model    String(64)                 e.g. 'text-embedding-3-small@2024-01-25'. Identifies the geometry the vector lives in.
  taxonomy_version   SmallInt                   bumped when taste_taxonomies.py canonical labels/aliases change (§5a). Cheap re-embed.
  embedding_updated_at TIMESTAMPTZ
  created_at, updated_at, deleted_at            (SoftDeleteModel)
  INDEX hnsw (taste_embedding vector_cosine_ops)
  INDEX hnsw (taste_embedding_next vector_cosine_ops) WHERE taste_embedding_next IS NOT NULL  -- partial; cheap when unused
  INDEX (dietary_strictness) WHERE deleted_at IS NULL

srvn_user_taste_signals (1:1 with users; aggregated from behavior)
  user_id                  INT PK FK→users.id
  cuisine_affinity         JSONB         normalized to sum=1.0
  price_tier_distribution  JSONB
  occasion_affinity        JSONB
  type_affinity            JSONB         over Spot.types
  saves_count, reviews_count, votes_count INT
  positive_signal_count, negative_signal_count INT
  last_aggregated_at       TIMESTAMPTZ
  signal_version           INT           bumped on rebuild → triggers re-embed

srvn_spot_taste_features (1:1 with spots; derived from spots.info JSONB + reviews)
  spot_id              INT PK FK→spots.id ON DELETE CASCADE
  primary_cuisine      String(64)
  cuisines             ARRAY(String)
  price_tier           SmallInt          1..4
  dietary_flags        ARRAY(String)     AFFIRMATIVE dietary support: vegan_options/gluten_free/halal/...
                                          NULL/empty = unverified, NOT a negative signal (§5b missing-data policy).
  allergen_warnings    JSONB             Tiered allergen evidence (§5b). Shape:
                                          [{"allergen":"peanut","source":"places_info","confidence":"high"},
                                           {"allergen":"peanut","source":"review_frequency",
                                            "confidence":"medium","mention_rate":0.34,"sample_size":50}]
                                          High-tier drives block. Medium-tier flags only.
  occasion_tags        ARRAY(String)
  taste_text           Text
  taste_text_hash      String(16)               SHA-256 prefix; same skip semantics as user side
  taste_embedding      vector(1536)             ACTIVE-generation vector
  taste_embedding_next vector(1536)             NEXT-generation vector during a model migration ONLY (§7a). NULL otherwise.
  embedding_model      String(64)               same shape as user side; pair must match user side at score time (§5)
  taxonomy_version     SmallInt
  features_updated_at, embedding_updated_at TIMESTAMPTZ
  INDEX hnsw (taste_embedding vector_cosine_ops)
  INDEX hnsw (taste_embedding_next vector_cosine_ops) WHERE taste_embedding_next IS NOT NULL  -- partial
  INDEX (price_tier)
  INDEX gin (cuisines), gin (dietary_flags), gin (allergen_warnings jsonb_path_ops)
```

**Why sidecar tables, not new columns on `users` / `spots`:**
- `users` is wide and on the auth hot path; adding a `vector(1536)` bloats row width and risks TOAST churn on every login.
- `spots` is repopulated from Google Places by `spot_refresh_service`; structured taste features must be decoupled so refresh doesn't clobber them.
- HNSW indexes on a sidecar can be `REINDEX`ed without touching auth-critical reads.

**Backfill**: insert empty `srvn_user_taste_profile` + `srvn_user_taste_signals` rows for every existing user; insert empty `srvn_spot_taste_features` rows for every existing spot. All embeddings start NULL; the worker fills them.

**Rollback**: drop the three tables. Do NOT drop the `vector` extension automatically.

### 2. Application code — new files

```
ressy_backend/models/srvn_user_taste_profile.py
ressy_backend/models/srvn_user_taste_signals.py
ressy_backend/models/srvn_spot_taste_features.py
ressy_backend/services/srvn_taste_graph/
    __init__.py
    embedding_client.py            # thin OpenAI wrapper (NOT langchain), batched
    signal_aggregator.py           # saves + reviews + event votes → affinity JSONBs
    spot_features_extractor.py     # spots.info JSONB → structured columns
    taste_taxonomies.py            # canonical vocabularies + normalize_*() for cuisine, dietary_flag, occasion (see §5a)
    scoring.py                     # weighted rerank, cold-start fallback
    text_builder.py                # deterministic taste_text builders
ressy_backend/routes/srvn_taste_profile.py    # new Smorest blueprint
ressy_backend/schemas/srvn_taste_profile.py
tests/srvn_backend/services/srvn_taste_graph/...
tests/srvn_backend/api/test_srvn_taste_profile_*.py
tests/srvn_backend/api/test_srvn_recommended_*.py
```

### 3. Application code — modified files

| File | Change |
|---|---|
| `ressy_backend/routes/spot.py:387-457` (`get_recommended_spots`) | Replace `Spot.find_nearby` ranking. Same query params (lat/lon/radius/limit/offset). Add optional `?occasion=` param. Honor `SRVN_PERSONALIZED_RECS` flag for clean rollback. Reuse the existing PostGIS `ST_DWithin` SQL, `lazy_refresh_spot`, `SpotController.prepare_spots_for_response`, and `paginate_results`. |
| `ressy_backend/tasks.py` | Add `srvn_aggregate_user_signals` (every 6h), `srvn_refresh_taste_embeddings` (every 15m), `srvn_refresh_spot_features` (daily 02:00 UTC). Match the existing `with scheduler.app.app_context():` pattern from `check_event_deadlines` and `reconcile_reports`. |
| `ressy_backend/app.py:176-244` | Register the 3 new jobs inside the existing `START_SCHEDULER` gate. Register the new `srvn_taste_profile` blueprint. |
| `ressy_backend/config.py` | Add `SRVN_PERSONALIZED_RECS` (default true), `SRVN_TASTE_EMBED_MODEL` (default `text-embedding-3-small`; *target* model — see §7a for model-bump procedure), `SRVN_TASTE_EMBED_ENABLED` (default **false** in production — code lands dark; ops flips after measuring real row counts), `SRVN_TASTE_EMBED_BACKFILL_CAP` (default 200/tick during initial sweep), `SRVN_TASTE_EMBED_STEADY_CAP` (default 1000/tick once backfill is complete), `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` (default 10_000_000 tokens/UTC-day; circuit-breaker, not a target), `SRVN_TASTE_EMBED_MIGRATION_TOKEN_BUDGET` (separate ceiling used only when `taste_embedding_next IS NOT NULL` work is in progress; default 50_000_000 tokens/UTC-day; requires explicit config push to enable), `SRVN_TASTE_EMBED_CANARY_USER_IDS` (comma-separated user IDs whose `/spots/recommended` requests read from `taste_embedding_next` instead of `taste_embedding`; empty default; used during §7a model migrations to validate before swap), `SRVN_REVIEW_ALLERGEN_FLAGS` (default **false**; gates surfacing of medium-tier review-derived allergen flags — see §5b), `SRVN_REVIEW_ALLERGEN_THRESHOLD` (default 0.20; mention-rate threshold for medium tier), `SRVN_REVIEW_ALLERGEN_EXCLUSION_WINDOW` (default 50 chars; "allerg"-co-mention exclusion window). |
| `pyproject.toml` | Add `pgvector = "^0.3"`. |
| `ressy_backend/routes/user.py:179-360` (`PUT /users/update-profile`) | **Untouched**. New fields go to the new endpoint to keep this route's responsibilities bounded. |

### 4. Endpoint surface

```
GET  /users/me/taste-profile        # JWT-required; returns extended fields + legacy
                                    # cuisines/dietaries (joined from users row).
                                    # Includes: allergens, allergen_handling ('warn'|'block'),
                                    # price_comfort, occasions, dietary_strictness, ambiance_prefs.
PUT  /users/me/taste-profile        # JWT-required; partial upsert; sets
                                    # embedding_updated_at=NULL + bumps signal_version
                                    # so the next worker tick re-embeds.
GET  /spots/recommended             # Same signature plus two NEW optional query params:
                                    #   ?occasion=date_night|family|business|solo|casual
                                    #   ?relax_strictness=true   (per-request override; does NOT
                                    #                              mutate the user's profile)
                                    # Response shape EXTENDED additively (existing clients ignore
                                    # extra fields):
                                    #   items: [...spots, each with new optional `caveats` field
                                    #           e.g. {allergen_warnings: [{allergen,confidence}],
                                    #                 dietary_status: 'verified'|'unverified'}]
                                    #   meta:  {pre_filter_count, post_filter_count,
                                    #           dropped: {allergen, strict_diet},
                                    #           degraded_to: 'soft'|'wider_radius'|'none'|null,
                                    #           suggestions: [{action,reason}]}
```

`PUT /users/update-profile` continues to accept `cuisines`, `dietaries`, `onboarding_complete` exactly as today (zero behavior change).

### 5. Personalized scoring algorithm

Two-stage: **SQL retrieval → Python rerank**. Pure Python reranking on a small candidate pool keeps the weights and cold-start fallback debuggable; SQL-only would be opaque.

**Stage 1 — SQL candidate pool (≤200 spots)**
- Existing PostGIS `ST_DWithin` spatial filter (reuse from `Spot.find_nearby`)
- **Allergen hard-block** (always-on, regardless of `dietary_strictness`, regardless of `?relax_strictness`): for users with `allergen_handling='block'` AND `cardinality(allergens) > 0`, exclude any spot whose `allergen_warnings` JSONB contains a HIGH-confidence entry for any of the user's allergens. Medium-confidence (review-derived) entries do NOT trigger block — they only surface as flags.
- **Strict dietary filter** (only when `dietary_strictness='strict'` AND `?relax_strictness != true`): `:user_required_flags <@ srvn_spot_taste_features.dietary_flags`. Per the **missing-data policy** (§5b), spots with NULL/empty `dietary_flags` are NOT excluded by this filter — they pass through and are tagged `dietary_status='unverified'` in the response.
- Coarse pre-order: distance + (when user embedding present) `taste_embedding <=> :user_emb`

**Stage 2 — Python rerank** (`scoring.score_candidate(...)`)

```
s_distance     = exp(-distance_m / 2000)
s_embedding    = 1 - cosine_distance(user_emb, spot_emb)
                 ONLY APPLIED when user.embedding_model == spot.embedding_model == CURRENT_EMBEDDING_MODEL
                 AND both vectors non-NULL. Otherwise dropped from the formula and weight redistributed
                 across remaining factors (prevents mixed-space cosine garbage during a §7a migration).
s_cuisine      = jaccard(declared ∪ top_signal_cuisines, spot.cuisines)
s_price        = 1.0 if spot.price_tier in user_price_range else 1 - 0.4 * |delta|
s_occasion     = 1.0 if (spot.occasion_tags ∩ user.occasions) else 0.5
s_popularity   = log1p(saves_or_review_signal) / log1p(global_max)
s_allergen     = 0.0 if any HIGH-tier allergen_warning matches user.allergens
                 else 0.4 if any MEDIUM-tier allergen_warning matches user.allergens
                 else 1.0    # always applied, regardless of allergen_handling mode
s_diet_match   = 1.0 if dietary_status == 'verified' AND required ⊆ dietary_flags
                 else 0.7 if dietary_status == 'unverified'
                 else 0.4    # for soft-strictness users; strict users already filtered in Stage 1

score = 0.25*s_distance + 0.20*s_embedding + 0.13*s_cuisine
      + 0.08*s_price    + 0.08*s_occasion  + 0.08*s_popularity
      + 0.10*s_allergen + 0.08*s_diet_match
```

(Weights renormalized to include `s_allergen` and `s_diet_match` while keeping the same relative ordering as before.)

**Cold-start fallback** — when user has no embedding AND no declared cuisines AND no signals, drop `s_embedding` + `s_cuisine` weights and renormalize to distance + popularity. Strictly better than today.

**Soft vs. strict dietary** — soft prefs do NOT filter; they down-weight via `s_diet_match` (see Stage 2 formula). See §5b for the full strict/soft/relax/missing-data contract and the response envelope semantics.

**Performance** — candidate pool ≤200 from indexed query; expected p95 < 80ms. Add Redis cache `srvn:rec:{user_id}:{lat_bucket}:{lon_bucket}:{radius}` with 60s TTL (project already runs Redis).

**Vocabulary contract for the formulas above** — every cuisine, dietary, and occasion symbol that appears in the scoring formula (`declared`, `top_signal_cuisines`, `spot.cuisines`, `:user_required_flags`, `dietary_flags`, `user.occasions`, `spot.occasion_tags`) is the output of the corresponding `normalize_*()` function from `taste_taxonomies.py`. See §5a below.

### 5a. Taxonomy / vocabulary normalization

The scoring formula above and the worker aggregations in §6 only behave correctly if both sides of every set comparison live in the same canonical vocabulary. Free-text declared prefs (`User.cuisines`, `User.dietaries`) and Google-Places-derived spot labels (`spots.types`, `spots.info.primary_type_display_name`) do not natively share a vocabulary, so we normalize.

**File**: `ressy_backend/services/srvn_taste_graph/taste_taxonomies.py` — one module, three sibling taxonomies (cuisine, dietary_flag, occasion). One file, not three, because the three are small and share the same shape.

**Shape (per taxonomy)**:
```python
class CanonicalCuisine(str, Enum):
    ITALIAN = "italian"
    JAPANESE = "japanese"
    # … ~30 canonical labels, sourced from Google Places food-serving types
    # (italian_restaurant, japanese_restaurant, …) plus a small curated supplement
    # for gaps (e.g. "ethiopian", "filipino" if Places lumps them under generic types).

CUISINE_ALIASES: dict[str, CanonicalCuisine] = {
    "italian_restaurant": CanonicalCuisine.ITALIAN,
    "ristorante_italiano": CanonicalCuisine.ITALIAN,   # Places localized variant
    "italian": CanonicalCuisine.ITALIAN,
    # …
}

def normalize_cuisine(raw: str | None) -> CanonicalCuisine | None: ...
def normalize_cuisines(raw: Iterable[str]) -> list[CanonicalCuisine]: ...
```

Same shape for `CanonicalDietaryFlag` (vegan_options, gluten_free, halal, kosher, vegetarian_options, dairy_free, nut_free, …) and `CanonicalOccasion` (date_night, family, business, solo, casual, group).

**Canonical-set source**: derived once from the Google Places `types` enum (filtered to food-serving types) plus a small curated supplement for gaps. Pinned in code; checked into the repo, not fetched at runtime.

**Strategy: normalize on read, not on write.** Reasons:
- Existing `User.cuisines` rows already contain free text — normalize-on-write would require a backfill migration of legacy data.
- Keeps `PUT /users/update-profile` truly behavior-unchanged (storage shape unaffected).
- Cost is a dict lookup per element on a list of single-digit length; negligible vs. the rest of the scoring pipeline.
- Lets us evolve the taxonomy without rewriting historical user data.

**Call sites** (the four places that must call `normalize_*()`):
1. `scoring.score_candidate(...)` — normalize `user.cuisines`, `user.dietaries`, `user.occasions`, `spot.cuisines`, `spot.dietary_flags`, `spot.occasion_tags` before any set/Jaccard operation. Drop `None` (un-mappable) values.
2. `signal_aggregator.aggregate_user_signals(...)` — when computing `cuisine_affinity` from saves/reviews/votes, key the JSONB on canonical labels (so two saves of "italian_restaurant" and "ristorante_italiano" both bucket into `italian`). Same for occasion_affinity.
3. `spot_features_extractor.extract(...)` — when writing `srvn_spot_taste_features.cuisines` / `dietary_flags` / `occasion_tags` from `spots.info` JSONB, the values stored are ALREADY canonical (this is the one normalize-on-write surface, because the extractor is the source of truth for these new columns).
4. `text_builder.build_user_taste_text(...)` / `build_spot_taste_text(...)` — normalize before string interpolation so embeddings see the canonical label, not raw aliases.

`PUT /users/me/taste-profile` does NOT normalize on write either — it writes user-provided values verbatim into the new columns, and §1–4 above normalize when those values are read. (The new `occasions` column on `srvn_user_taste_profile` is the borderline case: since this column is brand-new and has no legacy data, we *can* normalize on write here without a backfill. Decision: still normalize-on-read for consistency with the cuisine/dietary path. Schema validation in `schemas/srvn_taste_profile.py` enforces values come from `CanonicalOccasion.__members__` so unknown values are rejected at the schema layer — this gives the strict-input behavior without coupling storage to the in-memory enum.)

**Versioning**: each taxonomy carries `TAXONOMY_VERSION: int = 1` constant. Stored on each row in the `taxonomy_version SmallInt` column (NOT concatenated into `embedding_model` — see §7a for why model and taxonomy versions are tracked separately). When the taxonomy bumps (a new canonical label is added, or aliases shift), bump `TAXONOMY_VERSION`; the worker's filter (§6.2) picks up affected rows. Taxonomy bumps stay in-place — same `taste_embedding` column, no blue/green required — because the embedding *space* is unchanged; only the input *text* might change. The hash-skip path (§6.2 step 6) catches the common case where the canonical label change doesn't actually alter rendered taste_text, so a taxonomy bump usually costs ~zero tokens.

**Locale**: Google Places returns localized `types` strings based on request language. The aliases dict carries the localized variants we expect from our request configuration (English-default, with explicit fallbacks for the top non-English Places responses we observe). When a new locale is enabled in the Places client, expand `CUISINE_ALIASES` and bump `TAXONOMY_VERSION`.

### 5b. Strict-dietary, allergen, and empty-result semantics

The plan distinguishes **safety** (allergens) from **preference** (dietaries). They use different data, different filters, and different UI affordances. Conflating them — as the original `dietary_strictness` switch did — is the bug this section fixes.

#### Allergen vs. dietary preference — distinct semantics

| | Dietary preference (vegan, halal, kosher, gluten_free) | Allergen (peanut, shellfish, tree_nut) |
|---|---|---|
| Column | `User.dietaries` (legacy) + `srvn_spot_taste_features.dietary_flags` | `srvn_user_taste_profile.allergens` + `srvn_spot_taste_features.allergen_warnings` |
| Severity model | Single user-wide knob: `dietary_strictness` ∈ {strict, soft} | Single user-wide knob: `allergen_handling` ∈ {warn, block} |
| What "soft"/"warn" does | Score down-weight; spot still shown | Show flag; spot still shown |
| What "strict"/"block" does | Hard exclude in SQL when `?relax_strictness != true` | Hard exclude — but ONLY on HIGH-confidence signals (see tiers below) |
| Default for new users | NULL (no behavior change) | `'warn'` |
| Crosses to other column? | Never — strictness governs dietaries only | Never — allergen handling governs allergens only |

#### Allergen evidence tiers

`srvn_spot_taste_features.allergen_warnings` is a JSONB array of evidence records. Each record carries `{allergen, source, confidence, ...}`:

| Confidence | Source | Driver | UI affordance | Drives `allergen_handling='block'`? | Score impact |
|---|---|---|---|---|---|
| **high** | `places_info` (extracted from `Spot.info` JSONB by `spot_features_extractor`) | Authoritative — Google Places explicitly lists the allergen | "⚠ Contains peanut" (red flag) | **Yes** | `s_allergen = 0.0` |
| **medium** | `review_frequency` (computed by `srvn_refresh_spot_features` from `Review` text) | Heuristic — the allergen substring appears in ≥`SRVN_REVIEW_ALLERGEN_THRESHOLD` of the spot's reviews, after excluding reviews where "allerg" appears within `SRVN_REVIEW_ALLERGEN_EXCLUSION_WINDOW` chars of the allergen mention | "ⓘ Peanut mentioned in reviews" (amber flag), only when `SRVN_REVIEW_ALLERGEN_FLAGS=true` | **No** | `s_allergen = 0.4` (when surfaced) |

Why the medium tier exists: Google Places `info` carries authoritative allergen data on a small minority of restaurants. Restricting to high-confidence-only would silently fail on the safety dimension we promised — Maya the peanut-allergic user would get zero flags on most spots she could plausibly visit. Showing a *distinct, tiered* signal lets the user judge confidence; suppressing it entirely is paternalistic and unsafe.

Why medium tier never blocks: the heuristic produces false positives ("amazing pad thai with peanut sauce" flags the spot even though only one dish on the menu uses peanut). Blocking on this would over-prune a `block`-mode user's results to near zero. Surface-with-flag preserves user choice; auto-block only on data we're confident in.

Why the feature flag (`SRVN_REVIEW_ALLERGEN_FLAGS`, default `false`): the threshold (default 20%) is uncalibrated until we observe real mention-rate distributions. The daily worker logs per-spot mention rates; ops reviews the distribution before flipping the flag on. Same staged-rollout pattern as `SRVN_PERSONALIZED_RECS`.

Why review text never touches `allergen_handling='block'`: substring matching can't tell "the chef accommodated my peanut allergy" from "this dish contains peanuts." Until Phase 2 NLP can distinguish intent, review-derived signal is presented for human judgment, not used to make the safety decision.

#### Missing-data policy for dietary_flags

A spot whose `srvn_spot_taste_features.dietary_flags` is NULL or empty has *unverified* dietary support — we don't know whether the spot offers vegan/halal/etc. options.

The implicit policy in a naive `:user_required_flags <@ dietary_flags` filter would EXCLUDE these spots (set inclusion fails on the empty set). For Google-Places-sourced data — where most spots lack rich dietary metadata — this would empty out the result page for any strict-vegan user.

**Plan policy**: spots with NULL/empty `dietary_flags` are NOT excluded by the strict-dietary filter. They pass through with `caveats.dietary_status='unverified'` so the UI can surface "dietary support not verified for this spot" and the user can call ahead. The Stage 2 score adds a moderate `s_diet_match=0.7` penalty for unverified spots so verified-matching spots still rank above them.

Allergens use a stricter policy because safety: a spot's `allergen_warnings` containing no entries for an allergen means "no evidence of presence," which is treated as the spot being permissible. This is asymmetric on purpose — false-negative on dietary preference is annoying; false-negative on allergen presence is anaphylaxis only when we have *evidence* of the allergen. The medium-tier review heuristic exists precisely to raise allergen evidence above the "no signal" baseline.

#### Per-request relax override

`/spots/recommended?relax_strictness=true` disables the Stage-1 strict dietary hard filter for *this request only*. Does NOT mutate `srvn_user_taste_profile.dietary_strictness`. Use case: the frontend prompts "no strict matches in your area — see soft matches instead?" and the user accepts. The next call without the flag goes back to strict.

`?relax_strictness=true` does **not** affect the allergen filter. Allergens never relax via query param — only via the user changing `allergen_handling` in their profile. (Reasoning: per-request relaxation of an allergy filter is exactly the kind of one-tap mistake that ends in the ER. Force the user to make that choice in profile-settings, where the friction matches the consequence.)

#### Graceful degradation cascade

If the post-filter result count is **zero**, the recommender automatically tries:

1. Drop the strict dietary filter (keep allergen filter, keep distance, keep allergen down-weight). If ≥1 result, return with `meta.degraded_to='soft'` and a `suggestions` entry: `{action:'relax_strictness', reason:'no_strict_matches'}`.
2. If still zero: widen radius by 50% (max 2 widenings, capped at 15km). If ≥1 result, return with `meta.degraded_to='wider_radius'`.
3. If still zero: return empty `items: []` with `meta.degraded_to='none'` and `suggestions: [{action:'expand_radius', reason:'no_nearby_matches'}, {action:'review_dietary_settings', reason:'filters_too_narrow'}]`.

The cascade does NOT relax the allergen filter at any step. A `block`-mode user who has filtered out everything in their area gets `meta.degraded_to='none'` and a suggestion to review their settings — never an auto-relaxation of safety.

#### Response envelope

`/spots/recommended` returns the existing `PagedSpotsSchema` extended with two additive fields. Existing clients ignore unknown fields, so this is backward-compatible.

```json
{
  "items": [
    {
      "...existing spot fields...": "...",
      "caveats": {
        "allergen_warnings": [
          {"allergen": "peanut", "confidence": "medium", "mention_rate": 0.34}
        ],
        "dietary_status": "unverified"
      }
    }
  ],
  "meta": {
    "pre_filter_count": 47,
    "post_filter_count": 3,
    "dropped": {"allergen": 5, "strict_diet": 12, "unverified_passed_through": 27},
    "degraded_to": null,
    "suggestions": []
  },
  "...existing pagination fields...": "..."
}
```

#### Per-request log line

Worker jobs log a structured line; the recommender does the same per request:

```
event=srvn_rec user_id=… lat=… lon=… radius=…
  pre=N post=M dropped_allergen=A dropped_strict=B unverified=C
  degraded_to=…|null relax_strictness=true|false allergen_handling=warn|block
  duration_ms=…
```

Used to tune the strict-dietary threshold (`unverified` rate per metro), the medium-tier mention-rate threshold (per-allergen distribution), and to detect cascade-degradation rates that would warrant UX changes.

### 6. Worker jobs (APScheduler, gated by `START_SCHEDULER`)

1. **`srvn_aggregate_user_signals`** (interval 6h) — for users whose saves/reviews/votes changed since `last_aggregated_at`: compute cuisine/price/occasion affinities from `UserSavedSpot`, `Review` (rating ≥4 positive, ≤2 negative), `EventParticipant.vote_event_candidate_id`. Normalize each map to sum=1.0. If material change OR new signals since last embed, set `embedding_updated_at = NULL` and bump `signal_version`.
2. **`srvn_refresh_taste_embeddings`** (interval 15m) — gated execution with cost guardrails:
   1. **Enabled check**: if `SRVN_TASTE_EMBED_ENABLED` is false, log `event=srvn_embed_tick status=disabled` and return — no DB read, no API call. Lets the migration and code land before ops authorizes spend.
   2. **Daily budget check**: read `srvn:embed:tokens:{YYYY-MM-DD}` from Redis (UTC day key). If ≥ `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET`, log `event=srvn_embed_tick status=budget_exhausted day_budget_remaining=0` and return. Key TTL = 48h (covers UTC rollover lag).
   3. **Mode selection**: count rows where `taste_embedding IS NULL`. If > 5000 across users + spots, BACKFILL mode (per-tick cap = `SRVN_TASTE_EMBED_BACKFILL_CAP`, default 200). Else STEADY (`_STEADY_CAP`, default 1000). Mode is logged on every tick.
   4. **Candidate query**: pull users + spots that match either of two filters, in order of priority:
      - **Model migration in progress** (when `taste_embedding_next` column has any populated rows or `CURRENT_EMBEDDING_MODEL` differs from rows' `embedding_model`): pull rows where `taste_embedding_next IS NULL AND embedding_model != CURRENT_EMBEDDING_MODEL`. Worker writes results to `taste_embedding_next`. Uses `SRVN_TASTE_EMBED_MIGRATION_TOKEN_BUDGET` instead of the steady budget.
      - **Steady state** (no migration): pull rows where `taste_embedding IS NULL OR taxonomy_version != CURRENT_TAXONOMY_VERSION`. Worker writes to `taste_embedding`.
      Order by `embedding_updated_at NULLS FIRST`. Limit by the active per-tick cap.
   5. **Recompute taste_text** for each candidate via `text_builder.build_*_taste_text()`. Compute `new_hash = sha256(taste_text)[:16]`.
   6. **Hash-skip path** (taxonomy-bump and signal-bump only, NEVER on model bump): if the row was queued because `taxonomy_version != CURRENT_TAXONOMY_VERSION` OR `signal_version` changed, AND `new_hash == taste_text_hash`, update `taxonomy_version` + `embedding_updated_at` only — NO OpenAI call. **Hash-skip is unconditionally bypassed when `embedding_model != CURRENT_EMBEDDING_MODEL`** because the existing vector lives in a different geometry — text-identical does not mean vector-equivalent. Bypassing here is the difference between a clean migration and silent corruption.
   7. **Embed remaining candidates**: batch ≤96/OpenAI call (the model's per-request limit). On success, sum returned `usage.total_tokens` and `INCRBY` the Redis day counter. On 5xx, exponential backoff up to 3 attempts; on 4xx (other than 429), log and skip the row (do NOT retry — token waste). On 429, halt the tick and let the next 15m tick retry.
   8. **Write-back**: in one transaction per row, set `taste_text`, `taste_text_hash`, `embedding_model = CURRENT_EMBEDDING_MODEL`, `taxonomy_version = CURRENT_TAXONOMY_VERSION`, `embedding_updated_at = now()`. Vector goes to `taste_embedding_next` during a model migration, otherwise to `taste_embedding`. Idempotent — if the same row is picked up again, hash-skip catches the steady-state case; model-migration case re-writes harmlessly.
   9. **Structured log line at end of tick**: `event=srvn_embed_tick mode={backfill|steady} rows_seen=N rows_skipped_hash=K rows_embedded=E tokens=M est_cost_usd={M*0.00000002} duration_ms=Y day_budget_remaining=Z`. One line, parseable, no Datadog dependency.
3. **`srvn_refresh_spot_features`** (cron daily 02:00 UTC) — recompute `srvn_spot_taste_features` for spots whose `last_refreshed_at > features_updated_at`. Two passes, both pure SQL/Python with no OpenAI call:
   - **Pass A — structured features** from `Spot.info` JSONB: `primary_cuisine`, `cuisines`, `price_tier`, `dietary_flags`, `occasion_tags`, plus the HIGH-tier entries of `allergen_warnings` (one record per allergen Places explicitly lists, with `source='places_info', confidence='high'`).
   - **Pass B — review-derived medium-tier allergen signals** (per §5b): for each spot with reviews, scan `Review.description` text. For each allergen in a configured allergen list (`peanut`, `tree_nut`, `shellfish`, `sesame`, `soy`, `dairy`, `egg`, `gluten`, `fish` — the FDA top-9 plus tree-nut), count reviews containing the allergen substring (case-insensitive), excluding reviews where the substring `"allerg"` appears within `SRVN_REVIEW_ALLERGEN_EXCLUSION_WINDOW` chars of the allergen mention. If the resulting `mention_rate = matches / total_reviews ≥ SRVN_REVIEW_ALLERGEN_THRESHOLD`, append a medium-tier record `{allergen, source:"review_frequency", confidence:"medium", mention_rate, sample_size: total_reviews}` to `allergen_warnings`. If `total_reviews < 5` skip the spot for that allergen (insufficient sample). Log per-spot per-allergen: `event=srvn_review_allergen_scan spot_id=… allergen=… mention_rate=… sample_size=… emitted=true|false`.

### 7. Embedding strategy

**Why OpenAI `text-embedding-3-small` and not a local model.** The Phase 1 choice is OpenAI's hosted embedding API, not a local library (`sentence-transformers`, `fastembed`, BGE). Four reasons:

1. **Cost is not a real factor at this scale.** A full one-time backfill of 10k users + 50k spots ≈ $0.10 at the ~$0.0000016 per embedding worked example below. The §6.2 daily token budget circuit breaker exists to catch bugs, not to manage spend.
2. **Image bloat is real and asymmetric.** `docker-compose.yaml` runs the scheduler off the same `ressy-backend:dev` image as the API. The lean local path (`fastembed` + `bge-small-en-v1.5`, no torch) adds ~180 MB to every API replica; the `sentence-transformers` path adds >1 GB. Slower CI, slower deploys, slower cold starts, to save cents.
3. **Quality won't move the recommendation needle on 80–120-token blurbs.** The embedding contributes 0.20 of the §5 score; most signal is in the structured features (distance, cuisine, price, occasion, allergen, diet). The MTEB gap between `text-embedding-3-small` and `bge-base-en-v1.5` does not survive that weighting on short, vocabulary-bounded text.
4. **§7a already pays for swappability.** The blue/green geometry-migration playbook handles any vector-shape change, including a future provider swap. We don't need to build provider flexibility now; the schema design already accommodates it.

The only thing that flips this decision is a compliance/contractual constraint that the current `taste_text` shape can't be sent to a third-party API — see §7b.

Thin wrapper `services/srvn_taste_graph/embedding_client.py` over `openai.OpenAI().embeddings.create(...)` (NOT langchain — keeps the worker independent of the chatbot's langchain stack, lets tests inject a fake, and provides the seam for a future provider/model swap (see §7a) as a one-class addition, not a refactor). Persist `taste_text` so we can audit and re-embed without re-deriving.

**`CURRENT_EMBEDDING_MODEL` constant** lives in `embedding_client.py` as a module-level string, e.g. `CURRENT_EMBEDDING_MODEL = "text-embedding-3-small@2024-01-25"`. Bumping this requires a code change → controlled by the deploy pipeline. The `SRVN_TASTE_EMBED_MODEL` config var sets the *target* model (used for per-environment overrides during canary testing), but the worker compares row state against `CURRENT_EMBEDDING_MODEL` for correctness — never against the env var alone, so a bad config push can't silently bypass the version-aware scoring guard in §5.

`CURRENT_TAXONOMY_VERSION` lives the same way in `taste_taxonomies.py` (per §5a).

User taste text (~80 tokens): `"Likes {top_3_cuisines}; comfortable with price tier {range}; avoids {allergens}; prefers {occasions}; dietary {strictness} {dietaries}; recently saved: {top_3_spots}; rated highly: {top_3_high_rated}."`

Spot taste text: `"{name}, {primary_cuisine} in {neighborhood}; types {types}; price tier {price_tier}; dietary {flags}; good for {occasions}; rating {rating}."`

**Cost contract** (replaces the earlier hand-wavy "$0.10 negligible" estimate):

- Pricing baseline: `text-embedding-3-small` is $0.02 per 1M tokens; an ~80-token taste_text averages 0.0000016 USD per embedding.
- **Pre-merge measurement** is part of the verification plan (§Verification step 0a): run `SELECT count(*) FROM users WHERE deleted_at IS NULL; SELECT count(*) FROM spots WHERE deleted_at IS NULL;` on a recent prod snapshot, then confirm `(users + spots) * 80 tokens` fits under `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET`. If it doesn't, raise the budget OR cap the initial backfill scope (e.g. only backfill users who saved/reviewed in the last 90 days). Don't merge until this number is recorded in the PR description.
- Steady-state: hash-skip (§6.2 step 6) means a `signal_version` bump that produces an identical taste_text costs zero tokens. Real OpenAI calls happen only when the rendered text actually changes (new save, new review, new declared pref, taxonomy bump that changes a label).
- Circuit breaker: `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` is a hard ceiling, not a target. At default 10M tokens/day = ~$0.20/day worst-case — small enough that exceeding it almost certainly means a bug, not a real workload spike.
- Cost attribution: the existing `conversation_service.py` per-request FAISS embeddings hit the same OpenAI bill but a different code path. Tag taste-graph requests via OpenAI's `metadata` parameter (`{"surface": "srvn_taste_graph"}`) in the `embedding_client.py` wrapper so spend can be attributed in OpenAI's dashboard.

### 7a. Embedding-model migration playbook

A **model bump** (e.g. `text-embedding-3-small` → `text-embedding-4-small`) changes the geometry of the embedding space — old vectors and new vectors are not comparable, even after they're written to the same column. Because `s_embedding` in §5 is gated on `embedding_model == CURRENT_EMBEDDING_MODEL`, a careless model bump silently strips embedding contribution from scores during the migration window (correct behavior — falls back to feature scoring) but does not produce mixed-space cosine garbage.

Model bumps use a **two-revision blue/green** procedure on the `taste_embedding_next` column. Distinct from taxonomy bumps (which stay in-place per §5a).

**Procedure (operator runbook):**

1. **Decide model vs. taxonomy bump.** Read §5a vs. this section. If the canonical-label set or aliases are changing but the OpenAI model is not, it's a taxonomy bump — don't run this procedure.
2. **Open Alembic revision A**: enable `taste_embedding_next vector(N)` and the partial HNSW index on it (the column already exists per §1 schema; the partial HNSW index ships with Phase 1 and is cheap when unused). If the new model has a different dimension (e.g. 3072 instead of 1536), this revision also adjusts the `_next` column's dimension. No data writes.
3. **Open a config push** that sets `SRVN_TASTE_EMBED_MIGRATION_TOKEN_BUDGET` to a sufficient ceiling for the migration. Default 50M tokens/day allows a 50k-spot full re-embed in ~12 hours, but compute the actual number from current row counts. Get explicit approval — this is a separate budget knob from the steady-state ceiling so a model bump can never accidentally happen on the steady-state budget.
4. **Open Alembic revision B (or just deploy code)**: bump `CURRENT_EMBEDDING_MODEL` constant in `embedding_client.py` to the new model id. Deploy. Worker now sees `embedding_model != CURRENT_EMBEDDING_MODEL` on every row and switches to migration mode (§6.2 step 4 first branch). It writes new vectors to `taste_embedding_next`, leaving `taste_embedding` untouched. `s_embedding` in user-facing scoring is dropped during this window (correct fallback, see §5).
5. **Canary read path**: set `SRVN_TASTE_EMBED_CANARY_USER_IDS` to a small list (e.g. 50 internal/test users). For these users, `/spots/recommended` reads from `taste_embedding_next` instead of `taste_embedding`, AND `s_embedding` is computed against the new-model spot vectors only (skipping spots that don't yet have `_next` populated). Measure on the canary cohort: NDCG vs. baseline, click-through rate if instrumented, qualitative check on a fixed seed of test queries.
6. **Wait for coverage**: monitor `SELECT count(*) FROM srvn_spot_taste_features WHERE taste_embedding_next IS NULL` and same for users. When ≥99% covered AND canary measurements look acceptable, proceed. (If canary measurements are bad, abort: drop revision A's column, revert the constant; the original `taste_embedding` is untouched.)
7. **Open Alembic revision C — atomic swap**: in a single transaction, rename `taste_embedding` to `taste_embedding_prev` (kept for one cycle as rollback hedge), rename `taste_embedding_next` to `taste_embedding`. Drop the old HNSW index, build a fresh one with `CREATE INDEX CONCURRENTLY` on the renamed column. Clear `SRVN_TASTE_EMBED_CANARY_USER_IDS`. Worker exits migration mode automatically (no rows now have `taste_embedding_next IS NOT NULL`).
8. **REINDEX** is implicit — the swap built a fresh HNSW index. Recall is at peak.
9. **Audit window**: leave `taste_embedding_prev` in place for one cycle (~30 days). If a regression is found, downgrade revision C to roll back the rename (fast — pure metadata, no recompute). After the audit window, the *next* model bump's revision A drops `taste_embedding_prev` before adding the new `_next` column.

**Cross-provider swaps follow the same procedure.** A future move to e.g. Google Gemini (`text-embedding-004`, 768-dim) is mechanically identical to an in-vendor model bump:

- Add `GeminiEmbeddingClient` (~30 lines) implementing the same `EmbeddingClient` Protocol that `OpenAIEmbeddingClient` does — same `embed_batch(texts) -> EmbedBatchResult` shape, same `model_id` + `token_count` round-tripping for the §6.2 budget counter.
- Change one line in the worker bootstrap from `OpenAIEmbeddingClient(...)` to `GeminiEmbeddingClient(...)`. The worker's batching loop, retry, hash-skip, and budget logic don't change.
- Run steps 2–9 of the procedure above. Step 2's `vector(N)` adjustment handles the dim change (Gemini 768 vs OpenAI 1536). Step 4 bumps `CURRENT_EMBEDDING_MODEL` to the new provider+model id (e.g. `"gemini:text-embedding-004@2025"`).
- Re-evaluate the §7b compliance checklist against the new provider — different DPA, different data-residency posture, different special-category handling. Don't carry the OpenAI checklist forward unverified.

This is the payoff for the `EmbeddingClient` Protocol seam: provider swap = one new concrete class + one-line bootstrap change + the standard §7a runbook above. The Protocol itself does not need to grow a `provider` enum, factory, or registry — one concrete class per provider, instantiated explicitly, is sufficient.

**What NOT to do:**
- Never bump `CURRENT_EMBEDDING_MODEL` without revision A having shipped first — the worker will try to write to `taste_embedding_next` that doesn't exist (or has wrong dimension) and crash every tick.
- Never rely on `SRVN_TASTE_EMBED_MODEL` env var alone for the migration. The constant in `embedding_client.py` is the source of truth; the env var only overrides for canary/staging.
- Never drop `taste_embedding_prev` in the same revision that performs the swap — that eliminates the rollback hedge.

### 7b. Compliance posture and what we actually send to OpenAI

Quick answer to "is sending `taste_text` to OpenAI a compliance problem if we strip user identifiers?" — mostly no, but with sharp edges around special-category data. Documenting the answer here so the question doesn't keep getting re-litigated.

**What `taste_text` actually carries** (per §4 `text_builder.py`):

- **User text** — top cuisines, price tier range, allergens (e.g. `peanut`, `gluten`), dietary preferences (e.g. `vegan`, `halal`), occasion preferences (e.g. `date_night`). All tokens drawn from controlled vocabularies (§5a). No `user_id`, no name, no email, no exact location, no free-text reviews.
- **Spot text** — restaurant name (public on Google Maps), cuisine types, dietary flags, rating. No PII.

**What the design already does to bound exposure:**

- Controlled vocabulary in `text_builder.py` means there's no path for free-text to leak — every emitted token comes from cuisine/dietary/allergen/occasion/price-tier vocabularies defined in `taste_taxonomies.py`. Enforced by `test_text_builder.py` (§8) asserting the builder's output is a subset of the controlled vocabulary.
- `user_id` is never in the OpenAI request body. The only identifier in the call is the API key + the `metadata={"surface":"srvn_taste_graph"}` tag for billing attribution (§7).
- Hash-skip (§6.2 step 6) means an unchanged profile generates zero API calls — exposure is bounded by *change rate*, not user count.

**Sharp edges that survive identifier-stripping:**

- **Allergens are health data.** Under GDPR Article 9 they're "special category data." Under HIPAA they're generally not PHI (no covered-entity relationship), but EU users put srvn in scope.
- **Religious-adjacent dietary terms** (`halal`, `kosher`) can also fall under Article 9 as data revealing religious belief.
- **Pseudonymous ≠ anonymous.** A rare combination (uncommon allergen + uncommon cuisine + niche occasion) is quasi-identifying. In practice the risk is low for taste descriptors but it is not zero.
- **Privacy Policy and ToS** are independent of GDPR — a past commitment that "we don't share preferences with third parties" is binding regardless of GDPR data classification.

**Safe-harbor checklist for staying on OpenAI in Phase 1:**

1. Sign OpenAI's Data Processing Addendum (DPA) and request **zero data retention** on the API key the worker uses. OpenAI grants this for eligible workloads.
2. Use a **separate API key** for the taste-graph worker, distinct from the `conversation_service.py` key. Easier to scope retention/DPA terms and to revoke independently. This is the operational expression of the "do not reuse" rule in §7.
3. Update the Privacy Policy to disclose third-party AI processing of preference descriptors and the legitimate-interest / consent basis.
4. Confirm allergen/dietary collection has explicit consent (Article 9 lawful-basis requirement) for EU users, and that the consent covers third-party processing.
5. Keep `user_id`, email, name, exact coordinates, and review free-text out of the embedded string. The §8 vocabulary-bounded `test_text_builder.py` enforces this in code.

If those five are in place, "we're sending pseudonymized taste descriptors to OpenAI" is a defensible posture for a consumer app in most jurisdictions. If any item can't be satisfied (no DPA possible, allergen consent isn't airtight, Privacy Policy forbids third parties), the right pivot is local embedding — and §7a's blue/green procedure handles the migration cleanly.

This checklist is also the trigger list for revisiting §7's "Why OpenAI" decision: when any of items 1–5 stops being achievable, re-open §7.

### 8. Tests — required for CI green (`poetry run pytest`)

- `tests/srvn_backend/services/srvn_taste_graph/test_signal_aggregator.py` — `make_user()` + UserSavedSpot/Review/EventParticipant rows; assert affinity JSONBs and normalization
- `test_scoring.py` — pure-function: cold start, strict dietary exclusion, full weights, missing embedding fallback
- `test_embedding_client.py` — patch OpenAI client; assert batching (≤96/call), exponential-backoff retry on 5xx (max 3), no-retry on non-429 4xx, 429 halts immediately, model id, `metadata={"surface":"srvn_taste_graph"}` on every call
- `test_embed_worker_budget.py` — covers all the §6.2 guardrails: (a) `SRVN_TASTE_EMBED_ENABLED=false` short-circuits the tick with no DB read; (b) Redis day-counter ≥ budget halts execution; (c) hash-skip path: row whose `taste_text_hash` matches recompute updates `taxonomy_version` without an OpenAI call; (d) mode selection: 6000+ NULL-embedding rows triggers BACKFILL cap (200), <5000 triggers STEADY cap (1000); (e) tokens consumed are written to `srvn:embed:tokens:{date}` after every successful batch; (f) structured log line emitted with all required fields
- `test_scoring_version_mismatch.py` — pure-function: when `user.embedding_model != spot.embedding_model`, `s_embedding` is dropped from the formula and remaining weights renormalized; final score remains finite (no NaN, no division-by-zero); ranking stays consistent across same-version pairs; mismatched pairs rank only via feature factors (distance, cuisine, price, occasion, popularity, allergen, diet_match)
- `test_worker_model_bump_skips_hash.py` — when `embedding_model != CURRENT_EMBEDDING_MODEL`, hash-skip is bypassed even if `new_hash == taste_text_hash`; worker writes to `taste_embedding_next` (not `taste_embedding`); uses migration-token-budget Redis key (separate from steady-state); worker exits migration mode once all rows have `embedding_model = CURRENT_EMBEDDING_MODEL`
- `test_recommended_canary_read.py` — user IDs in `SRVN_TASTE_EMBED_CANARY_USER_IDS` read `taste_embedding_next` for `s_embedding` computation; non-canary users read `taste_embedding`; spots without `_next` populated are scored without `s_embedding` for canary users (no mixing)
- `test_spot_features_extractor.py` — Google-Places-info fixture → expected structured columns
- `test_taste_taxonomies.py` — for each of cuisine/dietary_flag/occasion: alias→canonical lookup, unknown returns None, idempotence (`normalize(normalize(x)) == normalize(x)`), `CURRENT_TAXONOMY_VERSION` matches what the worker writes to the `taxonomy_version` column, alias coverage spot-check against the Google Places types enum
- `test_text_builder.py` — asserts user/spot `taste_text` outputs are composed only of tokens drawn from the controlled vocabularies in `taste_taxonomies.py` (cuisines, dietary_flags, allergens, occasions, price tiers) plus a small set of skeleton words (`Likes`, `comfortable with price tier`, `avoids`, etc.); no `user_id`, email, name, coordinates, or review free-text ever appears in the output. Backs the §7b safe-harbor item 5.
- `tests/srvn_backend/api/test_srvn_taste_profile_get.py` / `_put.py` — `@pytest.mark.api`, real Postgres, `make_user()` factory; partial updates; invalid `dietary_strictness` rejected; on success `embedding_updated_at` cleared
- `test_srvn_recommended_personalized.py` — two users (Italian-affinity vs. Japanese-affinity); same lat/lon; assert ordering differs; with `SRVN_PERSONALIZED_RECS=false` ordering is identical (distance-only). Include one user whose declared `User.cuisines` contains a Google-Places-style alias (`"italian_restaurant"`) and assert it still scores Italian spots highly (proves the normalize-on-read path works)
- `test_srvn_recommended_strict_dietary.py` — strict-vegan user excludes spots that affirmatively lack vegan_options; spots with NULL `dietary_flags` PASS through tagged `dietary_status='unverified'` (missing-data policy); soft user sees down-rank but no exclusion; `?relax_strictness=true` disables strict filter for one request without mutating profile
- `test_srvn_recommended_allergen_handling.py` — covers the §5b allergen contract: (a) `allergen_handling='block'` user with peanut allergy: HIGH-tier peanut spot is excluded; medium-tier peanut spot is INCLUDED with amber flag in `caveats.allergen_warnings`; (b) `allergen_handling='warn'` user with peanut allergy: both tiers included with appropriate flag and down-rank (s_allergen=0.0 vs 0.4); (c) `?relax_strictness=true` does NOT relax the allergen filter; (d) `SRVN_REVIEW_ALLERGEN_FLAGS=false` suppresses medium-tier entries from response; (e) allergen filter applies regardless of `dietary_strictness` value
- `test_srvn_recommended_cascade.py` — strict-vegan user in an area with no verified-vegan spots: response degrades to `meta.degraded_to='soft'` and includes ≥1 spot with a `suggestions` entry; if still empty, degrades to `'wider_radius'`; allergen filter never relaxes during cascade
- `test_srvn_recommended_envelope.py` — `meta.pre_filter_count`, `post_filter_count`, `dropped` breakdown match seeded data; `caveats.dietary_status` and `caveats.allergen_warnings` populated correctly per spot
- `test_srvn_review_allergen_scan.py` — pure-function tests for the review-frequency heuristic: positive case (peanut in 30% of reviews → medium-tier emitted); allerg-co-mention exclusion ("I'm allergic to peanuts" within window → not counted); below-threshold case (10% < 20% → not emitted); insufficient sample (<5 reviews → skipped); FDA top-9 coverage
- `test_srvn_recommended_cold_start.py` — fresh user with no signal returns ≥1 spot, no 500
- `test_update_profile_unchanged.py` — regression: `PUT /users/update-profile` doesn't write to taste-profile table
- `test_worker_jobs.py` — direct invocation under `app.app_context()`; idempotence; only stale rows processed
- `test_srvn_phase1_migration.py` — alembic `upgrade head` + `downgrade -1` on fresh test DB; assert `vector` extension and three tables present

---

## Verification

End-to-end smoke (after merge to a dev branch):

0. **Postgres image**: `docker compose build postgres && docker compose up -d postgres && docker compose exec postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector; \dx"` — confirm both `postgis` and `vector` extensions are present. If this fails, section 0 of the plan didn't land — stop here, do not run the migration.
0a. **Cost-budget pre-flight** (record in the PR description before requesting review): on a recent prod snapshot run `SELECT count(*) FROM users WHERE deleted_at IS NULL; SELECT count(*) FROM spots WHERE deleted_at IS NULL;`. Compute `(user_count + spot_count) * 80` tokens; assert it fits within `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` (default 10M = ~$0.20). If not, raise the budget OR scope the initial backfill (e.g. last-90-days-active users only) before merging. Confirm `SRVN_TASTE_EMBED_ENABLED=false` is the production default in the merged config.
1. **DB**: `poetry run flask db upgrade` — confirm `\dx` shows `vector`; `\d srvn_user_taste_profile` shows expected columns including the HNSW index.
2. **Tests**: `poetry run pytest tests/srvn_backend/services/srvn_taste_graph tests/srvn_backend/api -m api` — all green.
3. **Worker**: set `START_SCHEDULER=true`, run app; tail logs for `srvn_aggregate_user_signals`, `srvn_refresh_taste_embeddings`, `srvn_refresh_spot_features` ticks; confirm zero errors and `last_aggregated_at` advances.
4. **API — taste profile**: with a JWT, `GET /users/me/taste-profile` returns defaults; `PUT` with `{"allergens":["peanut"],"dietary_strictness":"strict"}` returns 200; `GET` reflects values; `embedding_updated_at` is NULL until next worker tick, then populated.
5. **API — recommended**: two seeded users with divergent saves; same `?latitude=&longitude=&radius=`; assert different orderings. Set `SRVN_PERSONALIZED_RECS=false`; reissue requests; orderings collapse to identical distance-sorted output.
5a. **API — allergen + strict-dietary**: seed a peanut-allergic vegan user with `allergen_handling='block'`, `dietary_strictness='strict'`. Seed three spots: (i) HIGH-tier peanut + verified-vegan, (ii) medium-tier peanut (review-derived) + verified-vegan, (iii) verified-vegan + no allergen signal. Confirm: (i) excluded by allergen block; (ii) included with amber `caveats.allergen_warnings` entry when `SRVN_REVIEW_ALLERGEN_FLAGS=true`, else excluded from caveats but still in items; (iii) clean. Switch user to `?relax_strictness=true` and verify the strict-dietary filter is bypassed but the allergen block still applies. Switch user to `allergen_handling='warn'` and verify (i) is now included with red `caveats.allergen_warnings` entry. Confirm `meta.dropped` and `meta.degraded_to` populate correctly when the cascade fires.
6. **Cold-start**: brand-new user (no profile, no saves); `GET /spots/recommended` returns ≥1 spot, never 500.
7. **Backward-compat**: `PUT /users/update-profile` with `{"cuisines":["italian"],"onboarding_complete":true}` still returns 200 and behaves exactly as today (run existing `test_onboarding_api.py` unchanged).

---

## Critical files to read before implementing

- `ressy_backend/models/user.py:31-100` — User shape + relationships (`saved_spots`, `liked_reviews`, `event_memberships`)
- `ressy_backend/models/spot.py:22-411` — Spot shape, `find_nearby`, `_text_search_filter`, PostGIS patterns to mirror
- `ressy_backend/routes/spot.py:387-457` — `get_recommended_spots` endpoint we're replacing
- `ressy_backend/routes/user.py:179-360` — `update-profile` JWT + `with_for_update()` locking pattern to mirror in the new endpoint
- `ressy_backend/tasks.py` — APScheduler job pattern; `with scheduler.app.app_context():` is required
- `ressy_backend/app.py:176-244` — scheduler-job registration site; `START_SCHEDULER` gate
- `ressy_backend/services/conversation_service.py` — existing FAISS use; do NOT share an `OpenAIEmbeddings` instance with the new worker (keep configs independent)
- `tests/srvn_backend/api/test_onboarding_api.py` and `tests/conftest.py` — `make_user()` factory pattern + `@pytest.mark.api` integration-test setup

## Existing utilities to reuse

- `Spot.find_nearby` / `_build_order_by_clauses` / `_text_search_filter` — for the SQL retrieval stage; copy the geography-cast pattern, don't reinvent it
- `SpotController.prepare_spots_for_response` — keep the `saved` field on response items unchanged
- `paginate_results` — pagination shape stays identical
- `lazy_refresh_spot` — keep the existing stale-refresh trigger on the recommended endpoint
- `flask_jwt_extended.get_jwt_identity` + `with_for_update()` row-lock — same pattern as `update-profile`
- `SoftDeleteModel` base class — new `srvn_*` tables inherit it

## Risks acknowledged (not blocking Phase 1)

- **Privacy disclosure**: derived taste data ("user prefers X") may need a privacy-policy update — flag for legal review before launch, not before merge.
