# Legal acceptance — server contract (backend spec)

## Overview

Persist **terms / legal acceptance on the server** so onboarding or gating steps can treat acceptance as **authoritative**, consistent across devices, and independent of local client storage. This mirrors the existing pattern used for **`onboarding_completed_at`** on `users` (nullable UTC timestamp, set once via profile update, owner-only visibility on public profile responses).

**Target API surfaces (srvn-backend):**

- Expose acceptance fields on **`GET /users/profile`** (authenticated self profile).
- Allow recording acceptance via **`PUT /users/update-profile`**, alongside other profile fields (boolean flag → server sets timestamp once, idempotent).

---

## Decision: minimal vs versioned

| Approach | When to use | Suggested columns |
|----------|-------------|-------------------|
| **A. Timestamp only** | Proof of one-time acceptance is enough; rare or out-of-band re-prompts | `terms_accepted_at` — nullable `DateTime(timezone=True)`, set once, never cleared via API |
| **B. Timestamp + versions** | Must **re-prompt** when Terms/Privacy documents change; audits need “which revision” | `terms_accepted_at` + `terms_version`, and optionally `privacy_accepted_at` + `privacy_version` — or a single `legal_accepted_at` plus version fields |

**Recommendation:** Ship **A** if product/legal only needs “accepted at least once.” Add **B** when compliance requires matching acceptance to a specific document revision or forced re-acceptance in-app.

---

## Implementation phases

### 1. Data model and migration

- Add nullable UTC datetime column(s) on `users` (same SQLAlchemy style as `onboarding_completed_at`).
- **Alembic migration — backfill policy (explicit product/legal choice):**
  - **`NULL`:** existing users must accept in-app (strict).
  - **Grandfather:** e.g. set to `created_at` or `now()` for non-deleted rows (document in release notes and support runbooks).

Optional **B:** add `terms_version` / `privacy_version` as short strings or integers; values should be defined and owned by the backend (or config), not invented per request without a policy.

### 2. Serialization (read path)

- Add fields to **`UserProfileResponseSchema`** (`dump_only`, `allow_none=True`, OpenAPI `metadata.description`).
- Include the same keys in **`User.get_authenticated_profile_data()`** (or equivalent) so **`GET /users/profile`** stays aligned with the schema.
- **Privacy:** Same rule as **`onboarding_completed_at`**: return real values **only to the profile owner**; for **`GET /users/<id>/profile`**, share-token responses, and other-user contexts, return **`null`** (or omit consistently). Update any parallel payloads (e.g. review-author profile) if they reuse the same contract.

### 3. Write path (`PUT /users/update-profile`)

- Extend **`UserUpdateSchema`** with an optional boolean, e.g. `terms_accepted: true` (or `legal_accepted: true`).
- In **`update_profile`:**
  - If `true` and stored acceptance timestamp is **`NULL`**, set **`datetime.now(timezone.utc)`** (and, for **B**, set version fields from **server constants / config**, not from untrusted client input unless explicitly justified).
  - If `false` or omitted: **no-op** (do **not** clear acceptance).
  - If already set: **idempotent** success (no timestamp change), matching onboarding behavior.

### 4. Versioning (approach B only)

- Define **current** `TERMS_VERSION` / `PRIVACY_VERSION` in config or a small constants module.
- **Read path:** clients compare stored version(s) to current to decide whether to show the legal screen again.
- **Write path:** on accept, persist timestamp **and** current server version(s).
- **Compliance rule (document in API):** e.g. user is “up to date” iff `terms_accepted_at` is non-null **and** `terms_version == CURRENT_TERMS_VERSION` (and similarly for privacy if applicable).

### 5. Tests (project policy)

Per **`AGENTS.md`** in srvn-backend:

- **Schema:** load/validation for new update flags; response shape for new read-only fields.
- **API:** authenticated profile returns expected values after accept; second accept is idempotent; non-owner public profile hides sensitive fields; optional version-mismatch scenarios if **B** is implemented.

### 6. Documentation and client contract

- Update OpenAPI route descriptions for **`GET /users/profile`** and **`PUT /users/update-profile`** (same style as onboarding fields).
- **Client rule:** treat server fields as **source of truth**; local storage is cache only.

### 7. Rollout

- Deploy backend first (nullable columns; backward compatible).
- Clients switch gating from local-only → server-backed; treat **`NULL`** as not accepted.
- If migration grandfathered users, communicate to support/legal.

---

## Risks and notes

- **Trust model:** Prefer **server-defined** version strings; avoid accepting arbitrary versions from the client unless spoofing is acceptable for your threat model.
- **Evidence:** Timestamps answer **when**; versions answer **what** — retain both if audits matter.
- **Deletion / anonymization:** Align with data-retention policy (hard delete vs anonymize and whether acceptance records must remain).

---

## Reference implementation in codebase

When implementing in **srvn-backend**, use **`onboarding_completed_at`** as the template:

- `ressy_backend/models/user.py` — column(s)
- `migrations/versions/` — Alembic revision
- `ressy_backend/schemas/user.py` — `UserProfileResponseSchema`, `UserUpdateSchema`
- `ressy_backend/routes/user.py` — profile GET, `update_profile`, public profile / share-token payloads
- `ressy_backend/routes/socials.py` — any owner-scoped profile fragments
- `tests/srvn_backend/` — schema and API tests

---

## Document status

**Option B implemented in srvn-backend:** `terms_accepted_at`, `terms_version`, `privacy_accepted_at`, `privacy_version` on `users`; server constants in `ressy_backend/constants/legal_versions.py`; `GET /users/profile` and `PUT /users/update-profile` (`terms_accepted`, `privacy_accepted`); `current_terms_version` / `current_privacy_version` on profile responses for re-prompt logic. Migration: `a1b2c3d4e5f6_add_legal_acceptance_to_users.py`. Existing users remain `NULL` until they accept (no grandfather backfill unless added later).
