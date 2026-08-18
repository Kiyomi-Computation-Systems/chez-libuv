# Stage 0 Findings — chez-libuv

Evidence for the four questions the [design spec](../.plans/2026-08-18-chez-libuv-v0.1-design.md)
and ADRs 0001–0010 are contingent on. Every claim below is followed by the
command that produced it and the output that command actually printed. Every
experiment was run **twice**; where the two runs are not byte-identical, the
difference is named and explained rather than glossed.

Unlike the sibling `chez-cmark-gfm` spike — which committed only its
`FINDINGS.md` and lost its scripts — the scripts are committed here:
`spike/probe.c`, `spike/00-load.ss`, `spike/01-callback-gc.ss`,
`spike/02-raise.ss`, `spike/03-buf-loopback.ss`. Every number quoted in this
document is reproducible by re-running them.

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

## Summary of verdicts

| Q | Verdict |
|---|---|
| Q0 — load + call | **PASS.** `uv_version()` = `#x013401`, `uv_version_string()` = `"1.52.1"` via manual `uptr` copy. Definition-order trap reproduced and its exact message recorded. |
| Q1 — **THE GATE** | **PASS.** 10,000/10,000 re-entries from inside a blocking `uv_run`, `(collect)` on every fire, exit 0, twice, byte-identical. Locked entry points do not move across `(collect)`. |
| Q2 — raise across C | **PASS, with two refutations.** The plan assumed raising across C frames is unsafe: it is not — the condition reaches an enclosing `guard` and the loop survives. An earlier draft of this document then assumed the escape loses the abandoned iteration's events: it does not — measurement shows the `UV_EOF` is **redelivered**. What an escape actually costs is an invisible obligation (skipped cleanup, handles left open, `uv_loop_close` → `EBUSY`), plus process death if unguarded. Store-and-reraise retained. See "Q2 verdict". |
| Q3 — uv_buf_t + loopback | **PASS.** All six callback signatures round-trip; 5 bytes delivered exactly; `ssize_t` is a real Chez foreign type and `UV_EOF` = `-4095` arrives intact. |

Exit criterion 2 is met; ADRs 0001–0010 were flipped to `Accepted (2026-08-18)`
in the commit following this one.

---

## Q-1: the constants probe (`spike/probe.c`)

No enum value, struct size, or `offsetof` in any spike script below was
transcribed from `uv.h` or from memory. They all come from this probe, which is
the Stage 0 stand-in for the constants shim of
[ADR-0002](../.plans/decisions/0002-direct-ffi-with-constants-only-shim.md) /
[ADR-0005](../.plans/decisions/0005-constants-are-never-transcribed.md).

**Commands run (verbatim):**

```bash
cc -I/opt/homebrew/opt/libuv/include -o spike/probe spike/probe.c \
   -L/opt/homebrew/opt/libuv/lib -luv
./spike/probe
```

**Actual observed output** (verbatim; byte-identical across two runs, exit `0` both times):

```
== versions ==
UV_VERSION_HEX                     0x013401
UV_VERSION_MAJOR                   1
UV_VERSION_MINOR                   52
UV_VERSION_PATCH                   1
uv_version()                       0x013401
uv_version_string()                1.52.1

== uv_handle_type enum values ==
UV_UNKNOWN_HANDLE                  0
UV_ASYNC                           1
UV_TCP                             12
UV_TIMER                           13
UV_HANDLE_TYPE_MAX                 18

== uv_req_type enum values ==
UV_UNKNOWN_REQ                     0
UV_REQ                             1
UV_CONNECT                         2
UV_WRITE                           3
UV_SHUTDOWN                        4
UV_REQ_TYPE_MAX                    11

== uv_run_mode enum values ==
UV_RUN_DEFAULT                     0
UV_RUN_ONCE                        1
UV_RUN_NOWAIT                      2

== errno constants used by the spike ==
UV_EOF                             -4095
UV_ECANCELED                       -89
UV_EAGAIN                          -35

== runtime sizes (libuv accessors) ==
uv_loop_size()                     1072
uv_handle_size(UV_TCP)             264
uv_handle_size(UV_TIMER)           152
uv_req_size(UV_CONNECT)            96
uv_req_size(UV_WRITE)              192
uv_req_size(UV_SHUTDOWN)           80

== compile-time sizes ==
sizeof(uv_loop_t)                  1072
sizeof(uv_tcp_t)                   264
sizeof(uv_timer_t)                 152
sizeof(uv_connect_t)               96
sizeof(uv_write_t)                 192
sizeof(uv_buf_t)                   16
sizeof(struct sockaddr)            16
sizeof(struct sockaddr_in)         16
sizeof(struct sockaddr_storage)    128
sizeof(size_t)                     8
sizeof(ssize_t)                    8
sizeof(int)                        4
sizeof(void *)                     8

== uv_buf_t layout ==
offsetof(uv_buf_t, base)           0
sizeof(((uv_buf_t *)0)->base)      8
offsetof(uv_buf_t, len)            8
sizeof(((uv_buf_t *)0)->len)       8

== struct sockaddr_in layout ==
offsetof(struct sockaddr_in, sin_family) 1
sizeof(((struct sockaddr_in *)0)->sin_family) 1
offsetof(struct sockaddr_in, sin_port) 2
sizeof(((struct sockaddr_in *)0)->sin_port) 2
offsetof(struct sockaddr_in, sin_addr) 4
sizeof(((struct sockaddr_in *)0)->sin_addr) 4
AF_INET                            2

== uv_handle_t common-field layout (for uv_handle_get_type) ==
offsetof(uv_handle_t, data)        0
offsetof(uv_handle_t, loop)        8
offsetof(uv_handle_t, type)        16
sizeof(((uv_handle_t *)0)->type)   4
```

**Findings worth carrying forward:**

1. **`uv_handle_size()` agrees exactly with `sizeof` for every type checked**
   (`uv_loop_t` 1072, `uv_tcp_t` 264, `uv_timer_t` 152, `uv_connect_t` 96,
   `uv_write_t` 192). The runtime accessors are usable in place of compiled
   `sizeof`, which is what lets the binding allocate handles without a shim
   struct definition.
2. **`sockaddr_in` is NOT laid out the same on Darwin and Linux, and the
   difference is silent.** On this machine `sin_family` is a **one-byte field
   at offset 1** — byte 0 is BSD's `sin_len`. On Linux there is no `sin_len`
   and `sin_family` is a **two-byte field at offset 0**. Reading the family as
   a 2-byte value at offset 0 here would yield `0x0210` = 528, not `AF_INET`.
   `sin_port` happens to sit at offset 2 on both, which is why Q3's port
   extraction is portable while a family read would not be. This is a concrete
   instance of the hazard [ADR-0005](../.plans/decisions/0005-constants-are-never-transcribed.md)
   exists to prevent: a plausible constant, transcribed once, wrong on the
   other platform, failing silently.
3. **`UV_ECANCELED` is `-89` on this platform** (not a portable literal —
   libuv derives it from the host `errno`). The design's `'ECANCELED` symbol
   translation ([ADR-0006](../.plans/decisions/0006-error-codes-are-symbols.md))
   must go through `uv_err_name`, never through a compiled-in integer.
4. `UV_EOF` is `-4095` — a libuv-defined sentinel, identical across platforms
   because it is deliberately below the errno range.

---

## Q0: load the library and call into it

**Script:** `spike/00-load.ss`.

**Command run (verbatim):**

```bash
chez --script spike/00-load.ss /opt/homebrew/opt/libuv/lib/libuv.dylib
```

**Actual observed output** (verbatim; byte-identical across two runs, exit `0` both times):

```
--- (a) definition-order trap: foreign-procedure BEFORE load ---
raised: Exception in foreign-procedure: no entry for "uv_version"

--- (b) load, then bind ---
uv_version()          = 78849 (#x13401)
uv_version() unsigned = 78849 (#x13401)
decoded major.minor.patch = 1.52.1
uv_version_string()   = "1.52.1"
uv_loop_size()        = 1072

--- checks ---
uv_version() = #x013401: expected=78849 actual=78849 OK
signed and unsigned agree: expected=78849 actual=78849 OK
uv_version_string() = 1.52.1: expected="1.52.1" actual="1.52.1" OK
version hex decodes to the string: expected="1.52.1" actual="1.52.1" OK

RESULT: PASS
```

### The definition-order trap — the exact message

This is the error a future maintainer will hit, recorded so it is searchable:

```
Exception in foreign-procedure: no entry for "uv_version"
```

It is raised when the `foreign-procedure` **expression is evaluated**, not when
the resulting procedure is first called — so in a real library it surfaces at
*import* time, pointing at the binding rather than at the missing
`load-shared-object`. `spike/00-load.ss` reproduces it deliberately by
`eval`-ing the `foreign-procedure` form before any load; a literal top-level
`(define v (foreign-procedure ...))` in that position would abort the script
with the identical condition. This is design spec §4 rule 3 and the AGENTS.md
trap, now with its verbatim text.

### Return-type choices, recorded

| C signature | Chez type used | Why |
|---|---|---|
| `unsigned int uv_version(void)` | **`int`** | `UV_VERSION_HEX` is `(major<<16) \| (minor<<8) \| patch`; the sign bit is unreachable for any libuv 1.x release, so a signed 32-bit read is exact. Bound as `unsigned-int` alongside as a control: both returned `78849`, so the choice is not load-bearing at this value. |
| `const char *uv_version_string(void)` | **`uptr`** + manual byte copy | Deliberately **not** `string`. The spike copies bytes with `foreign-ref 'unsigned-8` until NUL and calls `utf8->string`, so neither the lifetime nor the encoding decision is delegated to Chez ([ADR-0009](../.plans/decisions/0009-copy-at-the-boundary.md)). |
| `size_t uv_loop_size(void)` | `size_t` | Native Chez foreign type; returned `1072`, matching the probe's `sizeof(uv_loop_t)`. |

**Conclusion:** Chez can load `libuv.dylib` by absolute path and call `uv_*`
symbols directly, with no shim in the call path. The packed version integer and
the version string agree. Q0 is answered; ADR-0002's Option A is reachable.

---

## Q1 — THE GATE: C→Scheme re-entry from inside a blocking `uv_run`, under GC pressure

**Script:** `spike/01-callback-gc.ss`.

A `uv_loop_t` and a `uv_timer_t` are `foreign-alloc`'d at probe-supplied sizes
(1072 and 152 bytes), zeroed, and initialized. The timer is started with
`timeout=0, repeat=1` (repeating, 1 ms) against a **locked**
`foreign-callable` of signature `(uptr) → void`. On **every** fire the callback
increments a Scheme counter, conses a fresh 1000-element list, and calls
`(collect)`. A single blocking `uv_run(loop, UV_RUN_DEFAULT)` drives all of it;
the callback calls `uv_stop` on fire 10,000.

`uv_run` is bound **plain** — no `__collect_safe`. See "deliberately untested"
below.

**Command run (verbatim):**

```bash
chez --script spike/01-callback-gc.ss /opt/homebrew/opt/libuv/lib/libuv.dylib 10000
```

**Actual observed output — stdout** (verbatim; **byte-identical across two runs**,
exit `0` both times; wall time 13.130 s and 13.278 s):

```
uv_loop_size()             = 1072
uv_handle_size(UV_TIMER)   = 152
locked timer entry point stable across (collect)? #t
locked close entry point stable across (collect)? #t
target fires               = 10000
uv_loop_init               = 0
uv_timer_init              = 0
uv_timer_start(0,1,repeat) = 0
uv_run(UV_RUN_DEFAULT)     = 1  (nonzero = handles still active, expected after uv_stop)
fire count after uv_run    = 10000
uv_timer_stop              = 0
uv_is_closing after close  = 1
close_cb fired before drain= 0
uv_run (drain)             = 0
close_cb fired after drain = 1
uv_loop_alive after drain  = 0
uv_loop_close              = 0
foreign-free               = done
post-teardown collect      = done

--- checks ---
fire count exact: expected=10000 actual=10000 OK
close_cb fired exactly once: expected=1 actual=1 OK
uv_loop_init rc: expected=0 actual=0 OK
uv_timer_init rc: expected=0 actual=0 OK
uv_timer_start rc: expected=0 actual=0 OK
uv_timer_stop rc: expected=0 actual=0 OK
uv_loop_close rc: expected=0 actual=0 OK
uv_loop_alive after drain: expected=0 actual=0 OK
timer entry point stable: expected=#t actual=#t OK
close entry point stable: expected=#t actual=#t OK
handle arg round-tripped: expected=#t actual=#t OK
garbage really was built: expected=1000 actual=1000 OK

RESULT: PASS
```

**stderr** carries the raw addresses, which are ASLR- and heap-dependent and
therefore the one part of the output that legitimately differs between runs.
Both runs, verbatim:

```
addresses: timer 10AC8CA10 -> 10AC8CA10 ; close 10AC8D010 -> 10AC8D010
handle arg: allocated 10446E670, callback saw 10446E670
```

```
addresses: timer 10747CA10 -> 10747CA10 ; close 10747D010 -> 10747D010
handle arg: allocated 1011EE670, callback saw 1011EE670
```

The addresses differ **between** runs (expected) and are identical **within**
each run across a `(collect)` and a full
`(collect (collect-maximum-generation))` (the finding).

### What Q1 establishes

1. **10,000 exact re-entries.** `fire-count` is `10000`, not 9,999 and not
   10,001. Every one of them happened inside a single blocking `uv_run`.
2. **GC on every fire is survivable.** 10,000 `(collect)` calls were made with
   libuv's `uv_run` → `uv__run_timers` C frames live on the stack below the
   Scheme callback. No crash, no counter drift.
3. **A locked callable's entry point does not move.** `lock-object` was called
   once per callable; `foreign-callable-entry-point` returned the same address
   before and after both a default `(collect)` and a maximum-generation
   collection. libuv retains the pointer for the whole life of the handle, so
   this is the property ADR-0008's "lock once, for the process lifetime"
   depends on.
4. **The handle pointer round-trips exactly.** The `uptr` libuv passed to the
   callback was `eqv?` to the pointer `foreign-alloc` returned — so a registry
   keyed on that `uptr` (design spec §5) has a valid key. The pre-set sentinel
   was the symbol `'none`, which is `eqv?` to no pointer, so this check cannot
   pass by way of a callback that never fired.
5. **Close protocol behaves as libuv documents.** `uv_is_closing` is `1`
   immediately after `uv_close`; `close_cb` had **not** fired yet at that point
   (`0`); it fired exactly once during the drain `uv_run`; `uv_loop_alive` then
   returned `0` and `uv_loop_close` returned `0`. This is the ordering design
   spec §5 builds its state machine on, now observed rather than assumed.

### Surprise recorded: a freed loop pointer answers, plausibly and wrongly

The first draft of `01-callback-gc.ss` evaluated its `uv_loop_alive` assertion
**after** `uv_loop_close` + `foreign-free`. It did not fault. It returned `1`:

```
uv_loop_alive after drain: expected=0 actual=1 MISMATCH
```

— while the same call, made a few lines earlier on the live pointer, had
printed `0`. The bug is mine, not libuv's, but the behaviour is the point: a
`uv_*` accessor on a freed pointer returns a **plausible-looking wrong answer**
rather than crashing. Nothing in the FFI layer will catch this.

It is reproducible on demand (stderr, so the default stdout stays byte-stable):

```bash
chez --script spike/01-callback-gc.ss /opt/homebrew/opt/libuv/lib/libuv.dylib 50 uaf-demo
```

```
UAF DEMO: uv_loop_alive(freed loop-ptr) = 1  (correct answer is 0)
```

This is direct evidence for design spec §5/§6/§7's rule that **the freeing site
zeroes the stored `uptr` immediately** — a zeroed slot fails loudly at the
Scheme boundary; a stale one returns `1`.

### Deliberately untested, and why

- **`__collect_safe` × callback re-entry.** `uv_run` is bound plain. The
  interaction between `__collect_safe` (which releases Chez's collect interlock
  for the duration of a foreign call) and a callable re-entered from inside
  that same call is **not** exercised here. v0.1 is single-threaded and
  ADR-0008 scopes it out; mixing the two axes in one experiment would make any
  failure un-attributable. This is a known, named gap, not an oversight — it
  must be re-opened before any multi-threaded or `__collect_safe` use of
  `uv_run` is introduced.
- **An *unlocked* callable's behaviour.** Not tested. A moving entry point
  would be a use-after-free with nondeterministic timing, so a passing run
  would prove nothing and a failing run would prove only that it can fail.
  `lock-object` is treated as required, not as verified-necessary.

**Q1 verdict: PASS.** The gate is open. Direct FFI with locked static
trampolines re-entered from a blocking `uv_run` works on this platform, exactly,
under adversarial GC pressure. The Option B fallback (C trampoline layer,
design spec §12 Stage 0) is **not** required.

---

## Q2: a Scheme `raise` escaping a callback into C

**Script:** `spike/02-raise.ss`, three scenarios, the same timer setup across
all three; the callback raises a custom `&spike-raise` condition on fire 3 of a
maximum 6. The timer here is `timeout=1ms, repeat=1ms` — **not** Q1's
`timeout=0`, which would race the first fire against the `uv_run` entry. Q1
wants maximum fire pressure; Q2 wants a predictable fire 3.
A `dynamic-wind` inside the callback distinguishes "the handler ran in place on
top of a live C frame" from "the continuation was invoked and the C frames were
abandoned" — only a real escape runs the after-thunk without the body having
completed.

**Commands run (verbatim):**

```bash
chez --script spike/02-raise.ss /opt/homebrew/opt/libuv/lib/libuv.dylib store
chez --script spike/02-raise.ss /opt/homebrew/opt/libuv/lib/libuv.dylib escape
chez --script spike/02-raise.ss /opt/homebrew/opt/libuv/lib/libuv.dylib bare
```

All three were run twice. **stdout and stderr were byte-identical across both
runs for all three scenarios**, with identical exit codes.

### Scenario `bare` — no guard anywhere. Exit code **255**.

**stdout** (verbatim):

```
scenario = bare
uv_loop_init  = 0
uv_timer_init = 0
uv_timer_start= 0
MARKER: about to enter blocking uv_run
  [cb] fire 1
  [cb] fire 2
  [cb] fire 3
  [cb] raising on fire 3
  [dw] after-thunk ran WITHOUT normal completion -> a real escape
```

**stderr** (verbatim):

```
Exception: spike raise from inside a libuv callback
```

The `MARKER: control resumed after uv_run form` line never printed. An
unhandled raise inside a `foreign-callable` **kills the process**. Nothing
after `uv_run` runs: no teardown, no `uv_loop_close`, no `foreign-free`.

**This alone makes guarding every trampoline body mandatory** — design spec §8's
"nothing raised inside a callback is permitted to unwind into libuv's C stack
frames" is, at minimum, "…is permitted to reach the default handler".

### Scenario `escape` — a `guard` wraps the blocking `uv_run`. Exit code **0**.

**stdout** (verbatim):

```
scenario = escape
uv_loop_init  = 0
uv_timer_init = 0
uv_timer_start= 0
MARKER: about to enter blocking uv_run
  [cb] fire 1
  [cb] fire 2
  [cb] fire 3
  [cb] raising on fire 3
  [dw] after-thunk ran WITHOUT normal completion -> a real escape
MARKER: guard around uv_run FIRED
MARKER: control resumed after uv_run form
uv_run result = guard-fired
fire count    = 3
guard around uv_run received: the spike condition, fire=3
stored pending-error: NOTHING (sentinel intact)
dynamic-wind after-thunk: 2 normal returns, 1 escapes
uv_loop_alive after the scenario = 1
MARKER: attempting a SECOND uv_run on the same loop
  [cb] fire 4
  [cb] fire 5
  [cb] fire 6
  [tr] reached max fires; uv_stop
second uv_run result = 1
fires during second uv_run = 3
uv_timer_stop = 0
uv_run (drain)= 0
close_cb fired= 1
uv_loop_alive after drain = 0
uv_loop_close = 0
MARKER: teardown complete, exiting 0
```

**This refutes the plan's stated assumption.** The design spec §8 and ADR-0008
both say store-and-reraise is chosen because raising across C frames is *not
safe or clean*. On this platform it is neither unsafe nor dirty in the timer
case:

- The condition **does** cross libuv's C stack frames and arrive at a `guard`
  established before `uv_run` was called — `guard around uv_run received: the
  spike condition, fire=3`, with the custom condition type and its field intact.
- The escape is **real**, not a handler running in place: `uv_run result` is the
  symbol `guard-fired`, never an int, so `uv_run` never returned; and the
  `dynamic-wind` after-thunk ran once *without* its body completing
  (`2 normal returns, 1 escapes`) — fires 1 and 2 completed normally, fire 3
  unwound.
- The loop **survives**. `uv_loop_alive` = 1 afterwards (correct — the timer is
  still active), a **second `uv_run` on the same loop ran three more callbacks
  normally**, and teardown returned `0` at every step.

### Scenario `store` — design spec §8's policy. Exit code **0**.

**stdout** (verbatim):

```
scenario = store
uv_loop_init  = 0
uv_timer_init = 0
uv_timer_start= 0
MARKER: about to enter blocking uv_run
  [cb] fire 1
  [cb] fire 2
  [cb] fire 3
  [cb] raising on fire 3
  [dw] after-thunk ran WITHOUT normal completion -> a real escape
  [tr] caught inside callback; storing + uv_stop
MARKER: control resumed after uv_run form
uv_run result = 1
fire count    = 3
guard around uv_run received: NOTHING (sentinel intact)
stored pending-error: the spike condition, fire=3
dynamic-wind after-thunk: 2 normal returns, 1 escapes
MARKER: re-raising the stored condition from Scheme
re-raise caught outside uv_run: original condition still matches, fire=3
uv_loop_alive after the scenario = 1
MARKER: attempting a SECOND uv_run on the same loop
  [cb] fire 4
  [cb] fire 5
  [cb] fire 6
  [tr] reached max fires; uv_stop
second uv_run result = 1
fires during second uv_run = 3
uv_timer_stop = 0
uv_run (drain)= 0
close_cb fired= 1
uv_loop_alive after drain = 0
uv_loop_close = 0
MARKER: teardown complete, exiting 0
```

Every mechanical claim design spec §8 makes about this policy holds:

- The guard inside the trampoline catches the condition; **nothing reaches the
  guard around `uv_run`** (`NOTHING (sentinel intact)` — and that sentinel is a
  symbol no success path can produce).
- `uv_run` returns an **integer** (`1`), i.e. it returned normally through its
  own C epilogue rather than being abandoned.
- The stored condition is re-raised from Scheme afterwards, wrapped with
  `make-error` + a message condition, and **a guard written against the
  original condition type still matches it**: `original condition still matches,
  fire=3`. This is the "composed with the original condition object" claim of
  §8, verified.
- The loop is fully usable afterwards; teardown returns `0` throughout.

### The deciding experiment: a raise from a *deeper* libuv frame

The timer case is the shallow case. `uv__run_timers` runs near the top of a loop
iteration with little in-progress state. Read callbacks run from inside
`uv__io_poll`, much deeper. `spike/03-buf-loopback.ss` re-runs the escape from
there.

Three aftermath modes were measured, each run twice, each stdout
byte-identical across its two runs, all exiting `0`:

```bash
chez --script spike/03-buf-loopback.ss <libuv.dylib> raise-in-read-cb
chez --script spike/03-buf-loopback.ss <libuv.dylib> drain-before-close
chez --script spike/03-buf-loopback.ss <libuv.dylib> no-recovery
```

All three escape identically — `uv_run returned = guard-fired`,
`nread values = (5)`, `close_cb calls = 1`,
`raise from read_cb: escaped-to-guard-around-uv-run`,
`uv_loop_alive after uv_run = 1`. They differ only in what happens next.

#### Is the abandoned iteration's `UV_EOF` lost, or merely deferred?

**Measured, after an earlier draft of this document got it wrong.** That draft
claimed the `UV_EOF` was "silently and permanently lost", citing a drain that
had closed the peer and the server *before* running — so no `read_cb` could
possibly have fired, and the check backing the claim could not fail. That is
exactly the empty assertion AGENTS.md warns about, and it produced a wrong
conclusion. `drain-before-close` fixes the method: it leaves every handle open
and the read **still started**, then drains, bounded by a one-shot deadline
timer so a genuinely-absent EOF cannot hang the script (the listening server
keeps the loop alive on its own, so `uv_run` would otherwise block forever).

**Actual observed output** (verbatim, `drain-before-close`):

```
MARKER: draining with every handle still open and read still started
uv_timer_init(deadline)  = 0
uv_timer_start(250ms one-shot) = 0
drain uv_run = 0 (deadline fired: yes)
nread values BEFORE drain = (5)
nread values AFTER  drain = (5 -4095)
close_cb calls after drain = 3
EOF redelivered? yes-eof-was-redelivered
uv_loop_close = 0
foreign-free  = done
post-teardown collect = done

--- drain-before-close verdict ---
raise escaped uv_run into the Scheme guard: expected=escaped-to-guard-around-uv-run actual=escaped-to-guard-around-uv-run OK
loop was left alive with handles open: expected=1 actual=1 OK
at the escape, only the data read had been delivered: expected=(5) actual=(5) OK
deadline timer bounded the drain: expected=yes actual=yes OK
EOF is REDELIVERED, not lost: expected=yes-eof-was-redelivered actual=yes-eof-was-redelivered OK
nread before drain (escape branch only): expected=(5) actual=(5) OK
nread after drain (EOF arrives late): expected=(5 -4095) actual=(5 -4095) OK
the late EOF ran the cleanup branch that the escape skipped: expected=3 actual=3 OK
loop closable after drain: expected=0 actual=0 OK
uv_loop_close returns 0: expected=0 actual=0 OK

RESULT: DIAGNOSTIC-COMPLETE (see measured values above)
```

**The EOF is REDELIVERED, not lost.** `nread` goes from `(5)` before the drain
to `(5 -4095)` after it, and `close_cb` goes from 1 to 3 — meaning the late EOF
ran `read_cb`'s EOF branch, the very branch the escape had skipped, which
closed the peer and the server. The loop then closed cleanly (`uv_loop_close =
0`). On this platform's kqueue backend the readiness is level-triggered and the
watcher registration survives the abandoned frame, so the event comes back the
next time anything runs the loop.

#### What does `uv_loop_close` return if the caller just tries to close?

**Actual observed output** (verbatim, `no-recovery` — no closes, straight to
`uv_loop_close` with the handles still open):

```
MARKER: calling uv_loop_close immediately, handles still open
uv_loop_close with handles open = -16 (EBUSY: resource busy or locked)
uv_loop_close = -16 (EBUSY: resource busy or locked)
foreign-free  = done
post-teardown collect = done

--- no-recovery verdict ---
raise escaped uv_run into the Scheme guard: expected=escaped-to-guard-around-uv-run actual=escaped-to-guard-around-uv-run OK
loop was left alive with handles open: expected=1 actual=1 OK
at the escape, only the data read had been delivered: expected=(5) actual=(5) OK
measured uv_loop_close with handles open: -16 (EBUSY: resource busy or locked)
uv_loop_close with handles open is nonzero: expected=#t actual=#t OK

RESULT: DIAGNOSTIC-COMPLETE (see measured values above)
```

`-16 (EBUSY: resource busy or locked)`, now measured by a committed code path
rather than asserted. (An earlier draft quoted this number from a scratch run
that no committed script could reproduce.)

#### What this actually costs

The escape does **not** destroy the event. It costs the caller three things,
all of them invisible from Scheme:

1. **The callback's own cleanup never ran at escape time.** `read_cb`'s EOF
   branch — the code that closes the peer and the server — was skipped. The
   handles stayed open.
2. **Nothing re-runs the loop automatically.** The deferred EOF arrives only
   if the caller happens to call `uv_run` again. A caller who reasonably
   treats the raise as terminal and goes straight to teardown never sees it.
3. **Teardown then fails, with a code that does not explain itself.**
   `uv_loop_close` returns `EBUSY` because of handles the caller never learned
   were still open.

### Q2 verdict

**The plan's premise is refuted; the plan's decision is retained, on new
grounds.** Recorded honestly rather than reframed — including the fact that an
earlier draft of this section stated a *second* premise that measurement also
refuted:

| Claim | Status |
|---|---|
| Design spec §8 / ADR-0008: raising across libuv's C frames is unsafe | **Refuted.** The condition arrives intact at an enclosing `guard`; the loop survives; a second `uv_run` works; teardown returns 0. |
| An earlier draft of this document: the escape permanently loses the abandoned iteration's events | **Refuted, by `drain-before-close`.** The `UV_EOF` is redelivered in full the next time the loop is run, and it then executes the cleanup branch the escape had skipped. |
| An *unguarded* raise kills the process | **Holds.** Exit 255, no teardown, no `uv_loop_close`, no `foreign-free`. |
| After an escape, teardown fails without explaining itself | **Holds, measured.** `uv_loop_close` with the abandoned handles still open returns `-16 (EBUSY)`. |

Store-and-reraise remains the policy, now justified by **determinism and the
invisible obligation an escape leaves behind**, not by event loss and not by
safety:

1. **Guarding every trampoline body is mandatory outright**, independent of any
   other choice, because an unguarded raise terminates the process (exit 255)
   with no teardown at all. This is the one unconditional result.
2. **An escape silently transfers work to the caller.** The event itself is
   deferred, not lost — but the callback's own cleanup branch did not run, the
   handles it would have closed stay open, and nothing re-runs the loop
   automatically. A caller who treats the raise as terminal and proceeds to
   teardown gets `EBUSY` from `uv_loop_close` and no indication why.
3. **The resulting state depends on which libuv frame was live.** Raising from
   `uv__run_timers` left nothing observable outstanding, with a single active
   handle; raising from `uv__io_poll` left two handles open and one event
   pending. Callers cannot see libuv's internal call depth, so they cannot
   predict which they are in.
4. **Store-and-reraise has none of that.** `uv_run` returns through its own C
   epilogue, every callback libuv had already queued for that iteration runs
   (a mechanism property of letting the iteration finish, not something Q2
   measured), and the caller gets a loop in a defined state — verified in the
   `store` scenario, where the second `uv_run` and the whole teardown returned
   0. The wrapped re-raise still matches a guard written against the original
   condition type.

**ADR-0008 is accepted with its decision unchanged and its rationale corrected.**
The ADR text says a negative Q2 finding "changes the error-delivery mechanism
described here"; the finding is not negative — the mechanism stands. Its stated
*reason* is what this document corrects.

**Not tested, and worth naming:** whether the escape is safe from *every* libuv
frame. Two frames were sampled (`uv__run_timers`, `uv__io_poll`); both survived.
No libuv source tree is vendored at Stage 0, so the in-progress state of the
abandoned frames was not inspected at source level. Since the binding does not
rely on escaping, this gap is not load-bearing — but it is the reason the
"escaping is fine" reading of the `escape` scenario should not be generalized.

---

## Q3: `uv_buf_t` by hand + one TCP loopback write/read

**Script:** `spike/03-buf-loopback.ss`. A `uv_buf_t` is `foreign-alloc`'d and
filled at the probe's offsets, then read back. A TCP server binds
`127.0.0.1:0`, the real port is recovered via `uv_tcp_getsockname` and a manual
`ntohs`, a client connects **from the same loop**, writes `"hello"` once, and is
closed from its `write_cb` — deliberately, to force `UV_EOF` at the server. All
six callbacks are locked `foreign-callable`s.

**Command run (verbatim):**

```bash
chez --script spike/03-buf-loopback.ss /opt/homebrew/opt/libuv/lib/libuv.dylib
```

**Actual observed output — stdout** (verbatim; **byte-identical across two
runs**, exit `0` both times):

```
--- part 0: foreign type availability ---
ssize_t: accepted by foreign-callable
size_t: accepted by foreign-callable
iptr: accepted by foreign-callable
uptr: accepted by foreign-callable
int: accepted by foreign-callable
integer-64: accepted by foreign-callable
unsigned-64: accepted by foreign-callable
long: accepted by foreign-callable

--- part 1: uv_buf_t built by hand ---
sizeof(uv_buf_t)          = 16
buf.base readback == payload pointer? #t
buf.len  readback         = 5 (payload "hello" is 5 bytes)
bytes at buf.base         = "hello"

--- part 2: TCP loopback on 127.0.0.1:0 ---
uv_loop_init      = 0
uv_tcp_init(srv)  = 0
uv_ip4_addr(:0)   = 0
uv_tcp_bind       = 0
uv_listen         = 0
uv_tcp_getsockname= 0
namelen written back = 16 (sizeof(struct sockaddr_in))
sin_family byte      = 2 (AF_INET = 2)
sin_addr             = 127.0.0.1
port is nonzero and in the ephemeral range? #t
uv_tcp_init(cli)  = 0
uv_ip4_addr(:port)= 0
uv_tcp_connect    = 0
MARKER: entering blocking uv_run
  [connection] uv_tcp_init=0 uv_accept=0 uv_read_start=0
  [connect] uv_write rc = 0
uv_run returned   = 0

--- results ---
connection_cb calls = 1, status = 0
connect_cb    calls = 1, status = 0
alloc_cb      calls = 2, suggested_size = 65536
read_cb       calls = 2, nread values = (5 -4095)
write_cb      calls = 1, status = 0
close_cb      calls = 3
alloc_cb buffer pointer reached read_cb? #t
received 5 bytes = "hello"
uv_loop_alive after uv_run = 0
uv_loop_close = 0
foreign-free  = done
post-teardown collect = done

--- checks ---
uv_buf_t base round-trips: expected=#t actual=#t OK
uv_buf_t len round-trips: expected=5 actual=5 OK
sin_family is AF_INET: expected=2 actual=2 OK
getsockname namelen: expected=16 actual=16 OK
sin_addr is 127.0.0.1: expected=(127 0 0 1) actual=(127 0 0 1) OK
connection_cb status: expected=0 actual=0 OK
connect_cb status: expected=0 actual=0 OK
write_cb status: expected=0 actual=0 OK
connection_cb fired once: expected=1 actual=1 OK
connect_cb fired once: expected=1 actual=1 OK
write_cb fired once: expected=1 actual=1 OK
close_cb fired 3x: expected=3 actual=3 OK
alloc_cb buffer reached read_cb: expected=#t actual=#t OK
received exactly the payload: expected="hello" actual="hello" OK
received byte count: expected=5 actual=5 OK
last nread is UV_EOF (-4095): expected=-4095 actual=-4095 OK
nread sequence: expected=(5 -4095) actual=(5 -4095) OK
uv_loop_alive after uv_run: expected=0 actual=0 OK
uv_loop_close rc: expected=0 actual=0 OK

RESULT: PASS
```

**stderr** carries the ephemeral port, which is by definition different on every
run — the one intentional non-determinism, kept off stdout for that reason. The
two runs printed:

```
bound ephemeral port = 60561
```

```
bound ephemeral port = 60563
```

### Callback signatures, as bound and verified

| libuv typedef | Chez `foreign-callable` types | Verified by |
|---|---|---|
| `void (*uv_alloc_cb)(uv_handle_t*, size_t, uv_buf_t*)` | `(uptr size_t uptr) void` | fired 2×, `suggested_size` = `65536` arrived as a Scheme integer; the buffer pointer it wrote reached `read_cb` (`alloc_cb buffer pointer reached read_cb? #t`) |
| `void (*uv_read_cb)(uv_stream_t*, ssize_t, const uv_buf_t*)` | `(uptr ssize_t uptr) void` | fired 2×, `nread values = (5 -4095)` |
| `void (*uv_write_cb)(uv_write_t*, int)` | `(uptr int) void` | fired 1×, `status = 0` |
| `void (*uv_connect_cb)(uv_connect_t*, int)` | `(uptr int) void` | fired 1×, `status = 0` |
| `void (*uv_connection_cb)(uv_stream_t*, int)` | `(uptr int) void` | fired 1×, `status = 0` |
| `void (*uv_close_cb)(uv_handle_t*)` | `(uptr) void` | fired 3× (client, peer, server) |

### `ssize_t` — the type question design spec §4 rule 4 left open

**`ssize_t` is a real Chez 10.4.1 foreign type. The `iptr` fallback the spec
allows for is not needed.** "part 0" of the same script declares a throwaway
`foreign-callable` for each candidate type and reports acceptance or the
condition raised; all eight candidates
(`ssize_t size_t iptr uptr int integer-64 unsigned-64 long`) were accepted, as
shown in the transcript above. The check lives in the committed script, so it
re-runs with everything else rather than resting on this sentence.

**`UV_EOF` = `-4095` arrives intact**, as the last element of
`nread values = (5 -4095)`.

**Mutation proof that this assertion is not empty.** Per AGENTS.md, the
assertion was watched to fail. A copy of the script was made *outside the repo*
and the single token `ssize_t` in the `read_cb` declaration changed to
`size_t` — nothing else:

```bash
cp spike/03-buf-loopback.ss "$SCRATCH/03-mutant-size_t.ss"
# in the copy only:  (uptr ssize_t uptr) void))  ->  (uptr size_t uptr) void))
chez --script "$SCRATCH/03-mutant-size_t.ss" /opt/homebrew/opt/libuv/lib/libuv.dylib
```

Exit code **255**, and the last line of output (verbatim):

```
Exception in make-bytevector: 18446744073709547521 is not a valid bytevector length
```

`18446744073709547521` is `2^64 − 4095` — `UV_EOF` reinterpreted as unsigned.
The failure is through the asserted property and nothing else: the wrong type
makes `(> nread 0)` true for EOF, so the callback takes the **data** branch and
tries to copy 18 exabytes out of the read buffer. In a binding without this
spike's bounds check, that is a silent EOF-as-data corruption rather than an
exception. `ssize_t` is load-bearing; it is now proven load-bearing.

### `uv_buf_t` construction by hand

`sizeof(uv_buf_t)` = 16; `base` at offset 0 (`uptr`), `len` at offset 8
(`size_t`). Written with `foreign-set!`, read back with `foreign-ref`: the base
readback was `=` to the `foreign-alloc`'d payload pointer, `len` was 5, and
decoding the bytes at the readback address produced `"hello"`. libuv then
accepted the same struct as `uv_write`'s `bufs` argument (`uv_write rc = 0`) and
delivered exactly those 5 bytes. `define-ftype` is not required to get this
right, though design spec §4 rule 4 still specifies one for Stage 1 — this
confirms the layout that ftype must match.

### The ephemeral-port dance (ADR-0010's test strategy)

`uv_tcp_bind` to `127.0.0.1:0` then `uv_tcp_getsockname` into a 128-byte
`sockaddr_storage`, with `namelen` seeded to 128 and written back as **16** =
`sizeof(struct sockaddr_in)`. Port extracted manually from
`offsetof(sockaddr_in, sin_port)` = 2 as a two-byte big-endian value (`ntohs`
by hand, no `htons`/`ntohs` binding needed). `sin_addr` decoded to `127.0.0.1`
and the family byte to `AF_INET` = 2 — **read as a one-byte field at offset 1,
per the Darwin layout finding in the probe section; this exact read would be
wrong on Linux.**

Both endpoints live on the **same loop in the same process**, with no
subprocess and no fixed port, which is what makes the whole exchange
deterministic and single-Valgrind-visible.

### Incidental finding

`(chezscheme)` has **no `bytevector-append`**. The first draft of the spike
called it and died with `Exception: variable bytevector-append is not bound`;
the script now defines a two-argument `bv-append` over `bytevector-copy!`.
Stage 5's read path accumulates chunks and will need the same helper — worth
knowing before it is discovered mid-implementation.

**Q3 verdict: PASS.**

---

## Consequences for the plan

Changes the implementation stages should absorb from this spike:

1. **`ssize_t`, not `iptr`.** Design spec §4 rule 4's fallback clause is dead;
   delete the hedge and bind `nread` as `ssize_t`.
2. **Design spec §8 and ADR-0008's rationale for store-and-reraise was wrong as
   written** — raising across C frames is *survivable* here, and the abandoned
   iteration's events are *deferred rather than lost*. The decision stands, on
   the grounds that an escape leaves the caller an invisible cleanup
   obligation (skipped callback branch, handles left open, `uv_loop_close` →
   `EBUSY`) whose shape depends on which libuv frame was live. Both documents
   now cite this file rather than the refuted premises.
3. **Guarding every trampoline body is mandatory**, independently of the
   store-and-reraise choice, because an unguarded raise kills the process
   (exit 255, no teardown).
4. **`sockaddr_in` field offsets must come from the shim, per platform.**
   `sin_family` is 1 byte at offset 1 on Darwin and 2 bytes at offset 0 on
   Linux. `sin_port` is at offset 2 on both.
5. **`UV_ECANCELED` is platform-derived** (`-89` here); the errno table must be
   built from `uv_err_name` at init, never from literals.
6. **Freed `uv_*` pointers answer plausibly and wrongly.** Zeroing the stored
   `uptr` at the single freeing site is the only thing standing between that
   and a silent wrong answer.
7. **`__collect_safe` × callback re-entry is an open question**, deferred by
   design and recorded here so it is re-opened deliberately rather than
   stumbled into.
8. **A stopped-mid-iteration loop still has its events waiting.** Because the
   kqueue registration survives an abandoned frame, `uv-loop-teardown!` must
   drain (design spec §5 already says so) rather than assume that a loop which
   stopped early has nothing left to deliver — the pending `UV_EOF` in
   `drain-before-close` arrived on the very next `uv_run`.
