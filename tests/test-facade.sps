#!r6rs
;;; SRFI-64 suite for the (libuv) facade -- design spec S3's module layout
;;; ("src/libuv.sls  # (libuv) facade: re-exports + uv-version(-compatible?)").
;;;
;;; This suite imports (libuv) and NOTHING ELSE from this project that could
;;; supply one of the facade's own names, and that is its whole point: every
;;; name it uses has to be re-exported by the facade itself. A test that also
;;; imported (libuv loop) or (libuv private conditions) would keep passing
;;; after an export was dropped from src/libuv.sls, because Chez would
;;; resolve the name from the other import -- so the export list would be
;;; guarded by nothing at all.
;;;
;;; The ONE exception is renamed on the way in: `libuv-packed-version` is
;;; (libuv private native)'s uv_version(), and it exists here only so the
;;; facade's uv-version string can be checked against a SECOND source rather
;;; than against itself. It is renamed precisely so it cannot stand in for a
;;; facade export that went missing.
;;;
;;; The failure is at EXPAND time (an unbound identifier), which is a suite
;;; that fails outright rather than an assertion that fails by name. That is
;;; the strongest check available for a re-export list, and it is why the
;;; facade's own procedures (uv-version, uv-version-compatible?) get ordinary
;;; assertions below while the re-exports get exercised instead.
;;;
;;; NOT pure: the facade reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv)
        (rename (only (libuv private native) uv-version)
                (uv-version libuv-packed-version))
        ;; (collect) only, so this suite's timer callback obeys design spec
        ;; S11's "every timer callback calls (collect)" like every other. It
        ;; is not a name the facade could be expected to supply, so it cannot
        ;; stand in for a dropped re-export.
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "facade")

;; --- uv-version ---------------------------------------------------------
(define version (uv-version))

(test-equal "uv-version returns a non-empty string"
  'non-empty-string
  (if (and (string? version) (positive? (string-length version)))
      'non-empty-string
      'not-a-version-string))

;; Cross-check against uv_version()'s packed integer -- a different libuv
;; entry point, reached without going through the facade -- so this is two
;; sources agreeing rather than one source restating itself: a facade that
;; returned a hard-coded or stale string fails here. The comparison is on the
;; "major.minor." prefix, because uv_version_string may carry a pre-release
;; suffix that uv_version()'s patch byte does not describe.
(define packed (libuv-packed-version))

(define expected-prefix
  (string-append (number->string (div packed 65536)) "."
                 (number->string (mod (div packed 256) 256)) "."))

(test-equal "uv-version's string agrees with uv_version()'s major.minor"
  expected-prefix
  (if (>= (string-length version) (string-length expected-prefix))
      (substring version 0 (string-length expected-prefix))
      'string-too-short))

(test-equal "uv_version() reports a version inside libuv's 1.x series"
  1 (div packed 65536))

(test-equal "this shim and this libuv are reported compatible"
  'compatible (if (uv-version-compatible?) 'compatible 'incompatible))

;; --- the re-exported loop surface, driven through the facade alone ------
(define l (make-uv-loop))

(test-equal "a loop made through the facade is open"
  'open (if (uv-loop-open? l) 'open 'not-open))

(test-equal "uv-loop? is re-exported and accepts the loop"
  'a-loop (if (uv-loop? l) 'a-loop 'not-a-loop))

(test-equal "uv-run is re-exported and reports no work on an empty loop"
  'no-work (if (uv-run l 'nowait) 'work 'no-work))

(test-equal "uv-loop-alive? is re-exported"
  'not-alive (if (uv-loop-alive? l) 'alive 'not-alive))

(test-equal "uv-now is re-exported and answers with a positive timestamp"
  'positive (if (positive? (uv-now l)) 'positive 'not-positive))

(test-equal "uv-loop-live-handles is re-exported"
  '() (uv-loop-live-handles l))

(test-equal "uv-loop-deferred-errors is re-exported"
  '() (uv-loop-deferred-errors l))

(test-equal "uv-stop! is re-exported"
  'stopped
  (guard (e (#t (list 'raised e)))
    (uv-stop! l)
    'stopped))

(uv-loop-teardown! l)

(test-equal "uv-loop-teardown! is re-exported and closes the loop"
  'not-open (if (uv-loop-open? l) 'open 'not-open))

;; --- the re-exported condition hierarchy --------------------------------
;; Predicates and accessors both, on a condition the facade's own procedures
;; raise: the type, its predicate, and its field accessors all have to come
;; through the facade for this to expand and pass.
(test-equal "a closed loop raises the re-exported &uv-handle-closed, kind 'loop"
  'loop
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-run l 'nowait)
    'no-raise))

(test-equal "the re-exported uv-error? catches the whole family"
  'uv-error
  (guard (e ((uv-error? e) 'uv-error) (#t 'wrong-condition))
    (uv-now l)
    'no-raise))

(test-equal "uv-invalid-argument?, its who and its reason are re-exported"
  '(uv-run not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-run 'not-a-loop 'nowait)
    'no-raise))

;; Constructors and the remaining accessors, exercised directly -- these are
;; the ones a caller needs in order to build the conditions this binding
;; hands to asynchronous callbacks (design spec S9).
(test-equal "the re-exported condition constructors and accessors round-trip"
  '(ECONNRESET -104 "connection reset by peer" tcp "/nope" 1 2 uv-write! bad-span)
  (let ((errno-e (make-uv-errno-error 'ECONNRESET -104 "connection reset by peer"))
        (closed-e (make-uv-handle-closed 'tcp))
        (shim-e (make-uv-shim-unavailable "/nope"))
        (version-e (make-uv-version-incompatible 1 2))
        (arg-e (make-uv-invalid-argument 'uv-write! 'bad-span)))
    (list (uv-errno-error-errno errno-e)
          (uv-errno-error-code errno-e)
          (uv-errno-error-message errno-e)
          (uv-handle-closed-kind closed-e)
          (uv-shim-unavailable-path shim-e)
          (uv-version-incompatible-compiled version-e)
          (uv-version-incompatible-runtime version-e)
          (uv-invalid-argument-who arg-e)
          (uv-invalid-argument-reason arg-e))))

(test-equal "&uv-callback-error and &uv-constant-unavailable are re-exported"
  '(the-cause UV_NOPE)
  (let ((cb (make-uv-callback-error 'the-cause))
        (cu (make-uv-constant-unavailable 'UV_NOPE)))
    (list (if (uv-callback-error? cb) (uv-callback-error-cause cb) 'not-a-callback-error)
          (if (uv-constant-unavailable? cu)
              (uv-constant-unavailable-name cu)
              'not-a-constant-unavailable))))

(test-equal "&uv-libuv-unavailable is re-exported and subtypes &uv-shim-unavailable"
  '(libuv-unavailable also-shim-unavailable "/nope/libuv")
  (let ((e (make-uv-libuv-unavailable "/nope/libuv")))
    (list (if (uv-libuv-unavailable? e) 'libuv-unavailable 'not-libuv-unavailable)
          (if (uv-shim-unavailable? e) 'also-shim-unavailable 'not-shim-unavailable)
          (uv-shim-unavailable-path e))))

;; --- the re-exported handle and timer surfaces --------------------------
;; Driven through the facade alone, for the same reason as the loop rows
;; above: every name below has to come from src/libuv.sls or this file does
;; not expand.
(define hl (make-uv-loop))
(define ht (make-uv-timer hl))
(define ht-fires 0)
(define ht-closed 'on-close-never-ran)

(test-equal "uv-timer? and uv-handle? are re-exported and accept a timer"
  '(timer handle)
  (list (if (uv-timer? ht) 'timer 'not-a-timer)
        (if (uv-handle? ht) 'handle 'not-a-handle)))

(test-equal "uv-tcp? is re-exported and answers #f for a timer"
  'not-a-tcp (if (uv-tcp? ht) 'a-tcp 'not-a-tcp))

(test-equal "uv-handle-open?, uv-handle-closing? and uv-handle-state are re-exported"
  '(#t #f open)
  (list (uv-handle-open? ht) (uv-handle-closing? ht) (uv-handle-state ht)))

(test-equal "uv-handle-loop is re-exported"
  'same (if (eq? hl (uv-handle-loop ht)) 'same 'different))

(uv-timer-start! ht
                 (lambda (timer) (collect) (set! ht-fires (+ ht-fires 1)))
                 1 7)

(test-equal "uv-timer-repeat is re-exported and reads the interval back"
  7 (uv-timer-repeat ht))

;; Stepped and capped, never a single blind 'once -- and never 'nowait.
;; 'once blocks until the next due timer (or unrelated I/O) wakes the poll,
;; and libuv re-checks due timers again right after that poll returns, so
;; this does not depend on wall-clock scheduling the way a fixed sleep or a
;; 'nowait poll loop would. It is not, however, guaranteed to fire on the
;; FIRST 'once call: libuv only arms a BLOCKING poll timeout for a
;; UV_RUN_ONCE iteration that ran no pending callbacks of its own that same
;; iteration, so an iteration that raced past that check can return without
;; the timer having come due yet. A bare single 'once call observed exactly
;; that under load (CI run 5 -- flaked on the re-arm row below, five runs
;; in): the assertion read stale not because the timer was late, but because
;; that one iteration didn't wait for it. Stepping with a cap absorbs a miss
;; like that for the cost of one more (still due-time-blocking) iteration
;; instead of failing outright -- the same principle the tcp drain loop
;; below already uses, applied here to a plain timer fire.
(let step ((i 0))
  (when (and (< i 32) (< ht-fires 1))
    (uv-run hl 'once)
    (step (+ i 1))))

(test-equal "uv-timer-start! is re-exported and its callback fires"
  1 ht-fires)

(uv-timer-stop! ht)

(test-equal "uv-timer-stop! is re-exported and disarms the timer"
  1 (begin (uv-run hl 'nowait) ht-fires))

(uv-timer-again! ht)
(let step ((i 0))
  (when (and (< i 32) (< ht-fires 2))
    (uv-run hl 'once)
    (step (+ i 1))))

(test-equal "uv-timer-again! is re-exported and re-arms a stopped repeating timer"
  2 ht-fires)

(uv-timer-stop! ht)
(uv-timer-set-repeat! ht 0)

(test-equal "uv-timer-set-repeat! is re-exported"
  0 (uv-timer-repeat ht))

(uv-close! ht (lambda () (set! ht-closed 'on-close-ran)))
(uv-run hl 'default)

(test-equal "uv-close! is re-exported and runs its on-close callback"
  'on-close-ran ht-closed)

(test-equal "the closed timer's state is re-exported as 'closed"
  'closed (uv-handle-state ht))

(uv-loop-teardown! hl)

;; --- the re-exported tcp surface ----------------------------------------
;; Same rule as the loop and timer rows above: every name here has to come
;; from src/libuv.sls or this file does not expand. Deliberately NOT using
;; (uv-testing)'s loopback helpers -- that library imports (libuv tcp)
;; directly, and a helper standing between this suite and the facade is
;; exactly what would let a dropped re-export go unnoticed.
;;
;; #f is never an expected value here (AGENTS.md): each callback's `err` is
;; mapped to a symbol, and each observer is seeded with a symbol no success
;; path can produce.
(define (facade-err->symbol err)
  (cond ((not err) 'no-error)
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else (list 'unexpected err))))

;; The `(bv start end)` span an on-data callback is handed, copied out. Spelt
;; here rather than taken from (uv-testing) for the same reason the loopback
;; helpers are not used: nothing in this suite may stand between it and the
;; facade.
(define (facade-span->bytevector bv start end)
  (let* ((n (- end start))
         (out (make-bytevector n)))
    (bytevector-copy! bv start out 0 n)
    out))

(define fl (make-uv-loop))
(define fserver (make-uv-tcp fl))

(test-equal "make-uv-tcp is re-exported and its handle answers uv-tcp?"
  '(a-tcp open)
  (list (if (uv-tcp? fserver) 'a-tcp 'not-a-tcp) (uv-handle-state fserver)))

(uv-tcp-bind! fserver "127.0.0.1" 0)

(define fport (uv-tcp-getsockname-port fserver))

(test-equal "uv-tcp-bind! and uv-tcp-getsockname-port are re-exported"
  'ephemeral (if (and (> fport 1024) (< fport 65536)) 'ephemeral fport))

(define f-accepted 'never-accepted)
(define f-connect-err 'connect-cb-never-fired)
(define f-write-err 'write-cb-never-fired)
(define f-shutdown-err 'shutdown-cb-never-fired)
(define f-read 'on-data-never-fired)
(define f-eof 'on-eof-never-fired)
(define f-read-error 'on-error-never-fired)

(uv-listen! fserver 128
            (lambda (err)
              (collect)
              (when (not err)
                (set! f-accepted (uv-accept! fserver))
                (uv-read-start! f-accepted
                                (lambda (bv start end)
                                  (collect)
                                  (set! f-read (utf8->string
                                                (facade-span->bytevector
                                                 bv start end))))
                                (lambda () (collect) (set! f-eof 'eof))
                                (lambda (rerr)
                                  (collect)
                                  (set! f-read-error
                                        (facade-err->symbol rerr)))))))

(define fclient (make-uv-tcp fl))

(uv-tcp-connect! fclient "127.0.0.1" fport
                 (lambda (err)
                   (collect)
                   (set! f-connect-err err)
                   (uv-tcp-nodelay! fclient #t)
                   (uv-write! fclient (string->utf8 "facade")
                              (lambda (werr)
                                (collect)
                                (set! f-write-err werr)
                                (uv-shutdown! fclient
                                              (lambda (serr)
                                                (collect)
                                                (set! f-shutdown-err serr)))))))

;; Bounded by iteration count, never by a clock (design spec S11). The whole
;; chain above is driven by callbacks the loop itself delivers.
;;
;; BOTH ends are waited for, not just the client's chain: the listening
;; socket's readability and the client's connect completion are separate poll
;; events, and libuv does not promise them in the same iteration. Draining
;; only until the shutdown completed left the accept unobserved on some runs
;; and passed on others -- measured, not theorised.
(let drain ((i 0))
  (when (and (< i 32)
             (or (eq? f-shutdown-err 'shutdown-cb-never-fired)
                 (eq? f-accepted 'never-accepted)
                 (eq? f-read 'on-data-never-fired)))
    (uv-run fl 'once)
    (drain (+ i 1))))

(test-equal "uv-tcp-connect! is re-exported and its callback reports success"
  'no-error (facade-err->symbol f-connect-err))

(test-equal "uv-listen! and uv-accept! are re-exported and produced a peer"
  'a-tcp (if (uv-tcp? f-accepted) 'a-tcp (list 'not-a-tcp f-accepted)))

(test-equal "uv-write! is re-exported and its completion reports success"
  'no-error (facade-err->symbol f-write-err))

(test-equal "uv-shutdown! is re-exported and its completion reports success"
  'no-error (facade-err->symbol f-shutdown-err))

(test-equal "uv-read-start! is re-exported and delivered the payload to the peer"
  "facade" f-read)

(test-equal "reading through the facade fired no error callback"
  'on-error-never-fired f-read-error)

(test-equal "uv-read-stop! is re-exported and stops a running read"
  'stopped
  (guard (e (#t (list 'raised e)))
    (uv-read-stop! f-accepted)
    'stopped))

(uv-loop-teardown! fl)

(test-equal "the facade's tcp loop tore down and closed every handle"
  '(closed closed) (list (uv-handle-state fserver) (uv-handle-state fclient)))

;; --- call-with-uv-loop, through the facade ------------------------------
(test-equal "call-with-uv-loop is re-exported and returns the body's value"
  'body-value
  (call-with-uv-loop (lambda (loop) (uv-run loop 'nowait) 'body-value)))

(test-end "facade")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
