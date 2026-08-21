# DNS Stage 4 Mutation Log

> **Provenance.** This file was back-filled on 2026-08-21, after the fact,
> from the implementer's session report for Stage 4
> (`task-s4-report.md`, scratchpad) — the report that accompanied commit
> `3b74fdb` (`feat: (libuv dns) getaddrinfo path + (libuv private addrinfo)
> pure module (S4)`). Stage 4's full watched-to-fail mutation round was
> actually run at implementation time; it was recorded only in that scratch
> report, not committed, which breaks the house convention
> (`.plans/stage-N-mutation-log.md`, v0.1) of committing one mutation log
> per stage. This file corrects that — it transcribes the mutation-testing
> section of the report rather than re-deriving or re-running it, including
> the report's own appended numbering note (reproduced below, unedited).

Covers `src/libuv/private/addrinfo.sls` (new pure library — the `uv-addrinfo`
record, `validate-hints`, `validate-node-and-service`) and `src/libuv/dns.sls`
(new — `uv-getaddrinfo!`, the getaddrinfo dispatcher, `addrinfo-chain->list`,
`uv-dns-request?`) — against the new `tests/test-addrinfo.sps` (41 passes)
and `tests/test-dns.sps` (77 passes). Commit `3b74fdb`.

## Method (as reported)

Quoted verbatim from the report's own mutation-log section header: "scratch
copies under the session scratchpad; each run against the full mutated tree
via CHEZSCHEMELIBDIRS; pristine scratch verified green before the first
mutation and the scratch deleted after the last." Note for the record: this
is weaker than Stage 1/3's explicit "each mutation individually reverted and
re-verified green before the next" language — the report states the pristine
baseline was verified green *before the round started* and the scratch was
deleted *after the round finished*, not a per-mutation revert transcript.
Transcribed as given rather than strengthened.

## Mutation log

| # | Anchor edited | Mutation | Verbatim first named failure(s) |
|---|---|---|---|
| M1 | src/libuv/dns.sls | chain walk's `next` forced 0 (`ai_next` advance dropped) | `FAIL unpinned socktype: the chain has at least two entries` |
| M2 | src/libuv/dns.sls | decode-entry reads `ai_addr` at the `ai_canonname` offset and vice versa | `FAIL v4: the literal renders back through uv_ip_name` (then port/canonname/v6 rows) — fails BY NAME, no SIGSEGV, because `sockaddr->address-string` refuses the zero pointer |
| M3 | src/libuv/dns.sls | step-4 `(uv-freeaddrinfo res)` removed | No suite assertion possible: 75 passes, exit 0; local macOS ASan arm (recipe env, `detect_leaks=0`) also exit 0 — macOS-blind, as predicted. **GATE-CAUGHT — OBSERVED** on the Linux valgrind leg, CI run 32509190939 (2026-08-21): suite green under the mutation (`# of expected passes      121` on the v0.2-final tree) while the leak gate fired — `definitely lost: 1,496 bytes in 23 blocks`, both loss records alloc'd at `generate_addrinfo (getaddrinfo.c:1081)` on libuv's worker thread, `make: *** [Makefile:426: test-memory] Error 1`, step-observed exit 2. Full verbatim record and the exit-code-chain note in "Linux valgrind observation" below. |
| M4 | src/libuv/dns.sls | on-complete delivered BEFORE `complete-request!` (free moved after user code) | `FAIL freed before on-complete: the live counter reads 0 inside the callback` + the ptr-zeroed and registry-popped rows — exactly the three row-g assertions, nothing else |
| M5 | src/libuv/private/handles.sls | `registry-deregister!` dropped from `complete-request!` | Cascade, exit 255: `Exception ... &uv-invalid-argument who: uv-registry-register! reason: pointer-already-registered` (a later alloc reused the freed-but-registered address; the duplicate check fired as designed) |
| M6 | src/libuv/dns.sls | freeing-site counter replaced with a no-op | `FAIL in flight: the live counter reads 1 after submit, before stepping` (then row g, row i, row l balance, epilogue) |
| M7 | src/libuv/dns.sls | `decode-socktype` returns the raw int for known socktypes | `FAIL v4: socktype decodes to the symbol stream`; also `FAIL unpinned socktype: the socktype set contains stream and dgram` |
| M8 | src/libuv/dns.sls | dispatcher passes status 0 to `complete-request!` (EAI mapping bypassed) | `FAIL numeric-host + non-numeric name: errno is EAI_NONAME, by symbol` — row e alone |
| M9 | src/libuv/private/addrinfo.sls | node NUL clause removed | test-addrinfo: `FAIL an embedded NUL in node is refused`; test-dns: `FAIL boundary: an embedded NUL in node is refused` + the allocated-nothing row (the mutated call really submitted) |
| M10 | tests/test-dns.sps (suite, not production code) | helper loses `'numeric-host` | `FAIL ADR-0013 watchdog: helper flags carry the AI_NUMERICHOST bit` — instantly, value-level. Report's own note: every lookup row (row e included) still PASSED under this mutation on this networked machine, confirming ADR-0013's measured claim that resolver rows cannot catch it. |
| M11 | src/libuv/private/addrinfo.sls | family field flipped to mutable | `FAIL every uv-addrinfo field is declared immutable` |
| M12 | src/libuv/private/addrinfo.sls | family/socktype field order swapped | `FAIL family accessor answers the family field` + socktype row |
| M13 | src/libuv/private/addrinfo.sls | duplicate-key check dropped | test-addrinfo: `FAIL a duplicate key is refused ...` + who-passthrough row; test-dns: `FAIL boundary: a duplicate hint key is refused` + allocated-nothing row |
| M14 | src/libuv/private/addrinfo.sls | unknown-flag check dropped | `FAIL a flag outside the closed set is refused` + `FAIL addrconfig is refused ...` (dns.sls's flag-symbols->int else arm is a second net for the boundary path — the pure suite is the named owner) |
| M16 | src/libuv/dns.sls | `uv-dns-request?` loses its kind check (any `uv-req?` → `#t`) | `FAIL uv-dns-request? refuses a non-DNS request record, by kind` (row added because the original suite had no discriminating input) |
| M17 | src/libuv/dns.sls | orphan arm frees the chain but records nothing | `FAIL orphan arm: the event is recorded with the dispatcher's name and pointer` + orphan-count epilogue |
| M18 | src/libuv/dns.sls | dispatcher kind-mismatch clause removed entirely | `FAIL kind-mismatch arm: contained, and re-raised from uv-run by name` + orphan-count epilogue (the wrong-kind entry fell through to `complete-request!`'s orphan arm) |
| M21 | src/libuv/dns.sls | `decode-protocol` returns raw ints | `FAIL v4: protocol decodes to the symbol tcp` + b2 row |
| M22 | src/libuv/dns.sls | `write-hints!` socktype write dropped | `FAIL absent service: port decodes as 0` (chain widened) + v6 count + `FAIL in flight: the hints tail carries exactly what the start call wrote` + row h |
| M23 | src/libuv/dns.sls | `write-hints!` FLAGS write dropped | `FAIL in flight: the hints tail carries exactly what the start call wrote` — the ONLY failing row: row e passed via the NXDOMAIN trap exactly as ADR-0013 predicts, which is why the report notes this readback row was added mid-round |
| M24 | src/libuv/dns.sls | `write-hints!` family write dropped | `FAIL in flight: the hints tail carries exactly what the start call wrote` — only row; every resolver row's literal already forces the family, so no resolver row can see this |
| M25 | src/libuv/dns.sls | `write-hints!` protocol write dropped | `FAIL in flight: the hints tail carries exactly what the start call wrote` — only row |

### Numbering note (transcribed verbatim from the report's own appended note)

> Numbering note: **M15 does not exist** — it was the planning label for the
> "'() hints treated as present/zeroed-struct" mutation, which was executed
> and recorded as **M20**; the original number was retired in a renumbering
> slip during the run, and no planned mutation went unexecuted.

## Honest uncovered / gate-only records (as reported)

- **M19 (run, passed): v6 port read at the v4 `sin_port` offset — UNCOVERED
  BY VALUE.** 76 passes. Both supported libcs put `sin_port` and `sin6_port`
  at offset 2, so no test on any gating platform can distinguish the honest
  per-family lookup from the v0.1 shortcut. The per-family read is an
  honesty/portability decision (§5.2), not an observable one; recorded
  rather than claimed covered.
- **M20 (run): `'()` hints treated as a zeroed struct instead of NULL —
  classification half COVERED, pointer half UNCOVERED on the hermetic
  gates.** test-addrinfo catches the classification by name
  (`FAIL hints '() classifies as absent`); test-dns passes 76/76 under the
  same mutation because the NULL-vs-zeroed-struct difference is exactly the
  glibc resolver-configuration behavior (`AI_V4MAPPED|AI_ADDRCONFIG`
  implication) ADR-0013 bans from the oracle. §4.2's rationale is the
  record. (This is the mutation the numbering note above refers to.)
- **Conversion-failure arm (dispatcher step 6) — UNCOVERED, unreachable by
  construction.** `addrinfo-chain->list` cannot be made to raise by any
  input short of a wild pointer (its readers validate positivity only); the
  arm guards a dispatcher bug, per §5.4/§4.4's documented caveat. No honest
  test input exists; verified structurally (abandon-request! + counter +
  loop-record-error!, no delivery).
- **Trampoline cross-pairing** — logged per §9 as "failure mode varies" (UB:
  garbage register / interior-pointer free); the DESIGNED defense is the
  dispatcher kind check, watched by M18 via the direct-drive row, with
  registry/counter balance rows and the valgrind leg as backstop. The actual
  cross-pairing is not executed (it is UB, not a test).
- **`(lambda () #f)`-shape mappers' else arms in dns.sls** (family/socktype/
  protocol/flag symbol→int): unreachable by construction behind
  `validate-hints`; recorded raising per the tcp.sls:150-156 unreachable-arm
  convention. M14 showed the flag else arm acting as a second net when the
  pure check is mutated away.
- **M3, above:** its GATE-CAUGHT status was provisional on a Linux valgrind
  run not yet observed at the time of the report; that run has since been
  observed and the designation is no longer provisional (see "Linux
  valgrind observation" below).

## Deferred coverage (Stage 5 owns, as reported)

- `uv-getnameinfo!` path, its dispatcher, copy-before-free, and the
  `getnameinfo-req` counter class; the unreachable-by-construction
  getnameinfo abandon guard record.
- `uv-cancel!` rows (tolerant tail-cancel branch-invariants, cancel-after-
  completion with no native call, double-cancel, `'EAI_CANCELED` delivery).
- teardown-with-in-flight rows (cancel-then-drain contract, `err ∈ {#f,
  'EAI_CANCELED}`, exactly-one-callback) and the `uv-loop-close!` EBUSY-
  pending row; the `uv-loop-close!` pending-error re-raise row is Stage 6
  per the spec's milestone table.
- `'getnameinfo` membership in `uv-dns-request?`'s kind list (no getnameinfo
  request can exist this stage; M16's row covers the kind-check mechanism,
  the second kind becomes watchable when Stage 5 constructs one).
- M3's Linux valgrind observation — **HARVESTED 2026-08-21** (run
  32509190939; see "Linux valgrind observation" below). Note the record
  is not literally "exit 9": valgrind's own `--error-exitcode=9` is
  converted by the recipe's `|| exit 1` (Makefile:433) before make
  surfaces exit 2 — the definite-leak marker lines are what prove the
  leak gate, not the suite, fired.
- numeric reverse v4/v6 rows (getnameinfo, §9) — Stage 5.

## Linux valgrind observation (2026-08-21, CI run 32509190939)

The deferred M3 observation was harvested from the dedicated workflow
"DNS Mutation Observation (spike)" (branch `spike/dns-mutation-obs`,
run 32509190939, conclusion success): Ubuntu 24.04.4, Valgrind-3.22.0,
the pkg-config build path (distro `libuv.so.1.0.0`), Chez 10.4.1. The
run's shape: a pristine control (green), then the same one-line M3
mutation re-applied to the v0.2-final tree by patch
(`spike/dns/mutations/m3-freeaddrinfo-dropped.patch`, `1 file changed,
1 deletion(-)`), `make test-memory MEMORY_TESTS=tests/test-dns.sps`,
revert, then M2 and M12 (stage-5 log), then a final control (green).
Control evidence, verbatim: `CONTROL GREEN: harness proven before any
mutation.` before, `FINAL CONTROL GREEN: clean revert proven; three
mutations observed and reverted without leaving state behind.` after —
both controls with `definitely lost: 0 bytes in 0 blocks` and
`ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)`.

Under the M3 mutation the suite itself stayed green — no suite assertion
possible, exactly as recorded above (`# of expected passes      121` on
the v0.2-final tree; the Stage 4 tree's count was 75) — and the leak
gate fired. Verbatim from the mutated run's output (elisions marked):

```
==5552== 152 bytes in 2 blocks are definitely lost in loss record 6 of 9
==5552==    at 0x4846828: malloc (in /usr/libexec/valgrind/vgpreload_memcheck-amd64-linux.so)
==5552==    by 0x4AA8039: generate_addrinfo (getaddrinfo.c:1081)
==5552==    by 0x4AA8039: gaih_inet (getaddrinfo.c:1199)
==5552==    by 0x4AA8039: getaddrinfo (getaddrinfo.c:2391)
==5552==    by 0x502E434: ??? (in /usr/lib/x86_64-linux-gnu/libuv.so.1.0.0)
==5552==    by 0x502C6A8: ??? (in /usr/lib/x86_64-linux-gnu/libuv.so.1.0.0)
==5552==    by 0x49E9B83: start_thread (pthread_create.c:447)
==5552==    by 0x4A76B63: clone (clone.S:100)
[...]
==5552== 1,472 (1,344 direct, 128 indirect) bytes in 21 blocks are definitely lost in loss record 8 of 9
[...same generate_addrinfo (getaddrinfo.c:1081) allocation site...]
==5552== LEAK SUMMARY:
==5552==    definitely lost: 1,496 bytes in 23 blocks
==5552==    indirectly lost: 128 bytes in 2 blocks
==5552==      possibly lost: 0 bytes in 0 blocks
==5552==    still reachable: 3,423 bytes in 10 blocks
==5552==         suppressed: 0 bytes in 0 blocks
[...]
==5552== ERROR SUMMARY: 2 errors from 2 contexts (suppressed: 0 from 0)
make: *** [Makefile:426: test-memory] Error 1
```

and the step's own verdict lines:

```
M3 run exit code: 2
M3 marker check: FOUND 'definitely lost:' with nonzero bytes
M3 CONFIRMED: exit 2, definite-leak marker present -- matches the stage-4 log's prediction.
```

The leaked blocks are glibc's own `getaddrinfo` chain allocations,
unreferenced at exit because the dropped `uv_freeaddrinfo` was the only
thing that ever freed them — exactly the mutation's shape.

**Honest discrepancy, recorded:** this log (and §9's corrected oracle)
said "definite leak → exit 9". The 9 is valgrind's `--error-exitcode=9`
(Makefile:429); the recipe converts any valgrind failure via `|| exit 1`
(Makefile:433), make surfaces that as `Error 1` and itself exits 2, and
2 is what the workflow step observed. The prediction's substance — the
definite-leak gate, not the suite, is what catches this mutation —
is confirmed by the marker lines; the literal "exit 9" was never
observable at the make level and no log may claim it was.

## Gate tails (as reported)

- `make build`: green (no shim changes; relink-guard quiet).
- `make test`: 11 suites, **1008 expected passes, ALL SUITES PASSED** —
  test-addrinfo 41, test-dns 77; every v0.1 suite at its baseline count
  (conditions 94, echo 32, facade 41, lifecycle 64, loop 119, native 220,
  shim-loading 24, tcp 168, timer 128).
- `make check-purity`: `purity holds: tests/test-conditions.sps` AND
  `purity holds: tests/test-addrinfo.sps` — both with `CHEZ_LIBUV_SHIM`
  poisoned to `/nonexistent`.
- `make test-memory` (macOS ASan arm, Darwin/arm64): exit 0, all 11 suites
  including test-dns/test-addrinfo under the ASan preload
  (`libclang_rt.asan_osx_dynamic.dylib`, `detect_leaks=0`,
  `MallocNanoZone=0`). Leak claims remain Linux CI's (ADR-0003), as the
  recipe itself prints.

## Notes for the coordinator (as reported)

- Two suite rows were added mid-mutation-phase because mutations proved
  gaps: the hints-tail readback watchdog (M23/M24/M25 are invisible to every
  other row on a networked machine — the ADR-0013 NXDOMAIN trap generalizes
  to the boundary writes) and the `uv-dns-request?` non-DNS-request row
  (M16). Both were then watched to fail and pass.
- `dispatcher-ref` direct drive is how the orphan/kind-mismatch arms are
  tested (test-native.sps precedent on the uninstalled stubs); the
  deliberate orphan is accounted exactly in the epilogue (baseline + 1).
