#!r6rs
;;; SRFI-64 suite for the (libuv) facade, src/libuv.sls: its re-exports and
;;; its own uv-version and uv-version-compatible?.
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
        ;; (collect) only, so this suite's timer callbacks call (collect) on
        ;; every fire, as every other suite's do. It is not a name the facade
        ;; could be expected to supply, so it cannot stand in for a dropped
        ;; re-export. Nor is describe, from the pure (uv-describe), which
        ;; reaches nothing of the binding's.
        (only (chezscheme) collect)
        (uv-describe))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. A row that catches a
;; raise answers the condition as its actual value, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

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

(test-equal "uv-update-time! is re-exported and callable on an open loop"
  'returned
  (guard (e (#t (list 'raised e)))
    (uv-update-time! l)
    'returned))

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
;; hands to asynchronous callbacks.
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

;; &uv-stack-exhausted is raised from a run deep in a thread's stack, which
;; this suite does not reach (tests/test-stack-headroom.sps does), so its
;; type and accessors are exercised directly.
(test-equal "&uv-stack-exhausted is re-exported, with its who, headroom and floor"
  '(stack-exhausted uv-run 4096 131072)
  (let ((e (make-uv-stack-exhausted 'uv-run 4096 131072)))
    (list (if (uv-stack-exhausted? e) 'stack-exhausted 'not-stack-exhausted)
          (uv-stack-exhausted-who e)
          (uv-stack-exhausted-headroom e)
          (uv-stack-exhausted-floor e))))

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
;; the timer having come due yet. A bare single 'once call did exactly that
;; under load, failing the re-arm row below once in five CI runs: the
;; assertion read stale not because the timer was late, but because that one
;; iteration didn't wait for it. Stepping with a cap absorbs a miss
;; like that for the cost of one more (still due-time-blocking) iteration
;; instead of failing outright -- the same principle the tcp drain loop
;; below already uses, applied here to a plain timer fire.
(let step ((i 0))
  (when (and (< i 32) (< ht-fires 1))
    (uv-run hl 'once)
    (step (+ i 1))))

;; AT LEAST one, not EXACTLY one. ht is a REPEATING timer (1ms initial, 7ms
;; repeat), so the exact count is a function of how fast the host got back
;; into the loop -- a wall-clock dependency in disguise, which no row here
;; may have. Measured under Valgrind on aarch64 (`make test-memory-docker`):
;; the initial AND the first repeat are both already due by the time the loop
;; processes timers, so a single 'once fires the callback TWICE and an
;; `(test-equal 1 ht-fires)` fails on a completely clean tree. CI's faster
;; x86_64 host happens to stay under 7ms and mask it; that is luck, not a
;; property. What this row is actually for is "the re-exported start! reaches
;; the callback at all", and `positive?` says exactly that.
(test-assert "uv-timer-start! is re-exported and its callback fires"
  (positive? ht-fires))

;; Captured BEFORE the stop, compared after: a delta, not a literal. This is
;; the stronger form anyway -- it asserts the count did not MOVE across the
;; stop, which is what "disarms" means, rather than that it equals a number
;; the row above already had to stop pinning.
(define ht-fires-at-stop ht-fires)
(uv-timer-stop! ht)

(test-equal "uv-timer-stop! is re-exported and disarms the timer"
  ht-fires-at-stop (begin (uv-run hl 'nowait) ht-fires))

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
;; #f is never an expected value here, since SRFI-64 also answers #f for a
;; raise: each callback's `err` is mapped to a symbol, and each observer is
;; seeded with a symbol no success path can produce.
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

;; A bind that raises fails a row by name, where at top level it would end
;; the suite (tests/test-seed-gates.sps, rule 4). An unbound handle has no
;; socket to name, so the port is read only after a bind.
(define f-bind
  (guard (e (#t (list 'raised (describe e))))
    (uv-tcp-bind! fserver "127.0.0.1" 0)
    'bound))

(define fport
  (if (eq? f-bind 'bound) (uv-tcp-getsockname-port fserver) f-bind))

(test-equal "uv-tcp-bind! and uv-tcp-getsockname-port are re-exported"
  'ephemeral
  (if (and (integer? fport) (> fport 1024) (< fport 65536)) 'ephemeral fport))

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

;; The chain goes on only from a successful connect. A connect still pending
;; when the drain below gives up completes at the suite's teardown, as
;; 'ECANCELED, and going on then, on the closing client, raises
;; &uv-handle-closed out of uv-loop-teardown! and aborts the suite (measured
;; by forcing the drain to give up).
(test-equal "uv-tcp-connect! is re-exported and starts the client's connect"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-tcp-connect! fclient "127.0.0.1" fport
                     (lambda (err)
                       (collect)
                       (set! f-connect-err err)
                       (when (not err)
                         (uv-tcp-nodelay! fclient #t)
                         (uv-write! fclient (string->utf8 "facade")
                                    (lambda (werr)
                                      (collect)
                                      (set! f-write-err werr))))))
    'started))

;; Bounded by iteration count, never by a clock. The whole chain above is
;; driven by callbacks the loop itself delivers.
;;
;; BOTH ends are waited for, not just the client's chain: the listening
;; socket's readability and the client's connect completion are separate poll
;; events, and libuv does not promise them in the same iteration. Draining
;; only until the client's chain completes leaves the accept unobserved on
;; some runs and passes on others -- measured, not theorised.
;;
;; The client shuts down only after the peer's read is stopped, so the read
;; uv-read-stop! stops is still running: libuv ends a read at EOF
;; (vendor/libuv/src/unix/stream.c's uv__stream_eof), and stopping one that
;; has ended returns at once. The read then restarts to take the EOF.
;;
;; THE TICKER IS WHAT MAKES THE BOUND REAL. Without it, `uv-run 'once`
;; BLOCKS waiting for an event, so a mutation that silences the I/O chain --
;; a dropped connect delivery, a miswired dispatcher -- leaves this suite
;; HANGING instead of failing: the iteration bound is never reached because
;; iterations stop arriving. A repeating facade-only timer guarantees every
;; 'once returns, so a dead chain burns through its iterations and the rows
;; below fail BY NAME. Built from facade exports alone -- (uv-testing)'s
;; run-until/ticking is exactly this, but that library imports (libuv tcp)
;; directly and may not stand between this suite and the facade.
;;
;; THE SAME TICKER MAKES THE CAP A TIME BUDGET. Each tick spends an
;; iteration, so the cap counts milliseconds, not events. These TCP drains,
;; the dns and resolve->connect drains and the spawn drain wait on the kernel
;; or the threadpool, and load can slow those while the ticker keeps its
;; pace: under a loopback flood, handshakes outlast a cap of 32 in up to 18
;; runs of 20. delivery-cap is four seconds or more. Under the heaviest flood
;; measured, a working chain uses under a quarter of it, and a dead chain
;; spends all of it, then fails by name. The timer drains above and the
;; close drain at the end keep 32: 'once waits there for the suite's own
;; timer or close, so those caps count events.
(define delivery-cap 4000)

(define f-ticker (make-uv-timer fl))
(uv-timer-start! f-ticker (lambda (t) (collect)) 1 1)

;; facade-drain : (-> boolean) -> unspecified
;; Steps the loop until DONE? answers true or the cap is spent.
(define (facade-drain done?)
  (let drain ((i 0))
    (when (and (< i delivery-cap) (not (done?)))
      (uv-run fl 'once)
      (drain (+ i 1)))))

(facade-drain (lambda ()
                (and (not (eq? f-write-err 'write-cb-never-fired))
                     (not (eq? f-accepted 'never-accepted))
                     (not (eq? f-read 'on-data-never-fired)))))

(test-equal "uv-tcp-connect! is re-exported and its callback reports success"
  'no-error (facade-err->symbol f-connect-err))

(test-equal "uv-listen! and uv-accept! are re-exported and produced a peer"
  'a-tcp (if (uv-tcp? f-accepted) 'a-tcp (list 'not-a-tcp f-accepted)))

(test-equal "uv-write! is re-exported and its completion reports success"
  'no-error (facade-err->symbol f-write-err))

(test-equal "uv-read-start! is re-exported and delivered the payload to the peer"
  "facade" f-read)

(test-equal "reading through the facade fired no error callback"
  'on-error-never-fired f-read-error)

;; A read that has ended would make this row pass without stopping anything,
;; so it says so instead.
(test-equal "uv-read-stop! is re-exported and stops a running read"
  'stopped
  (if (eq? f-eof 'on-eof-never-fired)
      (guard (e (#t (list 'raised e)))
        (uv-read-stop! f-accepted)
        'stopped)
      (list 'read-had-ended f-eof)))

(test-equal "uv-shutdown! is re-exported and starts the client's shutdown"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-shutdown! fclient (lambda (serr) (collect) (set! f-shutdown-err serr)))
    'started))

(facade-drain (lambda () (not (eq? f-shutdown-err 'shutdown-cb-never-fired))))

(test-equal "uv-shutdown! is re-exported and its completion reports success"
  'no-error (facade-err->symbol f-shutdown-err))

(test-equal "the stopped read delivered no EOF while the client shut down"
  'on-eof-never-fired f-eof)

(test-equal "uv-read-start! restarts the stopped read"
  'restarted
  (guard (e (#t (list 'raised (describe e))))
    (uv-read-start! f-accepted
                    (lambda (bv start end) (collect))
                    (lambda () (collect) (set! f-eof 'eof))
                    (lambda (rerr) (collect) (set! f-read-error (facade-err->symbol rerr))))
    'restarted))

(facade-drain (lambda () (not (eq? f-eof 'on-eof-never-fired))))

(uv-timer-stop! f-ticker)

(test-equal "the client's shutdown ended the restarted read through on-eof"
  'eof f-eof)

(test-equal "the restarted read fired no error callback"
  'on-error-never-fired f-read-error)

;; --- buffer-size surfaces, reached through the facade only ----------------
;; EACH NAME MUST BE EXERCISED, not merely called: a bare invocation would
;; only reprove that the re-export expands (the header's expand-time check
;; covers that), nothing about behaviour. Every row below both calls the
;; facade re-export AND asserts on what it returns -- tracking direction for
;; the two buffer setters, the idle-stream zero for the write-queue gauge,
;; the connected peer's address and port. Real `src/` mutations flip these
;; rows to FAIL, which is what makes them load-bearing rather than
;; name-mention rows: a getter that hands libuv a nonzero int cell sets the
;; buffer instead of reading it and answers that constant (both buffer
;; rows); a write-queue gauge stubbed to a constant 4096 (the gauge row); a
;; peer-address that calls uv_tcp_getsockname instead of uv_tcp_getpeername
;; answers the client's own port (the peer row).
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

(test-equal "the facade's write-queue-size answers zero on an idle stream"
  'zero (if (zero? (uv-stream-write-queue-size fclient)) 'zero 'nonzero))

;; The port is read in the tested expression: an expected value is
;; evaluated outside the row's catch, and on a client that never connected
;; the read raises, which outside the catch would abort the suite.
(test-equal "the facade's sockname-address answers this end's own name"
  'its-own-name
  (let-values (((a p) (uv-tcp-sockname-address fclient)))
    (let ((port (uv-tcp-getsockname-port fclient)))
      (if (equal? (list a p) (list "127.0.0.1" port))
          'its-own-name
          (list a p 'port port)))))

(test-equal "the facade's peer-address answers the connected peer"
  (list "127.0.0.1" fport)
  (let-values (((a p) (uv-tcp-peer-address fclient))) (list a p)))

;; uv-tcp-keepalive! reached through the facade: enabling with an idle delay on
;; the still-connected client exercises the re-export end to end (the fd path,
;; where a bad delay would surface as an errno) rather than a bare mention.
(test-equal "the facade's uv-tcp-keepalive! enables on the connected client"
  'set
  (guard (e (#t (list 'raised (facade-err->symbol e))))
    (uv-tcp-keepalive! fclient #t 60)
    'set))

;; uv-write*! reached through the facade IS the real validating stream verb:
;; on the still-open client it refuses an empty segment list with its own
;; named reason (libuv needs nbufs >= 1) before touching libuv, so this proves
;; the re-export end to end without perturbing the completed exchange above.
(test-equal "the facade's uv-write*! is the real verb, refusing an empty segment list"
  '(uv-write*! empty-segment-list)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-write*! fclient '() (lambda (err) #f))
    'no-raise))

(uv-loop-teardown! fl)

(test-equal "the facade's tcp loop tore down and closed every handle"
  '(closed closed) (list (uv-handle-state fserver) (uv-handle-state fclient)))

;; --- the re-exported dns surface ----------------------------------------
;; Same rule as every block above: each name here has to come from
;; src/libuv.sls or this file does not expand. One driven numeric forward
;; lookup exercises the re-export end to end -- hermetic: numeric-only,
;; so no resolver configuration, no network, no /etc/hosts
;; policy can decide the answer -- and the remaining names are exercised
;; directly. addrinfo-chain->list lives in (libuv private addrinfo-chain),
;; which no public library exports, so it must not appear here.
(define dl (make-uv-loop))
(define d-err 'callback-never-fired)
(define d-results 'callback-never-fired)

;; The request the start answers, once it has started.
(define d-req 'never-started)

(test-equal "uv-getaddrinfo! is re-exported and starts the lookup"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (set! d-req
          (uv-getaddrinfo! dl "127.0.0.1" "80"
                           '((family . inet) (socktype . stream) (protocol . tcp)
                             (flags . (numeric-host numeric-serv)))
                           (lambda (err results)
                             (collect)
                             (set! d-err (facade-err->symbol err))
                             (set! d-results results))))
    'started))

(test-equal "uv-dns-request? is re-exported and accepts the in-flight request"
  'a-dns-request
  (if (uv-dns-request? d-req) 'a-dns-request 'not-a-dns-request))

;; The ticker keeps the iteration bound real, exactly as the tcp drain
;; above: an active dns request keeps the loop alive, so a miswired
;; delivery would otherwise BLOCK a bare 'once instead of failing by name.
(define d-ticker (make-uv-timer dl))
(uv-timer-start! d-ticker (lambda (t) (collect)) 1 1)

(let drain ((i 0))
  (when (and (< i delivery-cap) (eq? d-err 'callback-never-fired))
    (uv-run dl 'once)
    (drain (+ i 1))))

(test-equal "uv-getaddrinfo! is re-exported and the numeric lookup succeeded"
  'no-error d-err)

(test-equal "the driven lookup answered exactly one 'inet record, the literal rendered back"
  '(1 an-addrinfo inet "127.0.0.1" 80 stream tcp canonname-absent)
  (list (length d-results)
        (if (uv-addrinfo? (car d-results)) 'an-addrinfo 'not-a-record)
        (uv-addrinfo-family (car d-results))
        (uv-addrinfo-address (car d-results))
        (uv-addrinfo-port (car d-results))
        (uv-addrinfo-socktype (car d-results))
        (uv-addrinfo-protocol (car d-results))
        (if (uv-addrinfo-canonname (car d-results))
            'canonname-present
            'canonname-absent)))

;; uv-getnameinfo! and uv-cancel!, driven together. The cancel's answer is
;; a RACE (this suite does not pin the threadpool), so the row asserts the
;; branch-paired consequence, never the boolean alone: cancel won =>
;; 'EAI_CANCELED with host and service absent; cancel lost => the real
;; numeric reverse.
(define n-err 'callback-never-fired)
(define n-host 'callback-never-fired)
(define n-serv 'callback-never-fired)

;; The request the start answers, once it has started.
(define n-req 'never-started)

(test-equal "uv-getnameinfo! is re-exported and starts the reverse lookup"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (set! n-req
          (uv-getnameinfo! dl "127.0.0.1" 8080 '(numeric-host numeric-serv)
                           (lambda (err host service)
                             (collect)
                             (set! n-err (facade-err->symbol err))
                             (set! n-host (if host (list 'host host) 'host-absent))
                             (set! n-serv (if service
                                              (list 'service service)
                                              'service-absent)))))
    'started))

;; A cancel that raises, of a request that never started too, is the answer
;; the row below reports.
(define n-cancel-answer
  (guard (e (#t (list 'raised (describe e))))
    (uv-cancel! n-req)))

(let drain ((i 0))
  (when (and (< i delivery-cap) (eq? n-err 'callback-never-fired))
    (uv-run dl 'once)
    (drain (+ i 1))))

(uv-timer-stop! d-ticker)

(test-equal "uv-cancel! is re-exported and answers a boolean"
  'boolean
  (if (boolean? n-cancel-answer) 'boolean (list 'not-a-boolean n-cancel-answer)))

(test-equal "uv-getnameinfo! is re-exported and delivered a branch-paired outcome"
  'paired-outcome
  (cond ((and (eq? n-err 'no-error)
              (equal? n-host '(host "127.0.0.1"))
              (equal? n-serv '(service "8080")))
         'paired-outcome)
        ((and (eq? n-err 'EAI_CANCELED)
              (eq? n-host 'host-absent)
              (eq? n-serv 'service-absent))
         'paired-outcome)
        (else (list 'unpaired n-err n-host n-serv))))

;; The record constructor and every accessor, round-tripped directly --
;; make-uv-addrinfo is public for the same reason the condition
;; constructors are: pure data, and a caller's test double is legitimate.
(test-equal "the re-exported uv-addrinfo constructor and accessors round-trip"
  '(inet6 stream tcp "::1" 443 canonname-absent)
  (let ((ai (make-uv-addrinfo 'inet6 'stream 'tcp "::1" 443 #f)))
    (list (uv-addrinfo-family ai)
          (uv-addrinfo-socktype ai)
          (uv-addrinfo-protocol ai)
          (uv-addrinfo-address ai)
          (uv-addrinfo-port ai)
          (if (uv-addrinfo-canonname ai) 'canonname-present 'canonname-absent))))

(uv-loop-teardown! dl)

(test-equal "the facade's dns loop tore down cleanly"
  'not-open (if (uv-loop-open? dl) 'open 'not-open))

;; --- resolve -> connect: a resolved record feeds uv-tcp-connect! --------
;; uv-addrinfo-address and uv-addrinfo-port compose directly with
;; uv-tcp-connect!'s parameters: resolution-to-connection needs no adapter.
;; Asserted end to end, on the record's OWN accessor answers, never on the
;; literals they came from: a loopback listener binds port 0, the kernel's
;; real port is resolved back hermetically (numeric-host/numeric-serv -- no
;; resolver configuration in the oracle), and the FIRST 'inet record's
;; address and port feed uv-tcp-connect! verbatim. The accept firing is
;; what proves the composed connect reached THIS listener: a record port
;; one off would ECONNREFUSED on loopback and the accept would never come
;; (watched to fail exactly so). Replacing the accessor calls with the
;; literals they came from is invisible to this row by construction, since
;; the answer for a numeric literal IS the literal: that swap is uncovered
;; here.
(define cl (make-uv-loop))
(define cserver (make-uv-tcp cl))

(define c-bind
  (guard (e (#t (list 'raised (describe e))))
    (uv-tcp-bind! cserver "127.0.0.1" 0)
    'bound))

(test-equal "resolve->connect: the listener binds 127.0.0.1, port 0" 'bound c-bind)

(define cport
  (if (eq? c-bind 'bound) (uv-tcp-getsockname-port cserver) c-bind))
(define c-accepted 'never-accepted)

(uv-listen! cserver 128
            (lambda (err)
              (collect)
              (when (not err)
                (set! c-accepted (uv-accept! cserver)))))

(define c-resolve-err 'resolve-cb-never-fired)
(define c-records 'resolve-cb-never-fired)

(test-equal "resolve->connect: the lookup of the listener's port starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! cl "127.0.0.1" (number->string cport)
                     '((family . inet) (socktype . stream) (protocol . tcp)
                       (flags . (numeric-host numeric-serv)))
                     (lambda (err results)
                       (collect)
                       (set! c-resolve-err (facade-err->symbol err))
                       (set! c-records results)))
    'started))

;; The ticker keeps both drains' iteration bounds real, exactly as the tcp
;; and dns blocks above.
(define c-ticker (make-uv-timer cl))
(uv-timer-start! c-ticker (lambda (t) (collect)) 1 1)

(let drain ((i 0))
  (when (and (< i delivery-cap) (eq? c-resolve-err 'resolve-cb-never-fired))
    (uv-run cl 'once)
    (drain (+ i 1))))

;; FIRST 'inet record by search rather than car, so the row's contract
;; survives a future multi-record answer unchanged. `find` is (rnrs
;; lists), not a project name, so it cannot mask a dropped re-export.
(define c-rec
  (or (and (pair? c-records)
           (find (lambda (r) (and (uv-addrinfo? r)
                                  (eq? (uv-addrinfo-family r) 'inet)))
                 c-records))
      'no-inet-record))

(define cclient (make-uv-tcp cl))
(define c-connect-err 'connect-cb-never-fired)

(test-equal "resolve->connect: the connect to the record's address starts"
  'started
  (if (uv-addrinfo? c-rec)
      (guard (e (#t (list 'raised (describe e))))
        (uv-tcp-connect! cclient
                         (uv-addrinfo-address c-rec)
                         (uv-addrinfo-port c-rec)
                         (lambda (err)
                           (collect)
                           (set! c-connect-err (facade-err->symbol err))))
        'started)
      (list 'no-record c-rec)))

;; Both ends waited for, as the tcp block above records: the accept and
;; the connect completion are separate poll events.
(let drain ((i 0))
  (when (and (< i delivery-cap)
             (or (eq? c-connect-err 'connect-cb-never-fired)
                 (eq? c-accepted 'never-accepted)))
    (uv-run cl 'once)
    (drain (+ i 1))))

(uv-timer-stop! c-ticker)
(uv-loop-teardown! cl)

(test-equal "resolve->connect: the record's own address and port drive uv-tcp-connect! to the listener"
  '(no-error an-inet-record no-error a-tcp closed closed)
  (list c-resolve-err
        (if (uv-addrinfo? c-rec) 'an-inet-record c-rec)
        c-connect-err
        (if (uv-tcp? c-accepted) 'a-tcp (list 'not-a-tcp c-accepted))
        (uv-handle-state cserver)
        (uv-handle-state cclient)))

;; --- call-with-uv-loop, through the facade ------------------------------
(test-equal "call-with-uv-loop is re-exported and returns the body's value"
  'body-value
  (call-with-uv-loop (lambda (loop) (uv-run loop 'nowait) 'body-value)))

;; --- the re-exported stream, pipe, and process surfaces -------------------
;; Same rule as every block above: each name here has to come from
;; src/libuv.sls or this file does not expand. Re-exported stream verbs are
;; tested above with TCP; here we test pipe and process.

(test-assert "make-uv-pipe is exported"
  (procedure? make-uv-pipe))

(test-assert "uv-pipe? is exported"
  (procedure? uv-pipe?))

(test-assert "uv-process? is exported"
  (procedure? uv-process?))

(test-assert "uv-spawn! is exported"
  (procedure? uv-spawn!))

(test-assert "uv-process-kill! is exported"
  (procedure? uv-process-kill!))

(test-assert "uv-kill! is exported"
  (procedure? uv-kill!))

(test-assert "uv-process-pid is exported"
  (procedure? uv-process-pid))

;; uv-os-getpid is exported from (libuv process), so it is checked with the
;; process surface.
(test-equal "uv-os-getpid is re-exported and answers a positive exact integer"
  'positive
  (if (and (integer? (uv-os-getpid)) (exact? (uv-os-getpid))
           (positive? (uv-os-getpid)))
      'positive
      'wrong))

;; The signal surface: one exercised row per export.
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

(uv-signal-stop! sig-h)   ; rc 0 on a never-started watcher
(uv-close! sig-h)
(uv-loop-teardown! sig-loop)

;; Smoke test: spawn sh -c 'exit 5' through facade names only, assert exit (5 #f)
(define pl (make-uv-loop))
(define p-exit 'never-exited)
(define p-ticker (make-uv-timer pl))
(uv-timer-start! p-ticker (lambda (t) (collect)) 1 1)

(define p-proc
  (uv-spawn! pl "/bin/sh" '("sh" "-c" "exit 5")
             (lambda (status sig)
               (collect)
               (set! p-exit (list status sig)))))

;; A real fork/exec/exit waits on the kernel, so this drain's cap is a time
;; budget too, like the tcp and dns drains above: delivery-cap.
(let drain ((i 0))
  (when (and (< i delivery-cap) (eq? p-exit 'never-exited))
    (uv-run pl 'once)
    (drain (+ i 1))))

(uv-timer-stop! p-ticker)

(test-equal "uv-spawn! through the facade spawned sh -c 'exit 5' and exit callback reports (5 #f)"
  '(5 #f) p-exit)

(test-assert "uv-process? and uv-process-pid work through the facade"
  (and (uv-process? p-proc) (number? (uv-process-pid p-proc))))

(uv-close! p-proc)
(let drain ((i 0))
  (when (and (< i 32) (not (eq? (uv-handle-state p-proc) 'closed)))
    (uv-run pl 'once)
    (drain (+ i 1))))

(uv-loop-teardown! pl)

(test-end "facade")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
