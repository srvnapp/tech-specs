# Dual Bundle ID — Implementation Checklist

**Goal:** Run `com.srvnapp.srvn.dev` (dev build) and `com.srvnapp.srvn` (production build) on the same device simultaneously without conflict.

See `docs/plans/dual-bundle-id-plan.md` for full context, rationale, and background on each step.

---

## Phase 1 — Code changes (no Google Console required)

- [x] **`eas.json`** — rename `APP_ENV` → `EXPO_PUBLIC_APP_ENV` in all three `env` blocks (`development`, `preview`, `production`)
  - Without this, `IS_DEV` is always `false` and the dev build silently gets the production bundle ID

- [x] **`app.json`** — remove the `@react-native-google-signin/google-signin` plugin entry
  - It will be re-declared in `app.config.ts`; leaving it in both causes duplicate plugin registration

- [x] **`app.config.ts`** — create at project root
  - Dynamically sets `name`, `scheme`, `ios.bundleIdentifier`, `android.package`, and the Google Sign-In plugin based on `EXPO_PUBLIC_APP_ENV`
  - Use `EXPO_PUBLIC_GOOGLE_IOS_URL_SCHEME_DEV` env var for the dev URL scheme (set to placeholder until Phase 3)

- [x] **`package.json`** — add `dev` script

  ```json
  "dev": "EXPO_PUBLIC_APP_ENV=development npx expo start"
  ```

  Use `npm run dev` instead of `npx expo start` when developing locally against a dev build

- [x] **`src/services/auth/google/loginWithGoogle.native.ts`** — update `ensureConfigured()`
  - Pick `EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID_DEV` when `EXPO_PUBLIC_APP_ENV === "development"`, otherwise use `EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID`

- [x] **`.env.example`** — document two new vars:
  ```bash
  EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID_DEV=<google-ios-client-id-for-com.srvnapp.srvn.dev>
  EXPO_PUBLIC_GOOGLE_IOS_URL_SCHEME_DEV=<reversed-ios-client-id-for-com.srvnapp.srvn.dev>
  ```

---

## Phase 2 — First dev EAS build (gets the Android keystore + SHA-1)

> These builds will have a placeholder Google URL scheme. Install only to get the SHA-1 — do not test Google Sign-In yet.

- [x] `eas build --profile development --platform ios`
  - EAS detects new bundle ID, generates new provisioning profile
- [x] `eas build --profile development --platform android`
  - EAS detects new package name, generates new keystore
- [x] `eas credentials -p android`
  - Copy the SHA-1 fingerprint for the new keystore (needed for Android OAuth client)

---

## Phase 3 — Google Cloud Console + secrets

- [x] Create iOS OAuth client for `com.srvnapp.srvn.dev`
  - APIs & Services → Credentials → Create OAuth 2.0 Client ID → iOS → bundle ID `com.srvnapp.srvn.dev`
  - Note the new client ID and reversed URL scheme (`com.googleusercontent.apps.<prefix>`)
- [x] Create Android OAuth client for `com.srvnapp.srvn.dev`
  - Application type = Android, package name = `com.srvnapp.srvn.dev`, SHA-1 from Phase 2
- [x] Add to `.env.development.local`
- [x] Add EAS env vars (Sensitive, development environment):
  ```bash
  eas env:create --scope project --name EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID_DEV
  eas env:create --scope project --name EXPO_PUBLIC_GOOGLE_IOS_URL_SCHEME_DEV
  ```

---

## Phase 4 — Verify

- [ ] `npm run dev` → Metro logs should show `EXPO_PUBLIC_APP_ENV=development`; home screen shows "SRVN (Dev)"
- [ ] Rebuild dev build with real credentials, install alongside production build — both launch without conflict
- [ ] Google Sign-In works on the dev build (uses dev credentials)
- [ ] Google Sign-In still works on the production build (uses production credentials)

---

## Deferred (post-launch)

- **Push notifications** — two bundle IDs = two push tokens per device. Backend needs to store tokens tagged by env and send to all tokens for a user. Coordinate with backend team when push notifications are fully in use.
- **Deep links** — both apps register `srvn://`. `app.config.ts` adds `srvn-dev://` to the dev build so deep links can be disambiguated during testing. No router code changes needed until actively testing deep links with both builds installed.
- **`preview` bundle ID** — preview builds get `com.srvnapp.srvn` (same as production). Accepted trade-off: preview is for QA, not for side-by-side installs. Add `com.srvnapp.srvn.preview` if needed later.

---

## Files changed (Phase 1 summary)

| File                                                 | Change                                            |
| ---------------------------------------------------- | ------------------------------------------------- |
| `eas.json`                                           | `APP_ENV` → `EXPO_PUBLIC_APP_ENV` in 3 profiles   |
| `app.json`                                           | Remove Google Sign-In plugin block                |
| `app.config.ts`                                      | Create — dynamic bundle ID, scheme, Google plugin |
| `package.json`                                       | Add `dev` script                                  |
| `src/services/auth/google/loginWithGoogle.native.ts` | Dev/prod iOS client ID switch                     |
| `.env.example`                                       | Document 2 new vars                               |
