# srvn Phase 2 — Vendor review ingestion + per-review RAG substrate

_Date: 2026-06-07 · Status: partially shipped — offline ingestion + summarizer done (PRs #197–208); **per-review RAG superseded** · Branch target: TBD (own ticket)_

> ⚠️ **Superseded (2026-07-01):** the **per-review** vector-search mechanism in this doc —
> `review_rag.py` (§2), `srvn_embed_spot_reviews` (§4), Stage-4 per-review RAG (§5), the
> `EMBED_MAX` config rows (§6), and the `srvn_spot_reviews.embedding`/HNSW schema (§1) — is
> **replaced** by a single spot-level `review_digest_embedding` (+ structured `review_noise`)
> on `srvn_spot_taste_features`, built by the summarizer. Per-review vectors were the
> storage/compute sink (~2.5 GB for Toronto vs. ~35 MB spot-level). See
> [`spot-digest-embedding-supersedes-per-review-rag.md`](./spot-digest-embedding-supersedes-per-review-rag.md).
> The vendor ingestion, dedup, spend breaker, and offline **digest+snippets** parts of this
> doc still stand.

## What this plan is

The substrate that powers review-grounded answers in **`POST /spots/recommend-by-intent`** (Phase 2). It defines where review text comes from, how it's turned into retrievable + summarizable data offline, and how the intent endpoint consumes it at request time.

It is the **review half** of the request-time AI pipeline. The endpoint mechanics (intent parse, query embed, candidate retrieval, scoring `s_query_match`, SSE rerank/explain) live in the companion **[`request-time-ai-pipeline.md`](./request-time-ai-pipeline.md)**; the data foundation lives in **[`srvn-user-taste-graph.md`](./srvn-user-taste-graph.md)** (Phase 1, shipped). Sourcing strategy / cost framing lives in **[`places-sourcing-recommendation.md`](./places-sourcing-recommendation.md)**.

> **Supersedes** the companion plan's assumption (its §"What gets PRECOMPUTED") that `top_review_snippets` come from "Internal + OpenTable reviews." srvn will **not** collect first-party reviews; review text is **purchased from a third-party vendor**. The companion plan's `top_review_snippets` field is produced by _this_ pipeline.

## Decisions this plan encodes (settled)

1. **No first-party reviews.** srvn does not collect user reviews. (The legacy `Review` model + `POST /spots/{id}/reviews` are unused; not the direction.)
2. **Buy, don't scrape.** Review text comes from a data vendor — **DataForSEO** (Google Reviews under the Business Data API), chosen over Outscraper / SerpApi / Apify / Bright Data / HasData / SearchApi / Scrapingdog after a full vendor sweep (see §14 + Appendix A). Not a self-hosted Google scraper (ToS + Maps-project-ban risk).
3. **Reviews are for the intent endpoint only.** They never enter the vocabulary-bounded `taste_text` embedding that powers `/spots/recommended` (compliance — see Phase 1 §7b/§8).
4. **Embed each review individually** (one vector per review, chunk only if long) — not one averaged vector per spot. Averaging destroys retrieval precision.
5. **Summarize with our own LLM**, not Google's `reviewSummary`. Google's summary only covers Google's ≤5 reviews; it cannot see the purchased corpus, and we need a structured digest shaped to our intent dimensions.
6. **All heavy work is offline.** Request time does only: embed the query, vector-search, and a tight LLM synthesis on already-curated text. The LLM never re-reads raw reviews at request time.

## Naming

All new tables, columns, services, files, jobs, and config use the `srvn_` prefix (project rule). Existing `ressy_backend/` package path stays.

---

## Architecture at a glance

```
OFFLINE (APScheduler, gated by START_SCHEDULER, budgeted)
  srvn_ingest_spot_reviews     vendor API → raw reviews (PII-stripped)  → srvn_spot_reviews
  srvn_embed_spot_reviews      each review → vector(1536)               → srvn_spot_reviews.embedding
  srvn_summarize_spot_reviews  our LLM over the corpus → digest+snippets→ srvn_spot_taste_features

REQUEST TIME (/spots/recommend-by-intent — companion plan owns the endpoint)
  1B query embed  →  2 candidate recall (taste-graph+geo)
                  →  RAG: pgvector search srvn_spot_reviews per candidate → top-k snippets
                  →  LLM rerank+explain on (digest + snippets)   [Stage 4, streamed]
  First paint (Stage 3) uses the PRECOMPUTED top_review_snippets — no per-request RAG needed for paint.
```

Why this shape: the vendor purchase and LLM digest are the expensive parts and they happen **once per spot** (refreshed only when the review set changes). Request time touches only small, curated text, preserving the companion plan's p50 ≤ 500ms first-paint budget.

---

## 1. Data model (new Alembic revision)

### `srvn_spot_reviews` (1:many with spots) — raw purchased reviews + per-review vector

```
id                  BIGINT PK
spot_id             INT FK→spots.id ON DELETE CASCADE, indexed
source              String(32)    vendor+origin, e.g. 'dataforseo_google'
external_review_id  String(128)   vendor's stable review id (dedup key)
rating              SmallInt      nullable (1..5)
text                Text          review body, PII-stripped at ingest
language_code       String(8)     nullable
published_at        TIMESTAMPTZ   nullable (vendor-provided)
source_rank         SmallInt      position in the vendor's sort order at fetch (relevance rank when
                                  sort_by=relevant); lets the embed worker apply SRVN_REVIEW_EMBED_MAX_PER_SPOT
                                  by relevance instead of by insertion order
content_hash        String(16)    sha256(text)[:16] — dedup + digest-skip input
embedding           vector(1536)  per-review vector; nullable; filled by embed worker
embedding_model     String(64)    same constant as taste graph (§7 Phase 1)
embedding_updated_at TIMESTAMPTZ  nullable
fetched_at          TIMESTAMPTZ
created_at, updated_at, deleted_at  (SoftDeleteModel)

UNIQUE (spot_id, external_review_id)              -- vendor-id dedup
UNIQUE (spot_id, content_hash)                    -- belt-and-suspenders text dedup
INDEX hnsw (embedding vector_cosine_ops)          -- RAG retrieval
INDEX (spot_id) WHERE deleted_at IS NULL
```

- **No author identity stored.** We deliberately drop reviewer name/handle/profile at ingest (compliance + we don't need it). We also drop the business's `owner_answer` reply — it's marketing voice and would pollute the per-review embedding if folded into `text`. Keep only rating/text/time/language (+ `source_rank`).
- One vector per row. Long reviews (> ~400 tokens) are split into chunks at embed time into additional rows with a `chunk_index` (deferred unless review length distribution warrants it — most are short).

### `srvn_spot_taste_features` (existing, extend) — precomputed request-time-read fields

```
+ review_digest_text     Text         our-LLM structured digest of the corpus (~200–400 chars)
+ review_digest_json     JSONB        structured: {vibe, noise, service, dietary_notes,
                                       occasion_fit, standout_dishes[]}
+ top_review_snippets    JSONB        N curated snippets for first paint (companion plan's field):
                                       [{text, rating, published_at}]  (PII-free)
+ review_digest_model    String(64)   LLM id that produced the digest
+ review_corpus_hash     String(16)   hash over the spot's review content_hashes; digest-skip key
+ reviews_count          INT          # reviews held for this spot
+ reviews_ingested_at    TIMESTAMPTZ  last successful vendor pull
+ review_digest_updated_at TIMESTAMPTZ
```

Putting the request-time-read fields on the existing features sidecar means the companion plan's Stage-2 JOIN already returns them — no extra query for first paint. Raw text + vectors stay in `srvn_spot_reviews`, off the hot path except for the RAG vector search.

**Backfill**: none required — fields default NULL; spots get populated lazily (see ingestion trigger). **Rollback**: drop `srvn_spot_reviews`; drop the added columns. Do not drop the `vector` extension.

---

## 2. New files

```
ressy_backend/models/srvn_spot_review.py                 # SrvnSpotReview ORM
ressy_backend/services/srvn_taste_graph/
    review_vendor_client.py     # ReviewVendorClient Protocol + DataForSEOClient (two-phase post/collect), PII strip — see Appendix A
    review_ingestor.py          # vendor → srvn_spot_reviews, dedup, cap, budget
    review_summarizer.py        # our-LLM digest + top_review_snippets selection (+ writes review_digest_embedding, see superseding doc)
    review_rag.py               # SUPERSEDED — not built; replaced by spot-level review_digest_embedding
tests/srvn_backend/services/srvn_taste_graph/
    test_review_vendor_client.py
    test_review_ingestor.py
    test_review_summarizer.py
    test_review_rag.py
tests/srvn_backend/api/test_srvn_recommend_by_intent_reviews.py
tests/srvn_backend/services/srvn_taste_graph/test_review_embed_worker.py
```

## 3. Modified files

| File                                                                                 | Change                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ressy_backend/services/srvn_taste_graph/embedding_client.py`                        | Reuse as-is for review vectors (batch ≤96). Tag `metadata={"surface":"srvn_review_embed"}` for billing attribution distinct from taste/query embeds.                                                                                                             |
| `ressy_backend/tasks.py`                                                             | Add `srvn_ingest_spot_reviews`, `srvn_embed_spot_reviews`, `srvn_summarize_spot_reviews` jobs (cadences below). Mirror the existing `with scheduler.app.app_context():` pattern.                                                                                 |
| `ressy_backend/app.py:176-244`                                                       | Register the 3 jobs inside the `START_SCHEDULER` gate.                                                                                                                                                                                                           |
| `ressy_backend/config.py`                                                            | Add the `SRVN_REVIEW_*` flags (below).                                                                                                                                                                                                                           |
| `ressy_backend/routes/spot.py` (or the new intent blueprint from the companion plan) | In `/spots/recommend-by-intent`: after candidate recall, call `review_rag.retrieve_snippets(query_vec, candidate_spot_ids)`; pass `review_digest_json` + retrieved snippets into the rerank/explain prompt. First paint reads precomputed `top_review_snippets`. |
| `pyproject.toml`                                                                     | No new dep — DataForSEO is plain REST + HTTP Basic via `requests` (already transitive).                                                                                                                                                                          |

---

## 4. Worker jobs (APScheduler, gated by `START_SCHEDULER`)

### `srvn_ingest_spot_reviews` — **demand-driven + capped** (interval 30m, processes a queue)

Do **not** bulk-buy reviews for every spot — that's the budget sink (see places-sourcing doc: enrichment dominates cost). Ingest only spots that matter:

- **Trigger**: a spot is enqueued for review ingestion when it (a) appears in an intent-endpoint candidate set, or (b) is among the top-N by popularity in an actively-queried metro, and (c) has `reviews_ingested_at IS NULL` or older than `SRVN_REVIEW_REFRESH_DAYS`.
- **Two-phase (DataForSEO is async).** Per tick, pop up to `SRVN_REVIEW_INGEST_PER_TICK` spots (Redis set `srvn:review:ingest_queue`) and `post_reviews_task` each at `depth = SRVN_REVIEW_INGEST_MAX_PER_SPOT`. Results land ~45 min later (standard queue); a collector step polls `tasks_ready` / handles the `postback_url` and `collect_reviews_task`s them. Don't block the tick on collection.
- **`sort_by` by phase**: seed pulls use `SRVN_REVIEW_SORT_SEED` (`relevant` — richest digest + RAG fodder for the one-time corpus); refresh pulls use `SRVN_REVIEW_SORT_REFRESH` (`newest` — clean delta append). Dedup keys make both idempotent.
- **Budget breaker — reserve-at-post, reconcile-at-collect (does NOT naively mirror §6.2).** Cost is committed at `task_post`, minutes before rows land, so the synchronous taste-embed "commit-then-INCRBY" pattern would let a tick post many tasks against a day key that still reads unspent. Instead `ReviewSpendLedger.reserve(max_cost)` debits the depth-based **maximum** into `srvn:review:spend:{YYYY-MM-DD}` at post (rolling back + halting the tick if it would breach `SRVN_REVIEW_DAILY_BUDGET_USD`), `release()` returns the reservation when a task errors, and `reconcile(reserved, actual)` trues up to the real charge from the `task_get` response. Plus `SRVN_REVIEW_INGEST_ENABLED` short-circuit + structured end-of-tick log line.
- **Standard queue, pinned.** Post with `priority = SRVN_REVIEW_PRIORITY` (default `1`); `priority=2` doubles the bill for ~1-min latency an offline queue doesn't need. Assert it in a test.
- **Store**: PII-strip (drop reviewer identity + `owner_answer`) → dedup on `(spot_id, external_review_id)` and `content_hash` → insert, preserving `source_rank` (vendor sort order). Set `reviews_ingested_at`, `reviews_count` on the features row.

### `srvn_embed_spot_reviews` — (interval 15m, budgeted) — ⚠️ SUPERSEDED

> Per-review embedding is dropped (see the superseding doc). A shipped manual sweep
> `refresh_review_embeddings` exists but is being retired; embeddings move to a single
> spot-level `review_digest_embedding` written by the summarizer. Ignore this section.

- Pull `srvn_spot_reviews` rows where `embedding IS NULL OR embedding_model != CURRENT_EMBEDDING_MODEL`, `embedding_updated_at NULLS FIRST`, capped per tick.
- **Embed cap is decoupled from ingest cap.** The candidate query ranks each spot's NULL-embedding rows by `source_rank` (relevance) and selects only those within `SRVN_REVIEW_EMBED_MAX_PER_SPOT` (or `…_HEAD` for high-popularity / high-query spots) — e.g. a `ROW_NUMBER() OVER (PARTITION BY spot_id ORDER BY source_rank)` filter. Text is ingested generously (cheap); vectors are the pgvector storage/index cost (~6 KB/vector → ~3 MB/spot at 500), so they're capped tighter. Rows beyond the cap keep their text (digest fodder + eligible if the cap later rises) and are simply never selected for embedding — no sentinel, no churn.
- Reuse `embedding_client` (batch ≤96). Same Redis token budget pattern + `CURRENT_EMBEDDING_MODEL` version guard as the taste-embed worker. Write `embedding`, `embedding_model`, `embedding_updated_at`.
- Model migrations follow the Phase 1 §7a blue/green playbook (these vectors are subject to the same geometry constraint).

### `srvn_summarize_spot_reviews` — (cron daily 03:00 UTC, after ingest)

- For spots where `review_corpus_hash` (computed over the spot's current review `content_hash`es) differs from the stored value → run the LLM digest; else **hash-skip** (no LLM call).
- LLM (`SRVN_GPT_5_MINI_MODEL`, default a Haiku-tier model) over the corpus → write `review_digest_text`, `review_digest_json` (structured dimensions), `top_review_snippets` (the N most informative, PII-free), `review_digest_model`, `review_corpus_hash`, `review_digest_updated_at`.
- **Snippet selection** for `top_review_snippets`: rank by informativeness (length-normalized, dimension coverage), cap at `SRVN_REVIEW_TOP_SNIPPETS` (default 5). These are what first paint shows.
- Structured end-of-tick log line with rows seen / summarized / hash-skipped / tokens.

---

## 5. Request-time integration (`/spots/recommend-by-intent`)

The companion plan owns Stages 1–4. This plan adds the review steps:

- **First paint (Stage 3, ≤500ms):** read `top_review_snippets` + `review_digest_text` from the candidate features rows already joined in Stage 2. **No per-request RAG** — precomputed snippets are good enough for the card. Latency budget untouched.
- **Rerank + explain (Stage 4, streamed):** ⚠️ **SUPERSEDED** — no per-review RAG. Instead, the candidate recall does a spot-level cosine search that blends `taste_embedding` with `review_digest_embedding`, and the rerank/explain LLM is fed `intent + review_digest_json + top_review_snippets` (the precomputed digest/snippets). Grounding like "is it quiet enough for a first date?" comes from the digest's `vibe`/`occasion_fit` and the structured `review_noise`, not query-matched per-review vectors. See the superseding doc. _(Original text: `review_rag.retrieve_snippets(query_vec, candidate_ids, …)` over `srvn_spot_reviews.embedding` — retired.)_
- **Query embedding** is the companion plan's existing 1B (`embed_query`, Redis-cached). No new query-side embedding.

What request time never does: read raw review corpora, average vectors, or call the vendor.

---

## 6. Config (`SRVN_REVIEW_*`, all srvn\_-prefixed)

| Var                                                  | Default                      | Purpose                                                                                    |
| ---------------------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------ |
| `SRVN_REVIEW_INGEST_ENABLED`                         | **false**                    | Lands dark; ops flips after vendor contract + budget set.                                  |
| `SRVN_REVIEW_VENDOR`                                 | `"dataforseo"`               | Which `ReviewVendorClient` impl to instantiate (was `outscraper`; see §14).                |
| `SRVN_DATAFORSEO_LOGIN` / `SRVN_DATAFORSEO_PASSWORD` | `""`                         | DataForSEO HTTP Basic creds (separate from Google + OpenAI keys).                          |
| `SRVN_DATAFORSEO_BASE_URL`                           | `https://api.dataforseo.com` | API host (override for sandbox/testing).                                                   |
| `SRVN_REVIEW_INGEST_MAX_PER_SPOT`                    | 500                          | **Text** cap — reviews bought + stored per spot (cheap).                                   |
| `SRVN_REVIEW_EMBED_MAX_PER_SPOT`                     | 200                          | **Vector** cap — rows embedded per spot (the pgvector cost).                               |
| `SRVN_REVIEW_EMBED_MAX_PER_SPOT_HEAD`                | 500                          | Adaptive vector cap for high-popularity / high-query spots.                                |
| `SRVN_REVIEW_PRIORITY`                               | 1                            | DataForSEO queue: 1 = standard; 2 = priority (2× cost — avoid).                            |
| `SRVN_REVIEW_SORT_SEED`                              | `relevant`                   | Sort for the first/seed pull (richest digest + RAG fodder).                                |
| `SRVN_REVIEW_SORT_REFRESH`                           | `newest`                     | Sort for refresh pulls (clean delta append).                                               |
| `SRVN_REVIEW_INGEST_PER_TICK`                        | 50                           | Spots processed per ingest tick.                                                           |
| `SRVN_REVIEW_DAILY_BUDGET_USD`                       | (set per contract)           | Daily $ circuit breaker; reserved-at-post in `srvn:review:spend:{YYYY-MM-DD}`.             |
| `SRVN_REVIEW_COST_PER_10_USD` / `_SETUP_USD`         | `0.00075` / `0.0`            | DataForSEO standard list price the breaker reserves against (override if pricing changes). |
| `SRVN_REVIEW_REFRESH_DAYS`                           | 90                           | Re-ingest a spot's reviews when older than this.                                           |
| `SRVN_REVIEW_DIGEST_ENABLED`                         | false                        | Gate the summarizer job.                                                                   |
| `SRVN_GPT_5_MINI_MODEL`                           | `claude-haiku-4-5`           | Digest LLM.                                                                                |
| `SRVN_REVIEW_TOP_SNIPPETS`                           | 5                            | `top_review_snippets` count for first paint.                                               |
| `SRVN_REVIEW_EMBED_ENABLED`                          | false                        | Gate the review-embed worker.                                                              |
| `SRVN_REVIEW_EMBED_*_CAP`, token budget              | per Phase 1 §6.2             | Reuse the taste-embed guardrail knobs.                                                     |
| `SRVN_INTENT_REVIEW_RAG_ENABLED`                     | false                        | Gate request-time RAG (Stage 4).                                                           |
| `SRVN_INTENT_REVIEW_TOPK`                            | 3                            | Snippets retrieved per spot at rerank time.                                                |

---

## 7. Compliance (reopens Phase 1 §7b)

Purchased review text is **third-party free text** and going to an LLM (digest job + request-time rerank). Before `SRVN_REVIEW_INGEST_ENABLED=true`:

1. **Vendor licensing** — confirm the vendor's terms permit storing review text and deriving/serving summaries from it. This is the load-bearing legal question; the rest follows from it. (DataForSEO is permissive-by-omission but §7.2 of its ToS indemnifies _DataForSEO_ against upstream Google-ToS violations — so this stays a counsel sign-off, not a vendor guarantee. Every candidate scrapes Google, so the vendor contract is risk-allocation, not a copyright license; **Scrapingdog** is the one vendor whose terms _explicitly_ grant store + commercial-serve if firmer cover is needed. See §14.)
2. **PII strip at ingest** — drop reviewer name/handle/profile/photo; keep rating/text/time/language only. Enforce in `review_ingestor` with a test.
3. **Keep review text out of `taste_text`** — Phase 1 §8's vocabulary-bounded test still guards the taste embedding; review vectors are a _separate_ store.
4. **LLM data terms** — the digest + rerank calls send review text to OpenAI/Anthropic. Use a distinct API key, request zero-retention, and re-run the §7b checklist for the chosen provider.
5. **Privacy policy** — disclose third-party review processing if not already covered.

If item 1 can't be satisfied, the plan stops — there is no in-scope fallback that yields review volume (first-party is ruled out, scraping is out).

---

## 8. Cost model

- **Vendor** (dominant): **DataForSEO Google Reviews, standard queue ≈ $0.075 / 1,000 reviews** ($0.00075 per 10). Bounded by `INGEST_MAX_PER_SPOT` + the reserved-at-post daily $ breaker. **The cost driver is spot count × per-spot depth** (per-review price is negligible), so economize on both selection and the cap.

  **Measured cost for the actual Toronto corpus** (2026-06-28 — all 5,766 spots carry `user_rating_count`; total 3.76M reviews, avg 652 / median 237 per spot, max 28,651). Cost to ingest reviews for **every** spot, by per-spot cap:

  | `INGEST_MAX_PER_SPOT` | reviews fetched | vendor cost (all 5,766) | ~vector storage |
  |---|---|---|---|
  | **100** (current default) | 442k | **~$33** | ~3 GB |
  | 200 | 789k | ~$59 | ~5 GB |
  | 500 | 1.53M | ~$114 | ~9 GB |
  | uncapped | 3.78M | ~$284 | ~23 GB |

  The cap is a ceiling — spots with fewer reviews give all they have (avg ~77/spot actually fetched at cap 100). Dedup means raising the cap later only re-charges for *new* reviews. At ~$33 the whole corpus is cheap enough that full seeding is viable; the gating factor is **vector storage**, not dollars.
- **Digest LLM**: one Haiku-tier call per spot, hash-skipped when the corpus is unchanged. Amortized.
- **Review embeddings**: ~$0.0000016 each — negligible. The real cost of "more vectors" is **pgvector storage/index** (~6 KB/vector → ~3 MB/spot at 500 rows), which is exactly why `EMBED_MAX` (200) is capped tighter than `INGEST_MAX` (500).
- **Request time**: 1 cached query embed + 1 vector search + 1 rerank LLM call. Cheap per request.

The expensive, variable line is the vendor; everything else mirrors Phase 1's amortized, hash-skipped, budget-broken pattern.

## 9. Latency

Unchanged from the companion plan: first paint reads precomputed `top_review_snippets`/digest (no RAG in the ≤500ms path); RAG + rerank happen in the streamed Stage 4. The pgvector snippet search over candidate-filtered rows (HNSW) is ~tens of ms.

---

## 10. Tests (CI green — `poetry run pytest`)

- `test_review_vendor_client.py` — patch DataForSEO HTTP; assert PII strip (no reviewer identity, no `owner_answer` stored), `priority=1` pinned, `depth` rounded to a multiple of 10 and clamped ≤4490, `source_rank` preserved in fetch order, `sort_by` validated, reserve/reconcile micro-USD math, error → `release` path, no credential leakage in logs.
- `test_review_ingestor.py` — dedup on `external_review_id` and `content_hash`; `*_MAX_PER_SPOT` cap; `SRVN_REVIEW_INGEST_ENABLED=false` short-circuits; daily-budget halt; `reviews_count`/`reviews_ingested_at` set.
- `test_review_embed_worker.py` — embeds NULL-vector rows, **per-spot `source_rank` cap honored (`EMBED_MAX`, `_HEAD` override)**, batch ≤96, `CURRENT_EMBEDDING_MODEL` guard, token budget honored, `metadata` surface tag present.
- `test_review_summarizer.py` — hash-skip when `review_corpus_hash` unchanged (no LLM call); digest_json has the expected dimensions; `top_review_snippets` ≤ cap and PII-free; corpus-changed triggers re-summary.
- `test_review_rag.py` — pure-ish: given seeded review vectors, query vector retrieves the semantically-closest snippets per spot; respects `topk`; filters to candidate spot ids only.
- `test_srvn_recommend_by_intent_reviews.py` (`@pytest.mark.api`, real Postgres+pgvector) — seed two spots with divergent reviews (one "quiet/intimate", one "loud/lively"); intent "quiet date night" surfaces and explains the quiet spot using its snippets; `SRVN_INTENT_REVIEW_RAG_ENABLED=false` falls back to precomputed snippets only.
- `test_srvn_phase2_review_migration.py` — `upgrade head` + `downgrade -1`: `srvn_spot_reviews` (incl. `source_rank`) + the added features columns present/absent.

## 11. Verification

0. **Vendor smoke** (staging key): ingest reviews for ~50 Toronto spots; confirm rows stored, PII-free, deduped, `reviews_count` sane.
1. **Migration**: `flask db upgrade`; `\d srvn_spot_reviews` shows HNSW index; features columns present.
2. **Workers**: `START_SCHEDULER=true`; tail ingest → embed → summarize ticks; zero errors; `review_digest_text` + `top_review_snippets` populate; hash-skip fires on a second summarize tick.
3. **Endpoint**: divergent-review spots (verification step in tests) — intent query grounds the explanation in the correct snippets; first paint works with RAG disabled.
4. **Budget**: set a tiny `SRVN_REVIEW_DAILY_BUDGET_USD`; confirm the reserve-at-post breaker halts ingestion (no further task posted once a reservation would breach) and logs it; confirm `reconcile` trues the day key back down to the real charge after collection.

---

## 12. Rollout order

1. Migration + models (dark).
2. Vendor client + ingestor (`ENABLED=false`); land + test against staging key.
3. Embed worker + summarizer (`ENABLED=false`).
4. Flip ingest/embed/summarize on for a **single metro** (Toronto); watch budget + digest quality.
5. Wire request-time RAG into the intent endpoint (`SRVN_INTENT_REVIEW_RAG_ENABLED=true`) once digests/snippets exist for the candidate pool.
6. Expand metros as budget allows.

## 13. What NOT to do

- **Don't bulk-ingest every spot's reviews up front** — demand-driven only; the vendor bill is the whole risk.
- **Don't put review text in `taste_text`** — separate store; Phase 1 §8 test stays green.
- **Don't average a spot's reviews into one vector** — per-review (or per-chunk) only.
- **Don't use Google `reviewSummary`** as the digest — it can't see the purchased corpus.
- **Don't do RAG in the first-paint path** — precomputed snippets only; RAG is Stage 4.
- **Don't reuse the taste-graph / conversation OpenAI key** — separate key for review-derived calls (retention scoping + revocation).
- **Don't store reviewer identity** — rating/text/time/language only.

## 14. Open questions (resolve before building)

- ~~**Vendor choice**~~ — **RESOLVED: DataForSEO** (Google Reviews under the Business Data API). Chosen over Outscraper / SerpApi / Apify / Bright Data / HasData / SearchApi / Scrapingdog after a full sweep: cheapest credible per-review (~$0.075/1k standard, ~13–40× under Outscraper), direct `place_id` input, complete schema-mapping fields (`review_id` → `external_review_id`, `original_language` → `language_code`, `timestamp` → `published_at`), async queue + `postback`/`pingback` webhooks that fit the ingest worker, free sandbox, `depth` to 4,490. **Scrapingdog** is the documented fallback if licensing clarity dominates — it's the only vendor whose terms _explicitly_ license store + commercial-serve. **Compliance item 1 still needs counsel sign-off regardless of vendor** — all candidates scrape Google, so the vendor contract is risk-allocation, not a copyright license. **Dropped:** SerpApi (active Google DMCA suit, Dec 2025), Bright Data (`fid`-only input fights `place_id` accretion + mandatory KYC), HasData (no stable per-review id breaks the dedup key). See Appendix A for the adapter.
- **Refresh cadence** — is 90 days right, or event-driven (re-ingest on a popularity spike)?
- **Chunking** — measure review length distribution after first ingest; add per-chunk rows only if long reviews are common.
- **Companion-plan reconciliation** — patch `request-time-ai-pipeline.md`'s "Internal + OpenTable reviews" line to point at this pipeline.

---

## Appendix A — DataForSEO adapter (`review_vendor_client.py` + config + breaker)

The vendor wrapper and the divergences it forces on the workers. Five constraints
drove this shape; each is tagged `[C#]` where it lives:

|        | Constraint                                                        | Lives in                              |
| ------ | ----------------------------------------------------------------- | ------------------------------------- |
| **C1** | reserve-at-post / reconcile-at-get breaker                        | `ReviewSpendLedger` + ingest worker   |
| **C2** | pinned standard `priority=1`                                      | client default + config + a test      |
| **C3** | `relevant` seed / `newest` refresh                                | config + worker passes `sort_by`      |
| **C4** | drop `owner_answer` (no column for it)                            | `_serialize_review` omits it          |
| **C5** | split `INGEST_MAX` (text) vs `EMBED_MAX` (vectors), adaptive head | config + `source_rank` + embed worker |

**Why C1 can't mirror the §6.2 taste-embed breaker:** the embed worker is synchronous
(commit-then-`INCRBY` at collection). DataForSEO commits cost at `task_post`, minutes
before rows arrive — so spend is **reserved at post** (depth-based maximum) and
**reconciled at get** (real charge from the response). Debiting at row-insert time
would let a tick post many tasks against a day key that still reads unspent.

### Config (`ressy_backend/config.py`)

```python
# --- Phase 2 review ingestion (DataForSEO) ---------------------------------
SRVN_REVIEW_INGEST_ENABLED_RAW = os.environ.get("SRVN_REVIEW_INGEST_ENABLED", "false")
SRVN_REVIEW_VENDOR = os.environ.get("SRVN_REVIEW_VENDOR", "dataforseo")  # was "outscraper"
SRVN_DATAFORSEO_LOGIN = os.environ.get("SRVN_DATAFORSEO_LOGIN", "")
SRVN_DATAFORSEO_PASSWORD = os.environ.get("SRVN_DATAFORSEO_PASSWORD", "")
SRVN_DATAFORSEO_BASE_URL = os.environ.get("SRVN_DATAFORSEO_BASE_URL", "https://api.dataforseo.com")

# [C5] Split cap: buy text generously (cheap), vectorize stingily (pgvector is the cost).
SRVN_REVIEW_INGEST_MAX_PER_SPOT_RAW = os.environ.get("SRVN_REVIEW_INGEST_MAX_PER_SPOT", "500")
SRVN_REVIEW_EMBED_MAX_PER_SPOT_RAW = os.environ.get("SRVN_REVIEW_EMBED_MAX_PER_SPOT", "200")
SRVN_REVIEW_EMBED_MAX_PER_SPOT_HEAD_RAW = os.environ.get(  # adaptive headroom for hot spots
    "SRVN_REVIEW_EMBED_MAX_PER_SPOT_HEAD", "500")

# [C2] Standard queue. priority=2 doubles cost for latency an offline queue doesn't need.
SRVN_REVIEW_PRIORITY_RAW = os.environ.get("SRVN_REVIEW_PRIORITY", "1")
# [C3] Phase-dependent sort.
SRVN_REVIEW_SORT_SEED = os.environ.get("SRVN_REVIEW_SORT_SEED", "relevant")
SRVN_REVIEW_SORT_REFRESH = os.environ.get("SRVN_REVIEW_SORT_REFRESH", "newest")

# [C1] Daily $ breaker + the standard-queue list price it reserves against.
SRVN_REVIEW_DAILY_BUDGET_USD_RAW = os.environ.get("SRVN_REVIEW_DAILY_BUDGET_USD", "5.0")
SRVN_REVIEW_COST_PER_10_USD_RAW = os.environ.get("SRVN_REVIEW_COST_PER_10_USD", "0.00075")
SRVN_REVIEW_COST_SETUP_USD_RAW = os.environ.get("SRVN_REVIEW_COST_SETUP_USD", "0.0")
```

```python
# ...in Config.__init__, alongside the other _RAW → typed coercions:
self.SRVN_REVIEW_INGEST_ENABLED = self.SRVN_REVIEW_INGEST_ENABLED_RAW.lower() == "true"
self.SRVN_REVIEW_INGEST_MAX_PER_SPOT = int(self.SRVN_REVIEW_INGEST_MAX_PER_SPOT_RAW)
self.SRVN_REVIEW_EMBED_MAX_PER_SPOT = int(self.SRVN_REVIEW_EMBED_MAX_PER_SPOT_RAW)
self.SRVN_REVIEW_EMBED_MAX_PER_SPOT_HEAD = int(self.SRVN_REVIEW_EMBED_MAX_PER_SPOT_HEAD_RAW)
self.SRVN_REVIEW_PRIORITY = int(self.SRVN_REVIEW_PRIORITY_RAW)
self.SRVN_REVIEW_DAILY_BUDGET_MICROS = int(round(float(self.SRVN_REVIEW_DAILY_BUDGET_USD_RAW) * 1_000_000))
self.SRVN_REVIEW_COST_PER_10_USD = float(self.SRVN_REVIEW_COST_PER_10_USD_RAW)
self.SRVN_REVIEW_COST_SETUP_USD = float(self.SRVN_REVIEW_COST_SETUP_USD_RAW)
```

### `review_vendor_client.py`

```python
"""DataForSEO Google Reviews vendor client for srvn Phase 2 review ingestion.

Two-phase by design (DataForSEO Business Data API is async): ``post_reviews_task``
orders up to ``depth`` reviews for one place_id (cost is *committed here*), and
``collect_reviews_task`` drains the finished task. Spend is therefore reserved at
post and reconciled at collect by the worker's ``ReviewSpendLedger`` — NOT debited
when rows land. This is the one place the review pipeline cannot mirror the
synchronous taste-embed worker's commit-then-increment breaker.

PII is dropped at the boundary: ``_serialize_review`` reads only rating / text /
language / timestamp / review_id. Reviewer identity (profile_name, profile_image_url)
and the business's ``owner_answer`` are intentionally never surfaced — the
srvn_spot_reviews schema stores none of them.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional, Protocol, runtime_checkable

import requests

from ressy_backend.config import CONFIG

_REVIEWS_POST_PATH = "/v3/business_data/google/reviews/task_post"
_REVIEWS_GET_PATH = "/v3/business_data/google/reviews/task_get/{task_id}"

# DataForSEO bills per 10 reviews and rounds non-multiples up (depth:11 → 20).
_DEPTH_STEP = 10
_DEPTH_MAX = 4490  # Google's own ceiling on reviews surfaced per place.
_SOURCE = "dataforseo_google"  # → srvn_spot_reviews.source

_ALLOWED_SORTS = {"relevant", "newest", "highest_rating", "lowest_rating"}  # [C3]


@dataclass(frozen=True)
class VendorReview:
    """One PII-stripped review, shaped to srvn_spot_reviews columns."""

    external_review_id: str
    rating: Optional[int]
    text: str
    language_code: Optional[str]
    published_at: Optional[datetime]
    source_rank: int  # [C5] index in the requested sort order → embed worker's relevance cutoff


@dataclass(frozen=True)
class ReviewTask:
    """A posted task. ``reserved_cost_micros`` is the *max* billable for this depth."""

    task_id: str
    place_id: str
    depth: int
    sort_by: str
    reserved_cost_micros: int  # [C1] worker reserves this against the day budget at post


@dataclass(frozen=True)
class ReviewCollectResult:
    """A drained task. ``actual_cost_micros`` is the true charge (from the response)."""

    place_id: str
    reviews: list[VendorReview]
    actual_cost_micros: int      # [C1] reconcile target
    reviews_count_total: int     # Google's total for the place → adaptive head decision [C5]


@runtime_checkable
class ReviewVendorClient(Protocol):
    """Vendor contract consumed by the ingest worker. Swap impls behind this."""

    def post_reviews_task(
        self, place_id: str, *, location_name: str, language_name: str,
        depth: int, sort_by: str,
    ) -> ReviewTask: ...

    def collect_reviews_task(self, task_id: str) -> ReviewCollectResult: ...


class DataForSEOClient:
    """Concrete ``ReviewVendorClient`` over DataForSEO Business Data → Google Reviews."""

    def __init__(
        self, *, session: Optional[requests.Session] = None,
        login: Optional[str] = None, password: Optional[str] = None,
        base_url: Optional[str] = None, priority: Optional[int] = None,
    ) -> None:
        self._base = (base_url or CONFIG.SRVN_DATAFORSEO_BASE_URL).rstrip("/")
        self._priority = CONFIG.SRVN_REVIEW_PRIORITY if priority is None else priority  # [C2] default=1
        if session is None:
            login = login or CONFIG.SRVN_DATAFORSEO_LOGIN
            password = password or CONFIG.SRVN_DATAFORSEO_PASSWORD
            if not (login and password):
                raise RuntimeError(
                    "DataForSEO credentials missing. Set SRVN_DATAFORSEO_LOGIN / _PASSWORD."
                )
            session = requests.Session()
            session.auth = (login, password)  # DataForSEO uses HTTP Basic
        self._session = session

    def post_reviews_task(
        self, place_id, *, location_name, language_name, depth, sort_by,
    ) -> ReviewTask:
        """Order up to ``depth`` reviews for ``place_id``. Cost is committed on success.

        ``depth`` is clamped to [10, 4490] and rounded UP to a multiple of 10 so the
        reserved estimate matches what DataForSEO actually bills.
        """
        if sort_by not in _ALLOWED_SORTS:
            raise ValueError(f"sort_by={sort_by!r} not in {_ALLOWED_SORTS}")  # [C3]
        depth = self._round_depth(depth)
        body = [{
            "place_id": place_id,
            "location_name": location_name,
            "language_name": language_name,
            "depth": depth,
            "sort_by": sort_by,
            "priority": self._priority,   # [C2] standard queue
            "tag": place_id,              # correlate task → spot on collect
        }]
        resp = self._session.post(self._base + _REVIEWS_POST_PATH, json=body, timeout=30)
        resp.raise_for_status()
        task = resp.json()["tasks"][0]
        if task.get("status_code") not in (20000, 20100):  # 20100 = "Task Created"
            raise RuntimeError(f"DataForSEO post failed: {task.get('status_message')}")
        return ReviewTask(
            task_id=task["id"], place_id=place_id, depth=depth, sort_by=sort_by,
            reserved_cost_micros=self._estimate_cost_micros(depth),  # [C1]
        )

    def collect_reviews_task(self, task_id) -> ReviewCollectResult:
        """Drain a finished task. Raises if not ready (worker polls / uses postback)."""
        url = self._base + _REVIEWS_GET_PATH.format(task_id=task_id)
        resp = self._session.get(url, timeout=30)
        resp.raise_for_status()
        task = resp.json()["tasks"][0]
        result = (task.get("result") or [{}])[0]
        items = result.get("items") or []
        reviews = [
            self._serialize_review(item, rank)
            for rank, item in enumerate(items)
            if item.get("review_text")  # skip rating-only rows; text is required
        ]
        return ReviewCollectResult(
            place_id=task.get("data", {}).get("tag", ""),
            reviews=reviews,
            actual_cost_micros=int(round(float(task.get("cost", 0.0)) * 1_000_000)),  # [C1]
            reviews_count_total=int(result.get("reviews_count") or 0),  # [C5]
        )

    # --- helpers -----------------------------------------------------------
    @staticmethod
    def _round_depth(depth: int) -> int:
        depth = max(_DEPTH_STEP, min(int(depth), _DEPTH_MAX))
        return math.ceil(depth / _DEPTH_STEP) * _DEPTH_STEP

    @staticmethod
    def _estimate_cost_micros(depth: int) -> int:
        """Max billable for ``depth`` reviews at standard list price → micro-USD."""
        units = math.ceil(depth / _DEPTH_STEP)
        usd = CONFIG.SRVN_REVIEW_COST_SETUP_USD + units * CONFIG.SRVN_REVIEW_COST_PER_10_USD
        return int(round(usd * 1_000_000))

    @staticmethod
    def _serialize_review(item: dict, rank: int) -> VendorReview:
        """Map one DataForSEO item → VendorReview, dropping all PII.

        Deliberately NOT read: ``profile_name`` / ``profile_image_url`` (reviewer
        identity) and ``owner_answer`` (business reply). [C4] The schema has no column
        for owner responses — folding them into ``text`` would pollute the per-review
        embedding with marketing voice. If ever wanted, add a separate column.
        """
        ts = item.get("timestamp")
        return VendorReview(
            external_review_id=item["review_id"],
            rating=(item.get("rating") or {}).get("value"),
            text=item["review_text"],
            language_code=item.get("original_language") or item.get("language"),
            published_at=datetime.fromisoformat(ts).astimezone(timezone.utc) if ts else None,
            source_rank=rank,  # [C5]
        )
```

### `ReviewSpendLedger` — the C1 breaker (in `review_ingestor.py`)

```python
_DAY_SPEND_PREFIX = "srvn:review:spend:"   # micro-USD, mirrors the embed token counter
_DAY_SPEND_TTL_SECONDS = 48 * 3600


class ReviewSpendLedger:
    """[C1] Daily $ circuit breaker with reserve / release / reconcile semantics.

    DataForSEO commits cost at task_post, minutes before rows arrive — so we reserve
    the *max* (depth-based) charge up front and true-up to the real charge on collect.
    Single-scheduler-process assumed (like the embed worker); not a cross-replica lock.
    """

    def __init__(self, redis_client=None, budget_micros: Optional[int] = None) -> None:
        self._redis = redis_client or CONFIG.REDIS_CLIENT
        self._budget = CONFIG.SRVN_REVIEW_DAILY_BUDGET_MICROS if budget_micros is None else budget_micros

    def _key(self, now: datetime) -> str:
        return f"{_DAY_SPEND_PREFIX}{now.strftime('%Y-%m-%d')}"

    def reserve(self, micros: int, *, now: datetime) -> bool:
        """Reserve ``micros`` before posting. Rolls back + returns False if it would
        breach today's budget (so the caller stops posting tasks)."""
        key = self._key(now)
        total = int(self._redis.incrby(key, micros))   # authoritative post-increment
        self._redis.expire(key, _DAY_SPEND_TTL_SECONDS)
        if total > self._budget:
            self._redis.decrby(key, micros)            # release the would-be overspend
            return False
        return True

    def reconcile(self, *, reserved: int, actual: int, now: datetime) -> None:
        """Net the difference once the real charge is known (actual ≤ reserved usually)."""
        delta = actual - reserved
        if delta:
            self._redis.incrby(self._key(now), delta)

    def release(self, micros: int, *, now: datetime) -> None:
        """Return a reservation when a posted task errors out (no charge incurred)."""
        self._redis.decrby(self._key(now), micros)
```

### Worker wiring (abridged — all five constraints firing)

```python
# srvn_ingest_spot_reviews tick
for place_id, spot_id in _pop_queue(CONFIG.SRVN_REVIEW_INGEST_PER_TICK):
    sort_by = CONFIG.SRVN_REVIEW_SORT_SEED if _needs_seed(spot_id) else CONFIG.SRVN_REVIEW_SORT_REFRESH   # [C3]
    task = client.post_reviews_task(
        place_id, location_name=metro, language_name="English",
        depth=CONFIG.SRVN_REVIEW_INGEST_MAX_PER_SPOT, sort_by=sort_by)                                   # [C5] text cap
    if not ledger.reserve(task.reserved_cost_micros, now=now):                                            # [C1] reserve @ post
        logger.info("event=srvn_review_ingest status=budget_reached halting"); break
    _persist_pending_task(spot_id, task)   # task_id + reserved_cost; collected next tick / via postback

# collector (poll tasks_ready, or the postback_url handler):
res = client.collect_reviews_task(task_id)
ledger.reconcile(reserved=pending.reserved_cost_micros, actual=res.actual_cost_micros, now=now)          # [C1] true-up
_upsert_reviews(spot_id, res.reviews)      # dedup on (spot_id, external_review_id) + content_hash; source_rank kept

# srvn_embed_spot_reviews — which rows become vectors:
embed_cap = CONFIG.SRVN_REVIEW_EMBED_MAX_PER_SPOT_HEAD if _is_head(spot_id) else CONFIG.SRVN_REVIEW_EMBED_MAX_PER_SPOT  # [C5]
# candidate query: ROW_NUMBER() OVER (PARTITION BY spot_id ORDER BY source_rank) <= embed_cap
```

### Schema deltas this appendix implies

1. **Add `source_rank SmallInt`** to `srvn_spot_reviews` (§1) — without it the embed
   worker can't honor `EMBED_MAX` _by relevance_; C5 collapses to "first N by insertion."
2. **Keep the schema free of any owner-response column** (C4) — the serializer enforces
   the omission so it's a decision, not drift.
3. **Config**: `INGEST_MAX_PER_SPOT` `200 → 500`; **new** `EMBED_MAX_PER_SPOT` `200`
   (+ `_HEAD 500`); vendor default `outscraper → dataforseo`; `INGEST_DAILY_BUDGET` →
   `DAILY_BUDGET_USD` (+ pricing constants).
