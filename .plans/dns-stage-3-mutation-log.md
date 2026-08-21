# DNS Stage 3 Mutation Log

> **Provenance.** This file was back-filled on 2026-08-21, after the fact,
> from the implementer's session report for Stage 3
> (`task-s3-report.md`, scratchpad) — the report that accompanied commit
> `6d2b9e3` (`feat: handle-less request machinery + teardown cancel sweep
> (S3)`). Stage 3's full watched-to-fail mutation round was actually run at
> implementation time; it was recorded only in that scratch report, not
> committed, which breaks the house convention (`.plans/stage-N-mutation-log.md`,
> v0.1) of committing one mutation log per stage. This file corrects that —
> it transcribes the mutation-testing section of the report rather than
> re-deriving or re-running it.

Covers `src/libuv/private/handles.sls` (`complete-request!` generalized to
read `registry-loop-of` before deregistering and deliver `extras` via
`apply`; the lifted, exported `abandon-request!`; the new exported
`cancel-requests-for-loop!` teardown sweep for handle-less DNS request kinds)
and `src/libuv/loop.sls` (the sweep wired into `uv-loop-teardown!` before the
close sweep, per ADR-0011) — against `tests/test-loop.sps`,
`tests/test-native.sps`, and `tests/test-timer.sps`. Commit `6d2b9e3`.

## Method (as reported)

Quoted verbatim from the report's own header: "TDD; all mutations run
against the working tree and reverted (final tree carries none —
`rg MUTATION` clean)." No scratch-copy/`CHEZSCHEMELIBDIRS` transcript beyond
that statement survives in the source report.

## Discovered consequence the brief did not enumerate (as reported)

`tests/test-timer.sps`'s dispatch-seam rows manufactured a request record
with `handle = 'not-a-handle` and relied on `complete-request!`'s
`(handle-loop (req-handle req))` read raising **before** any dispatch — the
very read ADR-0011 abolishes. Under the new code that record completes
normally (the registry entry is the authority), so two rows failed and the
suite's own cleanup then crashed it. The property under test (the seam
closure is itself guarded; a pre-guard dispatcher raise on a registered
pointer is contained, recorded on the entry's loop, re-raised by `uv-run` as
`&uv-callback-error` carrying the ORIGINAL raise) was preserved by returning
to the formulation those rows themselves replaced in v0.1 — fire a stub —
which v0.2 legitimately reopens: the `'getaddrinfo` name holds the raising
stub again. The identity pin changed from "an assertion, not a uv-error" to
"the stub's own who + message" (still discriminates a seam that manufactures
its own condition — verified by mutation M8, below). The report states this
is a test-formulation change, not a behavioral change to any public v0.1
path; the suite stayed green at the same 128 rows.

## New rows added this stage (as reported)

`tests/test-loop.sps`, ADR-0011 section: sweep no-op contract (seed a live
handle entry; "returns without raising"; "deregistered nothing"; "left the
timer open and its counter untouched"; "loop still usable"); a synthetic
handle-less completion built from a real alloc-zeroed block via
`%make-uv-req-record` with `handle #f`, registry kind `'getaddrinfo-req`,
`complete-request!` called directly (the exact Stage-4 call shape) — seed;
"completes without raising"; "delivered err then the extras, via apply";
"deregistered, counted, and zeroed"; a raising-on-complete pair ("contained,
not escaped" / "recorded on the loop the registry entry named" — pins
read-before-pop); and a teardown integration pair ("teardown still tears
down a loop with a live handle after the cancel sweep" / "timer closed and
freed").

## Mutation log

Every row below was watched and reverted, per the report's own header
statement above (`rg MUTATION` clean on the final tree).

| # | Anchor edited | Mutation | Result | Verbatim first named failure(s) |
|---|---|---|---|---|
| M1 | src/libuv/private/handles.sls | revert the loop-read substitution: `registry-loop-of` back to `(handle-loop (req-handle req))` | CAUGHT — the report notes the brief expected this UNCAUGHT until Stage 4/5; it was in fact caught now | "complete-request! completes a handle-less request without raising" (plus cascade: extras row, dereg/count/zero row, both raising-on-complete rows, suite balance). test-loop: 113 passes / 6 failures. test-tcp 168 GREEN, test-timer 128 GREEN — confirming the equivalence claim (entry-loop ≡ handle-loop for every publicly constructible request) exactly as ADR-0011 states. |
| M2 | src/libuv/private/handles.sls | drop the `apply` (extras become a positional list) | CAUGHT, but louder than predicted | "the handle-less completion delivered err then the extras, via apply" (actual `(#f (record-a record-b))`); test-tcp: dies loudly — exit 255, "incorrect number of arguments 2 to #<procedure at test-tcp.sps:15049>" surfacing through uv-run's re-raise path. The brief predicted "tcp write rows fail by name"; the report records the reality as louder but less named. |
| M3 | src/libuv/private/handles.sls | widen the sweep's kind filter to include handle kinds: `(append handle-kinds dns-request-kinds)` | **UNCAUGHT** | test-loop, test-timer, test-tcp, test-lifecycle, test-echo all stayed green. Verified empirically: `uv_cancel` on real `uv_timer_t`/`uv_tcp_t` pointers reads a garbage `req->type`, answers `UV_EINVAL`, and the sweep ignores it by design — no crash, no observable state change. Recorded HONEST-UNCOVERED; see below. |
| M4 | src/libuv/private/handles.sls | move the loop read to AFTER `registry-deregister!` | CAUGHT, deliberately run against test-loop only | "a raising handle-less on-complete is contained, not escaped" and "the raise was recorded on the loop the registry entry named" — both by name. (Report notes: under this mutation any raising callback in another suite would reach `loop-record-error!` with `#f` inside the seam guard's handler — spike-Q2 territory — hence the deliberately narrow run.) |
| M5 | src/libuv/private/handles.sls | drop `(count-free!)` | CAUGHT | "the handle-less completion deregistered, counted, and zeroed the block" (counted 0 ≠ 1) |
| M6 | src/libuv/private/handles.sls | off-by-one in the sweep's `do`-bound (iterate one past the vectors) | CAUGHT | "cancel-requests-for-loop! with no DNS entries returns without raising", plus the teardown cascade (every teardown row fails — a broken sweep structure breaks teardown everywhere) |
| M7 | src/libuv/private/handles.sls | destructive sweep — kind conjunct dropped, `registry-deregister!` used in place of `uv-cancel` (compound mutation; the single-edit variants are no-ops in a suite with no DNS entries) | CAUGHT | "the no-op sweep deregistered nothing", plus teardown cascade (unswept timer → EBUSY) |
| M8 | src/libuv/private/handles.sls (seam guard) | seam guard records a manufactured condition instead of the original raise (`contain-dispatcher-raise!` storing a fresh `(make-uv-error)`) | CAUGHT | test-timer's rewritten row: "...carrying the stub's own raise, not one the seam manufactured" — validates the discovered-consequence rewrite described above |

## Uncovered-but-noted (as reported)

Snapshot-first is untestable while the swept operation (`uv_cancel`) mutates
no registry state — it is defensive structure, per the ADR's "costs nothing
and removes the question." The rows "left the timer open and its counter
untouched" and "loop still usable" document the no-op contract, but their
single-purpose mutations (cancel answers on wrong pointers) are unobservable
by design; their destructive variants are covered via M6/M7 above.

## M3's caveat for Stage 5, verbatim (as reported)

The report records this note deliberately for the next stage's author:
future catcher for M3's widened-filter direction is Stage 5's
teardown-with-in-flight row. The WIDENED direction stays unobservable even
then (extra `EINVAL` answers are ignored); it is the **NARROWED** direction
(a DNS kind dropped from the filter → that request waits out its real
completion instead of cancelling) that Stage 5's row must be designed to
notice, and the spec'd branch-tolerant assert (`err ∈ {#f, 'EAI_CANCELED}`)
tolerates both branches — a pool-pinned queued-tail teardown or a
duration-shaped assert is needed for the filter to have a named catcher at
all.

## Deferred-coverage ledger (as reported, verbatim scope)

- Full cancel-then-drain integration (in-flight DNS during teardown,
  `'EAI_CANCELED` delivery, exactly-one-callback, balance) — Stage 5's
  teardown-with-in-flight row.
- getaddrinfo/getnameinfo extras delivery through the REAL dispatchers (chain
  conversion, two-string copy) — Stage 4's test-dns suite; this stage covers
  the extras mechanism synthetically only.
- The kind filter's narrowed-direction catch — Stage 5 (see M3 caveat above).
- `uv-cancel!` public policy over the same raw binding — Stage 5.
- The `handle-kinds`-untouched property for DNS entries (a `'getaddrinfo-req`
  entry stays out of `uv-loop-live-handles`/close sweep with a REAL request
  in flight) — Stage 4/5; this stage's synthetic entries are completed
  before any snapshot-reading row runs.

## Gate evidence (as reported)

Baseline (8248b81): nine suites, 877 passes, ALL SUITES PASSED. Final
`make build && make test`:

```
test-conditions 94 | test-echo 32 | test-facade 41 | test-lifecycle 64
test-loop 119 (+13) | test-native 220 | test-shim-loading 24
test-tcp 168 | test-timer 128 | ALL SUITES PASSED  (890 total)
```

Every v0.1 suite green at its baseline count; test-timer's count unchanged
with two rows reformulated (names changed, property preserved per the
discovered-consequence note above); test-loop's +13 are the new ADR-0011
rows. TDD red step recorded: the new section failed at compile time
(`unbound identifier cancel-requests-for-loop!`) before the implementation
landed.
