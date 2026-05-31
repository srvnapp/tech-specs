# Backend API / CRUD — phased work plan (frontend vs backend)

This document complements **[backend-api-crud-gap-analysis.md](./backend-api-crud-gap-analysis.md)**. It lists work by **phase**, with each item tagged as **Frontend** (Eden Expo app), **Backend** (`ressy_backend`), **Both** (requires coordinated changes), or **Product** (decision or design before build).

**Assumption:** OpenAPI (`eden/openapi.json`) matches deployed API unless noted. Most gaps are **client wiring**; backend routes already exist.

---

## Legend

| Tag          | Meaning                                                                                               |
| ------------ | ----------------------------------------------------------------------------------------------------- |
| **Frontend** | Eden: `src/services/*`, hooks, `app/**`, components, types aligned to OpenAPI.                        |
| **Backend**  | `ressy_backend`: new routes, schema changes, auth rules, migrations, bug fixes on server.             |
| **Both**     | Contract or behavior must change on server **and** client together (or discovery work on both sides). |
| **Product**  | UX copy, flows, or prioritization; may unblock FE/BE.                                                 |

---

## Phase A — Correctness and security

High priority: fixes wrong URLs/fields and unsafe or incomplete auth-related UI.

| #   | Work item                                 | Owner        | Details                                                                                                                                                                                             |
| --- | ----------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A.1 | Profile picture upload                    | **Frontend** | `POST /users/upload-profile-picture`, multipart key **`file`**, correct response typing (`ProfilePictureUploadResponse`). Files: `src/services/users.ts`, callers (e.g. profile photo picker).      |
| A.2 | Update password (Settings)                | **Frontend** | Add `updatePassword` → `PUT /auth/update-password`; hook + wire `UpdatePasswordContent` / `handleAccountSave`. Files: `auth.ts`, `useUser` or new hook, `SettingsSectionModal.tsx`, `settings.tsx`. |
| A.3 | Delete account (Settings)                 | **Frontend** | Replace `DELETE /users/{id}` with `POST /security/delete-account` `{ confirm: true, reason? }`; adjust `useDeleteAccount` and logout flow. Optional: small `security.ts` service module.            |
| A.4 | Hardening `DELETE /users/{id}` (optional) | **Backend**  | If the route must stay public to admins only: add role/ownership checks or remove from mobile-facing docs. **Not required** for Eden if mobile uses only `/security/delete-account`.                |

**Phase A summary:** **A.1–A.3** are **Frontend-only**. **A.4** is optional **Backend** hardening.

---

## Phase B — Data integrity and events

| #   | Work item                       | Owner                     | Details                                                                                                                                                                                                                                                 |
| --- | ------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B.1 | Review create with photos       | **Frontend**              | Extend `createSpotReview` multipart; pass `selectedUris` from `app/review/create.tsx`. If OpenAPI multipart field names for images are ambiguous, short **Both** spike: confirm against `ressy_backend` spot review handler.                            |
| B.2 | Edit event — remove guests      | **Frontend**              | `deleteEventInvite` (or equivalent) in `events.ts`; diff logic + save in `app/event/edit.tsx`. API already specified in OpenAPI.                                                                                                                        |
| B.3 | RSVP, vote, suggestions (UI)    | **Frontend**              | Use existing event service + `useRsvpEvent` / `useVoteOnEvent` (and suggestion endpoints) on list/detail screens. May need **Product** for exact UX (sheets, states).                                                                                   |
| B.4 | Event share (deep link / token) | **Frontend**              | `POST /events/{id}/share` then `Share.share` with API response.                                                                                                                                                                                         |
| B.5 | Event mute                      | **Both** _or_ **Backend** | Spec ties mute to **`PUT /chats/{chat_id}/mute`**. If event payloads lack `chat_id`, either expose it from **Backend** on event models or add event-level mute — **Product** decides. Until then, **Frontend** cannot correctly implement “mute event.” |

**Phase B summary:** **B.1–B.4** are **Frontend** (with possible **Both** verification on B.1). **B.5** is blocked or **Both** depending on `chat_id` / new API.

---

## Phase C — Notifications and security UX

| #   | Work item                                         | Owner                      | Details                                                                                                                                                                                       |
| --- | ------------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C.1 | Mark all read                                     | **Frontend**               | `useMarkAllRead` wrapping existing `notificationsService.markAllRead`; UI entry point on notification modal/screen.                                                                           |
| C.2 | Delete notification(s)                            | **Frontend**               | Implement clients for `DELETE /notifications/{id}` and `DELETE /notifications/delete-all` if not present; hooks + UI (swipe/actions). Verify paths in OpenAPI.                                |
| C.3 | Export my data                                    | **Frontend**               | Call `POST /security/download-data` from settings; handle success (“email sent”) and `400` when user has no email (per backend behavior).                                                     |
| C.4 | Notification preferences (push/SMS/email toggles) | **Backend** + **Frontend** | No matching OpenAPI today. **Backend**: design + implement prefs API; publish in OpenAPI. **Frontend**: persist toggles via new endpoints. **Product**: define matrix (which channels exist). |

**Phase C summary:** **C.1–C.3** are **Frontend**. **C.4** is **Backend** first, then **Frontend**.

---

## Phase D — Larger vertical slices

| #   | Work item                            | Owner                  | Details                                                                                                                                                                                                                                                                   |
| --- | ------------------------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D.1 | Chats module                         | **Frontend** (primary) | New `chats` service, hooks, navigation, screens per OpenAPI (`/chats/**`). **Backend** only if integration testing reveals spec/implementation gaps.                                                                                                                      |
| D.2 | Bill split                           | **Both** + **Product** | Endpoints exist in OpenAPI; **Product** defines host/guest flows. **Frontend** builds UX and service layer. **Backend** if new states, validation, or endpoints are required during build.                                                                                |
| D.3 | Edit spot review                     | **Frontend**           | `PUT /spots/{spot_id}/reviews/{review_id}` in `spots.ts`; entry from “my review” / spot detail. Prefer over deprecated socials PUT.                                                                                                                                       |
| D.4 | Share spot                           | **Frontend**           | `POST /spots/{spot_id}/share` + system share sheet.                                                                                                                                                                                                                       |
| D.5 | OAuth (Apple / Google)               | **Both** + **Product** | **Backend**: confirm `POST /users/link-oauth` (and unlink) contract, token shape, error codes. **Frontend**: native SDK / WebBrowser, then link call. **Product**: legal/branding, which providers ship. Alternative: **Frontend** hides buttons until contract is ready. |
| D.6 | Hide bill-split info modal           | **Frontend**           | `POST /users/me/hide-bill-split-info` when UI exists.                                                                                                                                                                                                                     |
| D.7 | Dedicated email / phone update flows | **Both** (optional)    | OpenAPI has `PUT /auth/update-email` and `PUT /auth/update-phone-number`. **Product**: whether these replace or complement `PUT /users/update-profile`. **Frontend**: dedicated screens/OTP if chosen. **Backend**: ensure OTP flows match app.                           |

**Phase D summary:** Mostly **Frontend** for D.1, D.3, D.4, D.6. **D.2**, **D.5**, **D.7** need **Product** and often **Both**.

---

## Cross-cutting / onboarding

| #   | Work item          | Owner                  | Details                                                                                                                                                                         |
| --- | ------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| X.1 | Forgot password    | **Product** + **Both** | No dedicated “reset password” in spec; login uses OTP. **Product** defines intended journey. **Backend**/**Frontend** implement agreed flow (e.g. OTP → set password endpoint). |
| X.2 | OAuth stub buttons | **Frontend**           | Until D.5: remove or disable “Continue with Apple/Google” no-ops to avoid false expectations.                                                                                   |

---

## Quick reference: who does what

| Phase | Mostly                                                     | Exceptions                                                                |
| ----- | ---------------------------------------------------------- | ------------------------------------------------------------------------- |
| **A** | Frontend                                                   | Optional Backend hardening on `DELETE /users/{id}`                        |
| **B** | Frontend                                                   | Event mute: Backend/Both/Product until `chat_id` or event-mute API exists |
| **C** | Frontend                                                   | Notification prefs: Backend first                                         |
| **D** | Frontend (chats, reviews, spot share, hide bill-split tip) | Bill split, OAuth, optional auth email/phone: Both + Product              |

---

## Related documents

- [backend-api-crud-gap-analysis.md](./backend-api-crud-gap-analysis.md) — full gap list, file references, open questions.
- OpenAPI: `eden/openapi.json`
- Backend: `projects/ressy-backend/ressy_backend`

---

_Created as a companion to the gap analysis; align phase numbering with §5 of that doc (A.1–A.3 ≈ Phase A items 1–3, etc.)._
