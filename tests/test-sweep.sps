#!r6rs
;;; SRFI-64 suite for (uv-sweep), the engine-sweep driver the suites share
;;; (#81): run-capped, capped and sweep-fuels, and what the step suites read
;;; from their sweeps (#103).
;;;
;;; Pure: the library imports no native code, and make check-purity runs
;;; this suite with the shim poisoned (PURE_TESTS), so the pure suites can
;;; use the driver too.
(import (rnrs)
        (srfi :64)
        (uv-sweep)
        ;; The engine census reads the suites' sources; the rows for what a
        ;; run leaves behind set interrupts and print.
        (only (chezscheme) directory-list with-output-to-string get-thread-id
              disable-interrupts enable-interrupts))

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

;; run-capped* makes its change at each of the first CHANGES expiries, and
;; gives the call FUEL ticks between them: a call of 10,000 ticks at fuel
;; 1,000 expires ten times, and one of 2,500 twice. A driver that resumed
;; with resume-fuel after its first change would let both finish there, at
;; one change each.
(test-equal "run-capped* changes at each of the first CHANGES expiries, with FUEL ticks between them"
  '((3 #t) (2 #t))
  (map (lambda (ticks)
         (let ((changes 0))
           (let-values (((answer expired)
                         (run-capped* (lambda () (spin ticks)) 1000
                                      (lambda () (set! changes (+ changes 1)))
                                      3)))
             (list changes expired))))
       '(10000 2500)))

(test-equal "run-capped gives a call up after resume-cap resumes, answering the give-up and no value of the call's"
  (list (list 'stuck-after-resumes resume-cap) #t #t)
  (let-values (((answer expired)
                (run-capped (lambda () (spin outlasting)) 1 (lambda () #f))))
    (list answer expired (stuck? answer))))

(test-equal "stuck? is true of the give-up alone, and of one a verdict added evidence to"
  '(#t #t #f #f #f #f)
  (list (stuck? (list 'stuck-after-resumes resume-cap))
        (stuck? (list 'stuck-after-resumes resume-cap 'registered 1))
        (stuck? 'stuck)
        (stuck? '(stuck))
        (stuck? '(refused stuck-after-resumes))
        (stuck? #f)))

;; The caller's handlers are in effect inside the engine, so the caller's
;; guard sees the raised object itself.
(test-equal "run-capped raises to the caller's handler what the call raised"
  '(caught boom)
  (guard (e ((symbol? e) (list 'caught e))
            (#t (list 'caught-something-else e)))
    (run-capped (lambda () (spin 1000) (raise 'boom)) 1 (lambda () #f))
    'no-raise))

;; A continuable raise, a warning say, goes to the caller's handler, and the
;; call goes on with what the handler returns: a driver that caught it and
;; raised it again would end the call there.
(test-equal "run-capped lets a continuable raise resume the call with what the caller's handler returns"
  '(resumed went-on)
  (with-exception-handler
   (lambda (e) 'resumed)
   (lambda ()
     (let-values (((answer expired)
                   (run-capped (lambda ()
                                 (spin 1000)
                                 (list (raise-continuable 'note) 'went-on))
                               1 (lambda () #f))))
       answer))))

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

;; The stop predicate reads each verdict, and one that meets a verdict of a
;; shape it did not expect can raise. The sweep keeps the runs before it as
;; it does for a raise in a run.
(test-equal "sweep-fuels keeps the runs before a raise in its stop predicate, and ends with the raise"
  '((1 (verdict 1) #t) (2 (sweep-raised "stop-raised") #f))
  (sweep-fuels (expiring-until 100) 100
               (lambda (verdict)
                 (if (equal? verdict '(verdict 2)) (raise 'stop-raised) #f))))

;; --- what a sweep's runs say (#103) --------------------------------------------
;; Two sweeps whose first, second and last verdicts all differ, so a helper
;; that read another run, or the expired? column, answers something else.
;; beta has a list verdict at two fuels in a row, and a verdict again after
;; another came between.
(define sample-sweeps
  '((alpha (1 refused #t) (2 wrong #t) (3 untouched #f))
    (beta (1 dropped #t) (2 (left ((block 1))) #t) (3 (left ((block 1))) #t)
          (4 dropped #t) (5 (untouched extra) #f))))

(define (right? v) (and (memq v '(refused dropped untouched)) #t))

(test-equal "bad-runs answers each run its predicate does not accept, by sweep and fuel, in order"
  '((alpha 2 wrong) (beta 2 (left ((block 1)))) (beta 3 (left ((block 1))))
    (beta 5 (untouched extra)))
  (bad-runs right? sample-sweeps))

(test-equal "reach answers each sweep's first verdict and its last"
  '((alpha refused untouched) (beta dropped (untouched extra)))
  (reach sample-sweeps))

(test-equal "reach-any answers whether some run of each sweep had the verdict, lists included, and its last"
  '(((alpha #t untouched) (beta #f (untouched extra)))
    ((alpha #f untouched) (beta #t (untouched extra))))
  (list (reach-any 'wrong sample-sweeps)
        (reach-any '(left ((block 1))) sample-sweeps)))

(test-equal "expected-reach is each sweep beginning with the verdict given and ending untouched"
  '((alpha refused untouched) (beta refused untouched))
  (expected-reach sample-sweeps 'refused))

(test-equal "fuel-map joins each stretch of equal verdicts, lists included, and no others"
  '((dropped 1 1) ((left ((block 1))) 2 3) (dropped 4 4) ((untouched extra) 5 5))
  (fuel-map (cdr (assq 'beta sample-sweeps))))

(test-equal "report! prints each sweep's fuel map under its kind and name"
  (string-append
   "  [informational] split alpha: ((refused 1 1) (wrong 2 2) (untouched 3 3))\n"
   "  [informational] split beta: ((dropped 1 1) ((left ((block 1))) 2 3)"
   " (dropped 4 4) ((untouched extra) 5 5))\n")
  (with-output-to-string (lambda () (report! 'split sample-sweeps))))

(test-equal "untouched? is true of untouched, alone or with evidence after it, and of nothing else"
  '(#t #t #f #f #f)
  (map untouched? '(untouched (untouched extra) refused (refused untouched) #f)))

;; --- what a run must leave as it found it ------------------------------------
(test-equal "interrupts-enabled? answers whether interrupts are enabled, and leaves them so"
  '(#t #f #t)
  (let* ((on (interrupts-enabled?))
         (off (begin (disable-interrupts)
                     (let ((answer (interrupts-enabled?)))
                       (enable-interrupts)
                       answer))))
    (list on off (interrupts-enabled?))))

(test-equal "residue answers what each count gained or lost, and nothing for a count that held"
  '(((registry 1) (block -2)) ())
  (let ((before '((registry . 3) (handle . 2) (block . 5))))
    (list (residue before '((registry . 4) (handle . 2) (block . 3)))
          (residue before before))))

;; A balance before a run, and two a suite's (balance) could read after it.
(define before-run '((registry . 3) (block . 5)))
(define (as-before) before-run)
(define (one-block-more) '((registry . 3) (block . 6)))

(test-equal "checked-verdict answers the verdict, or why its run was not tidied before what it left"
  '(v (v left ((block 1))) (v finish lock-held))
  (list (checked-verdict 'v 'finished before-run as-before)
        (checked-verdict 'v 'finished before-run one-block-more)
        (checked-verdict 'v 'lock-held before-run one-block-more)))

;; A run that leaves interrupts disabled would defer every expiry after it,
;; so the verdict says so first, and the next run starts with them enabled.
(test-equal "checked-verdict answers interrupts left disabled before anything else, and enables them"
  '((interrupts-left-disabled v) #t)
  (let ((verdict (begin (disable-interrupts)
                        (checked-verdict 'v 'lock-held before-run one-block-more))))
    (list verdict (interrupts-enabled?))))

;; --- the threads a handoff names -----------------------------------------------
(test-equal "me is the thread the suite runs on, and other-thread another"
  '(#t #f #t)
  (list (eqv? me (get-thread-id)) (eqv? other-thread me) (fixnum? other-thread)))

;; --- the engine census -------------------------------------------------------
;; A change sweep that resumes its engine itself can resume it without a cap,
;; and a cap shows only on a call that never ends, which a correct build has
;; none of: test-dns's sweep, test-process's two spawn sweeps and
;; test-native's truncation scan all resumed without one until #81, with
;; every row green. So every engine the tests make is the driver's, or one
;; of the sweeps below, each bounded on its own: most stop an engine once
;; and then resume it once with a fixed budget, or drop it (test-loop's
;; refused-take-drop-sweep drops every run that expires, up to fuel 5000);
;; test-loop-claim's exit-split-run resumes one tick at a time up to its
;; own cap; and test-owner-refusal's handback-run stops it twice, resuming
;; it with one tick and then a fixed budget. A new engine fails this row by
;; name, as (file definition): port it to the driver, or list it here once
;; it has a bound of its own.
(define engine-sites-allowed
  '(("tests/stranded-exit-child.sps" first-slice)
    ("tests/test-async-fence.sps" send-then-close)
    ("tests/test-async-fence.sps" close-suspended)
    ("tests/test-constructors.sps" split-run)
    ("tests/test-constructors.sps" server-close-run)
    ("tests/test-constructors.sps" handoff-run)
    ("tests/test-constructors.sps" drop-run)
    ("tests/test-constructors.sps" loop-drop-run)
    ("tests/test-constructors.sps" cwl-drop-run)
    ("tests/test-handle-steps.sps" split-run)
    ("tests/test-handle-steps.sps" drop-run)
    ("tests/test-loop-claim.sps" exit-split-run)
    ("tests/test-loop-claim.sps" split-sweep)
    ("tests/test-loop-claim.sps" drop-sweep)
    ("tests/test-loop-threads.sps" lock-sweep)
    ("tests/test-loop.sps" refused-take-drop-sweep)
    ("tests/test-loop.sps" first-slice)
    ("tests/test-loop.sps" suspend-in-callback)
    ("tests/test-loop.sps" suspending-slice)
    ("tests/test-owner-refusal.sps" handback-run)
    ("tests/test-process-steps.sps" split-run)
    ("tests/test-process-steps.sps" drop-run)
    ("tests/test-process.sps" drop-run)
    ("tests/test-request-steps.sps" split-run)
    ("tests/test-request-steps.sps" drop-run)
    ("tests/test-request-steps.sps" cancel-run)
    ("tests/test-stream.sps" start-engine)
    ("tests/test-stream.sps" drop-run)
    ("tests/test-tcp.sps" start-then-start)
    ("tests/test-tcp.sps" start-then-close)
    ("tests/test-timer.sps" close-then-close)
    ;; The driver's own, which shows the census read the sources.
    ("tests/uv-sweep.sls" library)))

;; test-sources : -> (list-of string)
;; Every .sps and .sls file directly under tests/, sorted.
(define (test-sources)
  (define (source? n)
    (let ((len (string-length n)))
      (and (> len 4)
           (not (char=? (string-ref n 0) #\.))
           (member (substring n (- len 4) len) '(".sps" ".sls"))
           #t)))
  (map (lambda (n) (string-append "tests/" n))
       (list-sort string<? (filter source? (directory-list "tests")))))

(define (read-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form) (reverse forms) (loop (cons form forms))))))))

;; calls? : datum symbol -> boolean
;; Whether X calls NAME anywhere outside quoted data.
(define (calls? x name)
  (and (pair? x)
       (not (eq? (car x) 'quote))
       (or (eq? (car x) name)
           (let walk ((x x))
             (and (pair? x) (or (calls? (car x) name) (walk (cdr x))))))))

;; site-name : datum -> object
;; The name a top-level form defines, else its head.
(define (site-name form)
  (cond ((and (pair? form) (eq? (car form) 'define) (pair? (cdr form)))
         (let ((head (cadr form))) (if (pair? head) (car head) head)))
        ((pair? form) (car form))
        (else form)))

;; engine-sites : -> (list-of (list string object))
;; Each top-level form in the tests that calls make-engine, as (file name).
(define (engine-sites)
  (apply append
         (map (lambda (path)
                (map (lambda (form) (list path (site-name form)))
                     (filter (lambda (form) (calls? form 'make-engine))
                             (read-forms path))))
              (test-sources))))

(test-equal "every engine in the tests is the driver's, or a split or drop sweep listed here"
  engine-sites-allowed
  (engine-sites))

;; describe was copied into seven suites and libraries before #81, and the
;; step suites' sweep helpers into eight suites before #103; each now lives
;; in one library. A new copy of any name either library exports fails this
;; row by name, as (name file ...).
;; defines? : datum symbol -> boolean
;; Whether X defines NAME, as a procedure or a variable, anywhere outside
;; quoted data.
(define (defines? x name)
  (and (pair? x)
       (not (eq? (car x) 'quote))
       (or (and (eq? (car x) 'define) (pair? (cdr x))
                (eq? (if (pair? (cadr x)) (car (cadr x)) (cadr x)) name))
           (let walk ((x x))
             (and (pair? x) (or (defines? (car x) name) (walk (cdr x))))))))

;; exports : string -> (list-of symbol)
;; The names a library source exports: its first form's export clause.
(define (exports path)
  (cdr (caddr (car (read-forms path)))))

;; definers : (list-of symbol) -> (list-of (cons symbol (list-of string)))
(define (definers names)
  (map (lambda (name)
         (cons name
               (filter (lambda (path)
                         (exists (lambda (form) (defines? form name))
                                 (read-forms path)))
                       (test-sources))))
       names))

(test-equal "each name (uv-describe) and (uv-sweep) export is defined in its own library alone"
  '((describe "tests/uv-describe.sls")
    (resume-fuel "tests/uv-sweep.sls") (resume-cap "tests/uv-sweep.sls")
    (run-capped "tests/uv-sweep.sls") (run-capped* "tests/uv-sweep.sls")
    (capped "tests/uv-sweep.sls") (stuck? "tests/uv-sweep.sls")
    (sweep-fuels "tests/uv-sweep.sls") (bad-runs "tests/uv-sweep.sls")
    (reach "tests/uv-sweep.sls") (reach-any "tests/uv-sweep.sls")
    (expected-reach "tests/uv-sweep.sls") (fuel-map "tests/uv-sweep.sls")
    (report! "tests/uv-sweep.sls") (untouched? "tests/uv-sweep.sls")
    (interrupts-enabled? "tests/uv-sweep.sls") (residue "tests/uv-sweep.sls")
    (checked-verdict "tests/uv-sweep.sls") (me "tests/uv-sweep.sls")
    (other-thread "tests/uv-sweep.sls"))
  (definers (append (exports "tests/uv-describe.sls")
                    (exports "tests/uv-sweep.sls"))))

(test-end "sweep")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
