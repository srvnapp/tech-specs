# srvn Review Ingestion — implementation plan (ingestion slice)

_Date: 2026-06-28 · **Status (upd. 2026-07-05): shipped (PRs #197–208, dark)** — the `srvn_spot_reviews`/`srvn_review_ingest_tasks` schema, DataForSEO vendor client, spend ledger, and the `srvn-reviews` CLI (`enqueue`/`run`/`collect`/`status`) are live behind `SRVN_REVIEW_INGEST_ENABLED=false`. · Scope: **get vendor reviews into the DB**. Embedding, summarization, RAG, and the intent-endpoint wiring were deferred at plan time — summarization has since shipped ([`srvn-review-summarizer-implementation.md`](./srvn-review-summarizer-implementation.md)) and per-review RAG was superseded by a spot-level digest embedding ([`spot-digest-embedding-supersedes-per-review-rag.md`](./spot-digest-embedding-supersedes-per-review-rag.md))._

Companion design doc (authoritative for the full vision): [`phase2-review-ingestion-and-rag.md`](./phase2-review-ingestion-and-rag.md). This document is the **build order for the ingestion half only** — the part that pulls reviews from the vendor and persists them, grounded against the current codebase conventions (mirrors the `srvn-seed` grid-sweep pipeline).

---

## 1. Goal & scope

**Goal:** stand up the pipeline that buys restaurant reviews from **DataForSEO** (Google Reviews via the Business Data API) and writes them, PII-stripped + deduped, into a new `srvn_spot_reviews` table — and give us a CLI lever to seed reviews for a metro (Toronto) on demand.

### In scope (this plan)
1. `srvn_spot_reviews` table + migration (incl. the `embedding` column, **filled in this phase** — item 8).
2. `SrvnSpotReview` model.
3. Config — only the genuinely env-driven knobs in `config.py`; fixed values as module constants (see §5).
4. `review_vendor_client.py` — `ReviewVendorClient` Protocol + `DataForSEOClient` (two-phase post/collect, PII strip, cost estimate).
5. `review_ingestor.py` — `ReviewSpendLedger` (reserve/release/reconcile $ breaker) + queue pop + post/collect + dedup upsert.
6. In-flight task tracking (`srvn_review_ingest_tasks` table — see §4.2) so the async post→collect gap survives restarts.
7. **Ingestion is fully manual — NO scheduled jobs.** The post and collect tick logic lives in `review_ingestor.py` but is invoked **only via the `srvn-reviews` CLI** (§8). Nothing posts a paid vendor task without a human running it. (The future auto-enqueue trigger lands with the intent endpoint; not now.)
8. **Per-review embedding — the one scheduled job in this slice.** A sibling APScheduler job sweeps `srvn_spot_reviews WHERE embedding IS NULL` and embeds *every* row (reuse `embedding_client` + the existing daily token-budget breaker). **No per-spot embed cap, no separate enable flag**: volume is already bounded by `SRVN_REVIEW_INGEST_MAX_PER_SPOT`, and rows only exist once a manual ingest ran. Uses **`OPENAI_API_KEY`** — the project's embedding key (key split: embeddings → `OPENAI_API_KEY`, LLM/chat → `OPENAI_API_CONVERSATIONAL_KEY`); reuses the existing `embedding_client`, so **no new key/wiring this phase**. A manual `srvn-reviews embed` CLI drain is added as an escape hatch (the prod scheduler is currently down — see §10).
9. `srvn-reviews` CLI group (enqueue / run / collect / status / reset) — the **"get reviews now"** lever.
10. Tests (CI green via `poetry run pytest`).

### Deferred (NOT this plan — designed-for, not built)
- `srvn_summarize_spot_reviews` (`review_digest_*`, `top_review_snippets`) — the per-spot LLM summary that powers the intent endpoint's first-paint card.
- `review_rag.py` + `/spots/recommend-by-intent` wiring (`SRVN_INTENT_REVIEW_RAG_ENABLED`, `…_TOPK`).
- The **automatic** demand-driven enqueue hook (enqueue a spot when it appears in an intent-endpoint candidate set) — that endpoint doesn't exist yet, so **enqueue is manual via CLI in this phase.**

> **`/spots/recommended` is untouched.** Per the settled decision, review text never enters the vocabulary-bounded `taste_text` embedding. Reviews are a separate store with one future consumer: the intent endpoint.

---

## 2. Hard external prerequisites (the load-bearing caveats)

These gate *running* the pipeline against prod — not writing/merging the code (which can land dark and be tested against the DataForSEO sandbox).

1. **DataForSEO account + credentials** (`SRVN_DATAFORSEO_LOGIN` / `_PASSWORD`). Paid, per-review billing (~$0.075 / 1,000 reviews standard queue). There's a **free sandbox** — develop and test against it first.
2. **Compliance item 1 — vendor licensing counsel sign-off** (companion plan §7). This is the load-bearing legal question and it gates `SRVN_REVIEW_INGEST_ENABLED=true` in production, exactly like the Phase 1 embed compliance gate. The vendor contract is *risk-allocation*, not a copyright license — every vendor scrapes Google. **If this can't be satisfied, the pipeline stops; there is no in-scope fallback that yields review volume.**
3. **PII strip is mandatory at ingest** (companion §7.2): drop reviewer name/handle/profile + the business `owner_answer`. Enforced in code (§7) and asserted in tests.

Code can merge with `SRVN_REVIEW_INGEST_ENABLED=false` (default) before 1–2 land. Flipping it on is an ops action behind the gate.

---

## 3. Architecture (ingestion slice)

DataForSEO is **async** — `task_post` returns a `task_id`, results land ~45 min later. So ingestion is two **manual CLI steps**, separated by that wait; only embedding is scheduled:

```
[MANUAL]  srvn-reviews enqueue   → Redis set srvn:review:ingest_queue  (spot_id|provider_id)

[MANUAL]  srvn-reviews run       # POST — a human runs this
  pop ≤ --max-spots from queue; per spot:
  → CLAIM: INSERT srvn_review_ingest_tasks (spot_id, status='claimed')
           ON CONFLICT (uq_srvn_review_active_task) DO NOTHING
           ↳ 0 rows inserted? spot already in-flight → SKIP (no spend, no vendor call)   ← double-post guard
  → ledger.reserve(max_cost)        # reserve into srvn:review:spend:{day}; if breached → release claim + halt
  → client.post_reviews_task(provider_id, depth=INGEST_MAX_PER_SPOT, sort_by=relevant|newest)   # $ committed here
  → UPDATE the claimed row → task_id, reserved_cost, status='posted'
           (post fails → ledger.release + delete the claim, so the spot is retryable)

        ...wait ~45 min (results are async)...

[MANUAL]  srvn-reviews collect   # COLLECT — a human runs this (re-runnable; drains whatever's ready)
  for each 'posted' task whose result is ready:
  → client.collect_reviews_task(task_id)
  → ledger.reconcile(reserved, actual)     # true-up to real charge
  → PII-strip + dedup upsert into srvn_spot_reviews   (on (spot_id, external_review_id) and content_hash)
  → set features.reviews_count, reviews_ingested_at ; mark task 'collected'

[SCHEDULED]  srvn_embed_spot_reviews  (interval 15m)   ← the ONLY background job
  sweep srvn_spot_reviews WHERE embedding IS NULL → embedding_client (batch ≤96, token budget) → write vectors
```

Why ingestion is manual: every `run` commits real vendor spend, so a human gates each batch. Why the `run`/`collect` split: DataForSEO **commits cost at `task_post`, minutes before rows arrive** — spend is **reserved at post** (depth-based max) and **reconciled at collect** (real charge), which is also why the `srvn_review_ingest_tasks` table must persist in-flight tasks across the wait (and across process restarts). This is the one place the pipeline cannot mirror the synchronous taste-embed breaker — companion Appendix A "C1".

### 3a. Double-post guard (claim-before-spend)

The risk: `reviews_ingested_at` is only set on **collect**, so between `run` and `collect` a spot has an in-flight ticket but looks "never ingested" — a second `enqueue`+`run` would post it again and **pay twice**. The fix is enforced at three layers, strongest first:

1. **Schema invariant (authoritative).** The partial unique index `uq_srvn_review_active_task (spot_id) WHERE status IN ('claimed','posted')` makes a second in-flight task for the same spot **impossible at the DB level** — even under a concurrent double-`run`.
2. **Claim-before-spend ordering.** `run` *first* inserts a `claimed` row (which trips the unique index if the spot is already in-flight → skip, **no vendor call**), and only then reserves budget and posts. So money is never committed for a spot we couldn't claim. A post that fails releases the budget and deletes the claim, leaving the spot retryable.
3. **Enqueue + queue hygiene (advisory).** `enqueue` skips spots with an active task (keeps `--dry-run` honest), and the queue is a Redis **set** so a spot can't sit in it twice.

Terminal states (`collected`, `error`) are *not* in the active set, so a spot becomes re-ingestable after a successful collect (subject to `REFRESH_DAYS`) or after `reset` clears an error/stuck claim.

---

## 4. Data model

### 4.1 `srvn_spot_reviews` (new table — companion §1 is authoritative)

`SoftDeleteModel` base (gives `created_at/updated_at/deleted_at` via the mixin). Columns:

| Column | Type | Notes |
|---|---|---|
| `id` | `BigInteger` PK autoincrement | |
| `spot_id` | `Integer` FK→`spots.id` `ON DELETE CASCADE`, indexed | |
| `source` | `String(32)` | e.g. `'dataforseo_google'` |
| `external_review_id` | `String(128)` | vendor's stable id — dedup key |
| `rating` | `SmallInteger` nullable | 1..5 |
| `text` | `Text` | review body, **PII-stripped at ingest** |
| `language_code` | `String(8)` nullable | |
| `published_at` | `TIMESTAMPTZ` nullable | vendor-provided |
| `source_rank` | `SmallInteger` | position in vendor sort order at fetch — records relevance order (used for snippet ordering later; **no longer an embed cutoff** since we embed all) |
| `content_hash` | `String(16)` | `sha256(text)[:16]` — dedup + future digest-skip |
| `embedding` | `Vector(1536)` nullable | **filled in this phase** — every ingested review is embedded (no per-spot cap) |
| `embedding_model` | `String(64)` nullable | |
| `embedding_updated_at` | `TIMESTAMPTZ` nullable | |
| `fetched_at` | `TIMESTAMPTZ` | |

**No reviewer-identity columns. No `owner_answer` column** — the omission is the compliance control (companion §7.2 / Appendix A "C4").

Constraints / indexes:
- `UNIQUE (spot_id, external_review_id)` — vendor-id dedup
- `UNIQUE (spot_id, content_hash)` — belt-and-suspenders text dedup
- `INDEX hnsw (embedding vector_cosine_ops)` — created now though unused (avoids a later index build on a populated table)
- `INDEX (spot_id) WHERE deleted_at IS NULL`

### 4.2 `srvn_review_ingest_tasks` (new table — in-flight task tracking)

> **Design decision to confirm (§11).** The async post→collect gap needs durable state for `{task_id, spot_id, reserved_cost_micros}`. Options: (a) a small DB table — durable across restarts, queryable in `status`, mirrors the `srvn_seed_grid_cells` checkpoint pattern; (b) a Redis hash — simpler but lost on flush and invisible to `status`. **Recommendation: the DB table** (a), for the same resumability reason the seeder uses one.

`Model` base (no soft-delete needed). Columns: `id` PK, `task_id String(128) unique nullable` (NULL while `claimed`, set on `posted`), `spot_id` FK→spots, `provider_id String(255)`, `depth SmallInt`, `sort_by String(16)`, `reserved_cost_micros BigInt nullable`, `status String(16)` (`claimed | posted | collected | error`), `claimed_at` / `posted_at` / `collected_at TIMESTAMPTZ nullable`, `error Text nullable`, `retry_count SmallInt default 0`.

Indexes:
- Partial index on `status='posted'` for the collector's hot query.
- **`uq_srvn_review_active_task` — partial UNIQUE on `(spot_id) WHERE status IN ('claimed','posted')`.** This *is* the double-post guard, enforced in the schema: a spot can have **at most one in-flight task**, so no second `run` can ever post (and pay for) it again. See §3a.

### 4.3 `srvn_spot_taste_features` — additive columns (same migration)

All nullable, **no backfill** (companion §1). Add the **full** future set now so the deferred summarizer PR needs no migration; **this plan only writes** `reviews_count` + `reviews_ingested_at`:

`+ reviews_count INT`, `+ reviews_ingested_at TIMESTAMPTZ` *(written by ingestor)*; `+ review_digest_text TEXT`, `+ review_digest_json JSONB`, `+ top_review_snippets JSONB`, `+ review_digest_model String(64)`, `+ review_corpus_hash String(16)`, `+ review_digest_updated_at TIMESTAMPTZ` *(written by the deferred summarizer)*.

### 4.4 Migration

One Alembic revision, `down_revision = "b7c2e9d4a1f3"` (current head — re-check with `flask db heads` at build time). Pattern mirrors `f3e1c9a7b8d6_create_srvn_taste_tables.py`:
- `op.execute("CREATE EXTENSION IF NOT EXISTS vector")` (idempotent; already present in prod).
- `create_table` for both new tables.
- HNSW + partial + GIN indexes via raw `op.execute(...)` / `op.create_index(..., postgresql_using=...)` (Alembic has no first-class HNSW — emit raw SQL like the taste-tables migration). **Incl. the `uq_srvn_review_active_task` partial UNIQUE** on `srvn_review_ingest_tasks (spot_id) WHERE status IN ('claimed','posted')` — the double-post guard.
- `op.add_column` × the features columns.
- `downgrade()`: drop the two new tables + the added columns; **do not** drop the `vector` extension.

---

## 5. Config — env var vs module constant

**Rule (matches the codebase):** `config.py` holds **only** env-overridable, ops-tunable, boot-validated settings (the `_RAW = os.environ.get(...)` + `__init__` coercion pattern, with the positive-int validation loop). **Fixed values that never change per-environment live as module `_CONSTANTS`** in the file that uses them — precedent: `_BACKFILL_THRESHOLD`, `_DAY_COUNTER_PREFIX`, `_DAY_COUNTER_TTL_SECONDS` in `embedding_worker.py`. This keeps the `config.py` surface small and puts constants where they're read.

**In `config.py` (genuinely env-driven):**

| Var | Default | Purpose |
|---|---|---|
| `SRVN_REVIEW_INGEST_ENABLED` | **`false`** | Master gate; ops flips after creds + compliance sign-off. |
| `SRVN_DATAFORSEO_LOGIN` / `_PASSWORD` | `""` | HTTP Basic creds (secrets — must be env). Separate from Google + OpenAI keys. |
| `SRVN_DATAFORSEO_BASE_URL` | `https://api.dataforseo.com` | Sandbox override. |
| `SRVN_REVIEW_DAILY_BUDGET_USD` | `5.0` | Daily $ breaker → stored as `SRVN_REVIEW_DAILY_BUDGET_MICROS`. |
| `SRVN_REVIEW_INGEST_MAX_PER_SPOT` | `100` | **The single volume knob** — max reviews bought + stored + embedded per spot (avg ~77 actually fetched; spots with fewer give all they have). Raise + re-pull later for spots that matter — dedup means you only pay for the *new* reviews. |
| `SRVN_REVIEW_INGEST_PER_TICK` | `50` | Spots posted per tick. |
| `SRVN_REVIEW_REFRESH_DAYS` | `90` | Re-ingest staleness threshold. |

**OpenAI key split (project policy):** embeddings — including review embeddings — use **`OPENAI_API_KEY`**; non-embedding LLM calls (the deferred review summarizer) use **`OPENAI_API_CONVERSATIONAL_KEY`**. No review-specific key. *This phase makes only embedding calls, so it needs no key changes;* the conversational key is wired when the summarizer lands. (Since review text shares the embedding key rather than an isolated one, request **zero-retention at the OpenAI org/account level** for `OPENAI_API_KEY` to satisfy the design-doc §7 data-terms item.)

**Module constants in `review_vendor_client.py` (fixed, not per-env):** `_PRIORITY = 1` (standard queue; `2` doubles cost — assert in a test), `_SORT_SEED = "relevant"` / `_SORT_REFRESH = "newest"`, `_COST_PER_10_USD = 0.00075` / `_COST_SETUP_USD = 0.0` (vendor list price — update in code if pricing changes), `_DEPTH_STEP = 10`, `_DEPTH_MAX = 4490`, `_SOURCE = "dataforseo_google"`, `_ALLOWED_SORTS`, and the `srvn:review:*` Redis key prefixes/TTLs.

**Dropped from the companion plan's §6 list** (per design review): `SRVN_REVIEW_VENDOR` (single vendor — hardcode until a second impl exists), `SRVN_REVIEW_EMBED_MAX_PER_SPOT` + `_HEAD` (redundant — `INGEST_MAX` already bounds it), `SRVN_REVIEW_EMBED_ENABLED` (embed whenever rows are un-embedded; gated transitively by ingest). **Deferred to their own phases:** `SRVN_GPT_5_MINI_MODEL` (reuse the existing LLM — today `gpt-4o-mini`), `SRVN_REVIEW_TOP_SNIPPETS`, `SRVN_INTENT_REVIEW_RAG_ENABLED`, `SRVN_INTENT_REVIEW_TOPK`.

---

## 6. New files

```
ressy_backend/models/srvn_spot_review.py            # SrvnSpotReview
ressy_backend/models/srvn_review_ingest_task.py     # SrvnReviewIngestTask (§4.2)
ressy_backend/services/srvn_taste_graph/
    review_vendor_client.py   # ReviewVendorClient Protocol + DataForSEOClient + VendorReview/ReviewTask/ReviewCollectResult dataclasses (companion Appendix A — paste-ready)
    review_ingestor.py        # ReviewSpendLedger + enqueue/pop + post_tick + collect_tick + dedup upsert + PII strip
ressy_backend/commands/srvn_review_ingest_command.py # srvn-reviews AppGroup
tests/srvn_backend/services/srvn_taste_graph/
    test_review_vendor_client.py
    test_review_ingestor.py
tests/srvn_backend/commands/test_srvn_review_ingest_command.py
tests/srvn_backend/test_srvn_review_ingestion_migration.py
```

The vendor client + `ReviewSpendLedger` are given essentially paste-ready in companion **Appendix A** — adapt identifiers, don't redesign.

---

## 7. Modified files

| File | Change |
|---|---|
| `ressy_backend/config.py` | Add the §5 vars (class `_RAW` + `__init__` coercion, reuse the int-validation loop). |
| `ressy_backend/tasks.py` | Add **one** thin wrapper `srvn_embed_spot_reviews()` (`with scheduler.app.app_context():` → the review-embed sweep). **No ingest/collect job wrappers** — those run only from the CLI. Structured end-of-tick log line (rows embedded / skipped / tokens). |
| `ressy_backend/app.py` (scheduler block, ~229–340) | Register **only** `srvn_embed_spot_reviews` inside the `START_SCHEDULER` gate, `if not scheduler.get_job(...)` idempotent guard (`interval` 15m, `max_instances=1`, `coalesce=True`). No enable flag — it no-ops when there are no NULL-embedding rows. |
| `ressy_backend/app.py` (CLI block, ~554–562) | `app.cli.add_command(srvn_review_cli)`. |
| `ressy_backend/models/__init__.py` | Export the two new models so Alembic autogenerate + app import see them (match how existing srvn models are exported). |

**PII enforcement + field mapping** (from the live `task_get` schema). `DataForSEOClient._serialize_review` maps each `result[].items[]` entry → `VendorReview`, reading **only**:

| `srvn_spot_reviews` | DataForSEO `items[]` field |
|---|---|
| `external_review_id` | `review_id` |
| `text` | `review_text` (prefer `original_review_text` when non-null) |
| `language_code` | `original_language` |
| `rating` | `rating.value` (it's an **object**, not a flat field) |
| `published_at` | `timestamp` — **parse with `strptime("%Y-%m-%d %H:%M:%S %z")`, NOT `fromisoformat`**: DataForSEO emits `"2024-05-05 14:09:32 +00:00"` (space before the offset), which `fromisoformat` rejects |
| `source_rank` | `rank_absolute` (authoritative position, not an enumerate index) |

**Explicitly dropped** (PII / noise): `profile_name`, `profile_url`, `profile_image_url`, `review_url`, `local_guide`, the reviewer's own `reviews_count`/`photos_count`, `owner_answer`/`original_owner_answer`/`owner_*`, and `images[]`. The **spot-level** `result[]` also returns `reviews_count` (Google's true total) + `cid` — store `reviews_count` on the features row (useful for "raise the cap later" decisions). Tests assert: no reviewer identity / no `owner_answer` stored, the timestamp parses correctly, and no credential leaks in logs.

---

## 8. The `srvn-reviews` CLI (the "get reviews now" lever)

Mirror `srvn_seed_spots_command.py` (`AppGroup` + `@with_appcontext`, gate on `SRVN_REVIEW_INGEST_ENABLED`):

- `enqueue` — push `(spot_id, provider_id)` onto `srvn:review:ingest_queue`. **`spot_id` is the primitive** — the queue is spot-keyed, and the deferred auto-enqueue hook (intent endpoint) will push spot_ids too, so the manual path matches where this is going. *(No `--bbox`/`--region`: spots have no region column, geographic selection is just sugar that resolves to ids, and you can produce any id list with your own `SELECT`.)*
  - `--spot-ids <csv | @file>` — the spots to ingest. You choose them however you like (a popularity `SELECT`, the seeder's region cells, etc.).
  - `--limit <N>` (optional convenience) — enqueue the first N *eligible* spots in **stable `id` order** (no quality ranking — see note) so a bulk seed doesn't mean pasting hundreds of ids.
  - `--dry-run` — print which spots / how many *would* be enqueued, then stop. **No queue write.** Preview the set + implied cost before any paid `run`.
  - `--force` — re-enqueue even if `reviews_ingested_at` is fresh (deliberate re-ingest); mirrors `srvn-seed --force`.
  - **Eligibility filter** applied to whatever is enqueued (the money-saver): skip null `provider_id`; skip spots with an **in-flight task** (`claimed`/`posted`); and — unless `--force` — skip spots with `reviews_ingested_at` newer than `SRVN_REVIEW_REFRESH_DAYS`. (Advisory only — the authoritative double-post guard fires again at `run`, §3a.)

> **Why `--limit` doesn't rank by rating:** `Spot.rating` is a weak signal (a 5.0 with 3 ratings outranks a 4.6 with 4,000) and biases toward *thinly-reviewed* spots — the opposite of what's worth buying reviews for. The real "popularity" signal is review *volume* (Google `user_rating_count`, which would need extracting from `Spot.info`). Rather than bake a bad proxy in, `--limit` stays neutral; pick a meaningful set with `--spot-ids` + your own query.
- `run [--max-spots N]` — **the only way to POST** vendor tasks. Per spot: **claim** (skip if already in-flight — §3a double-post guard) → reserve → post → mark `posted`. Stops at budget. A human runs it.
- `collect [--watch]` — **the only way to COLLECT**: drain ready tasks → reconcile → upsert. Re-runnable; `--watch` polls until all `posted` tasks are drained.
- `embed [--max N]` — manual drain of `srvn_spot_reviews WHERE embedding IS NULL` (same work as the scheduled job). Escape hatch for when the scheduler is down (§10) or for a tight dev loop.
- `status` — queue depth, `srvn_review_ingest_tasks` by status, today's `srvn:review:spend` vs budget, `srvn_spot_reviews` row count + spots-with-reviews + **un-embedded count**.
- `reset --kind error|stuck|all` — clear `error` tasks and **stuck in-flight** ones (a `claimed` row that never posted, or a `posted` row never collected) so their spots leave the active set and can be re-ingested (mirrors `srvn-seed reset`).

This lets the seed run **entirely by hand**: `enqueue --limit 500` (or `--spot-ids @ids.txt`) → `run` (posts) → wait ~45m → `collect` → (`embed` or let the scheduled job catch up) → `status`.

---

## 9. Tests (scoped to ingestion; companion §10 is the superset)

- `test_review_vendor_client.py` — patch DataForSEO HTTP; assert: PII strip (no reviewer identity, no `owner_answer`), `priority=1` pinned, `depth` clamped `[10,4490]` + rounded up to ×10, `sort_by` validated, `source_rank` preserved in fetch order, reserve/reconcile micro-USD math, missing-creds raises, no creds in logs.
- `test_review_ingestor.py` — dedup on `external_review_id` **and** `content_hash`; `INGEST_MAX_PER_SPOT` cap; `SRVN_REVIEW_INGEST_ENABLED=false` short-circuits `post_tick`; reserve-at-post **budget halt** (tiny budget → stops posting, no further task); `reconcile` trues the day key down to actual; `release` on post error; `reviews_count`/`reviews_ingested_at` set on the features row; pending-task lifecycle `posted → collected` survives a simulated restart (resumability).
- `test_review_double_post_guard.py` — **§3a:** a spot with a `claimed`/`posted` task is **not re-posted** (the claim insert conflicts on `uq_srvn_review_active_task` → skip, zero vendor calls, zero spend); a second concurrent claim loses cleanly; a failed post releases budget + deletes the claim (spot re-claimable); `reset` moves a stuck `claimed`/`posted` out of the active set so the spot can be re-ingested.
- `test_review_embed_sweep.py` — embeds `embedding IS NULL` rows, batch ≤96, `CURRENT_EMBEDDING_MODEL` stamped, token-budget breaker honored, dedicated-key path used, re-run is a no-op (drains to empty).
- `test_srvn_review_ingest_command.py` (`@pytest.mark.api`) — `enqueue` populates the queue; `run`/`collect`/`embed` drive the library functions with a mocked vendor + embedding client; `status` reports sane counts.
- `test_srvn_review_ingestion_migration.py` (`@pytest.mark.api`) — `upgrade head` then `downgrade -1`: both new tables (incl. `source_rank`, HNSW index) + the features columns present/absent.

Use `fakeredis` (per `tests/conftest.py`) for the ledger/queue; `@pytest.mark.api` + `TEST_DATABASE_URL` for DB-touching tests; mock the vendor HTTP — **never** hit DataForSEO in CI.

---

## 10. Verification

The §9 unit tests are the automated gate; these are the manual end-to-end checks, in build order.

1. **Client smoke (PR-2, sandbox).** Set `SRVN_DATAFORSEO_BASE_URL=https://sandbox.dataforseo.com` (confirmed sandbox host — and `task_get/00000000-0000-0000-0000-000000000000` returns a full dummy review payload, free, for building the serializer). Instantiate `DataForSEOClient` directly (throwaway script / `flask shell`) against one real `Spot.provider_id`; `post_reviews_task` → `collect_reviews_task`. **Go/no-go first: confirm a `ChIJ…` `place_id` post actually returns reviews** (the Reviews endpoint leans on `cid`; if place_id is flaky, switch to the `place_id→cid` via My Business Info fallback — §11.2). Then assert: auth works, response maps to `VendorReview`, **the dataclass exposes only rating/text/lang/time/rank — no author, no `owner_answer`**, cost fields populate, `source_rank` is monotonic in fetch order. No DB. *(Sandbox returns instantly; a real-key smoke posts then collects ~45 min later.)*

2. **Migration (PR-1).** `flask db upgrade`; `\d srvn_spot_reviews` shows the HNSW index + **both** unique constraints; `\d srvn_review_ingest_tasks` present; the features columns present. `downgrade -1` cleanly reverses (extension stays).

3. **Pipeline smoke (PR-4, sandbox or staging key).** `enqueue` ~5 known Toronto spots → `run` → `collect` → `status`. Confirm rows stored, PII-free at the DB (no reviewer columns even exist), `reviews_count`/`reviews_ingested_at` set on the features row.

4. **Budget breaker — the load-bearing check.** Set a tiny `SRVN_REVIEW_DAILY_BUDGET_USD`; `enqueue` more spots than it allows; `run`. Assert it posts up to the budget and **halts mid-batch** — it does *not* post the task that would breach, and does *not* keep posting against a day key that still reads "unspent" because rows haven't arrived (the failure mode the reserve-at-post design exists to prevent). Then `collect` and assert `reconcile` trues the day key **down** to the real charge (actual ≤ reserved). `status` shows spend at/under budget throughout.

5. **Resumability.** Between `run` and `collect`, kill the process. The in-flight tasks sit in `srvn_review_ingest_tasks` (status `posted`); a later `collect` still drains them and reconciles. (This is the whole reason the tracking table is a DB table, not Redis.)

6. **Dedup.** Re-`run` + re-`collect` the same spot → `srvn_spot_reviews` row count is unchanged (both `(spot_id, external_review_id)` and `content_hash` uniques hold).

7. **Embedding (scheduled job, or `srvn-reviews embed`).** After ingest, un-embedded count is >0; run the embed sweep (CLI drain, or let the 15m job tick if the scheduler is up); assert `embedding` non-null + `embedding_model` stamped on the rows, the daily token counter moved, and the **dedicated** review key was used (not the taste key). Re-running embeds nothing new (NULL-as-queue drains to empty). **Note:** the prod scheduler is currently down (the taste-embed backlog is frozen for the same reason) — so until that's fixed, drive embedding with `srvn-reviews embed`.

---

## 11. Open decisions (resolve while building)

1. **Pending-task store** — DB table (recommended, §4.2) vs Redis hash. DB wins on resumability + `status` visibility.
2. **`provider_id` / `place_id`** — ✅ **RESOLVED.** The `task_post` spec lists `place_id` as a **first-class accepted identifier** (required if no `cid`/`keyword`; example `GhIJ…`), and all 5,766 spots carry a `ChIJ…` place_id — so we post by `place_id` directly, no `cid` mapping. The enqueue filter still guards `provider_id IS NOT NULL`. (Sanity-check the first sandbox call returns reviews; the `place_id → cid` via **My Business Info** path remains a fallback for any individual id that fails — it also returns `reviews_count`, the better `--limit` signal than `Spot.rating`.)
3. **`location_name` / `language_name`** — ✅ **RESOLVED.** DataForSEO docs: both are **required** (or their `_code`/`_coordinate` equivalents). They set the Google scrape locale, **not** the business (the `place_id` does that), so they are **static request config, not per-spot**. They live as **module constants in `review_ingestor.py`** — `_DEFAULT_LOCATION_NAME = "Toronto,Ontario,Canada"`, `_DEFAULT_LANGUAGE_NAME = "English"` — **not** `config.py` env vars (per the §5 rule: fixed values go in the file that uses them). The vendor client keeps them as plain params (stays location-agnostic); the ingestor supplies the defaults. Promote to a per-batch `--location` CLI arg (and maybe config) only when multi-metro arrives. The only per-spot field the pipeline reads is `provider_id`.
4. **Collect mechanism** — ✅ **CONFIRMED, with a correction.** We persist `task_id`, so `collect` calls **`task_get/{id}` directly** for each `status='posted'` row — and that works for **30 days** (task_get is *free*; you're charged only at `task_post`). The `tasks_ready` list (free; ≤1000 ids/call, 20/min) only holds tasks completed in the **last 3 days**, so it's an *optional* readiness filter (avoid task_get-ing not-yet-ready tasks), **not** our source of truth. **Net collect window is 30 days, not 3** — because we drive off our own task_id list, not `tasks_ready`. Webhooks (`postback`/`pingback`) stay a later optimization (only needed >1000 tasks/min).
5. **Seed depth** — `INGEST_MAX_PER_SPOT=100` (set from real data: ~$33 to cover all 5,766 spots, ~3 GB vectors). With `sort_by=relevant` the first 100 are the most useful reviews anyway. Raise + re-pull later for spots that matter; dedup means you only pay for the new ones. Actual charge reconciles to reviews returned.

---

## 12. Rollout / PR breakdown (one ticket per PR)

1. **PR-1 — migration + models (dark).** `srvn_spot_reviews` + `srvn_review_ingest_tasks` + features columns; both models; migration test. No behavior change.
2. **PR-2 — config + vendor client.** `SRVN_REVIEW_*`/`SRVN_DATAFORSEO_*`; `review_vendor_client.py`; `test_review_vendor_client.py` (mocked HTTP, sandbox-verified). Still nothing runs.
3. **PR-3 — ingestor + ledger + scheduled embed.** `review_ingestor.py` (ledger, queue pop, `post_tick`/`collect_tick`, dedup, PII strip) as **library functions** (no scheduler wiring — the CLI calls them); the review-embed sweep + its **single** scheduled job (`tasks.py` wrapper + `app.py` registration); `test_review_ingestor.py` + embed test. Nothing posts vendor tasks yet (no CLI).
4. **PR-4 — CLI.** `srvn-reviews` group (`enqueue/run/collect/embed/status/reset`) + registration + `test_srvn_review_ingest_command.py`. After this, a human can seed Toronto end-to-end behind the enabled flag.

Then (ops, not a PR): obtain DataForSEO creds + compliance sign-off → set `SRVN_REVIEW_INGEST_ENABLED=true` → seed Toronto **by hand via the CLI** → watch budget. (Ingestion never runs unattended.)

**Deferred follow-on plans (separate tickets, separate PRs):** review summarizer (digest + `top_review_snippets`); `review_rag.py` + `/spots/recommend-by-intent` wiring. Both read the table this plan fills + embeds; neither blocks it.

---

## Cost sketch for a manual Toronto seed

DataForSEO standard ≈ **$0.075 / 1,000 reviews**. Computed from real `user_rating_count` data (all 5,766 spots have it; total 3.76M reviews, avg 652 / median 237 per spot):

| `INGEST_MAX_PER_SPOT` | reviews fetched | vendor cost (all spots) | ~vector storage |
|---|---|---|---|
| **100 (default)** | **442k** | **~$33** | **~3 GB** |
| 200 | 789k | ~$59 | ~5 GB |
| 500 | 1.53M | ~$114 | ~9 GB |
| uncapped | 3.78M | ~$284 | ~23 GB |

At cap 100 a spot that hits the cap costs **$0.0075**; avg ~77 reviews actually fetched/spot. Embedding those ~442k reviews adds only **~$1** in OpenAI — negligible; the real secondary cost is **vector storage (~3 GB)**, so check DB headroom before a full-corpus pull. The `$5/day` breaker paces it (~$33 ≈ a week; raise it for a one-shot). Dedup means raising the cap later only re-charges for *new* reviews.
