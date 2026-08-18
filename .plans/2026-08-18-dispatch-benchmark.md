# Dispatch-path benchmark: is the per-fire seam overhead worth removing?

Resolves two deferred Minors from the final whole-branch review
(`.superpowers/sdd/progress.md`, Task 6 and Task 7 triage):

- `dispatcher-ref` hashes a symbol through an eq-hashtable on every callback
  fire (`src/libuv/private/native.sls`) — proposed replacement: vector slots
  at fixed indices.
- the seam closure allocates a rest-args list and performs a second
  hashtable lookup (`dispatch-procedure`) plus `apply` on every fire
  (`src/libuv/private/handles.sls`, `seam-closure`) — proposed replacement:
  arity-specific `case-lambda`.

The review's own instruction was benchmark first, optimize only if
warranted.

## Method

`scratchpad/bench-dispatch.sps` (session scratchpad; reproduced below in
Results), run on the branch build (Chez 10.2.0, macOS arm64, libuv 1.52.1,
pkg-config leg), machine otherwise idle. Four measurements:

- **A** `(dispatcher-ref 'read)` as shipped, 10M reps.
- **B** `(vector-ref slots 1)` — the proposed slot lookup, 10M reps.
- **C1/C2** a rest-args `(lambda args (apply f args))` closure vs an
  arity-specific `case-lambda`, called with 3 args, 10M reps each.
- **D** a REAL fire: a timeout-0, no-repeat timer re-armed from inside its
  own callback, 200k fires driven by `uv-run` — the cheapest callback path
  the binding can execute (C trampoline → `dispatcher-ref` → seam closure →
  `timer-dispatch` → Scheme callback), with no I/O in the way. D therefore
  already CONTAINS one of everything A–C measure.

## Results

| Measurement | ns/op |
|---|---|
| A `dispatcher-ref` (eq-hashtable, symbol key) | 8.7 |
| B vector slot | 2.8 |
| C1 rest-args lambda + `apply` (3 args) | 2.5 |
| C2 `case-lambda` fixed arity (3 args) | 2.7 |
| D real timer fire, everything included | 26 060 |

- Replaceable per-fire cost: (A − B) + (C1 − C2) ≈ **6 ns** — and the C1−C2
  half is negative-to-noise: Chez compiles the rest-args + `apply` shape as
  well as the fixed arity one, so only the hashtable half is real.
- The cheapest possible real fire costs **~26 µs**. The replaceable cost is
  **~0.02%** of it. A TCP read fire adds syscalls and a payload copy on top,
  making the fraction smaller still.

## Verdict

**Not warranted.** Vector slots and arity-specific case-lambdas would buy
under a thousandth of even the cheapest fire while giving up the
symbol-keyed table that `install-callback-dispatchers!` validates by name.
Revisit only if a profile of a real Stage-5-style workload ever shows the
dispatch seam itself — not the fire — on the hot path, per the review's
"revisit if Stage 5 read path hot".
