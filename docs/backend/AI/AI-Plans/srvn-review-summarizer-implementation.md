# srvn Per-Spot Review Summarizer — implementation plan

_Date: 2026-07-01 · Status: **shipped (PRs #204–208)** · Scope: the **deferred review-summarizer** slice of Phase 2 — the per-spot LLM digest that fills the already-migrated `review_digest_*` / `top_review_snippets` columns on `srvn_spot_taste_features`._

Companion design doc: [`phase2-review-ingestion-and-rag.md`](./phase2-review-ingestion-and-rag.md) (authoritative for the digest spec). Predecessor (the shipped ingestion slice): [`srvn-review-ingestion-implementation.md`](./srvn-review-ingestion-implementation.md).

> **Follow-on (2026-07-01):** the summarizer is being extended to also write a spot-level
> `review_digest_embedding` (+ structured `review_noise`) in the same pass, replacing the
> retired per-review RAG. See
> [`spot-digest-embedding-supersedes-per-review-rag.md`](./spot-digest-embedding-supersedes-per-review-rag.md).

---

## Context — why this change

The review-ingestion slice (PRs #197–#201) is merged and reviews are now in the DB (Toronto seed: ~414k reviews across ~5,267 spots). The plan explicitly deferred two follow-ons; this is the **first and cheaper** one. The summarizer produces the per-spot structured digest + curated snippets that power the future intent endpoint's ≤500 ms first-paint card — and, unlike per-review vector search, it needs **no embeddings, no HNSW, no DB resize** (the 10 GiB / 1 GB box is fine). The six target columns already exist on `SrvnSpotTasteFeatures` (added ahead of time), so **no migration** is needed — this is pure additive code.

**Decisions locked with the user:**
- **LLM = OpenAI, model `gpt-5-mini` at `reasoning_effort=medium`** (defaults), via new config knobs `SRVN_GPT_5_MINI_MODEL` + `SRVN_OPENAI_REASONING_EFFORT` (both swappable — e.g. `gpt-5-nano` / `low` to cut cost). Reuses the `openai` SDK already in the repo. **~$15–25 one-time** for the full corpus (medium-effort reasoning tokens bill as output), ~$0 ongoing (corpus-hash skip). Key: `OPENAI_API_CONVERSATIONAL_KEY` → falls back to `OPENAI_API_KEY`.
- **Snippet selection = LLM picks the row ids.** The model returns the indices of the most-informative reviews; we store the **verbatim real rows** (`{text, rating, published_at}`) — LLM judgment, zero hallucination.

---

## OpenAI call shape (verified against live docs + the pinned SDK)

`openai` is pinned at **1.58.1** (`poetry.lock`), which **predates the Responses API** (`client.responses` is absent). `reasoning_effort` and `max_completion_tokens` are both valid typed kwargs on 1.58.1. So — no dependency bump — use **Chat Completions + Structured Outputs**:

```python
resp = self._client.chat.completions.create(
    model=self._model,                      # CONFIG.SRVN_GPT_5_MINI_MODEL ("gpt-5-mini")
    messages=[{"role": "system", "content": _SYSTEM_PROMPT},
              {"role": "user",   "content": user_prompt}],
    response_format={"type": "json_schema",
                     "json_schema": {"name": "spot_review_digest",
                                     "strict": True, "schema": _DIGEST_SCHEMA}},
    reasoning_effort=self._reasoning_effort, # CONFIG.SRVN_OPENAI_REASONING_EFFORT ("medium"); gpt-5-mini supports minimal|low|medium|high
    max_completion_tokens=_MAX_COMPLETION_TOKENS,  # 8000 ceiling for reasoning+output (a cap, not a spend) — NOT max_tokens (deprecated/o-series)
    user=_BILLING_USER,                     # "srvn_review_digest"
    # NO temperature — reasoning models reject a non-default value (400)
)
```
- **Strict Structured Outputs** requires every object to set `additionalProperties: false` and list **all** properties in `required`. `maxItems`/`maxLength` may be ignored → clamp caps in code/prompt, not schema.
- Handle `resp.choices[0].message.refusal` (raise a small `ReviewDigestRefused`).
- If a future kwarg/value isn't in the pinned SDK's typed signature, route it via `extra_body={...}` rather than bumping the dep.

---

## New files

### 1. `ressy_backend/services/srvn_taste_graph/review_summarizer_client.py`
Owns the digest call, prompt, and schema. Mirrors `embedding_client.py` structure (module constants → frozen result dataclasses → `Protocol` → concrete injectable client). Named `_client.py` to match the `embedding_client.py` convention and keep unrelated LLM calls from accreting here.

- **Constants:** `_BILLING_USER="srvn_review_digest"`, `_DEFAULT_MAX_RETRIES=2`, `_MAX_COMPLETION_TOKENS=8000` (ceiling for reasoning+output), `_SYSTEM_PROMPT`, `_DIGEST_SCHEMA`. Reasoning effort is read from `CONFIG.SRVN_OPENAI_REASONING_EFFORT` (default `medium`), not hard-coded.
- **Dataclasses (frozen):** `CorpusReview(text, rating)`; `ReviewDigestUsage(total_tokens)`; `ReviewDigestResult(digest_text, digest_json: dict, top_snippet_ids: list[int], usage, model_id)`.
- **`ReviewSummarizerClient` Protocol:** `summarize(*, spot_name, corpus: list[CorpusReview], top_k) -> ReviewDigestResult`.
- **`OpenAIReviewSummarizerClient`:** `__init__(*, client=None, api_key=None, model=None, reasoning_effort=None, max_retries=2)` — key resolution `api_key or CONFIG.OPENAI_API_CONVERSATIONAL_KEY or CONFIG.OPENAI_API_KEY` (else `RuntimeError`); `self._model = model or CONFIG.SRVN_GPT_5_MINI_MODEL`; `self._reasoning_effort = reasoning_effort or CONFIG.SRVN_OPENAI_REASONING_EFFORT`. `summarize()` builds the numbered prompt, makes the call above, raises `ReviewDigestRefused` on refusal/empty/non-JSON, else `json.loads` the strict content and returns the result with `usage.total_tokens`. **Error policy is caller-side** (propagate `openai.RateLimitError`/`APIConnectionError`/`APIStatusError` unmodified — same as `embedding_client.py`).

**System prompt (compact):** "You are a concise restaurant-review summarizer. Given a numbered list of real customer reviews for one venue, summarize only what the reviews actually say — never invent facts, dishes, or details. Return ONLY the structured object; use empty string / `"unknown"` for `noise` / empty array where unsupported. `digest_text` ≤ 400 chars, 2–3 neutral sentences. For `top_snippet_ids` pick up to {top_k} of the MOST decision-useful review numbers (most informative first) using ONLY the bracketed numbers shown. Never include reviewer names or personal data."

**User template** (built from `corpus`): `Spot: {name}\n\nReviews:\n[0] (rating: 5) <text≤600 chars>\n[1] (rating: 3) <…>\n…\nReturn the digest for this spot.`

**`_DIGEST_SCHEMA` (strict):**
```json
{"type":"object","additionalProperties":false,
 "required":["digest_text","digest_json","top_snippet_ids"],
 "properties":{
   "digest_text":{"type":"string"},
   "digest_json":{"type":"object","additionalProperties":false,
     "required":["vibe","noise","service","dietary_notes","occasion_fit","standout_dishes"],
     "properties":{
       "vibe":{"type":"string"},
       "noise":{"type":"string","enum":["quiet","moderate","lively","loud","unknown"]},
       "service":{"type":"string"},
       "dietary_notes":{"type":"string"},
       "occasion_fit":{"type":"string"},
       "standout_dishes":{"type":"array","items":{"type":"string"}}}},
   "top_snippet_ids":{"type":"array","items":{"type":"integer"}}}}
```

### 2. `ressy_backend/services/srvn_taste_graph/review_summarizer.py`
The sweep + helpers. Mirrors `refresh_review_embeddings` (`review_ingestor.py:548`) for DI, the Redis daily-token breaker, structured logging, and the return dict; mirrors `srvn_refresh_spot_features`/`extract_features` for the per-spot stale-loop with **commit-per-spot**.

- **Constants:** `_DAY_COUNTER_PREFIX="srvn:digest:tokens:"` (**new** prefix — do NOT reuse `srvn:embed:tokens:`), `_DAY_COUNTER_TTL_SECONDS=48*3600`, `_MAX_CORPUS_REVIEWS=40`, `_MAX_REVIEW_CHARS=600`, `_TOP_SNIPPETS=5`, `_DAILY_TOKEN_BUDGET=2_000_000`, `_PER_RUN_CAP=500` (these three tuning values live **here, not in `config.py`** — edit in-file to change); lazy `_get_default_summarizer_client()` singleton.
- **`_review_corpus_hash(content_hashes)`** — order-independent: `taste_text_hash("\n".join(sorted(hashes)))` (reuse `hashing.py`, sha256[:16], matches the `String(16)` column).
- **`_resolve_snippets(corpus_rows, ids, top_k)`** — validate `0 ≤ i < len`, dedupe preserving order, clamp to `top_k`, return `[{text, rating, published_at.isoformat()|None}]`. Copies only text/rating/published_at — **never** reviewer identity.
- **`summarize_spot_reviews(session, *, summarizer_client=None, redis_client=None, now=None, limit=None) -> dict`:**
  1. Budget short-circuit on `_DAILY_TOKEN_BUDGET` via `_digest_day_key(now)` (`budget_exhausted` early return).
  2. **Candidate query** on `SrvnSpotTasteFeatures`: `reviews_ingested_at IS NOT NULL` AND (`review_digest_updated_at IS NULL` OR `review_corpus_hash IS NULL` OR `coalesce(review_digest_model,'') != model` OR `reviews_ingested_at > review_digest_updated_at`); `order_by(review_digest_updated_at.asc().nullsfirst()).limit(limit or _PER_RUN_CAP)`.
  3. Per spot: fetch active `SrvnSpotReview` rows (`deleted_at IS NULL`, `order_by(source_rank.asc())`); **0 rows → skip** (`spots_skipped_empty`). Compute `corpus_hash` over **all** active `content_hash`es. **Hash-skip** (unchanged hash + same model) → restamp `review_digest_updated_at`, commit, no LLM call (`spots_skipped_hash`). Mid-run budget check → `halted; break`. Else call the client (`top_k=_TOP_SNIPPETS`) on the **top `_MAX_CORPUS_REVIEWS`** slice (truncated to `_MAX_REVIEW_CHARS`), with the same try/except ladder as the embed sweep (rate-limit/conn → halt; api-status → skip; refusal/json → `errors; continue`). Be robust to a missing features row (create like `extract_features`). Write the six columns (`top_review_snippets = _resolve_snippets(slice, result.top_snippet_ids, _TOP_SNIPPETS)`), **commit per spot**, then `redis.incrby(day_key, usage.total_tokens)` + `expire` (commit-before-increment).
  4. Structured `event=srvn_review_digest_tick …` log + return `{status, spots_seen, spots_digested, spots_skipped_hash, spots_skipped_empty, errors, tokens, day_budget_remaining, halted}`.
  - The library fn has **no gate and no scheduler** — it runs only when the CLI (`srvn-reviews summarize`) invokes it. Re-digests happen whenever you run the CLI; there is **no automatic nightly catch-up**.

### 3. Tests (`tests/srvn_backend/services/srvn_taste_graph/`, `commands/`)
- `test_review_summarizer_client.py` — inject a fake `openai.OpenAI` via `client=`; assert exact request kwargs (`response_format` json_schema `strict:True`, `reasoning_effort="medium"` from config, `max_completion_tokens`, `user`, **no `temperature`**), refusal path, `usage.total_tokens` capture.
- `test_review_summarize_sweep.py` (`@pytest.mark.api`) — model on `test_review_embed_sweep.py` (`make_spot_with_reviews`, `fakeredis _redis()`, injected `_FakeSummarizerClient`). Cover: writes all six columns; snippets resolve to **real** row text/rating/published_at at the returned ids; out-of-range/dup ids dropped + clamped to cap; unchanged corpus = hash-skip no-op (no client call, timestamp restamped, `tokens=0`); changed review re-digests; budget breaker via a preset `srvn:digest:tokens:<date>` key ≥ `_DAILY_TOKEN_BUDGET` (or monkeypatch the constant lower); the `srvn:embed:tokens:` key stays untouched; 0-review skip; missing features row created; and `undigested_spots`/`undigested_spot_ids` return exactly the still-undigested rows (right ids + `reviews_ingested_at`/`review_digest_updated_at`, agree with the `spots_undigested` count, honor `limit`, drop freshly-digested spots).
- Extend `test_review_config_knobs.py` (new knobs incl. `SRVN_OPENAI_REASONING_EFFORT` enum validation + `OPENAI_API_CONVERSATIONAL_KEY` fallback) and `test_srvn_review_ingest_command.py` (`summarize` cmd; `spots_undigested` in `status`; the `undigested` cmd prints id + both timestamps (`never` for a null digest) and honors `--limit`).

---

## Modified files

| File | Change |
|---|---|
| `ressy_backend/config.py` | Add `_RAW` + `__init__` for the **three** vars below, copying the `SRVN_EMBEDDING_MODEL` (string) and `OPENAI_TASTE_GRAPH_API_KEY` (optional key) patterns; validate `SRVN_OPENAI_REASONING_EFFORT` against `{minimal,low,medium,high}` like the `SRVN_SEED_MODE` enum (config.py:551–556). **No enable flag and no int knobs** — the token-budget / per-run-cap / top-snippet values are module constants in `review_summarizer.py`. |
| `ressy_backend/commands/srvn_review_ingest_command.py` | Add a `summarize [--max N]` subcommand (model on `embed_cmd`; no enable-gate); add a `spots_undigested` count to `status`; add an **`undigested [--limit N]`** subcommand that prints the total count then one row per spot — `spot_id  reviews_ingested_at  review_digest_updated_at` (via `undigested_spots`; `review_digest_updated_at` renders as `never` when NULL, so never-digested vs stale-by-re-ingest is visible at a glance; default `--limit 50`, `--limit 0` = all). |
| `ressy_backend/services/srvn_taste_graph/review_ingestor.py` | Factor the predicate into `_undigested_condition()` (features rows `reviews_ingested_at IS NOT NULL AND (review_digest_updated_at IS NULL OR reviews_ingested_at > review_digest_updated_at)`); extend `status_snapshot()` with a `spots_undigested` **count** built on it; add **`undigested_spots(session=None, *, limit=None)`** selecting `(spot_id, reviews_ingested_at, review_digest_updated_at)` via the **same** condition, `order_by(reviews_ingested_at.asc())`, plus a thin **`undigested_spot_ids(...)`** that pulls just the ids from it. Count, rows, and ids share one predicate so they can't drift. |
| `ressy_backend/services/srvn_taste_graph/__init__.py` | Export `summarize_spot_reviews`, `undigested_spots`, `undigested_spot_ids`, `OpenAIReviewSummarizerClient`, `ReviewSummarizerClient`, `ReviewDigestResult`, `ReviewDigestUsage`, `CorpusReview`. |

**New config vars** (only these three go in `config.py`):

| Var | Default | Pattern |
|---|---|---|
| `SRVN_GPT_5_MINI_MODEL` | `gpt-5-mini` | string |
| `SRVN_OPENAI_REASONING_EFFORT` | `medium` | validated enum `{minimal,low,medium,high}`, like `SRVN_SEED_MODE` |
| `OPENAI_API_CONVERSATIONAL_KEY` | `""` | optional key w/ fallback |

**Module constants** (in `review_summarizer.py`, *not* `config.py`):

| Constant | Default | Purpose |
|---|---|---|
| `_TOP_SNIPPETS` | `5` | curated snippets stored per spot (the `top_k`) |
| `_DAILY_TOKEN_BUDGET` | `2_000_000` | daily OpenAI-token spend ceiling (Redis breaker) |
| `_PER_RUN_CAP` | `500` | max spots processed per sweep (CLI `--max` overrides) |

**Corpus cap (module constants, not config):** send at most the top **40** active reviews by `source_rank` (vendor relevance order), each truncated to **600** chars (~2–4k input tokens/spot). The **corpus hash is over all active reviews**; only the top-40 slice is sent and used for snippet resolution.

---

## PR breakdown (one ticket per PR — assign real `sc-NN` from Shortcut)

1. **PR 1 — config + summarizer client (dark).** `config.py` vars + `review_summarizer_client.py` (prompt, `_DIGEST_SCHEMA`, dataclasses, Protocol, client) + `test_review_summarizer_client.py` + extend `test_review_config_knobs.py`. Nothing wired.
2. **PR 2 — summarizer sweep + service.** `review_summarizer.py` + `__init__.py` exports + `status_snapshot` `spots_undigested` + `undigested_spots()`/`undigested_spot_ids()` helpers + `test_review_summarize_sweep.py`. Library-only.
3. **PR 3 — surfacing (CLI only).** `srvn-reviews summarize` + `undigested` subcommands + `spots_undigested` in `status`, extend the command test. **No `tasks.py`/`app.py` changes — the summarizer is CLI-only, never scheduled.** Nothing runs automatically; review text hits OpenAI only when an operator invokes `summarize`.

---

## Verification

**Automated (`poetry run pytest`, `api` tests need `RESSY_TESTING=1` + `TEST_DATABASE_URL`):**
- `test_review_summarizer_client.py` — request shape / refusal / usage.
- `test_review_summarize_sweep.py -m api` — write-back, real-row snippets, hash-skip idempotency, corpus-change re-digest, budget breaker on the digest counter (embed counter untouched), 0-review + missing-row edges.
- `test_review_config_knobs.py`, `test_srvn_review_ingest_command.py`.

**Manual smoke** (needs a DB with `srvn_spot_reviews` + `OPENAI_API_CONVERSATIONAL_KEY`/`OPENAI_API_KEY`). Run these via `! …` since they hit the DB/OpenAI:
0. `flask srvn-reviews undigested --limit 5` → prints the total count + the first 5 rows (`spot_id  reviews_ingested_at  review_digest_updated_at`, the last showing `never` pre-first-run) awaiting a digest (before any run, ≈ all spots-with-reviews).
1. `flask srvn-reviews summarize --max 3` → `status=ok spots_digested=N tokens>0`.
2. Inspect DB: `review_digest_text` non-empty; `review_digest_json` has all six keys; `top_review_snippets` = `[{text,rating,published_at}]` whose `text` **matches real review rows** (no hallucinated text); `review_corpus_hash`/`review_digest_model`/`review_digest_updated_at` set.
3. Re-run `summarize --max 3` immediately → `spots_skipped_hash` increments, `tokens=0` (hash-skip proves no wasted spend).
4. `flask srvn-reviews status` → `undigested spots` dropped by N; Redis `srvn:digest:tokens:<date>` incremented, `srvn:embed:tokens:<date>` unchanged.

---

## Risks / edge cases (handled in the design)
- **0-review or missing-features-row spots** → skip / create-on-the-fly (like `extract_features`); never call the LLM on an empty corpus.
- **Budget mid-run halt** → commit digest, then `incrby`, check `>= budget` before each spot; commit-before-increment means a crash re-digests only one spot (idempotent).
- **Dedup ↔ hash** → ingestor's unique `(spot_id, content_hash)` + order-independent sorted-hash join → re-collecting identical/reordered reviews yields the same hash (correct skip); any add/remove/soft-delete re-triggers.
- **Snippet integrity** → model returns indices only; text is verbatim from rows; bad/dup indices dropped, clamped to cap, `[]` if none.
- **PII** → `SrvnSpotReview` carries no reviewer identity (stripped at ingest); `_resolve_snippets` copies only text/rating/published_at; prompt forbids personal data.
- **Reasoning truncation** → `finish_reason="length"` → client raises → sweep logs + `errors; continue`; `_MAX_COMPLETION_TOKENS=8000` gives medium-effort reasoning ample headroom for a ≤40-review corpus (it's a ceiling, not a spend).
## Compliance note
The digest sends third-party review text to OpenAI (companion §7). Two controls apply:

- **Distinct key.** Using `OPENAI_API_CONVERSATIONAL_KEY` (separate from the embedding `OPENAI_API_KEY`) satisfies the "distinct key" control.
- **Zero Data Retention (ZDR).** Before the first prod `summarize`, enable **project-scoped ZDR** on the OpenAI project that holds `OPENAI_API_CONVERSATIONAL_KEY`. ZDR excludes prompts/responses from OpenAI's default ≤30-day abuse-monitoring logs (API content is already not used for training). Mechanics — [OpenAI *Data controls*](https://developers.openai.com/api/docs/guides/your-data):
  - **Approval-gated, not self-serve** — request via sales ("API for Enterprise"). Once approved, configure per-project under **Settings → Organization → Data controls → Data Retention** (org-level or project-level; use a dedicated project for the conversational key).
  - Both endpoints we use are **ZDR-eligible**: `/v1/chat/completions` (digest, `gpt-5-mini`) and `/v1/embeddings` (`text-embedding-3-small`). `gpt-5-mini` is not in the `gpt-5.5`+ "safety retention" carve-out.
  - ZDR forces `store=false` on `/v1/chat/completions` — a **no-op for us** (the client never sets `store`); **no code change**.
  - **Modified Abuse Monitoring** is an acceptable fallback (also excludes content from abuse logs; does not force `store=false`).
  - **Data residency** (e.g. a Canada-region project) is a *separate* control and **out of scope** — the payload is public review text + venue names, no user PII, so ZDR alone satisfies this note. Residency only matters if legal requires in-country data localization.

Because the summarizer is **CLI-only** (no cron, no auto-run), all three PRs merge freely — nothing sends review text until an operator invokes `summarize`. The gate is therefore **operational, not a deploy gate: confirm ZDR is enabled on the conversational key's project before the first prod `summarize`.**
