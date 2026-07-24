# Intent endpoint — `POST /spots/recommend-by-intent` (Slice 3: request-path caching)

_Date: 2026-07-07 · Status: implemented · Scope: caches the two per-request OpenAI calls (facet parse + query embed) behind Redis; no behavior change to results._

## Context

Slices 1–2 (PRs #211/#212) made the endpoint make **two paid OpenAI calls on every
request** — an LLM facet parse (`gpt-5-nano`) and a query embedding. Both are pure
functions of the query text and return the same result every time for the same query,
so repeat/identical queries re-pay for nothing and add hot-path latency. The Slice-2 doc
named caching the "recommended next PR."

Slice 3 adds two **best-effort** Redis caches keyed on the normalized query text. It is
**caching only** — the daily-budget breaker (`SRVN_INTENT_DAILY_BUDGET`) remains a
separate deferred follow-up (see below).

**Scope decision:** bare minimum — no `config.py` changes, TTLs as module constants (1h),
always on. Mirrors the existing `resolve_photo_uri` photo cache. No kill-switch, no env
vars.

## What Slice 3 adds (repeat query → cache hit)

```
"cheap quiet seafood"  ──► [parsed-intent cache]  key = normalize(raw query)
   │  miss → gpt-5-nano parse, then SETEX facets (1h)
   │  hit  → skip the parse call
   ▼
ParsedIntent(search_text="waterfront seafood", …)
   │
   ▼  embed_text = search_text
"waterfront seafood"   ──► [query-embed cache]     key = normalize(embed_text)
      miss → OpenAI embed, then SETEX vector (1h)
      hit  → skip the embed call
```

**Keying subtlety.** The parsed-intent cache keys on the **raw query**; the query-embed
cache keys on **`embed_text`** (the parser's `search_text` on a successful parse, else the
raw query). Keying the embed cache on the raw query would return the wrong vector whenever
the parser rewrote the text. Because `embed_text` is canonical, two different raw queries
the parser normalizes to the same `search_text` share one cached vector (the parse cache
still misses per raw query).

**Normalization** (roadmap §2.4): accent-fold + lowercase (`normalize_text_for_comparison`),
strip punctuation, split, **sort tokens**. So `"Date Night"`, `"date night"`,
`"night, date"` share one key. Token-sorting is safe for both: facets are order-independent,
and treating `"cheap quiet seafood"` ≡ `"quiet cheap seafood"` is the intended dedup for a
dining search (the tiny embedding difference is noise).

## Files

**New**
- `ressy_backend/services/srvn_taste_graph/intent_cache.py` — `_normalize_query`, key
  builders (`srvn:intent:facets:<hash>` / `srvn:intent:embed:<hash>` via `taste_text_hash`),
  and `get`/`set` for both caches. Module constants `_INTENT_FACET_CACHE_TTL` /
  `_QUERY_EMBED_CACHE_TTL = 3600`. Every Redis/JSON error is swallowed → miss/no-op
  (logs via `logging.getLogger(__name__)`, so it's safe to unit-test outside app context).
- `tests/srvn_backend/services/srvn_taste_graph/test_intent_cache.py` — fakeredis unit
  tests (normalization collisions, round-trip, TTLs, corrupt/wrong-shape entries,
  degradation on Redis error).

**Modified**
- `ressy_backend/routes/srvn_recommend_by_intent.py` — `_parse_intent_safe` and
  `_embed_query` check the cache first and write on success. **Only successful parses are
  cached** (a `None` degrade is never stored, so a transient error can't poison the cache);
  the embed's 503 `abort` paths run before the cache write, so a failed embed is never
  cached.
- `tests/srvn_backend/api/test_srvn_recommend_by_intent.py` — an autouse `flushdb` fixture
  (the suite shares one session fakeredis; several tests reuse query strings, so a stale
  cache entry would mask a test's stubbed parser/embed), a `calls` counter on the fake
  parser, and four cache cases (repeat-query hits both caches; distinct queries miss;
  wording variant shares; embed cache keys on `search_text` not the raw query).

## Reuse (no new infra)
- `CONFIG.REDIS_CLIENT` (`config.py`, `decode_responses=True`) — the string/JSON client.
- `resolve_photo_uri` (`googleplaces_services.py`) — the best-effort read→compute→`setex`
  template with try/except-swallow.
- `normalize_text_for_comparison` (`utils/general_util.py`), `taste_text_hash`
  (`services/srvn_taste_graph/hashing.py`), `ParsedIntent`
  (`services/srvn_taste_graph/intent_parser.py`, all-JSON-native frozen dataclass).

## Notes
- A cache hit reconstructs `ParsedIntent` with `usage_total_tokens=0` (a hit consumed no
  tokens) — reports the truth and pre-empts double-counting when the budget breaker lands.
  `model_id` is preserved.
- A cached vector is `json.loads` of the stored 1536-float list; JSON float round-trip is
  lossy at ~15 sig figs — negligible for cosine ranking. ~28 KB/entry, bounded by TTL.

## Verification
1. **Unit (always):** `poetry run pytest tests/srvn_backend/services/srvn_taste_graph/test_intent_cache.py` — 18 tests.
2. **Route wiring** (no DB): the helpers were exercised against fakeredis directly —
   identical (normalized) queries call the parser/embed once, a distinct query misses,
   keys land with `ttl=3600`.
3. **API/DB** (needs `RESSY_TESTING=1` + local `TEST_DATABASE_URL`):
   `poetry run pytest tests/srvn_backend/api/test_srvn_recommend_by_intent.py` — runs in CI.
4. **Live smoke:** POST the same `query` twice → confirm `redis-cli --scan --pattern
   'srvn:intent:*'` shows one `:facets:` + one `:embed:` key at `TTL ≈ 3600`; kill Redis
   mid-run → endpoint still 200 (best-effort degrade).

## Known follow-ups
- **Daily-budget breaker** (`SRVN_INTENT_DAILY_BUDGET`) — reuse the `srvn:*:tokens:` Redis
  idiom; account tokens at the cache-**miss** site so replays don't double-count.
- **`open_now` enforcement** (opening hours + timezone).
