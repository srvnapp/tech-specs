# sc-48 — Mobile: Block / Unblock from public profile

Story: https://app.shortcut.com/srvn/story/48
Backend: srvnapp/srvn-backend#144 (POST/DELETE /users/{id}/block) + #145 (GET /users/me/blocks)
Backend prerequisite: [sc-62](https://app.shortcut.com/srvn/story/62) — surface `is_blocked` on `GET /users/{id}/profile`. **Merged** in srvnapp/srvn-backend#150 on 2026-05-02. Mobile reads `profile.is_blocked` directly.
Branch: `chrisejeh7239/sc-48/mobile-block-unblock-from-public-profile`

## Goal

Add an entry point on the public-profile screen so a viewer can block (and unblock) another user. Required for Apple Guideline 1.2 / Google Play UGC compliance — the backend already filters blocked users from feed, search, spot-detail reviews, and 1:1 chat, but mobile has no UI to trigger the block.

## Decisions (locked)

| Question                                    | Answer                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| How does mobile know block state?           | Read `profile.is_blocked` directly off `GET /users/{id}/profile` — landing in [sc-62](https://app.shortcut.com/srvn/story/62). This story is paused until that ships.                                                                                                                                                |
| Does block auto-unfollow?                   | **No** (confirmed in `UserBlockService.block` — only touches `user_blocks`). Don't invalidate `followers` / `following` caches; counts don't change.                                                                                                                                                                 |
| Report user row                             | **Not rendered.** Reverted from the original "Coming soon" placeholder — reporting users is no longer planned for this surface, and a disabled row taking up space without function is worse UX than no row.                                                                                                         |
| Post-block navigation                       | `router.back()` after the mutation settles. Unblock stays on the profile (no reason to leave when restoring a relationship). Trade-off: until the "Blocked users" management screen ships (separate story), unblock is unreachable from inside the app — backend search/feed filter the user out. Acceptable for v1. |
| Toast on success                            | Yes — `toast.success('@username blocked')` / `toast.success('@username unblocked')`. Mirrors the pattern already in `ReportTargetBottomSheet`.                                                                                                                                                                       |
| Profile reachable when target blocks viewer | Yes (confirmed — profile route only checks soft-delete, not blocks). No special-casing needed.                                                                                                                                                                                                                       |
| POST status code                            | Backend returns **200**, not 201 as story claimed. Mobile code is agnostic.                                                                                                                                                                                                                                          |

## What ships

1. **Kebab `…` icon** in `app/profile/[id].tsx` header `rightIcons`. Hidden when the viewer is on their own profile (`isCurrentUser`).
2. **Actions bottom sheet** opened by the kebab. Single row:
   - **Block @username** / **Unblock @username** — flips by current state. Block row uses `destructive` styling.
   - The kebab → sheet pattern is kept (rather than wiring the kebab straight to the confirm sheet) so future per-profile actions slot in here without restructuring.
3. **Confirm bottom sheet** for the block action (mirrors the unfollow modal at `app/profile/[id].tsx:283-313`). Copy: "Block @username? They won't see your reviews and you won't see theirs." Confirm tone primary.
4. **Confirm bottom sheet** for unblock with copy "Unblock @username?". Lighter consequence but still confirmable.
5. **Cache invalidation** after block/unblock settles:
   - `userKeys.profile()` — refresh the target's `is_blocked` flag and counts.
   - `[...userKeys.all, 'search']` — server filters blocked users out of search.
   - `socialKeys.feed()` — feed filters blocked users in both directions.
   - `[...spotKeys.all, 'reviews']` — spot detail review lists drop blocked authors.
   - **Not** invalidated: `followers` / `following` (block doesn't remove follow edges per `UserBlockService.block`).
6. **Toast** on success (`@username blocked` / `@username unblocked`) via `sonner-native`.
7. **`router.back()`** after a successful block. Stay on profile after a successful unblock.

## File-by-file changes

### `src/types/api.ts`

- Add `is_blocked?: boolean | null` to `UserProfileResponse` (one direction: viewer→target). Lands as part of sc-62.

> Out of scope for sc-48: `BlockedUser` type and `useMyBlockedUsers` hook. Those belong to the future "Blocked users" management screen story — not needed here once `profile.is_blocked` exists.

### `src/services/users.ts`

- `blockUser(targetUserId: number)` → `POST /users/${id}/block` → `{ message: string }`.
- `unblockUser(targetUserId: number)` → `DELETE /users/${id}/block` → `{ message: string }`.

### `src/hooks/useUser.ts`

- `useBlockUser()` — mutation calling `usersService.blockUser`. `onSuccess` invalidates: `userKeys.profile()`, `[...userKeys.all, 'search']`, `socialKeys.feed()`, `[...spotKeys.all, 'reviews']`.
- `useUnblockUser()` — mirror invalidation surface.

### `src/components/profile/ProfileActionsBottomSheet.tsx` (new)

- Encapsulates the kebab sheet so `app/profile/[id].tsx` doesn't grow another 100 lines.
- Props: `{ visible; onClose; username; isBlocked; onBlock; onUnblock; isPending }`.
- Renders a single `OptionRow`: Block/Unblock action.
- Block row uses `destructive` styling; Unblock uses default tone.

### `app/profile/[id].tsx`

- Add `useMyBlockedUsers()` query; derive `isBlocked = blockedData?.data.some(b => b.id === userId) ?? false`. Falls back to a local zustand override (next bullet) so the post-mutation flip is instant.
- Add `blockStatusByUserId` to `useUserStore` and read it as the optimistic override (same pattern as `followStatusByUserId`). On success, set the override; the cache invalidation refetches `/users/me/blocks` and the override eventually agrees with server truth.
- Add three new state vars: `showActionsSheet`, `showBlockConfirm`, `showUnblockConfirm`.
- Wire `rightIcons={[{ icon: 'ellipsis-horizontal', onPress: () => setShowActionsSheet(true), testID: 'profile-kebab' }]}` (gated on `!isCurrentUser`).
- Render `<ProfileActionsBottomSheet />` + the two confirm sheets.
- Handlers:
  - `confirmBlock`: run mutation → `setBlockStatus(userId, true)` → `toast.success("@${username} blocked")` → close sheets → `router.back()`.
  - `confirmUnblock`: run mutation → `setBlockStatus(userId, false)` → `toast.success("@${username} unblocked")` → close sheets → stay on profile and `refetchProfile()`.

### `src/stores/userStore.ts` (small extension)

- Add `blockStatusByUserId: Record<number, boolean>` and a `setBlockStatus(userId, blocked)` setter. Same shape and persistence policy as `followStatusByUserId`.

## Tests (unit)

- `tests/unit/hooks/useBlockUser.test.tsx` — mocks `usersService.blockUser`, asserts the invalidation surface (`profile`, `search`, `blocked`, social feed, spot reviews) after `mutateAsync` resolves. Confirms `followers` / `following` are NOT invalidated. Use `createWrapper()` from `@test-utils`.
- `tests/unit/hooks/useUnblockUser.test.tsx` — mirror.
- `tests/unit/components/profile/ProfileActionsBottomSheet.test.tsx` — renders Block / Unblock label by `isBlocked` prop; press handlers fire correctly; isPending suppresses the press; regression guard that no Report row is rendered.
- `tests/unit/screens/profile/[id].test.tsx` — kebab visible only for non-self; tap kebab opens actions sheet; tap Block opens confirm; confirm fires the mutation with the correct user id; on success calls `router.back()`.

## Manual smoke (before reporting done)

- Open another user's profile → kebab visible.
- Tap kebab → sheet shows Block @username (single row).
- Tap Block → confirm sheet → confirm → toast appears → screen pops back to wherever you came from.
- Re-open the same profile (if reachable via direct link / chat history) → kebab now reads Unblock.
- Verify the user vanishes from the socials feed and from search.
- Tap Unblock → confirm sheet → confirm → toast → kebab flips back to Block, no navigation.
- Verify the user reappears in feed and search.
- Edge: block a user you currently follow — confirm Following button still reads "Following" after block (no auto-unfollow per backend), but their content is gone from feed/search.

## Backend follow-up (separately tracked)

[sc-62](https://app.shortcut.com/srvn/story/62) (in epic 34) tracks adding `is_blocked` to `UserProfileResponseSchema` / `User.get_profile_stats`. Once shipped, mobile can drop the `useMyBlockedUsers`-membership-check derivation and read `profile.is_blocked` directly.
