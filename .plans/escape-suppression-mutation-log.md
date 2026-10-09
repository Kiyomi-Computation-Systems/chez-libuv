# The gate's suppression for Chez's escape `jmp_buf` (#94): evidence and mutation log

2026-10-09, Valgrind 3.19 on Debian 12 aarch64 (`chez-libuv-valgrind:10.4.1`),
Chez 10.4.1. The gate passes `tests/valgrind-chez.supp` to Valgrind, and
`check-memory-gate` gains an `escape` mode.

## What failed, and why it was not the binding's

#85's branch failed the gate in one suite, test-loop-claim:
`312 bytes in 1 blocks are definitely lost`, allocated by `malloc` called
directly from `S_call_help`. The suite run alone, alternating main
(27d84bb) and the branch:

| Run | main | branch |
|---|---|---|
| 1–5 | 0 B definitely lost, every run | 312 B in 1 block, every run |

Both legs allocated 3,766 blocks. With `--show-leak-kinds=all`, both had the
same 312 B block at exit, with the same stack and the same JIT address. On
main it was "still reachable", and on the branch "definitely lost". The
branch also had fewer Chez mutexes and conditions at exit (3 and 1, against
9 and 6): more collections had run.

**Bisected by file**, from main's pristine source with the branch's files
copied in:
- `native.sls` alone: 0 B lost, 26 blocks at exit.
- `+ handles.sls`: 312 B lost, 15 blocks at exit.
- `+ dns.sls`: the same as `+ handles.sls`.

The branch's `handles.sls` adds a procedure and a macro that test-loop-claim
never calls. The flip is collection timing.

**The block.** #94's repro under Valgrind on main, on the main thread:

| Escapes | Blocks at exit from `malloc` ← `S_call_help` |
|---|---|
| 0 | none |
| 1 | 312 B in 1 block, still reachable |
| 3 | 936 B in 3 blocks, still reachable |

312 B is `sizeof(jmp_buf)` on aarch64 glibc. Chez's `S_call_help` mallocs one
for each call from C into Scheme, and frees it when that call returns. An
escape never returns. test-loop-claim's "a teardown on another thread whose
close callback escapes" row makes one escape, on a thread that then ends,
and the block outlives the thread.

**A planted `foreign-alloc` leak** has stack `malloc ← s_malloc`, not
`S_call_help`, so the suppression cannot match the gate's own plants.

## The check, before and after

`make check-memory-gate`, every mode (Linux), on main plus this change:

| Mode | Result |
|---|---|
| store-overrun | caught: 0 bytes after a block of size 23 |
| libc-overrun | caught: a block of size 29 |
| shim-overrun | caught: a block of size 19, in `chez_uv_copy_in` |
| leak | caught: 777 bytes in 1 blocks are definitely lost |
| possible-leak | consistent: exit 0, possibly lost: 555 bytes in 1 blocks |
| **escape** | **passes, its jmp_bufs suppressed: 936 bytes in 3 blocks** |

`MEMORY GATE CAN FAIL`.

Watched to fail first: with the escape mode in place and no suppression file,
the mode failed with `SUPPRESSION NOT LIVE: Valgrind suppressed "0 bytes in 0
blocks"`, and `leak` was still caught.

## Mutants

Each mutant was made in a copy of the tree inside the container, then
restored before the next.

| Mutant | Change | Result |
|---|---|---|
| M1 | the suppression without its `fun:S_call_help` frame (any `malloc`) | **killed twice**. `leak` went VACUOUS: its 777 B block was suppressed and the gate exited 0. `escape` counted "1,292 bytes in 10 blocks", not three. |
| M2 | `match-leak-kinds: definite` only | **killed**: `escape` suppressed 0 blocks. The main thread's escapes are still reachable. |
| M3 | the frame misnamed (`S_call_hel`) | **killed**: `escape` suppressed 0 blocks |
| M4 | the file not passed to Valgrind (`--suppressions` removed) | **killed**: `escape` suppressed 0 blocks |

M2 is by design: the suppression matches every kind so that the check can
count it. Only definite leaks gate (`--errors-for-leak-kinds=definite`), so
matching the other kinds changes nothing the gate decides.

## #85 with the suppression

#85's branch (4c38ea0) plus this change:
- test-loop-claim alone: 23 rows pass, `definitely lost: 0 bytes`,
  `suppressed: 312 bytes in 1 blocks`, exit 0.
- The full gate: `check-memory-gate` passes (MEMORY GATE CAN FAIL), and
  `test-memory` passes, all 31 suites.

## Where the suppression matched in the full gate

Attributed by each process's `Command:` line:

| Process | Suppressed | Why it has the block |
|---|---|---|
| test-loop-claim | 312 B, 1 block | the escaped teardown |
| test-loop | 936 B, 3 blocks | its escape rows |
| test-async-fence | 312 B, 1 block | engines, by inference (below) |
| test-loop-threads | 312 B, 1 block | engines, by inference (below) |
| 82 forked children | 312 B each | a spawn's child that exits before exec; it reports the block its parent held at the fork |

**Engines.** test-async-fence and test-loop-threads have no escape from a
libuv callback, only escapes from exception handlers, which leave no C
frames. Both run engine sweeps over calls that enter callbacks, so their
blocks most likely come from those; no run attributed them row by row. A
probe shows the mechanism: it made an engine run out of fuel inside a timer
callback, three times:
- dropped there: `936 bytes in 3 blocks`, from `S_call_help`, still
  reachable;
- resumed to the end: none.

So a dropped engine strands the block too. This answers the heap half of
#94's first open question.

Without the suppression, only test-loop-claim's block had ever read
"definitely lost". The others were "still reachable" in every run here, and
did not gate.
