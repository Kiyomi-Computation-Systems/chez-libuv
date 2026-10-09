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

## The review's follow-ups: what the suppression could hide

PR #99's review (2026-10-09) found three gaps in the check above.

**1. The suppression hides the binding's escapes too.** A callback seam
that left its callback without returning would strand the same block, and
the suppression matches it in every kind. Before the suppression, the gate
saw that only when the block read "definitely lost", as it did once in
test-loop-claim. So `test-memory` now has Valgrind write each suite's
report to a log, which it prints when the suite ends, and reads the
suite's own leak summary there: the first process in the log, ahead of any
children it forked. A suite missing from `MEMORY_ESCAPE_SUITES` must have
nothing suppressed, or it fails with `UNEXPECTED ESCAPE`.

The list was taken from three full gates, each suite's own process only:

| Suite | aarch64, Docker | x86-64, #99's CI | x86-64, #100's CI |
|---|---|---|---|
| test-loop | 936 B, 3 blocks | 600 B, 3 blocks | 600 B, 3 blocks |
| test-loop-claim | 312 B, 1 | 200 B, 1 | 200 B, 1 |
| test-async-fence | 312 B, 1 | 200 B, 1 | 200 B, 1 |
| test-loop-threads | 312 B, 1 | 200 B, 1 | 200 B, 1 |
| every other suite | 0 | 0 | 0 |

All 82 forked children that reported a block were test-process's; its own
process had none. 200 B is `sizeof(jmp_buf)` on x86-64 glibc.

A new `stray-escape` mode in `check-memory-gate` makes the escape mode's
three escapes from a program the list leaves out, and requires the gate to
fail naming it:

```
gate caught stray-escape: UNEXPECTED ESCAPE: tests/memory-gate-sabotage.sps had
```

**2. The escape mode could not see `definite` dropped.** Its three blocks
are still reachable, so a suppression matching only `possible,reachable`
still counted three, while the block that gated test-loop-claim was
definitely lost. The mode now also requires each `match-leak-kinds` line in
the file to name `definite` or `all`. No escape can be made definitely lost
on demand: that depends on collection timing, which is the reason this
suppression exists. So the check reads the file.

**3. "Exactly three" was unmeasured on x86-64.** #99's first CI run
measured it: `gate passes escape, its jmp_bufs suppressed: 600 bytes in 3
blocks`. The count stays exact, since it is what kills M1 in this mode.

### Mutants

Run in the scratch container (Debian 12, aarch64) on #99's tree with
these changes. Each was restored before the next.

| Mutant | Change | Result |
|---|---|---|
| N1 | every suite exempt (`*" $$t "*)` → `*)`) | **killed**: `MEMORY GATE VACUOUS: make test-memory exited 0 with the stray-escape defect planted` |
| N2 | read the first summary in the log, whichever process wrote it (the escape mode's idiom) | **killed** on test-process: `UNEXPECTED ESCAPE: tests/test-process.sps had 312 bytes in 1 blocks`, a forked child's. Control, unmutated: passes, 146 rows. |
| N3 | kinds `possible,reachable` | **killed**: `SUPPRESSION MISSES DEFINITE` |
| N4 | the escape mode not listed as escaping | **killed**: `SUPPRESSION NOT LIVE: make test-memory failed`, with `UNEXPECTED ESCAPE` in its log |
| N5 | the `UNEXPECTED ESCAPE` branch prints but does not exit | **killed**: stray-escape `MEMORY GATE VACUOUS` |
| N6 | a suite fails even with nothing suppressed | **killed** on test-timer: `UNEXPECTED ESCAPE: tests/test-timer.sps had 0 bytes in 0 blocks`. Control, unmutated: passes, 133 rows. |
| N7 | `--log-file` dropped, so Valgrind writes to stderr | **killed** twice: escape `SUPPRESSION NOT LIVE`, stray-escape `failed, but not on the planted stray-escape`, both from `holds no Valgrind report` |

`check-memory-gate`, every mode, unmutated: MEMORY GATE CAN FAIL, with
`gate passes escape, its jmp_bufs suppressed: 936 bytes in 3 blocks` and
`gate caught stray-escape`. macOS: `make check-memory-gate` (ASan modes)
and `make check-help` pass.

**The full gate with the rule in place** (`make test-memory-docker`, a
`--no-hardlinks` clone of #99 with these changes): MEMORY GATE CAN FAIL in
all seven modes, then all 30 memory suites pass, exit 0. The suites with a
block suppressed in their own process were the four listed, with the
counts in the table above; no suite's own process lost a byte.
