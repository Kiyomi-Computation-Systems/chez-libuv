# #117: the stranded-exit child under the shared runner: mutation log

Branch `test/stranded-child-runner-117`, on main 2b1133a, 2026-10-09. Guix
container (ADR-0020), x86_64, Chez 10.4.1, libuv 1.52.1.

## What was weak

`tests/test-loop.sps`'s stranded-exit section ran
`tests/stranded-exit-child.sps` through its own copy of a child runner,
which had every flaw #88 and #110 had already fixed in `level-3-run`:

- no deadline: `get-string-all` waited for the child's stdout to end, so a
  child that hung hung the suite. Under `make test` that is
  `SUITE_TIMEOUT`'s `HUNG` after 300 s, which kills the suite and every row
  after the section with it;
- stderr read only after stdout had ended, so a child that filled the
  stderr pipe first blocked on it for good;
- the child never reaped: one that died before printing was answered
  `(unreadable "" "")`, with no status, and stayed a zombie.

And test-loop printed only a failing row's title, so even the evidence
that copy did keep never reached the log.

## The change

- `tests/uv-child.sls` (new, pure) holds the runner, as `child-run`. It is
  `level-3-run`'s code, with one new argument: the Chez options to put
  ahead of `--program`. `child-entry` is `level-3-entry`'s. The file is
  `tests/uv-level-3.sls` moved, so the drain-and-reap logic stays one copy.
- `tests/uv-level-3.sls` keeps its two exports, defined on `(uv-child)`:
  `level-3-run` is `child-run` with `--optimize-level 3`. test-addrinfo and
  test-process are unchanged.
- test-loop runs the stranded child with `child-run` and no options, the
  level it ran at before, and reads entries with `child-entry`. It drops
  `open-process-ports` from its imports.
- test-loop now prints a failing row's actual value, as most suites do.
- The stand-in child gains a `level` mode that prints its optimize level.
- `tests/test-level-3.sps` gains three rows: `child-run` passes the options
  it is given (level 2), `child-run` with no options runs at Chez's default
  (level 0), and `level-3-run` runs at level 3.

The runner's other properties (deadline, both pipes drained, every child
reaped, statuses) are held by test-level-3's existing rows against the
stand-in. They run the same code as before the move, so they were not
re-mutated.

## Mutants

Each was made in a copy of the worktree outside the repo
(`$SCRATCH/m117`, per the guix-env recipe: srfi links repointed,
`CHEZ_LIBUV_SHIM` set), and run the way `make test` runs a suite. The
baseline in the copy: test-level-3 16 passes, test-loop 212.

### The runner's new argument (test-level-3)

| Mutant | Rows that failed, by name | Actual |
|---|---|---|
| R1 `child-run` drops its options (`'()` in place of the mapped options) | "child-run runs the child with the options it is given"; "level-3-run runs the child at --optimize-level 3" | `((level . 0))` for both |
| R2 `child-run` runs `--optimize-level 3` whatever its options | "child-run runs the child with the options it is given"; "child-run with no options runs the child at Chez's default level" | `((level . 3))` for both |
| R3 `level-3-run` passes no options | "level-3-run runs the child at --optimize-level 3" | `((level . 0))` |

Each failed through the level the child reports; nothing else failed. The
level-2 row exists for R1 and the level-0 row for R2: either alone lets
one through.

### The stranded child misbehaving (test-loop)

With the change, each failed all seven stranded rows by name, and the rest
of the suite ran (205 passes):

| Mutant | Took | Actual, for `escape` |
|---|---|---|
| C1 the child prints its datum, then sleeps an hour | 63 s | `(no-entry escape (killed-at-cap "((escape . escaped) …)\n" "" (signal 9)))` |
| C2 the child raises before printing | 3 s | `(no-entry escape (unreadable "" "Exception occurred with non-condition value mutant-boom\n" (exit 255)))` |
| C3 the child prints its datum, then exits 1 | 2 s | `(no-entry escape (bad-exit "((escape . escaped) …)\n" "" (exit 1)))` |

Against main's test-loop.sps (its own runner), in the same copy:

- C1: the suite never finished; `timeout 300` killed it (`rc=124`), and no
  row after the section ran.
- C2: the same seven rows failed, carrying `(unreadable "" "Exception …")`
  with no status, and printed only their titles.

The printer: before it was added, C1 and C2's failing rows printed titles
only (both runs are in this session's transcript). With it, each carries
the line above.

### Not re-mutated

- The stderr-first deadlock: test-level-3's flood row holds `child-run`'s
  drain. No stranded-child mutant floods stderr: it would test the same
  code through a slower suite.
- Reaping: test-level-3's last row holds that every `child-run` child is
  waited on. test-loop has no zombie row of its own.

## Gates

- `make test`: every suite passes (test-level-3 16, test-loop 212).
- `make check-purity`: test-level-3 still pulls in no native code.
- `make HAVE_PKG=no test-memory MEMORY_TESTS="tests/test-loop.sps
  tests/test-level-3.sps"` (Valgrind): both pass, nothing definitely lost.
  test-loop suppresses 1,200 B in 6 blocks, the count #94's log recorded
  before this change, so loading libc into the suite strands nothing.
