# Profanity Filter for Review Creation — Implementation Plan

## Goal

Block users from saving a review when the review text or any dish name contains
profanity. Surface a clear, actionable toast error instead of submitting.

Applies to **both** create and edit flows, since they share
`src/components/reviews/ReviewComposerForm.tsx`.

## Approach (high level)

1. Add a profanity-filter utility (`src/utils/profanity.ts`) that exposes
   a single `containsProfanity(text: string): boolean` function. The util
   builds a combined dataset: obscenity's English preset plus a hand-curated
   French wordlist (incl. Quebec sacres) with word-boundary anchors.
2. Wire it into `ReviewComposerForm.onSave` as a new validation gate
   alongside the existing checks (uploading / failed / engaged-incomplete /
   no-content). The gate covers both create and edit screens since they
   share this form.
3. Show a toast using the same `validationToastId` pattern so the error
   replaces (rather than stacks with) other validation toasts.
4. Add unit tests covering: clean text passes, profane EN word blocks,
   profane FR word blocks, Quebec sacre blocks, l33t-speak variants caught,
   leading/trailing whitespace handled, empty input is safe.

## Library choice

**Selected: `obscenity` (npm)**

- ~16 KB gzipped, zero dependencies, MIT licensed.
- Ships an English dataset plus "recommended transformers" that handle
  common obfuscations (l33t-speak, repeated chars, leading/trailing
  punctuation): `f@ck`, `sh1t`, `fuuuck` all get caught out of the box.
- API is composable: `DataSet.addAll(englishDataset).addPhrase(...)` lets us
  layer a curated FR list (incl. Quebec sacres) onto the English defaults.

**Status:** ✅ already installed (`obscenity ~0.4.6` in `package.json`).

Alternatives considered & rejected:

| Option       | Why not                                                              |
| ------------ | -------------------------------------------------------------------- |
| `bad-words`  | Lighter (10 KB) but no l33t-speak handling; weaker default coverage  |
| Hand-rolled  | Reinvents pattern matching + transformer pipeline                    |
| Translate→EN | Translators sanitize slurs; latency, cost, privacy hit on every save |
| Server-only  | No instant feedback; defer as a hardening follow-up                  |

## Files to add / change

### New

**`src/utils/profanity.ts`**

```ts
import {
  DataSet,
  RegExpMatcher,
  englishDataset,
  englishRecommendedTransformers,
  pattern,
} from 'obscenity';

// Curated French profanity list (incl. Quebec sacres). Each entry is
// anchored with `|...|` so short words don't trip on benign substrings
// (e.g. "con" inside "control"). Accented and unaccented variants are
// listed explicitly because the recommended transformers don't normalize
// French diacritics.
const FRENCH_PROFANITY = [
  // Standard FR
  'putain',
  'merde',
  'merdique',
  'connard',
  'connasse',
  'salope',
  'salaud',
  'encule',
  'enculee',
  'enculé',
  'enculée',
  'pute',
  'putes',
  'bordel',
  'chiant',
  'chiante',
  'chier',
  'chiotte',
  'chiottes',
  'couille',
  'couilles',
  'bite',
  'nique',
  'niquer',
  'fdp',
  'foutre',
  // Quebec sacres
  'tabarnak',
  'tabarnac',
  'tabernacle',
  'calisse',
  'câlisse',
  'calice',
  'câlice',
  'crisse',
  'criss',
  'osti',
  'ostie',
  'hostie',
  'ciboire',
  'cibouère',
  'viarge',
];

// Build a combined dataset: English defaults + FR additions.
const dataset = new DataSet<{ originalWord: string }>().addAll(englishDataset);
for (const word of FRENCH_PROFANITY) {
  dataset.addPhrase((phrase) =>
    phrase.setMetadata({ originalWord: word }).addPattern(pattern`|${word}|`)
  );
}

// Singleton matcher — RegExpMatcher pre-compiles patterns at construction,
// so we pay that cost once at module load. Stateless after that.
const matcher = new RegExpMatcher({
  ...dataset.build(),
  ...englishRecommendedTransformers,
});

/** True if `text` contains profanity in English or our curated French list. */
export function containsProfanity(text: string | null | undefined): boolean {
  if (!text) return false;
  const trimmed = text.trim();
  if (trimmed.length === 0) return false;
  return matcher.hasMatch(trimmed);
}
```

The FR list is intentionally short and curated rather than imported from a
maintained list — false positives are more painful than misses for a v1
gate, and the list is easy to extend.

**`tests/unit/utils/profanity.test.ts`**

- "clean text returns false"
- "profane EN word returns true"
- "profane FR word returns true (e.g. 'putain', 'merde')"
- "Quebec sacre returns true (e.g. 'tabarnak', 'câlisse')"
- "case-insensitive across EN and FR"
- "punctuation around the word still detected (e.g. 'word!')"
- "l33t-speak variant detected for EN (e.g. 'sh1t', 'f@ck')"
- "stretched chars detected (e.g. 'fuuuck')"
- "FR word inside benign word is NOT matched (e.g. 'concombre' should pass)"
- "empty / null / whitespace-only returns false"

### Modified

**`src/components/reviews/ReviewComposerForm.tsx`**

Add to `onSave` (after the `hasContent` check, before building `dishPayload`):

```ts
// Profanity gate — runs after the structural validation above so we don't
// nag the user about wording when they haven't even completed the form yet.
// Generic message by design: we don't echo the user's profanity back or
// name the offending field.
const profaneDish = dishes.some((d) => containsProfanity(d.name));
if (containsProfanity(reviewText) || profaneDish) {
  toast.error('Please remove inappropriate language', {
    id: validationToastId,
  });
  return;
}
```

Add the import:

```ts
import { containsProfanity } from '../../utils/profanity';
```

No changes needed to `addReview.tsx` or `app/review/[id]/edit.tsx`; the gate
lives in the shared form.

### Removed (dead code cleanup)

- `app/review/create.tsx` — superseded by `addReview.tsx`. Verified no
  callers via grep.
- `<Stack.Screen name="create" />` line in `app/review/_layout.tsx` — the
  route registration for the deleted file.

Tests/comments referencing the old `/review/create` path
(`tests/unit/screens/restaurant/addReview.test.tsx`) are already asserting
the new flow does NOT navigate there, so they remain valid as-is.

### Package

✅ Already installed: `obscenity ~0.4.6`.

## Tests

1. **New utility tests** — `tests/unit/utils/profanity.test.ts` (described
   above).
2. **Form-level test** — extend
   `tests/unit/components/reviews/ReviewComposerForm.test.tsx`:
   - Type a profane review body, set rating, tap save → expect `onSubmit` is
     **not** called and toast.error fires with the validation id.
   - Type a profane dish name → same expectation.
   - Type clean text → save proceeds (regression sanity).

The existing test file already mocks `sonner-native`'s toast and the upload
hook, so adding the case is straightforward.

## Edge cases handled

- **Empty / whitespace-only** review text → `containsProfanity` short-circuits
  to `false`; doesn't produce a false positive.
- **Mixed case** ("BadWord", "bAdWoRd") → obscenity matches case-insensitively.
- **Punctuation** ("word!", "word.") → handled by obscenity's recommended
  transformers (skip non-alphabetic chars).
- **Obfuscation** ("sh1t", "f@ck", "fuuuck") → caught by the recommended
  transformers (l33t-speak, repeated-char collapse).
- **Multiple dishes** → any single offending dish blocks the save. The
  generic toast doesn't name which one (per decision 3).
- **Existing review being edited with already-saved profanity** → on edit, the
  user must clean it before saving. This is intentional.

## Decisions and open questions

1. ~~**Languages.**~~ ✅ **Decided:** English (obscenity default) + a small
   curated FR pattern set including Quebec sacres. We maintain the FR list
   inline in `src/utils/profanity.ts`.

2. ~~**Custom additions / removals.**~~ ✅ **Decided:** ship with the lists
   as-is (obscenity's English defaults + the curated FR/Quebec list above).
   Tune after seeing real false-positive reports.

3. ~~**Error UX.**~~ ✅ **Decided:** generic toast — "Please remove
   inappropriate language" with `id: validationToastId`. No echoing the
   user's profanity back, no field-level breakdown.

4. ~~**Legacy create screen.**~~ ✅ **Decided:** verify-and-delete.
   Verification done: only `app/review/_layout.tsx` declares the
   `<Stack.Screen name="create" />` route, and a single test-file comment
   references the path (asserting the new flow does NOT navigate there).
   No app code calls `router.push('/review/create')`. Safe to remove.

   **Action items:**
   - Delete `app/review/create.tsx`.
   - Remove `<Stack.Screen name="create" />` from `app/review/_layout.tsx`.

5. ~~**Server-side enforcement.**~~ ✅ **Decided:** client-only for now.
   Acknowledged tradeoff: bypassable by anyone editing the JS bundle, but
   acceptable for v1.

6. ~~**Realtime feedback vs save-time only.**~~ ✅ **Decided:** save-time
   only. No inline red border / warning while typing.

## Out of scope (proposed)

- Server-side profanity validation on `POST /spots/:id/reviews` and
  `PUT /reviews/:id`. Worth filing as a follow-up.
- Profanity filtering on usernames, comments (`CommentsModal.tsx`), spot
  search queries, or any other input. Easy to extend later by reusing the
  utility.
- Profanity-detection ML / AI models. Overkill for an MVP gate.

## Estimated effort

- Util + tests: ~30 min
- Form gate + form-test extension: ~30 min
- Legacy `app/review/create.tsx` deletion + layout update: ~5 min
- Dev-build smoke test (verify bundling, FR/EN flow): ~15 min
- Total: ~1.25 hr assuming no Metro / Hermes surprises with obscenity (it's
  a small zero-dep ESM module — should bundle cleanly).
