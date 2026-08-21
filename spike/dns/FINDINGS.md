# Stage 0 Findings — chez-libuv v0.2 DNS

Evidence for the four questions the
[v0.2 DNS design spec](../../.plans/2026-08-21-chez-libuv-v0.2-dns-design.md)
§10 and ADR-0011..0013 (plus the ADR-0008 ten-trampoline amendment) are
contingent on. Every claim below is followed by the command that produced it
and the output that command actually printed. Every experiment was run
**twice**; where the two runs are not byte-identical, the difference is named
and explained rather than glossed.

The scripts are committed beside this file: `spike/dns/probe-dns.c`,
`spike/dns/04-threadpool-gc.ss`, `spike/dns/05-cancel-race.ss`,
`spike/dns/06-hermetic-matrix.ss`. Every number quoted in this document is
reproducible by re-running them.

**This document is the macOS leg.** The Linux legs (Q1 ubuntu run, the whole
of Q2's valgrind question, Q4's glibc run) are `PENDING CI` and are marked as
such below — nothing in those subsections is projected or assumed, because
nothing there has been run. valgrind does not exist on this Darwin/arm64
machine.

## Toolchain

| Item | Value | How determined |
|---|---|---|
| Chez Scheme | 10.4.1 | `chez --version` |
| Machine type | tarm64osx | arm64 macOS build of Chez |
| libuv | 1.52.1 (Homebrew) | `brew list --versions libuv` |
| libuv shared object | `/opt/homebrew/opt/libuv/lib/libuv.dylib` | |
| libuv headers | `/opt/homebrew/opt/libuv/include/uv.h` | |
| C compiler | Apple clang 21.0.0 (clang-2100.1.1.101) | `cc --version` |
| Target triple | `arm64-apple-darwin25.5.0` | `cc --version` |
| macOS | 26.5.2 (build 25F84) | `sw_vers` |
| Arch | arm64 | `uname -m` |
| ASan runtime (Q2 macOS arm) | `libclang_rt.asan_osx_dynamic.dylib`, clang 21.0.0, resolved by the `Makefile` `ASAN_DYLIB_PATTERN` glob | see Q2 |

## Summary of verdicts

| Q | Verdict |
|---|---|
| Q1 — threadpool × GC × re-entrancy × loop-liveness | **PASS (macOS leg).** 10,000/10,000 threadpool completions delivered into a locked callable, `(collect)` + result verification + resubmission on every fire, exit 0, twice, stdout byte-identical. Both new trampoline shapes' entry points stable across all collections. ubuntu leg **PENDING CI**. |
| Q2 — sanitizers' view of unjoined workers | **macOS ASan arm PASS** (exit 0 twice, no reports, sanitizer proven live; no leak claim — LeakSanitizer is unsupported on arm64 macOS, ADR-0003). The valgrind question — the one Q2 actually gates on — is **PENDING CI** in its entirety. |
| Q3 — cancel race histogram | **PASS.** Both branches observed, every trial in a legal branch, exactly-one-callback held in all recorded trials. Cancelled branch dominates at pool 1 (1000/1000, twice) **and** at the default pool (996/4 twice, 993/7 in a third run). The tolerant cancel test is licensed; the 32-blocker fallback is not needed. |
| Q4 — hermetic determinism matrix | **PASS (macOS leg).** Every cell byte-identical across two runs. Darwin unpinned chain measured: 2 entries, dgram-first, no raw — §9's prediction confirmed. Scoped-literal rows measured end-to-end for ADR-0012. glibc leg **PENDING CI**. |

Spike exit (ADRs flip to Accepted) requires the PENDING CI legs; this
document records the macOS half of the evidence.

---

## Q-1: the constants probe (`spike/dns/probe-dns.c`)

Same role as v0.1's `spike/probe.c`: no enum value, struct size, or
`offsetof` in any spike script below was transcribed from a header or from
memory. They all come from this probe (ADR-0005's rule applied to the spike).

**Commands run (verbatim):**

```bash
cc -I/opt/homebrew/opt/libuv/include -o spike/dns/probe-dns \
   spike/dns/probe-dns.c -L/opt/homebrew/opt/libuv/lib -luv
./spike/dns/probe-dns
```

**Actual observed output** (verbatim; byte-identical across two runs, exit `0` both times):

```
== versions ==
uv_version()                           0x013401
uv_version_string()                    1.52.1

== uv_req_type enum values (DNS kinds) ==
UV_GETADDRINFO                         8
UV_GETNAMEINFO                         9

== uv_run_mode enum values ==
UV_RUN_DEFAULT                         0
UV_RUN_ONCE                            1
UV_RUN_NOWAIT                          2

== request sizes ==
uv_req_size(UV_GETADDRINFO)            160
uv_req_size(UV_GETNAMEINFO)            1320
sizeof(uv_getaddrinfo_t)               160
sizeof(uv_getnameinfo_t)               1320
uv_loop_size()                         1072

== struct addrinfo layout ==
sizeof(struct addrinfo)                48
offsetof(struct addrinfo, ai_flags)    0
offsetof(struct addrinfo, ai_family)   4
offsetof(struct addrinfo, ai_socktype) 8
offsetof(struct addrinfo, ai_protocol) 12
offsetof(struct addrinfo, ai_addrlen)  16
offsetof(struct addrinfo, ai_canonname) 24
offsetof(struct addrinfo, ai_addr)     32
offsetof(struct addrinfo, ai_next)     40

== address families ==
AF_UNSPEC                              0
AF_INET                                2
AF_INET6                               30

== socket types / protocols ==
SOCK_STREAM                            1
SOCK_DGRAM                             2
SOCK_RAW                               3
IPPROTO_TCP                            6
IPPROTO_UDP                            17

== AI_ flags ==
AI_PASSIVE                             1
AI_CANONNAME                           2
AI_NUMERICHOST                         4
AI_NUMERICSERV                         4096

== NI_ flags / buffer sizes ==
NI_NUMERICHOST                         2
NI_NUMERICSERV                         8
NI_NAMEREQD                            4
NI_DGRAM                               16
NI_MAXHOST                             1025
NI_MAXSERV                             32
INET6_ADDRSTRLEN                       46

== uv errno constants used by the dns spike ==
UV_EAI_NONAME                          -3008
UV_EAI_CANCELED                        -3003
UV_EAI_BADFLAGS                        -3002
UV_EAI_SERVICE                         -3010
UV_EINVAL                              -22
UV_EBUSY                               -16
UV_ECANCELED                           -89
UV_E2BIG                               -7
UV_ENOENT                              -2

== struct sockaddr_in layout (v0.1 probe re-check) ==
sizeof(struct sockaddr_in)             16
offsetof(struct sockaddr_in, sin_family) 1
sizeof(((struct sockaddr_in *)0)->sin_family) 1
offsetof(struct sockaddr_in, sin_port) 2
offsetof(struct sockaddr_in, sin_addr) 4

== struct sockaddr_in6 layout ==
sizeof(struct sockaddr_in6)            28
offsetof(struct sockaddr_in6, sin6_family) 1
sizeof(((struct sockaddr_in6 *)0)->sin6_family) 1
offsetof(struct sockaddr_in6, sin6_port) 2
offsetof(struct sockaddr_in6, sin6_addr) 8
offsetof(struct sockaddr_in6, sin6_scope_id) 24
```

**Findings worth carrying forward:**

1. **The Darwin `struct addrinfo` field order is measured on this side now:**
   `ai_canonname` at 24 **before** `ai_addr` at 32. glibc reverses those two
   (design spec §5.2, verified in both headers at design time). Any ftype or
   transcribed offset is wrong on one platform — this is the concrete number
   behind the rule that the production offsets come from the shim.
2. **`uv_req_size(UV_GETNAMEINFO)` is 1320 bytes** — the req embeds the
   result buffers (`NI_MAXHOST` 1025 + `NI_MAXSERV` 32, plus the base req and
   a 128-byte `sockaddr_storage`). The callback's `hostname`/`service`
   pointers point INTO the req block (`uv/unix.h:353-354`), so copy-before-free
   is structural, not stylistic. Both DNS req sizes agree exactly with
   `sizeof`, as every v0.1 pair did.
3. **`AI_NUMERICSERV` is 4096 on Darwin and `AF_INET6` is 30** — both
   platform-specific (glibc's differ). The spike scripts hardcode the Darwin
   values with a loud label; **the CI legs must run `probe-dns` on the runner
   and substitute its output**, never a remembered value.
4. **The `UV_EAI_*` codes are libuv-defined constants in the -3000 range**
   (`UV_EAI_NONAME` = -3008, `UV_EAI_CANCELED` = -3003), not host errno
   values — unlike `UV_ECANCELED` (-89, host-derived, the v0.1 finding).
   Whether they are numerically identical on Linux is for the CI probe run to
   print, not for this document to assume; the scripts compare *names* via
   `uv_err_name`, so they do not depend on it.
5. `sin6_port` sits at offset 2 with the same 2-byte width as `sin_port` on
   this platform, and `sin6_scope_id` at 24 — the offsets Q4's reverse and
   scoped rows read.

---

## Q1 — threadpool workers × Chez GC × re-entrancy × loop-liveness

**Script:** `spike/dns/04-threadpool-gc.ss`.

10,000 `uv_getaddrinfo` lookups of `"127.0.0.1"`/`"80"` under
`AI_NUMERICHOST|AI_NUMERICSERV` hints (family `AF_INET`, socktype
`SOCK_STREAM` — pure formatting, zero network, one entry per chain). The
callback, a **locked** `foreign-callable` of the new getaddrinfo shape
`(uptr int uptr) -> void`, on **every** fire: conses a fresh 1000-element
list, calls `(collect)`, verifies the decoded result (chain length 1, family,
`sin_family` byte, port 80 big-endian at offset 2, address bytes 127.0.0.1),
calls `uv_freeaddrinfo`, frees the completed req block, and **resubmits the
next lookup from inside itself** with a freshly `foreign-alloc`'d req. One
blocking `uv_run(UV_RUN_DEFAULT)` drives all 10,000 — the resubmission's
registration keeps the loop alive, so the run ends exactly when the chain
does. A locked getnameinfo-shaped callable `(uptr int uptr uptr) -> void` is
created alongside and fired once (numeric reverse lookup), so both new
trampoline arities are exercised, not just address-stable.

**Commands run (verbatim):**

```bash
/usr/bin/time -p chez --script spike/dns/04-threadpool-gc.ss \
  /opt/homebrew/opt/libuv/lib/libuv.dylib 10000
```

**Actual observed output — stdout** (verbatim; **byte-identical across two
runs**, exit `0` both times; wall time `real 0.18` both runs):

```
--- (c) putenv -> uv_os_getenv propagation (before any threadpool touch) ---
uv_os_getenv(CHEZ_LIBUV_DNS_SPIKE) = "q1-propagation-sentinel"
uv_os_getenv(UV_THREADPOOL_SIZE)   = "4"

--- setup ---
uv_req_size(UV_GETADDRINFO)  = 160
locked getaddrinfo entry point stable across (collect)? #t
locked getnameinfo entry point stable across (collect)? #t
target lookups               = 10000
uv_loop_init                 = 0

--- (a) uv_run modes with a request in flight ---
submit rc                     = 0
uv_run(NOWAIT) immediately    = 1 (callback fired by then: 0)
'once calls until delivery    = 1
uv_run(ONCE) rc at delivery   = 0
probe-a callback fired        = 1

--- (b) Chez `string` foreign-argument marshalling ---
strlen resolvable             = yes
strlen("hello")               = 5
strlen("h\xe9;llo")           = 6  (6 = UTF-8 two-byte e-acute; 5 would be Latin-1)
strlen("ab\x0;cd")            = 2  (2 = callee sees a prefix truncated at the embedded NUL)
uv_ip4_addr(#f, 80, sa)       = EINVAL
uv_ip4_addr("127.0.0.1", ...)  = 0
uv_ip4_addr("127.0.0.1\x0;junk") = 0  (0 = the NUL-truncated prefix parsed)
uv_getaddrinfo(node=#f, "80") submit rc = 0
  async status = 0, result verifies as 127.0.0.1:80 = ok
uv_getaddrinfo(node="", "80") submit rc = EINVAL  (synchronous; no callback will fire)
uv_getaddrinfo("127.0.0.1\x0;.evil", "80") submit rc = 0
  async status = 0, result verifies as 127.0.0.1:80 = ok  ('ok = the NUL-truncated prefix RESOLVED)

--- engine: 10000 lookups, (collect) + verify + resubmit in every callback ---
first submit rc              = 0
uv_run(UV_RUN_DEFAULT)       = 0  (0 = nothing left alive when the chain ended)
fire count after uv_run      = 10000
submit failures              = 0
verify failures              = 0
first verify failure         = none
getaddrinfo entry point stable across engine? #t
getnameinfo entry point stable across engine? #t

--- getnameinfo arity check (numeric reverse lookup) ---
uv_ip4_addr for reverse       = 0
uv_getnameinfo submit rc      = 0
gni callback fired            = 1
gni status                    = 0
gni host                      = "127.0.0.1"
gni service                   = "80"

uv_loop_alive after all work = 0
uv_loop_close                = 0
foreign-free                 = done
post-teardown collect        = done

--- checks ---
putenv sentinel propagated: expected="q1-propagation-sentinel" actual="q1-propagation-sentinel" OK
putenv UV_THREADPOOL_SIZE propagated: expected="4" actual="4" OK
fire count exact: expected=10000 actual=10000 OK
no submit failures: expected=0 actual=0 OK
no verify failures: expected=0 actual=0 OK
first verify failure sentinel: expected=none actual=none OK
getaddrinfo entry point stable: expected=#t actual=#t OK
getnameinfo entry point stable: expected=#t actual=#t OK
engine uv_run rc: expected=0 actual=0 OK
probe-a delivered exactly once: expected=1 actual=1 OK
node=#f submit rc: expected=0 actual=0 OK
node=#f async success: expected=0 actual=0 OK
node=#f result is 127.0.0.1:80: expected=ok actual=ok OK
node="" fails SYNCHRONOUSLY EINVAL: expected=-22 actual=-22 OK
embedded-NUL node resolved its prefix: expected=ok actual=ok OK
gni fired exactly once: expected=1 actual=1 OK
gni status: expected=0 actual=0 OK
gni host: expected="127.0.0.1" actual="127.0.0.1" OK
gni service: expected="80" actual="80" OK
garbage really was built: expected=1000 actual=1000 OK
loop alive after all work: expected=0 actual=0 OK
uv_loop_close rc: expected=0 actual=0 OK

RESULT: PASS
```

**stderr** carries the trampoline entry-point addresses (ASLR/heap
dependent, the one legitimately differing part) and the timing. Both runs,
verbatim:

```
addresses: getaddrinfo 10AC76CC0 -> 10AC76CC0 ; getnameinfo 10AC77600 -> 10AC77600
real 0.18
user 0.11
sys 0.05
```

```
addresses: getaddrinfo 106DF6CC0 -> 106DF6CC0 ; getnameinfo 106DF7600 -> 106DF7600
real 0.18
user 0.12
sys 0.05
```

The addresses differ **between** runs (expected) and are identical **within**
each run — and the in-script stability check additionally compares them
*after* the engine's 10,000 collections, not just after the warm-up
`(collect)` + `(collect (collect-maximum-generation))` pair.

### What Q1 establishes

1. **10,000 exact threadpool re-entries.** Every completion crossed worker
   thread → `wq_async` → loop thread → locked callable; `fire count` is
   exactly 10,000, with `(collect)` forced inside every single one and a
   fresh submission issued from inside every one but the last.
2. **Both new trampoline shapes are GC-stable.** `(uptr int uptr)` fired
   10,003 times across four distinct locked callables (engine + probe-a +
   two marshalling probes); `(uptr int uptr uptr)` fired once and delivered
   both C strings intact. Entry points of both did not move across ~10,002
   collections.
3. **Loop-liveness works as ADR-0011 needs it to.** The resubmission from
   inside the callback kept a single blocking `uv_run` alive for the whole
   chain, and the run returned `0` the moment the last callback declined to
   resubmit — active DNS requests alone hold the loop open, and only they.
4. **Result verification held on every fire** — family, `sin_family` byte at
   Darwin offset 1, big-endian port at offset 2, the four address bytes, and
   single-entry chain: `verify failures = 0` with the `'none` first-failure
   sentinel intact (a callback that never verified would have left `'none`
   too, but then `fire count` could not be 10,000 — the two checks back each
   other).
5. **Wall time is 0.18 s for the full 10k** — v0.1's Q1 took ~13 s because
   its 1 ms repeating timer gates each fire on the clock; getaddrinfo
   completions chain back-to-back with no timer in the path. The design
   spec's ~2-minute budget is not remotely approached, and the 10,000 target
   was run as specified, unreduced.

### Recorded observation (a): `uv_run` while a getaddrinfo request is pending

Measured with a standalone request, outside the engine:

- `uv_run(UV_RUN_NOWAIT)` immediately after submit returned `1` (loop still
  alive) **without delivering** (`callback fired by then: 0`).
- The next `uv_run(UV_RUN_ONCE)` **did not return until the completion was
  delivered**: one single `'once` call sufficed (`'once calls until delivery
  = 1`), the callback had fired by the time it returned, and its return
  value was `0` — nothing left alive afterwards.

So a pending DNS request parks `'once` in the poll until `wq_async` posts:
`'once` **blocks** (NOWAIT is the non-blocking probe that proves the work was
not yet done when `'once` was entered). For the test suite this is the
measured basis for the house rule that every DNS wait goes through
`run-until/ticking`: a bare `'once` will not spin, but it will sit for as
long as the pool takes, and the v0.1 trap about `'once` returning early
after callback activity still applies in mixed suites. Note the rc
convention: `'once` returned `0` here because the completed request was the
loop's only referent; a suite with other live handles would see nonzero.

### Recorded observation (b): Chez `string` argument marshalling

Three properties, each measured two independent ways:

1. **`#f` crosses as NULL.** `uv_ip4_addr(#f, …)` answered `EINVAL` — that
   is `uv_inet_pton`'s explicit NULL guard (`vendor/libuv/src/inet.c:147`).
   Necessary but not decisive (`""` also parses to `EINVAL`), so the
   discriminating pair went through `uv_getaddrinfo`: `node=#f` was
   **accepted** (submit rc 0) and resolved asynchronously to `127.0.0.1:80`
   (NULL node + numeric service is valid input), while `node=""` failed
   **synchronously** with `EINVAL` and no callback — the idna empty-input
   path (`vendor/libuv/src/idna.c:325-326`). If `#f` were marshalled as an
   empty string the two rows would have been identical. They were not.
   The `node=""` row doubles as the first live measurement of the spec §7
   "post-registration sync failure" fact `abandon-request!` exists for.
2. **The marshalling transcodes to UTF-8.** `strlen("h\xe9;llo")` = 6 — the
   é crossed as two bytes (Latin-1 would give 5). `strlen` is resolved from
   the images already loaded into the process (libSystem here), not from
   libuv; the script degrades to a printed `NO` rather than failing if some
   platform's Chez cannot resolve it.
3. **An embedded NUL silently truncates.** `strlen("ab\x0;cd")` = 2 at the
   byte level; behaviorally, `uv_ip4_addr("127.0.0.1\x0;junk")` parsed the
   prefix (rc 0), and — the measurement §4.1's refusal clause is premised
   on — `uv_getaddrinfo("127.0.0.1\x0;.evil", "80")` **resolved
   successfully to 127.0.0.1:80**. A hostile string resolves as its prefix,
   plausibly and wrongly. The production validation clause refusing `#\nul`
   in `node`/`service` is therefore guarding a measured behavior, not a
   hypothesis.

### Recorded observation (c): `putenv` propagation (feeds Q3)

`(putenv "CHEZ_LIBUV_DNS_SPIKE" "q1-propagation-sentinel")` and
`(putenv "UV_THREADPOOL_SIZE" "4")` were issued before any threadpool touch;
`uv_os_getenv` — libuv's own environment reader — returned both values
exactly. Chez's `putenv` writes the same process environment libuv reads, in
time for the pool's single read at first `uv__work_submit`
(`vendor/libuv/src/threadpool.c:194-217`). `"4"` is the documented default,
so this run's own pool behavior was untouched; the value-level readback is
the check, and Q3's pinned mode is where the variable is set to a
non-default value.

### Deliberately untested, and why

- **Concurrent workers under GC pressure.** The engine is sequential by
  design — each resubmission happens inside the previous completion, so at
  most one worker is in flight at any instant. Q3 runs five requests
  concurrently ×1000 trials (without per-fire collects); the two axes are
  kept apart so a failure would be attributable, the same reasoning v0.1
  used for `__collect_safe`.
- **`__collect_safe` × callback re-entry** remains the open question v0.1
  recorded. `uv_run` is bound plain here too; nothing in v0.2 changes that
  scope.
- **The NSS/dlopen resolver path.** Workers here run pure-libc numeric
  formatting (ADR-0013's whole point). Nothing about non-numeric lookups —
  their latency, their NSS module loading, their memory — is exercised
  anywhere in this spike, deliberately.

### PENDING CI (Linux): Q1 ubuntu leg

Not run — nothing to record. The design spec requires one run per CI OS
(workers × signal masks is per-OS). The CI leg must: run
`spike/dns/probe-dns` on the runner and substitute its printed values for
the Darwin constants block in `04-threadpool-gc.ss` (at minimum
`AI_NUMERICHOST`, `AI_NUMERICSERV`, `AF_INET6`, and all `OFFSETOF_*` /
`SIZEOF_*` values — glibc reverses `ai_canonname`/`ai_addr` and shifts
`sin_family` to a two-byte field at offset 0, so the Darwin numbers are
known-wrong there); then run the script twice at 10,000 against the CI
libuv `.so` and paste both stdouts and exit codes here.

**Q1 verdict (macOS leg): PASS.** The ubuntu leg gates the final verdict.

---

## Q2 — valgrind's and ASan's view of unjoined threadpool workers

libuv never joins its worker threads; their stacks and pthread TLS are alive
at process exit. The design's memory-gate posture (spec §8, §9) predicts:
still-reachable-or-possibly-lost under valgrind — **outside** the
`--errors-for-leak-kinds=definite` gate — and invisible to the macOS ASan
arm, which makes no leak claim at all (`detect_leaks=0`; LeakSanitizer is
unsupported on arm64 macOS — ADR-0003). Q2 is the evidence that this is
measurement, not hope. **Only the macOS arm exists in this document.**

### macOS ASan arm (the `test-memory` recipe, adapted verbatim)

The Makefile's macOS arm resolves the ASan runtime dylib first and refuses
to run un-sanitized if the glob misses. Adapted for the spike script (the
suite loop replaced by the one script, target reduced to 100 per the design
spec):

**Commands run (verbatim):**

```bash
asan="$(command ls "$(dirname "$(xcrun --find clang)")"/../lib/clang/*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib 2>/dev/null | head -1)"
# resolved to:
# /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/../lib/clang/21.0.0/lib/darwin/libclang_rt.asan_osx_dynamic.dylib
DYLD_INSERT_LIBRARIES="$asan" ASAN_OPTIONS=detect_leaks=0 MallocNanoZone=0 \
  chez --script spike/dns/04-threadpool-gc.ss \
  /opt/homebrew/opt/libuv/lib/libuv.dylib 100
```

Run twice. **Exit `0` both times.** stdout was **byte-identical across the
two ASan runs** — and additionally byte-identical to an un-sanitized run at
the same target (`cmp` agreed), i.e. the transcript is the Q1 output with
`100` in place of `10000` in the three target-bearing lines, every check
`OK`, `RESULT: PASS`. stderr carried only the per-run trampoline addresses
(as in Q1) and **no ASan report of any kind** — no ERROR, no SUMMARY, no
interceptor complaint. Verbatim, both runs' stderr in full:

```
addresses: getaddrinfo 10BFAECC0 -> 10BFAECC0 ; getnameinfo 10BFAF600 -> 10BFAF600
```

```
addresses: getaddrinfo 10D83ECC0 -> 10D83ECC0 ; getnameinfo 10D83F600 -> 10D83F600
```

**The sanitizer was proven live, not assumed** — the Makefile names the
failure mode where an empty `DYLD_INSERT_LIBRARIES` runs every test
un-sanitized and green. Witness run (same invocation plus `verbosity=1`,
target 5), first stderr line, verbatim:

```
==72314==AddressSanitizer: libc interceptors initialized
```

So: with addressability checking fully live across 100 threadpool
completions (chain copy-out after `uv_freeaddrinfo` would be a heap-use-
after-free; the req free/resubmit cycle would trip any double-free), ASan
found nothing to report. **No leak claim is made or possible on this arm.**

### PENDING CI (Linux): the valgrind question — the whole of it

Not run; valgrind does not exist on this Darwin/arm64 machine, and no
valgrind output appears anywhere in this document. The CI spike branch must
run the *exact* `test-memory` Linux invocation shape against
`04-threadpool-gc.ss` (reduced target), i.e.:

```bash
UV_USE_IO_URING=0 CHEZ_LIBUV_UNDER_VALGRIND=1 \
valgrind --error-exitcode=9 --leak-check=full --show-leak-kinds=definite \
  --errors-for-leak-kinds=definite --undef-value-errors=no \
  chez --script spike/dns/04-threadpool-gc.ss <ci-libuv.so> 100
```

Exit criteria (design spec §10): exit 0 under the definite-only gate,
**twice**; every definite block in the log attributed (glibc-internal vs
ours) before the ADRs flip; the suppression decision — targeted file or
none — made there, in the spike, not in red CI. The §8 prediction to
check against the log: worker stacks/TLS/nss classify as still-reachable
or possibly-lost, never definite.

**Q2 verdict: macOS arm PASS; no overall verdict until the valgrind leg
runs.**

---

## Q3 — the cancel race histogram

**Script:** `spike/dns/05-cancel-race.ss`.

Per trial: submit four blocker getaddrinfo requests, then a tail request,
then `uv_cancel(tail)` **in the same turn** (the loop has not run between
submit and cancel), then one blocking `uv_run(UV_RUN_DEFAULT)` to
quiescence. Recorded per trial: the pair `(uv_cancel rc, tail callback
status)`, and the branch invariant — **every one of the five requests'
callbacks fired exactly once**, tracked per request pointer, not in
aggregate. 1000 trials per mode. `pinned` mode issues
`(putenv "UV_THREADPOOL_SIZE" "1")` before any threadpool touch;
`default-control` leaves the pool at its default. The two modes are separate
processes because the pool is process-global and latches its size at the
first submit.

The two legal branches, per the pinned source (spec §7,
`vendor/libuv/src/threadpool.c:399-441`,
`vendor/libuv/src/unix/getaddrinfo.c:128-133`):
`(0 . EAI_CANCELED)` — cancelled while queued, callback fires with the
rewritten code; `(EBUSY . 0)` — already running or done, callback delivers
the normal result. Anything else fails the run.

**Commands run (verbatim), each twice:**

```bash
chez --script spike/dns/05-cancel-race.ss /opt/homebrew/opt/libuv/lib/libuv.dylib pinned
chez --script spike/dns/05-cancel-race.ss /opt/homebrew/opt/libuv/lib/libuv.dylib default-control
```

### `pinned` — exit `0` both runs; stdout **byte-identical across the two runs**:

```
mode                              = pinned
uv_os_getenv(UV_THREADPOOL_SIZE)  = "1"
trials                            = 1000
uv_loop_init                      = 0

histogram (cancel-rc . tail-status) — counts are the measured race:
  (0 . EAI_CANCELED) = 1000

cancelled branch (0 . EAI_CANCELED) trials = 1000
completed branch (EBUSY . 0) trials        = 0
trials in any OTHER branch                 = 0
exactly-one-callback violations            = 0
first violation                            = none
submit failures                            = 0
cancelled branch dominates?                = #t
uv_loop_alive after trials                 = 0
uv_loop_close                              = 0
post-teardown collect done

--- checks ---
every trial in a legal branch: expected=0 actual=0 OK
exactly-one-callback held: expected=0 actual=0 OK
first violation sentinel: expected=none actual=none OK
no submit failures: expected=0 actual=0 OK
trials accounted for: expected=1000 actual=1000 OK
cancelled branch dominates (pinned): expected=#t actual=#t OK
loop alive after trials: expected=0 actual=0 OK
uv_loop_close rc: expected=0 actual=0 OK

RESULT: PASS
```

The byte-identity here is the degenerate histogram: at pool 1 the cancelled
branch won **all 1000 trials in both runs**. With one worker and four
blockers queued ahead of it, the tail
cannot start before a same-turn cancel lands; the race has a heavy favorite.

### `default-control` — exit `0` both runs; the two runs' stdouts were byte-identical **by coincidence**, and the coincidence is named

Run 1 and run 2 both printed:

```
mode                              = default-control
uv_os_getenv(UV_THREADPOOL_SIZE)  = "ENOENT"
trials                            = 1000
uv_loop_init                      = 0

histogram (cancel-rc . tail-status) — counts are the measured race:
  (0 . EAI_CANCELED) = 996
  (EBUSY . 0) = 4

cancelled branch (0 . EAI_CANCELED) trials = 996
completed branch (EBUSY . 0) trials        = 4
trials in any OTHER branch                 = 0
exactly-one-callback violations            = 0
first violation                            = none
submit failures                            = 0
cancelled branch dominates?                = #t
uv_loop_alive after trials                 = 0
uv_loop_close                              = 0
post-teardown collect done

--- checks ---
every trial in a legal branch: expected=0 actual=0 OK
exactly-one-callback held: expected=0 actual=0 OK
first violation sentinel: expected=none actual=none OK
no submit failures: expected=0 actual=0 OK
trials accounted for: expected=1000 actual=1000 OK
loop alive after trials: expected=0 actual=0 OK
uv_loop_close rc: expected=0 actual=0 OK

RESULT: PASS
```

Two runs of a measured race landing on identical counts (996/4 twice) looked
suspicious enough to check rather than celebrate: the output depends only on
the branch **totals** (the histogram is sorted, per-trial order is not
printed), and a third run —

```bash
chez --script spike/dns/05-cancel-race.ss /opt/homebrew/opt/libuv/lib/libuv.dylib default-control
```

— printed `(0 . EAI_CANCELED) = 993` / `(EBUSY . 0) = 7`, exit 0, all
checks OK. So the counts are genuinely a race (the run-to-run difference is
the EBUSY total: 4, 4, 7), and the run-1/run-2 identity was equal totals by
chance, not determinism. `ENOENT` on the readback line is `uv_os_getenv`'s
answer for an unset variable — the control mode's precondition, printed as
evidence rather than assumed.

### What Q3 establishes

1. **Exactly-one-callback held in every recorded trial**: (2 pinned + 2
   control) × 1000 trials × 5 requests = 20,000 callbacks (plus the third
   control run's 5,000), zero violations, tracked per request pointer with
   a `'never-fired` sentinel no callback path produces.
2. **Both branches occur, and only those branches.** Every recorded trial
   landed in `(0 . EAI_CANCELED)` or `(EBUSY . 0)` — no third pairing, in
   particular never `(0 . 0)` (a cancel that "succeeded" but delivered a
   result) and never `(EBUSY . EAI_CANCELED)`. This is the exact
   boolean-vocabulary contract the design's `uv-cancel!` builds on.
3. **The cancelled branch dominates at pool 1 — totally.** 1000/1000, twice.
   The design's exit criterion ("the cancelled branch dominates at pool 1")
   is met with margin; **the recorded fallback (32 blockers at default
   pool) is not needed.**
4. **Pool pinning propagated**: the pinned process read back
   `UV_THREADPOOL_SIZE = "1"` through libuv's own reader before the first
   submit (with Q1's observation (c) establishing the putenv→getenv path
   independently).

### What this does NOT show

- **No direct observation of the worker count.** The evidence that the pool
  really ran with one thread is the value-level readback plus libuv's
  documented single read of the variable (`threadpool.c:194-217`) — not a
  thread enumeration. The histogram difference between modes (0 vs a
  handful of EBUSY per 1000) points the right way but is weak, because:
- **A same-turn cancel wins the race at either pool size on this machine.**
  The four "blockers" are microsecond-fast numeric lookups; the cancel lands
  before the workers wake often enough that even the default pool shows
  ~99.5% cancelled. The blockers never truly *blocked* a worker — they
  occupied the queue, which is all the same-turn cancel needs. A suite
  wanting the **completed** branch deterministically must not rely on
  submit-then-cancel timing; the design's cancel-after-completion row
  (cancel answering `#f` with no native call) is the reliable way to that
  branch, and the tolerant branch-invariant test is exactly what this
  histogram licenses.

**Q3 verdict: PASS.** (Dev-machine question per the design spec's venue —
no CI leg required for Q3.)

---

## Q4 — the hermetic determinism matrix

**Script:** `spike/dns/06-hermetic-matrix.ss`.

One line per case, deterministic format, so two runs diff cleanly and the
macOS and glibc legs can be compared cell by cell. Asserted: only the
cells ADR-0013 claims are deterministic on every platform (numeric literals
resolve to themselves; `AI_NUMERICHOST` + non-numeric → `EAI_NONAME`;
`AF_UNSPEC` + literal → single family; numeric reverse formats exactly).
Measured-but-not-asserted: the per-OS unpinned-socktype chain shape, so the
same script runs unmodified on the glibc leg and the cross-OS differences
are enumerated by diffing outputs.

**Command run (verbatim), twice:**

```bash
chez --script spike/dns/06-hermetic-matrix.ss /opt/homebrew/opt/libuv/lib/libuv.dylib
```

**Actual observed output** (verbatim; **byte-identical across two runs**,
exit `0` both times, stderr empty both times):

```
uv_loop_init = 0
scope interface for s-rows = "lo0"

== forward lookups (uv_getaddrinfo) ==
case f1: node="127.0.0.1" service="80" family=unspec socktype=stream flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 1   families = (inet)
    [0] family=inet socktype=stream proto=6 addr="127.0.0.1" port=80 scope=n/a
case f2: node="::1" service="80" family=unspec socktype=stream flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 1   families = (inet6)
    [0] family=inet6 socktype=stream proto=6 addr="::1" port=80 scope=0
case f3: node="chez-libuv-not-numeric.invalid" service="80" family=unspec socktype=stream flags=numerichost|numericserv
  submit rc = 0   status = EAI_NONAME   fired = 1
  entries = ()
case f4: node="127.0.0.1" service="80" family=unspec socktype=unpinned flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 2   families = (inet)
    [0] family=inet socktype=dgram proto=17 addr="127.0.0.1" port=80 scope=n/a
    [1] family=inet socktype=stream proto=6 addr="127.0.0.1" port=80 scope=n/a
case f5: node="::1" service="80" family=unspec socktype=unpinned flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 2   families = (inet6)
    [0] family=inet6 socktype=dgram proto=17 addr="::1" port=80 scope=0
    [1] family=inet6 socktype=stream proto=6 addr="::1" port=80 scope=0

== reverse lookups (uv_getnameinfo, NI_NUMERICHOST|NI_NUMERICSERV) ==
case r1 (127.0.0.1:80): flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  host = "127.0.0.1"   service = "80"
case r2 (::1:443): flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  host = "::1"   service = "443"

== scoped literal (ADR-0012 documented-drop row) ==
case s1: node="fe80::1%lo0" service="80" family=unspec socktype=stream flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 1   families = (inet6)
    [0] family=inet6 socktype=stream proto=6 addr="fe80::1" port=80 scope=1
case s2: uv_ip6_addr("fe80::1%lo0") rc = 0   sin6_scope_id = 1   uv_ip_name -> "fe80::1"
case s3: uv_ip6_addr("fe80::1") rc = 0   sin6_scope_id = 0   uv_ip_name -> "fe80::1"

uv_loop_close = 0

--- checks ---
every case fired exactly once: expected=0 actual=0 OK
f1 status: expected=0 actual=0 OK
f1 single entry: expected=1 actual=1 OK
f1 entries all inet 127.0.0.1:80: expected=#t actual=#t OK
f2 status: expected=0 actual=0 OK
f2 single entry: expected=1 actual=1 OK
f2 entries all inet6 ::1:80: expected=#t actual=#t OK
f3 errno symbol: expected="EAI_NONAME" actual="EAI_NONAME" OK
f3 empty chain: expected=() actual=() OK
f4 status: expected=0 actual=0 OK
f4 nonempty, single family (unspec + v4 literal): expected=#t actual=#t OK
f5 status: expected=0 actual=0 OK
f5 nonempty, single family (unspec + v6 literal): expected=#t actual=#t OK
r1 host: expected="127.0.0.1" actual="127.0.0.1" OK
r1 service: expected="80" actual="80" OK
r2 host: expected="::1" actual="::1" OK
r2 service: expected="443" actual="443" OK
sa4/sa6 fills: expected=(0 0) actual=(0 0) OK
s2 scoped literal parses inbound: expected=0 actual=0 OK
s2 scope id nonzero inbound: expected=#t actual=#t OK
s2 render drops the zone: expected="fe80::1" actual="fe80::1" OK
s3 descoped round-trip scope: expected=0 actual=0 OK
s3 render: expected="fe80::1" actual="fe80::1" OK
uv_loop_close rc: expected=0 actual=0 OK

RESULT: PASS
```

### What Q4 establishes (macOS cells)

1. **Every cell identical across two runs** — the §10 exit criterion for
   this OS. All the resolver interactions (five forward, two reverse, plus
   s1–s3) produced byte-identical output, with zero network touched.
2. **The Darwin unpinned-socktype chain shape is now measured, not
   predicted: 2 entries, dgram first, no raw** (f4 and f5, both families;
   dgram carries proto 17/UDP, stream 6/TCP). This is exactly the §9
   expectation, and it settles the suite's assertion style: the dgram-FIRST
   order is real on Darwin, so the multi-entry rows must be
   **set-containment, never order**, or the suite is wrong the day glibc's
   3-entry order differs.
3. **`AI_NUMERICHOST` + non-numeric answers `EAI_NONAME` with an empty
   chain, asynchronously** (submit 0, status `EAI_NONAME`, `entries = ()`)
   — the deterministic offline failure ADR-0013's banned-`localhost` policy
   substitutes in, and the errno arrives by name through `uv_err_name`
   with no integer transcription anywhere.
4. **`AF_UNSPEC` + a literal yields a single family** — f1/f4 chains are
   all-inet, f2/f5 all-inet6, ports all 80, addresses exactly the input
   literal rendered back by `uv_ip_name`.
5. **The numeric reverse lookups format exactly**: `"127.0.0.1"`/`"80"` and
   `"::1"`/`"443"`, through the 4-argument getnameinfo trampoline, with the
   `never-fired` sentinels replaced on the one and only fire.
6. **The ADR-0012 scoped-literal evidence, end to end.** The surprise worth
   naming: `getaddrinfo` under `AI_NUMERICHOST` **accepts** a zoned literal
   — s1 resolved `"fe80::1%lo0"` with `sin6_scope_id = 1` in the returned
   sockaddr — and the chain walk's `uv_ip_name` render then reads back
   `"fe80::1"`, scope silently gone. s2 shows the same inbound-keeps /
   outbound-drops asymmetry at the `uv_ip6_addr` level, and s3 completes
   the documented hazard: re-parsing the de-scoped string builds
   `sin6_scope_id = 0` — a plausible, wrong destination. ADR-0012's
   "documented drop" text now cites measured output, including the fact
   that a scoped input can arrive through the *resolver*, not just through
   a caller's literal.

### What this does NOT show

- No non-numeric **success** path, no canonname row, no named services —
  the accepted cost ADR-0013 records; nothing here exercises NSS.
- The chain-shape cells are one OS's answer. The set-containment rule is
  justified by the Darwin order alone, but the glibc cells (3 entries
  including raw, per §9's expectation) are unmeasured until the CI leg runs.

### PENDING CI (Linux): Q4 glibc leg

Not run — nothing to record. The CI leg must: run `spike/dns/probe-dns` on
the runner and substitute its values for the Darwin constants block in
`06-hermetic-matrix.ss` (the script's header names the groups known to
differ: `AF_INET6`, the `AI_*` flag values, and the
`addrinfo`/`sockaddr_in6` offsets); invoke with the runner's loopback
interface name for the s-rows:

```bash
chez --script spike/dns/06-hermetic-matrix.ss <ci-libuv.so> lo
```

twice; paste both outputs; and enumerate every cell that differs from the
macOS output above (expected differences, to be confirmed or refuted there:
3-entry unpinned chains including a raw entry, and possibly a different
entry order). Cells the script asserts (f1–f3 shapes, r1/r2 strings, s2/s3
invariants) must hold identically or the run exits 1.

**Q4 verdict (macOS leg): PASS.** The glibc leg gates the final verdict.

---

## Consequences for the plan

What the implementation stages should absorb from the macOS legs (the CI
legs may add to this list; they should not subtract from it):

1. **`run-until/ticking` for every DNS wait is confirmed necessary in the
   measured sense**: a pending getaddrinfo leaves `uv_run 'once` parked in
   the poll until the completion posts (NOWAIT returns first, without
   delivering). A suite that calls a bare `'once` around DNS inherits the
   pool's timing; the ticking pattern keeps every wait iteration-capped.
2. **§4.1's NUL refusal guards a measured behavior**:
   `"127.0.0.1\x0;.evil"` resolves as its prefix today, silently. The
   refusal clause is load-bearing, and the spike output is its citation.
3. **`#f` → NULL is real** (and distinguishable from `""` — which fails
   synchronously with `EINVAL` via idna, the `abandon-request!` path's
   trigger, also now measured). The `string` FFI type transcodes to UTF-8.
   Production may pass `node`/`service` as Chez `string` args exactly as
   §4.1 plans.
4. **The two new trampoline shapes behave like the eight old ones**: locked
   entry points immobile across ~10,000 collections, exact delivery counts,
   clean teardown. The ADR-0008 amendment's premise holds on this platform.
5. **The cancel vocabulary is exactly two branches**, `(0 . EAI_CANCELED)`
   and `(EBUSY . 0)`, with exactly-one-callback in 25,000 observed
   callbacks. The tolerant branch-invariant cancel test is licensed; the
   32-blocker fallback stays unused. A test that *needs* the completed
   branch must construct it (cancel-after-completion), not race for it.
6. **Pool pinning via suite-prologue `putenv` is confirmed at the value
   level** through libuv's own reader, both as a sentinel variable and as
   `UV_THREADPOOL_SIZE` itself. The design's pinned-prologue plus one
   throwaway drained lookup (to latch the size before any dependent test)
   stands.
7. **Darwin's unpinned chain is 2 entries dgram-first** — multi-entry
   assertions must be set-containment, never order or count equality
   across OSes.
8. **Scope IDs: measured drop, resolver-reachable.** A zoned literal can
   enter through getaddrinfo itself (s1), not just through `uv_ip6_addr`,
   and reads back de-scoped either way. ADR-0012's documentation clause
   should cite s1–s3.
9. **`uv_getnameinfo_t` is 1320 bytes because the result strings live
   inside it** — copy-before-free in the getnameinfo dispatcher is
   structural. (Probe fact, carried so nobody "optimizes" the copy away.)
10. **Runtime cost is a non-issue**: 10,000 lookup round-trips with a full
    `(collect)` each took 0.18 s. The spec's 10k target stays as written.
