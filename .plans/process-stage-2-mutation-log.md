# Process Stage 2 Mutation Log

Task 4: the eleventh + twelfth trampolines (`exit`, `walk`) and the
process/pipe FFI surface in `src/libuv/private/native.sls` — dispatcher-names
widened ten -> twelve (ADR-0008's v0.3 amendment, ADR-0015), the `exit-callable`
/ `walk-callable` locked trampolines, `uv-spawn-native` (baking the exit entry
point into the caller's options block at the shim-reported offset),
`uv-walk-native`, the raw `uv_process_kill` / `uv_kill` / `uv_process_get_pid`
/ `uv_pipe_init` bindings, the `c-uptr-size` / `c-uptr-set!` / `c-u32-set!`
boundary writers, `require-callback` lifted beside `require-address` /
`require-port`, the six pipe/process/spawn-options counter bindings, and the
three new `live-counts` rows. Against `tests/test-loop.sps` and
`tests/test-native.sps`. Also touches `src/libuv/tcp.sls` (one line: see
"Unplanned finding" below).

## Method

Per ADR-0008's amendment procedure and AGENTS.md ("a test is not finished
when it passes; it is finished when you have watched it fail"): the two
frozen ten-name literals were widened to twelve FIRST, and `make test` run
unmodified against the still-ten-name `native.sls`, so the failure below is
a real observation of the gap, not a restatement of the plan. `native.sls`
was then implemented, the exit/walk stub-assertion rows were added to
`tests/test-native.sps`, and `make build && make test` was run again to
confirm green. One live mutation probe was run afterwards on the committed
`native.sls` and reverted; two probes named by the brief are recorded as
forward obligations, undischargeable until Task 8 exists.

## RED evidence (Step 2, watched to fail first)

`tests/test-loop.sps:199-202` and `tests/test-native.sps` (frozen literal at
what was then line 1403) were widened to the twelve-name list; `native.sls`
itself was untouched (`dispatcher-names` still ten names). `make test`,
verbatim, the only failures in the whole run:

```
=== tests/test-loop.sps ===
FAIL dispatcher-names names the twelve callback types the design commits to
# of expected passes      137
# of unexpected failures  1
=== tests/test-native.sps ===
  [informational] uv_buf_t offsets on this platform: base=0 len=8 sizeof=16
  [informational] sockaddr_in offsets: sin_family=1 sin_port=2
  [informational] addrinfo offsets: ai_addr=32 ai_canonname=24 sizeof=48
FAIL live-counts reports all eleven allocation classes
FAIL dispatcher-names names the twelve callback types the design commits to
# of expected passes      232
# of unexpected failures  2
```

(`live-counts reports all eleven allocation classes` was RED in the same run
because the commented-out block driving it was uncommented in the same
commit, per the task's instruction to uncomment it "first as part of your
RED step" — its own three-counter gap closes with the same native.sls change
as the dispatcher-names widening, so both were watched-to-fail together
rather than in two separate `make test` runs.)

Every other suite passed unchanged (`test-addrinfo`, `test-conditions`,
`test-dns`, `test-echo`, `test-facade`, `test-lifecycle`, `test-shim-loading`,
`test-tcp`, `test-timer`) — confirming `dispatcher-names` widening alone,
with no native.sls change yet, does not silently break
`install-callback-dispatchers!`'s length/completeness check in
`handles.sls` (it could not: `handles.sls` still called it with the
old ten-name `dispatcher-names` value in that snapshot, since native.sls
had not yet been edited).

## Unplanned finding: tcp.sls's blanket import collides with the new export

The brief's Step 3(f) states exporting `require-callback` from native.sls is
safe "since tcp.sls doesn't import the new export" — but `src/libuv/tcp.sls`
imports `(libuv private native)` with no `only`/`except` restriction, so
exporting a new binding of the same name tcp.sls already defines locally is
NOT harmless: it produced

```
Exception: multiple definitions for require-callback in body
  (library (libuv tcp) ...) at line 31, char 1 of src/libuv/tcp.sls
```

on every suite that imports `(libuv tcp)` (`test-dns`, `test-echo`,
`test-facade`, `test-lifecycle`, `test-tcp`, `test-timer` — six of eleven
suites, discovered by the first post-implementation `make test`, not by a
deliberate probe). Fixed by excepting the new export from tcp.sls's existing
import clause:

```scheme
(except (libuv private native) require-callback)
```

rather than removing tcp.sls's private copy (which the brief reserves for
Task 7, when the verbs that use it move). This makes the brief's own stated
invariant — "tcp.sls doesn't import the new export" — literally true instead
of merely assumed. One line changed in `src/libuv/tcp.sls`; no behavior
change, since the two `require-callback` definitions are identical.

## Forward obligations (Step 6, items 2 and 3)

Neither probe below can be caught by any test that exists as of this task —
both are recorded here per the brief's instruction, to be discharged by
Task 8's exit-delivery test.

- **Obligation A — exit-callable signature swap.** Probe: in `exit-callable`'s
  `foreign-callable` type list, swap `integer-64` and `int` (i.e.
  `(uptr int integer-64) void` instead of `(uptr integer-64 int) void`).
  No test in this stage's suites drives a real `uv_spawn` + exit callback, so
  nothing observes the swapped marshalling. **Discharged by:** Task 8's
  exit-code delivery test, expected shape `(7 #f)` (exit code 7, no signal) —
  against the swapped signature this fails, because `exit_status` would be
  read as a 32-bit `int` positioned where libuv actually writes the low half
  of the `int64_t`, and `term_signal` would be read from the wrong offset
  entirely.
- **Obligation B — uv-spawn-native offset mispoint.** Probe: in
  `uv-spawn-native`, replace
  `(offsetof-uv-process-options-t-exit-cb)` with
  `(offsetof-uv-process-options-t-flags)`, so the exit trampoline's entry
  point is written into the `flags` field instead of `exit_cb`. No test in
  this stage calls `uv-spawn-native` at all. **Discharged by:** Task 8's
  exit-delivery test — with `exit_cb` never set, libuv would either call an
  uninitialized/garbage function pointer or (more likely, since the block is
  `alloc-zeroed`) call trampoline address 0 for the exit callback, and
  `flags` would carry a bogus high-bit pattern that trips libuv's
  unknown-flag assertion (design spec S5.5 step 3, "flags are OR'd from the
  shim values only, so libuv's unknown-flag assert is unreachable from
  Scheme" — this mutation reaches it).

## Live mutation probe (item 4): drop `'walk` from `dispatcher-names`

**Mutation:** in `src/libuv/private/native.sls`, `dispatcher-names` widened
to eleven instead of twelve (`exit` present, `walk` dropped):

```scheme
(define dispatcher-names
  '(alloc read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo exit))
```

**`make test` output, verbatim (only failures in the run):**

```
=== tests/test-loop.sps ===
FAIL dispatcher-names names the twelve callback types the design commits to
# of expected passes      137
# of unexpected failures  1
=== tests/test-native.sps ===
  [informational] uv_buf_t offsets on this platform: base=0 len=8 sizeof=16
  [informational] sockaddr_in offsets: sin_family=1 sin_port=2
  [informational] addrinfo offsets: ai_addr=32 ai_canonname=24 sizeof=48
FAIL dispatcher-names names the twelve callback types the design commits to
FAIL the walk slot holds the raising uninstalled stub
# of expected passes      236
# of unexpected failures  2
```

**Result:** GREEN (failure detected, by name, in both files the brief names
— the two frozen literals — plus a bonus catch in test-native.sps: the
Step 4 walk-stub row also fails, because `(dispatcher-ref 'walk)` with `walk`
gone from `dispatcher-names` no longer resolves to the uninstalled-stub
message at all — it raises `&uv-invalid-argument` naming `'unknown-dispatcher`
instead, so `condition-message` no longer reads "callback dispatchers have
not been installed" and the `test-assert` fails.) `handles.sls`'s own install
(which builds its alist by mapping over `dispatcher-names`, see
`src/libuv/private/handles.sls:1120-1122`) does not fail differently under
this mutation — both sides of the length/completeness check still shrink
together, exactly the empirical result the DNS Stage 2 log recorded for the
analogous `'getaddrinfo`-drop probe. **Reverted**; `make test` re-confirmed
green (below) before commit.

## Gate tails

Final `make build && make test` (build: no-op, shim already current for this
branch's dev flavor; `make test` ran clean from the same tree):

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        240
=== tests/test-shim-loading.sps ===   24
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```

1099 passes, 0 failures across eleven suites.

## Coverage notes

- `handles.sls` needed NO edit: its `dispatchers-wired` seeds
  `dispatch-table` by mapping over `dispatcher-names` (whatever length it
  is), then builds the `install-callback-dispatchers!` alist the same way
  (`map (lambda (name) (cons name (seam-closure name))) dispatcher-names`,
  `handles.sls:1120-1122`) — both constructions auto-widen to the new
  `exit`/`walk` names, exactly the "added-callback-type case anticipated" the
  file's own header comment describes for the DNS names in v0.2. `exit` and
  `walk` land in `dispatch-table` seeded with `unimplemented-dispatcher`
  (raises "this callback type is not implemented in this version"), same as
  `getaddrinfo`/`getnameinfo` were before v0.2 Stage 4 — until Task 8's
  `(libuv process)` installs the real dispatchers through the
  `install-dispatch-procedure!` seam at its own library-body time.
- `test-native.sps`'s generic per-name uninstalled-stub loop
  (`tests/test-native.sps:1410-1418`, `((dispatcher-ref name) 0)`) also
  auto-widened to cover `exit` and `walk` with no edit — the same
  by-construction coverage the DNS Stage 2 log recorded for its two new
  names. The Step 4 rows added this task (`"the exit slot holds..."`,
  `"the walk slot holds..."`) are a SHARPER assertion beside it: real arity
  (three args for exit, two for walk) and the exact message text, not just
  "raises &uv-error".
- **Uncovered by design, recorded per AGENTS.md** (mirrors the DNS Stage 2
  log's equivalent note): the two new trampoline BODIES cannot be exercised
  by any test until `(libuv process)` exists (Task 8) — nothing calls
  `uv-spawn-native` or `uv-walk-native` this stage. `uv-process-kill`,
  `uv-kill`, `uv-process-get-pid`, `uv-pipe-init` are declaration-only until
  then; their declarations were checked line-by-line against vendored
  `vendor/libuv/include/uv.h` (`uv_process_kill`, `uv_kill`,
  `uv_process_get_pid`, `uv_pipe_init`, `uv_walk`, `uv_exit_cb`, `uv_walk_cb`)
  during this task. `c-uptr-set!`/`c-u32-set!`/`c-uptr-size` and
  `require-callback` are likewise unexercised by any NEW test this stage —
  `require-callback`'s existing behavior is already covered by tcp.sls's own
  copy's call sites (unchanged), and the lifted copy is structurally
  identical.
