# Eden — Principal Frontend Architecture Review & Roadmap

**Reviewer perspective:** Principal Frontend Engineer, evaluating production readiness.

**Scope:** Expo / React Native client (`eden`), evaluated against production React Native architecture patterns (Expo Router, layered data access, offline-aware server state, native integrations, performance, release hygiene).

**Stack snapshot:** Expo SDK ~54, React 19, RN 0.81, New Architecture enabled, Expo Router v6, NativeWind v4, TanStack Query v5 (persisted + NetInfo `offlineFirst`), Zustand, Axios with refresh-queue, FlashList in several surfaces, Reanimated, gesture-handler, keyboard-controller, expo-image, dev client + EAS.

---

## 1. What is already strong

### 1.1 Layered data architecture

- **Services** (`src/services/*.ts`) are thin async wrappers over HTTP; **hooks** (`src/hooks/*.ts`) own React Query usage. This matches the documented convention in `docs/guidelines/CODEBASE.md` and scales well.
- **Query key factories** (e.g. `spotKeys` in `useSpots.ts`) support predictable invalidation and cache structure.
- **Axios interceptors** (`src/services/api.ts`) implement serialized 401 refresh with a queue — a solid production pattern for mobile tokens.

### 1.2 Offline-aware server cache

- `QueryProvider` wires `onlineManager` to NetInfo and uses `networkMode: 'offlineFirst'` with AsyncStorage persistence. This aligns with the React Native architecture skill's offline-first Query pattern.

### 1.3 Navigation ergonomics

- **Guarded router** (`src/hooks/useRouter.ts`) reduces double-tap navigation races — thoughtful UX detail.
- **Guarded callback** (`src/hooks/useGuardedCallback.ts`) generalizes the debounce pattern for any handler.
- **Route groups** `(auth)`, `(onboarding)`, `(tabs)` keep concerns separated at the file-system level.

### 1.4 Native / platform foundations

- Root layout composes **GestureHandlerRootView**, **KeyboardProvider**, **React Navigation ThemeProvider** with Eden colors — appropriate shell for modals, sheets, and headers.
- Push registration is **defensive** (`src/notifications/push.ts`) to avoid crashes when modules or simulators lack support.
- `src/services/haptics.ts` and `src/services/biometrics.ts` are clean, platform-gated native utilities.

### 1.5 Logging and error messaging

- `src/utils/logger.ts` has a `logError` with separate DEV / production paths (structured, no PII leak). `getAuthErrorMessage` maps Axios errors to user-facing copy with network-aware fallbacks. A good foundation to build on.

### 1.6 Form validation

- React Hook Form + Zod throughout auth screens. Validation schemas are colocated with the screens that use them. `mode: 'onTouched'` provides good UX.

---

## 2. Gaps and risks (prioritized)

### P0 — Correctness / data-loss / release blockers

| #     | Item                                      | Observation                                                                                                                                                                                                                                                                                                                                                                                                               | Impact                                                                                                    | Action                                                                                                                                                            |
| ----- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | **Registration flow drops personal info** | `personal-info.tsx` stores `firstName` / `lastName` in `useOnboardingStore` (memory-only Zustand). `create-password.tsx` calls `registerUser({ email, password, username })` **without reading the store**. The OpenAPI `User1` schema accepts `first_name`, `last_name`, `dietaries`, `cuisines`, `country_code`, `city_code`, `date_of_birth`, `phone_number`, `opt_in_marketing` — but the client sends none of these. | User data collected during onboarding is silently lost. Backend receives only email/password/username.    | **Wire onboarding store into `registerUser()`.** Read `firstName`, `lastName` from `useOnboardingStore` in `create-password.tsx` and include them in the payload. |
| 2     | **Missing route targets**                 | `sign-up.tsx` links to `/(auth)/terms` and `/(auth)/privacy-policy`. **Neither route file exists**. Tapping them crashes or shows +not-found.                                                                                                                                                                                                                                                                             | Broken UX on sign-up screen.                                                                              | Create route files (WebView or external link redirect).                                                                                                           |
| ~~3~~ | ~~**Social OAuth buttons are no-ops**~~   | "Continue with Apple" and "Continue with Google" have empty handlers.                                                                                                                                                                                                                                                                                                                                                     | Low — OAuth implementation coming soon.                                                                   | Leave as-is.                                                                                                                                                      |
| 4     | **Auth vs route protection**              | `app/index.tsx` redirects by `authStore.status` only. No `useSegments`-style guard in root layout; deep links to `/(tabs)` while unauthenticated are reachable.                                                                                                                                                                                                                                                           | Unauthenticated users can reach protected screens via deep links, push notifications, or universal links. | Add explicit **auth gate** in root layout.                                                                                                                        |
| 5     | **`API_BASE_URL` can be `undefined`**     | `src/services/config.ts` exports `process.env.EXPO_PUBLIC_SRVN_BACKEND_API_URL` with no fallback. `axios.create({ baseURL: undefined })` sends requests to relative paths.                                                                                                                                                                                                                                                | Every API call fails silently.                                                                            | Fail fast at startup; add `.env.example` for documentation.                                                                                                       |
| 6     | **EAS production profile missing**        | `eas.json` has `development`, `ios-simulator`, `preview` only.                                                                                                                                                                                                                                                                                                                                                            | Cannot ship to stores without manual config.                                                              | Add `production` profile with `autoIncrement` + `submit` section.                                                                                                 |

### P1 — Architecture / state management

| #   | Item                                                    | Observation                                                                                                                                                                                                | Impact                                                                                                | Action                                                                                                                                                                                                                                   |
| --- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7   | **Zustand stores duplicating React Query server state** | `socialStore` has `feed: ReviewList[]`, `isLoading`, `error`. `feedStore.spots` is synced from React Query via `useEffect`. `userStore.followStatusByUserId` mirrors `is_following` from server responses. | Two sources of truth → stale reads, missed invalidations.                                             | Eliminate parallel state. Social feed → React Query only. Spot lookup → `queryClient.getQueryData`. Follow state → optimistic updates on Query cache. Keep Zustand for **client-only** state (UI flags, location source, selected city). |
| 8   | **Profile loaded imperatively outside React Query**     | `app/index.tsx` calls `getMyProfile().then(setMe)` bypassing the `useMyProfile` hook. `(tabs)/profile/index.tsx` also syncs `profileData` → `setMe`.                                                       | Root fetch doesn't populate Query cache. Profile tab re-fetches.                                      | Use `queryClient.prefetchQuery` at root so data enters cache once.                                                                                                                                                                       |
| 9   | **React Query usage outside hooks**                     | `useQueryClient` in `CommentsModal.tsx` and `review/[id]/index.tsx` for direct cache invalidation.                                                                                                         | Violates project convention.                                                                          | Extract into hooks (e.g. `useInvalidateReviewComments`).                                                                                                                                                                                 |
| 10  | **Stale time constants unused**                         | `staleTimes.ts` exists but most hooks use inline `1000 * 60 * 5`.                                                                                                                                          | Scattered magic numbers.                                                                              | Adopt `STALE_TIME_*` constants in all hooks.                                                                                                                                                                                             |
| 11  | **Onboarding Zustand state not persisted**              | `useOnboardingStore` (`accountType`, `firstName`, `lastName`) is memory-only. Process death mid-signup loses everything.                                                                                   | User kills app mid-registration → must restart.                                                       | Persist to AsyncStorage.                                                                                                                                                                                                                 |
| 12  | **Orphaned `permissions` route**                        | `app/(onboarding)/permissions.tsx` exists but nothing navigates to it.                                                                                                                                     | Dead screen. First-time GPS prompt is missing from the flow.                                          | **Wire into post-auth flow** (per owner: force GPS permission for first-time users).                                                                                                                                                     |
| 13  | **`accountType` screen removed**                        | The OpenAPI `User1` and `UserUpdate` schemas have no `account_type` field. Screen collected data with no backend destination.                                                                              | ~~Wasted UI step.~~ **Resolved** — screen deleted, store field removed, navigation updated.           | **Done.** `account-type.tsx` deleted. `personal-info.tsx` and `create-password.tsx` now navigate to `/(auth)/account-created`. `useOnboardingStore` cleaned up.                                                                          |
| 14  | **Registration under-utilizes API fields**              | `User1` accepts `dietaries`, `cuisines`, `country_code`, `city_code`, `date_of_birth`, `opt_in_marketing` — none collected during onboarding.                                                              | Missed opportunity to personalize feed from day one. Backend has the capacity; client doesn't use it. | Consider adding onboarding steps for dietary/cuisine preferences and city. Low priority unless feed personalization is imminent.                                                                                                         |

### P2 — Performance & UX polish

| #   | Item                          | Observation                                                                                                                                                               | Impact                                                                    | Action                                                                                                  |
| --- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 15  | **FlatList vs FlashList**     | 7+ screens use `FlatList`: leaderboard, restaurant search, review media, `LabeledInput` picker, `NotificationListContent`, `RestaurantDetailsContent`, `ListPickerModal`. | Guideline says "always FlashList." Leaderboard and search are long lists. | Migrate long/dynamic lists to FlashList. Keep FlatList only for fixed-size paging carousels.            |
| 16  | **Feed empty when no coords** | `getEffectiveCoords` returns `null` → all feed queries `enabled: false` → permanent empty state.                                                                          | First-run users see "No restaurants found nearby" with no way out.        | Wire `permissions.tsx` into post-auth flow to force GPS permission. Fall back to city picker if denied. |
| 17  | **3-second minimum splash**   | `SPLASH_MIN_DURATION_MS = 3000` for all users.                                                                                                                            | Returning users wait unnecessarily.                                       | Gate on first launch only (AsyncStorage flag).                                                          |
| 18  | **Tailwind spacing scale**    | 50+ tokens (`2xs` through `50xl`), some negative. `30xl = 44px` is unguessable.                                                                                           | Hard to maintain.                                                         | Add semantic aliases or a reference comment.                                                            |

### P3 — Resilience, observability, & quality

| #   | Item                              | Observation                                                            | Impact                               | Action                                                                                                               |
| --- | --------------------------------- | ---------------------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| 19  | **No error boundaries**           | Zero `ErrorBoundary` usage. One render error white-screens the app.    | Production crashes with no recovery. | Add root + per-tab boundaries with retry CTA.                                                                        |
| 20  | **No production error reporting** | `logError` only calls `console.error` in prod. No Sentry/Crashlytics.  | Crashes invisible to team.           | Integrate crash reporting when service is chosen (coming soon per owner). Wire into `logError` and error boundaries. |
| 21  | **No automated tests**            | No test framework.                                                     | Regressions caught only manually.    | Start with unit tests for critical paths.                                                                            |
| 22  | **Logout double token clear**     | Both `auth.ts logout()` and `authStore.logout()` call `clearTokens()`. | Harmless but confusing.              | Let `authStore.logout()` own all cleanup.                                                                            |
| 23  | **Documentation drift**           | `CODEBASE.md` mentions **expo-sqlite**; not in `package.json`.         | Misleads contributors.               | Update `CODEBASE.md`.                                                                                                |

### Minor / hygiene

- **`isExpoGo` in root layout** — computed but unused. Remove or gate push registration.
- **Leaderboard** imports mock data — confirm production API wiring.
- **`deriveUsername`** from email prefix may collide. Consider server-side uniqueness or UUID suffix.
- **`tsconfig.json`** has no path aliases — lots of `../../../src/` imports. Add `@/` alias.

---

## 3. Alignment with "React Native architecture" skill checklist

| Pattern                                             | Eden status                                                   | Gap severity |
| --------------------------------------------------- | ------------------------------------------------------------- | ------------ |
| Expo Router file structure                          | Strong — `app/` routes + `src/` for logic                     | None         |
| Auth provider + segment guard                       | Partial — token bootstrap exists; segment-based guard missing | P0           |
| React Query offlineFirst + persist                  | Fully implemented                                             | None         |
| Single source of truth (Query vs Zustand)           | Violated — 3 Zustand stores duplicate server state            | P1           |
| Native modules (haptics, biometrics, notifications) | Present under `src/services/` / `notifications/`              | None         |
| FlashList for long lists                            | Partial — 7+ screens still use FlatList                       | P2           |
| Reanimated                                          | Used (splash, animated lists)                                 | None         |
| Error boundaries                                    | Missing entirely                                              | P3           |
| EAS profiles                                        | Dev/preview only; production TBD                              | P0           |
| Production observability                            | No remote error reporting                                     | P3           |
| Tablet adaptation                                   | Not implemented; required per owner                           | P2           |

---

## 4. Detailed implementation roadmap

### Phase A — Critical correctness fixes (1–3 days)

These are bugs that lose user data or crash the app.

| Task                                                                                           | Files affected                                                    | Effort |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | ------ |
| **A1.** Wire `firstName`, `lastName` from onboarding store into `registerUser()` payload       | `app/(auth)/create-password.tsx`, `src/stores/onboardingStore.ts` | 1h     |
| **A2.** Create `/(auth)/terms.tsx` and `/(auth)/privacy-policy.tsx` (WebView or external link) | `app/(auth)/`                                                     | 1–2h   |
| ~~**A3.**~~ ~~Hide social OAuth buttons~~ — **Skipped.** Left as-is; OAuth coming soon.        | —                                                                 | —      |
| **A4.** Add auth route guard in root layout — redirect unauthenticated deep links              | `app/_layout.tsx` or new `AuthGate` component                     | 2–4h   |
| **A5.** Add runtime env validation for `API_BASE_URL`                                          | `src/services/config.ts`                                          | 30min  |
| **A6.** Add `production` + `submit` profiles to `eas.json`                                     | `eas.json`                                                        | 30min  |

### Phase B — Onboarding & first-run location (3–5 days)

| Task                                                                                                                        | Files affected                                                                   | Effort |
| --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------ |
| **B1.** Wire `permissions.tsx` into post-auth flow: after first sign-in, navigate to GPS permission screen before `/(tabs)` | `app/(onboarding)/permissions.tsx`, `app/(auth)/verify-otp.tsx`, `app/index.tsx` | 1 day  |
| **B2.** If GPS denied, fall back to city picker (merge `FeedLocationSelector` prompt as fallback)                           | `app/(onboarding)/permissions.tsx`, `FeedLocationSelector.tsx`                   | 1 day  |
| **B3.** Persist onboarding state (`firstName`, `lastName`, `accountType`) to AsyncStorage so it survives process death      | `src/stores/onboardingStore.ts`                                                  | 2–4h   |
| **B4.** Replace empty-feed "No restaurants found" with actionable CTA when coords missing                                   | `FeedContent.tsx`                                                                | 2–4h   |
| ~~**B5.**~~ ~~Decide fate of `accountType` screen~~ — **Done.** Screen removed, store cleaned up.                           | —                                                                                | —      |

### Phase C — State architecture cleanup (3–5 days)

Eliminate parallel state so there is one source of truth per data domain.

| Task                                                                                                               | Files affected                                                      | Effort |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- | ------ |
| **C1.** Remove `socialStore` — social feed owned entirely by React Query                                           | `src/stores/socialStore.ts`, consumers                              | 1 day  |
| **C2.** Remove `feedStore.spots` sync — use `queryClient.getQueryData` or context for spot-by-id lookup            | `src/stores/feedStore.ts`, `FeedContent.tsx`, restaurant detail     | 1 day  |
| **C3.** Remove `followStatusByUserId` from `userStore` — manage follow state via optimistic updates on Query cache | `src/stores/userStore.ts`, `profile/[id].tsx`, `SocialFeedItem.tsx` | 1 day  |
| **C4.** Replace imperative `getMyProfile().then(setMe)` in `app/index.tsx` with `queryClient.prefetchQuery`        | `app/index.tsx`                                                     | 1–2h   |
| **C5.** Standardize stale time constants — replace inline magic numbers with `STALE_TIME_*`                        | All hooks in `src/hooks/`                                           | 1–2h   |
| **C6.** Extract cache invalidation from components into hooks                                                      | `CommentsModal.tsx`, `review/[id]/index.tsx`                        | 1–2h   |

### Phase D — Performance & list consistency (~1 week, can parallel)

| Task                                                                                | Files affected                                                          | Effort   |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | -------- |
| **D1.** Audit all FlatList usages → migrate long/dynamic lists to FlashList         | Leaderboard, search, notifications, restaurant details, ListPickerModal | 2–3 days |
| **D2.** Reduce splash delay for returning users (first-launch flag in AsyncStorage) | `app/index.tsx`                                                         | 1–2h     |
| **D3.** Simplify Tailwind spacing scale — add semantic aliases or reference comment | `tailwind.config.js`                                                    | 1h       |
| **D4.** Add `@/` path alias to `tsconfig.json` for cleaner imports                  | `tsconfig.json`, babel config, bulk import update                       | 2–4h     |

### Phase E — Resilience & observability (parallel)

| Task                                                                                                | Files affected                                                             | Effort                     |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------- |
| **E1.** Add root + per-tab `ErrorBoundary` with retry and error logging                             | `app/_layout.tsx`, `app/(tabs)/_layout.tsx`, new `ErrorBoundary` component | 2–4h                       |
| **E2.** Prepare `logError` for remote transport — add hook point for Sentry/Crashlytics when chosen | `src/utils/logger.ts`                                                      | 1–2h                       |
| **E3.** Consolidate logout token-clear to single responsibility (`authStore` owns it)               | `src/services/auth.ts`, `src/stores/authStore.ts`                          | 30min                      |
| **E4.** Push notification: complete backend device-token registration                               | `src/notifications/push.ts`, backend endpoint                              | 1 day (depends on backend) |

### Phase F — Tablet adaptation (1–2 weeks)

| Task                                                                                                       | Files affected                        | Effort                  |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------- | ----------------------- |
| **F1.** Define breakpoint strategy: max-width containers for feed on large screens, or multi-column layout | `tailwind.config.js`, feed components | Design decision + 1 day |
| **F2.** Tab bar → sidebar navigation on tablet-width viewports                                             | `app/(tabs)/_layout.tsx`              | 2–3 days                |
| **F3.** Audit card/list layouts for iPad/large Android (horizontal feed sections, modals, bottom sheets)   | Various components                    | 3–5 days                |
| **F4.** Test on iPad simulator + large Android emulator                                                    | Manual QA                             | 1–2 days                |

### Phase G — Testing (ongoing)

| Task                                                                                                    | Effort   |
| ------------------------------------------------------------------------------------------------------- | -------- |
| **G1.** Set up Jest/Vitest with React Native preset                                                     | 2–4h     |
| **G2.** Unit tests: token refresh queue, auth store transitions, `getEffectiveCoords`, `deriveUsername` | 1–2 days |
| **G3.** Integration tests: registration flow end-to-end (verify `first_name`/`last_name` reach API)     | 1 day    |
| **G4.** E2E: Detox or Expo MCP automation for signup → GPS permission → feed happy path                 | 2–3 days |

### Phase H — Future onboarding enrichment (backlog)

These leverage backend fields already available in the `User1` schema but not yet collected:

| Task                                                     | Backend field               | Effort   |
| -------------------------------------------------------- | --------------------------- | -------- |
| **H1.** Dietary preferences onboarding step              | `dietaries: string[]`       | 1–2 days |
| **H2.** Cuisine preferences onboarding step              | `cuisines: string[]`        | 1–2 days |
| **H3.** City/country selection during registration       | `country_code`, `city_code` | 1 day    |
| **H4.** Date of birth collection (age gate: must be 13+) | `date_of_birth`             | 1 day    |
| **H5.** Marketing opt-in toggle                          | `opt_in_marketing`          | 2h       |

---

## 5. Success metrics

| Metric                          | Target                                                     | How to measure                                               |
| ------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------ |
| **Registration data integrity** | 100% of collected fields reach the API                     | E2E test asserting payload contains `first_name`/`last_name` |
| **Cold start to interactive**   | < 2s for returning users                                   | AsyncStorage first-launch flag; `performance.now()`          |
| **First-run → feed with data**  | 100% of new users see restaurants                          | GPS prompt → fallback city picker → feed loads               |
| **Crash-free sessions**         | > 99.5%                                                    | Error reporting dashboard (when integrated)                  |
| **List scroll FPS**             | 60fps on mid-tier Android                                  | Flipper / React DevTools profiler                            |
| **Auth edge cases**             | Zero orphaned sessions after token refresh failure         | Unit tests on interceptor queue                              |
| **Deep link safety**            | All `/(tabs)` routes redirect to auth when unauthenticated | E2E test                                                     |
| **Tablet layout**               | Feed, profile, events render correctly on iPad 10th gen    | Manual QA + screenshots                                      |

---

## 6. Resolved questions

| #   | Question          | Answer                                               | Impact on plan                                                                             |
| --- | ----------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| 1   | Registration data | Send `firstName`/`lastName` in `registerUser()`      | Phase A1 — fix immediately                                                                 |
| 2   | Social OAuth      | Not implemented yet, coming soon                     | Leave as-is; no action needed now                                                          |
| 3   | Location strategy | Force GPS permission for first-time users            | Phase B1–B2 — wire `permissions.tsx` into post-auth flow, add city-picker fallback         |
| 4   | `accountType`     | No backend field. Screen removed, store cleaned up.  | **Done.** Screen deleted, navigation updated.                                              |
| 5   | Web               | Not a shipping target for now (dev convenience only) | GitHub issue [#47](https://github.com/Ressify/eden/issues/47) created to investigate later |
| 6   | Tablet            | Layouts should adapt                                 | Phase F added — breakpoints, sidebar nav, layout audit                                     |
| 7   | Error reporting   | Coming soon, service TBD                             | GitHub issue [#48](https://github.com/Ressify/eden/issues/48) created to track integration |

---

## 7. Tracked externally

| Item                                  | GitHub issue                                     |
| ------------------------------------- | ------------------------------------------------ |
| Web target investigation              | [#47](https://github.com/Ressify/eden/issues/47) |
| Production error tracking integration | [#48](https://github.com/Ressify/eden/issues/48) |

---

_All open questions resolved. No remaining blockers for Phase A._
