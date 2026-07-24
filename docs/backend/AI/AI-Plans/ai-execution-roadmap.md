# srvn AI execution roadmap

> **Status** — original synthesis of the four documents in `docs/plans/AI-Plans/`, written when none of the work was implemented (verified 2026-05-27). **Re-verified against the codebase 2026-07-05:** Phases 0–1 are **shipped** (`/spots/recommended` is now personalized), and the **Phase 2 review substrate** — vendor review ingestion → per-spot summarizer digest → the spot-level `review_digest_embedding` that superseded per-review RAG — is **shipped** (PRs #197–210). The one remaining Phase 2 piece is the `/spots/recommend-by-intent` endpoint (design pinned in [`spot-digest-embedding-supersedes-per-review-rag.md`](./spot-digest-embedding-supersedes-per-review-rag.md)); Phases 3–5 are **not started**. **Re-verified 2026-07-18:** the intent endpoint has since shipped (Slices 1–3, PRs #211–213; auth required in #218), and Phase 3 shipped as Slices 3A/3B/3D (PRs #214–217, follow-up fix #219; Slice 3C dropped by decision). Phase 4 is **not started**. **Phase 5 (concierge chatbot) was removed from the roadmap on 2026-07-18** — see the tombstone section below; the roadmap now ends at Phase 4. **Phase 4 re-scoped 2026-07-18:** group dining (4b) is removed, and 4a is redesigned — the existing intent endpoint converts to a single SSE response with one combined rerank+explanation LLM call; design pinned in [`phase4-intent-synthesis-implementation.md`](./phase4-intent-synthesis-implementation.md), which supersedes this doc's Phase 4 details. Per-phase status markers are inline under each heading below. This roadmap is the single ordering document; the source plans remain authoritative for the *content* of each phase.

## Context

`docs/plans/AI-Plans/` contains four documents describing different layers of an AI-powered dining concierge. They were written incrementally and don't fully agree with each other. When this roadmap was first written there was **zero implementation**; **as of 2026-07-05 that no longer holds** — pgvector is a dependency (`pyproject.toml`), all three `srvn_*` taste tables and the `services/srvn_taste_graph/` directory exist, and `/spots/recommended` is now **personalized** (two-stage `score_candidate`, gated by `SRVN_PERSONALIZED_RECS` which defaults on) rather than distance-only. The one item from that original list still outstanding is the **`/spots/recommend-by-intent` endpoint** — the next unbuilt slice.

This document does three things:

1. **Inventories the four plans** and declares which is authoritative where they conflict
2. **Sequences the work into six phases** with hard prerequisites and clear "can ship in parallel" markers
3. **Names every existing file to modify and every new file to create**, so each phase is one or two PRs of work, not a research exercise

The synthesis does not redesign anything — it picks an order, resolves contradictions, and stitches the dependencies. The detailed content (table columns, scoring weights, allergen tiers, compliance checklists) stays in the source plans.

## Plan inventory and authority

| File | Role | Authoritative for | Stale where |
|---|---|---|---|
| `Vector-Generation-and-storage.md` | Conceptual explainer | Nothing (reference reading) | N/A — explainer only |
| `AI-Ready-PostgreSQL-Schema.sql` | Aspirational pre-impl schema | **Superseded** — historic reference only | Table names (`restaurants`/`dishes`/`users.taste_embedding`), vector index choice (`ivfflat`), enumerates ~10 tables Phase 1 doesn't add |
| `srvn-user-taste-graph.md` | Phase 1 + 4-phase taste-graph roadmap | Schema, workers, scoring, allergen tiers, compliance, embedding-model migration playbook | N/A — currently the source of truth |
| `request-time-ai-pipeline.md` | Request-time AI tier + group dining | Free-text intent endpoint, latency budget, SSE+reranker plan, group taste merging | N/A — currently the source of truth |

**Resolution of cross-plan conflicts** (the SQL schema is the loser of each):

| Conflict | SQL schema says | Taste-graph plan says | Decision |
|---|---|---|---|
| Where the user vector lives | `users.taste_embedding vector(1536)` directly on the auth-hot table | Sidecar `srvn_user_taste_profile.taste_embedding` | Sidecar — avoids TOAST churn on every login (§1 rationale) |
| Vector index type | `ivfflat` with lists=100 | `hnsw vector_cosine_ops` | HNSW (better recall, no list-tuning) |
| Spot table name | `restaurants` / `dishes` | Existing `Spot` model + `srvn_spot_taste_features` sidecar | Use existing `Spot`; sidecar holds taste features |
| Behavioral signals storage | New `behavioral_events`, `review_likes`, `restaurant_saves`, `search_queries`, `concierge_*`, `dishes` tables | Reuses existing `Review`, `UserSavedSpot`, `EventParticipant` | Reuse existing tables in Phase 1; the SQL-schema-only tables are out of Phase 1 scope and most are unnecessary given current models |

The SQL schema file should stay in the repo as historic reference but the synthesized roadmap does not execute it. A small follow-up PR after Phase 1 lands can either delete the SQL file or re-edit it down to "we ended up with X" notes.

## Phase order at a glance

```
Phase 0 ─ pgvector image                                  [1 commit, blocks all others]
   │
   ▼
Phase 1 ─ Taste-graph foundation                          [the big PR; gates Phases 2-4]
   │       schema + workers + personalized /spots/recommended + /users/me/taste-profile
   │       (embedding worker dark-launched: SRVN_TASTE_EMBED_ENABLED=false)
   │
   ├──────────────► Phase 3 ─ Taste enrichment v2          [can ship in parallel with Phase 2]
   │
   ▼
Phase 2 ─ Request-time intent endpoint (synchronous)      [needs Phase 1 embed worker enabled]
   │       /spots/recommend-by-intent + intent_parser + query_embed + taste_summary_text
   │
   ▼
Phase 4 ─ Streamed AI synthesis                           [needs Phase 2; new SSE infra]
           POST /spots/recommend-by-intent → SSE; one combined rerank+explain LLM call (top 10)
```

Parallelism note: Phase 3 (enrichment-quality improvements to the spot features extractor) touches different files than Phase 2 (new intent endpoint + parser) and can be developed concurrently. They merge cleanly because Phase 3 only changes *what gets written to `srvn_spot_taste_features`*, while Phase 2 only *reads* those features through a new code path.

---

## Phase 0 — pgvector-enabled Postgres image

**Status (2026-07-05): ✅ Shipped.** `pgvector = "^0.3"` is in `pyproject.toml`; `docker/postgres/Dockerfile` builds the `srvn-postgres:dev` image.

**Why first**: every later phase's Alembic migration runs `CREATE EXTENSION vector`. The current `docker-compose.yaml` uses `postgis/postgis:16-3.4`, which doesn't ship pgvector. CI today is "whatever runs `pytest -m api` against compose-Postgres" — so dev image == CI image. Without this, Phase 1's migration fails on every machine.

**Scope** (one small PR, ships standalone):

- `docker/postgres/Dockerfile` — extend `postgis/postgis:16-3.4` with `postgresql-16-pgvector` (taste-graph §0 option A)
- `docker-compose.yaml` — flip the `postgres` service from `image:` to `build: ./docker/postgres`; keep volume + ports
- `README.md` — one-line note: `docker compose build postgres` after pull
- `pyproject.toml` — add `pgvector = "^0.3"` (Python client lib)

**Verification**: `docker compose down -v && docker compose build postgres && docker compose up -d postgres && docker compose exec postgres bash -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;" -c "\dx"'` — expect both `postgis` and `vector` rows. (Single quotes around `bash -c` keep `$POSTGRES_USER` unexpanded on the host so it expands inside the container, where `.env.test` sets it. Two `-c` flags are required because `\dx` is a psql backslash meta-command and can't be combined with SQL in a single `-c` string.)

**Authoritative reference**: `srvn-user-taste-graph.md` §0.

---

## Phase 1 — Taste-graph foundation

**Status (2026-07-05): ✅ Shipped.** All three sidecar models exist (`srvn_user_taste_profile`, `srvn_user_taste_signals`, `srvn_spot_taste_features`), the `services/srvn_taste_graph/` layer is in place (`embedding_client`, `embedding_worker`, `scoring`, `signal_aggregator`, `spot_features_extractor`, `taste_taxonomies`, `text_builder`), `routes/srvn_taste_profile.py` serves the taste-profile endpoint, and `/spots/recommended` runs the two-stage personalized `score_candidate` path (`SRVN_PERSONALIZED_RECS`, default on).

**Why this is the gate**: every other phase needs at least one of (a) the three sidecar tables, (b) the `embedding_client` Protocol, (c) the `taste_taxonomies` normalizer, (d) the `srvn_refresh_spot_features` worker. Phase 1 ships all four.

**Scope is large enough that it likely splits into 2 PRs** for review sanity:

- **PR 1a — schema + models + worker scaffolding** (no behavior change to user-facing endpoints yet; `SRVN_PERSONALIZED_RECS=false`)
- **PR 1b — flip personalized scoring on**, register endpoints, enable workers

Both PRs together implement the entirety of `srvn-user-taste-graph.md` §§1–8.

### 1.1 Schema (PR 1a)

Three sidecar tables (1:1 with existing models), all inheriting `SoftDeleteModel`:

- `srvn_user_taste_profile` — declared prefs (allergens, dietary_strictness, price_comfort, occasions, ambiance_prefs) + ACTIVE vector + `taste_embedding_next` for blue/green migrations + `embedding_model` + `taxonomy_version` + `taste_text_hash`
- `srvn_user_taste_signals` — aggregated affinities (cuisine/price/occasion/type) + counters + `signal_version`
- `srvn_spot_taste_features` — extracted features (primary_cuisine, cuisines, price_tier, dietary_flags, occasion_tags) + tiered `allergen_warnings` JSONB + ACTIVE + `_next` vectors + same model/taxonomy version columns

Indexes: HNSW on each `taste_embedding`; partial HNSW on each `taste_embedding_next WHERE NOT NULL`; GIN on `cuisines` / `dietary_flags` / `allergen_warnings` (jsonb_path_ops); btree on `price_tier` and `dietary_strictness`.

Backfill on migration: insert empty rows for every existing user and every existing spot. All vectors NULL until the worker fills them.

**Authoritative reference**: `srvn-user-taste-graph.md` §1.

### 1.2 New files (PR 1a)

```
ressy_backend/models/srvn_user_taste_profile.py
ressy_backend/models/srvn_user_taste_signals.py
ressy_backend/models/srvn_spot_taste_features.py
ressy_backend/services/srvn_taste_graph/
    __init__.py
    embedding_client.py        # Protocol + OpenAIEmbeddingClient; CURRENT_EMBEDDING_MODEL constant lives here
    signal_aggregator.py       # UserSavedSpot + Review + EventParticipant → affinity JSONBs
    spot_features_extractor.py # spots.info JSONB + review text → structured features + allergen tiers
    taste_taxonomies.py        # canonical cuisine / dietary_flag / occasion vocab; CURRENT_TAXONOMY_VERSION
    scoring.py                 # weighted rerank, cold-start fallback, model-mismatch guard
    text_builder.py            # deterministic taste_text builders (vocabulary-bounded — §7b safe-harbor)
ressy_backend/schemas/srvn_taste_profile.py
ressy_backend/routes/srvn_taste_profile.py  # Smorest blueprint for GET/PUT /users/me/taste-profile
```

Tests in `tests/srvn_backend/services/srvn_taste_graph/` and `tests/srvn_backend/api/test_srvn_*` per `srvn-user-taste-graph.md` §8 (15 test files enumerated).

### 1.3 Modified files (PR 1b)

| File | Change |
|---|---|
| `ressy_backend/routes/spot.py` (`get_recommended_spots`, currently distance-only) | Replace `Spot.find_nearby` ranking with SQL retrieval → Python rerank from `scoring.py`. Same query params; add optional `?occasion=` and `?relax_strictness=`. Honor `SRVN_PERSONALIZED_RECS` flag. Reuse existing `lazy_refresh_spot`, `SpotController.prepare_spots_for_response`, `paginate_results`. |
| `ressy_backend/tasks.py` | Add three APScheduler jobs: `srvn_aggregate_user_signals` (6h), `srvn_refresh_taste_embeddings` (15m, gated), `srvn_refresh_spot_features` (daily 02:00 UTC). Match existing `with scheduler.app.app_context():` pattern. |
| `ressy_backend/app.py` (scheduler registration, ~lines 176-244) | Register the 3 new jobs inside the existing `START_SCHEDULER` gate. Register the `srvn_taste_profile` blueprint. |
| `ressy_backend/config.py` | Add the 13 config vars from `srvn-user-taste-graph.md` §3 — flags, caps, budgets, canary IDs, review-allergen knobs. Critical: `SRVN_TASTE_EMBED_ENABLED` defaults **false** in production. |
| `ressy_backend/routes/user.py` (`PUT /users/update-profile`) | **Untouched**. New fields live on the new endpoint. |

### 1.4 Behavior contract for `/spots/recommended` after Phase 1

- Same query params plus optional `?occasion=` and `?relax_strictness=`
- Response shape extended additively with `caveats.allergen_warnings`, `caveats.dietary_status`, `meta.{pre_filter_count, post_filter_count, dropped, degraded_to, suggestions}`
- Allergen hard-block on HIGH-confidence Places-derived signals only — never on review-derived medium tier — regardless of `?relax_strictness`
- Strict dietary filter applies only when `dietary_strictness='strict'` AND `?relax_strictness != true`
- Missing-data policy: spots with NULL `dietary_flags` pass through with `dietary_status='unverified'` — not excluded
- Graceful degradation cascade: drop strict-dietary → widen radius (max 2×, capped 15km) → empty + suggestions
- Cold-start: drop `s_embedding` + `s_cuisine`, renormalize remaining weights

**Authoritative reference**: `srvn-user-taste-graph.md` §§4–6.

### 1.5 Compliance gate (blocks `SRVN_TASTE_EMBED_ENABLED=true`)

Before flipping the embedding worker on in production, the five-item checklist in `srvn-user-taste-graph.md` §7b must be satisfied:

1. OpenAI DPA signed + zero-retention requested on a **dedicated** worker API key
2. Worker key is distinct from the `conversation_service.py` key
3. Privacy Policy updated to disclose third-party AI processing of preference descriptors
4. Allergen/dietary consent in onboarding is explicit and covers third-party processing (GDPR Article 9)
5. `test_text_builder.py` is green — proves vocabulary-bounded output, no PII can leak

If any of these can't be satisfied, the fork is to local embedding (e.g. `fastembed` + `bge-small-en-v1.5`); the `EmbeddingClient` Protocol seam in §7a makes that a one-class addition, not a refactor.

### 1.6 Pre-merge measurements (PR description)

- `SELECT count(*) FROM users WHERE deleted_at IS NULL; SELECT count(*) FROM spots WHERE deleted_at IS NULL;` on a recent prod snapshot
- Confirm `(user_count + spot_count) * 80 tokens` fits under `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` (default 10M tokens ≈ $0.20/day)
- If it doesn't, raise the budget OR scope initial backfill to last-90-days-active users

### 1.7 Verification (Phase 1 end-to-end)

Full smoke from `srvn-user-taste-graph.md` §Verification — steps 0, 0a, 1–7 cover image build, migration, tests, worker ticks, taste-profile CRUD, divergent-user ranking, allergen+strict cascade (§5a), cold-start, backward-compat.

---

## Phase 2 — Request-time intent endpoint (synchronous)

**Status (2026-07-05): ◑ Endpoint shipping.** The review pipeline that feeds this endpoint is done — vendor ingestion (PRs #197–208, dark behind `SRVN_REVIEW_INGEST_ENABLED=false`), the per-spot summarizer digest, and the spot-level `review_digest_embedding` + `review_noise` columns that replaced per-review RAG (PRs #209–210). **Slice 1 (embedding-first) shipped in PR #211** — the endpoint, query embed, and the `s_query_taste`/`s_review_match` scoring terms. **Slice 2 (this PR) adds the LLM facet parser** — `intent_parser.py`, plus explicit price/atmosphere hard filters and occasion/cuisine/dietary soft boosts. Its design is fully pinned in the "Intended future integration" section of [`spot-digest-embedding-supersedes-per-review-rag.md`](./spot-digest-embedding-supersedes-per-review-rag.md); note that plan revises §2.1–§2.4 below (dedicated `review_digest_embedding` rather than `taste_summary_text`-only; two cosine terms rather than one `s_query_match`).

**Why this can ship next**: Phase 1 makes `srvn_spot_taste_features.taste_embedding` populated. Phase 2 layers a new endpoint that consumes those embeddings against a request-time-embedded query. Synchronous only — SSE infrastructure does not exist in srvn-backend and is deferred to Phase 4.

**Hard prerequisite**: Phase 1 in production AND `SRVN_TASTE_EMBED_ENABLED=true` AND ≥80% of spots have `taste_embedding != NULL`. Without this, the new `s_query_match` term has nothing to compare against; the endpoint would silently fall back to feature-only scoring.

**Degraded-mode fallback**: if compliance (§1.5) blocks turning the embedding worker on, Phase 2 still ships — `s_query_match` weight is redistributed to feature scores, intent parser still routes `occasion` + `vibe_tags` filters at SQL. UX is meaningfully worse but the endpoint is real.

### 2.1 New endpoint

```
POST /spots/recommend-by-intent
{ latitude, longitude, query: "date night, jazz music bar", radius?, limit? }
```

Returns 20 spots with `taste_summary_text` per spot, same `caveats`/`meta` envelope as `/spots/recommended`.

### 2.2 New files

- `ressy_backend/services/srvn_taste_graph/intent_parser.py` — OpenAI **GPT wrapper** (Chat Completions + strict Structured Outputs, mirrors `review_summarizer_client.py`); returns `{search_text, cuisine, price_max, atmosphere, occasion, dietary, open_now}`. (The AI stack is OpenAI end-to-end — there is no Claude/`anthropic` dependency; the earlier "haiku" framing was stale.)
- `ressy_backend/routes/srvn_recommend_by_intent.py` — Smorest blueprint, new route alongside the existing recommended endpoint
- Tests: `test_intent_parser.py`, `test_recommend_by_intent.py`, `test_query_embed_cache.py` (per `request-time-ai-pipeline.md` §Verification step 6)

### 2.3 Modified files

| File | Change |
|---|---|
| `ressy_backend/services/srvn_taste_graph/embedding_client.py` | Add `embed_query(text) -> vector` to the Protocol and the OpenAI impl. Single-element batch, `metadata={"surface":"srvn_intent_query"}` for billing attribution. |
| `ressy_backend/models/spot.py` | Extend `find_nearby` (or add `find_nearby_with_intent`) to accept `query_vector` + parsed intent struct. Apply the extended scoring formula (`s_query_match` weight ~0.35 when query present, renormalize others). |
| `ressy_backend/services/srvn_taste_graph/spot_features_extractor.py` | Add nightly LLM compression step that writes `srvn_spot_taste_features.taste_summary_text` (~200 chars). This is the field every Phase 2 response card carries. |
| `ressy_backend/config.py` | Add `SRVN_GPT_5_NANO_MODEL` (default `gpt-5-nano`); no separate parser effort var — the shared `SRVN_OPENAI_REASONING_EFFORT` (renamed from `SRVN_REVIEW_DIGEST_REASONING_EFFORT`, default `medium`) governs the digest, while the endpoint pins the parser call to `minimal`. `SRVN_QUERY_EMBED_CACHE_TTL` / `SRVN_INTENT_DAILY_BUDGET` are **deferred** — caching + budget breaker are a follow-up PR, out of the Slice-2 scope. |
| `docs/plans/AI-Plans/srvn-user-taste-graph.md` | Apply Diffs A, B, C from `request-time-ai-pipeline.md` §"Concrete spec diffs" — §5 adds `s_query_match`, §7 adds query-embedding subsection, §3 lists `intent_parser.py`. |

### 2.4 Caching

- `srvn:intent:{sha1(normalized_query)}` — 1h TTL on parsed intent
- `srvn:query_embed:{sha1(normalized_query)}` — 1h TTL on query vector
- Normalization: lowercase, strip punctuation, sort tokens (so "Date Night" and "date night" share)

### 2.5 Latency contract (Phase 2 acceptance)

| Stage | Target p50 | Target p95 |
|---|---|---|
| 1A intent parse + 1B query embed (parallel) | 250ms | 500ms |
| 2 candidate SQL | 150ms | 350ms |
| 3 response serialization | 50ms | 100ms |
| **End-to-end first paint** | **~450ms** | **~1s** |

If p95 > 1s, the bottleneck is almost certainly the parser LLM (`gpt-5-nano`) — measure each stage independently per `request-time-ai-pipeline.md` §Verification step 1.

### 2.6 Failure modes (acceptance criteria from `request-time-ai-pipeline.md` §user-story)

- AC-2 to AC-4: first-paint cards must be usable without the intent parser; intent parser malformed → fall back to embedding-only retrieval; query embed fails → 503 with `Retry-After` (do NOT silently degrade to lexical FTS).
- AC-7: cold-start user → drop `s_user_taste`, renormalize. Same fallback as Phase 1 `/spots/recommended`.

**Authoritative reference**: `request-time-ai-pipeline.md` §"Phase 1 minimum increment" + §"Concrete spec diffs for Phase 1 increment".

---

## Phase 3 — Taste enrichment v2 (parallel with Phase 2)

**Status (2026-07-05): ○ Not started.** `spot_features_extractor.py` still writes only the Phase-1 baseline (`occasion_tags` derived from the Places `good_for_groups` boolean); no review-mined `vibe_tags`, no taxonomy-version bump, no medium-tier allergen scan yet.

**Why parallel**: this phase only changes *what gets written to `srvn_spot_taste_features`*, while Phase 2 only *reads* features through a new endpoint. Different files, no merge conflict.

**Scope** (from `srvn-user-taste-graph.md` Roadmap row 2):

- Better cuisine taxonomy — expand `CUISINE_ALIASES` in `taste_taxonomies.py`; ship `TAXONOMY_VERSION` bump; the §6.2 worker's hash-skip catches the common case where bumping the canonical label doesn't change rendered `taste_text` (so the bump usually costs ~zero tokens)
- Higher-quality dietary-flag inference — extend `spot_features_extractor.py` to read more fields from `Spot.info` JSONB and to do better review-text mining (review-frequency heuristic for dietary already exists at medium tier per §5b, similar pattern applies to flagging affirmative support)
- Ambiance + occasion signals from reviews — extend Pass B of `srvn_refresh_spot_features` to compute `occasion_tags` and `vibe_tags` from review text (controlled vocabulary in `taste_taxonomies.py`)
- The medium-tier allergen heuristic (`SRVN_REVIEW_ALLERGEN_FLAGS`) flag-flip happens here once ops has reviewed real per-spot mention-rate distributions

**No new tables, no new endpoints.** Tests extend `test_spot_features_extractor.py` and `test_srvn_review_allergen_scan.py`.

**Authoritative reference**: `srvn-user-taste-graph.md` Roadmap Phase 2 + §5b feature-flag rollout.

---

## Phase 4 — Streamed AI synthesis (re-scoped 2026-07-18)

**Status (2026-07-18): ○ Not started — design pinned in [`phase4-intent-synthesis-implementation.md`](./phase4-intent-synthesis-implementation.md), which supersedes this section and the corresponding parts of `request-time-ai-pipeline.md`.**

Re-scope summary (decisions locked with the user 2026-07-18):

- **`POST /spots/recommend-by-intent` converts to a single SSE response** — it flushes the math-ranked first-paint `results` frame in <1s, then streams synthesis over the same connection. No second endpoint, no `request_id`, no Redis handoff; normal header JWT auth throughout. Breaking response-contract change coordinated with the frontend.
- **One combined LLM call** (the shared `SRVN_GPT_5_MINI_MODEL` knob, default gpt-5-mini — the old "haiku" framing was stale; the stack is OpenAI-only, and a dedicated `SRVN_RECOMMEND_SYNTH_MODEL` var was dropped by decision 2026-07-18): surfaces and reranks the **top 10 with grounded explanations** in one pass (pagination removed 2026-07-18 — the response is exactly the synthesis set). Cards carry the review digest + the latest 50 PII-stripped vendor reviews per spot.
- **No feature flags** (the old `SRVN_RECOMMEND_RERANK_ENABLED` idea is dropped) and **no daily token budget** — always-on; spend (~2¢/search) monitored via the `srvn_recommend_synthesis` billing tag.
- Degradation: any post-flush LLM failure ends the stream with `done {status: degraded}`; first paint is never affected.

### 4b — Group dining endpoint (removed 2026-07-18)

**Removed from the roadmap.** `group_taste_merger.py` and `POST /events/{event_id}/recommend-by-intent` are no longer planned; `request-time-ai-pipeline.md` §"Group taste merging" is historical. Cross-cutting risk #3 (`Event.dietary_constraints_merged`) is moot — 2026-07-18 exploration confirmed that column never existed on `Event`.

---

## Phase 5 — Concierge chatbot (removed 2026-07-18)

**Removed from the roadmap** — the concierge chatbot is no longer planned; this roadmap now ends at Phase 4. Consequences of the removal:

- The per-request FAISS rebuild in `ressy_backend/services/conversation_service.py` is no longer scheduled for retirement by this roadmap; any cleanup there is an independent decision.
- The `concierge_sessions` / `concierge_messages` design-reference tables in `AI-Ready-PostgreSQL-Schema.sql` lost their only planned consumer (see risk #6).
- `srvn-user-taste-graph.md` Roadmap rows 3–4 still describe the chatbot; treat them as historical.

---

## Critical files (single inventory, by role)

### Files that get modified across multiple phases

- `ressy_backend/routes/spot.py` — Phase 1 (`get_recommended_spots` replaced)
- `ressy_backend/services/srvn_taste_graph/embedding_client.py` — Phase 1 (created), Phase 2 (`embed_query` added)
- `ressy_backend/services/srvn_taste_graph/spot_features_extractor.py` — Phase 1 (created), Phase 2 (`taste_summary_text` LLM compression), Phase 3 (richer feature extraction + vibe_tags + occasion_tags)
- `ressy_backend/services/srvn_taste_graph/taste_taxonomies.py` — Phase 1 (created at v1), Phase 3 (alias expansion, version bump)
- `ressy_backend/config.py` — Phase 1 (13 vars), Phase 2 (3 vars), Phase 4 (no new var — synthesis reuses `SRVN_GPT_5_MINI_MODEL`)
- `ressy_backend/models/spot.py` — Phase 2 (`find_nearby_with_intent`)

### Existing utilities to reuse (do not reinvent)

- `Spot.find_nearby` / `_build_order_by_clauses` / `_text_search_filter` — Stage 1 SQL retrieval
- `SpotController.prepare_spots_for_response` — preserves `saved` field in response items
- `paginate_results` — pagination shape unchanged across phases
- `lazy_refresh_spot` — keep on the recommended endpoint
- `flask_jwt_extended.get_jwt_identity` + `with_for_update()` — locking pattern from `update-profile`, mirror in `taste-profile` PUT
- `SoftDeleteModel` — base for all `srvn_*` tables
- `scheduler.app.app_context()` — pattern from `check_event_deadlines` / `reconcile_reports`; required for all new APScheduler jobs

### Reference reading before implementation

- `ressy_backend/models/user.py:31-100` — User shape + relationships
- `ressy_backend/models/spot.py:22-411` — Spot, `find_nearby`, PostGIS patterns
- `ressy_backend/routes/spot.py:387-457` — current `get_recommended_spots`
- `ressy_backend/routes/user.py:179-360` — JWT + `with_for_update()` locking
- `ressy_backend/tasks.py` — APScheduler job patterns
- `ressy_backend/app.py:176-244` — scheduler registration + `START_SCHEDULER` gate
- `ressy_backend/services/conversation_service.py` — existing FAISS use (do NOT share an `OpenAIEmbeddings` instance between this and the new worker)
- `tests/conftest.py` + `tests/srvn_backend/api/test_onboarding_api.py` — `make_user()` factory + `@pytest.mark.api` setup

---

## Cross-cutting risks and blockers

1. **Compliance gate (§1.5)** — blocks `SRVN_TASTE_EMBED_ENABLED=true` in production. Phase 2 onwards still ships in a degraded mode if this slips, but the "real" UX requires it. Legal/privacy review should kick off in parallel with Phase 0 work so it's not on the critical path.

2. **Cost pre-flight (§1.6)** — must be measured before Phase 1 merges. Default 10M token/day budget is enough for ~125k embeddings/day (small-scale). If user+spot counts are 100k+ the initial backfill needs scoping.

3. **Existing `Event.dietary_constraints_merged` column state** — **moot (2026-07-18)**: Phase 4b was removed from the roadmap, and exploration confirmed the column never existed on `Event`.

4. **SSE in Flask** — Phase 4 is the first time srvn-backend will stream a response. Existing routes are all request-response. Greenfield. Budget extra design time for keepalive, client reconnection, and CORS implications.

5. **OpenTable review ingestion** — referenced by `request-time-ai-pipeline.md` (`top_review_snippets` would include OpenTable reviews once available). Independent pipeline; lands whenever it lands. Don't gate Phase 2 on it — internal reviews are sufficient for the precomputed snippet field.

6. **The SQL schema file (`AI-Ready-PostgreSQL-Schema.sql`)** is partially superseded. Action in the Phase 1 cleanup commit: **slim it down to future-reference tables only**. Strip everything Phase 1 supersedes or duplicates (the inline-embedding `users` / `restaurants` / `dishes`, the old `user_taste_profiles`, plus tables already in the codebase with different shapes — `reviews`, `follows`, `events`, `event_attendees`, `restaurant_saves`, `review_likes`/`review_saves`/`review_dishes`, `event_restaurant_candidates`). Keep only the tables that are genuinely not-yet-built and still useful as design reference for later phases: `behavioral_events` (granular per-action analytics), `search_queries` (free-text search analytics), and `dishes` if dish-level granularity is on the table. (`concierge_sessions` + `concierge_messages` lost their only planned consumer when the Phase 5 chatbot was removed from the roadmap on 2026-07-18 — strip them too.) Add a header making the doc's new purpose explicit ("Future signals — design reference"). This avoids the three-sources-of-truth drift problem that would come from rewriting the doc to mirror the taste-graph plan and the Alembic migration. Authoritative current-schema info stays in `srvn-user-taste-graph.md` §1 + the migration file.

---

## Verification (cross-phase)

Each phase's source plan carries its own end-to-end smoke. The cross-phase invariants worth re-checking after each merge:

- **After Phase 0**: `\dx` in psql shows both `postgis` and `vector` extensions
- **After Phase 1**: `/spots/recommended` ordering visibly differs between two seeded users with divergent saves; collapses to identical distance ordering when `SRVN_PERSONALIZED_RECS=false`; allergen+strict cascade works (§5a)
- **After Phase 2**: `/spots/recommend-by-intent` first-paint p95 ≤ 1s (warm cache); repeat queries hit Redis caches (TTL respected); cards include populated `taste_summary_text`
- **After Phase 3**: increased coverage in `srvn_spot_taste_features` rows (lower NULL rate on `vibe_tags` / `occasion_tags`); `SRVN_REVIEW_ALLERGEN_FLAGS=true` does not blow up `s_allergen` distribution
- **After Phase 4**: `POST /spots/recommend-by-intent` streams `results` in <1s, then `rerank` + `explanation` frames (~5–6s) and `done`; degrades silently on LLM provider outage (`done degraded`, first paint intact)

`poetry run pytest` must be green after every phase. The test files listed in each source plan are the verification harness.
