# v0.5 follow-up (Tier 1) — mutation probes

Covers `tests/test-native.sps`'s stub-level round-trips for v0.5's natives
(design spec §13.5), one of the two deliverables dropped from the milestone.
The spike scripts under `spike/flow/` are measurement, not assertion, and
carry no probes; their evidence is `spike/flow/FINDINGS.md`.

All probes run by the controller, tree verified clean before and after each.

---

## Probe 1: bind the `size_t` return as `double-float`

**Mutation:** `src/libuv/private/native.sls` —
`(foreign-procedure "uv_stream_get_write_queue_size" (uptr) size_t)` →
`... double-float`.

**Output:**
```
=== tests/test-flow.sps ===
FAIL the write queue goes positive against an unreading peer
FAIL an idle stream on the same loop reads zero while the other is congested
=== tests/test-native.sps ===
FAIL uv_stream_get_write_queue_size marshals as a non-negative exact integer
```

**Result: GREEN.** The new stub-level row fails by name, and the two
live-socket rows in `test-flow.sps` fail alongside it — correct for a
mutation to the shared binding.

---

## Probe 2: bind the `int` rc as `unsigned-int`

**Mutation:** `(foreign-procedure "uv_send_buffer_size" (uptr uptr) int)` →
`... unsigned-int`.

**Output, after the row was corrected (see below):**
```
=== tests/test-flow.sps ===
FAIL the send getter surfaces the native failure on a pipe with no fd
FAIL the send setter surfaces the native failure on a pipe with no fd
=== tests/test-native.sps ===
FAIL uv_send_buffer_size on an fd-less handle answers a NEGATIVE EBADF rc
```

**Result: GREEN — on the second attempt, and the first attempt is the finding.**

The row was originally written as `'EBADF (errno->symbol (uv-send-buffer-size-native tp cell))`
— asserting the symbol alone. Under this probe it **passed**, while
`test-flow.sps`'s two rows failed. Running the mutation is the only reason
that was noticed.

Measured cause: **`errno->symbol` normalises the unsigned wraparound.** It
answers `EBADF` for `-9` and for `4294967287` alike. So a row asserting only
the symbol is structurally blind to an `int`-bound-as-`unsigned-int` defect —
an empty test in exactly the sense AGENTS.md names, written by someone (me)
who had just spent a milestone warning about them.

The wrappers survive that mutation for a different reason than the row did:
`uv-check` gates on the rc being negative *before* mapping it, so an unsigned
value reads as success and no condition is raised. That is why `test-flow`'s
rows caught it and the stub-level row did not.

The row now asserts `'(negative EBADF)` — the **sign** is the marshalling
assertion, and the symbol is only corroboration.

---

## Explicitly uncovered property (AGENTS.md)

**"the int out-parameter still holds alloc-zeroed's zero after a failed
call"** is not falsifiable by any `src/` mutation, and is recorded here rather
than left looking guarded.

The cell is allocated by the test itself, so nothing in `src/` decides its
contents; the row documents *libuv's* behaviour — that a failed
`uv_send_buffer_size` does not write back through the out-parameter. Its value
is as the stated justification for `alloc-zeroed` over `foreign-alloc` in
`(libuv handle)`'s wrappers: since libuv leaves the cell untouched on failure,
a getter built on uninitialised heap would carry whatever the heap held and
nothing would notice. That reasoning is what the row preserves. It is
documentation with a runtime check attached, not a guard.
