# ADR-0012: An address is a presentation-form string; a port is a separate exact integer

- **Status:** Accepted (2026-08-21) — evidence: spike/dns/FINDINGS.md Q1–Q4
- **Date:** 2026-08-21
- **Scope:** chez-libuv v0.2
- **Related:** [design spec](../2026-08-21-chez-libuv-v0.2-dns-design.md), [ADR-0005](0005-constants-are-never-transcribed.md), [ADR-0009](0009-copy-at-the-boundary.md)

## Context

v0.1 met this question and deliberately walked around it.
`uv-tcp-getsockname-port` returns the port and nothing else, and the comment
above it records the deferral verbatim (src/libuv/tcp.sls:132-136):

> PORT ONLY, and the name says so. Returning a decoded address as well
> would mean deciding what an address IS in this binding's vocabulary --
> a string? a family plus bytes? -- and v0.1 has exactly one caller for
> this: a test (or a server) that bound port 0 and needs to know which
> port the kernel chose.

(The remainder of that comment block, tcp.sls:138-144, is the same caution
applied to layout: the port is decoded at a declared offset in network byte
order, and the family byte — whose offset and width differ between Darwin and
Linux — is deliberately not read at all.)

The DNS surface ends the deferral. A `uv-addrinfo` result must carry an
address the caller can hand straight back to `uv-tcp-connect!` — that
composition is the point of resolving — so v0.2 has to decide what an address
is, and the decision has to hold for inputs (`uv-getnameinfo!` takes one) as
well as outputs.

## Decision

An address crosses the public boundary as a **presentation-form string**
(`"127.0.0.1"`, `"::1"`) — never a bytevector, never a family-plus-bytes
record. The port travels beside it as a separate **exact integer in
0..65535** — never packed into the address value, never a string.

Both directions go through libuv's own code, and only libuv's own code:

- **Inbound** (string → sockaddr): `uv_ip4_addr`/`uv_ip6_addr`, via the
  `fill-sockaddr!` helper v0.1 already built on them (tcp.sls:84-87; lifted
  into native.sls in v0.2 so tcp and dns share the one parser).
- **Outbound** (sockaddr → string): `uv_ip_name`
  (vendor/libuv/src/uv-common.c:310-321), in libuv since 1.43 — inside the
  declared 1.44.0 floor (Makefile:57-59, README.org:45).

The binding neither parses nor formats an address itself. That is the
load-bearing property: the vocabulary cannot drift from what libuv accepts,
because it *is* what libuv accepts — ADR-0005's never-transcribed discipline
applied to a value format instead of a constant.

The vocabulary is symmetric across the API: `uv-getnameinfo!` accepts
`(ip, port)` in exactly the terms `uv-tcp-bind!`/`uv-tcp-connect!` already
use (`require-address`/`require-port`, tcp.sls:61-70), and `uv-addrinfo`
results speak the same terms back.

## Consequences

- `uv-addrinfo-address`/`uv-addrinfo-port` compose directly with
  `uv-tcp-connect!`'s existing parameters: resolution-to-connection needs no
  adapter, without any convenience wrapper existing (locked scope decision —
  no `tcp-connect-to-host`).
- Strings are immutable Scheme values, so ADR-0009 is satisfied trivially at
  this surface: no foreign lifetime ever attaches to a result, and nothing a
  callback stores can dangle.
- A future `uv-tcp-getsockname` sibling (address and port, beside the v0.1
  port-only accessor) needs no new vocabulary decision. That sibling is
  explicitly **not** scoped into v0.2; this ADR only guarantees that when it
  happens, the question stays answered.
- Raw address bytes are foreclosed at this surface; a caller who needs bytes
  parses the string. Accepted: no primitive this binding mirrors consumes raw
  address bytes. Relatedly, `uv_ip_name` refuses non-INET families with
  `UV_EAFNOSUPPORT` (uv-common.c:318-320), which is why the result walk skips
  such entries rather than smuggling them through in some second format.
- **IPv6 scope IDs are dropped in v0.2, and this ADR says so rather than
  pretending otherwise.** Verified against the pinned source:
  `uv_ip6_name`/`uv_ip_name` render only the 16 address bytes —
  `sin6_scope_id` is never read on any path
  (vendor/libuv/src/uv-common.c:305-321). A getaddrinfo result for a
  link-local address therefore reads back as `"fe80::1"`, not
  `"fe80::1%eth0"`. The asymmetry is real: inbound, `uv_ip6_addr` *does*
  parse a `%zone` suffix via `if_nametoindex` (uv-common.c:265-296), so
  feeding the de-scoped string back into `uv-tcp-connect!` builds a sockaddr
  with scope 0 — a plausible, wrong destination, the exact failure shape the
  v0.1 spike notes warn about. v0.2 documents the drop here and in
  README.org, and the spike matrix (Q4) carries a scoped-literal row so the
  observed behavior is on record. The fix path, recorded for whichever
  release needs it: snapshot `OFFSETOF_SOCKADDR_IN6_SIN6_SCOPE_ID` in the
  shim (ADR-0005 mechanism), read the scope during the chain walk, and when
  it is nonzero append `%` plus the interface name from `uv_if_indextoname`
  (already in libuv, vendor/libuv/src/unix/getaddrinfo.c:231-253, the same
  caller-buffer shape as `uv_strerror_r`; numeric fallback when the index no
  longer names an interface) — re-deriving the render scratch to
  45 + 1 + IF_NAMESIZE bytes. Until that lands, link-local results are
  ambiguous at this surface, and no document in this repo may claim scope IDs
  are representable.
