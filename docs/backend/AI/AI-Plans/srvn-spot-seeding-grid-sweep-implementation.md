# srvn spot seeding — implementation plan (with code)

> Companion to **[srvn-spot-seeding-grid-sweep.md](./srvn-spot-seeding-grid-sweep.md)** (the design).
> This is the build guide: ordered steps, each with code snippets matched to the repo's
> existing patterns. Verified against the codebase 2026-06-22. Current Alembic head:
> **`a3d9f4b1c2e7`** (use as the migration's `down_revision`; re-check before generating).

Build order (each step compiles/tests on its own):

1. Config knobs → 2. Model + migration → 3. Google client params/masks →
4. `upsert_serialized_spots` refactor → 5. Enrichment gating →
6. Seeder service → 7. CLI group → 8. Register CLI → 9. `.env` sample → 10. Tests

All new identifiers use **`srvn`** (never `ressy`/`ressify`).

---

## Step 1 — Config knobs (`ressy_backend/config.py`)

Follow the existing `*_RAW` class-attr → typed-in-`__init__` pattern (bools via
`.lower() == "true"`; ints via the validation loop at `config.py:489`).

**1a. Raw class attributes** — add near the other `SRVN_*_RAW` block (~`config.py:355`):

```python
    # --- srvn spot seeding (grid sweep) -----------------------------------
    SRVN_SEED_ENABLED_RAW = os.environ.get("SRVN_SEED_ENABLED", "false")
    SRVN_SEED_DEFAULT_MODE_RAW = os.environ.get("SRVN_SEED_DEFAULT_MODE", "exhaustive")
    SRVN_SEED_MONTHLY_CALL_CAP_RAW = os.environ.get("SRVN_SEED_MONTHLY_CALL_CAP", "950")
    SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M_RAW = os.environ.get(
        "SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M", "250"
    )
    SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH_RAW = os.environ.get(
        "SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH", "6"
    )
    SRVN_SEED_POPULAR_CELL_RADIUS_M_RAW = os.environ.get(
        "SRVN_SEED_POPULAR_CELL_RADIUS_M", "700"
    )
    SRVN_SEED_POPULAR_MAX_DEPTH_RAW = os.environ.get("SRVN_SEED_POPULAR_MAX_DEPTH", "2")
    SRVN_SEED_MAX_GRID_CELLS_RAW = os.environ.get("SRVN_SEED_MAX_GRID_CELLS", "5000")
    SRVN_SEED_MAX_RETRIES_RAW = os.environ.get("SRVN_SEED_MAX_RETRIES", "3")
    # Global kill-switch for on-view Place Details enrichment. Set false during
    # seeding so freshly-seeded spots don't auto-enrich (design §9).
    SPOT_LAZY_REFRESH_ENABLED_RAW = os.environ.get("SPOT_LAZY_REFRESH_ENABLED", "true")
```

**1b. Typed assignment** — in `Config.__init__`, alongside the other srvn typing (~`config.py:482`):

```python
        # srvn spot seeding — booleans
        self.SRVN_SEED_ENABLED = Config.SRVN_SEED_ENABLED_RAW.lower() == "true"
        self.SPOT_LAZY_REFRESH_ENABLED = (
            Config.SPOT_LAZY_REFRESH_ENABLED_RAW.lower() == "true"
        )
        # srvn spot seeding — mode (validated enum)
        mode = Config.SRVN_SEED_DEFAULT_MODE_RAW.lower()
        if mode not in ("exhaustive", "popular"):
            raise ValueError(
                f"SRVN_SEED_DEFAULT_MODE '{mode}' must be 'exhaustive' or 'popular'."
            )
        self.SRVN_SEED_DEFAULT_MODE = mode
```

Then **append the int knobs to the existing positive-int validation loop** (`config.py:489`):

```python
        for attr, raw in (
            ("SRVN_TASTE_EMBED_BACKFILL_CAP", Config.SRVN_TASTE_EMBED_BACKFILL_CAP_RAW),
            ("SRVN_TASTE_EMBED_STEADY_CAP", Config.SRVN_TASTE_EMBED_STEADY_CAP_RAW),
            (
                "SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET",
                Config.SRVN_TASTE_EMBED_DAILY_TOKEN_BUDGET_RAW,
            ),
            # --- added for spot seeding ---
            ("SRVN_SEED_MONTHLY_CALL_CAP", Config.SRVN_SEED_MONTHLY_CALL_CAP_RAW),
            ("SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M", Config.SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M_RAW),
            ("SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH", Config.SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH_RAW),
            ("SRVN_SEED_POPULAR_CELL_RADIUS_M", Config.SRVN_SEED_POPULAR_CELL_RADIUS_M_RAW),
            ("SRVN_SEED_POPULAR_MAX_DEPTH", Config.SRVN_SEED_POPULAR_MAX_DEPTH_RAW),
            ("SRVN_SEED_MAX_GRID_CELLS", Config.SRVN_SEED_MAX_GRID_CELLS_RAW),
            ("SRVN_SEED_MAX_RETRIES", Config.SRVN_SEED_MAX_RETRIES_RAW),
        ):
            try:
                value = int(raw)
            except ValueError:
                raise ValueError(f"{attr} '{raw}' must be a valid integer.")
            if value <= 0:
                raise ValueError(f"{attr} must be a positive integer (got {value}).")
            setattr(self, attr, value)
```

> `POPULAR_MAX_DEPTH` ≥ 1 is fine (depth-2 cap means root + 1 subdivision). All knobs are `> 0`.

---

## Step 2 — Model + migration

### 2a. Model (`ressy_backend/models/srvn_seed_grid_cell.py`)

Use the plain `Model` base (gives `created_at` + `updated_at` with `onupdate` — the
latter powers stale-`in_progress` detection). Not `SoftDeleteModel`: grid cells aren't
soft-deletable.

```python
"""Resumable Google Nearby grid-sweep cells for bulk Spot seeding.

One row == one Nearby Search request footprint (a circle). The seeder
(`services/srvn_spot_seeder.py`) is the only writer. See
`docs/plans/AI-Plans/srvn-spot-seeding-grid-sweep.md`.
"""

from datetime import datetime
from typing import Optional

from sqlalchemy import BigInteger, Float, ForeignKey, Index, Integer, SmallInteger, String, Text, UniqueConstraint
from sqlalchemy import DateTime
from sqlalchemy.orm import Mapped, mapped_column

from ressy_backend.database import Model
from ressy_backend.extensions import db


class SrvnSeedGridCell(Model):
    __tablename__ = "srvn_seed_grid_cells"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)

    region: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    # 'exhaustive' | 'popular' — stamped at init-grid, inherited by children.
    mode: Mapped[str] = mapped_column(String(16), nullable=False)

    # Rounded to 7 dp at generation time so the UNIQUE key is bit-stable
    # across regenerations (ON CONFLICT DO NOTHING idempotency).
    center_lat: Mapped[float] = mapped_column(Float, nullable=False)
    center_lng: Mapped[float] = mapped_column(Float, nullable=False)
    radius_m: Mapped[int] = mapped_column(Integer, nullable=False)

    depth: Mapped[int] = mapped_column(SmallInteger, nullable=False, default=0)
    parent_id: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("srvn_seed_grid_cells.id"), nullable=True
    )

    # pending | in_progress | done | saturated | error
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending", index=True)
    result_count: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    new_spot_count: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    retry_count: Mapped[int] = mapped_column(SmallInteger, nullable=False, default=0, server_default="0")
    error: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    swept_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("center_lat", "center_lng", "radius_m", name="uq_srvn_seed_cell_geom"),
        # Partial index for the hot claim query (status='pending').
        Index(
            "ix_srvn_seed_cells_pending",
            "depth",
            "id",
            postgresql_where=db.text("status = 'pending'"),
        ),
        Index("ix_srvn_seed_cells_region_mode_status", "region", "mode", "status"),
    )
```

Register in **`ressy_backend/models/__init__.py`** (so autogenerate sees it and the
Spot `after_insert` listener loads — add after the spot import):

```python
from ressy_backend.models.srvn_seed_grid_cell import *  # noqa
```

> Add `__all__ = ["SrvnSeedGridCell"]` to the model module so the `import *` is explicit.

### 2b. Migration (`migrations/versions/<rev>_create_srvn_seed_grid_cells.py`)

Generate with `poetry run flask db migrate -m "create srvn_seed_grid_cells"` then verify
it matches the model (autogenerate may miss the partial-index `postgresql_where`). Expected body:

```python
"""create srvn_seed_grid_cells (spot seeding grid sweep)

Revision ID: <new>
Revises: a3d9f4b1c2e7
Create Date: ...
"""
import sqlalchemy as sa
from alembic import op

revision = "<new>"
down_revision = "a3d9f4b1c2e7"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "srvn_seed_grid_cells",
        sa.Column("id", sa.BigInteger(), nullable=False),
        sa.Column("region", sa.String(length=128), nullable=False),
        sa.Column("mode", sa.String(length=16), nullable=False),
        sa.Column("center_lat", sa.Float(), nullable=False),
        sa.Column("center_lng", sa.Float(), nullable=False),
        sa.Column("radius_m", sa.Integer(), nullable=False),
        sa.Column("depth", sa.SmallInteger(), nullable=False),
        sa.Column("parent_id", sa.BigInteger(), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("result_count", sa.Integer(), nullable=True),
        sa.Column("new_spot_count", sa.Integer(), nullable=True),
        sa.Column("retry_count", sa.SmallInteger(), nullable=False, server_default="0"),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("swept_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["parent_id"], ["srvn_seed_grid_cells.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("center_lat", "center_lng", "radius_m", name="uq_srvn_seed_cell_geom"),
    )
    op.create_index("ix_srvn_seed_grid_cells_region", "srvn_seed_grid_cells", ["region"])
    op.create_index(
        "ix_srvn_seed_cells_pending",
        "srvn_seed_grid_cells",
        ["depth", "id"],
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_index(
        "ix_srvn_seed_cells_region_mode_status",
        "srvn_seed_grid_cells",
        ["region", "mode", "status"],
    )


def downgrade():
    op.drop_index("ix_srvn_seed_cells_region_mode_status", table_name="srvn_seed_grid_cells")
    op.drop_index("ix_srvn_seed_cells_pending", table_name="srvn_seed_grid_cells")
    op.drop_index("ix_srvn_seed_grid_cells_region", table_name="srvn_seed_grid_cells")
    op.drop_table("srvn_seed_grid_cells")
```

> No backfill of existing rows needed (unlike the taste tables) — the table starts empty.

---

## Step 3 — Google client: masks, type filter, params (`googleplaces_services.py`)

### 3a. Field masks — already in the code (Enterprise-only policy, 2026-06-22)

The tier constants + masks now exist in `googleplaces_services.py`: `_PRO_TIER_FIELDS`,
`_ENTERPRISE_TIER_FIELDS`, `_ATMOSPHERE_TIER_FIELDS` (defined but used by no mask), and
`_places_prefixed()`. Policy: **no atmosphere, no photos, no reviews anywhere.**

- `nearby_field_paths` **and** `seed_lean_field_paths` are both `_places_prefixed(_PRO_TIER_FIELDS + _ENTERPRISE_TIER_FIELDS)` — identical today (kept as two names so the modes can diverge later).
- `detail_field_paths` = `_PRO_TIER_FIELDS + _ENTERPRISE_TIER_FIELDS + ["movedPlaceId"]` (bare names); `get_restaurant_details` uses it.

**Still to add** for the seeder — the type-filter constants + the `included_primary_types` sentinel:

```python
# Dine-in & drink umbrella (Table A, all filterable). 'food' is Table B
# (response-only) and raises INVALID_ARGUMENT if sent in includedTypes.
# `restaurant` subsumes the whole *_restaurant cuisine family; the rest are the
# non-restaurant categories. ~33 types, under the 50-per-request cap. Excludes
# retail/production (candy/chocolate/roastery/confectionery), cafeteria, hookah.
seed_included_types = [
    "restaurant",
    "cafe", "coffee_shop", "coffee_stand", "cat_cafe", "dog_cafe",
    "tea_house", "juice_shop", "acai_shop",
    "bakery", "bagel_shop", "cake_shop", "pastry_shop",
    "dessert_shop", "ice_cream_shop", "donut_shop",
    "deli", "sandwich_shop", "salad_shop", "snack_bar", "bistro",
    "bar", "bar_and_grill", "pub", "wine_bar", "cocktail_bar",
    "sports_bar", "lounge_bar", "beer_garden", "gastropub",
    "brewery", "brewpub", "winery",
]

# Drop *primarily* quick-service places (filters by primary type, so a sit-down
# restaurant that merely also offers takeaway is kept).
seed_excluded_primary_types = [
    "fast_food_restaurant", "meal_takeaway", "meal_delivery", "food_court",
]

# Sentinel so callers can pass included_primary_types=None to omit it entirely,
# while the default (live path) still sends ["restaurant"].
_UNSET = object()
```

### 3b. Extend `get_nearby_restaurants` (replace the current def at ~line 541)

```python
def get_nearby_restaurants(
    longitude: float,
    latitude: float,
    radius_meters: float,
    additional_types: list[str] | None = None,
    *,
    field_paths: list[str] | None = None,
    included_types: list[str] | None = None,
    included_primary_types=_UNSET,
    excluded_primary_types: list[str] | None = None,
    rank_preference=None,
):
    """Nearby Search (New). Defaults preserve the original live behavior
    (restaurant umbrella, POPULARITY, Enterprise-only mask,
    includedPrimaryTypes=['restaurant']). The seeder overrides per mode (design §1)."""
    if included_types is None:
        included_types = list({"restaurant", *(additional_types or [])})
    if included_primary_types is _UNSET:
        included_primary_types = ["restaurant"]
    if field_paths is None:
        field_paths = nearby_field_paths
    if rank_preference is None:
        rank_preference = places_v1.SearchNearbyRequest.RankPreference.POPULARITY

    location_restriction = places_v1.SearchNearbyRequest.LocationRestriction()
    location_restriction.circle.center.latitude = latitude
    location_restriction.circle.center.longitude = longitude
    location_restriction.circle.radius = radius_meters

    request_kwargs = dict(
        language_code="en",
        included_types=included_types,
        location_restriction=location_restriction,
        rank_preference=rank_preference,
        max_result_count=20,
    )
    # Omit (don't pass empty list) when None so Google doesn't AND-filter on it.
    if included_primary_types:
        request_kwargs["included_primary_types"] = included_primary_types
    if excluded_primary_types:
        request_kwargs["excluded_primary_types"] = excluded_primary_types

    request = places_v1.SearchNearbyRequest(**request_kwargs)
    metadata_header = [
        ("x-goog-fieldmask", ",".join(field_paths)),
        ("user-agent", "ressy-backend/1.0"),
    ]
    try:
        response = client.search_nearby(request=request, metadata=metadata_header)
        return [serialize_place(p) for p in response.places]
    except Exception as e:
        current_app.logger.error(f"Google Places API error (get_nearby_restaurants): {str(e)}")
        raise e
```

> `serialize_place()` already tolerates the Enterprise-only mask (atmosphere fields → `None`/`False`, `photos`/`reviews` → `[]`). No serializer change.

---

## Step 4 — `upsert_serialized_spots` refactor (`spot_service.py`)

Extract the duplicated loop (currently `get_or_create_spots_from_google()` lines 85–177
**and** `process_and_store_google_spots()` lines 218–311) into one helper. Contract:
returns `int`, **raises** on commit failure, stamps `photos_refreshed_at` only when photos present.

```python
def upsert_serialized_spots(serialized: list[dict]) -> int:
    """Insert new Spots from serialized Google results; dedupe by provider_id.

    Returns the count newly created. RAISES on commit failure. Single source
    of PostGIS point creation + the after_insert taste-feature trigger, reused
    by the live cache-miss path, the legacy route helper, and the seeder.
    """
    now = datetime.now(timezone.utc)
    new_spots: list[Spot] = []

    for spot_data in serialized:
        provider_id = _extract_provider_id(spot_data)
        if not provider_id:
            current_app.logger.warning(
                f"Skipping spot without provider_id: {spot_data.get('name')}"
            )
            continue

        location = spot_data.get("location", {})
        if not location or "latitude" not in location or "longitude" not in location:
            current_app.logger.warning(
                f"Skipping spot without valid location: {spot_data.get('name')}"
            )
            continue

        if Spot.query.filter_by(provider_id=provider_id).first():
            continue

        location_point = func.ST_SetSRID(
            func.ST_MakePoint(location["longitude"], location["latitude"]), 4326
        )
        searchable_text = " ".join(
            filter(None, [
                spot_data.get("name", ""),
                spot_data.get("address", ""),
                " ".join(spot_data.get("types", [])),
            ])
        )
        spot = Spot(
            provider_id=provider_id,
            provider=spot_data.get("provider"),
            name=spot_data.get("name"),
            info=spot_data.get("info"),
            address=spot_data.get("address"),
            types=spot_data.get("types"),
            rating=spot_data.get("rating"),
            photos=spot_data.get("photos"),
            regular_opening_hours=spot_data.get("regular_opening_hours"),
            last_refreshed_at=now,
            # No-op today (Enterprise-only mask returns no photos → always NULL),
            # but correct if photos are ever re-enabled: a row carrying fresh photo
            # references gets stamped so should_refresh_photos() doesn't fire a
            # redundant photos-only Place Details pull at launch.
            photos_refreshed_at=now if spot_data.get("photos") else None,
            location=location_point,
            search_vector=func.to_tsvector("english", searchable_text),
        )
        try:
            with db.session.begin_nested():
                db.session.add(spot)
                db.session.flush()
            new_spots.append(spot)
        except Exception as e:
            if "unique" in str(e).lower() or "duplicate" in str(e).lower():
                current_app.logger.info(
                    f"Spot {provider_id} already exists (race condition handled), skipping"
                )
            else:
                current_app.logger.warning(f"Failed to add spot {provider_id}: {e}")
            continue

    if new_spots:
        try:
            db.session.commit()
            current_app.logger.info(f"Added {len(new_spots)} new spots to database")
        except Exception as e:
            current_app.logger.error(f"Failed to commit new spots: {e}")
            db.session.rollback()
            raise
    return len(new_spots)


def _extract_provider_id(spot_data: dict) -> str | None:
    provider_data = spot_data.get("provider")
    if isinstance(provider_data, list) and provider_data:
        return provider_data[0].get("provider_id")
    if isinstance(provider_data, dict):
        return provider_data.get("provider_id")
    return None
```

**Repoint the two callers:**

- `process_and_store_google_spots()` — replace its whole body with `return upsert_serialized_spots(google_spots)`. The route caller (`spot.py:301`) only uses `len(new_spots)` for a log line; switch that to use the int directly, or keep the helper name and return the count. (Either rename the helper or have it delegate; recommend deleting `process_and_store_google_spots` and updating the import in `routes/spot.py` to call `upsert_serialized_spots`.)
- `get_or_create_spots_from_google()` — replace the inline loop + commit block (lines 85–177) with a guarded call so the **live path keeps swallowing** errors:

```python
    try:
        upsert_serialized_spots(google_spots)
    except Exception as e:
        current_app.logger.error(f"Failed to persist Google spots: {e}")
        # degrade: fall through to re-query whatever is already in the DB
    # ... existing re-query (find_nearby / search_nearby_with_text) unchanged ...
```

> Update `routes/spot.py` import: `from ressy_backend.services.spot_service import upsert_serialized_spots` and at line 301 `new_count = upsert_serialized_spots(google_spots)` / log `new_count`.

---

## Step 5 — Enrichment gating (`spot_refresh_service.py`)

Guard both auto-enrichment entry points so `SPOT_LAZY_REFRESH_ENABLED=false` makes them
no-ops globally during seeding. Add at the **top** of each function:

```python
from ressy_backend.config import CONFIG  # if not already imported

def lazy_refresh_spot(spot: Spot) -> None:
    if not CONFIG.SPOT_LAZY_REFRESH_ENABLED:
        return
    if not should_refresh_spot(spot):
        return
    # ... unchanged ...


def lazy_refresh_photos_only(spot: Spot) -> None:
    if not CONFIG.SPOT_LAZY_REFRESH_ENABLED:
        return
    if not should_refresh_photos(spot):
        return
    # ... unchanged ...
```

> Don't gate `refresh_spots_batch` (`spot_refresh_service.py:404`) — the deliberate
> `refresh-spots` CLI must keep working to enrich thin rows on demand (design §9).

---

## Step 6 — Seeder service (`ressy_backend/services/srvn_spot_seeder.py`)

Pure grid helpers (unit-testable, no I/O) + the two DB-touching entrypoints.

```python
"""Resumable Google Nearby grid-sweep seeder. See
docs/plans/AI-Plans/srvn-spot-seeding-grid-sweep.md."""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from flask import current_app
from sqlalchemy.dialects.postgresql import insert as pg_insert

from ressy_backend.config import CONFIG
from ressy_backend.extensions import db
from ressy_backend.models.srvn_seed_grid_cell import SrvnSeedGridCell
from ressy_backend.services.googleplaces_services import (
    get_nearby_restaurants,
    seed_excluded_primary_types,
    seed_included_types,
)
from ressy_backend.services.spot_service import upsert_serialized_spots
from google.maps import places_v1

METERS_PER_DEG_LAT = 111_320
SPACING_FACTOR = math.sqrt(2)          # inscribed-square grid step
CHILD_OFFSET_FACTOR = math.sqrt(2) / 4  # quadrant-center offset for subdivision
_COORD_DP = 7
_STALE_IN_PROGRESS_MIN = 15

_RANK = places_v1.SearchNearbyRequest.RankPreference


# --- mode → rank --------------------------------------------------------
# Both modes use the SAME (Enterprise-only) mask now, so the only per-mode
# Google-call difference is ranking. (Mask defaults to nearby_field_paths in
# get_nearby_restaurants — no field_paths override needed.)
def _mode_rank(mode: str):
    if mode == "exhaustive":
        return _RANK.DISTANCE
    if mode == "popular":
        return _RANK.POPULARITY
    raise ValueError(f"unknown seed mode {mode!r}")


# --- pure geometry -------------------------------------------------------
def _round(v: float) -> float:
    return round(v, _COORD_DP)


def generate_grid(bbox, radius_m: int) -> list[dict]:
    """Tile bbox=(min_lng,min_lat,max_lng,max_lat) with radius_m circles on a
    √2 inscribed-square step. Returns dicts {center_lat, center_lng, radius_m}."""
    min_lng, min_lat, max_lng, max_lat = bbox
    spacing_m = radius_m * SPACING_FACTOR
    dlat = spacing_m / METERS_PER_DEG_LAT
    cells: list[dict] = []
    lat = min_lat
    while lat <= max_lat:
        dlng = spacing_m / (METERS_PER_DEG_LAT * math.cos(math.radians(lat)))
        lng = min_lng
        while lng <= max_lng:
            cells.append(
                {"center_lat": _round(lat), "center_lng": _round(lng), "radius_m": radius_m}
            )
            lng += dlng
        lat += dlat
    return cells


def subdivide(center_lat: float, center_lng: float, radius_m: int) -> list[dict]:
    """4 children at radius_m/2, offset ±radius_m·√2/4 (quadrant centers).
    Each child circumscribes one quadrant sub-square of the parent's inscribed
    square — do NOT use ±radius_m/2 (leaves center/edge-midpoints uncovered)."""
    child_r = radius_m // 2
    offset_m = radius_m * CHILD_OFFSET_FACTOR
    dlat = offset_m / METERS_PER_DEG_LAT
    dlng = offset_m / (METERS_PER_DEG_LAT * math.cos(math.radians(center_lat)))
    return [
        {
            "center_lat": _round(center_lat + sy * dlat),
            "center_lng": _round(center_lng + sx * dlng),
            "radius_m": child_r,
        }
        for sy in (-1, 1)
        for sx in (-1, 1)
    ]


# --- results -------------------------------------------------------------
@dataclass
class SeedRunResult:
    cells_swept: int = 0
    calls_made: int = 0
    new_spots: int = 0
    errors: int = 0
    stopped_reason: str = ""


# --- redis month counter -------------------------------------------------
def _month_key(now: datetime) -> str:
    return f"srvn:seed:calls:{now.strftime('%Y-%m')}"


def _spent_this_month(now: datetime) -> int:
    return int(CONFIG.REDIS_CLIENT.get(_month_key(now)) or 0)


# --- bulk insert (idempotent) -------------------------------------------
def _insert_cells(rows: list[dict]) -> int:
    if not rows:
        return 0
    stmt = (
        pg_insert(SrvnSeedGridCell.__table__)
        .values(rows)
        .on_conflict_do_nothing(constraint="uq_srvn_seed_cell_geom")
    )
    result = db.session.execute(stmt)
    db.session.commit()
    return result.rowcount or 0


# --- public API ----------------------------------------------------------
def init_grid(region: str, bbox, cell_radius_m: int, mode: str, force: bool = False) -> int:
    """Generate + bulk-insert pending root cells with mode stamped. Refuses an
    oversized bbox unless force=True. Returns count inserted."""
    cells = generate_grid(bbox, cell_radius_m)
    current_app.logger.info(
        f"init_grid region={region} mode={mode} radius={cell_radius_m}m -> {len(cells)} cells"
    )
    if len(cells) > CONFIG.SRVN_SEED_MAX_GRID_CELLS and not force:
        raise ValueError(
            f"{len(cells)} cells exceeds SRVN_SEED_MAX_GRID_CELLS="
            f"{CONFIG.SRVN_SEED_MAX_GRID_CELLS}; shrink the bbox or pass force=True."
        )
    rows = [
        {**c, "region": region, "mode": mode, "depth": 0, "status": "pending"} for c in cells
    ]
    return _insert_cells(rows)


def run_seed(max_calls: int | None = None) -> SeedRunResult:
    """Resumable claim-then-release loop. Honors the monthly Redis cap."""
    res = SeedRunResult()
    now = datetime.now(timezone.utc)
    try:
        spent = _spent_this_month(now)
    except Exception as e:  # Redis down -> fail closed
        current_app.logger.error(f"run_seed: Redis unavailable, fail-closed: {e}")
        res.stopped_reason = "redis_unavailable"
        return res

    budget = CONFIG.SRVN_SEED_MONTHLY_CALL_CAP - spent
    if max_calls is not None:
        budget = min(budget, max_calls)
    if budget <= 0:
        res.stopped_reason = "budget_exhausted"
        current_app.logger.info(f"run_seed: no budget (spent={spent})")
        return res

    while res.calls_made < budget:
        # --- claim one cell ---
        cell = (
            db.session.query(SrvnSeedGridCell)
            .filter(SrvnSeedGridCell.status == "pending")
            .order_by(SrvnSeedGridCell.depth.asc(), SrvnSeedGridCell.id.asc())
            .with_for_update(skip_locked=True)
            .first()
        )
        if cell is None:
            res.stopped_reason = "no_pending"
            break
        cell.status = "in_progress"
        db.session.commit()  # release lock; cell now claimed

        try:
            results = get_nearby_restaurants(
                longitude=cell.center_lng,
                latitude=cell.center_lat,
                radius_meters=cell.radius_m,
                rank_preference=_mode_rank(cell.mode),  # mask defaults to nearby_field_paths
                included_types=seed_included_types,
                included_primary_types=None,
                excluded_primary_types=seed_excluded_primary_types,
            )
        except Exception as e:
            cell.status = "error"
            cell.retry_count = (cell.retry_count or 0) + 1
            cell.error = str(e)[:2000]
            db.session.commit()
            res.errors += 1
            current_app.logger.warning(f"run_seed: cell {cell.id} error: {e}")
            continue

        # count the successful call (after the call; under-counts on crash by design)
        try:
            key = _month_key(now)
            CONFIG.REDIS_CLIENT.incr(key)
            CONFIG.REDIS_CLIENT.expire(key, 45 * 24 * 3600)
        except Exception as e:
            current_app.logger.error(f"run_seed: counter incr failed: {e}")
        res.calls_made += 1

        new = upsert_serialized_spots(results)

        # --- finalize ---
        cell.result_count = len(results)
        cell.new_spot_count = new
        cell.swept_at = datetime.now(timezone.utc)
        saturated = len(results) >= 20
        cell.status = "saturated" if saturated else "done"
        if saturated and _should_subdivide(cell):
            _enqueue_children(cell)
        db.session.commit()

        res.cells_swept += 1
        res.new_spots += new

    if not res.stopped_reason:
        res.stopped_reason = "budget_exhausted"
    return res


def _should_subdivide(cell: SrvnSeedGridCell) -> bool:
    if cell.mode == "exhaustive":
        return cell.depth < CONFIG.SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH
    if cell.mode == "popular":
        return cell.depth < CONFIG.SRVN_SEED_POPULAR_MAX_DEPTH
    return False


def _enqueue_children(cell: SrvnSeedGridCell) -> None:
    children = subdivide(cell.center_lat, cell.center_lng, cell.radius_m)
    rows = [
        {
            **c,
            "region": cell.region,
            "mode": cell.mode,
            "depth": cell.depth + 1,
            "parent_id": cell.id,
            "status": "pending",
        }
        for c in children
        if c["radius_m"] >= 1
    ]
    if rows:
        stmt = (
            pg_insert(SrvnSeedGridCell.__table__)
            .values(rows)
            .on_conflict_do_nothing(constraint="uq_srvn_seed_cell_geom")
        )
        db.session.execute(stmt)  # committed by caller


def reset_cells(region: str | None = None, kind: str = "error") -> int:
    """Re-queue stranded cells. kind='error' resets error cells under the retry
    cap; kind='stuck' resets stale in_progress; kind='all' does both."""
    now = datetime.now(timezone.utc)
    stale_cutoff = now - timedelta(minutes=_STALE_IN_PROGRESS_MIN)
    total = 0
    q = db.session.query(SrvnSeedGridCell)
    if region:
        q = q.filter(SrvnSeedGridCell.region == region)

    if kind in ("error", "all"):
        n = (
            q.filter(
                SrvnSeedGridCell.status == "error",
                SrvnSeedGridCell.retry_count < CONFIG.SRVN_SEED_MAX_RETRIES,
            )
            .update({SrvnSeedGridCell.status: "pending"}, synchronize_session=False)
        )
        total += n
    if kind in ("stuck", "all"):
        n = (
            q.filter(
                SrvnSeedGridCell.status == "in_progress",
                SrvnSeedGridCell.updated_at < stale_cutoff,
            )
            .update({SrvnSeedGridCell.status: "pending"}, synchronize_session=False)
        )
        total += n
    db.session.commit()
    return total
```

> Note: `_enqueue_children` runs inside the cell's open transaction and is committed by the
> finalize `db.session.commit()`, so children appear atomically with the parent's status flip.

---

## Step 7 — CLI group (`ressy_backend/commands/srvn_seed_spots_command.py`)

Mirror `waitlist_cli` (`AppGroup` + `@group.command` + `@with_appcontext`).

```python
"""srvn spot-seeding CLI — `flask srvn-seed …`. See
docs/plans/AI-Plans/srvn-spot-seeding-grid-sweep.md."""

from __future__ import annotations

import click
from flask import current_app
from flask.cli import AppGroup, with_appcontext
from sqlalchemy import func

from ressy_backend.config import CONFIG
from ressy_backend.extensions import db
from ressy_backend.models.srvn_seed_grid_cell import SrvnSeedGridCell
from ressy_backend.services.srvn_spot_seeder import (
    _month_key,
    init_grid,
    reset_cells,
    run_seed,
)

srvn_seed_cli = AppGroup("srvn-seed", help="Bulk Spot seeding via Google Nearby grid sweep.")


def _parse_bbox(raw: str) -> tuple[float, float, float, float]:
    """minlng,minlat,maxlng,maxlat (longitude first — matches PostGIS x,y)."""
    parts = [p.strip() for p in raw.split(",")]
    if len(parts) != 4:
        raise click.ClickException("--bbox must be 'minlng,minlat,maxlng,maxlat'")
    try:
        min_lng, min_lat, max_lng, max_lat = (float(p) for p in parts)
    except ValueError as exc:
        raise click.ClickException(f"--bbox has non-numeric values: {raw}") from exc
    if min_lng >= max_lng or min_lat >= max_lat:
        raise click.ClickException("--bbox min must be < max (lng,lat order)")
    return (min_lng, min_lat, max_lng, max_lat)


@srvn_seed_cli.command("init-grid")
@click.option("--region", required=True, help="Label, e.g. 'toronto-downtown'.")
@click.option("--bbox", required=True, help="minlng,minlat,maxlng,maxlat (longitude first).")
@click.option(
    "--mode",
    type=click.Choice(["exhaustive", "popular"]),
    default=None,
    help="Default: SRVN_SEED_DEFAULT_MODE.",
)
@click.option("--cell-radius", type=click.IntRange(min=1), default=None, help="Root radius (m).")
@click.option("--force", is_flag=True, help="Allow a grid over SRVN_SEED_MAX_GRID_CELLS.")
@with_appcontext
def init_grid_cmd(region, bbox, mode, cell_radius, force):
    """Generate + insert pending root cells for a region."""
    mode = mode or CONFIG.SRVN_SEED_DEFAULT_MODE
    if cell_radius is None:
        cell_radius = (
            CONFIG.SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M
            if mode == "exhaustive"
            else CONFIG.SRVN_SEED_POPULAR_CELL_RADIUS_M
        )
    try:
        inserted = init_grid(region, _parse_bbox(bbox), cell_radius, mode, force=force)
    except ValueError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"Inserted {inserted} new cells (region={region}, mode={mode}, radius={cell_radius}m).")


@srvn_seed_cli.command("run")
@click.option("--max-calls", type=click.IntRange(min=1), default=None, help="Cap calls this run.")
@with_appcontext
def run_cmd(max_calls):
    """Sweep pending cells until budget/cap is hit."""
    if not CONFIG.SRVN_SEED_ENABLED:
        raise click.ClickException("SRVN_SEED_ENABLED is false.")
    res = run_seed(max_calls=max_calls)
    click.echo(
        f"swept={res.cells_swept} calls={res.calls_made} new_spots={res.new_spots} "
        f"errors={res.errors} stop={res.stopped_reason}"
    )


@srvn_seed_cli.command("status")
@with_appcontext
def status_cmd():
    """Per region+mode cell counts by status + month calls spent."""
    from datetime import datetime, timezone

    rows = (
        db.session.query(
            SrvnSeedGridCell.region,
            SrvnSeedGridCell.mode,
            SrvnSeedGridCell.status,
            func.count(SrvnSeedGridCell.id),
        )
        .group_by(SrvnSeedGridCell.region, SrvnSeedGridCell.mode, SrvnSeedGridCell.status)
        .order_by(SrvnSeedGridCell.region, SrvnSeedGridCell.mode)
        .all()
    )
    for region, mode, status, count in rows:
        click.echo(f"{region:<24} {mode:<11} {status:<12} {count}")
    spent = int(CONFIG.REDIS_CLIENT.get(_month_key(datetime.now(timezone.utc))) or 0)
    click.echo(f"\nMonth calls spent: {spent} / cap {CONFIG.SRVN_SEED_MONTHLY_CALL_CAP}")


@srvn_seed_cli.command("reset")
@click.option("--region", default=None, help="Limit to one region.")
@click.option("--kind", type=click.Choice(["error", "stuck", "all"]), default="error")
@with_appcontext
def reset_cmd(region, kind):
    """Re-queue error and/or stale in_progress cells."""
    n = reset_cells(region=region, kind=kind)
    click.echo(f"Re-queued {n} cells (kind={kind}, region={region or 'ALL'}).")
```

> `status`/`run` import `_month_key` from the seeder — or promote it to a public name if you
> prefer not to import a `_`-prefixed helper across modules.

---

## Step 8 — Register the CLI (`ressy_backend/app.py`)

In `register_commands()` (~`app.py:558`):

```python
    from ressy_backend.commands.srvn_seed_spots_command import srvn_seed_cli
    app.cli.add_command(srvn_seed_cli)
```

---

## Step 9 — `.env.development.sample`

Document the new vars (off by default):

```bash
# --- srvn spot seeding (grid sweep) ---
SRVN_SEED_ENABLED=false
SRVN_SEED_DEFAULT_MODE=exhaustive
SRVN_SEED_MONTHLY_CALL_CAP=950
SRVN_SEED_EXHAUSTIVE_CELL_RADIUS_M=250
SRVN_SEED_EXHAUSTIVE_SAFETY_DEPTH=6
SRVN_SEED_POPULAR_CELL_RADIUS_M=700
SRVN_SEED_POPULAR_MAX_DEPTH=2
SRVN_SEED_MAX_GRID_CELLS=5000
SRVN_SEED_MAX_RETRIES=3
# Set false while seeding so fresh spots don't auto-enrich; flip true at launch.
SPOT_LAZY_REFRESH_ENABLED=true
```

---

## Step 10 — Tests

`tests/services/test_srvn_spot_seeder.py` (unit — mock the Google client + Redis):

```python
import math
from unittest.mock import MagicMock

from ressy_backend.services import srvn_spot_seeder as seeder


def test_generate_grid_count_and_rounding():
    bbox = (-79.40, 43.64, -79.38, 43.66)
    cells = seeder.generate_grid(bbox, radius_m=250)
    assert cells, "expected at least one cell"
    for c in cells:
        assert round(c["center_lat"], 7) == c["center_lat"]  # 7-dp rounding
        assert c["radius_m"] == 250


def test_generate_grid_is_deterministic():
    bbox = (-79.40, 43.64, -79.38, 43.66)
    assert seeder.generate_grid(bbox, 250) == seeder.generate_grid(bbox, 250)


def test_subdivide_offset_and_radius():
    children = seeder.subdivide(43.65, -79.38, radius_m=400)
    assert len(children) == 4
    assert all(c["radius_m"] == 200 for c in children)
    # offset magnitude ≈ radius·√2/4 in meters → lat degrees
    expected_dlat = 400 * (math.sqrt(2) / 4) / seeder.METERS_PER_DEG_LAT
    lats = sorted({round(abs(c["center_lat"] - 43.65), 9) for c in children})
    assert math.isclose(lats[0], round(expected_dlat, 7), rel_tol=1e-3)


def test_subdivide_children_cover_parent_inscribed_square():
    """Coverage guard against the ±radius/2 gap: every corner, edge-midpoint,
    and the center of the parent's inscribed square is within some child circle."""
    R = 400.0
    clat, clng = 43.65, -79.38
    children = seeder.subdivide(clat, clng, int(R))
    half = R / math.sqrt(2)  # inscribed-square half-side, in meters
    mlat = seeder.METERS_PER_DEG_LAT
    mlng = mlat * math.cos(math.radians(clat))

    def covered(px_m, py_m):  # point offset from center, in meters
        for ch in children:
            dx = (ch["center_lng"] - clng) * mlng
            dy = (ch["center_lat"] - clat) * mlat
            if math.hypot(px_m - dx, py_m - dy) <= ch["radius_m"] + 1e-6:
                return True
        return False

    probes = [(0, 0), (half, 0), (-half, 0), (0, half), (0, -half),
              (half, half), (-half, -half), (half, -half), (-half, half)]
    assert all(covered(px, py) for px, py in probes)
```

Cover the rest per the design's testing plan:

- **Mode wiring** — `run_seed` with a stub `get_nearby_restaurants` asserts exhaustive sends
  `rank=DISTANCE`, popular sends `POPULARITY`; both send `included_primary_types=None` +
  `excluded_primary_types=seed_excluded_primary_types` and the **same** (default, Enterprise-only)
  mask — the seeder no longer passes `field_paths`.
- **Default (live) call unchanged** — `get_nearby_restaurants(lng, lat, r)` builds a request with
  `included_primary_types=['restaurant']`, POPULARITY, the Enterprise-only `nearby_field_paths`
  (regression guard).
- **Masks Enterprise-only** — `nearby_field_paths`/`seed_lean_field_paths` exclude all atmosphere
  fields + `places.photos`; `detail_field_paths` excludes atmosphere/photos/reviews, keeps
  `movedPlaceId`; keeps `rating`/`userRatingCount`. (Covered by the existing
  `test_serialize_place_strips_review_authors.py` mask tests.)
- **Subdivision by mode** — exhaustive keeps subdividing saturated stubs past depth 2 until one
  returns <20; popular stops at `SRVN_SEED_POPULAR_MAX_DEPTH`.
- **Budget guard** — stops at cap; honors `--max-calls`; an `error` cell does NOT incr the counter;
  month-key rollover (patch `now`) resets.
- **Resumability** — run 2 issues zero calls for run 1's done/saturated cells; a simulated
  `in_progress` cell is skipped by `run_seed` but re-queued by `reset_cells(kind="stuck")`.
- **Error recovery** — `reset_cells` flips `error→pending` only while `retry_count < cap`.
- **bbox guard** — `init_grid` over the cap raises without `force`, succeeds with `force=True`.
- **`upsert_serialized_spots`** — dedupe by `provider_id`; PostGIS point created; `last_refreshed_at`
  set; `photos_refreshed_at` set iff payload has `photos`; raises on commit failure (and the
  `get_or_create_spots_from_google` wrapper swallows it).
- **Enrichment suppression** — `SPOT_LAZY_REFRESH_ENABLED=false` ⇒ `lazy_refresh_spot` /
  `lazy_refresh_photos_only` early-return.

`tests/commands/test_srvn_seed_spots_command.py` (`api` marker; mock the Google client),
invoked via `app.test_cli_runner()`:

- `init-grid` populates cells (mode stamped); re-run is a no-op (ON CONFLICT); oversized bbox
  fails without `--force`.
- `run` (with `SRVN_SEED_ENABLED=true`) inserts spots and increments the month counter by the
  number of cells successfully swept; `run` with the flag off errors out.
- `reset` re-queues error/stale cells so a follow-up `run` re-attempts them.
- `status` prints per region+mode counts and the month-spent line.

Run: `poetry run pytest tests/services/test_srvn_spot_seeder.py tests/commands/test_srvn_seed_spots_command.py`.

---

## Rollout (recap from design §Rollout)

1. `poetry run flask db upgrade`
2. `SRVN_SEED_ENABLED=true`, `SPOT_LAZY_REFRESH_ENABLED=false` (confirm `REDIS_URL`, `GOOGLE_API_KEY`)
3. `flask srvn-seed init-grid --region <hood> --bbox <minlng,minlat,maxlng,maxlat>` → `flask srvn-seed run`
4. (optional) `flask srvn-seed init-grid --region <metro> --mode popular --bbox <…>` → `run --max-calls 950`
5. `flask srvn-seed status`; on transient errors `flask srvn-seed reset --region <r>` then re-`run`
6. (secondary rows) enrich via `flask refresh-spots …`; flip `SPOT_LAZY_REFRESH_ENABLED=true` at launch
