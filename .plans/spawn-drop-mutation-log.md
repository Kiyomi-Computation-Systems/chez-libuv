# uv-spawn! allocates in the step that spawns: mutation log

Evidence for `fix/spawn-drop` (issue #63), on `main`'s a473313 (#65). This
is the drop half of the engine-split series' `uv-spawn!` family. #60
(48457d7) made the step that spawns check its stdio handles and its loop
again, and left the allocations before that step.

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 26.6 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config, the
dev build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image (Debian
bookworm, Valgrind 3.19, vendored libuv 1.52.1), from a `--no-hardlinks`
clone.

---

## The bug, confirmed

`start-spawn!` read the caller's data once, checked it, and allocated the
process handle (`alloc-zeroed`). It then allocated, counted and built the
options block (`build-options-block`), and only then entered `spawn-step!`.
That interrupt-free step checks the loop and the stdio handles again, calls
`uv_spawn`, frees the options block and registers the process. A scheduler
can drop an engine at its expiry, as a timeout drops a task, and never
resume it. Nothing after the expiry then runs, neither a `guard` nor a
`dynamic-wind` exit. So a drop anywhere between the first allocation and
the step stranded the handle, or the handle and the options block.

A scratch probe ran `uv-spawn!` in an engine at fuel 1, 2, …, after one
warm-up spawn, with stdio `(ignore (pipe p from-child))` and the child
`/bin/sh -c "exit 7"`. Each run had a loop of its own. The probe dropped
the engine at its first expiry, closed the pipe and tore the run's loop
down. It then recorded what was left: options blocks, processes, registry
entries, #53's `'block` counter and `/dev/fd`. On a473313:

| fuel | runs | left behind |
|---|---|---|
| 1–66 | 66 | nothing |
| 67–108 | 42 | 1 block (the process handle) |
| 109 | 1 | 2 blocks (the options block, not yet counted) |
| 110–190 | 81 | the options block, counted, and 2 blocks |
| 191 | 1 | (completed) |

124 of the 190 dropped runs leak. That is the issue's table, measured on
48457d7, to the run, five fuels later. Every teardown finished. Two spawns
that fail show the same window:

- a missing file, which libuv forks for and fails with `ENOENT`, leaked at
  fuel 96–194;
- an inherited stream that was never opened, which libuv refuses with
  `EINVAL` before it forks, leaked at fuel 52–137.

Their drops after the step left nothing, since the step had already
cleaned the failure up.

## The fix

The options block's layout is worked out from the request before the step
(`layout-options-block`): the process handle's size, the block's size, and
where its arrays and strings begin. Nothing is allocated there. The step
that spawns is still one `with-interrupts-disabled`, and now:

1. checks the loop and every stdio handle again, as #60's step did, and
   answers a refusal with nothing allocated;
2. allocates the process handle (`alloc-block`) and the options block
   (`alloc-options-block`, which counts only a block it got). Both answer 0
   rather than raising; if either is refused, the step frees both and
   answers `'no-memory`, which `step-refusal` raises as ENOMEM;
3. fills the options block (`fill-options-block!`) and raises nothing
   doing it. A string that would not fit, or a number its C type cannot
   hold, is not written: the fill answers `#f`, the step frees both blocks
   and answers `'options-not-written`, and the verb raises a `&uv-error`
   naming the binding's own fault. The checks before the step refuse the
   same numbers through the same predicates (`c-int-fd?`, `u32?`,
   `stdio-spec-flags` answering `#f`), so only a check that has drifted
   from the fill reaches that path. The strings are copied with
   `copy-in-unchecked!`: the request's bytevectors are private to the call,
   and the step is already interrupt-free. Each stdio container, its flags
   and its fd or stream pointer, is written in one walk;
4. makes the process record and registers it with `registry-add!` before
   libuv sees the block, as a constructor registers its handle before its
   init (`register-then-init!`). A refused registration frees both blocks
   and is answered, with nothing forked and no pipe marked;
5. calls `uv_spawn`, frees the options block, marks the pipes, and counts
   the process, or cleans up the failure. The cleanup keeps the entry of a
   handle libuv still queues and closes it, and removes the entry of one
   libuv unlinked, and of the unclassifiable state, before freeing or
   leaving it.

The verb returns the process, or raises after the step what it answered
(`spawn-refusal`). So `uv-spawn!` holds nothing until its step, and once
past it nothing the loop does not hold.

Bytes one `uv-spawn!` call allocates, fewest of 32 (identical across two
alternated runs), macOS arm64:

| spawn | main | first push (ed58f9b) | **now** |
|---|---|---|---|
| argv of 3, no options | 2,176 | 1,184 | **1,056** |
| argv of 5, env of 2, cwd, 3 stdio specs | 3,520 | 2,048 | **1,824** |
| argv of 3, env of 40 strings of 64 characters | 20,848 | 16,016 | **15,888** |

Against main, each string saves 96 B, the `with-interrupts-disabled` that
`copy-in!` put around its copy, and each spawn saves 608 B more, the two
`guard`s around the old build, net of the layout record (the first push,
measured by swapping `copy-in!` back in: 1,568, 2,912 and 20,240 B). The
review's round saved 128–224 B more: the size fold no longer builds a list
of the strings to fold (96–160 B), the fill's cursor is passed along
rather than boxed (16 B), and the step's closure no longer holds the
handle's size (16 B).

The step's `with-interrupts-disabled` costs 96 B over `one-step` (1,056
against 960 B), as it did on a473313 (2,176 against 2,080). #60's comment
and log said 32 B, which does not reproduce on #60's own commit either, and
the first push said 112 B, for a closure two variables wider. It stays, for
#60's reason: a fault in `uv_spawn` arrives as a Scheme condition, and the
bracket re-enables interrupts after it. It does not after a raise inside
the failure cleanup's close, which is a `one-step` of its own
(`begin-close!`); the step's comment says so.

## The rows

`tests/test-process.sps` gains a section after the state sweeps, "an engine
dropped during the call", with two drop sweeps:

| sweep | spawn | a run no expiry reached |
|---|---|---|
| spawn | `(ignore (pipe p from-child))`, `/bin/sh -c "exit 7"` | spawned; exit `(7 #f)` |
| refused-by-libuv | `((inherit-stream . p))`, `p` never opened, `/bin/cat` | `EINVAL`, before any fork |

Each run makes a loop and a pipe of its own and runs the spawn in an engine
at the run's fuel. It drops the engine at the first expiry, noting first
whether the step had run: the step marks the pipe consumed, an inherited
one too. The run then waits for any child the step started, closes the
pipe, and tears the loop down, which must finish. Its verdict is `dropped`
or `untouched` only if interrupts are enabled, and the options blocks,
processes, registry entries, blocks and open descriptors are back where
they were before the run's loop was made. A sweep stops at its first run
no expiry reached, at fuel 3,000, or after its first wrong run.

- **Reach.** A row requires each sweep to have run at every fuel from 1, its
  first run dropped and its last untouched (`every-fuel`). A second row
  requires the refused spawn's sweep to have dropped some runs after the
  step, where its refusal is raised: that is where a failure's cleanup left
  out of the step would be stranded.
- **A spawn that succeeds may be dropped after its step.** The first push
  asserted it never was. But a collection that comes due inside the step is
  taken where the step re-enables interrupts, and that spends about three
  ticks, so an engine with a tick or two left expires there. The review
  reproduced it at the default collect trip by aligning the allocation
  before the boundary run: the sweep's rows ended `(104 run dropped)` in 3
  of 3 sweeps, the reach row failed on correct code, and each left a
  zombie child. The suite as committed never met it (30 runs: the phase
  sat 4.7 MB short of the trip), but nothing guaranteed that. Such a run is
  now a right answer, and the run waits for the child it started.
- **A squatted block.** "a spawn whose handle block another entry holds"
  frees eight handle-size blocks through the shim with entries left at
  them, so the shim hands one back to the spawn's step (test-native.sps's
  seed). The spawn must be refused `pointer-already-registered` with the
  pipe unmarked, the loop torn down, and nothing left. Neither memory tool
  hands a freed block back, so under either the row asks only that the
  spawn ran and left nothing. The plain row passed on macOS and on glibc
  2.39 (Ubuntu 24.04).
- **Titles live in the variant records**, the state sweeps' too. Looked up
  in an alist outside SRFI-64's catch, a variant without one aborted the
  suite with exit 255 after its sweep had run.

The state sweeps' reach row changes. #60's required a change to find the
options block built, its witness that a sweep reached the last point before
the step. The step now makes the block, so no change can. The first push
expected `#f` there, the field's seed value, which a dead witness, deleting
both count calls, or stepping the fuel by 100 all passed. The row now
requires `every-fuel` instead, and the drop sweeps hold that nothing is
allocated before the step. The per-run witness stays: it fails a run whose
change found the block built (D10 on the first push), though nothing
proves it live on this code (Uncovered).

**Red** (macOS, each `process.sls` under these tests):

- main's (a473313), 7 rows by name, 132 pass: both drop rows (fuel 70 and
  55, `(residue (0 0 0 1 0) (dropped not-yet))`), the drop reach row, the
  after-the-step row (`none`: both sweeps stopped early), the squatter row,
  and the closing counter and registry rows.
- the first push's (ed58f9b), 3 rows, 136 pass: the squatter row,
  `((refused uv-registry-register! pointer-already-registered) marked
  (errno EBUSY) (0 0 1 2 3))`: the child ran, its handle stayed in the loop
  unregistered, and the run left an entry, two blocks and three
  descriptors; and the closing counter and registry rows.

**Green:** 139 rows. The drop sweeps take 95 runs (94 dropped before the
step, none after) and 131 (67 before, 63 after). The read-once sweeps take
231/204/201/208 runs (main: 380/353/351/357), and the state sweeps
94/94/94/88/80/176 (main: 193/193/193/190/172/249): the build no longer
costs fuel. The probe above finds nothing left in any of its three
variants. On libuv 1.48 (Ubuntu 24.04's, CI's pkg-config leg) the refused
spawn takes the exec-class arm, its handle registered and closed, and the
sweep is the same, 63 drops after the step.

## Mutations

Each mutation is a set of exact text replacements in a fresh scratch copy
of `src/` and `tests/`, aborted unless each target occurs exactly once.
`tests/test-process.sps` then runs from the copy. A mutation is caught when
every predicted row fails by name, with the evidence of the property that
row asserts. Two mutants are armed by an environment variable the mutated
test sets around the drop sweeps, so that they act there only. 39
mutations ran (R4 twice: unarmed it crashed the suite, armed it is R4n):

- 33 are caught;
- 5 are equivalent or uncovered (below);
- H3 is a counterfactual, which must leave the drop rows green.

| ID | mutation | caught by |
|---|---|---|
| D0 | main's `process.sls` | the 7 rows above |
| R0 | the first push's `process.sls` | the squatter row and the closing rows (above) |
| D1 | the process handle allocated before the layout, outside the step (a refusal frees it) | both drop rows (`(residue (0 0 0 1 0) …)` at fuel 75 and 55), the drop reach row, the closing counters |
| D2 | the options block allocated and counted there too | both drop rows (fuel 97 and 70), the drop reach row, the closing counters |
| D4 | the step allocates before its checks, and a refusal keeps both blocks | all six state rows (`(residue (9 0 0 18 0) before)`: a batch's nine refusals), the reach row, the closing counters |
| D5 | the fill's string bound is gone | nothing: equivalent (below) |
| D6 | the layout leaves out every NUL in a spawn whose env holds `W=w` (#56's M10n) | the four read-once sweep rows and their reach row, every run refused by name; the counters stay at zero |
| D6b | D6, and options not written keep the process handle | D6's rows and the closing counters |
| D6c | D6, and options not written keep the options block | D6's rows and the closing counters |
| D6d | D6, the refusal raised as the caller's `&uv-invalid-argument` | D6's rows only: uncovered (below) |
| D7 | the step is not interrupt-free | the four handle state rows; then the tear-down-loop sweep aborts the process (SIGABRT), as #60's M1 did |
| D7n | D7, with the teardown state sweeps skipped | both drop rows, and D7's rows |
| D8 | the process registered after `uv_spawn`, with the raising `registry-register!` (the first push's order) | the squatter row: the child ran, `(errno EBUSY)` |
| D8b | the process registered and counted after the step | the six state rows (`step-not-run`, the spawn made though nothing was registered) and more: 11 rows |
| D9 | a failed spawn cleaned up after the step | the failed-spawn teardown row (`invalid memory reference`: the teardown had closed the registered handle, and the deferred cleanup read it), the refused drop row, the reach and closing rows |
| D11 | the options block not counted | 23 rows: every counter row (`-1` …), every sweep |
| D12 | the fill copies none of `argv-one`'s bytes | "argv[0], argv[1], env, and cwd all arrived as written" (`"argv-zero\|\|from-env\|/"`) |
| D13 | the fill's next offset leaves out `argv-zero`'s NUL | the same row (`"argv-zeroargv-one\|argv-one\|from-env\|/"`) |
| D14 | the fill leaves the env array unpointed | the same row, the empty-env row, the read-once rows |
| D15 | freeing the options block does not uncount it | 23 rows, as for D11 |
| D16 | a refused allocation keeps the other block | nothing: unreachable (below) |
| D17 | a refused allocation is not refused | nothing: unreachable (below) |
| T1 | `stdio-spec-flags` answers flags for an unknown direction | "an unknown (pipe ...) direction" (`no-raise`), "validation created no process handle" (1) |
| T2 | the entry's direction check removed | "an unknown (pipe ...) direction" only: the fill refused it, and the counters stay at zero |
| T2b | T2, and the fill writes without its checks | that row, the options-counter rows, the read-once rows and the closing counters: 9 rows, both blocks lost |
| T3 | the entry's fd bound removed (fd 2^31) | "an inherit-fd value too wide for the C int container field" only: the fill refused it |
| R1 | a refused registration keeps the process handle | the squatter row (`(0 0 0 1 0)`), the closing counters |
| R2 | a refused registration keeps the options block | the squatter row (`(1 0 0 1 0)`), the closing counters |
| R3 | the unclassifiable arm keeps the entry | nothing: unreachable (below) |
| R4n | the setup-class arm keeps the entry, in the drop section | the refused drop row (fuel 68, after the step: `discard-failed-handle!` refused the registered handle, and the teardown closed what libuv had unlinked, the process counter at −1), the reach row, the closing counters. Unarmed, R4 raised from the suite's first setup-class failure, at top level: exit 255, a crash, not a kill |
| R5 | the exec-class arm removes the entry before closing | "the failed spawn's handle is gone once the loop has turned" (`iterations-exhausted`: the close found no entry) and 5 more |
| H1 | the drop sweeps' fuel cap is 5 | the drop reach row (both end `dropped`) and the after-the-step row |
| H2 | the drop sweeps resume the engine instead of dropping it | the drop reach row (both begin `untouched`) |
| H3 | D1, with the residue blind to blocks | the closing counters only: both drop rows pass, so `'block` is the column that catches D1 |
| H4 | the refused spawn refused on entry instead (empty args) | the after-the-step row (`none`) |
| H5 | the drop sweeps never see the step run | the after-the-step row |
| H6 | the state sweeps step their fuel by 100 | the state reach row (`(skipped-to 101 at 2)`) |
| H7 | the drop sweeps step their fuel by 2 | the drop reach row (`(skipped-to 3 at 2)`) |
| H8 | a refusal raised after the step leaves interrupts disabled, in the drop section | the refused drop row, `(interrupts-left-disabled ((errno EINVAL) not-yet))`, and the reach row |

## Uncovered

- **D5, the fill's string bound, is equivalent on the fix**, as #56's M9
  was. The layout sizes the block from the same bytevectors the fill
  copies, and nothing else can reach them. The bound's job is D6's: a
  layout that disagrees with the fill becomes a refusal by name in plain
  `make test`, not an overrun only the memory gate sees.
- **D6d: the refusal's condition is uncovered.** Only a mutation reaches
  `'options-not-written`, and D6's rows fail whether the verb raises
  `&uv-error`, as it does, or `&uv-invalid-argument`. The review weighed
  dropping the special arm and kept it: `&uv-invalid-argument` is the
  caller's error (docs/api.md), and this is the binding's.
- **D16, D17 and R3 are unreachable.** The handle's size is libuv's and the
  block's comes from the caller's strings, and no test can make calloc
  refuse either (#59's M14). Both blocks come from allocators that answer
  0, and `free-block!` and `free-options-block!` ignore 0, so the refusal
  frees both whichever failed; where the count happens no longer matters.
  The unclassifiable state is foreclosed by #60's checks.
- **Deleting both options-block count calls passes every row.** The count
  is nonzero only inside the step, where no test code runs, so no row can
  see a spawn count its block. A block left over is still seen: `'block`,
  in every residue and in the closing row, counts it either way.
- **The per-run `built` witness has no liveness row.** It reads `#f` on
  every run of this code, and a dead witness passes too. D10 on the first
  push showed it fire; the drop rows catch the same mutations by `'block`.
- **`free-options-block!` frees with `free-block!`**, not the raising
  `free!`: equivalent for the blocks it is given, and total for 0.
- **The window between the entry checks and the step** is reached on this
  code (#60's M3, the step's re-check deleted, fails four state rows at
  fuels 56–63), but no row requires the window to exist. If a refactor
  closed it, the re-check would be redundant rather than wrong.

## The review (#68)

A max-effort /code-review ran on the first push: ten finder angles, one
verifier per candidate, then a sweep for gaps. 15 findings survived. Each,
and what became of it:

| finding | what was done |
|---|---|
| the drop reach row's "no drop after a successful step" can fail on correct code (above) | dropped; a separate row for the refused spawn's drops after its step; the run waits for a child the step started |
| the state reach row expects the seeded `#f` | `every-fuel` instead (H6) |
| a raise in the fill, now inside the step, strands both blocks where main's guards freed them | the fill is total and the checks share its predicates (T1–T3); a guard instead would have cost 368 B a spawn |
| the process registered after the fork, with a raising call | registered first (R1, R2, R4n, R5; the squatter row) |
| the bracket's comment overclaims interrupt safety | reworded: not after a raise inside the close's own `one-step` |
| no interrupt check in the drop driver | added (H8) |
| the options counter's position between two free arms | `alloc-options-block` counts only a block it got; both frees ignore 0 |
| a variant without a title aborts the suite | titles in the variant records |
| docs/api.md's list of verbs not to abandon omits the scratch verbs | listed |
| ADR-0015 decision 5's dated note describes the old step | annotated |
| a stale "nothing after the step can expire" comment | rewritten for the failed spawn |
| this log misattributed the bracket's cost | corrected above |
| the size fold's throwaway list | folded directly |
| **pre-existing:** the registry and `walk-query-cell` are shared, unlocked, by every loop's thread | issue #70 |
| **pre-existing:** a split `uv-process-kill!` signals another process at the freed handle's address | issue #71 |

Also taken, below the cap: the second walk over the stdio specs, which the
step's split from the build had made, is gone. Refuted by the verifiers:
the string-order comment, and dropping `spawn-refusal`'s special arm.

## Harness notes

- **A mutant that keeps its state in a library global is not a mutant of
  the code.** The first push's first D2, D3 and D10 parked the early block
  in one global. The consume-pipe sweep's change spawns inside the expiry
  handler, and its spawn overwrote the global; the outer spawn then freed
  the inner one's block. All three died of SIGABRT. Threaded through the
  step's arguments and results instead, they fail by name.
- **The fill's mutations crash the suite at its first spawn**, which is
  unguarded top-level plumbing (exit 255). Sizing short everywhere,
  copying no bytes, and a cursor that skips every NUL all did. Narrowed to
  one row's strings (D12, D13) or to the read-once sweeps' spawns (D6, as
  #56 narrowed M10 to M10n), each fails its predicted rows by name. R4 was
  narrowed the same way, with an environment variable.
- **D7 aborts before the drop sweeps run**, in the tear-down-loop sweep,
  which #60 runs after the other state sweeps for that reason. D7n skips
  those sweeps, to show the drop rows catch D7 on their own.
- **A collection taken at a step's end spends engine fuel there.** The
  timer does not tick inside the step, but a collect request that comes
  due in it is serviced at `enable-interrupts`, about three ticks: fuel 3–5
  expired after a step where fuel 3 completed without the collection. A
  reach row must not assert where expiries cannot land unless no
  collection can come due in between.
- **The probe's long tails after the step were its own handler.** It
  formatted each refusal with `describe` inside the engine, about 600
  expiries past the step. The suite's handler (`spawn-outcome`) reads only
  the errno.
- **The witness of the step is the pipe's mark**, taken at the expiry
  before the drop. The step marks every pipe a spec names, an inherited one
  too (ADR-0015's Stage 5 amendment), so both sweeps can read it. H5 shows
  the after-the-step row needs it.

## Gates

On the branch rebased onto main's 2511d17 (#69), the tree pushed.

macOS arm64:

- `make test`: 24 suites pass (`test-process.sps`: 139 rows).
- `make test-memory` (ASan): 24 suites pass (139 rows).
- `make check-memory-gate`: the planted libc overrun and the shim overrun
  were caught, MEMORY GATE CAN FAIL.
- `make check-purity` holds, and `make check-help` is silent.

Linux, plain, Ubuntu 24.04 with apt libuv 1.48.0 and glibc 2.39 (CI's
pkg-config leg), in `chez-libuv-noble-scratch:10.4.1`: `make test`, 24 suites
pass (`test-process.sps`: 139 rows, the squatter row on glibc's allocator,
the refused spawn through the exec-class arm).

`make test-memory-docker` (Linux aarch64, Valgrind 3.19, vendored libuv
1.52.1) from a `--no-hardlinks` clone, make exit 0:

- `check-memory-gate` caught the store overrun, the libc overrun, the shim
  overrun and the leak, stayed consistent on the possible leak, and printed
  MEMORY GATE CAN FAIL.
- Every suite's own Valgrind summary (24 suites): 0 errors and 0 bytes
  definitely lost. `test-process.sps` passed 138 rows (the race row skips
  under Valgrind) at 15,793 allocations, against #60's 24,286: its sweeps
  are shorter.
- 76 forked children report their own summaries, none of which gates
  (ADR-0003): the two known exec-failure artifacts (131 B and 117 B), and
  74 from #60's failed-spawn teardown sweep (57 of 147 B in 1 block, 17 with
  nothing lost). The drop sweeps add none: the refused spawn fails before
  libuv forks.

The same recipe, run on the drop rows against main's `process.sls` (one
suite, `MEMORY_TESTS=tests/test-process.sps`), fails them by name, and
Valgrind reports the leak itself: `136 bytes in 1 blocks are definitely
lost`, allocated by `chez_uv_alloc`, exit 2. The other stranded handle was
still reachable (+136 B in one more block than the clean run), so the
gate's own report of a drop depends on a stale pointer being gone; the
suite's `'block` column does not.

The first push's gates, on a473313, are superseded by these.

## The squatter row on CI (2026-10-07)

The row "a spawn whose handle block another entry holds is refused before it
forks, leaving nothing behind" failed on CI's vendored pass in two runs:
37611536379 (PR #73, 11:04 UTC) and 37613004038 (PR #74, 11:18 UTC). #74's
`make test` ran main's `src/` and `test-process.sps` byte for byte. Both
printed `(spawned marked torn-down (0 0 0 0 0))`: the spawn forked, so its
handle block was not one the row had planted. Main's two runs since #68
(09:32 and 09:50 UTC) and both runs' pkg-config passes passed the row.
Neither the arm64 noble image nor the x86_64 Debian image (glibc 2.36,
under emulation) failed it in a full `test-process.sps`.

**Why.** The row freed 8 handle-size blocks in a row, entries left at
them, and relied on the shim's `calloc` handing one back to the spawn's
step. glibc's `calloc` skips the thread's cache, where the first 7 frees of
each size go, and returns the oldest free block of an exact size first.
So when earlier sections of the suite had left free blocks of a process
handle's size, the step was given one of those, unregistered, and forked.
That depends on the heap the earlier sections left, which is why two CI
runs failed the row while main's two passed it.

**Reproduced** by seeding the heap first: 16 unregistered handle-size blocks,
each between kept spacers, freed, then one 176 B allocation so that glibc
sorts them into its small bin, as earlier spawns can leave them. The
scenario run 20 times on its own (a scratch probe), handle 136 B:

| Layout | Clean heap, arm64 glibc 2.39 | Seeded, arm64 glibc 2.39 | Seeded, x86_64 glibc 2.36 |
|---|---|---|---|
| 8 blocks in a row (the row) | 20 of 20 squatted | 1 of 20 | 1 of 20 |
| 16 blocks, each between kept spacers | 20 of 20 | 20 of 20 | 20 of 20 |
| 64 blocks, each between kept spacers | 20 of 20 | 20 of 20 | 20 of 20 |

The seeded result also tells how `calloc` chooses. Had it taken from the
thread's cache, the old row would have squatted there: its 8 allocations
took the seeded blocks, and its 8 frees went where `calloc` looks next.

In the suite itself, with the same seeding placed just before the row, in
the noble image (vendored libuv): the old row failed 3 of 3 runs with
CI's exact `(spawned marked torn-down (0 0 0 0 0))`, and the new row passed
3 of 3. Each seeded run also failed "counters all zero at suite end",
because the scratch seeding never frees its spacers.

**The fix** (test-only, `test/squatter-row`). The row plants 64 blocks,
each allocated between two spacers that are kept until the spawn is over.
The spacers stop glibc merging a freed planted block with a freed
neighbour, and allocating 128 blocks takes up the older free blocks of that
size first. A precondition row now names the seed: the next handle-size
block the shim allocates must be one an entry still names. When the main
row fails, a failed seed points at the allocator and a held seed points at
the code. Under the memory tools the row keeps its weak form.

**Watched fail:**

- **The defect the row exists for.** M1 has `spawn-from-block!` ignore a
  refused registration (`(if #f …`). The main row failed by name with
  `(spawned marked (errno EBUSY) (0 1 1 2 3))`, and the precondition
  passed. The suite's closing counter and registry rows failed too: the
  forked process's handle was left unregistered.
- **The CI failure.** The seeded suite, as above.
