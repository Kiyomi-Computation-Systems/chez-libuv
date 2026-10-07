# uv-spawn!'s lists, read once: mutation log

Evidence for #66 items 2 and 3 and #64 item 4, and for the faults #73's
review found beside them. `uv-spawn!` reads its lists with
`(libuv private lists)`'s `read-proper-list`, where it measured each with
`list?` and then `length`. It reads each field of a stdio spec and of an
options entry once, and it reads its strings with `read-utf8`, the
copy-then-encode that `c-string-bytes` now shares from
`(libuv private c-string)`. From the review: `validate-hints` reads its
alist the same way, `fold-flags` requires its list's end, `read-proper-list`
reads a list changed once as it was before or after the change, and
`c-string-bytes` refuses a non-string by name again.

Everything below was measured on macOS arm64 with Chez 10.4.1, on the tree
this log was committed with, unless it says otherwise.

## The faults

`uv-spawn!` reads `file`, `args` and `options` once, in one interrupt-free
step (#56). The step holds engines off, but not another thread.

- **`read-list`** (`src/libuv/process.sls`, #56) asked `list?`, then took
  `length`, then walked at most that many pairs, checking each, and
  answered what it had read when it met a non-pair. It never required the
  list's end.
  - A list another thread cut between `list?` and `length` made `length`
    raise its own condition, which escaped `uv-spawn!` instead of
    `&uv-invalid-argument`.
  - A list cut during the walk was read as the part before the cut, and
    one made circular there was walked around its cycle for the count.
    Either way the call went on with a list the caller never had.
  - At `--optimize-level 3`, where Chez inlines `length` with no pair,
    cycle or trap check, `length` read through the cut (`invalid memory
    reference`), and a list made circular for good during `length` hung
    it, with interrupts disabled.
- **`read-stdio-spec`** read a pipe spec's `(cdr rest)`, the link from its
  second pair to its third, three times: to check it was a pair, then in
  `cddr` and in `cadr`. Cut in between, Chez's own `cddr` or `cadr`
  raised, and at level 3 the read went through the cut.
- **`read-string`** and `c-string-bytes` each wrote the copy-then-encode
  recipe and the NUL scan (#64 item 4). `c-string-bytes` took its copy
  inside `with-interrupts-disabled`, a dynamic-wind: 64 B a call.

#73's review found four more, two of them older than this branch:

- **`validate-hints`** (`src/libuv/private/addrinfo.sls`, since v0.2.0)
  measured the hints alist with Chez's `list?`, which walks a tortoise
  behind a hare. Two self-loops made at one engine expiry, one at each of
  the alist's first two pairs, can leave the two on separate cycles, and
  then `uv-getaddrinfo!` never returned, on one thread at the default
  level. The review counted 14 of 1,986 trials still running after 300
  resumes of 100,000 ticks on this branch's first push, and 14 of 2,004 on
  main (bfd2bbe). An alist made circular after `list?` returned was
  refused `'duplicate-hint-key`, a reason no version of it gets on entry.
- **`fold-flags`** (`src/libuv/private/lists.sls`; #69 moved it unchanged)
  walked its counted pairs without requiring the end. A flag list spliced
  longer during the walk was folded as far as the stale count: `(a b)` made
  `(a c d)` at the first expiry answered `a|c` at fuels 10 and 11, flags
  the caller never held. `uv-tcp-bind!` and `uv-getnameinfo!` fold their
  flag lists with it.
- **`read-proper-list`**, as this branch first pushed it, answered `#f`
  for a list that changed length once between its count and its walk,
  though the list was proper at every instant. `uv-spawn!` refused such a
  list as no list. Under a thread that made one `set-cdr!` per call, the
  review counted 20,246 of 100,000 calls refused (7,178 at level 3), where
  main refused none. The ADRs and `docs/api.md` said a list changed once
  was read before or after the change.
- **`c-string-bytes`** lost its own string check in the first push.
  `read-utf8` answers `#f` for a non-string, and `bytevector-length` then
  raised its own condition, or at level 3 read through `#f`. Its callers
  check `string?` first, so nothing reached it.

### Main's reads against a flipper

A probe ran main's `read-list` and `read-stdio-spec`, copied out, and this
branch's `read-proper-list` and `read-stdio-spec`, each against a flipper
thread, 100,000 reads a variant, at a load near 21 from other work on the
machine:

| flipper | main's reads | this branch's |
|---|---|---|
| third cdr ↔ a vector | 5,350 raised `length`'s condition; 1,084 read short | the list or `#f` |
| third cdr ↔ a longer tail | 4,536 read the stale count's worth of the longer tail | the list, the longer list, or `#f` |
| third cdr ↔ the head | 5,290 read around the cycle for the count | the list or `#f`; 94 once around the cycle and then to the end |
| a pipe spec's `(cdr rest)` ↔ 0 | 1,498 raised `cddr`'s condition | the spec, or a spec of no kind |

At level 3 a thread made the list circular for good at a moment of its
own, while main's `read-list` read it until `list?` saw the cycle. The
first of 3,000 such trials hung, killed at 90 s. At the default level the
same 3,000 trials finished, and 306 raised `length`'s "is circular" (the
first push's probe).

## The change

- `read-spawn-request` and `read-option` read `args`, `options`, `env` and
  `stdio` with `read-proper-list`. It counts a list with `proper-length`,
  walks at most that many pairs, each checked before it is read through,
  and requires the end after them. When the walk contradicts the count,
  meeting a non-pair before the count runs out or no end after it, it
  counts and walks the list once more. It answers `#f` for a list that is
  not one proper list as it read it, and the checks refuse that with the
  list's reason, as on entry.
- `read-stdio-spec` reads `(cdr rest)` once, and each pair after it once;
  `read-option` reads an entry's key and value once each.
- `validate-hints` reads the alist with `read-proper-list` into fresh
  entries (`read-hint-entry`), each entry's key and value read once, and
  checks that copy, which nothing else reaches.
- `fold-flags` requires the list's end after its counted pairs, and
  refuses a list without one.
- `(libuv private c-string)` gains `read-utf8`, the copy taken with
  interrupts disabled and then encoded (`#f` for a non-string), and
  `nul-free?`, the NUL scan. `uv-spawn!` reads with the first inside its
  step and checks with the second after it; `c-string-bytes` uses both at
  once, and `c-string?` uses the scan. `read-utf8` disables interrupts with
  a bare pair, which allocates nothing, so it hands `string-copy` only a
  string, which raises nothing between the two. `c-string-bytes` refuses a
  non-string as `(c-string-bytes not-a-string)`, under its own name, since
  one reaching it is the binding's own fault.
- `uv-spawn!`'s step keeps `with-interrupts-disabled`, a dynamic-wind,
  though its read raises nothing. A bare pair would save 80 B a spawn, but
  an edit that made the read raise would then leave interrupts off for
  good, and test-process would hang rather than fail rows by name (C4
  below shows the shape).

**Cost.** `c-string-bytes` allocates 112 B for `"127.0.0.1"`, down from
176 B. A spawn allocates slightly less than on main: argv of 3 went
1,040 → 1,008 B (the first push's measurement, the fewest of 32 spawns).
The saving is `check-string`'s scan: main's scan, put back on this branch
(S0), costs a refused three-string spawn 64 B more than its strings' read.
The list reads cost what they did, and the second count and walk cost
nothing on a list that keeps still.

## A read is not a snapshot

A list changed once during a `read-proper-list` read answers as it was
before the change or after it: a change that contradicts the count makes
the read count and walk the list again, and only a second change can
contradict that too. A list changed more than once can answer a mix of
its versions, or `#f` though every version was a proper list. One made
circular and whole again during the count, and again during the walk, is
counted and then walked once around its cycle: `(0 1 2 0 1 2 3 … 11)`, its
elements in an order it never held. The cycle probe at load near 21 saw 89
of 100,000 reads answer that, each exactly once around, and none answer
anything else but the list or `#f`. No read that takes no lock can rule
this out. `lists.sls`'s comment says so, as do ADR-0009 and `docs/api.md`.
`uv-spawn!`'s read is one interrupt-free step, so only another thread can
do this to it.

## Tests

### Shared plumbing

- **`tests/uv-race.sls`** (new, imports only `(rnrs)`): #67's liveness
  watch, which the races of test-native, test-stream and spawn-list-races
  share. `watch-change` waits up to 10^8 steps to see a value cut and then
  its own whole value again, read through the call's argument.
- **`tests/uv-meter.sls`** (new, pure): `fewest-bytes`, the fewest bytes of
  64 calls with the collector held off, for the cost rows of test-native,
  test-addrinfo, test-c-string and test-process.
- **`tests/uv-level-3.sls`** (new, pure): `level-3-run` runs a child
  program at `--optimize-level 3` and kills it at a 60 s monotonic
  deadline. A sleep-counted cap of 6,000 polls of 10 ms came to about 81 s
  on macOS. `level-3-entry` reads one entry of a child's report, totally.
  `make check-purity` holds the two pure libraries through test-c-string
  and test-addrinfo.

### `tests/spawn-list-races.sls` (new, not pure)

Nine races. In each a flipper thread turns one field of a pair a call is
given, a cdr or a car, between a cut and its whole value. Meanwhile this
thread calls `uv-spawn!` with that pair at least 100,000 times. Every call
is refused before anything is allocated, for one of two reasons:

| race | the field | whole | cut |
|---|---|---|---|
| `args` | args' third cdr ↔ a vector | `'embedded-nul` (the last string) | `'args-not-a-string-list` |
| `args-circular` | args' third cdr ↔ args | `'embedded-nul` | `'args-not-a-string-list` |
| `env` | env's third cdr ↔ a vector | `'embedded-nul` | `'env-not-a-string-list` |
| `options` | options' third cdr ↔ a vector | `'uid-out-of-range` (the last entry) | `'option-unknown` |
| `stdio` | stdio's third cdr ↔ a vector | `'stdio-fd-not-an-fd` (the last spec) | `'stdio-not-a-list` |
| `pipe-spec` | `(pipe p from-child)`'s second cdr ↔ 0 | `'pipe-wrong-loop` | `'stdio-spec-unknown` |
| `pipe-spec-head` | the same spec's first cdr ↔ 0 | `'pipe-wrong-loop` | `'stdio-spec-unknown` |
| `entry-key` | an options entry's key, `env` ↔ `cwd` | `'pipe-wrong-loop` | `'cwd-not-a-string` |
| `spec-kind` | a stdio spec's kind, `pipe` ↔ `inherit-fd` | `'pipe-wrong-loop` | `'stdio-fd-not-an-fd` |

- A read that stops short skips that last element, so its call goes on and
  is refused for its pipe, which is on another loop (`'pipe-wrong-loop`).
- Every call names `/nonexistent/sh`. A read that loses the pipe as well
  reaches `uv_spawn` and is refused there with `ENOENT`, leaving no child.
  A race stops at the first such outcome, since each failed spawn leaves a
  closing handle that the next one's cleanup walks past. It counts every
  other wrong outcome and goes on.
- Before the first call and after the last, each race watches its flipper
  cut the field and make it whole again (`watch-change`). It then calls on
  past 100,000 until a call has been refused for the cut, up to 1,000,000,
  so a flipper idle during the calls fails the precondition.
- Each race stops and joins its flipper in a dynamic-wind, and both loops
  are nested `call-with-uv-loop`s. A raise mid-race therefore leaves no
  thread and no handle, and the suite reaches its end rows (V10A and V10B
  below).
- `malformed-refusals` gives each of the four lists improper and circular
  from the start, with no thread.
- `defined-list-races` names every race the library defines.

### `tests/test-process.sps` (156 rows; 139 on main)

- `list-race-rows`, one alist of (race . row name), drives the races run
  and their nine rows. A row holds that every race the library defines has
  its row there, in its order. A precondition row holds each race's two
  watches and its cut-seen. The races and that row skip under Valgrind,
  which runs one thread at a time.
- The malformed lists, which need no thread and run under Valgrind too.
- Two cost rows, each a difference, not a figure:
  - a refused spawn with args improper or circular costs what one with
    args of `()` does (counting allocates nothing);
  - a refused three-string spawn costs its strings' read and nothing more
    (a pair, a copy and its UTF-8 a string).

  All three shapes of the first go through one closure whose args a
  `set!` assigns: cp0 folds a literal `()` into a closure of its own, 16 B
  smaller.
- A NUL as the first or the last character of an args string.
- **Level 3.** `tests/spawn-level-3-child.sps` runs the malformed lists at
  `--optimize-level 3`, in a child under the deadline. A seed row holds
  that the child ran at level 3 and that `library-object-filename` is `#f`
  for `(libuv process)`, `(libuv private lists)`, `(libuv private
  c-string)` and `(spawn-list-races)`, so no stale `.so` beside a source
  ran in its place. The child imports each library it names, since
  `library-object-filename` raises for a library not loaded. Main's
  `(libuv process)` loads neither private library, and the raise cost that
  run its malformed lists' report.

  The races run at the default level only. The first push ran them at
  level 3 too, but a guarded read hides what it reads through at level 3
  just as it hides a raise at the default level. No mutant was caught by
  those rows alone, and they cost CI 2.5–4.1 s a `make test` pass.

### `tests/test-native.sps` (320 rows; 314 on main)

- **The cycle race**, two rows. A flipper makes the list circular and whole
  again; every read must answer `#f` or a walk of the list to its end,
  around the cycle as often as it found it there.
- **The one-change race**, two rows. Another thread turns the second
  pair's cdr between two proper tails, once a round, at a random moment
  within the read. Every read must answer the shorter list or the longer,
  never `#f`, and a precondition holds that the reads saw both.
- **The fold-flags splice sweep**, two rows. A tail is spliced in at the
  first expiry. Every fold must answer the flags of the list as it was or
  as the splice left it, or refuse it, and a precondition holds that the
  sweep spliced before the walk and ended untouched.
- `list-race` takes the cut and a classifier, so the cut and cycle races
  share it, and its watch comes from `tests/uv-race.sls`.
- The suite prints a failing row's evidence, as test-process does.

### `tests/test-addrinfo.sps` (58 rows)

- Two hints variants join the sweep: `spine-split-in-two`, a self-loop at
  each of the first two pairs at one expiry, and `spine-made-circular`.
  Either must be refused `'hints-not-an-alist` or answered as given.
- The level-3 seed now checks the objects as test-process's does.
- `tests/flags-level-3-child.sps` imports each library it names.

### `tests/test-c-string.sps` (new, pure, 7 rows)

- `read-utf8` answers a string's UTF-8 and `#f` for anything else, and
  leaves interrupts enabled either way. The row undoes any disable left
  outstanding, so a mutant fails it rather than stalling every engine after
  it.
- `nul-free?` finds a NUL anywhere in its first END bytes, and looks no
  further. `c-string?` accepts exactly a bytevector whose only NUL is its
  last byte.
- `c-string-bytes` answers UTF-8 and one NUL, and refuses a NUL of its
  own, naming its caller and reason. It refuses a non-string under its own
  name.
- A cost row: `c-string-bytes` allocates what its copy, the copy's UTF-8
  and its answer cost made directly.
- Pure, so a mutant of these procedures fails rows here by name even when
  it stops `native.sls` working (N3).

### `tests/test-stream.sps` (37 rows)

Its span race takes `watch-flipper` from `tests/uv-race.sls`.

## On main

The suites run on main's four changed sources (`process.sls`, `lists.sls`,
`addrinfo.sls` and `c-string.sls`, at 1504309) with this branch's other
code, at load 4 to 10 (MAIN-SRC):

| suite | failed rows |
|---|---|
| test-process | 6 race rows, and the read-cost row (64 B) |
| test-native | the one-change row (11 of 20,000 reads `#f`) and the fold-flags splice row |
| test-addrinfo | the hints sweep row: `spine-split-in-two` stuck at fuel 9 and refused `'duplicate-hint-key` at fuels 10–13, `spine-made-circular` refused `'duplicate-hint-key` at 10–13 |
| test-address | none |
| test-c-string | cannot load: main has no `read-utf8` |

test-process's failing race rows, with the wrong calls of 100,000 and the
first wrong outcome:

| race | wrong calls | first wrong outcome |
|---|---|---|
| `args` | 27,102 | `length`'s "is not a proper list" |
| `args-circular` | 7,861 | `'pipe-wrong-loop` (read short) |
| `env` | 17,418 | `length`'s "is not a proper list" |
| `options` | 25,887 | `'pipe-wrong-loop` |
| `stdio` | 8,828 | `length`'s "is not a proper list" |
| `pipe-spec` | 6,246 | `cddr`'s "incorrect list structure" |

The precondition row passed, so each flipper was live. The other three
races pass on main, which read those fields once. The malformed rows, the
count-cost row, the NUL row and the level-3 rows pass too. `list?` refuses
a list malformed from the start at every level, and main's scan reached
every byte. They hold shapes main never had; the mutations show what each
catches. Main's `process.sls` with every outcome counted right
(MAIN-PROC+G6) fails only the read-cost row, so the race rows catch main
through their classification.

## Mutations

Each ran on a scratch copy of `src/` and `tests/` (`build/` linked in),
each target replaced exactly once, on every suite named. The process
mutants ran test-process; three ran at a time, at load 4 to 10. The control,
the same copy unmutated, passes every suite run.

### `uv-spawn!`'s read (`process.sls`)

| id | mutation | failed rows |
|---|---|---|
| MAIN-PROC | main's `process.sls` | the six old race rows (3,471–19,384 wrong calls), the read-cost row |
| P1 | `args` read with main's `read-list` | `args` (17,906) and `args-circular` (12,497) |
| P2 | `options` likewise | `options` (16,737) |
| P3 | `env` likewise | `env` (20,000) |
| P4 | `stdio` likewise | `stdio` (9,295) |
| P5 | `read-stdio-spec` as on main | `pipe-spec` (800, `cddr`'s condition) |
| P6 | `args` counted with a guarded `length` (#51's shape) | the count-cost row (784 B a shape); the level-3 seed and malformed rows (`killed-at-cap`, 60 s) |
| P6U | `args` counted with a bare `length` | the malformed row (`length`'s own conditions), `args` (56,852) and `args-circular` (186), the count-cost row, the level-3 seed and malformed rows |
| P7 | `args` read without requiring the end | `args-circular` (15,957) |
| P8 | a pipe spec's end not required | "a (pipe ...) spec with more than a pipe and a direction"; "validation created no process handle" |
| P9 | a pipe spec's rest read as a pair unchecked | "a (pipe) spec with no pipe"; `pipe-spec-head` (361,511 of 1,000,000, `cdr`'s condition); the precondition (no cut seen) |
| P10 | the pipe read as `(cadr spec)` | `pipe-spec-head` (320, `cadr`'s condition) |
| P11 | an entry's key read twice | `entry-key` (3), now and then: see below |
| P12 | a spec's kind read twice | none in this run: see below |
| S0 | main's NUL scan in `check-string` | the read-cost row (64 B) |
| S1 | `check-string` misses a final NUL | the NUL row; "validation created no process handle"; `env` (23,460); the read-cost row (`ENOENT`) |
| S2 | `check-string` scans nothing | 12 rows, every NUL row among them |
| A0 | `read-proper-list` answers `()` for `#f` | 9 rows: two older list-shape rows and "validation created no process handle", the malformed row, `env`, `options` and `stdio` (the last two stopped at their first `ENOENT`), the precondition, the level-3 malformed row |

**P11 and P12.** A key or a kind read twice is two reads of one car, a few
instructions apart. The flipper's store rarely lands between them unless
the reading thread is descheduled there, and no engine can split them,
since nothing between the two reads checks for an event. Run alone 30 times at a
load near 3, the `entry-key` race caught P11 in 1 run, and the `spec-kind`
race caught P12 in 2. Unmutated, neither race found a bad call in 30 runs.
Inside the suite, three suites at a time at load 4 to 10, P11 was caught in
2 of 2 runs and P12 in 1 of 2. So these two decisions are held, but weakly.
More calls would raise the odds at the cost of suite time, and no
deterministic row can reach them.

### The lists (`lists.sls`)

| id | mutation | failed rows |
|---|---|---|
| MAIN-LISTS | main's `lists.sls` | test-native's one-change row (23 `#f`) and fold-flags splice row |
| L1 | `read-proper-list` without its second count and walk | the one-change row (27 of 20,000 `#f`) |
| L2 | the second walk taking the first count | the one-change row (24 `#f`) |
| L3 | every list read twice | "read-proper-list reads each element once, in order, into a fresh list"; the one-change row; test-addrinfo's flags cost row (96 B) |
| L4 | `fold-flags` without its end check | the fold-flags splice row (folds from fuel 17 on answered flags of neither list) |
| E1 | `read-counted` without its end check | test-native: the read sweeps row, the cycle race (8,723 of 100,000), the one-change row; test-process: `args-circular` (17,580); test-addrinfo: the hints sweep row |

### The hints (`addrinfo.sls`)

| id | mutation | failed rows |
|---|---|---|
| MAIN-ADDRINFO | main's `addrinfo.sls` | the hints sweep row, as on main above |
| A2 | `read-hint-entry` answers the entry itself | "a non-pair element is refused" (`car`'s condition) |

### The strings (`c-string.sls`)

The suites: test-c-string, test-native, test-addrinfo, test-address.

| id | mutation | failed rows |
|---|---|---|
| C1 | `read-utf8` hands `string-copy` a non-string | test-c-string's three `read-utf8` and non-string rows (two disables left outstanding) |
| C2 | the copy taken with interrupts enabled | test-addrinfo's truncated-node row; test-c-string passes, as it changes no string mid-copy |
| C3 | the copy inside `with-interrupts-disabled`, as on main | the cost row (64 B) |
| C4 | interrupts never enabled again | the interrupts row (three disables left); run on test-c-string only, since the first push's run found test-native and test-addrinfo fail their sweeps by name and then deadlock in a race |
| C5 | `c-string-bytes` without its string check | the non-string row (`bytevector-length`'s condition) |
| C6 | that check naming its caller | the non-string row (refused under `test-who`) |
| N1 | `nul-free?` starts at byte 1 | the `nul-free?` and `c-string?` rows; test-native's address-NUL row; test-address's three NUL rows |
| N2 | `nul-free?` misses the byte before END | the `nul-free?`, `c-string?` and `c-string-bytes` rows; 1 row of test-native, 7 of test-address |
| N3 | `nul-free?` ignores END | the `nul-free?` and `c-string?` rows; test-native and test-address cannot load (`&uv-constant-unavailable: UV_RUN_DEFAULT`) |
| K1 | `c-string?` asks for no terminator | the `c-string?` row; test-native's two "not one C string" rows |
| B1 | `c-string-bytes` refuses no NUL | the `c-string-bytes` row; 1 row of test-native, 4 of test-addrinfo, 5 of test-address |
| B2 | `c-string-bytes` answers no terminator | the `c-string-bytes` row; 1 row of test-native, 11 of test-addrinfo, 5 of test-address |

### The fixtures and the shared plumbing

| id | mutation | failed rows |
|---|---|---|
| G1 | the flipper never flips | the precondition (`not-flipping`, no cut in 1,000,000 calls) |
| G2 | the `args` flipper turns another pair than the one watched | the precondition, for `args` and `args-circular` |
| G3 | a flipper that cuts and never makes the field whole | the precondition |
| G4 | a flipper that swaps the cut for another bad value | the precondition; `entry-key` and `spec-kind` (a vector as key or kind) |
| G5 | G4, and the watch without its "whole again" check | `entry-key` and `spec-kind` only: the precondition passes |
| G6 | every outcome counted right | none: passes |
| MAIN-PROC+G6 | main's `process.sls`, and G6 | the read-cost row only |
| G7 | the flipper flips only around the two watches | the precondition (no cut in 1,000,000 calls, each race) |
| R1 | `spec-kind` left out of test-process's alist | "every race tests/spawn-list-races.sls defines has its row here, in its order" |
| V10A | an unknown race name among those run | the nine race rows and the precondition; the counter, registry and level-3 rows pass, and the suite prints its summary |
| V10B | a raise mid-race, after the flipper is forked | the same: the flipper is joined, and the suite's last `(collect)` runs |
| SO | every library compiled beside its source first | test-process's and test-addrinfo's seed rows (the `.so` paths) |
| SO+P6 | SO, and P6 | the count-cost row and the seed: the level-3 malformed row passes, since the child ran the default-level `.so`, as the review found it did |
| H1 | a level-3 deadline of 0 | test-process's seed and level-3 row; test-addrinfo's seed and three level-3 rows (`killed-at-cap`) |
| H2 | the children run without `--optimize-level 3` | both seeds (level 0) |
| H3 | `level-3-entry` without its alist check | with `CHEZ_LIBUV_TEST_CHEZ=/nonexistent/chez`, the level-3 rows fail as before but show `#f`, where the guard shows the shell's error |
| W1 | a liveness watch that gives up at once | test-process's precondition, test-native's three race preconditions, test-stream's span-race precondition |
| M1 | a blind meter | every cost row: two of test-process, one each of test-addrinfo, test-native and test-c-string |
| E2 | test-native's flipper never restores the list | its three race preconditions |
| E3 | the one-change race's other thread never changes the list | its precondition (`shorter 20000 longer 0`) |
| E4 | the splice sweep splices nothing | its precondition |
| E5 | `spine-split-in-two` changes nothing | "each hints sweep began before the walk read the hints and ended untouched" |
| E6 | `spine-made-circular` changes nothing | the same row |

- **G5 and G6** pass as their pairings require. G5 shows the watch's
  "whole again" check is what catches G4 in the cdr races. G6 with main
  (MAIN-PROC+G6) shows the classification is what catches main.
- **H3** changes no verdict. The guard keeps a failed child's output in the
  row that fails, which is what it is for (#73's review found
  test-addrinfo's reader without it).
- **No child is left behind.** A driver ran every race and the malformed
  lists under A0 while a sampler listed its children every 5 ms. Naming
  `/nonexistent/sh`, it left none: each call that reached `uv_spawn` was
  refused `ENOENT`. Naming `/bin/sh`, as the first push did, the same run
  left 6 zombies until the driver exited, even with each race stopping at
  its first spawn. The first push's races did not stop there, so a misread
  forked once a call; the review counted about 73,000 calls of 100,000 in
  the `options` and `stdio` races spawning under such a mutant.

## Corrections to the first push's log

- At level 3 the race rows on main gave `invalid memory reference` or a
  short read, never `length`'s or `cddr`'s own condition.
- The level-3 cap was 6,000 polls of 10 ms, about 81 s on macOS, not 60 s;
  it is now a 60 s deadline by the monotonic clock.
- P6 was credited with the default-level malformed row, which it passes.
  A bare `length` (P6U) fails it. P6 is caught by the count-cost row and
  the level-3 child.
- test-c-string's header said any break of these procedures fails the
  native suites at import. Only N3 stops them, at the first
  `ensure-native-loaded!`. C2 passes the pure suite.
- `uv-spawn!`'s strings never paid 64 B each for a fence: main's
  `read-string` took none.
- test-native's cycle race rows had no watched failure: E1 and E2 fail
  them.

## Gates

At load averages near 6 to 13:

- `make test`: 26 suites pass. test-process has 156 rows, test-native
  320, test-addrinfo 58, test-c-string 7, test-stream 37.
- `make test-threading`, `make check-purity` (test-c-string and
  test-addrinfo among its suites), `make check-help` and `make check-pins`
  pass.
- macOS ASan, `make test-memory`: 26 suites pass with no
  AddressSanitizer report. Every race was live, with 39,205 to 80,135 of
  100,000 calls refused for the cut, and the level-3 rows ran.
- The Valgrind skip path, run natively with `CHEZ_LIBUV_UNDER_VALGRIND=1`:
  the thread races skip in both suites, and the malformed and level-3
  rows still run. test-native passes, 312 rows. test-process fails one
  row, #68's squatter row, which picks its expectation by that variable:
  with no real memory tool the allocator does reuse the freed blocks. main
  fails it the same way, run the same way. Valgrind itself is left to CI.
