#!r6rs
;;; SRFI-64 suite for (libuv tcp) -- design spec S5 (the handle lifecycle,
;;; extended to a second handle type), S6 (the read path: one reusable
;;; per-handle buffer, an infallible alloc_cb, copy-out at the boundary,
;;; UV_EOF kept distinct from errors, read-stop/read-start backpressure), S7
;;; (the write path: one foreign-alloc per write, freed before on-complete),
;;; S8 (callback boundary discipline), S10 (the debug counters) and S11 /
;;; ADR-0010 (loopback only: bind 127.0.0.1:0, read the real port back,
;;; connect from the same loop and process; no subprocess client, no fixed
;;; port, no external network).
;;;
;;; THE WRITE ROWS COME FIRST AND ARE STILL VERIFIED BY COMPLETION rather
;;; than by what arrived at the other end: the kernel buffers a few bytes for
;;; a peer that is not reading, which is what makes "the write completed"
;;; observable on its own. Payload integrity -- that the bytes on the wire are
;;; the bytes the caller passed -- is the read half's business, and the
;;; chunked 1 MiB transfer below is where it is settled end to end.
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
        ;; copied bytes are observable without a read on the other end.
        ;; uv-buf-set! seeds a scratch uv_buf_t for the alloc-dispatcher rows,
        ;; which is the only way to observe what alloc_cb hands libuv back.
        (only (libuv private native)
              live-counts alloc-zeroed free! count-read-buffer-new!
              dispatcher-ref
              uv-req-size uv-buf-base uv-buf-len uv-buf-set! copy-out)
        ;; uv-eof and errno-symbol->value are read from the SHIM's table, not
        ;; transcribed (ADR-0005): the read dispatcher's arms are driven with
        ;; the same values libuv would deliver.
        (only (libuv private constants)
              uv-write-req-type sizeof-uv-buf-t uv-eof errno-symbol->value)
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

;; --- the namelen libuv writes back ---------------------------------------
;; uv-tcp-getsockname-port seeds its `int` out-parameter with the scratch's
;; real size and READS IT BACK, refusing a sockaddr too small to contain
;; sin_port. The refusal arm is not reachable through this API (libuv writes
;; 16 for AF_INET and 28 for AF_INET6, both comfortably above the port's
;; end -- the mutation log records it as mutation-only). What IS reachable,
;; and what this row exists for, is the other direction: the check must not
;; be written so strictly that a real address is refused. An IPv6 handle is
;; the discriminating case, because its sockaddr_in6 is a DIFFERENT size from
;; the sockaddr_in every other row here produces -- a check spelled
;; `(= namelen (sizeof-sockaddr-in))` passes the whole suite except this row.
(define v6 (make-uv-tcp l))

(uv-tcp-bind! v6 "::1" 0)

(test-equal "uv-tcp-getsockname-port answers for an IPv6 handle too, whose namelen differs"
  'ephemeral
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (list 'raised (err->symbol e))))
    (let ((port (uv-tcp-getsockname-port v6)))
      (if (and (integer? port) (exact? port) (> port 1024) (< port 65536))
          'ephemeral
          (list 'not-an-ephemeral-port port)))))

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

(define connect-request
  (connect-loopback! client server-port
                     (lambda (err) (collect) (set! connect-err err))))

;; Taken BEFORE the loop runs, while the connect is still in flight: the
;; block is freed by its completion dispatcher, so this is the only window in
;; which its registry entry exists at all. The write path's twin of this row
;; is "the in-flight write request is registered against its handle's loop";
;; both exist because a connect request that is never registered shows up as
;; a suite that BLOCKS (the completion becomes an orphan and no callback ever
;; runs) rather than as a named failure -- see .plans/stage-4-mutation-log.md,
;; mutation 19.
(test-equal "the in-flight connect request is registered against its handle's loop"
  'same
  (if (eq? el (registry-loop-of (req-ptr connect-request))) 'same 'different))

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

;; The UPPER bound, which the row above cannot see: a payload placed past
;; the block's end still satisfies "after the block start, after the
;; uv_buf_t" while copy-in! corrupts whatever the allocator put next
;; (final-review triage, Task 8 Minors). The block's end is redone from the
;; same constants uv-write! sizes it with -- span-buf is already
;; block + aligned req size, so the end is that plus sizeof(uv_buf_t) plus
;; the span's own 3 bytes -- not read back out of the binding.
(test-equal "the payload's last byte lies inside the request's own block too"
  'inside
  (let ((base (uv-buf-base span-buf))
        (block-end (+ span-buf (sizeof-uv-buf-t) 3)))
    (if (<= (+ base 3) block-end)
        'inside
        (list 'past-the-end base block-end))))

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

(test-equal "uv-read-start! on a closed handle raises &uv-handle-closed, kind 'tcp"
  'tcp
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-read-start! closed-tcp
                    (lambda (bv start end) #f) (lambda () #f) (lambda (err) #f))
    'no-raise))

(test-equal "uv-read-stop! on a closed handle raises &uv-handle-closed, kind 'tcp"
  'tcp
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-read-stop! closed-tcp)
    'no-raise))

;; A closed handle must not have grown a read buffer on the way through the
;; two refusals above: uv-read-start! validates the handle BEFORE it allocates
;; anything, exactly as uv-write! validates its span before allocating.
(test-equal "the refused reads on a closed handle allocated no buffer"
  0 (live-count 'read-buffer))

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

;; =========================================================================
;; --- THE READ PATH (design spec S6) --------------------------------------
;; =========================================================================
;; Everything below is Stage 5: uv-read-start! / uv-read-stop!, the per-handle
;; buffer, the alloc and read dispatchers, copy-out at the boundary, UV_EOF
;; kept distinct from errors, and the backpressure contract the HTTP layer
;; above this library is going to be built on.

;; --- argument validation, all of it BEFORE any allocation ----------------
(define vl (make-uv-loop))
(define vtcp (make-uv-tcp vl))

;; Named, so the same three procedures can be handed to several starts (the
;; identity of the callbacks is part of what the re-start rows assert).
(define (ignore-data bv start end) #f)
(define (ignore-eof) #f)
(define (ignore-error err) #f)

(test-equal "uv-read-start! rejects a non-procedure on-data, naming who and why"
  '(uv-read-start! on-data-not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! vtcp 'not-a-procedure ignore-eof ignore-error)
    'no-raise))

(test-equal "uv-read-start! rejects a non-procedure on-eof, naming who and why"
  '(uv-read-start! on-eof-not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! vtcp ignore-data 'not-a-procedure ignore-error)
    'no-raise))

(test-equal "uv-read-start! rejects a non-procedure on-error, naming who and why"
  '(uv-read-start! on-error-not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! vtcp ignore-data ignore-eof 'not-a-procedure)
    'no-raise))

(test-equal "uv-read-start! refuses a handle of another kind, naming who and why"
  '(uv-read-start! not-a-uv-tcp)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! (make-uv-timer vl) ignore-data ignore-eof ignore-error)
    'no-raise))

(test-equal "uv-read-stop! refuses a handle of another kind, naming who and why"
  '(uv-read-stop! not-a-uv-tcp)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-stop! (make-uv-timer vl))
    'no-raise))

;; AGENTS.md's right-to-left trap again: `let*` sequences the before/after
;; observations explicitly rather than trusting argument evaluation order.
(define read-size-probe
  (let* ((before (live-count 'read-buffer))
         (outcome (guard (e ((uv-invalid-argument? e)
                             (list (uv-invalid-argument-who e)
                                   (uv-invalid-argument-reason e)))
                            (#t 'wrong-condition))
                    (uv-read-start! vtcp ignore-data ignore-eof ignore-error 0)
                    'no-raise))
         (after (live-count 'read-buffer)))
    (list outcome before after)))

(test-equal "a buffer size of zero is refused before anything is allocated"
  '((uv-read-start! buffer-size-out-of-range) 0 0) read-size-probe)

(test-equal "an inexact buffer size is refused, naming who and why"
  '(uv-read-start! buffer-size-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! vtcp ignore-data ignore-eof ignore-error 65536.0)
    'no-raise))

(test-equal "a negative buffer size is refused, naming who and why"
  '(uv-read-start! buffer-size-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! vtcp ignore-data ignore-eof ignore-error -1)
    'no-raise))

;; uv_tcp_init does not create a socket, so this handle is not readable and
;; libuv refuses the start. MEASURED on this platform, then locked in, like
;; the EBADF row above: the point is that the rc is CHECKED, and that it
;; arrives as a SYMBOL (ADR-0006) rather than as a raw negative int.
(test-equal "uv-read-start! on a stream that is not connected surfaces libuv's errno"
  'ENOTCONN
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-read-start! vtcp ignore-data ignore-eof ignore-error)
    'no-raise))

;; The buffer is the HANDLE's, not the read's: a start that libuv refused has
;; still allocated it, and it is not unwound here, because design spec S6
;; makes the close dispatcher the only place it may ever be freed. Both
;; halves of that are asserted -- it exists now, and it is gone after close.
(test-equal "seed: the refused start had already allocated the handle's read buffer"
  1 (live-count 'read-buffer))

(test-equal "a failed start leaves the handle NOT reading"
  'not-reading (if (tcp-reading? vtcp) 'reading 'not-reading))

(uv-loop-teardown! vl)

(test-equal "the buffer a failed read-start left behind is freed by the close dispatcher"
  0 (live-count 'read-buffer))

;; --- one write, read at the other end ------------------------------------
;; The first row in this suite that observes a payload from the PEER's side
;; rather than from the write block. `(bv start end)` is asserted as a
;; framing, not just as content: design spec S6 hands on-data a SPAN so a
;; future zero-copy variant can answer a sub-range of a larger buffer, and
;; today's copy must therefore be a bytevector whose whole length is the span.
(define sl (make-uv-loop))
(define s-in (make-byte-collector))
(define s-frames '())
(define s-data-fires 0)
(define s-eof-fires 0)
(define s-error 'on-error-never-fired)
(define s-empty-span 'no-empty-span-was-delivered)
(define s-peer 'never-accepted)

(define (s-on-data bv start end)
  (collect)
  (set! s-data-fires (+ s-data-fires 1))
  ;; The nread = 0 detector. libuv's "nothing to read this time" must never
  ;; reach on-data, and an empty span is what it would look like if it did.
  (when (= start end) (set! s-empty-span 'an-empty-span-was-delivered))
  (set! s-frames (cons (list start end (bytevector-length bv)) s-frames))
  (collect-span! s-in bv start end))

(define (s-on-eof) (collect) (set! s-eof-fires (+ s-eof-fires 1)))

(define (s-on-error err) (collect) (set! s-error (err->symbol err)))

(define sserver (make-uv-tcp sl))
(define sport (bind-loopback! sserver))

(uv-listen! sserver 128
            (lambda (err)
              (collect)
              (when (not err)
                (set! s-peer (uv-accept! sserver))
                ;; Legal from inside a callback, and required here: design
                ;; spec S8 lists uv-read-start! among the operations that may
                ;; run inside one.
                (uv-read-start! s-peer s-on-data s-on-eof s-on-error))))

(define sclient (make-uv-tcp sl))
(define s-payload (string->utf8 "hello, read path"))
(define s-write-err 'write-cb-never-fired)

(connect-loopback! sclient sport
                   (lambda (err)
                     (collect)
                     (uv-write! sclient s-payload
                                (lambda (werr)
                                  (collect)
                                  (set! s-write-err werr)))))

(define s-outcome
  (run-until/ticking sl (lambda () (positive? s-data-fires)) cap))

(test-equal "the peer's on-data callback delivered the client's write"
  'satisfied s-outcome)

(test-equal "on-data is handed the span (0 . nread) over a bytevector of exactly nread bytes"
  (list 0 (bytevector-length s-payload) (bytevector-length s-payload))
  (car (reverse s-frames)))

(test-equal "the bytes the peer read are the bytes the client wrote"
  s-payload (collector-bytes s-in))

(test-equal "delivering data fires neither on-eof nor on-error"
  '(0 on-error-never-fired) (list s-eof-fires s-error))

(test-equal "seed: the first read-start allocated exactly one read buffer"
  1 (live-count 'read-buffer))

(test-equal "a started read records that the handle is reading"
  'reading (if (tcp-reading? s-peer) 'reading 'not-reading))

;; --- stop, start, and the ONE buffer -------------------------------------
(define s-buffer-before-cycles (tcp-read-buf s-peer))

(uv-read-stop! s-peer)

(test-equal "uv-read-stop! outside a callback clears the reading flag"
  'not-reading (if (tcp-reading? s-peer) 'reading 'not-reading))

(test-equal "uv-read-stop! on a handle that is not reading is a no-op, not an error"
  'stopped
  (guard (e (#t (list 'raised (err->symbol e))))
    (uv-read-stop! s-peer)
    'stopped))

;; 50 cycles. A binding that allocated per start would leak 49 buffers, which
;; the counter sees; one that freed the old buffer each time would keep the
;; counter at 1 and still hand out a different address, which only the
;; pointer sees. Both are asserted, because they fail differently.
(let cycle ((i 0))
  (when (< i 50)
    (uv-read-start! s-peer s-on-data s-on-eof s-on-error)
    (uv-read-stop! s-peer)
    (cycle (+ i 1))))

(test-equal "50 read-start/stop cycles leave exactly one live read buffer"
  1 (live-count 'read-buffer))

(test-equal "...and it is the same buffer, not a fresh allocation per call"
  'same
  (if (= s-buffer-before-cycles (tcp-read-buf s-peer)) 'same 'reallocated))

;; --- the buffer's size is fixed by the first start -----------------------
;; Exercised on the CLIENT handle, which is connected and not reading, so the
;; sizes here are this suite's own rather than the default.
(uv-read-start! sclient ignore-data ignore-eof ignore-error 4096)

(test-equal "seed: an explicit buffer size is the size actually allocated"
  4096 (tcp-read-buf-len sclient))

(test-equal "seed: a second reading handle means a second read buffer"
  2 (live-count 'read-buffer))

(test-equal "starting a read that is already running surfaces libuv's errno"
  'EALREADY
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-read-start! sclient ignore-data ignore-eof ignore-error 4096)
    'no-raise))

(uv-read-stop! sclient)

(test-equal "restarting with the SAME explicit buffer size is allowed"
  'started
  (guard (e (#t (list 'raised (err->symbol e))))
    (uv-read-start! sclient ignore-data ignore-eof ignore-error 4096)
    'started))

(uv-read-stop! sclient)

(test-equal "restarting with a DIFFERENT explicit buffer size is refused, naming who and why"
  '(uv-read-start! buffer-size-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-read-start! sclient ignore-data ignore-eof ignore-error 8192)
    'no-raise))

(test-equal "the refused restart changed neither the buffer's size nor the buffer count"
  '(4096 2) (list (tcp-read-buf-len sclient) (live-count 'read-buffer)))

;; The row that separates "the size was omitted" from "the size defaulted":
;; a start with no size at all must be accepted against a buffer fixed at
;; ANY size, so an implementation that passed its own 64 KiB default down as
;; if the caller had asked for it fails here and nowhere else.
(test-equal "restarting with the size OMITTED reuses the buffer at whatever size it was fixed"
  '(started 4096 2)
  (guard (e (#t (list 'raised (err->symbol e))))
    (uv-read-start! sclient ignore-data ignore-eof ignore-error)
    (list 'started (tcp-read-buf-len sclient) (live-count 'read-buffer))))

(uv-read-stop! sclient)

;; --- EOF, and that it is not an error ------------------------------------
(uv-read-start! s-peer s-on-data s-on-eof s-on-error)

(define s-shutdown-err 'shutdown-cb-never-fired)

(uv-shutdown! sclient (lambda (err) (collect) (set! s-shutdown-err err)))

(define s-eof-outcome
  (run-until/ticking sl (lambda () (positive? s-eof-fires)) cap))

(test-equal "the peer's on-eof fired when the client shut its write side down"
  'satisfied s-eof-outcome)

(test-equal "the end of the stream fired on-eof exactly once"
  1 s-eof-fires)

(test-equal "EOF is delivered as on-eof, never as an error"
  'on-error-never-fired s-error)

(test-equal "EOF delivered no bytes alongside itself"
  (bytevector-length s-payload) (collector-count s-in))

(test-equal "the write and the shutdown that drove this section both completed cleanly"
  '(no-error no-error)
  (list (err->symbol s-write-err) (err->symbol s-shutdown-err)))

;; --- the read dispatcher's arms, reached directly ------------------------
;; Two of design spec S6's four `nread` cases cannot be produced on demand
;; through libuv: `0` is its "nothing to read this time" (a socket that was
;; readable a moment ago answering EAGAIN), and WHICH errno arrives is the
;; kernel's business. So the dispatcher is called here exactly as the
;; trampoline calls it -- with the handle's own pointer -- which runs the
;; shipped code path rather than a copy of it. tests/test-timer.sps uses the
;; same technique for the timer dispatcher's state check, and for the same
;; reason: without it these arms have no assertion at all.
;;
;; The `buf` argument is passed as 0 deliberately. The read dispatcher takes
;; its bytes from the handle's own buffer field -- the buffer alloc_cb handed
;; libuv in the first place -- so it never dereferences that argument.
(define s-fires-before-direct s-data-fires)
(define s-eof-before-direct s-eof-fires)

((dispatcher-ref 'read) (handle-ptr s-peer) 0 0)

(test-equal "a read callback with nread = 0 delivers nothing: not data, not EOF, not an error"
  (list s-fires-before-direct s-eof-before-direct 'on-error-never-fired)
  (list s-data-fires s-eof-fires s-error))

((dispatcher-ref 'read) (handle-ptr s-peer) (errno-symbol->value 'ENOBUFS) 0)

(test-equal "a negative nread that is not UV_EOF reaches on-error as a condition object"
  'ENOBUFS s-error)

(test-equal "...and reaches neither on-data nor on-eof"
  (list s-fires-before-direct s-eof-before-direct)
  (list s-data-fires s-eof-fires))

;; Design spec S5's tolerance rule, on the read path: a read completion can
;; be queued behind a uv_close, and the handle it names is 'closing by the
;; time it is delivered. Refusing to deliver there would drop the EOF a
;; caller's own bookkeeping may be waiting for.
(set-handle-state! s-peer 'closing)

((dispatcher-ref 'read) (handle-ptr s-peer) (uv-eof) 0)

(test-equal "a read callback that raced a close is still delivered ('closing is tolerated)"
  (+ s-eof-before-direct 1) s-eof-fires)

(set-handle-state! s-peer 'open)

;; --- the alloc dispatcher, reached directly ------------------------------
;; The only way to see what alloc_cb hands libuv back is to call it with a
;; uv_buf_t of one's own. The scratch is seeded with values no success path
;; can leave behind (AGENTS.md), so "the dispatcher wrote nothing" is
;; distinguishable from "the dispatcher wrote an empty buffer".
(define s-scratch-buf (alloc-zeroed (sizeof-uv-buf-t)))

(uv-buf-set! s-scratch-buf 999 999)

;; `suggested` is 1: libuv's hint is deliberately ignored, and a dispatcher
;; that answered the hint instead of the buffer's real length would put a 1
;; here -- and then libuv would read one byte at a time forever.
((dispatcher-ref 'alloc) (handle-ptr s-peer) 1 s-scratch-buf)

(test-equal "the alloc dispatcher hands libuv the handle's own buffer, at its full length"
  (list (tcp-read-buf s-peer) (tcp-read-buf-len s-peer))
  (list (uv-buf-base s-scratch-buf) (uv-buf-len s-scratch-buf)))

(uv-buf-set! s-scratch-buf 999 999)

(test-equal "the alloc dispatcher is infallible: a pointer it cannot resolve raises nothing"
  'no-raise
  (guard (e (#t (list 'raised e)))
    ((dispatcher-ref 'alloc) 909090 65536 s-scratch-buf)
    'no-raise))

(test-equal "...and answers the EMPTY buffer libuv turns into UV_ENOBUFS"
  '(0 0) (list (uv-buf-base s-scratch-buf) (uv-buf-len s-scratch-buf)))

(define s-unread (make-uv-tcp sl))

(uv-buf-set! s-scratch-buf 999 999)

((dispatcher-ref 'alloc) (handle-ptr s-unread) 65536 s-scratch-buf)

(test-equal "a tcp handle that never started reading gets the empty buffer too"
  '(0 0) (list (uv-buf-base s-scratch-buf) (uv-buf-len s-scratch-buf)))

(free! s-scratch-buf)

;; The orphan arm of the read dispatcher: a callback for a pointer the
;; registry does not know must not raise into a C frame (spike FINDINGS Q2:
;; exit 255, no teardown) and must leave a record behind, because a silent
;; swallow is worse than the crash.
(define read-orphans-before (length (orphan-callback-events)))

(test-equal "a read callback for an unregistered pointer does not raise"
  'recorded
  (guard (e (#t (list 'raised e)))
    ((dispatcher-ref 'read) 909091 5 0)
    'recorded))

(test-equal "...and is recorded as an orphan naming its callback type and pointer"
  '((read . 909091))
  (list-tail (orphan-callback-events) read-orphans-before))

(uv-loop-teardown! sl)

(test-equal "closing the two reading handles freed both read buffers"
  0 (live-count 'read-buffer))

(test-equal "no on-data delivery in this section had an empty span"
  'no-empty-span-was-delivered s-empty-span)

(test-equal "the read loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- a chunked 1 MiB transfer, byte for byte -----------------------------
;; The payload integrity claim the write-path rows had to defer: sixteen
;; 64 KiB writes of seeded, deterministic bytes (uv-testing's LCG -- never a
;; clock and never `random`, so a failure is reproducible), accumulated on the
;; other end and compared with bytevector=?.
;;
;; EVERY on-data callback calls (collect), which is design spec S11's
;; GC-pressure axis applied to the read path: sixteen full collections with
;; libuv's C frames live below the Scheme callback, on every run.
(define ml (make-uv-loop))
(define m-chunk 65536)
(define m-chunks 16)
(define m-total (* m-chunk m-chunks))
(define m-payload (seeded-bytes m-total 20260818))
(define m-in (make-byte-collector))
(define m-framing 'every-span-covered-its-whole-bytevector)
(define m-empty-span 'no-empty-span-was-delivered)
(define m-eof-fires 0)
(define m-error 'on-error-never-fired)
(define m-peer 'never-accepted)
(define m-writes-done 0)
(define m-write-err 'no-write-error)

(define (m-on-data bv start end)
  (collect)
  (unless (and (= start 0) (= end (bytevector-length bv)))
    (set! m-framing (list 'span-did-not-cover-its-bytevector
                          start end (bytevector-length bv))))
  (when (= start end) (set! m-empty-span 'an-empty-span-was-delivered))
  (collect-span! m-in bv start end))

(define (m-on-eof) (collect) (set! m-eof-fires (+ m-eof-fires 1)))

(define (m-on-error err) (collect) (set! m-error (err->symbol err)))

(define mserver (make-uv-tcp ml))
(define mport (bind-loopback! mserver))

(uv-listen! mserver 128
            (lambda (err)
              (collect)
              (when (not err)
                (set! m-peer (uv-accept! mserver))
                (uv-read-start! m-peer m-on-data m-on-eof m-on-error))))

(define mclient (make-uv-tcp ml))
(define m-connect-err 'connect-cb-never-fired)

(connect-loopback! mclient mport
                   (lambda (err) (collect) (set! m-connect-err err)))

(run-until/ticking ml
                   (lambda ()
                     (and (uv-tcp? m-peer)
                          (not (eq? m-connect-err 'connect-cb-never-fired))))
                   cap)

(test-equal "seed: the 1 MiB transfer's connection is up at both ends"
  '(a-tcp no-error) (list (if (uv-tcp? m-peer) 'a-tcp 'never-accepted)
                          (err->symbol m-connect-err)))

;; Sixteen spans of ONE bytevector: the span arity of uv-write! is what makes
;; a chunked transfer possible without slicing the payload in Scheme first.
(let write-chunk ((i 0))
  (when (< i m-chunks)
    (uv-write! mclient m-payload (* i m-chunk) (* (+ i 1) m-chunk)
               (lambda (err)
                 (collect)
                 (set! m-writes-done (+ m-writes-done 1))
                 (when err (set! m-write-err (err->symbol err)))))
    (write-chunk (+ i 1))))

(define m-outcome
  (run-until/ticking ml (lambda () (>= (collector-count m-in) m-total)) 1024))

(test-equal "the whole megabyte arrived at the reader"
  'satisfied m-outcome)

(test-equal "every chunk's write completed, none with an error"
  (list m-chunks 'no-write-error) (list m-writes-done m-write-err))

(test-equal "a 1 MiB transfer in 64 KiB chunks arrives byte for byte"
  'identical
  (if (bytevector=? m-payload (collector-bytes m-in)) 'identical 'differs))

(test-equal "every on-data span covered its whole bytevector, start 0 and end nread"
  'every-span-covered-its-whole-bytevector m-framing)

(test-equal "no on-data delivery during the transfer had an empty span"
  'no-empty-span-was-delivered m-empty-span)

;; The EOF half: the client shuts its write side down, and the reader sees
;; the end of the stream rather than an error.
(define m-shutdown-err 'shutdown-cb-never-fired)

(uv-shutdown! mclient (lambda (err) (collect) (set! m-shutdown-err err)))

(define m-eof-outcome
  (run-until/ticking ml (lambda () (positive? m-eof-fires)) cap))

(test-equal "the transfer ended with on-eof exactly once, and no on-error"
  '(satisfied 1 on-error-never-fired)
  (list m-eof-outcome m-eof-fires m-error))

(test-equal "the shutdown that produced the EOF completed cleanly"
  'no-error (err->symbol m-shutdown-err))

(uv-loop-teardown! ml)

(test-equal "the megabyte transfer left every counter at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-equal "the megabyte loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- backpressure: read-stop from inside on-data -------------------------
;; THE CONTRACT THIS LIBRARY EXISTS TO PROVIDE (design spec S6, and S8's list
;; of what is legal inside a callback). A reader that stops must stop
;; RECEIVING -- the bytes stay in the kernel's buffer and on-data does not
;; fire again -- and a reader that starts again must get exactly the bytes it
;; did not take, in order.
;;
;; "The callback did not fire" is only a claim if the loop really iterated
;; while it was not firing, so a 1 ms repeating timer runs alongside and
;; counts iterations. Without that probe, a loop with nothing to do and a
;; loop deliberately withholding data are the same observation.
(define bl (make-uv-loop))
(define b-chunk 1024)
(define b-chunks 4)
(define b-payload (seeded-bytes (* b-chunk b-chunks) 5150))
(define b-in (make-byte-collector))
(define b-data-fires 0)
(define b-eof-fires 0)
(define b-error 'on-error-never-fired)
(define b-write-err 'no-write-error)
(define b-ticks 0)
(define b-peer 'never-accepted)

(define (b-on-data bv start end)
  (collect)
  (set! b-data-fires (+ b-data-fires 1))
  (collect-span! b-in bv start end)
  ;; Backpressure applied from inside the delivery itself.
  (when (= b-data-fires 1) (uv-read-stop! b-peer)))

(define (b-on-eof) (collect) (set! b-eof-fires (+ b-eof-fires 1)))

(define (b-on-error err) (collect) (set! b-error (err->symbol err)))

(define bserver (make-uv-tcp bl))
(define bport (bind-loopback! bserver))

(uv-listen! bserver 128
            (lambda (err)
              (collect)
              (when (not err)
                (set! b-peer (uv-accept! bserver))
                (uv-read-start! b-peer b-on-data b-on-eof b-on-error))))

(define bclient (make-uv-tcp bl))
(define b-connect-err 'connect-cb-never-fired)

(connect-loopback! bclient bport
                   (lambda (err) (collect) (set! b-connect-err err)))

(run-until/ticking bl
                   (lambda ()
                     (and (uv-tcp? b-peer)
                          (not (eq? b-connect-err 'connect-cb-never-fired))))
                   cap)

(define (b-write! from to)
  (uv-write! bclient b-payload from to
             (lambda (err)
               (collect)
               (when err (set! b-write-err (err->symbol err))))))

(b-write! 0 b-chunk)

(define b-first-outcome
  (run-until/ticking bl (lambda () (positive? b-data-fires)) cap))

(test-equal "the first chunk arrived, and on-data stopped the read from inside itself"
  '(satisfied 1 not-reading)
  (list b-first-outcome b-data-fires
        (if (tcp-reading? b-peer) 'reading 'not-reading)))

;; Written while the reader is stopped. Four kilobytes fit in any socket
;; buffer, so nothing here depends on the writes blocking.
(b-write! b-chunk (* 2 b-chunk))
(b-write! (* 2 b-chunk) (* 3 b-chunk))
(b-write! (* 3 b-chunk) (* 4 b-chunk))

(define btimer (make-uv-timer bl))

(uv-timer-start! btimer
                 (lambda (t) (collect) (set! b-ticks (+ b-ticks 1)))
                 1 1)

(define b-idle-outcome (run-until bl (lambda () (>= b-ticks 12)) cap))

(test-equal "seed: the loop really did iterate while the reader was stopped"
  '(satisfied iterated)
  (list b-idle-outcome (if (>= b-ticks 12) 'iterated 'did-not-iterate)))

(test-equal "a stopped reader receives nothing, however long the loop runs"
  (list 1 b-chunk) (list b-data-fires (collector-count b-in)))

(uv-timer-stop! btimer)

;; Restarting with the same three callbacks: the buffer and the stored
;; callbacks are reused, and the bytes held back arrive now, in order.
(uv-read-start! b-peer b-on-data b-on-eof b-on-error)

(define b-resume-outcome
  (run-until/ticking bl
             (lambda () (>= (collector-count b-in) (* b-chunk b-chunks)))
             cap))

(test-equal "restarting the read delivers exactly the bytes that were held back"
  '(satisfied identical)
  (list b-resume-outcome
        (if (bytevector=? b-payload (collector-bytes b-in)) 'identical 'differs)))

(test-equal "the whole backpressure exchange raised nothing and ended no stream early"
  '(0 on-error-never-fired no-write-error)
  (list b-eof-fires b-error b-write-err))

(uv-loop-teardown! bl)

(test-equal "the backpressure loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- a connection reset by the peer --------------------------------------
;; Design spec S12's 'ECONNRESET row. A plain close sends FIN, which is EOF
;; and not a reset, so the reset has to be provoked: a socket closed while
;; unread data is still sitting in its receive queue sends RST instead (the
;; abortive close of RFC 1122 4.2.2.13, implemented by both Darwin and
;; Linux). So the SERVER writes, the client never reads a byte, and the
;; client is then closed.
;;
;; WHAT IS ASSERTED IS THE DISPATCH, NOT THE KERNEL'S CHOICE OF ERRNO. That
;; the failure reaches on-error as an &uv-errno-error carrying a SYMBOL --
;; rather than reaching on-eof, and rather than being raised into libuv's own
;; stack -- is this binding's contract. The observed symbol is printed and
;; recorded in the mutation log.
(define xl (make-uv-loop))
(define x-peer 'never-accepted)
(define x-error 'on-error-never-fired)
(define x-eof-fires 0)
(define x-data-fires 0)
(define x-connect-err 'connect-cb-never-fired)
(define x-write-err 'write-cb-never-fired)

(define xserver (make-uv-tcp xl))
(define xport (bind-loopback! xserver))

(uv-listen! xserver 128
            (lambda (err)
              (collect)
              (when (not err)
                (set! x-peer (uv-accept! xserver))
                (uv-read-start!
                 x-peer
                 (lambda (bv start end)
                   (collect)
                   (set! x-data-fires (+ x-data-fires 1)))
                 (lambda () (collect) (set! x-eof-fires (+ x-eof-fires 1)))
                 (lambda (err) (collect) (set! x-error (err->symbol err)))))))

(define xclient (make-uv-tcp xl))

(connect-loopback! xclient xport
                   (lambda (err) (collect) (set! x-connect-err err)))

(run-until/ticking xl
                   (lambda ()
                     (and (uv-tcp? x-peer)
                          (not (eq? x-connect-err 'connect-cb-never-fired))))
                   cap)

;; The client never calls uv-read-start!, so these bytes stay unread in its
;; receive queue -- which is exactly what makes the close below abortive.
(uv-write! x-peer (make-bytevector 4096 88)
           (lambda (err) (collect) (set! x-write-err err)))

(run-until/ticking xl
                   (lambda () (not (eq? x-write-err 'write-cb-never-fired)))
                   cap)

;; A completed write means libuv handed the bytes to the kernel; two further
;; turns cost nothing and remove any question about whether they have been
;; queued on the client's side before it is closed.
(uv-run xl 'nowait)
(uv-run xl 'nowait)

(uv-close! xclient)

(define x-outcome
  (run-until/ticking xl
             (lambda () (or (not (eq? x-error 'on-error-never-fired))
                            (positive? x-eof-fires)))
             cap))

(display "  [informational] abrupt peer close delivered as: ")
(display x-error)
(display " (on-eof fires: ")
(display x-eof-fires)
(display ")")
(newline)

(test-equal "the abrupt peer close reached the reader"
  'satisfied x-outcome)

(test-equal "a reset is delivered to on-error as a symbol errno, and not to on-eof"
  '(errno-symbol 0)
  (list (cond ((eq? x-error 'on-error-never-fired) 'on-error-never-fired)
              ((symbol? x-error) 'errno-symbol)
              (else (list 'not-a-symbol x-error)))
        x-eof-fires))

;; MEASURED on this platform, then locked in -- the same treatment as the
;; EBADF, EAGAIN and ECONNREFUSED rows above, and design spec S12's named
;; exit criterion for this stage. If a platform ever answers something else
;; here, THIS is the row to re-measure: the row above it is the portable
;; contract (the dispatch), and this one is the kernel's answer on the
;; machines this project tests on.
(test-equal "the errno an abortive close produces here is 'ECONNRESET"
  'ECONNRESET x-error)

;; The client never wrote a byte, so a reader that was handed "data" would be
;; reporting the reset through the wrong callback.
(test-equal "the reset reader was never handed data"
  0 x-data-fires)

(uv-loop-teardown! xl)

(test-equal "the reset loop tore down cleanly"
  registry-count-at-start (registry-count))

;; --- the six dispatchers Stages 4 and 5 installed through the seam -------
;; Stage 3 left six raising stubs behind (tests/test-timer.sps); Stage 4
;; replaced four of them by name and Stage 5 the last two, with no second
;; install-callback-dispatchers! call. Asking "is it still a stub?" on an
;; UNREGISTERED pointer cannot tell the two apart -- a stub's raise is
;; contained by the seam and recorded as an orphan, which is also what a real
;; dispatcher does with a pointer it cannot resolve. So the question is put
;; with a REGISTERED pointer: a stub's raise then lands on that pointer's
;; loop and surfaces from uv-run as &uv-callback-error, where a real
;; dispatcher leaves the error cell alone.
(define dl (make-uv-loop))
(define dtcp (make-uv-tcp dl))
(define dbuf (alloc-zeroed (sizeof-uv-buf-t)))
(define dispatch-orphans-before (length (orphan-callback-events)))

((dispatcher-ref 'connection) (handle-ptr dtcp) 0)
((dispatcher-ref 'write-done) (handle-ptr dtcp) 0)
((dispatcher-ref 'shutdown)   (handle-ptr dtcp) 0)
((dispatcher-ref 'connect)    (handle-ptr dtcp) 0)
((dispatcher-ref 'alloc)      (handle-ptr dtcp) 65536 dbuf)
((dispatcher-ref 'read)       (handle-ptr dtcp) 0 0)

(test-equal "the six dispatchers of Stages 4 and 5 are real, not Stage 3's raising stubs"
  'no-raise
  (guard (e (#t (list 'raised e)))
    (uv-run dl 'nowait)
    'no-raise))

(free! dbuf)

;; The connection, alloc and read dispatchers RESOLVED the pointer (it is a
;; tcp record that was never listened on and never read from, so there is no
;; callback to run and nothing to record); the three request dispatchers
;; could not, because a handle is not a request, so each records an orphan
;; naming its own callback type. Both halves are asserted at once: a
;; connection, alloc or read dispatcher that fell through to the orphan arm
;; would add a fourth pair here.
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
