# Reset section precondition: mutation log

Evidence for checking, rather than assuming, the fixture of
`tests/test-tcp.sps`'s "connection reset by the peer" section.

On 2026-10-05, once, on macOS arm64 under heavy load (a `make test-memory`
ASan run of every suite going in another checkout), that section failed two
rows:

```
  [informational] abrupt peer close delivered as: on-error-never-fired (on-eof fires: 1)
FAIL a reset is delivered to on-error as a symbol errno, and not to on-eof
FAIL the errno an abortive close produces here is 'ECONNRESET
```

The section provokes an RST by closing a client that still has unread bytes
in its receive queue, the abortive close of RFC 1122 4.2.2.13. The server
writes 4096 bytes, the suite waits for the write's completion, then it took
two `(uv-run xl 'nowait)` turns "to remove any question about whether they
have been queued on the client's side before it is closed", and closed.

**Cause, measured below:** a completed write means libuv handed the bytes to
the server's socket. The kernel moves them to the client's receive queue
after that, and two non-blocking turns put no bound on when. Under a loopback
flood the close sometimes found the client's queue still empty. It then went
out as a FIN, and the server's reader saw EOF.

**Change:** the close now waits until `recv(MSG_PEEK)` on the client's
descriptor shows all 4096 bytes queued. The wait is `run-until/ticking`,
capped at the suite's `cap` of 64 loop steps and counted in steps, never in
wall-clock time. The queue is read again right before the close. A new row,
asserted ahead of the contract rows, checks both:

```scheme
(test-equal "precondition: all 4096 bytes reached the client's receive queue before it was closed"
  '(satisfied 4096) (list x-queue-wait x-queued-at-close))
```

The contract rows are unchanged: the dispatch row (a symbol errno to
`on-error`, not `on-eof`) and the measured `'ECONNRESET` row. A run whose
close goes out as a FIN now fails the named precondition first.

Platform: macOS arm64, Darwin 25.6.0, Chez 10.4.1 (`tarm64osx`), libuv
1.52.1 via pkg-config, the dev build. Linux results are under "Gates".

---

## Method

**Load.** CPU load alone never reproduced the failure. Loopback traffic did.
`loopback-flood.py N small` runs N processes, each a connected 127.0.0.1
pair sending 1-byte writes with `TCP_NODELAY`, which floods the kernel's
loopback input path with tiny segments:

```python
import os, socket, sys, threading, multiprocessing
def pair(mode, stop):
    srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
    cli = socket.create_connection(srv.getsockname())
    peer, _ = srv.accept()
    cli.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    chunk = b"x" * (65536 if mode == "bulk" else 1)
    def drain():
        while peer.recv(1 << 20): pass
    threading.Thread(target=drain, daemon=True).start()
    n = 0
    while True:
        cli.send(chunk); n += 1
        if n % 4096 == 0 and os.path.exists(stop): return
if __name__ == "__main__":
    pairs, mode, stop = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    ps = [multiprocessing.Process(target=pair, args=(mode, stop)) for _ in range(pairs)]
    for p in ps: p.start()
    for p in ps: p.join()
```

"ASan loop" below is `make test-memory` repeated back to back in this
worktree. Other sessions' work ran on the machine throughout, so load levels
drift over time; that is why the decisive comparison alternates the two
fixtures run by run. "No added load" means none of these generators was
running.

**Suite runs.** Each run is `chez --program tests/test-tcp.sps` with the
`make test` environment. Each run's FAIL rows are tallied by name: P = the
precondition row, R = "the abrupt peer close reached the reader", D = the
dispatch row, E = the ECONNRESET row. "Reached" counts runs that got as far
as the section's informational line.

**Probe.** A scratch program repeats the section's fixture in one process,
a fresh loop each round. Right before each close it records how many of the
4096 bytes `recv(MSG_PEEK)` sees in the client's receive queue. Mode `blind`
is the old fixture (two `'nowait` turns), mode `wait` is the new one, and
mode `ab` alternates them round by round.

**Mutations.** Each runs on a scratch copy of `tests/` outside the repo. A
mutant is built by exact text replacement, which aborts unless its target
occurs exactly once, and the edit is checked present afterwards. Mutants run
from the worktree root with the scratch `tests/` first on
`CHEZSCHEMELIBDIRS`. The repo tree was never mutated.

---

## Reproduction: the unmodified suite (0e6a8e1)

| load | runs | passed | D+E failed (the incident) | failed elsewhere |
|---|---|---|---|---|
| none added | 100 | 100 | 0 | 0 |
| ASan loop (load average ~6.5 on 8 cores) | 150 | 150 | 0 | 0 |
| ASan loop + 16 busy loops (load average up to 106) | 150 | 150 | 0 | 0 |
| ASan loop + 8-pair flood | 150 | 109 | **28** | 13 |

All 28 failures print exactly the incident's signature,
`on-error-never-fired (on-eof fires: 1)`. The ASan loop running alongside
hit it too: test-tcp under ASan failed the same two rows in 2 of the 13
`make test-memory` iterations that overlapped the flood (iterations 22 and
27). The 13 runs that failed elsewhere are a separate problem, covered under
"Out of scope".

## The cause, measured (probe)

| load | mode | rounds | queue at the close | outcome |
|---|---|---|---|---|
| none added | blind | 200 | 4096 in all 200, already there when the wait for the write's completion returned | ECONNRESET 200 |
| 2-pair flood | blind | 200 | 4096 in 176; empty (`recv` -1) in 24 | ECONNRESET 176/176 with bytes queued; EOF 18 and ECONNRESET 6 with the queue empty |

With no added load, the bytes are in the client's queue by the time the wait
for the write's completion returns. Under the flood they sometimes are not,
and every EOF
happened with the queue empty at the close. An empty-queue close that still
got ECONNRESET is one where the late bytes reached the closed socket, which
answered them with an RST. The server's reader saw that RST before it read
the FIN.

Alternating the old and new fixture round by round, so both see the same
load:

| load | fixture | rounds past setup | needed the wait | EOF (FIN) | ECONNRESET |
|---|---|---|---|---|---|
| 2-pair flood | blind (old) | 500 | n/a | **13** (queue empty in all 13) | 487 |
| 2-pair flood | wait (new) | 500 | 21, each satisfied after 1 step | **0** | 500 |
| 8-pair flood | blind (old) | 282 | n/a | **16** (queue empty in all 16) | 266 |
| 8-pair flood | wait (new) | 284 | 30; worst case 17 steps (cap 64) | **0** | 284 |

Setup failures, where the accept missed its own 64-step cap, were 18 for
blind and 16 for wait under the 8-pair flood. They are excluded above and
belong to the out-of-scope problem.

## RED, then GREEN: the suite under load

**RED: the row, against the old fixture.** The precondition row was written
first, with the two blind turns left in place, and run under the 2-pair
flood:

| runs | passed | P+D+E | P only | crashed before the section |
|---|---|---|---|---|
| 200 | 178 | **14** | 2 | 6 |

Every run that failed the contract rows failed the precondition row first,
by name, and printed `queued at the close: (recv -1)`. The 2 "P only" runs
closed on an empty queue and got ECONNRESET anyway, from the late bytes.
The fixture's assumption failed in those runs too, and the row says so.

**GREEN: the wait added**, same flood. This run, and the new arm of the A/B
below, used a frozen copy of `tests/test-tcp.sps` (file SHA-1 `79dd95e`).
The committed file differs from it in comments and in one code change: the
look's raise handler now also reports the condition's irritants. No batch run
reached that handler.

| runs | passed | P | R+D+E | crashed before the section |
|---|---|---|---|---|
| 200 | 183 | **0** | 1 | 16 |

The single R+D+E run (run 107) had all 4096 bytes queued and the wait
satisfied. Its reset then failed to reach the server's reader within the
outcome wait's 64-step cap, and the existing row "the abrupt peer close
reached the reader" names that. That is the out-of-scope cap problem, not a
FIN.

**Interleaved A/B, the whole suite, heaviest load** (ASan loop + 8-pair
flood). The old fixture rebuilt in the new layout (mutant M0 below) and the
new one alternate run by run:

| fixture | runs | reached the section | passed | P+D+E: FIN on an empty queue | P+R+D+E: stalled past both caps | failed elsewhere only | crashed before the section |
|---|---|---|---|---|---|---|---|
| old (M0) | 100 | 94 | 76 | **14** | 0 | 4 | 6 |
| new | 100 | 89 | 83 | **0** | 1 | 5 | 11 |

In the old fixture's arm, 14 of 94 runs closed on an empty queue and failed
the contract rows with EOF (`queued at the close: (recv -1)` in all 14). The
precondition row failed first in every one. In the new arm, none did. Its one
precondition failure (run 13) is a stall: the queue wait ran out of its 64
steps with the bytes still not delivered (`queued at the close: (recv -1),
queue wait iterations-exhausted`), and the FIN that followed did not reach
the reader within the outcome wait's cap either. The row named it first,
which is the behaviour asked for.

---

## Mutations

3 runs each with no added load; M0's under-load evidence is the RED and A/B
runs above. FAIL rows are quoted verbatim the first time; "the
precondition" means that same row after that.

| # | Mutation | The section's FAIL rows, 3 runs | What the informational line showed |
|---|---|---|---|
| M0 | the wait replaced by the old two `'nowait` turns, wait outcome fixed at `'satisfied` | none, 3/3 (208 passes); under load, the precondition first in every FIN run (RED and the A/B above) | `4096`, `satisfied`; under load, `(recv -1)` in the FIN runs |
| M1 | the reading and `uv-close!` moved to just after `uv-write!`, before its completion | `FAIL precondition: all 4096 bytes reached the client's receive queue before it was closed`, alone, 3/3. **The contract rows passed**: the late bytes met the closed socket, which answered with an RST | `(recv -1)`, queue wait `iterations-exhausted` |
| M1b | the reading and `uv-close!` moved before `uv-write!` | the precondition, 3/3. The contract rows failed with EOF in 2 runs and passed in 1 | `(recv -1)`, queue wait `iterations-exhausted` |
| M2 | `msg-peek` 2 → 0: a look that drains | the precondition, then `FAIL a reset is delivered to on-error as a symbol errno, and not to on-eof` and `FAIL the errno an abortive close produces here is 'ECONNRESET`, 3/3: the incident's signature, now led by the precondition | `on-error-never-fired (on-eof fires: 1; queued at the close: (recv -1), queue wait satisfied)` |
| M3 | the wait looks at the server's socket (`x-peer`) | the precondition, alone, 3/3 | `4096`, queue wait `iterations-exhausted` |
| M4 | the wait asks for 4097 bytes | the precondition, alone, 3/3 | `4096`, queue wait `iterations-exhausted` |
| M5 | the wait's predicate replaced by `(lambda () #t)` | none, 3/3 | see "Uncovered" |
| I1 | injected failure: `uv_fileno` does not resolve | the precondition, alone, 3/3; the suite runs to its end (207 passes) | `(uv_fileno unavailable)` |
| I2 | injected failure: the look raises (`make-bytevector -1`) | the precondition, alone, 3/3; the suite runs to its end | `(raised ~s is not a valid bytevector length (-1))` |

What each row guards: M0 and M5, that the close waits for a look at the
queue; M1 and M1b, that the close comes after the bytes are queued; M2, that
the look does not drain; M3 and M4, that the wait looks at the right socket
for the right count, and does not merely spend its cap. I1 and I2 cover the
failure path: a look that cannot be made fails the named row, and the suite
keeps its later rows.

M1 shows why the row checks the mechanism and not just the outcome. With the
close moved ahead of the bytes, the reset still arrived, from the late bytes
rather than from a close with unread data, and every contract row passed.
Only the precondition noticed. The 2 "P only" runs in RED are the same case
arising under load.

After the sweep, the unmutated suite passed 5 of 5 runs with no added load:
`ECONNRESET (on-eof fires: 0; queued at the close: 4096, queue wait
satisfied)`, 208 passes.

## Uncovered, and why

- **M5 and M0 survive without added load.** Then the bytes are in the
  client's queue before the wait for the write's completion returns (probe:
  200 of 200), so a
  fixture that never looks still finds them there, and the row passes. That
  is the right verdict, because the precondition holds. Only load holds the
  look: M0's arm of the A/B (the row named all 14 FIN runs) and RED (16
  empty-queue closes named in 194 runs). M5 was not measured under load, to
  avoid adding more load while other sessions ran their suites on this
  machine. It removes the look the way M0 removes the wait, and M0 is what
  was measured.
- **The row's place ahead of the contract rows** only decides which FAIL line
  prints first. No row can observe that. The RED, M1b and M2 outputs show
  the order.
- **MSG_PEEK = 2** is held on Darwin by M2 and by every passing run, where
  the re-read after the wait's looks still sees 4096. On Linux it is held by
  the Linux gate below: a draining flag would leave the re-read an empty
  queue there too. Not run on the BSDs.
- **Windows** is not run; nothing in this repo's gates runs there. There
  `uv_os_fd_t` is a HANDLE and `recv` takes a SOCKET, so the helper's int
  descriptor is unverified.

## Out of scope, found on the way

Under the floods, other waits in this suite also ran out of their 64-step
caps, as did waits in test-facade and test-flow under the ASan loop. Many of
those failures abort the whole suite instead of failing named rows: the
AGENTS.md trap "an unguarded raise in suite plumbing between rows aborts the
suite and destroys the evidence". Across the 750 flooded suite runs above,
50 crashed, and all 50 share one shape: a peer variable still holding its
seed (`'never-accepted`), or a handle whose accept missed its cap, reaches an
unguarded verb.

| crashes | the raise |
|---|---|
| 29 | `stream-read-buf: never-accepted is not of type #<record type uv-stream-record>` |
| 12 | `uv-read-start!`: `&uv-invalid-argument`, `not-a-uv-stream` |
| 8 | `uv-write!`: `&uv-invalid-argument`, `not-a-uv-stream`. This includes this section's own write to `x-peer` when its accept misses the cap: 2 of 150 old-suite runs, 1 of 200 RED, 5 of 200 GREEN |
| 1 | `uv-read-start!: connection already in progress` |

The reset section's outcome wait can also miss its cap, so that the reset
never reaches the reader: GREEN run 107 and A/B run 13. The existing row
"the abrupt peer close reached the reader" names that case.

None of this is the FIN problem, and none of it changes here: it spans
several sections and suites, and is its own change.

## Gates

The PR was rebased twice while it waited, as #49 (`a0ea0ca`) and then #48
(`309c376`) merged. The second rebase had one conflict, in the
`(chezscheme)` import line. #48 already imports `foreign-procedure` and
`foreign-entry?`, so the resolution keeps its line and names both users in
the comment. Gates on the final commit, rebased onto `309c376`, with no
added load from this session:

- **macOS arm64** (this worktree):
  - `make test` relinked the shim (#48 changed it) and passed every suite:
    1611 rows, with test-tcp at 224 (main's 223 plus the precondition row).
  - `make test-memory` failed its first run, in five of test-flow's
    closed-reader rows, while other sessions' suites held the load average
    near 93. `src/` and `tests/test-flow.sps` are byte-identical to main's.
    test-flow then passed 3 of 3 under the same ASan recipe, and the full
    gate passed on the rerun: 21 suites, no reports.
  - `make check-purity` (4 pure suites) and `make check-help` exited 0.
- **Linux arm64**: `make test-memory-docker` from a `--no-hardlinks` clone of
  the final commit. That is the `chez-libuv-valgrind:10.4.1` image (Debian
  bookworm, vendored libuv 1.52.1, `HAVE_PKG=no`), CI's Valgrind leg.
  Exit 0. `check-memory-gate` ran first and caught store-overrun,
  libc-overrun and leak, and stayed consistent on possible-leak. Each of the
  21 suites' own processes: 0 errors, 0 bytes definitely lost. The only other
  summaries are test-process's two forked children (131 B and 117 B), the
  known artifacts that never gate (ADR-0003). There, test-tcp printed
  `ECONNRESET (on-eof fires: 0; queued at the close: 4096, queue wait
  satisfied)` and passed 224 rows. So `uv_fileno` and `recv` resolve on
  Linux, and flag 2 peeks there without draining.

The same gates passed on the two earlier bases: `0e6a8e1` (1573 rows,
test-tcp 208) and `a0ea0ca` (1583 rows, test-tcp 211; the Linux gate there
showed test-tcp's queue at 4096 too). CI's run on the `a0ea0ca` base
passed.
