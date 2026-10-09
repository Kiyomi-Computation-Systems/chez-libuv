# What an escape, a raise and an engine cost on a callback's thread (#94): evidence and mutation log

2026-10-09, the Guix container (`scripts/guix-env`) on Linux x86-64: Chez
10.4.1, glibc 2.41, Valgrind 3.27.0, an 8 MB stack (`ulimit -s` 8192).
Base: main at 0ac482c. The probe is `.plans/escape-costs-probe.sps`; each
row below names its mode and count.

This answers #94's three unmeasured questions (engines, raises, x86-64) and
corrects one thing docs/api.md had wrong: resuming an engine suspended
inside a callback does not always finish its run.

## How Chez returns from a callback

Read in Chez 10.4.1's `c/schlib.c`. `S_call_help`, the entry from C into
Scheme, mallocs a `jmp_buf`, pushes it on the thread's chain of C contexts
(`CCHAIN`), and `setjmp`s. A callback's return is `S_return`. It checks
that the context it saved is still in the chain, and raises "attempt to
return to stale foreign context" if not. Otherwise it `longjmp`s to that
context.

Back at the `setjmp`, the context and every newer one are dropped from the
chain. The stack below the frame comes back. The newer contexts' `jmp_buf`s
are **not** freed, though. Lines 257-258 set `CCHAIN(tc) = yp` *before* the
walk commented "unlock code objects that we're escaping past". The walk
therefore starts at `yp` and stops at once: only `yp`'s own `jmp_buf` is
freed, and the newer contexts' code objects stay immobilized. PR review
found this, and a probe confirmed it (below).

So a return into an older context discards every newer one. Their stack
goes back but their blocks do not, and anything that later tries to return
into one of them is refused. That predicts every row below.

## Stack and heap, measured

`VmStk` is the main thread's stack mapping from `/proc/self/status` at the
end of the run. It grows and never shrinks, so it is the peak.

| Mode | N | Result |
|---|---|---|
| `escape` | 0 | 132 kB |
| `escape` | 1,000 | 436 kB |
| `escape` | 4,000 | 1,656 kB: (1,656 − 436) / 3,000 ≈ 416 B an escape |
| `escape` | 16,000 | 6,524 kB |
| `escape` | 20,000 | 8,156 kB, survived |
| `escape` | 24,000 | `SIGSEGV` (exit 139) |
| `escape … thread` | 16,000 | survived |
| `escape … thread` | 24,000 | `SIGSEGV` |
| `raise` | 4,000 and 40,000 | 132 kB both: a raise strands nothing |
| `raise … thread` | 40,000 | survived |
| `engine-resume` | 4,000 and 40,000 | 132 kB both: a resumed engine strands nothing |
| `engine-drop` | 1,000 | 416 kB |
| `engine-drop` | 4,000 | 1,632 kB: ≈ 405 B a drop, as an escape |
| `engine-drop` | 24,000 | `SIGSEGV` |
| `reclaim` | 40,000 | 432 kB, survived |

`reclaim` runs 40,000 escapes in batches of 1,000, each batch above an
engine suspended inside a callback and resumed after the batch. The peak is
one batch's: the resumed engine's return gives back every escape's frames
above it. Without that return, 24,000 escapes crash.

It gives back the stack only. Under Valgrind, an engine suspended inside a
callback, then 3 escapes, then the engine resumed, left 600 B in 3 blocks
from `malloc` in `S_call_help`: the escapes' `jmp_buf`s, as without the
engine. 6 escapes left 6 blocks. An engine suspended and resumed with no
escapes left none.

A raise needs no measuring to explain: the seam's `guard` catches it inside
the callback (#46), which then returns. 40,000 confirm it. The probe's first
version caught every raise, so a setup that failed would also have read as
"costs nothing" (the code review's finding). It now catches only a
`&uv-callback-error` whose cause is the callback's own `'boom`. An escape
counts only when it returns `'escaped`, and the thread mode reports how its
run ended instead of waiting without end. Rerun that way: `raise 40000` and
`raise 40000 thread` stayed at 132 kB, and `escape 4000` reached 1,652 kB.
Each check was watched to fail: a callback that does not raise, or does not
escape, ends the probe with a non-zero exit, on the main thread and on a
forked one.

**Heap on x86-64.** The escape `jmp_buf` is 200 B here, against 312 B on
aarch64: #99's and #100's CI legs counted test-loop's three escapes as
600 B in 3 blocks.

## Two engines suspended inside callbacks on one thread

Modes `lifo` and `fifo` suspend engine A in a callback of one loop, then
engine B in a callback of another, and resume both.

| Mode | Order | Result |
|---|---|---|
| `lifo` | B, then A | both finish: `b`, `a` |
| `fifo` | A, then B | A finishes; B raises "attempt to return to stale foreign context" |
| `fifo … thread` | A, then B | the same |

After the `fifo` order (a second probe), B's loop refuses `uv-run` and
`uv-loop-teardown!` (`&uv-invalid-argument`), and `uv-loop-open?` answers
`#t`: B's run is left as an escape leaves it. An engine suspended on the
main thread and resumed on another raised the same error there.

**The scheduler's case.** An engine suspended inside a callback of loop A,
then resumed from inside a timer callback of loop C, finishes its run. The
timer callback's return is then refused: `uv-run` of C raises the
stale-context error, and a second `uv-run` of C is refused
(`&uv-invalid-argument`). PR review found this case, and a probe confirmed
it.

**Two more scheduler shapes**, which the code review of PR #115 found and a
probe then confirmed:
- An engine started from inside a scheduler's timer callback stops inside
  its own loop's callback. If the scheduler's callback then returns, its
  run returns normally (`#f`). But that return dropped the engine's
  callback, and resuming the engine later, outside every callback, raises
  the stale-context error. The engine's loop stays marked running.
- An engine started and resumed within one call of the scheduler's
  callback finishes, and so does the scheduler's run. Its callback nests
  inside the scheduler's, so this order is safe.

The rule is therefore nesting, not "latest first": an engine's callback
must still nest when the engine is resumed.

**Heap.** Under Valgrind (`--show-leak-kinds=all`), `fifo` leaves one
200 B block from `malloc` in `S_call_help` that `lifo` does not, besides
B's loop, which the probe cannot close. It is B's `jmp_buf`, dropped
unfreed when A's return passed it. Resuming A and never resuming B leaves
the same block. The refused resume allocates nothing: `S_error` longjmps to
the chain's top. The scheduler's case leaves one block the same way, the
scheduler callback's. `tests/valgrind-chez.supp` matches both.

## The rows

`tests/test-loop.sps`, "two runs suspended inside callbacks on one thread
(#94)". It has three cases, each with a seed that its engines ran out of
fuel inside their callbacks, using the suite's `run-slice` and
`slice-fuel`:
- **Later one resumed first.** Both finish. Neither loop stays marked
  running, and both tear down as they are, with nothing cleared by hand.
- **Earlier one resumed first.** It finishes, and its loop is not marked
  running. The later one's resume raises the stale-context error. Its loop
  stays marked running, and `uv-run` refuses it. Both tear down once the
  suite clears the mark.
- **Resumed from inside a scheduler's callback.** The engine finishes its
  run. The scheduler's `uv-run` raises the stale-context error, and its
  loop stays marked running. Both tear down once the suite clears the
  scheduler's mark.
- **Started inside a scheduler's callback that then returned.** The
  scheduler's run returns. Resumed outside every callback, the engine is
  refused by Chez. Its loop stays marked running, but the scheduler's does
  not. Both tear down once the suite clears the engine's mark.
- **Started and resumed in one call of a scheduler's callback.** Both
  finish, and both loops tear down as they are.

Every timer these rows start goes through `start-timer`, which answers
`'started` or the raise's evidence. A setup that raises therefore fails a
seed row by name instead of ending the suite (the code review's finding;
the older #45 block still starts its timer at top level).

The suite passes, 208 rows under `make test`. The full gate
(`make HAVE_PKG=no test-memory`, 25 suites) exits 0, and
`check-memory-gate` says MEMORY GATE CAN FAIL. test-loop's own process has
`definitely lost: 0 bytes` and `suppressed: 1,200 bytes in 6 blocks`. That
is the three escapes' 600 B, plus one block for each case that abandons a
callback: the earlier-first order, the resume from a scheduler's callback,
and the engine its scheduler's return left behind. test-loop is already one of
`MEMORY_ESCAPE_SUITES`. The full gate (`make HAVE_PKG=no test-memory`, 25
suites) exits 0.

## Mutants

Each was made in `src/libuv/loop.sls`'s `run-step!`, in a copy of the tree
outside the repository, and test-loop was run against it. The copy passed
202 rows before each mutant and after it was reverted (196 for the rows'
second version, before the code review added two cases). The child-process
rows need `make test`'s environment, so they did not run there.

M2's exact change, in `run-step!`:

```diff
>   (define last-claimed #f)
    (let ((ptr (claim-loop! loop #t)))
>       (unless (symbol? ptr) (set! last-claimed loop))
<                                          (release-loop! loop)
>                                          (when (loop-running? last-claimed) (release-loop! last-claimed))
```

| Mutant | Change | Result |
|---|---|---|
| M1 | release the claim on any exit from the native run that is not a return (#45's old `dynamic-wind`) | **killed** by 16 rows, the earlier-first "stays marked running" and "`uv-run` refuses it" among them. Run against the first version of the rows, before the scheduler's case was added. Broad: the expiry itself then fails, so the seeds fail too. The existing #45 rows already hold this. |
| M2 | release the thread's most recent claim rather than this run's loop (diff above) | **killed** by every new row that reads a mark or tears down as it is: 11 rows, each by name. "Neither loop is marked running"; "both loops resumed in that order tear down as they are"; "the earlier engine finishes its run"; "its loop stays marked running, as an escape leaves it"; "`uv-run` refuses it from then on"; "an engine resumed from inside another loop's callback finishes its run"; "the scheduler's loop stays marked running"; "both loops tear down once the suite clears the scheduler's mark"; "its loop stays marked running, but not the scheduler's"; "both loops tear down once the suite clears the engine's mark"; "and both loops tear down as they are". The suite's three balance rows fail after it, because a teardown failed. No existing row saw M2: a single suspended engine cannot tell two loops apart. |
| M3 | a `guard` around the native run that turns a raise into a return | **killed** by exactly seven rows, all new: the three stale-context rows, the three "stays marked running" rows, and "`uv-run` refuses it". The resumes reported `(finished #f)`, and the stale loops were released. |

**Uncovered.** Two rows are broken by no binding mutant through their own
property. They are "resumed later one first, both engines finish their
callbacks and runs" and "an engine started and resumed in one call of a
scheduler's callback finishes". Each holds Chez's in-order return and the
engine plumbing, and the binding makes no decision there. M1 breaks it only by breaking the seeds. The two
teardown rows that clear the mark first are cleanup, and no mutant covers
them either.

The stale-context rows also pin Chez itself. A Chez that let the return
through would fail them by name, and one that crashed would end the suite.

## Left open in #94

- Whether Chez could reset the C stack on an escape (a question for
  upstream; not asked here). The unfreed `jmp_buf`s above are a second
  upstream question: the walk at schlib.c:257-262 looks meant to free them.
  Both are drafted, not filed, in `.plans/upstream-chez-cchain-issue.md`.
- Whether the binding should count escapes per thread and raise a named
  condition before the stack runs out.
- macOS x86-64 and Windows are unmeasured.
- The code review also asked for a check on how many blocks each escape
  suite has suppressed (test-loop's rose from 3 to 6 here, and nothing
  pins it). The Makefile and suppression comments now name the new
  sources, but a count check is follow-up work. So is folding the #45
  block's fixture into `suspend-in-callback`.
