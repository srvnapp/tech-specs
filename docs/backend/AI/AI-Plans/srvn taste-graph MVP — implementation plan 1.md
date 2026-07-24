# srvn taste-graph MVP — implementation plan

> **Companion docs**: `docs/plans/AI-Plans/ai-execution-roadmap.md` (6-phase roadmap), `docs/plans/AI-Plans/srvn-user-taste-graph.md` (source plan §§1–8 are the detailed spec this plan executes). This plan implements the MVP slice we agreed on: Phase 0 + trimmed Phase 1, no intent endpoint, no compliance work, no streaming.

## Context

The four AI plans in `docs/plans/AI-Plans/` describe an AI-powered dining concierge built in six phases. None of it is implemented yet — verified against the codebase. The goal here is the smallest end-to-end slice that delivers user-visible value (personalized `/spots/recommended`) and lays a foundation the later phases (intent endpoint, group dining, chatbot) can add to without rework.

The MVP cuts a number of items from the source Phase 1 spec to keep scope sane:
- **Defer** the embedding-model migration playbook (`taste_embedding_next` column, partial HNSW index, canary read path)
- **Defer** the medium-tier review-allergen heuristic (`SRVN_REVIEW_ALLERGEN_FLAGS` and the Pass B review scanner)
- **Defer** the `dietary_strictness='strict'` SQL hard-filter and `?relax_strictness` query param — MVP treats all dietary prefs as score down-weights only
- **Defer** the graceful degradation cascade (drop strict → widen radius → empty + suggestions)
- **Defer** Phase 2 intent endpoint (`/spots/recommend-by-intent`), `taste_summary_text` precompute, group dining
- **Park** compliance work (OpenAI DPA, Privacy Policy, Article 9 consent) — embedding worker defaults to enabled; revisit before public launch
- **Keep** as cheap operational hygiene: separate OpenAI API key for the worker (falls back to shared key if unset)

Approach is **three small PRs after a pgvector infra commit**, per the user's review-friendly preference:

| PR | Surface | User-visible? |
|---|---|---|
| **PR 0** — pgvector Postgres image | `docker/` + compose + README | No |
| **PR 1** — Migration + models | Alembic + 3 model files + `pgvector` pyproject dep | No |
| **PR 2** — Services + workers | `services/srvn_taste_graph/` + 3 APScheduler jobs + config | No (workers run, write data) |
| **PR 3** — Endpoints | `routes/srvn_taste_profile.py` + scoring on `/spots/recommended` | Yes — personalized recs flip on |

## Key codebase discoveries that shape the plan

These came out of exploration and override some assumptions in the source plan:

1. **Google Places v1 exposes more dietary + lifestyle signal than initially audited — but not allergens.** A sample Place Details response (Añejo Restaurant, Toronto) confirms Places returns: `servesVegetarianFood`, `goodForGroups`, `outdoorSeating`, `liveMusic`, `servesCocktails`, `servesDessert`, `servesCoffee`, `reservable`, `dineIn`, plus the already-captured `serves_breakfast/lunch/dinner`. **These are NOT in the current field mask** at `googleplaces_services.py:158-191` (`nearby_field_paths`) and `:511-546` (`detail_field_paths`) — so the data is available but not being collected. MVP extends both field masks. Source-plan implications:
   - `dietary_flags` will be **sparsely populated** (only `vegetarian_options` from `servesVegetarianFood`) — not empty as previously assumed, but vegan/halal/kosher/gluten-free still aren't exposed.
   - `allergen_warnings` stays empty. Places does NOT expose allergens at any structured level. The HIGH-tier allergen hard-block remains a no-op until a richer data source lands — and that's OK because the MVP defers the strict filter anyway.
   - `occasion_tags` will carry `group` (from `goodForGroups`) — not empty as previously assumed.
   - The booleans we don't taxonomize (`outdoorSeating`, `liveMusic`, `servesCocktails`, etc.) feed into `taste_text` as a `Features:` line so the embedding picks them up.
2. **`Spot.types` is a separate `ARRAY` column** on the Spot model, not a key inside `info`. The cuisine taxonomy normalizes from there.
3. **Price is `Spot.info["price_level"]` as a string enum** (`"EXPENSIVE"`, `"MODERATE"`, etc.), not a 1–4 integer. Extractor maps enum → 1–4 int.
4. **`Spot.info["editorial_summary"]` is Google-authored prose** describing the restaurant. Carrying it raw into `taste_text` injects real semantic signal into the embedding without taxonomy work — it's not user text, so no PII concern.
5. **Review text column is `description String(255)`**, not `body`. Use `Review.visible_query(viewer_id=None)` to filter soft-deleted + hidden reviews when aggregating signals.
6. **`EventParticipant.vote_event_candidate_id`** is FK → `event_spot_candidates.id`, not directly to spots. Signal aggregator must join through `event_spot_candidates` to reach the voted spot.
7. **`openai^1.58.1`, `langchain^0.3.20`, `langchain-openai^0.3.8`, `faiss-cpu^1.10.0` are already in `pyproject.toml`** (used by `conversation_service.py`). Only `pgvector` needs adding.
8. **No dish-level model exists.** The source schema doc's `dishes` table is purely aspirational. MVP ignores it.

These shape the MVP's effective scoring formula: `dietary_flags` carries `vegetarian_options` for spots that serve vegetarian food, `occasion_tags` carries `group` for group-friendly spots, and `allergen_warnings` stays empty. So `s_diet_match` and `s_occasion` can contribute non-zero signal in MVP (not the no-op originally assumed), but most of the personalization lift still comes from `s_embedding` (compares user taste vector to spot taste vector — which includes `editorial_summary` + features text) and `s_cuisine` (Jaccard over normalized Google types). The embedding worker must be enabled for personalization to feel real — without it, ranking is reduced to distance + cuisine + price + popularity + a thin diet/occasion contribution.

## PR 0 — pgvector-enabled Postgres image

Standalone, ships first. Blocks PR 1's migration.

**Files**:
- `docker/postgres/Dockerfile` (new) — extend the existing base:
  ```Dockerfile
  FROM postgis/postgis:16-3.4
  RUN apt-get update \
      && apt-get install -y --no-install-recommends postgresql-16-pgvector \
      && rm -rf /var/lib/apt/lists/*
  ```
- `docker-compose.yaml` — flip the `postgres` service from `image: postgis/postgis:16-3.4` to `build: ./docker/postgres`. Keep volume, ports, env unchanged.
- `README.md` — one-line note: `docker compose build postgres` after pulling.

**Verification**:
```
docker compose down -v && docker compose build postgres && docker compose up -d postgres
docker compose exec postgres bash -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;" -c "\dx"'
```
Expect both `postgis` and `vector` rows in `\dx`. If `vector` is missing, do not proceed to PR 1.

## PR 1 — Migration + models

Adds the pgvector Python dep + the Alembic revision + the three SQLAlchemy model files. Code compiles and tests pass; no behavior change.

### 1.1 `pyproject.toml`

Add under deps (use caret pinning per the project's style — see `geoalchemy2 = "^0.18.1"` for the pattern):
```toml
pgvector = "^0.3"
```

### 1.2 Alembic revision

Follow the project's revision style — see `migrations/versions/e5a8c9b2d1f7_add_sessions_invalidated_at_to_users.py` as template (docstring with purpose, `revision`/`down_revision` UUIDs, `branch_labels = None`, `depends_on = None`, `upgrade()`/`downgrade()` defs, `op.batch_alter_table()` where appropriate).

New file: `migrations/versions/<rev>_create_srvn_taste_tables.py`.

`upgrade()` body, in order:

> **Schema-design update (epic 117) — applies doc-wide:** the six **declared**
> preference columns (`allergens`, `allergen_handling`, `price_comfort_tiers`,
> `occasions`, `dietary_strictness`, `ambiance_prefs`) were first created on
> `srvn_user_taste_profile` by sc-119, then **relocated to the `users` table**
> in a follow-up migration (`a3d9f4b1c2e7_move_taste_declared_prefs_to_users`).
> Declared, user-authored prefs now live on `users` alongside
> `cuisines`/`dietaries`; the sidecar is **purely derived** (taste_text / hash /
> embedding / model / taxonomy_version / embedding_updated_at).
>
> **Read every `profile.<field>` / `srvn_user_taste_profile.<field>` reference to
> one of those six (in §2.1 text_builder + scoring, §3.1 GET, §3.3 PUT, §2.5
> tests) as `user.<field>` instead.** The authoritative, corrected specs are the
> Shortcut tickets sc-125 / sc-126 / sc-127; this doc's scattered prose was not
> rewritten line-by-line. NULL-enum semantics, the non-empty `price_comfort_tiers`
> rule, and the re-embed trigger (`srvn_user_taste_profile.embedding_updated_at`,
> which stays on the sidecar) are all unchanged — only the table moved.

1. `op.execute("CREATE EXTENSION IF NOT EXISTS vector")` — idempotent, runs harmlessly if extension already present.
2. `op.create_table("srvn_user_taste_profile", ...)` with columns:
   - `user_id INT PK FK→users.id ON DELETE CASCADE`
   - *(declared prefs `allergens`, `allergen_handling`, `price_comfort_tiers`, `occasions`, `dietary_strictness`, `ambiance_prefs` — **now on the `users` table**, see the schema-design note above. NULL-enum semantics for `allergen_handling`/`dietary_strictness` and the non-empty `price_comfort_tiers` rule are unchanged, just on `users`.)*
   - `taste_text Text` nullable
   - `taste_text_hash String(16)` nullable  (SHA-256 prefix; hash-skip key)
   - `taste_embedding Vector(1536)` nullable
   - `embedding_model String(64)` nullable
   - `taxonomy_version SmallInt` default `1`
   - `embedding_updated_at TIMESTAMPTZ` nullable
   - SoftDeleteModel: `created_at`, `updated_at`, `deleted_at`
3. `op.create_table("srvn_user_taste_signals", ...)`:
   - `user_id INT PK FK→users.id ON DELETE CASCADE`
   - `cuisine_affinity JSONB` default `{}`
   - `price_tier_distribution JSONB` default `{}`
   - `occasion_affinity JSONB` default `{}`
   - `type_affinity JSONB` default `{}`
   - `saves_count INT` default `0`, `reviews_count INT` default `0`, `votes_count INT` default `0`
   - `positive_signal_count INT` default `0`, `negative_signal_count INT` default `0`
   - `last_aggregated_at TIMESTAMPTZ` nullable
   - `signal_version INT` default `0`
   - SoftDeleteModel columns
4. `op.create_table("srvn_spot_taste_features", ...)`:
   - `spot_id INT PK FK→spots.id ON DELETE CASCADE`
   - `primary_cuisine String(64)` nullable
   - `cuisines ARRAY(String)` default `[]`
   - `price_tier SmallInt` nullable  (1..4)
   - `dietary_flags ARRAY(String)` default `[]`  (MVP leaves empty — no upstream data)
   - `allergen_warnings JSONB` default `[]`  (MVP leaves empty)
   - `occasion_tags ARRAY(String)` default `[]`  (MVP leaves empty)
   - `taste_text Text` nullable
   - `taste_text_hash String(16)` nullable
   - `taste_embedding Vector(1536)` nullable
   - `embedding_model String(64)` nullable
   - `taxonomy_version SmallInt` default `1`
   - `features_updated_at TIMESTAMPTZ` nullable
   - `embedding_updated_at TIMESTAMPTZ` nullable
   - SoftDeleteModel columns
5. Indexes (use `op.execute()` for HNSW since Alembic doesn't have first-class support):
   - HNSW on `srvn_user_taste_profile.taste_embedding` (`vector_cosine_ops`)
   - HNSW on `srvn_spot_taste_features.taste_embedding` (`vector_cosine_ops`)
   - GIN on `srvn_spot_taste_features.cuisines`
   - GIN on `srvn_spot_taste_features.dietary_flags`
   - GIN on `srvn_spot_taste_features.allergen_warnings` (`jsonb_path_ops`)
   - btree on `srvn_spot_taste_features.price_tier`
6. **Backfill** (same revision, after table creation):
   - `INSERT INTO srvn_user_taste_profile (user_id, taxonomy_version) SELECT id, 1 FROM users WHERE deleted_at IS NULL`
   - `INSERT INTO srvn_user_taste_signals (user_id) SELECT id FROM users WHERE deleted_at IS NULL`
   - `INSERT INTO srvn_spot_taste_features (spot_id, taxonomy_version) SELECT id, 1 FROM spots WHERE deleted_at IS NULL` (use the existing `deleted_at` column convention)

`downgrade()` drops the three tables. **Does not drop the `vector` extension** — other tables may reference it later.

### 1.3 SQLAlchemy models

Three new files under `ressy_backend/models/`:

- `srvn_user_taste_profile.py` — `SrvnUserTasteProfile(SoftDeleteModel)`. Uses `pgvector.sqlalchemy.Vector(1536)` for `taste_embedding`. Relationship `user = relationship("User", back_populates="taste_profile")`. Tablename `srvn_user_taste_profile`.
- `srvn_user_taste_signals.py` — `SrvnUserTasteSignals(SoftDeleteModel)`. Mirror relationship.
- `srvn_spot_taste_features.py` — `SrvnSpotTasteFeatures(SoftDeleteModel)`. Relationship to Spot. Tablename `srvn_spot_taste_features`.

Each inherits `SoftDeleteModel` from `ressy_backend/database.py:84-119`. Mirror the column-definition style from `ressy_backend/models/user.py`.

Add back-populating relationships:
- `ressy_backend/models/user.py` — add `taste_profile`, `taste_signals` relationships to `User` class
- `ressy_backend/models/spot.py` — add `taste_features` relationship to `Spot` class

Update `ressy_backend/models/__init__.py` to import the three new modules (mirror existing pattern that re-exports model symbols).

**`after_insert` SQLAlchemy listeners** to maintain the invariant "every User has both sidecar rows" and "every Spot has its taste-features row" — covers ALL creation paths (signup, OTP auto-create, OAuth, test factories, future paths):

```python
# In ressy_backend/models/srvn_user_taste_profile.py
from sqlalchemy import event
from ressy_backend.models.user import User

@event.listens_for(User, "after_insert")
def _create_user_taste_sidecars(mapper, connection, user):
    connection.execute(
        SrvnUserTasteProfile.__table__.insert().values(
            user_id=user.id, taxonomy_version=CURRENT_TAXONOMY_VERSION,
        )
    )
    connection.execute(
        SrvnUserTasteSignals.__table__.insert().values(user_id=user.id)
    )

# In ressy_backend/models/srvn_spot_taste_features.py
from ressy_backend.models.spot import Spot

@event.listens_for(Spot, "after_insert")
def _create_spot_taste_features(mapper, connection, spot):
    connection.execute(
        SrvnSpotTasteFeatures.__table__.insert().values(
            spot_id=spot.id, taxonomy_version=CURRENT_TAXONOMY_VERSION,
        )
    )
```

Listeners run in the same transaction as the User/Spot INSERT — atomic. If the parent row rolls back, the sidecar rows do too. Symmetric handling on both sides means PR 2 services and PR 3 endpoints can assume sidecar rows exist (no `if profile is None:` branches).

### 1.4 Test

`tests/srvn_backend/test_srvn_taste_schema_migration.py`:
- `@pytest.mark.api`
- Skip on missing `RESSY_TESTING`/`TEST_DATABASE_URL` (mirror `test_onboarding_api.py:26-65` setup)
- `alembic upgrade head` then `alembic downgrade -1` on a fresh test DB
- Assert `vector` extension present after upgrade, three new tables present, HNSW indexes present
- Assert downgrade cleanly drops the three tables

`tests/srvn_backend/test_srvn_after_insert_listeners.py`:
- `@pytest.mark.api`
- **User listener**: insert a User via `make_user()` → assert exactly one `srvn_user_taste_profile` AND one `srvn_user_taste_signals` row exist for that user_id; both have default values.
- **Spot listener**: insert a Spot via direct `Spot(...).save()` → assert exactly one `srvn_spot_taste_features` row exists for that spot_id.
- **Atomicity**: insert a User inside a transaction, raise to rollback → assert no orphan sidecar rows remain.
- **Integration via real auth path**: `POST /verify-otp` with a new phone number → confirms listener fires through middleware, not just via the test factory.

### 1.5 Verification (PR 1)

- `poetry run flask db upgrade` — succeeds against the PR-0-built Postgres image
- `psql ... -c "\d srvn_user_taste_profile"` — shows expected columns including HNSW index
- `poetry run pytest tests/srvn_backend/test_srvn_taste_schema_migration.py -m api` — green
- Existing test suite stays green (`poetry run pytest`)

## PR 2 — Services + workers

Adds the `srvn_taste_graph` services package, the three APScheduler jobs, and the config knobs. Workers run in dev once `START_SCHEDULER=true`; they populate the tables PR 1 created. Still no user-visible change.

### 2.1 New package: `ressy_backend/services/srvn_taste_graph/`

Six files:

- `__init__.py` — re-exports public service entry points (`aggregate_user_signals`, `refresh_taste_embeddings_tick`, `refresh_spot_features`, the `EmbeddingClient` Protocol).

- `embedding_client.py` — module-level constants:
  ```
  CURRENT_EMBEDDING_MODEL = "text-embedding-3-small@2024-01-25"
  OPENAI_BATCH_MAX = 96
  ```
  Defines `EmbeddingClient` Protocol with `embed_batch(texts: list[str]) -> EmbedBatchResult` (where `EmbedBatchResult` carries vectors + `usage.total_tokens` + `model_id`). Concrete `OpenAIEmbeddingClient` reads `OPENAI_TASTE_GRAPH_API_KEY` from config, falls back to `OPENAI_API_KEY` if unset. Single `openai.OpenAI()` instance at module load (mirror `conversation_service.py:18` style, but with the dedicated key). Tags every call with `metadata={"surface": "srvn_taste_graph"}` for billing attribution. Exponential backoff on 5xx (max 3 tries); on 4xx other than 429, log + skip the batch; on 429, raise so the worker can halt the tick.

- `taste_taxonomies.py` — module-level constant:
  ```
  CURRENT_TAXONOMY_VERSION = 1
  ```
  Three sibling Enums + alias dicts:
  - `CanonicalCuisine` (~30 labels sourced from Google Places food-serving types: `italian`, `japanese`, `chinese`, `mexican`, `indian`, `thai`, `french`, `american`, `mediterranean`, `vietnamese`, `korean`, `greek`, `spanish`, `middle_eastern`, `caribbean`, `african`, `nigerian`, `ethiopian`, `filipino`, `peruvian`, `south_american`, `seafood`, `steakhouse`, `pizza`, `burger`, `sushi`, `bbq`, `vegan`, `vegetarian`, `cafe`, `bakery`, `bar`) plus the `CUISINE_ALIASES` dict mapping Google types (`italian_restaurant`, etc.) → canonical. `nigerian` and `south_american` were added beyond the initial enumeration during sc-122 — `south_american` is the umbrella for Brazilian and other South-American cuisines that don't have their own dedicated canonical (replaces an earlier draft that wrongly mapped `brazilian_restaurant` → `peruvian`).
  - `CanonicalDietaryFlag` (`vegan_options`, `vegetarian_options`, `gluten_free`, `halal`, `kosher`, `dairy_free`, `nut_free`, `pescatarian`) + aliases
  - `CanonicalOccasion` (`date_night`, `family`, `business`, `solo`, `casual`, `group`, `celebration`, `brunch`, `late_night`)
  - Plus `normalize_cuisine(raw: str | None) -> CanonicalCuisine | None`, `normalize_cuisines(raw: Iterable[str]) -> list[CanonicalCuisine]`, same shape for dietary + occasion.

- `signal_aggregator.py` — `aggregate_user_signals(user_id: int, session) -> SrvnUserTasteSignals`:
  - Pulls user's `UserSavedSpot` edges (via `User.saved_spot_edges` or direct query on `user_saved_spots`)
  - Pulls user's `Review` rows via `Review.visible_query(viewer_id=user_id)` filtered by `user_id` AND `Review.rating IS NOT NULL`. Rating ≥4 = positive signal, ≤2 = negative. NULL ratings (model column is nullable) are explicitly skipped — they carry no sentiment, and `NULL >= 4` would silently evaluate to NULL anyway, so making the filter explicit avoids confusion in the SQL.
  - Pulls user's `EventParticipant` rows where `vote_event_candidate_id IS NOT NULL`, joins through `event_spot_candidates` to get the voted spot
  - For each touched spot, looks up its `srvn_spot_taste_features.cuisines` and `price_tier`
  - Builds `cuisine_affinity` (normalized to sum=1.0 over canonical cuisines), `price_tier_distribution`, `occasion_affinity` (from saves' contextual occasion if available; cold for MVP), `type_affinity`
  - Compares against previous version; if material change OR new signals since last embed, set `embedding_updated_at = NULL` and bump `signal_version`
  - Updates counters + `last_aggregated_at`

- **PRE-STEP — extend Places field mask in `ressy_backend/services/googleplaces_services.py`** so the new fields actually arrive in `Spot.info`. Add to both `nearby_field_paths` (lines ~158-191, with `places.` prefix) AND `detail_field_paths` (lines ~511-546, no prefix):
  - `servesVegetarianFood` (dietary)
  - `goodForGroups` (occasion)
  - `outdoorSeating`, `liveMusic`, `servesCocktails`, `servesDessert`, `servesCoffee`, `reservable`, `dineIn` (vibe / format — feed into `taste_text`)

  Also extend `serialize_place()` (`googleplaces_services.py:439-455`) to lift these into `cleaned_output["info"]` as snake_case keys: `serves_vegetarian_food`, `good_for_groups`, `outdoor_seating`, `live_music`, `serves_cocktails`, `serves_dessert`, `serves_coffee`, `reservable`, `dine_in`. Existing keys (`editorial_summary`, `price_level`, `serves_breakfast/lunch/dinner`, etc.) unchanged.

  **Also lift reviews into `info["reviews"]`** — reviews are already in `detail_field_paths` (line ~537: `reviews.name`, `reviews.text`, `reviews.rating`, `reviews.publishTime`), just discarded today. Pre-store them now (scrubbed) so Phase 4 explainer LLM and Phase 5 chatbot can read from `Spot.info["reviews"]` without a future schema-touching PR or 30-day backfill wait. **NOT consumed by spot taste_text or embeddings in MVP** — purely persisted for later phases.

  Shape per review (stripped, PII-free):
  ```python
  {
      "id": review.name,                          # "places/.../reviews/..." — unique
      "rating": review.rating,                    # 1-5
      "text": review.text.text,
      "language_code": review.text.language_code, # for future multilingual handling
      "publish_time": review.publish_time,        # ISO 8601 — canonical timestamp
  }
  ```

  **Explicitly NOT stored**: `authorAttribution.displayName`, `authorAttribution.uri`, `authorAttribution.photoUri`, `flagContentUri`, `googleMapsUri`, `originalText`, `relativePublishTimeDescription` (locale-dependent string derivable from `publish_time`). Author attribution is the PII surface; stripping it at the boundary keeps our DB free of reviewer identifiers.

  **Not added**: `goodForChildren` (intentionally out of scope per product call), `menuForChildren`, payment/parking/accessibility options, `addressDescriptor.areas` (would need a new neighborhood column on `Spot` — defer).

- `spot_features_extractor.py` — `extract_features(spot_id: int, session) -> SrvnSpotTasteFeatures`:
  - Pulls Spot row + existing `SrvnSpotTasteFeatures` row
  - **Defensive `info = spot.info or {}`** at the top — `Spot.info` is nullable on the model (newly-created spots before first Places refresh). Using `info.get(...)` directly on NULL would crash; the `or {}` makes every downstream `info.get(...)` safe.
  - Reads `Spot.types` (using `spot.types or []` defensively — also nullable) → `normalize_cuisines(...)` → `cuisines` + `primary_cuisine` (first non-None). If `spot.types` is empty/NULL → `cuisines=[]`, `primary_cuisine=NULL`.
  - Reads `info.get("price_level")` (string enum) → map to 1..4 int → `price_tier`. Mapping: `INEXPENSIVE`=1, `MODERATE`=2, `EXPENSIVE`=3, `VERY_EXPENSIVE`=4. Missing → `None`.
  - **`dietary_flags`** — if `info["serves_vegetarian_food"] is True`, append `vegetarian_options`. Otherwise empty. (Vegan/halal/kosher/gluten-free not exposed by Places; column shape is ready for Phase 3 enrichment.)
  - **`allergen_warnings`** stays empty in MVP — Places exposes no allergen data at all. Pass B review-frequency scanner is deferred to Phase 3.
  - **`occasion_tags`** — if `info["good_for_groups"] is True`, append `group`. Otherwise empty. Other occasion tags (`date_night`, `family`, `business`, etc.) come from Phase 3 review-text mining.
  - **Vibe booleans** (`outdoor_seating`, `live_music`, `serves_cocktails`, `serves_dessert`, `serves_coffee`, `reservable`, `dine_in`, `serves_breakfast/lunch/dinner`) — NOT stored in their own columns. The extractor passes them through to `text_builder.build_spot_taste_text(...)` which renders them as a `Features:` line so the embedding picks them up. Keeps the schema small; the embedding does the work.
  - Rebuilds `taste_text` via `text_builder.build_spot_taste_text(...)` and recomputes `taste_text_hash`. If hash unchanged, only update `taxonomy_version` + `features_updated_at` (skip the rest).
  - Sets `embedding_updated_at = NULL` if `taste_text_hash` actually changed (triggers re-embed)

- `text_builder.py` — two functions:
  ```
  build_user_taste_text(profile: SrvnUserTasteProfile, signals: SrvnUserTasteSignals, user: User) -> str
  build_spot_taste_text(spot: Spot, features: SrvnSpotTasteFeatures) -> str
  ```
  User taste text (~80–120 tokens), built conditionally so empty fields don't produce empty stubs:
  ```
  Likes {top_3_cuisines}. Comfortable with price tiers {comma_joined_tiers}.
  Avoids {top_3_allergens}. Dietary: {top_3_dietaries}. Prefers {top_3_occasions}.
  Ambiance: {top_3_ambiance}.
  ```
  Where (all source lookups use defensive `or []` / `or {}` so NULL columns don't crash):
  - `top_3_cuisines` comes from `(signals.cuisine_affinity or {})` sorted desc ∪ `(user.cuisines or [])` (legacy), normalized. If both empty AND no other declared prefs → render the cold-start text instead.
  - `comma_joined_tiers` is `profile.price_comfort_tiers` joined with `", "` (e.g. `"2, 3"`); line dropped if NULL/empty.
  - `top_3_allergens` from `profile.allergens`, normalized.
  - `top_3_ambiance` from `profile.ambiance_prefs`, lowercased + de-duped. §3.3.5 lists `ambiance_prefs` as "embedding-only signal; helps the vector, doesn't enter scoring directly" — this is the wire-up. Line dropped when the array is empty.
  - **`allergen_handling`**: render *"Allergen handling: warn"* / *"Allergen handling: block"* ONLY when `profile.allergen_handling IS NOT NULL`. Omit the line entirely if NULL — NULL means "user hasn't chosen" and we shouldn't fabricate a preference into the embedding.
  - **`dietary_strictness`**: same NULL-omit rule. Render *"Dietary strictness: soft"* / *"strict"* only when explicitly set.
  - Cold-start user → text says `"No declared preferences"`.

  Spot taste text — built as a list of lines, joined with spaces, **each line included only when its source has data** (no empty stubs like `Description: .`):
  ```python
  # Defensive: spot.info nullable on newly-created spots; spot.types nullable too.
  info = spot.info or {}
  types_normalized = [t for t in normalize_cuisines(spot.types or []) if t is not None]
  comma_joined_normalized_types = ", ".join(types_normalized)

  # Header line: skip primary_cuisine_label suffix if normalization didn't yield one.
  if primary_cuisine_label:
      parts = [f"{spot.name}, {primary_cuisine_label}."]
  else:
      parts = [f"{spot.name}."]
  # Types line: only render if at least one canonical type was extracted.
  if comma_joined_normalized_types:
      parts.append(f"Types: {comma_joined_normalized_types}.")
  # Price + rating line — each phrase independent; line omitted if both NULL.
  # Avoids "Rating: None/5 (None ratings)" noise for spots Places hasn't rated yet.
  price_rating_phrases = []
  if features.price_tier is not None:
      price_rating_phrases.append(f"Price tier: {features.price_tier}.")
  if spot.rating is not None:
      count = spot.info.get("user_rating_count")
      if count:
          price_rating_phrases.append(f"Rating: {spot.rating}/5 ({count} ratings).")
      else:
          price_rating_phrases.append(f"Rating: {spot.rating}/5.")
  if price_rating_phrases:
      parts.append(" ".join(price_rating_phrases))
  if features.dietary_flags:
      parts.append(f"Dietary: {comma_joined_dietary_flags}.")
  if features.occasion_tags:
      parts.append(f"Occasions: {comma_joined_occasion_tags}.")
  vibe_phrases = [
      label for cond, label in [
          (info.get("outdoor_seating"),    "outdoor seating"),
          (info.get("live_music"),         "live music"),
          (info.get("serves_cocktails"),   "serves cocktails"),
          (info.get("serves_dessert"),     "serves dessert"),
          (info.get("serves_coffee"),      "serves coffee"),
          (info.get("reservable"),         "reservable"),
          (info.get("dine_in"),            "dine-in"),
          (info.get("serves_breakfast"),   "serves breakfast"),
          (info.get("serves_lunch"),       "serves lunch"),
          (info.get("serves_dinner"),      "serves dinner"),
      ] if cond is True
  ]
  if vibe_phrases:
      parts.append(f"Features: {', '.join(vibe_phrases)}.")
  if info.get("editorial_summary"):
      parts.append(f"Description: {info['editorial_summary']}")
  return " ".join(parts)
  ```
  Features and Description are **both included when both are present** — editorial prose and structured vibe flags carry complementary signal; redundancy reinforces vector space, doesn't conflict. The conditional logic only suppresses lines whose source is empty (avoids "Description: ." stubs). All user-side tokens drawn from controlled vocabularies; `editorial_summary` is Google-authored prose (no PII). `test_text_builder.py` asserts no `user_id`, email, name, or coordinates ever appear, and asserts the no-empty-stub guarantee.

- `scoring.py` — pure function:
  ```
  score_candidate(
      profile: SrvnUserTasteProfile,
      features: SrvnSpotTasteFeatures,
      signals: SrvnUserTasteSignals,
      user: User,
      distance_m: float,
      popularity_signal: float,  # from saves count or review count
      global_max_popularity: float,
  ) -> float
  ```
  **Read-time defaults for nullable enums** — at the top of `score_candidate`:
  ```python
  effective_allergen_handling  = profile.allergen_handling  or "warn"   # NULL → safe default
  effective_dietary_strictness = profile.dietary_strictness or "soft"   # NULL → safe default
  ```
  These substitutions apply ONLY in scoring (and any future filter logic) — never written back to the DB. The DB column stays NULL until the user explicitly chooses. (In MVP both enums are dormant per §"MVP active behavior" — the substitution is wired for Phase 3.)

  MVP weights (simplified from source plan §5 — `s_allergen` and `s_diet_match` drop out because MVP data is empty; `s_occasion` drops because spot occasion_tags are empty):
  ```
  s_distance     = exp(-distance_m / 2000)
  s_embedding    = 1 - cosine_distance(profile.taste_embedding, features.taste_embedding)
                   ONLY when profile.embedding_model == features.embedding_model == CURRENT_EMBEDDING_MODEL
                   AND both non-NULL; else dropped, weight redistributed
  s_cuisine      = jaccard(
                       normalize_cuisines(signals.cuisine_affinity.keys ∪ user.cuisines),
                       features.cuisines
                   )
  s_price        = 1.0 if features.price_tier in profile.price_comfort_tiers
                   else 1 - 0.4 * min(|features.price_tier - t| for t in profile.price_comfort_tiers)
                   else 1.0 if profile.price_comfort_tiers is NULL/empty (no preference)
                   else 1.0 if features.price_tier is NULL (no spot data)
  s_popularity   = 0.0 if global_max_popularity <= 0
                   else log1p(popularity_signal) / log1p(global_max_popularity)
                   # Guard against empty-DB / cold test cases where the global max
                   # is 0 → log1p(0)/log1p(0) = 0/0 = NaN would corrupt every score.
  
  score = 0.30*s_distance + 0.25*s_embedding + 0.20*s_cuisine
        + 0.10*s_price    + 0.15*s_popularity
  ```
  Cold-start fallback (no embedding AND no declared cuisines AND no signals):
  drop `s_embedding` + `s_cuisine`, renormalize → `0.55*s_distance + 0.18*s_price + 0.27*s_popularity`.
  
  Version-mismatch guard: `s_embedding` is dropped (weight redistributed proportionally over remaining terms) when models don't match. Function must return a finite float — no NaN, no div-by-zero — for any combination of NULL inputs.

### 2.2 APScheduler jobs in `ressy_backend/tasks.py`

Mirror the pattern at `tasks.py:42-107` (`check_event_deadlines`). Each new function wraps body in `with scheduler.app.app_context():`:

- `srvn_aggregate_user_signals()` — interval 6h. Query users where `srvn_user_taste_signals.last_aggregated_at` is older than 6h OR is NULL OR where any of `UserSavedSpot.created_at`, `Review.created_at`, or `EventParticipant.updated_at` is newer than `last_aggregated_at`. For each, call `aggregate_user_signals(user_id, session)`. Commit per-user (don't batch — keeps recovery simple). Structured log line at tick end.

- `srvn_refresh_taste_embeddings()` — interval 15m. Body:
  1. If `not config.SRVN_TASTE_EMBED_ENABLED`: log `event=srvn_embed_tick status=disabled` and return.
  2. Read Redis day-counter `srvn:embed:tokens:{UTC-YYYY-MM-DD}`. If `>= SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET`, log `status=budget_exhausted` and return. TTL 48h.
  3. Count rows where `taste_embedding IS NULL` across both `srvn_user_taste_profile` and `srvn_spot_taste_features`. If `>5000` → BACKFILL mode (cap = `SRVN_TASTE_EMBED_BACKFILL_CAP`), else STEADY (cap = `SRVN_TASTE_EMBED_STEADY_CAP`).
  4. Candidate query (MVP — no `_next` column, no migration mode): pull rows where embedding is stale AND the row has something worth embedding. For user-side rows:
     ```sql
     SELECT * FROM srvn_user_taste_profile p
     WHERE (p.taste_embedding IS NULL
            OR p.taxonomy_version != $CURRENT_TAXONOMY_VERSION
            OR p.embedding_model != $CURRENT_EMBEDDING_MODEL)
       AND (
         -- Cold-start filter: at least one declared pref OR signal exists.
         -- coalesce() handles nullable ARRAY columns where cardinality(NULL) = NULL.
         EXISTS (SELECT 1 FROM users u WHERE u.id = p.user_id
                  AND (coalesce(cardinality(u.cuisines), 0) > 0
                       OR coalesce(cardinality(u.dietaries), 0) > 0))
         OR coalesce(cardinality(p.allergens), 0) > 0
         OR coalesce(cardinality(p.occasions), 0) > 0
         OR coalesce(cardinality(p.price_comfort_tiers), 0) > 0
         OR coalesce(cardinality(p.ambiance_prefs), 0) > 0
         OR EXISTS (SELECT 1 FROM srvn_user_taste_signals s
                     WHERE s.user_id = p.user_id
                       AND coalesce(s.saves_count + s.reviews_count + s.votes_count, 0) > 0)
       )
     ORDER BY p.embedding_updated_at NULLS FIRST
     LIMIT $cap;
     ```
     Spot-side query is the same staleness clause without the cold-start filter (every spot with structured features is worth embedding once extracted). Ordered by `embedding_updated_at NULLS FIRST`, limited by cap.

     Cold-start users (newly inserted, mid-onboarding, never picked a preference) are silently excluded — no wasted OpenAI calls on "No declared preferences" placeholder vectors that nobody's profile will match anyway. They flow through cold-start scoring fallback at request time (drop `s_embedding`, redistribute weights).
  5. For each candidate: rebuild `taste_text` via `text_builder.*`. Compute `new_hash`.
  6. Hash-skip: if `new_hash == taste_text_hash` AND `embedding_model == CURRENT_EMBEDDING_MODEL`, update `taxonomy_version` + `embedding_updated_at` only. No OpenAI call.
  7. Batch remaining candidates (≤`OPENAI_BATCH_MAX=96`/call). Call `EmbeddingClient.embed_batch(texts)`. On success, `INCRBY` Redis counter by `usage.total_tokens`.
  8. Write back per row in its own transaction: `taste_text`, `taste_text_hash`, `embedding_model = CURRENT_EMBEDDING_MODEL`, `taxonomy_version`, `embedding_updated_at = now()`, vector.
  9. Structured log line: `event=srvn_embed_tick mode={backfill|steady} rows_seen=N rows_skipped_hash=K rows_embedded=E tokens=M duration_ms=Y day_budget_remaining=Z`.

- `srvn_refresh_spot_features()` — cron daily 02:00 UTC. For spots where `Spot.last_refreshed_at > srvn_spot_taste_features.features_updated_at` (or features_updated_at IS NULL), call `extract_features(spot_id, session)`. Per-spot transaction.

### 2.3 Scheduler registration in `ressy_backend/app.py`

In `register_scheduler()` (lines ~211–244), inside the existing `START_SCHEDULER` gate, mirror the existing `scheduler.add_job(id, func, trigger, ...)` calls:
- `id="srvn_aggregate_user_signals"`, `trigger="interval"`, `hours=6`
- `id="srvn_refresh_taste_embeddings"`, `trigger="interval"`, `minutes=15`
- `id="srvn_refresh_spot_features"`, `trigger="cron"`, `hour=2`, `minute=0`

Import the three functions at the top of `register_scheduler` (mirror existing pattern).

### 2.4 Config in `ressy_backend/config.py`

Follow the `<NAME>_RAW` env var + parse-in-`__init__` pattern (see `START_SCHEDULER_RAW` at line 293 / `START_SCHEDULER` parse at line 373):

```
# At class body
SRVN_PERSONALIZED_RECS_RAW = os.environ.get("SRVN_PERSONALIZED_RECS", "true")
SRVN_TASTE_EMBED_ENABLED_RAW = os.environ.get("SRVN_TASTE_EMBED_ENABLED", "true")
SRVN_TASTE_EMBED_MODEL = os.environ.get("SRVN_TASTE_EMBED_MODEL", "text-embedding-3-small")
SRVN_TASTE_EMBED_BACKFILL_CAP = int(os.environ.get("SRVN_TASTE_EMBED_BACKFILL_CAP", "200"))
SRVN_TASTE_EMBED_STEADY_CAP = int(os.environ.get("SRVN_TASTE_EMBED_STEADY_CAP", "1000"))
SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET = int(os.environ.get("SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET", "10000000"))
OPENAI_TASTE_GRAPH_API_KEY = os.environ.get("OPENAI_TASTE_GRAPH_API_KEY")
```

In `__init__` (line ~373):
```
self.SRVN_PERSONALIZED_RECS = Config.SRVN_PERSONALIZED_RECS_RAW.lower() == "true"
self.SRVN_TASTE_EMBED_ENABLED = Config.SRVN_TASTE_EMBED_ENABLED_RAW.lower() == "true"
# others passed through directly
```

`SRVN_PERSONALIZED_RECS` defaults `true` (PR 2 doesn't read it — PR 3 does — but the env-var lands now so PR 3 is small).

### 2.5 Tests (PR 2)

Under `tests/srvn_backend/services/srvn_taste_graph/`:

- `test_taste_taxonomies.py` — alias→canonical for each of cuisine/dietary/occasion; unknown returns None; idempotence `normalize(normalize(x)) == normalize(x)`; `CURRENT_TAXONOMY_VERSION == 1`; spot-check that `italian_restaurant` → `ITALIAN`.
- `test_text_builder.py` — multiple cases:
  - **`build_user_taste_text`** output is composed only of tokens from controlled vocab + skeleton words (`Likes`, `Comfortable with price tiers`, `Avoids`, `Dietary:`, `Allergen handling:`, `Dietary strictness:`, `Prefers`, `No declared preferences`).
  - **NULL enums omit lines**: profile with `allergen_handling=NULL`, `dietary_strictness=NULL` → output does NOT contain `Allergen handling:` or `Dietary strictness:` lines. Profile with `allergen_handling="block"` → output contains `Allergen handling: block`. Same for `dietary_strictness="strict"`. Confirms NULL doesn't fabricate a preference into the embedding text.
  - **`build_spot_taste_text` — both editorial AND features present**: Spot with `editorial_summary="Cozy spot..."`, `serves_vegetarian_food=True`, `good_for_groups=True`, `outdoor_seating=True`, `serves_cocktails=True`. Assert output contains BOTH `Description: Cozy spot...` AND `Features: outdoor seating, serves cocktails` AND `Dietary: vegetarian_options` AND `Occasions: group`. (Confirms features are kept when editorial is present.)
  - **`build_spot_taste_text` — editorial only**: Spot with `editorial_summary="..."` but all vibe booleans False/missing. Output contains `Description:` but NO `Features:` line.
  - **`build_spot_taste_text` — features only (editorial missing)**: Spot with `editorial_summary=None`, `outdoor_seating=True`, `live_music=True`. Output contains `Features: outdoor seating, live music` and NO `Description:` line. Output has no trailing `Description: .` stub.
  - **`build_spot_taste_text` — nothing optional present**: minimal Spot (name + cuisine + types + price + rating only). Output is just those three lines, no `Dietary:`, `Occasions:`, `Features:`, or `Description:` lines.
  - **`build_spot_taste_text` — empty/NULL types**: Spot with `types=[]` (or NULL) and no `primary_cuisine` → output is just `"{spot.name}."` (no `, cuisine_label`, no `Types:` line). Assert literal `"None"` does not appear in the output.
  - **`build_spot_taste_text` — `spot.info IS NULL`**: Spot with `info=None` → builder doesn't crash; output renders whatever non-`info` fields are present (name, types via `spot.types`, price tier via features if extractor ran). No AttributeError on `None.get(...)`.
  - **`build_user_taste_text` — `user.cuisines IS NULL`**: user with `cuisines=None`, `dietaries=None`, empty signals, no profile prefs → renders the cold-start text. Confirms defensive `or []` works for NULL columns.
  - **Price + rating NULL handling**: four cases for the price/rating line:
    - `price_tier=3`, `rating=4.5`, `user_rating_count=4402` → `"Price tier: 3. Rating: 4.5/5 (4402 ratings)."`
    - `price_tier=3`, `rating=4.5`, `user_rating_count=None` → `"Price tier: 3. Rating: 4.5/5."` (no count parenthetical)
    - `price_tier=3`, `rating=None` → `"Price tier: 3."` (rating phrase dropped)
    - `price_tier=None`, `rating=4.5`, count present → `"Rating: 4.5/5 (4402 ratings)."` (price phrase dropped)
    - `price_tier=None`, `rating=None` → price/rating line omitted entirely. Assert no `"None/5"` or `"None ratings"` substrings appear in output for ANY of these inputs.
  - **PII guard**: across all build_*_text calls, assert no `user_id`, email, name, or `location` coordinates appear in output for ANY input.
- `test_spot_features_extractor.py` — multiple cases:
  - **Baseline**: Spot with `types=["italian_restaurant","restaurant"]`, `info={"price_level":"MODERATE","editorial_summary":"Cozy spot..."}`; assert `cuisines=["italian"]`, `primary_cuisine="italian"`, `price_tier=2`, `dietary_flags=[]`, `occasion_tags=[]`, `allergen_warnings=[]`.
  - **Dietary + occasion mapping**: Spot with `info={"serves_vegetarian_food": True, "good_for_groups": True}` → `dietary_flags=["vegetarian_options"]`, `occasion_tags=["group"]`.
  - **Dietary + occasion absent**: Spot with `info={"serves_vegetarian_food": False, "good_for_groups": False}` → `dietary_flags=[]`, `occasion_tags=[]` (False is not the same as missing — both produce empty).
  - **goodForChildren is intentionally NOT mapped**: Spot with `info={"good_for_children": True}` → `occasion_tags=[]` (no `family` tag added; assert explicitly that `family` does not appear).
  - **Hash-skip idempotence**: re-running extractor with unchanged input → only `features_updated_at` + `taxonomy_version` touched; `embedding_updated_at` untouched.
  - **Hash-bump on dietary change**: Spot's `info["serves_vegetarian_food"]` flips False → True; re-run → `dietary_flags` updates, `taste_text_hash` changes, `embedding_updated_at` cleared.
  - **`Spot.info IS NULL` defensive**: Spot with `info=None` (never refreshed) → extractor runs without crashing; produces `cuisines=[]`, `primary_cuisine=NULL`, `price_tier=NULL`, all flag arrays empty. No AttributeError on `None.get(...)`.
  - **`Spot.types IS NULL` defensive**: Spot with `types=None` → `cuisines=[]`, `primary_cuisine=NULL`.
- `test_serialize_place_strips_review_authors.py` — fixture Places Details response with reviews containing `authorAttribution.displayName="Nasim Tafrishi"`, `authorAttribution.uri`, `authorAttribution.photoUri`, and `relativePublishTimeDescription="2 months ago"`. Assert: (a) `cleaned_output["info"]["reviews"]` is populated; (b) each entry has only `id`, `rating`, `text`, `language_code`, `publish_time` keys — no `authorAttribution`, no URIs, no `relativePublishTimeDescription`, no `originalText`; (c) the author name string `"Nasim Tafrishi"` does NOT appear anywhere in the JSON-serialized `info` dict.
- `test_signal_aggregator.py` — multiple cases:
  - **Baseline**: `make_user` + 3 saves on Italian-cuisine spots, 1 review (rating=5) on Japanese-cuisine spot, 1 event-vote on Italian spot. Assert `cuisine_affinity` normalizes to `{"italian": 0.8, "japanese": 0.2}` (rough proportions), `signal_version` bumped, `embedding_updated_at` cleared.
  - **NULL rating skipped**: review with `rating=NULL` → not counted toward positive or negative signal; `signal_version` unaffected by it; only non-NULL ratings drive the aggregation.
- `test_scoring.py` — pure function tests:
  - Full path: profile + features both populated → score in (0, 1]
  - Cold start: no profile fields, no signals → score = weighted distance + popularity only
  - Version mismatch: `profile.embedding_model != features.embedding_model` → `s_embedding` dropped, weights renormalize, score finite
  - Both vectors NULL → `s_embedding` dropped, no NaN
  - **NULL enum substitution**: `profile.allergen_handling=NULL` → scoring path behaves identically to `profile.allergen_handling='warn'` (substitution applied, no AttributeError, score identical). Same for `dietary_strictness=NULL` substituting to `'soft'`.
  - **Empty-DB popularity guard**: `global_max_popularity=0` → `s_popularity=0.0` (not NaN); final score is finite for every candidate.
- `test_embedding_client.py` — patch `openai.OpenAI`; assert batching at `OPENAI_BATCH_MAX=96`, exponential backoff on 5xx max 3 tries, no-retry on non-429 4xx, 429 raises (caller halts), `metadata={"surface":"srvn_taste_graph"}` on every call, model id passes through to `model_id` in result.
- `test_embed_worker_budget.py` — covers all the worker guardrails:
  - (a) `SRVN_TASTE_EMBED_ENABLED=false` → tick short-circuits before any DB read (assert via mock spy)
  - (b) Redis day-counter at budget → tick logs `budget_exhausted` and returns
  - (c) Hash-skip path: row with unchanged `taste_text` → no OpenAI call, only `taxonomy_version` + `embedding_updated_at` touched
  - (d) Mode selection: seed 6000 NULL-embedding rows → BACKFILL mode, cap=200; seed 100 NULL → STEADY mode, cap=1000
  - (d2) **Cold-start filter**: seed a brand-new user (empty cuisines, dietaries, allergens, etc., zero saves/reviews/votes) → user-side candidate query excludes that row; worker does not call OpenAI for them. Then add a single save → next tick picks them up. Also confirm `coalesce(cardinality(NULL), 0) = 0` is enforced (seed `user.cuisines=NULL` directly; filter still correctly excludes them).
  - (e) Tokens consumed `INCRBY`'d into Redis day key after successful batch
  - (f) Structured log line emitted with required fields
- `test_worker_jobs.py` — direct invocation of each of the three jobs under `app.app_context()`; idempotence (running twice in a row only processes stale rows); no errors on empty DB.

Use `tests/conftest.py:90-125` `make_user` factory + `auth_header` helper. Mirror `@pytest.mark.api` + `skipif` setup from `test_onboarding_api.py:26-30`.

### 2.6 Verification (PR 2)

- `poetry run pytest tests/srvn_backend/services/srvn_taste_graph` — green
- Local dev: `START_SCHEDULER=true poetry run flask run`; tail logs for the three tick types; confirm `last_aggregated_at` advances for users and `embedding_updated_at` populates for users + spots after one or two embedding ticks
- Spot-check the database: `SELECT user_id, taste_embedding IS NOT NULL FROM srvn_user_taste_profile LIMIT 10;` should show vectors populating
- OpenAI dashboard: spend appears tagged `surface=srvn_taste_graph` (proves the metadata tag works)

## PR 3 — Endpoints (user-visible flip)

This is the small PR that flips personalization on. Behavior change is gated by `SRVN_PERSONALIZED_RECS` so it can be turned off without a revert.

### 3.1 Taste-profile read endpoint (`GET` only)

Writes go through the consolidated `PUT /users/update-profile` (see §3.3). This subsection defines only the read surface.

New file `ressy_backend/routes/srvn_taste_profile.py`. Use `ressy_backend/routes/conversation.py:18-23` as the blueprint declaration template:

```
srvn_taste_profile_blueprint = Blueprint(
    "SrvnTasteProfile",
    __name__,
    description="User taste profile read endpoint (preferences feeding personalized recommendations)",
    url_prefix="/users/me/taste-profile",
)
```

Single route:

- `GET /` — `@jwt_required()`, returns the joined view: all `srvn_user_taste_profile` fields (allergens, allergen_handling, price_comfort_tiers, occasions, dietary_strictness, ambiance_prefs) + the legacy `User.cuisines` / `User.dietaries`. Schema: `SrvnTasteProfileGetSchema`.

**Why dedicated GET (not folded into a general `/users/me` endpoint)**: the existing `/users/me` (or equivalent profile endpoint) is auth-hot — called on cold-start and page navigation. Joining the sidecar on every call would add latency to every request when most reads (feed, search, etc.) don't need taste data. A dedicated `GET /users/me/taste-profile` keeps the hot path lean.

New file `ressy_backend/schemas/srvn_taste_profile.py`:
- `SrvnTasteProfileGetSchema` — Marshmallow Schema with all the new fields + joined legacy fields. Read-only.

Register the blueprint in `ressy_backend/app.py` `register_blueprints()` next to existing `api.register_blueprint(waitlist_blueprint)` and friends.

### 3.2 Personalized `/spots/recommended`

Modify `ressy_backend/routes/spot.py:387-458` (`get_recommended_spots`). The decorator stack and return type stay the same.

New body:

```
if not current_app.config.get("SRVN_PERSONALIZED_RECS"):
    # Existing distance-only path — UNCHANGED
    spots = Spot.find_nearby(latitude, longitude, radius_meters=radius, limit=limit, offset=offset)
    ...

# Stage 1 — SQL candidate pool (≤200)
# Reuse the ST_DWithin PostGIS pattern from Spot.find_nearby (lines 184-244).
# Join in srvn_spot_taste_features and order by:
#   (1 - taste_embedding <=> :user_emb) DESC NULLS LAST, distance ASC
# Limit 200.

# Stage 2 — Python rerank via scoring.score_candidate(...)
profile = SrvnUserTasteProfile.query.filter_by(user_id=user_id).first()
signals = SrvnUserTasteSignals.query.filter_by(user_id=user_id).first()
ranked = sorted(candidates, key=lambda c: scoring.score_candidate(
    profile=profile, features=c.taste_features, signals=signals, user=user,
    distance_m=c.distance_m, popularity_signal=c.popularity, global_max_popularity=GLOBAL_MAX,
), reverse=True)[:limit]

# Preserve existing post-processing
spots_for_response = SpotController.prepare_spots_for_response(ranked)
return paginate_results(spots_for_response, total, limit, offset, request.url)
```

**Response shape unchanged** in MVP — no `caveats` / `meta` envelope additions. (Source plan §5b's envelope expansion is deferred along with the cascade.)

Add optional `?occasion=` query param to the request schema (in `ressy_backend/schemas/spot.py`, on `SpotsNearbyRequestSchema`). MVP wiring: the value is passed through as a soft hint into scoring (boosts spots whose `occasion_tags` contain it — though spot `occasion_tags` are empty in MVP, the wiring is there for Phase 3).

### 3.3 Extend `PUT /users/update-profile` to write taste-profile fields + trigger re-embed

`PUT /users/update-profile` at `ressy_backend/routes/user.py:210-329` is the consolidated write surface for ALL preference data — legacy (`User.cuisines`, `User.dietaries`) AND new (`srvn_user_taste_profile.allergens`, `allergen_handling`, `price_comfort_tiers`, `occasions`, `dietary_strictness`, `ambiance_prefs`). One endpoint, one round-trip per onboarding screen, atomic cross-table updates.

**Why consolidate rather than ship a separate `PUT /users/me/taste-profile`:**
- Onboarding is a single flow — frontend shouldn't pick endpoints based on which preference field the user is editing.
- The two endpoints would have shared a re-embed-trigger concern anyway (originally drafted as a §3.3 side-effect). Consolidating removes the leaky abstraction — it's not a side-effect, it's the endpoint's job.
- All declared-preference fields are conceptually the same thing; the sidecar-vs-User-row split is a storage detail that shouldn't shape the API.
- Existing endpoint already handles cross-concern orchestration (email change → OTP, terms/privacy acceptance). Adding 6 preference fields fits the same pattern.

#### 3.3.1 Schema extension — `UserUpdateSchema`

Extend the existing schema (in `ressy_backend/schemas/user.py` or wherever it lives — find via `grep -rn "class UserUpdateSchema" ressy_backend/`) with the new fields, all **optional** (partial-update semantics preserved):

```python
allergens          = fields.List(fields.String(), required=False)
allergen_handling  = fields.String(required=False, validate=validate.OneOf(["warn", "block"]))
price_comfort_tiers = fields.List(
    fields.Integer(validate=validate.Range(min=1, max=4)),
    required=False,
    validate=validate.Length(min=1),  # non-empty when present; omit field entirely to "clear"
)
occasions          = fields.List(fields.String(), required=False)
dietary_strictness = fields.String(required=False, validate=validate.OneOf(["soft", "strict"]))
ambiance_prefs     = fields.List(fields.String(), required=False)
```

Marshmallow's built-in `validate.Range(min=1, max=4)` + `validate.Length(min=1)` covers the per-element bound + non-empty constraint. No nested schema needed. Duplicate values in the array are tolerated (e.g. `[2, 2, 3]` is stored as-sent; the scoring `in` check is set-semantic anyway). If we want strict deduplication, add a `@validates` method in the schema — but it's not necessary for MVP.

#### 3.3.2 `update_profile()` body extension

After the existing legacy-field partial-update loop and inside the same `try`/transaction block, add:

```python
# Capture originals BEFORE the partial-update writes (top of the function, after fetching user/profile)
original_cuisines = list(user.cuisines or [])
original_dietaries = list(user.dietaries or [])

# Lock the sidecar row once at the top of the function (matching the existing
# user-row lock pattern at line 229). After PR 1's after_insert listener,
# this row is guaranteed to exist for every user.
profile = (
    SrvnUserTasteProfile.query
    .filter_by(user_id=user_id)
    .with_for_update()
    .first()
)

# ...existing user-row partial-update loop runs as today...

# Then for each new taste-profile field:
taste_profile_changed = False
original_taste_state = (
    profile.allergens, profile.allergen_handling, profile.price_comfort_tiers,
    profile.occasions, profile.dietary_strictness, profile.ambiance_prefs,
)

if "allergens" in user_data:
    profile.allergens = user_data["allergens"]
if "allergen_handling" in user_data:
    profile.allergen_handling = user_data["allergen_handling"]
if "price_comfort_tiers" in user_data:
    profile.price_comfort_tiers = user_data["price_comfort_tiers"]
if "occasions" in user_data:
    profile.occasions = user_data["occasions"]
if "dietary_strictness" in user_data:
    profile.dietary_strictness = user_data["dietary_strictness"]
if "ambiance_prefs" in user_data:
    profile.ambiance_prefs = user_data["ambiance_prefs"]

new_taste_state = (
    profile.allergens, profile.allergen_handling, profile.price_comfort_tiers,
    profile.occasions, profile.dietary_strictness, profile.ambiance_prefs,
)
taste_profile_changed = original_taste_state != new_taste_state

# Re-embed trigger: any preference change (legacy OR new) clears the timestamp.
cuisines_changed   = "cuisines"   in user_data and user_data["cuisines"]   != original_cuisines
dietaries_changed  = "dietaries"  in user_data and user_data["dietaries"]  != original_dietaries

if cuisines_changed or dietaries_changed or taste_profile_changed:
    profile.embedding_updated_at = None
    # Next 15m srvn_refresh_taste_embeddings tick picks this row up,
    # rebuilds taste_text (with all current declared prefs), re-embeds.

if cuisines_changed or dietaries_changed or taste_profile_changed:
    changes_made = True
```

#### 3.3.3 Invariants preserved

- **Response shape unchanged.** The 200 body is whatever it was before — no new fields in the response. Reads go through `GET /users/me/taste-profile` (§3.1).
- **Existing callers** (mobile, `test_onboarding_api.py`): payloads without the new fields produce the exact same behavior as today.
- **Atomicity**: User row + sidecar row are written in the same transaction. Same `with_for_update()` lock pattern as the existing user-row lock at line 229.
- **Sidecar row guaranteed to exist**: the PR 1 `after_insert` listener (see PR 1) creates it on User insert. The `with_for_update()` query above doesn't need defensive `None` handling.
- **Idempotence**: payloads that re-send the same values produce no writes (the `!=` checks gate the side-effect). Fast path.
- **Frontend onboarding** can now mix legacy + new fields in a single PUT: `{"cuisines": [...], "allergens": [...], "occasions": [...], "onboarding_complete": true}` — one round-trip, one transaction, one re-embed-trigger.

#### 3.3.4 Why endpoint-side trigger over aggregator-side

The 6h aggregator could in theory detect pref changes by hashing declared fields each tick. But:
- Aggregator runs every 6h → up to 6h staleness on prefs-only changes.
- Endpoint-side gives sub-15m freshness (limited only by the embedding worker tick).
- Endpoint already has the change-detection data for free (the partial-update payload).

#### 3.3.5 Onboarding data inventory (frontend reference)

Quick reference for what the frontend onboarding flow can send. **All fields are optional on every `PUT /users/update-profile` call** — onboarding sends partial payloads as each screen completes. The endpoint coalesces them and the 15m embedding tick coalesces re-embeds into one OpenAI call per session (typical case).

**Identity & profile (existing today)**
| Field | Storage | Notes |
|---|---|---|
| `username` | `User.username` | Display + uniqueness. Conflict-check on PUT. |
| `first_name`, `last_name` | `User.*` | Display only |
| `date_of_birth` | `User.date_of_birth` | Age-gate (alcohol-serving spots — future) |
| `country_code`, `city_code` | `User.*` | Region + currency. Schema enforces `city_code` starts with `<country_code>-`. |
| `email` | `User.email` | Triggers OTP re-verification flow if changed |

**Legal acceptance (existing — idempotent)**
| Field | Persists to | Notes |
|---|---|---|
| `terms_accepted: true` | `terms_accepted_at` + `terms_version` | Once-set; re-sending the same version is a no-op |
| `privacy_accepted: true` | `privacy_accepted_at` + `privacy_version` | Same pattern |

**Communication preferences (existing)**
| Field | Storage | Notes |
|---|---|---|
| `opt_in_marketing` | `User.opt_in_marketing` | Usually defaults false on signup |
| `messaging_privacy` | `User.messaging_privacy` | App-level default if omitted |

**Onboarding state (existing — idempotent)**
| Field | Persists to | Notes |
|---|---|---|
| `onboarding_complete: true` | `User.onboarding_completed_at` | Once-set; sending `false` is a no-op (never clears) |

**Personalization — taste profile** (mix of existing + new after consolidation; triggers re-embed)
| Field | Storage | Required for MVP personalization? | Notes |
|---|---|---|---|
| `cuisines` ARRAY | `User.cuisines` (legacy) | **Critical** | Drives `s_cuisine` Jaccard directly + flows into embedding. Without it, embedding is essentially the cold-start placeholder. |
| `dietaries` ARRAY | `User.dietaries` (legacy) | **Strongly recommended** | Flows into embedding. MVP doesn't hard-filter; spots offering matching options rank higher via embedding similarity. Empty array is fine for users with no dietary needs. |
| `allergens` ARRAY | `srvn_user_taste_profile.allergens` | **Safety-recommended** | Hard-blocks HIGH-tier allergen matches. Currently dormant (Places exposes no allergen data) but the column shape is collected so Phase 3 flips on without re-asking users. |
| `allergen_handling` (`warn`/`block` or omit/null) | `srvn_user_taste_profile.allergen_handling` | Useful | **Nullable.** NULL = "not chosen"; scoring substitutes `warn` at read time. Distinguishes explicit choice from defaulted state. User must actively pick `block` to enable hard-exclusion semantics. |
| `occasions` ARRAY (`date_night`/`family`/`business`/`solo`/`casual`/`group` + future) | `srvn_user_taste_profile.occasions` | Recommended | Flows into embedding; spot `occasion_tags` only carries `group` in MVP, so occasion match is weak until Phase 3 enriches spot side. |
| `price_comfort_tiers` ARRAY of ints in `{1, 2, 3, 4}` (e.g. `[2, 3]` = "comfortable at $$ or $$$") | `srvn_user_taste_profile.price_comfort_tiers` | Recommended | Drives `s_price`. Without it, scoring treats every price tier as 1.0 (no preference). Multi-select chips UX (Yelp/OpenTable-style $/$$/$$$/$$$$ pickable subset). |
| `dietary_strictness` (`soft`/`strict` or omit/null) | `srvn_user_taste_profile.dietary_strictness` | Column shipped, MVP scoring ignores | **Nullable.** NULL = "not chosen"; scoring substitutes `soft` at read time. Phase 3 will use this to gate strict SQL filters. |
| `ambiance_prefs` ARRAY (`cozy`/`lively`/`intimate`/etc.) | `srvn_user_taste_profile.ambiance_prefs` | Nice-to-have | Embedding-only; helps the vector, doesn't enter scoring directly. |

**Minimum personalization-meaningful onboarding**: `cuisines` non-empty. That alone clears the cold-start filter and lets the embedder produce a meaningful taste vector. Everything else layers on incremental quality.

**Suggested screen → endpoint mapping** (~6 screens for full coverage; can compress to 3 for a leaner MVP onboarding):

| Screen | PUT payload |
|---|---|
| Welcome / Legal | `{"terms_accepted": true, "privacy_accepted": true}` |
| Basic profile | `{"first_name", "last_name", "date_of_birth", "country_code", "city_code"}` |
| Cuisines (must-have) | `{"cuisines": [...]}` |
| Dietary + allergens | `{"dietaries": [...], "allergens": [...]}` (only send `allergen_handling` if the user actively picks one; omit to leave NULL → defaults to `warn` at scoring time) |
| Occasions + price | `{"occasions": [...], "price_comfort_tiers": [2, 3]}` |
| Marketing opt-in + complete | `{"opt_in_marketing": ..., "onboarding_complete": true}` |

Leaner 3-screen MVP: legal+basic / cuisines+dietaries / complete. Allergens, occasions, price_comfort_tiers, ambiance can be deferred to a post-onboarding "complete your profile" prompt or a settings screen accessing the same endpoint.

### 3.4 Tests (PR 3)

Under `tests/srvn_backend/api/`:

- `test_srvn_taste_profile_get.py` — `@pytest.mark.api`; `make_user` + JWT; assert default response shape on `GET /users/me/taste-profile` (`allergen_handling=null`, `dietary_strictness=null`, empty arrays, joined `User.cuisines` and `User.dietaries`). After `PUT /users/update-profile` sets `allergen_handling="block"`, GET reflects `"block"` (proves explicit-set distinct from null).
- `test_update_profile_taste_fields.py` — covers writing the new fields via `PUT /users/update-profile`:
  - **Partial taste-profile update**: `{"allergens":["peanut"], "occasions":["date_night"]}` → 200; `GET /users/me/taste-profile` reflects the new values; `srvn_user_taste_profile.embedding_updated_at` cleared (NULL).
  - **Mixed legacy + new in one PUT**: `{"cuisines":["italian"], "allergens":["peanut"], "occasions":["date_night"], "onboarding_complete": true}` → 200; both `User.cuisines` AND `srvn_user_taste_profile.allergens` updated atomically; `embedding_updated_at` cleared; `onboarding_completed_at` set.
  - **Validation rejection**: invalid `dietary_strictness="extreme"` → 422; nothing persisted (transaction rolled back).
  - **`price_comfort_tiers` validation**: out-of-range value `[5]` → 422; out-of-range value `[0, 1, 2]` → 422; empty array `[]` → 422 (non-empty constraint); valid `[2, 3]` → 200 and persists.
  - **Default fill**: omitting `allergen_handling` keeps it at the row's existing value (no overwrite). For a fresh user, the row's value is NULL — omitting keeps NULL.
  - **Null-to-explicit transition**: starting with `allergen_handling=NULL`, PUT with `{"allergen_handling":"block"}` → 200; GET reflects `"block"`. Then PUT with `{"allergen_handling":"warn"}` → GET reflects `"warn"` (NOT null — different from "user never chose"). Same path for `dietary_strictness`.
- `test_srvn_recommended_personalized.py` — seed two users: User-A saves three Italian spots + one Japanese spot; User-B saves three Japanese spots + one Italian spot. Run signal aggregator + embedding worker manually. With `SRVN_PERSONALIZED_RECS=true`, query `/spots/recommended?latitude=X&longitude=Y&radius=5000` for each user; assert their orderings differ (Italian spots rank higher for A; Japanese for B). With `SRVN_PERSONALIZED_RECS=false`, reissue → orderings collapse to identical distance-sorted.
- `test_srvn_recommended_cold_start.py` — `make_user` with no saves, no taste profile entries. `GET /spots/recommended?lat=X&lon=Y&radius=5000` returns ≥1 spot, status 200, no 500.
- `test_update_profile_re_embed_trigger.py` — covers the re-embed trigger logic (decoupled from the field-write tests above so the trigger contract is testable in isolation):
  - **No change → no side-effect**: `PUT /users/update-profile` with `{"onboarding_complete":true}` (no preference fields in payload) returns 200; `srvn_user_taste_profile.embedding_updated_at` is unchanged.
  - **Cuisines change → cleared**: pre-populate `embedding_updated_at` with a non-NULL timestamp. `PUT` with `{"cuisines":["japanese"]}` (different from existing) → 200; `embedding_updated_at` is NULL.
  - **Same cuisines → no-op**: existing `User.cuisines=["italian"]`. `PUT` with `{"cuisines":["italian"]}` → 200; `embedding_updated_at` unchanged.
  - **Dietaries change → cleared**: same pattern.
  - **New taste field change → cleared**: pre-populate `embedding_updated_at`; `PUT` with `{"allergens":["peanut"]}` (different from existing `[]`) → cleared.
  - **New taste field unchanged → no-op**: pre-populate `embedding_updated_at`; `PUT` with `{"allergens":["peanut"]}` matching existing value → unchanged.
  - **No new field touched, only first_name changed → no-op**: `PUT` with `{"first_name": "Maya"}` → `embedding_updated_at` unchanged (non-preference fields don't trigger).

Existing `tests/srvn_backend/api/test_onboarding_api.py` must stay green unchanged — its assertions are on response body + DB User row, not on the new sidecar fields, so the consolidated endpoint extension is invisible to it.

### 3.5 Verification (PR 3)

After merge to a dev branch with PRs 0–2 applied and workers having run at least once:

1. JWT in hand, `GET /users/me/taste-profile` returns defaults: `allergen_handling=null`, `dietary_strictness=null`, empty arrays, joined `User.cuisines`/`dietaries`. (Nulls reflect "user hasn't chosen"; scoring substitutes `'warn'`/`'soft'` at runtime so no behavior change vs. before.)
2. `PUT /users/update-profile` with `{"allergens":["peanut"], "occasions":["date_night"]}` → 200 (with the standard /users/update-profile response body); `GET /users/me/taste-profile` reflects values; `srvn_user_taste_profile.embedding_updated_at` is NULL until next 15m worker tick, then populated.
2a. **Atomic mixed update**: `PUT /users/update-profile` with `{"cuisines":["italian"], "allergens":["peanut"], "onboarding_complete":true}` → 200; one transaction writes `User.cuisines`, `srvn_user_taste_profile.allergens`, AND `User.onboarding_completed_at`. `embedding_updated_at` cleared once.
3. Two seeded users with divergent save histories + same `?latitude=&longitude=&radius=`; assert different orderings via real HTTP calls. Set `SRVN_PERSONALIZED_RECS=false` in the running app config; reissue; orderings collapse to identical.
4. Brand-new user (no taste profile entries, no saves); `GET /spots/recommended` returns ≥1 spot, never 500.
5. Existing `PUT /users/update-profile` with `{"onboarding_complete":true}` (no cuisines/dietaries) returns 200 with identical response body — `test_onboarding_api.py` green unchanged.
6. **New side-effect smoke**: pre-populate a user's `srvn_user_taste_profile.embedding_updated_at` with `now()`. Call `PUT /users/update-profile` with `{"cuisines":["japanese"]}` (different from current). Assert `embedding_updated_at` is NULL after the call, and the next 15m worker tick rebuilds the user's `taste_text` (with the new cuisine) and re-embeds.
7. Full `poetry run pytest` green.

## Critical files to read before implementing

- `ressy_backend/models/user.py:31-613` — User columns + relationships (`saved_spots`, `reviews`, `event_memberships`)
- `ressy_backend/models/spot.py:22-507` — Spot, `find_nearby` (lines 184–244), `_build_order_by_clauses` (126–181), `_text_search_filter` (104–123), `info` JSONB column
- `ressy_backend/models/associations.py:30-46` (UserSavedSpot) + `199-250` (EventParticipant with `vote_event_candidate_id`)
- `ressy_backend/models/review.py:15-100` — Review (`description`, `rating`, `Review.visible_query()` at lines 77–89)
- `ressy_backend/routes/spot.py:387-458` — current `get_recommended_spots` to replace
- `ressy_backend/routes/user.py:210-278` — `PUT /users/update-profile` (JWT + `with_for_update()` + partial-update pattern)
- `ressy_backend/routes/conversation.py:18-23` — Smorest blueprint declaration template
- `ressy_backend/tasks.py:42-107` — `check_event_deadlines` as the APScheduler job pattern template (`with scheduler.app.app_context():`)
- `ressy_backend/app.py:211-244` — `register_scheduler` + scheduler `add_job` registration site
- `ressy_backend/app.py` `register_blueprints()` (around line 176) — blueprint registration site
- `ressy_backend/config.py:293, 373` — `<NAME>_RAW` env var pattern + `__init__` parse
- `ressy_backend/database.py:84-119` — `SoftDeleteModel` base + `Model` parent
- `ressy_backend/services/spot_refresh_service.py:262` — where `Spot.info` gets written (read-only awareness — do NOT change it)
- `ressy_backend/services/googleplaces_services.py:158-191` (`nearby_field_paths`) + `:511-546` (`detail_field_paths`) + `:439-455` (`serialize_place`) — **EXTENDED in PR 2** to add `servesVegetarianFood`, `goodForGroups`, `outdoorSeating`, `liveMusic`, `servesCocktails`, `servesDessert`, `servesCoffee`, `reservable`, `dineIn` to the field mask AND lift them into `info` as snake_case keys
- `ressy_backend/services/conversation_service.py` — **anti-pattern reference** — do NOT share `OpenAIEmbeddings` instance with the new worker
- `tests/conftest.py:90-125` — `make_user` factory, `auth_header` helper
- `tests/srvn_backend/api/test_onboarding_api.py:26-65` — `@pytest.mark.api` + JWT test pattern template
- `migrations/versions/e5a8c9b2d1f7_add_sessions_invalidated_at_to_users.py` — Alembic revision style template

## Existing utilities to reuse (don't reinvent)

- `Spot.find_nearby`'s `ST_DWithin` PostGIS pattern — for Stage 1 SQL retrieval in personalized scoring (extract the geography-cast bit, don't reinvent)
- `SpotController.prepare_spots_for_response` — preserves the `saved` field on response items
- `paginate_results` — pagination shape stays identical
- `lazy_refresh_spot` — keep on the recommended endpoint
- `flask_jwt_extended.get_jwt_identity` + `with_for_update()` — JWT + row-lock pattern from `update_profile`
- `SoftDeleteModel` base — inherit for all `srvn_*` tables
- `scheduler.app.app_context()` — required for all new APScheduler job bodies
- `Review.visible_query(viewer_id=…)` — filter hidden/deleted in signal aggregator
- `Config._RAW` env var pattern + `.lower() == "true"` parsing — for new flags
- `tests/conftest.py` `make_user`, `auth_header` — JWT in tests
- `create_access_token(identity=user.id)` — JWT issuance in tests

## Open items / followups (not blocking the MVP)

- After PR 3 ships and is verified, slim down `docs/plans/AI-Plans/AI-Ready-PostgreSQL-Schema.sql` per the roadmap §"Cross-cutting risks" item 6 — strip everything Phase 1 supersedes, keep only the genuinely-not-yet-built future tables (`behavioral_events`, `search_queries`, `concierge_*`, `dishes`) with a "Future signals — design reference" header. Small separate commit.
- Compliance (DPA, Privacy Policy, Article 9 consent) parked per user decision — revisit before public launch. Worker can keep running on the shared OpenAI key with the `surface=srvn_taste_graph` metadata tag for billing attribution. A separate `OPENAI_TASTE_GRAPH_API_KEY` env var lands in PR 2 as cheap operational hygiene with shared-key fallback.
- Phase 2 (intent endpoint `/spots/recommend-by-intent`) is the natural next slice once embedding coverage on spots reaches ≥80%. Spec is in `docs/plans/AI-Plans/request-time-ai-pipeline.md` §"Phase 1 minimum increment" + the three diffs in §"Concrete spec diffs for Phase 1 increment".

## Execution sequencing note

Step 1 of execution (after this plan is approved) is to **move this plan file** from `~/.claude/plans/go-through-the-plans-logical-goblet.md` into `docs/plans/AI-Plans/mvp-implementation-plan.md` per the project's plan-location convention, then commit. The five plan docs in that folder become: the four originals + the synthesized roadmap + this MVP plan.
