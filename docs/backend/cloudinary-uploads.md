# Cloudinary uploads

This doc covers the signed-upload flow that mobile/web clients use for dish
photos and avatars, the plumbing that supports it, and the moderation options
we deferred but should know about before we need them.

---

## Why direct upload

Routing multi-MB files through the API server costs bandwidth twice (client →
us → Cloudinary), holds worker memory while the file streams, and risks
timeouts on cellular. Direct-to-Cloudinary uploads keep our request path
lean. The client gets a short-lived signature from us, posts the file
straight to Cloudinary, then sends back the resulting URL/`public_id` for us
to persist.

The Cloudinary API secret never leaves the server.

---

## End-to-end flow

```
┌────────┐  1. POST /uploads/cloudinary/sign            ┌────────────┐
│ Client │ ──── upload_type, context (dish/avatar) ───▶ │  Backend   │
│        │                                              │  + Redis   │
│        │ ◀── { signature, params_to_sign, ... } ──── │  rate-limit│
└────────┘                                              └────────────┘
     │ 2. POST direct to Cloudinary
     │    api.cloudinary.com/v1_1/<cloud>/<resource_type>/upload
     │    fields: api_key, timestamp, signature, file, *params_to_sign
     ▼
┌────────────┐
│ Cloudinary │ ──── { public_id, secure_url, eager: [...] } ──▶ Client
└────────────┘
                                                           │
   3. POST /spots/<id>/reviews   { dishes:[{media:{url, public_id, type}}],
                                    draft_id }
   3'. PATCH /users/me/profile-picture { url, public_id, thumbnail_url }
                                                           │
                                                           ▼
                                                       ┌────────┐
                                                       │ Backend│
                                                       └────────┘
```

The pre-create cancel path (`DELETE /uploads/cloudinary/<public_id>`) exists
for composer "swipe to delete" — it verifies ownership via the asset's signed
`context.uploaded_by` and destroys the asset on Cloudinary.

The daily orphan-cleanup task (`cleanup_orphan_dish_uploads`, 03:00 UTC)
sweeps any `type:dish` asset older than 24h whose `draft_id` doesn't appear
on a live Review row. That's the long-tail safety net for clients that
upload then drop off without submitting.

---

## Endpoints

| Method | Path                                  | Purpose                                                           |
|-------:|---------------------------------------|-------------------------------------------------------------------|
| POST   | `/uploads/cloudinary/sign`            | Issue a signed upload payload for a registered preset             |
| DELETE | `/uploads/cloudinary/<public_id>`     | Owner-only delete (composer cancel)                               |
| POST   | `/spots/<id>/reviews`                 | Create a review with optional pre-uploaded dish media + draft_id  |
| PUT    | `/spots/<id>/reviews/<id>`            | Update review; dish-media diff drops removed assets from Cloudinary |
| PATCH  | `/users/me/profile-picture`           | Persist a Cloudinary-hosted avatar (URL/public_id only)           |

All require `@jwt_required`. The sign endpoint is rate-limited per user (see
config below).

The legacy `POST /users/upload-profile-picture` (multipart server-side
upload) was deleted alongside this work. The legacy `review_N_file` /
`dish_N_file` multipart parts on review create/update were dropped — both
endpoints now accept JSON only.

---

## Preset registry

`ressy_backend/services/cloudinary_signing.py` owns the registry. Adding a
new upload type = adding a registry entry. Routes never branch on
`upload_type` beyond looking it up.

| upload_type   | resource_type | folder template                                       | max size | formats                    | required context        |
|---------------|---------------|-------------------------------------------------------|----------|----------------------------|--------------------------|
| `dish_image`  | image         | `srvn/{env}/dishes/{spot_id}/{user_id}/{draft_id}`    | 15 MB    | jpg, jpeg, png, heic, webp | `spot_id`, `draft_id`   |
| `dish_video`  | video         | `srvn/{env}/dishes/{spot_id}/{user_id}/{draft_id}`    | 100 MB   | mp4, mov                   | `spot_id`, `draft_id`   |
| `avatar`      | image         | `srvn/{env}/users/{user_id}/avatar`                   | 5 MB     | jpg, jpeg, png, heic, webp | (none)                  |

`env` resolves to `prod` when `SRVN_CONFIG=production`, else `dev`. Avatar
uses a deterministic `public_id` (`avatar_<user_id>`) plus
`overwrite=true, invalidate=true`, so a new avatar replaces the old in place
— no cleanup needed.

Tags include `type:{dish|avatar}`, `user:<id>`, and (for dish) `draft:<uuid>`
+ `spot:<id>`. The cleanup job filters on `type:dish` + `draft:*`.

---

## Chunked / resumable uploads (video)

Cloudinary's chunked upload protocol uses the *same* signed params we
already issue. For videos large enough to risk a network blip on cellular,
the mobile SDK should call its chunked-upload helper (e.g.
`UploadLargeRequest` in iOS, the equivalent on Android) with the params from
`/uploads/cloudinary/sign` instead of the simple single-shot upload. No
backend change is needed.

---

## Configuration

All Cloudinary env vars live in `ressy_backend/config.py`:

| Env var                                | Default | Purpose                                                          |
|----------------------------------------|---------|------------------------------------------------------------------|
| `CLOUDINARY_CLOUD_NAME`                | (req)   | Cloudinary account                                               |
| `CLOUDINARY_API_KEY`                   | (req)   | Public key (sent to client)                                      |
| `CLOUDINARY_API_SECRET`                | (req)   | Signing secret — server only                                     |
| `CLOUDINARY_SIGN_RATE_LIMIT`           | `20`    | Sign requests per user per window                                |
| `CLOUDINARY_SIGN_RATE_WINDOW_SECONDS`  | `3600`  | Window length for the rate limit                                 |
| `START_SCHEDULER`                      | `false` | Must be `true` in the worker that should run cleanup_orphan_dish_uploads |

A single signature can be reused for multiple files within its 1-hour TTL,
so 20/hr is generous in practice — clients usually only sign once per draft.

---

## Plan and caps

We're on Cloudinary's free tier today (25 GB storage, 25 GB bandwidth/month).
That fits early users comfortably. Don't size the rate limit to the plan —
size it to actual user behavior, then revisit:

- After 30 days of real data, check signing volume and Cloudinary usage.
- If costs climb, the cheapest knob is *per-file* (lower preset
  `max_file_size` for video) before you raise the plan tier.
- A leaked JWT can drain quota at most
  `CLOUDINARY_SIGN_RATE_LIMIT × hours × max_file_size` per user — the
  client-side cap is the floor on abuse, the rate limit is the ceiling.
- Set spend alerts in the Cloudinary dashboard so the bill is the *backstop*,
  not the surprise.

---

## Moderation: what we have, what we don't

Today nothing inspects user-uploaded photos. Direct-to-Cloudinary makes that
explicit — bytes never touch our backend, so moderation has to live somewhere
else. Three options for when this becomes a product requirement:

### 1. Cloudinary built-in add-ons

Configured per upload preset; runs server-side at Cloudinary. Two flavors:

- **Blocking**: `moderation: aws_rek` (or `google_video_moderation`,
  `webpurify`, `metascan`). Uploads that exceed the threshold are rejected
  before Cloudinary stores them. Cleanest UX — bad content never lands.
- **Flagging**: same providers, async. Upload succeeds with
  `moderation: "pending"` on the asset; we get notified later (see #2).

Available add-ons:
- AWS Rekognition (images): nudity, violence, weapons, drugs.
- Google Video Moderation (videos): same categories.
- WebPurify (images): nudity-focused, cheaper, fast.
- MetaDefender (images): malware scan if we ever care.

These are paid Cloudinary add-ons — pricing scales per moderation call.

### 2. Async webhook

Cloudinary calls our backend with the moderation result via a notification
URL. We add a `moderation_status` column on `ReviewDish.media` (or wherever
the asset lives) and the API hides un-approved items until cleared.

Setup:
- Configure the notification URL in the Cloudinary dashboard.
- Build a `POST /webhooks/cloudinary/moderation` route that verifies the
  signature, finds the asset by `public_id`, updates the moderation status.
- Roughly an hour of plumbing once we own the column.

### 3. Client-side hint

Useless against bad actors, fine as a UX nudge. The mobile SDK can offer a
basic NSFW pre-screen, but anything that determines what *we* show needs to
run server-side.

### Architectural note

With the previous server-side-upload flow, we *could* have run moderation
synchronously in the request handler before storing anything. With direct
upload, that synchronous chokepoint is gone — we either delegate to
Cloudinary or moderate after-the-fact via webhook. If "moderate after the
first report" is acceptable forever, no further action; if pre-publish
moderation is on the roadmap, plan for the webhook path because it composes
with the current architecture.

---

## Tests

- `tests/srvn_backend/services/test_cloudinary_signing.py` — preset registry
  + signing helper unit tests (signature determinism, context validation,
  preset-derived params).
- `tests/srvn_backend/utils/test_rate_limit.py` — Redis-backed
  per-user rate limiter (under/over limit, TTL expiry, missing JWT).
- `tests/srvn_backend/api/test_uploads_cloudinary_sign.py` — integration
  tests for both `POST /uploads/cloudinary/sign` and
  `DELETE /uploads/cloudinary/<public_id>`, with mocked Cloudinary lookup.
- `tests/srvn_backend/api/test_spot_reviews_dish_media_diff.py` — pins the
  PUT review dish-media diff: swap deletes old asset, clear deletes asset,
  unchanged is a no-op, non-author returns 403.
- `tests/srvn_backend/api/test_users_profile_picture_patch.py` — avatar PATCH
  endpoint + a regression that signup still accepts inline `profile_picture`.
- `tests/srvn_backend/api/test_cleanup_orphan_dish_uploads.py` — orphan
  cleanup job behavior with mocked Cloudinary list/delete and real Review
  rows in the test DB.
