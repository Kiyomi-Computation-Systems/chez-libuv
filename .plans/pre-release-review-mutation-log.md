# Pre-release review fixes (0.7.4) — mutation log

Branch `fix/pre-release-review`, on main 0fa1965. The xhigh /code-review of
`v0.7.3..main` (2026-10-08) reported seven findings. The user chose three
to fix before the release, CI on Ubuntu 26.04 by name, and issues for the
rest (#85–#90, and #91 from the 26.04 mirror run).

## 1. Rows that took their weaker form from an environment variable

The memory gates set `CHEZ_LIBUV_UNDER_VALGRIND` (Linux) or `ASAN_OPTIONS`
(macOS), and some rows took a weaker form, or were skipped, on the variable
alone. A plain run inherits `ASAN_OPTIONS` from a developer's shell.

Measured on main 0fa1965, natively, with `ASAN_OPTIONS=color=never`:

| Suite | Row | What happened |
|---|---|---|
| test-process | the squatter row (L1907) | FAILED a correct build: the weak form expects `spawned`, and the spawn was refused, `actual: ((refused uv-registry-register! pointer-already-registered) …)` |
| test-native | the dirty-memory seed (L888) | weak seed ran (always 32) instead of requiring the dirtied block back |
| test-native | the two refused-allocation rows (L942) | skipped: 324 passes where a plain run has 326 |

The review named the first two. The third was found by comparing each
suite's plain and env-set pass counts.

**The fix:** `(uv-evidence)` exports `under-memory-tool?` and `under-asan?`,
which require the variable AND an allocator that reports a 288 B shim block
as exactly 288 B. #75 measured that for test-process-steps: 288 under ASan
and Valgrind, 320 on macOS and 296 on glibc 2.36 and 2.39 natively.
test-process-steps' local copy moved there, and the three sites above use
it. The Valgrind-only race skips (`CHEZ_LIBUV_UNDER_VALGRIND`, a variable
only the Makefile sets) are unchanged.

**The detector, measured:**

| Where | exact-block-sizes? | under-memory-tool? | under-asan? |
|---|---|---|---|
| macOS natively, `ASAN_OPTIONS` set | #f | #f | #f |
| macOS under the ASan preload (`DYLD_INSERT_LIBRARIES` on chez) | #t | #t | #t |

`make test-memory MEMORY_TESTS="tests/test-native.sps tests/test-process.sps
tests/test-process-steps.sps"` (the real ASan arm) passed: 324, 157 and 12
passes. Those are the plain counts minus exactly the rows each suite weakens
or skips (the seed keeps its count; the squatter pair becomes one row; the
refused-allocation pair is skipped). The Linux Valgrind arm ran in the
Ubuntu 26.04 mirror (section 3).

Natively, plain and with `ASAN_OPTIONS` set, after the fix: test-native 326
and 326, test-process 158 and 158, test-process-steps 12 and 12, test-dns
150 and 150, every row passing.

**Mutations** (scratch copies outside the repo, exact single-match
replacement, `ASAN_OPTIONS=color=never` set, native run). "Old" is main
0fa1965's tests with the same mutation.

| Row | Mutation | New tests | Old tests |
|---|---|---|---|
| M2 | `spawn-from-block!` spawns although its registration was refused (`(if (not (eq? registered 'registered))` → `(if #f`) | FAIL `a spawn whose handle block another entry holds is refused before it forks, leaving nothing behind` (+ suite-end counters) | FAIL through the weak row's leftover counts (`… (a memory tool: reuse unobservable by design)`) |
| M3 | `alloc-zeroed` asks for `(+ n 4096)` | seed held: macOS gave the freed block back for the larger request | same |
| M3b | `alloc-zeroed` takes the freed block and keeps it: `(begin (alloc-block n) (alloc-block n))` | FAIL `seed: the shim's allocator handed alloc-zeroed the very block just dirtied` (+ the leak's counter rows) | seed row passes (weak form); only the leak's counter rows fail |
| M4 | `alloc-zeroed` answers 0 instead of raising ENOMEM (`(when (zero? addr)` → `(when #f`) | FAIL `alloc-zeroed raises ENOMEM under its own name when the allocator refuses` | not seen: both rows skipped |

Every scratch-tree run of test-native, the unmutated baseline included,
also failed three `resolve-shim-path` rows, which look for files beside the
repo's own tree: an artifact of the scratch layout, not of any row here.

**Uncovered, and why:** the variable clause of both predicates. No
environment here has a native allocator that reports exact sizes, so
dropping the clause changes nothing that can be run. It guards against
such an allocator, and against an exact-size probe that answers by
accident.

## 2. dns.sls: the conversion-failure arm reads `req-loop`

`getaddrinfo-dispatch`'s arm for a chain that `addrinfo-chain->list` fails
to convert found the loop with `registry-loop-of`. That is a second lock
round trip, and it worked only while the entry was registered. Since #82
the request carries its loop. The arm now calls `(req-loop req)` after
`abandon-request!`.

**Uncovered, before and after:** the arm itself. No `res` can make the
conversion raise without `uv_freeaddrinfo` then freeing a pointer libc did
not allocate: every field read is through a positive address, and a
negative or synthetic chain is passed to `freeaddrinfo` next. What the arm
now reads is held:

| Row | Mutation | Result |
|---|---|---|
| M7 | a getaddrinfo request built with no loop (`… on-complete loop)` → `… on-complete #f)`) | test-constructor-owner FAILS 3 rows by name: `uv-cancel! from a thread that does not own the loop is refused, leaving nothing`, `uv-cancel! on the thread that made the loop makes it`, `uv-cancel! is made by the thread a loop was handed to, and refused to its maker` |

## 3. CI on `ubuntu-26.04` by name

`ubuntu-latest` moves to 26.04 on 2026-10-19. ci.yml now names
`ubuntu-26.04`, and the Chez cache key adds the image (`ID-VERSION_ID` from
`/etc/os-release`, read on the runner), so the first run builds Chez with
26.04's compiler, not a 24.04 build from the cache.

**Mirror:** `ubuntu:26.04` (arm64, Docker on macOS) with ci.yml's packages,
built from docker/valgrind.Dockerfile with only the base image changed:
gcc 15.2.0, cmake 4.2.3, Valgrind 3.26.0, apt libuv 1.51.0, apt chezscheme
10.0.0 (below the floor). Chez 10.4.1 built from the tarball with CI's
flags, with no error. ci.yml's steps ran in order, as CI runs them, root
lane as root:

| Step | Exit | Notes |
|---|---|---|
| check-pins, deps | 0 | |
| build (pkg-config, libuv 1.51.0) | 0 | |
| test (pkg-config) | 2 | one row: test-loop-claim's `precondition: the other thread ran some of those loops`, `actual: (0 stopped 0)` (below) |
| vendor (cmake 4.2.3), build (vendored) | 0 | |
| check-purity | 0 | |
| test (vendored) | 2 | the same row, the same `(0 stopped 0)` |
| root lane (sudo) | 0 | ROOT LANE PASSED |
| check-memory-gate | 0 | all four plants caught, `shim-overrun` in `chez_uv_copy_in`; MEMORY GATE CAN FAIL |
| test-memory (Valgrind 3.26.0) | 0 | all 30 suites ERROR SUMMARY 0 and 0 B definitely lost; 82 forked children, 0 errors, 0 B definitely lost |
| the `make test` sabotage check | 0 | |
| make prod → check-prod guard | 0 | |

test-process's failed-spawn rows took the exec-class arm on 1.51.0
(`[informational] stdio-setup (EINVAL) cleanup arm:
exec-class-close-through-protocol`), as on 24.04's 1.48.0.

**The loop-claim precondition is not 26.04's.** The row is #83's: its
exit race needs the racing thread to catch a loop open and unclaimed
between a teardown's steps at least once in 2,000 attempts. On the 24.04
mirror (`chez-libuv-noble-scratch`, CI's current image) it failed 1 run of
3 the same way, `(0 stopped 0)`, while Valgrind loaded the VM. The A/B on
an idle VM is below.

| Image | Runs | Failed | Notes |
|---|---|---|---|
| Ubuntu 26.04 (libuv 1.51.0; the vendored 1.52.1) | 7 | 2 | both failures in the CI run above, while Valgrind loaded the VM; idle and alternating with 24.04, 5 of 5 passed |
| Ubuntu 24.04 (libuv 1.48.0) | 8 | 6 | idle and alternating, 5 of 5 failed |

macOS `make test` passes it, and so did CI's two x64 runs (#83, #84). A
fixed count of the main thread's own attempts bounds a wait on the other
thread's progress, the shape AGENTS.md's careless-pool trap names. Filed as
#91, with these runs, and left out of this branch.

## Issues filed for the rest

- #85: make `uv-tcp-connect!` and the DNS verbs one interrupt-free step
- #86: the remaining verbs (scratch verbs, handle verbs, loop queries, the stream owner check)
- #87: completions and closes take the registry lock twice
- #88: tests/uv-level-3.sls drains stderr late and loses its deadline
- #89: test-tcp's `graise-peer` is never read
- #90: no CI run links a libuv below 1.49 after the move to 26.04
- #91: test-loop-claim's exit-race precondition fails on Linux (section 3)
