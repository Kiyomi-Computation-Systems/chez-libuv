#!r6rs
;;; The engine-sweep driver the suites share (#81): a call run in an engine
;;; whose resumes are capped, a change made at its first expiry, and a sweep
;;; of such runs at rising fuel. tests/test-sweep.sps holds it.
;;;
;;; A sweep runs a verb in an engine at fuel 1, 2, 3, ... and changes the
;;; verb's argument at the engine's first expiry, so that some run changes it
;;; at each point the verb can be stopped at. Each suite used to write its own
;;; copy, with resume caps of 10, 20, 100 or none, and three spellings of the
;;; give-up; test-dns's had none, so a verb whose walk came to loop would have
;;; hung its suite instead of failing a row by name.
;;;
;;; PURE: (rnrs) and make-engine only, so the pure suites can use it too
;;; (PURE_TESTS; make check-purity holds it).
(library (uv-sweep)
  (export resume-fuel resume-cap run-capped run-capped* capped stuck? sweep-fuels)
  (import (rnrs)
          (only (chezscheme) make-engine)
          (uv-describe))

  ;; A call is resumed with resume-fuel ticks at a time, at most resume-cap
  ;; times: 10,000,000 ticks, which a bare loop spends in about 8 ms
  ;; (measured, 2026-10-07). The suites' own caps were 10 to 100 resumes of
  ;; these ticks, and passed on every correct build.
  (define resume-fuel 100000)
  (define resume-cap 100)

  ;; The give-up: what a call still running after resume-cap resumes
  ;; answers. A call's own value could only match it by returning a list
  ;; headed by this symbol, which no verb returns.
  (define (give-up) (list 'stuck-after-resumes resume-cap))

  ;; stuck? : object -> boolean
  ;; The give-up, or a verdict that adds its run's evidence after it.
  (define (stuck? x)
    (and (pair? x) (eq? (car x) 'stuck-after-resumes)))

  ;; run-capped : (-> object) exact-positive-integer (-> any)
  ;;              -> (values object boolean)
  ;; CALL's value, run in an engine given FUEL ticks, and whether an expiry
  ;; reached it. At the first expiry CHANGE is called, once, from outside
  ;; the engine; the call is then resumed with resume-fuel ticks at a time,
  ;; and given up after resume-cap resumes, answering (stuck-after-resumes
  ;; resume-cap). The caller's handlers are in effect inside the engine: what
  ;; CALL raises reaches the caller's guard, and a continuable raise resumes
  ;; CALL with what the caller's handler returns. A guard here that caught
  ;; every raise to raise it again outside would end the call at a warning.
  (define (run-capped call fuel change)
    (run-capped* call fuel change 1))

  ;; run-capped* : (-> object) exact-positive-integer (-> any)
  ;;               exact-positive-integer -> (values object boolean)
  ;; run-capped, with CHANGE called at each of the first CHANGES expiries
  ;; and the call resumed with FUEL ticks until the last of them, then with
  ;; resume-fuel.
  (define (run-capped* call fuel change changes)
    (let* ((made 0)
           (answer
            (let run ((eng (make-engine call))
                      (ticks fuel)
                      (resumes 0))
              (eng ticks
                   (lambda (left v) v)
                   (lambda (next)
                     (when (< made changes)
                       (set! made (+ made 1))
                       (change))
                     (if (= resumes resume-cap)
                         (give-up)
                         (run next
                              (if (< made changes) fuel resume-fuel)
                              (+ resumes 1))))))))
      (values answer (positive? made))))

  ;; capped : (-> object) -> object
  ;; CALL's value, run in an engine whose resumes are capped as
  ;; run-capped's are, with nothing changed: a call that never ends answers
  ;; the give-up instead of hanging the suite.
  (define (capped call)
    (let-values (((answer expired) (run-capped call resume-fuel (lambda () #f))))
      answer))

  ;; sweep-fuels : (exact-positive-integer -> (values verdict boolean))
  ;;               exact-positive-integer (verdict -> boolean)
  ;;               -> (list-of (list fuel verdict expired?))
  ;; RUN-AT's verdict at fuel 1, 2, ... and whether an expiry reached the
  ;; run. It stops at the first run no expiry reached, since more fuel
  ;; changes nothing after it; at MAX-FUEL; at a run given up, which would
  ;; cost every later run the same; and at a verdict STOP? names. A raise in
  ;; a run, outside whatever the run guards itself, or in STOP?, would abort
  ;; the suite before any row could say why, so the sweep ends there,
  ;; keeping the runs before it, with (sweep-raised message) as the last
  ;; run's verdict.
  (define (sweep-fuels run-at max-fuel stop?)
    (let next ((fuel 1) (acc '()))
      ;; run : (list verdict expired? last?)
      (let* ((run (guard (e (#t (list (list 'sweep-raised (describe e)) #f #t)))
                    (call-with-values (lambda () (run-at fuel))
                      (lambda (verdict expired)
                        (list verdict expired
                              (or (not expired) (stuck? verdict) (stop? verdict)))))))
             (acc (cons (list fuel (car run) (cadr run)) acc)))
        (if (or (caddr run) (= fuel max-fuel))
            (reverse acc)
            (next (+ fuel 1) acc))))))
