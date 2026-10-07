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

The options block's layout, its size and where its arrays and strings
begin, is worked out from the request before the step
(`layout-options-block`). Nothing is allocated there. The step that spawns
is still one `with-interrupts-disabled`, and now:

1. checks the loop and every stdio handle again, as #60's step did, and
   answers a refusal with nothing allocated;
2. allocates the process handle and the options block with `alloc-block`,
   which answers 0 rather than raising. If either is refused, the step frees
   both and answers `'no-memory`, which `step-refusal` raises as ENOMEM;
3. counts the options block and fills it (`fill-options-block!`). The
   strings are copied with `copy-in-unchecked!`: the request's bytevectors
   are private to the call, and the step is already interrupt-free. A
   string that would not fit is answered as `'options-block-too-small`;
   the step frees both blocks, and the verb raises the condition the fill
   used to raise;
4. makes the process record on the handle block, writes the stream
   pointers from the handles it has just checked, calls `uv_spawn`, frees
   the options block, marks the pipes, and registers the process or cleans
   up after a failure (`spawn-from-block!`, #60's tail, unchanged).

The verb returns the process, or raises after the step what the step
answered (`spawn-refusal`). So `uv-spawn!` holds nothing until its step.
Once past the step, it holds nothing the loop does not hold.

Bytes one `uv-spawn!` call allocates, fewest of 32 (identical across two
alternated runs), macOS arm64:

| spawn | main | **fix** | fix, strings copied with `copy-in!` |
|---|---|---|---|
| argv of 3, no options | 2,176 | **1,184** | 1,568 |
| argv of 5, env of 2, cwd, 3 stdio specs | 3,520 | **2,048** | 2,912 |
| argv of 3, env of 40 strings of 64 characters | 20,848 | **16,016** | 20,240 |

The saving has two parts. Each string saves 96 B, the
`with-interrupts-disabled` that `copy-in!` put around its copy. Each spawn
saves 608 B more, the two `guard`s around the old build, net of the layout
record. The step's own `with-interrupts-disabled` now costs 112 B over
`one-step` (1,072 B for argv of 3), where #60 measured 32 B: its closure
holds six variables, not four. It stays, for #60's reason. A fault in
`uv_spawn` arrives as a Scheme condition, and must not leave interrupts off.

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
one too. The run then closes the pipe, waits for any child the spawn
started, and tears the loop down. Its verdict is `dropped` or `untouched`
only if the teardown finished and the options blocks, processes, registry
entries, blocks and open descriptors are back where they were before the
run's loop was made. A sweep stops at its first run no expiry reached, at
fuel 3,000, or after its first wrong run. The refused spawn still has a
refusal to raise after its step, so some of its drops land there.

Each sweep's row runs as soon as the sweep ends. A reach row requires each
sweep to drop its first run and to end untouched. It also requires the
refused spawn, and only that one, to have drops after its step: a spawn
that succeeds has nothing after its step that can expire.

The state sweeps' reach row changes. No change can now find the options
block built, so its third column expects `#f` where #60's expected `#t`.
That column was #60's witness that a sweep reached the window before the
step. The window now holds nothing, and the column holds that instead.

**Red on the unfixed `process.sls`** (a473313), macOS: 5 rows fail by name,
132 pass.

- The spawn drop row: fuel 70, `(residue (0 0 0 1 0) (dropped not-yet))`,
  the process handle.
- The refused-spawn drop row: fuel 55, the same.
- The drop reach row: both sweeps stopped at those runs.
- The state reach row: every sweep found the options block built (`#t`).
- The closing counter row: the two blocks the stopped runs left.

**Green on the fix:** 137 rows. The drop sweeps take 104 runs (103 dropped
before the step, none after it) and 142 (78 before, 63 after). The build no
longer costs fuel, so the other sweeps shorten. The read-once sweeps drop
from 380/353/351/357 runs to 244/217/213/221. The state sweeps drop from
193/193/193/190/172/249 to 103/103/103/102/94/187. The probe above finds
nothing left in any of its three variants.

## Mutations

Each mutation is a set of exact text replacements in a fresh scratch copy
of `src/` and `tests/`, aborted unless each target occurs exactly once.
`tests/test-process.sps` then runs from the copy. A mutation is caught when
every predicted row fails by name, with the evidence of the property that
row asserts. 27 mutations ran:

- 22 are caught;
- 4 are equivalent or uncovered (below);
- H3 is a counterfactual, which must leave the drop rows green.

| ID | mutation | caught by |
|---|---|---|
| D0 | the unfixed `process.sls` | the two drop rows, the drop reach row, the state reach row, the closing counters (above) |
| D1 | the process handle allocated before the layout, outside the step (a refusal frees it) | both drop rows (`(residue (0 0 0 1 0) …)` at fuel 70 and 55), the drop reach row, the closing counters |
| D2 | the options block allocated and counted there too: main's shape | the same rows, and the state reach row (`#t`) |
| D3 | D2, with the block counted only in the step | both drop rows, by `'block` alone; the state reach row stays green, as it must |
| D4 | the step allocates before its checks, and a refusal keeps both blocks | all six state rows (`(residue (0 0 0 18 0) before)`: a batch's nine refusals), the state reach row, the closing counters |
| D5 | the fill's bound is gone | nothing: equivalent (below) |
| D6 | the layout leaves out every NUL in a spawn whose env holds `W=w` (#56's M10n) | the four read-once sweep rows and their reach row, every run refused by the bound by name; the counters stay at zero |
| D6b | D6, and a block too small keeps the process handle | D6's rows and the closing counters |
| D6c | D6, and a block too small keeps the options block | D6's rows (`(residue (953 0 0) …)`) and the closing counters |
| D6d | D6, the refusal raised as the caller's `&uv-invalid-argument` | D6's rows only: uncovered (below) |
| D7 | the step is not interrupt-free | the four handle rows and the shared loop's teardown row (`EBUSY`); then the tear-down-loop sweep aborts the process (SIGABRT), as #60's M1 did |
| D7n | D7, with the teardown state sweeps skipped | both drop rows (fuel 111 and 84: a drop inside the step left the handle) and D7's rows |
| D8 | the process registered after the step | the spawn drop row (`(teardown (errno EBUSY) …)` at fuel 104, the step run), the drop reach row (`#t` for the spawn), and #60's rows |
| D9 | a failed spawn cleaned up after the step | the refused-spawn drop row (fuel 79, the step run: a handle libuv had unlinked, never freed), the drop reach row, #60's failed-spawn teardown row (`EBUSY`), the state reach row, the closing counters |
| D10 | the options block freed after the step, after the refusal is built | both drop rows (`(residue (1 0 0 1 0) …)`), all six state rows (`step-run block-still-built`), both reach rows |
| D11 | the step does not count the options block | 22 rows: every counter row (`-1` …), every sweep |
| D12 | the fill copies none of `argv-one`'s bytes | "argv[0], argv[1], env, and cwd all arrived as written" (`"argv-zero\|\|from-env\|/"`) |
| D13 | the fill's cursor leaves out `argv-zero`'s NUL | the same row (`"argv-zeroargv-one\|argv-one\|from-env\|/"`) |
| D14 | the fill leaves the env array unpointed | the same row, the empty-env row (`"xshould-not-crossx"`), the read-once rows |
| D15 | freeing the options block does not uncount it | 22 rows, as for D11 |
| D16 | a refused allocation keeps the other block | nothing: unreachable (below) |
| D17 | a refused allocation is not refused | nothing: unreachable (below) |
| H1 | the drop sweeps' fuel cap is 5 | the drop reach row (both end `dropped`) |
| H2 | the drop sweeps resume the engine instead of dropping it | the drop reach row (both begin `untouched`) |
| H3 | D1, with the residue blind to blocks | the closing counters only: both drop rows pass, so `'block` is the column that catches D1 |
| H4 | the refused spawn refused on entry instead (empty args) | the drop reach row (no drop after the step) |
| H5 | the drop sweeps never see the step run | the drop reach row |

## Uncovered

- **D5, the fill's bound, is equivalent on the fix**, as #56's M9 was. The
  layout sizes the block from the same bytevectors the fill copies, and
  nothing else can reach them. The bound's job is D6's: a layout that
  disagrees with the fill becomes a refusal by name in plain `make test`,
  not an overrun only the memory gate sees.
- **D6d: the refusal's condition is uncovered.** Only a mutation reaches
  `'options-block-too-small`. D6's rows fail whether the verb raises
  `&uv-error` with the fill's old message, as the fix does, or
  `&uv-invalid-argument`. The fix keeps `&uv-error`, since the refusal
  names the binding's own fault, not the caller's.
- **D16 and D17, the refused allocations, are unreachable.** The handle's
  size is libuv's, and the block's comes from the caller's strings; no test
  can make calloc refuse either (#59's M14). Both blocks come from
  `alloc-block`, which answers 0, and `free-block!` ignores 0. So the
  refusal frees both, whichever allocation failed.

## Harness notes

- **A mutant that keeps its state in a library global is not a mutant of
  the code.** The first D2, D3 and D10 parked the early block in one global.
  The consume-pipe sweep's change spawns inside the expiry handler, and its
  spawn overwrote the global; the outer spawn then freed the inner one's
  block. All three died of SIGABRT. Threaded through the step's arguments
  and results instead, all three fail by name.
- **The fill's mutations crash the suite at its first spawn**, which is
  unguarded top-level plumbing (exit 255). Sizing short everywhere, copying
  no bytes, and a cursor that skips every NUL all did. Narrowed to one
  row's strings (D12, D13) or to the read-once sweeps' spawns (D6, as #56
  narrowed M10 to M10n), each fails its predicted rows by name.
- **D7 aborts before the drop sweeps run**, in the tear-down-loop sweep,
  which #60 runs after the other state sweeps for that reason. The drop
  sweeps come after the whole state section, so D7n skips those sweeps, to
  show that the drop rows catch D7 on their own.
- **The probe's long tails after the step were its own handler.** It
  formatted each refusal with `describe` inside the engine, about 600
  expiries past the step. The suite's handler (`spawn-outcome`) reads only
  the errno, and the refused spawn's sweep has 63 drops after its step.
- **The witness of the step is the pipe's mark**, taken at the expiry
  before the drop. The step marks every pipe a spec names, an inherited
  one too (ADR-0015's Stage 5 amendment), so both sweeps can read it. H5
  shows the reach row needs it.

## Gates

On a473313 with the fix, macOS arm64:

- `make test`: 24 suites pass (`test-process.sps`: 137 rows; in the race
  row 194 of 200 children reported the argument mid-change).
- `make test-memory` (ASan): 24 suites pass.
- `make check-memory-gate`: the planted libc overrun and the shim overrun
  were caught, MEMORY GATE CAN FAIL.
- `make check-purity` holds, and `make check-help` is silent.

`make test-memory-docker` (Linux aarch64, Valgrind 3.19, vendored libuv
1.52.1) from a `--no-hardlinks` clone, make exit 0:

- `check-memory-gate` caught the store overrun, the libc overrun, the shim
  overrun and the leak, stayed consistent on the possible leak, and
  printed MEMORY GATE CAN FAIL.
- Every suite's own Valgrind summary (24 suites): 0 errors and 0 bytes
  definitely lost. `test-process.sps` passed 136 rows (the race row skips
  under Valgrind) at 16,839 allocations, down from #60's 24,286: its
  sweeps are shorter.
- The drop sweeps' fuel maps match macOS run for run: 104 runs (103
  dropped before the step), and 142 (78 before, 63 after).
- 76 forked children report their own summaries, none of which gates
  (ADR-0003): the two known exec-failure artifacts (131 B and 117 B), and
  74 from #60's failed-spawn teardown sweep (73 of 147 B in 1 block, 1 with
  nothing lost). The drop sweeps add none: the refused spawn fails before
  libuv forks.

The same recipe, run on the new rows against the unfixed `process.sls`
(one suite, `MEMORY_TESTS=tests/test-process.sps`), fails the 5 rows by
name, and Valgrind reports the leak itself: `136 bytes in 1 blocks are
definitely lost`, allocated by `chez_uv_alloc`, exit 2. The other stranded
handle was still reachable (+136 B in one more block than the clean run),
so the gate's own report of a drop depends on a stale pointer being gone;
the suite's `'block` column does not.

`make test` ran again on the committed tree, and passed. The other gates
ran on a tree that differs from it only in a comment in `process.sls` (the
step bracket's cost, corrected from #60's 32 B to the 112 B measured
above), in `docs/` and in `.plans/`.
