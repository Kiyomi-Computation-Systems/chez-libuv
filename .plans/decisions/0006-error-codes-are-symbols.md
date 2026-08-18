# ADR-0006: Represent error codes as symbols, not raw platform integers

- **Status:** Proposed — to be accepted with Stage 0 spike evidence
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0005](0005-constants-are-never-transcribed.md)

## Context

`uv_*` functions signal failure with a negative `int`. libuv's `UV_*` error
names look like a portable namespace, but the numeric values behind them are
ordinary per-platform enum values — not guaranteed equal across platforms
even though the names are. A binding that compared raw return codes against
numeric constants captured on one platform would be subtly wrong on another,
which is the same transcription failure
[ADR-0005](0005-constants-are-never-transcribed.md) already rules out for
scalar constants, applied here to the error-code path specifically.

Separately, one particular "negative code," `UV_EOF`, is not an error at
all — it is libuv's signal that a stream ended normally. A read-path design
that routed `UV_EOF` through the same condition type as `'ECONNRESET` would
force every caller to special-case one specific "error" that represents
success, in every single read handler.

## Decision

Every negative `uv_*` return code is converted, at the FFI boundary, via
`uv_err_name_r`, into a Scheme **symbol** (`'ECONNRESET`, `'ECONNREFUSED`,
and so on) — the value callers pattern-match and compare against, portably,
regardless of the platform's underlying numeric encoding. The raw platform
`int` is preserved too, but only as the `code` field on
`&uv-errno-error`, for logging and diagnostics — never as the primary
discriminant a caller is expected to branch on.

`UV_EOF` is kept structurally outside the error-condition hierarchy
entirely. The read path (design spec §6) delivers it as a distinct callback,
`(on-eof)`, never as an `&uv-errno-error` instance.

## Consequences

- Callers branch on `eqv?`/`case` against portable symbols instead of magic
  numbers whose meaning depends on which platform produced them; this is the
  same discipline the design spec applies to `'EBUSY` from `uv-loop-close!`
  — compared by symbol equality, never treated as merely truthy.
- `test-native`'s errno round-trip enumerates the *entire* `UV_ERRNO_MAP`
  table ([ADR-0005](0005-constants-are-never-transcribed.md)), checking
  name-to-value and value-to-name consistency for every entry, not a sample.
- Read-path callers never need a special case distinguishing "the stream
  ended" from "the stream errored" within a single error-handling branch —
  the two arrive through different callbacks.
- One extra `foreign-procedure` call (`uv_err_name_r`) per error delivered,
  accepted since error delivery is not a hot path.
