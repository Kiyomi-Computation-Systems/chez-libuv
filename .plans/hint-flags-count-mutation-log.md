# Hint flags, read once: mutation log

Evidence for #66 item 1 and #64 item 3: `uv-getaddrinfo!`'s hint flags
are read with `read-proper-list`, from the new pure library `(libuv private
lists)`, where `checked-flags` counted them with a guarded `length`.

## The fault

`checked-flags` (`src/libuv/private/addrinfo.sls`, #51) measured the flag
list with `(guard (e (#t #f)) (length value))`.

- **At `--optimize-level 3` it hung.** A program compiled there compiles
  this library from source at the same level, where Chez 10.4.1 inlines
  `length` with no pair, cycle or trap check. A circular flag list was
  walked forever: no guard could catch that, and no engine could stop it.
  `validate-hints` from main's sources, run on its own, with a circular
  list:

  | flag list | default level | `--optimize-level 3` |
  |---|---|---|
  | circular | refused, `'hint-flags-not-a-list` | hung, killed at 15 s |
  | improper | refused | refused |

- **The guard cost 272 B a call.** A guard allocates even when nothing
  raises. A flags entry cost 272 B more than a family entry, the same
  figure #61 measured for `fold-flags`' guarded `length`.

The issue noted that `(and (list? value) (length value))` returns in every
case. That is no fix: it reopens the gap between `list?` and `length`, in
which a list made circular makes `length` raise its own condition at the
default level and hang at level 3 (C6 below).

## The change

- **`(libuv private lists)`**, pure, holds the three reads of a caller's
  list. `proper-length` and `fold-flags` move there from `native.sls`
  unchanged; `stream.sls`, `tcp.sls` and `dns.sls` import them from it.
- **`read-proper-list`** is new. It counts a list with `proper-length`,
  walks at most that many pairs, checking each before reading through it,
  and requires the list's end after them. It answers a fresh list of
  `(READ element)`, or `#f` where the list is not one proper list as it
  read it: never a list it never was. It raises only what `READ` raises, so
  #66 item 2's `read-list`, which must answer rather than raise, can use it
  as it is.
- **`checked-flags`** reads with it, then checks the flags on its own copy.
  A flags entry now costs what a family entry does, plus one pair a flag.

## Tests

- `tests/test-addrinfo.sps`:
  - **Level 3.** `tests/flags-level-3-child.sps` runs `validate-hints` at
    `--optimize-level 3` in a child process and prints what it answered;
    the suite kills a child still running after 6,000 polls of 10 ms. Two
    children, so the circular list's hang takes only its own row. A seed
    row holds that the child ran at level 3. The rows skip when
    `CHEZ_LIBUV_TEST_CHEZ` is unset, as under `make check-purity`.
  - **Cost.** A flags entry costs what a family entry does, plus a pair a
    flag: `(0 48)`, where main gives `(272 48)`. The second figure is
    three pairs, so a blind meter fails the row too.
  - **The end.** A hints sweep splices a longer tail into the flag list at
    the first expiry. Read whole, its last flag is refused; stopped at the
    stale count, the read is refused as not a list. Only a read without the
    end check answers, and what it answers is not the hints as given.
- `tests/test-native.sps`:
  - `read-proper-list` reads each element once, in order, into a fresh
    list; reads `()` as `()`; and refuses a non-list, an improper list and
    a circular one, reading none of it.
  - Sweeps in an engine: a cut, a list made circular, two cycles, and a
    longer tail spliced in. Each run answers the list as it was, the list
    as the change left it, or `#f`. A reach row holds that each sweep
    changed the list before the read began and ended with a whole read.
  - #67's race now runs `read-proper-list` as well as `proper-length`,
    with its own liveness precondition row.

## On main

The final tests on main's sources (6b5e080) fail three rows of
`tests/test-addrinfo.sps`:

- the cost row, `(272 48)`;
- the hints sweep: main's `checked-flags` stopped at the stale count
  without requiring the end, so a tail spliced in during the read was
  answered as `(numeric-host passive)` at fuels 25 and 26, a list the
  caller never had;
- the level-3 circular row, `killed-at-cap` after the 60 s cap.

The suite fails 3 rows and passes 55. `tests/test-native.sps` cannot load
on main, which has no `(libuv private lists)`, so its rows are held by the
mutations below.

## Mutations

Each ran on a scratch copy of `src/` and `tests/`, with a 150 s cap.

| id | mutation | failed rows |
|---|---|---|
| R1 | `read-proper-list` without the end check | test-native: the read sweeps; test-addrinfo: the hints sweep, through flags-spliced-longer at fuels 21 and 22 |
| R2 | it reads through a non-pair | test-native: the read sweeps (the cut) and the read race |
| R3 | it walks one pair more than it counted | test-native: both unit rows and the reach row; test-addrinfo: 11 rows, every flag list refused, the level-3 proper list among them |
| R4 | it reads an element after the rest of the list | test-native: "reads each element once, in order" |
| R5 | an inner `#f` is consed into the answer | test-native: the read sweeps and the read race; test-addrinfo: the hints sweep (`car: #f is not a pair`) |
| R6 | it counts with a guarded `length` | test-addrinfo: the cost row, `(272 48)`, and the level-3 circular row (`killed-at-cap`) |
| R7 | it walks without a count | test-native: 4 rows; test-addrinfo: 6 rows |
| R8 | it reads the next pair through the one it came from (a double read) | test-native: the read race alone |
| C1 | main's `checked-flags` | test-addrinfo: the cost row, the hints sweep and the level-3 circular row |
| C2 | no check that each flag is in the set | test-addrinfo: the unknown-flag and addrconfig rows, and both sweep rows |
| C3 | a non-list refused as an unknown flag | test-addrinfo: 6 rows, among them the level-3 ones |
| C4 | the caller's list answered instead of the copy | test-addrinfo: the copy row (`shared`) and the hints sweep |
| C6 | the issue's `(and (list? value) (length value))` | test-addrinfo: the hints sweep (`length: ... is circular` at fuels 20 and 21) |
| P1 | `proper-length`'s mark never moves | test-native: 7 rows, fold-flags' circular row among them |
| F1 | `fold-flags` reads through a non-pair | test-address: its flags sweep (`car: oops is not a pair`) |
| T1 | the child run without `--optimize-level 3` | test-addrinfo: the seed row alone (`0`) |
| T2 | a cap of 0 polls | test-addrinfo: all four level-3 rows (`killed-at-cap`) |
| S1 | the cut sweep's change does nothing | test-native: the read sweeps' reach row |

All 18 fail rows by name.

- R8 is a double read that only another thread can split, and only the
  read race catches it.
- R6 and C1 pass test-native: at the default level the guard catches what
  `length` raises. The cost row and the level-3 child are what see them.
- T1 is why the seed row exists. Without the flag, the circular row passes,
  because at the default level `length` checks for itself.
- P1 first hung test-native, in the new unit row, which read a circular
  list outside an engine. That row now reads in an engine capped at 100
  resumes, and P1 fails seven rows by name in 10 s.

The control run of the same copies passes both suites.

## Gates

At load averages near 125, from other sessions:

- `make test`: 24 suites pass. test-native has 313 rows (was 307) and
  test-addrinfo 58 (was 53). `make test-threading`, `make check-purity` and
  `make check-help` pass. Under `check-purity`, test-addrinfo's level-3
  rows skip, because `CHEZ_LIBUV_TEST_CHEZ` is unset there (55 rows).
- macOS ASan, `make test-memory`: 24 suites pass with no AddressSanitizer
  report. The level-3 rows ran, and both races were live: 68,230 and 81,901
  of 100,000 counts and reads found the list cut.
- The Valgrind skip path, run natively with `CHEZ_LIBUV_UNDER_VALGRIND=1`:
  test-native 309 rows, with both races skipped, and test-addrinfo 57, with
  its cross-thread race skipped and the level-3 rows run. Valgrind itself
  is left to Linux CI, which runs it on every push.
