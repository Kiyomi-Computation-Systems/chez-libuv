# Stage 3 Mutation Log

Task 7 opens this log (Tasks 8–9 append to it). It covers the timer stage —
`src/libuv/timer.sls`, `src/libuv/handle.sls`, the handle records, callback
guard, dispatchers and close protocol added to
`src/libuv/private/handles.sls`, the eight static trampolines and the timer /
close entry points added to `src/libuv/private/native.sls`, the teardown
error policy in `src/libuv/loop.sls`, and the `(libuv)` facade's new
re-exports — proving that every decision those files encode has an assertion
in `tests/test-timer.sps`, `tests/test-lifecycle.sps`, `tests/test-loop.sps`,
`tests/test-facade.sps` or `tests/test-native.sps` that fails, **by name**,
when the decision is broken.

**Method**, identical to `.plans/stage-1-mutation-log.md` and
`.plans/stage-2-mutation-log.md`, and to AGENTS.md's "a test is not finished
when it passes; it is finished when you have watched it fail":

1. The six files under test were copied, once, to a scratch tree *outside*
   this repository:
   `…/scratchpad/stage3/mutation-scratch-stage3/src/{libuv.sls,libuv/loop.sls,libuv/handle.sls,libuv/timer.sls,libuv/private/handles.sls,libuv/private/native.sls}`,
   each with a `.pristine` sibling. The repo's own files were never edited
   during mutation testing.
2. Each mutation edits *only* the scratch copy, breaking exactly one
   decision. The driver refuses to apply an edit whose anchor text is not
   unique, so no mutation can land somewhere other than where it was aimed.
3. The five suites run from the repo, unmutated, against the mutated library:

   ```
   CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/src:$REPO/tests:$REPO/build/scheme-libs" \
     chez --program $REPO/tests/test-timer.sps
   ```

   `$SCRATCH/src` first makes Chez resolve the mutated library there; every
   other library still resolves from `$REPO/src`.
4. The failing test names are recorded verbatim, with the process exit
   status. A 120 s per-suite cap turns a mutation that hangs into a recorded
   `TIMEOUT` rather than a stuck run (Mutation 10 is the one that hit it).
5. The scratch copy is restored from `.pristine` and all five suites are
   re-run to confirm green before the next mutation. **Every one of the 25
   in-process mutations below was confirmed restored-green**; no mutation was
   ever left in place while another was applied.

Mutation 1 is different in kind and is run separately, through a subprocess
probe — see its own section.

**Baseline** (before any mutation, and reconfirmed after every one):

| Suite | Assertions | Exit |
|---|---|---|
| `tests/test-timer.sps` | 136 | 0 |
| `tests/test-lifecycle.sps` | 41 | 0 |
| `tests/test-loop.sps` | 101 | 0 |
| `tests/test-facade.sps` | 30 | 0 |
| `tests/test-native.sps` | 160 | 0 |
| `tests/test-conditions.sps` | 89 | 0 |
| `tests/test-shim-loading.sps` | 19 | 0 |

Driver, mutation set, and raw output:
`…/scratchpad/stage3/{mutate3.py,mutations3.json,mutations-final.txt,results3.json}`,
probe at `…/scratchpad/stage3/probe/guard-probe.sps`.

Two suites changed shape this stage, and both changes are themselves a
consequence of a Stage 3 decision:

- **`test-loop.sps` lost 18 assertions and `test-native.sps` gained 24.**
  `(libuv private handles)` now installs the eight dispatchers and the real
  `close-handle!` **in its own library body**, so any suite whose import
  chain reaches it finds them already installed. The "not installed yet"
  rows therefore cannot run there any more. They were **moved**, not
  deleted, to `test-native.sps` — the one suite that never imports
  handles.sls and whose process still has empty slots. `test-loop.sps` now
  asserts the installed reality instead (already-installed, second install
  refused, and — via an orphan-event probe — that the refusal did not rebind
  the slots).
- **`test-loop.sps`'s teardown sweep uses a real timer.** Stage 2 swept a
  fake `(cons 31337 'fake-timer)` through a probe `close-handle!`; the real
  one refuses anything that is not a handle record. The replacement timer is
  deliberately **never started**: an armed one would keep the loop alive, so
  a teardown that failed to sweep would *block* in the drain rather than
  fail, and a hang is not a test result. An unstarted timer is still in
  libuv's handle queue, so an unswept one makes `uv_loop_close` answer
  `EBUSY` and the row fails by name (confirmed as Mutation 10's
  `test-loop.sps` cascade).

## Summary

Failing test names are quoted verbatim from the SRFI-64 runner. Where a
mutation produced a cascade, the **first** name listed is the one that names
the broken decision; the rest are consequences.

| # | Decision under test | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 1 | Every trampoline body is guarded (ADR-0008, spike Q2) | `dispatch-guarded`'s `guard` deleted | **process death, exit 255** | subprocess probe — see below |
| 2 | The close dispatcher frees, zeroes and transitions BEFORE the user's on-close (design spec §5) | on-close moved ahead of the free | FAIL, exit 1 | "the handle was already 'closed when its on-close callback ran" — and *only* that one |
| 3 | `uv-close!` is idempotent by an explicit state test | `(when (eq? (handle-state handle) 'open) …)` → `(when #t …)` | FAIL, exit 255 | "uv-close! on an already-closed timer is a no-op, not an error"; "a second uv-close! while 'closing ignored its on-close argument"; (+5 rows, then `invalid memory reference` — libuv double-close) |
| 4 | `timer-dispatch` delivers only to an `'open` handle | state check dropped | FAIL, exit 1 | "the timer dispatcher delivers nothing to a handle whose close has started" — and *only* that one |
| 5 | The close dispatcher POPS the registry entry | `registry-deregister!` → `registry-ref` | FAIL, exit 255 | "the close dispatcher deregistered the handle"; "an ordinary close returns the registry to its baseline"; "the registry is back to its starting size" (+ a later re-registration collision) |
| 6 | `loop-record-error!` calls `uv_stop` on the first error (design spec §8) | the `uv-loop-stop` call deleted | FAIL, exit 1 | "the raise stopped the loop on the fire that raised"; "the close the raising callback started is still pending when uv-run returns" |
| 7 | `uv-timer-start!` validates BEFORE any native call | validation moved after `uv_timer_start` | FAIL, exit 1 | "no refused start armed the timer (validation precedes the native call)"; (+ the EINVAL row, a consequence — the mutant armed the timer, so `uv_timer_again` no longer had a NULL callback) |
| 8 | The freeing site zeroes the stored `uptr` (design spec §10) | `(set-handle-ptr! handle 0)` deleted | FAIL, exit 1 | "the close dispatcher zeroed the stored handle pointer" — and *only* that one |
| 9 | The freeing site bumps the counter for its kind | `count-handle-free!` call deleted | FAIL, exit 1 | "the close dispatcher returned the live timer counter to zero" (+15 balance rows across three suites) |
| 10 | `make-uv-timer` registers the handle (the registry is the dispatch table AND the GC root) | `registry-register!` deleted | FAIL, exit 255 / TIMEOUT | "make-uv-timer registers the timer in the handle registry" (+32 rows: every callback became an orphan event, so no timer ever fired and the 1-hour drain hit the cap) |
| 11 | `make-uv-timer` bumps the `timer` counter | `count-timer-new!` deleted | FAIL, exit 1 | "seed: creating a timer moves the live timer counter" (+18 balance rows) |
| 12 | `&uv-handle-closed` carries the handle's OWN kind | kind hard-coded to `'tcp` | FAIL, exit 1 | all five "use after close: … raises &uv-handle-closed with kind 'timer" rows; "touching the timer from inside on-close raises &uv-handle-closed with kind 'timer" |
| 13 | `timer-dispatch` hands the callback the RECORD, not the pointer | `handle` → `handle-ptr` | FAIL, exit 255 | "the on-timeout callback is handed its own timer record" (+6 rows: `uv-close!` on an integer then refused every self-closing callback) |
| 14 | A trampoline resolves its slot at FIRE time, never at declaration time | slot captured in a `let` around the `foreign-callable` | FAIL, exit 255 | "the loop ran the probe timer's callback" — with `Exception in timer: callback dispatchers have not been installed`, i.e. the stub captured forever (+10 rows) |
| 15 | The two wrappers bake in the RIGHT entry point | `uv-timer-start-native` given the close trampoline | FAIL, exit 255 | "the loop ran the probe timer's callback"; `invalid memory reference` (the close dispatcher freed an armed timer) |
| 16 | `uv-loop-teardown!` finishes the teardown before re-raising a callback error | the drain's `guard` deleted (error escapes as it did in Stage 2) | FAIL, exit 1 | "…and the loop was closed anyway, not left open behind the error" (+2 balance rows) |
| 17 | …and does re-raise it rather than swallowing it | the `(raise stored)` deleted | FAIL, exit 1 | "a raise from an on-close callback escapes uv-loop-teardown!"; "…wrapped as &uv-callback-error, like any other callback raise" |
| 18 | `uv-tcp?` answers from the kind field | kind test replaced by `#f` | FAIL, exit 1 | "uv-tcp? answers #t for a handle record of kind 'tcp" — and *only* that one |
| 19 | A callback for an unregistered pointer is RECORDED, never raised and never dropped | `record-orphan-callback!` deleted | FAIL, exit 1 | "both orphaned callbacks were recorded, in order, with kind and pointer"; "the refused second install left handles.sls's dispatchers in place" |
| 20 | The eight trampolines are `lock-object`'d (ADR-0008, spike Q1) | `lock-object` → `values` | FAIL, exit 255 | "the probe timer closed itself from inside its callback", with `Exception: invalid relocation type 4` — see the note below |
| 21 | `install-dispatch-procedure!` is install-once per name | the already-installed check deleted | FAIL, exit 1 | "replacing an already-replaced dispatcher is refused, naming who and why"; "the refused replacement did not rebind the slot"; "replacing this stage's own timer dispatcher is refused, naming who and why" |
| 22 | The trampoline guard catches ANY raised object, not just conditions | `#t` clause → `(condition? e)` | FAIL, exit 1 | "a callback raising a NON-condition is caught by the guard too"; "the wrapped cause is the raised object itself" |
| 23 | `uv-handle-state` refuses a non-handle rather than defaulting | `require-handle` deleted | FAIL, exit 1 | "uv-handle-state rejects a non-handle, naming who and why" — and *only* that one |
| 24 | `uv-close!` actually calls `uv_close`, not just the Scheme state machine | the `uv-close-native` call deleted | FAIL, exit 255 / TIMEOUT | "libuv agrees the handle is closing, and did not before" (+30 rows across four suites; the timer suite then blocked on a handle that never closes) |
| 25 | The seam closure libuv actually calls is itself guarded | the `guard` in `seam-closure` deleted | FAIL, exit 255 | all six "the … stub's raise is contained by the seam, not delivered into C" rows; "every contained stub raise was recorded, in order, naming its callback type" |
| 26 | …and the containment RECORDS rather than swallows | `contain-dispatcher-raise!` gutted to `#f` | FAIL, exit 1 | "every contained stub raise was recorded, in order, naming its callback type"; "…and reaches the caller from uv-run as &uv-callback-error"; "…carrying the stub's own condition as its cause"; "the refused install left the read stub in place" |

### Notes on individual mutations

**Mutation 4 did not fail anywhere until a row was written for it.** The
first campaign run recorded it as NOT CAUGHT, which is the honest and
expected outcome: libuv stops a timer as part of `uv_close`, so a timeout for
a `'closing` handle cannot be produced *through libuv* at all, and no
end-to-end row can reach that arm. Rather than record the decision as
permanently uncovered, `tests/test-timer.sps` now calls
`((dispatcher-ref 'timer) (handle-ptr closing-timer))` directly — the exact
call the trampoline makes, with the handle's own pointer — once with the
handle `'open` (the seed, so "the callback did not run" cannot pass against a
dispatcher that never delivers anything) and once with it `'closing`. The
mutation was then re-run and failed by name, alone.

**Mutations 25 and 26 were added by review, and the defect they guard was
real.** The closure installed into each native slot was
`(lambda args (apply (dispatch-procedure name) args))` — **unguarded**. The
comment at the stub claimed "the guard above catches it", and it did not:
`dispatch-guarded` is invoked *inside* `timer-dispatch` and `close-dispatch`,
so it protects the user's callback but nothing that raises before a
dispatcher has been entered. The six stubs — and anything Stages 4-5 install
— would have raised straight into a C frame. The seam closure is now guarded
itself, the comment says what is true, and both halves of the new behaviour
(containing the raise, and *recording* rather than swallowing it) have a
mutation.

Mutation 25's exit 255 is worth reading precisely: the six per-stub rows fail
because each `test-equal`'s own guard catches what the seam should have, and
then the suite *dies* at the next line, where the seam is called at top level
with a registered pointer and nothing catches it (`Exception in alloc: this
callback type is not implemented in this version`). That top-level call is as
close to the C-frame case as an in-process suite can get. The genuine
C-frame death is what Mutation 1's subprocess probe measures, and it is **not
reconstructible for the seam in Stage 3**: the only dispatchers libuv can
reach here are timer and close, both of which enter their bodies successfully
and are already covered by that probe. Recorded rather than faked.

**Mutation 20's exception text varies between runs** (`invalid relocation
type 4` and `invalid relocation type 7` were both observed, as were
`invalid memory reference` and `hashtable-ref: #<garbage> is not a hashtable`
in the other two suites). That is what an unlocked, GC-moved code object
looks like, and the variability is the point rather than a flaw in the
measurement: three suites die three different ways, none of them cleanly.
Every timer callback in these suites calls `(collect)` (design spec §11),
which is why this mutation is caught at all — spike FINDINGS Q1's GC-pressure
axis, productionized, is what makes `lock-object` a *tested* requirement here
instead of an assumed one.

**Mutation 10 hit the 120 s cap in `test-timer.sps`.** With no registry
entry, every callback becomes an orphan event, so the one-hour timer's
`run-until` never sees its predicate satisfied — but `run-until`'s cap is on
`uv-run 'once` *iterations*, and each of those blocks until the next due
event, which for a one-hour timer is one hour. The suite is bounded by the
iteration cap in the sense design spec §11 requires (it cannot spin), but a
*blocking* step is not bounded in wall-clock time. Recorded rather than
hidden: the driver's per-suite timeout is what turned it into a result. The
same mutation is caught in under a second by three other suites.

## Mutation 1: the guard, via a subprocess probe

Removing the guard in `dispatch-guarded` cannot be measured from inside a
suite — the failure mode *is* the death of the process running the suite
(spike FINDINGS Q2, scenario `bare`: exit 255, no teardown, no
`uv_loop_close`, no `foreign-free`). So this one is run as a probe program
in a subprocess, with the mutated library on `CHEZSCHEMELIBDIRS`, and the
exit status observed from outside.

The probe (`…/scratchpad/stage3/probe/guard-probe.sps`, outside the repo per
AGENTS.md) models a real caller: it guards around `uv-run` for
`&uv-callback-error` — the documented class the store-and-reraise policy
delivers (design spec §8, "raise inside a callback, catch around
`uv-run`") — and guards nothing else anywhere. Its timer callback closes its
own handle and then raises the bare symbol `raised-inside-the-callback`.

**Actual observed output, both runs byte-identical:**

```
$ CHEZSCHEMELIBDIRS=$REPO/src:$REPO/build/scheme-libs chez --program probe/guard-probe.sps
MARKER: entering uv-run
MARKER: uv-run returned control, outcome = wrapped-and-delivered
MARKER: teardown complete
pristine exit=0
```

```
$ CHEZSCHEMELIBDIRS=probe-scratch/src:$REPO/src:$REPO/build/scheme-libs chez --program probe/guard-probe.sps
MARKER: entering uv-run
Exception occurred with non-condition value raised-inside-the-callback     [stderr]
mutant exit=255
```

Three things are visible there, and all three are the decision under test:

1. **The exit status is 0 against the shipped code and 255 against the
   mutant** — the discrimination this probe exists for.
2. **The mutant's raise arrives UNWRAPPED.** The probe's guard is written for
   `&uv-callback-error`; the escaped object is the bare symbol, so the guard
   declines it and it reaches Chez's default handler. A caller who follows
   the documented contract catches nothing.
3. **`MARKER: teardown complete` never prints in the mutant.** No
   `uv_loop_teardown!`, no `uv_loop_close`, no `foreign-free` — the loop and
   its handle are leaked outright, exactly as spike Q2 measured.

The in-suite counterpart of this same invariant is
`tests/test-lifecycle.sps`'s "the counters balance after a callback raise"
row, which ADR-0008 names as the check that would fail if a trampoline were
ever left unguarded.

## Decisions this stage made, with the evidence

### The Stage 2 open question: a callback error during teardown

`src/libuv/loop.sls` recorded an open question for this task: the drain calls
`uv-run`, so a callback error stored during teardown re-raises out of
`uv-loop-teardown!` and leaves the loop **open and unclosed**. Stage 3 made
that path reachable (an `on-close` callback that raises) and chose:
**catch it, finish the teardown, re-raise afterwards.**

Rationale, and it is the same one ADR-0008 gives for store-and-reraise: the
alternative hands the caller an error *and* an open loop with half-closed
handles — the invisible cleanup obligation spike Q2 measured, where the
caller proceeds to `uv_loop_close` and gets `EBUSY` with no explanation.
Teardown's contract is that the loop is closed when it returns, and one
`on-close` callback raising is not a reason to abandon the other handles.

Both halves are asserted (`tests/test-timer.sps`) and both mutations are
caught: Mutation 16 (let it escape, i.e. the Stage 2 behaviour) fails "…and
the loop was closed anyway, not left open behind the error"; Mutation 17
(finish but swallow) fails "a raise from an on-close callback escapes
uv-loop-teardown!".

**What this policy costs, recorded rather than papered over:** only the
FIRST callback error of a teardown is kept, and each later drain iteration
clears the deferred list as it goes (`uv-run` clears it at the start of a
run, design spec §8). So an error deferred *during* a teardown is not
readable afterwards. No test asserts that, because no assertion could
distinguish it from the single-error path without a second raising handle in
the same teardown; it is a known, named gap, not an oversight.

### The deferred-errors two-timer question: no fallback needed

The brief allowed a fallback to direct `loop-record-error!` calls if libuv
turned out not to deliver two same-tick timer callbacks in one iteration
deterministically. **It does, and the fallback was not taken.** The
mechanism is in `vendor/libuv/src/timer.c`: `uv__run_timers` first drains the
timer heap of everything due into a local `ready_queue`, and only then walks
that queue calling `handle->timer_cb`. `uv_stop` sets a flag that `uv_run`'s
own `while` condition tests — it does not interrupt that queue. So two 0 ms
timers armed before the same run both fire in the same iteration even though
the first one's raise stopped the loop.

`tests/test-timer.sps` asserts the whole shape end to end from real
callbacks: `'(1 1)` fires, the first error re-raised by `uv-run`, exactly one
deferred error, that error being the *second* callback's own condition, the
list still readable after the run that produced it, and cleared by the next
run. This is the "full end-to-end shape" `.plans/stage-2-mutation-log.md`
deferred to Task 7 under "Deferred-error readability". Observed identical
across four full suite runs (two acquisition legs × two runs each).

### Measured: `uv_stop` from a callback leaves pending closes for the next run

`tests/test-lifecycle.sps`'s callback-raise row was written expecting the
counters to balance the moment `uv-run` returned. They do not, and the reason
is in `vendor/libuv/src/unix/core.c`: in `UV_RUN_DEFAULT` mode `uv_run` runs
timers **before** entering its `while` loop, while `uv__run_closing_handles`
runs **inside** it. A callback that calls `uv-close!` and then raises causes
`uv_stop`, the `while` condition fails immediately, and the close the
callback started is still pending when `uv_run` returns.

The test was changed to assert what was measured, not what was assumed:
the handle is `'closing`, its pointer is still live, the counter has not
moved, and a further `uv-run` completes the close. Mutation 6 (no `uv_stop`)
is caught by exactly these rows, which is the check that the behaviour being
described is the one actually happening.

### Deviation from the brief: there is no `uv-handle-closed?` predicate

The brief specified `uv-handle-open?/closing?/closed?` on `(libuv handle)`.
`uv-handle-closed?` **cannot** be that predicate: it is already the condition
predicate of `&uv-handle-closed` (design spec §9), which
`src/libuv/private/conditions.sls` exports and `src/libuv.sls` re-exports —
and the two would collide in the facade and in every suite that imports both.
The third state is therefore read by name, `(eq? 'closed (uv-handle-state
h))`, and the reason is written at the top of `src/libuv/handle.sls` and in
the facade's export list. The two predicates that remain never raise, on
anything (asserted: "the state predicates answer on a closed handle instead
of raising", "the state predicates answer #f for a non-handle instead of
raising"); `uv-handle-state` is an accessor and does refuse a non-handle
(Mutation 23).

## Uncovered, and why

Recorded per AGENTS.md: "If no mutation can break the assertion, the
assertion is empty. Rewrite it, or write down in the mutation log that the
property is uncovered and why."

1. **`free!` itself, in the close dispatcher.** Deleting `(free! handle-ptr)`
   while keeping the zeroing and the counter leaves every suite green — the
   same hole `.plans/stage-2-mutation-log.md` recorded as Mutation 2b for the
   loop. It is a *leak*, and a leak is invisible to the debug counters (which
   count this binding's own bookkeeping, not the allocator's). This is what
   `make test-memory` under Linux Valgrind is for (ADR-0003); macOS ASan
   cannot claim it (LeakSanitizer is unsupported on arm64).
2. **The `'tcp` arm of `count-handle-free!`.** There is no TCP handle to
   build one from until Stage 4, and a synthetic record with a fake pointer
   would be freeing an address `foreign-alloc` never returned. Stage 4 adds
   the arm and the row together.
3. **The six unimplemented dispatchers' argument shapes.** The `alloc`,
   `read`, `connection`, `write-done`, `shutdown` and `connect` trampolines
   are declared, locked and reachable now, and their stubs are asserted to
   raise — but nothing calls them with the argument shapes libuv would use,
   because nothing in Stage 3 can arm them. A wrong `ssize_t`/`size_t`
   declaration on the `read` trampoline would not be caught here. Spike Q3
   measured that specific hazard (`UV_EOF` arriving as 2^64 − 4095 when bound
   unsigned) and Stage 5 is where it gets an assertion.
4. **`handle-pointer`'s null arm.** `(raise (make-uv-invalid-argument who
   'null-handle-pointer))` fires only for a handle that is `'open` with a
   zeroed pointer, which the close dispatcher's ordering makes unreachable —
   the same shape, and the same reasoning, as `loop-pointer`'s arm in Stage
   2. It is a structured failure standing where a segfault would otherwise
   be, not a branch a caller can reach.
5. **`close-handle-proc`'s initial raising body** (handles.sls, "the close
   seam"). It is **dead code**, and structurally so: the install is
   unconditional, in this library's own body, so no importer can run a line
   before it happens. Stage 2 had a suite row for it ("close-handle! raises
   &uv-error until Task 7 installs a real one"); that row could not survive
   the install moving into the library body and was dropped rather than
   replaced. Flagged in review, and kept deliberately rather than deleted:
   the slot still buys the once-only guarantee, which *is* tested
   ("a second close-handle! install is refused, naming who and why"), and
   `install-close-handle!`'s own validation arms are reachable. The
   uninstalled *body* is not. If Stage 4 finds no other use for the
   indirection — `(libuv loop)` could call a `close-handle!` exported
   directly from here, with no cycle — the slot, its stub, and
   `close-handle-installed?` should collapse into one procedure. Recorded
   here so that decision is a deliberate one rather than an oversight
   inherited twice.
6. **Multi-threaded / `__collect_safe` re-entry.** Still deliberately
   untested, still named: spike FINDINGS Q1's "deliberately untested" section
   applies unchanged. `uv_run` is bound plain and v0.1 is single-threaded.

## The seam Stages 4 and 5 plug into

`install-callback-dispatchers!` fills the eight slots in
`(libuv private native)` **exactly once**, and a second call asserts
(ADR-0008). Stage 3 can only implement two of the eight, so the procedures it
installs are thin closures that look their real implementation up in a
handles.sls-internal table **at fire time**:

```
native slot 'read  ->  (seam-closure 'read)
                            guards the whole call, then
                            dispatch-procedure reads dispatch-table
                            dispatch-table's 'read entry is a raising stub
```

Stage 4 replaces one by calling
`(install-dispatch-procedure! 'write-done write-done-dispatch)`. That swaps
the implementation behind an already-installed slot without touching the
slot, so ADR-0008's once-only guarantee about the slots survives intact.
Each name is itself install-once (Mutation 21), and `'timer` and `'close` are
pre-marked as installed so this stage's own dispatchers cannot be hijacked.

Two rules for the new dispatchers, both load-bearing:

- **Call through `dispatch-guarded`** (exported from
  `(libuv private handles)`) for every user callback. Mutation 1 above is
  what happens otherwise. The seam's own guard is a net, not a substitute:
  it has only a pointer and a raised object, so it cannot stop the *right*
  loop as precisely, and an error arriving there means a dispatcher failed
  before it reached its own guard — a bug, not a delivered callback error.
- **Handle the "not in the registry" case with `record-orphan-callback!`,
  never with a raise** — there is no loop record to record an error against,
  and raising from a C frame is the same process death.

## Verification, on both acquisition legs

| Check | Result |
|---|---|
| `make test` (`HAVE_PKG=yes`, pkg-config libuv 1.52.1), **run 1** | ALL SUITES PASSED — conditions 89, facade 30, lifecycle 41, loop 101, native 160, shim-loading 19, timer 136 = **576 assertions** |
| `make test` (pkg-config), **run 2** | ALL SUITES PASSED — assertion counts byte-identical to run 1 |
| `make HAVE_PKG=no test` (vendored submodule libuv 1.52.1), **run 1** | ALL SUITES PASSED — identical counts |
| `make HAVE_PKG=no test` (vendored), **run 2** | ALL SUITES PASSED — identical counts |
| `make check-purity` | green; `PURE_TESTS` is an explicit per-suite list, so `test-timer.sps` is excluded by construction (it imports `(libuv timer)`, which reaches `(libuv private native)`) |
| `make check-pins`, `make check-help` | green |
| `make test-memory` (macOS, ASan) | all seven suites pass under the ASan preload with `detect_leaks=0`, exit 0, no ASan diagnostic emitted. **This is not a leak claim** — LeakSanitizer is unsupported on arm64 macOS, so this leg checks use-after-free / double-free / overflow only, which is precisely the class this stage introduces (a handle pointer freed in the close dispatcher while libuv may still hold it). Leak claims come from Linux Valgrind (ADR-0003), which is where the uncovered `free!` of item 1 above would be caught. |

The suite was run **twice on each acquisition leg specifically to shake timer
nondeterminism**, since Stage 3 is the first stage whose assertions depend on
libuv's scheduling. All four runs produced identical assertion counts and
zero failures.

Those four runs were taken at 572 assertions (timer 132), before review added
the seam-guard rows. The review commit re-ran `test-timer`, `test-loop`,
`test-native` and one full `make test` at **576** (timer 136); the earlier
figure of "571" in the Stage 3 commit message and the first draft of this
table was an arithmetic slip — 89+30+41+101+160+19+132 is 572, not 571 — and
the totals here are now the summed, checked numbers.

Recorded observations (informational, not assertions):

- Every timer callback in `tests/test-timer.sps`,
  `tests/test-lifecycle.sps` and `tests/test-facade.sps` calls `(collect)`
  (design spec §11). That is 100 forced collections in the lifecycle
  iteration row alone, each with libuv's `uv_run` → `uv__run_timers` C frames
  live below the Scheme callback. Mutation 20 is the evidence that this
  pressure is doing work rather than decorating the suite.
- `uv_handle_size(UV_TIMER)` on this platform is 152 bytes, matching spike
  FINDINGS Q1's measurement; the value is read from the running library at
  every `make-uv-timer` rather than transcribed (ADR-0005).
