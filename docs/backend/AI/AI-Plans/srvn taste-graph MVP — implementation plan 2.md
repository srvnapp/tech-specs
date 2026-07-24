# srvn taste-graph implementation plan 2 — Phase 2: request-time intent endpoint

> **Companion docs**: `docs/plans/AI-Plans/ai-execution-roadmap.md` (6-phase roadmap), `docs/plans/AI-Plans/request-time-ai-pipeline.md` (source plan — authoritative for the request-time AI tier; this plan calls it "Phase 1 minimum increment"), `docs/plans/AI-Plans/srvn taste-graph MVP — implementation plan 1.md` (Phase 1 MVP — this plan's hard prerequisite). This plan implements the Phase 2 slice: synchronous `POST /spots/recommend-by-intent` + Redis intent/query-embed caching + `s_query_match` scoring + precomputed `taste_summary_text` + `top_review_snippet` + `vibe_tags`. Defers SSE streaming, reranker LLM, per-spot explainer, and group dining to Phase 4.

## Context

After the MVP ships, users get personalized `/spots/recommended` driven by distance + taste embedding + cuisine + price + popularity. Phase 2 layers a sibling endpoint that takes a free-text vibe query — `"date night, jazz music bar"` — parses it into structured intent, embeds the query string into the same 1536-dim vector space as spot taste vectors, and re-ranks against both feature scores and `s_query_match` (cosine similarity between query vector and spot taste vector). The endpoint returns 20 spots, each with a precomputed `taste_summary_text` (~200 chars LLM-compressed), `top_review_snippet`, and `vibe_tags` array — so first paint carries real semantic content, not a placeholder.

**Hard prerequisites**:

- MVP shipped: 3 sidecar tables exist, embedding worker has populated spot vectors (at current 500-spot scale, ~30 min after MVP deploy — runway-free in practice; see MVP conversation)
- MVP's `services/srvn_taste_graph/` package exists with `embedding_client.py`, `scoring.py`, `taste_taxonomies.py`, `spot_features_extractor.py`, `text_builder.py`
- MVP-extended Google Places ingest is populating `Spot.info["reviews"]` (PII-scrubbed: id, rating, text, language_code, publish_time only) and `Spot.info["editorial_summary"]`

**Cuts vs. source plan** (`request-time-ai-pipeline.md` Phase 1 minimum increment):

- **Defer** SSE streaming (Phase 4a — greenfield in Flask, no precedent today)
- **Defer** reranker LLM (Stage 4a — needs streaming infra)
- **Defer** per-spot explainer LLM (Stage 4b — needs streaming infra)
- **Defer** group dining endpoint `POST /events/{event_id}/recommend-by-intent` (Phase 4b — separate scope, needs participant taste merger)
- **Defer** social signal scoring + `social_summary_text` (Phase 3 — needs ClickHouse rollups)
- **Defer** 24h in-request save-signal boost (AC-6 in source plan; small UX feature)
- **Keep** intent parser, query embedding, `s_query_match` scoring, `taste_summary_text` precompute, `top_review_snippet`, `vibe_tags`, Redis caching, daily budget, AC-2 / AC-4 / AC-5 / AC-7 failure modes

Approach: **3 small PRs after MVP merges**, mirroring the MVP's review-friendly cadence.

| PR | Surface | User-visible? |
|---|---|---|
| **PR 1** — Migration + config + intent parser foundation | Alembic (4 new cols on `srvn_spot_taste_features`) + 7 config vars + `intent_parser.py` + `intent_cache.py` | No |
| **PR 2** — Spot feature enrichment workers | `spot_features_extractor.py` extension + new `srvn_refresh_spot_taste_summaries` job + backfill CLI | No (workers populate data) |
| **PR 3** — Endpoint + scoring + query embed | `embedding_client.embed_query()` + `scoring.s_query_match` term + `Spot.find_nearby_with_intent` + new `routes/srvn_recommend_by_intent.py` | Yes — POST endpoint flips on |

## Key codebase discoveries that shape the plan

Cross-referenced against the MVP plan's discoveries; these are Phase 2 additions/specifics:

1. **No Anthropic Claude in codebase today.** Per user direction (this session), Phase 2 reuses the existing langchain + OpenAI stack from `conversation_service.py` — `ChatOpenAI(model_name="gpt-4o-mini")`. Intent parser uses `gpt-4o-mini` via langchain's `.with_structured_output(IntentSchema)` mode for reliable JSON extraction. **Latency budget shifts vs. source plan**: gpt-4o-mini intent parse ~400ms p50 (vs. haiku ~250ms), so end-to-end becomes **~600ms p50 / ~1.2s p95** instead of source plan's 450ms/1s. Still under "feels instant" (~1.5s); flag in PR 3 description for future haiku swap if/when Anthropic SDK is on the dependency list.

2. **Two Redis clients exist** (`config.py:530-549`): `SESSION_REDIS` (binary, Flask-Session) and `REDIS_CLIENT` (decoded strings). Phase 2 uses `REDIS_CLIENT` for all cache + budget operations. Library: `redis-py ^5.2.1` already pinned.

3. **Existing rate-limit pattern** (`utils/rate_limit.py:46-62`) — `_incr_with_ttl()` does atomic INCR + TTL-on-first-creation. Phase 2's daily-budget counter mirrors this exactly: key `srvn:intent:calls:{YYYY-MM-DD}`, INCRBY 1 per request, TTL 48h covering UTC rollover.

4. **`Spot.find_nearby` returns ORM objects, not raw rows + distance** (`spot.py:184-244`). Distance is computed inline via `db.text("ST_Distance(...)")` for ORDER BY but NOT exposed on the result. Phase 2's response needs `distance_m` on cards — so the new query path uses `query.add_columns(distance_expr, taste_similarity_expr)` and hydrates a `(spot, distance_m, taste_similarity)` tuple instead of just `spot`. Existing `/spots/recommended` keeps its current behavior.

5. **PostGIS calls use raw SQL via `db.text()`** with `bindparams()`. Phase 2's pgvector cosine-distance operator `<=>` follows the same pattern — `db.text("1 - (f.taste_embedding <=> (:query_emb)::vector)").bindparams(query_emb=vector_to_str(query_vector))`. SQLAlchemy ORM has no first-class pgvector operator support; raw SQL is correct. Vector binding format: `'[0.123,0.456,...]'::vector` string literal — define `vector_to_str()` once in `embedding_client.py`.

6. **Smorest blueprint pattern** (`spot.py:63-68` + `app.py:140-177`): `Blueprint(...)` with `url_prefix`, decorate POST routes with `@blp.arguments(Schema, location="json")`, register in `register_blueprints()`. Phase 2 creates a new blueprint file `routes/srvn_recommend_by_intent.py` rather than extending `spots_blueprint` — matches the MVP's `routes/srvn_taste_profile.py` precedent, keeps Smorest doc grouping clean, lets `SRVN_INTENT_ENABLED=false` shed the entire blueprint registration cleanly.

7. **`Spot.info["reviews"]` shape after MVP** (per MVP plan §2.1 PRE-STEP): each entry is `{id, rating, text, language_code, publish_time}`. Phase 2's `top_review_snippet` picks the highest-rated review (ties broken by most recent `publish_time`), truncates to ~200 chars at word boundary, filters out reviews with `language_code != "en"` (until translation lands later), falls back to second-highest if first fails the filter.

8. **`make_user` factory hard-deletes users on teardown** (`conftest.py:90-129`), but does NOT cover spots. Phase 2 tests that seed spots need explicit cleanup — mirror MVP's `test_srvn_recommended_personalized.py` teardown pattern.

These shape:

- Latency targets (gpt-4o-mini-adjusted)
- Daily budget knob naming (`SRVN_INTENT_DAILY_BUDGET` as call-count ceiling, not token-count, since gpt-4o-mini per-call cost is tightly bounded)
- Cache key normalization (lowercase + strip punctuation + sort tokens + sha1[:16] of result; matches source plan)
- `s_query_match` weight = **0.30** when query present; redistribute proportionally from `s_distance` (0.30→0.20), `s_embedding` (0.25→0.18), `s_cuisine` (0.20→0.17), keep `s_price` (0.10) and `s_popularity` (0.15) unchanged. Sums to 1.00. Tunable in Phase 2 PR 3.
- Vector binding helper (`vector_to_str()`) defined once in `embedding_client.py`, reused by candidate-pool SQL

## PR 1 — Migration + config + intent parser foundation

Standalone, no behavior change. Adds the substrate Phase 2 needs.

### 1.1 Alembic migration

New file: `migrations/versions/<rev>_srvn_spot_taste_summary_cols.py`. Mirror MVP revision style.

`upgrade()`:

1. `op.add_column("srvn_spot_taste_features", sa.Column("taste_summary_text", sa.Text(), nullable=True))`
2. `op.add_column("srvn_spot_taste_features", sa.Column("vibe_tags", postgresql.ARRAY(sa.String()), nullable=False, server_default="{}"))`
3. `op.add_column("srvn_spot_taste_features", sa.Column("top_review_snippet", sa.Text(), nullable=True))`
4. `op.add_column("srvn_spot_taste_features", sa.Column("taste_summary_updated_at", sa.TIMESTAMP(timezone=True), nullable=True))`
5. GIN index on `vibe_tags` — used by intent SQL `vibe_tags && :intent_vibe_tags` candidate-pool filter

No backfill — columns ship NULL/empty. PR 2 workers fill them.

`downgrade()` drops the 4 columns + GIN index.

### 1.2 Model

Extend `ressy_backend/models/srvn_spot_taste_features.py` (created by MVP PR 1) to add the 4 columns. Mirror MVP's column declaration style.

### 1.3 Config

Add to `ressy_backend/config.py` using `_RAW` env var + `__init__` validation pattern (mirror MVP §2.4):

```
# Class-level
SRVN_INTENT_ENABLED_RAW = os.environ.get("SRVN_INTENT_ENABLED", "true")
SRVN_GPT_5_NANO_MODEL = os.environ.get("SRVN_GPT_5_NANO_MODEL", "gpt-4o-mini")
SRVN_QUERY_EMBED_CACHE_TTL_RAW = os.environ.get("SRVN_QUERY_EMBED_CACHE_TTL", "3600")
SRVN_INTENT_DAILY_BUDGET_RAW = os.environ.get("SRVN_INTENT_DAILY_BUDGET", "100000")
SRVN_TASTE_SUMMARY_ENABLED_RAW = os.environ.get("SRVN_TASTE_SUMMARY_ENABLED", "true")
SRVN_TASTE_SUMMARY_MODEL = os.environ.get("SRVN_TASTE_SUMMARY_MODEL", "gpt-4o-mini")
SRVN_TASTE_SUMMARY_DAILY_BUDGET_RAW = os.environ.get("SRVN_TASTE_SUMMARY_DAILY_BUDGET", "10000")

# __init__ — int validation tier
("SRVN_QUERY_EMBED_CACHE_TTL", Config.SRVN_QUERY_EMBED_CACHE_TTL_RAW),
("SRVN_INTENT_DAILY_BUDGET", Config.SRVN_INTENT_DAILY_BUDGET_RAW),
("SRVN_TASTE_SUMMARY_DAILY_BUDGET", Config.SRVN_TASTE_SUMMARY_DAILY_BUDGET_RAW),

# __init__ — bool tier
self.SRVN_INTENT_ENABLED = Config.SRVN_INTENT_ENABLED_RAW.lower() == "true"
self.SRVN_TASTE_SUMMARY_ENABLED = Config.SRVN_TASTE_SUMMARY_ENABLED_RAW.lower() == "true"
```

Budget defaults sized for current 500-spot scale:

- **Intent**: 100k calls/day. gpt-4o-mini at ~$0.0000225/intent call (150 input + 50 output tokens) = ~$2.25/day worst case.
- **Taste summary**: 10k calls/day. Worker uses budget only on spots where `features_updated_at > taste_summary_updated_at`. At 500 spots, full re-summarize = 500 calls = ~5% of budget. Cap exists to catch runaway loops.
- **Query embed**: no explicit budget — costs are tied to intent (no intent → no query embed; intent cache hit → query embed cache hit). Token spend lands in MVP's existing `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` Redis day counter with `metadata={"surface":"srvn_intent_query"}` for billing attribution.

### 1.4 Intent parser

New file `ressy_backend/services/srvn_taste_graph/intent_parser.py`:

```python
from langchain_openai import ChatOpenAI
from pydantic import BaseModel, Field
from typing import Literal

class IntentSchema(BaseModel):
    occasion: Literal["date_night", "family", "business", "solo", "casual", "group",
                      "celebration", "brunch", "late_night"] | None = None
    vibe_tags: list[str] = Field(default_factory=list, max_length=5)
    price_signal: Literal["budget", "moderate", "upscale", "luxury"] | None = None
    time_of_day: Literal["breakfast", "brunch", "lunch", "dinner", "late_night"] | None = None

class IntentParseError(Exception):
    """Raised when the LLM fails or returns invalid structure. Caller decides fallback."""

def parse_intent(query: str) -> IntentSchema:
    llm = ChatOpenAI(
        model=CONFIG.SRVN_GPT_5_NANO_MODEL,
        openai_api_key=CONFIG.OPENAI_API_KEY,
        temperature=0,
        timeout=4.0,
        max_retries=1,
        model_kwargs={"metadata": {"surface": "srvn_intent_parser"}},
    ).with_structured_output(IntentSchema)
    try:
        return llm.invoke([("system", SYSTEM_PROMPT), ("user", query)])
    except Exception as e:
        raise IntentParseError(str(e)) from e
```

`SYSTEM_PROMPT` lists allowed `vibe_tags` vocab (sourced from `taste_taxonomies.py`):

- Extend MVP's `CanonicalOccasion` enum with a sibling `CanonicalVibeTag` enum: `cozy`, `lively`, `intimate`, `loud`, `quiet`, `rustic`, `modern`, `outdoor`, `live_music`, `cocktails`, `wine_bar`, `dive`, `upscale_casual`, `jazz`, `dancing`, `romantic`, `family_friendly`, `pet_friendly`, `view`, `rooftop`, `speakeasy` (~25 tokens; tune from real query distribution post-launch)
- Define `normalize_vibe_tag(raw: str | None) -> CanonicalVibeTag | None` mirroring MVP's cuisine/dietary normalizers
- Bump `CURRENT_TAXONOMY_VERSION` to 2 — triggers MVP's existing embedding-worker hash-skip-bypass for affected user/spot rows (`taste_text` may render new vibe tokens)

Failure handling: on `pydantic.ValidationError`, langchain transport errors, or timeout → raise `IntentParseError`. PR 3 endpoint catches and falls back to embedding-only retrieval.

### 1.5 Intent cache

New file `ressy_backend/services/srvn_taste_graph/intent_cache.py`:

```python
import hashlib, re
from datetime import datetime, timezone

INTENT_KEY_PREFIX = "srvn:intent"
QUERY_EMBED_KEY_PREFIX = "srvn:query_embed"
INTENT_BUDGET_PREFIX = "srvn:intent:calls"
_PUNCT_RE = re.compile(r"[^\w\s]")

def normalize_query(query: str) -> str:
    """'Date Night!' / 'date night' / 'night date' → same canonical key."""
    return " ".join(sorted(_PUNCT_RE.sub(" ", query.lower()).split()))

def query_hash(query: str) -> str:
    return hashlib.sha1(normalize_query(query).encode()).hexdigest()[:16]

def cached_intent(redis_client, query: str) -> IntentSchema | None: ...
def cache_intent(redis_client, query: str, intent: IntentSchema, ttl_s: int) -> None: ...
def cached_query_embed(redis_client, query: str) -> list[float] | None: ...
def cache_query_embed(redis_client, query: str, vec: list[float], ttl_s: int) -> None: ...

def daily_budget_check_and_incr(redis_client, daily_budget: int) -> tuple[bool, int]:
    """Returns (ok, current_count). Atomic INCR + TTL-on-first-creation;
    mirrors utils/rate_limit.py:_incr_with_ttl."""
    key = f"{INTENT_BUDGET_PREFIX}:{datetime.now(timezone.utc).strftime('%Y-%m-%d')}"
    current = int(redis_client.incr(key))
    if current == 1:
        redis_client.expire(key, 48 * 3600)
    return current <= daily_budget, current
```

Query-embed value serialization: store as JSON array (`json.dumps(vec)`), reload via `json.loads`. Small (~12KB for 1536 floats); acceptable for 1h TTL cache.

### 1.6 Tests

Under `tests/srvn_backend/services/srvn_taste_graph/`:

- `test_intent_parser.py` — patch `ChatOpenAI.invoke`; assert structured output schema enforced; malformed LLM response raises `IntentParseError`; system prompt contains the controlled `vibe_tags` vocab; happy-path returns `IntentSchema` with expected fields populated; timeout path raises `IntentParseError`; `metadata={"surface":"srvn_intent_parser"}` round-trips.
- `test_intent_cache.py`:
  - **Normalization**: `normalize_query("Date Night!")` == `normalize_query("date night")` == `normalize_query("night date")`
  - **Hash determinism**: same normalized input → same hash; different input → different hash
  - **Cache roundtrip**: write `IntentSchema` → read back; expires after TTL
  - **Daily budget**: 100 calls under budget → all `ok=True`; 101st returns `ok=False`; counter survives across calls; 48h TTL verified via mocked clock
  - **Budget atomicity**: parallel calls don't double-count (Redis INCR atomic)
  - **Query embed roundtrip**: write 1536-float vector → read back equal within float epsilon

### 1.7 Verification (PR 1)

- `poetry run flask db upgrade` — succeeds; `\d srvn_spot_taste_features` shows 4 new columns + GIN index
- `poetry run pytest tests/srvn_backend/services/srvn_taste_graph/test_intent_*.py -m api` — green
- Existing test suite stays green

---

## PR 2 — Spot feature enrichment workers

No user-visible change. Two sub-deliverables, can ship together as one PR.

### 2.1 `spot_features_extractor` extension

Extend `extract_features(spot_id, session)` (created by MVP PR 2) to additionally write:

**`vibe_tags`** — materialized from `Spot.info` vibe booleans:

```python
vibe_tag_map = [
    (info.get("good_for_groups"),   "group"),       # also goes to occasion_tags (MVP)
    (info.get("live_music"),        "live_music"),
    (info.get("outdoor_seating"),   "outdoor"),
    (info.get("serves_cocktails"),  "cocktails"),
    (info.get("serves_dessert"),    "dessert"),
    (info.get("serves_coffee"),     "coffee"),
    (info.get("serves_breakfast"),  "breakfast"),
    (info.get("serves_lunch"),      "lunch"),
    (info.get("serves_dinner"),     "dinner"),
    (info.get("reservable"),        "reservable"),
    (info.get("dine_in"),           "dine_in"),
]
features.vibe_tags = [tag for cond, tag in vibe_tag_map if cond is True]
```

Note: `vibe_tags` are MVP's `Features:` line distilled into a structured array — same source data, two surfaces (one for embedding, one for SQL `&&` candidate filter).

**`top_review_snippet`** — pick from `Spot.info["reviews"]`:

```python
def pick_top_review_snippet(reviews: list[dict]) -> str | None:
    eligible = [r for r in reviews if r.get("language_code") == "en"
                and r.get("text") and r.get("rating") is not None]
    if not eligible:
        return None
    eligible.sort(key=lambda r: (r["rating"], r["publish_time"]), reverse=True)
    raw_text = eligible[0]["text"]
    return _truncate_at_word(raw_text, max_chars=200)
```

`_truncate_at_word(text, max_chars)` cuts at the last word boundary ≤ `max_chars`, appends `…` if truncated. Helper lives in `text_builder.py` next to MVP's `build_*_taste_text` functions.

If `Spot.info["reviews"]` is missing/empty → `top_review_snippet = None`. Endpoint serializes as null; UI omits.

**Hash-skip**: extend MVP's `taste_text_hash` to cover `vibe_tags` (since they appear in MVP's `Features:` line of `taste_text`). `top_review_snippet` change does NOT clear `embedding_updated_at` — it's not part of `taste_text`.

### 2.2 New worker: `srvn_refresh_spot_taste_summaries`

New APScheduler job in `ressy_backend/tasks.py`. Cron daily 03:00 UTC (after MVP's 02:00 `srvn_refresh_spot_features`):

```python
def srvn_refresh_spot_taste_summaries():
    with scheduler.app.app_context():
        if not CONFIG.SRVN_TASTE_SUMMARY_ENABLED:
            log("event=srvn_summary_tick status=disabled")
            return
        # Daily budget check (mirrors MVP embed worker §6.2 step 2)
        used = int(CONFIG.REDIS_CLIENT.get(_BUDGET_KEY) or "0")
        if used >= CONFIG.SRVN_TASTE_SUMMARY_DAILY_BUDGET:
            log("event=srvn_summary_tick status=budget_exhausted")
            return
        # Candidate: features_updated_at > taste_summary_updated_at OR taste_summary_updated_at IS NULL
        # AND embedding exists (so summary has structured content to reference)
        rows = SrvnSpotTasteFeatures.query.filter(...).limit(CAP).all()
        for f in rows:
            summary = _llm_compress_to_summary(f, spot=f.spot)
            f.taste_summary_text = summary
            f.taste_summary_updated_at = func.now()
            db.session.commit()
            CONFIG.REDIS_CLIENT.incr(_BUDGET_KEY)
            CONFIG.REDIS_CLIENT.expire(_BUDGET_KEY, 48 * 3600)
```

`_llm_compress_to_summary(features, spot)` — single gpt-4o-mini call with prompt: "Compress this restaurant's structured taste features and editorial summary into a ≤200-character third-person vibe description. No marketing language; describe the experience." Input: structured features (cuisines, vibe_tags, occasion_tags, price_tier) + `Spot.info["editorial_summary"]` + `spot.name`. Output: plain string, validated ≤220 chars (small slack for tokenizer drift), stored as-is.

Per-spot transaction (matches MVP signal-aggregator pattern — keeps recovery simple). On LLM failure: log + skip the row (don't retry inline; next tick picks it up).

### 2.3 One-shot backfill CLI

New CLI command at `ressy_backend/commands/srvn_backfill.py` (or extend MVP's PR 2 backfill module if it exists):

```
flask srvn-backfill-summaries [--limit N] [--dry-run]
```

For initial population at deploy time. Runs the same `_llm_compress_to_summary` loop over all spots, but synchronously and with high parallelism (`asyncio.gather` over batches of 10). At 500 spots:

- Cost: 500 × ~$0.0001 = **~$0.05**
- Wall-clock: ~1–2 min with light parallelism

Register the command in `app.py` next to existing CLI commands (mirror whatever pattern exists; if no current pattern, use `@app.cli.command("srvn-backfill-summaries")`).

Run order at MVP→Phase 2 deploy:

1. MVP deploys (spot embeddings start populating via worker)
2. Wait ~30 min for spot embedding coverage
3. Phase 2 PR 1 + PR 2 deploys
4. `flask srvn-backfill-summaries` runs (~1–2 min)
5. PR 3 deploys with `SRVN_INTENT_ENABLED=true` — endpoint ships against fully-populated data

### 2.4 Scheduler registration

In `ressy_backend/app.py` `register_scheduler()`, inside the existing `START_SCHEDULER` gate:

```python
scheduler.add_job(
    id="srvn_refresh_spot_taste_summaries",
    func=srvn_refresh_spot_taste_summaries,
    trigger="cron", hour=3, minute=0,
)
```

### 2.5 Tests

Under `tests/srvn_backend/services/srvn_taste_graph/`:

- `test_spot_features_extractor_vibe_tags.py` — extends MVP's `test_spot_features_extractor.py`:
  - All vibe booleans True → all corresponding `vibe_tags` populated
  - All False/missing → `vibe_tags=[]`
  - Mix (e.g. `live_music=True, outdoor_seating=True, others=False`) → exactly two tags
  - Hash-skip bumps `taste_text_hash` when `vibe_tags` changes (since they appear in `Features:` line)
  - `top_review_snippet` selects highest-rated en review
  - Multiple reviews with same rating → tiebreak by most recent `publish_time`
  - All reviews `language_code != "en"` → snippet is None
  - Review text > 200 chars → truncated at word boundary, `…` suffix
  - Empty/missing `Spot.info["reviews"]` → snippet is None (no crash)
- `test_taste_summary_worker.py`:
  - **Disabled flag**: `SRVN_TASTE_SUMMARY_ENABLED=false` → tick short-circuits, no LLM call
  - **Budget exhausted**: Redis day counter ≥ budget → tick returns without LLM call
  - **Happy path**: seeded spot with populated features → LLM mock returns 150-char string → row updated; `taste_summary_updated_at` set
  - **Idempotence**: next tick with no feature change → row skipped (where clause)
  - **LLM failure**: mock raises → row skipped, no transaction rollback for OTHER rows
  - **Over-length output**: LLM returns 300-char string → validation fails, row skipped, log emitted
- `test_srvn_backfill_summaries_cli.py`:
  - **Dry-run**: counts rows that would be updated; no LLM call; no DB writes
  - **Limit**: `--limit 10` processes exactly 10 spots
  - **Idempotence**: re-running with no spot changes → 0 updates

### 2.6 Verification (PR 2)

- `poetry run pytest tests/srvn_backend/services/srvn_taste_graph/test_spot_features_extractor_vibe_tags.py test_taste_summary_worker.py test_srvn_backfill_summaries_cli.py -m api` — green
- Local dev: `START_SCHEDULER=true poetry run flask run`; tail logs for `srvn_refresh_spot_taste_summaries` tick at 03:00 UTC (or trigger manually via Python shell)
- DB spot-check: `SELECT spot_id, taste_summary_text, vibe_tags, top_review_snippet IS NOT NULL FROM srvn_spot_taste_features LIMIT 10;` after backfill CLI run

---

## PR 3 — Endpoint + scoring + query embed

User-visible flip. Behavior gated by `SRVN_INTENT_ENABLED` so blueprint registration can be toggled per environment without a revert.

### 3.1 Extend `embedding_client.py`

Add to the `EmbeddingClient` Protocol AND `OpenAIEmbeddingClient`:

```python
def embed_query(self, text: str) -> list[float]:
    """Single-element batch with metadata for billing attribution."""
    result = self._client.embeddings.create(
        input=[text],
        model=CURRENT_EMBEDDING_MODEL,
        metadata={"surface": "srvn_intent_query"},
    )
    return result.data[0].embedding
```

Add module-level helper:

```python
def vector_to_str(vec: list[float]) -> str:
    """Format for pgvector binding: '[0.123,0.456,...]'::vector."""
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"
```

Token spend lands in MVP's existing `srvn:embed:tokens:{date}` Redis counter (so `SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET` covers query embeds too — single accounting source).

### 3.2 Extend `scoring.score_candidate(...)`

Add optional `query_vector: list[float] | None = None` and `intent: IntentSchema | None = None` params. When `query_vector` provided AND `features.taste_embedding` non-NULL AND models match:

```python
s_query_match = 1 - cosine_distance(query_vector, features.taste_embedding)

# Weight redistribution when query present:
# distance 0.30→0.20, embedding 0.25→0.18, cuisine 0.20→0.17,
# price 0.10 unchanged, popularity 0.15 unchanged, NEW query_match 0.30
score = 0.20*s_distance + 0.18*s_embedding + 0.17*s_cuisine \
      + 0.10*s_price + 0.15*s_popularity + 0.30*s_query_match
```

When query absent → existing MVP formula unchanged.

Intent-driven boosts (additive on top of query_match):

- If `intent.occasion` matches `features.occasion_tags` → `s_query_match *= 1.1` (cap at 1.0)
- If `intent.vibe_tags ∩ features.vibe_tags` non-empty → `s_query_match *= 1.05` per overlap (cap at 1.2x total)

Cold-start fallback (no user embedding AND no signals) — drop `s_embedding` + `s_cuisine`, renormalize remaining over `s_query_match` + `s_distance` + `s_price` + `s_popularity`. Matches MVP cold-start pattern. Query users still get personalization via `s_query_match`.

### 3.3 New retrieval method on `Spot`

Add `Spot.find_nearby_with_intent(latitude, longitude, radius_meters, query_vector, intent, limit_candidates=200)` to `ressy_backend/models/spot.py`. Reuse `_text_search_filter` if needed; mirror existing `find_nearby` pattern.

Stage 1 SQL pre-order:

```sql
SELECT s.*, ST_Distance(...) AS distance_m,
       1 - (f.taste_embedding <=> :query_emb::vector) AS taste_similarity
FROM spots s
LEFT JOIN srvn_spot_taste_features f ON f.spot_id = s.id
WHERE ST_DWithin(s.location::geography, ...)
  AND s.deleted_at IS NULL
  AND (
    -- Intent vibe filter when present and non-empty:
    :intent_vibe_tags IS NULL OR f.vibe_tags && :intent_vibe_tags
  )
  AND (
    -- Intent occasion filter when present:
    :intent_occasion IS NULL OR :intent_occasion = ANY(f.occasion_tags)
  )
ORDER BY taste_similarity DESC NULLS LAST, distance_m ASC
LIMIT 200;
```

Returns `(Spot, distance_m, taste_similarity)` tuples for Python rerank.

Intent SQL filters degrade gracefully: if intent parser failed (caller passes `intent=None`), the `vibe_tags &&` and `occasion =` filters are bypassed. If LLM returned an intent but it produced zero candidates, retry with filters dropped (one fallback round, not a multi-step cascade — cascade is Phase 3 work per MVP cuts).

### 3.4 New blueprint: `routes/srvn_recommend_by_intent.py`

```python
srvn_recommend_by_intent_blueprint = Blueprint(
    "SrvnRecommendByIntent",
    __name__,
    description="Free-text vibe-based recommendation endpoint",
    url_prefix="/spots/recommend-by-intent",
)

@srvn_recommend_by_intent_blueprint.route("", methods=["POST"])
@srvn_recommend_by_intent_blueprint.arguments(IntentQuerySchema, location="json")
@jwt_required()
@srvn_recommend_by_intent_blueprint.response(IntentRecommendationsSchema, status_code=HTTPStatus.OK)
def recommend_by_intent(payload):
    if not CONFIG.SRVN_INTENT_ENABLED:
        abort(404)  # Endpoint not registered if disabled; this guards in-flight requests during ops flip
    user_id = get_jwt_identity()
    # Budget check
    ok, _ = daily_budget_check_and_incr(CONFIG.REDIS_CLIENT, CONFIG.SRVN_INTENT_DAILY_BUDGET)
    if not ok:
        # Degrade: fall back to MVP /spots/recommended scoring locally (no query_match, no intent filters)
        return _degraded_response(payload, user_id, reason="budget_exhausted")
    # Stage 1A + 1B in parallel via threads (gpt-4o-mini + openai embed)
    intent_future = executor.submit(_intent_with_cache, payload["query"])
    query_emb_future = executor.submit(_query_embed_with_cache, payload["query"])
    try:
        intent = intent_future.result(timeout=4.0)
    except IntentParseError:
        intent = None  # fall back to embedding-only retrieval
    try:
        query_emb = query_emb_future.result(timeout=4.0)
    except OpenAIError:
        abort(503, message="search_temporarily_unavailable", headers={"Retry-After": "5"})
    # Stage 2 candidate SQL
    candidates = Spot.find_nearby_with_intent(
        latitude=payload["latitude"],
        longitude=payload["longitude"],
        radius_meters=payload.get("radius", 5000),
        query_vector=query_emb,
        intent=intent,
    )
    # Stage 3 Python rerank + response
    profile = SrvnUserTasteProfile.query.filter_by(user_id=user_id).first()
    signals = SrvnUserTasteSignals.query.filter_by(user_id=user_id).first()
    ranked = sorted(
        candidates,
        key=lambda c: scoring.score_candidate(
            profile=profile, features=c.spot.taste_features, signals=signals,
            user=current_user, distance_m=c.distance_m,
            popularity_signal=..., global_max_popularity=GLOBAL_MAX,
            query_vector=query_emb, intent=intent,
        ),
        reverse=True,
    )[:payload.get("limit", 20)]
    return _serialize_intent_response(ranked, intent)
```

`_intent_with_cache(query)`:

1. Check `cached_intent(REDIS_CLIENT, query)` → if hit, return
2. Else call `parse_intent(query)`; cache result with TTL; return

`_query_embed_with_cache(query)`: same pattern with `cached_query_embed` + `EmbeddingClient.embed_query`.

`_serialize_intent_response(ranked, intent)`:

- Each spot card carries: existing fields from `SpotController.prepare_spots_for_response(...)` (preserves `saved`) + new top-level fields `taste_summary_text`, `top_review_snippet`, `vibe_tags`, `distance_m`
- Response envelope (additive to existing `PagedSpotsSchema` if reused, or fresh `IntentRecommendationsSchema`):

```json
{
  "items": [
    { "id": 1, "name": "...", "distance_m": 432, "saved": false,
      "taste_summary_text": "Cozy Italian wine bar with...",
      "top_review_snippet": "Best carbonara I've had outside Rome...",
      "vibe_tags": ["wine_bar", "intimate", "live_music"]
    }
  ],
  "meta": {
    "intent": { "occasion": "date_night", "vibe_tags": ["jazz","bar"], ... } | null,
    "intent_parser_used": true,
    "query_embed_cached": false,
    "degraded": false | "budget_exhausted" | "intent_parser_failed"
  }
}
```

`_degraded_response(payload, user_id, reason)`:

- Skip intent parse + query embed
- Call existing MVP `Spot.find_nearby` + MVP scoring path (no `s_query_match`)
- Return same envelope shape with `meta.degraded=reason`

### 3.5 Blueprint registration

In `ressy_backend/app.py` `register_blueprints()`, gated:

```python
if CONFIG.SRVN_INTENT_ENABLED:
    from ressy_backend.routes.srvn_recommend_by_intent import srvn_recommend_by_intent_blueprint
    api.register_blueprint(srvn_recommend_by_intent_blueprint)
```

Per-environment toggle: ops can disable Phase 2 by setting `SRVN_INTENT_ENABLED=false` and restarting; clients get 404 instead of 503.

### 3.6 Schemas

New file `ressy_backend/schemas/srvn_recommend_by_intent.py`:

```python
class IntentQuerySchema(Schema):
    latitude = fields.Float(required=True, validate=validate.Range(min=-90, max=90))
    longitude = fields.Float(required=True, validate=validate.Range(min=-180, max=180))
    query = fields.String(required=True, validate=validate.Length(min=1, max=200))
    radius = fields.Integer(required=False, load_default=5000,
                            validate=validate.Range(min=100, max=15000))
    limit = fields.Integer(required=False, load_default=20,
                           validate=validate.Range(min=1, max=20))

class IntentRecommendationItemSchema(Schema):
    # Inherits/reuses existing SpotSchema fields
    distance_m = fields.Float(dump_only=True)
    taste_summary_text = fields.String(dump_only=True, allow_none=True)
    top_review_snippet = fields.String(dump_only=True, allow_none=True)
    vibe_tags = fields.List(fields.String(), dump_only=True)

class IntentRecommendationsSchema(Schema):
    items = fields.List(fields.Nested(IntentRecommendationItemSchema))
    meta = fields.Dict()
```

### 3.7 Tests

Under `tests/srvn_backend/api/`:

- `test_recommend_by_intent_basic.py`:
  - JWT + seeded user with declared cuisines + seeded spots with populated `taste_embedding` + `vibe_tags`
  - `POST /spots/recommend-by-intent` with `{latitude, longitude, query: "date night jazz bar"}` returns 200, 20 items, each with `taste_summary_text`, `top_review_snippet`, `vibe_tags`, `distance_m`
  - `meta.intent` populated with parsed `occasion`, `vibe_tags`, etc.
  - Assert ordering favors spots with matching vibe (jazz/live_music) over plain spots at similar distance
- `test_recommend_by_intent_cache.py`:
  - First call → `meta.query_embed_cached=false`, `meta.intent_parser_used=true`
  - Second identical call within TTL → both cache flags flip to `true`; LLM/embed mocks called once total
  - Different casing/punctuation: `"Date Night!"` vs `"date night"` → second hits cache (proves normalization)
- `test_recommend_by_intent_intent_fallback.py`:
  - Patch `parse_intent` to raise `IntentParseError`
  - Endpoint returns 200; `meta.intent=null`; results based on embedding-only retrieval (no `vibe_tags &&` SQL filter); `meta.degraded="intent_parser_failed"`
- `test_recommend_by_intent_embed_fallback.py`:
  - Patch `EmbeddingClient.embed_query` to raise transport error
  - Endpoint returns 503 with `Retry-After: 5`
  - Does NOT silently fall back to lexical FTS
- `test_recommend_by_intent_cold_start.py`:
  - User with no profile/signals; POST with query → 200, ≥1 result; no 500
  - Assert scoring still applies `s_query_match` (cold-start fallback drops `s_embedding`+`s_cuisine` only)
- `test_recommend_by_intent_budget.py`:
  - Set `SRVN_INTENT_DAILY_BUDGET=2`; make 3 requests
  - First two: normal path; third: `meta.degraded="budget_exhausted"`, no LLM calls (mock counters), results from MVP `Spot.find_nearby` path
- `test_recommend_by_intent_disabled.py`:
  - `SRVN_INTENT_ENABLED=false` → blueprint not registered → 404
- `test_score_candidate_with_query.py` (extends MVP `test_scoring.py`):
  - With `query_vector` + matching `vibe_tags` → score higher than baseline
  - With `query_vector` only (no intent) → `s_query_match` term still applied, no vibe boost
  - With both NULL → falls back to MVP formula
  - Cold-start user + query → `s_query_match` applied, `s_embedding`+`s_cuisine` dropped
- `test_find_nearby_with_intent.py`:
  - Seeded spots: 5 with `vibe_tags=["jazz"]`, 5 without
  - Intent with `vibe_tags=["jazz"]` → candidate pool prefers the matching 5
  - Intent with `vibe_tags=[]` → no filter applied, all spots in radius returned
  - Empty result + retry-without-filters → returns ≥1 spot

### 3.8 Verification (PR 3)

After PRs 1 + 2 deployed and CLI backfill complete:

1. JWT in hand; `POST /spots/recommend-by-intent` with `{latitude: 43.6532, longitude: -79.3832, query: "date night jazz bar"}` → 200, 20 items, populated content fields, `meta.intent` non-null
2. Re-issue same request within 1h → `meta.query_embed_cached=true`, `meta.intent_parser_used=true` (both cache hits), measurably faster (compare timing in test or curl `-w "%{time_total}\n"`)
3. Different casing: `"Date Night Jazz Bar"` → also hits cache (proves normalization)
4. Cold-start user (no saves, no taste profile): `POST` → 200, ≥1 result
5. `SRVN_INTENT_ENABLED=false`, restart → `POST` returns 404
6. Set `SRVN_INTENT_DAILY_BUDGET=0`, restart → `POST` returns 200 with `meta.degraded="budget_exhausted"` and results from distance-only path
7. Patch OpenAI embed key to be invalid → `POST` returns 503 with `Retry-After: 5`
8. Existing `/spots/recommended` unchanged: identical response shape and ordering before vs. after Phase 2 deploy (MVP regression)
9. Full `poetry run pytest` green

---

## Critical files to read before implementing

(Builds on MVP plan's critical-files list — these are Phase 2 additions/specifics.)

- `docs/plans/AI-Plans/request-time-ai-pipeline.md` — source plan; §§"Phase 1 minimum increment" + "Concrete spec diffs" + AC-2/4/5/7 + §65 cache hit perf
- `docs/plans/AI-Plans/srvn taste-graph MVP — implementation plan 1.md` — MVP plan; references for `embedding_client.py`, `scoring.py`, `spot_features_extractor.py`, `taste_taxonomies.py`, `text_builder.py` (all created by MVP, extended here)
- `ressy_backend/services/conversation_service.py:1-18` — langchain + OpenAI stack pattern; mirror imports + init style in `intent_parser.py`
- `ressy_backend/config.py:530-549` — Redis client setup (`REDIS_CLIENT` for decoded strings)
- `ressy_backend/utils/rate_limit.py:46-62` — `_incr_with_ttl` pattern for daily-budget counter
- `ressy_backend/routes/spot.py:63-68, 387-457` — Smorest blueprint declaration + current `/spots/recommended` for reference
- `ressy_backend/models/spot.py:184-244` — `Spot.find_nearby` PostGIS pattern; raw `db.text()` + `bindparams()` for pgvector cosine-distance
- `ressy_backend/app.py:140-177` — `register_blueprints()` site; gated registration pattern
- `ressy_backend/app.py:211-244` — `register_scheduler()` site; `START_SCHEDULER` gate for new `srvn_refresh_spot_taste_summaries` job
- `tests/conftest.py:90-129` — `make_user` factory + `auth_header` helper
- `tests/srvn_backend/api/test_onboarding_api.py:26-65` — `@pytest.mark.api` test-skip pattern

## Existing utilities to reuse (don't reinvent)

- `EmbeddingClient` Protocol (from MVP) — extend with `embed_query`, do not introduce a new client
- `scoring.score_candidate` (from MVP) — extend with `query_vector`/`intent`, do not duplicate the scoring formula
- `taste_taxonomies.CanonicalOccasion` + `CanonicalVibeTag` (new sibling) — single source of truth for vocab
- `SoftDeleteModel` base — `srvn_spot_taste_features` already inherits via MVP
- `flask_jwt_extended.get_jwt_identity` + `@jwt_required` — same JWT pattern as existing routes
- `SpotController.prepare_spots_for_response` — preserves `saved` field on items
- `Spot._build_order_by_clauses` / `_text_search_filter` — reuse for Stage 1 retrieval where applicable
- `CONFIG.REDIS_CLIENT` (decoded strings) — for cache + budget counters
- `CONFIG._RAW` env var + `__init__` parse pattern (from `START_SCHEDULER_RAW` line 293 / parse line 373) — for new config vars
- `langchain_openai.ChatOpenAI(...).with_structured_output(PydanticSchema)` — already in dep tree (langchain 0.3.20+), no new package

## Open items / followups (not blocking Phase 2)

1. **Anthropic SDK swap path**. If/when haiku is added to dependencies, `intent_parser.py` swaps `ChatOpenAI(...).with_structured_output(IntentSchema)` → `anthropic.Anthropic().messages.create(...)` with Anthropic's tool-use mode for structured output. Latency target tightens from ~600ms p50 → ~450ms p50 (matches source plan). Single-file change, no Phase 2 architectural impact. Triggered by: (a) the wider chatbot decision to adopt Claude, or (b) an A/B test showing parser failure rate is higher with gpt-4o-mini than acceptable.

2. **Vibe-tag vocabulary tuning**. The initial `CanonicalVibeTag` enum is sourced from intuition + Yelp/Resy-style categories. After Phase 2 ships, log all parsed `intent.vibe_tags` values for a month; review distribution; expand the canonical set to cover the top 80% of inputs. Bump `CURRENT_TAXONOMY_VERSION` accordingly. Same playbook as MVP §5a taxonomy bumps.

3. **Cache hit rate observability**. The endpoint logs `meta.query_embed_cached` and `meta.intent_parser_used` in the response, but a Redis `INFO commandstats` or per-request structured log would let ops measure cache hit rate without scraping responses. Add a tiny `srvn:intent:hits` / `srvn:intent:misses` daily counter pair in PR 3 if observability is wanted from day one.

4. **Score weight A/B tuning**. The `s_query_match=0.30` weight is an initial guess. Once Phase 2 ships, instrument click-through (when frontend tracking lands) and run a small `SRVN_SCORE_WEIGHTS_PROFILE` env-var experiment to compare against `s_query_match=0.25` and `0.35`. Phase 2 ships with the constant; AB tuning is a Phase 3 follow-up.

5. **`taste_summary_text` quality review**. After backfill CLI runs, sample 50 spots and manually review summaries. The gpt-4o-mini prompt may produce marketing-speak or repetitive phrasing; tune the system prompt iteratively. Worker idempotence makes re-summarizing cheap (~$0.05/full pass at 500 spots).

6. **Compliance** (same posture as MVP §7b — third-party LLM processing of user query text). Query text is user-typed and may contain PII the user voluntarily includes ("dinner for my wife's birthday"). The `metadata={"surface":"srvn_intent_query"}` tag enables zero-retention enforcement once the OpenAI DPA is signed. Add the surface to the Privacy Policy disclosure list alongside `srvn_taste_graph`.

7. **Group dining endpoint (Phase 4b)**. The natural follow-up — `POST /events/{event_id}/recommend-by-intent` with `group_taste_merger.py`. Spec is fully laid out in `request-time-ai-pipeline.md` §"Phase 2 — Group dining extension". Builds directly on Phase 2's endpoint + scoring; merge rules are well-defined (allergens UNION, dietary STRICTEST, embedding centroid). Estimated 1 PR after Phase 2 stabilizes.

## Execution sequencing note

Step 1 of execution (after this plan is approved): **move this plan file** from `~/.claude/plans/create-the-implementation-plan-nested-comet.md` into `docs/plans/AI-Plans/srvn taste-graph MVP — implementation plan 2.md` per the project's plan-location convention, then commit. The six plan docs in that folder become: the four originals + the synthesized roadmap + the MVP implementation plan (1) + this implementation plan (2).

Step 2: confirm MVP plan 1 has been merged and the embedding worker has populated ≥80% of spot taste embeddings (`SELECT count(*) FILTER (WHERE taste_embedding IS NOT NULL) * 100.0 / count(*) FROM srvn_spot_taste_features WHERE deleted_at IS NULL;`). At current 500-spot scale this is ~30 min after MVP deploy.

Step 3: open PR 1 (migration + config + intent parser foundation). Ship.

Step 4: open PR 2 (workers + backfill CLI). Ship. Run `flask srvn-backfill-summaries` in the production deploy window.

Step 5: open PR 3 (endpoint flip). Ship with `SRVN_INTENT_ENABLED=true` (current scale comfortably absorbs the worst-case ~$2.25/day intent cost).
