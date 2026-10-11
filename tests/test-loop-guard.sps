#!r6rs
;;; SRFI-64 suite for a raise out of call-with-uv-loop's body reaching guards
;;; outside it.
;;;
;;; R6RS guard unwinds to itself before it tests its clauses. When none
;;; matches, it re-raises in the dynamic environment of the original raise,
;;; and so re-enters the body's dynamic-wind. call-with-uv-loop refuses every
;;; return into a body it has left, since the loop is torn down by then. A
;;; refusal that raised &uv-handle-closed there would replace the body's
;;; condition: a guard that did not match would hand its caller
;;; &uv-handle-closed, and a guard with a uv-error? clause would take a
;;; user's error for the binding's.
;;;
;;; So the first re-entry into a body that was left while its raise was
;;; being handled raises that raise again. It is still a refusal, so nothing
;;; resumes the body, but the condition that reaches the guards outside is
;;; the body's own.
(import (rnrs)
        (srfi :64)
        (libuv)
        (only (uv-evidence) live-count describe)
        (only (chezscheme) make-engine engine-block))

;; SRFI-64's default runner does not set a process exit code.
(define runner (test-runner-simple))
(test-runner-current runner)

(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "loop-guard")

(define live-before (live-count 'loop))

;; The body's own condition. Rows compare by eq?, so only this object
;; passes: &uv-handle-closed, another &error, or #f from SRFI-64's catch
;; cannot.
(define original
  (condition (make-error) (make-message-condition "the body's own raise")))

;; verdict : object -> object
;; 'the-bodys-own for ORIGINAL, else what came instead.
(define (verdict e)
  (if (eq? e original) 'the-bodys-own (list 'got (describe e))))

(define (raise-original loop) (raise original))

(test-equal "a catch-all guard gets the body's own condition"
  'the-bodys-own
  (guard (e (#t (verdict e)))
    (call-with-uv-loop raise-original)))

(test-equal "a guard whose clauses do not match passes the body's own condition to the guard outside it"
  'the-bodys-own
  (guard (e (#t (verdict e)))
    (guard (e ((string? e) 'string))
      (call-with-uv-loop raise-original))))

(test-equal "a uv-error? guard does not take the body's own error for the binding's"
  'the-bodys-own
  (guard (e (#t (verdict e)))
    (guard (e ((uv-error? e) (list 'handled-as-uv-error (describe e))))
      (call-with-uv-loop raise-original))))

;; #f is what a raise that left no record of itself looks like, so a body
;; that raises #f must still be told from one that raised nothing.
(test-equal "a body that raises #f passes #f through a guard that does not match"
  '(got #f)
  (guard (e (#t (list 'got e)))
    (guard (e ((string? e) 'string))
      (call-with-uv-loop (lambda (loop) (raise #f))))))

;; The cost of the refusal: the guard that did not match sees the
;; condition twice, once from the body and once from the re-entry, and so
;; tests its clauses twice. docs/api.md says so.
(test-equal "a guard whose clauses do not match tests them twice"
  '(the-bodys-own 2)
  (let ((tests 0))
    (let ((outcome
           (guard (e (#t (verdict e)))
             (guard (e ((begin (set! tests (+ tests 1)) #f) 'never))
               (call-with-uv-loop raise-original)))))
      (list outcome tests))))

;; raise-continuable handled where it was raised never leaves the body: the
;; handler returns into it, and the loop is still live.
(test-equal "a raise-continuable the handler returns from resumes the body, with its loop live"
  '(42 fired)
  (guard (e (#t (list 'raised (describe e))))
   (with-exception-handler
    (lambda (c) (if (eq? c 'ask) 42 (raise c)))
    (lambda ()
      (call-with-uv-loop
       (lambda (loop)
         (let* ((answer (raise-continuable 'ask))
                (fired 'not-fired))
           (uv-timer-start! (make-uv-timer loop)
                            (lambda (t) (set! fired 'fired))
                            0 0)
           (uv-run loop 'default)
           (list answer fired))))))))

;; With a guard that does not match between them, the handler that returns
;; would resume a torn-down body. It must not.
(test-equal "a guard that does not match a raise-continuable never lets a handler outside it resume the body"
  'not-resumed
  (let ((resumed #f))
    (guard (e (#t #f))
      (with-exception-handler
        (lambda (c) 'resume)
        (lambda ()
          (guard (e ((string? e) 'string))
            (call-with-uv-loop
             (lambda (loop)
               (raise-continuable 'warn)
               (set! resumed #t)))))))
    (if resumed 'resumed 'not-resumed)))

;; A raise the body was resumed from is over. A later exit by a continuation
;; is not a raise, and a re-entry after it is refused as one.
(test-equal "a raise the body was resumed from does not outlive its handling"
  '(handle-closed loop)
  (let ((resume-k #f) (entered 0))
    (call/cc
     (lambda (done)
       (guard (e ((uv-handle-closed? e) (done (list 'handle-closed (uv-handle-closed-kind e))))
                 (#t (done (verdict e))))
         (call/cc
          (lambda (escape)
            (with-exception-handler
              (lambda (c) (if (eq? c original) 'resume (raise-continuable c)))
              (lambda ()
                (call-with-uv-loop
                 (lambda (loop)
                   (set! entered (+ entered 1))
                   (raise-continuable original)
                   (call/cc (lambda (k) (set! resume-k k) (escape 'left)))
                   (done (list 'body-resumed entered))))))))
         (resume-k 'back-in))))))

;; Two raises in one body: the guard outside gets the one that left it. The
;; handler that resumes the first sits inside the guard, so the guard never
;; unwinds for it.
(test-equal "after a raise the body was resumed from, a later raise is the one that reaches the guard"
  'the-bodys-own
  (guard (e (#t (verdict e)))
    (guard (e ((string? e) 'string))
      (with-exception-handler
        (lambda (c) (if (eq? c 'first) 'resume (raise-continuable c)))
        (lambda ()
          (call-with-uv-loop
           (lambda (loop)
             (raise-continuable 'first)
             (raise original))))))))

;; The rule is the first re-entry, a guard's or not: here a continuation the
;; body captured, called after a guard that matched has handled its raise.
;; The continuation holds that guard too, so the guard handles the raise a
;; second time. Called again, it is refused as closed. PAST counts the
;; body's code after the capture point: a re-entry let through runs it.
(test-equal "only the first re-entry into a body left by its raise raises it, and the body never runs again"
  '(handled 2 entered 1 past 1 then handle-closed)
  (let ((resume-k #f) (handled 0) (entered 0) (past 0) (attempts 0))
    (call/cc
     (lambda (done)
       (guard (e ((uv-handle-closed? e)
                  (done (list 'handled handled 'entered entered 'past past
                              'then 'handle-closed)))
                 (#t (done (list 'escaped (describe e)))))
         (guard (e ((eq? e original) (set! handled (+ handled 1))))
           (call-with-uv-loop
            (lambda (loop)
              (set! entered (+ entered 1))
              (call/cc (lambda (k) (set! resume-k k)))
              (set! past (+ past 1))
              (raise original))))
         (set! attempts (+ attempts 1))
         (when (and (<= attempts 2) (procedure? resume-k))
           (resume-k 'back-in))
         (done (list 'handled handled 'entered entered 'past past
                     'attempts attempts)))))))

;; A handler outside that answers a raise by re-entering the body, to retry
;; it, is refused. Were every re-entry refused with the raise, it would see
;; the same raise for good and retry for good; the cap of 5 makes that a
;; failure here instead of a hang.
(test-equal "a handler that retries the body by re-entering it is refused once with the raise, then as closed"
  '((outer-got handle-closed) retries 1 body-runs 1)
  (let ((retries 0) (body-runs 0) (restart #f))
    (let ((outcome
           (guard (e (#t (list 'outer-got (if (uv-handle-closed? e) 'handle-closed (verdict e)))))
             (with-exception-handler
               (lambda (c)
                 (if (and (eq? c original) (< retries 5) restart)
                     (begin (set! retries (+ retries 1)) (restart 'retry))
                     (raise-continuable c)))
               (lambda ()
                 (guard (e ((string? e) 'string))
                   (call-with-uv-loop
                    (lambda (loop)
                      (set! body-runs (+ body-runs 1))
                      (call/cc (lambda (k) (set! restart k)))
                      (if (= retries 0) (raise original) 'retried)))))))))
      (list outcome 'retries retries 'body-runs body-runs))))

;; A handler that gives a raise up by jumping back into the body never
;; returns, so its record is not cleared then. The body's own return clears
;; it: a later re-entry is refused as closed, not with the old raise.
(test-equal "a raise a handler gave up by jumping back into the body does not outlive the body's return"
  '(handle-closed)
  (let ((restart #f) (later #f) (tries 0))
    (call/cc
     (lambda (done)
       (guard (e ((uv-handle-closed? e) (done '(handle-closed)))
                 (#t (done (verdict e))))
         (with-exception-handler
           (lambda (c)
             (if (and (eq? c original) (= tries 1))
                 (restart 'retry)
                 (raise-continuable c)))
           (lambda ()
             (call-with-uv-loop
              (lambda (loop)
                (call/cc (lambda (k) (set! restart k)))
                (set! tries (+ tries 1))
                (when (= tries 1) (raise original))
                (call/cc (lambda (k) (set! later k)))
                'returned))))
         (if (< tries 3)
             (begin (set! tries 3) (later 'back-in))
             (done (list 'later-returned tries))))))))

;; The costs docs/api.md states, held so that a change to them is made on
;; purpose. A handler between the guard that does not match and the body
;; sees the condition twice, as the guard's clauses do.
(test-equal "a handler between a guard that does not match and the body sees the body's condition twice"
  '(the-bodys-own (the-bodys-own the-bodys-own))
  (let ((seen '()))
    (let ((outcome
           (guard (e (#t (verdict e)))
             (guard (e ((string? e) 'string))
               (with-exception-handler
                 (lambda (c)
                   (set! seen (cons (verdict c) seen))
                   (raise-continuable c))
                 (lambda () (call-with-uv-loop raise-original)))))))
      (list outcome (reverse seen)))))

;; A handler that returns from the body's raise: R6RS raises the
;; &non-continuable from the handler that was returned to. That handler is
;; call-with-uv-loop's own, so the handler outside it is called once more,
;; with the &non-continuable.
(test-equal "a handler that returns from the body's raise is called again with the &non-continuable"
  '(non-continuable (the-bodys-own non-continuable))
  (let ((seen '()))
    (define (name c)
      (if (non-continuable-violation? c) 'non-continuable (verdict c)))
    (let ((outcome
           (guard (e (#t (name e)))
             (with-exception-handler
               (lambda (c) (set! seen (cons (name c) seen)) 'returned)
               (lambda () (call-with-uv-loop raise-original))))))
      (list outcome (reverse seen)))))

(test-equal "a handler's several answers to the body's raise-continuable reach the body"
  '(1 2)
  (guard (e (#t (list 'raised (describe e))))
    (with-exception-handler
      (lambda (c) (values 1 2))
      (lambda ()
        (call-with-uv-loop
         (lambda (loop)
           (call-with-values (lambda () (raise-continuable 'ask)) list)))))))

(test-equal "the body's several values reach call-with-uv-loop's caller"
  '(1 2)
  (guard (e (#t (list 'raised (describe e))))
    (call-with-values
     (lambda () (call-with-uv-loop (lambda (loop) (values 1 2))))
     list)))

;; blocked-raise-run : -> (list object integer integer)
;; What a guard outside the body got, how many times the engine expired,
;; and how many times the handler outside the body was called, for an
;; engine suspended by engine-block in that handler while it handles the
;; body's raise, on its first call only. Resumed with a fixed budget, at
;; most 10 times.
(define (blocked-raise-run)
  (let* ((blocked #f)
         (expiries 0)
         (calls 0)
         (engine
          (make-engine
           (lambda ()
             (guard (e (#t (verdict e)))
               (with-exception-handler
                 (lambda (c)
                   (set! calls (+ calls 1))
                   (unless blocked (set! blocked #t) (engine-block))
                   (raise-continuable c))
                 (lambda () (call-with-uv-loop raise-original))))))))
    (let run ((engine engine) (rounds 0))
      (if (> rounds 10)
          (list 'still-suspended expiries calls)
          (engine 1000000
                  (lambda (ticks value) (list value expiries calls))
                  (lambda (next)
                    (set! expiries (+ expiries 1))
                    (run next (+ rounds 1))))))))

;; An engine whose fuel runs out while a handler outside the body handles
;; its raise leaves the body as a guard does. Resumed, the re-entry raises
;; the body's condition again, so the handler is called a second time: a
;; re-entry let through would carry on from the first call instead.
(test-equal "an engine suspended while the body's raise was being handled raises it again when resumed"
  '(the-bodys-own 1 2)
  (blocked-raise-run))

(test-equal "every row's loop was torn down"
  live-before (live-count 'loop))

(test-end "loop-guard")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
