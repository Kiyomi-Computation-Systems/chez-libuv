# uv-write*!'s segment list, read once: mutation log

Issue #64, item 1. Branch `fix/write-segments-once`, from `main` at e94b2b6.
Chez 10.4.1 on macOS arm64 unless a section says otherwise.

`uv-write*!` checked `(list? segments)` and then parsed the list with
`(map parse-write-segment segments)`, both before #53's interrupt-free step.
Chez's `map` counts a list and then walks it without checking its pairs
again. An engine's timer handler, or another thread, that changes the list
between the count and the walk has the walk read through whatever it put
there.

## The fault, confirmed

### In Chez itself, without the binding

A 12-element list walked in an engine at rising fuel. At the first expiry,
the third pair's cdr becomes a non-pair, and the walk is resumed to the end:

| walker | outcome by fuel |
|---|---|
| `map` | 1–4: `map`'s own "is not a proper list"; **5–9: `invalid memory reference`**; 10+: no expiry |
| `for-each` | 1–4: "is not a proper list"; 5–12: "input list was altered during operation"; 13–41: completes |
| a walk that checks `pair?` at each step | 1–3: refused; 4–33: completes |

A vector, a symbol, a fixnum, a string and a bytevector as the new tail all
gave the same `map` window. A mutation made from inside the function `map`
applies does nothing, because `map` reads the whole list before it applies
the function: it applied it in the order `(5 6 3 4 1 2)` to a list of six.

With the third pair's cdr pointing back at the list's head instead, `map`
never finished. The engine never expired again, so a resume cap could not
stop it. The process grew to 5,862 MiB of resident memory before it was
killed. `for-each` raised "is circular" instead.

### In the verb, on main

`tests/test-stream.sps`'s new sweeps, run against e94b2b6's `stream.sls` and
`native.sls` (fuel maps printed by a scratch copy of the suite):

| sweep | fuel map |
|---|---|
| segments-cut | 1–10 refused; 11–18 `map`'s "is not a proper list"; **19–23 `invalid memory reference`**; 24–56 written; 57 untouched |
| segments-made-circular | skipped: the cut sweep had another answer |
| span-cut | 1–25 refused; 26–27 `length`'s "is not a proper list"; 28–60 written; 61 untouched |

The issue measured the cut sweep's windows one fuel lower (its own sweep's
plumbing differs). The span sweep's two runs are the issue's "smaller scale"
case, unmeasured there: `parse-write-segment` asked `list?`, an expiry came
before its `length`, and `length` raised its own condition instead of the
verb's refusal. In safe code that read is checked; at `--optimize-level 3`
it is not.

### In proper-length, found by the fix's first run

The first fix counted with #61's `proper-length` and walked with a checked
walk. Its cut sweep raised `Exception in cdr: #(not a pair) is not a pair`
at fuel 11, from `proper-length` itself. Its tortoise walks pairs the hare
has passed, and took `(cdr tortoise)` of whatever it found. A cut behind
the hare put a vector there, and the next step took its cdr. At
`--optimize-level 3` that is an unchecked read. #61's flag sweeps could not
see it: a list of one or two flags never leaves the tortoise behind a cut.

## The fix

- `proper-length` (native.sls) takes every cdr of a value just found to be a
  pair, and reads each once. A tortoise that finds no pair answers `#f`. It
  still raises nothing and allocates nothing. It is exported now.
- `read-segments` (stream.sls) parses the list `proper-length` counted, at
  most N pairs, checking each before it reads it. It requires the list's end
  after them. `fold-flags` does not: a flag read twice sets the same bit
  twice, but a list made circular after the count would send its first
  segments again.
- `parse-write-segment` reads a `(bv start end)` span once, each pair
  checked, and refuses the same shapes it refused before.
- `uv-write*!` still allocates 208 B (`tests/test-callback-alloc.sps`'s row,
  unchanged).

## The rows

`tests/test-stream.sps`, "a segment list that changes during the call":
three sweeps on the shrinking-payload sweep's machinery. That machinery
(`change-verdict`, `sweep-runs`, `rows-in`) now takes the change as an
argument, and gives up a run after 20 resumes, so a walk that never ends
fails its run by name.

- segments-cut: the third pair's cdr becomes a vector.
- segments-made-circular: the third pair's cdr becomes the list's head. It
  runs only when every run of the cut sweep had a right answer: on a walk
  that reads through a non-pair, it would hold the machine's memory instead
  of failing. Skipped, it fails both rows below by name.
- span-cut: the third segment, a `(bv 0 5)` span, loses its end.

Each segment is filled with a byte of its own, so a walk that read a segment
twice or out of order cannot send the bytes the call was given. The rows:

- each segment-list sweep began at fuel 1 with a refusal and ended in a run
  no expiry reached;
- a uv-write*! whose segment list changed during the call is refused by the
  verb itself, leaving no request;
- a uv-write*! the segment-list sweeps let through sent the peer exactly the
  segments it was given.

On this branch each sweep reads: 1–18 refused, 19–53 written, 54 untouched.

`tests/test-native.sps`, "proper-length: a list changed during the count":
two sweeps, a cut and a cycle at the third pair. Every run must answer `#f`
or 12, and the reach row requires the first run to have changed the list
before the count began and the last to have counted it whole.

`tests/test-tcp.sps`: an improper or a circular list, and five span shapes
(too short, too long, improper, cut, a string head), are refused before
allocation as before. The circular row runs in an engine whose resumes are
capped (`capped`), so a count that loops fails the row instead of hanging the
suite.

## Mutations

Each ran on a fresh copy of `src/` outside the repo, by exact text
replacement that aborts unless its target occurs once, under a watchdog
(2 GB resident, 600 s). Nothing hung; nothing reached the watchdog.

| id | mutation | caught by |
|---|---|---|
| W1 | the walk takes car and cdr without `pair?` | test-stream: refused, reach (`car: #(not a pair) is not a pair` at 12–18; the cycle skipped) |
| W2 | the walk follows the list to its end, not at most N pairs | test-stream: refused, reach |
| W3 | the walk stops after N pairs without requiring the end | test-stream: sent the peer exactly the segments |
| W4 | the verb parses with Chez's `map` again | test-stream: refused, reach (`invalid memory reference` at 19–23) |
| W5 | the verb counts with `list?` then `length` | test-stream: refused, reach (`length` raised at 11–17) |
| W6 | a list changed during the walk is refused as `segments-changed` | test-stream: refused, reach |
| W7 | an empty list goes to libuv | test-tcp: an empty segment list is refused before allocation |
| S1 | the span's second pair is read without `pair?` | test-tcp: a span that is not exactly (bytevector start end) is refused |
| S2 | the span's third pair is read without `pair?` | test-stream: refused, reach (`car: oops is not a pair` at 1–18); test-tcp: the span row |
| S3 | a span longer than three is accepted | test-tcp: the span row (and four later rows, which the accepted write left a request in flight for) |
| S4 | the span is checked with `list?` and `length` before it is read | test-stream: refused (`length` raised at 20–21) |
| P1 | the tortoise takes the cdr of whatever it found | test-native: proper-length answers #f or the count; test-stream: refused, reach |
| P2 | `proper-length` has no cycle check | test-native: proper-length, its reach row, and fold-flags' circular row; test-tcp: the improper-or-circular row, by name once its capped engine gave up, where it would otherwise have hung the suite |
| P3 | `proper-length` is #61's shape again | test-native: proper-length answers #f or the count; test-stream: refused, reach |
| P4 | the hare reads its pair's cdr twice (`cddr`) | uncovered, below |

## Uncovered

P4 re-reads a cdr with no trap check between the two reads, so no engine can
expire between them, and the sweeps cannot split them. This section said only
another thread could, "which no single-threaded row can order", and left it
without a row. The review showed that wrong, and that a second double read
had gone unlisted. Both are held now by two-thread rows (below).

## The review

A /code-review at max effort (ten finder angles, one verifier per
candidate, then a sweep for gaps) found these in the PR. All are fixed in
the commit after 139ebe4 unless the list says otherwise.

- **proper-length could still loop forever.** Its tortoise walked the
  list's links behind the hare, so two changes in one count could leave the
  two on separate cycles. Four angles found it independently. With
  `(set-cdr! p5 p4)` and `(set-cdr! p11 p10)` made at one expiry,
  uv-write*! was still running after 200 resumes of a million ticks, at fuels
  11 to 13. In 30,000 random trials the count hung 129 times, including on a
  three-element list, the size of a flag list. Chez's own `list?`, which
  main used, hangs the same way. Fixed: one walk with Brent's check, whose
  mark moves to the pair it stands on at each power of two of the count. It
  takes each cdr once, of a value just found to be a pair, and compares the
  mark with `eq?` only. A count of N pairs takes N + 1 engine ticks. The
  contract now says a count can be stale.
- **A double read went unlisted.** Reading a span's end back as
  `(caddr seg)` passed every suite and was missing from the table above.
  Under a racing thread it raises Chez's own "incorrect list structure":
  6,661 to 8,884 times in 200,000 calls. And P4 could have had a row: a
  two-thread race catches it every time.
- **A sweep that could not deliver ran its drain dry at every fuel.** Each
  segment-list sweep writes three dozen runs. Against a uv-write*! whose
  completion never arrives, test-stream took 192 s before any row printed,
  64% of the suite's timeout. sweep-runs now stops at a run whose drain ran
  out. On the same build the suite fails the same 9 rows by name in 14 s.
- **The order of a refusal was unpinned.** A list with two malformed
  segments is refused for the first of them. Chez's map named the first in
  only 24 of 112 placements, and a walk that parsed the rest first still
  passed every suite.
- **`capped`'s give-up never reached its row.** wv-refusal recorded it as a
  call that returned, `(no-raise (0 0) 0)`. The row now wraps capped round
  the whole of wv-refusal.
- **Smaller things.** change-verdict's parameters shadowed `write` and
  `expected`. The list-variant record had a field nothing read. The reach row
  was pasted twice, and the two sweep families had bad-verdict predicates of
  different shapes; the enumerated one missed a stuck shrink run.
- **A spec was a list of three, 48 B a segment, live for the whole walk.**
  A million-segment write ran 11 or 12 collections to main's 2, and took
  15-26% longer. A spec is now `(bv . len)` for a span from 0, else
  `(bv start . len)`. That brings one segment from 208 to 176 B, and 64
  segments from 5,248 to 3,200 B. A million one-byte segments written to an
  unconnected pipe (parsed, copied, then refused by libuv) now take as long
  as on main: 60–72 ms against 61–90 ms over five calls, with 7 collections
  against main's 2 (macOS arm64, 3335c38).
- **Not fixed here: #66 has them.** Three older walks have
  the faults this PR removed from uv-write*!, and none of the three is in
  its diff:
  - addrinfo.sls's checked-flags hangs on circular flags at
    --optimize-level 3;
  - process.sls's read-list counts with list? and then length and never
    requires the end;
  - process.sls's read-stdio-spec re-reads a checked cdr.
  Also deferred: one shared counted walk, and one shared engine-sweep
  driver for the suites.

With the Brent count, a count of N pairs takes N + 1 engine ticks, so the
sweeps' windows moved. On 3335c38 each reads refused, then written, then
one untouched run: fuels 1–24, 25–59 and 60 for segments-cut,
segments-made-circular and span-cut, and 1–33, 34–59 and 60 for
segments-two-cycles.

### The rows the review added

- tests/test-native.sps:
  - a two-cycles proper-length sweep, beside the cut and the cycle;
  - 3,000 seeded random trials, in which one or two changes land at one or
    two expiries, and every count must end and raise nothing (a
    precondition row requires a third of them to have changed their list
    mid-count; all 3,000 did);
  - a two-thread race, in which a flipper turns the third pair's cdr while
    100,000 counts must answer #f or 12.
- tests/test-stream.sps:
  - a segments-two-cycles sweep, behind the same gate as the circular one;
  - a two-thread race on a span written 20,000 times to an unconnected
    pipe. Every call must be refused by the parse or by libuv's errno; in
    the green run the change reached 16,812 of them.
- tests/test-tcp.sps: the order pin.
- tests/test-callback-alloc.sps: a 64-segment row. One segment's row cannot
  see a per-segment cost, which is smaller than its margin. Both race rows
  skip under Valgrind, which runs one thread at a time, as test-addrinfo's
  does.

### Mutations, round two

Each ran as before, on a fresh copy of `src/`, under the watchdog. All 23
were caught by name; none hung.

| id | mutation | caught by |
|---|---|---|
| W1-W7 | as in the first table | the same rows |
| O1 | the walk parses each segment after the rest of the list | test-tcp: the order pin |
| S1-S4 | as in the first table | the same rows; S4 also fails the span race |
| S5 | the span's end is read again through the span (`caddr`), as main did | test-stream: the span race |
| C1 | a spec is a list of three again | test-callback-alloc: the 64-segment row |
| C2 | a span from 0 takes two pairs too | the 64-segment row |
| C3 | spec-start answers 0 for every spec | test-tcp: each buf holds the requested span's bytes; the three segments arrive in order |
| B1 | Brent's mark never moves | test-native: the sweeps' answers and reach, the random trials, fold-flags' circular row; test-tcp: the circular row |
| B2 | the mark moves at every step, not at powers of two | the same |
| B3 | the walk never compares the mark | the same |
| B4 | the walk takes the cdr of a non-pair | test-native: sweeps, trials, the race, fold-flags; test-stream: the list sweeps |
| B5 | the count is one too many | test-native: fold-flags folds a proper list, the sweeps |
| P3 | proper-length is #61's shape again (its hare reads each cdr twice) | test-native: the sweeps, the trials and the race; test-stream: the list sweeps |
| P5 | proper-length is this PR's first count again (a tortoise behind the hare) | test-native: the sweeps' answers and reach, the trials; test-stream: the two-cycles sweep |

The race catches P3 and passes P5, which reads each cdr once; the two-cycles
sweeps and the random trials catch P5. Nothing is uncovered in this round.

## Gates

On 680e0c3:

- `make test`: 24 suites pass.
- `make test-threading`: passes.
- `make check-purity` holds, and `make check-help` is silent.
- macOS ASan: `check-memory-gate` caught its planted overruns and printed
  MEMORY GATE CAN FAIL, then `make test-memory` passed with no
  AddressSanitizer report.
- `make prod` passes check-prod, and `make test` passes again on the
  rebuilt dev build.
- `make test-memory-docker` (Linux Valgrind, aarch64, vendored libuv), from a
  `--no-hardlinks` clone:
  - `check-memory-gate` printed MEMORY GATE CAN FAIL;
  - each of the 24 suites reports 0 errors and 0 B definitely lost, at 778
    to 24,288 allocations (test-stream 5,855, test-tcp 3,050, test-native
    1,208), and the three this branch touches reach their full pass counts
    (35, 236 and 303);
  - forked children report fork artifacts, which never gate (ADR-0003):
    117 and 131 B, as before, and 147 B in 69 of test-process's spawn
    children (5 more report none), a block `chez_uv_alloc` gave the parent
    before the fork, beside the usual 1,576 B possibly lost.

On 3335c38, after the review:

- `make test`: 24 suites pass. `make test-threading` passes. `make
  check-purity` holds, and `make check-help` is silent.
- macOS ASan: `check-memory-gate` printed MEMORY GATE CAN FAIL, then `make
  test-memory` passed with no AddressSanitizer report. Both race rows ran
  there: the count race's change reached 69,814 of 100,000 counts, and the
  span race's 16,926 of 20,000 calls.
- `make prod` passes check-prod, and `make test` passes again on the
  rebuilt dev build.
- `make test-memory-docker` (Linux Valgrind, aarch64, vendored libuv), from a
  `--no-hardlinks` clone:
  - `check-memory-gate` printed MEMORY GATE CAN FAIL;
  - each of the 24 suites reports 0 errors and 0 B definitely lost
    (test-stream at 6,063 allocations, test-callback-alloc at 5,671);
  - both race rows skip under Valgrind, so test-native passes 305 rows and
    test-stream 35, with no unexpected failure in any suite;
  - forked children report the same fork artifacts as on 680e0c3: 117 and
    131 B, 147 B in 69 spawn children, and none in 5.
