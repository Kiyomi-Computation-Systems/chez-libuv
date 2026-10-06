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
expire between them, and the sweeps cannot split them. Only another thread
writing that cdr in the few instructions between could, which no
single-threaded row can order. It is the shape #61 had; the fix keeps the
single read without a row to hold it.

## Gates

(below)
