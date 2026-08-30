# chez-libuv v0.5 Flow Control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make chez-libuv's three per-connection memory surfaces visible and adjustable from Scheme, and bind the one write-side congestion quantity the layer above cannot derive — without changing any behaviour.

**Architecture:** Four new `foreign-procedure` bindings in `(libuv private native)`, wrapped by six public procedures across `(libuv handle)`, `(libuv stream)` and `(libuv tcp)`. One test-only task lands first, against unchanged code, so the behaviour-preserving claim is guarded rather than asserted. No new library, no new allocation class, no record-layout change.

**Tech Stack:** Chez Scheme 10.4.1+ (R6RS libraries), C99 shim, libuv ≥ 1.44.0 (vendored pin 1.52.1), SRFI-64, GNU/BSD make, Valgrind (Linux) / ASan (macOS).

**Source spec:** `.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md`

> **Trust the tree over this plan.** An earlier draft of this document shipped a `uv-accept!` call with the wrong arity, a `compare-bytes` return value that does not exist, an errno accessor that does not exist, and a self-review that certified two of those as correct. All are fixed below, but the lesson stands: if a snippet here disagrees with the source, **the source is right** — read it, fix the plan, and note the correction in the task's mutation log. Do not "fix" working code to match this document.

## Global Constraints

Every task's requirements implicitly include this section.

- **No behaviour change.** v0.5 adds procedures and documentation. It changes no default, no signature, no existing code path. `CHANGELOG.md` is all **Added**.
- **No policy in the binding.** Every addition reports or configures. `README.org:19-21` — "no connection-state or backpressure policy of its own" — stays true.
- **libuv floor is 1.44.0** (`Makefile:57-59`). All four natives predate it. **No `check-pins` version movement.**
- **The shim never wraps a `uv_*` call** (ADR-0002). No `src/libuv-shim.c` changes.
- **Every `foreign-procedure` is defined after `load-shared-object`** in `native.sls`. A misplaced definition fails at *import* time, pointing nowhere near the mistake.
- **A raw native takes the `-native` suffix only where a public wrapper would otherwise collide with it.** The tree is not uniform here on purpose: `uv-tcp-getsockname`, `uv-tcp-init`, `uv-accept` and `uv-read-stop` are unsuffixed because nothing shadows them; `uv-read-start-native`, `uv-write-native`, `uv-shutdown-native` are suffixed because something does. Tasks 2–4 add four suffixed bindings, all of which would collide.
- **Validate before the first allocation; free on every path.** Five of the six new wrappers allocate. The idiom is `tcp.sls:148-165`.
- **`alloc-zeroed`, never `foreign-alloc`, for the `int` out-parameter.** libuv's get-vs-set discriminator reads `*value` (`vendor/libuv/src/unix/core.c:255-261`); uninitialised heap makes a getter perform a `setsockopt` with garbage.
- **Gate on `require-open-handle`, never bare `require-handle`.** `require-handle` (`handles.sls:454`) checks only that the argument *is* a handle. `require-open-handle` (`:462`) is what raises `&uv-handle-closed`. Every sibling gate in the tree (`require-open-tcp` at `tcp.sls:53`, `require-open-stream` at `stream.sls:39`) uses the latter.
- **Test discipline (AGENTS.md).** Every suite ends with its own `(exit …)`. Iteration caps, never wall-clock. Sentinels never `#f` or `0`. Every new assertion is watched-to-fail against a mutation in `src/`, logged with its output.
- **What a failing SRFI-64 row actually prints.** `(test-runner-simple)` opens no log port, so `testing-impl.scm:496-502` emits exactly `FAIL <test name>` and the end-of-suite `# of unexpected failures N`. **Expected values, actual values and source lines are never printed.** Every `Expected:` line below is written in that form; do not promise output the runner cannot produce.
- **New suites are never added to `PURE_TESTS`** — they reach native code. They are auto-discovered by the `TESTS` wildcard and auto-enrolled in the Valgrind lane via `MEMORY_TESTS := $(TESTS)`.
- **Pass counts are stated as `count of top-level test-* forms in the file`.** Recompute rather than trust: `grep -cE '^\(test-(equal|assert|eqv|eq) ' tests/<suite>.sps`. Baseline: `test-tcp.sps` = 168.
- **Run `make test` before every commit.**

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `tests/uv-testing.sls` | shared fixtures; gains `compare-bytes` lifted from its second user | 1 |
| `tests/test-echo.sps` | loses the now-shared `compare-bytes` | 1 |
| `tests/test-tcp.sps` | default pin; peer-address fixture and rows; write-ordering rows | 1, 4 |
| `tests/test-flow.sps` | **new** — cross-stream isolation, buffer-size wrappers, congestion fixture | 1, 2, 3 |
| `tests/test-facade.sps` | six exercised exports, distributed to the tasks that create them | 2, 3, 4 |
| `src/libuv/private/native.sls` | four `-native` bindings and their exports | 2, 3, 4 |
| `src/libuv/handle.sls` | the four buffer-size wrappers | 2 |
| `src/libuv/stream.sls` | `uv-stream-write-queue-size`; the corrected `:187` comment | 3, 5 |
| `src/libuv/tcp.sls` | `uv-tcp-peer-address`; re-export of the stream verb | 3, 4 |
| `src/libuv/private/handles.sls` | the corrected `:1001` comment | 5 |
| `src/libuv.sls` | facade: six names | 2, 3, 4 |
| `Makefile` | the vendor tripwire and its help text | 5 |
| `docs/api.md`, `README.org`, `CHANGELOG.md`, `Akku.manifest`, `.plans/decisions/` | release | 6 |

**Task order note.** The buffer-size wrappers (Task 2) land *before* the write-queue gauge (Task 3), inverting the spec's §14 stage numbering. Reason: the gauge's congestion fixture needs a shrunk `SO_SNDBUF` to be deterministic, so building the gauge first would mean watching three mutations fail against a fixture the next task rewrites — a mutation log describing code that no longer exists. The wrappers have no dependency on the gauge, so this ordering costs nothing.

Stage 0 (the `spike/flow/` measurement) is **not** in this plan: it produces no `src/` change and gates only the follow-up milestone that sets the default.

**Mutation-log naming.** One file per task: `.plans/flow-task-N-mutation-log.md`, matching the `signal-task-N-` precedent. Every task has one; a task with no mutation records why.

---

### Task 0: Branch

- [ ] **Step 1: Sync and branch (idempotent)**

```bash
git checkout main && git pull --ff-only origin main
git rev-parse --verify feat/v0.5-flow-control >/dev/null 2>&1 \
  && git checkout feat/v0.5-flow-control \
  || git checkout -b feat/v0.5-flow-control
git status --porcelain
```

Expected: on `feat/v0.5-flow-control`, `git status --porcelain` empty. The branch may already exist carrying the design spec commits; that is fine.

---

### Task 1: Test-only forward guards

Two assertions the milestone's "no behaviour change" claim depends on, both written against unchanged code. Nothing in `src/` changes.

**Files:**
- Modify: `tests/uv-testing.sls`, `tests/test-echo.sps`, `tests/test-tcp.sps`
- Create: `tests/test-flow.sps`, `.plans/flow-task-1-mutation-log.md`

**Interfaces:**
- Produces: `compare-bytes` exported from `(uv-testing)`. Signature `(compare-bytes expected actual)` → `'identical` | `(wrong-length n)` | `(differs-at i expected-byte actual-byte)`. **Not `'same`** — read `test-echo.sps:175-185` before writing any row against it.

- [ ] **Step 1: Pin the read-buffer default**

No test observes what a size-less `uv-read-start!` allocates: every `stream-read-buf-len` row is against an explicit 4096 (`test-tcp.sps:1244`, `:1275`, `:1285`), a hand-set 64 (`:774`), or self-comparing (`:1385`) — and `:1239-1240` says so outright.

Insert into `tests/test-tcp.sps` immediately after the `"seed: a second reading handle means a second read buffer"` row (`:1246-1247`):

```scheme
;; --- the DEFAULT buffer size, pinned -------------------------------------
;; The rows above fix their own sizes explicitly; this is the only row in the
;; suite that observes what a size-LESS uv-read-start! actually allocates.
;; s-peer was started size-lessly at :1227, so its buffer is the default.
;;
;; v0.5 does not change this number. The row exists so the milestone that
;; does cannot change it silently.
(test-equal "a size-less read-start allocates default-read-buffer-size"
  65536 (stream-read-buf-len s-peer))
```

- [ ] **Step 2: Lift `compare-bytes` to the shared fixture**

`test-echo.sps` is its first user, `test-flow.sps` its second; the repo's PR #4 rule is one copy on the second user. Move `tests/test-echo.sps:172-185` — **the three-line comment above the definition included** — into `tests/uv-testing.sls` beside `seeded-bytes`, delete it from `test-echo.sps`, and extend the export list at `:15-19`:

```scheme
  (export run-until run-until/ticking
          bind-loopback! connect-loopback! loopback-address
          seeded-bytes compare-bytes
          make-byte-collector byte-collector? collect-span!
          collector-count collector-bytes)
```

- [ ] **Step 3: Write the cross-stream isolation suite**

No current test asserts that closing one stream leaves others on the same loop reading. This guards Appendix A condition 3.

**`uv-accept!` takes ONE argument and constructs the peer itself** (`tcp.sls:201-208`) — it does not accept a handle you made.

Create `tests/test-flow.sps`:

```scheme
#!r6rs
;;; SRFI-64 suite for v0.5's flow-control surfaces. Task 1 writes the
;;; cross-stream isolation section; Tasks 2 and 3 append.
;;;
;;; NOT pure: reaches (libuv private native). Never add to PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv stream)
        (libuv tcp)
        (libuv timer)
        (libuv pipe)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "flow")

;; --- cross-stream isolation ----------------------------------------------
;; FOUR readers, not two: with two, "the survivor still reads" and "the
;; survivor got ITS OWN bytes" are the same assertion.
(define reader-count 4)
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(define port (bind-loopback! server))

(define accepted '())
(define collectors '())
(define clients '())

(uv-listen! server 16
  (lambda (err)
    (when (not err)
      (let ((peer (uv-accept! server))      ; ONE argument; returns the peer
            (col  (make-byte-collector)))
        (set! accepted (cons peer accepted))
        (set! collectors (cons col collectors))
        (uv-read-start! peer
                        (lambda (bv s e) (collect-span! col bv s e) (collect))
                        (lambda () #f)
                        (lambda (c) #f))))))

(let build ((i 0))
  (when (< i reader-count)
    (let ((c (make-uv-tcp loop)))
      (set! clients (cons c clients))
      (connect-loopback! c port (lambda (err) #f))
      (build (+ i 1)))))

(test-equal "seed: every client connected and was accepted"
  'satisfied
  (run-until/ticking loop (lambda () (= (length accepted) reader-count)) 4000))

(define peers (list->vector (reverse accepted)))
(define cols  (list->vector (reverse collectors)))
(define cli   (list->vector (reverse clients)))

;; Distinct payloads per survivor. A SHARED sentinel is the trap
;; test-echo.sps:163-172 names by title.
(define (payload-for i) (seeded-bytes 256 (+ 7000 (* i 131))))

(test-equal "seed: the survivors' payloads are pairwise distinct"
  '(distinct distinct distinct)
  (list (if (equal? (payload-for 1) (payload-for 2)) 'same 'distinct)
        (if (equal? (payload-for 1) (payload-for 3)) 'same 'distinct)
        (if (equal? (payload-for 2) (payload-for 3)) 'same 'distinct)))

;; Close reader 0 from inside its own read callback. The replacement callback
;; STILL COLLECTS: without that, cols[0] is frozen at 0 on both sides of the
;; comparison below and no src/ mutation could move it.
(define closed-fired 'not-yet)
(uv-read-stop! (vector-ref peers 0))
(uv-read-start! (vector-ref peers 0)
                (lambda (bv s e)
                  (collect-span! (vector-ref cols 0) bv s e)
                  (when (uv-handle-open? (vector-ref peers 0))
                    (uv-close! (vector-ref peers 0)
                               (lambda () (set! closed-fired 'fired)))))
                (lambda () #f)
                (lambda (c) #f))
(uv-write! (vector-ref cli 0) (seeded-bytes 32 1) (lambda (err) #f))

;; THE GATE. close-dispatch frees on a LATER loop iteration than the
;; uv-close! call (handles.sls:984-996), so a post-close write issued at
;; close-ISSUE time can complete before the window under test opens.
(test-equal "gate: the closed reader reached 'closed before survivors are written to"
  '(satisfied fired closed)
  (let ((r (run-until/ticking loop
                              (lambda () (eq? 'closed (uv-handle-state (vector-ref peers 0))))
                              4000)))
    (list r closed-fired (uv-handle-state (vector-ref peers 0)))))

(define closed-deliveries-at-gate (collector-count (vector-ref cols 0)))

(test-assert "seed: the closing reader received the trigger write before closing"
  (positive? closed-deliveries-at-gate))

(let write-survivors ((i 1))
  (when (< i reader-count)
    (uv-write! (vector-ref cli i) (payload-for i) (lambda (err) #f))
    (write-survivors (+ i 1))))

(test-equal "every survivor received its full payload"
  'satisfied
  (run-until/ticking loop
                     (lambda ()
                       (let check ((i 1))
                         (cond ((>= i reader-count) #t)
                               ((< (collector-count (vector-ref cols i))
                                   (bytevector-length (payload-for i))) #f)
                               (else (check (+ i 1))))))
                     8000))

;; compare-bytes answers 'identical, (wrong-length n), or
;; (differs-at i expected actual) -- never #f, which SRFI-64 also produces
;; for a raise.
(test-equal "survivor 1 received exactly its own bytes"
  'identical (compare-bytes (payload-for 1) (collector-bytes (vector-ref cols 1))))
(test-equal "survivor 2 received exactly its own bytes"
  'identical (compare-bytes (payload-for 2) (collector-bytes (vector-ref cols 2))))
(test-equal "survivor 3 received exactly its own bytes"
  'identical (compare-bytes (payload-for 3) (collector-bytes (vector-ref cols 3))))

(test-equal "the closed reader received nothing further"
  closed-deliveries-at-gate (collector-count (vector-ref cols 0)))

(uv-loop-teardown! loop)
(uv-loop-close! loop)

(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))

(test-end "flow")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
```

- [ ] **Step 4: Run against unchanged code**

```bash
make test 2>&1 | tail -3
grep -cE '^\(test-(equal|assert|eqv|eq) ' tests/test-flow.sps
grep -cE '^\(test-(equal|assert|eqv|eq) ' tests/test-tcp.sps
```

Expected: `ALL SUITES PASSED`; `test-flow.sps` = **8** (after Task 1's fix consolidates three rows into one); `test-tcp.sps` = **169** (168 + Step 1's row).

- [ ] **Step 5: Watch the default pin fail**

```bash
cp src/libuv/stream.sls /tmp/stream.sls.bak
sed -i.tmp 's/(define default-read-buffer-size 65536)/(define default-read-buffer-size 65535)/' src/libuv/stream.sls
make test 2>&1 | grep -E '^FAIL|unexpected failures'
```

Expected: exactly one line `FAIL a size-less read-start allocates default-read-buffer-size`, and `# of unexpected failures  1` for `test-tcp`. No other `FAIL`.

```bash
cp /tmp/stream.sls.bak src/libuv/stream.sls && rm -f src/libuv/stream.sls.tmp
make test 2>&1 | tail -3
```

- [ ] **Step 6: Watch the isolation rows fail**

The mutation must break the test *through the asserted property*, and must be **total** — `alloc-dispatch` is infallible by requirement (`handles.sls:846-858`) and `test-tcp.sps:1389-1394` guards that with a named row, so a mutation that can raise fails the wrong rows. Note that `read-dispatch` copies from `(stream-read-buf handle)`, not from `buf->base` (`handles.sls:872-875`), so handing back *another handle's* buffer would not cross-wire payloads at all. Shift the base by one byte instead:

```bash
cp src/libuv/private/handles.sls /tmp/handles.sls.bak
```

In `alloc-dispatch` (`handles.sls:880-885`):

```scheme
          ;; MUTATION: answer one byte past the base.
          (uv-buf-set! buf-ptr
                       (+ (stream-read-buf handle) 1)
                       (- (stream-read-buf-len handle) 1))
```

```bash
make test 2>&1 | grep -E '^FAIL|unexpected failures'
```

Expected `FAIL` lines, and the plan states the full blast radius so it is not mistaken for "too broad": the three `survivor N received exactly its own bytes` rows, **plus** `test-echo.sps`'s byte-equality rows and `test-tcp.sps`'s read-path rows — correct for a read-path mutation. `every survivor received its full payload` still passes (count-based), as do the seed and gate rows.

```bash
cp /tmp/handles.sls.bak src/libuv/private/handles.sls
make test 2>&1 | tail -3
```

- [ ] **Step 7: Memory lane**

```bash
make test-memory 2>&1 | tail -20
```

Expected: no `definitely lost:` and no `Invalid read`/`Invalid write` marker lines. Gate on the markers, not the exit code — Valgrind's `--error-exitcode` surfaces as make exit 2 through the recipe. Per ADR-0003 the Linux leg is the sole memory gate; on macOS this runs ASan and makes no leak claim.

- [ ] **Step 8: Record and commit**

Create `.plans/flow-task-1-mutation-log.md` with both probes in the repo's format (Mutation / Build & test output / Result), pasting the actual `FAIL` lines. Record `"the closed reader received nothing further"` as an **explicitly uncovered property** if no `src/` mutation moves it — `close-dispatch` deregisters before anything further can deliver — with that reason, per AGENTS.md.

```bash
git add tests/ .plans/flow-task-1-mutation-log.md
git commit -m "test: default-size pin and cross-stream isolation guards

Neither existed. The default pin makes the follow-up milestone's change
deliberate; the isolation suite guards Appendix A condition 3. compare-bytes
lifted to (uv-testing) on its second user, per the PR #4 rule."
```

---

### Task 2: The buffer-size wrappers

**Files:** `src/libuv/private/native.sls`, `src/libuv/handle.sls`, `src/libuv.sls`, `tests/test-flow.sps`, `tests/test-facade.sps`, `.plans/flow-task-2-mutation-log.md`

**Interfaces:**
- Consumes: `require-open-handle`, `handle-pointer`, `handle-kind` from `(libuv private handles)`; `alloc-zeroed`, `free!`, `c-int-size`, `c-int-ref`, `c-int-set!`, `uv-check` from `(libuv private native)`; `make-uv-invalid-argument`, `uv-invalid-argument?`, `uv-invalid-argument-who`, `uv-invalid-argument-reason`, `uv-handle-closed?` from `(libuv private conditions)`.
- Produces: `(uv-send-buffer-size handle)` → exact positive integer; `(uv-send-buffer-size! handle n)` → unspecified; same pair for `recv`.

- [ ] **Step 1: Add the native bindings**

In `src/libuv/private/native.sls`, after `load-shared-object` with the other handle natives:

```scheme
  ;; uv_send_buffer_size / uv_recv_buffer_size overload ONE entry point on
  ;; whether *value is zero (get) or non-zero (set):
  ;;
  ;;   len = sizeof(*value);
  ;;   if (*value == 0)  r = getsockopt(fd, SOL_SOCKET, optname, value, &len);
  ;;   else              r = setsockopt(fd, SOL_SOCKET, optname, value, len);
  ;;                                     -- vendor/libuv/src/unix/core.c:255-261
  ;;
  ;; libuv reads the CALLER'S MEMORY to decide which operation to perform, so
  ;; the getter's zero is load-bearing and alloc-zeroed is mandatory. The
  ;; -native suffix is required here: (libuv handle)'s public wrappers take
  ;; these exact names.
  (define uv-send-buffer-size-native
    (foreign-procedure "uv_send_buffer_size" (uptr uptr) int))
  (define uv-recv-buffer-size-native
    (foreign-procedure "uv_recv_buffer_size" (uptr uptr) int))
```

Export both.

- [ ] **Step 2: Widen `handle.sls`'s imports and exports**

`handle.sls:26-27` imports only `(libuv private handles)`. The three private libraries have **disjoint export sets** (verified: 116 / 93 / no overlap), and `loop.sls`, `tcp.sls` and `stream.sls` already import this same combination.

```scheme
  (import (rnrs)
          (libuv private conditions)
          (libuv private handles)
          (libuv private native))
```

Export list at `:18-21` gains the four names before `uv-close!`.

- [ ] **Step 3: Write the four wrappers**

Append to `src/libuv/handle.sls` before `uv-close!`:

```scheme
  ;; --- OS socket buffer sizes ----------------------------------------------
  ;; THREE DIFFERENT BUFFERS share confusable names, and docs/api.md tabulates
  ;; them together for that reason:
  ;;
  ;;   * chez-libuv's per-handle read buffer -- fixed by the first
  ;;     uv-read-start!, freed by the close dispatcher, 64 KiB by default;
  ;;   * the OS SEND buffer -- these procedures;
  ;;   * the OS RECEIVE buffer -- these procedures.
  ;;
  ;; Setting SO_RCVBUF does not resize the chez-libuv buffer, or vice versa.
  ;; At high connection counts the OS buffers are a first-class memory cost:
  ;; Linux autotunes SO_RCVBUF from roughly 87 KB per socket upward, which at
  ;; ten thousand connections can exceed every read buffer combined.
  ;;
  ;; PLATFORM SUPPORT IS NOT UNIFORM (vendor/libuv/docs/src/handle.rst:202):
  ;; TCP, pipe and UDP on Unix; TCP and UDP only on Windows. The gate is an
  ;; allowlist failing closed for kinds libuv never supports; libuv's own
  ;; UV_ENOTSUP is the backstop for the platform-specific case.
  ;;
  ;; A socket needs an fd but NOT a connection: bind is sufficient.
  ;;
  ;; require-open-handle, not require-handle: on a 'closing handle the pointer
  ;; is still live, so a bare require-handle would let all four SILENTLY
  ;; SUCCEED against a handle that is going away.
  (define (require-socket-handle handle who)
    (require-open-handle handle who)
    (unless (memq (handle-kind handle) '(tcp pipe))
      (raise (make-uv-invalid-argument who 'not-a-socket-handle)))
    handle)

  ;; n must fit an int: c-int-set! bottoms out in foreign-set! 'int, which
  ;; raises a raw Chez exception -- outside this binding's condition hierarchy
  ;; -- for a value that does not fit.
  (define (require-buffer-size n who)
    (unless (and (integer? n) (exact? n) (positive? n) (< n 2147483648))
      (raise (make-uv-invalid-argument who 'buffer-size-out-of-range)))
    n)

  ;; THE ZERO IS THE API. alloc-zeroed, never foreign-alloc.
  (define (get-buffer-size! native handle who)
    (require-socket-handle handle who)
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! cell) (raise e)))
        (uv-check (native (handle-pointer handle who) cell) who)
        (let ((v (c-int-ref cell)))
          (free! cell)
          v))))

  (define (set-buffer-size! native handle n who)
    (require-socket-handle handle who)
    (require-buffer-size n who)
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! cell) (raise e)))
        (c-int-set! cell n)
        (uv-check (native (handle-pointer handle who) cell) who)
        (free! cell))))

  (define (uv-send-buffer-size handle)
    (get-buffer-size! uv-send-buffer-size-native handle 'uv-send-buffer-size))
  (define (uv-send-buffer-size! handle n)
    (set-buffer-size! uv-send-buffer-size-native handle n 'uv-send-buffer-size!))
  (define (uv-recv-buffer-size handle)
    (get-buffer-size! uv-recv-buffer-size-native handle 'uv-recv-buffer-size))
  (define (uv-recv-buffer-size! handle n)
    (set-buffer-size! uv-recv-buffer-size-native handle n 'uv-recv-buffer-size!))
```

Add all four to `src/libuv.sls`'s handle group.

- [ ] **Step 4: Write the sixteen rows — four per wrapper**

Spec §8 requires, per wrapper: success path, native-failure cleanup, closed/closing gate, and (setters) validation before allocation. Insert into `tests/test-flow.sps` before the teardown block.

**Two platform traps this fixture must dodge.** First, the naive "call the getter twice, assert no change" row is an **empty test**: a getter seeding `1` performs `setsockopt(1)` twice and returns the same value both times. Second, `(< after before)` after setting 8192 **fails on Linux CI**: the kernel stores `max(2n, SOCK_MIN_SNDBUF)`, so 8192 becomes 16384 — exactly `tcp_wmem[1]`, the default. Both are answered by a **two-point** comparison, which is platform-robust and is also the zero-seed proof: a getter that secretly sets would clamp both readings to the same minimum.

```scheme
;; --- OS socket buffer sizes ------------------------------------------------
(define bloop (make-uv-loop))
(define btcp (make-uv-tcp bloop))
(uv-tcp-bind! btcp "127.0.0.1" 0)          ; bind is enough; no connection needed

;; TWO-POINT: set low, read; set high, read; assert the readings track the
;; direction. Not (< after default): Linux stores max(2n, SOCK_MIN_SNDBUF),
;; so 8192 lands exactly on tcp_wmem[1] and "below default" is false there.
(uv-send-buffer-size! btcp 8192)
(define send-low (uv-send-buffer-size btcp))
(uv-send-buffer-size! btcp 262144)
(define send-high (uv-send-buffer-size btcp))

(test-equal "the send buffer tracks the value set, at two points"
  '(positive tracks-upward)
  (list (if (and (integer? send-low) (exact? send-low) (positive? send-low))
            'positive 'not-positive)
        (if (> send-high send-low) 'tracks-upward 'did-not-track)))

(uv-recv-buffer-size! btcp 8192)
(define recv-low (uv-recv-buffer-size btcp))
(uv-recv-buffer-size! btcp 262144)
(define recv-high (uv-recv-buffer-size btcp))

(test-equal "the receive buffer tracks independently of the send buffer"
  '(tracks-upward send-unmoved)
  (list (if (> recv-high recv-low) 'tracks-upward 'did-not-track)
        (if (= send-high (uv-send-buffer-size btcp)) 'send-unmoved 'send-moved)))

;; Validation BEFORE allocation, one row per setter.
(test-equal "the send setter refuses a non-positive size"
  '(uv-send-buffer-size! buffer-size-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (list 'wrong-condition e)))
    (uv-send-buffer-size! btcp 0)
    'no-raise))

(test-equal "the receive setter refuses a size that does not fit an int"
  '(uv-recv-buffer-size! buffer-size-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (list 'wrong-condition e)))
    (uv-recv-buffer-size! btcp 2147483648)
    'no-raise))

;; The kind gate, failing closed.
(test-equal "a timer is refused as a socket handle"
  'not-a-socket-handle
  (let ((t (make-uv-timer bloop)))
    (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
              (#t (list 'wrong-condition e)))
      (uv-send-buffer-size t)
      'no-raise)))

;; NATIVE FAILURE, one row per wrapper. An unconnected pipe passes the kind
;; allowlist but has no fd, so uv_send_buffer_size reaches getsockopt(-1) and
;; answers EBADF -- AFTER the int cell is allocated. These four rows are what
;; give the Valgrind lane a failure path to walk; without them §8's
;; free-on-every-path claim is untested.
(define bpipe (make-uv-pipe bloop))

(test-equal "the send getter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-send-buffer-size bpipe) 'no-raise))

(test-equal "the send setter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-send-buffer-size! bpipe 8192) 'no-raise))

(test-equal "the receive getter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-recv-buffer-size bpipe) 'no-raise))

(test-equal "the receive setter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-recv-buffer-size! bpipe 8192) 'no-raise))

;; THE CLOSING GATE, one row per wrapper. 'closing, not 'closed: on a closing
;; handle the pointer is still live, so a missing gate silently SUCCEEDS.
(define bclosing (make-uv-tcp bloop))
(uv-tcp-bind! bclosing "127.0.0.1" 0)
(uv-close! bclosing)                       ; not run: state is 'closing

(test-equal "all four refuse a closing handle with &uv-handle-closed"
  '(closed closed closed closed)
  (map (lambda (thunk)
         (guard (e ((uv-handle-closed? e) 'closed)
                   (#t (list 'wrong-condition e)))
           (thunk) 'no-raise))
       (list (lambda () (uv-send-buffer-size bclosing))
             (lambda () (uv-send-buffer-size! bclosing 8192))
             (lambda () (uv-recv-buffer-size bclosing))
             (lambda () (uv-recv-buffer-size! bclosing 8192)))))

(uv-loop-teardown! bloop)
(uv-loop-close! bloop)
```

Add `uv-errno-error?` and `uv-errno-error-errno` to the suite's condition imports if not already in scope. **`uv-errno-error-errno` yields the symbol** (`'EBADF`); there is no `uv-errno-symbol`.

- [ ] **Step 5: Add the facade rows for these exports**

`test-facade.sps` **already has a connected pair**: `fl` (`:282`), `fserver` (`:283`), `fport` (`:291`), `fclient` (`:321`). Insert **immediately before `(uv-loop-teardown! fl)` at `:393`** — rows after that operate on closed handles.

```scheme
;; --- v0.5 buffer-size surfaces, reached through the facade only -----------
;; CALLED, not asserted about: this suite's enforcement is that an
;; un-re-exported name fails to expand (:19-23), so a row that merely mentions
;; a name proves nothing the import did not already prove.
(test-equal "the facade's send-buffer getter and setter track at two points"
  'tracks-upward
  (begin (uv-send-buffer-size! fclient 8192)
         (let ((lo (uv-send-buffer-size fclient)))
           (uv-send-buffer-size! fclient 262144)
           (if (> (uv-send-buffer-size fclient) lo) 'tracks-upward 'did-not-track))))

(test-equal "the facade's receive-buffer getter and setter track at two points"
  'tracks-upward
  (begin (uv-recv-buffer-size! fclient 8192)
         (let ((lo (uv-recv-buffer-size fclient)))
           (uv-recv-buffer-size! fclient 262144)
           (if (> (uv-recv-buffer-size fclient) lo) 'tracks-upward 'did-not-track))))
```

- [ ] **Step 6: Run**

```bash
make test 2>&1 | tail -3
grep -cE '^\(test-(equal|assert|eqv|eq) ' tests/test-flow.sps
```

Expected: `ALL SUITES PASSED`; `test-flow.sps` = **18** (8 + 10).

- [ ] **Step 7: Watch five mutations fail**

*A — the zero seed.* In `get-buffer-size!`, insert `(c-int-set! cell 1)` after the `alloc-zeroed`.
Expected: `FAIL the send buffer tracks the value set, at two points` and `FAIL the receive buffer tracks independently of the send buffer` and both facade `tracks-upward` rows. The mutated getter sets the buffer to the kernel minimum on every read, so neither reading tracks.

*B — the gate.* Change `require-open-handle` back to `require-handle` in `require-socket-handle`.
Expected: exactly `FAIL all four refuse a closing handle with &uv-handle-closed`.

*C — swallow the native return code.* Delete the `uv-check` wrapper in `get-buffer-size!` and `set-buffer-size!`, keeping the bare native call.
Expected: all four `surfaces the native failure on a pipe with no fd` rows fail, each reporting `'no-raise`.

*D — the kind allowlist.* Delete the `memq` check from `require-socket-handle`.
Expected: exactly `FAIL a timer is refused as a socket handle`.

*E — validate-after-allocate.* Move `require-buffer-size` below the `alloc-zeroed` in `set-buffer-size!`.
Expected: no `FAIL` in a plain build — the rows still see the right condition. **This is the point:** the leak is invisible except under `make test-memory`, which must report a `definitely lost:` line on the Linux leg. Record that asymmetry in the log; it is the justification for the four EBADF rows.

Revert after each; confirm `ALL SUITES PASSED` between.

- [ ] **Step 8: Memory lane, record, commit**

```bash
make test-memory 2>&1 | tail -20
```

Write `.plans/flow-task-2-mutation-log.md` with all five probes, then:

```bash
git add src/libuv/private/native.sls src/libuv/handle.sls src/libuv.sls tests/test-flow.sps tests/test-facade.sps .plans/flow-task-2-mutation-log.md
git commit -m "feat: bind uv_send_buffer_size / uv_recv_buffer_size

Handle-generic, in (libuv handle): the native takes uv_handle_t* and accepts
TCP, pipe and UDP on Unix (handle.rst:202), so TCP-shaping it would repeat
the mistake ADR-0014 records.

The get/set overload is split into four procedures because libuv decides
which operation to perform by reading *value. alloc-zeroed is therefore
mandatory, and the two-point set/read row is what proves it -- 'call the
getter twice' is an empty test, and (< after default) fails on Linux where
8192 lands exactly on tcp_wmem[1]."
```

---

### Task 3: `uv-stream-write-queue-size`

**Files:** `src/libuv/private/native.sls`, `src/libuv/stream.sls`, `src/libuv/tcp.sls`, `src/libuv.sls`, `tests/test-flow.sps`, `tests/test-facade.sps`, `.plans/flow-task-3-mutation-log.md`

**Interfaces:**
- Consumes: `require-open-stream` (private to `stream.sls`); `handle-pointer`; and from Task 2, `uv-send-buffer-size!` / `uv-recv-buffer-size!`, which make this task's fixture deterministic.
- Produces: `(uv-stream-write-queue-size stream)` → exact non-negative integer.

- [ ] **Step 1: Add the native binding**

```scheme
  ;; A struct field read (vendor/libuv/src/uv-data-getter-setters.c:77): no
  ;; callback, no allocation, no error return. size_t and not a signed type
  ;; deliberately -- this repo's scar is binding `nread` unsigned, which routed
  ;; UV_EOF into the data path as four gigabytes of data (handles.sls:889-895).
  ;; This is the opposite case: the value cannot be negative and cannot fail.
  (define uv-stream-get-write-queue-size-native
    (foreign-procedure "uv_stream_get_write_queue_size" (uptr) size_t))
```

- [ ] **Step 2: Add the wrapper**

Export `uv-stream-write-queue-size` from `stream.sls` and append:

```scheme
  ;; (uv-stream-write-queue-size stream) -> exact non-negative integer
  ;;
  ;; libuv's PLATFORM-DEPENDENT count of queued stream bytes. Unix counts bytes
  ;; not yet handed to the kernel (unix/stream.c:693-694) and leaves the count
  ;; non-zero after a FAILED write, deliberately, so the user stops writing
  ;; (unix/stream.c:719-724). Windows counts the opposite thing:
  ;; write_queue_size is incremented only in the UV_SUCCEEDED_WITH_IOCP branch
  ;; (win/tcp.c:986) -- bytes the kernel has ACCEPTED into an incomplete
  ;; overlapped send -- and the immediate-completion branch never increments.
  ;;
  ;; SO: A CONGESTION SIGNAL. Not a memory gauge, and not a portable measure of
  ;; kernel occupancy. It UNDERCOUNTS the memory this binding holds, because a
  ;; write's foreign block stays allocated until the whole request completes
  ;; while this number falls as the kernel takes bytes. A consumer bounding
  ;; memory counts its own submissions against completions -- and must count
  ;; BOTH outstanding payload bytes and outstanding request count, since a
  ;; zero-length write allocates a full block for zero payload bytes
  ;; (stream.sls:91). See docs/api.md.
  ;;
  ;; THE NATIVE CANNOT FAIL; THE GATE CAN. On a 'closing handle the pointer is
  ;; still live, so a missing gate returns a plausible number -- which is why
  ;; the suite mutates this gate against a CLOSING stream. A fully closed one
  ;; does not discriminate: handle-pointer refuses the zeroed pointer first
  ;; (handles.sls:471-475).
  (define (uv-stream-write-queue-size stream)
    (require-open-stream stream 'uv-stream-write-queue-size)
    (uv-stream-get-write-queue-size-native
     (handle-pointer stream 'uv-stream-write-queue-size)))
```

Re-export from `tcp.sls`'s ADR-0014 block; add to `src/libuv.sls`.

- [ ] **Step 3: Write the congestion fixture**

Insert into `tests/test-flow.sps` before the teardown. **`cidle` gets its own listener** — sharing `cport` would race, and whichever connection the listen callback accepted first would become `cpeer`, so a lost race would tune and drain the wrong socket and fail the drain row with a name pointing at the gauge.

```scheme
;; --- write-queue congestion ------------------------------------------------
;; A gauge test that only ever sees 0 passes against a stub, a misbound
;; pointer, and a size_t marshalling bug -- and 0 is truthy. So: observe a
;; POSITIVE value, then observe it FALL. Two assertions, two mutations.
(define cloop (make-uv-loop))
(define cserver (make-uv-tcp cloop))
(define cport (bind-loopback! cserver))
(define cpeer 'not-accepted)
(define cclient (make-uv-tcp cloop))

(uv-listen! cserver 4
  (lambda (err)
    (when (and (not err) (eq? cpeer 'not-accepted))
      (set! cpeer (uv-accept! cserver)))))   ; deliberately NOT reading

;; The idle stream gets its OWN listener: sharing cserver would race for which
;; connection becomes cpeer.
(define cidle-server (make-uv-tcp cloop))
(define cidle-port (bind-loopback! cidle-server))
(define cidle-peer 'not-accepted)
(uv-listen! cidle-server 1
  (lambda (err)
    (when (and (not err) (eq? cidle-peer 'not-accepted))
      (set! cidle-peer (uv-accept! cidle-server)))))
(define cidle (make-uv-tcp cloop))

(connect-loopback! cclient cport (lambda (err) #f))
(connect-loopback! cidle cidle-port (lambda (err) #f))

(test-equal "seed: both congestion pairs connected"
  'satisfied
  (run-until/ticking cloop
                     (lambda () (and (not (eq? cpeer 'not-accepted))
                                     (not (eq? cidle-peer 'not-accepted))))
                     4000))

;; Shrink BOTH: shrinking only the writer's does not bound loopback buffering,
;; because the peer's receive buffer absorbs independently.
(uv-send-buffer-size! cclient 4096)
(uv-recv-buffer-size! cpeer 4096)

(define chunk (seeded-bytes 65536 4242))
(define submissions 0)
(define completions 0)

(define congested
  (let push ((i 0))
    (cond ((>= i 64) 'gauge-never-went-positive)
          (else
           (uv-write! cclient chunk (lambda (err) (set! completions (+ completions 1))))
           (set! submissions (+ submissions 1))
           ;; Sampled synchronously after uv-write! returns and BEFORE any
           ;; uv-run: stream.sls:100-104 submits inline, so this is the moment
           ;; the queue is deepest.
           (let ((q (uv-stream-write-queue-size cclient)))
             (if (positive? q) q (begin (uv-run cloop 'nowait) (push (+ i 1)))))))))

(test-equal "the write queue goes positive against an unreading peer"
  'positive
  (if (and (integer? congested) (positive? congested)) 'positive congested))

;; THE per-stream discriminator: the only row separating a real per-stream read
;; from a per-loop total or a misbound pointer.
(test-equal "an idle stream on the same loop reads zero while the other is congested"
  '(congested-positive idle-zero)
  (list (if (positive? (uv-stream-write-queue-size cclient)) 'congested-positive 'congested-zero)
        (if (zero? (uv-stream-write-queue-size cidle)) 'idle-zero 'idle-nonzero)))

;; Drain, requiring BOTH halves. Without the completions half, a gauge stubbed
;; to 0 passes this row trivially.
(uv-read-start! cpeer (lambda (bv s e) (collect)) (lambda () #f) (lambda (c) #f))

(test-equal "the queue falls to zero AND every write completed once the peer reads"
  '(satisfied all-completed)
  (let ((r (run-until/ticking cloop
                              (lambda () (and (zero? (uv-stream-write-queue-size cclient))
                                              (= completions submissions)))
                              20000)))
    (list r (if (= completions submissions) 'all-completed
                (list 'short completions submissions)))))

;; The gate, on a CLOSING stream.
(test-equal "a closing stream refuses the gauge with &uv-handle-closed"
  'closed
  (let ((doomed (make-uv-tcp cloop)))
    (uv-tcp-bind! doomed "127.0.0.1" 0)
    (uv-close! doomed)
    (guard (e ((uv-handle-closed? e) 'closed)
              (#t (list 'wrong-condition e)))
      (uv-stream-write-queue-size doomed)
      'no-raise)))

(uv-loop-teardown! cloop)
(uv-loop-close! cloop)
```

- [ ] **Step 4: Facade row**

Insert before `(uv-loop-teardown! fl)` at `test-facade.sps:393`, beside Task 2's rows:

```scheme
(test-equal "the facade's write-queue-size answers zero on an idle stream"
  'zero (if (zero? (uv-stream-write-queue-size fclient)) 'zero 'nonzero))
```

- [ ] **Step 5: Run**

```bash
make test 2>&1 | tail -3
grep -cE '^\(test-(equal|assert|eqv|eq) ' tests/test-flow.sps
```

Expected: `ALL SUITES PASSED`; `test-flow.sps` = **23** (18 + 5).

- [ ] **Step 6: Watch three mutations fail**

*A — constant zero.* `(define (uv-stream-get-write-queue-size-native ptr) 0)`.
Expected: `FAIL the write queue goes positive against an unreading peer`. The idle-stream row also fails (its `congested-positive` half). The drain row still passes — which is exactly why it needs the `completions` half.

*B — constant non-zero.* `(define (uv-stream-get-write-queue-size-native ptr) 4096)`.
Expected: `FAIL an idle stream on the same loop reads zero while the other is congested` and `FAIL the queue falls to zero AND every write completed once the peer reads` and `FAIL the facade's write-queue-size answers zero on an idle stream`.

*C — the gate.* Delete the `require-open-stream` line.
Expected: exactly `FAIL a closing stream refuses the gauge with &uv-handle-closed`.

- [ ] **Step 7: Memory lane, record, commit**

```bash
make test-memory 2>&1 | tail -20
git add src/libuv/private/native.sls src/libuv/stream.sls src/libuv/tcp.sls src/libuv.sls tests/test-flow.sps tests/test-facade.sps .plans/flow-task-3-mutation-log.md
git commit -m "feat: bind uv_stream_get_write_queue_size

A platform-dependent congestion signal, documented as not a memory gauge:
Unix counts bytes not yet given to the kernel, Windows counts bytes the
kernel accepted into an incomplete overlapped send (win/tcp.c:986)."
```

---

### Task 4: `uv-tcp-peer-address`, and the write-ordering rows

**Files:** `src/libuv/private/native.sls`, `src/libuv/tcp.sls`, `src/libuv.sls`, `tests/test-tcp.sps`, `tests/test-facade.sps`, `.plans/flow-task-4-mutation-log.md`

- [ ] **Step 1: Native binding and wrapper**

```scheme
  (define uv-tcp-getpeername-native
    (foreign-procedure "uv_tcp_getpeername" (uptr uptr uptr) int))
```

In `src/libuv/tcp.sls`, after `uv-tcp-getsockname-port`:

```scheme
  ;; (uv-tcp-peer-address tcp) -> (values address-string-or-#f port)
  ;;
  ;; The uv-tcp-getsockname-port shape verbatim (ADR-0012's address
  ;; vocabulary), with one difference: the local side answers only the PORT,
  ;; because what a caller needs locally is the ephemeral port a zero-bind
  ;; chose. What a caller needs about the PEER is the address -- for per-IP
  ;; limits and access logging, both of which are the consumer's policy.
  ;;
  ;; The first value may be #f: sockaddr->address-string answers string | #f
  ;; deliberately. An unconnected handle answers UV_ENOTCONN through uv-check.
  (define (uv-tcp-peer-address tcp)
    (require-open-tcp tcp 'uv-tcp-peer-address)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage)))
          (len  (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! addr) (free! len) (raise e)))
        (c-int-set! len (sizeof-sockaddr-storage))
        (uv-check (uv-tcp-getpeername-native
                   (handle-pointer tcp 'uv-tcp-peer-address) addr len)
                  'uv-tcp-peer-address)
        (unless (>= (c-int-ref len) (+ (offsetof-sockaddr-in-sin-port) 2))
          (raise (make-uv-invalid-argument 'uv-tcp-peer-address
                                           'sockaddr-too-small-for-a-port)))
        (let ((address (sockaddr->address-string addr))
              (port    (read-net-u16 addr (offsetof-sockaddr-in-sin-port))))
          (free! addr)
          (free! len)
          (values address port)))))
```

Export from `tcp.sls` and `src/libuv.sls`.

- [ ] **Step 2: Write the fixture and rows**

`test-tcp.sps` carries **absolute** live-counter assertions downstream — `:394` expects `3 (live-count 'tcp)` and `:704` expects `0`. Extra live handles before those break them. Insert **immediately after the `"every tcp handle of the exchange was freed"` row at `:704`**, before the `;; --- use after close` block at `:706`. The suite already imports `(uv-testing)` at `:57`.

```scheme
;; --- peer address ---------------------------------------------------------
(define pa-loop (make-uv-loop))
(define pa-server (make-uv-tcp pa-loop))
(define pa-server-port (bind-loopback! pa-server))
(define pa-peer 'never-accepted)

(uv-listen! pa-server 128
            (lambda (err)
              (collect)
              (when (and (not err) (eq? pa-peer 'never-accepted))
                (set! pa-peer (uv-accept! pa-server)))))

(define pa-client (make-uv-tcp pa-loop))
(define pa-connect-err 'connect-cb-never-fired)
(connect-loopback! pa-client pa-server-port
                   (lambda (err) (collect) (set! pa-connect-err err)))

(test-equal "seed: the peer-address pair connected and was accepted"
  'satisfied
  (run-until/ticking pa-loop
                     (lambda () (and (not (eq? pa-peer 'never-accepted))
                                     (not (eq? pa-connect-err 'connect-cb-never-fired))))
                     4000))

;; The expected IPv4 string is REQUIRED, not tolerated: a row accepting #f
;; passes against an implementation whose address conversion returns #f.
(test-equal "the client's peer address and port are the server's"
  (list "127.0.0.1" pa-server-port)
  (let-values (((a p) (uv-tcp-peer-address pa-client))) (list a p)))

;; The direction that catches getpeername implemented as getsockname. Two
;; independent ports also shrink the byte-order blind spot (tcp.sls:125-129
;; records why read-net-u16 exists) from ~1/256 to ~1/65536.
(test-equal "the accepted handle's peer port is the client's own local port"
  (list "127.0.0.1" (uv-tcp-getsockname-port pa-client))
  (let-values (((a p) (uv-tcp-peer-address pa-peer))) (list a p)))

(test-equal "an unconnected handle refuses with ENOTCONN"
  'ENOTCONN
  (let ((u (make-uv-tcp pa-loop)))
    (uv-tcp-bind! u "127.0.0.1" 0)
    (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
              (#t (list 'wrong-condition e)))
      (uv-tcp-peer-address u)
      'no-raise)))

;; --- two-write ordering (design spec §13.5) -------------------------------
;; What the BINDING owns: FIFO submission order and per-request completion
;; routing. Non-interleaving itself is structural (head-of-queue drain,
;; unix/stream.c:1043) and is logged as an uncovered property, not asserted.
(define pa-col (make-byte-collector))
(uv-read-start! pa-peer (lambda (bv s e) (collect-span! pa-col bv s e) (collect))
                (lambda () #f) (lambda (c) #f))
;; Chez has NO bytevector-append -- it is R7RS, and absent from both (rnrs)
;; and (chezscheme). Verified: "variable bytevector-append is not bound".
;; R6RS bytevector-copy! is (source source-start target target-start count).
(define (bv-append a b)
  (let* ((la (bytevector-length a))
         (lb (bytevector-length b))
         (out (make-bytevector (+ la lb))))
    (bytevector-copy! a 0 out 0 la)
    (bytevector-copy! b 0 out la lb)
    out))

(define pa-a (seeded-bytes 1024 11))
(define pa-b (seeded-bytes 1024 22))
(define pa-order '())
(uv-write! pa-client pa-a (lambda (err) (set! pa-order (cons (or err 'no-error) pa-order))))
(uv-write! pa-client pa-b (lambda (err) (set! pa-order (cons (or err 'no-error) pa-order))))

(test-equal "both writes arrive, A then B"
  'identical
  (begin (run-until/ticking pa-loop
                            (lambda () (>= (collector-count pa-col) 2048)) 8000)
         (compare-bytes (bv-append pa-a pa-b) (collector-bytes pa-col))))

(test-equal "both completions fired with no error, in submission order"
  '(no-error no-error) (reverse pa-order))

(uv-loop-teardown! pa-loop)
```

- [ ] **Step 3: Facade row**

```scheme
(test-equal "the facade's peer-address answers the connected peer"
  (list "127.0.0.1" fport)
  (let-values (((a p) (uv-tcp-peer-address fclient))) (list a p)))
```

- [ ] **Step 4: Run**

```bash
make test 2>&1 | tail -3
grep -cE '^\(test-(equal|assert|eqv|eq) ' tests/test-tcp.sps
```

Expected: `ALL SUITES PASSED`; `test-tcp.sps` = **175** (169 + 6).

- [ ] **Step 5: Watch two mutations fail, with the true blast radius**

*A — point the wrapper at `uv-tcp-getsockname`.*
Expected: **both** address rows fail, not one. A connected client's *sockname* port is its own ephemeral port, never the server's, so row 1 fails too. Row 2 exists because it is the one that still discriminates when both ends share an address — it is not narrower. Expected `FAIL` lines: `the client's peer address and port are the server's`, `the accepted handle's peer port is the client's own local port`, `the facade's peer-address answers the connected peer`.

*B — `sockaddr->address-string` returning constant `#f`.*
Expected: **both** address rows plus the facade row fail. No mutation isolates row 1 alone; record that.

- [ ] **Step 6: Record and commit**

Log both probes plus the §13.5 uncovered-property entry (non-interleaving is structural; citation `unix/stream.c:1043`).

```bash
git add src/libuv/private/native.sls src/libuv/tcp.sls src/libuv.sls tests/test-tcp.sps tests/test-facade.sps .plans/flow-task-4-mutation-log.md
git commit -m "feat: bind uv_tcp_getpeername as uv-tcp-peer-address

Completes the mirror. Both directions asserted: on loopback the addresses
are identical, so only the accepted-handle direction catches a getpeername
implemented as getsockname. Plus the two-write ordering rows §13.5 requires."
```

---

### Task 5: Correct the overlapped-model comments; add the vendor tripwire

Independent of Tasks 2–4; can land at any point. Gated by `make check-pins && make check-help`.

**Files:** `src/libuv/stream.sls:183-193`, `src/libuv/private/handles.sls:999-1005`, `Makefile`, `.plans/flow-task-5-mutation-log.md`

- [ ] **Step 1: Correct both comment sites**

`rg -n 'overlapped' src/libuv/` returns exactly two hits — `stream.sls:187` and `handles.sls:1001` — carrying the identical claim. Correcting one leaves the repo contradicting itself. Replace the Windows clause at both with:

```scheme
  ;; ... the close dispatcher is the only place that buffer may ever be freed
  ;; -- so that nothing on a path libuv can call into ever has to allocate.
  ;; THAT is the reason, and it is portable: alloc-dispatch is required to be
  ;; infallible (handles.sls:846-858), and a realloc reachable from a
  ;; uv-read-start! issued inside on-data would break the invariant on every
  ;; platform.
  ;;
  ;; This comment used to say the reason was Windows' overlapped-read model
  ;; keeping a completion queued against the buffer. For the two handle kinds
  ;; this binding supports, that is DEAD CODE at the pinned libuv: uv_tcp_t
  ;; never posts a user buffer at all (win/tcp.c:559 queues a zero-byte
  ;; WSARecv against static uv_zero_; the real read at :1100 is
  ;; non-overlapped), and uv_pipe_t drains its overlapped ReadFile with
  ;; CancelIoEx + a blocking GetOverlappedResult before returning
  ;; (win/pipe.c:2000-2013). The residue: pipe.c:2006 checks CancelIoEx only
  ;; through an assert that release builds compile out. `make check-pins`
  ;; carries a tripwire over these vendor facts.
```

- [ ] **Step 2: Add the tripwire**

`UV_HANDLE_ZERO_READ` is assigned in **two** places — `win/tcp.c:559` and `win/udp.c:280` — not one. Verified counts against the pinned tree: set = 2, cleared = 0, `read_buffer` assigned = 0. Append to the `check-pins` recipe:

```make
	@zr=$$(grep -rn 'UV_HANDLE_ZERO_READ' $(VENDOR_DIR)/src | grep -c '|=' || true); \
	zc=$$(grep -rn 'UV_HANDLE_ZERO_READ' $(VENDOR_DIR)/src | grep -c '&= *~' || true); \
	rb=$$(grep -rn 'read_buffer *=' $(VENDOR_DIR)/src $(VENDOR_DIR)/include | grep -vc 'read_buffer ==' || true); \
	if [ "$$zr" != "2" ] || [ "$$zc" != "0" ] || [ "$$rb" != "0" ]; then \
	  echo "VENDOR DRIFT: UV_HANDLE_ZERO_READ assigned $$zr (expected 2: win/tcp.c, win/udp.c)," >&2; \
	  echo "  cleared $$zc (expected 0); read_buffer assigned $$rb (expected 0)." >&2; \
	  echo "src/libuv/stream.sls and src/libuv/private/handles.sls both cite these" >&2; \
	  echo "facts in the read-buffer comments. Re-verify BOTH before bumping." >&2; \
	  exit 1; \
	fi; \
	echo "vendor read-path facts ok: ZERO_READ set=$$zr cleared=$$zc, read_buffer assigned=$$rb"
```

`grep -c` writes `0` to stdout even when it exits 1, so `|| true` leaves the literal string `"0"` — the comparisons are safe. Update the target's `## ` description at `Makefile:195` to mention the vendor read-path audit; `make check-help` fails on an undocumented `.PHONY` target.

- [ ] **Step 3: Watch the tripwire fail**

`vendor/libuv` is a git submodule; edit it in place and restore with `git -C` so the parent repo's index is untouched.

```bash
printf '\nvoid drift(uv_tcp_t*h){h->flags |= UV_HANDLE_ZERO_READ;}\n' >> vendor/libuv/src/win/tcp.c
make check-pins; echo "exit=$?"
```

Expected: `VENDOR DRIFT: UV_HANDLE_ZERO_READ assigned 3 (expected 2 …)`, naming both Scheme comment sites. `exit=2` — make reports 2 for a recipe that exits 1; gate on the message, not the number.

```bash
git -C vendor/libuv checkout -- src/win/tcp.c
git -C vendor/libuv status --porcelain    # must be empty
make check-pins && make check-help
```

Expected: `vendor read-path facts ok: ZERO_READ set=2 cleared=0, read_buffer assigned=0`, and `check-help` green.

- [ ] **Step 4: Record and commit**

```bash
make test 2>&1 | tail -3
git add src/libuv/stream.sls src/libuv/private/handles.sls Makefile .plans/flow-task-5-mutation-log.md
git commit -m "fix: correct both overlapped-model comments; gate the vendor facts

Both comments justified the close-only-free rule with a Windows overlapped
read that, for uv_tcp_t and uv_pipe_t at the pinned libuv, does not exist.
The rule is right for a portable reason -- the infallible-alloc invariant --
and the vendor facts now have a check-pins tripwire rather than a comment a
reader would grep for and not find."
```

---

### Task 6: Decision records, documentation, release

**Files:** `.plans/decisions/0018-unbuffered-write-submission.md`, `.plans/decisions/0009-copy-at-the-boundary.md`, `docs/api.md`, `README.org`, `CHANGELOG.md`, `Akku.manifest`

- [ ] **Step 1: ADR-0018**

House structure (Status / Date / Scope / Related, then Context / Decision / Consequences — see `0014`, `0017`), titled affirmatively: **"Write submission is unbuffered; queue-depth policy belongs to the consumer."** Body is §11 of the design spec. Both grounds must appear: (1) `uv-shutdown!` submits immediately (`stream.sls:110-119`), so a shutdown after a deferred write would reach libuv first, putting FIN ahead of data; (2) `uv-close!` frees the read buffer and handle pointer and nothing else (`handles.sls:984-996`), and libuv cannot cancel what it never received. Plus the forfeited property (a Scheme-side queue is invisible to `live-counts` and both teardown sweeps, `handles.sls:500,508`) and the deferred alternative (`uv-stream-set-write-limit!`).

- [ ] **Step 2: Amend ADR-0009**

Add a dated note in the style of its existing "Corrected 2026-08-18 (Stage 4)" block:

> **Amended 2026-08-29 (v0.5).** Two facts about read-buffer ownership, established while rejecting a shared per-loop buffer. **First:** `uv__read` is a loop (`unix/stream.c:1043`) — `alloc_cb`, `read()`, `read_cb`, then again unless the read did not fill the buffer — so a handle's buffer is already overwritten immediately after `on-data` returns. Callback-scoped borrowing is therefore the natural lifetime under *any* ownership model, and the `(bv start end)` span shape reserved above remains right. **Second, correcting an assumption made when this ADR was written:** read-stop does **not** make a retained span safe. `uv-read-stop!` stops the read loop, but `close-dispatch` frees the buffer unconditionally (`handles.sls:990`), so a span retained across callbacks becomes a use-after-free the instant the handle closes — and close can be initiated from anywhere, including a teardown sweep. A retained-borrow design needs explicit borrow ownership: a token, a refcount, a deferred close, or an equivalent. Recorded as Appendix A condition 9 of the v0.5 design spec.

- [ ] **Step 3: `docs/api.md`**

Six export rows in the per-module tables (`uv-stream-write-queue-size` under Streams; the four buffer-size procedures under Handles; `uv-tcp-peer-address` under TCP). Two new reason symbols at `:286-294`: `'buffer-size-out-of-range`, `'not-a-socket-handle`. The three-buffers table from spec §4.2. A **Flow control** section carrying: the sizing contract as a *tradeoff* (a smaller buffer cuts foreign memory linearly and raises `read(2)` count, `on-data` deliveries and therefore Scheme bytevector allocation proportionally); the read-stop/read-start pairing invariant with the `uv-handle-open?` guard for a stop racing a close; and how a consumer bounds write memory — **outstanding payload bytes and outstanding request count**, incremented only after `uv-write!` returns successfully, because a zero-length write allocates a full block for zero payload bytes. Plus, beside the "Exit ≠ close" note at `:105`:

> **A second `uv-close!` silently discards its callback.** `real-close-handle!` guards on the handle being `'open` (`handles.sls:1128`), so a close against an already-`'closing` handle stores nothing and the supplied `on-close` never runs. A server that deregisters a connection from `on-close` must own *every* close initiation; see `.plans/chez-http-server-architecture.md`.

- [ ] **Step 4: Version and counts**

`Akku.manifest:4` → `"0.5.0"`. `CHANGELOG.md`: `## 0.5.0 — 2026-08-29`, **Added** only. `README.org:22`: "seventeen accepted decision records" → "eighteen"; update the version status line.

- [ ] **Step 5: Full gate**

```bash
make check-pins && make check-help && make test && make test-memory && make prod && make check-prod
```

Expected: all green. `check-pins` prints all five lines including `vendor read-path facts ok:`. `check-prod` still PASSes — this milestone does not touch the counters, so `check-prod.sps:77`'s `for-all … zero?` is unaffected.

- [ ] **Step 6: PR and closing ritual**

```bash
git add -A && git commit -m "docs: v0.5 decision records, API documentation, and release"
git push -u origin feat/v0.5-flow-control
gh pr create --title "feat: chez-libuv v0.5 — flow control mechanism" --body "..."
```

Then the closing ritual (AGENTS.md): squash merge, catch up local `main`, delete branches, annotated tag `v0.5.0`, reflect.

---

## Self-Review

**Spec coverage.** D1 → Task 1 Step 1. D2 → Task 3. D3 → Task 2. D4 → Task 4. D5 → Task 5. D6 → Task 6. §13.1 → Task 1 Step 1; §13.2 → Task 3 Step 3; §13.3 → Task 2 Step 4 (**sixteen rows: four success/tracking, two validation, one kind gate, four native-failure, one four-way closing gate, two facade** — the spec's "twenty" counted four per wrapper including peer-address, whose four are Task 4's); §13.4 → Task 1 Step 3; §13.5 → Task 4 Step 2, both halves. Appendix A conditions 3 and 9 → Task 1's regression and ADR-0009's amendment. §9's close hazard → Task 6 Step 3.

**Deviations from the spec's §14 stage order, and why.** D3 before D2 (Task 2 before Task 3): the congestion fixture needs shrunk socket buffers to be deterministic, so building the gauge first would mean logging mutations against a fixture the next task rewrites. The spec's Stage 1 pair is merged into one task: one assertion and one suite, one commit, one gate.

**Corrections carried from the review of this plan's first draft** — recorded because an implementer hitting an unexplained failure will come here: `uv-accept!` takes **one** argument and returns the peer (`tcp.sls:201`); `compare-bytes` returns **`'identical`**, not `'same` (`test-echo.sps:180`); the errno symbol accessor is **`uv-errno-error-errno`**, and `uv-errno-symbol` does not exist; `test-facade.sps` **already has** a connected pair (`fl`/`fserver`/`fport`/`fclient`, `:282-321`); the SRFI-64 simple runner prints **only** `FAIL <name>`.

**Known gap, stated rather than hidden.** `"the closed reader received nothing further"` (Task 1) may be unfalsifiable — `close-dispatch` deregisters before anything further can deliver. Step 8 requires logging it as an explicitly uncovered property with that reason if no `src/` mutation moves it, rather than shipping a green row that proves nothing.

**Type consistency.** `-native` suffix on all four new bindings, none shadowed by a public name. `compare-bytes` → `'identical` at every use. `uv-errno-error-errno` at every use. `uv-handle-state` → `'open`/`'closing`/`'closed`. Setters `!`-suffixed, getters not. Pass counts stated with their derivation command: `test-flow` 8 → 18 → 23; `test-tcp` 168 → 169 → 175.
