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
| 18 | Supertype declaration (root's own parent) | `&uv-error`'s own supertype changed from `&error` to `&warning` (`(define-condition-type &uv-error &error ...)` → `(define-condition-type &uv-error &warning ...)`, `conditions.sls` line 44) | FAIL, exit 1 | "uv-error is an R6RS &error" |

**18/18 mutations caught**, every one by the exact assertion(s) the brief and
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
- **`&uv-error`'s own supertype declaration is a separate decision from the
  seven children's parentage, and gets its own mutation (18)** — Mutations
  1–7 all break a *child's* parent (`&uv-errno-error` etc. reparented away
  from `&uv-error`); none of them touch line 44's
  `(define-condition-type &uv-error &error make-uv-error uv-error?)` itself.
  The design spec calls this out explicitly (S9 lists `&uv-error` as "root
  condition, no fields, subtype of `&error`", the *only* type in the
  hierarchy that names `&error` directly) and `conditions.sls`'s own header
  comment repeats it ("`&uv-error` itself is the only one that derives from
  `&error` directly"). Exactly one assertion guards it —
  `tests/test-conditions.sps:30`, "uv-error is an R6RS &error" — and
  Mutation 18 (changing `&uv-error`'s parent from `&error` to the sibling
  R6RS condition type `&warning`, which is not an ancestor of `&error`)
  confirms that assertion is live: it is the *only* one of 89 that fails,
  which also confirms the mutation doesn't accidentally break `uv-error?`
  itself (a type's own predicate is unaffected by what its declared parent
  is) or any child's `uv-error?` check (unaffected for the same reason) —
  the failure is isolated to exactly the property this decision governs.
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
mutation, the brief's named sibling-discrimination example, and the root's
own supertype mutation); the rest followed the identical pattern and are
recorded in the summary table above.

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

### Mutation 18 — `&uv-error`'s own supertype changed from `&error` to `&warning`

Added after review flagged that Mutations 1–7 only cover the seven
*children's* parentage, never `&uv-error`'s own declared parent (`conditions.sls`
line 44), a decision the design spec calls out by name (S9: `&uv-error` is
"the only one that derives from `&error` directly"). `&warning` is a real,
exported R6RS condition type (a sibling of `&serious`/`&error` in the
standard hierarchy, not an ancestor of it), so this is a structurally valid
`define-condition-type` parent — the failure below is semantic, not a
syntax or import error.

```
$ CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/tests:$REPO/build/scheme-libs" chez --program "$REPO/tests/test-conditions.sps"
%%%% Starting test conditions
FAIL uv-error is an R6RS &error
# of expected passes      88
# of unexpected failures  1
EXIT=1
```
Caught by name on the first attempt — no test strengthening was needed.
Reverted, `diff` against pristine empty, rerun: `# of expected passes 89`, `EXIT=0`.

## Final clean-tree confirmation

```
$ diff conditions.sls.pristine src/libuv/private/conditions.sls  # scratch vs its own pristine backup
IDENTICAL (no output)
$ diff conditions.sls.pristine src/libuv/private/conditions.sls  # pristine vs the real repo file
IDENTICAL (no output)
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-conditions.sps
%%%% Starting test conditions
# of expected passes      89
EXIT=0
$ git status --short
(clean)
```
The repo's own `src/libuv/private/conditions.sls` was never edited during
mutation testing — every mutation above, including Mutation 18 added during
review, was applied to, and reverted on, the scratch copy outside the
repository.

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

---

# Stage 1c (Task 5) — `(libuv private native)` + `(libuv private constants)`

Appended per the "Carried into Stage 1c" note above. Covers
`src/libuv/private/native.sls`, `src/libuv/private/constants.sls`, and the
constant table in `src/libuv-shim.c`, against `tests/test-native.sps` and
`tests/test-shim-loading.sps`.

**Method**, unchanged from Task 4 except where the mutation target is C:

1. `src/libuv/private/` was copied, once, to a scratch directory *outside*
   this repository:
   `/private/tmp/claude-501/-Users-yuzu-github-chez-libuv/22d84e17-d52b-4512-b1aa-5f906caef935/scratchpad/mut5/src/libuv/private/`
   (pristine backup alongside in `.../mut5/pristine/`).
2. Each mutation edits *only* the scratch copy, breaking exactly one decision.
3. The suite runs against the mutated scratch library with the repo's own
   unmutated tests, scratch first on the library path:
   ```
   CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/tests:$REPO/build/scheme-libs" \
     chez --program "$REPO/tests/test-native.sps"
   ```
4. Failing test names recorded verbatim; scratch restored from pristine;
   `diff` confirms byte-identical before the next mutation.
5. **C-side mutations** (M45, M46) cannot use that mechanism — the shim is a
   compiled artifact, not a library on `CHEZSCHEMELIBDIRS`. `src/libuv-shim.c`
   was copied to scratch, mutated, compiled with the Makefile's own
   `CFLAGS_DEV` line into `$SCRATCH/lib/libchezlibuv-*.dylib`, and selected at
   runtime via `CHEZ_LIBUV_SHIM`. The repo's own shim was never rebuilt from
   mutated source.

**Baseline** (before any mutation, reconfirmed after all of them):
`test-native` 123 assertions, `test-shim-loading` 19, both exit 0. The review
round below (M51–M55) raises `test-native` to **136**.

## Summary

| # | Target | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 19 | constants.sls | Errno snapshot: `EACCES`'s symbol→value entry bound to the *next* index's value (a two-entry swap) | FAIL, exit 1 | "no two errno names share a value on this platform"; "every errno symbol round-trips symbol -> value -> symbol"; "the snapshot agrees with uv_err_name_r for every errno value" |
| 20 | native.sls | Version ceiling `(<= v hi)` → `(< v hi)` | FAIL, exit 1 | "version-supported? accepts the ceiling of the configured range"; "version-compatible? accepts a compiled/runtime pair at the ceiling"; "…accepts a runtime ahead of the compiled version, both in range" |
| 21 | native.sls | Version floor `(>= v lo)` → `(> v lo)` | FAIL, exit 1 | "version-supported? accepts the floor of the configured range"; "version-compatible? accepts a compiled/runtime pair at the floor"; "…accepts a runtime ahead of the compiled version, both in range" |
| 22 | native.sls | Version ceiling widened by one: `(<= v hi)` → `(<= v (+ hi 1))` — the brief's `<=`-where-`<` off-by-one, in the permissive direction | FAIL, exit 1 | "version-supported? rejects one above the ceiling"; "version-compatible? rejects a runtime above the ceiling" |
| 23 | native.sls | `version-compatible?` drops the `compiled` half, checking only `runtime` | FAIL, exit 1 | "version-compatible? rejects a compiled version below the floor" |
| 24 | native.sls | **The 0-is-truthy trap**: `uv-check`'s `(if (zero? rc) …)` → `(if rc …)`, so it never raises at all | FAIL, exit 1 | "uv-check raises uv-errno-error on a negative return code"; "the raised condition carries the errno as a symbol"; "…preserves the raw return code"; "…carries uv_strerror_r's message"; "…names the calling procedure via &who"; "…is also a uv-error"; "uv-check raises with 'UV_UNKNOWN for an unmapped negative code" |
| 25 | native.sls | `uv-check` inverted: raises on 0, passes everything else through | FAIL, exit 1 | "uv-check passes a zero return code straight through" + the seven from M24 |
| 26 | native.sls | `uv_buf_t` ftype field order swapped to the Windows/WSABUF layout `(len base)` | FAIL CLOSED at init, exit 255 (see note) | uncaught `&uv-shim-unavailable: "…/libchezlibuv.dylib"` |
| 26b | native.sls | M26 **plus** the layout validation removed from `ensure-native-loaded!` | FAIL, exit 1 | "the uv_buf_t ftype's base offset matches the shim's offsetof"; "…len offset matches the shim's offsetof"; "…base field fills the space before len"; "…len field fills the rest of the struct"; "the base pointer is readable at the shim's offsetof(uv_buf_t, base)" |
| 27 | native.sls | `uv_buf_t` ftype `len` narrowed to `unsigned-32` + explicit `pad` (size and *both* offsets stay correct) | FAIL CLOSED at init, exit 255 | uncaught `&uv-shim-unavailable: "…/libchezlibuv.dylib"` |
| 27b | native.sls | M27 **plus** the layout validation removed | FAIL, exit 1 | "the uv_buf_t ftype's len field fills the rest of the struct" — **the only** assertion of 123 that catches it |
| 28 | native.sls | `(validate-uv-buf-layout!)` deleted from `ensure-native-loaded!`, ftype left correct | **PASS, 123/123 — UNCAUGHT** | (see coverage note) |
| 29 | native.sls | `resolve-shim-path` drops the `absolute-path?` test | **First run: PASS, 93/93 — UNCAUGHT.** After the suite and the code were fixed: FAIL, exit 1 | "resolve-shim-path rejects a relative override even when it names an existing regular file"; "…rejects a relative default path even when it names an existing regular file" |
| 30 | native.sls | `regular-file?` drops `file-regular?`, accepting directories | FAIL, exit 1 | "resolve-shim-path rejects a directory given as an override, naming it"; "…rejects a directory as the default path" |
| 31 | native.sls | `load-shim`'s guard removed — a raw dlopen error escapes | FAIL, exit 1 | "load-shim wraps a real dlopen failure in uv-shim-unavailable, carrying the path" |
| 32 | native.sls | `c-string->string` maps NULL to `""` instead of `#f` | FAIL, exit 1 | "c-string->string maps NULL to #f" |
| 33 | native.sls | `zero-out!` body deleted (no-op) | FAIL, exit 1 | "zero-out! clears every byte it was given" |
| 34 | native.sls | `zero-out!` off-by-one: `(< i len)` → `(<= i len)` | FAIL, exit 1 | "zero-out! does not write past the length it was given" |
| 35 | native.sls | `alloc-zeroed` drops its `zero-out!` call | **First run: PASS, 96/96 — UNCAUGHT.** After the test was fixed: FAIL, exit 1 | "alloc-zeroed returns zeroed memory even when the allocator hands back a dirty block" |
| 36 | native.sls | `free!` accepts a null pointer | FAIL, exit 1 | "free! rejects a null pointer instead of passing it to the allocator" |
| 37 | native.sls | `copy-in!` ignores the `start` offset | FAIL, exit 1 | "copy-in! copies the requested span, honouring start"; "copy-out copies: mutating the foreign source afterwards leaves the result unchanged" |
| 38 | native.sls | `copy-in!` span bounds check replaced with `#t` | FAIL, exit 1 | "copy-in! rejects a span that runs past the end of the bytevector" |
| 39 | native.sls | `copy-out` null-source check removed | FAIL, exit 1 | "copy-out rejects a null source" |
| 40 | constants.sls | `constants-init!`'s double-init guard removed | **First run: PASS, 97/97 — UNCAUGHT.** After the test was added: FAIL, exit 1 | "a direct second constants-init! is a no-op and never consults its lookups" |
| 41 | native.sls | `ensure-native-loaded!`'s `unless initialized?` guard removed | FAIL, exit 1 | "further calls do not re-run the initialiser body" |
| 42 | constants.sls | `errno-value->symbol`'s fallback returns `#f` instead of `'UV_UNKNOWN` | FAIL, exit 1 | "an unmapped errno value falls back to 'UV_UNKNOWN"; "uv-check raises with 'UV_UNKNOWN for an unmapped negative code" |
| 43 | constants.sls | `constant-ref` returns `#f` for a missing name instead of raising | FAIL, exit 1 | "a constant name the shim does not define raises uv-constant-unavailable"; "the raised condition names the missing constant" |
| 44 | native.sls | **Load ORDER broken**: the shim loaded *before* libuv | **PASS, 123/123 — UNCAUGHT ON macOS** (see the honest note below) | — |
| 44b | native.sls | The explicit libuv load removed *entirely* | **PASS, 123/123 — UNCAUGHT ON macOS** | — |
| 45 | **libuv-shim.c** | `SIZEOF_UV_TIMER_T` deleted from the shim's constant table, shim rebuilt | FAIL CLOSED at init, exit 255 | uncaught `&uv-constant-unavailable: SIZEOF_UV_TIMER_T` — **ADR-0005's mutation-testability claim, demonstrated** |
| 46 | **libuv-shim.c** | `chez_uv_errno_count()` overreports by one, shim rebuilt | FAIL CLOSED at init, exit 255 | uncaught `&uv-constant-unavailable: UV_ERRNO_INDEX_85` |
| 47 | native.sls | Counter cross-wiring: `count-timer-new!` bound to `chez_uv_count_tcp_new` | FAIL, exit 1 | "counter timer: increments are visible (seeded non-zero)"; "counter timer: no other class moved"; "counter timer: decrements return it to zero"; "counter write-req/connect-req/read-buffer: no other class moved"; "every counter is back at its baseline afterwards" |
| 48 | native.sls | `live-counts`' `timer` slot reads `chez_uv_live_tcp` | FAIL, exit 1 | "counter tcp: no other class moved"; "counter timer: increments are visible (seeded non-zero)" |
| 49 | native.sls | `uv-req-size` bound to `uv_handle_size` | FAIL, exit 1 | "uv_req_size(UV_WRITE) agrees with the shim's sizeof(uv_write_t)"; "…UV_CONNECT…"; "…UV_SHUTDOWN…" |
| 50 | constants.sls | `uv-timer-type` accessor reads the `UV_TCP` key | FAIL, exit 1 | "uv_handle_size(UV_TIMER) agrees with the shim's sizeof(uv_timer_t)"; "the tcp and timer handle type tags are distinct" |

**30 of 32 mutations caught** (M19–M50, counting 26b/27b/44b); with the review
round below, **35 of 37**. Three were
uncaught on the first attempt and are recorded as such above — each produced a
real fix, described below. Two remain uncaught by design, both named and
explained rather than left silent.

## The three that were NOT caught on the first attempt

AGENTS.md's point, in three concrete instances. None of these would have been
discovered by reading the code.

### M29 — `resolve-shim-path`'s absoluteness check was untested *and* half missing

The suite asserted that `"relative/path.dylib"` is rejected. It is — but by
the `regular-file?` check, since no such file exists. Deleting the
`absolute-path?` test entirely left all 93 assertions passing. The genuinely
discriminating input is a relative path that **does** resolve under the working
directory, which is exactly design spec S4 rule 1's "the working directory is
never consulted".

Two changes followed:

- `tests/test-native.sps` gained "resolve-shim-path rejects a relative override
  even when it names an existing regular file", using `"Makefile"` — preceded
  by a seed assertion that the probe really does name an existing file, so a
  different working directory fails loudly instead of passing vacuously.
- **`native.sls` was fixed, not just the test.** The original (inherited from
  `chez-cmark-gfm`) applied `absolute-path?` only to the *override* branch; the
  default path from generated `config.sls` was accepted on `regular-file?`
  alone. The spec requires absoluteness of both, and the generated path only
  satisfied it because the Makefile uses `$(abspath …)` — true by construction,
  not by enforcement. `resolve-shim-path` now validates one `candidate`
  uniformly, and a second assertion covers the default branch.

### M35 — `alloc-zeroed`'s zeroing was untested because macOS zeroes small blocks

The original test churned 64 dirty 128-byte blocks, freed them, then asserted
`alloc-zeroed` returned clean memory. Dropping the zeroing entirely still
passed. Direct measurement (`scratchpad/probe/dirty.ss`) explains why:

```
size 16:    dirty bytes across 64 reallocs = 0
size 64:    dirty bytes across 64 reallocs = 0
size 128:   dirty bytes across 64 reallocs = 0
size 1072:  dirty bytes across 64 reallocs = 61248
size 65536: dirty bytes across 64 reallocs = 3932160
```

macOS routes allocations up to ~256 bytes through the *nano* zone, which hands
them back already zeroed — so the test could not fail. The churn size is now
`(sizeof-uv-loop-t)` (1072 here): above the nano zone, and the size the binding
actually allocates at. Crucially, a **seed assertion** was added — "seed: a
plain foreign-alloc really does hand back dirty memory at this size" — so on
any future platform whose allocator always zeroes, *that* assertion fails by
name and announces the next one is non-discriminating, instead of the
non-discrimination being silent. This is the "write down that the property is
uncovered" rule turned into a runtime check.

> **Amended 2026-08-18 (final review, CI run 4).** Real Valgrind runs showed
> the seed itself failing there, root-caused as unobservable by design:
> Memcheck's own freelist (`--freelist-vol`, ~20MB by default) exists
> specifically to delay reusing a freed block, so it can still flag a
> use-after-free against it — no warm-up depth lets an alloc-after-free
> observe the just-freed block's leftover bytes under Memcheck, because
> keeping that memory from being served back immediately is the whole point
> of the mechanism. The seed is now environment-aware: `make test-memory`'s
> Linux leg sets `CHEZ_LIBUV_UNDER_VALGRIND=1`, and under it the seed drops
> to a weak form (fill a fresh block with `#xff`, assert the bytes read back
> `#xff`) that proves the fill/read-back machinery works but nothing about
> allocator dirt — so **under Valgrind, M35's mutation (`alloc-zeroed`
> skipping its `zero-out!` call) is undetectable by this seed's line of
> reasoning.** That is not a coverage gap in practice: detection is carried
> by the plain `make test` runs, which exercise this exact suite on both CI
> jobs and locally with the strong (recycled-dirt) form intact. This is
> ADR-0003's own division of labor made explicit for this one test: the
> Valgrind leg's job is leaks and addressability, not mutation coverage.

### M40 — `constants-init!`'s own guard was shadowed by `ensure-native-loaded!`'s

Removing the double-init guard from `constants-init!` changed nothing
observable: `ensure-native-loaded!`'s guard short-circuits first, so
`constants-init!` is never called twice through the normal path. The fix
exploits the deliberate dependency inversion in `constants.sls` (it takes its
lookup procedures as *arguments* rather than importing the FFI): the new test
calls `constants-init!` directly a second time, handing it four procedures that
**raise if consulted**. With the guard present the call is a no-op; without it,
the lookup fires and the assertion fails. The expected value is `1` (the init
count), never `#f`, so SRFI-64's exception-to-`#f` behaviour cannot mask it.

## The two that remain uncaught, and why

### M44 / M44b — the load-order invariant is invisible on macOS

**Recorded truthfully: on this machine, loading the shim before libuv passes
123/123, and removing the explicit libuv load entirely also passes 123/123.**

The cause is measurable rather than speculative:

```
$ otool -L build/lib/libchezlibuv.dylib
	/opt/homebrew/opt/libuv/lib/libuv.1.dylib (compatibility version 1.0.0, …)
```

macOS's dyld resolves a dylib's own recorded dependencies transitively, so
`uv_*` entry points are available to `foreign-procedure` as soon as the shim is
loaded, whatever order the two `load-shared-object` calls happen in. On Linux a
`dlopen`'d object's dependencies are **not** placed in the global symbol
namespace, so the same mutation fails at *import* time with
`Exception in foreign-procedure: no entry for "uv_version"` (spike
`FINDINGS.md` Q0 records that exact text; `chez-cmark-gfm`'s CI hit the
identical failure — green on macOS, red on Linux — which is why the explicit
load exists at all).

**Linux CI is the real guard for this invariant, and it is the only one.** No
assertion in `tests/test-native.sps` can cover it on a Darwin runner; this is a
property of the platform loader, not of the test suite. `.github/workflows/ci.yml`
runs both platforms, so the invariant is enforced — but the enforcement lives
there, not here, and a macOS-only development loop will not notice a
regression. Re-verify on Linux before trusting any change to the ordering of
`uv-loaded` / `shim-loaded` in `native.sls`.

### M28 — deleting the layout validation is invisible while the layout is right

Removing `(validate-uv-buf-layout!)` from `ensure-native-loaded!` passes
123/123, because on this platform the declared ftype and the real `uv_buf_t`
*do* agree — there is nothing for the check to catch. That is the nature of a
fail-closed guard: it is unobservable exactly when the condition it guards
against does not hold.

It is not, however, an untested decision. M26 and M27 mutate the ftype so the
condition *does* hold, and the pair of runs isolates the two properties
cleanly:

- **with** the validation in place, both mutations abort initialisation with
  `&uv-shim-unavailable` carrying the shim path, exit 255, before a single
  assertion runs — the guard fires;
- **without** it (M26b/M27b), the suite proceeds and the layout assertions fail
  by name — the suite notices.

Together those establish both halves. M27b is worth singling out: the narrowed
`len` field keeps `ftype-sizeof` at 16 and *both* offsets correct, and is caught
by exactly one assertion out of 123 — "the uv_buf_t ftype's len field fills the
rest of the struct". That is the field-width half of the layout check earning
its place; the offset comparisons alone would have missed a `uv_buf_t.len`
truncated to 32 bits, which is the write-side twin of the `ssize_t`/`size_t`
corruption spike `FINDINGS.md` Q3 measured on the read side.

## ADR-0005, demonstrated rather than asserted

[ADR-0005](decisions/0005-constants-are-never-transcribed.md) claims its policy
is "directly mutation-testable: deleting or corrupting a single table entry must
make one specific, predictable test fail by name, not merely 'some test
somewhere'." M45 and M46 are that demonstration, against the compiled C artifact
rather than a Scheme stand-in:

```
$ perl -0pi -e 's/  \{ "SIZEOF_UV_TIMER_T",    \(long\)sizeof\(uv_timer_t\) \},\n//' $SCRATCH/libuv-shim.c
$ cc -std=c99 -Wall -Wextra -Werror … -o $SCRATCH/lib/libchezlibuv-mutant.dylib $SCRATCH/libuv-shim.c -luv
$ CHEZ_LIBUV_SHIM=$SCRATCH/lib/libchezlibuv-mutant.dylib chez --program tests/shim-load-probe.sps
Exception occurred with condition components:
  0. &uv-constant-unavailable: SIZEOF_UV_TIMER_T
PROBE EXIT=255
```

```
$ perl -0pi -e 's/  return \(int\)CHEZ_UV_ERRNO_COUNT;/  return (int)CHEZ_UV_ERRNO_COUNT + 1;/' $SCRATCH/libuv-shim.c
$ CHEZ_LIBUV_SHIM=$SCRATCH/lib/libchezlibuv-count.dylib chez --program tests/shim-load-probe.sps
Exception occurred with condition components:
  0. &uv-constant-unavailable: UV_ERRNO_INDEX_85
PROBE EXIT=255
```

Both name the exact missing thing — the constant, and the index at which the
shim's own count and table came apart — and both fail *before* any handle can
exist. The complementary Scheme-side assertion, "the raised condition names the
missing constant", covers the same mechanism for a name that was never in the
table (M43).

## Coverage notes

- **The version boundary is mutated in three directions**, not one: too strict
  at the floor (M21), too strict at the ceiling (M20), too permissive at the
  ceiling (M22). The brief asked for the `<=`-where-`<` off-by-one; M22 is that
  mutation, and M20/M21 confirm the accept-side assertions are not vacuous.
- **M24 is the `0`-is-truthy trap head on.** `(if rc rc (raise …))` makes
  `uv-check` never raise, because every integer including `0` is true in
  Scheme. It is caught by seven named assertions, all of which compare the
  errno **symbol** against an expected value with `'no-raise` as the no-raise
  sentinel. Had any of them expected `#f`, SRFI-64's
  exception-to-`#f` behaviour would have made both the mutant and a correct
  implementation pass.
- **Cross-wiring gets its own mutations (M47–M50)** because this file binds
  eighteen near-identically-named shim entry points and four near-identical
  size accessors. A suite exercising one counter class would not have noticed
  `count-timer-new!` wired to `chez_uv_count_tcp_new`; the six-class loop with
  a "no other class moved" assertion per class does, from both sides (the
  increment M47 and the read M48).
- **The errno mapping is checked against two independent sources.** M19's
  entry swap is caught not only by the round-trip over the whole enumeration
  but by "the snapshot agrees with uv_err_name_r for every errno value" — the
  shim's compiled `UV_ERRNO_MAP` snapshot versus the running library's own
  `uv_err_name_r`. A self-consistent-but-wrong table fails the second even
  where it would satisfy the first.
- **An assertion caught a real mistake in the tests themselves.** "the probe
  code used for the unknown-errno case really is unmapped" failed on the first
  GREEN run: the obvious probe `UV_EOF + 1` is *not* unmapped — libuv reserves
  `-4094` for its own `XX(UNKNOWN, …)` entry, which the shim exports under the
  bare name `"UNKNOWN"`. The probe is now `UV_EOF - 1`, and libuv's own
  `UNKNOWN` errno has its own assertion so it stays distinct from the
  binding's `'UV_UNKNOWN` fallback. This is why the probe's absence is checked
  rather than assumed.
- **`shim-file`, `native-initialized?`, and `constants-initialized?` are
  covered by seeded before/after pairs** rather than a bare after-the-fact
  assertion: each flag is captured *before* the first `ensure-native-loaded!`
  call and asserted false, then asserted true afterwards, so a predicate stuck
  at either value fails.

## Scope added during Task 5

Two shim/API additions were made rather than leaving an untested binding:

- `UV_WRITE`, `UV_CONNECT`, `UV_SHUTDOWN` were added to `src/libuv-shim.c`'s
  constant table (ADR-0005's "adding a constant this binding needs later means
  adding one table entry"). Without them `uv_req_size()` — which the brief
  requires binding — had no argument to be called with, and would have shipped
  as an exported, untested, unusable procedure. With them it is checked against
  `sizeof(uv_write_t)`/`sizeof(uv_connect_t)`/`sizeof(uv_shutdown_t)` exactly
  as `uv_handle_size()` is checked against the handle sizes (spike
  `FINDINGS.md` Q-1 finding 1), and M49 confirms those assertions are live.
- The Makefile's `PURE_TESTS` comment claimed a new pure suite would be picked
  up automatically. It would not — the wildcard names one literal file. The
  comment now states the real rule (adding a pure suite is a deliberate edit,
  and "not pure" is the default for a new suite), which matters because
  `test-native.sps` and `test-shim-loading.sps` must never appear there.
  `make check-purity` confirmed unchanged behaviour on both acquisition legs.

## Final clean-tree confirmation

```
$ diff -r $SCRATCH/pristine/libuv $SCRATCH/src/libuv
IDENTICAL (no output)
$ make test
=== tests/test-conditions.sps ===   # of expected passes  89
=== tests/test-native.sps ===       # of expected passes 123
=== tests/test-shim-loading.sps === # of expected passes  19
ALL SUITES PASSED
$ make check-purity
purity holds: tests/test-conditions.sps pulled in no native code
$ make HAVE_PKG=no test
=== tests/test-conditions.sps ===   # of expected passes  89
=== tests/test-native.sps ===       # of expected passes 123
=== tests/test-shim-loading.sps === # of expected passes  19
ALL SUITES PASSED
```

The repo's own `src/libuv/private/*.sls` and `src/libuv-shim.c` were never
edited during mutation testing — every mutation above was applied to, and
reverted on, the scratch copies outside the repository. The three code changes
this task made in the repo (`resolve-shim-path`'s uniform absoluteness check,
the three `uv_req_type` shim constants, and the `PURE_TESTS` comment) were
deliberate fixes, each covered above.

## Review round: five further mutations (M51–M55)

Added after task review flagged an unguarded `zero-out!`, an expected-`#f`
assertion, an unexercised raise arm, and an unnamed suite precondition. Same
method; baseline after the fixes is **136 assertions** in `test-native`.

| # | Target | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 51 | native.sls | `zero-out!`'s null-destination check removed — `(zero-out! 0 64)` writes through NULL | FAIL, exit 1 | "zero-out! rejects a null destination" |
| 52 | native.sls | `zero-out!`'s length validation removed (null check kept) | FAIL, exit 1 | "zero-out! rejects an inexact length"; **"zero-out! wrote nothing before rejecting"**; "zero-out! rejects a negative length" |
| 53 | native.sls | `check-version-compatible!`'s payload swapped: `(make-uv-version-incompatible runtime compiled)` | FAIL, exit 1 | "the raised condition carries the COMPILED version in its compiled field"; "…the RUNTIME version in its runtime field"; "an out-of-range compiled version with an in-range runtime still raises, payload intact" |
| 54 | native.sls | `check-version-compatible!`'s raise arm removed (always returns `runtime`) | FAIL, exit 1 | "check-version-compatible! raises uv-version-incompatible for an out-of-range pair" + the three payload assertions + "the raised condition is also a uv-error" |
| 55 | **libuv-shim.c build** | The suite run against a **production** shim (`-O2`, no `CHEZ_LIBUV_DEBUG_COUNTERS`), i.e. the counters compiled to no-ops | FAIL, exit 1 | **"seed: this suite requires the debug-counter shim (a live query must move)" fails FIRST**, ahead of the six per-class failures it explains |

**5/5 caught.** Notes:

- **M51 does not crash.** Chez signals an invalid memory reference for
  `foreign-set!` at address 0 rather than letting the process die, so SRFI-64
  folds it and the assertion fails by name — predicted to be a bare SIGSEGV,
  measured to be a clean named failure. Either way the check is the difference
  between a structured `&uv-invalid-argument` and an unhandled fault, which is
  what the surrounding group's contract promises.
- **M52 is the ordering mutation.** An inexact length is what discriminates:
  `(< i 3.0)` is perfectly true, so an unvalidated `zero-out!` zeroes three
  bytes and only then fails to complain. "zero-out! wrote nothing before
  rejecting" is the assertion that proves the guard runs *ahead of* the loop
  rather than merely existing; a negative length alone would have been vacuous,
  since the loop writes nothing for it either way.

  > **Superseded 2026-09-28 (#35).** `zero-out!` is now one `memset` through
  > the shim. Chez's `size_t` argument conversion refuses 3.0 before C runs,
  > so M52 now fails only "rejects an inexact length" and "rejects a negative
  > length". "wrote nothing before rejecting" holds by construction.
  >
  > The check-before-call order is pinned by those two rows' who instead. It
  > still fails if `zero-out!` goes back to a Scheme loop that writes before
  > it validates. `.plans/bulk-copy-mutation-log.md` (M52, M52x) has the runs.
- **M53 is the mutation the review predicted would be uncaught, and was.**
  Before this round the `&uv-version-incompatible` raise arm lived inline in
  `ensure-native-loaded!`, where it runs zero times per process against a
  matching shim. Extracting it as the exported `check-version-compatible!` —
  the same seam that already makes `resolve-shim-path` and `load-shim`
  testable — is what makes the payload assertable at all. The two probe
  versions are distinct and both out of range, so a swap cannot hide behind
  two same-typed integer fields; M53 confirms both field assertions are live.
- **M55 is a build-configuration mutation, not a source one.** The six
  per-class counter assertions hard-require the dev shim, and against a prod
  shim they fail saying "increments are visible" — which reads as cross-wiring
  that is not there. The new seed assertion fails *first* and names the actual
  cause. (The run also fails "the shim this process loaded is the one
  config.sls names", correctly: the probe supplies an override.)

## Carried into Stage 2 (Task 6)

- The load-order invariant (M44) has **no macOS-observable test**. Any Task 6+
  change touching the `uv-loaded` / `shim-loaded` definitions in `native.sls`
  must be verified on Linux CI before it is trusted.
- `uv-check` raises on **any** non-zero return code. `uv_run` legitimately
  returns a positive value ("handles still active"), so Task 6's `uv-run`
  must interpret its own result and call `uv-check` only where the C contract
  is "0 or negative errno". A mutation confirming that distinction belongs in
  Stage 2's log.
- The eight callback trampolines, `lock-object`, and `foreign-callable` are
  **not** in `native.sls` yet — design spec S4 places them here, but Task 5
  binds only what it tests. They arrive with Stage 3 (Task 7), along with the
  store-and-reraise mutations Task 4's log deferred.

## Post-v0.1 cleanup round (chore/post-v0.1-cleanup)

Final whole-branch review triage: `copy-in!`/`copy-out` tested `(exact? x)`
before `(integer? x)` in their span/length checks — inconsistent with
`zero-out!`'s safe order, and `exact?` on a non-number raises a bare Chez
`&assertion` instead of the structured `&uv-invalid-argument`. Here the
"mutation" IS the pre-cleanup code: the two new rows were added first and
watched fail against it, then the order was swapped and both watched pass.

| # | Target | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 56 | native.sls | `copy-in!`/`copy-out` span checks in the pre-cleanup order (`exact?` before `integer?`); probed with a symbol span argument | FAIL, exit 1 | "copy-in! rejects a non-numeric start as a structured condition, not a bare assertion"; "copy-out rejects a non-numeric length as a structured condition, not a bare assertion" |

**Red evidence:** both rows answered `wrong-condition` (the escaping bare
assertion) against the pre-swap code, 170 passes + 2 unexpected failures;
after the swap, 172 passes, exit 0.

**`&uv-libuv-unavailable` (the libuv-leg subtype), same cleanup round.**
Baseline after the change: 94 conditions / 175 native / 24 shim-loading / 41
facade assertions, all green on both acquisition legs.

| # | Target | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 57 | conditions.sls | `&uv-libuv-unavailable` re-parented from `&uv-shim-unavailable` to `&uv-error` (a sibling with its own path field, i.e. the hierarchy decision reversed) | FAIL, exit 1 | "libuv-unavailable IS a shim-unavailable: existing guards keep matching"; "libuv-unavailable carries the attempted path through the inherited accessor" |
| 58 | native.sls | `uv-loaded` wired with the parent maker (the pre-cleanup mislabeling — this IS the state the rows were watched red against before implementation) | FAIL, exit 1 | "a bad libuv path: raises uv-libuv-unavailable, the subtype, not the shim's own type" (tests/test-shim-loading.sps, via a synthetic config.sls shadowing the generated one; its two positive-control rows passed in the same run, so the failure is the label, not the machinery) |

M57 ran against a scratch copy (restored-green confirmed, diff-identical to
the repo file). M58's evidence is the watched-red run itself: the wiring
mutation and the pre-implementation code are the same text.
