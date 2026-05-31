# Migration Plan: Remove Axios → Native Fetch API

## Overview

Replace the Axios HTTP client with a custom fetch-based client that preserves all existing functionality: automatic auth headers, 401 token refresh with request queuing, timeout support, multipart/form-data uploads, and structured error handling.

---

## Current State Analysis

### What Axios provides today

| Feature                                               | Where                                                         | Details                                          |
| ----------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------ |
| Shared instance with baseURL + default headers        | `src/services/api.ts`                                         | Single `api` instance used everywhere            |
| Request interceptor (auth token)                      | `src/services/api.ts:35-43`                                   | Attaches `Bearer` token from SecureStore         |
| Response interceptor (401 refresh + queue)            | `src/services/api.ts:45-123`                                  | Refresh token flow, request queuing, auto-logout |
| 60s timeout                                           | `src/services/api.ts:13`                                      | For Render cold starts                           |
| Automatic JSON parsing                                | Implicit                                                      | `res.data` auto-parsed                           |
| `params` serialization                                | All service files                                             | Query string from object                         |
| `isAxiosError()` guard                                | `app/event/create.tsx`, `app/(tabs)/events/[id].tsx`          | Imported type guard in screens                   |
| Axios-shaped checks in logger                         | `src/utils/logger.ts`                                         | `'isAxiosError' in err` (not the imported fn)    |
| Axios error shape (`response.data`, `code`, `status`) | `src/utils/logger.ts`                                         | `logError()` and `getAuthErrorMessage()`         |
| Multipart form-data                                   | `src/services/users.ts:30-41`, `src/services/spots.ts:84-101` | Profile picture + review uploads                 |

### Files that import Axios directly

- `src/services/api.ts` — core instance + interceptors (also uses standalone `axios.post` for `/auth/refresh`)
- `src/utils/logger.ts` — `AxiosError` type import + `'isAxiosError' in err` checks
- `app/event/create.tsx` — `isAxiosError()` guard
- `app/(tabs)/events/[id].tsx` — `isAxiosError()` guard

### Files that import `api` (the Axios instance)

- `src/services/auth.ts`
- `src/services/users.ts`
- `src/services/spots.ts`
- `src/services/socials.ts`
- `src/services/events.ts`
- `src/services/leaderboard.ts`
- `src/services/notifications.ts`
- `src/services/misc.ts`
- `src/services/locations.ts`

---

## Migration Strategy

### Phase 1: Build the fetch client (`src/services/api.ts`)

Replace the Axios instance with a custom `api` object that exposes the same method signatures: `api.get()`, `api.post()`, `api.put()`, `api.delete()`. This means **zero changes needed in any service file** — they all call `api.get(path, { params })` or `api.post(path, body, { headers })` and read `res.data`.

#### 1.0 — Internal `request()` and refresh bypass (required for parity)

Today’s 401 interceptor retries with **`api(originalRequest)`** — Axios’s callable form with a full config (method, URL, query `params`, body, headers). The fetch client must include an **internal `request(config)`** (or equivalent) that performs one round-trip with those fields. The public `get` / `post` / `put` / `delete` methods should delegate to it.

**Token refresh** today uses **standalone** `axios.post` to `${API_BASE_URL}/auth/refresh` — not the shared `api` instance. Mirror that with **raw `fetch`** to the same URL (or a small helper that does **not** pass through the same 401-refresh wrapper). That avoids recursion and matches current behavior.

#### 1.1 — Custom `ApiError` class

Create a typed error class to replace the Axios error shape:

```typescript
export class ApiError extends Error {
  status: number;
  statusText: string;
  data: unknown;
  code?: string;

  constructor(status: number, statusText: string, data: unknown) {
    super(`Request failed with status ${status}`);
    this.name = 'ApiError';
    this.status = status;
    this.statusText = statusText;
    this.data = data;
  }
}

export function isApiError(err: unknown): err is ApiError {
  return err instanceof ApiError;
}
```

Also introduce **network-layer errors** (failed fetch, timeout) as `Error` subclasses (or a dedicated type) that set **`code`** to **`'ERR_NETWORK'`** or **`'ECONNABORTED'`** where appropriate, so `getAuthErrorMessage()` can keep the same branches as today (it relies on those Axios codes and `Network Error` message patterns).

#### 1.2 — Core `fetchClient` function

Build the internal fetch wrapper that handles:

- **Base URL prepending** — same `API_BASE_URL` from config
- **Default headers** — `Content-Type: application/json`
- **Auth token injection** — calls `getAccessToken()` before each request (replaces request interceptor)
- **Timeout via `AbortController`** — 60s default (replaces Axios `timeout`)
- **Auto JSON body serialization** — `JSON.stringify(body)` for non-FormData payloads
- **Response body parsing** — Prefer `response.json()` for JSON APIs; for **204 No Content** or **empty bodies**, avoid calling `json()` blindly (it can throw). For error responses that are **not JSON** (HTML/plain text from a proxy), try `json()` and **fall back** to `text()` and attach the result to `ApiError.data`
- **Query param serialization** — build `URLSearchParams` from `params` object (replaces Axios `params`)
- **Error throwing** — throw `ApiError` for non-2xx responses (replaces Axios auto-throw behavior)
- **Network error handling** — catch `TypeError` (fetch network errors) and timeout `AbortError`, map to consistent error codes

#### 1.3 — 401 Token Refresh with Request Queuing

Port the existing interceptor logic into the `fetchClient`:

- After receiving a 401, check if the URL is `/auth/refresh` (skip to avoid loops)
- If already refreshing → queue the request in `failedQueue` (same pattern)
- Otherwise → call `/auth/refresh` via **standalone `fetch`** (not through the wrapped client), store new tokens, retry the original request via **`request(config)`**
- On refresh failure → clear tokens, logout, reject

This is the most critical piece — the logic stays identical, just expressed as control flow instead of interceptors.

#### 1.4 — `api` object with method shortcuts

```typescript
export const api = {
  get<T>(url: string, config?: RequestConfig): Promise<ApiResponse<T>>,
  post<T>(url: string, body?: unknown, config?: RequestConfig): Promise<ApiResponse<T>>,
  put<T>(url: string, body?: unknown, config?: RequestConfig): Promise<ApiResponse<T>>,
  delete<T>(url: string, config?: RequestConfig): Promise<ApiResponse<T>>,
};
```

Where `ApiResponse<T>` has a `data: T` property to match Axios's `res.data` pattern. This keeps all service files working without changes. Implementation detail: each method builds a config object and calls the shared **`request()`** used by the 401 retry path.

#### 1.5 — Multipart FormData handling

When the body is a `FormData` instance, skip `JSON.stringify` and omit the `Content-Type` header (let the runtime set the multipart boundary). This matches how the current code works in `users.ts` and `spots.ts`.

---

### Phase 2: Update error handling (`src/utils/logger.ts`)

#### 2.1 — Replace `AxiosError` references in `logError()`

- Replace `'isAxiosError' in err` with **`isApiError(err)`** (and handle network-error type the same way if it is a separate class)
- Map `ax.code` → `err.code`, `ax.response?.status` → `err.status`, `ax.response?.data` → `err.data`
- Rename `devPayload.axios` to something neutral (e.g. `api`) so logs reflect the new stack

#### 2.2 — Replace `AxiosError` references in `getAuthErrorMessage()`

- Branch on **`isApiError(err)`** for HTTP failures (`err.data` for `message` / `detail`, `err.status === 401`)
- For network/timeout, preserve today’s behavior by matching **`code === 'ERR_NETWORK'`**, **`code === 'ECONNABORTED'`**, and/or **`message === 'Network Error'`** — these must be emitted by the fetch client for fetch failures and `AbortController` timeouts (see §1.1)
- Keep the same user-facing strings

---

### Phase 3: Update component-level error handling

#### 3.1 — `app/event/create.tsx`

- Replace `import { isAxiosError } from 'axios'` with `import { isApiError } from '@/services/api'`
- Replace `isAxiosError(e) && e.response?.data` with `isApiError(e) && e.data`

#### 3.2 — `app/(tabs)/events/[id].tsx`

- Same changes as §3.1 (this file also imports `isAxiosError` from `axios` today)

---

### Phase 4: Remove Axios dependency

#### 4.1 — Uninstall Axios

```bash
npm uninstall axios
```

(Optional beforehand: `npx expo install --fix` if you are already reconciling dependency versions; it is not required solely to remove axios.)

#### 4.2 — Verify no remaining Axios imports

Search entire codebase for `from 'axios'` or `require('axios')` — should be zero results.

---

### Phase 5: Type check and test

#### 5.1 — Type check

```bash
npx tsc --noEmit
```

#### 5.2 — Lint

```bash
npm run lint
```

#### 5.3 — Manual testing checklist

- [ ] Login flow (email OTP, phone OTP, email/password)
- [ ] Token refresh on 401 (let token expire, verify auto-refresh)
- [ ] Request queuing (multiple API calls hitting 401 simultaneously)
- [ ] Auto-logout when refresh token is invalid
- [ ] Profile picture upload (multipart)
- [ ] Create review with form data (multipart)
- [ ] Social feed loading (paginated GET with params)
- [ ] Event creation (POST with JSON body)
- [ ] Search with query params
- [ ] Network error handling (airplane mode)
- [ ] Timeout handling (slow server)
- [ ] Error messages displayed correctly in UI (including event **create** and event **details** screens)

---

## File Change Summary

| File                            | Action        | Scope                                                     |
| ------------------------------- | ------------- | --------------------------------------------------------- |
| `src/services/api.ts`           | **Rewrite**   | Replace Axios instance with fetch client + ApiError class |
| `src/utils/logger.ts`           | **Update**    | Replace `AxiosError` imports/checks with `ApiError`       |
| `app/event/create.tsx`          | **Update**    | Replace `isAxiosError` with `isApiError`                  |
| `app/(tabs)/events/[id].tsx`    | **Update**    | Same as `create.tsx`                                      |
| `src/services/auth.ts`          | **No change** | Uses `api.post()/get()` + `res.data` — compatible         |
| `src/services/users.ts`         | **No change** | Uses `api.get()/post()/put()/delete()` — compatible       |
| `src/services/spots.ts`         | **No change** | Uses `api.get()/post()/delete()` — compatible             |
| `src/services/socials.ts`       | **No change** | Uses `api.get()/post()/put()/delete()` — compatible       |
| `src/services/events.ts`        | **No change** | Uses `api.get()/post()/put()` — compatible                |
| `src/services/leaderboard.ts`   | **No change** | Uses `api.get()` — compatible                             |
| `src/services/notifications.ts` | **No change** | Uses `api.get()/put()` — compatible                       |
| `src/services/misc.ts`          | **No change** | Uses `api.get()` — compatible                             |
| `src/services/locations.ts`     | **No change** | Uses `api.get()` — compatible                             |
| `package.json`                  | **Update**    | Remove `axios` dependency                                 |

**Total files changed: 5** (api.ts rewrite, logger.ts update, two app screens, package.json cleanup)
**Total files unchanged: 9** service files work as-is due to compatible API surface

---

## Key Design Decisions

1. **Match Axios's `res.data` pattern** — Return `{ data: T }` so 9 service files need zero changes
2. **Match Axios's method signatures** — `api.get(url, { params })`, `api.post(url, body, { headers })`
3. **Custom `ApiError` over raw `Response`** — Provides the same structured error info that Axios errors did
4. **`AbortController` for timeouts** — Native replacement for Axios `timeout` option
5. **No external dependencies** — Pure fetch, zero new packages
6. **FormData detection** — Skip JSON serialization and Content-Type header when body is FormData
7. **Future-proof query param serialization** — Verified via OpenAPI spec: all current query params are scalars. However, the serializer will handle arrays using repeated keys (e.g., `cuisines=italian&cuisines=japanese`) to future-proof against new endpoints. This is the standard convention supported by most backend frameworks (Flask, Express, FastAPI). `null`/`undefined` values are silently skipped.
8. **Single internal `request()`** — Public verbs and 401 retry share one code path (replaces `api(originalRequest)`).
9. **Refresh uses bare `fetch`** — Same separation as today’s standalone `axios.post` for refresh.
10. **Safe response parsing** — Handle empty and non-JSON bodies so production errors do not surface as parse exceptions.

---

## Risks & Mitigations

| Risk                                                              | Mitigation                                                                                                                  |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Token refresh race condition during migration                     | Port exact same queuing logic — no behavioral change                                                                        |
| FormData boundary not set correctly                               | Let runtime handle it by omitting Content-Type for FormData (React Native handles this correctly)                           |
| Fetch doesn't reject on HTTP errors (4xx/5xx)                     | Explicitly check `response.ok` and throw `ApiError`                                                                         |
| Query param serialization differences                             | Serializer handles both scalars and arrays (repeated keys). `null`/`undefined` skipped. Matches Axios behavior              |
| React Query retry behavior may change with different error shapes | `ApiError` extends `Error`, so React Query's retry logic works the same                                                     |
| **204 / empty response body**                                     | Detect empty body before `json()`; return `{ data: undefined as T }` or parse only when `Content-Type` / length warrants it |
| **Non-JSON error bodies** (HTML, plain text)                      | Try `json()`, catch and use `text()` into `ApiError.data`                                                                   |
| **Array query serialization** vs backend                          | Repeated keys are common but not universal; confirm against your API if you add array params                                |
| **Queries that inspect `error.response`**                         | Grep for `axios`, `AxiosError`, `isAxiosError`, `response?.data` after migration — should only hit the new types            |
