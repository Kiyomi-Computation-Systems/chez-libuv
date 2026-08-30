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


---

## Controller-run results

Both probes were executed by the controller, not the implementer — mutation
execution moved after two subagents earlier in this milestone returned control
with a live `src/` mutation still in the working tree. Tree verified clean
(`git status --porcelain` empty, no probe residue) before and after each run,
and `make test` green after both reverts.

### Probe A — point the wrapper at `uv_tcp_getsockname`

`src/libuv/tcp.sls`, in `uv-tcp-peer-address`: `uv-tcp-getpeername-native`
replaced by `uv-tcp-getsockname`.

```
=== tests/test-facade.sps ===
FAIL the facade's peer-address answers the connected peer
=== tests/test-tcp.sps ===
FAIL the client's peer address and port are the server's
FAIL the accepted handle's peer port is the client's own local port
FAIL an unconnected handle refuses with ENOTCONN
```

**Four rows, not the three predicted** — and the implementer flagged this
fourth as uncertain rather than asserting three, which was the right call.

The ENOTCONN row fails for a mechanically distinct and instructive reason:
`uv_tcp_getsockname` on a **bound but unconnected** handle *succeeds* — the
socket has a local address even with no peer — so no `UV_ENOTCONN` is
produced, `uv-check` does not raise, and the row's guard falls through to
`'no-raise`. So this row is not merely collateral: it independently
discriminates `getpeername` from `getsockname`, because only `getpeername`
has a failure mode on an unconnected socket.

Both address rows fail, as designed. Row 1 alone would not have been enough:
on loopback both ends are `127.0.0.1`, so the *address* half is identical
under the mutation and only the port half moves. Row 2 is what catches a
`getpeername` implemented as `getsockname` when the two ends share an address.

### Probe B — `sockaddr->address-string` returns constant `#f`

`src/libuv/private/native.sls`: body replaced with `#f`.

```
FAIL the client's peer address and port are the server's
FAIL the accepted handle's peer port is the client's own local port
FAIL the facade's peer-address answers the connected peer
FAIL sockaddr->address-string renders back the dotted quad uv_ip4_addr parsed
FAIL synthetic: a non-INET entry is skipped, the entry behind it decoded
FAIL the driven lookup answered exactly one 'inet record, the literal rendered back
FAIL unpinned socktype: every entry carries the same address
FAIL v4: the literal renders back through uv_ip_name
FAIL v6: the literal renders back
```

**Nine rows across test-tcp, test-facade, test-native and test-dns.** The six
beyond this task are correct, not excessive: `sockaddr->address-string` is the
shared address-decoding helper (ADR-0012's vocabulary), used by the DNS path
as well as by both TCP name verbs. A mutation to a shared helper legitimately
breaks every consumer.

The ENOTCONN row **passes** under this probe, as predicted — it asserts a
raise that happens before any address decoding is reached.

This is why the peer-address rows require the literal `"127.0.0.1"` rather
than tolerating `#f`: a row written to accept `#f` would pass against exactly
this mutation.

### Explicitly uncovered property (AGENTS.md)

**Non-interleaving of two consecutive `uv-write!` calls is NOT asserted, and
deliberately so.** libuv drains its write queue head-of-first
(`vendor/libuv/src/unix/stream.c:1043`), so a second request cannot begin
before the head completes. That makes non-interleaving a structural guarantee
of the vendored library, and "the byte stream is never interleaved" an absence
assertion no mutation in this binding can break — an empty test by AGENTS.md's
definition.

What this task asserts instead is what the *binding* owns: that accumulated
bytes equal payload-A followed by payload-B, and that both `on-complete`
callbacks fired with `'no-error` **in submission order**. That second row
fails if completions are ever routed by request kind rather than by block
pointer.

**A correction, recorded rather than quietly fixed.** The claim directly
above — that the completion row "fails if completions are ever routed by
request kind rather than by block pointer" — was false as originally
written. Both closures pushed the identical opaque value `'no-error` onto
`pa-order`, and the row compared the reversed list against the constant
`'(no-error no-error)`. That expected value cannot distinguish "A's callback
ran for A's completion and B's for B's" from "the two completions were
routed to each other's callbacks" — a swap still produces exactly two
`'no-error` entries, in the same list, either way. As written, the row
tested only two things: that exactly two completions fired (catching a
dropped or duplicated completion, which changes the list's length) and that
neither carried an error (catching a real failure, which changes an
element). It said nothing about *which* callback each completion reached,
so the routing claim quoted above did not hold for the row that existed at
the time.

The routing claim becomes true only once each closure is tagged with a
value the other closure cannot also produce — `'a` for A's callback, `'b`
for B's, with `(a-failed <cond>)` / `(b-failed <cond>)` on error so a
genuine failure stays distinguishable from a misroute — and the expected
value tightens from `'(no-error no-error)` to `'(a b)`. Only with that
change does a routing swap (both callbacks still firing exactly once, both
still error-free, but A's completion landing in B's closure or vice versa)
produce a value the test can tell apart from correct routing.

This is the **sixth** mechanism narrative in this milestone found wrong —
after Probe A's "kernel clamp", Probe G's "SO_SNDBUF moves", Probe H's "raw
Chez exception", and Task 3's fused-predicate gauge claim (the fifth). It
differs from those four in how it was caught: each of those was measured
wrong by instrumenting a mutation that had actually been run; this one was
never run at all — the row's own construction was sufficient to show, on
inspection, that it could not support the claim being made about it.
