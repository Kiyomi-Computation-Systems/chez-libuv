# ADR-0016: Signals, pipe directions and identities cross the boundary as closed vocabularies; privileged-but-deterministic behavior is bound behind an opt-in root lane

- **Status:** Accepted (2026-08-21) — evidence: spike/process/FINDINGS.md SQ-0, SQ2, SQ3
- **Date:** 2026-08-21
- **Scope:** chez-libuv v0.3
- **Related:** [design spec](../2026-08-21-chez-libuv-v0.3-process-design.md) §4.2, §4.3, §4.4, §4.5, §9.1, §9.4,
  [ADR-0005](0005-constants-are-never-transcribed.md),
  [ADR-0006](0006-error-codes-are-symbols.md),
  [ADR-0012](0012-address-vocabulary.md),
  [ADR-0013](0013-offline-deterministic-dns-tests.md)

## Context

Process control drags four vocabulary questions across the public boundary
at once, and each has a wrong answer that is *plausible*:

- **Signals.** `uv_process_kill(handle, signum)` takes an int. Passing ints
  through would make `(uv-process-kill! p 9)` legal and portable-looking
  when it is neither — and `SIGKILL` is 9 on both supported platforms
  (SQ-0 probed `SIGTERM 15`, `SIGKILL 9`, byte-identical on Darwin and
  glibc) while nothing guarantees the same of the other seven names v0.3
  binds. ADR-0005 already forbids the binding from *knowing* any of these
  numbers; the open question is what the caller says instead.
- **Exit payloads.** `uv_exit_cb` reports `(int64 exit_status, int
  term_signal)`, where a signal death arrives as `exit_status = 0` and
  `term_signal = WTERMSIG` (design spec §7, V5) — the same integer a clean
  exit produces. Both fields are success-shaped: nothing failed, a child
  ended.
- **Pipe directions.** libuv's `UV_READABLE_PIPE` (probed: 16) and
  `UV_WRITABLE_PIPE` (32) are named from the **child's** perspective, so the
  flag for "parent writes to the child's stdin" is the one spelled
  *readable*. ADR-0012's never-invent rule says mirror libuv's vocabulary;
  this is the case where mirroring it produces silent direction bugs.
- **`uid`/`gid`.** libuv ignores `options.uid` unless `UV_PROCESS_SETUID`
  (probed: 1) is in `flags`. A binding that exposes field and flag
  separately exposes a state — field set, flag clear — whose only meaning is
  "silently ignored".

Underneath all four sits a policy question v0.2 answered narrowly.
ADR-0013 ruled that `AI_ADDRCONFIG`/`AI_V4MAPPED`/`AI_ALL` "stay unbound,
because no offline-deterministic test can assert their libc-varying
semantics, and unwatched behavior cannot ship" (ADR-0013:77-80). `uid`/`gid`
are unwatched for a different reason: not because their behavior varies, but
because asserting it requires privileges the default suite does not have.
The two reasons deserve different answers.

Two spike results bound the answers. SQ3 measured the exit/EOF ordering and
found **both orders reachable from ordinary child commands** — `ORDERING:
EOF before exit : 70 run(s)` versus `ORDERING: exit before EOF : 50 run(s)`,
`incomplete (one never came) : 0`, identical on both platforms — with the
order "determined by the *child's* process structure, not by libuv
scheduling and not by anything the binding controls". SQ2 measured whether
libuv's child reaping survives Chez's own subprocess APIs on the platform
where it can fail (Linux reaps via `SIGCHLD handler + waitpid(WNOHANG)`,
Darwin via `kqueue EVFILT_PROC (no SIGCHLD handler)` — SQ-0's last probe
row) and found `110 / 110 rounds` delivered with the exact `(7 . 0)` payload
across four orderings, on both platforms: `VERDICT: NO CONFLICT OBSERVED`.

## Decision

**Signals are a closed symbol set, plus the exact integer `0`.** `sig` is
one of `sigterm sigkill sigint sighup sigquit sigusr1 sigusr2 sigcont
sigstop`, or `0` — the POSIX liveness probe (`kill(pid, 0)`, V9), documented
as the one integer that is not a number the caller had to look up. Anything
else raises `'signal-unknown`. Every number comes from a
`chez_uv_constant_table` row read from `<signal.h>` at build time
(ADR-0005): no signal number is written in Scheme source, so the binding is
correct on a platform whose numbering it was never told. The symbol→int
validator starts in `process.sls` and lifts to `(libuv private native)` on
its second user, per the PR #4 rule that produced ADR-0012's amendment.

**Exit is delivered as two already-copied results, never a condition.**
`on-exit` receives `(exit-status term-signal)`: `exit-status` an exact
integer with libuv's semantics stated prominently (`0` when a signal killed
the child, so SIGTERM death is `(0 sigterm)` and never `(-1 …)`), and
`term-signal` either `#f` for a normal exit or the signal **as a symbol**,
reverse-mapped through the same shim table. A signal outside the bound set
is delivered as the **raw exact integer**: information is never dropped to
keep a vocabulary closed. This is the UV_EOF precedent (ADR-0006) — a
success-shaped event gets its own delivery and is never routed through
`&uv-errno-error` — and `uv_exit_cb` has no error argument to route.

**Pipe directions are named from the parent's perspective**: `to-child`
(parent writes, child reads — the stdin shape, `= UV_READABLE_PIPE`),
`from-child` (child writes, parent reads — the stdout/stderr shape, `=
UV_WRITABLE_PIPE`), `duplex` (both flags OR'd). This is the one place v0.3
deliberately does not mirror libuv's names, and the mapping is stated
wherever the vocabulary appears — module header, §4.3, and here — so the
divergence is a documented translation rather than a local invention. The
justification is asymmetric risk: mirroring `READABLE`/`WRITABLE` costs a
silent, data-shaped bug (the parent writes into the end nobody reads);
renaming costs one table lookup in the docs. `duplex` is the only spec whose
sole coverage is one test (§9.2), because it is the only one that OR's both
probed flag rows.

**`uid`/`gid` presence implies `UV_PROCESS_SETUID`/`UV_PROCESS_SETGID`.**
The pair is never split at the public boundary: absent means flag unset and
field zeroed; present means both. The state whose only behavior is "libuv
ignores this" is not expressible. Range is `0 ≤ n < 2³²`
(`'uid-out-of-range`/`'gid-out-of-range`), and a non-root caller setting
either gets `'EPERM` from `uv_spawn` — a negative case cheap enough to live
in the *normal* suite (§9.2).

**The root lane: privileged-but-deterministic behavior is testable, and
therefore bindable.** `tests/test-process-setuid.sps` is excluded from the
default `TESTS` (and so from `MEMORY_TESTS`) and runs only under `make
test-root`, which refuses with exit 1 unless `geteuid` is 0; both CI jobs
gain a `sudo` step so the lane is *watched on every push*, not
opt-in-in-name-only. The suite looks its target identity up at runtime (`id
-u nobody` — never a transcribed number, ADR-0005's spirit applied to a host
fact) and asserts the child actually ran as it.

This **refines** ADR-0013's rule rather than overturning it. The v0.2 rule's
real content is *unwatched behavior cannot ship*; "untestable" was its
proxy. `uid`/`gid` are deterministic — given root, the child's `id -u` is
exactly the number we asked for, on both platforms — so they are watchable,
and the lane is what watches them. `AI_ADDRCONFIG` stays unbound because no
amount of privilege makes its libc-varying semantics assertable. The
dividing line this ADR draws: **privilege is a prerequisite a lane can
supply; host configuration is not.**

**The binding sends signals; it does not claim SIGCHLD.** SQ2 was run to
decide whether the README must declare libuv and Chez's `system` /
`open-process-ports` mutually exclusive. It must not: "No README
mutual-exclusion warning is justified by this evidence" — 110/110 exit
callbacks delivered with the exact payload, 185 `system` and 115
`open-process-ports` calls all returning their own correct results, in four
orderings, on the platform where a stolen `waitpid` silently drops an
`exit_cb`. What the README *does* say is the honest residue of that finding:
libuv owns SIGCHLD in this process, so any C code linked in that calls
`wait()`/`waitpid(-1, …)` or installs its own SIGCHLD handler breaks libuv's
reaping (V6) — libuv's constraint, surfaced rather than fixed — and the
measurement covers Chez 10.4.1 on glibc 2.39, not every Chez on every libc.

**No test may assert the order of exit against EOF.** SQ3 makes this a
measured rule rather than a caution: with `/bin/cat` the stdout EOF arrived
first in **140/140 runs across both platforms**; with the echo moved into a
grandchild (`sh -c 'exec 3<&0; cat <&3 & exit 0'`) the order inverted
completely — `exit_cb` first in **100/100 runs**. So every stdio scenario
carries two sentinels, one per event, neither derived from the other and
neither `#f` or `0`, and waits on both under an iteration cap (§9.1, §9.2).

## Consequences

- **`(uv-process-kill! p 9)` is an error, not a portable shortcut**, and
  `(uv-process-kill! p 0)` is the documented liveness probe. The closed set
  is nine names; adding a tenth is one shim row plus one table entry, and
  the reverse map for `term-signal` grows with it automatically.
- **A child killed by an unbound signal still reports it.** `term-signal`
  falls back to the raw integer, so a `SIGWINCH` death is `(0 28)` on a
  platform where 28 means that — legible, unambiguous, and not a lie about
  the closed set.
- **Pid validity ends at the exit callback** (§4.5). The child is reaped by
  the time `on-exit` runs, so a later kill or `0`-probe races pid reuse; the
  binding cannot promise the signal will not land on a recycled pid, and the
  suites never signal after exit. Documented in the module header beside the
  probe.
- **The root lane is a new way to be wrong**, and its guards are the answer:
  a suite that silently passes as non-root would be worse than no suite, so
  `make test-root` fails closed on `geteuid ≠ 0` rather than skipping, and
  the lane is excluded from valgrind/ASan (§9.4) because running Memcheck as
  root is a different risk profile than the one ADR-0003 gated.
- **Rejected: a `signal` record or an int passthrough.** A record buys
  nothing over a symbol the validator already closes; ints reopen the
  portability hole ADR-0005 exists to close and make `9` look like a
  contract.
- **Rejected: mirroring `READABLE`/`WRITABLE` for `dir`.** It would satisfy
  ADR-0012's never-invent rule literally and defeat its purpose, which is
  that the caller's vocabulary means what the caller thinks it means. The
  translation table is one row per direction and appears three times in the
  tree by design.
- **Rejected: binding `uid`/`gid` without the root lane** (ship it,
  document that it is untested). That is precisely the unwatched behavior
  ADR-0013 refuses, and the `'EPERM` negative test alone would pin only the
  failure path — the interesting half is that the child *is* the requested
  identity.
- The exit-payload vocabulary composes with nothing else in the binding, on
  purpose: exit is not close (§6), so `on-exit` firing obliges the caller to
  `uv-close!` the record exactly as ADR-0007 obliges every other handle
  owner, and the `exited?` flag is the observable the lifecycle scenarios
  read.
