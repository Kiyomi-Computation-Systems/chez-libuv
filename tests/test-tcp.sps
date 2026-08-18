#!r6rs
;;; SRFI-64 suite for (libuv tcp)'s WRITE path -- design spec S5 (the handle
;;; lifecycle, extended to a second handle type), S7 (the write path: one
;;; foreign-alloc per write, freed before on-complete), S8 (callback boundary
;;; discipline), S10 (the debug counters) and S11 / ADR-0010 (loopback only:
;;; bind 127.0.0.1:0, read the real port back, connect from the same loop and
;;; process; no subprocess client, no fixed port, no external network).
;;;
;;; READING IS STAGE 5. Nothing here calls uv_read_start, so every write is
;;; verified by its COMPLETION callback rather than by what arrived at the
;;; other end: the kernel buffers a few bytes for a peer that is not reading,
;;; which is exactly what makes "the write completed" observable without a
;;; read path. Payload integrity -- that the bytes on the wire are the bytes
;;; the caller passed -- is Stage 5's chunked 1 MiB transfer; the rows here
;;; that exercise the caller's freedom to mutate its own bytevector therefore
;;; assert completion and non-corruption of this process, not the peer's view.
;;;
;;; NOTHING HERE ASSERTS ELAPSED TIME. Determinism comes from callback
;;; invocation counts and from run-until's iteration cap (uv-testing).
;;;
;;; NOT pure: (libuv tcp) reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv tcp)
        ;; A timer is the stand-in for "a handle that is not a tcp handle":
        ;; every uv_tcp_* entry point would be undefined behaviour against
        ;; one, so the rejection has to be tested with a real handle of
        ;; another kind rather than with a non-handle.
        (libuv timer)
        (libuv private handles)
        (libuv private conditions)
        ;; `only`, for the same reason as tests/test-timer.sps: this library
        ;; also exports names the public libraries above define differently.
        ;; alloc-zeroed / count-read-buffer-new! are here for the ONE row that
        ;; reaches the close dispatcher's read-buffer arm -- Stage 5 owns the
        ;; code that fills that field, but the arm that frees it ships now, so
        ;; it is exercised now rather than left dead (AGENTS.md).
        ;; uv-req-size / uv-buf-base / uv-buf-len / copy-out are the ONE row
        ;; group that looks inside a write block while it is still in flight
        ;; -- see "a written span" below for why that is the only place the
        ;; copied bytes are observable before Stage 5's read path exists.
        (only (libuv private native)
              live-counts alloc-zeroed count-read-buffer-new! dispatcher-ref
              uv-req-size uv-buf-base uv-buf-len copy-out)
        (only (libuv private constants) uv-write-req-type)
        (uv-testing)
        (only (chezscheme) collect))

;; SRFI-64's default runner sets no process exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

(define (live-count kind) (cdr (assq kind (live-counts))))

;; Captured before this suite allocates anything.
(define registry-count-at-start (registry-count))

;; A callback's `err` argument is #f on success, and #f is the value
;; AGENTS.md names as the worst possible expected value: it is what a missing
;; key, a defaulting accessor and an SRFI-64-swallowed exception all produce.
;; So every assertion below compares a SYMBOL, and this is the one place the
;; mapping happens. 'callback-never-fired is the seed every observer starts
;; at, and no success path can produce it.
(define (err->symbol err)
  (cond ((not err) 'no-error)
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else (list 'unexpected-err-object err))))

;; Iteration caps. Generous enough that a slow machine never hits them,
;; small enough that a genuinely stuck loop is a failure rather than a hang.
(define cap 64)

(test-begin "tcp")

;; --- seeds ---------------------------------------------------------------
;; Every counter assertion in this suite needs the DEV shim (the Makefile's
;; CFLAGS_DEV, -DCHEZ_LIBUV_DEBUG_COUNTERS); against a production shim the
;; live queries answer a constant 0 and the "moved" rows would fail pointing
;; at cross-wiring that is not there. Name that precondition first.
(test-equal "seed: no tcp handle is live before this suite creates one"
  0 (live-count 'tcp))

(test-equal "seed: no write request is live before this suite creates one"
  0 (live-count 'write-req))

(test-equal "seed: the handle registry is empty before this suite registers anything"
  0 registry-count-at-start)

(define l (make-uv-loop))
(define registry-with-loop (registry-count))

;; --- construction --------------------------------------------------------
(define t0 (make-uv-tcp l))

(test-equal "make-uv-tcp returns a uv-tcp"
  'a-tcp (if (uv-tcp? t0) 'a-tcp 'not-a-tcp))

(test-equal "a tcp handle is a uv-handle"
  'a-handle (if (uv-handle? t0) 'a-handle 'not-a-handle))

(test-equal "a tcp handle is not a uv-timer"
  'not-a-timer (if (uv-timer? t0) 'a-timer 'not-a-timer))

(test-equal "a fresh tcp handle is open"
  'open (if (uv-handle-open? t0) 'open 'not-open))

(test-equal "a tcp handle knows the loop it belongs to"
  'same (if (eq? l (uv-handle-loop t0)) 'same 'different))

;; positive? is the discriminating part: 0 is what the freeing site leaves
;; behind (design spec S10).
(test-equal "make-uv-tcp stores a non-null handle pointer"
  'positive
  (if (and (integer? (handle-ptr t0)) (exact? (handle-ptr t0))
           (positive? (handle-ptr t0)))
      'positive
      'null-or-not-a-pointer))

(test-equal "seed: creating a tcp handle moves the live tcp counter"
  1 (live-count 'tcp))

(test-equal "make-uv-tcp registers the handle in the registry"
  1 (- (registry-count) registry-with-loop))

(test-equal "the registry resolves the tcp pointer back to the tcp record"
  'same (if (eq? t0 (registry-ref (handle-ptr t0))) 'same 'different))

(test-equal "a registered tcp handle appears in its loop's live-handle snapshot"
  'listed (if (memq t0 (uv-loop-live-handles l)) 'listed 'missing))

(test-equal "make-uv-tcp rejects a non-loop argument, naming who and why"
  '(make-uv-tcp not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (make-uv-tcp 'not-a-loop)
    'no-raise))

;; --- bind and getsockname ------------------------------------------------
(uv-tcp-bind! t0 "127.0.0.1" 0)

(define bound-port (uv-tcp-getsockname-port t0))

(test-equal "binding to port 0 yields a real ephemeral port"
  'ephemeral
  (if (and (integer? bound-port) (exact? bound-port)
           (> bound-port 1024) (< bound-port 65536))
      'ephemeral
      (list 'not-an-ephemeral-port bound-port)))

(test-equal "uv-tcp-bind! rejects an address that is neither IPv4 nor IPv6"
  '(uv-tcp-bind! bad-address)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-tcp-bind! (make-uv-tcp l) "999.1.1.1" 0)
    'no-raise))

(test-equal "uv-tcp-bind! accepts an IPv6 address literal"
  'bound
  (guard (e (#t (list 'raised (err->symbol e))))
    (uv-tcp-bind! (make-uv-tcp l) "::1" 0)
    'bound))

(test-equal "uv-tcp-bind! rejects a non-string address, naming who and why"
  '(uv-tcp-bind! address-not-a-string)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-tcp-bind! t0 12345 0)
    'no-raise))

(test-equal "uv-tcp-bind! rejects a port outside 0..65535, naming who and why"
  '(uv-tcp-bind! port-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-tcp-bind! t0 "127.0.0.1" 65536)
    'no-raise))

(test-equal "uv-tcp-getsockname-port refuses something that is not a handle"
  '(uv-tcp-getsockname-port not-a-uv-tcp)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-tcp-getsockname-port 'not-a-handle)
    'no-raise))

;; A timer IS a handle and IS open, so nothing but a kind check can refuse
;; it -- and handing a uv_timer_t to uv_tcp_bind is undefined behaviour, not
;; an errno.
(test-equal "uv-tcp-bind! refuses a handle of another kind, naming who and why"
  '(uv-tcp-bind! not-a-uv-tcp)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-tcp-bind! (make-uv-timer l) "127.0.0.1" 0)
    'no-raise))

(test-equal "uv-write! refuses a handle of another kind, naming who and why"
  '(uv-write! not-a-uv-tcp)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-write! (make-uv-timer l) (string->utf8 "hello") (lambda (err) #f))
    'no-raise))

;; uv_tcp_init does not create the socket on unix -- bind or connect does --
;; so an untouched handle has no fd, and libuv's uv__getsockpeername answers
;; whatever uv_fileno does with a handle that has none:
;; UV_EBADF (vendor/libuv/src/unix/core.c, one code path for both supported
;; platforms). MEASURED on this platform, then locked in: the point of the
;; row is that the rc is CHECKED at all rather than ignored, and it is
;; asserted as a SYMBOL (ADR-0006), never as the raw -9.
(test-equal "uv-tcp-getsockname-port on an unbound handle surfaces libuv's errno"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-tcp-getsockname-port (make-uv-tcp l))
    'no-raise))

;; --- the port is byte-swapped, and this is the row that proves it --------
;; Every other port in this suite is ephemeral, so a getsockname that forgot
;; ntohs would return a different-but-equally-plausible number and every
;; "port > 1024" row would still pass. Binding a KNOWN port is the only way
;; to make the swap detectable: 46137 is 0xB439, whose byte-swap is 0x39B4 =
;; 14772, so a missing swap fails this row by name with a specific wrong
;; number.
;;
;; A fixed port can be occupied by something else on the machine, which is
;; precisely what ADR-0010 avoids everywhere else. So it is tried against a
;; small candidate list, EADDRINUSE moving on to the next -- and if every
;; candidate is busy the row fails loudly rather than passing vacuously.
(define fixed-port-candidates '(46137 46339 46541 46743 46945))

(define fixed-loop (make-uv-loop))

(define (bind-a-fixed-port ports)
  (if (null? ports)
      (cons #f 'every-candidate-port-was-in-use)
      (let* ((s (make-uv-tcp fixed-loop))
             (outcome (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
                                (#t 'wrong-condition))
                        (uv-tcp-bind! s "127.0.0.1" (car ports))
                        'bound)))
        (if (eq? outcome 'bound)
            (cons s (car ports))
            (begin
              (uv-close! s)
              (uv-run fixed-loop 'nowait)
              (bind-a-fixed-port (cdr ports)))))))

(define fixed (bind-a-fixed-port fixed-port-candidates))

(test-equal "getsockname reads back the EXACT port bound, byte order and all"
  (cdr fixed)
  (if (car fixed)
      (uv-tcp-getsockname-port (car fixed))
      'no-candidate-port-was-free))

(uv-loop-teardown! fixed-loop)

;; --- listen validation ---------------------------------------------------
(test-equal "uv-listen! rejects a non-procedure callback, naming who and why"
  '(uv-listen! on-connection-not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-listen! t0 128 'not-a-procedure)
    'no-raise))

(test-equal "uv-listen! rejects a negative backlog, naming who and why"
  '(uv-listen! backlog-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-listen! t0 -1 (lambda (err) #f))
    'no-raise))

(uv-loop-teardown! l)

(test-equal "the construction loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- listen / connect / accept, end to end -------------------------------
;; One loop, both endpoints, no subprocess (ADR-0010).
(define el (make-uv-loop))

(define connection-err 'connection-cb-never-fired)
(define connection-fires 0)
(define accepted 'never-accepted)
(define connect-err 'connect-cb-never-fired)

(define server (make-uv-tcp el))
(define server-port (bind-loopback! server))

(uv-listen! server 128
            (lambda (err)
              (collect)
              (set! connection-fires (+ connection-fires 1))
              (set! connection-err err)
              (when (not err)
                (set! accepted (uv-accept! server)))))

(define client (make-uv-tcp el))

(connect-loopback! client server-port
                   (lambda (err) (collect) (set! connect-err err)))

(define exchange-outcome
  (run-until el
             (lambda () (and (not (eq? connection-err 'connection-cb-never-fired))
                             (not (eq? connect-err 'connect-cb-never-fired))))
             cap))

(test-equal "the loop delivered both the connection and the connect callback"
  'satisfied exchange-outcome)

(test-equal "the connection callback fired exactly once"
  1 connection-fires)

(test-equal "the connection callback was handed no error"
  'no-error (err->symbol connection-err))

(test-equal "the connect callback was handed no error"
  'no-error (err->symbol connect-err))

(test-equal "uv-accept! returned an open tcp handle"
  '(a-tcp open)
  (if (uv-tcp? accepted)
      (list 'a-tcp (uv-handle-state accepted))
      (list 'not-a-tcp accepted)))

(test-equal "the accepted handle belongs to the same loop as its server"
  'same
  (if (and (uv-tcp? accepted) (eq? el (uv-handle-loop accepted)))
      'same 'different))

(test-equal "seed: three tcp handles are live -- server, client and peer"
  3 (live-count 'tcp))

(test-equal "uv-tcp-nodelay! succeeds on a connected handle"
  'set
  (guard (e (#t (list 'raised (err->symbol e))))
    (uv-tcp-nodelay! client #t)
    'set))

(test-equal "uv-tcp-nodelay! rejects a non-boolean, naming who and why"
  '(uv-tcp-nodelay! enable-not-a-boolean)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-tcp-nodelay! client 'yes)
    'no-raise))

;; --- uv-accept! with nothing pending: the failure path, for real ---------
;; libuv answers EAGAIN when no connection is queued. That is the accept
;; failure design spec risk #8 describes, reachable without a stub: the
;; freshly-init'd client's memory can only be released by close_cb, so the
;; binding must route it through the NORMAL close path before re-raising.
(define tcp-live-before-failed-accept (live-count 'tcp))

(define failed-accept
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-accept! server)
    'no-raise))

(test-equal "uv-accept! with no pending connection surfaces libuv's errno"
  'EAGAIN failed-accept)

;; The SEED for the row below: a handle really was allocated before the
;; failure, and its close is in flight (uv_close only schedules close_cb).
;; Without this, "the counter is back where it started" would also pass
;; against a uv-accept! that never allocated anything.
(test-equal "seed: the failed accept had already allocated its client handle"
  1 (- (live-count 'tcp) tcp-live-before-failed-accept))

(uv-run el 'nowait)

(test-equal "the failed accept's client was closed through the normal close path"
  tcp-live-before-failed-accept (live-count 'tcp))

;; --- write, verified by completion (reading is Stage 5) ------------------
;; The peer is accepted but never read from, so these five bytes sit in the
;; kernel's socket buffer. That is enough for uv_write to complete, which is
;; the property this stage can check.
(define write-err 'write-cb-never-fired)
(define write-fires 0)
(define write-req-live-inside 'on-complete-never-ran)
(define registry-inside 'on-complete-never-ran)

(define payload (string->utf8 "hello"))

(define write-registry-before (registry-count))

(define first-write
  (uv-write! client payload
             (lambda (err)
               (collect)
               (set! write-fires (+ write-fires 1))
               (set! write-err err)
               ;; Design spec S7: the block is freed BEFORE on-complete runs.
               ;; Both observations are taken from INSIDE the callback, which
               ;; is the only place the ordering is visible at all.
               (set! write-req-live-inside (live-count 'write-req))
               (set! registry-inside (- (registry-count) write-registry-before)))))

(test-equal "seed: an in-flight write is counted and registered"
  '(1 1)
  (list (live-count 'write-req) (- (registry-count) write-registry-before)))

(test-equal "the in-flight write request is registered against its handle's loop"
  'same
  (if (eq? el (registry-loop-of (req-ptr first-write))) 'same 'different))

;; The caller's bytevector is free the instant uv-write! returns (design
;; spec S7: the copy into the foreign block is already complete). Mutating
;; it here is the assertion -- if the binding had kept a reference into the
;; Scheme heap, this is where it would corrupt the in-flight write. What the
;; PEER received is Stage 5's business; what is checked here is that the
;; write still completes cleanly and that this process survives it.
(bytevector-u8-set! payload 0 (char->integer #\X))
(bytevector-u8-set! payload 4 (char->integer #\Z))

(define write-outcome
  (run-until el (lambda () (positive? write-fires)) cap))

(test-equal "the write completion callback arrived"
  'satisfied write-outcome)

(test-equal "the write completed without error"
  'no-error (err->symbol write-err))

(test-equal "the write completion fired exactly once"
  1 write-fires)

(test-equal "the write block was already freed when on-complete ran"
  0 write-req-live-inside)

(test-equal "the write request was already deregistered when on-complete ran"
  0 registry-inside)

(test-equal "the write request record's pointer was zeroed at the freeing site"
  0 (req-ptr first-write))

(test-equal "the write counters balance after the completion"
  0 (live-count 'write-req))

;; --- write argument validation, all of it BEFORE any allocation ----------
;; AGENTS.md's right-to-left trap: this must not depend on which argument of
;; the assertion runs first. `let*` sequences the three observations
;; explicitly, so the recorded before/after counters are unambiguous.
(define span-probe
  (let* ((before-count (live-count 'write-req))
         (before-registry (registry-count))
         (outcome (guard (e ((uv-invalid-argument? e)
                             (list (uv-invalid-argument-who e)
                                   (uv-invalid-argument-reason e)))
                            (#t 'wrong-condition))
                    (uv-write! client (string->utf8 "hello") 3 99
                               (lambda (err) #f))
                    'no-raise))
         (after-count (live-count 'write-req))
         (after-registry (registry-count)))
    (list outcome
          (list before-count after-count)
          (- after-registry before-registry))))

(test-equal "an out-of-range span is refused before anything is allocated"
  '((uv-write! span-out-of-range) (0 0) 0) span-probe)

(test-equal "a negative start is refused, naming who and why"
  '(uv-write! span-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-write! client (string->utf8 "hello") -1 2 (lambda (err) #f))
    'no-raise))

(test-equal "an end before start is refused, naming who and why"
  '(uv-write! span-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-write! client (string->utf8 "hello") 4 2 (lambda (err) #f))
    'no-raise))

(test-equal "a source that is not a bytevector is refused, naming who and why"
  '(uv-write! source-not-a-bytevector)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-write! client "hello" (lambda (err) #f))
    'no-raise))

(test-equal "a non-procedure on-complete is refused, naming who and why"
  '(uv-write! on-complete-not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-write! client (string->utf8 "hello") 'not-a-procedure)
    'no-raise))

;; --- a written span, not the whole bytevector ----------------------------
;; WHAT WAS ACTUALLY COPIED is checked here, on this side of the wire.
;; Reading is Stage 5, so the peer's view is not available -- but the write
;; block is, until its completion frees it, and the block is where the copy
;; landed. So the loop is deliberately NOT run between uv-write! and the
;; three assertions below: the request is still in flight, so its block is
;; still alive and its uv_buf_t still describes the copy.
;;
;; The offset arithmetic is redone here from the SAME constants the binding
;; uses, not read out of it: a binding that laid the block out differently
;; would have this suite reading the wrong address, which is the point.
(define span-source (string->utf8 "0123456789"))
(define span-err 'span-write-never-fired)

(define span-req
  (uv-write! client span-source 2 5
             (lambda (err) (collect) (set! span-err err))))

(define span-block (req-ptr span-req))
(define span-buf
  (+ span-block (* 16 (div (+ (uv-req-size (uv-write-req-type)) 15) 16))))

(test-equal "the write block's uv_buf_t carries the SPAN's length, not the bytevector's"
  3 (uv-buf-len span-buf))

;; Design spec S7's single block: the payload pointer must address memory
;; inside the request's own allocation, never the Scheme heap and never a
;; second allocation.
(test-equal "the payload pointer addresses memory inside the request's own block"
  'inside
  (let ((base (uv-buf-base span-buf)))
    (if (and (> base span-block) (> base span-buf)) 'inside (list 'outside base))))

;; The bytes themselves. A copy that read from offset 0 instead of `start`
;; would put "012" here -- same length, same completion, wrong payload, and
;; invisible to every other row in this suite until Stage 5 can read the
;; peer's end.
(test-equal "the copied bytes are the requested span, not the head of the bytevector"
  (string->utf8 "234")
  (copy-out (uv-buf-base span-buf) (uv-buf-len span-buf)))

(test-equal "a span write completes without error"
  'no-error
  (begin (run-until el (lambda () (not (eq? span-err 'span-write-never-fired)))
                    cap)
         (err->symbol span-err)))

;; --- shutdown ------------------------------------------------------------
(define shutdown-err 'shutdown-cb-never-fired)
(define shutdown-registry-inside 'on-shutdown-never-ran)
(define shutdown-registry-before (registry-count))

(define shutdown-req
  (uv-shutdown! client
                (lambda (err)
                  (collect)
                  (set! shutdown-err err)
                  (set! shutdown-registry-inside
                        (- (registry-count) shutdown-registry-before)))))

(test-equal "seed: an in-flight shutdown request is registered"
  1 (- (registry-count) shutdown-registry-before))

(test-equal "the shutdown completed without error"
  'no-error
  (begin (run-until el
                    (lambda () (not (eq? shutdown-err 'shutdown-cb-never-fired)))
                    cap)
         (err->symbol shutdown-err)))

(test-equal "the shutdown request was already deregistered when on-shutdown ran"
  0 shutdown-registry-inside)

(test-equal "the shutdown request record's pointer was zeroed at the freeing site"
  0 (req-ptr shutdown-req))

;; Writing to a shut-down stream fails. WHICH failure is libuv's business:
;; the synchronous uv_write may refuse it outright, or accept it and report
;; an errno to the completion callback. Both are recorded as failures here,
;; and the observed one is written into the mutation log -- what must NOT
;; happen is a clean success.
(define post-shutdown-sync 'no-sync-raise)
(define post-shutdown-async 'post-shutdown-write-never-completed)

(guard (e ((uv-errno-error? e) (set! post-shutdown-sync (uv-errno-error-errno e)))
          (#t (set! post-shutdown-sync 'wrong-condition)))
  (uv-write! client (string->utf8 "after") (lambda (err)
                                             (collect)
                                             (set! post-shutdown-async err))))

;; ONLY if uv_write accepted the write. A synchronous refusal means no
;; completion callback will ever fire, and stepping a loop whose next event
;; does not exist is a hang, not a test result.
(when (eq? post-shutdown-sync 'no-sync-raise)
  (run-until el
             (lambda ()
               (not (eq? post-shutdown-async
                         'post-shutdown-write-never-completed)))
             cap))

;; RECORDED, not asserted: which of the two legal failures this platform
;; produced. The mutation log carries the observed value; the assertion below
;; carries the contract.
(display "  [informational] write after shutdown: sync=")
(display post-shutdown-sync)
(display " async=")
;; A synchronous refusal means no completion callback was ever scheduled, so
;; the async observer is still holding its seed. Reporting that as
;; 'not-attempted rather than running the seed through err->symbol keeps the
;; informational line from reading like an unexpected condition object.
(display (if (eq? post-shutdown-sync 'no-sync-raise)
             (err->symbol post-shutdown-async)
             'not-attempted))
(newline)

(test-equal "a write after shutdown fails, synchronously or in its completion"
  'failed
  (let ((sync post-shutdown-sync)
        (async (err->symbol post-shutdown-async)))
    (cond ((not (eq? sync 'no-sync-raise)) 'failed)
          ((eq? async 'no-error) (list 'write-after-shutdown-succeeded sync async))
          ((symbol? async) 'failed)
          (else (list 'unexpected sync async)))))

(uv-loop-teardown! el)

(test-equal "the exchange loop tore down cleanly"
  registry-count-at-start (registry-count))

(test-equal "every tcp handle of the exchange was freed"
  0 (live-count 'tcp))

;; --- use after close -----------------------------------------------------
(define cl (make-uv-loop))
(define closed-tcp (make-uv-tcp cl))

(uv-close! closed-tcp)
(uv-run cl 'default)

(test-equal "seed: the closed handle really reached 'closed"
  'closed (uv-handle-state closed-tcp))

(test-equal "uv-write! on a closed handle raises &uv-handle-closed, kind 'tcp"
  'tcp
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-write! closed-tcp (string->utf8 "hello") (lambda (err) #f))
    'no-raise))

(test-equal "uv-shutdown! on a closed handle raises &uv-handle-closed, kind 'tcp"
  'tcp
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-shutdown! closed-tcp (lambda (err) #f))
    'no-raise))

(test-equal "uv-tcp-connect! on a closed handle raises &uv-handle-closed, kind 'tcp"
  'tcp
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-tcp-connect! closed-tcp "127.0.0.1" 9 (lambda (err) #f))
    'no-raise))

(test-equal "uv-listen! on a closed handle raises &uv-handle-closed, kind 'tcp"
  'tcp
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-listen! closed-tcp 128 (lambda (err) #f))
    'no-raise))

;; The close dispatcher frees the per-handle read buffer (design spec S5's
;; "pop registry entry -> free read buffer -> free handle pointer"). Stage 5
;; owns the code that FILLS that field; the arm that frees it ships now, so
;; it is exercised now rather than left as dead code until then. The buffer
;; is a real foreign-alloc, so a close that forgot it leaks (Valgrind) and a
;; close that freed it twice traps (ASan).
(define buffered-tcp (make-uv-tcp cl))

(set-tcp-read-buf! buffered-tcp (alloc-zeroed 64))
(set-tcp-read-buf-len! buffered-tcp 64)
(count-read-buffer-new!)

(test-equal "seed: the handle holds a live read buffer before it is closed"
  1 (live-count 'read-buffer))

(uv-close! buffered-tcp)
(uv-run cl 'default)

(test-equal "the close dispatcher freed the handle's read buffer"
  0 (live-count 'read-buffer))

(test-equal "the close dispatcher zeroed the read-buffer field"
  '(0 0)
  (list (tcp-read-buf buffered-tcp) (tcp-read-buf-len buffered-tcp)))

(uv-loop-teardown! cl)

;; --- close with a write still in flight ----------------------------------
;; Design spec S5: request callbacks tolerate a 'closing handle -- an
;; in-flight write completing with 'ECANCELED lands there. BOTH orderings
;; are legal (the write may already have been handed to the kernel when the
;; close starts), so this asserts the disjunction and RECORDS which one this
;; platform produced, rather than pretending one of them is the contract.
(define pl (make-uv-loop))
(define pending-conn 'connection-cb-never-fired)
(define pending-peer 'never-accepted)
(define pending-write-err 'write-cb-never-fired)
(define pending-closed 'on-close-never-ran)
(define pending-connect-err 'connect-cb-never-fired)

(define pserver (make-uv-tcp pl))
(define pserver-port (bind-loopback! pserver))

(uv-listen! pserver 128
            (lambda (err)
              (collect)
              (set! pending-conn err)
              (when (not err) (set! pending-peer (uv-accept! pserver)))))

(define pclient (make-uv-tcp pl))

(connect-loopback! pclient pserver-port
                   (lambda (err) (collect) (set! pending-connect-err err)))

(run-until pl (lambda () (not (eq? pending-connect-err 'connect-cb-never-fired)))
           cap)

(define write-req-live-before-pending (live-count 'write-req))

(uv-write! pclient (string->utf8 "in flight")
           (lambda (err) (collect) (set! pending-write-err err)))

(test-equal "seed: the write was in flight when uv-close! was called"
  1 (- (live-count 'write-req) write-req-live-before-pending))

(uv-close! pclient (lambda () (collect) (set! pending-closed 'on-close-ran)))

(define pending-outcome
  (run-until pl
             (lambda () (and (not (eq? pending-write-err 'write-cb-never-fired))
                             (eq? pending-closed 'on-close-ran)))
             cap))

(test-equal "both the write completion and the close callback arrived"
  'satisfied pending-outcome)

;; RECORDED, not asserted: which of the two legal orderings won this run.
(display "  [informational] write racing close completed as: ")
(display (err->symbol pending-write-err))
(newline)

;; The disjunction, stated as a membership test rather than as a single
;; expected value. 'write-cb-never-fired (the seed) and any other errno are
;; both outside the set, so this cannot pass vacuously.
(test-equal "a write racing a close completes either cleanly or as 'ECANCELED"
  'a-legal-ordering
  (let ((observed (err->symbol pending-write-err)))
    (if (memq observed '(no-error ECANCELED)) 'a-legal-ordering observed)))

(test-equal "the handle's on-close callback still ran"
  'on-close-ran pending-closed)

(test-equal "the write request was freed exactly once, whichever ordering won"
  write-req-live-before-pending (live-count 'write-req))

(test-equal "the closed client reached 'closed"
  'closed (uv-handle-state pclient))

(uv-loop-teardown! pl)

(test-equal "the pending-write loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- the same race, forced to the ECANCELED side -------------------------
;; The row above records whichever ordering the platform produced, and on a
;; five-byte write that is "the kernel already took it" -- so the 'ECANCELED
;; arm design spec S5 exists for would never actually run. Four megabytes to
;; a peer that is not reading does not fit in any socket buffer, so the write
;; is still QUEUED INSIDE LIBUV when uv-close! arrives, and the completion
;; has to come back as a cancellation. That is the arm under test: a request
;; callback delivered to a handle that is already 'closing, carrying a
;; nonzero status that becomes a condition OBJECT rather than a raise.
(define ql (make-uv-loop))
(define q-peer 'never-accepted)
(define q-connect-err 'connect-cb-never-fired)
(define q-write-err 'write-cb-never-fired)
(define q-state-inside 'on-complete-never-ran)
(define q-closed 'on-close-never-ran)

(define qserver (make-uv-tcp ql))
(define qport (bind-loopback! qserver))

(uv-listen! qserver 128
            (lambda (err)
              (collect)
              (when (not err) (set! q-peer (uv-accept! qserver)))))

(define qclient (make-uv-tcp ql))

(connect-loopback! qclient qport
                   (lambda (err) (collect) (set! q-connect-err err)))

(run-until ql
           (lambda () (and (not (eq? q-connect-err 'connect-cb-never-fired))
                           (uv-tcp? q-peer)))
           cap)

(uv-write! qclient (make-bytevector 4194304 65)
           (lambda (err)
             (collect)
             (set! q-write-err err)
             (set! q-state-inside (uv-handle-state qclient))))

(uv-close! qclient (lambda () (collect) (set! q-closed 'on-close-ran)))

(test-equal "a write too large for the socket buffer, cancelled by a close, reports 'ECANCELED"
  'ECANCELED
  (begin
    (run-until ql
               (lambda () (and (not (eq? q-write-err 'write-cb-never-fired))
                               (eq? q-closed 'on-close-ran)))
               256)
    (err->symbol q-write-err)))

;; Design spec S5: "private dispatchers still tolerate this state: in-flight
;; request callbacks (e.g. 'ECANCELED writes) land here". Sampled from inside
;; the completion, which is the only place the handle's state at delivery
;; time is observable.
(test-equal "the cancelled write was delivered to a handle that was already 'closing"
  'closing q-state-inside)

(test-equal "the cancelled write's four-megabyte block was freed"
  0 (live-count 'write-req))

(uv-loop-teardown! ql)

(test-equal "the cancelled-write loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- a refused connection ------------------------------------------------
;; The deterministic loopback refusal ADR-0010 allows: bind a socket to an
;; ephemeral port, read the port back, close it, and connect there. Nothing
;; is listening, so the kernel refuses. A rebind by another process in the
;; window is theoretically possible, so the assertion is on the SHAPE (an
;; errno-error carrying a symbol) with the observed symbol recorded.
(define rl (make-uv-loop))
(define doomed (make-uv-tcp rl))

(define dead-port (bind-loopback! doomed))

(uv-close! doomed)
(uv-run rl 'default)

(define refused-err 'connect-cb-never-fired)

(connect-loopback! (make-uv-tcp rl) dead-port
                   (lambda (err) (collect) (set! refused-err err)))

(define refused-outcome
  (run-until rl (lambda () (not (eq? refused-err 'connect-cb-never-fired))) cap))

(test-equal "the connect callback arrived for the refused connection"
  'satisfied refused-outcome)

(test-equal "a refused connection is delivered as an &uv-errno-error object, not raised"
  'errno-error-object
  (if (uv-errno-error? refused-err) 'errno-error-object (list 'not-an-errno refused-err)))

(test-equal "its errno is a symbol, and the symbol is 'ECONNREFUSED"
  'ECONNREFUSED (err->symbol refused-err))

(test-equal "the failed connect's request block was freed"
  0 (live-count 'connect-req))

(uv-loop-teardown! rl)

;; --- a raise from inside a request callback ------------------------------
;; The store-and-reraise policy (design spec S8) applies to the new
;; dispatchers exactly as it does to the timer's: a raise inside on-complete
;; is caught, stored, and re-raised by uv-run wrapped as &uv-callback-error
;; composed with the original condition.
(define gl (make-uv-loop))
(define graise-conn 'connection-cb-never-fired)
(define graise-peer 'never-accepted)

(define gserver (make-uv-tcp gl))
(define gserver-port (bind-loopback! gserver))

(uv-listen! gserver 128
            (lambda (err)
              (collect)
              (set! graise-conn err)
              (when (not err) (set! graise-peer (uv-accept! gserver)))))

(define gclient (make-uv-tcp gl))

(connect-loopback! gclient gserver-port
                   (lambda (err)
                     (collect)
                     (uv-write! gclient (string->utf8 "boom")
                                (lambda (werr)
                                  (collect)
                                  (raise (make-uv-invalid-argument
                                          'on-write-complete 'deliberate))))))

(define graise-outcome
  (guard (e ((uv-callback-error? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (uv-run gl 'default)
    'no-raise))

(test-equal "a raise from a write completion reaches the caller through uv-run"
  'deliberate graise-outcome)

(test-equal "the write block was freed even though on-complete raised"
  0 (live-count 'write-req))

(uv-loop-teardown! gl)

;; --- the four dispatchers this stage installed through the seam ----------
;; Stage 3 left six raising stubs behind (tests/test-timer.sps); Stage 4
;; replaced four of them by name, with no second install-callback-dispatchers!
;; call. Asking "is it still a stub?" on an UNREGISTERED pointer cannot tell
;; the two apart -- a stub's raise is contained by the seam and recorded as
;; an orphan, which is also what a real dispatcher does with a pointer it
;; cannot resolve. So the question is put with a REGISTERED pointer: a stub's
;; raise then lands on that pointer's loop and surfaces from uv-run as
;; &uv-callback-error, where a real dispatcher leaves the error cell alone.
(define dl (make-uv-loop))
(define dtcp (make-uv-tcp dl))
(define dispatch-orphans-before (length (orphan-callback-events)))

((dispatcher-ref 'connection) (handle-ptr dtcp) 0)
((dispatcher-ref 'write-done) (handle-ptr dtcp) 0)
((dispatcher-ref 'shutdown)   (handle-ptr dtcp) 0)
((dispatcher-ref 'connect)    (handle-ptr dtcp) 0)

(test-equal "the four Stage 4 dispatchers are real, not Stage 3's raising stubs"
  'no-raise
  (guard (e (#t (list 'raised e)))
    (uv-run dl 'nowait)
    'no-raise))

;; The connection dispatcher RESOLVED the pointer (it is a tcp record that
;; was never listened on, so there is no callback to run and nothing to
;; record); the three request dispatchers could not, because a handle is not
;; a request, so each records an orphan naming its own callback type. Both
;; halves are asserted at once: a connection dispatcher that fell through to
;; the orphan arm would add a fourth pair here.
(test-equal "the request dispatchers record an orphan for a pointer that is not a request"
  (list (cons 'write-done (handle-ptr dtcp))
        (cons 'shutdown (handle-ptr dtcp))
        (cons 'connect (handle-ptr dtcp)))
  (list-tail (orphan-callback-events) dispatch-orphans-before))

(uv-loop-teardown! dl)

;; --- balance -------------------------------------------------------------
(collect)

(test-equal "the registry is back to its starting size"
  registry-count-at-start (registry-count))

(test-equal "a full collection after teardown leaves every counter at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-end "tcp")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
