# test-facade's delivery drains wait out a loaded host: mutation log

Evidence for `test/facade-load-proof-drains`, measured on `main` at 309c376
(#48's squash); the branch now sits on cff802b ("On later bases", below).
The change is test-only: `tests/test-facade.sps`.

Platform: macOS arm64 26.6.2, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1 from
Homebrew (the dev build's `config.sls`), Python 3.14 for the load generator
and the connect probe. The machine was shared with other sessions' work all
morning, at load averages from about 6 to 371; the windows below say where.

---

## The defect

Observed 2026-10-06, macOS arm64, load average about 40 from other
processes: `tests/test-facade.sps` failed "uv-tcp-connect! is re-exported
and its callback reports success" and the six TCP rows after it, then died
before its summary:

```
Exception occurred with condition components:
  0. &uv-callback-error: #<condition &uv-handle-closed>
  1. &uv-handle-closed: tcp
```

It happened in two `make test-memory` runs, alone with and without ASan, and
on main's own code. Loopback connects took 4–831 ms through the binding then.

Two things combine:

1. **The cap was a 32 ms time budget.** The TCP drain stepped `uv-run 'once`
   at most 32 times beside a 1 ms facade-only ticker. The ticker exists so a
   dead chain fails by name instead of blocking in the kernel (the suite's
   comment explains it). But it also makes each step return within about a
   millisecond, so the cap counted milliseconds, not events. The getaddrinfo,
   getnameinfo, resolve and resolve->connect drains had the same shape: a
   ticking wait of 32 on work done outside the loop thread.
2. **A late connect raised during teardown.** When the drain gave up with
   the connect still pending, `uv-loop-teardown!` closed the client, and
   libuv delivered the connect as `'ECANCELED` (`uv__stream_destroy`; G0E
   below prints it). The callback went on to `uv-tcp-nodelay!` and
   `uv-write!` without looking at its error. On the closing client the first
   of them raised `&uv-handle-closed`, the seam deferred it, and the teardown
   re-raised it at top level: exit 255, with every later section unrun. All
   26 aborts below had the TCP drain at its cap, after 48–234 ms. This is
   AGENTS.md's trap "an unguarded raise in suite plumbing between rows aborts
   the suite and destroys the evidence". PR #52 found the same callback shape
   in test-tcp.

## Method

**Runs.** Each run is `chez --program <copy>` with `make test`'s
environment (`CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs`,
`CHEZ_LIBUV_TEST_CHEZ=chez`) under a 300 s `timeout`. Batches run frozen
copies of the suite from a scratch directory, so an edit in the repo cannot
change a batch midway. An instrumented copy rewrites each
`(let drain|step ((i 0)) (when (and (< i CAP) ...) ...))` into the same loop
plus one line on stderr when it stops: `DRAIN <label> <steps> <cap> <ms>`.
The rewrite changes nothing else; uninstrumented copies were run too.

**Load.**

- CPU: 40 user-space spinners (a C loop that exits by itself after 150 s).
- Loopback: PR #50's generator (`.plans/reset-precondition-mutation-log.md`
  on `test/reset-precondition`), 8 processes, each a 127.0.0.1 pair sending
  1-byte `TCP_NODELAY` writes.
- A plain-socket probe (Python, sequential connect + accept pairs) measured
  loopback connect latency before the floods, and at the start and end of
  each flood.

**Mutations** run on copies outside the repo. Each was built by exact text
replacement that aborts unless its target occurs exactly once, and the edit
was checked present afterwards. Source mutants put the scratch `src/` first
on `CHEZSCHEMELIBDIRS`; suite mutants are copies of the suite. The repo tree
was never mutated (`rg MUTANT src tests` is empty).

**Windows (EDT, all this session's own generators):** 40 spinners
07:06:29–07:09:00; 8-pair floods 07:09:09–07:10:45 (window 1),
07:15:35–07:22:26 (window 2), 07:28:07–07:29:49 (window 3) and
07:30:13–07:31:06 (window 4). Other sessions' work ran throughout: load
averages reached 371 during window 2, with another session's Docker VM and
Spotlight busy. The test-tcp delivery-cap session ran test-tcp copies from
07:31, after window 4, and its own 8-pair flood from 07:37. No load-dependent
result below comes from its flood; only exit codes of the deterministic
mutants G0, G1 and G0E were re-checked during it.

## RED: main under load

| load | runs | failed | aborted (exit 255) | by name (exit 1) | TCP drain at its cap | resolve->connect drain at its cap |
|---|---|---|---|---|---|---|
| 40 spinners (load 34–111) | 25 | 0 | 0 | 0 | 0 (worst 3 steps, 6 ms) | 0 |
| window 1 | 20 | 4 | 2 | 2 | 3 | 1 |
| window 2, alternated with the fix | 25 | 10 | 9 | 1 | 10 | 0 |
| window 3, rotated with the fix and K32 | 20 | 15 | 15 | 0 | 15 | 0 |

Under the flood, main failed 29 of 65 runs, and 26 of those aborted. Every
aborted run printed the defect's signature: the seven TCP rows (connect,
listen and accept, write, shutdown, read start, read stop, peer address),
then the exception above.

The failures took three shapes:

- the TCP drain ran out with the connect pending: seven rows, then the
  abort;
- it ran out with the connect done but the accept pending: three rows (accept,
  read start, read stop) by name;
- the resolve->connect drain ran out: its one row by name.

**CPU load alone never reproduced it**, at load averages up to 111: the TCP
drain still needed at most 3 steps. A descheduled process finds the connect
done and the tick due together when it next runs, in one step. Under the
flood the process got the CPU and ticked at full rate while loopback
delivery lagged. That is the case a ticking cap cannot absorb.

The plain-socket probe before the floods: median 0.41 ms, worst 3.1 ms (50
connects). Under the floods (30 connects at each window's start and end):
medians 0.15–28 ms; worst 520 and 6, 81 and 6,428, 1,029 and 610, 441 and
1,337 ms.

## The change

- `delivery-cap` (4000) is the cap of every drain that waits on the kernel
  or the threadpool: TCP, getaddrinfo, getnameinfo, resolve,
  resolve->connect, and the spawn drain. The spawn drain had 2048,
  test-process.sps's number, and a comment saying every other drain in the
  file waits on in-process callbacks, which the TCP and dns drains never did.
- The connect callback writes only after a successful connect. That hunk,
  comment included, is copied byte for byte from the working tree of the
  `test/sibling-seed-gates` session (2026-10-06), which makes the same change
  for the same reason. So the two merge cleanly in either order: checked with
  `git merge-tree` against that file on 309c376, where this branch's first
  comment conflicted.
- Unchanged: the two timer drains and the final close drain keep 32. There
  `'once` waits for the suite's own timer or close, so the cap counts events:
  each took 1 step in all 158 instrumented runs, including one step that
  lasted 1,346 ms.

## GREEN: the fixed suite under the same load

| window | suite | runs | passed | worst TCP drain | worst resolve->connect drain | worst getaddrinfo drain |
|---|---|---|---|---|---|---|
| 2, alternated with main | draft, instrumented | 25 | 25 | 291 steps, 795 ms | 260 steps, 713 ms | 10 steps |
| 3, rotated with main and K32 | final, plain | 20 | 20 | not instrumented | | |
| 4, alone | final, instrumented | 20 | 20 | 932 steps, 2,415 ms | 712 steps, 1,107 ms | 12 steps |

The committed file reads as the same 167 forms as window 3's copy (compared
with Chez's `read`; main's file reads differently), and window 4 ran that
copy with the reporting added. The window 2 draft differs only inside the
connect form: it also gated the write callback's shutdown on the client
being open. That gate was dropped (below).

Window 4 is the worst case for a ticking cap. The box was less loaded there
(load average 51–59, against up to 371 during window 2), so steps were short
while delivery still lagged. The worst drain used under a quarter of the
cap. A step took about 2.6 ms under that flood (932 steps in 2,415 ms), so
4000 steps there are about 10 s.

## What each decision buys

| id | mutation | built on | result |
|---|---|---|---|
| MC | `connect-dispatch` frees the request and never calls the callback (a dropped connect delivery) | `src/` | exit 1 with the summary in 10–11 s; five rows by name (connect, write, shutdown, read start, resolve->connect), 65 passed. Each starved drain spent its 4000 steps in about 5.2 s. Main's suite fails the same five rows in 0.4 s. |
| T0 | MC, and the TCP drain's ticker never started | suite | hung; killed by `timeout` at 60 s (exit 124), no row, no summary. The ticker is still what turns a dead chain into named failures. |
| K32 | `delivery-cap` 32 | suite | window 3: 18 of 20 failed, every one with exit 1 and its summary. TCP drain at its cap 18 times, resolve->connect 16. Rotated with the fix (20 of 20 passed) and main (15 of 20 aborted). |
| G0 | the TCP drain gives up before its first step | suite | exit 1 in 7 of 7 runs, with the summary and every later section run. Six or seven TCP rows fail by name: the peer-address row passes when the kernel has finished the handshake by itself. |
| G0E | G0, printing the connect's error after the teardown | suite | `ECANCELED`. |
| G1 | G0, and the connect callback writes whatever its error | suite | exit 255 in 7 of 7 runs, with the defect's exception and no summary. |
| GM | main's suite, its TCP drain giving up before its first step | suite | exit 255 with the defect's exception: the reported failure, deterministic and without load. |
| W1 | the TCP drain stops as soon as the connect callback has run | suite | 20 of 20: the write callback had already run by then; exit 1 by name, no abort. |

K32 against the fix separates the two decisions: the cap is what removes the
failures under load, and the connect gate is what turns an exhausted TCP
drain into named failures (K32 never aborted; main aborted 26 times).

## The write callback is not gated

W1 shows the mechanism on libuv 1.52.1. Since v1.44.2 (ee3718dd, "loop:
better align order-of-events behavior between platforms"), `uv_run` runs
pending callbacks right after the poll. So a write that the connect callback
issues, and that finishes at once, has its callback run inside the same
`uv_run`. By teardown, of the client's requests only the shutdown can still
be pending, and its callback only records. A gate on the write callback
therefore changes nothing on 1.52.1 (this box, and the vendored pin), nor,
by the same code, on 1.48 (CI's pkg-config leg). It was dropped.

**Residual, unmeasured:** on libuv 1.44.0 and 1.44.1 (the floor is 1.44.0),
that callback runs in the next iteration instead. If the drain ran out of
steps in exactly the iteration where the connect landed, teardown would hand
the write callback a success on the closing client, and its `uv-shutdown!`
would raise. No libuv older than 1.44.2 was built to check this.

## The dns drains

None was seen near 32: in 130 instrumented flooded runs the getaddrinfo
drain took at most 13 steps (38 ms), getnameinfo 1, resolve 3. Moving them
to `delivery-cap` is preventive: they have the TCP drain's shape, a ticking
wait on work done outside the loop thread.

## Cost

A working chain's drains stop as soon as their predicates hold, so the
passing suite's time is unchanged (0.35–0.9 s quiet). A dead chain costs at
least four seconds per starved drain: 10–11 s for MC, against 0.4 s before.

Under Valgrind, where every tick's `(collect)` is slower, MC still fails by
name well inside the memory gate's 900 s cap. Run through the real recipe
(`make test-memory MEMORY_TESTS=tests/test-facade.sps` in the
`chez-libuv-valgrind:10.4.1` image, vendored libuv), it took 44 s. The same
five rows failed by name, the summary printed, and Valgrind reported 0
errors and 0 bytes definitely lost. The recipe exited 2, from the suite's
exit 1.

## On later bases

Main moved twice while this was gated, and the suite file never changed:

- #53 (the stream verbs as one interrupt-free step, a shim change) and #52
  landed, so the branch was rebased onto eb5b719 and the shim rebuilt;
- #51 (DNS), #55 (a check-memory-gate plant) and #56 (`uv-spawn!`) landed,
  all Scheme, so the branch was rebased onto cff802b.

The flood runs above were made on the 309c376 base. On each later one, the
deterministic mutants were re-run against that base's `src/`:

| mutant | eb5b719 (load ~174) | cff802b (load ~12) |
|---|---|---|
| MC | exit 1 in 19 s, the same five rows by name, 65 passed | exit 1 in 11 s, likewise |
| G0 | exit 1, seven rows by name, 63 passed | the same |
| G1 | exit 255 with the defect's exception | the same |
| T0 with MC | hung until `timeout` killed it at 60 s | the same |

## Gates

The branch's test commit is 5b8ba3d (tree 5621379), on cff802b. Every gate
ran on each of its five versions, on a shared machine:

| commit (tree) | what changed | make test | make test-memory (macOS ASan) | make check-memory-gate (macOS) | make test-memory-docker |
|---|---|---|---|---|---|
| 54be6b7 (18022713), on 309c376 | first version | 21 suites passed (twice, around a comment-only edit) | 21 passed (twice) | MEMORY GATE CAN FAIL | exit 0, 5 min 42 s |
| de99d15 (9768a40), on 309c376 | the connect gate's comment taken from the sibling session | 21 passed | 21 passed | MEMORY GATE CAN FAIL | exit 0, 6 min 18 s |
| 35104e8 (76e6ea7), on 65ae4c2 | rebased past #50 and #54 | 21 passed | 21 passed | MEMORY GATE CAN FAIL | exit 0, 7 min 53 s (three other sessions' Valgrind containers running) |
| 27fc213 (b3f9502), on eb5b719 | rebased past #53 and #52; shim rebuilt | 22 passed (#52 adds test-seed-gates) | 22 passed | MEMORY GATE CAN FAIL | exit 0, 5 min 58 s (on 6d46474, which adds only this log) |
| 5b8ba3d (5621379), on cff802b | rebased past #51, #55 and #56 | 22 passed | 22 passed | MEMORY GATE CAN FAIL (#55 adds the shim-overrun plant) | exit 0, 4 min 17 s (on c5bcb79, which adds only this log) |

Each `make test-memory-docker` ran unmodified from a fresh `--no-hardlinks`
clone (aarch64 container, Valgrind 3.19, the vendored libuv 1.52.1). Its own
`check-memory-gate` caught store-overrun, libc-overrun and leak first, and
shim-overrun too once #55 had landed. Every
suite reported 0 errors; test-facade passed its 70 rows (1,231 allocations
and 0 bytes definitely lost on the final base). A first try on 35104e8 is not
counted: the host-side shell running it was killed (exit 144) before it
recorded `make`'s status, though its log showed all 21 suites at 0 errors.
