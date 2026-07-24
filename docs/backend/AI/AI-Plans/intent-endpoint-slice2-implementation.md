# Intent endpoint — `POST /spots/recommend-by-intent` (Slice 2: LLM facet parser)

_Date: 2026-07-05 · Status: in progress · Scope: adds the facet parser + explicit-only hard filters and soft boosts on top of Slice 1 (embedding-first)._

## Context

Slice 1 (PR #211) shipped the embedding core: a free-text dining query is embedded once and
nearby spots are ranked by cosine similarity against the controlled `taste_embedding` and the
review-derived `review_digest_embedding`. It **deliberately deferred** the LLM facet parser — so a
query like *"cheap quiet seafood spot"* was embedded verbatim; "cheap" and "quiet" nudged the vector
but nothing enforced them.

Slice 2 adds `intent_parser.py`: a single OpenAI **GPT** call (Chat Completions + strict Structured
Outputs, mirroring `review_summarizer_client.py`) that turns the free text into a structured facet
object. The AI stack is OpenAI end-to-end — the roadmap's "haiku wrapper" framing was stale; there is
no Claude/`anthropic` dependency.

## What Slice 2 adds (query → facets → behavior)

```
"cheap quiet seafood spot near the water"
   │  OpenAIIntentParserClient.parse()  — one gpt-5-nano chat call, strict JSON schema
   ▼
ParsedIntent(search_text="waterfront seafood", cuisine="seafood",
             price_max=2, atmosphere="quiet", occasion=None,
             dietary=[], open_now=False)
   │
   ├─ search_text ─────────► what we embed (replaces the raw query)
   ├─ price_max ──────────► HARD SQL filter, NULL-tolerant
   ├─ atmosphere="quiet" ─► HARD review_noise filter (explicit token only)
   ├─ occasion ───────────► existing soft occasion bonus (parsed value wins over ?occasion)
   └─ dietary / cuisine ──► new soft additive bonuses in the scorer
```

**Explicit-only.** The model fills a facet *only* when the user states it — silence maps to
`null`/empty, never a guess. So an intent-free query (the common case) applies no filters and behaves
exactly like Slice 1. This is enforced in the system prompt (*"Fill a facet ONLY when the user
EXPLICITLY indicates it … Never infer or guess"*), so e.g. a query that says nothing about noise
leaves `atmosphere = null` and the `review_noise` filter never fires.

## Files

**New**
- `ressy_backend/services/srvn_taste_graph/intent_parser.py` — `ParsedIntent` (frozen dataclass),
  `IntentParserClient` (Protocol), `OpenAIIntentParserClient`, `IntentParseRefused`, and the strict
  `_INTENT_SCHEMA`. `_coerce_facets` clamps `price_max` to 1–4, lowercases `atmosphere`, and falls
  `search_text` back to the raw query when blank.
- `tests/srvn_backend/services/srvn_taste_graph/test_intent_parser.py` — unit tests (request shape,
  mapping, normalization, refusal/empty/non-JSON, key resolution, exception propagation).
- `docs/plans/AI-Plans/intent-endpoint-slice2-implementation.md` — this doc.

**Modified**
- `ressy_backend/routes/srvn_recommend_by_intent.py` — `_get_intent_parser_client()` factory +
  `_parse_intent_safe()` degradable wrapper; `_intent_candidates` gains the price/noise hard filters;
  the handler parses first, embeds `search_text`, and threads facets into recall + scoring.
- `ressy_backend/services/srvn_taste_graph/scoring.py` — `score_intent_candidate` gains optional
  `dietary` / `cuisine` params + additive soft bonuses.
- `ressy_backend/config.py` — `SRVN_GPT_5_NANO_MODEL` (default `gpt-5-nano`); reasoning effort
  reuses the shared `SRVN_OPENAI_REASONING_EFFORT` (renamed from
  `SRVN_REVIEW_DIGEST_REASONING_EFFORT`, default `medium`, used by the digest too).
- `docs/plans/AI-Plans/ai-execution-roadmap.md` — corrected the stale `claude-haiku-4-5` / "haiku"
  references to the shipped OpenAI reality.

## The facet parser — `intent_parser.py`

Chat Completions + strict Structured Outputs (the `openai` SDK is pinned at 1.58.1, which predates
the Responses API). Reasoning models reject a non-default `temperature` (400), so it is never sent;
`max_completion_tokens` caps reasoning + output. Billing is attributed via `user="srvn_intent_parser"`,
on the conversational (ZDR) key with `OPENAI_API_KEY` fallback — same zero-retention project as the
query embed and the review digests.

```python
_INTENT_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["search_text", "cuisine", "price_max", "atmosphere",
                 "occasion", "dietary", "open_now"],
    "properties": {
        "search_text": {"type": "string"},
        "cuisine":     {"type": ["string", "null"]},
        "price_max":   {"type": ["integer", "null"]},
        "atmosphere":  {"type": ["string", "null"]},
        "occasion":    {"type": ["string", "null"]},
        "dietary":     {"type": "array", "items": {"type": "string"}},
        "open_now":    {"type": "boolean"},
    },
}
```

Value ranges strict mode can't express (price 1–4, atmosphere token, blank `search_text`) are enforced
in the prompt + normalized in `_coerce_facets`. `cuisine`/`occasion`/`dietary` stay raw here and are
normalized against `taste_taxonomies.py` where consumed.

## Facet enforcement

| Facet | Slice 2 behavior | Backing column |
|---|---|---|
| `search_text` | what gets embedded | — |
| `price_max` | **hard** filter: `price_tier IS NULL OR price_tier <= price_max` | `price_tier` |
| `atmosphere` (`quiet`) | **hard** filter: `review_noise IS NULL OR review_noise NOT IN ('lively','loud')` — explicit token only | `review_noise` |
| `occasion` | soft bonus (`_OCCASION_BONUS`); parsed value overrides `?occasion` | `occasion_tags` |
| `dietary` | soft bonus `_DIETARY_BONUS * matched/requested` | `dietary_flags` |
| `cuisine` | flat soft bonus `_CUISINE_BONUS` on match | `cuisines` |
| `open_now` | parsed but **enforcement deferred** (needs hours + timezone) | — |

Both hard filters are **NULL-tolerant**: a spot with unknown price/noise is never dropped on missing
data — only an explicit over-cap or lively/loud value excludes it.

## Scoring — new soft bonuses

`score_intent_candidate` keeps its six weighted, renormalized terms untouched. Dietary + cuisine are
**additive bonuses** applied after renormalization and before the `[0, 1]` clamp — the same pattern as
the existing occasion bonus — so they never perturb the tuned base weight set and are a no-op when the
facet is unset or the spot lacks the tag.

## Degradation + failure modes

- **Parser failure is not a 503.** A refusal, transport error, or missing key → `_parse_intent_safe`
  returns `None` → we embed the raw query and apply no facets (Slice-1 behavior). The parser is
  optional; only the *required* query embed keeps Slice 1's 503 + `Retry-After`.
- **Malformed model output** (refusal / truncation / empty / non-JSON / bad shape) →
  `IntentParseRefused` inside the parser → caught by `_parse_intent_safe` → degrade.

## Config

`SRVN_GPT_5_NANO_MODEL` defaults to `gpt-5-nano` — the cheapest current tier (~5× cheaper than
`gpt-5-mini`), right-sized for short free-text → JSON extraction. Reasoning effort: the shared
`SRVN_OPENAI_REASONING_EFFORT` knob (renamed from `SRVN_REVIEW_DIGEST_REASONING_EFFORT`; default
`medium`) governs the batch review digest, but the request-path parser **pins `minimal`** at the call
site (`_get_intent_parser_client`) — a hot-path extraction doesn't need deep reasoning, so this keeps
latency + cost down without a second env var. Escalate the parser model to `gpt-5-mini` only if evals
show missed facets.

## Tests

**Parser unit** (`test_intent_parser.py`): request shape (model, `user`, strict `response_format`,
`reasoning_effort`, `max_completion_tokens`, no `temperature`), JSON→`ParsedIntent` mapping,
normalization (price clamp, blank `search_text` fallback, atmosphere lowercasing),
refusal/length/empty/non-JSON/bad-shape → `IntentParseRefused`, empty query → `ValueError` with no API
call, transport-error propagation, and key resolution.

**Scoring unit** (`test_scoring_intent.py`): dietary bonus graded by match fraction, cuisine flat
bonus on match, no-op when the spot lacks the tag, and the `[0, 1]` clamp holds.

**API** (`test_srvn_recommend_by_intent.py`, `@pytest.mark.api`): a module autouse fixture stubs a
no-facet parser so no test hits the network; facet tests override it. Cases: `price_max` excludes
over-cap but keeps NULL-price spots; explicit `quiet` excludes loud spots; parser failure still
returns 200 (embedding-only, not 503); `search_text` (not the raw query) is what gets embedded. The
`test_recommended_ignores_review_signal` compliance guard is unaffected.

## Verification

1. `poetry run pytest tests/srvn_backend/services/srvn_taste_graph/test_intent_parser.py tests/srvn_backend/services/srvn_taste_graph/test_scoring_intent.py` — pure-Python, always run.
2. The API/DB tests need `RESSY_TESTING=1` + a local `TEST_DATABASE_URL`:
   `poetry run pytest tests/srvn_backend/api/test_srvn_recommend_by_intent.py`.
3. Live smoke with `SRVN_INTENT_SEED_ONLY=1`: `POST /spots/recommend-by-intent` with *"cheap quiet
   seafood spot"* → over-cap / loud seed spots dropped, only `SEED_FAKE_` spots returned. Force a
   parser failure (bad parser key) and confirm the request still returns 200 (degradation), while a
   bad *embed* key still 503s.

## Known follow-ups

- **Caching (recommended next PR):** query-embed cache (`SRVN_QUERY_EMBED_CACHE_TTL`) + parsed-intent
  cache (Redis SETEX, key on normalized query). The parser is a pure function of the normalized query,
  so a cache slots in trivially — without it every request makes a hot-path GPT call.
- **Daily-budget breaker** (`SRVN_INTENT_DAILY_BUDGET`, reuse the `srvn:*:tokens:` Redis idiom).
- **`open_now` enforcement** (opening hours + timezone).
- **Digest-model staleness — not needed:** all embedding surfaces use one model
  (`text-embedding-3-small`) and swapping it is not planned, so `s_review_match`'s ungated cosine is
  correct. *Only* if `SRVN_EMBEDDING_MODEL` is ever changed must a swap first add a
  `review_digest_embedding_model` column, gate `s_review_match` on it, and re-embed.
