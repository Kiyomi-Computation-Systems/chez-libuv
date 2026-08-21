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

**This document now carries both legs.** The macOS legs were run first, on a
Darwin/arm64 dev machine that has no valgrind. The Linux legs (Q1 ubuntu run,
the whole of Q2's valgrind question, Q4's glibc run) were run second, in CI —
GitHub Actions run **32491363796**, workflow **"DNS spike (Linux legs)
[TEMPORARY]"**, job "dns spike (ubuntu, Q1/Q2/Q4 Linux legs)", runner
**ubuntu-24.04 (`ubuntu-latest`), x86_64**, conclusion **success**. Every
number quoted in the Linux subsections below is copied verbatim from that
run's log.

## Toolchain

### macOS leg (dev machine)

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

### Linux leg (CI)

| Item | Value | How determined |
|---|---|---|
| CI run | 32491363796, workflow "DNS spike (Linux legs) [TEMPORARY]" | GitHub Actions run log |
| Job | "dns spike (ubuntu, Q1/Q2/Q4 Linux legs)" | run log |
| Runner | `ubuntu-latest` = Ubuntu 24.04.4 LTS, image `ubuntu-24.04` (20260816.277.1), x86_64 | run log job-setup groups |
| Chez Scheme | 10.4.1 | `$CHEZ --version` (`echo "chez: $($CHEZ --version 2>&1)"`) |
| libuv | 1.48.0 (`apt` `libuv1-dev` 1.48.0-1.1build1) | `pkg-config --modversion libuv` |
| libuv shared object | `/usr/lib/x86_64-linux-gnu/libuv.so` | `pkg-config --variable=libdir libuv` |
| C compiler | `cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` | `cc --version \| head -1` |
| valgrind | valgrind-3.22.0 | `valgrind --version` |
| Arch | x86_64 | runner image |

## Summary of verdicts

| Q | Verdict |
|---|---|
| Q1 — threadpool × GC × re-entrancy × loop-liveness | **PASS (overall, both legs).** macOS: 10,000/10,000 threadpool completions delivered into a locked callable, `(collect)` + result verification + resubmission on every fire, exit 0 twice, stdout byte-identical. ubuntu (CI run 32491363796): 10,000/10,000 both runs, exit 0 both runs, stdout byte-identical **outside** the three probe-a race lines — the CI's own gated diff (race lines excluded) was empty. The race lines differ *by which legal branch of the NOWAIT/pending race each run measured*, not by defect; see the ubuntu subsection. |
| Q2 — sanitizers' view of unjoined workers | **PASS (overall, both legs).** macOS ASan arm: exit 0 twice, no reports, sanitizer proven live; no leak claim — LeakSanitizer is unsupported on arm64 macOS (ADR-0003). Linux valgrind (CI run 32491363796): exit 0 both runs under `--error-exitcode=9` with the definite-only gate; LEAK SUMMARY identical both runs — definitely/indirectly/possibly lost all 0, still reachable 1,913 bytes in 6 blocks, suppressed 0; ERROR SUMMARY 0 errors both runs. The §8 prediction held as measurement; no suppression file is needed, and that is the suppression decision. |
| Q3 — cancel race histogram | **PASS.** Both branches observed, every trial in a legal branch, exactly-one-callback held in all recorded trials. Cancelled branch dominates at pool 1 (1000/1000, twice) **and** at the default pool (996/4 twice, 993/7 in a third run). The tolerant cancel test is licensed; the 32-blocker fallback is not needed. |
| Q4 — hermetic determinism matrix | **PASS (overall, both legs).** macOS: every cell byte-identical across two runs; Darwin unpinned chain measured: 2 entries, dgram-first, no raw — §9's prediction confirmed. glibc (CI run 32491363796): every cell byte-identical across two runs (in-job `diff` empty); unpinned chain measured: 3 entries, **stream-first**, **includes a `raw` entry** — confirming §9's "possibly a different order" prediction and the 3-entry-incl.-raw prediction exactly. Scoped-literal rows measured end-to-end on both OSes for ADR-0012. |

**Spike exit reached 2026-08-21.** All four questions have run on both
required legs (Q3 is dev-machine-only by the design spec's own venue rule);
this document records the full evidence, and the DNS ADRs (0011, 0012, 0013,
and the ADR-0008 amendment) are flipped to Accepted on it.

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
runs**, exit `0` both times; wall time `real 0.18` both runs). *Revisited
after the ubuntu leg (below): the ubuntu leg's two runs landed on the two
different legal branches of the same probe-a race and printed different
`uv_run(NOWAIT)`/`'once`/`uv_run(ONCE)` lines for it, which proves those
three lines are race-dependent, not deterministic — so this macOS pair's
identical probe-a block was this machine happening to land on the same
branch twice, not evidence of determinism. The macOS transcript below is
unaltered; this note only revises what the byte-identity is evidence of.*

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

### Linux (ubuntu) leg — CI run 32491363796

**Constants substitution (before either run).** The CI job built and ran
`spike/dns/probe-dns` on the runner (glibc/x86_64, libuv 1.48.0), then ran
`spike/dns/apply-probe-constants.sh` against `04-threadpool-gc.ss` and
`06-hermetic-matrix.ss` to substitute the runner's own probe values for the
Darwin constants block — never a transcribed or remembered number
(ADR-0005's rule, applied to the spike). The job's own `git diff --stat`
after the rewrite, verbatim:

```
=== git diff --stat spike/dns/ (post-rewrite; shows what changed on the runner) ===
 spike/dns/04-threadpool-gc.ss   | 10 +++++-----
 spike/dns/06-hermetic-matrix.ss | 10 +++++-----
 2 files changed, 10 insertions(+), 10 deletions(-)
```

The glibc probe values that went into that substitution (from the same job's
`./spike/dns/probe-dns` step; the layout-defining ones the design spec
flagged as known-different from Darwin): `AF_INET6 = 10` (Darwin: 30),
`AI_NUMERICSERV = 1024` (Darwin: 4096), `NI_NUMERICHOST = 1` /
`NI_NUMERICSERV = 2` / `NI_NAMEREQD = 8` (Darwin: 2 / 8 / 4),
`offsetof(struct addrinfo, ai_canonname) = 32`, `offsetof(struct addrinfo,
ai_addr) = 24` (Darwin: 24 and 32 — reversed, exactly as predicted),
`offsetof(struct sockaddr_in, sin_family) = 0` with
`sizeof(sin_family) = 2` (Darwin: offset 1, size 1),
`UV_ECANCELED = -125` (Darwin: -89 — both host-`errno`-derived, per ADR
context), `uv_loop_size() = 848` (Darwin: 1072), `uv_version_string() =
1.48.0` (Darwin: 1.52.1).

**Command run (verbatim, twice), from the job's own script step:**

```bash
$CHEZ --script spike/dns/04-threadpool-gc.ss "$LIBUV_SO" 10000 | tee /tmp/q1-run1.out
# rc1=${PIPESTATUS[0]}
$CHEZ --script spike/dns/04-threadpool-gc.ss "$LIBUV_SO" 10000 | tee /tmp/q1-run2.out
# rc2=${PIPESTATUS[0]}
```

with `$CHEZ` = `scheme` (10.4.1) and `$LIBUV_SO` =
`/usr/lib/x86_64-linux-gnu/libuv.so`. **Both runs exited 0**, `fire count
after uv_run = 10000` both times, every `--- checks ---` line `OK` both
times, `RESULT: PASS` both times — the full engine transcript (10,000-fire
section, marshalling probes (b), `putenv` propagation (c), the getnameinfo
arity check) is byte-identical to the macOS transcript above line-for-line
except for the three lines below and the (expected, ASLR-dependent)
trampoline addresses in stderr.

**Run 1's probe-a block** (§"uv_run modes with a request in flight"),
verbatim:

```
--- (a) uv_run modes with a request in flight ---
submit rc                     = 0
uv_run(NOWAIT) immediately    = 0 (callback fired by then: 1)
'once calls until delivery    = 0
uv_run(ONCE) rc at delivery   = not-run
probe-a callback fired        = 1
```

**Run 2's probe-a block**, verbatim:

```
--- (a) uv_run modes with a request in flight ---
submit rc                     = 0
uv_run(NOWAIT) immediately    = 1 (callback fired by then: 0)
'once calls until delivery    = 1
uv_run(ONCE) rc at delivery   = 0
probe-a callback fired        = 1
```

**The three differing lines** are `uv_run(NOWAIT) immediately`, `'once calls
until delivery`, and `uv_run(ONCE) rc at delivery` — the job's own
`diff /tmp/q1-run1.out /tmp/q1-run2.out` names exactly these three (`14,16c14,16`)
and nothing else. **This is the important finding**: run 1 and run 2 landed
on the two *different legal branches* of the same probe-a race, not on a
defect. In run 1, `uv_run(NOWAIT)` returned `0` (loop not alive) with
`callback fired by then: 1` — the getaddrinfo completion had already been
posted and delivered by the time NOWAIT ran, so there was nothing left to
wait for, and the follow-up `'once` was never called (`not-run`). In run 2,
`uv_run(NOWAIT)` returned `1` (loop still alive) with `callback fired by
then: 0` — the completion was still pending — and the follow-up
`uv_run(ONCE)` then blocked until delivery, returning `0` after exactly one
call. Both are legal, mutually exclusive outcomes of the same race between
the threadpool worker posting `wq_async` and the loop thread reaching
`uv_run(NOWAIT)`; libuv gives no guarantee of which wins. The CI job proves
this explicitly: it computes a **gated diff** with those exact three lines
filtered out —

```
filter='uv_run\(NOWAIT\) immediately|'\''once calls until delivery|uv_run\(ONCE\) rc at delivery'
grep -Ev "$filter" /tmp/q1-run1.out > /tmp/q1-run1.filtered
grep -Ev "$filter" /tmp/q1-run2.out > /tmp/q1-run2.filtered
diff /tmp/q1-run1.filtered /tmp/q1-run2.filtered
```

— and that gated diff's output was **empty**: `Q1: exit 0 both runs, stdout
identical outside the probe-a race lines`. So stdout was byte-identical
**outside** the three race lines, and the three race lines are exactly the
ones the design predicted could legally vary.

**Consequence for the plan, made explicit by this measurement**: a DNS test
suite must never assert *which* legal branch a bare `uv_run(NOWAIT)` (or the
`'once` that follows a pending completion) takes immediately after a DNS
submit — both branches are observed on the same OS, same binary, same CI
runner, back-to-back. Only `run-until/ticking`'s tolerant wait (already the
house rule per the macOS-leg "What Q1 establishes" §3 above) is licensed;
a test hard-coding either branch's outcome is flaky by construction, not by
accident.

**Q1 verdict: overall PASS.** Both OS legs: exit 0 both runs, 10,000/10,000
fire count both runs, every check `OK`, stdout identical outside the
race-dependent probe-a lines (gated diff empty on the ubuntu leg; the
macOS leg's own two runs happened to land on the same branch twice, see the
revisit note above).

---

## Q2 — valgrind's and ASan's view of unjoined threadpool workers

libuv never joins its worker threads; their stacks and pthread TLS are alive
at process exit. The design's memory-gate posture (spec §8, §9) predicts:
still-reachable-or-possibly-lost under valgrind — **outside** the
`--errors-for-leak-kinds=definite` gate — and invisible to the macOS ASan
arm, which makes no leak claim at all (`detect_leaks=0`; LeakSanitizer is
unsupported on arm64 macOS — ADR-0003). Q2 is the evidence that this is
measurement, not hope. Both the macOS ASan arm and the Linux valgrind leg
are recorded below.

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

### Linux valgrind leg — CI run 32491363796

valgrind does not exist on the Darwin/arm64 dev machine, so this question
runs only on the ubuntu leg. The CI job ran the *exact* `test-memory` Linux
invocation shape against `04-threadpool-gc.ss` (reduced target 100), twice.
**Command run (verbatim, from the job's own script step)**, `$CHEZ` =
`scheme` (10.4.1), `$LIBUV_SO` = `/usr/lib/x86_64-linux-gnu/libuv.so`:

```bash
UV_USE_IO_URING=0 CHEZ_LIBUV_UNDER_VALGRIND=1 \
  valgrind --error-exitcode=9 --leak-check=full --show-leak-kinds=definite \
    --errors-for-leak-kinds=definite --undef-value-errors=no \
    $CHEZ --script spike/dns/04-threadpool-gc.ss "$LIBUV_SO" 100
```

Both runs' `04-threadpool-gc.ss` transcripts (under valgrind, target 100)
matched the un-instrumented ubuntu-leg transcript: `fire count after uv_run
= 100`, every check `OK`, `RESULT: PASS`, both times. valgrind's own
`Command:` line confirms the exact invocation instrumented, run 1:
`==2953== Command: scheme --script spike/dns/04-threadpool-gc.ss
/usr/lib/x86_64-linux-gnu/libuv.so 100`.

**Run 1 — HEAP SUMMARY / LEAK SUMMARY / ERROR SUMMARY**, verbatim:

```
==2953== HEAP SUMMARY:
==2953==     in use at exit: 1,913 bytes in 6 blocks
==2953==   total heap usage: 834 allocs, 828 frees, 162,044 bytes allocated
==2953==
==2953== LEAK SUMMARY:
==2953==    definitely lost: 0 bytes in 0 blocks
==2953==    indirectly lost: 0 bytes in 0 blocks
==2953==      possibly lost: 0 bytes in 0 blocks
==2953==    still reachable: 1,913 bytes in 6 blocks
==2953==         suppressed: 0 bytes in 0 blocks
==2953== Reachable blocks (those to which a pointer was found) are not shown.
==2953== To see them, rerun with: --leak-check=full --show-leak-kinds=all
==2953==
==2953== For lists of detected and suppressed errors, rerun with: -s
==2953== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)
```

Exit code: `0` (`=== end Q2 run 1 (exit 0) ===`).

**Run 2 — HEAP SUMMARY / LEAK SUMMARY / ERROR SUMMARY**, verbatim:

```
==2958== HEAP SUMMARY:
==2958==     in use at exit: 1,913 bytes in 6 blocks
==2958==   total heap usage: 834 allocs, 828 frees, 162,044 bytes allocated
==2958==
==2958== LEAK SUMMARY:
==2958==    definitely lost: 0 bytes in 0 blocks
==2958==    indirectly lost: 0 bytes in 0 blocks
==2958==      possibly lost: 0 bytes in 0 blocks
==2958==    still reachable: 1,913 bytes in 6 blocks
==2958==         suppressed: 0 bytes in 0 blocks
==2958== Reachable blocks (those to which a pointer was found) are not shown.
==2958== To see them, rerun with: --leak-check=full --show-leak-kinds=all
==2958==
==2958== For lists of detected and suppressed errors, rerun with: -s
==2958== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)
```

Exit code: `0` (`=== end Q2 run 2 (exit 0) ===`). The job's own gate agreed:
`Q2: exit 0 both valgrind runs`.

**The two runs' LEAK SUMMARY and ERROR SUMMARY blocks are identical**:
`1,913 bytes in 6 blocks` still-reachable, `0` everywhere else (definite,
indirect, possible, suppressed), `0 errors from 0 contexts` both times —
only the valgrind PID prefix (`==2953==` vs `==2958==`) differs, which is
process-identity noise, not data.

**No per-block record appears in the log for the worker stacks/TLS.** The
invocation used `--show-leak-kinds=definite` (the `test-memory` gate's own
shape), and valgrind's own text says why nothing is itemized: "Reachable
blocks (those to which a pointer was found) are not shown. To see them,
rerun with: --leak-check=full --show-leak-kinds=all." So the log has no
per-allocation attribution of the 1,913 still-reachable bytes to worker
stacks vs pthread TLS vs anything else — only the aggregate LEAK SUMMARY
line. This document records that absence rather than inventing an
attribution: the measurement is that the 1,913 bytes sit entirely in the
still-reachable bucket, outside the `--errors-for-leak-kinds=definite`
gate, on both runs, which is exactly what the definite-only gate is built to
tolerate.

**Outcome.** The §8 prediction (worker stacks/TLS classify as
still-reachable, never definite or possible) held **as measurement, not
hope**: `definitely lost = 0` and `possibly lost = 0` both runs, with the
entire non-zero total sitting in `still reachable`. Because nothing landed
in `definite` or `possible`, there is nothing to attribute or suppress:
**no valgrind suppression file is needed for the DNS suite, and that
absence is the suppression decision** — targeted-file-vs-none was decided
here, in the spike, as "none."

**Q2 verdict: overall PASS.** macOS ASan arm PASS (no leak claim possible on
that arm) plus Linux valgrind PASS (exit 0 both runs, definite/possible both
zero both runs, identical LEAK SUMMARY and ERROR SUMMARY) together satisfy
the design spec §10 exit criteria for Q2 in full.

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
- The chain-shape cells above are one OS's answer alone. The set-containment
  rule is justified by the Darwin order here; the glibc cells (3 entries
  including raw, per §9's expectation) are measured in the Linux (glibc) leg
  subsection below, not in this macOS-only section.

### Linux (glibc) leg — CI run 32491363796

**The runner's probe-dns output for the glibc layout numbers** — the values
`apply-probe-constants.sh` substituted into `06-hermetic-matrix.ss` before
either run — verbatim from the same job's `./spike/dns/probe-dns` step:

```
== struct addrinfo layout ==
sizeof(struct addrinfo)                48
offsetof(struct addrinfo, ai_flags)    0
offsetof(struct addrinfo, ai_family)   4
offsetof(struct addrinfo, ai_socktype) 8
offsetof(struct addrinfo, ai_protocol) 12
offsetof(struct addrinfo, ai_addrlen)  16
offsetof(struct addrinfo, ai_canonname) 32
offsetof(struct addrinfo, ai_addr)     24
offsetof(struct addrinfo, ai_next)     40

== address families ==
AF_UNSPEC                              0
AF_INET                                2
AF_INET6                               10
```

`ai_addr` at offset 24 sits **before** `ai_canonname` at offset 32 on
glibc — the reverse of Darwin's layout (`ai_canonname` 24, `ai_addr` 32,
Q-1 above), confirming the design spec §5.2 claim the shim exists to guard
against. `AF_INET6 = 10` on glibc vs `30` on Darwin, likewise substituted
mechanically, never transcribed.

**Post-rewrite `git diff --stat`** (same job step, covering both scripts the
substitution touched), verbatim:

```
=== git diff --stat spike/dns/ (post-rewrite; shows what changed on the runner) ===
 spike/dns/04-threadpool-gc.ss   | 10 +++++-----
 spike/dns/06-hermetic-matrix.ss | 10 +++++-----
 2 files changed, 10 insertions(+), 10 deletions(-)
```

**Command run (verbatim, twice)**, `$CHEZ` = `scheme` (10.4.1), `$LIBUV_SO`
= `/usr/lib/x86_64-linux-gnu/libuv.so`, invoked with the runner's own
loopback interface name:

```bash
$CHEZ --script spike/dns/06-hermetic-matrix.ss "$LIBUV_SO" lo | tee /tmp/q4-run1.out
$CHEZ --script spike/dns/06-hermetic-matrix.ss "$LIBUV_SO" lo | tee /tmp/q4-run2.out
diff /tmp/q4-run1.out /tmp/q4-run2.out
```

**Run 1 — full matrix output**, verbatim, exit `0`:

```
uv_loop_init = 0
scope interface for s-rows = "lo"

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
  entries = 3   families = (inet)
    [0] family=inet socktype=stream proto=6 addr="127.0.0.1" port=80 scope=n/a
    [1] family=inet socktype=dgram proto=17 addr="127.0.0.1" port=80 scope=n/a
    [2] family=inet socktype=raw proto=0 addr="127.0.0.1" port=80 scope=n/a
case f5: node="::1" service="80" family=unspec socktype=unpinned flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 3   families = (inet6)
    [0] family=inet6 socktype=stream proto=6 addr="::1" port=80 scope=0
    [1] family=inet6 socktype=dgram proto=17 addr="::1" port=80 scope=0
    [2] family=inet6 socktype=raw proto=0 addr="::1" port=80 scope=0

== reverse lookups (uv_getnameinfo, NI_NUMERICHOST|NI_NUMERICSERV) ==
case r1 (127.0.0.1:80): flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  host = "127.0.0.1"   service = "80"
case r2 (::1:443): flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  host = "::1"   service = "443"

== scoped literal (ADR-0012 documented-drop row) ==
case s1: node="fe80::1%lo" service="80" family=unspec socktype=stream flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 1   families = (inet6)
    [0] family=inet6 socktype=stream proto=6 addr="fe80::1" port=80 scope=1
case s2: uv_ip6_addr("fe80::1%lo") rc = 0   sin6_scope_id = 1   uv_ip_name -> "fe80::1"
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

**Run 2 — full matrix output**, verbatim, exit `0`:

```
uv_loop_init = 0
scope interface for s-rows = "lo"

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
  entries = 3   families = (inet)
    [0] family=inet socktype=stream proto=6 addr="127.0.0.1" port=80 scope=n/a
    [1] family=inet socktype=dgram proto=17 addr="127.0.0.1" port=80 scope=n/a
    [2] family=inet socktype=raw proto=0 addr="127.0.0.1" port=80 scope=n/a
case f5: node="::1" service="80" family=unspec socktype=unpinned flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 3   families = (inet6)
    [0] family=inet6 socktype=stream proto=6 addr="::1" port=80 scope=0
    [1] family=inet6 socktype=dgram proto=17 addr="::1" port=80 scope=0
    [2] family=inet6 socktype=raw proto=0 addr="::1" port=80 scope=0

== reverse lookups (uv_getnameinfo, NI_NUMERICHOST|NI_NUMERICSERV) ==
case r1 (127.0.0.1:80): flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  host = "127.0.0.1"   service = "80"
case r2 (::1:443): flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  host = "::1"   service = "443"

== scoped literal (ADR-0012 documented-drop row) ==
case s1: node="fe80::1%lo" service="80" family=unspec socktype=stream flags=numerichost|numericserv
  submit rc = 0   status = 0   fired = 1
  entries = 1   families = (inet6)
    [0] family=inet6 socktype=stream proto=6 addr="fe80::1" port=80 scope=1
case s2: uv_ip6_addr("fe80::1%lo") rc = 0   sin6_scope_id = 1   uv_ip_name -> "fe80::1"
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

The job's own `diff /tmp/q4-run1.out /tmp/q4-run2.out` produced **no
output** — byte-identical, confirmed by the in-job diff, not just eyeballed
here — and the job printed `Q4: exit 0 both runs, stdout byte-identical`.

**Every cell that differs from the macOS matrix, enumerated by case id**
(all other cases — f1, f2, f3, r1, r2, s1's family/socktype/proto/addr/port,
s2, s3 — are identical in value to the macOS transcript above; only the two
below differ, and only in the unpinned-socktype chain shape):

- **f4** (`node="127.0.0.1"`, `socktype=unpinned`): macOS has **2 entries**,
  `[0] dgram proto=17`, `[1] stream proto=6` (dgram first, no raw entry).
  glibc has **3 entries**, `[0] stream proto=6`, `[1] dgram proto=17`,
  `[2] raw proto=0` (stream first, **includes a raw entry** glibc's own
  chain adds). Three independent differences in one cell: entry count (2 vs
  3), leading member (dgram vs stream), and set membership (no-raw vs
  incl.-raw).
- **f5** (`node="::1"`, `socktype=unpinned`): the identical shape of
  difference, one family over — macOS **2 entries** (`[0] dgram`,
  `[1] stream`, no raw); glibc **3 entries** (`[0] stream`, `[1] dgram`,
  `[2] raw`).

Both differences confirm the design spec §9 prediction exactly as stated
there: "3-entry unpinned chains incl. raw, possibly different order." The
order is different (glibc leads with `stream`, Darwin with `dgram`), and
glibc's chain does include the `raw`/`proto=0` entry Darwin's omits. No
other cell in the matrix — f1/f2/f3's shapes, r1/r2's strings, s1's
scope-carrying resolve, s2/s3's inbound-parse/render invariants — differs
between the two OSes; those are exactly the cells ADR-0013 asserts as
equal-by-design (numeric literals, `AI_NUMERICHOST` failure mode,
`AF_UNSPEC` singling one family), and they held. (The `s1`/`s2` loopback
interface **name** is `"lo0"` on macOS vs `"lo"` on glibc — an expected,
intentional difference in the script's own invocation argument, not a
libuv/libc behavioral cell; the interfaces' numeric `sin6_scope_id`, `1` on
both runners, is not asserted equal by the script and happens to agree here
incidentally.)

This is exactly the evidence ADR-0013's set-containment rule was written
for: f4/f5 must be asserted as set-containment, never order or exact count,
because order and count are now measured to differ legitimately between the
two libcs the gating suites must run under.

**Q4 verdict: overall PASS.** Both OS legs: exit 0 both runs, every
asserted cell (f1–f3, r1–r2, s1–s3) `OK` on both runs, stdout byte-identical
within each OS (macOS gated by the plain `diff`, glibc gated by the in-job
`diff`), and the two OSes' unpinned-chain cells differ in exactly the way
§9 predicted before either leg ran.

---

## Consequences for the plan

What the implementation stages should absorb from the macOS legs, plus what
the Linux CI legs added on top (numbered 11–12 below; nothing the macOS legs
established was subtracted):

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
11. **A suite must never assert which branch a `uv_run(NOWAIT)` (or the
    `'once` that follows) takes immediately after a DNS submit.** The ubuntu
    CI leg's own two runs, same binary, same runner, back-to-back, landed on
    the two different legal outcomes of the probe-a race: run 1 measured
    "already delivered by NOWAIT" (`immediately = 0`, `callback fired by
    then: 1`, the follow-up `'once` never called); run 2 measured "still
    pending at NOWAIT" (`immediately = 1`, `callback fired by then: 0`, one
    blocking `'once` then delivered it). Item 1 above already prescribes
    `run-until/ticking`; this item is the direct measurement that makes it
    non-negotiable rather than merely cautious — hard-coding either NOWAIT
    outcome is flaky by construction, confirmed on CI, not just in theory.
12. **glibc's unpinned-socktype chain is 3 entries, stream-first, including
    `raw`** — `[0] stream, [1] dgram, [2] raw` — measured identically on two
    CI runs, against Darwin's 2 entries, dgram-first, no raw (item 7 above).
    Both the entry count and the leading member differ by OS, confirming
    item 7's set-containment rule was necessary, not merely cautious: a
    suite asserting order or exact count for the unpinned-socktype rows
    would pass on one CI OS and fail on the other.
