# Plan: Shared hero + collapsing-header screen shell

## Goal

Extract the duplicated layout used by:

- `src/components/restaurant/RestaurantDetailsContent.tsx` (spot / restaurant details from feed or events stack)
- `app/(tabs)/events/[id].tsx` (event details)

into one reusable component so both screens share the same **SafeArea + StatusBar + scroll-linked header chrome + scroll container** behavior and stay visually/behaviorally aligned.

## Proposed component

**Name (working):** `HeroScrollScreen` (or `CollapsingHeaderScreen` if you prefer naming that describes animation, not hero image).

**Location (recommended):** `src/components/ui/HeroScrollScreen.tsx`

- Keeps it next to `Header` and other shell primitives.
- Alternative: `src/components/layout/HeroScrollScreen.tsx` if you introduce a small `layout/` folder for non-feature shells.

**Responsibilities (in scope):**

- `SafeAreaView` with `edges={['left', 'right']}` (same as today).
- Translucent `StatusBar` (`light-content`, transparent background).
- Absolute layers: status-bar fade overlay + header row background fade (same `interpolate` / `Easing` ranges as today, driven by `STATUS_BAR_FADE_END`, `HEADER_BG_FADE_*`, `STATUS_BAR_EXTRA_HEIGHT`, padding constants).
- Renders shared `Header` with `scrollY` + `config` passed in via props (callers supply `title`, icons, etc.).
- `Animated.ScrollView` wired with `useAnimatedScrollHandler` and internal `useSharedValue(0)` for `scrollY` (unless we explicitly need an external ref—see open questions).
- Optional **`footer` slot** below the scroll view (event details needs this; restaurant details does not).

**Out of scope for the shell:**

- Hero image / carousel / page-specific body content (passed as `children` inside the scroll view).
- Business logic (share handlers, navigation, data fetching).

## Public API (sketch)

```ts
type HeroScrollScreenProps = {
  headerConfig: HeaderConfig; // must include animate-friendly fields; shell sets scrollY + typically animateHeader: true
  children: React.ReactNode; // scroll body
  footer?: React.ReactNode;
  /** Merged into ScrollView; shell always sets onScroll + scrollEventThrottle for Reanimated */
  scrollViewProps?: Omit<
    React.ComponentProps<typeof Animated.ScrollView>,
    'onScroll' | 'scrollEventThrottle' | 'children'
  >;
  safeAreaEdges?: ('top' | 'right' | 'bottom' | 'left')[];
  testID?: string;
};
```

Callers pass `headerConfig` with `title`, `leftIcons`, `rightIcons`, etc. The shell injects `scrollY` and can enforce `animateHeader: true` if not set.

## Implementation steps

1. **Add `HeroScrollScreen.tsx`** under `src/components/ui/` implementing the structure duplicated today (overlay views + `Header` + `Animated.ScrollView` + optional footer wrapper `View` with `flex: 1` column).
2. **Unify scroll defaults** inside the shell (single source of truth):
   - `style={{ flex: 1 }}` on `Animated.ScrollView` when a `footer` is present (fixes column + footer layout).
   - `scrollEventThrottle={1}` for smooth header sync with Reanimated.
   - `bounces` / `overScrollMode` aligned with whatever product standard you pick (see open questions).
3. **Export** from `src/components/ui/index.ts`.
4. **Refactor `RestaurantDetailsContent`** success branch: replace inline SafeArea/header/scroll block with `<HeroScrollScreen headerConfig={...}>...</HeroScrollScreen>` (no footer).
5. **Refactor `app/(tabs)/events/[id].tsx`**: remove local `scrollY`, `scrollHandler`, `statusBarOverlayStyle`, `statusBarBackgroundStyle`, and duplicate layout; use `<HeroScrollScreen headerConfig={...} footer={...}>` wrapping existing scroll content.
6. **Verify** TypeScript (`npm run typecheck`), ESLint (`npm run lint`), and manual smoke on iOS/Android: back/share/header title fade, scroll with footer on event detail, full-height scroll on restaurant detail.

## Risks / testing notes

- **Nested scrolling:** Restaurant screen has a horizontal `FlatList` inside the vertical scroll; behavior must stay the same after wrapping.
- **z-index / touch:** Preserve `pointerEvents` on overlay layers (`none` / `box-none`) so header buttons remain tappable.
- **Safe area + hero:** Content still draws under the status bar; no accidental double top inset.

## Open decisions (need your call)

1. **Scroll physics parity:** Event detail currently uses `bounces={Platform.OS === 'ios'}` and Android `overScrollMode="never"`. Restaurant detail still uses `bounces={false}` and no `overScrollMode`. Should the **shell enforce one policy for both** (recommended), or allow per-screen overrides via `scrollViewProps` only?
2. **`Header` config typing:** Should the shell accept `Omit<HeaderConfig, 'animateHeader'> & { animateHeader?: boolean }` and always merge `scrollY`, or allow callers to pass a custom `titleComponent` without animation?
3. **Future `scrollY` access:** If a screen later needs scroll position for something other than `Header` (e.g. parallax), do we add an optional `onScrollYReady?: (sv: SharedValue<number>) => void` or `scrollYRef`—or defer until needed?

---

**Cases easy to miss:** modals over the screen (event `InviteFriendsModal`), keyboard avoiding if you add inputs later, and any screen that needs `edges` including `bottom` or `top`—the shell should keep those configurable via `safeAreaEdges` with a documented default.

If you confirm decisions (1)–(3), implementation can follow this plan without further API churn.
