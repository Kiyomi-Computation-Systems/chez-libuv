# A faster CI: one needless wait, and the pure suites off the memory lane

2026-10-09. CI's `linux (vendored + valgrind)` job took 19m14s on #101's
run (37954992095). Its steps:

| Step | Time |
|---|---|
| Memory (valgrind) | 9m58s |
| Test (pkg-config path) | 2m34s |
| Test (vendored path) | 2m34s |
| Verify the test target fails on a failing suite | 2m33s |
| Verify the memory gate fails on planted defects | 48s |
| everything else | about 1m |

Valgrind writes each suite's report to a log that the recipe prints when
the suite ends, so a suite's time is the gap from the report before it to
its own.

## test-constructor-owner waited for what was never started

In each plain `make test` the suite took 128 of 153 s, and under Valgrind
149 s. The job runs it four times, and the floor job once more. Timed row
by row on macOS:

| Rows | Each |
|---|---|
| `uv-spawn!`, `uv-getaddrinfo!`, `uv-getnameinfo!` refused from another thread (two rows each) | about 24 s |
| every other row | under 20 ms |

Each refused row ended in `finish!`, which waited for the row's cell to
settle: a cell only a spawned child's exit or a lookup's completion
settles. A refused call starts neither, so the wait ticked to its cap of
20,000. `finish!` now waits only while the loop is alive, which is libuv's
own word for "something was started": a child, a lookup, or the accept
row's listening server, whose context is settled at once.

| Run | Time |
|---|---|
| the suite, before | about 145 s (macOS) |
| the suite, after | under 1 s, 35 rows pass |
| `make test`, after, macOS | 27 s; 22 s on #101's merge (4211331) |

| Mutant | Change | Result |
|---|---|---|
| CO1 | `uv-getaddrinfo!` without its owner checks (entry and step) | **killed** in 1 s: its refusal row, its bad-arguments row, its handoff row |
| CO2 | `uv-spawn!` without its owner checks | **killed** in 1 s: the same three rows for spawn |
| CO3 | the wait made always, as before | survived, in **141 s**: the time the change saves |
| CO4 | no wait at all | survived: the wait lets a started child or lookup finish before the teardown, and no row checks that it did. So it was before this change |

The CO1 and CO2 lookups and children, started where the refusal failed,
were waited for and torn down: `finish torn-down` in the failing rows.

## The pure suites off the memory lane

`MEMORY_TESTS` was every suite. The seven in `PURE_TESTS` load no native
code (`make check-purity` runs each with the shim's path poisoned), so
under Valgrind they check Chez alone. On #101's run they took 7.0 to
10.1 s each, 58 s together, most of it Chez starting under Valgrind:

| Suite | Valgrind |
|---|---|
| test-require-threaded | 7.0 s |
| test-c-string | 7.1 s |
| test-conditions | 7.5 s |
| test-sweep | 8.3 s |
| test-seed-gates | 8.5 s |
| test-addrinfo | 9.0 s |
| test-source-rules | 10.1 s |

`MEMORY_TESTS` is now `TESTS` less `PURE_TESTS`: 25 of the 32 suites on
4211331. A suite that comes to reach native code fails `check-purity`
until it leaves `PURE_TESTS`, which puts it back in the lane.

With the list derived, a filter gone wrong could leave `test-memory` an
empty list, and the loop would pass having run nothing. The recipe now
refuses an empty list; watched failing with `make test-memory
MEMORY_TESTS=`:

```
test-memory: MEMORY_TESTS is empty; refusing to pass having checked nothing
```

## Gates

- macOS: `make test` (27 s before the rebase, 22 s after), `make
  check-purity`.
- Debian 12 aarch64 (the Valgrind image), on the tree before #101 merged:
  `make check-memory-gate` passed in 46 s; `make test-memory` passed in
  6m22s, 24 suites, none of them pure, each suite's own process with 0
  bytes definitely lost; `make test` passed in 19 s.
