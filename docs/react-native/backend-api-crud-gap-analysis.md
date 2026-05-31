# Backend API / CRUD integration gap analysis

**See also:** [backend-api-crud-phased-work-plan.md](./backend-api-crud-phased-work-plan.md) — phases with **Frontend / Backend / Both** ownership.

This document maps **OpenAPI 3.0.3** (`openapi.json` at repo root) mutating endpoints and in-app actions to the current Expo app implementation. Focus: **POST, PUT, PATCH, DELETE** (plus a few **wrong URL / no-op Save** cases). Generated from static review of `src/services/*`, hooks, and `app/**` screens (no runtime tests).

---

## Executive summary

- **Critical bug (path + field):** profile photo upload calls **`POST /users/profile-picture`** with form key **`profile_picture`**. OpenAPI and **`ressy_backend`** expect **`POST /users/upload-profile-picture`** with multipart key **`file`** (see route docstring in `ressy_backend/routes/user.py`). The in-code JSDoc in `users.ts` claiming `profile_picture` is incorrect for the real endpoint.
- **Dead mutations:** `useVoteOnEvent` and `useRsvpEvent` are exported but **never used**; event voting and RSVP are not surfaced in UI despite service functions existing.
- **False completion:** Settings **“Update Your Password”** Save does **not** call **`PUT /auth/update-password`** (`handleAccountSave` in `SettingsSectionModal` only persists `personal-info`; `settings.tsx` `onSavePress` closes the sheet with password still TODO).
- **Data loss risk:** Review flows let users pick **photos**, but **`createSpotReview`** always sends `media: []` in the JSON payload—selected images are never uploaded.
- **Edit event / guests:** Save adds **new** invites only; **`DELETE /events/{event_id}/invites/{invitee_user_id}`** is never called when a user removes someone from the guest list.
- **No client module for chats:** Entire **`/chats/**`\*\* surface is absent (create chat, messages, reactions, mute, read, leave, delete message).
- **Large event subdomains missing:** suggestions, voting UX wiring, bill split lifecycle, share token for events, reminders—mostly unimplemented in services and UI.
- **Account deletion (backend-verified):** The app uses **`DELETE /users/{user_id}`**. In **`ressy_backend`**, that route is documented as **auth without ownership checks, intended for dev/admin**. **`POST /security/delete-account`** uses the JWT identity, requires **`{ confirm, reason? }`**, and runs `SecurityController.delete_user_account`—this is the **intended mobile path**. Migrate the app to the security endpoint; do not rely on `DELETE /users/{id}` for end-user account deletion unless product explicitly overrides.

---

## Backend verification notes (`projects/ressy-backend/ressy_backend`)

Cross-check performed against the Flask app (April 2026):

| Topic                        | Finding                                                                                                                             |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Profile upload               | `POST /users/upload-profile-picture` — multipart key **`file`**; invalid path `/users/profile-picture` is not the documented route. |
| Delete user                  | `DELETE /users/<user_id>` in `routes/user.py`: docstring warns **no role/ownership checks**, dev/admin intent.                      |
| Delete account (user-facing) | `POST /security/delete-account` in `routes/security.py` with `DeletionRequestSchema` (`confirm` required, optional `reason`).       |
| Export data                  | `POST /security/download-data` sends PDF to the user’s email; requires account email.                                               |

---

## 1. Incorrect or risky wiring (fix first)

| Area             | Current behavior                                                       | OpenAPI + backend                                                                                  | Action                                                                                                                                                                 |
| ---------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Profile picture  | `users.ts` → `POST /users/profile-picture`, form key `profile_picture` | `POST /users/upload-profile-picture`, form key **`file`**; response `ProfilePictureUploadResponse` | Change URL; append image as **`file`**; align TypeScript return type with OpenAPI (may not be full `UserProfileResponse`—update callers/cache invalidation as needed). |
| Account deletion | `deleteAccount(userId)` → `DELETE /users/{user_id}`                    | Prefer **`POST /security/delete-account`** `{ confirm: true, reason?: string }`; identity from JWT | Replace mobile flow: call security endpoint, drop URL `userId` for deletion, keep logout + local clear.                                                                |

---

## 2. UI / actions with no backend call (spec has an endpoint)

### 2.1 Auth & onboarding

| UI                                           | Issue                                     | Spec endpoint(s)                                                                                                                                                                        |
| -------------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Sign up** — “Continue with Apple / Google” | `onPress={() => {}}`                      | `POST /users/link-oauth` (and flow likely needs WebBrowser / native SDK + token exchange—confirm backend contract).                                                                     |
| **Forgot password**                          | Comment says no reset; uses **login OTP** | No dedicated “reset password” in spec; **`PUT /auth/update-password`** exists for authenticated users. Product may need a dedicated reset flow or documented OTP→set-password sequence. |

### 2.2 Settings

| UI                                            | Issue                                                                                          | Spec endpoint(s)                                                                                            |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **Update Your Password** (modal Save)         | Only validation UI; **no `updatePassword` service**; `handleAccountSave` skips password branch | `PUT /auth/update-password` (`UserUpdatePassword`: `current_password?`, `new_password`, `confirm_password`) |
| **Export Data**                               | `Alert` “Coming soon”                                                                          | `POST /security/download-data` (no body in spec)                                                            |
| **Notification toggles** (push/SMS/email/all) | Local `useState` only                                                                          | _No matching OpenAPI_ for prefs—either backend gap or different service; do not fake persistence.           |
| **Clear My Cache**                            | Local toggle only                                                                              | _Not in OpenAPI_—acceptable as purely client-side if documented.                                            |

### 2.3 Events

| UI / flow                                        | Issue                                                              | Spec endpoint(s)                                                                                                                                               |
| ------------------------------------------------ | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Events list** — “Vote Now” / “Suggest a place” | Same as tap: **`router.push` to detail** only; **no vote/suggest** | `POST /events/{event_id}/vote`, `POST /events/{event_id}/suggestions`                                                                                          |
| **Event detail**                                 | No RSVP (Accept/Decline), no voting UI, no suggest spot            | `POST /events/{event_id}/rsvp`, vote, suggestions                                                                                                              |
| **Share event** (header + sheet + footer)        | **`Share.share` plain text** only                                  | `POST /events/{event_id}/share` (share token / deep link)                                                                                                      |
| **Mute event** toggle                            | **`eventMuted` React state** only                                  | Spec has **`PUT /chats/{chat_id}/mute`** (chat-scoped). If event notifications use a `chat_id` on event payload, wire mute to that; otherwise confirm backend. |
| **Edit event** — remove guest                    | **Not synced**: only **add** invites                               | `DELETE /events/{event_id}/invites/{invitee_user_id}`                                                                                                          |
| **Bill split**                                   | `bill_split_status` on models only                                 | `POST .../bill-split`, `PUT .../allocation`, `POST .../confirm`, `PATCH .../payment-status`, `POST .../remind`, `POST .../remind-pending`, `POST .../reset`    |
| **Host reminders**                               | N/A                                                                | `POST /events/{event_id}/remind-pending`                                                                                                                       |

### 2.4 Reviews & spots

| UI                                        | Issue                                  | Spec endpoint(s)                                                                                                                      |
| ----------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **`app/review/create.tsx`** Done          | Ignores `selectedUris` / params photos | Multipart review create should attach media per **`POST /spots/{spot_id}/reviews`** (extend `createSpotReview` like social patterns). |
| **Edit / update review**                  | No `PUT` in `spots.ts`                 | `PUT /spots/{spot_id}/reviews/{review_id}`                                                                                            |
| **Spot deep link share**                  | No API                                 | `POST /spots/{spot_id}/share`                                                                                                         |
| **Restaurant row** — call / website icons | `disabled` (no request)                | _No POST in spec for those_—OK unless product adds endpoints.                                                                         |

### 2.5 Social feed

| UI                 | Issue                                          | Spec endpoint(s)                                                      |
| ------------------ | ---------------------------------------------- | --------------------------------------------------------------------- |
| **Follow** on feed | When already following, control **disabled**   | `DELETE /socials/reviews/{review_id}/follow` to unfollow from context |
| **Share review**   | Calls **`POST .../share`** then local URL—good | —                                                                     |

### 2.6 Notifications

| UI                     | Issue                                      | Spec endpoint(s)                                                                                |
| ---------------------- | ------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| **Notification modal** | No “mark all read”, no swipe delete        | `PUT /notifications/read-all`, `DELETE /notifications/{id}`, `DELETE /notifications/delete-all` |
| **Service**            | `markAllRead` exists in `notifications.ts` | Expose hook + UI (e.g. header action).                                                          |

### 2.7 Users (misc)

| UI                                                     | Issue                                                  | Spec endpoint(s)                                                                                           |
| ------------------------------------------------------ | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| **Bill split info modal** (if shown after API adds it) | —                                                      | `POST /users/me/hide-bill-split-info`                                                                      |
| **Saved list unsave**                                  | Uses **`DELETE /spots/{id}/save`** via `useUnsaveSpot` | Spec also has **`DELETE /users/saved-spots/{spot_id}`**—either is valid; keep one pattern for consistency. |

---

## 3. Endpoints with no app implementation (feature gaps)

These appear in **OpenAPI** but have **no** `src/services/*` client and **no** meaningful UI hook-up:

- **All of `/chats/**`\*\* (create/get chat, send message multipart, reactions, read, mute, leave, delete message).
- **Event:** `POST .../suggestions`, `DELETE .../suggestions/{candidate_id}`, `POST .../share`, bill-split family, `POST .../remind-pending`.
- **Spots:** `PUT .../reviews/{review_id}`, `POST .../share`.
- **Socials:** `PUT /socials/reviews/{review_id}` marked **DEPRECATED**—prefer spots PUT for edit.
- **Security:** `POST /security/download-data`, **`POST /security/delete-account`** (preferred for app account deletion—see §1).
- **Users:** `POST /users/link-oauth`, `POST /users/unlink-oauth`, `POST /users/me/hide-bill-split-info`.
- **Auth:** `PUT /auth/update-email`, `PUT /auth/update-phone-number` (if profile email/phone edits should go through dedicated OTP flows vs `PUT /users/update-profile`—spec text says profile email change triggers OTP; verify single source of truth).

---

## 4. Implemented and aligned (representative)

Worth keeping as reference—**already call backend** in line with spec paths:

- **Auth:** signup/login phone & email, verify OTP, retry code, register, login email-password, logout; refresh via `api` interceptor.
- **Events:** list, details, create, update, delete, vote/rsvp **service + hooks** (hooks unused in screens—see §2.3), invites **POST**.
- **Users:** get profile, update profile, follow/unfollow, followers/following, remove follower, search, share profile, saved spots list.
- **Spots:** get/list/search/nearby/recommended, reviews list, create review (text path), save/unsave spot.
- **Socials:** feed, like/unlike review, save/unsave spot via review, comments CRUD, comment like, follow/unfollow author, share review, shared review by token fetch.
- **Notifications:** list, unread count, **single** mark read.

---

## 5. Suggested implementation order

Work is grouped by **phase** (A = correctness/security, then features). Within a phase, order is still roughly top-to-bottom by impact.

### Phase A — Correctness and security

1. **Profile upload:** `uploadProfilePicture` in `src/services/users.ts` — use **`POST /users/upload-profile-picture`**, multipart field **`file`** (React Native `FormData` blob `{ uri, name, type }`). Fix JSDoc. Retest on device; adjust response typing vs `ProfilePictureUploadResponse`.
2. **`PUT /auth/update-password`:** add `updatePassword` in `src/services/auth.ts` + mutation hook; wire **`UpdatePasswordContent`** values into **`handleAccountSave`** when `subView === 'update-password'` (or lift submit into the password component like `PersonalInfoContent`).
3. **Account deletion:** switch **`useDeleteAccount`** / service to **`POST /security/delete-account`** with `{ confirm: true }`; stop using **`DELETE /users/{user_id}`** for settings “delete account” unless product mandates the admin-style route.

### Phase B — Data integrity and events

4. **Review photos:** extend **`createSpotReview`** to attach files; pass **`selectedUris`** from **`app/review/create.tsx`**; mirror multipart patterns from social review create where applicable; confirm media field names in OpenAPI.
5. **Edit event guests:** diff initial vs current invitee IDs; keep **`POST .../invites`** for additions; call **`DELETE /events/{event_id}/invites/{invitee_user_id}`** for removals (`app/event/edit.tsx`, `events.ts`).
6. **Event detail + list:** surface RSVP + vote (+ suggestions when allowed) via existing **`events`** service and **`useRsvpEvent` / `useVoteOnEvent`**.
7. **Event share:** **`POST /events/{id}/share`**, then **`Share.share`** with returned URL/token.

### Phase C — Notifications and security UX

8. **Notifications:** add **`useMarkAllRead`** (wrap existing `markAllRead`); add delete one / delete-all clients if missing; header or list actions in notification UI.
9. **Export data:** **`POST /security/download-data`** from settings; user messaging should reflect email delivery (and “no email on account” error from backend).

### Phase D — Larger vertical slices

10. **Chats module** — `src/services/chats.ts` + hooks + screens (product priority).
11. **Bill split** — after UX spec (host vs guest).
12. **`updateSpotReview` + UI** — `PUT /spots/{spot_id}/reviews/{review_id}`.
13. **Spot share** — `POST /spots/{spot_id}/share`.
14. **OAuth** — implement **`POST /users/link-oauth`** (and unlink) or hide buttons until contract is fixed.
15. **Optional:** `POST /users/me/hide-bill-split-info`; dedicated **`PUT /auth/update-email`** / **`update-phone-number`** if settings should not rely solely on **`PUT /users/update-profile`**.

---

## 6. Open questions for product / backend

- **Account deletion:** resolved for implementation — use **`POST /security/delete-account`** (see §1 and backend verification). Revisit only if product requires retaining **`DELETE /users/{id}`** for a specific scenario.
- Do **events** expose a **`chat_id`** for **`PUT /chats/{chat_id}/mute`**, or is event mute a different future endpoint?
- **Notification preferences** (push/SMS/email): is there an API not yet in `openapi.json`?
- **Forgot password:** intended flow (OTP + which screen sets password using which endpoint)?

---

## 7. Files touched most often during implementation (reference)

| Concern             | Primary files                                                                                                                                                                                |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| API clients         | `src/services/events.ts`, `users.ts`, `spots.ts`, `socials.ts`, `notifications.ts`, `auth.ts` (add `updatePassword`; account delete may move to a `security.ts` client or live in `auth.ts`) |
| React Query         | `src/hooks/useEvents.ts`, `useUser.ts`, `useSpots.ts`, `useSocials.ts`, `useNotifications.ts`                                                                                                |
| Event UX            | `app/(tabs)/events/index.tsx`, `app/(tabs)/events/[id].tsx`, `app/event/edit.tsx`, `app/event/create.tsx`                                                                                    |
| Settings / password | `src/components/profile/SettingsSectionModal.tsx`, `UpdatePasswordContent.tsx`, `app/(tabs)/profile/settings.tsx`                                                                            |
| Reviews             | `app/review/create.tsx`, `src/services/spots.ts`, `app/(tabs)/index/restaurant/addReview.tsx`                                                                                                |

---

_Last reviewed: Eden codebase + cross-check against `ressy_backend` (`routes/user.py`, `routes/security.py`), April 2026._
