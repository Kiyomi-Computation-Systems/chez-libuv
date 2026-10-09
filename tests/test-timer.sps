#!r6rs
;;; SRFI-64 suite for (libuv timer) and (libuv handle) -- the first C-to-Scheme
;;; callback path in this binding. Design spec S5 (the handle lifecycle state
;;; machine and the close protocol), S8 (callback boundary discipline and the
;;; store-and-reraise error policy), S10 (the debug counters), S11 ("timers
;;; never depend on wall-clock timing ... every timer callback calls
;;; (collect)"), ADR-0007 (explicit close) and ADR-0008 (eight static locked
;;; trampolines dispatching through the registry).
;;;
;;; EVERY on-timeout callback in this file calls (collect). That is design
;;; spec S11's GC-pressure axis, productionized from spike FINDINGS Q1 (which
;;; forced a full collection on each of 10,000 re-entries with libuv's C
;;; frames live below the Scheme callback): the re-entrant callback path is
;;; exercised under a moving heap on every single run of this suite rather
;;; than in one special-case test.
;;;
;;; NOTHING HERE ASSERTS ELAPSED TIME. Determinism comes from invocation
;;; counts, from 'once-stepping (which blocks until the next timer is due),
;;; and from an iteration cap (uv-testing's run-until). A one-hour timer
;;; checked against 'nowait is how "did not fire early" is stated without a
;;; clock.
;;;
;;; NOT pure: (libuv timer) reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv private handles)
        (libuv private conditions)
        ;; `only`, for the same reason as tests/test-loop.sps: this library
        ;; also exports uv-version, which is a different binding in (libuv).
        ;; uv-is-closing is libuv's own answer to "is this handle closing?",
        ;; used below to cross-check the Scheme-side state field against the
        ;; C-side flag rather than against itself.
        ;; alloc-zeroed / free! are here for the ONE row group that has to
        ;; register a request block of its own to make a dispatcher raise
        ;; before its guard -- see "the dispatch seam" below.
        (only (libuv private native)
              live-counts dispatcher-ref uv-is-closing alloc-zeroed free!)
        (uv-testing)
        ;; The close-against-close sweep below needs a second kind of handle
        ;; (an async closes by its own path, inside its send fence) and an
        ;; engine to interleave the two closes.
        (only (libuv async) make-uv-async)
        ;; A signal handle is the other kind the timer verbs must refuse.
        (only (libuv signal) make-uv-signal)
        (uv-evidence)
        (only (chezscheme) collect make-engine))

;; SRFI-64's default runner sets no process exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. Rows that return
;; their evidence when they fail, like the close sweeps below, get it printed
;; too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; Captured before this suite allocates anything, so every "back to baseline"
;; assertion below is measured against a real observation.
(define registry-count-at-start (registry-count))

;; A condition type of this suite's own, deliberately OUTSIDE the &uv-error
;; hierarchy. The store-and-reraise policy's load-bearing claim (design spec
;; S8) is that the re-raised compound still satisfies a guard written against
;; the ORIGINAL condition's type -- and that claim is only discriminating if
;; the original type is one this binding could not have produced by itself.
(define-condition-type &timer-probe &error
  make-timer-probe timer-probe?
  (mark timer-probe-mark))

(test-begin "timer")

;; --- seeds ---------------------------------------------------------------
;; Every counter assertion in this suite needs the DEV shim (the Makefile's
;; CFLAGS_DEV, -DCHEZ_LIBUV_DEBUG_COUNTERS); against a production shim the
;; live queries answer a constant 0 and the "moved" rows would fail pointing
;; at cross-wiring that is not there. Name that precondition first.
(test-equal "seed: no timer is live before this suite creates one"
  0 (live-count 'timer))

(test-equal "seed: the handle registry is empty before this suite registers anything"
  0 registry-count-at-start)

(define l (make-uv-loop))

;; The registry's resting size for the rest of the file: the loop registers
;; itself, so "back to baseline" for handles means back to THIS.
(define registry-with-loop (registry-count))

;; --- construction and the record surface ---------------------------------
(define t0 (make-uv-timer l))

(test-equal "make-uv-timer returns a uv-timer"
  'a-timer (if (uv-timer? t0) 'a-timer 'not-a-timer))

(test-equal "a timer is a uv-handle"
  'a-handle (if (uv-handle? t0) 'a-handle 'not-a-handle))

(test-equal "a timer is not a uv-tcp"
  'not-a-tcp (if (uv-tcp? t0) 'a-tcp 'not-a-tcp))

;; uv-tcp? would otherwise be indistinguishable from (lambda (x) #f) until
;; Stage 4: a handle record carrying kind 'tcp is the stand-in that makes the
;; predicate's answer depend on the kind field rather than on a constant.
(test-equal "uv-tcp? answers #t for a handle record of kind 'tcp"
  'a-tcp
  (if (uv-tcp? (%make-uv-handle-record 1 'tcp l)) 'a-tcp 'not-a-tcp))

(test-equal "uv-timer? answers #f for a handle record of another kind"
  'not-a-timer
  (if (uv-timer? (%make-uv-handle-record 1 'tcp l)) 'a-timer 'not-a-timer))

(test-equal "uv-handle? answers #f for a loop"
  'not-a-handle (if (uv-handle? l) 'a-handle 'not-a-handle))

(test-equal "a fresh timer is open"
  'open (if (uv-handle-open? t0) 'open 'not-open))

(test-equal "a fresh timer is not closing"
  'not-closing (if (uv-handle-closing? t0) 'closing 'not-closing))

(test-equal "a fresh timer's state field reads 'open"
  'open (uv-handle-state t0))

(test-equal "a timer knows the loop it belongs to"
  'same (if (eq? l (uv-handle-loop t0)) 'same 'different))

;; positive? is the discriminating part: 0 is what the freeing site leaves
;; behind (design spec S10).
(test-equal "make-uv-timer stores a non-null handle pointer"
  'positive
  (if (and (integer? (handle-ptr t0)) (exact? (handle-ptr t0))
           (positive? (handle-ptr t0)))
      'positive
      'null-or-not-a-pointer))

(test-equal "seed: creating a timer moves the live timer counter"
  1 (live-count 'timer))

(test-equal "make-uv-timer registers the timer in the handle registry"
  1 (- (registry-count) registry-with-loop))

(test-equal "the registry resolves the timer pointer back to the timer record"
  'same (if (eq? t0 (registry-ref (handle-ptr t0))) 'same 'different))

(test-equal "a registered timer appears in its loop's live-handle snapshot"
  'listed (if (memq t0 (uv-loop-live-handles l)) 'listed 'missing))

(test-equal "make-uv-timer rejects a non-loop argument, naming who and why"
  '(make-uv-timer not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (make-uv-timer 'not-a-loop)
    'no-raise))

;; --- a non-handle is a CALLER bug, distinct from a closed handle ---------
;; Two different conditions on purpose (design spec S9): passing a symbol is
;; &uv-invalid-argument naming who, while touching a closed handle is
;; &uv-handle-closed, which is the one callers guard for.
(define (non-handle-refusal thunk)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(for-each
 (lambda (entry)
   (test-equal (string-append (car entry)
                              " rejects a non-handle, naming who and why")
     (list (string->symbol (car entry)) 'not-a-uv-handle)
     (non-handle-refusal (cdr entry))))
 (list (cons "uv-handle-state"     (lambda () (uv-handle-state 'nope)))
       (cons "uv-handle-loop"      (lambda () (uv-handle-loop 'nope)))
       (cons "uv-timer-start!"     (lambda () (uv-timer-start! 'nope (lambda (h) h) 1 0)))
       (cons "uv-timer-stop!"      (lambda () (uv-timer-stop! 'nope)))
       (cons "uv-timer-again!"     (lambda () (uv-timer-again! 'nope)))
       (cons "uv-timer-repeat"     (lambda () (uv-timer-repeat 'nope)))
       (cons "uv-timer-set-repeat!" (lambda () (uv-timer-set-repeat! 'nope 1)))
       (cons "uv-close!"           (lambda () (uv-close! 'nope)))))

;; --- another kind of handle is a caller bug too ---------------------------
;; libuv's timer calls take any handle's address as a uv_timer_t's and read
;; and write its fields. Before the timer verbs checked the kind, given a
;; TCP handle uv-timer-set-repeat! wrote into its struct and uv-timer-stop!
;; faulted. A signal handle that has never started is the gentlest other
;; kind to ask with.
(define other-kind (make-uv-signal l))

(for-each
 (lambda (entry)
   (test-equal (string-append (car entry)
                              " rejects another kind of handle, naming who and why")
     (list (string->symbol (car entry)) 'not-a-uv-timer)
     (non-handle-refusal (cdr entry))))
 (list (cons "uv-timer-start!"      (lambda () (uv-timer-start! other-kind (lambda (h) h) 1 0)))
       (cons "uv-timer-stop!"       (lambda () (uv-timer-stop! other-kind)))
       (cons "uv-timer-again!"      (lambda () (uv-timer-again! other-kind)))
       (cons "uv-timer-repeat"      (lambda () (uv-timer-repeat other-kind)))
       (cons "uv-timer-set-repeat!" (lambda () (uv-timer-set-repeat! other-kind 1)))))

;; The rows below count the registry from the suite's start.
(test-equal "the signal handle the timer verbs refused closes"
  'satisfied
  (begin (uv-close! other-kind)
         (run-until l (lambda () (eq? 'closed (uv-handle-state other-kind))) 64)))

(test-equal "the state predicates answer #f for a non-handle instead of raising"
  '(#f #f)
  (list (uv-handle-open? 'nope) (uv-handle-closing? 'nope)))

(test-equal "uv-close! rejects an on-close that is not a procedure, naming who and why"
  '(uv-close! on-close-not-a-procedure)
  (non-handle-refusal (lambda () (uv-close! t0 'not-a-procedure))))

(test-equal "the refused on-close left the timer open"
  'open (uv-handle-state t0))

;; --- uv-timer-start! validates BEFORE it reaches libuv -------------------
;; Design spec S5: the argument checks happen before any native call. The
;; row after the matrix is what makes that ordering observable -- a
;; validation done after uv_timer_start would leave the timer armed and the
;; loop alive.
(define (start-refusal thunk)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(test-equal "uv-timer-start! rejects a non-procedure callback, naming who and why"
  '(uv-timer-start! on-timeout-not-a-procedure)
  (start-refusal (lambda () (uv-timer-start! t0 'not-a-procedure 1 0))))

(test-equal "uv-timer-start! rejects a negative timeout, naming who and why"
  '(uv-timer-start! timeout-out-of-range)
  (start-refusal (lambda () (uv-timer-start! t0 (lambda (h) h) -1 0))))

(test-equal "uv-timer-start! rejects an inexact timeout, naming who and why"
  '(uv-timer-start! timeout-out-of-range)
  (start-refusal (lambda () (uv-timer-start! t0 (lambda (h) h) 1.0 0))))

(test-equal "uv-timer-start! rejects a negative repeat, naming who and why"
  '(uv-timer-start! repeat-out-of-range)
  (start-refusal (lambda () (uv-timer-start! t0 (lambda (h) h) 0 -5))))

(test-equal "uv-timer-start! rejects an inexact repeat, naming who and why"
  '(uv-timer-start! repeat-out-of-range)
  (start-refusal (lambda () (uv-timer-start! t0 (lambda (h) h) 0 2.5))))

(test-equal "no refused start armed the timer (validation precedes the native call)"
  'not-alive (if (uv-loop-alive? l) 'alive 'not-alive))

;; --- repeat, read back through libuv ------------------------------------
(test-equal "a never-started timer reports a repeat of 0"
  0 (uv-timer-repeat t0))

(uv-timer-set-repeat! t0 25)

(test-equal "uv-timer-set-repeat! is readable back through uv_timer_get_repeat"
  25 (uv-timer-repeat t0))

(test-equal "uv-timer-set-repeat! rejects a negative interval, naming who and why"
  '(uv-timer-set-repeat! repeat-out-of-range)
  (start-refusal (lambda () (uv-timer-set-repeat! t0 -1))))

(test-equal "the refused set-repeat left the interval alone"
  25 (uv-timer-repeat t0))

;; libuv's own EINVAL, surfaced as a SYMBOL (ADR-0006): uv_timer_again on a
;; timer that was never started has no callback to re-arm.
(test-equal "uv-timer-again! on a never-started timer surfaces libuv's EINVAL as a symbol"
  'EINVAL
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-timer-again! t0)
    'no-raise))

;; --- the close protocol, on a handle that never ran ----------------------
(define t0-closing-before (uv-is-closing (handle-ptr t0)))

(uv-close! t0)

(test-equal "uv-close! moves the handle to 'closing"
  'closing (uv-handle-state t0))

;; The record's state field and libuv's OWN answer, cross-checked -- two
;; sources rather than this binding restating itself. Without this row,
;; nothing would notice a uv-close! that updated the Scheme state and never
;; called uv_close. uv_is_closing returns a C boolean, not an errno, so it is
;; read for its value: 0 before the close was started, nonzero after (spike
;; FINDINGS Q1 measured exactly this ordering, with close_cb not yet fired at
;; that point).
(test-equal "libuv agrees the handle is closing, and did not before"
  '(not-closing closing)
  (list (if (zero? t0-closing-before) 'not-closing 'closing)
        (if (zero? (uv-is-closing (handle-ptr t0))) 'not-closing 'closing)))

(test-equal "the handle pointer is still live while the handle is only 'closing"
  'positive (if (positive? (handle-ptr t0)) 'positive 'already-zeroed))

(test-equal "draining the loop completes the close"
  'satisfied (run-until l (lambda () (eq? 'closed (uv-handle-state t0))) 64))

(test-equal "the close dispatcher zeroed the stored handle pointer"
  0 (handle-ptr t0))

(test-equal "the close dispatcher deregistered the handle"
  registry-with-loop (registry-count))

(test-equal "the close dispatcher returned the live timer counter to zero"
  0 (live-count 'timer))

;; --- use after close -----------------------------------------------------
;; The KIND is what is asserted, not merely that something raised: 'timer is
;; the discriminant a caller branches on, and 'no-raise / 'wrong-condition
;; are sentinels no success path produces.
(define (closed-op-kind thunk)
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(for-each
 (lambda (entry)
   (test-equal (string-append "use after close: " (car entry)
                              " raises &uv-handle-closed with kind 'timer")
     'timer (closed-op-kind (cdr entry))))
 (list (cons "uv-timer-start!"
             (lambda () (uv-timer-start! t0 (lambda (h) h) 1 0)))
       (cons "uv-timer-stop!"       (lambda () (uv-timer-stop! t0)))
       (cons "uv-timer-again!"      (lambda () (uv-timer-again! t0)))
       (cons "uv-timer-repeat"      (lambda () (uv-timer-repeat t0)))
       (cons "uv-timer-set-repeat!" (lambda () (uv-timer-set-repeat! t0 5)))))

(test-equal "uv-close! on an already-closed timer is a no-op, not an error"
  'idempotent
  (guard (e (#t (list 'raised e)))
    (uv-close! t0)
    'idempotent))

;; The state predicates are the ONE part of the handle surface that answers
;; on a closed handle instead of raising -- that is what makes them usable
;; from inside an on-close callback (see the ordering row below).
(test-equal "the state predicates answer on a closed handle instead of raising"
  '(#f #f closed)
  (list (uv-handle-open? t0) (uv-handle-closing? t0) (uv-handle-state t0)))

(test-equal "uv-handle-loop still answers for a closed handle"
  'same (if (eq? l (uv-handle-loop t0)) 'same 'different))

;; --- what the callback is handed ----------------------------------------
;; libuv's uv_timer_cb takes the firing handle; the Scheme mirror hands back
;; the timer RECORD the registry resolved that pointer to. `eq?` to the
;; record this suite created is the assertion -- the sentinel is a symbol no
;; pointer and no record can be.
(define seen-handle 'callback-never-ran)
(define probe-timer (make-uv-timer l))

(uv-timer-start! probe-timer
                 (lambda (timer)
                   (collect)
                   (set! seen-handle timer)
                   (uv-close! timer))
                 1 0)

(test-equal "the loop ran the probe timer's callback"
  'satisfied
  (run-until l (lambda () (not (eq? seen-handle 'callback-never-ran))) 64))

(test-equal "the on-timeout callback is handed its own timer record"
  'same (if (eq? seen-handle probe-timer) 'same 'different))

(test-equal "the probe timer closed itself from inside its callback"
  'satisfied
  (run-until l (lambda () (eq? 'closed (uv-handle-state probe-timer))) 64))

;; --- exactly three fires, stopped and closed from inside the callback ----
(define fires 0)
(define t1 (make-uv-timer l))

(uv-timer-start!
 t1
 (lambda (timer)
   (set! fires (+ fires 1))
   ;; design spec S11: GC pressure on the re-entry path, every fire.
   (collect)
   (when (= fires 3)
     (uv-timer-stop! timer)
     (uv-close! timer)))
 1 1)

(define run-outcome (if (uv-run l 'default) 'work 'no-work))

(test-equal "a 1ms repeat timer closed from inside its own callback fires exactly three times"
  3 fires)

(test-equal "uv-run 'default returns once the only handle has closed"
  'no-work run-outcome)

(test-equal "the self-closed timer reached 'closed"
  'closed (uv-handle-state t1))

(test-equal "the self-closed timer is gone from the registry"
  registry-with-loop (registry-count))

(test-equal "the self-closed timer returned the live timer counter to zero"
  0 (live-count 'timer))

;; --- "did not fire early", stated without a clock ------------------------
(define hour-fires 0)
(define t2 (make-uv-timer l))

(uv-timer-start! t2
                 (lambda (timer) (collect) (set! hour-fires (+ hour-fires 1)))
                 3600000 0)

;; The positive half of the pair: the timer really is armed. Without this,
;; "0 fires" would also be what a uv-timer-start! that did nothing produces.
;; This is also the loop-liveness transition tests/test-loop.sps could not
;; reach in Stage 2 (no handle type existed to hold a loop alive).
(test-equal "an armed timer holds its loop alive"
  'alive (if (uv-loop-alive? l) 'alive 'not-alive))

(test-equal "uv-run 'nowait reports work remaining while the hour timer is armed"
  'work (if (uv-run l 'nowait) 'work 'no-work))

(test-equal "a one-hour timer has not fired after a 'nowait run"
  0 hour-fires)

;; --- closing an ARMED timer from outside a callback ----------------------
(define t2-close-ran 'on-close-never-ran)
(define t2-state-inside 'on-close-never-ran)
(define t2-touch-inside 'on-close-never-ran)
(define t2-second-thunk 'second-thunk-never-ran)

(uv-close! t2
           (lambda ()
             (set! t2-close-ran 'on-close-ran)
             ;; Design spec S5: the free and the state transition happen
             ;; BEFORE the user's on-close runs, so this is 'closed and the
             ;; touch below deterministically raises.
             (set! t2-state-inside (uv-handle-state t2))
             (set! t2-touch-inside (closed-op-kind (lambda () (uv-timer-stop! t2))))))

(test-equal "closing an armed timer moves it to 'closing"
  'closing (uv-handle-state t2))

(test-equal "the on-close callback has not run before the loop is drained"
  'on-close-never-ran t2-close-ran)

;; Idempotence, with the second call's on-close argument IGNORED -- two
;; flags, because "the second call did not raise" would pass against a
;; close that ran the whole protocol twice.
(uv-close! t2 (lambda () (set! t2-second-thunk 'second-thunk-ran)))

(test-equal "draining completes the close of the armed timer"
  'satisfied (run-until l (lambda () (eq? 'closed (uv-handle-state t2))) 64))

(test-equal "the on-close callback ran"
  'on-close-ran t2-close-ran)

(test-equal "the handle was already 'closed when its on-close callback ran"
  'closed t2-state-inside)

(test-equal "touching the timer from inside on-close raises &uv-handle-closed with kind 'timer"
  'timer t2-touch-inside)

(test-equal "a second uv-close! while 'closing ignored its on-close argument"
  'second-thunk-never-ran t2-second-thunk)

(test-equal "the armed timer's close returned the live timer counter to zero"
  0 (live-count 'timer))

(test-equal "the armed timer's close returned the registry to its baseline"
  registry-with-loop (registry-count))

(test-equal "the loop is no longer alive once its only handle has closed"
  'not-alive (if (uv-loop-alive? l) 'alive 'not-alive))

;; --- the callback error policy, end to end (design spec S8) --------------
(define raise-fires 0)
(define t3 (make-uv-timer l))

(uv-timer-start!
 t3
 (lambda (timer)
   (set! raise-fires (+ raise-fires 1))
   (collect)
   (cond ((= raise-fires 2) (raise (make-timer-probe 'fire-2)))
         ((>= raise-fires 4) (uv-close! timer))))
 1 1)

(define raised-by-run (guard (e (#t e)) (uv-run l 'default) 'no-raise))

(test-equal "a raise inside a timer callback comes back out of uv-run"
  'raised (if (condition? raised-by-run) 'raised 'no-raise))

(test-equal "the re-raised condition satisfies uv-callback-error?"
  'callback-error
  (if (uv-callback-error? raised-by-run) 'callback-error 'not-callback-error))

(test-equal "the re-raised condition ALSO satisfies the original condition's own predicate"
  'timer-probe (if (timer-probe? raised-by-run) 'timer-probe 'not-timer-probe))

(test-equal "the compound still answers the original condition's field accessor"
  'fire-2 (timer-probe-mark raised-by-run))

(test-equal "the callback-error's cause is the original condition object"
  'fire-2
  (let ((cause (uv-callback-error-cause raised-by-run)))
    (if (timer-probe? cause) (timer-probe-mark cause) 'not-the-cause)))

;; Spike FINDINGS Q2: the raise consumed its own iteration and nothing else.
(test-equal "the raise stopped the loop on the fire that raised"
  2 raise-fires)

(test-equal "the loop reports no pending error once uv-run has re-raised it"
  'no-pending
  (if (loop-has-pending-error? l) 'still-pending 'no-pending))

;; The timer is still armed, so the loop is still usable: this is the
;; "defined post-error state" store-and-reraise buys (design spec S8).
(define after-raise (if (uv-run l 'default) 'work 'no-work))

(test-equal "the loop runs normally again after the callback error"
  'no-work after-raise)

(test-equal "the post-raise fires are visible in the counter"
  4 raise-fires)

(test-equal "the timer that raised still closed cleanly"
  'closed (uv-handle-state t3))

(test-equal "the raising timer's whole lifecycle balanced the counters"
  0 (live-count 'timer))

(test-equal "the raising timer's whole lifecycle balanced the registry"
  registry-with-loop (registry-count))

;; A callback may raise a NON-condition -- R6RS `raise` takes any object.
;; The trampoline guard's clause is `#t` rather than a condition predicate
;; precisely so those are caught here as well; a predicate clause would let
;; this one unwind into libuv's C frames, which spike FINDINGS Q2 measured
;; as process death.
(define bare-loop (make-uv-loop))
(define bare-timer (make-uv-timer bare-loop))

(uv-timer-start! bare-timer
                 (lambda (timer)
                   (collect)
                   (uv-close! timer)
                   (raise 'a-bare-symbol))
                 1 0)

(define bare-raise (guard (e (#t e)) (uv-run bare-loop 'default) 'no-raise))

(test-equal "a callback raising a NON-condition is caught by the guard too"
  'callback-error
  (if (uv-callback-error? bare-raise) 'callback-error 'not-callback-error))

(test-equal "the wrapped cause is the raised object itself"
  'a-bare-symbol (uv-callback-error-cause bare-raise))

(uv-loop-teardown! bare-loop)

;; --- uv-stop! from inside a callback -------------------------------------
;; Design spec S11 lists this as a test-loop row; it needs a callback, so it
;; lands here. The timer stays ARMED across the stop, which is what makes
;; the 'work answer discriminating: an unstopped loop would keep firing and
;; a stopped-and-disarmed loop would answer 'no-work.
(define stop-fires 0)
(define t4 (make-uv-timer l))

(uv-timer-start! t4
                 (lambda (timer)
                   (set! stop-fires (+ stop-fires 1))
                   (collect)
                   (uv-stop! (uv-handle-loop timer)))
                 1 1)

(define stop-outcome (if (uv-run l 'default) 'work 'no-work))

(test-equal "uv-stop! from inside a callback ends the run after that iteration"
  1 stop-fires)

(test-equal "uv-run reports work remaining after a stop with the timer still armed"
  'work stop-outcome)

(uv-close! t4)

(test-equal "the stopped loop drains normally afterwards"
  'satisfied (run-until l (lambda () (eq? 'closed (uv-handle-state t4))) 64))

;; --- operations that are illegal from inside a callback (design spec S8) -
(define illegal-attempts '())
(define t5 (make-uv-timer l))

(define (attempt who thunk)
  (guard (e ((uv-invalid-argument? e)
             (cons (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (cons who 'wrong-condition)))
    (thunk)
    (cons who 'no-raise)))

(uv-timer-start!
 t5
 (lambda (timer)
   (collect)
   (set! illegal-attempts
         (list (attempt 'uv-loop-close!
                        (lambda () (uv-loop-close! (uv-handle-loop timer))))
               (attempt 'uv-loop-teardown!
                        (lambda () (uv-loop-teardown! (uv-handle-loop timer))))))
   (uv-close! timer)
   ;; UNGUARDED, deliberately: this one has to arrive at the caller through
   ;; the trampoline guard and uv-run's re-raise -- the compound path.
   (uv-run (uv-handle-loop timer) 'nowait))
 1 0)

(define reentry-raise (guard (e (#t e)) (uv-run l 'default) 'no-raise))

(test-equal "uv-loop-close! from inside a callback is refused, naming who and why"
  '(uv-loop-close! . loop-running)
  (if (pair? illegal-attempts) (car illegal-attempts) 'callback-never-ran))

(test-equal "uv-loop-teardown! from inside a callback is refused, naming who and why"
  '(uv-loop-teardown! . loop-running)
  (if (and (pair? illegal-attempts) (pair? (cdr illegal-attempts)))
      (cadr illegal-attempts)
      'callback-never-ran))

(test-equal "a re-entrant uv-run arrives at the caller as &uv-callback-error"
  'callback-error
  (if (uv-callback-error? reentry-raise) 'callback-error 'not-callback-error))

(test-equal "...composed with &uv-invalid-argument naming uv-run and 'loop-running"
  '(uv-run loop-running)
  (if (uv-invalid-argument? reentry-raise)
      (list (uv-invalid-argument-who reentry-raise)
            (uv-invalid-argument-reason reentry-raise))
      'wrong-condition))

(test-equal "the re-entrant callback's own close still completed"
  'satisfied (run-until l (lambda () (eq? 'closed (uv-handle-state t5))) 64))

(test-equal "every timer this section created is accounted for"
  0 (live-count 'timer))

;; --- pending vs deferred, from two callbacks in one iteration ------------
;; libuv's uv__run_timers collects every due timer into a ready queue and
;; then runs the whole queue, so two 0 ms timers armed before the same run
;; fire in the SAME iteration -- uv_stop, called when the first error is
;; recorded, is checked by uv_run's own while-loop and does not interrupt
;; that queue. That is what makes "first error pending, second deferred"
;; reachable from real callbacks rather than from direct loop-record-error!
;; calls.
;;
;; WHICH of the two is "first" is also libuv's, not chance: the timer heap's
;; comparator breaks a timeout tie on start_id, allocated from
;; loop->timer_counter by uv_timer_start (vendor/libuv/src/timer.c:50-53).
;; So the timer started FIRST fires first, and `ta`'s error is the pending
;; one. Swapping the two uv-timer-start! calls below swaps the expected
;; 'first / 'second marks with it -- that is a real property being asserted,
;; not an ordering this test happens to have been written around.
(define deferred-loop (make-uv-loop))
(define fires-a 0)
(define fires-b 0)
(define ta (make-uv-timer deferred-loop))
(define tb (make-uv-timer deferred-loop))

(uv-timer-start! ta
                 (lambda (timer)
                   (collect)
                   (set! fires-a (+ fires-a 1))
                   (uv-close! timer)
                   (raise (make-timer-probe 'first)))
                 0 0)

(uv-timer-start! tb
                 (lambda (timer)
                   (collect)
                   (set! fires-b (+ fires-b 1))
                   (uv-close! timer)
                   (raise (make-timer-probe 'second)))
                 0 0)

(define deferred-raise (guard (e (#t e)) (uv-run deferred-loop 'default) 'no-raise))
(define deferred-list (uv-loop-deferred-errors deferred-loop))

(test-equal "both 0ms timers fired in the same iteration"
  '(1 1) (list fires-a fires-b))

(test-equal "uv-run re-raises the FIRST callback error"
  'first
  (if (timer-probe? deferred-raise) (timer-probe-mark deferred-raise) 'wrong-condition))

(test-equal "the second callback error is deferred, not lost and not re-raised"
  1 (length deferred-list))

(test-equal "the deferred error is the second callback's own condition"
  'second
  (if (and (pair? deferred-list) (timer-probe? (car deferred-list)))
      (timer-probe-mark (car deferred-list))
      'wrong-condition))

(test-equal "the deferred list is still readable after the run that produced it"
  1 (length (uv-loop-deferred-errors deferred-loop)))

(test-equal "the next uv-run clears the deferred list"
  '()
  (begin (uv-run deferred-loop 'nowait)
         (uv-loop-deferred-errors deferred-loop)))

(test-equal "both timers of the deferred pair closed"
  '(closed closed) (list (uv-handle-state ta) (uv-handle-state tb)))

(uv-loop-teardown! deferred-loop)

;; --- an on-close callback that raises, during teardown -------------------
;; The open question tests/../loop.sls recorded for Task 7: a callback error
;; raised while uv-loop-teardown! is draining. The policy chosen is
;; "complete the teardown, THEN re-raise", so the caller gets both the error
;; and a closed loop rather than an error and a leak.
(define teardown-loop (make-uv-loop))
(define teardown-timer (make-uv-timer teardown-loop))

(uv-timer-start! teardown-timer (lambda (timer) (collect)) 3600000 0)
(uv-close! teardown-timer (lambda () (raise (make-timer-probe 'from-on-close))))

(define teardown-raise
  (guard (e (#t e)) (uv-loop-teardown! teardown-loop) 'no-raise))

(test-equal "a raise from an on-close callback escapes uv-loop-teardown!"
  'from-on-close
  (if (timer-probe? teardown-raise) (timer-probe-mark teardown-raise) 'wrong-condition))

(test-equal "...wrapped as &uv-callback-error, like any other callback raise"
  'callback-error
  (if (uv-callback-error? teardown-raise) 'callback-error 'not-callback-error))

(test-equal "...and the loop was closed anyway, not left open behind the error"
  'not-open (if (uv-loop-open? teardown-loop) 'open 'not-open))

(test-equal "the teardown that raised still freed its timer"
  0 (live-count 'timer))

;; The close dispatcher calls on-close last, so a raise there skips none of
;; its own steps (#45): the seam contains the raise only after the dispatcher
;; has returned control to it, with nothing left to run.
(test-equal "...and marked it closed before its on-close raised"
  'closed (uv-handle-state teardown-timer))

;; --- the dispatcher's state check, reached directly ----------------------
;; libuv stops a timer as part of uv_close, so a timeout for a 'closing
;; handle cannot be produced through libuv -- which would leave the state
;; check in timer-dispatch untested by every row above (it was: the mutation
;; that deletes it survived the whole suite until this row existed). The
;; dispatcher is called here exactly as the trampoline calls it, with the
;; handle's own pointer, so what is exercised is the shipped code path and
;; not a copy of it.
;;
;; The 'open call is the seed: without it, "the callback did not run" would
;; also be what a dispatcher that never delivers anything produces.
(define closing-fires 0)
(define closing-timer (make-uv-timer l))

(uv-timer-start! closing-timer
                 (lambda (timer) (collect) (set! closing-fires (+ closing-fires 1)))
                 3600000 0)

((dispatcher-ref 'timer) (handle-ptr closing-timer))

(test-equal "seed: the timer dispatcher delivers a timeout to an OPEN handle"
  1 closing-fires)

(set-handle-state! closing-timer 'closing)
((dispatcher-ref 'timer) (handle-ptr closing-timer))

(test-equal "the timer dispatcher delivers nothing to a handle whose close has started"
  1 closing-fires)

(set-handle-state! closing-timer 'open)
(uv-close! closing-timer)

(test-equal "the state-check timer closed normally afterwards"
  'satisfied
  (run-until l (lambda () (eq? 'closed (uv-handle-state closing-timer))) 64))

;; --- the orphan fallback (a callback for a pointer nobody knows) ---------
;; libuv hands a trampoline nothing but a pointer. If the registry has no
;; entry for it there is no loop to record an error against, so the
;; dispatcher must not raise (that would be a raise inside a C frame, which
;; spike FINDINGS Q2 measured as process death) and must not crash. It
;; records instead.
(define orphans-before (length (orphan-callback-events)))

(test-equal "a timer callback for an unregistered pointer does not raise"
  'recorded
  (guard (e (#t (list 'raised e)))
    ((dispatcher-ref 'timer) 424242)
    'recorded))

(test-equal "a close callback for an unregistered pointer does not raise"
  'recorded
  (guard (e (#t (list 'raised e)))
    ((dispatcher-ref 'close) 424243)
    'recorded))

(test-equal "both orphaned callbacks were recorded, in order, with kind and pointer"
  '((timer . 424242) (close . 424243))
  (list-tail (orphan-callback-events) orphans-before))

;; --- the dispatch seam, and the two stubs v0.2 brings back ---------------
;; The ten slots in (libuv private native) are installed exactly once, by
;; (libuv private handles), at library initialisation. The callback types no
;; stage had implemented yet were installed as raising stubs that the
;; installed closure reaches THROUGH a mutable table -- so a later stage
;; replaces one by name, with no second install-callback-dispatchers! call.
;;
;; v0.1's Stage 4 spent four of its six stubs ('connection, 'write-done,
;; 'shutdown, 'connect) and Stage 5 the last two ('alloc, 'read); v0.2
;; Stage 2 widened the list to ten, and the two DNS names ('getaddrinfo,
;; 'getnameinfo) hold the raising stub until (libuv dns) installs the real
;; dispatchers through the seam. So the ORIGINAL formulation of these rows
;; -- fire a stub and watch the seam contain its raise -- is available
;; again, and it is once more the one pre-guard raise reachable through
;; shipped code: v0.1's replacement route (a req record whose handle field
;; is not a handle, making complete-request!'s record-accessor read raise
;; before it reached user code) no longer raises at all, because ADR-0011's
;; complete-request! resolves the owning loop from the REGISTRY ENTRY and
;; never touches the handle field -- that record now completes normally,
;; the entry being the authority on ownership. This suite keeps no row on
;; that shape; the handle-less completion itself is pinned in
;; tests/test-loop.sps's ADR-0011 section.
;;
;; THE SEAM CLOSURE IS GUARDED, and these rows are what says so. Since #45
;; its guard is the only containment a callback crosses: it covers the
;; user's callback, and anything raised before a dispatcher gets that far
;; -- a stub, or a bug in a dispatcher's own registry lookup. Unguarded,
;; spike FINDINGS Q2 applies: exit 255, no teardown, no foreign-free.
(define seam-loop (make-uv-loop))
(define seam-block (alloc-zeroed 64))
(define seam-orphans-before (length (orphan-callback-events)))

(registry-register! seam-block 'getaddrinfo-req seam-loop 'stub-target)

(test-equal "a stub raising in its slot does not escape into its caller"
  'contained
  (guard (e (#t (list 'escaped-into-the-caller e)))
    ((dispatcher-ref 'getaddrinfo) seam-block 0 0)
    'contained))

;; The registered fork of the seam's guard: the entry knows its loop, so the
;; contained object goes on that loop's error cell rather than into the
;; orphan list.
(test-equal "a contained raise on a REGISTERED pointer goes to the loop, not the orphan list"
  0 (- (length (orphan-callback-events)) seam-orphans-before))

(define seam-raise (guard (e (#t e)) (uv-run seam-loop 'nowait) 'no-raise))

(test-equal "...and reaches the caller from uv-run as &uv-callback-error"
  'callback-error
  (if (uv-callback-error? seam-raise) 'callback-error 'not-callback-error))

;; Pinned to WHAT was contained, not merely to "something was". The cause
;; has to be the stub's own raise -- &uv-error, who naming the callback
;; type, the not-implemented message -- so a seam that manufactured a
;; condition of its own instead of carrying the original through fails
;; here.
(test-equal "...carrying the stub's own raise, not one the seam manufactured"
  '(uv-error getaddrinfo
    "this callback type is not implemented in this version")
  (let ((cause (uv-callback-error-cause seam-raise)))
    (list (if (uv-error? cause) 'uv-error 'not-a-uv-error)
          (and (who-condition? cause) (condition-who cause))
          (and (message-condition? cause) (condition-message cause)))))

;; The stub raised before anything could pop or free the block, so this
;; suite owns the cleanup -- and the balance rows at the end of the file
;; are what would notice if it did not happen.
(when (registry-ref seam-block) (registry-deregister! seam-block))
(free! seam-block)

(uv-loop-teardown! seam-loop)

;; --- the seam's install-once rule, with every name spoken for ------------
;; Every name is installed, so every install-dispatch-procedure! call from
;; here on is refused. What each row below pins down is WHICH refusal, and
;; that a refused call changes nothing.
(test-equal "replacing a dispatcher a later stage installed is refused, naming who and why"
  '(uv-install-dispatch-procedure! dispatch-procedure-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-dispatch-procedure! 'read (lambda args 'hijacked))
    'no-raise))

;; A hijacked slot would answer 'hijacked and record nothing; the real read
;; dispatcher cannot resolve 606060, so it records an orphan naming itself.
;; That is the discriminating observation, and it is why this row calls the
;; slot rather than inspecting it.
(test-equal "the refused replacement left the real read dispatcher in place"
  '((read . 606060))
  (let ((before (length (orphan-callback-events))))
    ((dispatcher-ref 'read) 606060 0 0)
    (list-tail (orphan-callback-events) before)))

(test-equal "replacing this stage's own timer dispatcher is refused, naming who and why"
  '(uv-install-dispatch-procedure! dispatch-procedure-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-dispatch-procedure! 'timer (lambda args 'hijacked))
    'no-raise))

(test-equal "install-dispatch-procedure! rejects a name that is not a callback type"
  '(uv-install-dispatch-procedure! unknown-dispatcher)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-dispatch-procedure! 'not-a-callback-type (lambda args 'nope))
    'no-raise))

;; The argument checks run in a fixed order, and this row is what says so:
;; 'read is already installed, so a not-a-procedure argument would be refused
;; by EITHER check -- and the reason it names is the one that runs first.
(test-equal "install-dispatch-procedure! rejects a dispatcher that is not a procedure"
  '(uv-install-dispatch-procedure! not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-dispatch-procedure! 'read 'not-a-procedure)
    'no-raise))

;; --- a close suspended at any point is one step -------------------------
;; uv-close! checks that a handle is open, marks it closing, and calls
;; libuv's uv_close. A green-thread scheduler on the loop thread can suspend
;; a close anywhere in that and run another close of the same handle
;; meanwhile, so all three must be one step. Measured before the fix:
;; - split between the check and the mark, two closes both began and both
;;   called uv_close, and the loop then walked a corrupted closing list
;;   ("invalid memory reference" on macOS, a hang on Linux);
;; - split between the mark and uv_close, the handle read closing while
;;   libuv had not begun to close it, and a teardown in that window hung (an
;;   async) or failed with EBUSY (a timer).
;;
;; An engine runs (uv-close! h on-close-first) for FUEL ticks. Where it is
;; suspended, the sweep first compares the handle's state with libuv's
;; uv_is_closing: the close has either not begun, or begun natively too.
;; Then a second close with on-close-second runs, and the engine resumes. A
;; close that begins stores its on-close, so the first close's callback
;; replacing the second's means both began. Such a row answers its evidence
;; and leaks its loop: running that loop would walk the corrupted list.

(define close-sweep-max-fuel 60)

;; close-then-close : (uv-loop -> uv-handle) exact-positive-integer
;;                    -> (or symbol list)
(define (close-then-close make-handle fuel)
  (let* ((loop (make-uv-loop))
         (h (make-handle loop))
         (on-close-first (lambda () #f))
         (on-close-second (lambda () #f))
         (first (make-engine
                 (lambda ()
                   (guard (c (#t (list 'raised (describe c))))
                     (uv-close! h on-close-first)
                     'closed)))))
    (first fuel
           (lambda (ticks v)
             (uv-loop-teardown! loop)
             (if (eq? v 'closed) 'finished (list fuel 'finished v)))
           (lambda (suspended)
             (let* ((state (handle-state h))
                    (native (uv-is-closing (handle-ptr h)))
                    (split (and (not (eq? (eq? state 'closing)
                                          (not (zero? native))))
                                (list fuel 'split-close state native))))
               (uv-close! h on-close-second)
               (let* ((second-began (eq? (handle-on-close h) on-close-second))
                      (v (suspended 1000000 (lambda (ticks v) v)
                                    (lambda (more) 'still-running))))
                 (cond ((not (eq? v 'closed)) (list fuel 'resumed v))
                       ((and second-began (eq? (handle-on-close h) on-close-first))
                        (list fuel 'both-closes-began))
                       (else
                        (uv-loop-teardown! loop)
                        (cond (split)
                              (second-began 'second-began)
                              (else 'first-began))))))))))

;; close-sweep : (uv-loop -> uv-handle) -> (list-of (or symbol list))
(define (close-sweep make-handle)
  (guard (e (#t (list (list 'sweep-raised (describe e)))))
    (let run ((fuel 1) (acc '()))
      (if (> fuel close-sweep-max-fuel)
          (reverse acc)
          (run (+ fuel 1) (cons (close-then-close make-handle fuel) acc))))))

(define (close-sweep-violations sweep)
  (filter (lambda (row) (not (memq row '(finished first-began second-began))))
          sweep))

;; The sweep is live only if it caught the first close before its step (a
;; 'second-began row) and its fuel outlasted the whole verb, so every point
;; in between was visited. A split step would add suspension points inside
;; it, and the rows above would see them; the one-step close has none after
;; its step (fuel map in the async-send-fence mutation log).
(define (close-sweep-reach sweep)
  (list (if (memq 'second-began sweep) 'second-began 'never-caught-before-the-step)
        (let ((last-row (list-ref sweep (- (length sweep) 1))))
          (if (eq? last-row 'finished) 'finished last-row))))

(define timer-close-sweep (close-sweep make-uv-timer))
(define async-close-sweep
  (close-sweep (lambda (loop) (make-uv-async loop (lambda (h) #f)))))

(test-equal "a timer's close suspended anywhere is one step, and a second close starts no second one"
  '() (close-sweep-violations timer-close-sweep))
(test-equal "the timer close sweep caught a close before its step and ran one to the end"
  '(second-began finished) (close-sweep-reach timer-close-sweep))
(test-equal "an async's close suspended anywhere is one step, and a second close starts no second one"
  '() (close-sweep-violations async-close-sweep))
(test-equal "the async close sweep caught a close before its step and ran one to the end"
  '(second-began finished) (close-sweep-reach async-close-sweep))

;; --- balance -------------------------------------------------------------
(uv-loop-teardown! l)

(test-equal "every timer this suite created has been freed"
  0 (live-count 'timer))

(test-equal "the registry is back to its starting size"
  registry-count-at-start (registry-count))

(collect)

(test-equal "a full collection after teardown leaves every counter at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-end "timer")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
