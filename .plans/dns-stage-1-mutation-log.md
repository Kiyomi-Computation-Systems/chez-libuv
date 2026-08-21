# DNS Stage 1 Mutation Log

> **Provenance.** This file was back-filled on 2026-08-21, after the fact,
> from the implementer's session report for Stage 1
> (`task-s1-report.md`, scratchpad) — the report that accompanied commit
> `2ec30da` (`feat: DNS shim constants + getaddrinfo/getnameinfo counter
> classes (S1)`). Stage 1's full watched-to-fail mutation round was actually
> run at implementation time; it was recorded only in that scratch report,
> not committed, which breaks the house convention (`.plans/stage-N-mutation-log.md`,
> v0.1) of committing one mutation log per stage. This file corrects that —
> it transcribes the mutation-testing section of the report rather than
> re-deriving or re-running it. Where the report gives only a summary line
> rather than a full transcript, that line is transcribed as given and
> flagged below.

Covers `src/libuv-shim.c` (29 new constant-table entries + six
getaddrinfo/getnameinfo counter functions), `src/libuv/private/constants.sls`
(29 snapshot names + accessors), and `src/libuv/private/native.sls` (the six
counter foreign-procedure bindings + two `live-counts` entries) — proving the
new DNS constants, offsets, and counter classes each have a
`tests/test-native.sps` assertion that fails, by name, when the decision is
broken. Commit `2ec30da`.

## Method (as reported)

The report does not restate the scratch-copy/`CHEZSCHEMELIBDIRS` mechanics
`.plans/stage-1-mutation-log.md` (Task 5's C-side section) used for shim
mutations; it records only the outcome: mutations were applied post-GREEN,
each against `src/libuv-shim.c` unless a row says otherwise, the suite was
re-run, and the failure recorded verbatim. One trap is called out explicitly:
the make-3.81 whole-second-mtime stale-relink trap (`AGENTS.md`) bit once
during the round — a revert written in the same wall-clock second as the
prior build skipped the relink and the suite judged the mutated shim against
stale object code. All subsequent rounds forced the relink
(`rm -f build/lib/libchezlibuv.dylib` before `make build`) before re-testing;
no Makefile change was made.

## Baseline / RED phases (as reported)

RED-1 (test rows only, no C yet):
```
Exception: attempt to reference unbound identifier sizeof-sockaddr-in6 at line 261, char 37 of tests/test-native.sps
```

RED-2a (constants.sls + native.sls in, shim untouched):
```
Exception in foreign-procedure: no entry for "chez_uv_count_getaddrinfo_req_new"
```
— at import, the load-before-bind failure shape native.sls's own header
documents.

RED-2b (counter trios in shim, table entries still absent):
```
0. &uv-constant-unavailable: AF_INET6
```
at init — ADR-0005's designed structured failure, naming the first missing
snapshot name.

GREEN: 211 expected passes, 0 failures; informational row `addrinfo offsets:
ai_addr=32 ai_canonname=24 sizeof=48` matched `./spike/dns/probe-dns`
output exactly (Darwin order, canonname before addr).

## Mutation log

Every row below is a **post-GREEN targeted mutation** (mutation → verbatim
first named failure), transcribed exactly as the report's own table. The
report's collective restored-green statement, covering the whole table, is:
"Every mutation produced its predicted failure through the asserted property;
none failed for a side-effect reason. Each was reverted and green
re-verified." No per-mutation exit code or revert transcript beyond that
collective statement survives in the source report.

| # | Anchor edited | Mutation | Verbatim first named failure |
|---|---|---|---|
| M1 | src/libuv-shim.c | delete the `OFFSETOF_ADDRINFO_AI_NEXT` table entry | `&uv-constant-unavailable: OFFSETOF_ADDRINFO_AI_NEXT` (init, before any row) |
| M2 | src/libuv-shim.c | `SIZEOF_UV_GETADDRINFO_T` → `sizeof(uv_getnameinfo_t)` | `FAIL uv_req_size(UV_GETADDRINFO) agrees with the shim's sizeof(uv_getaddrinfo_t)` |
| M3 | src/libuv-shim.c | `SIZEOF_UV_GETNAMEINFO_T` → `sizeof(uv_getaddrinfo_t)` | `FAIL uv_req_size(UV_GETNAMEINFO) agrees with the shim's sizeof(uv_getnameinfo_t)` |
| M4 | src/libuv-shim.c | `UV_GETNAMEINFO` value → `UV_GETADDRINFO` AND its sizeof made to coincide (tags collapsed, cross-checks still pass) | `FAIL the write, connect, shutdown, getaddrinfo, and getnameinfo request tags are pairwise distinct` |
| M5 | src/libuv-shim.c | `OFFSETOF_ADDRINFO_AI_FAMILY` → `offsetof(ai_flags)` | `FAIL the eight addrinfo field offsets are pairwise distinct` |
| M6 | src/libuv-shim.c | `OFFSETOF_ADDRINFO_AI_NEXT` → `sizeof(struct addrinfo)` | `FAIL snapshot: OFFSETOF_ADDRINFO_AI_NEXT lies inside sizeof(struct addrinfo)` |
| M7 | src/libuv-shim.c | `OFFSETOF_SOCKADDR_IN6_SIN6_PORT` → `sizeof(struct sockaddr_in6) - 1` | `FAIL sin6_port's two network-order bytes fit inside sockaddr_in6` |
| M8 | src/libuv-shim.c | `SIZEOF_SOCKADDR_IN6` → `sizeof(struct sockaddr_storage) + 1` | `FAIL sockaddr_storage can hold a sockaddr_in6` |
| M9 | src/libuv-shim.c | `AF_INET6` → `AF_INET` | `FAIL the three address families are pairwise distinct` |
| M10 | src/libuv-shim.c | `SOCK_RAW` → `SOCK_DGRAM` | `FAIL the three socket types are pairwise distinct` |
| M11 | src/libuv-shim.c | `IPPROTO_UDP` → `IPPROTO_TCP` | `FAIL IPPROTO_TCP and IPPROTO_UDP are distinct` |
| M12 | src/libuv-shim.c | `AI_PASSIVE` → `0` | `FAIL snapshot: AI_PASSIVE is a nonzero flag` |
| M13 | src/libuv-shim.c | `AI_NUMERICSERV` → `AI_NUMERICHOST` | `FAIL the four AI_ flags are pairwise distinct` |
| M14 | src/libuv-shim.c | `NI_NUMERICHOST` → `0` | `FAIL snapshot: NI_NUMERICHOST is a nonzero flag` |
| M15 | src/libuv-shim.c | `NI_DGRAM` → `NI_NAMEREQD` | `FAIL the four NI_ flags are pairwise distinct` |
| M16 | src/libuv-shim.c (dev arm) | `chez_uv_count_getaddrinfo_req_new` bumps `live_getnameinfo_req` | `FAIL counter getaddrinfo-req: increments are visible (seeded non-zero)` — then the predicted cascade: no-other-class-moved and baseline rows, 8 failures total |
| M17 | src/libuv-shim.c (dev arm) | `chez_uv_live_getnameinfo_req` returns `live_getaddrinfo_req` | `FAIL counter getaddrinfo-req: no other class moved` (cross-read visible in the neighbour class first, as predicted), then `FAIL counter getnameinfo-req: increments are visible` |
| M18 | src/libuv/private/native.sls | `(cons 'getnameinfo-req (live-getnameinfo-req))` removed from `live-counts` | `FAIL live-counts reports all eight allocation classes` |
| M19 | src/libuv-shim.c (no-op arm) | getaddrinfo counter trio deleted; `make build FLAVOR=prod` links clean | `check-prod`: `Exception in foreign-procedure: no entry for "chez_uv_count_getaddrinfo_req_new"` (exit 255) — the prod gate is what guards the no-op arm, not test-native.sps |

## Gate evidence (as reported)

check-prod contract runs, kept as the report recorded them since M19 above
depends on them:

- **Dev shim (must refuse):** `check-prod: FAIL: the counters moved while the
  probe's scope was live: ((loop . 1) (tcp . 1) (timer . 0) (write-req . 0)
  (connect-req . 0) (getaddrinfo-req . 0) (getnameinfo-req . 0)
  (read-buffer . 0))` → make Error 1. Correct refusal; both new counter
  classes visibly iterated.
- **`make prod` (clean → build FLAVOR=prod → check-prod):**
  `check-prod: PASS: every counter read 0 while a bound tcp handle
  (port 49422) was live on the loop; the shim is a prod (counters-free)
  build` → exit 0.

Final `make test`: **ALL SUITES PASSED** — conditions 63, echo 21, facade 79,
lifecycle 106, loop 175, native **211** (was 175; +36), shim-loading 24, tcp
168, timer 128.

## Notes carried forward (as reported)

- The make-3.81 same-second stale-relink trap bit once during this round
  (see Method); any future scripted mutation loop on this repo should force
  the shim relink between rounds.
- Darwin's addrinfo layout was confirmed live: `ai_canonname` (24) precedes
  `ai_addr` (32); the test rows deliberately assert distinctness/bounds only,
  so Linux CI legs pass against glibc's swapped order.
- The two new `live-counts` entries were inserted after `connect-req` (request
  classes kept contiguous), not appended at the end; the exact-key-list row
  in test-native pins this order, and all other consumers were checked
  order-agnostic (test-loop, test-lifecycle, test-echo, check-prod use
  assq/for-all).
