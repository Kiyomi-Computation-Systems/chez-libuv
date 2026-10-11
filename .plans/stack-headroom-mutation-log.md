# #94: the C stack headroom check: mutation log

Branch `feat/stack-headroom-94`, on `docs/escape-headroom-design-94`
(59ada65, PR #124), 2026-10-09. macOS 26 arm64 (Homebrew libuv 1.52.1),
and Linux arm64 (Debian 12 in Docker, vendored libuv 1.52.1); Chez 10.4.1.
The design and its measurements are in
`.plans/2026-10-09-escape-headroom-check-design.md`.

## What changed

- **The shim** exports `chez_uv_stack_pointer`, the address of its own
  frame, and `chez_uv_stack_bottom`, the lowest address of the calling
  thread's stack from pthreads, or 0 where it cannot be read. It keeps no
  state. ADR-0002 is amended for this seventh kind of export.
- **`(libuv private native)`**'s `stack-headroom` is the distance between
  the two. It reads each thread's bottom once and keeps it in a thread
  parameter, `stack-bottom-cell`, as `(thread-id . bottom)`: a new thread
  starts with its creator's cell and reads its own. Where the bottom is 0
  the headroom is 2^40, so nothing is refused.
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
x86-64  floors   ((between (refused uv-run 131072 97328) torn-down #f) (under (refused uv-run 131072 48144) (refused uv-loop-teardown! 65536 48144)) (after-return torn-down #f))
x86-64  escapes  ((first escaped escaped) (timer-strand . 480) (async-strand . 17264) (escapes . 478) (last refused uv-run 131072 114048) (open-loops . 0))
```

x86-64 is Ubuntu 26.04 emulated in Docker on the arm64 Mac, with apt's
Chez 10.0.0 and Valgrind 3.26. Emulation changes no frame size.

The child's main thread runs a loop before it makes the thread, so the
thread starts with the main thread's cached bottom, which it must not
use.

Also:
- `tests/test-conditions.sps`: the type's predicate, fields and parent, and
  a place in the sibling matrix.
- `tests/test-facade.sps`: the re-export.
- `tests/test-source-rules.sps`:
  - rule 6 lists `stack-bottom-cell` as thread-local, and holds the C shim
    to no thread-local storage in any spelling, with a seeded row for the
    checker;
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
| `stack-headroom` always answers "unknown" | all 9 | the floors child nested until it died of signal 4, and the escapes child faulted |
| the stack bottom read as its top (C, macOS) | all 9 | the same |
| `stack-headroom` takes any cell, not only its own thread's | all 9 | the thread measured against the main thread's bottom: the same |
| a `static __thread` counter in the shim (C) | source-rules: "the C shim keeps no thread-local storage…" and the static list | `(437)` and `(unlisted (calls))` |
| rule 6's thread-local checker reading only `__thread` | source-rules: "rule 6 finds each line of C that names thread-local storage, in any spelling" | `(1)` |
| `stack-bottom-cell` left out of rule 6's list | source-rules: "every process-wide variable in src/ is listed…" | `(unlisted (("src/libuv/private/native.sls" stack-bottom-cell)))` |
| the condition's headroom and floor accessors swapped | conditions: "stack-exhausted carries…"; facade: "&uv-stack-exhausted is re-exported…" | |
| `&uv-stack-exhausted` under `&error`, not `&uv-error` | conditions: "stack-exhausted is a uv-error"; the matrix's subtype row | |
| `run-step!` claims with `claim-loop!` | source-rules: rule 11's `claim-loop-for-run!` row; test-stack-headroom: 8 of 9 | |
| the drain calls `uv-loop-run` itself | source-rules: rule 11's `uv-loop-run` row | |

## The first push failed CI

The first version kept each thread's bottom in the shim, in a `static
__thread uintptr_t stack_low`. CI's x86-64 Valgrind leg (Ubuntu 26.04)
failed `check-memory-gate`'s escape mode: Valgrind suppressed "608 bytes
in 4 blocks" where the mode requires the three 200 B `jmp_buf`s three
escapes strand. Reproduced under emulated x86-64 with
`--default-suppressions=no`, the fourth block was 8 bytes:

```
8 bytes in 1 blocks are still reachable in loss record 1 of 10
   at malloc (vg_replace_malloc.c:447)
   by allocate_dtv_entry (dl-tls.c:760)
   by tls_get_addr_tail (dl-tls.c:1012)
   by __tls_get_addr (tls_get_addr.S:55)
   by chez_uv_stack_headroom (libuv-shim.c:467)
```

glibc mallocs a dlopened library's thread-local storage on each thread's
first use, and Valgrind's own default suppressions hide the block. The
escape mode counts every suppressed block, and `test-memory` fails any
suite outside `MEMORY_ESCAPE_SUITES` that has one, so every suite would
have failed on x86-64. arm64's Debian 12 showed no such block. With the
bottom kept in Scheme instead, the same run suppressed "600 bytes in 3
blocks", and test-timer and test-stack-headroom suppressed nothing.

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
- Linux x86-64, emulated: the escape sabotage under Valgrind suppressed
  exactly the 3 escape blocks, and test-timer and test-stack-headroom 0.
- Linux arm64, as a non-root user (the container's root fails test-process's
  non-root setuid row, on any tree): 36 suites pass, with `make -o
  check-pins` since the container has no git. Under Valgrind
  (`test-memory` with the new suite, test-loop, test-timer,
  test-loop-claim and test-facade), every suite passed with 0 bytes
  definitely lost. Valgrind's main thread reads 8,386,832 B of headroom.
- Both flavors build on both systems, `-std=c99 -Werror` (gcc on Linux,
  clang on macOS).
