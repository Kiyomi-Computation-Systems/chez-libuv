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
;;; It also holds what the step suites read from their sweeps (#103): which
;;; runs were wrong, how far each sweep reached, its fuel map, and what a
;;; run left behind. Each step suite used to carry its own copy of these,
;;; and the copies drifted: bad-runs took its arguments in two orders, and
;;; runs had two shapes. tests/test-sweep.sps holds every one, and fails a
;;; new copy of any name this library exports.
;;;
;;; PURE: (rnrs) and a few Chez primitives, none native, so the pure suites
;;; can use it too (PURE_TESTS; make check-purity holds it).
(library (uv-sweep)
  (export resume-fuel resume-cap run-capped run-capped* capped stuck? sweep-fuels
          bad-runs reach reach-any expected-reach fuel-map report! untouched?
          interrupts-enabled? residue checked-verdict me other-thread)
  (import (rnrs)
          (only (chezscheme) make-engine get-thread-id
                disable-interrupts enable-interrupts)
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
  ;; changes nothing after it; at MAX-FUEL or past it, so that a sweep that
  ;; skipped it fails a row instead of hanging; at a run given up, which would
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
        (if (or (caddr run) (>= fuel max-fuel))
            (reverse acc)
            (next (+ fuel 1) acc)))))

  ;; --- what a sweep's runs say ----------------------------------------------
  ;; A sweep is (name . runs), each run (fuel verdict expired?) as
  ;; sweep-fuels makes it, and sweeps are a list of them.

  ;; bad-runs : (verdict -> boolean) sweeps -> (list-of (list name fuel verdict))
  ;; Every run whose verdict GOOD? does not accept, in order.
  (define (bad-runs good? sweeps)
    (apply append
           (map (lambda (s)
                  (map (lambda (run) (list (car s) (car run) (cadr run)))
                       (filter (lambda (run) (not (good? (cadr run)))) (cdr s))))
                sweeps)))

  (define (last-verdict runs) (cadr (list-ref runs (- (length runs) 1))))

  ;; reach : sweeps -> (list-of (list name first last))
  ;; Each sweep's first verdict and its last. A row that looks for bad runs
  ;; and finds none says nothing unless each sweep caught its verb before
  ;; its checks (FIRST) and ran it to the end (LAST, a run no expiry
  ;; reached).
  (define (reach sweeps)
    (map (lambda (s) (list (car s) (cadr (cadr s)) (last-verdict (cdr s))))
         sweeps))

  ;; reach-any : verdict sweeps -> (list-of (list name boolean last))
  ;; Whether some run of each sweep answered VERDICT, and its last verdict:
  ;; reach for a sweep whose first runs end before the verb's checks, as
  ;; test-owner-refusal's hand-back does.
  (define (reach-any verdict sweeps)
    (map (lambda (s)
           (list (car s)
                 (exists (lambda (run) (equal? (cadr run) verdict)) (cdr s))
                 (last-verdict (cdr s))))
         sweeps))

  ;; expected-reach : sweeps verdict -> (list-of (list name verdict untouched))
  ;; The reach of sweeps that each began with FIRST and ended untouched.
  (define (expected-reach sweeps first)
    (map (lambda (s) (list (car s) first 'untouched)) sweeps))

  ;; fuel-map : runs -> list, e.g. ((refused 1 9) (untouched 10 10)): each
  ;; stretch of equal verdicts with its first and last fuel, for the record.
  (define (fuel-map runs)
    (let collect ((runs runs) (acc '()))
      (cond ((null? runs) (reverse acc))
            ((and (pair? acc) (equal? (caar acc) (cadar runs)))
             (collect (cdr runs)
                      (cons (list (caar acc) (cadar acc) (caar runs)) (cdr acc))))
            (else (collect (cdr runs)
                           (cons (list (cadar runs) (caar runs) (caar runs)) acc))))))

  ;; report! : symbol sweeps -> unspecified
  ;; Prints each sweep's fuel map, as  [informational] KIND NAME: MAP.
  (define (report! kind sweeps)
    (for-each (lambda (s)
                (display "  [informational] ") (display kind) (display " ")
                (display (car s)) (display ": ")
                (write (fuel-map (cdr s))) (newline))
              sweeps))

  ;; untouched? : verdict -> boolean
  ;; The verdict of a run no expiry reached, alone or with evidence after it.
  (define (untouched? verdict)
    (or (eq? verdict 'untouched)
        (and (pair? verdict) (eq? (car verdict) 'untouched))))

  ;; --- what a run must leave as it found it ------------------------------------

  ;; interrupts-enabled? : -> boolean
  ;; Whether this thread runs with interrupts enabled. A run that leaves them
  ;; disabled defers every engine expiry and collection after it.
  (define (interrupts-enabled?)
    (disable-interrupts)
    (zero? (enable-interrupts)))

  ;; residue : balance balance -> (list-of (list name delta))
  ;; What changed from BEFORE to AFTER, each a balance: a list of
  ;; (name . count) in a fixed order, as a suite's own (balance) reads the
  ;; registry, the debug counters and whatever else it counts. '() when
  ;; nothing did.
  (define (residue before after)
    (filter (lambda (x) x)
            (map (lambda (b a)
                   (and (not (= (cdr b) (cdr a)))
                        (list (car b) (- (cdr a) (cdr b)))))
                 before after)))

  ;; checked-verdict : verdict object balance (-> balance) -> verdict
  ;; VERDICT, or what its run left behind with it. FINISHED is 'finished, or
  ;; why the run could not be tidied. What the run left is the residue from
  ;; BEFORE to what BALANCE reads here, once the arguments are in hand: the
  ;; run's tidying is often one of them, and Chez evaluates arguments right
  ;; to left, so a balance read in an argument could come before it.
  ;; Interrupts left disabled are enabled again, so the next run starts
  ;; clean.
  (define (checked-verdict verdict finished before balance)
    (let ((left (residue before (balance))))
      (cond ((not (interrupts-enabled?))
             (enable-interrupts)
             (list 'interrupts-left-disabled verdict))
            ((not (eq? finished 'finished)) (list verdict 'finish finished))
            ((pair? left) (list verdict 'left left))
            (else verdict))))

  ;; --- the threads a handoff names ---------------------------------------------
  ;; me is the thread a suite runs on: Chez instantiates a program's
  ;; libraries on its main thread, before its body. other-thread is another
  ;; thread's id, for a loop handed to it: no thread runs the loop, but its
  ;; owner is no longer this one.
  (define me (get-thread-id))
  (define other-thread (+ me 1)))
