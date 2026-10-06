# ADR-0015: Spawn inputs are one co-allocated block freed the instant `uv_spawn` returns; a failed spawn is cleaned up by asking the loop who still owns the handle, never by reading the errno

- **Status:** Accepted (2026-08-21) — evidence: spike/process/FINDINGS.md SQ1
  (`spike/process/07-spawn-failure.ss`, both platforms, Linux leg under
  valgrind). Amended 2026-10-06: decision 1's block is sized and filled from
  the caller's data as read once, never from the data itself; and decision
  5's state is foreclosed by checks made in the step that spawns, which also
  holds decisions 2 and 3's cleanup and registration — see the dated notes
  after decisions 1 and 5.
- **Date:** 2026-08-21
- **Scope:** chez-libuv v0.3
- **Related:** [design spec](../2026-08-21-chez-libuv-v0.3-process-design.md) §4.3, §5.5, §5.6, §7 (V1, V3),
  [ADR-0006](0006-error-codes-are-symbols.md),
  [ADR-0007](0007-no-guardians-explicit-close.md),
  [ADR-0008](0008-static-trampolines-and-handle-registry.md),
  [ADR-0009](0009-copy-at-the-boundary.md)

## Context

`uv_spawn` takes a `uv_process_options_t` holding five foreign pointers
(`file`, `args`, `env`, `cwd`, `stdio`) and consumes all of them
synchronously: it copies `exit_cb` into the handle
(vendor/libuv/src/unix/process.c:1054) and does the fork/exec inside the
call, so nothing it was handed outlives the return (design spec §7, V1).
That settles the *success* path's memory question — one block in, one free
out — and settles nothing about failure.

Failure is where the spike found the design spec wrong. §5.6 assumed one
cleanup strategy would win for all spawn failures and asked SQ1 to pick it.
SQ1's verdict, verbatim: **"There are two failure classes with opposite
correct cleanups, and the spike measured both on both platforms."**

The source says why. `uv_spawn` runs `uv__handle_init` — which links the
handle into `loop->handle_queue` — at process.c:991, and has **two** exits:

- **setup failures** leave through `error:` (process.c:1075), whose first
  statement is `uv__queue_remove(&process->handle_queue)` (process.c:1076).
  The handle is *unlinked*. Reachable from ordinary calls: a bad
  `uv_stdio_container_t` (process.c:226 returns `UV_EINVAL` when the
  inherited stream's fd is −1), a socketpair that could not be made
  (process.c:207), the `pipes` allocation itself (process.c:999-1005,
  `UV_ENOMEM`).
- **exec failures** never reach that label. libuv forks, the child's
  `execvp` fails, the errno comes back over the error pipe, and `uv_spawn`
  falls off the end at `return exec_errorno` (process.c:1073) with the
  handle **still linked into the loop**.

Measured, both platforms (FINDINGS SQ1 Observation 1): for an exec failure
our handle is still visible to `uv_walk` (`#t`), `uv_is_active` /
`uv_is_closing` are `0 / 0`, `handle->pid` is `0`, and `uv_loop_close`
before any cleanup answers `EBUSY`; for a stdio-setup failure `uv_walk` no
longer visits it (`#f`). The 2×2 that follows is the decision:

```
the 2x2 (failure class x cleanup strategy):
  exec failure  + uv_close    : close_cb #t, loop_close 0
  exec failure  + direct free : loop_close EBUSY
  stdio failure + uv_close    : late handle survived #f, loop_close 0
  stdio failure + direct free : late handle survived #t, loop_close 0
```

Both wrong cells are silent. Exec-failure + direct free crashed nothing in
1000/1000 iterations, yet valgrind reported **402 errors from 15 contexts**
plus `definitely lost: 576 bytes in 2 blocks`, against strategy A's `0
errors from 0 contexts` in the same CI job: "136 bytes is exactly
`uv_handle_size(UV_PROCESS)`; offset 32 is inside the handle's
`handle_queue` node", and the next spawn's `uv__handle_init` appends through
a tail pointer naming freed memory. Stdio-failure + `uv_close` is worse than
loud: a live handle registered *after* the failure was spliced out of
`loop->handle_queue` (`late handle survived #f`) while remaining perfectly
live, because "libuv's `error:` path leaves the handle's own queue node
pointing at its old neighbours, and `uv__finish_close` unlinks it a *second*
time" — and `uv_loop_close` still returned 0, because the handle it should
have refused for is no longer in the queue it checks.

The spike also refuted §5.6's other assumption. Pipes named in `(pipe …)`
specs are **not** left untouched by a failed spawn: `uv_fileno` on the
parent ends goes from `rc EBADF, fd -12345` before the spawn to `rc 0, fd 9`
after it, because "libuv creates the socketpairs *before* forking and opens
the parent ends into the pipe handles **regardless of whether the exec
succeeded**". They come back "connected, correctly directioned, inactive,
and closeable". Not closing them costs one fd per slot per attempt: over 300
failed rounds the parent-end fd climbed `9 / 606` on macOS and 12 → 611 on
Linux, with `handles left open in that loop = 600` — "a slow leak rather
than a prompt error — the worst kind".

## Decision

**1. One co-allocated options block, freed unconditionally the moment
`uv_spawn` returns.** A single `foreign-alloc` holds the
`uv_process_options_t`, the `uv_stdio_container_t` array, the argv and env
pointer arrays, and every string's UTF-8 bytes, with internal pointers fixed
up (design spec §5.5 step 3). V1 licenses the free: the block is dead the
instant the call returns, on both paths. One alloc site, one free site, no
conditional — the `uv-write!` discipline, and the ADR-0009 boundary applied
to a struct instead of a payload.

> **Amended 2026-10-06: the block is built from the caller's data as read
> once.** Until then `uv-spawn!` checked its caller's strings and lists,
> sized the block from them, and read them again to fill it, and an engine's
> timer handler (or another thread) could change them in between. Engine
> sweeps on a0ea0ca (`tests/test-process.sps`) measured each way that went
> wrong. Strings and args or env lists that grew were written past the
> block's end (Valgrind: `Invalid write … chez_uv_copy_in`, 667 and 909
> errors). A list that grew also wrote argv's NULL slot, so argv ran on into
> the env strings or the child's `execve` failed with EFAULT. A stdio list
> that grew wrote a container over argv[0]: EFAULT natively, an empty argv
> under Valgrind, whose gate stayed green because the write landed inside
> the block. A pipe swapped in after the check reached libuv, and a NUL set
> after the check cut the child's strings short (exit status 0 for
> `exit 7`).
>
> Now `uv-spawn!` reads file, args, options, env, cwd and the stdio specs
> once, in one interrupt-free step, into fresh bytevectors, lists and
> records nothing else can reach. The checks (the NUL check on the encoded
> bytes), the block's sizing and filling, and the marking of pipes read only
> that. The step holds an engine off, but not another thread, so it never
> trusts the data to keep still while it reads it. Chez's own
> `string->utf8` sizes its result in one pass and fills it, unchecked, in a
> second, so each string is copied (a fixed-width copy) and the copy
> encoded; Chez's `map` walks a list it has measured without checking it
> again, so lists are walked a checked pair at a time. The fill refuses a
> string that would not fit in the block, a bound `copy-in!` does not have.
> Evidence and the mutations: `.plans/spawn-read-once-mutation-log.md`.

**2. Cleanup after a nonzero rc is class-dependent, and the class is decided
by whether the loop still owns the handle — never by the errno.** Both
measured-correct arms ship:

- **still in the loop's handle queue** → close through the normal protocol
  (`uv_close`, callback-driven free). Measured correct: 1000/1000 `close_cb`s
  delivered, 0 handles left in the queue, `uv_loop_close` 0, valgrind clean.
- **not in the queue** → `foreign-free` the block directly, no callback
  expected. Measured correct: both sentinels still visible, `uv_loop_close` 0.

FINDINGS' own formulation is the rule this ADR adopts: **"Ask the loop,
don't guess"** — "the *robust* discriminator measured here is whether the
handle is still in the loop. `uv_close`-then-free is correct exactly when it
is; direct free is correct exactly when it is not."

**Discriminating on the rc is rejected, and not as a stylistic preference.**
The two classes' errno sets *overlap*: `UV_ENOMEM` is the setup class's
pre-fork allocation failure (process.c:999-1005) **and** a fork/posix_spawn
failure returned as `exec_errorno` (process.c:1073); `EMFILE`/`ENFILE` can
come from the pre-fork `uv_socketpair` (process.c:207) **and** from the
child's own `dup2`, which reports over the error pipe like any exec failure
(`uv__write_errno`, process.c:372-373) and therefore arrives in the linked
class. SQ1 measured exactly two errnos — `ENOENT` for the exec class and
`EINVAL` for the stdio class — and establishes no mapping for the rest. An errno table would therefore be a guess whose
wrong answers are a permanently-`EBUSY` loop or a silently-spliced live
handle, and whose untestable cases (resource exhaustion) are precisely the
ones it would get wrong. This is a second, deliberate disagreement with
FINDINGS' own phrasing: FINDINGS:432 states "the binding can distinguish
the classes by rc, but the *robust* discriminator measured here is whether
the handle is still in the loop" — this ADR adopts only the second half of
that sentence and rejects the first outright, on the both-sides-of-the-fork
errno-overlap evidence above, rather than carry rc forward as a fallback
discriminator.

**The measured instrument for the property is `uv_walk`, and it is the one
this binding ships.** It is what the spike used to produce every row above
(`spike/process/07-spawn-failure.ss` builds a `uv_walk_cb` foreign-callable,
locks it, and compares visited pointers against ours), it is public API
whose documented meaning is exactly the property, and it ran memory-clean
under Memcheck inside strategy A's `0 errors` leg. Adopting it costs one new
foreign-procedure (`uv_walk`) **and one more locked foreign-callable**:
`uv_walk_cb` (uv.h:341) is a callback type no existing trampoline matches,
so it is the **twelfth** locked callback type, joining `exit` as v0.3's
second addition — the v0.3 locked set grows by two, and design spec §5.2/§8
and ADR-0008's v0.3 amendment are both amended to ten → twelve in the same
change as this decision, with both frozen test literals widened
watched-to-fail. `walk` joins `dispatcher-names` and is installed at
`(libuv process)`'s library-body time (the dns.sls late-install seam's
second application, same as `exit`), wiring `walk` over a module-level
query cell in `handles.sls` that backs the query the failure path actually
calls: `(handle-in-loop-queue? loop handle)`. `walk` fires synchronously —
only for the duration of the `uv_walk` call that drives it, on the caller's
own thread, never from `uv_run` — which is why it still satisfies ADR-0008's
invariant: that invariant tracks callback *type*, not when or from where a
callback fires.

- *Rejected alternative, no new callable:* read the handle's own
  `handle_queue` node through a shim offset row (ADR-0005 mechanism) and
  test `node->next->prev == node`. Its soundness rests on the same FINDINGS
  observation that defeats the naive test — a removed node keeps "pointing
  at its old neighbours" while they no longer point back — and valgrind
  located that node at offset 32 of the 136-byte handle. **Evidence status:
  not measured by the spike, and it reads a field uv.h marks private** — the
  reason it was passed over in favor of the measured instrument, not a
  defect in the mechanism itself; it remains available if a future need
  ever justifies re-litigating the trampoline count.
- *Rejected instrument:* `uv_loop_close`'s `EBUSY`. SQ1 measured it, but it
  answers "some handle is in this loop", not "ours is" — conclusive only in
  an otherwise-empty loop, which no real caller has.

**3. The close-through-protocol arm registers, because in this binding
closing *is* registration.** `close-dispatch` (handles.sls:872-885) resolves
the firing pointer through the registry and is, per its own comment, "THE
ONLY PLACE A HANDLE POINTER IS FREED" (handles.sls:848-849); an
unregistered pointer is filed by
`record-orphan-callback!` and **never freed**. So the exec-class arm
`registry-register!`s the record and bumps `count-process-new!` before
calling `uv_close`, and the standard protocol deregisters, frees, and bumps
`count-process-free!` when `close_cb` fires. This refines — and is the one
place it must refine — FINDINGS' summary phrasing "no registry entry, no
counter increment": that phrasing describes libuv's requirements, and the
close protocol is a property of this binding that the spike was not in a
position to weigh. The setup class needs no registry entry at all and gets
none.

Two consequences of that are contractual, not incidental: the free is
**asynchronous** — `close_cb` arrives on a later loop iteration (the spike
needed capped `'once` steps to collect it) — and the raise happens
**immediately**, so a failed spawn can leave one process handle in `'closing`
state that the caller's next `uv-run` or `uv-loop-teardown!` reclaims. That
is the same contract every `uv-close!` in this binding already has
(ADR-0007): nothing new to explain, and the counters return to baseline once
the loop turns rather than at the moment of the raise.

**4. Whatever the class, the record does not escape and the raise carries
the errno symbol** (ADR-0006): no record is returned, no `on-exit` can fire
for it, the options block is already gone, and `&uv-errno-error` names the
`uv_spawn` rc.

**5. A guard for the one state the spike did not measure.** If `exec_errorno`
was 0 but a later `uv__process_open_stream` fails, `uv_spawn` jumps to
`error:` (process.c:1060-1067) with the handle *unlinked yet started*
(`uv__handle_start` at process.c:1056) and a **live child** in
`loop->process_handles`. Neither measured arm is correct there. The only
trigger reachable through this binding's own API *by construction* is an
already-connected target stream (`uv__stream_open` returns `UV_EBUSY`,
vendor/libuv/src/unix/stream.c:407-408), which `'pipe-already-used`
forecloses before any allocation; a macOS-only `setsockopt(SO_OOBINLINE)`
failure arm remains (stream.c:424-430), reachable for the socketpair fd and
not gated on `'pipe-already-used` at all — which is why the pid==0 guard,
not this argument, is what covers the remainder. Because AGENTS.md prefers a
check to a comment, the failure path asserts the state instead of asserting
the reasoning: `uv_process_get_pid` must read `0` (measured `handle->pid = 0`
for the exec class; the field is only written at process.c:1053 when the
exec succeeded). A nonzero pid raises loudly — `&uv-invalid-argument`, who
`'uv-spawn!`, reason `'spawn-failure-state-unclassifiable` (the
implementation stage may refine this symbol name; design spec §4.7 gains
the row when it does) — with the handle **deliberately untouched**: a
leaked 136-byte block is recoverable and diagnosable; queue corruption and
use-after-free are neither.

> **Amended 2026-10-06: the stdio handles and the loop are checked again in
> the step that spawns.** "`'pipe-already-used` forecloses [the trigger]
> before any allocation" held for a pipe consumed before the call, and
> missed two ways to reach this state:
> - **A pipe consumed during the call.** `uv-spawn!` checked its handles on
>   entry, then allocated and built the options block, and an engine's timer
>   handler could spawn on the same pipe in between. An engine sweep over
>   55125e1 reached this state in 148 of 232 runs, and in 8 more it put the
>   handler's own spawn here: the pipes were marked only after `uv_spawn`
>   returned.
> - **One pipe named twice in one spawn,** from a plain call: libuv opens
>   the pipe once per spec after the fork, and the second open fails.
>
> Now one interrupt-free step checks the loop and every stdio handle again
> (open, with a pointer, and a pipe not consumed), passes libuv the pointers
> it has just checked, calls `uv_spawn`, frees the options block and marks
> the pipes. No spawn on this thread can then consume a pipe between the
> check and libuv's open. A pipe named twice is refused `'pipe-already-used`
> before anything is allocated. The pid guard stays, for the `SO_OOBINLINE`
> arm above.
>
> The same sweeps found three siblings of the window, each closed by the
> same step. A pipe closed during the call was opened into its closing
> handle, a descriptor nothing ever closed (8 open descriptors became 157).
> A pipe closed and freed during the call, with a new pipe at its address,
> connected the child to the new pipe. A loop torn down during the call
> leaked the options block and the process handle, or reached `uv_spawn`
> freed (an invalid memory reference, or an abort).
>
> Decision 2's cleanup and decision 3's registration run inside the step
> too. Placed after it (mutations M5 and M8), a teardown between
> `uv_spawn` and them left the process handle in the loop unregistered, and
> the teardown raised `EBUSY`. The step raises nothing: it answers a
> status, and `uv-spawn!` raises after it with what the entry checks raise
> for the same state. A refusal in the step, made before `uv_spawn` is
> called, frees the options block and the process handle before it answers,
> as the build's own guard does when the build fails; on every other path
> the block is still freed the moment `uv_spawn` returns. Evidence and the
> mutations: `.plans/spawn-stdio-fence-mutation-log.md`.

**6. The pipe contract, rewritten from measurement.** On a failed spawn every
pipe named in a `(pipe …)` spec is **marked connected, left open, and closed
by the caller**, exactly like a pipe from a successful spawn:

- *Marked connected* because on the exec path they demonstrably are
  (`uv_fileno` rc 0, a real fd), and because the conservative direction is
  the safe one: under-reporting connectedness is what would let a later
  spawn hand libuv an already-opened stream and reach state 5 above.
- *Left open* on the S6 precedent — "the binding never auto-closes the handle
  on a read error … what happens next is the caller's decision"
  (handles.sls:838-840) — and because auto-closing cannot be done honestly
  here anyway: `uv_close` completes on a later loop iteration, so a
  self-closing failure path would raise while leaving the caller's own pipe
  records mid-close.
- *Closed by the caller*, with the cost of not doing so documented rather
  than implied: one fd per pipe slot per failed attempt, measured `9 / 606`
  over 300 rounds (Linux 12 → 611), 600 handles left open, and no `EMFILE` on
  either runner to announce it.

Design spec §4.3 and §5.6 are amended to say this; the sentence asserting
that "our pipe records remain consistently unconnected and closeable" is
deleted as refuted.

**Amendment (2026-08-21, Stage 5):** implementation widened the marking to
pipes named via `(inherit-stream . h)` specs as well — provably a no-op on
every success path (inherit-stream only succeeds against an already-connected
pipe), live only on the setup-class failure path, where the conservative
direction matches this decision's own over-report policy. Spec §4.3/§5.1
carry the reconciled wording.

**Amendment (2026-08-21, Task 12 fix wave 1):** the "unlinked" fact above
(lines 32-33) holds for **libuv >= 1.52.0 only**. Upstream commit
[`3e9ae1bc`](https://github.com/libuv/libuv/commit/3e9ae1bca07f8155bc4249a21ec41ca2c86fdb93)
("unix: remove handle from queue on uv_spawn() error (#4980)") added
`uv__queue_remove(&process->handle_queue)` to `uv_spawn`'s `error:` label
first in 1.52.0; on an older libuv the handle **remains linked** at the same
stdio-setup trigger, and the discriminator (decision 2, asking the loop
rather than the errno) correctly takes the exec-class arm there instead —
measured on ubuntu-noble's apt `libuv1-dev` 1.48.0, the CI job's
pkg-config leg (CI run 32543915500, red, on that leg → run 32544754290,
green, once `tests/test-process.sps` was rewritten to assert decision 2's
class-independent observables instead of one arm's timing, commit
`6db61e6`). No production code changed. This **validates** decision 2 —
the class is decided by asking the loop at runtime, never by a version- or
platform-keyed table — rather than weakening it.

## Consequences

- **A failed spawn is not a no-op on its arguments.** `'pipe-already-used`
  now fires for pipes consumed by a *failed* spawn too, so the recovery
  pattern is close-and-remake, not retry-with-the-same-pipes. This is the
  caller-visible half of the refutation and belongs in the module header and
  README, not only here.
- **The stdio-setup class needs a production twin the design spec does not
  yet have.** §9.2's `'ENOENT` scenario exercises only the exec class.
  `(inherit-stream h)` where `h` is an open but never-connected tcp handle
  reaches process.c:226 and returns `EINVAL` — a one-line, network-free,
  deterministic way to drive the other class from the public API. The
  discriminator's test asserts, for both classes: the loop closes cleanly
  afterwards, a handle registered *after* the failure still exists, and the
  counters balance once the loop has turned. Those are the two observables
  the 2×2 separated; a mutation that collapses the two arms into one fails
  one of them.
- **The memory lane is the mutation target for the options block.** One
  alloc site and one free site with a counter pair means an early return that
  skips the free is a definite leak under `make test-memory` (ADR-0003), and
  a double free is an invalid free — neither is a comment anyone has to
  believe.
- **`uv_loop_close` after a failed spawn answers `EBUSY` until the loop
  turns** (exec class), and `0` immediately (setup class). Both are correct
  and neither is new vocabulary: it is the ordinary "you have an unclosed
  handle" answer (ADR-0011 records the same shape for pending requests).
- **The trampoline set is twelve: `exit` and `walk`.** `uv_walk` is the
  discriminator's instrument (Decision 2 above), which makes `uv_walk_cb`
  the twelfth locked callback type; ADR-0008's v0.3 amendment and design
  spec §5.2/§8 move from ten to twelve, `walk` joins `dispatcher-names`
  beside `exit`, and both frozen test literals widen to twelve
  watched-to-fail. `walk` fires synchronously, only for the duration of the
  `uv_walk` call the discriminator makes, never from `uv_run`, and installs
  at `(libuv process)`'s library-body time over a module-level query cell in
  `handles.sls` that backs `(handle-in-loop-queue? loop handle)`. The
  `handle_queue` back-pointer read recorded above stays the rejected
  alternative — unmeasured by the spike and reading a field uv.h marks
  private, which is why it did not ship — rather than a discarded option;
  §5.3 would gain one offset row if it were ever adopted instead. The
  decision recorded here — *which property decides the class* — is
  instrument-independent regardless, and no implementation may substitute
  an errno table for it.
- **Nothing here changes the success path.** Register, count, mark the
  consumed pipes connected, return the record (design spec §5.5 step 6); the
  handle is active from birth and the loop stays alive until the exit
  callback has fired (V10).
