# Stage 1 Mutation Log

Task 4 starts this log (Task 5, covering `(libuv private native)`, appends to it).
It proves every distinct decision encoded in `src/libuv/private/conditions.sls` —
each subtype's parentage, each field's identity, and the sibling-discrimination
guarantee the design spec's condition hierarchy (`.plans/2026-08-18-chez-libuv-v0.1-design.md`
S9) depends on — has a `tests/test-conditions.sps` assertion that fails when the
decision is broken.

**Method**, applied identically to every mutation below, per the brief and
AGENTS.md's "a test is not finished until you have watched it fail":

1. `src/libuv/private/conditions.sls` was copied, once, to a scratch directory
   *outside* this repository:
   `/private/tmp/claude-501/-Users-yuzu-github-chez-libuv/22d84e17-d52b-4512-b1aa-5f906caef935/scratchpad/mutation-scratch/src/libuv/private/conditions.sls`
   (pristine backup kept alongside as `conditions.sls.pristine`). The real
   repo file was never edited during mutation testing — confirmed below.
2. Each mutation edits *only* the scratch copy, breaking exactly one decision.
3. The suite runs against the mutated scratch library, with the repo's own
   unmutated `tests/test-conditions.sps`:
   ```
   CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/tests:$REPO/build/scheme-libs" \
     chez --program "$REPO/tests/test-conditions.sps"
   ```
   Putting `$SCRATCH/src` first in `CHEZSCHEMELIBDIRS` makes Chez resolve
   `(libuv private conditions)` to the mutated scratch copy instead of the
   real one.
4. The failing test name(s) are recorded verbatim.
5. The scratch copy is restored from the pristine backup (`cp
   conditions.sls.pristine src/libuv/private/conditions.sls`), a `diff`
   against pristine confirms byte-identical, and the suite is re-run to
   confirm green before the next mutation begins. No mutation was left in
   place while another was applied.

**Baseline** (before any mutation, and reconfirmed clean after all of them):
1 suite, 89 assertions, `# of expected passes 89`, exit 0.

## Summary

| # | Category | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 1 | Subtype parentage | `&uv-errno-error` reparented under `&error` instead of `&uv-error` | FAIL, exit 1 | "errno-error is a uv-error"; "subtype relationship: uv-errno-error instance satisfies uv-error?" |
| 2 | Subtype parentage | `&uv-handle-closed` reparented under `&error` instead of `&uv-error` (the brief's own example) | FAIL, exit 1 | "handle-closed is a uv-error"; "subtype relationship: uv-handle-closed instance satisfies uv-error?" |
| 3 | Subtype parentage | `&uv-shim-unavailable` reparented under `&error` instead of `&uv-error` | FAIL, exit 1 | "shim-unavailable is a uv-error"; "subtype relationship: uv-shim-unavailable instance satisfies uv-error?" |
| 4 | Subtype parentage | `&uv-version-incompatible` reparented under `&error` instead of `&uv-error` | FAIL, exit 1 | "version-incompatible is a uv-error"; "subtype relationship: uv-version-incompatible instance satisfies uv-error?" |
| 5 | Subtype parentage | `&uv-constant-unavailable` reparented under `&error` instead of `&uv-error` | FAIL, exit 1 | "constant-unavailable is a uv-error"; "subtype relationship: uv-constant-unavailable instance satisfies uv-error?" |
| 6 | Subtype parentage | `&uv-invalid-argument` reparented under `&error` instead of `&uv-error` | FAIL, exit 1 | "invalid-argument is a uv-error"; "subtype relationship: uv-invalid-argument instance satisfies uv-error?" |
| 7 | Subtype parentage | `&uv-callback-error` reparented under `&error` instead of `&uv-error` | FAIL, exit 1 | "callback-error is a uv-error"; "subtype relationship: uv-callback-error instance satisfies uv-error?" |
| 8 | Field identity | `&uv-errno-error`'s three field accessors rotated (`errno`→code's accessor, `code`→message's, `message`→errno's) | FAIL, exit 1 | "errno-error carries the errno symbol"; "errno-error carries the raw code"; "errno-error carries the message"; "composed condition still exposes the errno field directly"; "composed condition's callback-error-cause is the original errno-error" |
| 9 | Field identity | `uv-handle-closed-kind` ignores the stored field, always returns `'tcp` | FAIL, exit 1 | "handle-closed carries the kind" |
| 10 | Field identity | `uv-shim-unavailable-path` ignores the stored field, always returns a fixed path string | FAIL, exit 1 | "shim-unavailable carries the attempted path" |
| 11 | Field identity | `&uv-version-incompatible`'s `compiled`/`runtime` accessors swapped | FAIL, exit 1 | "version-incompatible carries the compiled version"; "version-incompatible carries the runtime version" |
| 12 | Field identity | `uv-constant-unavailable-name` ignores the stored field, always returns a fixed symbol | FAIL, exit 1 | "constant-unavailable carries the constant name" |
| 13 | Field identity | `&uv-invalid-argument`'s `who`/`reason` accessors swapped | FAIL, exit 1 | "invalid-argument carries who rejected the call"; "invalid-argument carries the reason" |
| 14 | Field identity | `uv-callback-error-cause` ignores the stored field, always returns a fixed symbol | FAIL, exit 1 | "callback-error carries its cause"; "composed condition's callback-error-cause is the original errno-error" |
| 15 | Sibling discrimination | `uv-errno-error?` made an always-`#t` predicate | FAIL, exit 1 | "a bare callback-error does not satisfy uv-errno-error?"; "sibling discrimination: uv-handle-closed instance under uv-errno-error?"; "...uv-shim-unavailable..."; "...uv-version-incompatible..."; "...uv-constant-unavailable..."; "...uv-invalid-argument..."; "...uv-callback-error..." |
| 16 | Sibling discrimination | `uv-handle-closed?` made an always-`#f` predicate (rejects its own instances) | FAIL, exit 1 | "handle-closed predicate accepts its own instance"; "handle-closed carries the kind"; "sibling discrimination: uv-handle-closed instance under uv-handle-closed?" |
| 17 | Sibling discrimination (root) | `uv-error?` made an always-`#f` predicate | FAIL, exit 1 | "uv-error predicate accepts its own instance"; all 7 "\<type\> is a uv-error" tests; all 7 "subtype relationship: \<type\> instance satisfies uv-error?" tests; "composed condition also satisfies the family-wide uv-error?" |

**17/17 mutations caught**, every one by the exact assertion(s) the brief and
AGENTS.md require — the failure traces through the asserted property itself
(a predicate or accessor returning the wrong value), never through a syntax
or import error. No mutation needed a test to be strengthened after the fact.

## Coverage notes

- **All 7 non-root subtypes' parentage is mutated individually** (Mutations
  1–7), not just the brief's one named example (`&uv-handle-closed`, Mutation
  2) — `AGENTS.md`'s "every decision... gets a mutation" reads as one
  `define-condition-type` parent choice per type, and this is the module's
  foundational property: every later stage's error handling assumes
  `uv-error?` catches the whole family.
- **Field-identity mutations use swaps/rotations rather than one mutation per
  field** for the multi-field types (`&uv-errno-error`: 3 fields rotated in
  one edit, Mutation 8; `&uv-version-incompatible` and `&uv-invalid-argument`:
  2 fields swapped in one edit each, Mutations 11 and 13) — this matches the
  brief's own example ("swap two field accessors" is offered as *one*
  mutation covering two fields' identity) and each swap independently caught
  every field it touched, confirmed above. Single-field types (`kind`,
  `path`, `name`, `cause`) instead got a "return a fixed constant regardless
  of the argument" mutation, since there is nothing to swap against.
- **Mutation 8 (errno-error field rotation) and Mutation 14 (callback-error
  cause returns a fixed constant) both also failed the composed-condition
  tests**, not just the standalone round-trip tests. This is direct evidence
  that "composed condition still exposes the errno field directly" and
  "composed condition's callback-error-cause is the original errno-error"
  are not vacuous — they genuinely exercise `&uv-errno-error`'s and
  `&uv-callback-error`'s own field accessors through the compound condition
  R6RS's `condition` procedure builds, not some separate code path.
- **Mutation 15 is the brief's named sibling-discrimination example exactly**:
  making `uv-errno-error?` always `#t` is caught by "sibling discrimination:
  uv-handle-closed instance under uv-errno-error?" — a `&uv-handle-closed`
  instance wrongly satisfying `uv-errno-error?`. Because the suite's sibling
  matrix loops over the full 7×7 instances × predicates grid
  (`tests/test-conditions.sps`, `sibling-catalog`), this single mutation was
  actually caught by *six* named assertions simultaneously (one per sibling
  instance tested against the broken predicate), not only the one pair the
  brief names.
- **No decision was found to be uncovered.** Unlike chez-cmark-gfm's Stage 1
  log (which recorded several mutations the test suite could not catch, e.g.
  non-idempotent teardown), every mutation attempted here against
  `conditions.sls` was caught. This is expected for a pure condition-type
  module: there is no allocation, no ownership, no teardown ordering, and no
  I/O — the entire observable surface is "does this predicate/accessor return
  the right value for the right input," which is exactly what the brief's
  required test shapes (round-trip, field identity, subtype relationship,
  sibling discrimination, composition) already cover exhaustively.
- **The composition itself (`(condition (make-uv-callback-error cause)
  cause)`) is R6RS's own `condition` combinator, not code this library
  writes** — there is no separate "decision" in `conditions.sls` to mutate
  for the act of composing two conditions. What *is* this library's decision,
  and what the composed tests actually exercise, is that `&uv-callback-error`
  and `&uv-errno-error` are real R6RS condition types (built via
  `define-condition-type`, correctly parented) whose own predicates/accessors
  keep working when a compound condition wraps them — which Mutations 1, 7,
  8, and 14 collectively cover from every angle that matters to composition.

## Verbatim mutation transcripts

Representative full transcripts (first parentage mutation, the field-rotation
mutation, and the brief's named sibling-discrimination example); the rest
followed the identical pattern and are recorded in the summary table above.

### Mutation 1 — `&uv-errno-error` parented under `&error`

```
$ CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/tests:$REPO/build/scheme-libs" chez --program "$REPO/tests/test-conditions.sps"
%%%% Starting test conditions
FAIL errno-error is a uv-error
FAIL subtype relationship: uv-errno-error instance satisfies uv-error?
# of expected passes      87
# of unexpected failures  2
EXIT=1
```
Reverted, `diff` against pristine empty, rerun: `# of expected passes 89`, `EXIT=0`.

### Mutation 8 — `&uv-errno-error` field accessors rotated

```
$ CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/tests:$REPO/build/scheme-libs" chez --program "$REPO/tests/test-conditions.sps"
%%%% Starting test conditions
FAIL errno-error carries the errno symbol
FAIL errno-error carries the raw code
FAIL errno-error carries the message
FAIL composed condition still exposes the errno field directly
FAIL composed condition's callback-error-cause is the original errno-error
# of expected passes      84
# of unexpected failures  5
EXIT=1
```
Reverted, `diff` against pristine empty, rerun: `# of expected passes 89`, `EXIT=0`.

### Mutation 15 — `uv-errno-error?` made an always-`#t` predicate

```
$ CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/tests:$REPO/build/scheme-libs" chez --program "$REPO/tests/test-conditions.sps"
%%%% Starting test conditions
FAIL a bare callback-error does not satisfy uv-errno-error?
FAIL sibling discrimination: uv-handle-closed instance under uv-errno-error?
FAIL sibling discrimination: uv-shim-unavailable instance under uv-errno-error?
FAIL sibling discrimination: uv-version-incompatible instance under uv-errno-error?
FAIL sibling discrimination: uv-constant-unavailable instance under uv-errno-error?
FAIL sibling discrimination: uv-invalid-argument instance under uv-errno-error?
FAIL sibling discrimination: uv-callback-error instance under uv-errno-error?
# of expected passes      82
# of unexpected failures  7
EXIT=1
```
Reverted, `diff` against pristine empty, rerun: `# of expected passes 89`, `EXIT=0`.

## Final clean-tree confirmation

```
$ diff conditions.sls.pristine src/libuv/private/conditions.sls  # scratch vs its own pristine backup
IDENTICAL (no output)
$ diff conditions.sls.pristine /Users/yuzu/github/chez-libuv/src/libuv/private/conditions.sls  # pristine vs the real repo file
IDENTICAL (no output)
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-conditions.sps
%%%% Starting test conditions
# of expected passes      89
EXIT=0
$ git status --short
?? src/libuv/
?? tests/
```
The repo's own `src/libuv/private/conditions.sls` was never edited during
mutation testing — every mutation above was applied to, and reverted on, the
scratch copy outside the repository. `git status` shows only the two new
untracked paths this task adds (`src/libuv/` and `tests/`), nothing modified.

## Carried into Stage 1c (Task 5)

- Task 5 adds `(libuv private native)` and `(libuv private constants)`, the
  first modules that actually load the shim. This log's method (scratch copy
  outside the repo, mutate one decision, catch by name, revert) carries
  forward unchanged; Task 5 appends its own mutations to this same file
  rather than starting a new one.
- `&uv-callback-error`'s composed-condition contract (design spec S8,
  "store-and-reraise") is proven here only at the condition-type level —
  that composing `&uv-callback-error` with an `&uv-errno-error` cause
  satisfies both predicates and keeps both sets of fields reachable. The
  *policy* itself (storing the first callback error, deferring the rest,
  re-raising wrapped on the way out of `uv-run`) has no implementation yet;
  that lands with the trampolines in Stage 3 (Task 7), which is where a
  mutation of the actual store-and-reraise logic (e.g. re-raising the bare
  cause instead of the composed condition) will need its own test and its
  own entry in a later stage's log.
