# Toast System — Port from Flutter (`project-eden`) to srvn React Native app (`srvn-app`)

> **Status:** DRAFT — open questions at the bottom. Do not implement until resolved.
> `react-native-toast-message` is already installed via `npm i react-native-toast-message`.

## 1. Goal

Port the Flutter app's toast feedback system (`EdenLoadingModalAndToasts.showToast`) to the srvn React Native app, preserving:

- A single imperative API usable from anywhere (hooks, components, service layer).
- Three variants mirroring Flutter's `EdenToastType`: `success`, `warning`, `info` (+ optional `error`).
- Consistent visual language (solid background, white text, bottom-ish placement).
- Automatic success toasts on successful API mutations (Flutter's `RequestHelperMixin` pattern), with per-call opt-out.
- Manual toasts for client-side validation and local actions.

Note on naming: the Flutter source app is still directory-named `project-eden` and uses the `Eden*` symbol prefix. The new React Native app is **srvn**, so all new symbols introduced here use a `Srvn` prefix (`SrvnToastType`, etc.). Existing symbols already in `srvn-app` that still use the `Eden` prefix (e.g. `EdenColors` in `src/utils/colors.ts`) are left untouched — renaming those is a separate refactor out of scope for this plan.

Explicitly NOT in scope:

- The Flutter `loadingService` / loading modal (RN app already uses inline loading states on `Button`).
- Auto-toasting on queries (would fire on every refetch; Flutter only does it on explicit `runRequest` calls).

## 2. Current state in the srvn app

Investigated files (none need rewriting wholesale, only surgical changes):

| Area | File | Current behavior |
|---|---|---|
| API client | `src/services/api.ts` | Axios instance with 401 refresh flow. No user-facing feedback. |
| Query client | `src/providers/QueryProvider.tsx` | `QueryClient` with `offlineFirst`, `retry: 2`, persistence. No `mutationCache` handlers. |
| Errors | `src/utils/logger.ts` | `logError` + `getAuthErrorMessage` — feeds form `setError('root', ...)`. |
| Colors | `src/utils/colors.ts` | Already has `EdenColors.success/warning/info/error` (symbol kept as-is for now) matching Flutter. |
| Root layout | `app/_layout.tsx` | `QueryProvider > GestureHandlerRootView > ThemeProvider > KeyboardProvider > Stack`. No toast host. |
| Existing alerts | `components/profile/AboutSettingsModal.tsx`, `components/socials/ReviewCommentsThread.tsx`, etc. | 5 call sites use `Alert.alert` — 3 are informational ("Copied", "Coming soon") and fit toasts; 2 are destructive confirmations and should stay dialogs. |

**`react-native-toast-message` is installed.** No prior toast code to migrate or delete.

## 3. Library choice — DECIDED

**`react-native-toast-message`** — already installed. JS-controlled, mounted once at root, imperative `Toast.show()`, theming via `config` prop, Expo-compatible. Matches the Flutter approach (JS-themed toasts) and lets us reuse existing `EdenColors` + Inter fonts with full control.

## 4. Architecture

### 4.1 Module: `src/services/toast.ts`

The public API — a thin wrapper over `react-native-toast-message` so call sites never import the library directly (swappable later).

```ts
export type SrvnToastType = 'success' | 'warning' | 'info' | 'error';

export interface ShowToastOptions {
  message: string;
  type?: SrvnToastType;            // default 'info'
  title?: string;                  // optional bold header line
  durationMs?: number;              // default 3500 (matches Flutter LENGTH_LONG)
  haptic?: boolean;                 // default true — fires appropriate haptics
}

export const toast = {
  show(opts: ShowToastOptions): void,
  success(message: string, opts?: Omit<ShowToastOptions, 'message' | 'type'>): void,
  warning(message: string, opts?: Omit<ShowToastOptions, 'message' | 'type'>): void,
  info(message: string, opts?: Omit<ShowToastOptions, 'message' | 'type'>): void,
  error(message: string, opts?: Omit<ShowToastOptions, 'message' | 'type'>): void,
  hide(): void,
};
```

Internals:

- Calls `Toast.show({ type, text1: title ?? message, text2: title ? message : undefined, ... })`.
- Fires `haptics.success()` / `haptics.warning()` / `haptics.light()` based on type when `haptic !== false`, reusing `src/services/haptics.ts`.
- Guards against SSR / non-native (`react-native-web`) by checking `Platform.OS`.

### 4.2 Module: `src/components/ui/ToastHost.tsx`

Custom `config` for `react-native-toast-message` defining the four variants. Each variant:

- Full-width capsule, `rounded-2xl`, solid background per type, Inter font.
- Left accent icon (Ionicons: `checkmark-circle`, `alert-circle`, `information-circle`, `close-circle`).
- `text1` bold, `text2` regular, white text.
- Horizontal margin = 16, respects safe-area via `useSafeAreaInsets`.
- Accessible: `accessibilityRole="alert"`, `accessibilityLiveRegion="polite"` on Android.

```tsx
// ToastHost.tsx
import Toast, { BaseToastProps } from 'react-native-toast-message';
// ...colored capsule components per type...
export const toastConfig = { success, warning, info, error };
export function ToastHost() {
  return <Toast config={toastConfig} position="top" topOffset={insets.top + 8} />;
}
```

### 4.3 Root mount: `app/_layout.tsx`

Add `<ToastHost />` as the **last** child of the outermost view so it overlays `Stack` (including modal screens). Must be inside `SafeAreaProvider` — add `react-native-safe-area-context`'s provider at root if not already wrapping (verify).

```tsx
<QueryProvider>
  <GestureHandlerRootView style={{ flex: 1, backgroundColor: EdenColors.pageBackground }}>
    <SafeAreaProvider>
      <ThemeProvider value={edenNavigationTheme}>
        <KeyboardProvider>{content}</KeyboardProvider>
      </ThemeProvider>
      <ToastHost />
    </SafeAreaProvider>
  </GestureHandlerRootView>
</QueryProvider>
```

### 4.4 Auto success-toast on mutations

Install a global `mutationCache` handler on the `QueryClient` that reads `mutation.meta`:

```ts
new QueryClient({
  mutationCache: new MutationCache({
    onSuccess: (_data, _vars, _ctx, mutation) => {
      const meta = mutation.options.meta as { successToast?: string | boolean } | undefined;
      if (!meta?.successToast) return;
      const msg = typeof meta.successToast === 'string'
        ? meta.successToast
        : extractServerMessage(_data) ?? 'Success';
      toast.success(msg);
    },
    onError: (err, _vars, _ctx, mutation) => {
      const meta = mutation.options.meta as { errorToast?: string | boolean } | undefined;
      if (!meta?.errorToast) return;
      const msg = typeof meta.errorToast === 'string'
        ? meta.errorToast
        : getAuthErrorMessage(err);
      toast.error(msg);
    },
  }),
  defaultOptions: { /* unchanged */ },
});
```

Helper `extractServerMessage(data)` — returns `data?.message` if present, else `null`. This matches Flutter's `response.message` pattern.

**Default behavior: OFF.** A mutation only toasts if it opts in via `meta`. This keeps existing mutations unaffected and avoids spurious toasts during the migration.

Usage:

```ts
useMutation({
  mutationFn: updateProfile,
  meta: { successToast: 'Profile updated' },        // or true → use server message
  // errorToast is OFF by default — keep form-field errors for forms
});
```

### 4.5 Manual usage

```ts
import { toast } from '../../services/toast';

toast.warning('You cannot select a time in the past.');
toast.success('Reward claimed successfully!');
```

**Google Sign-In (auth screens):** `sign-in.tsx` / `sign-up.tsx` use `Alert.alert('Google sign-in failed', getAuthErrorMessage(err))` in the `catch` (plus `logError`). When this toast system ships, optionally replace that alert with `toast.error(getAuthErrorMessage(err))` for consistency with other transient feedback.

## 5. File-by-file changes

| # | File | Change |
|---|---|---|
| 1 | `package.json` | ✅ `react-native-toast-message` already installed. Verify `react-native-safe-area-context` is also present (Expo SDK 54 ships it). |
| 2 | `src/services/toast.ts` | **New.** Public API (§4.1) |
| 3 | `src/components/ui/ToastHost.tsx` | **New.** Themed host (§4.2) |
| 4 | `src/components/ui/index.ts` | Export `ToastHost` |
| 5 | `src/services/index.ts` (if exists) or add `toast` to consumers | Export `toast` |
| 6 | `app/_layout.tsx` | Mount `<ToastHost />` (§4.3), add `SafeAreaProvider` if missing |
| 7 | `src/providers/QueryProvider.tsx` | Add `MutationCache` with meta-driven handlers (§4.4) |
| 8 | `src/components/profile/AboutSettingsModal.tsx` | Replace informational `Alert.alert('Copied', ...)` and `'Coming soon'` with `toast.info(...)` |
| 9 | Future: any new mutation needing feedback | Add `meta.successToast` |

No existing mutations are touched in this PR — they are opt-in only.

## 6. Styling spec

| Type | Background | Icon | Icon color | Text color |
|---|---|---|---|---|
| success | `EdenColors.success` (#34a853) | `checkmark-circle` | white | white |
| warning | `EdenColors.warning` (#fbbc05) | `alert-circle` | `#1a1a1a` | `#1a1a1a` (dark on yellow for contrast) |
| info | `EdenColors.info` (#4285f4) | `information-circle` | white | white |
| error | `EdenColors.error` (#eb4335) | `close-circle` | white | white |

Font: `font-inter-semibold` (title), `font-inter-regular` (body). Sizes 16/14.

Deviation from Flutter: Flutter uses white text on all backgrounds including yellow. On RN I recommend dark text on yellow for WCAG AA contrast (Flutter is accessibility-debt here, we don't need to inherit it). **Confirm.**

## 7. Edge cases & risks

1. **Root mount inside `GestureHandlerRootView`**: `react-native-toast-message` uses `PanGestureHandler` for swipe-to-dismiss — must be inside `GestureHandlerRootView`. ✅ Will be.
2. **Safe area**: top-anchored toasts need to clear the status bar. Bottom-anchored need to clear home indicator AND the tab bar on `(tabs)` routes. Top is simpler.
3. **Modals**: if a toast fires while an RN modal is open, the toast must render above the modal. `react-native-toast-message` supports this via `autoHide` and re-mounting the host inside modals if needed. Acceptable limitation — document it.
4. **Keyboard**: toast should not be obscured by keyboard. Top position avoids this.
5. **Query retries**: since our `QueryClient` has `retry: 2`, a failing mutation with `meta.errorToast` will NOT toast until all retries exhaust (desired behavior — `onError` fires once at the end).
6. **Offline mode**: `networkMode: 'offlineFirst'` means mutations may be paused. Toast fires when the mutation actually resolves, not when queued. Acceptable.
7. **React Strict Mode / Fast Refresh**: imperative `Toast.show` outside a component tree works fine.
8. **Jest / unit tests**: the library provides no mock — we'll stub `src/services/toast.ts` in tests.
9. **`react-native-web`**: library supports web, but we should guard against it just in case; srvn-app targets mobile first.
10. **Accessibility**: confirm `react-native-toast-message` sets `accessibilityLiveRegion` or wrap with it in custom config.

## 8. Migration order

1. Add dependency, create `toast.ts` and `ToastHost.tsx`.
2. Mount at root. Verify on iOS and Android dev build.
3. Smoke test by calling `toast.success('hello')` from a button.
4. Wire `MutationCache` handlers in `QueryProvider`.
5. Opt one mutation into `meta.successToast` as a canary.
6. Port the 3 informational `Alert.alert` calls.
7. Document usage in `docs/guidelines/CODEBASE.md` (if the codebase guide pattern exists there).
8. Verify: `npm run typecheck && npm run lint`.

## 9. Out of scope / future work

- Loading modal port (not recommended — use inline loading).
- Auto error-toast on all mutations (keep form errors in form state).
- Undo actions / action buttons in toasts.
- Queue policy tuning (replace vs. stack).

---

## 10. Open questions for the user

Blocking items — please answer before I implement:

1. ~~**Library**~~ — DECIDED: `react-native-toast-message` (installed).
2. **Position** — top (my recommendation, avoids tab bar / home indicator) or bottom (matches Flutter)?
3. **Auto-success-toast default** — opt-in per mutation (safe, my recommendation) or opt-out globally (matches Flutter behavior but will cause a wave of new toasts across existing mutations)?
4. **Server message field** — does your backend consistently return `{ message: string }` on success responses? If not, what's the path? (Needed for `extractServerMessage`.)
5. **Error toasts** — keep form-field errors only (my recommendation for auth forms) or also toast on mutation errors when opted in via `meta.errorToast`?
6. **Error variant** — add `error` type (red) distinct from `warning`, or collapse like Flutter does (warning for everything bad)?
7. **Yellow-on-white contrast** — override Flutter's white-on-yellow for accessibility (my recommendation), or match Flutter exactly?
8. **Haptics** — integrate `src/services/haptics.ts` on toast show? (Yes from me.)
9. **Alert.alert replacements** — convert the 3 informational ones in `AboutSettingsModal` + `ReviewCommentsThread` in this same PR, or defer?
10. **Loading modal** — confirm we're skipping the port (RN already uses inline loading states)?
