# Unit Test Foundation — Follow-ups

> Phase 1 shipped: Jest 29 + `jest-expo` + `@testing-library/react-native` v13 wired up, `tests/unit/` layout with `@/*` and `@test-utils` path aliases, 5 seed test files / 34 tests green, coverage HTML generating, docs updated. See `docs/guidelines/CODEBASE.md#testing` for the conventions.
>
> This file tracks what's left.

---

## Current baseline (for context)

- `npm test` — 5 suites, 34 tests ✅
- `npm run test:coverage` — writes `coverage/lcov-report/index.html`
- `npm run typecheck` — clean (incl. `tests/**`)
- `npm run lint` — clean on everything under `tests/`
- `npm run validate` — gates typecheck + lint + format on every pre-commit; tests NOT in validate yet (would be too slow)
- `npm run test:ci` — `jest --ci --coverage --maxWorkers=2`, used by the GitHub Actions workflow
- `.github/workflows/test.yml` runs on every PR and push to `main` — two parallel jobs: **Unit tests** (`npm run test:ci`, uploads `coverage/` as a 14-day artifact) and **Lint** (`npm run lint`). Node 22, `HUSKY=0`, concurrency group cancels stale runs.

Coverage is deliberately unenforced — seed tests bring `phone.ts` and `distance.ts` to 100%, `onboardingStore.ts` to ~78%, everything else 0%.

---

## Phase 2 — CI enforcement ✅ done

Workflow + `test:ci` script + required status checks on `main` (`Unit tests`, `Lint`, `strict: true`) all live. Merges into `main` are now blocked until both checks pass.

**One deferred item:** after the workflow has been green on `main` for a week or so, promote `test` into the `validate` script so local pre-commit mirrors CI. One-liner: change `"validate": "npm run typecheck && npm run lint && npm run format:check"` to `... && npm test`. Skipped for now because pre-commit should stay fast.

---

## Phase 3 — Expand test coverage

Three independent workstreams; can land in any order.

### 3a. ~~Screen tests via `expo-router/testing-library`~~ ✅ done

Shipped `tests/unit/test-utils/renderScreen.tsx` (a `renderScreenWithProviders` that composes `renderRouter` inside the existing provider stack) and `tests/unit/screens/auth/welcome.test.tsx` (2 tests: renders, and navigates to `/signup-phone` on press). CODEBASE.md now documents five archetypes.

`renderScreen.tsx` is intentionally **not** in the `@test-utils` barrel — `expo-router/testing-library` has module-load-time side effects (installs global mocks). Screen tests import from `@test-utils/renderScreen` explicitly; other tests aren't affected.

### 3b. ~~Axios 401 refresh-queue test~~ ✅ done

Shipped as `tests/unit/services/api.test.ts` — five tests covering single-request refresh, concurrent-burst collapsing (one refresh per N 401s), no-refresh-token logout, failed-refresh logout, and the self-loop guard on `/auth/refresh`. Header-validated mocks (return 401 for stale token, 200 for refreshed) prove retries carry the new Authorization.

Incidental cleanup required: `jest-expo`'s preset installs a buggy `ReadableStream` shim (`expo/virtual/streams`) that crashes axios's fetch-adapter probe at module-load time. Fixed in `tests/unit/jest.setup.ts` by swapping globals for Node's native `node:stream/web`. This unblocks any future test that imports `axios` or `@/services/api` directly.

### 3c. ~~Coverage floor~~ ✅ done

Shipped in `jest.config.js` as `coverageThreshold.global` = `{ lines: 5, statements: 4.5, functions: 3, branches: 2 }`. Floor is just below current numbers so today's suite passes with headroom but any regression below those values (e.g., a deleted test or a large new untested file) fails CI.

**Ratchet protocol going forward:** every PR that adds meaningful coverage should bump these thresholds to the new floor in the same PR. Targets:

- End of next quarter: `lines: 30`, `statements: 30`, `functions: 25`, `branches: 20`
- Mid-year: `lines: 60`, `branches: 45`

Never lower the thresholds.

---

## Phase 4 — E2E

Out of scope until the app has ~50%+ unit coverage. Noting here so `tests/e2e/` isn't forgotten.

- **Maestro** (recommended) — YAML flows, no native build needed for iOS sim or Android emulator in most cases, reruns well in CI via `maestro cloud`.
- **Detox** — more mature, more invasive (requires a prod build), slower iteration loop.

Start with one flow: sign-up → onboarding → home feed. Document the test target in `CODEBASE.md#testing` alongside the unit conventions.

---

## Follow-up on the Phase 1 Metro smoke test

The `tsconfig.json` path-alias change was tested via `tsc --noEmit` but never via a live Metro bundle. Before landing large app-code migrations to `@/…`, run `npm run dev` once and confirm:

- Metro starts without resolution errors.
- A single `@/…` import in a dev-branch file bundles cleanly on both iOS and Android dev builds.

This is a sanity check, not a likely regression — Expo SDK 54's Metro honors tsconfig paths natively — but worth ticking off once before the rest of the codebase adopts the alias.
