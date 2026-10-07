# The process verbs as one step: mutation log

Evidence for making `uv-process-kill!` and `uv-process-pid` one
interrupt-free step each (#71), the process family's last verbs in the
series #53 began with the stream verbs (`.plans/stream-step-mutation-log.md`)
and #59 continued with the constructors
(`.plans/constructor-step-mutation-log.md`). #68's review found the split
(its verifier V7); ADR-0019's decision 3 amendment of 2026-10-07 records the
decision.

The probes and the red runs ran on `main` at bfd2bbe (#72). The suite is
51c604b and the fix d4429b8, on `fix/process-verb-steps`.

Platforms:

- macOS arm64: Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config, the
  dev build. Other sessions kept the load average between 65 and 185.
- Linux aarch64, from `--no-hardlinks` clones:
  - `chez-libuv-noble-scratch:10.4.1`: Ubuntu 24.04, glibc 2.39, apt's
    libuv 1.48.0 (CI's pkg-config leg);
  - `chez-libuv-valgrind:10.4.1`: Debian bookworm, glibc 2.36, Valgrind
    3.19, vendored libuv 1.52.1 (CI's Valgrind leg).

Every probe and mutation ran on a scratch copy outside the repo.

---

## The defect, confirmed

**The issue's probe, re-run on bfd2bbe.** #68's verifier probe spawns A
and B as `/bin/sleep 47`, runs `(uv-process-kill! a 'sigterm)` in an engine
at rising fuel, and at the first expiry closes A, runs the loop until the
close has freed A's block, spawns B, and resumes the kill only if B took
A's address; `ps` reads each pid's state after. On macOS it gave the
issue's table to the row:

| fuel | the kill | A | B |
|---|---|---|---|
| 1–8 | `&uv-handle-closed` | sleeping | sleeping |
| 9–11 | `null-handle-pointer` | sleeping | sleeping |
| 12 | **returns normally** | sleeping | **exits `(0 sigterm)`** |
| 13 (no expiry) | returns | exits `(0 sigterm)` | not spawned |

`uv-process-pid`, split the same way: refused at 1–8, B's pid at 9, A's pid
at 10 (no expiry). B took A's address in every run.

**The suite on the base.** `tests/test-process-steps.sps` against
bfd2bbe's `process.sls`, the rest of `src/` unchanged. Fuel maps, macOS:

| sweep | verb | runs |
|---|---|---|
| split | kill, signal 0 | refused 1–9; at 10 returned after the close; untouched 11 |
| split | pid | refused 1–9; at 10 returned 0 after the close; untouched 11 |
| reuse | kill, SIGTERM | refused 1–9; `null-handle-pointer` 10–12; at 13 returned, **B `(0 sigterm)`**; untouched 14 |
| reuse | pid | refused 1–9; at 10 returned **B's pid**; untouched 11 |
| drop | kill, signal 0 / pid | dropped 1–10; untouched 11 |

Ubuntu 24.04 gave the same maps, except that the split pid at 10 returned
A's own pid: the freed block still held it there. On both, two rows fail by
name, "… split by its process's close is refused, or had returned before
the close" and "… split by a close never reaches a new process given the
old one's address". The drop rows pass on the base, as #53's did for
`uv-read-stop!` and the queue size: neither verb allocates, so a drop
strands nothing. The drop sweep is held by M9b instead (Mutations).

**A stale kill on a freed block.** Not probed with a real signal, as the
issue says: whatever pid the freed block holds is what `uv_process_kill`
signals (`kill(process->pid, signum)`, `src/unix/process.c`), and 0 there
is `kill(0, sig)`, this process's own group. The split sweep sends signal
0, which reaches no one, and shows the call made: it returned normally.

## The fix

Each verb checks its process again with `open-handle-ptr`, reads the
pointer and makes its native call in one `one-step`, and raises after the
step with `step-refusal`, as `uv-read-stop!` and
`uv-stream-write-queue-size` do. The FFI arguments are total inside the
step: the pointer is one `open-handle-ptr` found valid, and the signal one
`signal-symbol->int` answered before the step.

Fuel maps on the fix, identical on macOS (libuv 1.52.1) and Ubuntu 24.04
(1.48.0):

| sweep | verb | runs |
|---|---|---|
| split | kill, signal 0 | refused 1–9; untouched 10 |
| split | pid | refused 1–9; untouched 10 |
| reuse | kill, SIGTERM | refused 1–12; untouched 13 |
| reuse | pid | refused 1–9; untouched 10 |
| drop | kill, signal 0 / pid | dropped 1–9; untouched 10 |

The step costs no fuel, so each untouched run comes one fuel earlier than
on the base. No run was suspended after its step.

On the fix, the kill with signal 0 and the pid have no expiry point between
`require-open-process` and the step: their runs 1–9 all expire at or before
the open check. The step's own re-check is reached by the SIGTERM kill at
fuels 10–12, where converting the signal's name has trap checks, and by the
forced-state row. M4, M8 and M10 are caught there.

**Allocation.** Both verbs allocate 0 B a call, before and after: the
fewest of 400 calls, metered as `(+ (bytes-allocated) (bytes-deallocated))`
with the collector held off. The meter read a pair as 16 B in the same run.
(A first control, a vector stored into a variable nothing read, read 0:
Chez had dropped the dead store with the allocation. The control stores
into a vector that stays referenced, as test-callback-alloc's does.)

## A new process at the freed address

The reuse sweep needs a process handle at A's freed address. A spawn made
after A's free took it by itself on macOS in 24 to 30 of 30 runs, and on
glibc in none of 30, on 2.36 and on 2.39 alike, also after first freeing
7, 8 or 16 blocks of the handle's size. Why glibc's spawn misses was not
measured.

Allocating blocks of the handle's size (136 B, `uv_process_t`) through the
shim instead found the freed address at the first try:

| allocator | no blocks freed first | 7 blocks freed first |
|---|---|---|
| macOS | 29 of 30, then 30 of 30 | 30 of 30, twice |
| glibc 2.39 | 29 of 30, then 30 of 30 | 30 of 30, twice |
| glibc 2.36 | 29 of 30 (one at the second try), then 30 of 30 | 30 of 30, twice |

So a reuse run frees seven blocks of that size before closing A, searches
at most 16 blocks for A's address, spawns B, and copies B's handle into the
block it found. A stale call reads B's pid there. The run resumes only once
`uv_process_get_pid` reads B's pid from the copy: a block holding 0 would
make a stale kill `kill(0, sig)`. In every suite run since, the block
landed in every expired reuse run (21 of 21 on macOS and on Ubuntu 24.04).
Under a memory tool it never lands, by design, and the rows ask only that
the sweep ran.

## The tests

`tests/test-process-steps.sps`, a new suite, so that #66's PR B, which
adds sections to test-process.sps and its import list, merges with it in
either order. Each child is `/bin/cat` blocked reading a pipe from the
suite, which exits 0 when the suite closes that pipe unless a signal ended
it first. A child whose handle is open is reaped by libuv and reports
through `on-exit`; one whose handle a run closed is reaped by the suite
with `waitpid`, whose status the suite decodes as `on-exit` would.

- **Split** (signal 0 and pid): at the first expiry, close A, step the loop
  until the close has freed it, resume. Right answers: `'refused` (and A
  untouched), `'made-before-close` (the verb had returned before the
  expiry), `'untouched` (no expiry; the answer is A's).
- **Reuse** (SIGTERM and pid): the same, with B's handle placed at A's
  address before resuming. B must come through untouched, and A too
  unless the kill was made before the close.
- **Drop** (signal 0 and pid): drop the engine at the first expiry. Every
  debug counter as the run found it, blocks included, and interrupts
  enabled.
- Every run starts with `(collect)`: a collection that came due inside a
  step would be taken where the step ends and spend fuel there (#68), and
  the verb would be suspended after its call. Neither verb allocates, so
  after a collection no run can bring the next one due.
- Seeds: a child killed through its open handle reports `(0 sigterm)` and
  one whose stdin closed `(0 #f)`; the same two fates read by `waitpid`
  after the handles closed; `uv-process-kill!` on a reaped child raises
  `ESRCH` as `uv-process-kill!`; every expired reuse run found its block
  at A's address (a memory tool: only that the sweep ran).
- Reach rows: each sweep caught its verb at fuel 1, visited every fuel
  after it, and ended in a run no expiry reached.
- Last: a process forced open with no native block is refused as
  `null-handle-pointer` by both verbs, with interrupts enabled after.

A sweep runs on past a wrong run, to the first run no expiry reached: no
run can reach anything but its own children, since the split and drop
sweeps send signal 0 and a reuse run resumes only onto B's copy. It stops
early at a stalled run, a child that never exited or a resumed verb that
never finished.

## Mutations

Each mutant is an exact replacement in a scratch copy of `src/` or of the
suite, which must match exactly once. The suite ran against each on macOS.

| ID | mutation | caught by |
|---|---|---|
| M1 | the kill as on main: open check, `handle-pointer`, `uv-check`, no step | split (signal 0 at 10, returned after the close); reuse (`null-handle-pointer` 10–12; B `(0 sigterm)` at 13) |
| M2 | the pid as on main | split (returned 0 at 10); reuse (B's pid at 10) |
| M3c | the kill's `open-handle-ptr` read just before the step, outside it | equivalent: see below |
| M4 | the kill's step answers `'not-open` as success | reuse (returned at 10–12, never made); the forced-state row |
| M5 | libuv's errno ignored, the refusal kept | the `ESRCH` row |
| M6 | the kill's refusal named `uv-process-pid` | the `ESRCH` row; the forced-state row |
| M7 | the pid's status answered as its pid | the forced-state row |
| M8 | the kill's refusal raised inside its step | reuse (`interrupts-left-disabled` at 10–12); the forced-state row |
| M9 | the pid takes a block before its checks, frees it after its step, and in a `guard` on a raise | drop (block +1 at 11–19); split and reuse (returned at 17–19 without having returned before: see below); the suite's closing counter row |
| M9b | the pid takes a block before its checks and frees it before its step, and in a `guard` on a raise | drop (block +1 at 11–19); the closing counter row; nothing else |
| M10 | the kill's step checks the pointer, not the open state | reuse (`null-handle-pointer` at 10–12) |
| M11 | the kill's step split in two: the check, then the call | equivalent: see below |
| M12 | the kill calls with a pointer read at entry, and checks after | reuse (refused, B `(0 sigterm)` at 10–12); the forced-state row |
| M13 | the kill sends by a pid read before its step, and checks after | reuse (B `(0 sigterm)` at 10; A `(0 sigterm)` at 11–13); the forced-state row |
| M13b | the same, with the pid read at entry while A is open | reuse only (A `(0 sigterm)` at 11–13) |
| M14 | the kill ignores its signal (always 0) | the first seed; reuse (`untouched-but`, A `(0 #f)`); the reuse reach row |
| M15 | the kill with no step, its body unchanged | split (returned after the close at 10); reuse (B `(0 sigterm)` at 13) |
| T1 | `poll!` never steps the loop | split (counters left at every run); split and reuse reach rows; the reuse seed (0 of 21) |
| T2 | the `waitpid` decoder never reports a signal | the second seed |
| T3 | the expiry closes nothing | split (every run returned, never refused); both reach rows; the reuse seed |
| T5 + M1 | the oracle's `'made-before-close` stops asking that the verb had returned before the expiry, with M1 | the split row passes; reuse still fails |
| T6 + M12 | `'refused` stops asking B untouched, with M12 | the reuse row passes: B's check is M12's only catcher in the sweeps |
| T7 + M13 | `'refused` stops asking A untouched, with M13 | reuse still fails, at fuel 10, where M13 reached B |
| T7 + M13b | the same, with M13b | everything passes: A's check is M13b's only catcher |
| T8 | the sweep strides by two | all three reach rows (`skipped-to 3 at 2`) |

The control, the unmutated suite on the fix, passed 12 of 12 before and
after the sweep.

**M15 is not equivalent.** With the step removed and its body unchanged,
the split sweep finds the kill made after the close at fuel 10. So the
step is load-bearing, not an artefact of code layout: a trap check falls
between the open check and the native call.

**M3c and M11 are equivalent.** A pointer read just before the step, or a
check in one step and the call in the next, leaves no point where an engine
can suspend between them: nothing between the two has a trap check, as
#53's W19 and W20 found. Their fuel maps match the fix's run for run.

**M9 shows the oracle's premise.** Its free after the step adds trap checks
there, so an engine can expire after the call and before the verb returns,
and the split row then cannot tell the run from a stale call: the verb
returns after the close without having returned before it. The oracle holds
only for a verb whose step is its last act, which both verbs' are; a later
change that puts work after a step will fail this row until the oracle is
revisited. M9b, which frees before the step, is caught by the drop row
alone: the drop sweep is what holds a block held across the checks.

**Uncovered.** The `(collect)` that starts each run guards against a false
failure, a collection taken at the end of a step; no mutant shows it.

## Valgrind

The new suite under the memory gate's own flags, in the
`chez-libuv-valgrind:10.4.1` image (vendored libuv 1.52.1):

- **On the base**, Memcheck reported both stale calls, and the run exited
  9: `Invalid read of size 4 at uv_process_kill` and `at
  uv_process_get_pid`, each "104 bytes inside a block of size 136 free'd",
  the freed `uv_process_t` and its pid. The split row failed by name too.
  The reuse row passed there, since Memcheck never hands the block back
  and no reuse run resumes. So on Linux the memory gate catches a stale
  call that the reuse sweep cannot reach.
- **On the fix**: 12 of 12, 0 errors, 0 bytes definitely lost.

## Gates

On d4429b8, the fix with the suite as committed:

- `make test`, macOS: 25 suites passed.
- `make test`, Ubuntu 24.04 with apt's libuv 1.48.0 (the pkg-config leg):
  25 suites passed.
- `make HAVE_PKG=no check-purity` and `make HAVE_PKG=no test`, Ubuntu
  24.04 with the vendored libuv 1.52.1: purity held; 25 suites passed.
- `make test-memory`, macOS ASan: 25 suites passed. The new suite's reuse
  rows took their weak form: 0 of 21 blocks landed, ASan's quarantine
  holding them.
- `make test-memory-docker`: `check-memory-gate` printed `MEMORY GATE CAN
  FAIL` for its five modes, then every suite's own summary read 0 errors
  and 0 bytes definitely lost (the new suite: 2,252 allocs). The 76
  forked children with no `Command:` line are the known fork artifacts
  (10,979 B among them, never gating); the new suite adds none, since its
  `cat` children exec.

The suite's edits after d4429b8, its comments and an unused `nop`, change
no behaviour; `make test` passed again on them (25 suites, macOS).

## Not done

- The steps re-check the process, not its loop's owner, as the stream
  verbs' steps do (ADR-0019, the constructor amendment's "Found, not done").
- On glibc, the reuse sweep's new process is a copy of B's handle, not B's
  own handle: glibc's spawn did not take the freed address by itself.
