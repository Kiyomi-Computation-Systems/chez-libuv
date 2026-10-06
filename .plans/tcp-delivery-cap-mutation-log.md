# test-tcp's delivery waits get a load-proof cap: mutation log

Evidence for `test/delivery-cap`, on `main` at eb5b719 (#50, #52, #53 and
#54 merged). The change is test-only: `tests/test-tcp.sps` and
`tests/test-seed-gates.sps`.

Platform: macOS arm64 26.6.2, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1 from
pkg-config, the dev build. Every run used a `--no-hardlinks` clone outside
the repo. Times are EDT on 2026-10-06. Other sessions' work shared the
machine throughout, and the tables give the load average.

---

## The defect

`run-until/ticking` spends an iteration on every 1 ms tick, so a ticking
wait's cap is a time budget. After #52 gave the handshake waits
`handshake-cap` (4000), eight ticking waits on deliveries still gave up
early:

| wait | its row | old cap |
|---|---|---|
| the read path's EOF | "the peer's on-eof fired when the client shut its write side down" | 64 |
| the 1 MiB transfer's drain | "the whole megabyte arrived at the reader" | 1024 |
| the 1 MiB transfer's EOF | "the transfer ended with on-eof exactly once, and no on-error" | 64 |
| the backpressure section's first chunk | "the first chunk arrived, and on-data stopped the read from inside itself" | 64 |
| the backpressure section's resume | "restarting the read delivers exactly the bytes that were held back" | 64 |
| the reset section's write | none: the outcome was discarded | 64 |
| the reset section's queue (#50) | "precondition: all 4096 bytes reached the client's receive queue before it was closed" | 64 |
| the reset section's outcome | "the abrupt peer close reached the reader" | 64 |

#52's log records named failures of the EOF and reset waits during #50's
loopback floods.

## Which load stretches a delivery

Two probes measured how many iterations each wait really needs:

- **The probe.** A scratch copy of the suite in which every ticking wait
  is wrapped. Each wait counts its predicate's calls, gets a cap of 60000,
  and logs its iterations and wall time. Nothing else changed.
- **The flood.** #50's generator: 8 processes, each a 127.0.0.1 pair
  sending 1-byte `TCP_NODELAY` writes.

| batch | when | load | copies at once | load average | longest wait | named failures |
|---|---|---|---|---|---|---|
| D1 | 07:13:06–07:13:19 | the copies | 32 probes | to 34 | 13 ticks | reset FIN (#50's flake) in 4 |
| D2 | 07:14:31–07:15:15 | the copies | 64 probes | to 83 | 7 ticks | the fixed-port row in 3 (below) |
| D3 | 07:16:48–07:20:06 | the copies, during another session's 8-pair flood | 128 probes | to 411 | 14 ticks, up to 1.6 s of wall time | reset FIN in 2, fixed-port in 1 |
| P1 | 07:31:47–07:34 | the copies, no flood running | 2 probes + 2 + 2 legs a round, 132 rounds | 19 to 35 | 30 ticks (the drain) | the fixed-port row in 8 of 786 |
| F1 | 07:37:06–07:48:38 | this session's 8-pair flood | 1 probe + 1 + 1 legs a round, 126 rounds | 15 to 67 | 2633 ticks (a handshake); 1529 for a delivery | below |

**CPU load does not test a ticking cap.** Under CPU contention the loop's
ticks slow down as much as the deliveries do. At load 411, waits took up to
1.6 s of wall time but never more than 14 ticks. Only a flood on a box with
CPU to spare stretched a delivery across many ticks. The test-facade
session measured the same contrast that morning: 40 CPU spinners never
pushed its drain past 3 steps, and a flood pushed it to 932.

The fixed-port row binds one of 5 fixed candidate ports, so 6 or more
copies at once can find them all taken. That is this method's artifact.
`make test` runs suites one at a time.

## The change

- `delivery-cap` (4000) is the cap of all eight waits. It equals
  `handshake-cap`, and it is 2.6 times the longest delivery measured during
  the flood (1529 ticks, the 1 MiB drain).
- The reset section's write wait is a row: "seed: the reset section's
  write to the client completed without error", `'(satisfied no-error)`. A
  write that never completes now fails by name, not only through the reset
  rows it takes down.
- `tests/test-seed-gates.sps` gains rule 3. No ticking wait in
  test-tcp.sps may give up sooner than `flooded-delivery-ticks` (1529). Each
  wait's cap is resolved through the file's own top-level integer
  definitions. A cap the scan cannot resolve counts as too short. Three rows
  hold it:
  - "a cap's ticks come from the file's own integer definitions";
  - "rule 3 flags a ticking wait that gives up sooner than a flooded
    delivery, and only that", with 10 seeded cases, including both sides of
    the boundary (1528 flagged, 1529 not);
  - a pinned vocabulary of the file's ticking caps, `(handshake-cap 8000
    delivery-cap 4000)`, which also keeps the findings row from passing
    against a file the scan read nothing from.

  The findings row prints each short wait's cap and predicate, because the
  runner prints only row names.
- The drain's comment had said it "uses TWO iterations against a cap of
  1024". It now gives the measured range: at most 30 with no added load, up
  to 1529 during the flood.
- AGENTS.md gains the trap "A ticking wait's cap is a time budget, and CPU
  load does not test it".

## The cap's size: F1's probe

125 probe runs under the flood, every wait at a cap of 60000:

| wait | p50 | p90 | p99 | max | over 64 |
|---|---|---|---|---|---|
| read path, first delivery (`handshake-cap`) | 2 | 5 | 212 | 306 | 2 |
| read path, EOF | 1 | 2 | 50 | 625 | 1 |
| 1 MiB drain | 4 | 305 | 1262 | **1529** | 22 |
| 1 MiB EOF | 1 | 9 | 375 | 515 | 4 |
| backpressure, first chunk | 1 | 10 | 162 | 530 | 4 |
| backpressure, resume | 1 | 1 | 216 | 239 | 3 |
| reset, write | 1 | 1 | 1 | 1 | 0 |
| reset, queue (#50) | 0 | 6 | 63 | 127 | 1 |
| reset, outcome | 1 | 9 | 62 | 365 | 1 |
| vectored round trip (8000) | 1 | 5 | 121 | 296 | 3 |
| vectored write (4000) | 1 | 1 | 1 | 1 | 0 |

The handshake seeds, at `handshake-cap`, reached 304 to 948 ticks. The
keepalive seed reached **2633** (6.1 s), 1.5 times short of its cap (below).

## RED, then GREEN, under the flood

**F1 (quiet box plus flood).** Before = #52 and #50 merged on 309c376, the
waits at their old caps. Its waits are `main`'s at eb5b719. It differs from
that file only in one comment and in #53's `install-read-buffer!` rows.
After = the same, with `delivery-cap` (4000) on every wait except the
drain, which stayed at 1024 in this frozen copy. Its write row also gated
its wait on the peer, which the committed row does not do. The two differ
only when a seed has failed. Both legs ran in every round, side by side:

| leg | runs | runs with a FAIL row | aborted |
|---|---|---|---|
| before | 125 | **12** | 0 |
| after | 125 | **1**: the drain, at 1024 | 0 |

The before leg's runs failed these waits' own rows:

| wait | runs |
|---|---|
| 1 MiB EOF | 4 |
| read path, EOF | 3 |
| backpressure, first chunk | 3 |
| backpressure, resume | 3 |
| reset, outcome | 3 |
| reset, queue | 2 |
| 1 MiB drain | 2 |

Each brought down the rows that depend on it: "the end of the stream fired
on-eof exactly once" (3), the reset contract rows (4 each), the
backpressure idle and restart rows (3 each), and the drain's byte-for-byte
row (2). In the after leg, only the drain, still at 1024, failed (round 28),
and the probe saw that drain reach 1529. The committed file gives the drain
`delivery-cap`.

**C1 (the committed trees, 08:06:05–08:11:35).** Before = `main` eb5b719,
after = this branch's commit, under the same 8-pair flood. Another job held
the box at load 148 to 208 the whole time (a Linux VM at ~180% CPU, plus
another project's suites):

| leg | runs | runs with a FAIL row |
|---|---|---|
| before | 20 | 0 |
| after | 20 | 0 |

At that CPU load the flood did not stretch the ticks, as in D3, so C1 does
not discriminate. It shows only that the committed file passed under the
flood. F1 is the comparison.

**Rule 3, against `main`.** The new `test-seed-gates.sps` run against
eb5b719's `test-tcp.sps` exits 1, failing both new file rows by name. It
prints the eight waits above: seven at `cap` and the drain at 1024.
Against #52's file before #50 landed, it found the same seven, without
#50's queue wait. Rebasing onto `main` brought #50's queue wait in at `cap`,
and the scan named it at once.

## Mutations

The sweep ran on the commit rebased onto eb5b719. Each plant is an exact,
whitespace-tolerant replacement that must match once, and it is checked
present before the run. `tests/` is reset and checked clean after each.
The control passed: test-seed-gates 10 rows, test-tcp 234.

| | mutation | fails, by name |
|---|---|---|
| T1 | read path's EOF back to `cap` | both rule-3 file rows; prints `(cap (lambda () (positive? s-eof-fires)))` |
| T2 | the drain back to 1024 | both; prints the drain with `1024` |
| T3 | 1 MiB EOF back to `cap` | both, naming it |
| T4 | first chunk back to `cap` | both, naming it |
| T5 | resume back to `cap` | both, naming it |
| T6 | reset write back to `cap` | both, naming it |
| T7 | reset outcome back to `cap` | both, naming it |
| T11 | reset queue back to `cap` | both, naming it |
| T8 | `delivery-cap` lowered to 1528 | the findings row, naming all eight waits; the vocabulary is unchanged |
| T9 | `delivery-cap` defined as `(* 2 2000)` | the findings row: an expression is not resolved, so all eight count as short |
| T10 | a new ticking wait with a literal 64 | both, naming it |
| X1 | the reset write never issued | "seed: the reset section's write to the client completed without error", then the precondition and the two reset contract rows; the summary printed |
| X2 | the reset write completes with an error | the seed row alone |
| S1 | quoted data counts as a wait | rule 3's seeded row |
| S2 | nested waits are not found | the seeded row and the vocabulary row |
| S3 | a plain run-until counts as ticking | the seeded row and both file rows, printing the plain waits that rightly use `cap` |
| S4 | names are not resolved | the seeded row and the findings row |
| S5 | an unresolved cap passes | the seeded row |
| S6 | the floor is exclusive (`>`) | the seeded row (1529 flagged) |
| S7 | the floor is 64 | the seeded row |
| S8 | an inexact number counts as a definition | the definitions row |
| S9 | any datum counts as a definition | the definitions row |
| S10 | `first-uses` keeps repeats | the vocabulary row |
| S11 | the findings dropped, with T1 planted | the vocabulary row: it backs the findings row |
| S12 | the scan reads no forms | the placeholder row and the vocabulary row |

**Survived: X3.** The write row reads the write's error after the wait,
sequenced by a `let`. With the `let` replaced by
`(list (run-until/ticking ...) (err->symbol x-write-err))`, the row still
passed: in this program, `list`'s arguments ran left to right. R6RS leaves
that order unspecified, and AGENTS.md records Chez running them right to
left in compiled library code. The `let` stays as a guard against that,
and nothing in `make test` can observe it.

The first S12 plant had an extra parenthesis. The suite died on a read
error, which proved nothing. It was re-planted as the empty-forms case
above.

## Not covered

- **`delivery-cap`'s value above the floor.** Rule 3 holds every ticking
  cap to at least the longest delivery measured. Whether 4000 is enough for
  a heavier flood than 8 pairs, only a heavier flood can show.
- **The handshake tail.** During F1, the keepalive seed's handshake took
  2633 ticks against `handshake-cap` (4000). The other handshake seeds
  stayed under 950. Raising `handshake-cap` is outside this change.
- **The mechanism.** The tail looks like segments lost from loopback's
  input queue (`net.link.generic.system.rcvq_maxlen` is 256) and resent
  after TCP's retransmission timeout. That was not verified: `netstat -id`
  shows no drops on lo0, and `netstat -s -p tcp` reads all zeros here. Only
  the ticks are claimed.
- **The waits that keep literals.** The peer-address delivery (8000), the
  round-trip delivery (8000) and the vectored-write completion (4000) were
  already above the floor and keep their caps. The probe did not instrument
  the peer-address delivery.
- **Other suites.** Rule 3 reads `tests/test-tcp.sps` only. test-facade,
  test-flow, test-stream and test-echo have ticking waits of their own, and
  another session is reworking test-facade's drain.
- **Linux.** The flood measurements are macOS only.

## Gates

After the PR opened, #51, #55, #56 and #57 landed, and the branch was
rebased onto 652bb40. Neither test file changed in the rebase (same blobs),
so the flood runs and the sweep above stand. Every gate ran again on the
rebased tree, d2ef4d4. The final docs commit differs from d2ef4d4 only in
this section.

On macOS (load ~3), with test-facade at #57's 70 rows:

- `make test`: 22 suites, `ALL SUITES PASSED` (test-tcp 234,
  test-seed-gates 10, test-source-rules 8);
- `make check-purity`: the five pure suites hold, test-seed-gates.sps among
  them;
- `make check-help`: silent;
- `make test-memory`: the ASan arm, its runtime preloaded on the Chez
  command. All 22 suites passed, with no report.

On Linux, `make test-memory-docker` ran from a `--no-hardlinks` clone of
d2ef4d4, in the `chez-libuv-valgrind:10.4.1` image with vendored libuv
1.52.1. It exited 0 in 4:06:

- `check-memory-gate` printed `MEMORY GATE CAN FAIL`;
- every suite's own process (22) had 0 errors and 0 bytes definitely lost,
  among them test-tcp at 234 rows and test-seed-gates at 10;
- test-process's forked children show their documented 131 and 117 bytes
  (ADR-0003).

The same gates passed on the earlier bases with the same counts: on
aac37b5 (eb5b719; Linux 5:32) and on e8c7955 (cff802b; Linux 4:00).
