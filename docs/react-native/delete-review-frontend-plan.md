# Plan: Frontend wiring for `DELETE /spots/<spot_id>/reviews/<review_id>`

## Context

Backend PR [srvnapp/srvn-backend#140](https://github.com/srvnapp/srvn-backend/pull/140) shipped an
author-only soft-delete endpoint that cascades to a review's likes, saves,
mentions, and dish associations and recomputes `Spot.rating` in the same
transaction. The endpoint is idempotent in the soft-delete sense: a second
DELETE on the same review returns 404.

The frontend has **no plumbing for review deletion** today:

- No service wrapper (`src/services/spots.ts:4-103` — only `createSpotReview`).
- No mutation hook (`src/hooks/useSpots.ts:395-445` — only `useCreateSpotReview`).
- No UI affordance on `ReviewCard` (`src/components/reviews/ReviewList.tsx`)
  or `SocialFeedItem` (`src/components/socials/SocialFeedItem.tsx`).
- The closest UX precedent is the comment options sheet
  (`src/components/socials/CommentOptionsBottomSheet.tsx`), which already does
  author-only edit/delete for comments — that is the pattern to mirror.

## UX

**Trigger.** Both surfaces now share the same Instagram-style header
(`AvatarRow`: avatar + reviewer name on the left). The trigger is a `···`
(`ellipsis-horizontal`) icon button pinned to the top-right of that header
row, vertically centered with the avatar:

- **`ReviewCard`** (spot detail review list, profile review list) — `···`
  in the header row. Tapping it opens the `ReviewOptionsBottomSheet`. The
  rest of the card retains its existing pressables (media → gallery viewer,
  "more" link → review detail, tagged-user mentions → user profile, avatar
  row → author profile).
- **`SocialFeedItem`** (home social feed) — same `···` in the same
  position, opens the same sheet.

Sharing the trigger placement across both cards keeps the affordance
discoverable and consistent, and avoids the muddy "tap card body" target
problem (the cards already have many inner navigations).

**Modal contents are viewer-relative.** The same
`ReviewOptionsBottomSheet` renders different rows based on whether the
viewer authored the review:

| Viewer is…                                 | Rows shown                    |
| ------------------------------------------ | ----------------------------- |
| The author (`me.id === review.author?.id`) | "Delete review" (destructive) |
| Anyone else                                | "Report review"               |

Edit is not yet wired and is intentionally omitted from this plan — slot it
in alongside Delete when the edit screen ships.

**Confirmation.** Use the existing branded `ConfirmActionBottomSheet`
(`src/components/ui/ConfirmActionBottomSheet.tsx`), which is the
destructive-confirm convention in this app — same component the delete-
account flow uses (`app/(tabs)/profile/settings.tsx:177-181`). Header
"Delete review?", message "This can't be undone. The review and its
likes, saves, and mentions will be removed.", `confirmLabel="Delete"`,
`cancelLabel="Cancel"`. Dismiss the sheet immediately on confirm tap
(don't pass `confirmPending`); let the card overlay handle the in-flight
state, since it's more informative — the user sees _which_ row is being
deleted, and the sheet would otherwise cover the card it's acting on.

**In-flight visual.** Per the agreed pattern: on confirm, the review card
overlays itself with a dim scrim + centered spinner using `LoadingState`. The
overlay's `pointerEvents` block any further taps on the card. Source of truth
for "which row is loading" is `mutation.variables.reviewId` while
`mutation.isPending` — no separate `useState`. This composes correctly with
virtualized lists and remounts.

**Success.** Fire `toast.success('Review deleted')` and invalidate the
relevant queries in the same `onSuccess` tick. The review row disappears on
the next render via cache invalidation; the toast slides in alongside. No
artificial sequencing — the user sees overlay → row gone + toast within a
single frame after the 204 lands.

**Failure.** Drop the overlay, fire `toast.error('Could not delete review.
Please try again.')`. No cache touch — the row was never removed.

**Idempotent 404.** If the server returns 404 (already deleted on another
device, or a duplicate tap that raced through), treat as success: invalidate

- success toast. Do **not** surface "Review not found" to an author who just
  asked to delete it.

## Implementation

### 1. Service (`src/services/spots.ts`)

Add after `createSpotReview` (line 93):

```ts
/**
 * DELETE /spots/{spotId}/reviews/{reviewId}.
 *
 * Author-only soft-delete. The backend cascades to the review's likes, saves,
 * mentions, and dish associations and recomputes the spot's rating in one
 * transaction. Cloudinary cleanup happens out-of-band.
 *
 * Idempotent in the soft-delete sense: a second call returns 404. Callers
 * should treat 404 as success (the review is already gone).
 */
export async function deleteSpotReview(params: { spotId: number; reviewId: number }) {
  await api.delete(`/spots/${params.spotId}/reviews/${params.reviewId}`);
}
```

### 2. Mutation hook (`src/hooks/useSpots.ts`)

Add after `useCreateSpotReview` (line 445). Mirrors `useDeleteComment`
(`src/hooks/useSocials.ts:438-462`) for shape, but invalidates the
spot-side caches instead of the comments tree.

```ts
/**
 * Hook to delete (soft-delete) a review.
 *
 * On success — including 404, which we treat as success (idempotent
 * re-delete) — drops the review from the spot's review list, the social
 * feed caches, and the user-profile review list, then invalidates spot
 * detail/list caches so denormalized rating_avg / reviews_count refresh.
 */
export function useDeleteSpotReview() {
  const queryClient = useQueryClient();

  const applyDelete = (variables: { spotId: number; reviewId: number }) => {
    // Drop the row from this spot's reviews list (paged + infinite shapes).
    queryClient.setQueriesData(
      { queryKey: [...spotKeys.all, 'reviews', variables.spotId] },
      (old) => removeReviewFromPagedCaches(old, variables.reviewId)
    );

    // Drop from any social-feed cache.
    queryClient.setQueriesData({ queryKey: socialKeys.feed() }, (old) =>
      removeReviewFromPagedCaches(old, variables.reviewId)
    );

    // Drop from user-profile review lists (any user — could be the author's
    // public profile or their own profile tab; we don't know the user id from
    // the variables alone, so match the prefix).
    queryClient.setQueriesData({ queryKey: ['user', 'reviews'] }, (old) =>
      removeReviewFromPagedCaches(old, variables.reviewId)
    );

    // Refetch spot detail and the various spot lists so rating_avg /
    // reviews_count update. Skip the 'reviews' branch — we just edited it.
    queryClient.invalidateQueries({
      queryKey: spotKeys.all,
      predicate: (query) => query.queryKey[1] !== 'reviews',
    });
  };

  return useMutation({
    mutationFn: spotsService.deleteSpotReview,
    onSuccess: (_data, variables) => applyDelete(variables),
    onError: (error, variables) => {
      // Treat 404 as success: the review is already gone (e.g. deleted on
      // another device, or a re-delete after a successful first call).
      if (isHttpStatus(error, 404)) {
        applyDelete(variables);
        return;
      }
      // Real failure — let the caller surface a toast.
      throw error;
    },
  });
}
```

Add a tiny shared helper `removeReviewFromPagedCaches` next to the existing
`prependReviewToPagedCaches` in the same file — same `Paged` /
`InfiniteData<Paged>` shape detection, but `data.filter(r => r.id !==
reviewId)` instead of prepend.

`isHttpStatus` already exists or can be a one-liner against the axios error
shape (`error?.response?.status === 404`); confirm what's in
`src/services/api.ts` and reuse it. If nothing exists, add a small helper
rather than inlining the shape.

### 3. UI: review-options bottom sheet

New file `src/components/reviews/ReviewOptionsBottomSheet.tsx`. Modeled on
`CommentOptionsBottomSheet`, but the rows are viewer-relative — the parent
decides which mode to render:

```ts
export type ReviewOptionsBottomSheetProps = {
  visible: boolean;
  onClose: () => void;
  /** Determines which row(s) render. Author → Delete; everyone else → Report. */
  variant: 'author' | 'viewer';
  onDelete?: () => void; // required when variant === 'author'
  onReport?: () => void; // required when variant === 'viewer'
};
```

- **`variant: 'author'`** — two rows:
  - "Edit review" (`create-outline`) — toasts a "Coming soon"
    `Alert.alert` stub until the edit screen ships
    (`UpdateReviewPayload` exists at `src/types/api.ts:287-288` but is
    unused today). The affordance is left in the menu so it's
    discoverable and impossible to forget.
  - "Delete review" (`trash-outline`, destructive) — opens the confirm
    sheet.
- **`variant: 'viewer'`** — single row:
  - "Report review" (`flag-outline`) — `Alert.alert("Coming soon",
"Reporting will be available soon.")`. Same "Coming soon" pattern
    used elsewhere in settings (`app/(tabs)/profile/settings.tsx:93`,
    `AboutSettingsModal.tsx:26-31`).

The parent (review card / feed item) determines the variant from the same
`me?.id === review.author?.id` check it uses to gate the trigger:

```ts
const variant = me?.id != null && me.id === review.author?.id ? 'author' : 'viewer';
```

### 4. Shared header trigger baked into `AvatarRow`

`ReviewCard` (`src/components/reviews/ReviewList.tsx`) and `SocialFeedItem`
(`src/components/socials/SocialFeedItem.tsx`) both render their author
header through `AvatarRow` (`src/components/ui/AvatarRow.tsx`). Bake the
`···` menu trigger directly into `AvatarRow` so the icon, sizing, color,
hit target, and a11y attributes are guaranteed identical across surfaces.

Audit before changing: `AvatarRow` has 6 consumers; only 2 want the menu
(`ReviewCard`, `SocialFeedItem`). The other 4 (`FollowUserCard`,
`feed/FeedItem`, `app/(tabs)/profile/index`, `app/profile/[id]`) pass no
new props and are unaffected by this change.

```ts
export type AvatarRowProps = {
  // …existing props…
  /**
   * When provided, renders an `ellipsis-horizontal` button at the right end
   * of the row, vertically centered with the avatar. Render-when-defined,
   * idiomatic React — no separate boolean flag.
   */
  onMenuPress?: () => void;
  menuAccessibilityLabel?: string; // e.g., 'Review options'
  menuTestID?: string;
};
```

Single optional handler — render the icon when `onMenuPress` is defined,
skip when not. (A separate `showMenu: boolean` would be redundant with
"is `onMenuPress` defined?" and creates a chance to mismatch.)

Implementation: wrap the existing pressable section + the menu button in an
outer `<View className="flex-row items-center">`. The avatar/name section
keeps `flex-1`; the menu button is fixed-width on the right. The menu
button renders **outside** the row's own `Pressable`, so tapping `···`
does not also fire `goToAuthorProfile`. Hit slop ≥ 8 to maintain a 44×44
tap target.

Trade-off acknowledged: if a future surface wants a _different_ trailing
affordance (e.g., a follow button beside the avatar in `SocialFeedItem`),
this API forces another prop pair or a refactor to a generic `trailing?:
ReactNode` slot. YAGNI for now — current and foreseeable use is just the
menu.

### 5. Sheet wiring + overlay (same for both cards)

- `me` comes from `useUserStore`. The sheet variant is
  `me?.id === review.author?.id ? 'author' : 'viewer'`.
- **Author flow** — options sheet's `onDelete` opens a
  `ConfirmActionBottomSheet`. On confirm tap, both sheets close and the
  parent calls `mutation.mutate({ spotId, reviewId: review.id })`. The
  card overlay then handles in-flight state.
- **Viewer flow** — sheet's `onReport` is the stub described in §7.
- **Loading overlay** — while
  `mutation.isPending && mutation.variables?.reviewId === review.id`, the
  card renders an absolute-positioned overlay (rounded to match the card
  radius, `EdenColors.black` at ~70% opacity, centered `LoadingState`)
  with `pointerEvents: 'auto'` so taps on the card behind it are blocked.

Both components need the spot id. `ReviewCard` does not currently receive
it — thread it through `ReviewListProps` (known at the call site since the
list is per-spot). For `SocialFeedItem`, confirm `review.spot_id` is on
the `ReviewList` type.

**Mutation hook is per-card.** Each `ReviewCard` / `SocialFeedItem` calls
`useDeleteSpotReview()` itself. The card owns its overlay
(`mutation.isPending`), confirm-sheet open state, and toast trigger. No
prop drilling for delete logic — the only prop the list passes is
`spotId` (already needed for create/edit context too). Cache invalidation
runs from the hook config, so it fires correctly even if the card
unmounts mid-flight (e.g., the row scrolls offscreen). Cost is
negligible — `useMutation` is cheap and FlatList virtualization keeps
hooks bounded to visible rows.

### 6. Where the modal appears

The `···` trigger is always present in the header for signed-in viewers —
variant decides what they see when they tap.

| Surface                                                         | Trigger         | Author variant | Viewer variant |
| --------------------------------------------------------------- | --------------- | -------------- | -------------- |
| Spot detail review list (`SpotReviewsAndInfo`)                  | `···` in header | Delete         | Report         |
| Social feed (`SocialFeedItem`)                                  | `···` in header | Delete         | Report         |
| Profile review list — own profile (`app/(tabs)/profile/index`)  | `···` in header | Delete         | (n/a — own)    |
| Profile review list — other user's profile (`app/profile/[id]`) | `···` in header | (n/a)          | Report         |
| Review detail screen                                            | `···` in header | Delete (back)  | Report         |
| Public share view (`/socials/reviews/share/<token>`)            | None            | —              | —              |

Public share view stays clean — no JWT, no viewer identity, no actions.

For the review detail screen, after the 204 lands and invalidation runs,
`router.back()` so the user does not stay on a now-404 screen.

### 7. Report — backend gap

There is no `POST /reviews/<id>/report` (or similar) endpoint today. Until
the backend ships one, the Report row needs a stub. Recommended:

```ts
const onReport = () => {
  closeSheet();
  toast("Thanks — we'll take a look at this review.");
};
```

This keeps the affordance honest-looking without lying about a server-side
record. Track the real endpoint as a follow-up — when it lands, swap the
toast for a `useReportReview` mutation that hits it. (Alternatives: an
"reporting coming soon" alert, or hide the Report row entirely until the
endpoint exists. The toast stub is the lowest-friction option that still
ships the UI affordance.)

### 8. Type / shape verification (do this before coding)

- Confirm `ReviewList` carries `author.id` even for `is_anonymous: true`
  reviews when the viewer is the author. If anonymous-and-mine reviews omit
  `author` over the wire, the menu will never show on them, which is
  user-hostile. Either:
  - the backend exposes a viewer-relative `is_mine: boolean`, or
  - we keep `author.id` populated on outbound payloads and only suppress
    `author.username` / `author.profile_picture` for is_anonymous.
    This is a backend question — flag in the gaps section.
- Confirm `ReviewList` exposes `spot_id` for the social-feed surface.
- Confirm there is or isn't an existing `isHttpStatus` helper in
  `src/services/api.ts`.

## Test plan

- [ ] Hook test (`useDeleteSpotReview`): seeds the QueryClient with paged spot
      reviews, social feed, and user-profile reviews carrying the same
      review id; runs the mutation; asserts the row is gone from all three.
- [ ] Hook test for the 404-as-success path: mock the service to throw a
      404, assert the cache mutation still runs.
- [ ] Hook test for the real-error path: mock a 500, assert the cache is
      untouched.
- [ ] Component test for the overlay: render `ReviewCard` while mutation is
      pending with matching `reviewId`, assert overlay is visible and
      `pointerEvents` block taps.
- [ ] Manual: delete a review from spot detail, profile, and feed; confirm
      spot rating updates after the refetch settles; confirm the empty
      state appears when the last review on a spot is deleted.

## Resolutions

1. **Anonymous reviews — out of scope.** Anonymous review creation will not
   be supported going forward. The author check is the simple
   `me?.id === item.author?.id`. Existing anonymous rows that don't match
   never show the menu — acceptable.
2. **Report — `Alert.alert("Coming soon", …)` stub.** Discoverable
   affordance, impossible to forget. Real endpoint filed as a backend
   follow-up.
3. **`AvatarRow` audit — done.** 6 consumers; only `ReviewCard` and
   `SocialFeedItem` use the new `onMenuPress`. The other 4 are
   unaffected.
4. **Edit option — included as a "Coming soon" stub** in the author
   variant, mirroring Report. Wires to the real edit screen when it
   ships.
5. **Review detail on author-delete — `router.back()`** on success.
6. **Confirm dialog — branded `ConfirmActionBottomSheet`**, dismissed
   immediately on confirm tap so the card overlay handles in-flight
   state. Not using `Alert.alert`.
7. **Mutation hook placement — per-card.** Each card calls
   `useDeleteSpotReview()` itself; no prop drilling beyond `spotId`.
   Hook-level cache invalidation runs even if the card unmounts
   mid-flight.

## Follow-ups (out of scope for this delivery)

1. **404 handling on the review-comments screen.**
   `app/review/[id]/index.tsx` is a comments thread, not a review-detail
   page (it never fetches the review itself). When a deleted-review
   notification is tapped, the comments fetch returns 404 and renders as
   a generic comments-fetch error. The deleter never sees this (they
   `router.back()` on success), but other viewers tapping stale
   notifications/share links will. Fix: when comments fetch errors with
   status 404 specifically, fire a `toast('This review is no longer
available')` and pop:
   `router.canGoBack() ? router.back() : router.replace('/(tabs)/index')`.
   Toaster is mounted at the root (`app/_layout.tsx:128`) so the toast
   survives the pop. Only on 404 — 500s and network errors should keep
   the user on the screen with a retry.
2. **Backend `POST /reviews/<id>/report` endpoint.** Required to make the
   Report row functional. Until then it's a "Coming soon" stub.
3. **Edit-review screen.** `UpdateReviewPayload` is defined in
   `src/types/api.ts:287-288` but unused. The composer
   (`addReview.tsx`) is the create flow; reusing it for edit is
   plausible but a separate task. The Edit row is a "Coming soon" stub
   until then.
