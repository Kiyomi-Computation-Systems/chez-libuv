# Lift require-address/require-port Mutation Log (post-v0.2)

Covers the post-v0.2 duplication lift flagged by the whole-branch review of
`feat/dns-v0.2` (PR #3): `require-address`/`require-port`, restated verbatim
in `src/libuv/tcp.sls` (with its `valid-port?` folded in) and
`src/libuv/dns.sls`, now one copy in `src/libuv/private/native.sls` beside
the Stage-2-lifted `fill-sockaddr!`/`align-16`, exported and imported by
both former owners. ADR-0012 amended inline (dated note) — the vocabulary
is unchanged, only the definitions moved. Six new rows in
`tests/test-native.sps` pin the validators at their shared home.

## Method

Per AGENTS.md: `src/` copied to a scratch location outside the repo,
`CHEZSCHEMELIBDIRS=<scratch>/src:tests:build/scheme-libs` so the scratch
copy shadows the repo's, one decision broken per round, suite run, first
named failure recorded verbatim, scratch restored from the repo copy
between rounds. The repo tree itself was never mutated (`git status`
confirmed only the four intended files modified throughout).

## RED evidence (watched to fail first)

The six rows were written and run before `native.sls` exported anything.
R6RS makes an export-lift's RED an expand-time refusal rather than a FAIL
row — the suite names the missing binding:

```
Exception: attempt to reference unbound identifier require-address
  at line 1081, char 6 of tests/test-native.sps
```

After the lift (export + both restatements deleted, which must land
together — a local definition alongside the wholesale import would be a
duplicate-binding error): test-native rose 220 → 226 with the six new
rows, test-tcp stayed 168 and test-dns stayed 121 with **no test edit** —
the lift was behavior-preserving at every verb boundary.

## Mutation log

All rows mutate the scratch `native.sls` (the ONE shared copy); all
reverted. M1 and M3 also ran test-tcp and test-dns: a mutation in the
lifted copy must fail the callers' existing boundary rows, or the callers
are not actually routing through the lift.

| # | Mutation (scratch native.sls) | Verbatim first named failure(s) |
|---|---|---|
| M1 | `require-address` check made unreachable (`(or (string? ip) #t)`) | test-native: `FAIL require-address refuses a non-string, naming its caller and why`; test-tcp: `FAIL uv-tcp-bind! rejects a non-string address, naming who and why`; test-dns: `FAIL boundary: a non-string address is refused` — one mutation, all three suites, so both verbs provably share this copy |
| M2 | `require-address` tightened to pre-parse (`(and (string? ip) (char-numeric? (string-ref ip 0)))`) | `FAIL require-address accepts a string it cannot parse (parsing is fill-sockaddr!'s job)` — only that row; the parse-refusal boundary stays fill-sockaddr!'s |
| M3 | Upper bound `(<= port 65535)` → `(<= port 65536)` | test-native: `FAIL require-port refuses 65536, naming its caller and why`; test-tcp: `FAIL uv-tcp-bind! rejects a port outside 0..65535, naming who and why`; test-dns: `FAIL boundary: an out-of-range port is refused` + the allocated-nothing balance row + the teardown invariants row (the mutated call really submits — the same cascade as dns-stage-5 M15) |
| M4 | `(>= port 0)` dropped | `FAIL require-port refuses a negative port, naming its caller and why` — only that row |
| M5 | `(exact? port)` dropped | `FAIL require-port refuses an inexact port even inside the range` — only that row (8080.0 satisfies `integer?`, so this row fails through the `exact?` clause specifically) |
| M6 | `(<= port 65535)` → `(< port 65535)` | `FAIL require-port accepts both ends of 0..65535` — only that row |
| M7 | `require-port`'s raise hardcodes `'require-port` instead of `who` | All three require-port refusal rows fail (each expects `(test-lift port-out-of-range)`) — the raise must name the caller handed in, and `test-lift` is a symbol no real caller passes |

Every new assertion has a mutation that breaks it through its asserted
property; no uncovered properties to record.

## Final gate

Scratch removed; repo tree re-verified after all rounds:
`make build && make test && make check-purity` — eleven suites, zero
unexpected failures (addrinfo 41, conditions 94, dns 121, echo 32, facade
49, lifecycle 64, loop 138, native 226, shim-loading 24, tcp 168, timer
128), purity holds for both pure suites with `CHEZ_LIBUV_SHIM` poisoned.
