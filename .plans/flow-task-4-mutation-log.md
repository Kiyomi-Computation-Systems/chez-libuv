# v0.5 Task 4 Mutation Log: `uv-tcp-peer-address`

Covers `src/libuv/tcp.sls`'s new public procedure `uv-tcp-peer-address` and
its native binding `uv-tcp-getpeername-native` in
`src/libuv/private/native.sls`.

**Process note.** Per the controller's explicit instruction for this task,
mutation execution was NOT performed by this agent — the controller runs all
`src/` mutations itself after Task 3's log recorded two separate incidents of
a subagent returning control with an experimental mutation still applied to
the working tree. Everything below Probe A and Probe B is therefore a
**prediction**, not a measurement: the brief's own claims, checked against
the actual implementation and the actual test rows, but not run. Per the
milestone's own lesson (five mechanism narratives wrong on direct test while
every `FAIL` line was genuine), these predictions should be treated as
unverified until the controller runs them and the output is captured
verbatim in this file.

## Probe A (predicted, not executed): point the wrapper at `uv-tcp-getsockname`

**Mutation to apply:** in `src/libuv/tcp.sls`, change `uv-tcp-peer-address`'s
native call from `uv-tcp-getpeername-native` to the already-bound
`uv-tcp-getsockname` (same signature: `(uptr uptr uptr) -> int`):
```scheme
;; before
(uv-check (uv-tcp-getpeername-native
           (handle-pointer tcp 'uv-tcp-peer-address) addr len)
          'uv-tcp-peer-address)
;; after (MUTATION A)
(uv-check (uv-tcp-getsockname
           (handle-pointer tcp 'uv-tcp-peer-address) addr len)
          'uv-tcp-peer-address)
```

**Predicted result:** both address rows fail, not one:
- `"the client's peer address and port are the server's"` — under this
  mutation, `(uv-tcp-peer-address pa-client)` answers `pa-client`'s OWN
  sockname (its ephemeral local port), never `pa-server-port`. The row
  expects `(list "127.0.0.1" pa-server-port)`; the mutated call answers
  `(list "127.0.0.1" <pa-client's-own-port>)`, which is a different (though
  still in-range) port on essentially every run — a comparison that fails by
  construction, not by chance.
- `"the accepted handle's peer port is the client's own local port"` — this
  is the row the brief calls out as the one that still discriminates when
  both loopback ends share an address `"127.0.0.1"`: `pa-peer`'s sockname is
  the SERVER's bound port (`pa-server-port`), not the client's, so this row
  fails too, for the same reason as the first.
- `"the facade's peer-address answers the connected peer"` (test-facade.sps)
  — `fclient`'s sockname is its own ephemeral port, not `fport` (the
  server's), so it fails identically to the first row above.

**Not predicted to fail:** `"an unconnected handle refuses with ENOTCONN"` —
`uv_tcp_getsockname` on a bound-but-unconnected socket succeeds (that is
exactly what `uv-tcp-getsockname-port` already exercises elsewhere in this
suite), so the mutated call does not raise, and the row's `guard` falls
through to `'no-raise`, which is compared against `'ENOTCONN` — so this row
is ALSO expected to fail under Probe A, in addition to the three above. The
brief's Step 5 enumerates only the three address-identity rows as the
"expected FAIL lines"; whether the ENOTCONN row independently fails as well
should be confirmed by the controller's run rather than assumed from this
log, since it is not called out either way in the brief.

## Probe B (predicted, not executed): `sockaddr->address-string` returning constant `#f`

**Mutation to apply:** in `src/libuv/private/native.sls`, replace the body
of `sockaddr->address-string` with a stub:
```scheme
(define (sockaddr->address-string addr) #f)   ; MUTATION B
```

**Predicted result:** the brief states both address rows plus the facade row
fail, and no mutation isolates row 1 alone. This follows directly from the
row construction: all three rows require the literal string `"127.0.0.1"` as
the first element of the compared list (this is deliberate per the brief —
"the expected IPv4 string is REQUIRED, not tolerated: a row accepting `#f`
passes against an implementation whose address conversion returns constant
`#f`"), so a stub that always answers `#f` fails every row that checks an
address, uniformly. `"an unconnected handle refuses with ENOTCONN"` is
predicted to still PASS under this mutation, since that row never reaches
`sockaddr->address-string` at all — `uv-check` raises from the ENOTCONN
errno before the address decode runs.

## Uncovered property: two-write non-interleaving (design spec S13.5)

**Not asserted, by design, and not coverable by a source mutation in this
binding.** The two-write ordering rows (`"both writes arrive, A then B"` and
`"both completions fired with no error, in submission order"`) assert what
`(libuv tcp)` / `(libuv stream)` actually own: FIFO submission order of
`uv-write!` calls and per-request completion routing back to the correct
callback. They do NOT assert that the two writes' bytes cannot interleave on
the wire — that guarantee is structural to libuv's stream implementation
(head-of-queue drain: `vendor/libuv/src/unix/stream.c:1043`, `uv__write`
walks `stream->write_queue` and does not begin request N+1's buffers until
request N's are fully written), not something this Chez binding implements
or could break by itself. There is no source-level mutation confined to
`src/libuv/tcp.sls`, `src/libuv/stream.sls`, or `src/libuv/private/native.sls`
that would interleave the two payloads without also breaking FIFO submission
order itself (which the existing rows already cover) — an absence assertion
that no mutation of this binding's own code can falsify. Logged per the
brief's instruction rather than asserted as a test row.

## `make test` (this agent's run, Darwin)

`ALL SUITES PASSED`. `tests/test-tcp.sps`: 175 expected passes (169 + 6, the
four peer-address rows plus the two write-ordering rows).
`tests/test-facade.sps`: 66 expected passes (65 + 1). Full tail in the task
report.

## `make test-memory` (Darwin, ASan)

All sixteen suites completed with no `FAIL` lines, exit code 0
(`test-tcp.sps` at 175, `test-facade.sps` at 66, matching `make test`'s
counts exactly). Grepped the full output for `definitely lost:`,
`Invalid read`, `Invalid write`, `ERROR: AddressSanitizer`,
`LeakSanitizer`: zero matches, aside from this run's own informational
banner line ("macOS: ASan preload only; LeakSanitizer is unsupported on
arm64"). Per ADR-0003 and prior tasks' logs, the Linux leg under Valgrind is
the sole memory-leak gate; this Darwin/ASan run makes no leak claim and is
checked here only for addressability (invalid read/write, use-after-free)
on `uv-tcp-peer-address`'s two-allocation guard path.

## Final state

`git diff --stat -- src/` shows only this task's feature diff (Step 1's
native binding and wrapper). No mutation was applied to `src/` by this
agent — both probes above and the uncovered-property entry are the
controller's next step, not something this agent ran or reverted.
