# Frontend integration — srvn taste-graph MVP

## Context

The backend taste-graph MVP (`srvn-backend/docs/plans/AI-Plans/srvn taste-graph MVP — implementation plan 1.md`) introduces personalized restaurant recommendations driven by user preferences + embedding similarity. The contract changes the frontend has to absorb are:

- `PUT /users/update-profile` accepts 6 new optional fields: `allergens` (string[]), `allergen_handling` (`"warn" | "block" | null`), `price_comfort_tiers` (int[] ⊆ {1,2,3,4}, non-empty when sent), `occasions` (string[]), `dietary_strictness` (`"soft" | "strict" | null`), `ambiance_prefs` (string[]).
- New endpoint `GET /users/me/taste-profile` returns the joined view (the 6 new fields + legacy `User.cuisines`/`User.dietaries`). Deliberately separate from `GET /users/profile` so the auth-hot path stays lean.
- `/spots/recommended` response shape is **unchanged**; ordering becomes personalized server-side and is gated by `SRVN_PERSONALIZED_RECS`. New optional `?occasion=` query param (soft hint).

User-confirmed scope:
1. **Onboarding**: keep current 5 steps, insert one new step for `price_comfort_tiers`. Remaining new fields live in a Settings screen.
2. **Dormant enums** (`allergen_handling`, `dietary_strictness`): expose both as optional toggles on the Settings screen (Phase 3-ready).
3. **`?occasion=`**: render a bottom-sheet dropdown in the feed header mirroring `FeedLocationSelector` — selected label visible in trigger title.

The intended outcome: minimum frontend lift to (a) collect the new preference fields from users, (b) display/edit them post-onboarding, and (c) let users filter recommended results by occasion. Personalization itself flips on transparently — `useRecommendedSpots` keeps the same `Paged<Spot>` shape, only ordering changes.

## Scope at a glance

| Area | Files touched | New files |
|---|---|---|
| Types | `src/types/api.ts` | — |
| Services | `src/services/users.ts`, `src/services/spots.ts` | — |
| Hooks | `src/hooks/useUser.ts`, `src/hooks/useSpots.ts`, `src/hooks/index.ts` | — |
| Data | `src/data/preferences.ts` | — |
| Onboarding step gating | `src/utils/onboardingState.ts`, `src/stores/onboardingStore.ts`, `app/(onboarding)/cuisines.tsx`, `app/(onboarding)/dietaries.tsx` | `app/(onboarding)/price-comfort.tsx` |
| Settings entry | `src/components/profile/SettingsList.tsx`, `app/(tabs)/profile/settings.tsx` | `src/components/profile/TastePreferencesModal.tsx` (or screen) |
| Feed occasion dropdown | `src/stores/feedStore.ts`, `src/components/feed/FeedContent.tsx`, `app/(tabs)/index/feed.tsx`, `src/components/feed/index.ts` | `src/components/feed/FeedOccasionSelector.tsx` |

## 1. Types (`src/types/api.ts`)

Add a `TasteProfileResponse` interface alongside `UserProfileResponse`:

```ts
export type AllergenHandling = 'warn' | 'block';
export type DietaryStrictness = 'soft' | 'strict';

export type TasteProfileResponse = {
  // Sidecar fields
  allergens: string[];
  allergen_handling: AllergenHandling | null;
  price_comfort_tiers: number[];                // ints ⊆ {1,2,3,4}
  occasions: string[];
  dietary_strictness: DietaryStrictness | null;
  ambiance_prefs: string[];
  // Convenience join from legacy User columns
  cuisines: string[] | null;
  dietaries: string[] | null;
};
```

Do **not** add these fields to `UserProfileResponse` — the backend deliberately split the endpoints.

## 2. Services

### `src/services/users.ts`

- Extend the `updateProfile()` payload type with the 6 new optional fields. Mirror the existing optional-pattern (no defaults; omitted fields are partial-update no-ops). Note explicitly in a comment that `price_comfort_tiers` must be non-empty when present.
- Add `getMyTasteProfile()` (mirror `getMyProfile()` shape):
  ```ts
  export async function getMyTasteProfile() {
    const res = await api.get('/users/me/taste-profile');
    return res.data as TasteProfileResponse;
  }
  ```

### `src/services/spots.ts`

- Extend `listRecommendedSpots()` params with `occasion?: string`. The axios `{ params }` object passes it through verbatim; backend ignores unknown values gracefully so no enum guard needed client-side.

## 3. React Query hooks

### `src/hooks/useUser.ts`

- Extend `userKeys` factory with `tasteProfile: () => [...userKeys.all, 'tasteProfile', 'me'] as const`.
- Add `useMyTasteProfile()` mirroring `useMyProfile()` (stale time `STALE_TIME_PROFILE`). Enable on demand only — the Settings preferences screen is the sole consumer.
- Extend `useUpdateProfile().onSuccess` to also invalidate `userKeys.tasteProfile()` so post-PUT the sidecar refetches (matches backend semantics where `/update-profile` writes both User and sidecar atomically).

### `src/hooks/useSpots.ts`

- Add `occasion?: string` to `useRecommendedSpots()` params. Include it in the `spotKeys.recommended(params)` key so different occasions cache independently.

Update `src/hooks/index.ts` to export `useMyTasteProfile`.

## 4. Data dictionaries (`src/data/preferences.ts`)

Add four arrays + types alongside the existing `CUISINES` / `DIETARIES`:

```ts
export const ALLERGENS = [
  'Peanut', 'Tree nut', 'Dairy', 'Egg', 'Shellfish', 'Fish',
  'Soy', 'Wheat', 'Sesame', 'Gluten',
] as const;

export const OCCASIONS = [
  'date_night', 'family', 'business', 'solo', 'casual',
  'group', 'celebration', 'brunch', 'late_night',
] as const;

export const AMBIANCE_PREFS = [
  'cozy', 'lively', 'intimate', 'upscale', 'casual', 'romantic',
  'trendy', 'quiet', 'outdoor',
] as const;

export const PRICE_COMFORT_TIERS = [1, 2, 3, 4] as const;
export const PRICE_TIER_LABELS: Record<1 | 2 | 3 | 4, string> = {
  1: '$', 2: '$$', 3: '$$$', 4: '$$$$',
};

// Human-readable for occasion dropdown
export const OCCASION_LABELS: Record<(typeof OCCASIONS)[number], string> = {
  date_night: 'Date night',
  family: 'Family',
  business: 'Business',
  solo: 'Solo',
  casual: 'Casual',
  group: 'Group',
  celebration: 'Celebration',
  brunch: 'Brunch',
  late_night: 'Late night',
};
```

Keep `MIN_CUISINES_REQUIRED = 3`. Backend taxonomy normalizes; the frontend sends the raw strings/snake_case unchanged.

## 5. Onboarding — insert "Price comfort" step (new step 5)

Final order: **1 intro → 2 terms → 3 photo → 4 cuisines → 5 price-comfort → 6 dietaries**. Dietaries stays last so it remains the screen that sends `onboarding_complete: true`.

### `src/utils/onboardingState.ts`

- Bump `ONBOARDING_TOTAL_STEPS` from `5` to `6`.
- Add `5: '/(onboarding)/price-comfort'` to `ONBOARDING_STEP_HREFS`; renumber dietaries to `6`.
- Add `'price-comfort'` to `POST_AUTH_ONBOARDING_SEGMENTS`.
- Add `priceStepDone?: boolean` to `OnboardingLocalFlags`.
- Add `priceSatisfied(p, local) => local.priceStepDone === true`. The sidecar field isn't on `UserProfileResponse` (backend keeps `/users/profile` lean), so completion is tracked locally — same pattern as `photoStepDone` and `dietariesStepDone`.
- Extend `computeFirstIncompleteStep` to check `priceSatisfied` between `cuisinesSatisfied` (step 4) and the dietaries fallback (now step 6).

### `src/stores/onboardingStore.ts`

- Add `priceComfortTiers: number[]` + `priceStepDone?: boolean` to `OnboardingPersistedState` and `initialDraft`.
- Add `setPriceComfortTiers(v: number[])` and `setPriceStepDone(v: boolean)` actions.
- Include both in `partialize` and clear `priceStepDone` in `resetAfterOnboardingComplete` + `syncFromCompletedProfile`.
- Expose `priceStepDone` via `getLocalFlags()`.

### `app/(onboarding)/cuisines.tsx`

Update post-save navigation from step 4 to point to step 5 (`/(onboarding)/price-comfort`) instead of directly to dietaries. Use `hrefForOnboardingStep(5)` rather than a literal.

### `app/(onboarding)/dietaries.tsx`

- Update `setStep(5)` → `setStep(6)`.
- Update `OnboardingHeader currentStep={5}` → `currentStep={6}`.
- Update the back-button target from step 4 → step 5 (`hrefForOnboardingStep(5)`).

### NEW `app/(onboarding)/price-comfort.tsx`

Clone `app/(onboarding)/dietaries.tsx` as the template. Differences:

- Title: "Price comfort"
- Subtitle: "Optional — pick any price ranges you're comfortable with."
- State: `selected: number[]` (subset of `[1,2,3,4]`).
- Render a row of 4 chips ($, $$, $$$, $$$$). Either:
  - Reuse `ChipGroup` by passing `options={Object.values(PRICE_TIER_LABELS)}` and mapping labels ↔ numbers in onChange. Simpler.
  - Or add a small numeric variant. Prefer reuse — keep `ChipGroup` as-is.
- On Continue:
  - If `selected.length > 0`, `updateProfile.mutateAsync({ price_comfort_tiers: selected })`.
  - If `selected.length === 0`, send no payload (skip).
  - On success: `setPriceComfortTiers(selected)`, `setPriceStepDone(true)`, `router.replace('/(onboarding)/dietaries' as Href)`.
- On Skip: identical to Continue with empty selection (no PUT call needed, just set local flag + navigate).
- On Back: `router.replace(hrefForOnboardingStep(4) as Href)`.
- Analytics: `trackOnboardingStepViewed('price-comfort')`, `trackOnboardingStepCompleted('price-comfort')`, `trackOnboardingStepSkipped('price-comfort')`. Add the new step name to whatever union/enum `src/services/onboardingAnalytics.ts` uses.

## 6. Settings → Taste preferences screen

### `src/components/profile/SettingsList.tsx`

- Add `'taste-preferences'` to the `SettingsItemId` union.
- Insert an item entry above `personal-info` (or in the Account section — choose visually). Label: "Taste preferences", icon: same family as existing items (sparkle/star).

### `app/(tabs)/profile/settings.tsx`

- Add a `showTastePreferencesModal` state + handler.
- Wire `id === 'taste-preferences'` in `handleSelectItem` to open it.
- Render the new modal at the bottom of the JSX, mirroring `BlockedUsersSettingsModal`.

### NEW `src/components/profile/TastePreferencesModal.tsx`

- Use `BottomSheetModal` (or full-screen modal — match existing `BlockedUsersSettingsModal` pattern).
- Load data via `useMyTasteProfile()`.
- Initialize local form state from the response; gate Save on `dirty`.
- Sections (all optional):
  1. **Cuisines** — `ChipGroup` over `CUISINES`. Pre-filled from `tasteProfile.cuisines ?? []`.
  2. **Dietaries** — `ChipGroup` over `DIETARIES` (preserves the `None` exclusivity logic from `dietaries.tsx:24-29`; extract that helper to `src/utils/dietarySelection.ts` and import from both places).
  3. **Allergens** — `ChipGroup` over `ALLERGENS`.
  4. **Allergen handling** — segmented control: `Warn` / `Block` / `Not set` (mapped to `'warn'` / `'block'` / `null`). Help text under: "Block hides spots with allergens you've listed; warn shows them with a warning."
  5. **Price comfort** — same 4-chip row as the onboarding step.
  6. **Occasions** — `ChipGroup` over `OCCASIONS` rendered with `OCCASION_LABELS`. Selection saves snake_case keys.
  7. **Dietary strictness** — segmented control: `Soft` / `Strict` / `Not set` → `'soft'` / `'strict'` / `null`. Help text: "Strict will eventually hide non-matching spots; soft just ranks them lower."
  8. **Ambiance** — `ChipGroup` over `AMBIANCE_PREFS`.
- Save button calls `useUpdateProfile().mutateAsync({ ...changedFields })` — only send changed sections (diff against the snapshot from `useMyTasteProfile` data).
  - For `price_comfort_tiers`: if user cleared it to empty, omit the field (backend rejects empty arrays). Provide a small "Clear" affordance or just treat unselected-on-save as "no change".
  - For nullable enums: send the field with value `null` if user explicitly chose "Not set" after having had a value previously (backend Marshmallow accepts `null` via `allow_none=True` — confirm). If backend doesn't accept null, document this as "once set, can change but not clear" and hide the "Not set" option after first save.
- On mutation success the `useUpdateProfile` hook already invalidates `userKeys.myProfile()`; with the extension in §3 it also invalidates `userKeys.tasteProfile()` so the modal re-syncs.
- Error path: surface a generic `Alert.alert('Could not save', '...')`; field-level 422 handling is out of scope (matches existing `PersonalInfoContent` pattern).

> Decision deferred to implementation: bottom-sheet modal vs full-screen modal. Settings already uses both. Default to **full-screen modal** like `BlockedUsersSettingsModal` because the form is taller than a comfortable sheet.

## 7. Feed — occasion dropdown

### `src/stores/feedStore.ts`

- Add `recommendedOccasion: string | null` to state + `setRecommendedOccasion(v: string | null)`. Default `null` (no filter).
- Do NOT persist this across sessions — keep it ephemeral by excluding from any persisted partializer (check the file for the persist config; if not persisted, just add to in-memory state).

### NEW `src/components/feed/FeedOccasionSelector.tsx`

- Clone the structure of `src/components/feed/FeedLocationSelector.tsx`:
  - `Pressable` trigger with the selected occasion label (or "Any occasion" when null), chevron-down icon.
  - `BottomSheetModal` with a vertical list of options.
  - First row "Any occasion" (resets to `null`).
  - Remaining rows render `OCCASIONS` with `OCCASION_LABELS`.
  - On select: `setRecommendedOccasion(value)` + close.
- No async loading — `OCCASIONS` is a static dictionary.

Export from `src/components/feed/index.ts`.

### `src/components/feed/FeedContent.tsx`

- Read `recommendedOccasion` from `feedStore`.
- Pass to `useRecommendedSpots({ ..., occasion: recommendedOccasion ?? undefined })`.

### `app/(tabs)/index/feed.tsx`

- Render `<FeedOccasionSelector />` next to `<FeedLocationSelector />` inside the header `View` (around `feed.tsx:212-220`). Likely a horizontal row with both selectors and a slight gap.

## Reused utilities (don't reinvent)

- `ChipGroup` (`src/components/onboarding/ChipGroup.tsx`) — works for all multi-select arrays, including price tiers via label mapping.
- `BottomSheetModal` + `BottomSheetScrollView` — already used by `FeedLocationSelector` and `BlockedUsersSettingsModal`.
- `useUpdateProfile` (`src/hooks/useUser.ts:72-82`) — single mutation for both legacy and new fields; backend handles the atomic write.
- `STALE_TIME_PROFILE` (`src/utils/staleTimes.ts`) — matches `useMyProfile` cadence for the new sidecar query.
- `OnboardingStepFrame`, `OnboardingHeader`, `KeyboardFloatingFAB` — direct reuse for the new onboarding screen.
- `hrefForOnboardingStep` — keeps step navigation declarative.
- `normalizeDietarySelection` (currently in `dietaries.tsx:24`) — extract to `src/utils/dietarySelection.ts` so the new settings modal reuses the same `None` exclusivity rule.

## Out of scope (deferred)

- **Field-level 422 surface** — backend may return validation errors per field; current frontend pattern is a generic alert and we keep that.
- **Strict allergen warnings** at spot detail — backend MVP doesn't populate `allergen_warnings`; no UI to build.
- **Cold-start vs personalized indication** in the UI — no copy change in recommended list.
- **`SRVN_PERSONALIZED_RECS` client mirror** — purely server-side gate; no client flag needed.
- **Migration from axios to fetch** — separate plan exists; this work is fully forward-compatible.

## Verification

Run the EAS dev build (Expo Go won't work per CLAUDE.md).

1. **Onboarding**
   - Sign up a fresh user → progress through 1 intro → 2 terms → 3 photo → 4 cuisines (≥3) → **5 price comfort** (new) → 6 dietaries → tabs.
   - Skip on price step → still lands on dietaries; dietaries → finishes onboarding → tabs.
   - Kill the app mid-onboarding after step 4 → relaunch → resumes at price-comfort (proves local `priceStepDone` flag + `effectiveOnboardingStep` work).
2. **Settings**
   - Open Settings → Taste preferences → all 8 sections visible.
   - Edit one section, Save → toast/no-error, reopen → values persisted.
   - Toggle allergen_handling between Warn/Block/Not set → reopen reflects choice.
   - Confirm response is from `GET /users/me/taste-profile` not from `useMyProfile` (network tab).
3. **Recommended feed**
   - On feed screen, see new occasion dropdown next to location.
   - Open dropdown → pick "Date night" → list refetches, trigger title now reads "Date night".
   - Pick "Any occasion" → resets to null, list refetches.
   - Backend `SRVN_PERSONALIZED_RECS=true` + a user with saved spots → ordering differs across two devices/users with divergent histories (manual end-to-end check; backend tests cover the assertion at the API level).
4. **Type & unit checks**
   - `yarn tsc --noEmit` clean (no `any` introduced for `TasteProfileResponse`).
   - Existing tests under `tests/` for onboarding remain green; add a smoke test for the new onboarding step gating in `src/utils/onboardingState.ts` (the existing test for `computeFirstIncompleteStep` if any — search before adding).
5. **Cache invalidation**
   - After Settings save, `useMyTasteProfile()` cache is fresh (open modal → no stale data).
   - After legacy cuisines edit via Settings, `useMyProfile()` also refreshes (existing behavior preserved).

## Critical files to read before implementing

- `src/services/users.ts:28-54` — current `updateProfile()` payload signature
- `src/hooks/useUser.ts:23-82` — `userKeys`, `useMyProfile`, `useUpdateProfile`
- `src/hooks/useSpots.ts:200-222` — `useRecommendedSpots` + `spotKeys.recommended`
- `src/utils/onboardingState.ts` (full) — step gating logic
- `src/stores/onboardingStore.ts` (full) — local flags + partialize
- `app/(onboarding)/dietaries.tsx` (full) — template for the new price step (state, focus effect, mutation, navigation, analytics)
- `src/components/onboarding/ChipGroup.tsx` (full) — multi-select API
- `src/components/feed/FeedLocationSelector.tsx` (full) — template for the occasion selector
- `src/components/profile/SettingsList.tsx` — `SettingsItemId` union + item list
- `app/(tabs)/profile/settings.tsx` — modal mounting pattern (e.g. `BlockedUsersSettingsModal`)
- `src/services/onboardingAnalytics.ts` — to register `'price-comfort'` step name
- `src/types/api.ts:40-73` — `UserProfileResponse` location for sibling type
