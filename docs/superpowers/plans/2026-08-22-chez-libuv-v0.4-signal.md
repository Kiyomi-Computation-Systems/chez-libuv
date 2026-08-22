# chez-libuv v0.4 Signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind `uv_signal_t` — in-loop signal watching — as `(libuv signal)`, per the Accepted spec `.plans/2026-08-22-chez-libuv-v0.4-signal-design.md`, ADR-0017, and ADR-0008's third amendment, with every vendor fact already measured (`spike/signal/FINDINGS.md`, EV-1..EV-10, both platforms, zero surprises).

**Architecture:** A thirteenth locked trampoline (`signal`, `(uptr int) → void`) in `(libuv private native)`; a `uv-signal-record` handle kind in `(libuv private handles)` following the process-record shape; a timer-sized public library `src/libuv/signal.sls` whose library body late-installs `signal-dispatch` (the DNS/process seam); the signal vocabulary validators lifted from `process.sls` into `native.sls` (their recorded second-user rule). Mode is fixed per handle (`'signal-mode-fixed`), the watchable set is the ADR-0016 nine minus `sigkill`/`sigstop` (`'signal-unwatchable`), and the callback receives the signal symbol.

**Tech Stack:** Chez Scheme 10.4.1 (floor), R6RS libraries, libuv 1.52.1 (pinned vendored submodule; floor 1.44.0), SRFI-64 suites, the constants-only C shim (ADR-0002).

## Global Constraints

Every task's requirements implicitly include all of these. Copy them into each task brief's **inherited obligations** alongside the task-specific ones.

- **Repo:** `/Users/yuzu/github/chez-libuv`, branch `feat/v0.4-signal`. Conventional Commits with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Run a single suite with:** `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs CHEZ_LIBUV_TEST_CHEZ="$(command -v chez)" chez --program tests/<suite>.sps` (run `make build deps` once first so the shim and SRFI libs exist). Run `make test` (expect final line `ALL SUITES PASSED`) before every commit.
- **ADR-0002:** the C shim is constants-only — never wrap a `uv_*` call there.
- **ADR-0005:** no constant is ever transcribed into Scheme or C source; every number is a shim table row read at build time. `snapshot-ref` never falls through — a name missing from `constants.sls`'s `snapshot-names` raises `&uv-constant-unavailable` at first use.
- **ADR-0007:** the registry is the GC root; `uv-close!` is the only path to freeing; the close dispatcher is the only place a handle pointer dies; forgotten closes show as unbalanced debug counters, never GC sweeps.
- **ADR-0008 (third amendment):** one locked trampoline per callback TYPE; `dispatcher-names` is APPEND-ONLY at the end; the frozen thirteen-name literals in tests/test-loop.sps and tests/test-native.sps are deliberate friction — widen them FIRST, watch them fail, and record that RED evidence in the task's mutation log.
- **Public libraries never take or return pointers.** Every argument is validated before the first native call; a failed native call leaves nothing half-built.
- **Test discipline (spec §9.1/§9.2):** every wait whose predicate depends on a callback being delivered uses `run-until/ticking`; plain `run-until` only where a suite timer already keeps the loop waking or in close-drains. Sentinels are symbols, never `#f`/`0`. Every callback under test calls `(collect)`. Assert on observed deliveries, never on which iteration delivered them. **Every self-sent signal has a continuous guard watcher armed on its signum for the send's whole window** (an unwatched self-send lands on `SIG_DFL` and kills the suite — EV-3), except inside a child process whose death IS the assertion.
- **Vendor facts are settled** (spike, both platforms): do not re-litigate EV-1..EV-10; tests assert the measured behavior.

## File Structure

| File | Responsibility (delta) |
|---|---|
| `src/libuv-shim.c` / `.h` | `UV_SIGNAL` table row; `signal` debug-counter triple in both branches + prototypes |
| `src/libuv/private/constants.sls` | `UV_SIGNAL` in `snapshot-names`; `(uv-signal-type)` accessor + export |
| `src/libuv/private/native.sls` | thirteenth trampoline; signal raw bindings + two `*-native` wrappers; `uv-os-getpid-native`; signal counters; lifted `signal-symbol->int`/`term-signal->value` |
| `src/libuv/private/handles.sls` | `uv-signal-record`; `'signal` in `handle-kinds`; `count-handle-free!` arm |
| `src/libuv/signal.sls` (new) | constructor, three verbs, mode/watchable policy, `signal-dispatch` + late install |
| `src/libuv/process.sls` | imports lifted validators back; gated `uv-os-getpid` |
| `src/libuv/handle.sls` | kind-keyed `uv-signal?` |
| `src/libuv.sls` | facade imports `(libuv signal)`; six new exports by name |
| `Makefile` | export `CHEZ_LIBUV_TEST_CHEZ=$(CHEZ)` into both suite loops |
| `tests/test-signal.sps` (new) | the signal suite |
| `tests/signal-child.sps` (new) | E2E child program (outside the `test-*` wildcard) |
| `tests/test-loop.sps`, `tests/test-native.sps` | frozen literals → thirteen; signal stub row |
| `tests/test-process.sps`, `tests/test-facade.sps`, `tests/test-lifecycle.sps` | `uv-os-getpid` rows; facade rows; signal counter-balance rows |
| `README.org`, `CHANGELOG.md` | v0.4 status, graceful-shutdown example, the SQ-S1 caveat |

---

### Task 1: Shim row, counter triple, and the constants three-part edit

**Files:**
- Modify: `src/libuv-shim.c` (constant table ends near line 158; counter blocks near lines 211-315)
- Modify: `src/libuv-shim.h` (prototypes end near line 88)
- Modify: `src/libuv/private/constants.sls` (`snapshot-names` at line 100; accessors near line 359; export block near line 55)
- Test: `tests/test-native.sps`

**Interfaces:**
- Consumes: nothing new.
- Produces: shim symbols `chez_uv_count_signal_new`, `chez_uv_count_signal_free`, `chez_uv_live_signal`; constants accessor `(uv-signal-type) → exact integer` exported from `(libuv private constants)`. Task 2 binds the counters; Task 4's constructor calls `(uv-signal-type)`.

**Inherited obligations:** Global constraints only.

- [ ] **Step 1: Write the failing test**

In `tests/test-native.sps`, find the import clause naming `(libuv private constants)` and add `uv-signal-type` to it (it is an `(only ...)` clause; if `uv-timer-type` is already imported there, add beside it — otherwise extend the clause with both). Then add this row immediately after the existing constants assertions (search for `uv-timer-type` or `snapshot` to find them; any point after native init is fine):

```scheme
(test-equal "UV_SIGNAL is snapshotted and distinct from the other handle type tags"
  'distinct-positive
  (if (and (integer? (uv-signal-type))
           (exact? (uv-signal-type))
           (positive? (uv-signal-type))
           (not (memv (uv-signal-type)
                      (list (uv-timer-type) (uv-tcp-type)
                            (uv-process-type) (uv-named-pipe-type)))))
      'distinct-positive
      'wrong))
```

(If `uv-tcp-type`/`uv-process-type`/`uv-named-pipe-type` are not already imported, add them to the same `(only ...)` clause.)

- [ ] **Step 2: Run to verify it fails**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-native.sps`
Expected: FAIL — either an unbound `uv-signal-type` at expand time, or `&uv-constant-unavailable` naming `UV_SIGNAL`.

- [ ] **Step 3: Shim edits**

In `src/libuv-shim.c`, after the `{ "SIGSTOP", SIGSTOP },` row (line ~156), before the closing `};`:

```c
  /* v0.4 signal (design spec 2026-08-22 §5.5; ADR-0017). */
  { "UV_SIGNAL", UV_SIGNAL },
```

In the `#ifdef CHEZ_LIBUV_DEBUG_COUNTERS` branch, beside the pipe/process counters: add `static long live_signal = 0;` to the static declarations block, and after the `chez_uv_live_process` function:

```c
void chez_uv_count_signal_new(void)  { live_signal += 1; }
void chez_uv_count_signal_free(void) { live_signal -= 1; }
long chez_uv_live_signal(void)       { return live_signal; }
```

In the `#else` (no-op) branch, after the process no-ops:

```c
void chez_uv_count_signal_new(void)  { }
void chez_uv_count_signal_free(void) { }
long chez_uv_live_signal(void)       { return 0; }
```

In `src/libuv-shim.h`, after the `chez_uv_live_spawn_options` prototype (before `#endif`):

```c
void chez_uv_count_signal_new(void);
void chez_uv_count_signal_free(void);
long chez_uv_live_signal(void);
```

- [ ] **Step 4: The constants three-part edit**

In `src/libuv/private/constants.sls`:

1. `snapshot-names` (line ~100): append a final entry before the closing paren of the quoted list:

```scheme
      ;; v0.4 signal (ADR-0017)
      UV_SIGNAL
```

2. Beside `(define (uv-named-pipe-type) ...)` (line ~359):

```scheme
  ;; v0.4 signal handle type tag (design spec 2026-08-22 §5.5; ADR-0017)
  (define (uv-signal-type) (snapshot-ref 'UV_SIGNAL))
```

3. Export block (line ~55, beside `uv-process-type uv-named-pipe-type`): add `uv-signal-type` to that line.

- [ ] **Step 5: Rebuild and verify it passes**

Run: `make build` then the Step 2 command.
Expected: the shim relinks; the new row PASSES; suite exits 0.

- [ ] **Step 6: Full suite, commit**

Run: `make test` — expected `ALL SUITES PASSED`.

```bash
git add src/libuv-shim.c src/libuv-shim.h src/libuv/private/constants.sls tests/test-native.sps
git commit -m "feat: UV_SIGNAL shim row, signal counter triple, constants snapshot"
```

---

### Task 2: The thirteenth trampoline and the signal entry points (native.sls)

**Files:**
- Modify: `src/libuv/private/native.sls` (exports ~29-141; counters ~307-322; `live-counts` ~897-908; `dispatcher-names` ~932-934; trampolines ~1044-1162; process/pipe entry points ~1244-1261)
- Test: `tests/test-loop.sps:199-202`, `tests/test-native.sps:1411-1414` and the stub rows near 1430

**Interfaces:**
- Consumes: Task 1's shim counter symbols.
- Produces (all exported from `(libuv private native)`): `uv-signal-init (uptr uptr) → int`, `uv-signal-stop (uptr) → int` (raw); `(uv-signal-start-native handle-ptr signum) → int` and `(uv-signal-start-oneshot-native handle-ptr signum) → int` (wrappers baking in the one signal trampoline); `uv-os-getpid-native () → int` (raw); `count-signal-new!`, `count-signal-free!`; `live-counts` gains a `(signal . n)` row; `dispatcher-names` ends in `signal`.

**Inherited obligations:** ADR-0008 third amendment — **the frozen literals are widened FIRST and their failure recorded as RED evidence in this task's mutation log** before native.sls changes; `'signal` is appended at the END of `dispatcher-names`; the trampoline entry point stays module-private, leaving the file only inside the two wrappers.

- [ ] **Step 1: Widen the frozen literals (the failing tests)**

In `tests/test-loop.sps` (line ~199) and `tests/test-native.sps` (line ~1411), change both occurrences of:

```scheme
(test-equal "dispatcher-names names the twelve callback types the design commits to"
  '(alloc read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo exit walk)
  dispatcher-names)
```

to:

```scheme
(test-equal "dispatcher-names names the thirteen callback types the design commits to"
  '(alloc read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo exit walk signal)
  dispatcher-names)
```

In `tests/test-native.sps`, after the walk stub row (the `"the walk slot holds the raising uninstalled stub"` assertion, ~line 1445), add the signal row with its real arity:

```scheme
;; The signal slot, v0.4's thirteenth: uv_signal_cb's own (handle signum)
;; arity. It shares connection's arity and still has its own slot -- the
;; per-TYPE rule ADR-0008's third amendment states in its own terms.
(test-assert "the signal slot holds the raising uninstalled stub"
  (guard (e (#t (and (uv-error? e)
                     (string=? (condition-message e)
                               "callback dispatchers have not been installed"))))
    ((dispatcher-ref 'signal) 0 0)
    #f))
```

- [ ] **Step 2: Run both suites to verify they fail (RED evidence — record it)**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-loop.sps` and the same for `tests/test-native.sps`.
Expected: both FAIL by name on the thirteen-name literal (actual list has twelve); test-native additionally fails the signal stub row with `'unknown-dispatcher`. Record this in the task's mutation log.

- [ ] **Step 3: native.sls edits**

1. `dispatcher-names` (line ~932) — append at the END:

```scheme
  (define dispatcher-names
    '(alloc read connection write-done close timer shutdown connect
      getaddrinfo getnameinfo exit walk signal))
```

2. After `walk-callable` (line ~1117), the thirteenth trampoline:

```scheme
  ;; uv_signal_cb: void (*)(uv_signal_t*, int signum). It SHARES
  ;; connection's (uptr int) arity and still gets its own locked trampoline:
  ;; the rule is one per callback TYPE, not per arity (ADR-0008, third
  ;; amendment -- the original eight already contain same-arity
  ;; distinct-type pairs: timer and close are both (uptr) -> void).
  (define signal-callable
    (foreign-callable (lambda (handle signum)
                        ((dispatcher-ref 'signal) handle signum))
                      (uptr int) void))
```

3. `trampolines-locked` (line ~1136): the list gains `signal-callable` after `exit-callable walk-callable`.

4. Beside the other entry points (line ~1162):

```scheme
  (define signal-cb-entry (foreign-callable-entry-point signal-callable))
```

5. After the pipe entry points (line ~1261), the signal block:

```scheme
  ;; --- the signal entry points (design spec 2026-08-22 §5.2, ADR-0017) ---
  ;; uv_signal_start AND uv_signal_start_oneshot both take a uv_signal_cb,
  ;; so both are bound raw- and reached only through the wrappers below,
  ;; which bake in the ONE signal trampoline -- two verbs, one callback
  ;; TYPE (ADR-0008 third amendment). uv_signal_init and uv_signal_stop
  ;; take no callback and are exported raw; every int is an errno
  ;; (uv_signal_stop is rc 0 even on a never-started watcher, EV-2).
  (define uv-signal-init
    (foreign-procedure "uv_signal_init" (uptr uptr) int))
  (define raw-signal-start
    (foreign-procedure "uv_signal_start" (uptr uptr int) int))
  (define raw-signal-start-oneshot
    (foreign-procedure "uv_signal_start_oneshot" (uptr uptr int) int))
  (define uv-signal-stop
    (foreign-procedure "uv_signal_stop" (uptr) int))

  (define (uv-signal-start-native handle-ptr signum)
    (raw-signal-start handle-ptr signal-cb-entry signum))

  (define (uv-signal-start-oneshot-native handle-ptr signum)
    (raw-signal-start-oneshot handle-ptr signal-cb-entry signum))

  ;; uv_os_getpid: this process's own pid. No errno, no callback; the
  ;; public gated spelling lives in (libuv process) beside uv-process-pid.
  (define uv-os-getpid-native
    (foreign-procedure "uv_os_getpid" () int))
```

6. Counters, beside the process counters (line ~315):

```scheme
  (define count-signal-new!
    (foreign-procedure "chez_uv_count_signal_new" () void))
  (define count-signal-free!
    (foreign-procedure "chez_uv_count_signal_free" () void))
  (define live-signal (foreign-procedure "chez_uv_live_signal" () long))
```

7. `live-counts` (line ~897): add `(cons 'signal (live-signal))` after the `spawn-options` row.

8. Export block: after the process/pipe entry-point exports (line ~127) add:

```scheme
          ;; the signal entry points (design spec 2026-08-22 §5.2,
          ;; ADR-0017). The two start calls take a uv_signal_cb and are NOT
          ;; exported raw: both wrappers bake in the ONE signal trampoline
          ;; (ADR-0008 third amendment). init/stop take no callback.
          ;; uv-os-getpid-native is the raw pid query (libuv process) gates.
          uv-signal-init uv-signal-start-native
          uv-signal-start-oneshot-native uv-signal-stop
          uv-os-getpid-native
```

and in the counters export block (line ~141) add a line `count-signal-new!      count-signal-free!` before the closing paren.

- [ ] **Step 4: Run to verify green**

Run the two Step 2 commands again. Expected: both PASS (test-native's install/stub loops map over `dispatcher-names`, so they widen automatically).

- [ ] **Step 5: Full suite, commit**

Run: `make test` — `ALL SUITES PASSED`.

```bash
git add src/libuv/private/native.sls tests/test-loop.sps tests/test-native.sps
git commit -m "feat: thirteenth trampoline (signal) + signal/pid entry points"
```

---

### Task 3: The validator lift and public uv-os-getpid

**Files:**
- Modify: `src/libuv/private/native.sls` (after `require-callback`, line ~822; exports near ~109)
- Modify: `src/libuv/process.sls` (delete lines ~525-542 `signal-symbol->int` and ~582-599 `term-signal->value`; exports line 49)
- Modify: `src/libuv.sls` (process export block line ~78)
- Test: `tests/test-process.sps`, `tests/test-facade.sps`

**Interfaces:**
- Consumes: Task 2's `uv-os-getpid-native`.
- Produces: `(signal-symbol->int sig who) → exact integer` and `(term-signal->value n) → symbol | exact integer | #f`, exported from `(libuv private native)` (Task 5's library layers the watchable check on top and the dispatcher uses the reverse map); public `(uv-os-getpid) → exact positive integer` exported from `(libuv process)` and the facade (the suite's self-delivery address).

**Inherited obligations:** The lift is verbatim code motion — behavior of `uv-kill!`/`uv-process-kill!`/exit payloads must not change (the existing test-process.sps rows are the check); `uv-os-getpid` goes through `ensure-native-loaded!` (the `uv-version` precedent).

- [ ] **Step 1: Write the failing tests**

In `tests/test-process.sps`, after the kill-vocabulary rows (search `signal-unknown`), add:

```scheme
(test-equal "uv-os-getpid answers a positive exact integer, stable across calls"
  'stable-positive
  (let ((a (uv-os-getpid)) (b (uv-os-getpid)))
    (if (and (integer? a) (exact? a) (positive? a) (= a b))
        'stable-positive
        'wrong)))
```

In `tests/test-facade.sps`, beside the other process-block rows (search `uv-kill!` or `uv-spawn!`; anywhere after the imports is fine):

```scheme
;; v0.4: the pid query rides the process block (ADR-0017 D8).
(test-equal "uv-os-getpid is re-exported and answers a positive exact integer"
  'positive
  (if (and (integer? (uv-os-getpid)) (exact? (uv-os-getpid))
           (positive? (uv-os-getpid)))
      'positive
      'wrong))
```

- [ ] **Step 2: Run to verify they fail**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps` (and the facade suite).
Expected: FAIL at expand time — `uv-os-getpid` unbound.

- [ ] **Step 3: The lift**

In `src/libuv/private/native.sls`, immediately after `require-callback` (line ~822), add — the two procedure bodies are **moved verbatim** from `process.sls` (they are quoted in full here so this task needs no other file open):

```scheme
  ;; --- the signal vocabulary (ADR-0016, ADR-0017) ------------------------
  ;; Lifted verbatim from process.sls on its second user, (libuv signal) --
  ;; the PR #4 rule the original comment promised. SENDING vocabulary: the
  ;; closed nine-symbol set plus exact 0 (the POSIX liveness probe,
  ;; kill(pid,0)). Symbols only otherwise: 15 is refused even though it is
  ;; SIGTERM everywhere, because "everywhere" is how transcription bugs
  ;; start. WATCHING's narrower refusal policy (no sigkill/sigstop, no 0)
  ;; layers on top in signal.sls, not here: vocabulary is shared, refusal
  ;; policy is not (ADR-0017).
  (define (signal-symbol->int sig who)
    (cond
      ((eqv? sig 0) 0)
      ((symbol? sig)
       (case sig
         ((sigterm) (sig-term)) ((sigkill) (sig-kill)) ((sigint) (sig-int))
         ((sighup) (sig-hup)) ((sigquit) (sig-quit))
         ((sigusr1) (sig-usr1)) ((sigusr2) (sig-usr2))
         ((sigcont) (sig-cont)) ((sigstop) (sig-stop))
         (else (raise (make-uv-invalid-argument who 'signal-unknown)))))
      (else (raise (make-uv-invalid-argument who 'signal-unknown)))))

  ;; The reverse map. 0 -> #f is EXIT-payload vocabulary ("exited
  ;; normally"); an unbound signal passes through RAW as its exact integer
  ;; -- never dropped, never fabricated (ADR-0016). The signal dispatcher
  ;; (v0.4) reuses it for uniformity: its signum is a validated watchable,
  ;; so only the symbol arms are reachable there.
  (define (term-signal->value n)
    (cond ((zero? n) #f)
          ((= n (sig-term)) 'sigterm)
          ((= n (sig-kill)) 'sigkill)
          ((= n (sig-int))  'sigint)
          ((= n (sig-hup))  'sighup)
          ((= n (sig-quit)) 'sigquit)
          ((= n (sig-usr1)) 'sigusr1)
          ((= n (sig-usr2)) 'sigusr2)
          ((= n (sig-cont)) 'sigcont)
          ((= n (sig-stop)) 'sigstop)
          (else n)))
```

Add `signal-symbol->int term-signal->value` to native.sls's export list beside `require-callback` (line ~109).

In `src/libuv/process.sls`: delete the two moved definitions (the `--- signals` comment block around line 525-542 keeps its first paragraph, retargeted: replace the deleted text with a two-line pointer comment `;; signal-symbol->int / term-signal->value moved to (libuv private native)` `;; on their second user, (libuv signal) -- ADR-0016's own lift rule, ADR-0017.`). The callers (`uv-process-kill!`, `uv-kill!`, `exit-dispatch`) need no edits — the names now resolve through the existing `(libuv private native)` import.

- [ ] **Step 4: Public uv-os-getpid**

In `src/libuv/process.sls`, after `uv-process-pid` (line ~571):

```scheme
  ;; (uv-os-getpid) -- this process's OWN pid, through the init gate like
  ;; every public nullary query (the uv-version precedent: the answer must
  ;; come from a library this binding has validated). It lives here beside
  ;; uv-process-pid because pid vocabulary is this module's (ADR-0017 D8);
  ;; the suites' self-delivery ((uv-kill! (uv-os-getpid) 'sigusr1)) is its
  ;; first consumer.
  (define (uv-os-getpid)
    (ensure-native-loaded!)
    (uv-os-getpid-native))
```

Change the export line 49 to:

```scheme
  (export uv-spawn! uv-process-kill! uv-kill! uv-process-pid uv-os-getpid)
```

In `src/libuv.sls`, process block (line ~78): change to

```scheme
          uv-spawn! uv-process-kill! uv-kill! uv-process-pid uv-os-getpid
```

- [ ] **Step 5: Run to verify green, full suite, commit**

Run the two Step 2 commands — PASS. Run `make test` — `ALL SUITES PASSED` (the lift is proven behavior-preserving by the untouched process rows staying green).

```bash
git add src/libuv/private/native.sls src/libuv/process.sls src/libuv.sls tests/test-process.sps tests/test-facade.sps
git commit -m "refactor: lift signal vocabulary to (libuv private native); add uv-os-getpid"
```

---

### Task 4: The signal handle exists and closes

**Files:**
- Modify: `src/libuv/private/handles.sls` (record after `uv-process-record` line ~389; `handle-kinds` line 478; `count-handle-free!` line ~999; export block — search the export list for `%make-uv-process-record` and add beside it)
- Modify: `src/libuv/handle.sls` (predicate after `uv-process?` line ~80; export line 18)
- Create: `src/libuv/signal.sls` (constructor only in this task)
- Create: `tests/test-signal.sps`

**Interfaces:**
- Consumes: `(uv-signal-type)` (Task 1), `count-signal-new!`/`count-signal-free!` (Task 2).
- Produces: `uv-signal-record` — parent `uv-handle-record`, kind `'signal`, fields `on-signal` (mutable, `#f` at construction) and `mode` (mutable, `#f` until a start verb pins `'continuous`/`'oneshot`); exports `%make-uv-signal-record uv-signal-record? signal-on-signal set-signal-on-signal! signal-mode set-signal-mode!`; public `(make-uv-signal loop) → record` from `(libuv signal)`; public `(uv-signal? x) → boolean` from `(libuv handle)`. Task 5 adds the verbs to the same library.

**Inherited obligations:** `'signal` MUST join `handle-kinds` in this task (or the teardown sweep never closes signal handles — spec §5.1); the close path itself needs zero changes (no owned buffers).

- [ ] **Step 1: Write the failing tests**

Create `tests/test-signal.sps`:

```scheme
#!r6rs
;;; SRFI-64 suite for (libuv signal) -- v0.4 (design spec
;;; .plans/2026-08-22-chez-libuv-v0.4-signal-design.md §9.3, ADR-0017).
;;;
;;; HARNESS RULES (§9.1/§9.2): every wait whose predicate depends on a
;;; callback is run-until/ticking with an iteration cap; sentinels are
;;; symbols, never #f or 0; every callback (collect)s; EVERY self-sent
;;; signal has a continuous GUARD watcher armed on its signum (EV-3: an
;;; unwatched self-send lands on SIG_DFL and kills this suite) -- except in
;;; the spawned child whose death IS the assertion.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). Never add this
;;; to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv signal)
        (libuv process)
        (libuv pipe)
        (libuv stream)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect getenv))

(define runner (test-runner-simple))
(test-runner-current runner)

(define (live-count kind) (cdr (assq kind (live-counts))))

(test-begin "signal")

(define signal-base (live-count 'signal))

;; --- construction and close (the whole ADR-0007 lifecycle) --------------
(define l0 (make-uv-loop))
(define s0 (make-uv-signal l0))

(test-assert "make-uv-signal answers an open signal handle"
  (and (uv-signal? s0) (uv-handle-open? s0)))

(test-assert "a signal handle is not a timer, and vice versa"
  (and (not (uv-timer? s0))
       (not (uv-signal? (make-uv-timer l0)))))

(test-equal "the signal counter counts the construction"
  (+ signal-base 1) (live-count 'signal))

(uv-close! s0)
(test-equal "close drains to 'closed"
  'satisfied (run-until l0 (lambda () (eq? (uv-handle-state s0) 'closed)) 64))

(uv-close! s0)  ;; a second close on 'closed is the documented no-op
(test-equal "close is idempotent and the state stays 'closed"
  'closed (uv-handle-state s0))

;; --- the teardown sweep (handle-kinds membership, spec §5.1) ------------
(define s1 (make-uv-signal l0))
(uv-loop-teardown! l0)
(test-equal "teardown swept the open signal handle to 'closed"
  'closed (uv-handle-state s1))

(test-equal "signal counter balanced after teardown"
  signal-base (live-count 'signal))

(test-end "signal")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
```

(The suite grows through Tasks 5-7; the `test-end`/`exit` lines stay last.)

- [ ] **Step 2: Run to verify it fails**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-signal.sps`
Expected: FAIL — library `(libuv signal)` not found.

- [ ] **Step 3: The record, kinds, and counter arm (handles.sls)**

After `uv-process-record` (line ~389):

```scheme
  ;; The signal child (v0.4 design spec §4.4, ADR-0017): like process, a
  ;; direct uv-handle-record child -- a watcher is not a stream. on-signal
  ;; is stored by the start verbs BEFORE arming (the timer discipline).
  ;; mode is #f until the first successful start verb pins it, then
  ;; 'continuous | 'oneshot for the life of the handle: it mirrors the
  ;; vendor's one-way UV_SIGNAL_ONE_SHOT ratchet (EV-8, measured), which is
  ;; why mode is trackable where armed-state is not -- oneshot auto-disarm
  ;; happens inside libuv, so a watching? flag would race the vendor's own
  ;; view (ADR-0017: no armed-state field, deliberately).
  (define-record-type (uv-signal-record %make-uv-signal-record uv-signal-record?)
    (parent uv-handle-record)
    (fields (mutable on-signal signal-on-signal set-signal-on-signal!)
            (mutable mode      signal-mode      set-signal-mode!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'signal loop) #f #f)))))
```

`handle-kinds` (line 478) — widen with its comment amended:

```scheme
  ;; Widened to five in v0.4: a signal watcher needs the same teardown
  ;; sweep (design spec 2026-08-22 §5.1 -- MANDATORY, or teardown never
  ;; closes it).
  (define handle-kinds '(timer tcp pipe process signal))
```

`count-handle-free!` (line ~999) — add the arm before `(else #f)`:

```scheme
      ((signal)  (count-signal-free!))
```

Export block: beside the process-record exports add
`%make-uv-signal-record uv-signal-record? signal-on-signal set-signal-on-signal! signal-mode set-signal-mode!`.
(`count-signal-free!` is already reachable — handles.sls imports `(libuv private native)`.)

- [ ] **Step 4: The library skeleton (signal.sls) and the predicate**

Create `src/libuv/signal.sls`:

```scheme
#!r6rs
;;; (libuv signal) -- uv_signal_t watching (v0.4 design spec, ADR-0017).
;;; The receiving half of the pair (libuv process)'s uv-kill! started.
;;;
;;; DELIVERY != CLOSE (ADR-0007/0017): neither delivery, uv-signal-stop!,
;;; nor oneshot auto-disarm closes the handle; the caller always
;;; uv-close!s, and close implicitly stops an armed watcher (EV-10).
;;;
;;; MODE IS FIXED PER HANDLE (D10, EV-8 -- measured): the first successful
;;; start verb pins 'continuous | 'oneshot; the other verb thereafter
;;; raises 'signal-mode-fixed. Changing mode = uv-close! + make-uv-signal.
;;;
;;; THE COEXISTENCE CAVEAT (SQ-S1, measured both platforms): watching
;;; sigint takes SIGINT away from the Chez runtime, and uv_signal_stop
;;; restores SIG_DFL -- NOT what was there before. libuv's behavior,
;;; surfaced not fixed (README carries the caveat).
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER.
(library (libuv signal)
  (export make-uv-signal
          uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; The make-uv-timer shape verbatim: size from the RUNNING library via
  ;; uv_handle_size, type tag from the shim (ADR-0005); a failed init frees
  ;; the block before the condition escapes, and nothing is registered or
  ;; counted yet.
  (define (make-uv-signal loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-signal)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-signal-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-signal-init (loop-pointer loop 'make-uv-signal) ptr)
                  'make-uv-signal))
      (let ((sig (%make-uv-signal-record ptr loop)))
        (registry-register! ptr 'signal loop sig)
        (count-signal-new!)
        sig)))

  ;; The verbs and the dispatcher land with the next task; nothing can arm
  ;; a watcher yet, so the 'signal dispatcher slot deliberately still holds
  ;; handles.sls's contained raising stub.
  (define (uv-signal-start! sig watch-symbol on-signal)
    (raise (make-uv-invalid-argument 'uv-signal-start! 'not-yet-implemented)))
  (define (uv-signal-start-oneshot! sig watch-symbol on-signal)
    (raise (make-uv-invalid-argument 'uv-signal-start-oneshot!
                                     'not-yet-implemented)))
  (define (uv-signal-stop! sig)
    (raise (make-uv-invalid-argument 'uv-signal-stop! 'not-yet-implemented))))
```

In `src/libuv/handle.sls`, after `uv-process?` (line ~80):

```scheme
  ;; Kind-keyed like the three above (v0.4 design spec §4.6): the predicate
  ;; lives with the kind vocabulary, not with the module that constructs
  ;; the handle.
  (define (uv-signal? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'signal)))
```

and add `uv-signal?` to the export list (line 18).

- [ ] **Step 5: Run to verify green, full suite, commit**

Run the Step 2 command — PASS. Run `make test` — `ALL SUITES PASSED` (test-signal.sps is auto-discovered by the `TESTS` wildcard; no Makefile edit).

```bash
git add src/libuv/private/handles.sls src/libuv/signal.sls src/libuv/handle.sls tests/test-signal.sps
git commit -m "feat: uv-signal-record + (libuv signal) constructor + uv-signal? (v0.4 task 4)"
```

---

### Task 5: The verbs, the refusal matrix, and the dispatcher

**Files:**
- Modify: `src/libuv/signal.sls` (replace the three stubs; add policy helpers + dispatcher + late install)
- Modify: `src/libuv.sls` (import + signal export block)
- Test: `tests/test-signal.sps` (grow), `tests/test-facade.sps` (five rows)

**Interfaces:**
- Consumes: Task 3's `signal-symbol->int`/`term-signal->value`; Task 2's `uv-signal-start-native`/`uv-signal-start-oneshot-native`/`uv-signal-stop`; Task 4's record accessors; handles.sls's `install-dispatch-procedure!`, `dispatch-guarded`, `registry-ref`, `record-orphan-callback!`, `handle-loop`, `handle-state`, `require-open-handle`, `handle-pointer`.
- Produces: public `(uv-signal-start! sig watch-symbol on-signal)`, `(uv-signal-start-oneshot! ...)`, `(uv-signal-stop! sig)` — contracts per spec §4.2; callback contract `(on-signal sig-symbol)`; refusal reasons `'signal-unknown`, `'signal-unwatchable`, `'signal-mode-fixed`, `'not-a-uv-signal`, `'on-signal-not-a-procedure`; the `'signal` dispatcher installed. Facade exports all five signal names + `uv-signal?`.

**Inherited obligations:** Validation order is kind → state → mode-compatibility → procedure → symbol, ALL before any native call; the callback is stored BEFORE arming (a pending same-signum delivery can dispatch on the very next run — EV-1's swap); **mode is pinned only after `uv-check` succeeds** (a refused or failed start pins nothing); the wrapper NEVER issues a bare stop-then-start for a same-signum rearm (the vendor short-circuit is the mechanism — EV-1; a wrapper stop would open the SIG_DFL window); every suite send is guarded (§9.2).

- [ ] **Step 1: Write the failing tests**

In `tests/test-signal.sps`, before `(test-end ...)`, add:

```scheme
;; --- the refusal matrix (§4.2, ADR-0017) --------------------------------
(define l2 (make-uv-loop))
(define sv (make-uv-signal l2))

(define (start-refusal sig-arg cb)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-signal-start! sv sig-arg cb)
    'no-raise))

(test-equal "sigkill is refused as unwatchable, before any native call"
  '(uv-signal-start! signal-unwatchable)
  (start-refusal 'sigkill (lambda (s) s)))

(test-equal "sigstop is refused as unwatchable"
  '(uv-signal-start! signal-unwatchable)
  (start-refusal 'sigstop (lambda (s) s)))

(test-equal "exact 0 is sending vocabulary, unknown to watching"
  '(uv-signal-start! signal-unknown)
  (start-refusal 0 (lambda (s) s)))

(test-equal "a raw integer is refused even where it is right (15)"
  '(uv-signal-start! signal-unknown)
  (start-refusal 15 (lambda (s) s)))

(test-equal "an unknown symbol is refused"
  '(uv-signal-start! signal-unknown)
  (start-refusal 'sigfoo (lambda (s) s)))

(test-equal "a non-procedure callback is refused by name"
  '(uv-signal-start! on-signal-not-a-procedure)
  (start-refusal 'sigusr1 'not-a-procedure))

(test-equal "a non-handle is refused by name"
  '(uv-signal-start! not-a-uv-signal)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start! "nope" 'sigusr1 (lambda (s) s))
    'no-raise))

(test-equal "a timer handle is the wrong kind, refused by name"
  '(uv-signal-start! not-a-uv-signal)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start! (make-uv-timer l2) 'sigusr1 (lambda (s) s))
    'no-raise))

(test-equal "a refused start pinned no mode"
  'no-mode (if (not (signal-mode-via-behavior sv)) 'no-mode 'pinned))

;; --- mode fixedness (D10, EV-8 -- measured) -----------------------------
;; sv becomes continuous; the oneshot verb must then refuse, armed or not.
(define sv-fired '())
(uv-signal-start! sv 'sigusr1 (lambda (s) (set! sv-fired (cons s sv-fired)) (collect)))

(test-equal "the oneshot verb on a continuous-mode handle raises 'signal-mode-fixed"
  '(uv-signal-start-oneshot! signal-mode-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start-oneshot! sv 'sigusr2 (lambda (s) s))
    'no-raise))

(uv-signal-stop! sv)
(test-equal "mode survives stop: still refused after uv-signal-stop!"
  '(uv-signal-start-oneshot! signal-mode-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start-oneshot! sv 'sigusr1 (lambda (s) s))
    'no-raise))

(define os (make-uv-signal l2))
(uv-signal-start-oneshot! os 'sigusr2 (lambda (s) (collect)))
(test-equal "the continuous verb on a oneshot-mode handle raises 'signal-mode-fixed"
  '(uv-signal-start! signal-mode-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start! os 'sigusr2 (lambda (s) s))
    'no-raise))

;; --- delivery (guard discipline: sv re-armed continuous on sigusr1) -----
(uv-signal-start! sv 'sigusr1 (lambda (s) (set! sv-fired (cons s sv-fired)) (collect)))
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "a self-sent SIGUSR1 arrives as its symbol"
  '(satisfied (sigusr1))
  (list (run-until/ticking l2 (lambda () (pair? sv-fired)) 512) sv-fired))

;; EV-6: two watchers on one signum both fire on one delivery.
(define twin-fired '())
(define twin (make-uv-signal l2))
(uv-signal-start! twin 'sigusr1
                  (lambda (s) (set! twin-fired (cons s twin-fired)) (collect)))
(set! sv-fired '())
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "both watchers on one signum fire once each (EV-6)"
  '(satisfied (sigusr1) (sigusr1))
  (list (run-until/ticking l2
                           (lambda () (and (pair? sv-fired) (pair? twin-fired)))
                           512)
        sv-fired twin-fired))

;; --- stop is idempotent (EV-2); closed handles refuse by state ----------
(define never-started (make-uv-signal l2))
(uv-signal-stop! never-started)
(uv-signal-stop! never-started)
(test-assert "stop on a never-started watcher is rc 0, twice (EV-2)"
  #t)

(uv-close! never-started)
(run-until l2 (lambda () (eq? (uv-handle-state never-started) 'closed)) 64)
(test-equal "verbs on a closed handle raise &uv-handle-closed naming 'signal"
  'signal
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e)))
    (uv-signal-stop! never-started)
    'no-raise))

(uv-loop-teardown! l2)
(test-equal "signal counter balanced after the verb sections"
  signal-base (live-count 'signal))
```

Also define, near the suite's top (after `live-count`), the behavioral mode probe (D7: no structural armed/mode predicate is public, so the suite reads mode through refusal behavior):

```scheme
;; Mode is deliberately not public (§4.4); the suite observes "no mode
;; pinned" behaviorally: BOTH verbs still being willing to validate past
;; the mode check is what an unpinned handle looks like. This probe asks
;; with a deliberately-invalid callback so nothing is ever armed: reaching
;; 'on-signal-not-a-procedure means the mode gate passed.
(define (signal-mode-via-behavior sig)
  (define (gate-passes? verb)
    (guard (e ((uv-invalid-argument? e)
               (eq? (uv-invalid-argument-reason e) 'on-signal-not-a-procedure)))
      (verb sig 'sigusr1 'not-a-procedure)
      #f))
  (not (and (gate-passes? uv-signal-start!)
            (gate-passes? uv-signal-start-oneshot!))))
```

In `tests/test-facade.sps`, beside the Task 3 row:

```scheme
;; v0.4 signal block (design spec §4.6): one exercised row per export.
(define sig-loop (make-uv-loop))
(define sig-h (make-uv-signal sig-loop))

(test-assert "make-uv-signal and uv-signal? cross the facade"
  (uv-signal? sig-h))

(test-equal "uv-signal-start-oneshot! crosses the facade and validates"
  'signal-unwatchable
  (guard (e (#t (uv-invalid-argument-reason e)))
    (uv-signal-start-oneshot! sig-h 'sigkill (lambda (s) s))
    'no-raise))

(test-equal "uv-signal-start! crosses the facade and validates"
  'signal-unknown
  (guard (e (#t (uv-invalid-argument-reason e)))
    (uv-signal-start! sig-h 'sigfoo (lambda (s) s))
    'no-raise))

(uv-signal-stop! sig-h)   ; rc 0 on a never-started watcher (EV-2)
(uv-close! sig-h)
(uv-loop-teardown! sig-loop)
```

- [ ] **Step 2: Run to verify they fail**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-signal.sps`
Expected: FAIL — first refusal row answers `'(uv-signal-start! not-yet-implemented)`. The facade suite fails at expand time (signal names not exported).

- [ ] **Step 3: The real verbs and dispatcher (signal.sls)**

Replace the three stubs (everything after `make-uv-signal`) with:

```scheme
  ;; --- policy helpers (§4.2, ADR-0017) ------------------------------------
  ;; The watchable subset: ADR-0016's nine minus the two the kernel forbids
  ;; catching. Layered on top of the lifted signal-symbol->int: vocabulary
  ;; is shared, refusal policy is not. Exact 0 -- the SENDING liveness
  ;; probe -- names no signal, so watching refuses it as unknown, not
  ;; unwatchable.
  (define (watch-symbol->int sig who)
    (when (memq sig '(sigkill sigstop))
      (raise (make-uv-invalid-argument who 'signal-unwatchable)))
    (when (eqv? sig 0)
      (raise (make-uv-invalid-argument who 'signal-unknown)))
    (signal-symbol->int sig who))

  (define (require-signal-handle sig who)
    (unless (uv-signal-record? sig)
      (raise (make-uv-invalid-argument who 'not-a-uv-signal)))
    (require-open-handle sig who))

  ;; The one start path both verbs share. VALIDATION ORDER (§4.2): kind,
  ;; state, mode compatibility, procedure, symbol -- all before any native
  ;; call. The callback is stored BEFORE arming (a pending same-signum
  ;; delivery can dispatch on the very next uv-run: the vendor's
  ;; same-signum restart is a callback swap that preserves pending
  ;; deliveries, EV-1 -- which is also why this wrapper NEVER issues a
  ;; stop-then-start for a rearm: a last-watcher stop would install SIG_DFL
  ;; and a watched fatal signal in that window kills the process). MODE IS
  ;; PINNED ONLY AFTER uv-check SUCCEEDS: a refused or failed start pins
  ;; nothing (ADR-0017 D10 -- "the first start verb" means the first one
  ;; that arms).
  (define (start-signal! sig watch-symbol on-signal wanted-mode
                         native-start who)
    (require-signal-handle sig who)
    (let ((mode (signal-mode sig)))
      (when (and mode (not (eq? mode wanted-mode)))
        (raise (make-uv-invalid-argument who 'signal-mode-fixed))))
    (require-callback on-signal who 'on-signal-not-a-procedure)
    (let ((signum (watch-symbol->int watch-symbol who)))
      (set-signal-on-signal! sig on-signal)
      (uv-check (native-start (handle-pointer sig who) signum) who)
      (set-signal-mode! sig wanted-mode)))

  ;; Continuous: fires on every delivery until stopped or closed. Rearm
  ;; while armed is allowed WITHIN the mode: a signum change is libuv's
  ;; internal stop-then-start; same-signum is the pending-preserving
  ;; callback swap (EV-1, measured).
  (define (uv-signal-start! sig watch-symbol on-signal)
    (start-signal! sig watch-symbol on-signal 'continuous
                   uv-signal-start-native 'uv-signal-start!))

  ;; Oneshot: fires exactly once; libuv disarms the watcher itself, and
  ;; once no watcher remains for the signum PROCESS-WIDE the disposition
  ;; reverts to SIG_DFL (EV-3) -- first-SIGTERM-drains, second-kills.
  ;; REARMING FROM INSIDE ITS OWN CALLBACK DOES NOT TAKE EFFECT: the
  ;; vendor auto-stop runs after the callback returns and undoes it,
  ;; rc 0 (EV-9, measured; D11). Rearm from a later dispatch instead.
  (define (uv-signal-start-oneshot! sig watch-symbol on-signal)
    (start-signal! sig watch-symbol on-signal 'oneshot
                   uv-signal-start-oneshot-native 'uv-signal-start-oneshot!))

  ;; Idempotent (EV-2: rc 0 on a never-started or auto-disarmed watcher).
  ;; The 'open pre-check is load-bearing, not cosmetic: the native calls
  ;; assert-abort on a closing handle in assert-enabled builds, and close
  ;; stops the watcher itself (EV-10) -- so no native stop ever follows
  ;; uv-close!.
  (define (uv-signal-stop! sig)
    (require-signal-handle sig 'uv-signal-stop!)
    (uv-check (uv-signal-stop (handle-pointer sig 'uv-signal-stop!))
              'uv-signal-stop!))

  ;; --- the dispatcher (timer-shaped; §5.3) --------------------------------
  ;; Delivers only to 'open handles (timer discipline: a delivery dequeued
  ;; for a 'closing handle is dropped silently -- close already stopped the
  ;; watcher, EV-10). The signum is converted through the lifted reverse
  ;; map for uniformity; start validated the symbol, so only symbol arms
  ;; are reachable. Runs under dispatch-guarded: store-and-reraise
  ;; unchanged.
  (define (signal-dispatch handle-ptr signum)
    (let ((sig (registry-ref handle-ptr)))
      (if (uv-signal-record? sig)
          (when (eq? (handle-state sig) 'open)
            (let ((on-signal (signal-on-signal sig)))
              (when on-signal
                (dispatch-guarded
                 (handle-loop sig)
                 (lambda () (on-signal (term-signal->value signum)))))))
          (record-orphan-callback! 'signal handle-ptr))))

  ;; The late install (the dns.sls seam's third application, ADR-0008): the
  ;; 'signal slot held handles.sls's contained raising stub until this
  ;; instant; a process image that never imports (libuv signal) keeps it.
  (define signal-dispatch-installed
    (install-dispatch-procedure! 'signal signal-dispatch)))
```

- [ ] **Step 4: The facade block (libuv.sls)**

Add `(libuv signal)` to the import list (after `(libuv process)`, line ~125). Add `uv-signal?` to the handle export block (line 31, beside `uv-process?`). After the process export block (line ~78), add:

```scheme
          ;; --- Signal, from (libuv signal) ---
          ;; The receiving half of the process module's kill pair
          ;; (ADR-0017). Mode fixed per handle ('signal-mode-fixed);
          ;; watchable set = the nine minus sigkill/sigstop
          ;; ('signal-unwatchable); DELIVERY != CLOSE. Watching sigint
          ;; takes SIGINT from the Chez runtime and stop leaves SIG_DFL --
          ;; the README carries the measured caveat.
          make-uv-signal
          uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!
```

- [ ] **Step 5: Run to verify green, full suite, commit**

Run the Step 2 commands — PASS. Run `make test` — `ALL SUITES PASSED`.

```bash
git add src/libuv/signal.sls src/libuv.sls tests/test-signal.sps tests/test-facade.sps
git commit -m "feat: signal verbs, mode/watchable policy, dispatcher + facade (v0.4 task 5)"
```

---

### Task 6: The measured-behavior suite (EV-1/5/9/10, oneshot, lifecycle)

**Files:**
- Test: `tests/test-signal.sps` (grow), `tests/test-lifecycle.sps` (signal rows)

**Interfaces:**
- Consumes: everything public from Tasks 1-5. No production code changes in this task — if a scenario fails, STOP and report; the vendor facts are measured, so a red row here means the binding (or the test) is wrong, not libuv.
- Produces: suite coverage the final review will hold the milestone to.

**Inherited obligations:** Stop-suppression and same-signum-rearm probes live in SEPARATE loop drains (suppression is a dispatch-time signum comparison, not a purge — EV-5 corollary; §6); close-wait assertions stay iteration-agnostic (signal close callbacks can defer while trapped signals drain — EV-10); every send guarded.

- [ ] **Step 1: Write the scenarios (all in `tests/test-signal.sps`, before `test-end`)**

```scheme
;; ========================================================================
;; The measured-behavior sections (spike/signal/FINDINGS.md; every EV cited
;; was measured on both platforms -- a red row here indicts the binding).
;; ========================================================================
(define l3 (make-uv-loop))
(define g3-fired 0)   ; the section guard: continuous on sigusr1, armed throughout
(define g3 (make-uv-signal l3))
(uv-signal-start! g3 'sigusr1 (lambda (s) (set! g3-fired (+ g3-fired 1)) (collect)))

(define (send-usr1-and-wait-guard!)
  (let ((before g3-fired))
    (uv-kill! (uv-os-getpid) 'sigusr1)
    (run-until/ticking l3 (lambda () (> g3-fired before)) 512)))

;; --- oneshot: exactly once, rearm-outside works (EV-2, spike leg1) ------
(define once-fired 0)
(define once (make-uv-signal l3))
(uv-signal-start-oneshot! once 'sigusr1
                          (lambda (s) (set! once-fired (+ once-fired 1)) (collect)))
(test-equal "oneshot fires on the first delivery" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "…exactly once" 1 once-fired)
(test-equal "a second send reaches only the guard" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "the oneshot stayed disarmed (auto-disarm)" 1 once-fired)
(uv-signal-stop! once)   ; rc 0 on an auto-disarmed watcher (EV-2)
(uv-signal-start-oneshot! once 'sigusr1
                          (lambda (s) (set! once-fired (+ once-fired 1)) (collect)))
(test-equal "rearm from OUTSIDE the callback delivers again"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…and again exactly once" 2 once-fired)

;; --- EV-9: an in-callback rearm is silently undone ----------------------
(define incb-fired 0)
(define incb (make-uv-signal l3))
(define (incb-cb s)
  (set! incb-fired (+ incb-fired 1))
  ;; The rearm attempt the vendor auto-stop undoes after this returns.
  (uv-signal-start-oneshot! incb 'sigusr1 incb-cb)
  (collect))
(uv-signal-start-oneshot! incb 'sigusr1 incb-cb)
(test-equal "in-callback-rearm oneshot fires" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "the in-callback rearm did NOT take effect (EV-9): second send silent"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…count still 1" 1 incb-fired)

;; --- EV-1a: continuous rearm across a signum change ---------------------
(define sw-fired-1 0)
(define sw-fired-2 0)
(define sw (make-uv-signal l3))
(uv-signal-start! sw 'sigusr1 (lambda (s) (set! sw-fired-1 (+ sw-fired-1 1)) (collect)))
(test-equal "armed on the old signum" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "…delivered" 1 sw-fired-1)
;; Switch signum while armed -- and arm a sigusr2 guard FIRST (§9.2).
(define g3b-fired 0)
(define g3b (make-uv-signal l3))
(uv-signal-start! g3b 'sigusr2 (lambda (s) (set! g3b-fired (+ g3b-fired 1)) (collect)))
(uv-signal-start! sw 'sigusr2 (lambda (s) (set! sw-fired-2 (+ sw-fired-2 1)) (collect)))
(test-equal "after the switch, the old signum reaches only its guard"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…switched watcher silent on old signum" 1 sw-fired-1)
(uv-kill! (uv-os-getpid) 'sigusr2)
(test-equal "…and fires on the new signum (EV-1a)"
  'satisfied (run-until/ticking l3 (lambda () (positive? sw-fired-2)) 512))

;; --- EV-1b: same-signum restart swaps the callback, keeps pending -------
;; ITS OWN DRAIN, apart from the stop-suppression probe below (§6).
(define swap-old 0)
(define swap-new 0)
(define swap (make-uv-signal l3))
(uv-signal-start! swap 'sigusr2 (lambda (s) (set! swap-old (+ swap-old 1)) (collect)))
(let ((before g3b-fired))
  (uv-kill! (uv-os-getpid) 'sigusr2)          ; pending: accepted inside kill
  (uv-signal-start! swap 'sigusr2             ; same-signum swap, PRE-run
                    (lambda (s) (set! swap-new (+ swap-new 1)) (collect)))
  (test-equal "the guard proves the pending delivery was dispatched"
    'satisfied (run-until/ticking l3 (lambda () (> g3b-fired before)) 512)))
(test-equal "the swap preserved the pending delivery for the NEW callback (EV-1b)"
  '(0 1) (list swap-old swap-new))

;; --- EV-5: send -> stop -> run suppression (the discriminating shape) ---
(define ev5-a 0)
(define ev5-b 0)
(define ev5-A (make-uv-signal l3))
(define ev5-B (make-uv-signal l3))
(uv-signal-start! ev5-A 'sigusr2 (lambda (s) (set! ev5-a (+ ev5-a 1)) (collect)))
(uv-signal-start! ev5-B 'sigusr2 (lambda (s) (set! ev5-b (+ ev5-b 1)) (collect)))
(uv-kill! (uv-os-getpid) 'sigusr2)            ; accepted synchronously
(uv-signal-stop! ev5-A)                       ; stop A BEFORE the next run
(test-equal "B's delivery proves the event was dequeued"
  'satisfied (run-until/ticking l3 (lambda () (positive? ev5-b)) 512))
(test-equal "A's silence proves suppression (EV-5)" 0 ev5-a)

;; --- a raising callback rides store-and-reraise, counters balance -------
(define boom (make-uv-signal l3))
(uv-signal-start! boom 'sigusr1 (lambda (s) (collect) (raise 'signal-boom)))
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "a callback raise surfaces from uv-run as &uv-callback-error"
  'signal-boom
  (guard (e ((uv-callback-error? e) (uv-callback-error-cause e)))
    (let drain ((i 0))
      (if (< i 512) (begin (uv-run l3 'once) (drain (+ i 1))) 'never-raised))))
(uv-signal-stop! boom)

;; --- EV-10: close with a delivery pending -------------------------------
(define ev10-fired 0)
(define ev10 (make-uv-signal l3))
(uv-signal-start! ev10 'sigusr1
                  (lambda (s) (set! ev10-fired (+ ev10-fired 1)) (collect)))
(define g3-before-ev10 g3-fired)              ; snapshot BEFORE the send
(uv-kill! (uv-os-getpid) 'sigusr1)            ; pending for ev10 AND guard g3
(uv-close! ev10)                              ; close BEFORE the next run
(test-equal "the close drains (iteration-agnostic: signal closes may defer, EV-10)"
  'satisfied
  (run-until/ticking l3 (lambda () (eq? (uv-handle-state ev10) 'closed)) 512))
(test-equal "the closing watcher's callback was suppressed" 0 ev10-fired)
(test-assert "the guard still got THIS delivery (delta, not cumulative)"
  (> g3-fired g3-before-ev10))

;; --- EV-4: an armed watcher keeps the loop alive ------------------------
(test-assert "the loop is alive while watchers are armed (EV-4)"
  (uv-loop-alive? l3))

(uv-loop-teardown! l3)
(test-equal "teardown swept every armed watcher; counters balanced"
  signal-base (live-count 'signal))
```

- [ ] **Step 2: Run to verify — every row green**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-signal.sps`
Expected: PASS on every new row (the behavior is already implemented; these rows pin the measured facts). If a row is red, STOP: report it — do not "fix" a vendor fact.

- [ ] **Step 3: Lifecycle rows**

In `tests/test-lifecycle.sps`, add `(libuv signal)` to the imports, and append (before its `test-end`), following the timer rows' idiom:

```scheme
;; --- v0.4 signal rows (design spec §9.3; ADR-0007) ----------------------
(define sig-base (live-count 'signal))

;; Row: ordinary close balances.
(let ((l (make-uv-loop)))
  (let ((s (make-uv-signal l)))
    (test-equal "signal counter counts a construction" (+ sig-base 1) (live-count 'signal))
    (uv-close! s)
    (run-until l (lambda () (eq? (uv-handle-state s) 'closed)) 64))
  (uv-loop-teardown! l))
(test-equal "signal counter balanced after an ordinary close" sig-base (live-count 'signal))

;; Row: a raising callback still balances (the guard invariant, ADR-0008).
(let ((l (make-uv-loop)))
  (let ((s (make-uv-signal l)))
    (uv-signal-start! s 'sigusr1 (lambda (x) (collect) (raise 'lifecycle-boom)))
    (uv-kill! (uv-os-getpid) 'sigusr1)
    (guard (e (#t 'reraised))
      (let drain ((i 0)) (when (< i 256) (uv-run l 'once) (drain (+ i 1))))))
  (uv-loop-teardown! l))
(test-equal "signal counter balanced after a raising callback" sig-base (live-count 'signal))

;; Row: 100 make/arm/fire/close iterations with a full collection each.
(let ((l (make-uv-loop)))
  (let loop ((i 0))
    (when (< i 100)
      (let ((fired 0))
        (let ((s (make-uv-signal l)))
          (uv-signal-start! s 'sigusr1
                            (lambda (x) (set! fired (+ fired 1)) (collect)))
          (uv-kill! (uv-os-getpid) 'sigusr1)
          (run-until/ticking l (lambda () (positive? fired)) 512)
          (uv-close! s)
          (run-until l (lambda () (eq? (uv-handle-state s) 'closed)) 64)
          (collect)))
      (loop (+ i 1))))
  (uv-loop-teardown! l))
(test-equal "signal counter balanced after 100 arm/fire/close iterations"
  sig-base (live-count 'signal))
```

(`uv-kill!`/`uv-os-getpid` need `(libuv process)` in that suite's imports — add it if absent, plus `getenv`-free `(only (chezscheme) collect)` is already there.)

- [ ] **Step 4: Run to verify, full suite + memory lane, commit**

Run test-lifecycle and test-signal individually — PASS. Run `make test` — `ALL SUITES PASSED`. Run `make test-memory` — expected green (no threadpool, no io_uring in the signal path; no new suppressions).

```bash
git add tests/test-signal.sps tests/test-lifecycle.sps
git commit -m "test: measured-behavior signal suite (EV-1/5/9/10, oneshot, lifecycle)"
```

---

### Task 7: End-to-end graceful shutdown (the spawned child) + Makefile export

**Files:**
- Modify: `Makefile` (the `test:` recipe line ~384 and the `test-memory` suite loop — both `$(CHEZ) --program` invocations)
- Create: `tests/signal-child.sps`
- Test: `tests/test-signal.sps` (the E2E scenario)

**Interfaces:**
- Consumes: v0.3's `uv-spawn!` (`(uv-spawn! loop file args options-alist on-exit)`, stdio spec `(list 'ignore (list 'pipe p 'from-child))`, `on-exit` receiving `(status sig)`), `uv-read-start!` (`(uv-read-start! pipe on-data on-eof on-error)`, on-data `(bv start end)`), `make-uv-pipe`, `uv-process-pid`, `uv-kill!`, and the whole Task 5 surface.
- Produces: env var `CHEZ_LIBUV_TEST_CHEZ` in every suite's environment; the graduated SQ-S2 scenario with the **three-ack** handshake (READY / GOT1 / DISARMED — spike finding SQ-S2-F1).

**Inherited obligations:** THE THREE-ACK HANDSHAKE IS LOAD-BEARING: the in-callback GOT1 proves delivery, not disarm (the vendor auto-stop runs after the callback returns, EV-9) — kill #2 gates on DISARMED, never on GOT1. Kill #2 is sent before the child exits (pid validity ends at the exit callback). The suite skips with a NAMED row when `CHEZ_LIBUV_TEST_CHEZ` is unset — deterministic and honest, never silent.

- [ ] **Step 1: The Makefile export**

In the `test:` recipe (line ~384), change the invocation line to:

```make
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) CHEZ_LIBUV_TEST_CHEZ=$(CHEZ) $(CHEZ) --program $$t || fail=1; \
```

In the `test-memory` recipe, find each line invoking `$(CHEZ) --program` with a `CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS)` prefix (both the Linux/valgrind and macOS/ASan arms) and add `CHEZ_LIBUV_TEST_CHEZ=$(CHEZ)` beside the existing variable, identically.

- [ ] **Step 2: The child program**

Create `tests/signal-child.sps` (the name is deliberately outside the `test-*.sps` wildcard, so `make test` never runs it as a suite):

```scheme
#!r6rs
;;; tests/signal-child.sps -- the spawned-child half of test-signal.sps's
;;; end-to-end graceful-shutdown scenario (v0.4 design spec §9.3; spike
;;; finding SQ-S2-F1). NOT a suite: the name stays outside the test-*.sps
;;; wildcard on purpose.
;;;
;;; Protocol, one line each on stdout (the parent's from-child pipe):
;;;   READY      after the oneshot sigterm watcher is armed
;;;   GOT1       from INSIDE the sigterm callback -- proves DELIVERY
;;;   DISARMED   from a LATER dispatch (a repeating timer's next tick) --
;;;              proves DISARM: the vendor auto-stop runs only after the
;;;              signal callback returns (EV-9), so any later dispatch is
;;;              after it by construction. The parent gates kill #2 here.
;;; Then kill #2 lands on SIG_DFL (EV-3) and this process dies (0 sigterm).
;;; Surviving to the iteration cap is the named failure: exit 43.
(import (rnrs)
        (libuv)
        (only (chezscheme) collect flush-output-port))

(define l (make-uv-loop))
(define got #f)
(define acked #f)

(define (say! line)
  (put-string (current-output-port) line)
  (put-string (current-output-port) "\n")
  (flush-output-port (current-output-port)))

(define w (make-uv-signal l))
(define tick (make-uv-timer l))

(uv-signal-start-oneshot! w 'sigterm
  (lambda (s) (set! got #t) (say! "GOT1") (collect)))

(uv-timer-start! tick
  (lambda (t)
    (when (and got (not acked))
      (set! acked #t)
      (say! "DISARMED")))
  5 5)

(say! "READY")

;; Iteration-capped stepping, never wall-clock: kill #2 ends this process
;; long before 4000 ticks of the 5 ms timer.
(let step ((i 0))
  (when (< i 4000)
    (uv-run l 'once)
    (step (+ i 1))))

(say! "SURVIVED")
(exit 43)
```

- [ ] **Step 3: The E2E scenario (test-signal.sps, before `test-end`)**

```scheme
;; ========================================================================
;; End-to-end graceful shutdown: the SQ-S2 spike probe, graduated (§9.3).
;; Three-ack handshake (SQ-S2-F1): kill #2 gates on DISARMED, never GOT1.
;; ========================================================================
(define chez-exe (getenv "CHEZ_LIBUV_TEST_CHEZ"))

(if (not chez-exe)
    (test-equal "E2E graceful shutdown SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (let ((l4 (make-uv-loop)))
      (define out (make-byte-collector))
      (define eof-mark 'not-yet)
      (define done 'not-yet)
      (define child-out (make-uv-pipe l4))
      (define proc
        (uv-spawn! l4 chez-exe
                   (list "chez" "--program" "tests/signal-child.sps")
                   (list (cons 'stdio (list 'ignore
                                            (list 'pipe child-out 'from-child))))
                   (lambda (status sig) (collect) (set! done (list status sig)))))
      (define (ack-lines)
        (let ((s (utf8->string (collector-bytes out))))
          (let count ((i 0) (n 0))
            (if (= i (string-length s))
                n
                (count (+ i 1) (if (char=? (string-ref s i) #\newline) (+ n 1) n))))))
      (uv-read-start! child-out
                      (lambda (bv start end) (collect) (collect-span! out bv start end))
                      (lambda () (collect) (set! eof-mark 'eof))
                      (lambda (err) (collect) (set! eof-mark (list 'error err))))

      (test-equal "the child armed and acked READY"
        'satisfied (run-until/ticking l4 (lambda () (>= (ack-lines) 1)) 4096))

      (uv-kill! (uv-process-pid proc) 'sigterm)          ; kill #1

      (test-equal "the child acked delivery (GOT1, from inside the callback)"
        'satisfied (run-until/ticking l4 (lambda () (>= (ack-lines) 2)) 4096))

      (test-equal "the child acked disarm (DISARMED, from a later dispatch)"
        'satisfied (run-until/ticking l4 (lambda () (>= (ack-lines) 3)) 4096))

      (uv-kill! (uv-process-pid proc) 'sigterm)          ; kill #2, gated on DISARMED

      (test-equal "the child exited"
        'satisfied (run-until/ticking l4 (lambda () (pair? done)) 4096))
      (test-equal "…killed by the second SIGTERM: (0 sigterm) -- graceful then killed"
        '(0 sigterm) done)
      (test-equal "the ack transcript is exactly READY/GOT1/DISARMED"
        "READY\nGOT1\nDISARMED\n" (utf8->string (collector-bytes out)))

      (uv-loop-teardown! l4)
      (test-equal "signal+process+pipe counters balanced after the E2E"
        signal-base (live-count 'signal))))
```

- [ ] **Step 4: Run to verify**

Run: `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs CHEZ_LIBUV_TEST_CHEZ="$(command -v chez)" chez --program tests/test-signal.sps`
Expected: PASS, including the E2E rows. Then run once WITHOUT the variable and confirm the named SKIPPED row appears instead of a failure.

- [ ] **Step 5: Full suite + memory lane, commit**

Run: `make test` — `ALL SUITES PASSED`; `make test-memory` — green.

```bash
git add Makefile tests/signal-child.sps tests/test-signal.sps
git commit -m "test: E2E graceful shutdown with three-ack handshake (v0.4 task 7)"
```

---

### Task 8: Docs — README, CHANGELOG

**Files:**
- Modify: `README.org` (the Status section's "no `uv_signal_t`" sentence, ~line 35-40; a new signal subsection beside the process one)
- Modify: `CHANGELOG.md` (new v0.4.0 section at top)

**Interfaces:** none — prose only, but the claims must match the shipped behavior exactly.

**Inherited obligations:** The SQ-S1 caveat text ships VERBATIM in spirit from `spike/signal/FINDINGS.md` ("the honest caveat"); the example is the graceful-shutdown idiom §6 documents (the watcher closes itself in the drain).

- [ ] **Step 1: README edits**

In the Status section, change the sentence that currently reads (line ~35):

```
No filesystem, no UDP, no zero-copy I/O ([[file:.plans/decisions/0009-copy-at-the-boundary.md][ADR-0009]] copies at the boundary and reserves the API shape for a later zero-copy variant), no ~uv_signal_t~ (signal *sending* ships with the process module; handling is a recorded future milestone).
```

to:

```
No filesystem, no UDP, no zero-copy I/O ([[file:.plans/decisions/0009-copy-at-the-boundary.md][ADR-0009]] copies at the boundary and reserves the API shape for a later zero-copy variant).
```

Add a signal section beside the process documentation (match the surrounding org heading level):

```org
** Signals: watching (v0.4)

~(libuv signal)~ completes the pair the process module's ~uv-kill!~ started
([[file:.plans/decisions/0017-signal-watching-vocabulary-and-mode.md][ADR-0017]]).
The watchable set is the closed vocabulary minus ~sigkill~/~sigstop~
(~'signal-unwatchable~ — the kernel forbids catching them); exact ~0~ stays
sending-only. A watcher's *mode* is fixed by its first start verb —
~uv-signal-start!~ (continuous) or ~uv-signal-start-oneshot!~ — and the other
verb thereafter raises ~'signal-mode-fixed~; changing mode is
~uv-close!~ + ~make-uv-signal~ (the vendored ~UV_SIGNAL_ONE_SHOT~ flag is a
one-way per-handle ratchet, measured in [[file:spike/signal/FINDINGS.md][the
v0.4 spike]]). The callback receives the signal as a symbol. Delivery is not
close: the caller always ~uv-close!~s the handle.

Graceful shutdown, the driving use case — first ~SIGTERM~ drains, a second
one kills (the disposition reverts to ~SIG_DFL~ once the oneshot fires):

#+begin_src scheme
(define loop (make-uv-loop))
(define watcher (make-uv-signal loop))
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    ;; close the listener, start the drain timer, then:
    (uv-close! watcher)))
(uv-run loop 'default)
#+end_src

*Measured caveat* (both platforms, [[file:spike/signal/FINDINGS.md][FINDINGS]]
SQ-S1): watching ~sigint~ takes SIGINT away from the Chez runtime — while the
watcher is armed, Ctrl-C is delivered to the loop callback and Chez's keyboard
interrupt never fires; after ~uv-signal-stop!~ (or oneshot auto-disarm) the
disposition is *SIG_DFL*, not what was there before, so SIGINT then terminates
the process. This applies equally to handlers installed with Chez's
~register-signal-handler~. It is libuv's behavior
(~uv__signal_unregister_handler~), surfaced rather than fixed. Rearming a
oneshot watcher from inside its own callback does not take effect (the vendor
auto-stop runs after the callback returns) — rearm from a later dispatch.
```

- [ ] **Step 2: CHANGELOG**

Add at the top of `CHANGELOG.md`, matching the existing sections' format:

```markdown
## v0.4.0 — 2026-08-XX

### Added

- `(libuv signal)`: `make-uv-signal`, `uv-signal-start!`,
  `uv-signal-start-oneshot!`, `uv-signal-stop!`; kind predicate
  `uv-signal?`; `uv-os-getpid` (exported from `(libuv process)` beside
  `uv-process-pid`). The callback receives the watched signal as a symbol.
- The thirteenth locked trampoline (`signal`) — ADR-0008's third
  amendment, which states the one-per-callback-TYPE rule in its own terms
  (`uv_signal_cb` shares `connection`'s arity and still gets its own slot).

### Semantics

- Watchable set: the closed nine-symbol vocabulary minus
  `sigkill`/`sigstop` (`'signal-unwatchable`); exact `0` stays
  sending-only (`'signal-unknown`); `sigchld` remains inexpressible (libuv
  owns SIGCHLD for child reaping — vendor fact V6).
- **Mode is fixed per handle** (`'signal-mode-fixed`): the first
  successful start verb pins continuous/oneshot for the handle's life;
  mode change is close-and-recreate (the vendored `UV_SIGNAL_ONE_SHOT`
  ratchet, measured — spike/signal/FINDINGS.md EV-8).
- DELIVERY ≠ CLOSE: stop and oneshot auto-disarm never close; the caller
  always `uv-close!`s (close implicitly stops an armed watcher, EV-10).
- Rearming a oneshot watcher from inside its own callback does not take
  effect (the vendor auto-stop runs after the callback returns, EV-9).

### Notes

- Measured caveat (SQ-S1, both platforms): watching `sigint` takes SIGINT
  from the Chez runtime, and `uv-signal-stop!` leaves `SIG_DFL` — neither
  `keyboard-interrupt-handler` nor `register-signal-handler` handling is
  restored. libuv's behavior, surfaced rather than fixed (README).
- The signal vocabulary validators lifted from `process.sls` to
  `(libuv private native)` on their second user — the rule recorded at
  their v0.3 introduction. `(libuv process)`'s surface is unchanged
  (plus `uv-os-getpid`).
```

(Replace `2026-08-XX` with the release date at tag time.)

- [ ] **Step 3: Full suite, commit**

Run: `make test` — `ALL SUITES PASSED`.

```bash
git add README.org CHANGELOG.md
git commit -m "docs: README signal section + caveat, CHANGELOG v0.4.0"
```

---

## Plan Self-Review (performed at write time)

- **Spec coverage:** §3 module layout → Tasks 1-5,7; §4.1 → Task 4; §4.2 (verbs, refusals, mode, rearm, stop) → Task 5; §4.3 payload → Task 5 (dispatcher) + Task 6 (assertions); §4.4 mode field → Task 4; §4.5 `uv-os-getpid` → Task 3; §4.6 facade + conditions → Tasks 5, 3; §5.1-§5.5 internals → Tasks 1, 2, 4, 5; §6 semantics → Tasks 5, 6; §7 EV facts → asserted across Tasks 5-7; §8 memory → Task 6 Step 4 memory lane; §9.1-§9.3 → Tasks 4-7 (guard discipline, ticking waits, three-ack E2E, skip row, frozen literals, facade rows, lifecycle rows); §9.4 → Task 6 Step 4; §11 docs → Task 8. ADR-0008 RED-evidence obligation → Task 2 Step 2.
- **Placeholder scan:** none — every step carries complete code or an exact locator+content instruction.
- **Type consistency:** `uv-os-getpid-native` (native) vs public `uv-os-getpid` (process) used consistently; `signal-mode`/`set-signal-mode!`, `signal-on-signal`/`set-signal-on-signal!` consistent across Tasks 4-5; `watch-symbol->int` private to signal.sls; refusal reasons consistent with ADR-0017.
