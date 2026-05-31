# Apple Sign-In Plan

> **Prerequisite:** The [dual-bundle-id-plan](./dual-bundle-id-plan.md) must be fully implemented before starting this work. Both `com.srvnapp.srvn` and `com.srvnapp.srvn.dev` App IDs must exist in Apple Developer Console before you can enable Sign In with Apple on them.

---

## What changes and why

| Area                        | Impact                                                   | Notes                                                                                  |
| --------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Apple Developer Console     | Enable Sign In with Apple capability on both App IDs     | Required before any build will work                                                    |
| `expo-apple-authentication` | Install package + add plugin                             | Provides the native Sign In with Apple API and the required Apple-styled button        |
| `app.config.js`             | Add plugin config                                        | No per-variant logic needed — capability is tied to bundle ID, not config              |
| `loginWithApple.native.ts`  | Replace stub with real implementation                    | Posts identity token to `/oauth/apple/mobile`                                          |
| UI screen                   | Wire up the button                                       | Must use Apple's official button component — custom styling is an App Review violation |
| Backend                     | Verify Apple identity token, handle first-time user data | Apple only sends name/email on the very first authorization                            |
| Android                     | Hide the button                                          | Sign In with Apple is iOS-only; conditionally render with `Platform.OS === 'ios'`      |

---

## Step 1 — Apple Developer Console

Do this for **both** App IDs (dev first, then production).

1. Go to [developer.apple.com](https://developer.apple.com) → **Certificates, IDs & Profiles → Identifiers**
2. Select `com.srvnapp.srvn.dev` → scroll to **Sign In with Apple** → check **Enable** → Save
3. Repeat for `com.srvnapp.srvn`

> No Service ID needed. Service IDs are only for web/server-side flows. Mobile apps use the bundle ID directly.

EAS will automatically include the `com.apple.developer.applesignin` entitlement in provisioning profiles after this — no manual entitlements file needed in a managed Expo project.

---

## Step 2 — Install `expo-apple-authentication`

```bash
npx expo install expo-apple-authentication
```

---

## Step 3 — Add plugin to `app.config.js`

In `app.config.js`, add `expo-apple-authentication` to the plugins array:

```js
export default ({ config }) => ({
  ...config,
  // ... existing overrides
  plugins: [
    ...config.plugins,
    'expo-apple-authentication', // adds Sign In with Apple entitlement
  ],
});
```

> Adding it in `app.config.js` rather than `app.json` keeps the override in one place. No per-variant logic is needed — the entitlement applies to whichever bundle ID is active.

---

## Step 4 — Implement `loginWithApple.native.ts`

Replace the stub at `src/services/auth/apple/loginWithApple.native.ts`:

```ts
import * as AppleAuthentication from 'expo-apple-authentication';

import { api } from '../../api';
import type { OAuthSessionResponse } from '../types';

export async function loginWithApple(): Promise<OAuthSessionResponse | null> {
  let credential;

  try {
    credential = await AppleAuthentication.signInAsync({
      requestedScopes: [
        AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
        AppleAuthentication.AppleAuthenticationScope.EMAIL,
      ],
    });
  } catch (error: any) {
    // User dismissed the sheet — not an error, treat as cancellation
    if (error.code === 'ERR_REQUEST_CANCELED') {
      return null;
    }
    throw error;
  }

  const { identityToken, fullName, email } = credential;

  if (!identityToken) {
    throw new Error('Apple Sign-In failed: no identity token returned');
  }

  // IMPORTANT: Apple only sends fullName and email on the VERY FIRST authorization.
  // On all subsequent sign-ins, both will be null. The backend must persist
  // this data on first sign-in and not rely on receiving it again.
  const res = await api.post('/oauth/apple/mobile', {
    identity_token: identityToken,
    // Pass name/email when present (first-time only) so backend can store them
    ...(fullName?.givenName && { first_name: fullName.givenName }),
    ...(fullName?.familyName && { last_name: fullName.familyName }),
    ...(email && { email }),
  });

  return res.data as OAuthSessionResponse;
}
```

---

## Step 5 — UI: wire up the button

Apple's App Review guidelines **require** that Sign In with Apple uses the official `AppleAuthenticationButton` component. A custom-styled button will get rejected. The button must also only render on iOS — the API is unavailable on Android.

Find the screen with the "Continue with Apple" button and replace the placeholder handler:

```tsx
import * as AppleAuthentication from 'expo-apple-authentication';
import { Platform } from 'react-native';

import { loginWithApple } from '@/services/auth';

// Only render on iOS — Sign In with Apple doesn't exist on Android
{
  Platform.OS === 'ios' && (
    <AppleAuthentication.AppleAuthenticationButton
      buttonType={AppleAuthentication.AppleAuthenticationButtonType.SIGN_IN}
      buttonStyle={AppleAuthentication.AppleAuthenticationButtonStyle.BLACK}
      cornerRadius={8}
      style={{ width: '100%', height: 48 }}
      onPress={async () => {
        const session = await loginWithApple();
        if (session) {
          // handle session the same way Google Sign-In does
        }
      }}
    />
  );
}
```

> `buttonStyle` can be `BLACK`, `WHITE`, or `WHITE_OUTLINE` — pick whichever fits the screen background. The dark theme in this app means `WHITE` or `WHITE_OUTLINE` likely works best.

---

## Step 6 — Backend requirements

This is the most critical piece. Coordinate with whoever owns `/oauth/apple/mobile`.

### What the backend must do

1. **Verify the identity token** — it's a JWT signed by Apple. Fetch Apple's public keys from `https://appleid.apple.com/auth/keys` and verify the signature. Libraries exist for this in most server languages.

2. **Extract the `sub` field** — this is the stable Apple user ID. It never changes for a given user on your app. Use it as the unique identifier, not the email.

3. **Persist name and email on first sign-in only** — Apple sends `first_name`, `last_name`, and `email` exactly once (the first time the user authorizes your app). After that, those fields will not be sent. If the backend doesn't store them on first sign-in, they are lost permanently (the user would have to revoke and re-authorize to send them again).

4. **Handle email relay** — Apple may provide a real email or a private relay address (`@privaterelay.appleid.com`). The backend must handle both.

5. **Return the same `OAuthSessionResponse`** shape as `/oauth/google/mobile`:
   ```json
   { "access_token": "...", "refresh_token": "..." }
   ```

### Expected request shape

```json
POST /oauth/apple/mobile
{
  "identity_token": "<JWT from Apple>",
  "first_name": "Chris",      // only on first sign-in, may be absent
  "last_name": "Ejeh",        // only on first sign-in, may be absent
  "email": "user@example.com" // only on first sign-in, may be absent
}
```

---

## Step 7 — Android handling

Sign In with Apple does not exist on Android. The current `.web.ts` stub already throws for web. Ensure the UI button is not rendered on Android (covered by `Platform.OS === 'ios'` in Step 5).

No Android-specific code changes needed.

---

## What you do NOT need

- A Service ID — that's for web flows only
- A client secret — Apple's mobile flow uses the identity token directly, no server-to-server exchange needed from the app side
- Any additional env vars — no client IDs or secrets needed in the app

---

## Rollout order

1. [ ] Complete dual-bundle-id-plan fully (both App IDs registered in Apple Developer Console)
2. [ ] Enable Sign In with Apple capability on `com.srvnapp.srvn.dev` (Step 1)
3. [ ] Enable Sign In with Apple capability on `com.srvnapp.srvn` (Step 1)
4. [ ] `npx expo install expo-apple-authentication` (Step 2)
5. [ ] Add plugin to `app.config.js` (Step 3)
6. [ ] Implement `loginWithApple.native.ts` (Step 4)
7. [ ] Wire up the button in the UI screen (Step 5)
8. [ ] Backend implements `/oauth/apple/mobile` (Step 6) — can be parallelised with Steps 4–5
9. [ ] Build dev build (`eas build --profile development --platform ios`) and test end-to-end
10. [ ] Test second sign-in to confirm name/email absence is handled gracefully

---

## Gaps / open questions

1. **Backend endpoint name** — the stub comment says `/oauth/apple/mobile`. Confirm with backend that this is the correct path before wiring.

2. **First-time name handling in the app** — if the backend can't receive the name on first sign-in (e.g., the endpoint isn't ready yet), there's no recovery path. Make sure Steps 6 and 7 ship together.

3. **Revocation handling** — Apple can notify your backend when a user revokes access (via a server-to-server notification). Out of scope here but worth flagging to the backend team.

4. **App Review** — Apple's guidelines require that if you offer any third-party social login (Google is already in), you **must** offer Sign In with Apple. This plan satisfies that requirement. Don't ship a production build with Google Sign-In enabled but Apple Sign-In still throwing.
