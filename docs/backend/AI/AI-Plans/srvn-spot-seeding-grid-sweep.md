# srvn spot seeding — resumable Google Nearby grid sweep

> **Status (upd. 2026-07-05): ✅ Shipped (PRs #194–195).** The two-mode grid sweep is live — `SrvnSeedGridCell` model, `srvn_spot_seeder.py`, and the `srvn-seed` CLI (`init-grid`/`run`/`status`/`reset`) with both `exhaustive` and `popular` modes. Historical design record below. Design verified against the codebase on 2026-06-12; re-planned **2026-06-22** around a two-mode design (primary = exhaustive-by-neighborhood, secondary = metro popular-core); **review pass 2026-06-22** re-verified all code references and closed five gaps — claim-then-release locking, `error`/stale-`in_progress` recovery (`reset` + `retry_count`), `upsert_serialized_spots` error/return contract, `init-grid` bbox-size guard, and coord rounding for stable UNIQUE idempotency; **mask-policy change 2026-06-22** — all Google calls (live `/spots`, both seed modes, and Place Details refresh) are now **Pro + Enterprise only** (no atmosphere/photos/reviews → $35/1k Enterprise SKU), so the two modes now differ **only in ranking + subdivision**, not mask or SKU. This plan adds a *bulk pre-seed* path for the `Spot` catalog that does not exist today — currently spots are only created lazily on cache-miss inside `get_or_create_spots_from_google()` (`ressy_backend/services/spot_service.py:12`). Nothing here changes the live `/spots/*` request path.

## Goal

Pre-populate the `Spot` table using Google Places **Nearby Search (New)**, tiling an area with small circular searches to beat the hard **20-results-per-request cap** (Nearby New has no pagination — subdivision is the only way past 20). Two modes, sharing one resumable grid + dedup + budget engine:

- **PRIMARY — `exhaustive` (default).** **DISTANCE** ranking, subdivide **until complete** (no cell returns 20). Scoped to a **neighborhood** (e.g. a 500 m–2 km bbox). Gets **every** spot the area has in Google, unbiased by popularity — and at neighborhood scale it's **$0** (a dense 500 m-radius area ≈ 150–400 calls, under the free tier). This is the launch play: complete coverage where users actually are.
- **SECONDARY — `popular` (flagged).** **POPULARITY** ranking, subdivision **capped** (depth 2). Scoped to a **metro**. Captures the popular core broadly and cheaply over 2–3 monthly runs at $0. Use when you want thin, wide coverage rather than complete neighborhoods.

Both modes use the **same Pro + Enterprise field mask** (`nearby_field_paths`) — **no atmosphere, no photos, no reviews** — billing at the **$35/1k Enterprise SKU** (mask policy changed 2026-06-22). They differ only in **ranking + subdivision**. Both are **resumable** (a monthly run never re-sweeps ground already covered) and **budget-capped** (≤ 950 Nearby calls/month → $0 under the free tier).

### Two modes at a glance

| | PRIMARY `exhaustive` (default) | SECONDARY `popular` (flag) |
|---|---|---|
| Ranking | **DISTANCE** | POPULARITY |
| Subdivision | **until no cell returns 20** (safety depth cap) | capped at **depth 2** |
| Field mask | Pro + Enterprise (`nearby_field_paths`) — no atmosphere/photos/reviews | **same** |
| Billing SKU | Enterprise ($35/1k, 1,000 free) | Enterprise ($35/1k, 1,000 free) |
| Scope | one neighborhood (≤ ~few km²) | metro |
| Coverage | **complete**, unbiased | popular core, popularity-biased |
| Seed-row fidelity | medium (types + price + rating + hours; no atmosphere/photos/reviews) | **same** |
| Cost | **$0** at neighborhood scale | $0 over 2–3 months |

> **Why the package, not a free toggle:** DISTANCE only pays off *with* until-complete subdivision — once every cell returns <20 it has captured everything, so ranking stops mattering and DISTANCE just removes Google's popularity bias. POPULARITY's only edge — keeping the *best* 20 in cells you leave over-dense — exists only *because* the secondary mode caps subdivision. So `rank + subdivision` move together as a mode; mixing them (e.g. DISTANCE + cap) is strictly worse. (Masks are now identical across modes — see the mask-policy note — so only rank + subdivision distinguish them.)

## Why this design (cost rationale)

Verified Google Places (New) pricing, June 2026:

| SKU | Price / 1,000 | Free / month |
|---|---|---|
| Nearby Search **Pro** | $32 | 5,000 |
| Nearby Search **Enterprise** | **$35** | **1,000** |
| Nearby Search **Enterprise + Atmosphere** | $40 | **1,000** |
| Place Details **Photos** (resolve) | $7 | — |

Key levers:

- **One Nearby request returns up to 20 places**, paid per *request* not per *spot*. Effective yield after grid overlap is **~10–13 distinct spots/call** (overlap ≈ 1 − 2/π ≈ 36%).
- **One free allotment, shared by both modes.** Both modes now use the Pro + Enterprise mask → the **Enterprise SKU ($35/1k, 1,000 free/month)**. (Pre-2026-06-22 the exhaustive mode used the Enterprise + Atmosphere $40 SKU with its own separate free bucket; dropping atmosphere/photos collapsed both modes onto the single Enterprise bucket.) The 950 cap keeps a month under that 1,000-free allotment.
- **Cost scales with spots collected, not with ranking.** DISTANCE itself is free (same SKU). Exhaustive costs more than popular-core only because it collects more places (the long tail) — roughly `calls ≈ places / 11` for a flat grid pass.
- **Two overlap taxes — exhaustive pays both.** The `places / 11` figure captures only **adjacency overlap** (the `1 − 2/π ≈ 36%` ring of each circle that spills into neighbors). Until-complete subdivision adds a second tax: **ancestral re-coverage** — every saturated cell's 4 children re-search the parent's already-swept footprint, re-finding (and de-duping away) spots the parent already stored to surface the long tail the 20-cap hid. In a quadtree, internal nodes ≈ leaves/3, so total calls ≈ `1.33 × leaves` and the realistic divisor in a dense, deeply-subdividing core is closer to **`places / 8–9`, ~30% more calls than `/11`**. This never overspends (the 950 cap is hard) and never loses coverage (resumability finishes it next run) — it just means dense cores can span **2 monthly runs**. `--cell-radius` trades the two taxes off: a smaller root radius pays more adjacency overlap up front but triggers less subdivision depth.
- **Neighborhood-scale exhaustive is tiny.** A dense 500 m-radius downtown area (~0.785 km², ~800–1,500 spots) needs only ~150–400 calls → **$0** on the $35 Enterprise SKU (use the `/8–9` end for ultra-dense cores). The blow-up only happens at metro scale (~$90–260 one-time for a whole metro exhaustively at $35/1k), which is exactly when you'd switch to the secondary popular-core mode.

### Field-mask policy — Enterprise-only (decided 2026-06-22)

Every Google call — live `/spots`, **both** seed modes, and the Place Details refresh — uses a **Pro + Enterprise** mask: **no atmosphere, no photos, no reviews**. All Nearby calls bill at the **$35/1k Enterprise SKU**; Place Details (`get_restaurant_details`) is likewise Enterprise-only (no `reviews`, which for Place Details is itself an Enterprise + Atmosphere field).

Rationale: atmosphere fields, `photos`, and `reviews` each push a call to the **Enterprise + Atmosphere ($40/1k)** tier and add downstream cost (photo-URI resolution at $7/1k), while the launch priority is broad, cheap coverage over per-row richness.

Concretely, in `ressy_backend/services/googleplaces_services.py`:
- `nearby_field_paths` and `seed_lean_field_paths` are now **identical** — `_PRO_TIER_FIELDS + _ENTERPRISE_TIER_FIELDS` (`id, displayName, formattedAddress, shortFormattedAddress, types, primaryTypeDisplayName, location, businessStatus, googleMapsUri, addressComponents, postalAddress, timeZone` + `rating, userRatingCount, priceLevel, priceRange, currentOpeningHours, regularOpeningHours, internationalPhoneNumber, nationalPhoneNumber, websiteUri`). Both seed modes **and** the live path use this.
- `detail_field_paths` = those two tiers + `movedPlaceId` only (bare names for `get_place`).
- The atmosphere group survives as `_ATMOSPHERE_TIER_FIELDS` (defined but used by no mask); re-enabling atmosphere/photos/reviews later is a one-line edit per mask.

Seed rows are **medium fidelity**: types, `primaryTypeDisplayName`, price, `rating`/`userRatingCount`, opening hours, address, phone, website, timezone. No `Features:` line (atmosphere), no photos, no reviews. Because the **refresh path is also Enterprise-only now**, a later `refresh-spots` pass adds *nothing* richer unless those masks are re-enabled first (§9).

> **Taste-graph consequence.** The sc-120 atmosphere fields fed `spot_features_extractor` (dietary_flags, occasion_tags) and the `Features:` line in `taste_text`. With atmosphere dropped everywhere those are empty/absent and `taste_text` is thinner (types + price + rating only). The embedding still runs; it just carries less signal. Re-enable `_ATMOSPHERE_TIER_FIELDS` on `nearby_field_paths`/`detail_field_paths` if taste quality needs it.

> **Cuisine taxonomy bumped to v3 (2026-06).** The expanded `seed_included_types` (and Google's Feb-2026 type release) introduced many cuisine slugs that `CUISINE_ALIASES` (`services/srvn_taste_graph/taste_taxonomies.py`) didn't map — so those spots' `cuisines` would have been empty. The alias map was extended (and 4 broad canonicals added: `asian`, `european`, `eastern_european`, `dessert`), with `CURRENT_TASTE_TAXONOMY_VERSION` bumped **2 → 3** and the pinned snapshot in `test_taste_taxonomies.py` updated. **Do not revert the vocab edit without the version bump** — the embedding worker re-embeds rows on `taxonomy_version` mismatch (cheap: ~cents under the 10M/day budget), and the `cuisines` column refreshes on the next `srvn_refresh_spot_features` extraction. This applies to **all** spots, not just seeded ones.

(Pro-only — $32/1k, 5,000 free — was considered but rejected: reaching it also requires dropping `rating`/`userRatingCount`/price/hours/phone/website, leaving bare shells. Keeping the Enterprise tier means even seed rows are immediately rankable.)

## Design overview

```
init-grid (per region, picks --mode)        run (≤950 calls/month, resumable, mode read per cell)
┌──────────────────────────────┐            ┌────────────────────────────────────────────────┐
│ bbox + cell radius + mode    │            │ while month budget > 0:                          │
│   → generate grid cells      │            │   ── claim one cell ──                           │
│   → INSERT status=pending,   │   ──▶       │   cell = SELECT … WHERE status='pending'         │
│     mode stamped on each     │            │          ORDER BY depth,id LIMIT 1               │
└──────────────────────────────┘            │          FOR UPDATE SKIP LOCKED                  │
                                            │   if none: break                                │
                                            │   cell.status='in_progress'; COMMIT (release)    │
 exhaustive: subdivide until <20            │   ── process (HTTP outside any held lock) ──     │
 popular:    subdivide only if depth<2      │   rank/mask ← cell.mode                          │
                                            │   get_nearby_restaurants(rank, mask) ×1          │
                                            │   redis.incr(srvn:seed:calls:YYYY-MM)            │
                                            │   upsert_serialized_spots(results)               │
                                            │   ── finalize ──                                 │
                                            │   status = (result_count==20) ? saturated : done │
                                            │   if saturated & under cap → enqueue 4 children  │
                                            │   COMMIT (per cell)                              │
                                            └────────────────────────────────────────────────┘
```

The unit of idempotency is the **grid cell (= one request)**, persisted in a new `srvn_seed_grid_cells` table. A swept cell is `done`/`saturated` and excluded from every future run's query — re-runs cover **new** ground only. Row dedup is handled by the unique `provider_id` constraint, so adjacent-cell overlap never creates duplicates.

## Components

### 1. Field masks + type filter + ranking + `get_nearby_restaurants` params

`ressy_backend/services/googleplaces_services.py`

- **Masks (both modes identical — Enterprise-only).** Fields are grouped into `_PRO_TIER_FIELDS`, `_ENTERPRISE_TIER_FIELDS`, `_ATMOSPHERE_TIER_FIELDS`. `nearby_field_paths` and `seed_lean_field_paths` are **both** `_places_prefixed(_PRO_TIER_FIELDS + _ENTERPRISE_TIER_FIELDS)` (no atmosphere/photos/reviews → Enterprise $35 SKU); they're kept as two names so the modes can diverge later, but today both modes **and** the live path use the same fields. `_ATMOSPHERE_TIER_FIELDS` stays defined-but-unused for one-line re-enable. (`detail_field_paths` = the same two tiers + `movedPlaceId`, bare names for `get_place`.)
- **Type filter (both modes).** Add `seed_included_types` — the dine-in & drink umbrella, all **Table A** (filterable): `restaurant` (subsumes the whole `*_restaurant` cuisine family — they carry `restaurant` in their types array) plus the non-restaurant categories: `cafe, coffee_shop, coffee_stand, cat_cafe, dog_cafe, tea_house, juice_shop, acai_shop, bakery, bagel_shop, cake_shop, pastry_shop, dessert_shop, ice_cream_shop, donut_shop, deli, sandwich_shop, salad_shop, snack_bar, bistro, bar, bar_and_grill, pub, wine_bar, cocktail_bar, sports_bar, lounge_bar, beer_garden, gastropub, brewery, brewpub, winery` (~33 total, well under the **50-per-request** cap). Retail/production-leaning types (candy/chocolate/roastery/confectionery), `cafeteria`, and `hookah_bar` are deliberately excluded. **`food` cannot be used** — it is **Table B** (response-only); `includedTypes:["food"]` returns `INVALID_ARGUMENT: Unsupported types: food`. (The asterisks in Google's type table mark the **Feb 12, 2026 release** additions — all Table A, all filterable.)
- **Drop quick-service (both modes).** Add `seed_excluded_primary_types = ["fast_food_restaurant", "meal_takeaway", "meal_delivery", "food_court"]`. It filters by **primary** type, which is safe: a sit-down restaurant that merely also offers takeaway (e.g. the docs' Kokkari — primary `greek_restaurant`, types include `meal_takeaway`) is **kept**, while a primarily-QSR place is dropped. (`excludedTypes` would wrongly drop Kokkari since types co-occur.) No retail `excludedTypes` needed — the umbrella never includes `grocery_store`/`supermarket`.
- **Params.** Extend `get_nearby_restaurants(longitude, latitude, radius_meters, additional_types=None, *, field_paths=None, included_types=None, included_primary_types=<sentinel>, excluded_primary_types=None, rank_preference=None)`. Defaults preserve the live path (`field_paths=nearby_field_paths`; `included_types` from `["restaurant"]+additional_types`; `included_primary_types=["restaurant"]`; POPULARITY). Since both masks are identical now, the seeder varies only **rank + type filter** per mode:
  - **exhaustive:** `rank_preference=DISTANCE`, `included_types=seed_included_types`, `included_primary_types=None`, `excluded_primary_types=seed_excluded_primary_types` (mask defaults to `nearby_field_paths`).
  - **popular:** `rank_preference=POPULARITY`, same type filter, same mask.
  - *Why drop `included_primary_types` for the seed:* Google AND-combines filter categories, so the live `included_primary_types=["restaurant"]` would re-exclude cafés/bars/bakeries (primary `cafe`/`bar`/`bakery`). Matching the types **array** via `included_types` (OR within the list) minus `excludedPrimaryTypes` is the whole filter.
- No change to `serialize_place()`; it already tolerates missing keys (atmosphere fields serialize to `None`/`False` when absent).

### 2. New table `srvn_seed_grid_cells`

Model `ressy_backend/models/srvn_seed_grid_cell.py` (`SrvnSeedGridCell`); Alembic migration in `migrations/versions/`. **Register it in `ressy_backend/models/__init__.py`** so Alembic autogenerate sees the table *and* the `after_insert` taste-feature listener loads.

| Column | Type | Notes |
|---|---|---|
| `id` | BigInteger PK | |
| `region` | String, indexed | label, e.g. `"toronto-downtown"` |
| `mode` | String | `exhaustive` \| `popular` — stamped at `init-grid`, **inherited by children**; the run reads it to pick rank/mask and the subdivision cap |
| `center_lat` / `center_lng` | Float | **rounded to 7 decimals (~1 cm)** before insert so the UNIQUE key is stable against float drift |
| `radius_m` | Integer | |
| `depth` | SmallInteger | 0 = root; subdivision level |
| `parent_id` | BigInteger FK self, null | lineage |
| `status` | String, indexed | `pending` \| `in_progress` \| `done` \| `saturated` \| `error` |
| `result_count` | Integer, null | places returned (0–20) |
| `new_spot_count` | Integer, null | rows actually inserted |
| `retry_count` | SmallInteger, default 0 | bumped on each `error`; `reset` skips cells past `SRVN_SEED_MAX_RETRIES` so a permanently-bad cell isn't retried forever |
| `error` | Text, null | last error |
| `swept_at` | DateTime(tz), null | |
| `created_at` / `updated_at` | DateTime(tz) | |

Constraints/indexes: `UNIQUE (center_lat, center_lng, radius_m)` (idempotent identity — re-running `init-grid` is a no-op via `ON CONFLICT DO NOTHING`; coords are rounded to 7 decimals at generation time so regeneration produces bit-identical keys); partial index on `status` for the `WHERE status='pending'` hot query.

### 3. Grid generation + subdivision

Pure helper in `ressy_backend/services/srvn_spot_seeder.py` (unit-testable, no I/O):

```
METERS_PER_DEG_LAT = 111_320
spacing_m = radius_m * SPACING_FACTOR        # SPACING_FACTOR = √2 ≈ 1.414 (inscribed square)
dlat = spacing_m / METERS_PER_DEG_LAT
dlng = spacing_m / (METERS_PER_DEG_LAT * cos(radians(lat)))
# walk bbox (min_lng,min_lat)→(max_lng,max_lat) stepping (dlng, dlat); emit a cell per point
# round(center_lat, 7), round(center_lng, 7) on each emitted cell — keeps the
# UNIQUE(center_lat, center_lng, radius_m) key bit-stable across regenerations
```

**Subdivision (adaptive quadtree).** A cell with `result_count == 20` enqueues **4 children** at radius `radius_m/2`, placed at the **quadrant centers of the parent's inscribed square** — centers offset by `±radius_m·√2/4` (≈ `±0.354·radius_m`) — with `depth+1`, `parent_id=cell.id`, inherited `mode`, `status=pending`. The **stop rule differs by mode**:
- **exhaustive:** keep subdividing every saturated cell **until no cell returns 20** (a `SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH` guards against runaway, but the real terminator is `result_count < 20` ⟺ that circle is provably complete).
- **popular:** subdivide only while `depth < SRVN_SEED_POPULAR_MAX_DEPTH` (2).

> **Offset correctness — do NOT use `±radius_m/2`.** Each `radius_m/2` child is the **circumscribed** circle of one quadrant sub-square of the parent's inscribed square (a radius-`R/2` circle around a `R·√2/2`-side square); equivalently, the four children's *own* inscribed squares (each side `R·√2/2`) tile the parent's inscribed square exactly. At offset `±radius_m·√2/4` they meet at the parent's center and edge-midpoints, fully tiling its footprint. The naïve `±radius_m/2` offset pushes them out toward the corners and leaves the parent's **center and edge midpoints uncovered** — precisely the long-tail a saturated cell subdivided to recover would fall through. Radius stays `radius_m/2`. (Points in the parent *circle* beyond its inscribed square belong to neighbor cells, which in exhaustive mode also subdivide-until-complete, so square coverage tiles the whole area.)

Defaults: `SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M=250`, `SRVN_SEED_POPULAR_CELL_RADIUS_M=700`. Radius is tunable per run via `--cell-radius`; in exhaustive mode it only affects efficiency (front-loaded vs. subdivided calls), not completeness.

### 4. Shared upsert helper (small refactor)

The result-processing/insert loop lives inside `get_or_create_spots_from_google()` (`spot_service.py:85`–end) **and** is duplicated as `process_and_store_google_spots()` (`spot_service.py:207`, called by `routes/spot.py:301`). Extract one helper and repoint **both** callers (so there's one implementation, not three):

```python
def upsert_serialized_spots(serialized: list[dict]) -> int:
    """Insert new Spots from serialized Google results; dedupe by provider_id.
    Returns count newly created. RAISES on commit failure (the seeder records
    it as a per-cell error; the route caller already tolerated a raise). Reused
    by the live cache-miss path, the legacy route helper, and the seeder so
    PostGIS point creation + the after_insert taste-feature trigger stay
    identical."""
```

This routes seed rows through the **same** `provider_id` dedup (per-row existence check + `begin_nested()` savepoint catching unique violations — crash/overlap-safe), PostGIS `ST_SetSRID/ST_MakePoint`, and the `after_insert` listener that backfills `srvn_spot_taste_features` (auto-enqueues taste extraction + embedding — no seeder code). Seed rows keep the helper's `last_refreshed_at = now` stamp **deliberately**: it makes them **fresh** to `should_refresh_spot()`, so `lazy_refresh_spot()` never auto-enriches them on view (§9). (All seed rows are medium-fidelity now — no mode is "born rich" — so this applies to every seeded row.)

**Error-handling contract (reconcile the two source loops).** The two functions being consolidated differ on commit failure: `get_or_create_spots_from_google()` swallows (rollback + return what it has), `process_and_store_google_spots()` re-raises. The helper **raises** (the stricter contract). To preserve the live request path exactly, `get_or_create_spots_from_google()` wraps its `upsert_serialized_spots()` call in `try/except` and degrades to returning the DB results it already has; the route helper (`spot.py:301`) already used `len(new_spots)` only, so it keeps working unchanged; the seeder lets the raise bubble so the cell goes to `status='error'`.

**Photos (Enterprise-only mask → none).** Nearby never returns `photos` under the current mask, so every seed row gets `photos = []` and `photos_refreshed_at` stays NULL. The helper still does the conditional `photos_refreshed_at = now` stamp *only when the payload has photos* — a no-op today, but correct if photos are ever re-enabled. Place Details refresh is also photo-free now, so a refresh overwrites `spot.photos` with `[]` (accepted — no guard added, matching the no-photos decision).

### 5. Seeder service

`ressy_backend/services/srvn_spot_seeder.py`

- `init_grid(region, bbox, cell_radius_m, mode) -> int` — generate + bulk-insert pending root cells with `mode` stamped (`ON CONFLICT DO NOTHING`); returns count inserted. **Guards bbox size:** compute the root-cell count first and refuse above `SRVN_SEED_MAX_GRID_CELLS` (~5000) unless `force=True`; always log the count. (Prevents a metro bbox accidentally fed to a 250 m exhaustive grid.)
- `run_seed(max_calls: int | None = None) -> SeedRunResult` — the resumable **claim-then-release** loop:
  1. Resolve month budget. `cap = SRVN_SEED_MONTHLY_CALL_CAP` (950); `spent = int(redis.get(f"srvn:seed:calls:{YYYY_MM}") or 0)`; `budget = min(max_calls or ∞, cap - spent)`. If `budget <= 0`, log and return. **Redis unavailable → fail closed** (treat as exhausted).
  2. Loop, **one cell per iteration**, while `budget > 0`:
     - **Claim:** `cell = SELECT ... WHERE status='pending' ORDER BY depth, id LIMIT 1 FOR UPDATE SKIP LOCKED`. If none, break. Set `status='in_progress'`; **commit** (releases the row lock immediately and marks the cell claimed, so a concurrent run skips it — `SKIP LOCKED` now does real work). Doing the API call *outside* a held lock/txn avoids pinning a DB connection across an HTTP round-trip.
     - **Process:** `rank, mask ← cell.mode`; `get_nearby_restaurants(..., field_paths=mask, rank_preference=rank, included_types=seed_included_types, included_primary_types=None, excluded_primary_types=seed_excluded_primary_types)`; `redis.incr(key)` (TTL ~45d on first write); `new = upsert_serialized_spots(results)`.
     - **Finalize:** record counts; `status = 'saturated' if len==20 else 'done'`; **if saturated**: enqueue children when `mode=='exhaustive'` (under safety depth) or `mode=='popular' and depth < 2`; `swept_at=now`; **commit per cell** (status flips to done/saturated only after spots commit → a mid-cell crash leaves the cell in `in_progress`, recoverable by `reset`).
     - **On API error:** `status='error'`, `retry_count += 1`, store message, commit, continue (no `redis.incr` — see note).
  3. Stop when no `pending` cell remains or the month budget hits 0.
- **Counter direction (under-counts on crash, deliberately).** `redis.incr` fires *after* a successful call, so a crash between the API call and the incr loses the count for one call (you spend a call you didn't bill). This is the conservative direction and the 950/1000 headroom absorbs it; incrementing *before* would over-count failed calls instead.
- Mirror the embedding worker's Redis day-counter (`srvn:embed:tokens:{YYYY-MM-DD}` at `services/srvn_taste_graph/embedding_worker.py`) — here a **month** key so it auto-resets on the 1st.
- `reset_cells(region=None, kind="error") -> int` — recovery path for stranded cells (backs the `reset` CLI). Flips back to `pending`: `error` cells with `retry_count < SRVN_SEED_MAX_RETRIES`, and stale `in_progress` cells (`updated_at` older than ~15 min, i.e. a crashed claim). Without this, an `error` storm (e.g. `RESOURCE_EXHAUSTED`) permanently orphans that ground, since `error`/`in_progress` are excluded from the `WHERE status='pending'` query.

### 6. CLI command (primary interface)

`ressy_backend/commands/srvn_seed_spots_command.py`, a `click` group registered in `register_commands()` via `app.cli.add_command(srvn_seed_cli)` (mirrors `refresh_spots_command` at `app.py:558`). `@with_appcontext`.

```
# PRIMARY — exhaustive coverage of one neighborhood (default mode):
flask srvn-seed init-grid --region toronto-downtown --bbox <minlng,minlat,maxlng,maxlat>
flask srvn-seed run                       # respects the monthly Redis cap

# SECONDARY — broad metro popular-core sweep:
flask srvn-seed init-grid --region lagos-metro --mode popular --cell-radius 700 --bbox <...>
flask srvn-seed run --max-calls 950

flask srvn-seed status                    # pending/done/saturated/error counts per region+mode + month calls spent
flask srvn-seed reset --region toronto-downtown   # re-queue error + stale in_progress cells (retry_count < cap)
```

`init-grid` refuses a bbox that generates more than `SRVN_SEED_MAX_GRID_CELLS` cells unless `--force` is passed. `--mode` defaults to `exhaustive` and is stamped on the region's cells. Manual CLI is the right interface pre-launch: full control, matches the `refresh-spots` precedent, and the Redis cap + cell checkpoint make it impossible to overspend or repeat. **Do not run two `run`s concurrently** — the month-counter check isn't atomic across processes.

### 7. Config / env vars

`ressy_backend/config.py` (follow the existing `SRVN_*` `_RAW` → typed pattern):

| Env var | Default | Purpose |
|---|---|---|
| `SRVN_SEED_ENABLED` | `false` | master switch |
| `SRVN_SEED_DEFAULT_MODE` | `exhaustive` | mode when `--mode` omitted |
| `SRVN_SEED_MONTHLY_CALL_CAP` | `950` | hard ceiling under the 1,000 free tier |
| `SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M` | `250` | root radius, exhaustive |
| `SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH` | `6` | runaway guard (real stop = no cell saturates) |
| `SRVN_SEED_POPULAR_CELL_RADIUS_M` | `700` | root radius, popular |
| `SRVN_SEED_POPULAR_MAX_DEPTH` | `2` | subdivision cap, popular |
| `SRVN_SEED_MAX_GRID_CELLS` | `5000` | `init-grid` refuses a bbox over this without `--force` (oversized-bbox guard) |
| `SRVN_SEED_MAX_RETRIES` | `3` | `reset` skips `error` cells past this `retry_count` (no infinite retry of a bad cell) |
| `SPOT_LAZY_REFRESH_ENABLED` | `true` | global kill-switch for on-view Place Details enrichment; set `false` during seeding so spots don't auto-enrich (§9) |

### 8. Optional scheduled tick (defer)

A daily APScheduler job `srvn_seed_tick()` mirroring `srvn_refresh_spot_features()` (`tasks.py:475`) could automate the trickle behind `SRVN_SEED_ENABLED && START_SCHEDULER`. **Out of scope for v1** — manual CLI is preferred pre-launch.

### 9. Enrichment control — keep the seed at $0

On-view Place Details enrichment (`refresh_spot_data`, `spot_refresh_service.py`) must **not** fire automatically against a fresh seed. Under the current Enterprise-only `detail_field_paths` a refresh is cheaper than before (no atmosphere/photos/reviews) but also adds **nothing** the seed didn't already capture — so suppression is now mainly about avoiding pointless churn and the photo/review-wipe-to-`[]` a same-mask refresh would cause.

- **All seed rows are medium-fidelity** (Pro + Enterprise). No mode is "born rich"; none gains anything from a *same-mask* refresh. Keeping `last_refreshed_at=now` means lazy refresh won't pointlessly re-fetch them.
- **To actually add fidelity** (atmosphere/photos/reviews) you must first **re-enable those fields** on `nearby_field_paths`/`detail_field_paths`; only then does a deliberate `refresh-spots` pass bring new signal. Until then `refresh-spots` is a fidelity no-op.

Verified controllable in the codebase: the **only** automatic enrichment trigger is `lazy_refresh_spot()` on view (`routes/spot.py:273,316,442,632,655`; `spot_service.py:67,202`), gated by `should_refresh_spot()` (age-based, `REFRESH_CYCLE_DAYS=30`). `refresh_spots_batch` runs **only** from the manual `refresh-spots` CLI; **no scheduler job** does a full Place Details refresh. Add a **`SPOT_LAZY_REFRESH_ENABLED`** flag (default `true`) checked at the top of `lazy_refresh_spot()` and `lazy_refresh_photos_only()`; set it `false` during seeding → zero automatic enrichment, globally (≈zero UX cost pre-launch). Flip the flag back `true` at launch for on-view self-healing.

## How seeded spots reach the taste graph

Inserting a `Spot` fires the existing `after_insert` listener (`srvn_spot_taste_features.py:84` — one cheap sidecar INSERT **per spot**, via Core `connection.execute`) → creates a `srvn_spot_taste_features` row with `embedding_updated_at = NULL` → the embedding worker (`srvn_refresh_taste_embeddings`, `tasks.py:517`) picks it up. Spots have **no cold-start filter** (`services/srvn_taste_graph/embedding_worker.py:18,233-236`), so all seeded rows embed; the daily token budget (10M) dwarfs the seed's cost (~3M tokens for 20k thin rows ≈ $0.06), and the per-tick backfill cap (200) drains a 20k backlog in ~20h (bump `SRVN_TASTE_EMBED_BACKFILL_CAP` to go faster). With atmosphere off, **all** rows are thin — `taste_text` is types + price + rating only, no `Features:` line — and would only re-embed if atmosphere is re-enabled and a later refresh flips the `taste_text_hash`. **No seeder-side taste code required.**

## Resumability & idempotency (the core requirement)

- **No repeated calls:** swept cells are `done`/`saturated`, excluded from the `WHERE status='pending'` query. Next run hits only fresh cells.
- **No double-spend in a month:** the `srvn:seed:calls:{YYYY-MM}` counter is checked before and incremented after every call; resets on the 1st.
- **No duplicate rows:** `upsert_serialized_spots()` dedupes by unique `provider_id`; adjacent-cell overlap is wasted-work-free, never a duplicate.
- **Crash safety:** claim-then-release per cell — a cell is set `in_progress` (committed) before its API call and only flipped to `done`/`saturated` after spots commit, so a crash leaves exactly one cell in `in_progress`, which `flask srvn-seed reset` re-queues. `FOR UPDATE SKIP LOCKED` on the claim makes concurrent claims safe (though concurrent `run`s are still discouraged — the month counter isn't atomic across processes).
- **Error recovery:** `error` cells (and stale `in_progress`) are re-queued by `reset`, capped at `SRVN_SEED_MAX_RETRIES` so a permanently-bad cell stops retrying.
- **Stop signal:** exhaustive mode self-terminates (no cell returns 20). Popular mode's only *coded* stop is the depth cap (`SRVN_SEED_POPULAR_MAX_DEPTH`); "`new_spot_count≈0`" is an **operator** signal — you read `status` and choose to stop re-running, it is not automatic.

## Cost & cap analysis

**PRIMARY — exhaustive, per neighborhood** (`calls ≈ places / 8–11`, $35 Enterprise SKU, 1,000 free):

| Area | Spots | Calls | Cost |
|---|---|---|---|
| Dense 500 m-radius (downtown Toronto) | ~800–1,500 | ~150–400 (`places/8–11`; ultra-dense cores at the high end) | **$0** |
| ~2–5 such neighborhoods | — | ~900 (cap) | **$0 / month** |
| A launch city's key neighborhoods | — | over 1–3 months | **$0** |

> Calls use the `places/8–11` band from "Two overlap taxes" above — ultra-dense cores that saturate to depth 3–4 land near `/8` and may need **2 monthly runs** to finish one neighborhood (resumability carries the remainder; still $0/run).

**SECONDARY — popular-core, metro** ($35 Enterprise SKU, ~12 distinct/call):

| Run | Calls | Net distinct | Cost |
|---|---|---|---|
| Month 1 | 950 | ~11,400 | **$0** |
| Month 2 | 950 | ~8,000 | **$0** |
| Month 3 | ~300 | ~2,500 | **$0** |
| **Total to ~20k** | ~2,200 | ~20,000 | **$0** |

A whole metro **exhaustively** would be ~$90–260 one-time at $35/1k (or many $0 months) — which is the signal to use the secondary mode for breadth and reserve exhaustive for the neighborhoods that matter.

## Edge cases & risks

- **Exhaustive only pays where Google's catalog is deep.** DISTANCE recovers the long tail that *exists in Google but is popularity-filtered*. Where Google's coverage is itself thin (informal markets — Lagos street food, bukas), there's no hidden tail to recover and exhaustive costs the same as popular-core for the same result. **Before committing a thin-coverage city to exhaustive, A/B one dense cell** (same point, DISTANCE vs POPULARITY) and compare distinct counts. Toronto/Central-Europe/USA — deep coverage, go exhaustive.
- **Enrichment adds nothing until masks are re-enabled.** Refresh now uses the same Enterprise-only mask as the seed, so a `refresh-spots` pass brings no new fidelity (and would wipe photos/reviews to `[]`). Keep it gated (`SPOT_LAZY_REFRESH_ENABLED=false` + `last_refreshed_at=now`); never let lazy on-view enrichment loose on a fresh seed. To genuinely enrich, re-enable atmosphere/photos/reviews on the masks first (§9).
- **Free tier shared with live serving.** The 1,000/month allotments also cover live `/spots/nearby` cache-miss calls. Pre-launch fine; once live, seeding and serving compete — stop seeding or accept paid.
- **Types in scope.** Food/drink umbrella (`seed_included_types`), primary restriction dropped, `excludedPrimaryTypes` removing primarily-QSR; pure nightlife (`night_club`) not added but a bar/restaurant that's also a venue still comes in. `food` unusable (Table B).
- **bbox over water/parks** wastes cells returning 0 — acceptable; subdivision only deepens *saturated* cells.
- **Redis unavailable** → fail closed.

## Testing plan (per `CLAUDE.md` / `AGENTS.md`)

Unit (pure logic, mock Google client + Redis):
- Grid generation: cell count for a known bbox/radius; `cos(lat)` longitude correction; centers rounded to 7 dp so regeneration is bit-identical (`init-grid` re-run is a true no-op via `ON CONFLICT`); subdivision produces 4 children at `radius_m/2` offset `±radius_m·√2/4`, with a **coverage assertion** that the four child circles cover the parent's inscribed square (center *and* edge-midpoints) — guarding the `±radius_m/2` gap.
- **bbox-size guard:** `init_grid` over `SRVN_SEED_MAX_GRID_CELLS` refuses without `force=True`, succeeds with it.
- **Mode behaviour:** `exhaustive` keeps subdividing saturated cells past depth 2 (until a stubbed client returns <20) and stops when none saturate; `popular` stops at `SRVN_SEED_POPULAR_MAX_DEPTH`. Each mode selects the right rank (the mask is identical across modes).
- Ranking/mask wiring: both seed modes send the **same** mask (`nearby_field_paths` == `seed_lean_field_paths`); exhaustive sends `rankPreference=DISTANCE`, popular `POPULARITY`; the **default** (live) call is unchanged (POPULARITY, `nearby_field_paths`, `includedPrimaryTypes=["restaurant"]`).
- Type filter: seed call sends the umbrella in `includedTypes` + QSR `excludedPrimaryTypes`, omits `includedPrimaryTypes`; `food` never sent; café/bar/bakery retained; a *primarily* fast-food stub dropped while a `restaurant`-primary + `meal_takeaway` stub is kept.
- Masks are Enterprise-only: `nearby_field_paths`/`seed_lean_field_paths` exclude all atmosphere fields + `photos`; `detail_field_paths` excludes atmosphere/photos/reviews and keeps `movedPlaceId`; `_ATMOSPHERE_TIER_FIELDS` stays defined but used by no mask. (Tiers are disjoint.)
- Budget guard: stops at `SRVN_SEED_MONTHLY_CALL_CAP`; honors `--max-calls`; month-key rollover resets; `redis.incr` fires only on success (an `error` cell does **not** advance the counter).
- Cell status transitions: claim sets `in_progress` (committed) before the API call; then `→done` (<20) / `→saturated`+children (==20); `→error` + `retry_count += 1` on API exception (loop continues).
- **Resumability:** two runs against a fake pending set; run 2 issues **zero** calls for run 1's cells; a cell left `in_progress` (simulated crash) is **not** picked up by `run` but **is** re-queued by `reset_cells`.
- **Error recovery:** `reset_cells` flips `error`→`pending` only while `retry_count < SRVN_SEED_MAX_RETRIES`; leaves exhausted cells alone; re-queues stale `in_progress`.
- `upsert_serialized_spots()`: dedupes by `provider_id`; creates PostGIS point; correct new-count; stamps `last_refreshed_at=now`; leaves `photos_refreshed_at` NULL today (no photos in any mask) and stamps it `now` only when the payload has `photos` (the re-enable case); **raises** on commit failure, and `get_or_create_spots_from_google()`'s wrapper swallows that to return DB results (live-path behavior preserved).
- Enrichment suppression: `SPOT_LAZY_REFRESH_ENABLED=false` → `lazy_refresh_spot()` early-returns; a fresh-stamped spot is skipped by `should_refresh_spot()` regardless.

API/integration (`api` marker; mock the Google client):
- `init-grid` populates cells (mode stamped); re-running is a no-op; oversized bbox refused without `--force`.
- `run` inserts spots and increments the month counter by the number of cells **successfully** swept.
- `reset` re-queues `error`/stale-`in_progress` cells so a follow-up `run` re-attempts them.

## Rollout / how to run

1. `poetry run flask db upgrade` (creates `srvn_seed_grid_cells`).
2. Set `SRVN_SEED_ENABLED=true` and `SPOT_LAZY_REFRESH_ENABLED=false` (+ confirm `REDIS_URL`, `GOOGLE_API_KEY`).
3. **Primary path:** `flask srvn-seed init-grid --region <neighborhood> --bbox <minlng,minlat,maxlng,maxlat>` (defaults to exhaustive), then `flask srvn-seed run`. Repeat per neighborhood (~3–6 dense ones/month at $0).
4. **Secondary path (optional):** `flask srvn-seed init-grid --region <metro> --mode popular --bbox <...>`, then `flask srvn-seed run --max-calls 950`; re-run monthly.
5. `flask srvn-seed status` for progress / saturation / error counts. If a run hit transient errors (timeouts, a quota storm), `flask srvn-seed reset --region <r>` re-queues them and re-run.
6. At launch, flip `SPOT_LAZY_REFRESH_ENABLED=true` for on-view self-healing. (To enrich rows beyond Pro+Enterprise, first re-enable atmosphere/photos/reviews on `nearby_field_paths`/`detail_field_paths`, *then* run `flask refresh-spots …` — otherwise refresh adds nothing and wipes photos/reviews to `[]`.)

bbox format is `minlng,minlat,maxlng,maxlat` (**longitude first**, x,y order — matches `get_nearby_restaurants(longitude, latitude, …)` / PostGIS; lat-first is the main footgun).

## File-by-file change list

**New**
- `ressy_backend/models/srvn_seed_grid_cell.py` — `SrvnSeedGridCell` model incl. `retry_count` (+ register in `models/__init__.py`).
- `migrations/versions/<rev>_create_srvn_seed_grid_cells.py` — table + indexes.
- `ressy_backend/services/srvn_spot_seeder.py` — grid gen (coords rounded to 7 dp), mode-aware subdivision, `init_grid` (bbox-size guard), `run_seed` (claim-then-release loop), `reset_cells`.
- `ressy_backend/commands/srvn_seed_spots_command.py` — `srvn-seed` click group (`init-grid`, `run`, `status`, `reset`).
- `tests/services/test_srvn_spot_seeder.py`, `tests/commands/test_srvn_seed_spots_command.py`.

**Modified**
- `ressy_backend/services/googleplaces_services.py` — **done:** tier constants (`_PRO_TIER_FIELDS`/`_ENTERPRISE_TIER_FIELDS`/`_ATMOSPHERE_TIER_FIELDS`), Enterprise-only `nearby_field_paths` & `seed_lean_field_paths` (identical) + `detail_field_paths` (+`movedPlaceId`; no atmosphere/photos/reviews), `get_restaurant_details` repointed to `detail_field_paths`. **To add:** `seed_included_types`, `seed_excluded_primary_types`, and the `field_paths`/`included_types`/`included_primary_types`/`excluded_primary_types`/`rank_preference` params on `get_nearby_restaurants` (defaults preserve the live path).
- `ressy_backend/services/spot_service.py` — extract `upsert_serialized_spots()` (returns `int`, **raises** on commit failure, stamps `photos_refreshed_at=now` when payload has photos); call it from `get_or_create_spots_from_google()` (wrap in try/except to preserve its swallow-and-degrade behavior) **and** `process_and_store_google_spots()` (consolidate the duplicate loop).
- `ressy_backend/services/spot_refresh_service.py` — gate `lazy_refresh_spot()` / `lazy_refresh_photos_only()` behind `SPOT_LAZY_REFRESH_ENABLED`.
- `ressy_backend/app.py` — register `srvn_seed_cli`.
- `ressy_backend/config.py` — add the `SRVN_SEED_*` settings + `SPOT_LAZY_REFRESH_ENABLED`.
- `ressy_backend/.env.development.sample` — document the new env vars.

## Open decisions

**Resolved (2026-06-22):**
- **Strategy** → **two modes**: primary `exhaustive` (DISTANCE, until-complete, neighborhood) as the default; secondary `popular` (POPULARITY, depth-2 cap, metro) behind `--mode popular`. Both use the **same** Enterprise-only mask — they differ only in rank + subdivision.
- **Types in scope** → food/drink umbrella, primary-type restriction dropped, QSR removed via `excludedPrimaryTypes`; `food` unusable (Table B).
- **Billing / field mask** → **Enterprise-only ($35/1k)** for every call — live `/spots`, both seed modes, and Place Details refresh: **no atmosphere, no photos, no reviews** (decided 2026-06-22). `_ATMOSPHERE_TIER_FIELDS` kept defined for a one-line re-enable. Both modes share the single 1,000-free Enterprise bucket; 950 cap.
- **Interface** → manual CLI only; scheduled tick deferred.
- **Enrichment** → not automatic; gated by `SPOT_LAZY_REFRESH_ENABLED`. All rows are medium-fidelity (no mode is "born rich"), and refresh uses the same Enterprise-only mask, so `refresh-spots` adds no fidelity until atmosphere/photos/reviews are re-enabled on the masks.
- **Subdivision geometry** → children at `radius_m/2`, offset `±radius_m·√2/4` (not `±radius_m/2`).

**Still live (runtime inputs, not blockers):**
1. **Which neighborhoods (primary) / metro bbox (secondary)** — the real input each run needs.
2. **Cell radius** — exhaustive 250 m / popular 700 m defaults; tune after run 1's `result_count` distribution (exhaustive: radius affects only call efficiency, not completeness).
3. **Per-city mode** — run the DISTANCE-vs-POPULARITY count A/B before committing a thin-coverage city to exhaustive.
