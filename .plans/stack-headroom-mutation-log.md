# #94: the C stack headroom check: mutation log

Branch `feat/stack-headroom-94`, on `docs/escape-headroom-design-94`
(59ada65, PR #124), 2026-10-09. macOS 26 arm64 (Homebrew libuv 1.52.1),
and Linux arm64 (Debian 12 in Docker, vendored libuv 1.52.1); Chez 10.4.1.
The design and its measurements are in
`.plans/2026-10-09-escape-headroom-check-design.md`.

## What changed

- **The shim** exports `chez_uv_stack_headroom`: the distance from its own
  frame to the bottom of the calling thread's stack. The bottom comes from
  pthreads on the thread's first call and is kept in a `__thread` variable.
  Where it cannot be read, the answer is `CHEZ_UV_HEADROOM_UNKNOWN` (2^40).
  ADR-0002 is amended for this seventh kind of export.
- **`(libuv private handles)`** defines `run-stack-floor` (131,072) and
  `teardown-stack-floor` (65,536), a `stack-shortfall` record that
  `refused?` takes for a refusal, and `claim-loop-for-run!`: in one
  interrupt-free step, a shortfall if the headroom is under the floor, else
  `claim-loop!`'s answer. `step-refusal` turns a shortfall into the new
  `&uv-stack-exhausted` (who, headroom, floor).
- **`run-step!`** claims through `claim-loop-for-run!` with a floor:
  `uv-run` passes the run floor, a teardown's drain the teardown floor.
- **`&uv-stack-exhausted`** is in `(libuv private conditions)` and
  re-exported from `(libuv)`.

## The tests

`tests/test-stack-headroom.sps` (new) runs `tests/stack-headroom-child.sps`
twice through `level-3-run`, with a 30 s deadline. A binding that lets a
run through too deep crashes or hangs the child, and its rows then fail
carrying how. The child works on a `fork-thread` thread:
- `floors` nests libc `qsort` comparator callbacks to a depth, every one of
  them returning afterwards, so no frame is stranded. Between the floors
  (96 KiB) it tries a run and then a teardown; under the teardown floor
  (48 KiB, above the 36 KiB deepest path) both; then the deep loop's
  teardown again once the callbacks have returned.
- `escapes` measures one timer escape's strand and one async escape's, then
  escapes async callbacks until `uv-run` refuses, and counts the loops made
  meanwhile that are still open.

The child's reports on a correct build:

```
macOS   floors   ((between (refused uv-run 131072 98288) torn-down #f) (under (refused uv-run 131072 49008) (refused uv-loop-teardown! 65536 49008)) (after-return torn-down #f))
macOS   escapes  ((first escaped escaped) (timer-strand . 352) (async-strand . 34352) (escapes . 11) (last refused uv-run 131072 123792) (open-loops . 0))
Linux   floors   ((between (refused uv-run 131072 98272) torn-down #f) (under (refused uv-run 131072 48832) (refused uv-loop-teardown! 65536 48832)) (after-return torn-down #f))
Linux   escapes  ((first escaped escaped) (timer-strand . 384) (async-strand . 22272) (escapes . 370) (last refused uv-run 131072 119296) (open-loops . 0))
```

Also:
- `tests/test-conditions.sps`: the type's predicate, fields and parent, and
  a place in the sibling matrix.
- `tests/test-facade.sps`: the re-export.
- `tests/test-source-rules.sps`:
  - rule 6 lists `stack_low` as a per-thread static and holds it to
    `__thread`, with a seeded row for the checker;
  - rule 11 (new) holds `uv-loop-run` and `claim-loop-for-run!` to
    `run-step!`.

## Mutations

Each was made in a copy of the tree outside the repository
(`scratchpad/m94`, rebuilt there for the C ones), and the named suite run
on it. Every one failed the rows below by name, and the copy was then
discarded. The correct tree passes every row.

| Mutation | Rows that failed (test-stack-headroom unless named) | How |
|---|---|---|
| no check: `claim-loop-for-run!` never refuses | 8 of 9: all but "a loop whose teardown was refused deep…" | between the floors: `(ran torn-down #f)`. The escapes child's 15th I/O escape faulted with "invalid memory reference" |
| `run-stack-floor` = the teardown floor | between the floors; refused between them; escapes end in refusal; every loop torn down; the gap holds one escape | the gap is 0, and loops whose teardown was refused stay open |
| `teardown-stack-floor` = 0 | under the teardown floor; the teardown floor holds one escape and 16 KiB | the deep teardown ran |
| `uv-run` given the teardown floor | between the floors; refused between them; under the teardown floor; escapes end in refusal; every loop torn down | |
| the drain given the run floor | between the floors; under the teardown floor; escapes end in refusal; every loop torn down | the teardown is refused naming 131,072, and 2 loops stay open |
| the refusal's headroom and floor swapped | between the floors; refused between them; under the teardown floor; escapes end in refusal | |
| the shortfall answered after the claim, which it keeps | between the floors; refused between them; under the teardown floor; the deep loop tears down after | each teardown then raised `&uv-invalid-argument` `'loop-running` |
| `refused?` blind to a shortfall | all 9 | the record went to `uv_run` as a loop pointer (the child runs at optimize-level 3, where nothing checks it): "invalid memory reference" |
| the export always answers "unknown" (C) | all 9 | the floors child nested until it died of signal 4, and the escapes child faulted |
| the stack bottom read as its top (C, macOS) | all 9 | the same |
| `stack_low` without `__thread` (C) | source-rules: "every per-thread variable in the C shim is declared __thread" | `(stack_low)` |
| rule 6's lapse checker reading any `static` | source-rules: "rule 6 finds a per-thread variable defined without __thread" | `(c)` |
| the condition's headroom and floor accessors swapped | conditions: "stack-exhausted carries…"; facade: "&uv-stack-exhausted is re-exported…" | |
| `&uv-stack-exhausted` under `&error`, not `&uv-error` | conditions: "stack-exhausted is a uv-error"; the matrix's subtype row | |
| `run-step!` claims with `claim-loop!` | source-rules: rule 11's `claim-loop-for-run!` row; test-stack-headroom: 8 of 9 | |
| the drain calls `uv-loop-run` itself | source-rules: rule 11's `uv-loop-run` row | |

## What no row holds

- **The seed row's bounds.** "Seed: an escape from an async callback
  strands more than one from a timer callback" failed under every mutation
  above that crashed the child, because the child then reported no
  strands. No mutation of the binding changes what an escape strands, so
  none fails its bounds (a timer strand under 4 KiB, an async one 8 KiB
  more). They keep the floors rows from passing on a measurement of
  something else, such as an export that reads no stack.
- **A suspension between the check and `uv_run`.** An engine can expire
  between `claim-loop-for-run!`'s step and the native call, and a resume
  from deeper in the C stack runs below where the step measured. The gap
  between the floors absorbs one such case. No row resumes an engine
  deeper than it stopped.
- **Linux x86-64.** CI runs the suite there, so the floors rows check
  what an async escape strands on it, but nobody has read those numbers.

## Other runs

- `make test` passes on macOS: 36 suites.
- Linux arm64, as a non-root user (the container's root fails test-process's
  non-root setuid row, on any tree): 36 suites pass, with `make -o
  check-pins` since the container has no git. Under Valgrind
  (`test-memory` with the new suite, test-loop, test-timer,
  test-loop-claim and test-facade), every suite passed with 0 bytes
  definitely lost. Valgrind's main thread reads 8,386,832 B of headroom.
- Both flavors build on both systems, `-std=c99 -Werror` (gcc on Linux,
  clang on macOS).
