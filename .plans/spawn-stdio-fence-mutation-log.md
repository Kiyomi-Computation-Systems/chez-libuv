# uv-spawn! checks its stdio handles and loop where it spawns: mutation log

Evidence for `fix/spawn-stdio-fence`, on `main`'s a3750e5 (#59, the
constructors as one step; #56, the read-once fix, is cff802b). The probes
ran on `fix/spawn-read-once` as it was before its rebases (55125e1, on
a0ea0ca), whose `process.sls` is #56's. The step uses #59's
`open-loop-ptr`, #53's `open-handle-ptr` and `step-refusal`, and the rows
count #53's `'block`. The rows, the mutations and the gates ran on this
base; the drop probe and M11 under Valgrind ran on an earlier one (86de01e),
with the same step.

`uv-spawn!` (`src/libuv/process.sls`) checked its stdio handles and its loop
on entry (`require-open-loop`, then `require-open-handle`, `pipe-connected?`
and the same-loop check per stdio spec), allocated the process handle,
allocated and built the options block, and only then read the loop's
pointer, called `uv_spawn`, freed the block, marked the pipes consumed and
registered the process. The read-once fix made the caller's data private,
but a stdio spec names a handle, and the handle and the loop stay the
caller's: an engine's timer handler can close a handle, consume a pipe in a
spawn of its own, or tear the loop down in between.

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 26.6 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config, the
dev build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image (Debian
bookworm, Valgrind 3.19, vendored libuv 1.52.1), from a `--no-hardlinks`
clone.

---

## The bugs, confirmed

A scratch probe ran `uv-spawn!` in an engine at fuel 1, 2, …, with stdio
`(ignore (pipe p from-child))` and the child `/bin/sh -c "printf hello;
exit 7"`, made a change at the first expiry, resumed, and drained the loop
between runs. It stopped at the first run no expiry reached. On 55125e1,
232 runs a case:

| change at the first expiry | refused as the change's own state | wrong |
|---|---|---|
| `uv-close! p` | 71 (`&uv-handle-closed`) | **148 spawned on the closing pipe**: libuv opened the parent's end into it, and nothing ever closed that descriptor (open descriptors 8 → 157) |
| close `p`, run the loop until it is freed, make a new pipe `q` (at `p`'s address in 232 of 232) | 71 | **122 refused `null-handle-pointer`** instead of as closed; **26 connected the child to `q`**, which read `hello` and EOF though no spawn named it |
| spawn another child with `p` (to-child) | 71 (`'pipe-already-used`; the handler's spawn ran) | **148 refused `spawn-failure-state-unclassifiable`**: libuv forked, then found `p` open (ADR-0015 decision 5's state), and the 136-byte handle leaked; **8 more put the handler's own spawn there**, because `p` was marked only after `uv_spawn` returned |
| `uv-loop-teardown!`, stdio `(ignore)` | 14 (`&uv-handle-closed` loop) | **175 refused `null-loop-pointer`**, each after both allocations, which nothing freed; at **fuel 190 the process aborted** (exit 134), `uv_spawn` given the freed loop |
| `uv-loop-teardown!`, stdio with `p` | 71 (14 loop, 57 pipe) | 122 `null-handle-pointer`; 20 `null-loop-pointer` (20 options blocks left counted); **6 raised `invalid memory reference`**; **11 spawned and left the teardown raising `EBUSY`**, the process not yet registered |

The runs whose change landed after the pipes were marked behaved: in 12
close-pipe runs the child died of SIGPIPE, its parent end closed after the
spawn, and in 4 consume-pipe runs the other spawn was refused
`'pipe-already-used`.

**A pipe named twice** reaches the same unclassifiable state from a plain
call, no engine needed: `(stdio ((pipe p to-child) (pipe p from-child)))`
was refused `spawn-failure-state-unclassifiable`, the child ran (its exit
arrived later as an orphan callback), and `p` was left marked, so a spawn
naming it once was refused `'pipe-already-used`. libuv opens a `(pipe …)`
spec's end into its pipe after the fork, once per spec, and the second
`uv__stream_open` answers `EBUSY` (`vendor/libuv/src/unix/stream.c:407`).
ADR-0015 decision 5 had argued that `'pipe-already-used` forecloses the only
trigger reachable through the API.

**Dropped engines** (informational, the drop class of ADR-0019's survey,
which the stream-verb series leaves to a `uv-spawn!` PR of its own): the
same spawn on a loop of its own, the engine dropped at the first expiry,
then the pipe closed and the loop torn down. On 86de01e, counting #53's
blocks: 42 runs lost the process handle, 92 lost it and the options block,
13 left the teardown raising `EBUSY` with the process unregistered, and one
left the process counter at −1, dropped between the registration and the
count.

## The fix

`start-spawn!` still reads the caller's data once, checks it, allocates the
process handle and builds the options block, as before. Then one
interrupt-free step (`spawn-step!`, under `with-interrupts-disabled`):

1. checks the loop again (#59's `open-loop-ptr`: open, with a pointer) and
   every stdio handle (`open-handle-ptr`: open, with a pointer; and for a
   `(pipe …)` spec not consumed), answering the first refusal;
2. on a refusal, frees the options block and the process handle and
   answers it;
3. otherwise writes each stream spec's pointer into its container, from the
   handle it has just checked (`fill-stream-pointers!`; the build now
   writes only the flags and the inherited fds);
4. calls `uv_spawn` with the loop address it checked, frees the options
   block, marks the pipes;
5. registers and counts the process, or cleans up after a failure as
   ADR-0015 decisions 2 and 3 say, and answers.

The step raises nothing. `uv-spawn!` raises after it what the entry checks
raise for the same state, through #53's `step-refusal`:
`&uv-handle-closed` (kind `loop`, `pipe` or `tcp`),
`'pipe-already-used`, `'null-handle-pointer`, `'null-loop-pointer`,
`'spawn-failure-state-unclassifiable` or libuv's errno. Nothing after the
step has a trap check, so an engine that expires during `uv-spawn!` is
suspended before the step or after the verb has returned.

A pipe named twice is refused `'pipe-already-used` before anything is
allocated (`require-distinct-pipes!`), after the same-loop check, so every
input refused before keeps its old refusal.

Bytes one `uv-spawn!` call allocates, fewest of 32 (every run identical
across two alternated runs), macOS arm64, the read-once log's three shapes,
on a3750e5:

| spawn | unfixed | **fix** | the step as `one-step`, a bare interrupt pair |
|---|---|---|---|
| argv of 3, no options | 2,144 | **2,176** | 2,144 |
| argv of 5, env of 2, cwd, 3 stdio specs | 3,200 | **3,280** | 3,248 |
| argv of 3, env of 40 strings of 64 characters | 20,784 | **20,816** | 20,784 |

(Every spawn costs 144 B more than on 86de01e, the fix and the unfixed code
alike: #59's `ensure-native-loaded!` takes its lock in an interrupt-free
step. This probe also reads 16 B more than the read-once log's probe did for
the same code. Compare within a column.)

`with-interrupts-disabled` is a `dynamic-wind`: 32 B a spawn over #53's
`one-step` on this base (96 B on 86de01e). A raise inside `one-step` would
leave interrupts disabled for good, and one can happen: a fault in
`uv_spawn` arrives as a Scheme condition, `invalid memory reference`, as
M2 below shows. The read step in the same verb made the same choice; the
stream verbs, whose steps are on every write, took `one-step`.

**Drops after the fix:** the same drop probe gives 42 runs losing the
process handle and 82 losing both blocks, all dropped between the
allocations and the step, and nothing else: no `EBUSY`, no counter off by
one. Moving the allocations into the step, with #53's `alloc-block`, would
close that too; it is left to the `uv-spawn!` PR of the engine-split
series.

## The rows

`tests/test-process.sps` gains a section, "a stdio handle or the loop
changing state during the call", with six engine sweeps on a loop of their
own (`state-loop`), and a row for a pipe named twice.

| sweep | change at the first expiry | step not run: refused as | step run |
|---|---|---|---|
| close-pipe | `uv-close! p` | `&uv-handle-closed` pipe, `p` unmarked | child exits 7, `p` marked |
| close-pipe-and-replace-it | close `p`, wait for the free, make `q` | the same; `q` refuses to read (`ENOTCONN`: never opened) | the same; `q` never opened |
| consume-pipe | another spawn with `p`, its child exiting 3 | `'pipe-already-used`; the other child exits 3 | child exits 7; the other spawn refused `'pipe-already-used` |
| close-inherited-stream | `uv-close!` a bound TCP handle given as `(inherit-stream . t)` | `&uv-handle-closed` tcp | child exits 7 |
| tear-down-loop | `uv-loop-teardown!` (each run has a loop of its own) | `&uv-handle-closed` loop | spawned; the teardown closes the process |
| tear-down-loop-of-a-failed-spawn | the same, spawning a missing file | `&uv-handle-closed` loop | `ENOENT`, its handle closed by the teardown |

Each run has one right answer. At the first expiry the run notes, before
the change, whether the registry has grown since the run began (the step
registers the process, or, for a failed spawn, its handle on the way to
closing it) and whether the run's options block is allocated. A run whose
change found the step not run must come to the refusal; one whose change
found it run must come to the step's outcome with its options block freed;
the run no expiry reached must spawn untouched. Each batch of 16 (each run,
for the teardown sweeps) must leave the options blocks, processes, registry
entries, #53's blocks and the open descriptors (`/dev/fd`) as it found
them. A pipe opened into a closing handle shows only in the descriptors,
and a process handle a refusal fails to free only in the blocks.

A sweep stops at its first run no expiry reached, at fuel 3,000, or after
its first wrong or unfinished run: on the unfixed code a teardown sweep run
on would reach the abort at fuel 190 and take the evidence with it. A reach row
requires each sweep to begin with a refused run, to have seen a change find
the options block built (the last point before the step), and to end
untouched. No change lands after the step on the fix: nothing after it has a
trap check. The failed-spawn sweep is the exception, as raising `ENOENT`
runs code that does: 73 of its runs land after the step.

Each sweep's row runs as soon as the sweep ends. On a broken build a later
sweep can take the process down where no guard can catch it: with the step
no longer interrupt-free (M1), a teardown landing between `open-loop-ptr`
and `uv_spawn` hands libuv the freed loop's old address, which aborts the
process (on 86de01e it raised a catchable `invalid memory reference`
instead). So the sweeps that tear loops down run last, and the four handle
sweeps' rows are out before them. Between the two groups a row requires
the shared loop to tear down cleanly: a spawn that went wrong can leave
that loop a handle it never registered, and that teardown used to raise at
the top level, aborting the suite before any row (M1 and M3 did, first time
round).

**Red on the unfixed `process.sls`** (main's cff802b, on this branch's base),
macOS: every new row fails by name. The residue reads options blocks,
processes, registry entries, blocks, descriptors.

- close-pipe: from run 56, spawned on the closed pipe, the batch's
  descriptors left open.
- close-pipe-and-replace-it: from run 56, refused `null-handle-pointer`.
- consume-pipe: from run 56, `spawn-failure-state-unclassifiable`.
- close-inherited-stream: from run 56, refused `EINVAL` (libuv found the
  stream's descriptor gone, -1).
- tear-down-loop and the failed-spawn sweep: run 13, refused
  `null-loop-pointer`, its options block counted and both blocks lost:
  `(residue (1 0 0 2 0) …)`.
- the pipe named twice: `((refused uv-spawn! spawn-failure-state-unclassifiable)
  marked 0 (refused uv-spawn! pipe-already-used) not-yet)`.
- the reach row, and the suite's closing counter row.

**Green on the fix:** 133 rows. The sweeps take 193, 193, 193, 190, 172 and
249 runs. The replacing pipe took the closed pipe's address at every one of
the 192 changes on macOS. The four read-once sweeps take 21 runs fewer than
on the unfixed code (401 → 380, 374 → 353, 372 → 351, 378 → 357): the work
after `uv_spawn` now sits inside the step, where no expiry falls.

## Mutations

Each mutation was an exact text replacement in a fresh copy of `src/` and
`tests/` (aborted unless its target occurred once, the copy removed on any
abort), with `tests/test-process.sps` run against the copy; caught means
every predicted row failed by name. The whole table ran on 2f69e0e's tree.

| id | mutation | caught by |
|---|---|---|
| M0 | the unfixed `process.sls` | every new row (above) |
| M1 | the step is not interrupt-free | the four handle rows (close-pipe from run 198 spawned on the closed pipe; the inherited stream refused `EINVAL`) and the shared loop's teardown row (`EBUSY`); then the tear-down-loop sweep aborts the process at run 171, `uv_spawn` given the freed loop's old address |
| M2 | the step does not check the loop again (and spawns on `loop-ptr` read raw) | both teardown rows: run 13 raised `invalid memory reference` (`uv_spawn` given loop 0) and lost both blocks: `(residue (1 0 0 2 0) …)` |
| M3 | the step does not check the stdio handles again | the four handle rows, the teardown row |
| M3a | … ignores `open-handle-ptr`'s `'not-open` | close-pipe (spawned on the closed pipe), inherited stream (`EINVAL`), and the replacing sweep: a freed pipe reaches `uv_spawn` as NULL and faults |
| M3e | … lets a closing handle with its pointer through | close-pipe (spawned on the closing pipe from run 56), inherited stream (`EINVAL`) |
| M3b | … ignores `open-handle-ptr`'s `'no-pointer` | nothing: equivalent (below) |
| M3c | … skips the pipe's consumption | consume-pipe (`spawn-failure-state-unclassifiable`) |
| M3d | … checks pipes only, not inherited streams | close-inherited-stream (`EINVAL`) |
| M4 | the containers get their stream pointers before the step, from the raising accessor (the unfixed fill) | close-pipe-and-replace-it (`null-handle-pointer`) |
| M5 | the process is registered after the step | close-pipe, replace, consume, inherited stream: from run 193 the change found nothing registered yet the spawn went ahead; tear-down-loop: run 172, the teardown raised `EBUSY` |
| M6 | the pipes are marked after the step | consume-pipe: the other spawn found `p` unmarked and reached the unclassifiable state |
| M7 | the options block is freed after the step | the failed-spawn sweep and the five others: `step-run block-still-built` |
| M8 | a failed spawn is cleaned up after the step | the failed-spawn sweep: run 176, the teardown raised `EBUSY` |
| M9 | the unclassifiable state raises inside the step | nothing: equivalent (below) |
| M10 | a refusal in the step does not free the options block | every sweep, e.g. a close-pipe batch: `(residue (9 0 0 9 0) before)` |
| M11 | a refusal in the step does not free the process handle | every sweep, by #53's block counter alone, e.g. `(residue (0 0 0 9 0) before)`; and the memory gate (below) |
| M12 | a pipe named twice is not refused | the pipe-named-twice row, and the closing counter row: #53's block counter sees the handle the unclassifiable state leaks |
| M12a | the duplicate refusal leaves the pipe marked | the pipe-named-twice row (`marked`, and the spawn naming it once refused) |
| M13 | a closed handle is refused as an invalid argument | close-pipe, replace, inherited stream (`(refused uv-spawn! not-open)`) |
| M14 | a torn-down loop is refused as an invalid argument | both teardown rows (`(refused uv-spawn! loop-not-open)`) |
| M15 | `open-loop-ptr` (#59's, in `handles.sls`) reads only the pointer | both teardown rows (`null-loop-pointer`) |
| M16 | `open-loop-ptr` reads only the state | nothing: equivalent (below) |
| M17 | the entry check no longer refuses a consumed pipe | nothing: equivalent by design (below) |
| H1 | the sweeps' fuel cap is 5 | both reach rows |
| H2 | no change ever finds the options block built | the reach row |
| H3 | M3e with every not-run verdict forced right | close-pipe, by the descriptor count alone: `(residue (0 0 0 0 9) before)` |
| H4 | a batch waits one loop step for its children | the four shared-loop rows, each run unfinished; no hang |
| H5 | H3 with the descriptor count dead | nothing, as it must: H3's control |

## Uncovered

- **M3b and M16, the pointer checks, are equivalent.** An open handle and
  an open loop always have their pointer: it is zeroed only where the state
  leaves `'open` for good. The checks stand for the entry checks they
  repeat (`handle-pointer`, `loop-pointer`), so that a state nothing can
  reach today is refused rather than handed to libuv as NULL.
- **M9, the unclassifiable state, is unreachable** on the fix: the step's
  consumption check and the duplicate check foreclose both triggers found,
  and the macOS `SO_OOBINLINE` arm (ADR-0015 decision 5) is a
  `setsockopt` failure on a fresh socketpair, which no row can provoke.
  Raising inside the step there would be safe anyway:
  `with-interrupts-disabled` re-enables interrupts on the way out.
- **M17 is equivalent by design.** The entry checks still refuse a closed
  handle or a consumed pipe before anything is allocated, which is the
  common case; the step refuses the same state after allocating, and frees
  both blocks. No row can tell the two apart.

## Harness notes

- **libuv opens a descriptor on a loop's first stream and keeps it until
  the loop closes:** `/dev/null`, held in reserve for `EMFILE`
  (`uv__stream_init`, `loop->emfile_fd`). The first batch on a fresh loop
  counted it as a leak (+1). The section spawns once on a pipe before any
  batch counts. Separately, a process's first loop opens libuv's signal
  lock pipe (two descriptors, `uv__signal_global_once_init`), kept for the
  process's life; earlier sections have made loops by then. Each loop's
  own two descriptors (its kqueue among them on macOS) close with it.
- **Absolute counters carry an earlier sweep's leak into later ones.** The
  first form compared the options blocks against 0 and took "built" as any
  block alive, so on a broken build one sweep's leaked block failed the
  next sweep at fuel 1 under the wrong name. Baselines are now per batch,
  and per run for "built".
- **A check-skipping mutation can take a wider window than it names.**
  `open-handle-ptr` answers `'not-open` for a closing handle and for a
  freed one alike, so ignoring that answer (M3a) also sends a freed pipe
  to `uv_spawn` as NULL, which faults and fails rows H3 was not about.
  M3e lets only a closing handle with its pointer through: the original
  defect, and the one H3 needs.
- **No change lands after the step on the fix,** so the reach row cannot
  ask for one, as the read-once rows do. It asks instead that some change
  found the options block built, which is the last point before the step.
- **The race row's narrower outlived its last word.** Found here, and
  fixed in #56 as 0d3487e. The narrower set a flag under a mutex as its
  last act, and the suite's closing `(collect)` raised "cannot collect
  when multiple threads are active" when the main thread got there before
  the thread had exited: 2 of 27 mutation runs at load averages of 30 to
  60, exit 255 after every row had run. A narrower spinning after its flag
  failed the suite 2 of 2; `thread-join` passes that widened copy 2 of 2.
- A loopback flood from another session ran 07:37–07:49 EDT on 2026-10-06;
  the first `make test` of the fix ran in it, and test-facade's seven TCP
  rows failed. The re-run after it passed (Gates).

## Found on the way, not fixed here

- **Drops between the allocations and the step** (above): left to the
  `uv-spawn!` PR of the engine-split series, which has PR #53's allocator.
- **The read-once section tears its sweep loops down at the top level,
  unguarded,** as the state section did before its row: a spawn that
  leaves the loop a handle it never registered would abort the suite there.
  On the fix nothing does.

## Gates

On the branch on `main`'s a3750e5 (the docs commit on top changes no code),
macOS arm64:

- `make test`: 23 suites pass (`test-process.sps`: 133 rows; in the race
  row 199 of 200 children reported the argument mid-change).
- `make test-memory` (ASan): 23 suites pass.
- `make check-memory-gate`: the planted libc overrun and #55's shim overrun
  were caught, MEMORY GATE CAN FAIL.
- `make check-purity` holds, and `make check-help` is silent.

`make test-memory-docker` (Linux aarch64, Valgrind 3.19, vendored libuv
1.52.1) from a `--no-hardlinks` clone of the docs commit, make exit 0:

- `check-memory-gate` caught the store overrun, the libc overrun, the shim
  overrun and the leak, stayed consistent on the possible leak, and
  printed MEMORY GATE CAN FAIL.
- Every suite's own Valgrind summary (23 suites): 0 errors and 0 bytes
  definitely lost, at 773 to 24,286 allocations (`test-process.sps`:
  24,286).
- 76 forked children report their own summaries, none of which gates
  (ADR-0003): the two known exec-failure artifacts (131 B and 117 B), and
  74 from the failed-spawn teardown sweep (69 of 147 B in 1 block, 5 with
  nothing lost; the shape follows how the base allocates a loop, and was
  275 B in 2 blocks on 86de01e). Each child fails its exec and exits, and
  Memcheck counts what the parent held at the fork, the run's own loop
  among it, as lost. The parent's summary is clean.

**M11 under Valgrind:** the same image and recipe, `MEMORY_TESTS` set to
`tests/test-process.sps`, with M11 applied to the branch as it was on
86de01e: make exit 2, `3,944 bytes in 29 blocks are definitely lost …
calloc … by chez_uv_alloc (libuv-shim.c:387)`, 29 process handles of
136 B, one per refused run before each sweep stopped. On this base #53's
block counter also catches M11 in plain `make test` (Mutations).
