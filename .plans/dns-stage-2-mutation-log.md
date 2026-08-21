# DNS Stage 2 Mutation Log

> **Provenance.** This file was back-filled on 2026-08-21, after the fact,
> from the implementer's session report for Stage 2
> (`task-s2-report.md`, scratchpad) — the report that accompanied commit
> `8248b81` (`feat: DNS FFI surface in native.sls -- bindings, two
> trampolines, helper lifts (S2)`). Stage 2's full watched-to-fail mutation
> round was actually run at implementation time; it was recorded only in
> that scratch report, not committed, which breaks the house convention
> (`.plans/stage-N-mutation-log.md`, v0.1) of committing one mutation log
> per stage. This file corrects that — it transcribes the mutation-testing
> section of the report rather than re-deriving or re-running it.

Covers `src/libuv/private/native.sls` (raw `uv_getaddrinfo`/`uv_getnameinfo`/
`uv_cancel`/`uv_freeaddrinfo`/`uv_ip_name` bindings, `sockaddr->address-string`,
`c-uptr-ref`, the two new locked trampolines, `dispatcher-names` widened to
ten, the `fill-sockaddr!`/`align-16` lift from tcp.sls) and `src/libuv/tcp.sls`
(the lift site) — against `tests/test-loop.sps` and `tests/test-native.sps`.
Commit `8248b81`.

## Method (as reported)

The report's own mutation-row heading states the method in one line:
"Mutation rows (mutation → verbatim first named failure; all reverted)."
No scratch-copy/`CHEZSCHEMELIBDIRS` transcript beyond that line survives in
the source report; the final gate run (below) is the report's own
re-confirmation that the tree was left green.

## RED evidence (watched to fail first, as reported)

The ten-name `native.sls` was implemented first and the suites run
unmodified. Verbatim, the only failures in the whole run:

```
=== tests/test-loop.sps ===
FAIL dispatcher-names names the eight callback types the design commits to
# of expected passes      105
# of unexpected failures  1
=== tests/test-native.sps ===
FAIL dispatcher-names names the eight callback types the design commits to
# of expected passes      214
# of unexpected failures  1
```

test-native rose 211→214 passes with **no test edit**: the per-name
uninstalled-stub loop and the per-name installed-slot loop each iterate
`dispatcher-names` and widened by two rows apiece — by-construction coverage
of the two new stubs. test-tcp stayed at 168 with the lifted helpers, so the
lift was behavior-preserving.

## Mutation log

All rows reverted per the report's own heading; the final gate run below is
the report's stated re-confirmation of a green tree.

| # | Anchor edited | Mutation | Verbatim first named failure(s) |
|---|---|---|---|
| M1 | src/libuv/private/native.sls | Drop `'getaddrinfo` from `dispatcher-names` (full `make test`) | `FAIL dispatcher-names names the ten callback types the design commits to` in test-loop.sps AND test-native.sps — and, per the report, **only** those two rows across all nine suites |
| M2 | src/libuv/private/native.sls | Zero arm of `sockaddr->address-string` answers `"0.0.0.0"` instead of `#f` | `FAIL sockaddr->address-string refuses a zero pointer with #f, without calling native` |
| M2b | src/libuv/private/native.sls (supplementary) | Zero check removed entirely — native called with 0 | Same row fails by name: `uv_ip_name(NULL,…)` faults, Chez converts it to `Exception: invalid memory reference. Some debugging context lost`, SRFI-64 catches it as `#f` ≠ `'refused-null`. Per the report, the sentinel discipline is what kept this a named failure rather than a false pass. |
| M3 | src/libuv/private/native.sls | rc arms swapped (zero rc → `#f`, nonzero → string) | `FAIL sockaddr->address-string renders back the dotted quad uv_ip4_addr parsed` + `FAIL sockaddr->address-string answers #f for a family uv_ip_name refuses` |
| M4 | src/libuv/private/native.sls | `c-uptr-ref`'s `who` → `'uv-c-int-ref` | `FAIL c-uptr-ref rejects a null source, naming who` |
| M5 | src/libuv/private/native.sls | `c-uptr-ref` reads `'int` instead of `'uptr` | `FAIL c-uptr-ref reads the full pointer width a raw uptr write stored` |

## The ten-name-drop empirical result (as reported)

Verified, per the report, exactly as its own corrected adversarial-review
oracle predicted: with `'getaddrinfo` dropped, `install-callback-dispatchers!`'s
length validation does **not** fire — `handles.sls` builds its install alist
by mapping the same `dispatcher-names`, so both sides shrink together and the
install succeeds at nine (test-loop's "importing (libuv private handles) has
already installed the dispatchers" row passed; zero `incomplete-dispatcher-set`
failures anywhere). The actual catch is the two widened literal rows failing
by name, and nothing else — the report notes the second half of the oracle
(`'unknown-dispatcher` at `(libuv dns)` import) becomes checkable only in
Stage 4.

## Coverage notes (as reported)

- The two DNS dispatcher slots remain uninstalled this stage; the raising
  stubs cover them, and the auto-widened stub loop proves it. Nothing calls
  the new wrappers this stage.
- **Uncovered by design (recorded per AGENTS.md, per the report):** the two
  new trampoline BODIES (a cross-pairing mutation, e.g. getaddrinfo's body
  dispatching to `'getnameinfo`) cannot be caught this stage — no test can
  fire them until Stage 4's suites exist. Design §9 records the cross-pairing
  failure mode as "varies", with the dispatcher kind-check arm as the
  designed defense. Likewise `uv-cancel`/`uv-freeaddrinfo`/
  `uv-getaddrinfo-native`/`uv-getnameinfo-native` are declaration-only until
  Stage 4 exercises them; the report states their declarations were verified
  line-by-line against vendored `uv.h:1002-1007,:1024-1028,:1200,:1785` and
  the callback typedefs at `:345-352` during this task.
- M2b's fail-by-name is noted as a macOS/Chez-signal-handling observation; on
  Linux (and under valgrind) the same mutation may be a hard SIGSEGV instead.
  Either way the gate goes red; the report states the design's stated
  rationale for the zero-refusal stands regardless.

## Gate tails (as reported)

Final `make build && make test` (build: shim relink guard + config.sls,
clean):

```
=== tests/test-conditions.sps ===   94
=== tests/test-echo.sps ===         32
=== tests/test-facade.sps ===       41   (facade suite: green, no changes this stage)
=== tests/test-lifecycle.sps ===    64
=== tests/test-loop.sps ===        106
=== tests/test-native.sps ===      220
=== tests/test-shim-loading.sps === 24
=== tests/test-tcp.sps ===         168
=== tests/test-timer.sps ===       128
ALL SUITES PASSED
```

877 passes, 0 failures across nine suites.
