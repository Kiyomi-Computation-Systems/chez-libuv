# Rule 14: no caller's number reaches a C integer unchecked for its type

## Why

Chez's integer foreign argument types each accept -2^(N-1) .. 2^N-1 and
wrap in two's complement at optimize level 0, and check nothing at level 3:
a fixnum keeps its low bits, a bignum reaches C as bits of its address.
`int` given 4294967295 gives C -1, which made `(uv-kill! 4294967295 sig)`
`kill(-1, sig)` until #137. At level 0 Chez's own refusal, raised inside a
`one-step`, leaves interrupts disabled for good. So the binding's own
predicate is the only guard, and it must run before the step. Nothing holds
that each caller's number has one.

Survey of 6766f8d (x86_64 Linux, Chez 10.4.1; probes kept in the main
checkout's `build/survey-int/`): no caller's number reaches C out of range
today by any call a real heap can make. Two counts go unchecked against
their C type (`uv-write*!`'s `nbufs`, `unsigned int`; `uv-spawn!`'s
`stdio_count`, written by `c-int-set!`), each needing ≥ 2^31 elements. The
C int range is written out by hand in five places and computed from
`foreign-sizeof` in a sixth.

## Design (the smallest that would have caught uv-kill!)

### 1. One predicate per C type, defined once

A new pure library, `(libuv private c-types)`, computes each range from
`foreign-sizeof` and exports:

| Predicate | C types it holds | Range on every supported platform |
|---|---|---|
| `c-int?` | int, integer-32 | -2^31 .. 2^31-1 |
| `c-unsigned-int?` | unsigned, unsigned-int, unsigned-32 | 0 .. 2^32-1 |
| `c-u64?` | unsigned-64 | 0 .. 2^64-1 |
| `c-uptr?` | uptr (an address the binding holds) | 0 .. 2^64-1 on 64-bit |

Each is `(and (integer? x) (exact? x) (<= min x max))`. It imports
`(libuv private require-threaded)` ahead of `(only (chezscheme)
foreign-sizeof)` (AGENTS.md's threaded-Chez trap).

Every hand-written C bound in src/ becomes one of these:

- native.sls: `c-int-min`/`c-int-max` go; `try-c-int-set!` uses `c-int?` and
  `c-uptr?`; `c-int-set!` refuses a value that is no `c-int?` (it is called
  outside steps only; Chez checks nothing at level 3); `c-u32-set!` uses
  `c-unsigned-int?`; `valid-port?` becomes `(and (c-int? x) (<= 0 x 65535))`.
- process.sls: its own `c-int?` and `u32?` go; `c-int-fd?` is
  `(and (c-int? x) (>= x 0))`; uid and gid use `c-unsigned-int?`;
  `fill-scalars!` answers #f, writing nothing, when the stdio count is no
  `c-int?`, as it does for a uid.
- tcp.sls: the backlog check is `(and (c-int? b) (>= b 0))`; the keepalive
  delay `(and (c-unsigned-int? d) (positive? d))`.
- handle.sls: a buffer size is `(and (c-int? n) (positive? n))`.
- timer.sls: `valid-milliseconds?` is `c-u64?`.
- stream.sls: `uv-write*!` refuses a segment list whose length is no
  `c-unsigned-int?`, before anything is allocated.

### 2. The rule (test-source-rules.sps)

- **Positions:** every parameter of every foreign call in src/ whose type is
  an integer type: rule 5's scalar types less the floats, chars, booleans,
  `uptr` and `void*` (addresses the binding allocated, which rules 3-4
  cover). Each is keyed (binding, 1-based index), the binding being the
  definition whose form holds the foreign call.
- **A table, `integer-parameters`, one entry per position, with a word:**
  - `constant`: a literal, a constant from (libuv private constants), or a
    symbol's mapping to one;
  - `libuv`: a value libuv or the system answered;
  - `size`: a size, offset or index the binding computes, or a caller's
    offset it has bounded by a buffer it holds;
  - `(caller P D)`: a caller's number, checked by predicate P in
    definition D.
- **Rows:**
  1. The table equals the positions found, both ways.
  2. No foreign call in src/ takes `boolean` or `stdbool` (0 reaches C as 1).
  3. For each `caller` entry: P is a c-types predicate for the position's
     type, or a predicate whose definition names one (`valid-port?`); D
     names P or reaches it; D reaches the binding.
  4. Each c-types predicate is defined once in src/, in c-types.sls.
  5. No top-level form in src/ outside c-types.sls names a C type's bound
     as a number: ±2^15, 2^16, ±2^31, 2^31-1, 2^32, 2^32-1, 2^63, 2^63-1,
     2^64, 2^64-1. So a new hand-written range fails.

The words other than `caller` are not checked against the source: the
table forces a decision for each new position, and review holds the word.

### 3. Edge rows (a new pure suite, tests/test-c-types.sps)

For each predicate, the edges written as literals, not computed:
min-1 → out, min → in, max → in, max+1 → out, and 1.0, 1/2, "1", #f → out.
A predicate computed from `foreign-sizeof` that allowed the unsigned range
for a signed type fails max+1. Added to PURE_TESTS.

## The table, as the survey found the positions

| Binding | # | Type | Word |
|---|---|---|---|
| raw-errno-name, raw-errno-value | 1 | int | size |
| raw-copy-in | 3, 4 | size_t | size |
| raw-copy-out | 3 | size_t | libuv |
| raw-zero | 2 | size_t | size |
| raw-alloc | 1 | size_t | size |
| raw-strerror-r, raw-err-name-r | 1 | int | libuv |
| raw-strerror-r, raw-err-name-r | 3 | size_t | constant |
| uv-handle-size, uv-req-size | 1 | int | constant |
| uv-loop-run | 2 | int | constant |
| raw-timer-start | 3, 4 | unsigned-64 | (caller c-u64? uv-timer-start!) |
| uv-timer-set-repeat | 2 | unsigned-64 | (caller c-u64? uv-timer-set-repeat!) |
| uv-tcp-bind | 3 | unsigned-int | constant |
| uv-tcp-nodelay | 2 | int | constant |
| uv-tcp-keepalive | 2 | int | constant |
| uv-tcp-keepalive | 3 | unsigned-int | (caller c-unsigned-int? uv-tcp-keepalive!) |
| raw-ip4-addr, raw-ip6-addr | 2 | int | (caller valid-port? try-fill-sockaddr!) |
| raw-listen | 2 | int | (caller c-int? uv-listen!) |
| raw-write | 4 | unsigned-int | (caller c-unsigned-int? uv-write*!) |
| raw-getnameinfo | 5 | int | constant |
| raw-ip-name | 3 | size_t | constant |
| uv-process-kill | 2 | int | constant |
| uv-kill | 1 | int | (caller c-int? uv-kill!) |
| uv-kill | 2 | int | constant |
| uv-pipe-init | 3 | int | constant |
| raw-signal-start, raw-signal-start-oneshot | 3 | int | constant |

## What the scan cannot see

- which argument a predicate is applied to: D naming P is taken as P
  checking the position, and a check on another argument would pass;
- whether a `constant`, `libuv` or `size` word is true;
- values carried through records or pairs, arithmetic, and
  procedure-valued parameters.

## Mutations planned

- `uv-kill!` without its `c-int?` check: row 3 names `(uv-kill 1)`.
- `c-int?`'s max 2^32-1: test-c-types' max+1 row, and test-process's pid rows.
- A new foreign call with an `int` parameter, unlisted: row 1.
- A listed position that no longer exists: row 1.
- A `caller` entry whose P is for another type (`c-u64?` on `uv-kill 1`):
  row 3.
- A `caller` entry whose D does not reach the binding: row 3.
- A hand-written `2147483648` back in tcp.sls: row 5.
- A second definition of `c-int?` in process.sls: row 4 (and row 5).
- A foreign call taking `boolean`: row 2.
- `fill-scalars!` without the stdio-count check: none fails in a suite
  (≥ 2^31 entries), so it is held by row 3 only if the count joins the
  table; it does not (memory writes are out of scope): logged as uncovered.

## Not in scope

Memory writes (`c-int-set!` and the like) get the typed checks above but no
table. The keepalive delay's Linux limit (> 32767 is EINVAL on a socket)
is libuv's and the kernel's, not a C type's.

## Revised after the adversarial review (as built)

An Opus review found three gaps that would let the uv-kill! shape back in,
and several smaller ones. What was built instead:

- **Places, not positions.** The table is keyed (binding, index, applier),
  the applier being each definition in src/ that names the binding. A
  definition that passes its own parameter through is worded
  `(forwards j)`, and each definition naming it is then a place too. A new
  path to a binding, such as a group kill calling `uv-kill` directly, is a
  new place, and fails until worded. 64 places today.
- **`(caller P v)` names the variable.** Every call the applier makes to
  the binding (directly, or through `handle-call!`, whose position k is its
  argument k+2) must pass V, or a number literal P holds; and the applier
  must apply P, or a predicate defined with P (`valid-port?`,
  `valid-milliseconds?`, `c-int-fd?`), to V. P must be the c-types
  predicate for the position's type. Checking `total` where `n` is passed,
  or a predicate reached only through a helper on another argument, fails.
- **A constant or libuv place passes no parameter of its own applier,** so
  a pass-through cannot be worded constant. `size` is exempt: a caller's
  offset bounded by a buffer is passed as a parameter.
- **The spawn fills run inside the step** (the plan's "outside steps only"
  was false). They write with `try-c-int-set!` and a new
  `try-c-u32-set!`, which answer #f, and src/ may name neither raising
  writer. `c-int-set!` refuses a value no C int holds, with
  `'value-out-of-range`, for its callers in the tests.
- **`c-size?`** joins c-types; `alloc-block`, `zero-out!`, `copy-out` and
  `try-copy-in!` check their sizes with it, and test-c-types holds that
  every fixnum is a size_t.
- **The bound scan** folds `(expt 2 k)`, `(ash 1 k)` and either less one,
  for k in 31, 32, 63, 64, and has a live row on a fixture. ±2^15 and 2^16
  are not on its list: no foreign call takes a short, and 65536 is a
  buffer size here. `free!` and `free-block!` use `c-uptr?`.
- **One foreign call per definition,** held by a row.
- **uptr and void\*** are not covered by rules 3-4 as the plan said; they
  are left out as addresses, which the rule cannot see.

Mutations: `.plans/int-range-rule-mutation-log.md`.

## After a second review, of the built rule

A read-only Opus review of the built change found no behaviour change in
the public API, four false statements in shipped files (fixed), and holes
in the rule. Changed in response:

- Every word but the new `(via H)` needs a call site; `via` names the
  procedure the applier hands the binding to (`constants-init!`,
  `start-signal!`), and the rule checks it does.
- `r-call` is read as `handle-call!` is: `(r-call binding code)` passes
  `code` at position 1. The errno chain stops at `uv-errno-condition`,
  which checks its code with `c-int?` and gives a code no C int holds the
  message "unknown error".
- `forwards` is checked per case-lambda arm; a family predicate must be
  `(define (f x) (P x))` or `(… (and (P x) …))`; a caller's check must come
  before, in its arm, each call that passes the variable.
- `src-definitions` splices top-level begins, and a row holds every
  foreign call to a top-level define the scan reads.
- `integer-types` is rule 5's scalars less an explicit list.
- The bound scan also flags `(expt 2 e)` with `e` computed from
  `foreign-sizeof`.
- `uv-write!`'s start is checked with `c-size?` and worded `caller`, so
  `size` means only values the binding computes or a span's length.
