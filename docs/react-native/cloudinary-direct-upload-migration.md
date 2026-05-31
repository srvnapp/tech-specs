# Cloudinary Direct-Upload Migration

**Status:** Draft — gaps flagged at the bottom, awaiting clarification.
**Backend tracking PR:** srvnapp/srvn-backend#138
**Spec:** https://github.com/srvnapp/tech-specs/blob/main/docs/backend/cloudinary-uploads.md

## What's changing

The backend deleted its multipart upload routes. The mobile client now uploads
directly to Cloudinary using a short-lived signature, then submits pure JSON to
our API. The three affected surfaces:

1. **Dish photos** — review media now lives on dishes (not the review). One
   image or video per dish, max 10 dishes per review.
2. **Avatar** — both signup (onboarding) and edit-profile go through the new
   signed flow. `POST /users/upload-profile-picture` is 404 now.
3. **Comments** — media support fully removed, body required.

---

## Phase 1 — Upload foundation (shared)

### 1.1 New service `src/services/uploads.ts`

- `signCloudinaryUpload(req)` → `POST /uploads/cloudinary/sign`
  Accepts `{ upload_type, context? }`, returns the signed envelope.
- `destroyCloudinaryAsset(public_id, resource_type)` →
  `DELETE /uploads/cloudinary/:public_id?resource_type=...` for pre-submit cancel.
- `uploadToCloudinary(file, signed)` — POSTs to
  `https://api.cloudinary.com/v1_1/{cloud_name}/{resource_type}/upload` with
  `api_key`, `timestamp`, `signature`, `file`, and **every** key from
  `params_to_sign` verbatim. Parses `{ secure_url, public_id, resource_type, eager }`.
- `uploadLargeToCloudinary(file, signed)` — chunked path for videos over a
  threshold (default 20 MB). Uses `X-Unique-Upload-Id` + `Content-Range`
  per Cloudinary's resumable protocol. Chunk size 6 MB (their recommended min).
- `toMediaDescriptor(cloudinaryResponse)` — shapes the API-contract object:
  `{ url, public_id, type, thumbnail_url? }`. For `resource_type: video`, pulls
  `thumbnail_url` from `eager[0].secure_url`.

### 1.2 New types in `src/types/api.ts`

```ts
export type UploadType = 'dish_image' | 'dish_video' | 'avatar';

export interface SignUploadRequest {
  upload_type: UploadType;
  context?: { spot_id?: number; draft_id?: string };
}

export interface SignedUpload {
  cloud_name: string;
  api_key: string;
  timestamp: number;
  signature: string;
  resource_type: 'image' | 'video';
  params_to_sign: Record<string, string | number | boolean>;
  max_file_size: number;
  allowed_formats: string[];
}

export interface MediaDescriptor {
  url: string;
  public_id: string;
  type: 'image' | 'video';
  thumbnail_url?: string;
}
```

Rename existing `ReviewMedia` usage to `MediaDescriptor` across the codebase
(it's the same shape) to signal the new per-dish ownership.

### 1.3 New hook `src/hooks/useCloudinaryUpload.ts`

- Returns `{ upload, progress, cancel }`.
- Wraps sign → validate (size/format from `max_file_size`, `allowed_formats`)
  → upload → return descriptor.
- Caches the signature per `(upload_type, draft_id)` for 55 min to stay under
  the 20/hour rate limit.
- Surfaces 429 with the `Retry-After` value as a user-facing toast.
- Routes large videos through `uploadLargeToCloudinary`.
- Reports per-file progress via `XMLHttpRequest.upload.onprogress` so the
  UI can render progress bars.

### 1.4 Draft-session helper

Small React context / hook `useDraftSession(key)` that yields a stable UUID v4
for the lifetime of the composer screen. Used by the dish-photo flow (step 1
of the backend spec). Discarded when the composer unmounts after submit.

---

## Phase 2 — Avatar flow (onboarding + edit)

### 2.1 Replace `uploadProfilePicture` in `src/services/users.ts`

- Delete the legacy multipart function (lines 48–60).
- Add `updateProfilePicture(descriptor: MediaDescriptor)` →
  `PATCH /users/me/profile-picture` with JSON body `{ url, public_id, thumbnail_url }`.

### 2.2 Update `src/hooks/useUser.ts`

- Replace `useUploadProfilePicture` with:
  - `useUploadAvatar()` — wraps `useCloudinaryUpload` with `upload_type: 'avatar'`.
  - `useUpdateProfilePicture()` — PATCH mutation; invalidates `userKeys.myProfile()`.
- Onboarding: upload → hold descriptor in local state → include in `sign-up` body.
- Edit profile: upload → PATCH on save tap. Append `?v=<timestamp>` to the
  displayed URL immediately after to bust the CDN cache.

### 2.3 UI touches

- `app/(onboarding)/profile-photo.tsx` — replace `uploadPicture.mutateAsync(uri)`
  with the new flow. Upload on pick; disable Continue while uploading.
- `src/components/profile/ProfilePhotoPicker.tsx` — no behavior change other
  than returning a `MediaDescriptor` instead of a raw URI.
- Edit-profile modal (wherever the avatar is swapped from `/app/(tabs)/profile/`)
  — upload on pick, PATCH on save. If the user cancels without saving, we still
  have a live overwritten asset (avatar uses a deterministic `public_id`), so
  the old image is already gone. **Open question below.**

---

## Phase 3 — Review composer (dish photos)

### 3.1 Composer state model

Shift from a flat `selectedUris: string[]` to:

```ts
type DishDraft = {
  id: string; // client-side only
  name: string;
  price: number | null;
  media: MediaDescriptor | null; // set after upload completes
  uploading: boolean;
  localPreviewUri?: string; // pre-upload preview
};

type ReviewDraft = {
  draftId: string;
  dishes: DishDraft[]; // max 10
};
```

### 3.2 Composer UI

- Reshape both composers (`app/(tabs)/index/restaurant/addReview.tsx`,
  `app/review/create.tsx`) around a dish list.
- Each dish row: name, price, one photo/video slot. Replacing the existing
  media picks a new asset; the old one is deleted via `destroyCloudinaryAsset`
  on confirm.
- Swipe-to-remove a dish triggers `destroyCloudinaryAsset` (pre-submit cancel
  per the spec).
- `AddPhotoBox` stays, but is now per-dish and single-slot. Consider renaming
  to `DishMediaSlot`. Gallery/camera picker can continue to use `pickImage.ts`,
  extended to support video (`mediaTypes: All`).
- Cap at 10 dish entries; disable "Add dish" beyond that.
- On unmount without submit (back button, tab switch), fire
  `destroyCloudinaryAsset` for every uploaded descriptor. Fire-and-forget —
  if the app is killed the backend's nightly cleanup catches it.

### 3.3 Service + hook updates

- `src/services/spots.ts`:
  - `createSpotReview` → JSON body `{ rating, description, is_anonymous,
tag_user_ids, draft_id, dishes }`. Drop `FormData` and `Content-Type` header.
  - Add `updateSpotReview(spotId, reviewId, payload)` →
    `PUT /spots/{spotId}/reviews/{reviewId}` if the edit surface is in scope
    (see gaps).
- `src/hooks/useSpots.ts`:
  - `useCreateSpotReview` — stop defaulting `media` / `has_media` (lines 421–422).
  - Optimistic cache update needs a new shape since `review.media` is gone.
- `src/services/spots.ts` `ReviewList`/`Review` consumers — strip `media` and
  `has_media` reads everywhere.

### 3.4 Rendering changes

`review.media` → no longer exists. Feed cards need a source of thumbnails:

- `SocialFeedItem.tsx`: derive a media array from `review.dishes[].media`
  (filter nulls). Pass to `MediaCard`.
- `ReviewList.tsx` (`ReviewCard`): same — `getMediaUri` reads
  `item.dishes.map(d => d.media).filter(Boolean)`.
- `app/review/[id]/index.tsx` (detail): render dishes as first-class cards
  with name + price + media, not a flat media row.
- `app/review/[id]/media.tsx` (carousel): feed from dish media list.
- `SharedReviewSchema` consumers: drop `has_media`.

### 3.5 Type changes in `src/types/api.ts`

- Remove `media` and `has_media` from `ReviewList` and `Review`.
- Replace `ReviewMedia` with `MediaDescriptor` (alias during migration).
- Add `ReviewDish` type:
  ```ts
  export interface ReviewDish {
    id: number;
    name: string;
    price: number | null;
    media: MediaDescriptor | null;
  }
  ```
  and add `dishes: ReviewDish[]` to `ReviewList` / `Review`.
- Create-review payload type:
  ```ts
  export interface CreateReviewPayload {
    rating: number;
    description: string;
    is_anonymous?: boolean;
    tag_user_ids?: number[];
    draft_id: string;
    dishes: Array<{
      name: string;
      price?: number;
      media?: MediaDescriptor;
    }>;
  }
  ```

---

## Phase 4 — Comments cleanup

- `src/types/api.ts`: remove `media` from `CommentCreate`, `CommentUpdate`,
  and `ReviewComment` (lines 134–167). Body is now required.
- `src/services/socials.ts`: no signature change (already sends JSON), but
  update types and ensure empty-body submission is blocked client-side.
- `CommentsModal.tsx` and `ReviewCommentsThread.tsx`: drop any media-rendering
  path (audit confirmed it's typed-only today but verify before removal).
- `app/review/[id]/index.tsx`: already passes only `{ reviewId, body,
parentCommentId }` — just tighten types.

---

## Phase 5 — Tests

### 5.1 New

- `tests/unit/services/uploads.test.ts` — sign, upload, destroy, descriptor
  shaping.
- `tests/unit/hooks/useCloudinaryUpload.test.ts` — signature caching,
  rate-limit toast, progress reporting.
- `tests/integration/composer/dishPhotoFlow.test.tsx` — happy path: pick →
  sign mock → Cloudinary mock → submit. Assert JSON body matches the contract.
- `tests/integration/composer/cancelCleanup.test.tsx` — pre-submit cancel
  fires `DELETE /uploads/cloudinary/<id>` for every uploaded descriptor.

### 5.2 Update

- `tests/unit/screens/onboarding/profile-photo.test.tsx` — new flow.
- `tests/unit/components/profile/ProfilePhotoPicker.test.tsx` — descriptor return.
- `tests/unit/screens/restaurant/addReview.test.tsx` — dish-list composer.
- `tests/unit/components/socials/SocialFeedItem.test.tsx` — media from dishes.
- `tests/unit/services/socials.test.ts` — comment schema without media.
- `tests/unit/test-utils/factories.ts` — review factory emits `dishes`, not
  `media`/`has_media`.

### 5.3 Delete

- Any assertion specific to `review.media` / `review.has_media` shape
  (the fields are gone).

---

## Phase 6 — Rollout

1. Land types + service layer (`uploads.ts`, new types, `updateProfilePicture`).
2. Land `useCloudinaryUpload` + tests.
3. Migrate avatar (onboarding + edit). Ship behind no flag — backend has
   already removed the old route, so this is ship-or-break.
4. Migrate composer. Biggest diff; strongly consider splitting the UI refactor
   (dish-centric layout) from the wiring (service swap) into two PRs stacked
   against the same base.
5. Remove comment `media` everywhere + ship.
6. Strip dead types (`ReviewMedia` alias, `has_media`, etc.) once all
   consumers are updated.

---

## Confirmed from backend (srvn-backend `feat/cloudinary-signed-uploads`, tech-specs `cloudinary-uploads.md`)

1. **`ReviewListSchema` and `ReviewSchema` both include `dishes`.**
   Each dish on read contains `{ id, dish: { id, name, normalized_name, aliases },
price, media | null }`. `media` is a **single object, not an array**. Feed
   cards derive thumbnails from `review.dishes[*].media` (filter nulls).
   The create/update schemas accept `name` (load_only), `price`, and `media`.
   So the read/write shape is asymmetric: **FE sends `{ name, price, media }`,
   reads back `{ id, dish: {...}, price, media }`**.

2. **Edit-review exists on the backend.** `PUT /spots/<id>/reviews/<id>` with
   `ReviewUpdateRequestSchema`. Any dish photo not in the new `dishes[]` is
   destroyed from Cloudinary after DB commit. FE can wire it whenever — the
   backend is ready.

3. **Dish-less reviews are valid.** `dishes: fields.List(..., load_default=list)`.
   A review with zero dishes submits fine. Product consequence stands:
   **media requires a dish**; there is no "general review photo" slot.

4. **Avatar uses deterministic `public_id` (`avatar_<user_id>`) with
   `overwrite=true, invalidate=true`.** No backend-side draft/promote pattern.
   Pick-replaces-old is the contract.

5. **Signature shape confirmed.** Covers `timestamp + folder + tags + context +
eager (+ eager_async + public_id + overwrite + invalidate)`. File bytes and
   `resource_type` are **not** signed. A single signature is reusable for
   many files within its 1-hour TTL. `params_to_sign` is the literal dict the
   client must echo verbatim (alongside `api_key`, `timestamp`, `signature`,
   and the file).

6. **Rate limit: 20 signs/user/hour** (configurable), 429 with `Retry-After` header.

7. **Comments have no `media` field.** `CommentCreateSchema.body` is required
   (min length 1). Frontend must strip `media` from all comment payloads and
   types.

8. **Onboarding orphan concern is moot.** In the current FE flow, `/auth/register`
   runs before the profile-photo step, so a JWT (and real user id) exists by
   the time the avatar is uploaded. Avatars are attached to a real user row;
   they aren't orphans. Cleanup job remains dish-only by design.

9. **Signup inline `profile_picture` path exists.** `/auth/register` reads
   `user_data.profile_picture` at `routes/auth.py:642`. **But the current FE
   onboarding already uploads the avatar after register**, so the FE can
   ignore the inline path and use `PATCH /users/me/profile-picture` uniformly.
   Simplifies things.

10. **Avatar preset needs no context.** Sign request body for avatar is just
    `{ "upload_type": "avatar" }`. All dish uploads require `{ spot_id,
draft_id }`.

## Decisions locked in

1. **Dish-only media — accepted.** Dish entry is how users attach photos.
   The tabs composer (`app/(tabs)/index/restaurant/addReview.tsx`) already
   has dish name + price inputs (lines 63–64), just limited to a single
   dish and dropped on submit. Work is to extend to a list + wire the
   submission. The simpler composer (`app/review/create.tsx`) gains the
   same dish-list model.

2. **Avatar cancel — upload on save.** Pick updates the preview locally;
   the actual Cloudinary upload + `PATCH /users/me/profile-picture` fires
   when the user confirms. Revert is free because nothing reaches the
   server until save.

3. **Video — image only for v1.** No `dish_video` support in this PR.
   `pickImage.ts` stays image-only. `uploadLargeToCloudinary` and
   `expo-video-thumbnails` deferred to a follow-up. Removes chunked upload
   from Phase 1.

4. **Client-side resize — yes, via `expo-image-manipulator`.** Max 1920 px
   on the long edge, JPEG quality 0.8. Runs before the Cloudinary upload
   for every dish image + avatar.

5. **Edit-review — deferred.** Backend endpoint is ready but the UI is
   net-new scope. This PR covers create + avatar + legacy-field cleanup.
   Follow-up ticket for the edit surface.
