# ADR-0013: DNS suites are hermetic — numeric-only lookups; the resolver is never consulted

- **Status:** Accepted (2026-08-21) — evidence: spike/dns/FINDINGS.md Q1–Q4
- **Date:** 2026-08-21
- **Scope:** chez-libuv v0.2
- **Related:** [design spec](../2026-08-21-chez-libuv-v0.2-dns-design.md), [ADR-0010](0010-loopback-integration-tests-replace-differential-oracle.md), [ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)

## Context

ADR-0010 anchors correctness to the kernel's own TCP semantics plus libuv's
documented callback contract, in one process. Name-resolution
*configuration* is neither: `/etc/hosts`, `/etc/services`, nsswitch module
order, systemd-resolved, mDNSResponder's XPC daemon are all host state this
project neither pins nor vendors. A DNS test whose green depends on runner
image contents — or worse, on the external network — is exactly the flake
class ADR-0010 exists to exclude, arriving through a new door.

Even `"localhost"` is host configuration: glibc routes it through nsswitch
(myhostname/files order varies by image), Darwin through mDNSResponder. Both
CI runners resolve it from `/etc/hosts` — today. "Today" is the problem.

## Decision

The gating suites (`make test`, `make test-memory`) never consult a
resolver. Every DNS operation in them is numeric:

1. **Forward, success:** `AI_NUMERICHOST` lookups of `"127.0.0.1"` and
   `"::1"`, with `AI_NUMERICSERV` and numeric services (`"80"`, `"8080"`) —
   pure `inet_pton`-class formatting; zero network, zero daemon, no
   `/etc/services`.
2. **Forward, error:** a non-numeric name under `numeric-host` → a
   deterministic `'EAI_NONAME` with empty results — the offline error path
   (measured on libSystem already; Q4's CI leg confirms glibc before this
   ADR flips to Accepted).
3. **Reverse:** `NI_NUMERICHOST|NI_NUMERICSERV` of `127.0.0.1:8080` and
   `[::1]:8080` — pure formatting.
4. **Banned:** `"localhost"` and every other non-numeric hostname; named
   services (`"http"`); any lookup that could reach the external network.
5. **`AI_ADDRCONFIG` is never set** in any suite: on interface-less CI
   containers glibc filters `::1` results under that flag, which would make
   rule 1's IPv6 half configuration-dependent. (The flag is not even
   expressible through the v0.2 hints surface — it is deliberately absent
   from the shim table and from the closed flags set, so a suite would have
   to bypass the public API to set it.)

**The watchdog is value-level, and deliberately so.** Every hints record in
`tests/test-dns.sps` is built by one suite-local helper that always includes
the numeric flags, and the property "the ban is watched" (AGENTS.md: prefer a
check to a comment) is a deterministic, offline assertion that the helper's
computed `ai_flags` integer has the shim-snapshotted `AI_NUMERICHOST` bit
set. The obvious watchdog — mutate the helper to drop the flag and watch the
`.invalid`-name row fail — does **not** work, and the mutation log must not
claim it does: `.invalid` is RFC 6761-reserved, so on any networked machine
the mutated suite performs a real query, receives NXDOMAIN, and both glibc
and libSystem map that to `EAI_NONAME` — the very symbol the row asserts
(measured on the dev machine against libSystem). Under that mutation the
suite only gets slower, and `run-until/ticking`'s iteration cap does not
catch a fast NXDOMAIN either. The value-level check fails instantly,
offline, by name.

## Consequences

- **No non-numeric resolver success path is exercised. Accepted, and stated
  here rather than papered over.** That path is libc's code, not this
  binding's. Everything the binding owns — argument marshalling and
  submission, the threadpool round-trip, chain copy-out, `uv_freeaddrinfo`
  ordering, dispatch, and registry/counter balance — is exercised by the
  numeric cases, including multi-entry chains via the unpinned-socktype
  lookup.
- Per-OS chain shapes are asserted as **set-containment, never order or
  exact length**: a numeric lookup with socktype unpinned answers 2 entries
  on macOS (dgram first, no `SOCK_RAW` — measured against libSystem) and an
  expected 3 on glibc (stream/dgram/raw). Spike Q4 pins both shapes on both
  CI libcs before any test hard-codes either; where the libcs agree the
  suite asserts equality, where they legitimately differ it asserts
  containment.
- The v0.2 hints surface is limited to what this policy can watch:
  `AI_ADDRCONFIG`/`AI_V4MAPPED`/`AI_ALL` stay unbound, because no
  offline-deterministic test can assert their libc-varying semantics, and
  unwatched behavior cannot ship (AGENTS.md's watched-to-fail rule).
- An opt-in networked test tier was considered and rejected for v0.2:
  nothing in the milestone needs it, and an off-by-default suite is
  unwatched code by definition.
- The memory gate stays coherent (ADR-0003): numeric-only means glibc never
  dlopens NSS/resolv modules into the instrumented process, so the valgrind
  leg observes the binding's allocations rather than resolver machinery —
  the remaining still-reachable worker stacks/TLS sit outside the
  definite-only gate and are documented at the Makefile's `test-memory`
  recipe.
- The errno symbols the suite pins (`'EAI_NONAME`, `'EAI_CANCELED`) are
  libuv-defined constants, identical on both OSes (all fourteen `EAI_*`
  codes are in `UV_ERRNO_MAP`, vendor/libuv/include/uv.h:81-94), so the
  assertions are portable by construction with zero new errno machinery.
