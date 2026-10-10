# Refusing a run before the C stack runs out (#94): design note

- **Status:** Accepted, 2026-10-09: option D, with every recommendation
  under "Decisions" below. Implemented the same day
  (`.plans/stack-headroom-mutation-log.md`), as proposed except where
  "As built" says otherwise.
- **Scope:** the part of #94 still open after #115: "whether the binding can
  do more than document it". The upstream question (can Chez reclaim the
  frames?) is drafted separately and not filed.
- **Sequencing:** the check touches `src/libuv/loop.sls`. PR #120 (#118),
  which changed `call-with-uv-loop` there, has merged (5a3ec99), so nothing
  waits on it.
- **Evidence:** `.plans/escape-headroom-probe.sps` and its C helper
  `.plans/escape-headroom-probe.c`. Every number below is from them, on
  Chez 10.4.1 with libuv 1.52.1: macOS 26 arm64 (Homebrew libuv), and Linux
  arm64 (Debian 12 in Docker, vendored libuv).

## The problem

A continuation that escapes a libuv callback leaves that `uv_run`'s C
frames on its thread's stack until the thread ends. Every later foreign
call pushes below them. Enough escapes and a `uv_run` overflows the stack:
`SIGSEGV`, or on macOS a fault Chez catches, after which the thread can
hang the next collection for good (#95). Nothing tells the program it is
getting close.

#94 suggested counting escapes at `call-with-uv-loop`'s exit and raising a
named condition before the stack runs out. Measuring what to count showed
that a count is the wrong quantity. The stack itself can be measured, and
the measurement costs about 4 ns.

## What was measured

### What one escape strands depends on which callback it leaves

`trace` escapes from a timer callback, `trace-async` from an async
callback. Headroom is the distance from the current C stack pointer to the
bottom of the thread's stack, read through the helper after each escape.
Each escape strands the same amount every time, to the byte:

| Callback left | macOS arm64 | Linux arm64 |
|---|---|---|
| timer (`uv__run_timers`) | 352 B | 384 B |
| async (`uv__io_poll`) | 34,352 B | 22,272 B |

An escape from a callback that `uv__io_poll` calls strands `uv__io_poll`'s
frame too, and that frame holds the event array: 1,024 `struct kevent` on
macOS (32 KiB), 1,024 `struct epoll_event` on Linux arm64 (16 KiB). Reads,
connects, accepts, async wakes, signals and a child's exit all take that
path. So does a DNS or other request's completion, which comes back
through libuv's async wake. A write's callback takes it when the poll
finished the write, and comes from the pending queue, after the poll has
returned, when the write finished at once. Timer and close callbacks never
take it: `uv_run` calls them before the poll or after it returns.

So escapes held before the fault:

| Thread | Stack | Timer escapes | I/O escapes |
|---|---|---|---|
| macOS main | 8,372,224 B | 23,671 | 242 |
| macOS `fork-thread` | 536,576 B | 1,429 | 14 |
| Linux arm64 main | 8,388,608 B | 21,777 | not run (the same stack as the thread's) |
| Linux arm64 `fork-thread` | 8,388,608 B | 21,773 | 375 |

docs/api.md and AGENTS.md give only the timer column. On a macOS worker
thread, 14 escapes from a read callback are enough to crash or hang it.

### Where the fault comes: the deepest path through a `uv_run`

The fault is not in the escape itself. In `'default` mode a due timer runs
before `uv__io_poll`, so the escaping run never reaches the event array.
The fault comes in the teardown that `call-with-uv-loop`'s exit runs after
the escape: its drain is a fresh `uv_run` at the current depth, and that
one does reach `uv__io_poll`.

| | macOS arm64 | Linux arm64 |
|---|---|---|
| Headroom at the last run that survived | 33,712 B (`fork-thread`) | 21,760 B (`fork-thread`) |
| Headroom at the run that faulted | 33,360 B (`fork-thread`), 33,296 B (main) | 21,376 B (`fork-thread`), 21,120 B (main) |
| A run whose I/O callback allocates and collects: survived / faulted | 35,824 B / 35,472 B | not measured |

Main and `fork-thread` fault at the same headroom on each system, just
above the size of `uv__io_poll`'s event array. So the bounds the helper
reads (`pthread_get_stackaddr_np` and `pthread_get_stacksize_np` on macOS,
`pthread_getattr_np` on Linux) agree with where the stack really ends, on
both kinds of thread. A collection inside an I/O callback needs about
2.3 KiB beyond `uv__io_poll` alone. A collection inside a timer callback
needs nothing extra, since the timer runs before `uv__io_poll`.

### A refusal leaves the thread healthy

`guarded 65536` escapes until headroom falls under 64 KiB, then stops, as a
check would. On both systems the thread then collected twice, ran a loop
whose callback collected, and ended. Main joined it and collected. The
fault, and so #95's hang, never happens.

### What the check costs

`cost 1000000`, nanoseconds per call (macOS: the middle of three rounds):

| | macOS main | macOS `fork-thread` | Linux main | Linux `fork-thread` |
|---|---|---|---|---|
| empty `uv-run 'nowait` | 100.9 | 100.5 | 183.8 | 213.3 |
| the same with the check | 107.7 | 106.7 | 184.0 | 208.0 |
| the check alone (cached low bound) | 3.9 | 3.8 | 3.6 | 3.5 |
| reading the low bound uncached | 8.1 | 7.2 | 22,219 | 263 |

On Linux the main thread's low bound costs 22 µs to read, because glibc
reads `/proc/self/maps`. So the low bound is read once per thread and
cached. With the cache the check costs about 4 ns a run, inside the noise
of the cheapest run there is.

## Options

**A. Document only (today).** It costs nothing, and it leaves the crash and
the #95 hang where they are. The docs also need the I/O column, whichever
option is chosen.

**B. Count escapes at `call-with-uv-loop`'s exit (#94's suggestion).**
Rejected:
- One escape strands 352 B or 34,352 B depending on the callback, so no
  count maps to bytes. A limit safe for I/O escapes would refuse a
  timer-escaping program a hundred times too early.
- It misses escapes from a bare `uv-run` outside `call-with-uv-loop`.
- It overcounts after an engine resume. A resumed engine's return gives
  back every newer callback's frames (#115), and no count can see that.
- A limit still needs the thread's stack size, which is 512 KiB or 8 MiB
  for the same program.

**C. Count runs in progress per thread, in `run-step!`.** Every `uv_run`
starts there, so a counter raised before it and lowered after it would
count stranded runs, bare `uv-run` included. It keeps B's other three
faults.

**D. Measure headroom before each `uv_run` (recommended).** `run-step!` is
the only place the binding enters `uv_run`: `uv-run` and every teardown
drain go through it, and every callback is entered from inside some
`uv_run`. Checking headroom there covers every run and every escape,
whatever callback it leaves. It sees a resumed engine's return and the
real size of each thread's stack, and it needs no count.

## The proposal (D)

1. **A shim export: `chez_uv_stack_headroom`.** It answers the distance from
   its own frame to the bottom of the calling thread's stack. It reads the
   bottom from pthreads on the thread's first call and keeps it in a
   `__thread` variable. This is a seventh kind of export, so ADR-0002 needs
   an amendment, and its line still holds: the export calls nothing in
   libuv or Scheme. Rule 6 of `tests/test-source-rules.sps` needs a word
   for a per-thread static. Windows (ADR-0004) would read
   `GetCurrentThreadStackLimits`.
2. **Two floors, both checked in `run-step!`:**
   - **Teardown floor, 64 KiB:** a teardown's drain runs only with at least
     this much headroom. The deepest path measured is 35.8 KiB (macOS, a
     collection in an I/O callback), so this leaves 28 KiB of slack.
   - **Run floor, 128 KiB:** `uv-run` runs only with at least this much.
   The gap between the floors must be at least the most one run can strand
   (34.4 KiB measured). Headroom shrinks only when a run's callback
   escapes, and every run starts at or above the run floor. So after any
   escape, at least the teardown floor is left, and the teardown that
   `call-with-uv-loop`'s exit runs can always drain. That covers a nested
   run too: the inner run's own check was made below the outer frames.
3. **The refusal.** `uv-run` raises a new `&uv-stack-exhausted` (rooted at
   `&uv-error`; fields: who, the headroom, the floor). A teardown answers it
   as it answers its other failures: `uv-loop-teardown!` raises it, and
   `call-with-uv-loop`'s exit after an escape contains it. The check goes in the same interrupt-free step as the
   claim (`claim-loop!`), before the mark is taken, so a refusal leaves
   nothing to give back.
4. **What a program sees.** A thread that has escaped too often gets
   `&uv-stack-exhausted` from its next `uv-run`, with room left to tear
   its loops down. The thread should then end: nothing but its end or a
   resumed engine gives the frames back. docs/api.md says so.
5. **Tests:**
   - A child on a `fork-thread` escapes I/O callbacks until refused, then
     tears down, collects and ends, under `child-run`'s deadline (#122).
     The row expects the refusal's condition and the child's exit 0.
     Mutations:
     - remove the check: the child dies with `SIGSEGV` (Linux) or hangs
       until the deadline (macOS);
     - give `uv-run` the teardown floor: the last escape leaves less than
       the teardown floor, and the teardown is refused or faults.
   - The floors as a check, not a comment. On the platform running the
     suite, measure one I/O escape's strand through the new export, and
     assert that the run floor minus the teardown floor is at least that
     strand, and the teardown floor at least that strand plus 16 KiB. CI's
     x86-64 runner then checks numbers nobody has measured by hand.

## What it does not cover

- **C stack a callback spends below the binding.** A callback that calls
  deep C code of its own, or another library's foreign callable that
  escapes, is outside what `run-step!` sees. The floors' slack absorbs
  some of it, but nothing guarantees it.
- **A suspension between the check and the native call.** `uv_run` is a
  `__collect_safe` call and cannot sit inside the interrupt-free step, so
  an engine can expire between them. Resumed from deeper in C (inside
  another run's callback), it would run below where it checked. The gap
  between the two floors absorbs one such case.
- **A macOS worker thread stays small.** It holds 12 I/O escapes under the
  check, against 14 without it, and its 13th run is refused where the 15th
  escape crashed or hung. Timer escapes go from 1,429 to about 1,151. The
  check makes no room. It turns the crash into a named error.
- **Linux x86-64 and Windows** are not measured here. The floors test in
  item 5 measures x86-64 on CI. On x86-64 the epoll array is 12 KiB, packed,
  so its strand should be smaller than arm64's.
- **Linux with `ulimit -s unlimited`.** What `pthread_getattr_np` reports
  for the main thread then was not measured.

## The docs correction (shipped with this note)

docs/api.md ("An escape also costs its thread stack") and AGENTS.md's
escape trap quoted only timer escapes, 352–500 B each. An escape from a
callback the poll calls strands about 34 KiB on macOS and 22 KiB on Linux
arm64, so a macOS `fork-thread` holds 14 of them, not 1,429. Both now say
so. The correction stands under every option, A included.

## Decisions (2026-10-09)

The user took every recommendation:

1. **Option D**, the headroom check in `run-step!`, over counting escapes
   (B, C) or documenting only (A).
2. **Fixed floors** of 64 KiB for a teardown's drain and 128 KiB for
   `uv-run`, held by the floors test (item 5). A setting would invite a
   value under the deepest path, which brings the crash back.
3. **A new condition type, `&uv-stack-exhausted`**, not
   `&uv-invalid-argument` with a reason. The caller did nothing wrong in
   the call, and the way to recover (end the thread) is unlike any other
   refusal's.
4. **The docs correction ships now**, with this note, ahead of the check.

## As built (2026-10-09)

- The shim export, the floors and `&uv-stack-exhausted` are as proposed.
  The floors live in `(libuv private handles)` as `run-stack-floor` and
  `teardown-stack-floor`. The check is `claim-loop-for-run!`, which reads
  the headroom first in the claim's step, ahead of every other refusal,
  and `run-step!` is its only caller. Rule 11 of
  `tests/test-source-rules.sps` holds that, and that `run-step!` is the
  only caller of the foreign call to `uv_run`.
- Where the stack's bottom cannot be read, the export answers
  `CHEZ_UV_HEADROOM_UNKNOWN` (2^40), so nothing is refused.
- The tests run in a child, `tests/stack-headroom-child.sps`, on a
  `fork-thread`. Its `floors` mode reaches a depth by nesting libc `qsort`
  comparator callbacks, which all return, so the floors are tested without
  any escape. Its `escapes` mode escapes async callbacks until refused.
  Measured there, under the check:

  | | macOS arm64 | Linux arm64 |
  |---|---|---|
  | I/O escapes held by a `fork-thread` thread | 12 | 370 |
  | headroom at the refusal | 123,792 B | 119,296 B |
  | loops left open | 0 | 0 |

  Timer escapes held by a macOS `fork-thread` thread: 1,152.
- Valgrind's main thread reads 8,386,832 B of headroom, so the memory
  gate's runs are not refused.

## Reproducing

From the repository root, after `make build`:

```sh
cc -O2 -fPIC -dynamiclib -o /tmp/libstackprobe.dylib .plans/escape-headroom-probe.c
export STACKPROBE=/tmp/libstackprobe.dylib CHEZSCHEMELIBDIRS=src:tests
chez --program .plans/escape-headroom-probe.sps trace 3000 thread        # faults at 1,430; hangs on macOS
chez --program .plans/escape-headroom-probe.sps trace-async 40 thread    # faults at 15
chez --program .plans/escape-headroom-probe.sps margin-async 36000 thread
chez --program .plans/escape-headroom-probe.sps guarded 65536 5000 thread
chez --program .plans/escape-headroom-probe.sps cost 1000000
```

Wrap each in `timeout`. On Linux, build the helper with
`-shared -o /tmp/libstackprobe.so … -lpthread` and run the same commands
with `scheme`. The Linux numbers came from the `chez-libuv-valgrind:10.4.1`
image, fed the worktree by `tar --exclude=./build --exclude=./.git
--exclude=./src/libuv/private/config.sls --exclude=./tests/tmp -cf - . |
docker run --rm -i …`. Inside, a stub `git` that exits 0 goes first on
`PATH`, then `make CHEZ=scheme deps` and
`make CHEZ=scheme HAVE_PKG=no vendor build`.
