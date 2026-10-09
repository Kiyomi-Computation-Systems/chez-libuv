#!r6rs
;;; SRFI-64 suite for a raise out of call-with-uv-loop's body reaching guards
;;; outside it (#118).
;;;
;;; R6RS guard unwinds to itself before it tests its clauses. When none
;;; matches, it re-raises in the dynamic environment of the original raise,
;;; and so re-enters the body's dynamic-wind. call-with-uv-loop refuses every
;;; return into a body it has left, since the loop is torn down by then. Its
;;; refusal raised &uv-handle-closed, which replaced the body's condition: a
;;; guard that did not match handed its caller &uv-handle-closed, and a guard
;;; with a uv-error? clause took a user's error for the binding's.
;;;
;;; A re-entry into a body that was left while its raise was being handled
;;; now raises that raise again. It is still a refusal, so nothing resumes
;;; the body, but the condition that reaches the guards outside is the
;;; body's own.
(import (rnrs)
        (srfi :64)
        (libuv)
        (only (uv-evidence) live-count describe)
        (only (chezscheme) make-engine engine-block))

;; SRFI-64's default runner does not set a process exit code (AGENTS.md).
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

;; The rule is any re-entry, not only a guard's: a continuation the body
;; captured, called after a guard that matched has handled its raise. The
;; continuation holds that guard too, so the guard handles the raise a
;; second time, and the body never runs again.
(test-equal "a body left by its raise refuses a later re-entry with that raise"
  '(handled 2 entered 1)
  (let ((resume-k #f) (handled 0) (entered 0))
    (guard (e (#t (list 'escaped (describe e))))
      (guard (e ((eq? e original) (set! handled (+ handled 1))))
        (call-with-uv-loop
         (lambda (loop)
           (set! entered (+ entered 1))
           (call/cc (lambda (k) (set! resume-k k)))
           (raise original))))
      (when (and (= handled 1) (procedure? resume-k))
        (resume-k 'back-in))
      (list 'handled handled 'entered entered))))

;; blocked-raise-run : -> (list object integer)
;; What a guard outside the body got, and how many times the engine
;; expired, for an engine suspended by engine-block in a handler outside
;; the body while it handles the body's raise, on its first call only.
;; Resumed with a fixed budget, at most 10 times.
(define (blocked-raise-run)
  (let* ((blocked #f)
         (expiries 0)
         (engine
          (make-engine
           (lambda ()
             (guard (e (#t (verdict e)))
               (with-exception-handler
                 (lambda (c)
                   (unless blocked (set! blocked #t) (engine-block))
                   (raise-continuable c))
                 (lambda () (call-with-uv-loop raise-original))))))))
    (let run ((engine engine) (rounds 0))
      (if (> rounds 10)
          (list 'still-suspended expiries)
          (engine 1000000
                  (lambda (ticks value) (list value expiries))
                  (lambda (next)
                    (set! expiries (+ expiries 1))
                    (run next (+ rounds 1))))))))

;; An engine whose fuel runs out while a handler outside the body handles
;; its raise leaves the body as a guard does. Resumed, the re-entry raises
;; the body's condition again.
(test-equal "an engine suspended while the body's raise was being handled raises it again when resumed"
  '(the-bodys-own 1)
  (blocked-raise-run))

(test-equal "every row's loop was torn down"
  live-before (live-count 'loop))

(test-end "loop-guard")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
