#!r6rs
;;; SRFI-64 suite for the claim a loop's runner makes on it (#78).
;;;
;;; uv-run marks its loop running, and every verb that would run, close or
;;; tear the loop down refuses a loop so marked ('loop-running). Until #78
;;; that mark was a plain field, checked and then set as two steps, and so
;;; were uv-loop-close!'s and uv-loop-teardown!'s checks of it. Two threads
;;; could both pass the check and both run uv_run on one uv_loop_t: two of
;;; the loop's callbacks ran at once on two threads, `invalid memory
;;; reference` was raised out of uv-run and left the loop marked running for
;;; good, or both threads spun in libuv's timer heap for good. A close or a
;;; teardown that passed its check while another thread entered uv_run freed
;;; the loop, or closed its handles, under that thread.
;;;
;;; Each of those verbs now claims the loop first: the mark is taken with a
;;; compare-and-set, in one interrupt-free step, and whoever takes it is the
;;; only one inside until it is given back. The rows below hold that:
;;; - from another thread, while this thread is inside a run: each verb is
;;;   refused, and the refusal leaves this thread's claim and ownership as
;;;   they were;
;;; - every way out of a verb that took the claim gives it back, a refusal
;;;   by libuv or a callback's raise included;
;;; - two threads that race the verbs on one loop: every call is run or
;;;   refused, no two of the loop's callbacks ever run at once, and the
;;;   claim is free once both are done.
;;;
;;; The races need two threads that really contended for the loop, so each
;;; has a precondition row: each thread saw the other's progress move, and
;;; was refused at least once. A thread past its own rounds goes on until
;;; both hold, or the other has finished, bounded by race-time-cap and never
;;; by a count of its own (#74). Every wait on another thread gives up at
;;; that cap too, so a broken build that hangs two threads in uv_run fails
;;; its rows by name instead of hanging the suite. Valgrind runs one thread
;;; at a time, so under it the races are skipped (CHEZ_LIBUV_UNDER_VALGRIND).
;;;
;;; NOT pure: it runs loops. Never add this to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop) (libuv handle) (libuv timer)
        (libuv private conditions)
        (only (libuv private native) current-thread-id)
        (only (libuv private handles) loop-running? loop-owner-thread)
        (only (uv-evidence) describe print-actual-on-failure!)
        (only (chezscheme) fork-thread getenv make-list real-time make-time make-engine
              box unbox box-cas! set-box!
              make-mutex make-condition with-mutex condition-wait
              condition-broadcast))

(define runner (test-runner-simple))
(test-runner-current runner)

;; Each row returns its evidence when it fails, so print that too.
(print-actual-on-failure! runner)

(test-begin "loop-claim")

;; --- plumbing ----------------------------------------------------------------

;; evidence : object -> object
;; A raise as the rows below expect it, or else its description.
(define (evidence e)
  (cond ((uv-invalid-argument? e)
         (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
        ((uv-handle-closed? e) (list 'handle-closed (uv-handle-closed-kind e)))
        ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e)))
        ((uv-callback-error? e) (list 'callback-error (uv-callback-error-cause e)))
        (else (describe e))))

(define (marked loop) (if (loop-running? loop) 'running 'not-running))

(define (refused-running? e)
  (and (uv-invalid-argument? e)
       (eq? (uv-invalid-argument-reason e) 'loop-running)))

;; How long, in milliseconds, any wait on another thread lasts. It bounds
;; only how long a broken build takes to show itself; on a correct build
;; every wait ends long before it.
(define race-time-cap 10000)

(define ten-ms (make-time 'time-duration 10000000 0))

;; on-other-thread : (-> object) -> object
;; THUNK's value on a new thread, (raised evidence) if it raised, or
;; 'never-ended if it had not ended within race-time-cap.
(define (on-other-thread thunk)
  (let ((m (make-mutex)) (cv (make-condition)) (done #f) (result 'never-ended))
    (fork-thread
     (lambda ()
       (let ((v (guard (e (#t (list 'raised (evidence e)))) (thunk))))
         (with-mutex m
           (set! result v)
           (set! done #t)
           (condition-broadcast cv)))))
    (let ((end (+ (real-time) race-time-cap)))
      (with-mutex m
        (let wait ()
          (unless (or done (> (real-time) end))
            (condition-wait cv m ten-ms)
            (wait)))
        result))))

;; inside-a-run : uv-loop (-> object) -> object
;; Runs LOOP on this thread, calls PROBE from inside one of its callbacks,
;; and answers PROBE's value, or (raised evidence) if the run raised.
(define (inside-a-run loop probe)
  (let ((answer 'never-called)
        (t (make-uv-timer loop)))
    (uv-timer-start! t (lambda (t) (set! answer (probe)) (uv-close! t)) 0 0)
    (guard (e (#t (list 'raised (evidence e))))
      (uv-run loop 'default)
      answer)))

;; tear-down : uv-loop -> (or 'torn-down list)
(define (tear-down loop)
  (guard (e (#t (list 'raised (evidence e))))
    (uv-loop-teardown! loop)
    'torn-down))

;; --- from another thread, while this thread runs the loop -------------------

;; refused-from-another-thread : uv-loop (uv-loop -> object) -> list
;; From inside a run of LOOP on this thread, VERB on another thread: how
;; it was refused, whether this thread still owns LOOP and whether LOOP is
;; still marked running, both seen inside the run; then, once the run is
;; over, whether LOOP is marked running, and its teardown.
(define (refused-from-another-thread verb)
  (let* ((loop (make-uv-loop))
         (inside (inside-a-run
                  loop
                  (lambda ()
                    (let ((other (on-other-thread
                                  (lambda ()
                                    (guard (e (#t (evidence e)))
                                      (verb loop)
                                      'accepted)))))
                      (list other
                            (if (eqv? (loop-owner-thread loop) (current-thread-id))
                                'owner-kept
                                'owner-moved)
                            (marked loop)))))))
    (list inside (marked loop) (tear-down loop))))

(test-equal "a uv-run from another thread, while this thread runs the loop, is refused and leaves this thread's claim and ownership"
  '(((uv-run loop-running) owner-kept running) not-running torn-down)
  (refused-from-another-thread (lambda (loop) (uv-run loop 'nowait))))

(test-equal "a uv-loop-close! from another thread, while this thread runs the loop, is refused and leaves this thread's claim and ownership"
  '(((uv-loop-close! loop-running) owner-kept running) not-running torn-down)
  (refused-from-another-thread uv-loop-close!))

(test-equal "a uv-loop-teardown! from another thread, while this thread runs the loop, is refused and leaves this thread's claim and ownership"
  '(((uv-loop-teardown! loop-running) owner-kept running) not-running torn-down)
  (refused-from-another-thread uv-loop-teardown!))

;; A close only claims the loop; it does not take it over, as a run and a
;; teardown do. A close refused 'EBUSY on another thread leaves the loop
;; with the thread that runs it.
(test-equal "a uv-loop-close! refused EBUSY on another thread leaves this thread the owner"
  '((errno EBUSY) owner-kept torn-down)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop))
         (other (on-other-thread
                 (lambda ()
                   (guard (e (#t (evidence e)))
                     (uv-loop-close! loop)
                     'closed))))
         (owner (if (eqv? (loop-owner-thread loop) (current-thread-id))
                    'owner-kept
                    'owner-moved)))
    (list other owner (tear-down loop))))

;; uv-run refuses a loop that is running before it looks at the mode, as it
;; did before the claim.
(test-equal "a uv-run with an unknown mode, on a loop this thread is running, is refused 'loop-running"
  '(uv-run loop-running)
  (let ((loop (make-uv-loop)))
    (let ((answer (inside-a-run
                   loop
                   (lambda ()
                     (guard (e (#t (evidence e)))
                       (uv-run loop 'no-such-mode)
                       'accepted)))))
      (tear-down loop)
      answer)))

;; --- every way out of a claim gives it back ---------------------------------

(test-equal "a uv-run whose callback raised gives the claim back: the raise reaches the caller, and the loop runs again"
  '((raised (callback-error boom)) not-running ran torn-down)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop)))
    (uv-timer-start! t (lambda (t) (uv-close! t) (raise 'boom)) 0 0)
    (let* ((first (guard (e (#t (list 'raised (evidence e))))
                    (uv-run loop 'default)
                    'returned))
           (mark (marked loop))
           (again (guard (e (#t (evidence e))) (uv-run loop 'nowait) 'ran)))
      (list first mark again (tear-down loop)))))

(test-equal "a uv-loop-close! refused EBUSY gives the claim back: the loop runs again"
  '((errno EBUSY) not-running ran torn-down)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop)))
    (let* ((first (guard (e (#t (evidence e))) (uv-loop-close! loop) 'closed))
           (mark (marked loop))
           (again (guard (e (#t (evidence e))) (uv-run loop 'nowait) 'ran)))
      (list first mark again (tear-down loop)))))

(test-equal "a uv-loop-teardown! that raises a close callback's error gives the claim back"
  '((raised (callback-error boom)) not-running closed)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop)))
    (uv-close! t (lambda () (raise 'boom)))
    (let ((first (tear-down loop)))
      (list first (marked loop) (if (uv-loop-open? loop) 'open 'closed)))))

;; A teardown whose drain never empties the loop gives up at its bound and
;; raises from deep in its work. Here a close callback starts a timer the
;; teardown never saw, which repeats every millisecond and stops each run,
;; so every drain run ends with work left.
(test-equal "a uv-loop-teardown! that gives up at its drain bound gives the claim back"
  '(drain-bound not-running torn-down)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop))
         (late #f))
    (uv-close! t (lambda ()
                   (set! late (make-uv-timer loop))
                   (uv-timer-start! late (lambda (t) (uv-stop! loop)) 1 1)))
    (let* ((first (guard (e ((and (uv-error? e) (message-condition? e)
                                  (equal? (condition-message e)
                                          "loop still had work after the drain bound"))
                             'drain-bound)
                            (#t (list 'raised (evidence e))))
                    (uv-loop-teardown! loop)
                    'torn-down))
           (mark (marked loop)))
      (when late (uv-close! late))
      (list first mark (tear-down loop)))))

(test-equal "a uv-loop-close! of a closed loop is still a quiet no-op, with no claim left"
  '(closed-again not-running)
  (let ((loop (make-uv-loop)))
    (uv-loop-close! loop)
    (let ((again (guard (e (#t (evidence e))) (uv-loop-close! loop) 'closed-again)))
      (list again (marked loop)))))

;; A teardown takes the loop over, as its drain's uv-run always did. So a
;; teardown on another thread whose close callback escapes leaves the loop
;; claimed by that thread, and owned by it, like any run left from a
;; callback: call-with-uv-loop's exit asks the owner whether its own thread
;; left the mark.
(test-equal "a teardown on another thread whose close callback escapes leaves the loop claimed, and owned by that thread"
  '(escaped running owned-by-that-thread)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop))
         (other (on-other-thread
                 (lambda ()
                   (list (call/cc
                          (lambda (k)
                            (uv-close! t (lambda () (k 'escaped)))
                            (uv-loop-teardown! loop)
                            'returned))
                         (current-thread-id))))))
    (if (and (pair? other) (number? (cadr other)))
        (list (car other)
              (marked loop)
              (if (eqv? (loop-owner-thread loop) (cadr other))
                  'owned-by-that-thread
                  'owned-by-another))
        other)))

;; --- a verb split by an engine ------------------------------------------------

;; The claim's take and its open check are one step, so no engine of the
;; claiming thread comes between them. A uv-run an engine suspends before
;; its claim, while the engine's own thread closes or tears the loop down,
;; must find the loop closed when it resumes, never run the freed one; one
;; suspended after its claim keeps the loop from the close. Until #78 a run
;; suspended between its check of the mark and setting it ran the loop the
;; close had freed: `invalid memory reference`. Each sweep runs a uv-run
;; 'nowait in an engine with fuel 1, 2, ..., and at its first expiry calls
;; VERB on the loop, then resumes the run.

;; The most fuel a sweep tries before it gives up on a run that finishes
;; with no expiry.
(define split-sweep-cap 20000)

;; refused-claim? : object -> boolean
;; Whether OUTCOME is a refusal of the claim another call held.
(define (refused-claim? outcome)
  (and (pair? outcome) (pair? (cdr outcome)) (eq? (cadr outcome) 'loop-running)))

;; the-run : uv-loop -> object
;; The run each sweep splits: 'ran, or how it was refused.
(define (the-run loop)
  (guard (e (#t (evidence e)))
    (uv-run loop 'nowait)
    'ran))

;; ends-agree : object object -> (or 'accepted 'refused #f)
;; For a close or a teardown: it was accepted and the resumed run then
;; refused the closed loop, or it was refused the claim the run held and
;; the run went on; #f if neither.
(define (ends-agree verb-outcome run-outcome)
  (cond ((and (eq? verb-outcome 'accepted) (equal? run-outcome '(handle-closed loop)))
         'accepted)
        ((and (refused-claim? verb-outcome) (eq? run-outcome 'ran)) 'refused)
        (else #f)))

;; accepted : (uv-loop -> object) -> (uv-loop -> 'accepted)
(define (accepted verb) (lambda (loop) (verb loop) 'accepted))

;; split-sweep : (-> uv-loop) (uv-loop -> object) (uv-loop -> object)
;;               (object object -> (or 'accepted 'refused 'after #f))
;;               -> (list wrong accepted refused reached)
;; Splits (RUN loop) at each fuel, calling VERB at the expiry (its value,
;; or how it was refused, is its outcome), and asks
;; (JUDGE verb-outcome run-outcome) whether the two agree: 'accepted or
;; 'refused for a split before the run's claim or during it, 'after for one
;; after it, and #f if they do not. Answers the
;; fuels whose outcomes did not, with them; how many expiries had VERB
;; accepted and how many had it refused; and whether a run finished with no
;; expiry before split-sweep-cap.
(define (split-sweep make-loop verb run judge)
  (let sweep ((fuel 1) (wrong '()) (accepted 0) (refused 0))
    (if (> fuel split-sweep-cap)
        (list (reverse wrong) accepted refused 'cap-reached)
        (let* ((loop (make-loop))
               (outcome
                ((make-engine (lambda () (run loop)))
                 fuel
                 (lambda (ticks value) 'finished)
                 (lambda (resume)
                   (let* ((verb-outcome (guard (e (#t (evidence e)))
                                          (verb loop)))
                          (run-outcome (resume 100000000
                                               (lambda (ticks value) value)
                                               (lambda (more) 'expired-again))))
                     (list verb-outcome run-outcome))))))
          (when (uv-loop-open? loop) (tear-down loop))
          (if (eq? outcome 'finished)
              (list (reverse wrong) accepted refused 'reached)
              (case (judge (car outcome) (cadr outcome))
                ((accepted) (sweep (+ fuel 1) wrong (+ accepted 1) refused))
                ((refused) (sweep (+ fuel 1) wrong accepted (+ refused 1)))
                ((#f) (sweep (+ fuel 1) (cons (cons fuel outcome) wrong)
                             accepted refused))
                (else (sweep (+ fuel 1) wrong accepted refused))))))))

(define (loop-with-timer)
  (let ((loop (make-uv-loop)))
    (make-uv-timer loop)
    loop))

(define close-split
  (split-sweep make-uv-loop (accepted uv-loop-close!) the-run ends-agree))
(define teardown-split
  (split-sweep loop-with-timer (accepted uv-loop-teardown!) the-run ends-agree))

;; A run's deferred errors are its own: the run resets them once it holds
;; the claim. Each loop here has three timers due at once whose callbacks
;; raise, so whichever run fires them raises the first and defers the other
;; two. VERB is a run of its own at the expiry. Split before the claim, VERB
;; fires them, and the resumed run fires nothing, so it must defer nothing.
;; Split during the claim, VERB is refused, and the resumed run fires them
;; and defers two. Split after the claim is given back, VERB finds nothing
;; to fire, and its own reset is what the resumed run's caller reads. A run
;; that reset its errors before the claim, and was split between the reset
;; and the claim, kept VERB's two.
(define (loop-with-raising-timers)
  (let ((loop (make-uv-loop)))
    (let arm ((i 0))
      (when (< i 3)
        (uv-timer-start! (make-uv-timer loop) (lambda (t) (uv-close! t) (raise i)) 0 0)
        (arm (+ i 1))))
    loop))

;; run-and-its-deferrals : uv-loop -> (list object exact-nonnegative-integer)
(define (run-and-its-deferrals loop)
  (list (guard (e ((uv-callback-error? e) 'raised) (#t (evidence e)))
          (uv-run loop 'nowait)
          'ran)
        (length (uv-loop-deferred-errors loop))))

(define (deferrals-agree verb-outcome run-outcome)
  (cond ((and (equal? verb-outcome '(raised 2)) (equal? run-outcome '(ran 0))) 'accepted)
        ((and (refused-claim? verb-outcome) (equal? run-outcome '(raised 2))) 'refused)
        ((and (equal? verb-outcome '(ran 0)) (pair? run-outcome)
              (eq? (car run-outcome) 'raised))
         'after)
        (else #f)))

(define deferral-split
  (split-sweep loop-with-raising-timers
               (lambda (loop)
                 (let ((outcome (run-and-its-deferrals loop)))
                   (if (pair? (car outcome)) (car outcome) outcome)))
               run-and-its-deferrals
               deferrals-agree))

(define (split-verdict s) (list (car s) (cadddr s)))

(define (split-seen s)
  (list (if (positive? (cadr s)) 'accepted-somewhere 'never-accepted)
        (if (positive? (caddr s)) 'refused-somewhere 'never-refused)))

(test-equal "a uv-run split by an engine while its thread closes the loop: at every expiry, the close and the resumed run agree"
  '(() reached)
  (split-verdict close-split))

(test-equal "precondition: the close split the run both before its claim and while it held it"
  '(accepted-somewhere refused-somewhere)
  (split-seen close-split))

(test-equal "a uv-run split by an engine while its thread tears the loop down: at every expiry, the teardown and the resumed run agree"
  '(() reached)
  (split-verdict teardown-split))

(test-equal "precondition: the teardown split the run both before its claim and while it held it"
  '(accepted-somewhere refused-somewhere)
  (split-seen teardown-split))

(test-equal "a uv-run split by an engine while its thread runs the loop: at every expiry, the resumed run defers only its own callbacks' errors"
  '(() reached)
  (split-verdict deferral-split))

(test-equal "precondition: the other run split the run both before its claim and while it held it"
  '(accepted-somewhere refused-somewhere)
  (split-seen deferral-split))

;; --- races on one loop ------------------------------------------------------

;; The loop each race runs: timers that fire every millisecond, whose
;; callback notes how many of the loop's callbacks are running at once.
(define timers-per-loop 20)

;; atomic-add! : box integer -> integer
(define (atomic-add! b d)
  (let retry ()
    (let ((v (unbox b)))
      (if (box-cas! b v (+ v d)) (+ v d) (retry)))))

;; atomic-max! : box integer -> unspecified
(define (atomic-max! b n)
  (let retry ()
    (let ((v (unbox b)))
      (when (and (> n v) (not (box-cas! b v n)))
        (retry)))))

;; make-witnessed-loop : -> (values uv-loop box)
;; A loop with timers-per-loop repeating timers, and the box that holds the
;; most of its callbacks seen running at once: 0 until one has run.
(define (make-witnessed-loop)
  (let ((loop (make-uv-loop))
        (inside (box 0))
        (most (box 0)))
    (define (on-timeout t)
      (atomic-max! most (atomic-add! inside 1))
      (let spin ((i 0)) (when (< i 2000) (spin (+ i 1))))
      (atomic-add! inside -1))
    (let make ((i 0))
      (when (< i timers-per-loop)
        (uv-timer-start! (make-uv-timer loop) on-timeout 1 1)
        (make (+ i 1))))
    (values loop most)))

;; race-state: what the two threads of one race share. PROGRESS holds the
;; rounds each has done, REFUSED how often each was refused 'loop-running,
;; MOVED whether each saw the other's progress move, VERDICTS what each
;; thread's work answered ('unset until it has), and DEADLINE the cap.
(define-record-type race-state
  (fields progress refused moved verdicts deadline)
  (protocol
   (lambda (new)
     (lambda ()
       (new (vector 0 0) (vector 0 0) (vector #f #f) (vector 'unset 'unset)
            (+ (real-time) race-time-cap))))))

(define (finished? state i)
  (not (eq? (vector-ref (race-state-verdicts state) i) 'unset)))

;; note-progress! : race-state 0|1 exact-nonnegative-integer boolean -> unspecified
;; Round I of thread ME is done, and was refused when REFUSED?.
(define (note-progress! state me i refused?)
  (let ((progress (race-state-progress state)))
    (when refused?
      (vector-set! (race-state-refused state) me
                   (+ 1 (vector-ref (race-state-refused state) me))))
    (vector-set! progress me (+ i 1))))

;; go-on? : race-state 0|1 exact-nonnegative-integer exact-nonnegative-integer
;;          object -> boolean
;; Whether thread ME does round I. SEEN is the other's progress when ME
;; last looked; a change marks it moved. Past ROUNDS, ME goes on until each
;; thread has seen the other move and been refused, or the other has
;; finished, or the cap has passed.
(define (go-on? state me rounds i seen)
  (let* ((other (- 1 me))
         (moved (race-state-moved state))
         (refused (race-state-refused state)))
    (unless (= (vector-ref (race-state-progress state) other) seen)
      (vector-set! moved me #t))
    (or (< i rounds)
        (and (not (finished? state other))
             (not (and (vector-ref moved 0) (vector-ref moved 1)
                       (positive? (vector-ref refused 0))
                       (positive? (vector-ref refused 1))))
             (<= (real-time) (race-state-deadline state))))))

;; run-pair : race-state (race-state 0|1 -> object) (race-state 0|1 -> object)
;;            -> (list verdict verdict)
;; Runs WORK-0 and WORK-1 on two new threads, each first waiting (to the
;; cap) for the other to start, and waits for both until twice the cap.
(define (run-pair state work-0 work-1)
  (let ((m (make-mutex)) (cv (make-condition))
        (started (vector #f #f))
        (verdicts (race-state-verdicts state)))
    (define (run me work)
      (vector-set! started me #t)
      (let wait ()
        (unless (or (vector-ref started (- 1 me))
                    (> (real-time) (race-state-deadline state)))
          (wait)))
      (let ((v (guard (e (#t (list 'raised (evidence e)))) (work state me))))
        (with-mutex m
          (vector-set! verdicts me v)
          (condition-broadcast cv))))
    (fork-thread (lambda () (run 0 work-0)))
    (fork-thread (lambda () (run 1 work-1)))
    (let ((end (+ (race-state-deadline state) race-time-cap)))
      (with-mutex m
        (let wait ()
          (unless (or (and (finished? state 0) (finished? state 1))
                      (> (real-time) end))
            (condition-wait cv m ten-ms)
            (wait)))
        (list (if (finished? state 0) (vector-ref verdicts 0) 'never-ended)
              (if (finished? state 1) (vector-ref verdicts 1) 'never-ended))))))

(define (moved-pair state)
  (map (lambda (b) (if b 'moved 'still)) (vector->list (race-state-moved state))))

(define (refused-pair state)
  (map (lambda (n) (if (positive? n) 'refused 'never-refused))
       (vector->list (race-state-refused state))))

(define (stuck? verdicts) (memq 'never-ended verdicts))

;; A race whose thread never ended leaves that thread inside the loop for
;; good. No race after it can be trusted, so the rest are skipped and their
;; rows fail with this.
(define stuck #f)

;; --- two threads run one loop ------------------------------------------------

(define run-rounds 20000)

;; run-rounds-work : uv-loop -> (race-state 0|1 -> 'ok)
;; Each round is a uv-run 'nowait, which either runs the loop or is refused
;; 'loop-running; any other raise ends the thread with it.
(define (run-rounds-work loop)
  (lambda (state me)
    (let next ((i 0) (seen (vector-ref (race-state-progress state) (- 1 me))))
      (if (go-on? state me run-rounds i seen)
          (let* ((seen-now (vector-ref (race-state-progress state) (- 1 me)))
                 (refused? (guard (e ((refused-running? e) #t))
                             (uv-run loop 'nowait)
                             #f)))
            (note-progress! state me i refused?)
            (next (+ i 1) seen-now))
          'ok))))

;; shared-run-race : -> list
;; (verdicts most-at-once after moved refused): the two threads' verdicts,
;; the most callbacks seen running at once, what this thread's own run and
;; teardown of the loop gave once both threads were done, and the
;; precondition pairs.
(define (shared-run-race)
  (let-values (((loop most) (make-witnessed-loop)))
    (let* ((state (make-race-state))
           (verdicts (run-pair state (run-rounds-work loop) (run-rounds-work loop))))
      (if (stuck? verdicts)
          (begin (set! stuck verdicts)
                 (list verdicts (unbox most) 'stuck (moved-pair state) (refused-pair state)))
          (let* ((ran (guard (e (#t (evidence e))) (uv-run loop 'nowait) 'ran))
                 (after (list ran (tear-down loop))))
            (list verdicts (unbox most) after (moved-pair state) (refused-pair state)))))))

;; --- one thread runs the loop, another closes or tears it down --------------

;; Each race makes this many loops, one after another, or stops at the cap.
;; A close or a teardown gets one chance per loop to come between the
;; runner's check and its run, so the race wants many loops.
(define end-race-loops 200)

;; runner-work : uv-loop -> (race-state 0|1 -> list)
;; uv-run 'nowait until the loop is closed under it: each call runs the
;; loop, is refused 'loop-running while the other thread holds the claim,
;; or is refused &uv-handle-closed once the loop is gone, which ends the
;; thread with (closed-out). Any other raise ends it with that.
(define (runner-work loop)
  (lambda (state me)
    (let next ((i 0))
      (cond
       ((> (real-time) (race-state-deadline state)) '(never-closed))
       ((guard (e ((uv-handle-closed? e) #t)
                  ((refused-running? e) #f))
          (uv-run loop 'nowait)
          #f)
        '(closed-out))
       (else (note-progress! state me i #f) (next (+ i 1)))))))

;; ender-work : uv-loop (uv-loop -> object) -> (race-state 0|1 -> list)
;; Once the runner has run the loop, VERB on it until it is accepted:
;; (accepted refusals), with how many times it was refused 'loop-running.
(define (ender-work loop verb)
  (lambda (state me)
    (let wait ()
      (when (and (zero? (vector-ref (race-state-progress state) (- 1 me)))
                 (<= (real-time) (race-state-deadline state)))
        (wait)))
    (let next ((refusals 0))
      (cond
       ((> (real-time) (race-state-deadline state)) (list 'never-accepted refusals))
       ((guard (e ((refused-running? e) #f))
          (verb loop)
          #t)
        (list 'accepted refusals))
       (else
        (vector-set! (race-state-refused state) me (+ refusals 1))
        (next (+ refusals 1)))))))

;; end-race : (uv-loop -> object) boolean -> list
;; (verdict contended): the first loop whose race went wrong, as
;; (verdicts most-at-once mark open?), or 'all-ok; and how many loops' VERB
;; was refused at least once. Each loop has timers when WITH-TIMERS?, and
;; none otherwise, so that uv-loop-close! can close it.
(define (end-race verb with-timers?)
  (let next ((n 0) (contended 0))
    (if (= n end-race-loops)
        (list 'all-ok contended)
        (let-values (((loop most) (if with-timers?
                                      (make-witnessed-loop)
                                      (values (make-uv-loop) (box 1)))))
          (let* ((state (make-race-state))
                 (verdicts (run-pair state (runner-work loop) (ender-work loop verb)))
                 (ender (cadr verdicts))
                 (contended (if (and (pair? ender) (eq? (car ender) 'accepted)
                                     (pair? (cdr ender)) (positive? (cadr ender)))
                                (+ contended 1)
                                contended))
                 (outcome (list verdicts (unbox most) (marked loop)
                                (if (uv-loop-open? loop) 'open 'closed))))
            (cond
             ((stuck? verdicts) (set! stuck verdicts) (list outcome contended))
             ((and (equal? (car verdicts) '(closed-out))
                   (pair? ender) (eq? (car ender) 'accepted)
                   (memv (unbox most) (if with-timers? '(0 1) '(1)))
                   (eq? (marked loop) 'not-running)
                   (not (uv-loop-open? loop)))
              (next (+ n 1) contended))
             (else (list outcome contended))))))))

;; --- the races ---------------------------------------------------------------

(define skip-races? (getenv "CHEZ_LIBUV_UNDER_VALGRIND"))

(define race-runs 3)

(define (unless-stuck thunk)
  (if stuck (list 'skipped-after-stuck stuck) (thunk)))

(if skip-races?
    (begin
      (display "  [informational] the races on one loop:")
      (display " skipped under Valgrind, which runs one thread at a time")
      (newline))
    (begin
      (let ((runs (let collect ((i 0) (acc '()))
                    (if (= i race-runs)
                        (reverse acc)
                        (collect (+ i 1)
                                 (cons (unless-stuck shared-run-race) acc))))))
        (define (field k) (map (lambda (r) (if (= (length r) 5) (list-ref r k) r)) runs))
        (test-equal "two threads that run one loop at once: every uv-run either runs it or is refused 'loop-running"
          (make-list race-runs '(ok ok))
          (field 0))
        (test-equal "...and no two of the loop's callbacks ever run at once"
          (make-list race-runs 1)
          (field 1))
        (test-equal "...and once both are done the claim is free: this thread runs the loop and tears it down"
          (make-list race-runs '(ran torn-down))
          (field 2))
        (test-equal "precondition: in every run, each thread saw the other move during its own run"
          (make-list race-runs '(moved moved))
          (field 3))
        (test-equal "precondition: in every run, each thread was refused 'loop-running at least once"
          (make-list race-runs '(refused refused))
          (field 4)))

      (let ((teardowns (unless-stuck (lambda () (end-race uv-loop-teardown! #t)))))
        (test-equal "a thread tears a loop down while another runs it: the runner's calls run or are refused until the loop is gone, the teardown is accepted, and no claim is left"
          'all-ok
          (car teardowns))
        (test-equal "precondition: some of those teardowns were refused 'loop-running first"
          'contended
          (if (and (number? (cadr teardowns)) (positive? (cadr teardowns)))
              'contended
              teardowns)))

      (let ((closes (unless-stuck (lambda () (end-race uv-loop-close! #f)))))
        (test-equal "a thread closes a loop while another runs it: the runner's calls run or are refused until the loop is gone, the close is accepted, and no claim is left"
          'all-ok
          (car closes))
        (test-equal "precondition: some of those closes were refused 'loop-running first"
          'contended
          (if (and (number? (cadr closes)) (positive? (cadr closes)))
              'contended
              closes)))))

(test-end "loop-claim")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
