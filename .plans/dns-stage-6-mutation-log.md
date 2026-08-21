# DNS Stage 6 Mutation Log

Covers the Stage 6 delta — `uv-loop-close!`'s pending-error re-raise in
`src/libuv/loop.sls` (the extracted `deliver-pending-callback-error!`
shared with `uv-run`'s exit path, the close-path call after
`count-loop-free!`, and the EBUSY non-delivery constraint), the `(libuv)`
facade's DNS re-export block in `src/libuv.sls`, and the Stage 5 polish
(`tests/test-dns.sps`: outcome-branched informational wording, tightened
losing-draw `tail-err` invariants) with its chartered re-run of the
stage-5 M3 kind-narrow mutation. Owning suites: `tests/test-loop.sps`
(138 passes at this stage's baseline; 119 at Stage 5's),
`tests/test-facade.sps` (48; 41 at Stage 5's), `tests/test-dns.sps` (121,
unchanged count).

## Red before green

**test-loop.** The 19 new rows were written first and run against the
Stage 5 tree (HEAD `4314db0` behavior — close discards). Eight failed by
name, exactly the delivery rows, with the invariant-preserving rows
(loop-closed-anyway, EBUSY discrimination, next-run delivery) passing as
they must under either policy:

```
FAIL close with a pending error re-raises it instead of discarding it
FAIL the close-raised condition satisfies uv-callback-error?
FAIL the close-raised condition ALSO satisfies the original condition's own predicate
FAIL the close-raised compound still answers the original condition's field accessors
FAIL the close-raised callback-error's cause is the original condition object
FAIL the pending error was consumed by the close's re-raise
FAIL close re-raises a #f callback error instead of dropping it silently
FAIL the #f-close's callback-error carries the #f as its cause
# of expected passes      130
# of unexpected failures  8
```

exit 1. One mid-red correction, recorded rather than hidden: the EBUSY
sequence's first draft expected ONE `uv-run 'default` to both deliver the
pending error and drain the timer's close. It cannot —
`loop-record-error!` also calls `uv_stop` (design spec S8), and the
stored stop flag makes that run return before its first iteration, so it
delivers the ERROR but not the close callback (probed: the timer read
`'closing` and the follow-up close answered EBUSY again). The sequence
gained the "one more run drains the close sweep quietly" row and a
comment stating the probed reason.

**test-facade.** The new DNS rows were run before the facade edit; the
suite died at expand time — the strongest failure a re-export list can
produce, no assertion ever running:

```
Exception: attempt to reference unbound identifier uv-getaddrinfo! at line 411, char 4 of tests/test-facade.sps
```

exit 255.

## Method

Identical to `.plans/dns-stage-{1..5}-mutation-log.md` and AGENTS.md's "a
test is not finished when it passes; it is finished when you have watched
it fail":

1. Each file under test was copied once to a scratch tree OUTSIDE the
   repository (session scratchpad, `stage6-mutation/src/...`), each with
   a `.pristine` sibling. The repo's own files were never edited during
   mutation testing.
2. Each mutation edits only the scratch copy, breaking exactly one
   decision, applied by a driver that refuses any anchor text not unique
   in the file.
3. The suite runs from the repo, unmutated, against the mutated tree:
   `CHEZSCHEMELIBDIRS="$SCRATCH/src:src:tests:build/scheme-libs" chez
   --program tests/<suite>.sps`.
4. Failing test names recorded verbatim with the exit status.
5. The scratch copy is restored from `.pristine` and the suite re-run
   green before the next mutation (verified after every round, including
   the last); the scratch tree was deleted after the round.

**Baselines** (pristine scratch tree): test-loop 138, test-facade 48,
test-dns 121, all exit 0.

## Mutation log

| # | Anchor edited | Mutation | Verbatim first named failure(s) |
|---|---|---|---|
| M1 | src/libuv/loop.sls | close-path delivery reverted to discard: the `(deliver-pending-callback-error! loop)` call after `count-loop-free!` removed | The same eight rows as the red run, by name, first: `FAIL close with a pending error re-raises it instead of discarding it`; 130 passes, 8 failures, exit 1. The EBUSY rows and the loop-closed-anyway rows still pass — they hold under either policy, which is why the delivery rows exist. |
| M2 | src/libuv.sls | `uv-dns-request?` dropped from the facade export list | Expand-time death, no assertion ran: `Exception: attempt to reference unbound identifier uv-dns-request? at line 421, char 8 of tests/test-facade.sps`, exit 255. Every other DNS name is referenced by the same suite (the driven lookup, the cancel pair, the record round-trip), so any single drop produces the same shape; one representative was run, per the stage brief. |
| M3 | src/libuv/private/handles.sls | stage-5 M3 re-run after the invariant tightening: `dns-request-kinds` narrowed to `'(getaddrinfo-req)` (its one code use is `cancel-requests-for-loop!`'s kind filter) | `[informational] queued-tail teardown: cancel never won in 16 attempts (max 16)` then `FAIL queued-tail teardown: the sweep cancelled the queued tail within the attempt bound` + `FAIL queued-tail teardown: the cancelled tail delivered EAI_CANCELED with host and service #f`; 119 passes, 2 failures, exit 1. Still exhausts, still fails by name; the TIGHTENED invariants row passed — every losing draw's tail-err was `'no-error`, a legal branch — and the informational line now agrees with the failing catcher instead of printing "won on attempt 16" (the Stage 5 wording the polish fixed). |

Every round restored from `.pristine` and re-verified green before the
next; final restore re-verified after M3 (test-facade 48, exit 0); the
scratch tree was deleted after the round.

## Honest uncovered / gate-only records

- **The composition itself is now shared code, not mirrored code.**
  `uv-run`'s exit path and the close path both call the one
  `deliver-pending-callback-error!`, so a composition-drift mutation
  (compose dropped, wrap-alone arm broken, consume-after-raise) is caught
  by BOTH suites' existing rows through one body — the uv-run re-raise
  rows already watch each of those decisions (v0.1 stage logs). What
  remained mutable at close specifically was the CALL, which is M1.
- **The #f discipline is still pinned separately on the close path** (the
  two `#f`-close rows): the shared helper makes truthiness-drift
  impossible today, but a future inlining of the close-path call could
  reintroduce `(when pending ...)`; the rows are the tripwire.
- **The facade's driven getnameinfo/cancel pair asserts the tolerant
  branch-paired shape** (this suite does not pin `UV_THREADPOOL_SIZE`):
  the boolean row plus the paired-outcome row, never the boolean alone.
  The forced branches live in test-dns, where the pool is pinned.
- **`make-uv-addrinfo` validates nothing by design** (addrinfo.sls's
  recorded decision), so the facade round-trip row pins re-export, arity
  and field order only.
- The `uv-loop-close!` EBUSY *answer* remains vendor-guarded, not mutated
  (stage-5 log's closing note); what Stage 6 adds — and M1 covers — is
  that the EBUSY path *delivers nothing* while the error stays pending.

## Gate tails (macOS arm, Darwin/arm64, final verification run)

- `make build`: exit 0 (dev relink after the `make prod` probe;
  relink-guard healed the flavor as designed).
- `make test`: 11 suites, **ALL SUITES PASSED**, exit 0 — test-loop 138
  (119 at Stage 5 + 19 new), test-facade 48 (41 + 7 new), test-dns 121
  (count unchanged by the polish), every other suite at its baseline
  (addrinfo 41, conditions 94, echo 32, lifecycle 64, native 220,
  shim-loading 24, tcp 168, timer 128).
- `make check-purity`: exit 0 — `purity holds` for both
  tests/test-conditions.sps and tests/test-addrinfo.sps,
  `CHEZ_LIBUV_SHIM` poisoned.
- `make test-memory` (macOS ASan arm): exit 0, all 11 suites under the
  preload. Leak claims remain Linux CI's (ADR-0003); the Linux valgrind
  leg is the controller's CI phase.
- `make check-pins`: exit 0 — `pins agree: chez-srfi 7879b52`, `vendored
  libuv pin ok: 1.52.1 (0x013401) in [0x012c00,0x01ffff]`, `README states
  the libuv floor (1.44.0)` (the floor line was untouched by the README
  rework). NOTE: check-pins does NOT cover Akku.manifest's version — the
  0.2.0 bump was manual, recorded in its own commit body.
- `make check-help`: exit 0 (no new targets this stage).
- `make prod`: exit 0, ending `check-prod: PASS: every counter read 0
  while a bound tcp handle (port 58845) was live on the loop; the shim is
  a prod (counters-free) build`.

## Final-review addendum (2026-08-21): the resolve->connect composition row

The whole-branch review found the one test the design spec's Non-goals
(§1: "Resolution composes with `uv-tcp-connect!` through the address
vocabulary") and ADR-0012's first consequence
("`uv-addrinfo-address`/`uv-addrinfo-port` compose directly with
`uv-tcp-connect!`'s existing parameters") both promise but no suite ran:
feeding a resolved record's own accessor answers into `uv-tcp-connect!`.
One row was added to `tests/test-facade.sps` (both surfaces live there
and nothing may stand between that suite and the facade): a loopback
listener binds port 0, `uv-tcp-getsockname-port` reads the kernel's
port, `uv-getaddrinfo!` resolves `"127.0.0.1"` + that port rendered as a
string — hermetic per ADR-0013 (`numeric-host`/`numeric-serv`, family
`inet` pinned) — the FIRST `'inet` record is taken by search, and
`uv-tcp-connect!` is called on `(uv-addrinfo-address rec)` /
`(uv-addrinfo-port rec)` verbatim. The accept firing on the listener is
what proves the composed connect reached it. House rules kept: facade-
only ticker keeps both drains' 32-iteration bounds real, `(collect)` in
every callback, no `#f`/0 sentinel anywhere. Suite count: 48 → 49.

### Suite-side mutation round (scratch copies, pristine library)

Method as stage 5's M5: each mutation edits a scratch COPY of
`tests/test-facade.sps` (session scratchpad, `s6c-mutation/`) and runs
against the pristine repo library
(`CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs`); the repo copy was
never edited during the round; baseline re-verified green (49 passes,
exit 0) after the last mutation; the scratch copies were deleted after
recording.

| # | Mutation (suite copy) | Verbatim outcome |
|---|---|---|
| MA | connect call's accessor uses replaced with the literals they came from (`"127.0.0.1"` / `cport`) | `# of expected passes      49`, exit 0 — **still passes, by construction**. Run because the review brief asked for the record: a literal-for-accessor swap is INVISIBLE to this row — the resolver's answer for a numeric literal IS the literal — so the row's value is that the shipped code path is the accessor path, not that it could catch this swap. Recorded honestly rather than claimed covered. |
| MB | `uv-addrinfo-address` shadowed at the connect site via a local `let` to answer a truncated string (`(substring ... 0 5)` → `"127.0"`) | Red, not by name: `Exception occurred with condition components:` / `  0. &uv-invalid-argument` / `      who: uv-tcp-connect!` / `      reason: bad-address`, exit 255 — `fill-sockaddr!` (libuv's own `uv_ip4_addr`, ADR-0012) refuses the truncated string synchronously, before any submit. |
| MC | `uv-addrinfo-port` shadowed to answer `port+1` (the review brief's suggested red) | Red, not by name, and NOT the predicted ECONNREFUSED on this machine: `Exception in uv-tcp-connect!: invalid argument`, exit 255. Probed (scratchpad `probe2.sps`): `(sync-raise 60337 EINVAL -22)` for the listener's port + 1, while ports with no nearby bind answer the async refusal — `(async 1 ECONNREFUSED)`, `(async 47123 ECONNREFUSED)`. Darwin assigns ephemeral ports sequentially, so the connecting socket's own auto-bound source port collides with the destination (self-connect shape) and macOS `connect(2)` answers a synchronous `EINVAL`. Recorded as a discrepancy against the brief's port+1/ECONNREFUSED expectation — the row still goes red, but the errno and the timing are a platform accident. |
| MD | `uv-addrinfo-port` shadowed to answer 47123 (probed refused above) — the wrong-port red with the platform accident removed | Fails BY NAME at the value level: `FAIL resolve->connect: the record's own address and port drive uv-tcp-connect! to the listener (ADR-0012)` / `# of expected passes      48` / `# of unexpected failures  1`, exit 1 — the connect completed `ECONNREFUSED` and the accept never came, exactly the wrong-record-port consequence the row's comment names. |

The row is shown capable of failing three different ways (MB, MC, MD),
with MD the clean by-name red; MA is the honest invisible-by-construction
record.

### Gate tails (this addendum's verification run, macOS arm)

- `make test`: 11 suites, **ALL SUITES PASSED**, exit 0 — test-facade
  **49** (48 + the composition row), every other suite at its Stage 6
  baseline (addrinfo 41, conditions 94, dns 121, echo 32, lifecycle 64,
  loop 138, native 220, shim-loading 24, tcp 168, timer 128).
- `make check-purity`: exit 0 — `purity holds` for both
  tests/test-conditions.sps and tests/test-addrinfo.sps.
