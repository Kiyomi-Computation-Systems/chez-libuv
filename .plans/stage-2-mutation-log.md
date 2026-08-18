# Stage 2 Mutation Log

Task 6 opens this log (Tasks 7–9 append to it). It covers the loop lifecycle
delivered in Stage 2 — `src/libuv/loop.sls`, the registry and loop-record core
of `src/libuv/private/handles.sls`, the loop entry points and callback
dispatcher slots added to `src/libuv/private/native.sls`, and the `(libuv)`
facade in `src/libuv.sls` — proving that every decision those files encode has
an assertion in `tests/test-loop.sps`, `tests/test-lifecycle.sps`, or
`tests/test-facade.sps` that fails, **by name**, when the decision is broken.

**Method**, identical to `.plans/stage-1-mutation-log.md` and to AGENTS.md's
"a test is not finished when it passes; it is finished when you have watched
it fail":

1. The four files under test were copied, once, to a scratch tree *outside*
   this repository:
   `…/scratchpad/mutation-scratch-stage2/src/{libuv.sls,libuv/loop.sls,libuv/private/handles.sls,libuv/private/native.sls}`,
   each with a `.pristine` sibling. The repo's own files were never edited
   during mutation testing — confirmed afterwards by `diff` against every
   pristine copy (all four identical) and by `git status`.
2. Each mutation edits *only* the scratch copy, breaking exactly one decision.
   The driver refuses to apply an edit whose anchor text is not unique, so no
   mutation can land somewhere other than where it was aimed.
3. The three suites run from the repo, unmutated, against the mutated library:

   ```
   CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/src:$REPO/tests:$REPO/build/scheme-libs" \
     chez --program $REPO/tests/test-loop.sps
   ```

   `$SCRATCH/src` first makes Chez resolve the mutated library there; every
   other library still resolves from `$REPO/src`.
4. The failing test names are recorded verbatim, along with the process exit
   status.
5. The scratch copy is restored from `.pristine` and all three suites are
   re-run to confirm green before the next mutation. **Every one of the 32
   mutations below was confirmed restored-green**; no mutation was ever left
   in place while another was applied.

**Baseline** (before any mutation, and reconfirmed after every one):

| Suite | Assertions | Exit |
|---|---|---|
| `tests/test-loop.sps` | 119 | 0 |
| `tests/test-lifecycle.sps` | 25 | 0 |
| `tests/test-facade.sps` | 19 | 0 |

Driver and raw output:
`…/scratchpad/mutate.py`, `…/scratchpad/mutations.json`,
`…/scratchpad/evidence/mutations.txt`.

## Summary

Failing test names are quoted verbatim from the SRFI-64 runner. Where a
mutation produced a cascade, the **first** name listed is the one that names
the broken decision; the rest are consequences and are marked as such in the
notes below the table.

| # | Decision under test | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 1 | `uv-loop-close!` deregisters the loop | `(registry-deregister! ptr)` deleted | FAIL, exit 255 | "closing deregisters the loop from the registry"; "the registry no longer resolves the closed loop's pointer"; (+5 registry-balance rows in `test-lifecycle`, 1 in `test-facade`) |
| 2 | The freeing site zeroes the stored `uptr` (design spec §10) | `(free! ptr)` and `(set-loop-ptr! loop 0)` both deleted | FAIL, exit 1 | "closing zeroes the stored loop pointer" — and *only* that one |
| 2b | `free!` itself | `(free! ptr)` deleted, zeroing kept | **NOT CAUGHT** | none — see "Uncovered" below |
| 3 | First error → pending, later errors → deferred (§8) | `loop-record-error!`'s branch test inverted | FAIL, exit 1 | "the first callback error becomes the loop's pending error"; "the first callback error is not put on the deferred list"; "a second callback error leaves the pending error alone"; "a second callback error is appended to the deferred list"; "deferred errors read back in occurrence order"; (+7 re-raise rows) |
| 4 | `uv-run` wraps the pending error in `&uv-callback-error` | re-raises the cause alone | FAIL, exit 1 | "the re-raised condition satisfies uv-callback-error?"; "the callback-error's cause is the original condition object"; "a non-condition callback raise is wrapped in &uv-callback-error alone"; "its cause is the raised object itself" |
| 4b | …**composed with** the cause, so a guard on the original type still matches (§8) | wraps without composing | FAIL, exit 1 | "the re-raised condition ALSO satisfies the original condition's own predicate"; "the compound still answers the original condition's field accessors" |
| 5 | `uv-run` returns a boolean, not `uv_run`'s int | returns `rc` | FAIL, exit 255 | "uv-run 'default on an empty loop reports no work remaining" (+ 'once, 'nowait, default-mode, and 9 teardown/drain rows) |
| 6 | `uv-loop-close!` is idempotent | `(when (eq? (loop-state loop) 'open) …)` → `(when #t …)` | FAIL, exit 1 | "closing an already-closed loop is a no-op, not an error" — and *only* that one |
| 7 | The snapshot excludes the loop's own entry by kind | kind filter dropped | FAIL, exit 255 | "a fresh loop reports no live handles (and never itself)"; "it does not appear in another loop's snapshot"; (+5 teardown rows: the sweep then hands the loop record to `close-handle!`) |
| 8 | The snapshot filters by loop backpointer | loop filter dropped | FAIL, exit 1 | "it does not appear in another loop's snapshot" — and *only* that one |
| 9 | `uv-loop-teardown!` sweeps registered handles through `close-handle!` | `for-each close-handle!` line deleted | FAIL, exit 1 | "teardown swept the loop's registered handles through close-handle!"; "the registry is back to its starting size" |
| 10 | `call-with-uv-loop` tears down in its after-thunk | after-thunk gutted | FAIL, exit 1 | "call-with-uv-loop tears the loop down on a normal return"; "the loop is torn down even when the body raises"; (+5 balance rows, +10 in `test-lifecycle`) |
| 11 | …and refuses re-entry in its before-thunk (ADR-0006 shape) | before-thunk gutted | FAIL, exit 1 | "re-entering a torn-down call-with-uv-loop raises &uv-handle-closed with kind 'loop" — and *only* that one |
| 12 | `uv-run` clears `running?` on the way out (`dynamic-wind`) | after-thunk gutted | FAIL, exit 255 | "uv-run 'once on an empty loop reports no work remaining"; "uv-run leaves the running flag clear after it returns"; (+4 rows; every later `uv-run` raised `'loop-running`) |
| 13 | `require-open-loop` raises kind `'loop` | kind changed to `'tcp` | FAIL, exit 1 | all six "use after close: … raises &uv-handle-closed with kind 'loop" rows; "a closed loop raises the re-exported &uv-handle-closed, kind 'loop" (`test-facade`) |
| 14 | `make-uv-loop` registers the loop | `registry-register!` deleted | FAIL, exit −6 (SIGABRT) | "make-uv-loop registers the loop in the handle registry"; "the registry entry resolves the loop pointer back to the loop record"; (+6 close rows, then the process aborted — see note) |
| 15 | `make-uv-loop` runs the init gate | `ensure-native-loaded!` deleted | FAIL, exit 255 | "make-uv-loop initialises the native layer itself"; (+5 rows: the constants snapshot is then absent, so `uv-run`'s mode lookup raises) |
| 16 | `make-uv-loop` bumps the `loop` counter | `count-loop-new!` deleted | FAIL, exit 1 | "seed: creating a loop moves the live loop counter"; "seed: make-uv-loop moves the live loop counter off zero" (`test-lifecycle`); (+16 balance rows) |
| 17 | `uv-loop-close!` bumps the free counter | `count-loop-free!` deleted | FAIL, exit 1 | "closing decrements the live loop counter"; "the second close did not move the live loop counter again"; (+15 balance rows) |
| 18 | `uv-run` requires an OPEN loop | `require-open-loop` → `require-loop` | FAIL, exit 1 | "use after close: uv-run raises &uv-handle-closed with kind 'loop"; "a closed loop raises the re-exported &uv-handle-closed, kind 'loop" |
| 19 | The pending error is consumed at the END of a run, never cleared at the start | added a start-of-run clear | FAIL, exit 1 | "uv-run re-raises the pending callback error on the way out" (+6 rows) |
| 20 | The deferred list IS cleared at the start of a run (§8) | start-of-run clear deleted | FAIL, exit 1 | "uv-run clears the deferred list at the START of a run" — and *only* that one |
| 21 | An uninstalled dispatcher slot raises | stub returns `'silently-ignored` | FAIL, exit 1 | all eight "an uninstalled ⟨name⟩ dispatcher raises &uv-error when invoked" rows |
| 22 | `install-callback-dispatchers!` is once-only (ADR-0008) | guard disabled | FAIL, exit 1 | "a second install is refused, naming who and why"; "the refused second install did not rebind a slot" |
| 23 | …and all-or-nothing | completeness check dropped, `for-each` made tolerant | FAIL, exit 255 | "an install missing one of the eight is refused, naming who and why"; "the refused install left the slots uninstalled" |
| 24 | `install-close-handle!` is once-only | guard disabled | FAIL, exit 1 | "a second close-handle! install is refused, naming who and why"; (+2 rows: the second install replaced the sweep probe) |
| 25 | `registry-register!` refuses a duplicate pointer | guard disabled | FAIL, exit 1 | "registering the same pointer twice is refused, naming who and why" — and *only* that one |
| 26 | `registry-register!` refuses a null pointer | guard disabled | FAIL, exit 1 | "registry-register! rejects a null pointer, naming who and why"; (+2 rows: the null entry then stayed in the table) |
| 27 | `registry-deregister!` refuses an unregistered pointer | guard disabled | FAIL, exit 1 | "deregistering an unregistered pointer is refused, naming who and why" — and *only* that one |
| 28 | The facade's `uv-version` asks libuv rather than restating a version | returns `"9.9.9"` | FAIL, exit 1 | "uv-version's string agrees with uv_version()'s major.minor" |
| 29 | `loop-record-error!` calls `uv_stop` on the first error (§8) | `uv_stop` call removed | **NOT CAUGHT** | none — see "Uncovered" below |
| 30 | `uv-run` maps `'once` / `'nowait` to their own constants | both mapped to `UV_RUN_DEFAULT` | **NOT CAUGHT** | none — see "Uncovered" below |
| 31 | `uv-loop-close!` routes `uv_loop_close`'s rc through `uv-check` | `uv-check` dropped | **NOT CAUGHT** | none — see "Uncovered" below |
| 32 | `uv-loop-teardown!` drains before closing | drain loop deleted | **NOT CAUGHT** | none — see "Uncovered" below |
| 33 | The loop's empty-pending marker is a private sentinel, not `#f` (so a callback's own `(raise #f)` survives) | reverted to `#f` as the marker, in all three places (field default, predicate, clear) | FAIL, exit 1 | "a callback that raised #f leaves the loop holding a pending error"; "the error after a #f is DEFERRED, not mistaken for the first one"; "the #f is still the pending error, not overwritten by the second"; "the re-raised condition's cause is the #f the callback raised" |
| 34 | The registry holds its entries strongly (ADR-0007) | `make-eqv-hashtable` → `make-weak-eqv-hashtable` | **NOT CAUGHT** — and cannot be, see below | none |
| 35 | …the same property, mutated where it can be observed | the registry entry stores `#f` in place of the object, so the table records the pointer but holds nothing | FAIL, exit 1 | "a loop the caller dropped is still resolvable through the registry"; "the dropped loop is still open"; "the dropped loop still runs"; "closing it through the registry restores the counter balance"; (+ 5 registry rows in `test-loop`) |

**31 of 37 mutations caught.** Of the six that were not, **five are uncovered
properties** — each recorded below with the reason and the task that will
cover it, per AGENTS.md's "write down in the mutation log that the property is
uncovered and why; leaving it silently is the exact failure this rule exists to
prevent" — and the sixth (34) is a mutation *form* that cannot discriminate for
a structural reason, with the property it aimed at covered by 35 instead.

### Notes on the cascades

- **Mutation 14 aborted the process** (`SIGABRT`) after its named assertions
  had already failed and printed. With the loop unregistered,
  `uv-loop-close!`'s `registry-deregister!` raises before `free!` runs, and a
  later close in the same suite reached macOS's allocator with a pointer whose
  bookkeeping no longer matched. The two assertions that name the broken
  decision fail *first*, and by name, which is what AGENTS.md requires; the
  abort is recorded here rather than smoothed over.
- **Mutations 2, 6, 8, 11, 20, 25 and 27 each failed exactly one assertion.**
  Those seven are the sharpest evidence in this log: the assertion is
  specific to the decision, and nothing else in 163 assertions depends on it
  by accident.
- **Mutation 34 is recorded as attempted-and-not-discriminating**, not as an
  uncovered property. Chez's weak hashtables are weak in the **key**, and the
  registry's key is the loop's `uptr` — an integer the strong-hold test
  necessarily holds itself, since it is what the test asks the registry
  *with*. The entry therefore stays reachable and the mutation changes
  nothing observable. Mutation 35 is the form that does discriminate: it
  leaves the table, the key and the entry in place and removes only the
  entry's hold on the object, which is precisely the "registry is the GC
  root" role ADR-0007 assigns it.
- Mutation 12's cascade is itself informative: with `running?` never cleared,
  every later `uv-run` raised `&uv-invalid-argument` with reason
  `'loop-running`. That is the re-entry rejection branch executing — see the
  deferral note below for why it still has no *positive* assertion.

## Newly covered at review: two properties that were relying on nothing

Both were found by the Task 6 review, and both are now assertions rather than
assumptions. They are recorded here because each had been *invisible* — no
failing mutation, and no row in the uncovered list either, which is the worse
of the two failure modes AGENTS.md names.

### The empty pending-error slot is a sentinel, not `#f` (Mutation 33)

`#f` was the loop record's "no pending error" marker, and R6RS `raise` accepts
any object — so a callback's own `(raise #f)` was stored, `uv_stop` fired with
nothing to show for it, `uv-run`'s `(when pending …)` read the slot as empty
and dropped the error **silently**, and the *next* error was then misclassified
as the first and overwrote the slot instead of being deferred. The empty marker
is now `no-pending`, a pair allocated inside `handles.sls` and `eq?` to nothing
a callback can produce; `loop-has-pending-error?` and
`clear-loop-pending-error!` are the operations, and `uv-run` tests the
predicate rather than the value's truthiness. Four assertions guard it, all
four named in the table under Mutation 33.

This is the same rule AGENTS.md states for assertions ("prefer a sentinel no
failure path produces", and "`#f` is worse: it is what a missing key returns")
applied to a data structure instead of a test.

### The registry actually holds the record (Mutations 34, 35)

ADR-0007 and design spec §5 promise that "an open handle and its stored
closures stay reachable through this table for as long as it is open, even if
the caller drops every other reference to it". Nothing asserted it, and it is
the one loop-lifecycle property in this stage that needs no handle type to
test. `tests/test-lifecycle.sps` now creates a loop inside a `let` whose
binding dies with it, keeps only the pointer (an integer, which holds nothing
alive), forces a full `(collect)`, and then asserts through the registry that
the loop is still resolvable, still open, and **still runs** — the last one
driving the real `uv_loop_t` through libuv, so a record whose pointer had been
freed underneath it could not pass. It is then closed through the recovered
record, which restores both the counter and the registry baseline.

See the note above on why Mutation 34 (a weak hashtable) cannot discriminate
here and Mutation 35 is the form that does.

## Uncovered, and why

### 1. `free!` in `uv-loop-close!` (Mutation 2b)

Deleting the `free!` while keeping the pointer zeroing leaks one `uv_loop_t`
per loop and **no assertion in any suite notices**. This is expected and is
recorded rather than papered over:

- The debug counters cannot see it. `count-loop-free!` is a separate call to
  the shim; a leak that skips `foreign-free` but still decrements the counter
  is invisible to `live-counts` by construction. Making the counter call
  *conditional* on the free would not help either — it would just move the
  same untested assumption.
- What *does* guard it is the memory gate: Linux Valgrind
  (`make test-memory`, ADR-0003's sole leak authority) and, on macOS, the
  ASan leg's use-after-free/double-free checking. This is precisely the split
  ADR-0003 sets up, and it is why the leak gate is a CI job rather than an
  assertion.
- The *zeroing* half of the same line **is** covered, by "closing zeroes the
  stored loop pointer" (Mutation 2), and that matters independently: a freed
  `uv_loop_t` does not fault when read, it answers plausibly and wrongly
  (spike FINDINGS Q1), so the zeroed slot is the only thing that makes a
  use-after-free detectable in Scheme.

### 2. `uv_stop` on the first callback error (Mutation 29)

Design spec §8 requires the loop to be stopped when the first error is
recorded. `uv_stop`'s only observable effect is on a loop that is *currently
running*, and reaching that state requires a callback that raises — which
requires a trampoline, which arrives in **Task 7**. The recording policy
either side of the `uv_stop` call (pending vs deferred, order, the re-raise)
is fully covered by Mutations 3, 4, 4b, 19 and 20; the stop itself is not.
Task 7's timer suite must assert it: a repeating timer whose callback raises
must fire exactly once more (the already-queued callbacks of that iteration)
and then `uv-run` must return, rather than looping forever.

### 3. `'once` / `'nowait` mode mapping (Mutation 30)

All three modes are indistinguishable on an **empty** loop: `uv_run` computes
`uv__loop_alive(loop)` before entering its iteration, and with no active
handles the answer is 0 for every mode, so all three return 0 immediately and
`uv-run` answers `#f`. There is no handle type in Stage 2 to make the loop
alive, so no assertion here can separate the constants. **Task 7** covers it
with a timer: a 1-hour timeout under `'nowait` must return with work
remaining and the callback un-fired ("didn't fire early", design spec §11),
while `'once` blocks until the timer is due. The constants themselves are
already known distinct — `tests/test-native.sps` asserts pairwise
distinctness over the whole snapshot — so what is uncovered is exactly the
symbol→constant wiring in `run-mode->int`, and nothing else.

### 4. `uv-check` on `uv_loop_close`'s return (Mutation 31)

`uv_loop_close` only fails when handles are still open on the loop: it
returns `-EBUSY` (spike FINDINGS Q2 measured `-16`). Stage 2 has no handle
type, so the failing branch is unreachable from a test here. **Task 7** must
assert it directly, and design spec §11 already names the shape: `'EBUSY` as
a **symbol equality**, never truthiness — open a timer, call `uv-loop-close!`
without closing it, and assert `(uv-errno-error-errno e)` is `'EBUSY`.

### 5. The teardown drain (Mutation 32)

On an empty loop the drain is a single `uv-run` returning `#f` immediately,
so deleting it changes nothing observable. Its whole purpose is to let
`close_cb` fire — `uv_close` only *starts* a close — and there is no
`close_cb` until Task 7. Note that the drain's own failure path (the
`max-drain-iterations` bound) is likewise unexercised; it exists so that a
loop that will not drain fails as a bounded, named condition rather than
hanging, per design spec §11's "failure is iteration exhaustion, never
wall-clock elapsed time".

### 6. `uv-run` re-entry rejection (no mutation; deliberately not faked)

The brief's own deferral, recorded as instructed. `uv-run` refuses a
re-entrant call (`running?` set → `&uv-invalid-argument`, who `'uv-run`,
reason `'loop-running`), and the same flag gates `uv-loop-close!` and
`uv-loop-teardown!` (design spec §8's "Illegal from inside a callback"). The
only way to reach that state honestly is from inside a callback that runs
while `uv_run` is on the stack — Task 7. The alternative would have been to
export a test-only mutator for `running?` from the public library, which is
not a thing the shipped API should carry, so it was not done.

What *is* established today: the flag is set and cleared around the run
(Mutation 12 shows that removing the clear makes every later `uv-run` raise
`'loop-running`, so the rejection branch is live and reachable), and it is
cleared by a `dynamic-wind` after-thunk, so a raise or a continuation jump
out of the extent cannot strand it. Task 7 must add the positive assertions:
`uv-run`, `uv-loop-close!` and `uv-loop-teardown!` each called from inside a
timer callback, each raising `&uv-invalid-argument` with reason
`'loop-running`.

### 7. `uv-stop!`'s effect, and the `uv-loop-alive?` transition

Both are asserted only in their trivial direction today, for the same reason
as the two above:

- `uv-stop!` is asserted to be accepted on an open loop and refused on a
  closed one; that it actually stops a *running* loop needs a callback
  (Task 7 — design spec §11 lists "stopping a loop from inside a callback" as
  a `test-loop` row, which is why that row is written here as a deferral
  rather than a passing test).
- `uv-loop-alive?` is asserted `#f` before and after a run on an empty loop.
  The `#f`→`#t`→`#f` transition requires an active handle (Task 7). A mutation
  that made `uv-loop-alive?` a constant `#f` would survive Stage 2's suites,
  and is recorded here as uncovered for exactly that reason.

## Deferred-error readability, in the shape a callback would produce it

`tests/test-loop.sps` records the errors by calling `loop-record-error!`
directly, *before* the run, because no callback exists yet. That inverts one
detail relative to real operation: with callbacks, the raises happen **during**
run *N*, the caller reads `uv-loop-deferred-errors` after run *N* returns or
re-raises, and run *N+1* clears the list. Recording them before the run means
the run that re-raises is also the run whose start-clear discards the deferred
list.

Both halves are still covered, just not in one sequence: the list is asserted
readable (contents *and* order) with no run in between, and the start-of-run
clear is asserted by Mutation 20. Task 7 should replace this with the real
shape — a timer callback that raises twice — and assert that the deferred list
is readable *after* the run that produced it.

## Verification, on both acquisition legs

| Check | Result |
|---|---|
| `make test` (`HAVE_PKG=yes`, pkg-config libuv 1.52.1) | ALL SUITES PASSED — conditions 89, facade 19, lifecycle 25, loop 119, native 136, shim-loading 19 |
| `make HAVE_PKG=no test` (vendored submodule libuv 1.52.1) | ALL SUITES PASSED — identical counts |
| `make check-purity` | green; `PURE_TESTS` is an explicit per-suite list, so the three new suites are excluded by construction (all three import `(libuv loop)` or `(libuv)`, both of which reach `(libuv private native)`) |
| `make check-pins`, `make check-help` | green |
| `make test-memory` (macOS, ASan) | all six suites pass under the ASan preload with `detect_leaks=0`. **This is not a leak claim** — LeakSanitizer is unsupported on arm64 macOS, so this leg checks use-after-free / double-free / overflow only. Leak claims come from Linux Valgrind (ADR-0003), which is where Mutation 2b's leak would be caught. |

Recorded observations (informational, not assertions):

- `uv-now` on a fresh loop: `3461016815` before a `'nowait` run and
  `3461016815` after — **delta 0**, and correct. `uv_run` updates the cached
  clock at the top of each loop *iteration*, and an empty loop never enters
  one, so the value cannot advance. This is why the assertion is written
  `>=` ("does not go backwards") rather than `>`: a strict-increase assertion
  would be asserting something libuv does not promise, and would fail on a
  fast machine rather than on a broken binding.
- `(uv-version)` = `"1.52.1"`; `uv_version()`, read from
  `(libuv private native)` for the facade's cross-check, = `78849` =
  `#x013401`. The packed integer is deliberately **not** a facade export:
  design spec §3 scopes `(libuv)` to "re-exports + `uv-version(-compatible?)`",
  and `tests/test-facade.sps` reaches the second source through a renamed
  private import so the cross-check cannot be mistaken for a public API.

## Post-v0.1 cleanup round (chore/post-v0.1-cleanup)

**`uv-loop-close!` record-update ordering — property uncovered, and why.**
Final-review triage moved `set-loop-state!` to run immediately after the
`uv-check` on `uv_loop_close`, ahead of `registry-deregister!`/`free!`: once
the native close has succeeded, nothing later can un-close it, so a raise
from a later step must not leave a record still claiming `'open` over a loop
libuv has already shut down (a retried `close!` would hand the closed loop
straight back to `uv_loop_close`). No test watches this ordering fail, and
that is recorded here rather than papered over: the window is unreachable
through the public API — by the time `uv-check` has passed, the entry is
registered and the pointer valid by construction, so `registry-deregister!`
and `free!` cannot raise — and R6RS gives a suite no seam to make an imported
`registry-deregister!` raise mid-close. The ordering is therefore asserted by
this entry and the comment at the call site, not by a mutation; any future
change that makes those steps fallible must bring the test this entry could
not.
