# Race-row liveness: mutation log

Evidence for the precondition rows that hold #65's two race rows to a
flipper that is flipping: test-native's `proper-length` race and
test-stream's span race.

## The gap

#65 (a473313) added two two-thread race rows. Each asserts only what no
schedule can make fail on a right answer: every count answers `#f` or 12,
and every write is refused by the verb or by libuv's errno. Each prints, as
an informational line, how many reads the flipper's change reached. Nothing
checked the flipper itself:

- A flipper that never flipped left every row passing, with no read cut
  (F1 below: the race rows pass, and only the new row fails).
- A flipper that raised never said it had stopped, so the race's wait for
  it never returned. On main, test-native with a flipper that raises
  before its first flip hung until a 30 s cap killed it (`main-F2`).

test-addrinfo's and test-process's races already hold their racer to this:
each round waits, under an iteration cap, for the racer to change the
datum, and raises naming it dead past the cap.

## The change

- **Two waits.** Before the first read and after the last, each race waits
  up to `race-wait-cap` steps (100,000,000, the cap test-addrinfo and
  test-process use) to see the flipper cut the datum and make it whole
  again (`watch-flipper`). A precondition row in each suite expects
  `(flipping flipping)`, so a failure says which end failed. The first wait
  also holds the race until the flipper is flipping (F7, W5).
  - Not a wait per round. test-addrinfo's and test-process's rounds undo
    the racer's work, so each must wait for it again. These flippers never
    stop, and a per-round wait across 100,000 rounds would pay a scheduling
    delay each time the flipper is off the CPU.
- **Whole, not just changed.** The watch requires the datum's own tail back
  (`eq?` to `rest` and `tail`), not merely something other than the cut. A
  flipper that swapped the cut for another bad value would leave every read
  cut: each count answers `#f`, each write is refused alike, and the race
  rows pass while no read can split a checked value from a stale one (F8,
  W7).
- **Through what the code reads.** The watch finds its pair through `l` and
  `segs`, the values the count and the write are given, so a flipper that
  changes some other list fails the row (F4, W4).
- **A join.** Each race joins its flipper (`thread-join`, as test-process
  does) instead of waiting on a mutex and condition for it to say it
  stopped. A flipper that raised now fails the row instead of hanging the
  suite (F2). No thread outlives the race either: test-stream's later
  `(collect)` raises "cannot collect when multiple threads are active"
  while one does (J1 with X).
- Whether a change lands mid-read stays informational.

Platform: macOS arm64 (Darwin 25.6.0), Chez 10.4.1 (`tarm64osx`), libuv
1.52.1, the dev build.

## The waits, measured

Each suite's copy printed both waits' step counts, 8 runs each, at load
averages near 7:

| suite | before the first read | after the last |
|---|---|---|
| test-native | 11,830–24,458 steps | 11–1,584 |
| test-stream | 3,655–21,625 | 18–7,124 |

The cap is 100,000,000, about 4,000 times the longest wait. A dead flipper
costs two capped waits: test-native ran in 0.7 s against 0.5 s. The races
overlap as before: on the gate runs, 69,719–71,421 of 100,000 counts and
16,970–16,975 of 20,000 calls found the change.

## Mutations

Each ran on a scratch copy of `tests/`, with `src/` and the shim unchanged.
The copy of test-native printed a failing row's actual value, as
test-constructors does; test-stream has that hook already. A cap of 60 s
(30 s for `main-F2`) stopped any suite that hung. All 46 runs are on the
final tree.

### The flipper

Each fault must fail the precondition row by name. The race row passes with
every one of them: that is the gap.

| id | the flipper | test-native | test-stream |
|---|---|---|---|
| F1 | never flips | FAIL `(not-flipping not-flipping)`; 0 cut | FAIL `(not-flipping not-flipping)`; 0 cut |
| F2 | raises before its first flip | FAIL `(not-flipping not-flipping)` in 0.7 s | FAIL `(not-flipping not-flipping)` in 1.9 s |
| F3 | stops after 10,000 flips | FAIL `(flipping not-flipping)`; 175 cut | FAIL `(flipping not-flipping)`; 56 cut |
| F4 | changes another list (span) | FAIL `(not-flipping not-flipping)`; 0 cut | FAIL `(not-flipping not-flipping)`; 0 cut |
| F5 | cuts and never makes it whole | FAIL `(not-flipping not-flipping)`; 100,000 cut | FAIL `(not-flipping not-flipping)`; 20,000 cut |
| F6 | never cuts | FAIL `(not-flipping not-flipping)`; 0 cut | FAIL `(not-flipping not-flipping)`; 0 cut |
| F7 | spins 50,000,000 steps before its first flip | passes; 67,281 cut | passes; 16,928 cut |
| F8 | swaps the cut for another bad value (a vector; `'oops2`) | FAIL `(not-flipping not-flipping)`; 100,000 cut | FAIL `(not-flipping not-flipping)`; 20,000 cut |

F7 is a flipper that starts late but is sound, so it must pass. The first
wait held the race until it was flipping.

`main-F2`: main's test-native with F2 hung until the cap killed it. Its
flipper never set `stopped`, and the race waited on the condition for it.

### The watch and the join

Two mutants make a sound flipper fail the row in both suites with
`(not-flipping not-flipping)`: W2, a cap of 0, and W9, a cut clause that
never matches.

The other mutants change only what a faulty flipper is told. A sound flipper
passes every row with each of them alone (all ten runs passed, with the
usual overlap). Each is paired with the fault its decision exists to catch,
and lets that fault through:

| id | mutation | paired with | test-native | test-stream |
|---|---|---|---|---|
| W1 | `flipping` without a cut seen first | F1 | passes; 0 cut | passes; 0 cut |
| W3 | no wait after the last read | F3 | passes; 4,458 cut | passes; 60 cut |
| W4 | watch the flipper's own pair (`p`, `second`) | F4 | passes; 0 cut | passes; 0 cut |
| W5 | no wait before the first read | F7 | passes; 0 cut | passes; 0 cut |
| W6 | no cap | F1 | hung, killed at 60 s | hung, killed at 60 s |
| W7 | after a cut, anything but the cut counts as whole | F8 | passes; 100,000 cut | passes; 20,000 cut |

W5 with F7 is the vacuous race the first wait prevents. Every read ran
before the late flipper began, and every row passed.

The join, in test-stream, where `(collect)` runs after the race:

| id | mutation | result |
|---|---|---|
| X | the flipper spins 3,000,000,000 steps after it stops | passes, in 4.1 s: the race waits for it |
| J1 | no join | passes: the flipper is gone long before the `(collect)` |
| J1 + X | both | the suite dies (rc 255) at `(collect)`: "cannot collect when multiple threads are active". The two bulk-write timing rows failed first, with the flipper spinning beside them |

### Uncovered

Nothing. One wrong turn is worth recording. Paired only with F5, W7 passed
as an equivalent mutant: F5 leaves the list cut for good, and the cut clause
comes first, so the `whole` comparison is never reached. That suggested the
comparison guarded nothing, and it was dropped from a draft. F8 is the fault
it guards. A watch without it took F8 for a live flipper, while every read
was cut and both race rows passed. Before calling a check unbreakable, look
for the fault it tells apart from its neighbours, not only the one first
tried.

## Gates

Run on the final tree:

- `make test`: 24 suites pass, test-native with 307 rows (was 306) and
  test-stream with 37 (was 36). `make test-threading`, `make check-purity`
  and `make check-help` (silent) pass.
- macOS ASan, `make test-memory`: 24 suites pass with no AddressSanitizer
  report. Both races ran there, with their precondition rows. test-native
  passes 305 there, because two allocator-refusal rows stay out under ASan.
- The Valgrind skip path, run natively with `CHEZ_LIBUV_UNDER_VALGRIND=1`:
  test-native 305 rows and test-stream 35, as before. Both rows of each race
  skip. Valgrind itself is left to Linux CI. The change does not touch the
  memory gate's recipes, so `check-memory-gate` was not rerun.
