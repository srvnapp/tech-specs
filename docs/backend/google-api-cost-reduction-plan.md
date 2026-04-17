# Google Places API Cost Reduction — Implementation Plan

## Context

The app was spending ~$150/month on Google Places API despite only ~5 users. A full audit
traced the cost to two compounding problems:

1. `get_photo_details()` fires a separate `GetPhotoMedia` HTTP call **per photo per place**
   during every search — resulting in 80–200 billed photo API calls per user search.
2. `photo_uri` URLs returned by Google expire after ~24 hours, but the refresh cycle is
   30 days — meaning the URIs stored in `spot.photos` (DB) are broken for 29 of every 30
   days. The DB is the wrong place to store them.

The corrected architecture separates stable metadata (stored in DB forever) from ephemeral
photo URIs (cached in Redis with a 23-hour TTL, resolved fresh at API response time).

---

## Corrected Architecture

| Layer | What is stored | TTL |
|-------|---------------|-----|
| **DB `spot.photos`** | Stable metadata only: `name`, `flag_content_uri`, `google_maps_uri` | Forever |
| **Redis** | `photo_uri` keyed by `photo_name` | 23 hours |
| **API response** | All of the above combined — `photo_uri` resolved at response time | N/A |

**Flow:**

1. **Seeding / refresh** (`serialize_place()`): fetch stable photo metadata from Google nearby
   search response (no `GetPhotoMedia` call). Store in `spot.photos`. Max 1 photo per place.

2. **API response** (`SpotController.prepare_spots_for_response()`): for each photo in
   `spot.photos`, look up Redis for `photo_uri`. On miss: call `GetPhotoMedia`, cache 23h,
   attach to response. On hit: attach cached URI directly — zero API cost.

3. **Result**: `GetPhotoMedia` is called at most once per photo per 23 hours, regardless of
   how many users request that spot. After the first call, all users within the 23-hour window
   get the cached URI at zero cost.

---

## Root Causes Addressed

| # | Issue | Fix |
|---|-------|-----|
| 1 | `get_photo_details()` calls `GetPhotoMedia` during seeding/refresh | Remove the call; store stable metadata only |
| 2 | `photo_uri` stored in DB expires after 24h (broken for 29/30 days) | Store in Redis (23h TTL), resolve at response time |
| 3 | No cap on photos per place — up to 10 fetched per place | `MAX_PHOTOS_PER_PLACE = 1` |
| 4 | `lazy_refresh_spot()` spawns unbounded daemon threads | Semaphore capped at 3 concurrent |
| 5 | `get_nearby_restaurants()` uncached — same area re-fetched per user | Handled by DB — spots persist after first seed; no Redis cache needed |

---

## Implementation Plan

### Change 1 — Remove `GetPhotoMedia` call from `get_photo_details()`; cap to 1 photo per place

**File:** `ressy_backend/services/googleplaces_services.py`

`get_photo_details()` currently reads `photo_proto.name` from the nearby search response
(already in memory) then immediately makes a second `GetPhotoMedia` API call to get a
`photo_uri`. Remove that API call. The function now just reads the `name` off the proto
object and returns it — no network request.

Also drop `flag_content_uri` and `google_maps_uri` from the returned dict (unused by the
app) and add `MAX_PHOTOS_PER_PLACE = 1` to cap how many photos are processed per place.

```python
MAX_PHOTOS_PER_PLACE = 1  # module-level constant

def get_photo_details(photo_proto) -> dict | None:
    if not photo_proto:
        return None
    photo_name = photo_proto.name if hasattr(photo_proto, "name") else None
    if not photo_name:
        return None
    return {"name": photo_name}   # no API call — just reads from the proto already in memory
```

Update the photos loop in `serialize_place()` (line 422) to apply the cap:

```python
serialized_output["photos"] = []
if hasattr(place_obj, "photos") and place_obj.photos:
    for photo_proto in list(place_obj.photos)[:MAX_PHOTOS_PER_PLACE]:
        photo = get_photo_details(photo_proto)
        if photo:
            serialized_output["photos"].append(photo)
```

**What gets stored in `spot.photos` (DB):**
```json
[{"name": "places/ChIJ.../photos/AXC..."}]
```

`photo_uri` is not stored here because it expires after ~24 hours — it is resolved fresh
at API response time (Change 3).

---

### Change 2 — New `resolve_photo_uri()` Function (Redis-first, Google fallback)

**File:** `ressy_backend/services/googleplaces_services.py`

Add a new function that resolves the short-lived `photo_uri` from Redis cache or Google.
This is the only place in the codebase that calls `GetPhotoMedia`.

```python
PHOTO_URI_CACHE_TTL = 82_800  # 23 hours — safely under Google's ~24h expiry

def resolve_photo_uri(photo_name: str) -> str | None:
    """
    Return a fresh photo_uri for the given photo reference.
    Checks Redis first (23h cache). On miss, calls GetPhotoMedia and caches the result.
    Returns None on any failure — callers should treat missing photo_uri gracefully.
    """
    if not photo_name:
        return None

    cache_key = f"photo_uri:{photo_name}"

    # 1. Redis hit — no API call
    try:
        cached = CONFIG.REDIS_CLIENT.get(cache_key)
        if cached:
            return cached
    except Exception as e:
        current_app.logger.warning(f"Redis read failed for photo_uri cache ({cache_key}): {e}")

    # 2. Cache miss — call Google
    try:
        request = places_v1.GetPhotoMediaRequest(
            name=f"{photo_name}/media",
            max_height_px=400,
            max_width_px=400,
        )
        response = client.get_photo_media(request=request)
        photo_uri = response.photo_uri

        try:
            CONFIG.REDIS_CLIENT.setex(cache_key, PHOTO_URI_CACHE_TTL, photo_uri)
        except Exception as e:
            current_app.logger.warning(f"Redis write failed for photo_uri cache ({cache_key}): {e}")

        return photo_uri
    except Exception as e:
        current_app.logger.error(f"Google Places API error (resolve_photo_uri): {str(e)}")
        return None
```

---

### Change 3 — Resolve Photo URIs at API Response Time

**Files:**
- `ressy_backend/Controllers/spot.py` — `SpotController.prepare_spots_for_response()`
- `ressy_backend/schemas/spot.py` — replace `List(Dict())` with a typed `SpotPhotoSchema`

#### 3a — Enrich photos in `prepare_spots_for_response()`

Reconstruct each photo dict with only the allowed fields. Old DB entries with
`flag_content_uri`, `google_maps_uri`, or stale `photo_uri` are silently discarded
here — the only fields that ever reach the serializer are `name`, `photo_uri`,
`height_px`, and `width_px`.

```python
from ressy_backend.services.googleplaces_services import resolve_photo_uri

class SpotController:
    @classmethod
    def prepare_spots_for_response(cls, spots):
        if not spots:
            return

        # Existing reviews_count logic (unchanged)
        ids = [s.id for s in spots]
        rows = (
            db.session.query(Review.spot_id, func.count(Review.id))
            .filter(Review.spot_id.in_(ids), Review.deleted_at.is_(None))
            .group_by(Review.spot_id)
            .all()
        )
        count_by_spot = {spot_id: count for spot_id, count in rows}
        for spot in spots:
            setattr(spot, "reviews_count", count_by_spot.get(spot.id, 0))

        # Resolve photo URIs — build clean dicts with only the 4 allowed fields
        for spot in spots:
            if not spot.photos:
                continue
            enriched = []
            for photo in spot.photos:
                photo_name = photo.get("name")
                if not photo_name:
                    continue
                enriched.append({
                    "name": photo_name,
                    "photo_uri": resolve_photo_uri(photo_name),  # Redis-first, Google fallback
                    "height_px": 400,
                    "width_px": 400,
                })
            spot.photos = enriched
```

#### 3b — Add `SpotPhotoSchema` in `schemas/spot.py`

Replace the open-ended `fields.List(fields.Dict())` with a typed schema. This acts as a
hard boundary: even if old DB rows slip through, unrecognised fields are never serialized.

```python
class SpotPhotoSchema(Schema):
    name = fields.String(allow_none=True)
    photo_uri = fields.String(allow_none=True)
    height_px = fields.Integer(allow_none=True)
    width_px = fields.Integer(allow_none=True)
```

Update `SpotSchema`:
```python
# Before
photos = fields.List(fields.Dict(), allow_none=True, ...)

# After
photos = fields.List(
    fields.Nested(SpotPhotoSchema),
    allow_none=True,
    metadata={"description": "List of photo objects. photo_uri is resolved fresh per response."},
)
```

#### 3c — Data migration: strip old fields from existing `spot.photos` rows

`spot.photos` is a JSONB column — no Alembic column migration is needed. However,
existing rows contain stale fields (`photo_uri`, `flag_content_uri`, `google_maps_uri`,
`height_px`, `width_px`) that should be cleaned up for hygiene.

Create a new Alembic migration (`alembic revision --autogenerate -m "strip_photo_metadata_to_name_only"`)
with the following `upgrade()`:

```python
def upgrade():
    op.execute("""
        UPDATE spots
        SET photos = (
            SELECT jsonb_agg(jsonb_build_object('name', photo->>'name'))
            FROM (
                SELECT photo
                FROM jsonb_array_elements(photos) AS photo
                WHERE photo->>'name' IS NOT NULL
                  AND photo->>'name' <> ''
                LIMIT 1
            ) sub
        )
        WHERE photos IS NOT NULL
          AND jsonb_array_length(photos) > 0
    """)

def downgrade():
    pass  # data-only migration; old URIs are expired anyway — not worth restoring
```

This leaves only `{"name": "..."}` in every photo entry across all existing spots.

**Cost model after Change 3:**
- Cache hit (within 23h): 0 `GetPhotoMedia` calls per spot, unlimited users
- Cache miss: 1 `GetPhotoMedia` call per spot per 23 hours, result shared across all users
- With `MAX_PHOTOS_PER_PLACE = 1`: worst case = 1 call per unique spot per 23h

---

### Change 4 — Semaphore for Background Refresh Threads

**File:** `ressy_backend/services/spot_refresh_service.py` — `lazy_refresh_spot()` (line 36)

Prevents unbounded thread spawning. A request returning 5 spots can currently fire 5
concurrent background threads, each making Google API calls.

```python
_REFRESH_SEMAPHORE = threading.Semaphore(3)  # module-level; max 3 concurrent refreshes

def lazy_refresh_spot(spot: Spot) -> None:
    if not should_refresh_spot(spot):
        return
    if not spot.provider_id:
        return

    spot_id = spot.id
    app = current_app._get_current_object()

    def refresh_in_background():
        acquired = _REFRESH_SEMAPHORE.acquire(blocking=False)
        if not acquired:
            return  # too many refreshes in flight; skip
        try:
            with app.app_context():
                spot_to_refresh = Spot.query.filter(
                    Spot.id == spot_id, Spot.deleted_at.is_(None)
                ).first()
                if spot_to_refresh and should_refresh_spot(spot_to_refresh):
                    try:
                        refresh_spot_data(spot_to_refresh)
                    except NotFound:
                        pass
                    db.session.commit()
        except Exception as e:
            current_app.logger.error(
                f"Error in background refresh for spot {spot_id}: {str(e)}", exc_info=True
            )
            try:
                db.session.rollback()
            except Exception:
                pass
        finally:
            _REFRESH_SEMAPHORE.release()

    thread = threading.Thread(target=refresh_in_background, daemon=True)
    thread.start()
```

---

## Files Modified

| File | Changes |
|------|---------|
| `ressy_backend/services/googleplaces_services.py` | Changes 1, 2 — rework photo handling |
| `ressy_backend/Controllers/spot.py` | Change 3a — resolve + clean photo dicts at response time |
| `ressy_backend/schemas/spot.py` | Change 3b — replace `List(Dict())` with typed `SpotPhotoSchema` |
| `ressy_backend/services/spot_refresh_service.py` | Change 4 — semaphore |
| `migrations/versions/<hash>_strip_photo_metadata_to_name_only.py` | Change 3c — data migration |
| `tests/srvn_backend/services/test_googleplaces_services.py` | New — unit tests |

---

## Critical Code Paths

- `googleplaces_services.py:422` — `serialize_place()` photos loop — apply `MAX_PHOTOS_PER_PLACE` cap (Change 1)
- `googleplaces_services.py:566` — `get_photo_details()` — remove `GetPhotoMedia` call, return `{"name": ...}` only (Change 1); new `resolve_photo_uri()` added alongside it (Change 2)
- `Controllers/spot.py:11` — `prepare_spots_for_response()` — clean + enrich photo dicts (Change 3a)
- `schemas/spot.py` — add `SpotPhotoSchema`; update `SpotSchema.photos` field (Change 3b)
- `spot_refresh_service.py:36` — `lazy_refresh_spot()` — add semaphore (Change 4)
- `config.py:281` — `CONFIG.REDIS_CLIENT` — reused as-is, no changes

---

## Existing Utilities to Reuse

- `CONFIG.REDIS_CLIENT` (`config.py:281`) — `redis.StrictRedis` with `decode_responses=True`; use `.get()`, `.setex()` directly (same pattern as `ressy_backend/services/cachechatservice.py`)

---

## Tests to Write

File: `tests/srvn_backend/services/test_googleplaces_services.py`

Use `unittest.mock.patch` and `FakeStrictRedis` (consistent with existing patterns in `tests/conftest.py`).

1. **`test_get_photo_details_returns_name_only_no_api_call`** — assert returned dict has only `name`; no `flag_content_uri`, `google_maps_uri`, `photo_uri`; assert `get_photo_media` is never called.
2. **`test_serialize_place_caps_photos_at_one`** — mock place with 6 photos; assert only 1 `get_photo_metadata` call.
3. **`test_resolve_photo_uri_cache_hit_skips_api`** — Redis returns cached URI; assert `get_photo_media` never called.
4. **`test_resolve_photo_uri_cache_miss_calls_api_and_caches`** — Redis miss; assert `get_photo_media` called once and `setex` called with `PHOTO_URI_CACHE_TTL`.
5. **`test_resolve_photo_uri_redis_failure_falls_through`** — Redis raises exception; assert `get_photo_media` still called (non-fatal fallback).
6. **`test_semaphore_blocks_excess_threads`** — acquire `_REFRESH_SEMAPHORE` 3 times in the test body, then call `lazy_refresh_spot()`; assert `get_photo_media` is never called (4th acquire fails, inner function returns early).

---

## Verification

1. Run the test suite:
   ```bash
   poetry run pytest tests/srvn_backend/services/test_googleplaces_services.py -v
   poetry run pytest  # full suite — check for regressions
   ```

2. Confirm DB rows contain only `name` after migration:
   ```sql
   SELECT photos FROM spots ORDER BY created_at DESC LIMIT 5;
   -- Each photos[0] should be {"name": "places/..."} — nothing else
   -- New inserts should also have only "name"
   ```

3. Confirm Redis is populated after an API response:
   ```bash
   redis-cli keys "photo_uri:*"   # should appear after first spot is served
   ```

4. Confirm photo URIs appear in the API response (resolved at response time):
   ```bash
   curl -H "Authorization: Bearer <token>" \
     "http://localhost:5000/spots?latitude=...&longitude=..."
   # Each spot.photos[0] should include "photo_uri" in the response JSON
   ```

5. Check Google Cloud Console billing 24 hours after deployment — expected:
   - `GetPhotoMedia` SKU: max 1 call per unique spot per 23 hours (vs. 5–10 per search before)
   - `SearchNearby` SKU: unchanged in frequency, but reduced by DB seeding — once an area is seeded, no further `SearchNearby` calls fire

---

## Rollout Notes

- **Backward compatibility**: existing spots in DB have `photo_uri`, `flag_content_uri`,
  `google_maps_uri`, `height_px`, `width_px` in their photos. The data migration (Change 3c)
  strips these to `name`-only. The `SpotPhotoSchema` (Change 3b) acts as a second guard —
  any stale fields that survive are never serialized to the API response.
- **Redis failure**: all Redis calls are wrapped in `try/except` with a `logger.warning`.
  If Redis is unreachable, every response falls through to Google — the API keeps working
  at higher cost, and the warnings make the outage visible in logs.
- **Data migration required**: Change 3c must run at deployment. It strips stale fields
  from existing `spot.photos` rows and caps each spot to 1 photo. No schema (ALTER TABLE)
  migrations are needed — JSONB column shape is unchanged.
- No mobile app changes required — API response shape of `spot.photos` is preserved
  (`photo_uri` still present in responses, just resolved differently).
