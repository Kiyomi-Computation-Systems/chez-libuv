# Quickstart

An echo server and one client, on one loop, in one process — the whole
public API surface in miniature. [`tests/test-echo.sps`](../tests/test-echo.sps)
is this program with eight concurrent clients, 32 KiB payloads and
assertions.

## Before you start

Build the native shim once (full story in [Building & testing](building.md)):

```sh
make build
```

Then run any program in this guide with `src` on Chez's library path:

```sh
CHEZSCHEMELIBDIRS=src chez --program echo.sps
```

## The program

```scheme
(import (rnrs) (libuv))

;; A span is [start, end), like every other R6RS range. on-data is handed a
;; FRESH bytevector per delivery (ADR-0009), so this copy is only about
;; taking the sub-range.
(define (span->bytevector bv start end)
  (let ((out (make-bytevector (- end start))))
    (bytevector-copy! bv start out 0 (- end start))
    out))

(define loop (make-uv-loop))
(define echoed #f)

;; --- the server: echo the exact span back, close when the peer is done ---
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))

(uv-listen! server 128
            (lambda (err)
              (unless err
                (let ((peer (uv-accept! server)))
                  (uv-read-start!
                   peer
                   (lambda (bv start end)              ; on-data
                     (uv-write! peer bv start end (lambda (err) #f)))
                   (lambda ()                          ; on-eof: not an error
                     (uv-shutdown! peer (lambda (err) (uv-close! peer))))
                   (lambda (err)                       ; on-error: a condition
                     (uv-close! peer)))))))

;; --- one client, on the SAME loop ---------------------------------------
(define client (make-uv-tcp loop))

(uv-tcp-connect!
 client "127.0.0.1" port
 (lambda (err)
   (unless err
     (uv-read-start!
      client
      (lambda (bv start end)
        (set! echoed (utf8->string (span->bytevector bv start end)))
        (uv-shutdown! client (lambda (err) (uv-close! client)))
        (uv-close! server))
      (lambda () #f)
      (lambda (err) (uv-close! client)))
     (uv-write! client (string->utf8 "hello, libuv\n") (lambda (err) #f)))))

;; Callbacks run here and nowhere else. uv-run answers #f when the loop has
;; run dry; uv-loop-teardown! closes whatever is left, drains it, and closes
;; the loop (there are no guardians -- ADR-0007).
(uv-run loop 'default)
(uv-loop-teardown! loop)

(display echoed)
```

## The three rules

That program depends on three rules, stated in full in the design spec
(§5–§9 of [the v0.1 design](../.plans/2026-08-18-chez-libuv-v0.1-design.md)):

- **A close is asynchronous.** `uv-close!` *starts* the close; the handle is
  `closing` until the loop runs its close callback, which is the only place
  a handle's memory is ever released. Nothing is freed by the garbage
  collector ([ADR-0007](../.plans/decisions/0007-no-guardians-explicit-close.md)).
- **EOF is not an error.** It is its own callback, taking no arguments, and
  it is never wrapped in a condition. A read *error* is delivered to
  `on-error` as a condition *object* — never raised across the callback
  boundary — and does not close the handle: what to do about it is the
  caller's decision.
- **A callback that raises does not cross into C.** The first raise of a run
  is stored, the loop is stopped, and it is re-raised from `uv-run` wrapped
  in `&uv-callback-error` and composed with the original condition, so a
  `guard` written against the original type still matches. Later raises in
  the same run are readable through `uv-loop-deferred-errors`. Raising, or
  calling `uv-stop!`, is how a callback ends a run early: a continuation
  that escapes a callback leaves its loop marked running for good
  ([the loop](api.md#the-loop--libuv-loop)).

## Where next

- [API reference](api.md) — every export of every module, one line each
- [Building & testing](building.md) — acquisition paths, `CHEZ_LIBUV_SHIM`,
  release builds, the test gates
- [Design specs & ADRs](../.plans/) — why it is built this way, with the
  evidence
