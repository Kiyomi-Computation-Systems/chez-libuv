#!r6rs
;;; SRFI-64 suite for (uv-sweep), the engine-sweep driver the suites share
;;; (#81): run-capped, capped and sweep-fuels.
;;;
;;; Pure: the library imports no native code, and make check-purity runs
;;; this suite with the shim poisoned (PURE_TESTS), so the pure suites can
;;; use the driver too.
(import (rnrs)
        (srfi :64)
        (uv-sweep))

;; SRFI-64 sets no exit status; the runner's fail count drives it
;; (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The rows return
;; their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "sweep")

;; spin : exact-nonnegative-integer -> 'finished
;; N loop iterations, one engine tick each (measured: 10,000,000 iterations
;; expire an engine 100 times at 100,000 ticks).
(define (spin n)
  (let loop ((i 0)) (if (< i n) (loop (+ i 1)) 'finished)))

;; Three times the ticks the cap allows, so a call that ran this long is
;; given up, and one that was not given up finishes it: a driver with no cap
;; answers 'finished here, where a driver with no cap at all on a call that
;; never ends would hang the suite instead of failing a row.
(define outlasting (* 3 resume-cap resume-fuel))

;; --- run-capped -------------------------------------------------------------
(test-equal "run-capped answers the call's value, and no expiry for a call that fits its fuel"
  '(answer #f 0)
  (let ((changes 0))
    (let-values (((answer expired)
                  (run-capped (lambda () 'answer) resume-fuel
                              (lambda () (set! changes (+ changes 1))))))
      (list answer expired changes))))

;; A call of 200 ticks outlasts a fuel of 100 and fits one of 1,000, so the
;; first expiry comes at FUEL ticks: a driver that gave the first slice
;; resume-fuel ticks would let both fit, and no sweep would split a call.
(test-equal "run-capped gives the call FUEL ticks before the first expiry"
  '((finished #t) (finished #f))
  (map (lambda (fuel)
         (let-values (((answer expired)
                       (run-capped (lambda () (spin 200)) fuel (lambda () #f))))
           (list answer expired)))
       '(100 1000)))

;; The call reads the flag the change sets as its last step, after
;; outlasting several expiries, so it answers what the change did.
(test-equal "run-capped makes its change once, at the first expiry, and resumes the call after it"
  '((finished changed) #t 1)
  (let ((changes 0) (flag 'unchanged))
    (let-values (((answer expired)
                  (run-capped (lambda () (list (spin (* 5 resume-fuel)) flag))
                              1
                              (lambda ()
                                (set! changes (+ changes 1))
                                (set! flag 'changed)))))
      (list answer expired changes))))

(test-equal "run-capped gives a call up after resume-cap resumes, answering the give-up and no value of the call's"
  (list (list 'stuck-after-resumes resume-cap) #t #t)
  (let-values (((answer expired)
                (run-capped (lambda () (spin outlasting)) 1 (lambda () #f))))
    (list answer expired (stuck? answer))))

(test-equal "stuck? is true of the give-up alone"
  '(#t #f #f #f #f)
  (list (stuck? (list 'stuck-after-resumes resume-cap))
        (stuck? 'stuck)
        (stuck? '(stuck))
        (stuck? '(refused stuck-after-resumes))
        (stuck? #f)))

;; A raise inside the engine is caught there and raised again once the
;; engine has returned, so the caller's guard sees the raised object itself.
(test-equal "run-capped raises again, outside the engine, what the call raised"
  '(caught boom)
  (guard (e ((symbol? e) (list 'caught e))
            (#t (list 'caught-something-else e)))
    (run-capped (lambda () (spin 1000) (raise 'boom)) 1 (lambda () #f))
    'no-raise))

(test-equal "capped answers the call's value, gives up a call that outlasts the cap, and makes no change"
  (list 'answer (list 'stuck-after-resumes resume-cap))
  (list (capped (lambda () 'answer))
        (capped (lambda () (spin outlasting)))))

;; --- sweep-fuels ------------------------------------------------------------
;; A run at FUEL answers its verdict and whether an expiry reached it.
(define (expiring-until last)
  (lambda (fuel) (values (list 'verdict fuel) (< fuel last))))

(define (never-stop verdict) #f)

(test-equal "sweep-fuels runs fuel 1 up, and stops at the first run no expiry reached"
  '((1 (verdict 1) #t) (2 (verdict 2) #t) (3 (verdict 3) #f))
  (sweep-fuels (expiring-until 3) 100 never-stop))

(test-equal "sweep-fuels stops at its last fuel"
  '((1 (verdict 1) #t) (2 (verdict 2) #t))
  (sweep-fuels (expiring-until 100) 2 never-stop))

(test-equal "sweep-fuels stops at a run given up, which would cost every later run the same"
  (list '(1 (verdict 1) #t) (list 2 (list 'stuck-after-resumes resume-cap) #t))
  (sweep-fuels (lambda (fuel)
                 (values (if (= fuel 2)
                             (list 'stuck-after-resumes resume-cap)
                             (list 'verdict fuel))
                         #t))
               100 never-stop))

(test-equal "sweep-fuels stops at a run its stop predicate names"
  '((1 (verdict 1) #t) (2 (verdict 2) #t))
  (sweep-fuels (expiring-until 100) 100
               (lambda (verdict) (equal? verdict '(verdict 2)))))

;; A raise between runs, in the change or the verdict's own plumbing, would
;; abort the suite before any row could say why. The sweep keeps the runs
;; before it and ends with the raise as the last run's verdict.
(test-equal "sweep-fuels keeps the runs before a raise, and ends with the raise as its last verdict"
  '((1 (verdict 1) #t) (2 sweep-raised #f))
  (let ((rows (sweep-fuels (lambda (fuel)
                             (if (= fuel 2)
                                 (raise 'between-runs)
                                 (values (list 'verdict fuel) #t)))
                           100 never-stop)))
    (map (lambda (row)
           (if (and (pair? (cadr row)) (eq? (car (cadr row)) 'sweep-raised))
               (list (car row) 'sweep-raised (caddr row))
               row))
         rows)))

(test-equal "a sweep-raised verdict names what was raised"
  '(sweep-raised "between-runs")
  (let ((rows (sweep-fuels (lambda (fuel) (raise 'between-runs)) 100 never-stop)))
    (cadr (car rows))))

(test-end "sweep")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
