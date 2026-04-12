# Google OAuth (mobile) — React Native / Expo client flow

This document describes how the **Expo (srvn) mobile app** performs Google sign-in and exchanges Google’s **ID token** for **application** access and refresh tokens. Server-side verification, audiences, and user provisioning are documented in the backend spec in this same repo.

**Backend reference:** [GOOGLE_MOBILE_AUTH_FLOW.md](../backend/GOOGLE_MOBILE_AUTH_FLOW.md)

## How it differs from web OAuth

- **Web** typically uses redirects and an **authorization code** (often with PKCE), then the server exchanges the code with Google.
- **Native (iOS/Android)** uses `@react-native-google-signin/google-signin`, which runs the platform Google Sign-In UI and returns a **Google ID token** (JWT). The app sends that JWT to our backend; the server verifies it with Google and issues **our** JWT pair.

Do not send Google `client_secret` from the mobile app.

## End-to-end flow

```text
App (native)              Backend                      Google
    |                        |                            |
    |-- GoogleSignin UI ---->|                            |
    |<-- ID token (JWT) -----|                            |
    |                        |                            |
    |-- POST /oauth/google/mobile ----------------------->|
    |    { id_token }        |-- verify JWT + aud ------->|
    |                        |<-- JWKS / validation ------|
    |                        |-- create/find user         |
    |                        |-- issue access + refresh   |
    |<-- app tokens ---------|                            |
```

After a successful response, the client service layer persists tokens (`setTokens`); sign-in screens also update the auth store (`setAuthTokens`) and navigate home.

## Reference implementation (srvn-app)

Paths refer to the **srvn** Expo repository (not this `tech-specs` repo).

| Piece | Location |
|--------|----------|
| Native Google Sign-In + `POST /oauth/google/mobile` | `src/services/auth/google/loginWithGoogle.native.ts` |
| Web stub (no native module; throws until web OAuth exists) | `src/services/auth/google/loginWithGoogle.web.ts` |
| Public export | `src/services/auth/index.ts` → `loginWithGoogle` |
| Expo config plugin (iOS URL scheme, etc.) | `app.json` → `@react-native-google-signin/google-signin` |

Metro resolves `./google/loginWithGoogle` to `.native` or `.web` using **`moduleSuffixes`** in `tsconfig.json`, so the web bundle does not load the Google native module.

## Environment variables (client)

These are supplied at build time via Expo public env (see the app’s `.env.example`):

- `EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID` — `GoogleSignin.configure({ webClientId })` (needed for ID token on Android; must align with backend audience rules).
- `EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID` — `GoogleSignin.configure({ iosClientId })` on iOS.

The backend must accept the ID token’s `aud` values; see **GOOGLE_ALLOWED_AUDIENCES** in [GOOGLE_MOBILE_AUTH_FLOW.md](../backend/GOOGLE_MOBILE_AUTH_FLOW.md).

## API contract (client → backend)

```http
POST /oauth/google/mobile
Content-Type: application/json

{ "id_token": "<google-jwt>" }
```

The client expects JSON including at least `access_token` and `refresh_token` (typed as `OAuthSessionResponse` in the app). The backend may also return `message` and `user`.

## Session handling

1. **`loginWithGoogle`** (native) calls `setTokens` in `src/services/tokens.ts` after success.
2. **Auth screens** call `setAuthTokens` on the auth store and `router.replace('/(tabs)')`.

Same pattern as email/password login: service persists tokens; UI updates store.

## User cancellation and errors

- User cancels the Google UI → `signIn()` resolves to a non-success response → implementation throws **`Google Sign-In was cancelled`**.
- Missing `id_token` after success → **`Google Sign-In failed: no ID token returned`** (misconfiguration or edge case).

Product UX should surface these (alert, toast, inline error) in addition to logging.

## Apple Sign-In and web (planned)

- **`loginWithApple`** — platform files under `src/services/auth/apple/`; stubs until Sign in with Apple + backend route exist.
- **Web Google** — `loginWithGoogle.web.ts` throws until a browser OAuth path (e.g. `expo-auth-session`) and backend contract are implemented.

## Related reading

- [GOOGLE_MOBILE_AUTH_FLOW.md](../backend/GOOGLE_MOBILE_AUTH_FLOW.md) — backend verification and configuration
- Repo root: `YELP_RAG.md` and other product/engineering notes
