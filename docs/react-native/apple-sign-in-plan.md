# Apple Sign-In Implementation and Rollout

Updated: October 23, 2026.

The app implementation is complete. Development Apple sign-in, code exchange, and refresh-token storage are verified: correcting `APPLE_KEY_ID` resolved the `invalid_client` exchange error, and the operator confirmed `apple_code_exchange_ok = true`. Complete email-relay delivery, account-deletion revocation, and the remaining development and production checks before rollout.

## Implemented

- [x] Install the Expo SDK 58 versions of `expo-apple-authentication` and `expo-crypto` and update the lockfile.
- [x] Set `ios.usesAppleSignIn: true` and register `expo-apple-authentication` in `srvn-app/app.config.ts` for both build variants.
- [x] Replace `loginWithApple.native.ts` with native authentication and `POST /oauth/apple/mobile`.
- [x] Generate a fresh cryptographic nonce per attempt, pass its SHA-256 hash to Apple, and send the raw nonce to the backend for comparison with the signed token.
- [x] Send Apple's authorization code so the backend can exchange it and retain a revocation token.
- [x] Forward first-consent name fields when supplied. Get email from the verified identity token on the backend, rather than trusting a client-supplied address.
- [x] Return `null` for user cancellation, propagate other failures, and reject incomplete credentials before contacting the backend.
- [x] Use the shared app button with the existing white Apple logo and approved "Continue with Apple" label on welcome and sign-up, shown only after an iOS availability check succeeds. Welcome uses the same dark background, 16-point semibold text, 56-point height, and spacing as the other login methods; sign-up inherits its neighboring social button styles. Authentication still uses Apple's native SDK.
- [x] Reuse `useAuthSuccess` to persist the session, load the profile, and route to onboarding or the app.
- [x] Block overlapping social sign-ins and phone submissions; restore controls after cancellation or failure.
- [x] Redact identity tokens, authorization codes, and nonces from development API logs.
- [x] Add automated coverage for the service contract, nonce handling, cancellation, missing credentials, platform availability, screen session handling, overlapping requests, and log redaction.
- [x] Backend authentication is already merged in [srvn-backend#232](https://github.com/srvnapp/srvn-backend/pull/232).
- [x] Backend code exchange and revocation are already merged in [srvn-backend#234](https://github.com/srvnapp/srvn-backend/pull/234).
- [x] Add backend diagnostics for code-exchange HTTP status and documented Apple error codes, with tests that prevent response bodies, credentials, and raw exceptions from appearing in these logs.

`SOCIAL_AUTH_HIDDEN` remains `false`; the Apple button now calls the implemented flow. Android and web do not show this native Apple entry point. Web Apple authentication is a separate integration.

## 1. Apple Developer configuration

Use the Apple Developer team that owns both bundle IDs and signs the EAS builds. An Account Holder or Admin can change capabilities.

### Enable both App IDs

In **Certificates, Identifiers & Profiles → Identifiers**, confirm these explicit App IDs exist:

| Build profile                  | Bundle ID              | Recommended Sign in with Apple configuration              |
| ------------------------------ | ---------------------- | --------------------------------------------------------- |
| `development`, `ios-simulator` | `com.srvnapp.srvn.dev` | Enable as its own primary App ID for isolated development |
| `preview`, `production`        | `com.srvnapp.srvn`     | Enable as its own primary App ID for production           |

For each identifier, select **Sign in with Apple**, choose **Configure**, select **Enable as a primary App ID**, and save the capability configuration and identifier. The app's dual bundle ID configuration already exists; see [the implementation checklist](./dual-bundle-id-implementation.md).

Separate primary IDs and keys are the recommended setup here because development and production use separate backend environments. If the identifiers are already intentionally grouped, review that existing grouping before changing it: grouped apps share Apple consent and identity behavior. Grouping does not make authorization codes interchangeable between client IDs.

Changing capabilities invalidates affected provisioning profiles. During the next EAS iOS build, authenticate with the correct Apple team and allow capability synchronization and provisioning profile regeneration. If EAS retains a stale profile, regenerate the profile for that bundle ID using `eas credentials --platform ios`, then rebuild.

References: [Apple capability configuration](https://developer.apple.com/help/account/identifiers/enable-app-capabilities), [Apple app grouping](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple/).

### Create the signing keys

For each independent primary App ID:

1. Open **Certificates, Identifiers & Profiles → Keys → +**.
2. Name the key, for example `SRVN Apple Sign In Dev` or `SRVN Apple Sign In Production`.
3. Enable **Sign in with Apple**, click **Configure**, select the corresponding primary App ID, and save.
4. Register the key and download the `.p8` file. Apple allows this download once; retain it securely.
5. Record the **Key ID** for that key and the **Team ID** from Apple Developer membership details.

The `.p8` contents, Key ID, and Team ID belong in the backend configuration described below. No Apple private key or generated client secret belongs in the app, an `EXPO_PUBLIC_*` variable, or source control.

An existing APNs key can also serve Sign in with Apple if that service is enabled on the key and configured for the correct primary App ID. Keep APNs enabled when editing the key. The backend must use that key's matching Key ID and original `.p8` contents; changing only the Key ID is insufficient. Editing a key does not allow its private key to be downloaded again. See [Apple's key editing and download instructions](https://developer.apple.com/help/account/keys/revoke-edit-and-download-keys/).

References: [Sign in with Apple keys](https://developer.apple.com/help/account/capabilities/create-a-sign-in-with-apple-private-key), [create and download a private key](https://developer.apple.com/help/account/keys/create-a-private-key/).

### Configure Hide My Email delivery

In **Certificates, Identifiers & Profiles → Services → Sign in with Apple for Email Communication → Configure**, register the outbound domains/subdomains and sender addresses used by the backend's `SENDGRID_FROM_EMAIL`. Complete the applicable SPF/DKIM configuration for the actual SendGrid sending domain and confirm delivery to an Apple private relay address.

This is needed for OTP and sensitive-action emails, including the account-deletion flow. Successful Apple sign-in alone does not prove those messages can reach a relay address.

Reference: [Apple private email relay setup](https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service/).

No Services ID, website return URL, or Apple JS setup is required for this native iOS flow. The backend uses the iOS bundle ID as its client ID.

## 2. Backend configuration

Set these variables in each backend environment's secret/environment configuration. Locally, use `srvn-backend/.env.development.local`; on Render, set them for the actual backend service. Redeploy or restart after changing them: `CONFIG` reads them at startup.

| Variable                  | Development backend                           | Production backend                                   |
| ------------------------- | --------------------------------------------- | ---------------------------------------------------- |
| `APPLE_CLIENT_ID`         | `com.srvnapp.srvn.dev`                        | `com.srvnapp.srvn`                                   |
| `APPLE_ALLOWED_AUDIENCES` | `com.srvnapp.srvn.dev`                        | `com.srvnapp.srvn`                                   |
| `APPLE_TEAM_ID`           | The owning Apple Developer Team ID            | The owning Apple Developer Team ID                   |
| `APPLE_KEY_ID`            | Key ID associated with the dev primary App ID | Key ID associated with the production primary App ID |
| `APPLE_PRIVATE_KEY`       | Full contents of the dev `.p8` file           | Full contents of the production `.p8` file           |

`APPLE_ALLOWED_AUDIENCES` is a comma-separated list, not JSON. Leaving it unset defaults to the single `APPLE_CLIENT_ID`; setting it explicitly as above makes the intended environment clear.

Store the entire private key, including `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----`. The backend accepts a multiline secret or a single-line value with literal `\n` escapes. Do not add surrounding quotation marks when pasting into a hosting dashboard's secret value field. There is no `APPLE_CLIENT_SECRET` setting: the backend generates and caches a short-lived ES256 client secret using the `.p8` key.

In a dotenv file, use an `APPLE_PRIVATE_KEY=` assignment with its value quoted; keep literal `\n` separators when using one physical line. Bare PEM lines outside an assignment are not valid environment settings. Use the actual private key contents, including both boundary lines. This backend reads `APPLE_KEY_ID` and `APPLE_PRIVATE_KEY`, not `APPLE_P8_KEY_ID` or `APPLE_P8`. Recreate the Docker backend container after changing environment values so it receives the updated settings.

Leave the normal endpoint defaults unchanged:

```text
APPLE_ISSUER=https://appleid.apple.com
APPLE_JWKS_URL=https://appleid.apple.com/auth/keys
APPLE_TOKEN_URL=https://appleid.apple.com/auth/token
APPLE_REVOKE_URL=https://appleid.apple.com/auth/revoke
```

**Current single-client limitation:** `APPLE_ALLOWED_AUDIENCES` controls token verification, but `mint_apple_client_secret`, `exchange_apple_code`, and `revoke_apple_token` all use the single configured `APPLE_CLIENT_ID`. Adding both bundle IDs to the allowed audience list lets both tokens pass verification; it does not make code exchange or revocation correct for both apps. Use separate dev/prod backend environments as above. A backend serving both IDs with full revocation support needs a separate change to select and persist the originating Apple client ID per provider link. Do not repeatedly switch a populated backend between client IDs; stored refresh tokens remain associated with the client that obtained them.

Development setup returned HTTP 400 with `invalid_client` until `APPLE_KEY_ID` matched the `.p8` used to sign the client secret. Correcting the Key ID resolved the error, and the operator confirmed `apple_code_exchange_ok = true`. The verified development Team ID is `758HB2G849`, with primary App ID `758HB2G849.com.srvnapp.srvn.dev`. Production configuration remains unverified.

For future troubleshooting, the backend logs the exchange HTTP status and a documented Apple error code without logging response bodies or credentials. Local signature verification and a synthetic-code probe cannot establish Apple's Key ID/private-key association; verify a real exchange and stored refresh token. Temporary troubleshooting scripts have been removed. Confirm that no backend environment or push-notification service uses an old key before revoking it.

### Database and outbound access

Apply the existing migrations in the intended backend environment with its normal release process (`flask db upgrade`). The schema must include migration `c4d8e2f1a6b9`, which adds `user_oauth_providers.provider_refresh_token`; no new migration is introduced by this app change. For the local Docker backend, the existing wrapper is `./sv upgrade` from `srvn-backend`.

The backend must be able to reach Apple's HTTPS keys, token, and revoke endpoints. Configure SendGrid and the registered relay sender for real delivery; disable `OTP_USE_MOCK_PROVIDER` for production and for relay-delivery validation.

The manual development deletion test on October 23 stopped at `/auth/step-up/send-otp`: SendGrid returned HTTP 401 with `Maximum credits exceeded`, and the backend returned HTTP 500 to the app. This attempt did not reach account deletion or Apple revocation. Restore the SendGrid Email API sending allowance before retrying the real email-code flow. The operator performs deletion in the app; validation work is limited to observing status/results.

The existing exchange/revocation implementation is best-effort: login can succeed even if the Apple key is missing or code exchange fails. Verify that an Apple provider refresh token is stored before calling the setup complete. Check only whether the column is populated; do not print or copy token values. An existing user without a stored token should sign in again with the new app after configuration is corrected.

`provider_refresh_token` is distinct from the SRVN session refresh token returned to the app. The current Google mobile route verifies Google's ID token and issues SRVN session tokens without obtaining or storing a Google refresh token, so a null value on Google provider links is expected. Apple links need the provider token for the implemented account-deletion revocation flow.

Returning directly to an existing SRVN account does not bypass the code exchange. Each Apple button press requests fresh native credentials, and the backend attempts exchange even when it resolves an existing provider link or matches a password account by verified email. A code-exchange error is separate from successful SRVN authentication. Use the diagnostic Apple error code when troubleshooting; [Apple's response-error guide](https://developer.apple.com/documentation/technotes/tn3107-resolving-sign-in-with-apple-response-errors) explains the possible causes.

### Sign-in and account-linking decision

Apple sign-in and automatic linking to an existing matching-email account require no additional SRVN OTP or password challenge. The backend validates Apple's identity token, resolves an existing Apple provider link first, and otherwise links an existing account using the email from that signed token. If neither match exists, it creates an account through the normal OAuth flow. Retain this current behavior; an extra account-linking verification screen is not part of this implementation.

Sensitive actions, including account deletion, use their existing verification flow. Email-relay delivery checks below cover those messages.

## 3. App/backend contract

```http
POST /oauth/apple/mobile
Content-Type: application/json
```

```json
{
  "identity_token": "<Apple identityToken>",
  "authorization_code": "<Apple authorizationCode from this attempt>",
  "nonce": "<raw nonce generated by the app>",
  "first_name": "Chris",
  "last_name": "Ejeh"
}
```

Name fields are omitted when Apple does not supply them. The app sends the SHA-256 digest of this raw nonce to Apple's SDK. The backend verifies Apple's signature, issuer, expiry, audience, and matching nonce before resolving the user by Apple's subject. Email comes from the signed token; a relay address works like any other verified provider address. Returning users are resolved by subject even when email and name are absent.

Both signup and login return the same app session shape:

```json
{
  "access_token": "<SRVN access token>",
  "refresh_token": "<SRVN refresh token>"
}
```

Apple's authorization code is single-use. Avoid manual replay or logging of request credentials. If a sign-in fails, a fresh button press starts a new authorization with a new nonce and code.

## 4. Build and validate

Verify the development app points at the development backend using `EXPO_PUBLIC_SRVN_DEV_BACKEND_API_URL`, and preview/production use `EXPO_PUBLIC_SRVN_BACKEND_API_URL`. No additional Apple environment variables are needed in the app.

From `srvn-app`, after portal and backend configuration:

```bash
npm run dev:build:ios
```

Install the new build on a physical iPhone, then use `npm run dev` for Metro. The existing binary cannot acquire the new native module or entitlement through a JavaScript update alone. Use a standalone development build for backend validation; Expo Go can return different Apple client identifiers.

- [ ] First authorization with Share My Email creates one SRVN account, persists the supplied name, and routes through the shared onboarding flow.
- [ ] Log out and sign in again: the same account is returned and the stored name is retained even without a new name payload.
- [ ] Repeat with Hide My Email and verify both login and actual OTP delivery to the relay address.
- [ ] Cancel the Apple sheet: no alert or session is created, and all other auth methods become available again.
- [ ] Confirm repeated taps do not launch overlapping Apple/Google/phone requests.
- [ ] Simulate backend failure: show the existing auth error, restore controls, and allow a fresh authorization attempt.
- [x] Verify the provider refresh token was stored after code exchange without exposing its value. Confirmed in development with `apple_code_exchange_ok = true` after correcting the Key ID.
- [ ] Delete the account through the app: OTP arrives, deletion succeeds, and Apple revocation is attempted successfully. Existing backend deletion remains best-effort if Apple is unavailable.
- [ ] Confirm Apple is absent on Android/web and unsupported iOS devices; phone/email/Google retain their existing behavior.
- [ ] Build and repeat the critical signup/login/deletion checks against production configuration using a release/preview build with `com.srvnapp.srvn`.

Only after those checks, build the production release:

```bash
npm run prod:build:ios
```

## Known backend follow-ups

The backend still rejects a previously unseen Apple subject with no email claim (`400`); nullable-email account creation is outside this app change. Apple's first-consent display name is forwarded immediately, but a failed first request before backend persistence can require the user to enter their name through profile/onboarding instead.

The existing backend has no Apple server-to-server notification webhook for later consent revocation or account changes. This plan does not claim that webhook is implemented. The code exchange and account-deletion revocation paths described above are already present.

## Verification record

Initial implementation validation: **3,388 tests passed across 186 suites**, including 132 focused authentication/API logging checks. After matching Apple button styling to the shared login controls, **121 tests passed** across the Apple service, button availability/disabled behavior, and welcome/sign-up screens; typecheck and targeted lint/formatting checks also passed. `npm run validate` passed (typecheck, lint with 12 existing warnings, and formatting). Expo config introspection confirmed the `com.apple.developer.applesignin` entitlement and mixed-localization setting for both bundle IDs. Physical-device and deployed-environment checks above remain open until performed with real Apple credentials.

Development login has been exercised successfully, including reuse of an existing password account. Correcting the Key ID resolved the exchange failure, and the operator confirmed **`apple_code_exchange_ok = true`**, verifying that a real Apple code exchange returned a refresh token and the backend stored it. Email-relay delivery, account-deletion revocation, and production validation remain open. The backend retains safe error-code logging and automated coverage for HTTP/network failures and credential redaction. Temporary diagnostic scripts, their tests, and the audience-comparison log have been removed. After cleanup, **62 retained Apple service and mobile API tests passed**, along with targeted Ruff and diff checks.

PR preparation validation on October 23: **3,407 app tests passed across 186 suites** on current `origin/main` with only the Apple sign-in changes applied. App typechecking, lint (12 existing warnings), and formatting passed. **62 backend Apple service/mobile API tests passed** on current `origin/main`, along with targeted Ruff and diff checks. Unrelated local app changes and its existing cleanup commit are excluded from the PR branches.

Reference: [Expo SDK 58 AppleAuthentication](https://docs.expo.dev/versions/v58.0.0/sdk/apple-authentication/).
