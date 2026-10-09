#!r6rs
;;; SRFI-64 suite for the claim a loop's callers make on it (#78).
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
;;; A run, a close and each step of a teardown now claim the loop before
;;; they call libuv on it: the mark, which names the claiming thread, is
;;; taken with a compare-and-set in one interrupt-free step, and whoever
;;; takes it is the only one inside until it is given back. The rows below
;;; hold that:
;;; - from another thread, while this thread is inside a run: each verb is
;;;   refused, and the refusal leaves this thread's claim and ownership as
;;;   they were;
;;; - every way out of a verb that took the claim gives it back, a refusal
;;;   by libuv or a callback's raise included;
;;; - call-with-uv-loop's exit takes back only a claim its own thread left;
;;; - an engine split or dropped inside a verb: the verbs that run the loop
;;;   agree with each other at every expiry, and a dropped close or teardown
;;;   leaves its loop unclaimed, except inside a run, as a dropped run does;
;;; - two threads that race the verbs on one loop: every call is run or
;;;   refused, no two of the loop's callbacks ever run at once, inside every
;;;   callback the claim names the thread running it, and the claim is free
;;;   once both are done.
;;;
;;; The races need two threads that really contended, so each has
;;; precondition rows: each thread saw the other's progress move, and was
;;; refused at least once where refusal is the point. A thread past its own
;;; rounds goes on until those hold, or the other has finished, bounded by
;;; race-time-cap and never by a count of its own (#74). Every wait on
;;; another thread gives up at that cap too, so a broken build that hangs two
;;; threads in uv_run fails its rows by name instead of hanging the suite.
;;; Valgrind runs one thread at a time, so under it the races are skipped
;;; (CHEZ_LIBUV_UNDER_VALGRIND).
;;;
;;; NOT pure: it runs loops. Never add this to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop) (libuv handle) (libuv timer) (libuv async)
        (libuv private conditions)
        (only (libuv private native) current-thread-id)
        (only (libuv private handles) loop-running? loop-holder set-loop-holder!
              loop-owner-thread set-loop-owner-thread! claim-loop! release-loop!)
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

(define (refused-busy? e)
  (and (uv-errno-error? e) (eq? (uv-errno-error-errno e) 'EBUSY)))

;; How long, in milliseconds, any wait on another thread lasts. It bounds
;; only how long a broken build takes to show itself; on a correct build
;; every wait ends long before it.
(define race-time-cap 10000)

(define ten-ms (make-time 'time-duration 10000000 0))

;; await : mutex condition (-> boolean) -> boolean
;; With M held, waits on CV until (READY?) holds or race-time-cap passes, and
;; answers (READY?).
(define (await m cv ready?)
  (let ((end (+ (real-time) race-time-cap)))
    (let wait ()
      (if (or (ready?) (> (real-time) end))
          (ready?)
          (begin (condition-wait cv m ten-ms) (wait))))))

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
    (with-mutex m
      (await m cv (lambda () done))
      result)))

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

;; take-back-and-tear-down : uv-loop -> (or 'torn-down list)
;; For a loop a row left claimed on purpose, once nothing is running in
;; it: clears the claim, takes the loop back and tears it down.
(define (take-back-and-tear-down loop)
  (set-loop-holder! loop #f)
  (set-loop-owner-thread! loop (current-thread-id))
  (tear-down loop))

;; --- from another thread, while this thread runs the loop -------------------

;; refused-from-another-thread : (uv-loop -> object) -> list
;; Makes a loop and, from inside a run of it on this thread, calls VERB on
;; it from another thread: how VERB was refused, whether this thread still
;; owns the loop, and whether it is still marked running, all seen inside
;; the run; then, once the run is over, whether the loop is marked running,
;; and its teardown.
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
                            (marked loop))))))
         (after (marked loop)))
    (list inside after (tear-down loop))))

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
  (let* ((loop (make-uv-loop))
         (answer (inside-a-run
                  loop
                  (lambda ()
                    (guard (e (#t (evidence e)))
                      (uv-run loop 'no-such-mode)
                      'accepted)))))
    (tear-down loop)
    answer))

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
    (let* ((first (tear-down loop))
           (mark (marked loop)))
      (list first mark (if (uv-loop-open? loop) 'open 'closed)))))

;; A teardown whose drain never empties the loop gives up at its bound. Here
;; a close callback makes an async the teardown never saw, whose wake stops
;; each run and sends itself again, so every drain run ends with work left,
;; and none waits for it.
(test-equal "a uv-loop-teardown! that gives up at its drain bound gives the claim back"
  '(drain-bound not-running torn-down)
  (let* ((loop (make-uv-loop))
         (t (make-uv-timer loop))
         (late #f))
    (uv-close! t (lambda ()
                   (set! late (make-uv-async loop (lambda (a)
                                                    (uv-stop! loop)
                                                    (uv-async-send! a))))
                   (uv-async-send! late)))
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
    (let* ((again (guard (e (#t (evidence e))) (uv-loop-close! loop) 'closed-again))
           (mark (marked loop)))
      (list again mark))))

;; Only the claim's holder gives it back: a release from any other thread
;; would clear a claim it does not hold, so release-loop! refuses it, as a
;; defect in the binding, and the claim stays.
(test-equal "a release of a claim this thread does not hold is refused, and the claim stays"
  '(refused held-by-that-thread torn-down)
  (let* ((loop (make-uv-loop))
         (other (+ (current-thread-id) 1)))
    (set-loop-holder! loop other)
    (let* ((released (guard (e ((assertion-violation? e) 'refused) (#t (evidence e)))
                       (release-loop! loop)
                       'released))
           (held (if (eqv? (loop-holder loop) other)
                     'held-by-that-thread
                     (list 'held-by (loop-holder loop)))))
      (list released held (take-back-and-tear-down loop)))))

;; A teardown takes the loop over at each run of its drain, as its drain's
;; uv-run always did. So a teardown on another thread whose close callback
;; escapes leaves the loop claimed by that thread, and owned by it, like any
;; run left from a callback.
(define escaped-teardown-loop (make-uv-loop))

(test-equal "a teardown on another thread whose close callback escapes leaves the loop claimed by that thread, and owned by it"
  '(escaped held-by-that-thread owned-by-that-thread)
  (let* ((loop escaped-teardown-loop)
         (t (make-uv-timer loop))
         (other (on-other-thread
                 (lambda ()
                   (list (call/cc
                          (lambda (k)
                            (uv-close! t (lambda () (k 'escaped)))
                            (uv-loop-teardown! loop)
                            'returned))
                         (current-thread-id))))))
    (if (and (pair? other) (pair? (cdr other)) (number? (cadr other)))
        (list (car other)
              (if (eqv? (loop-holder loop) (cadr other))
                  'held-by-that-thread
                  (list 'held-by (loop-holder loop)))
              (if (eqv? (loop-owner-thread loop) (cadr other))
                  'owned-by-that-thread
                  'owned-by-another))
        other)))

;; The escape left a close callback whose handle libuv had finished closing,
;; so the loop's state is whole and the suite can take it back.
(test-equal "the escaped teardown's loop tears down once the suite takes its claim back"
  'torn-down
  (take-back-and-tear-down escaped-teardown-loop))

;; --- call-with-uv-loop's exit and another thread's claim ---------------------

;; The exit tears its loop down. A claim this thread left there, by leaving
;; the body from inside one of the loop's callbacks, it takes over (#45),
;; and any other call's claim it refuses. Before #78's review the exit took
;; "marked, and owned by this thread" for its own claim. A close on another
;; thread claims without taking the loop over, so its claim looked like the
;; exit's own: the exit cleared it and tore the loop down under the close.
;; Here another thread holds a claim taken as a close takes it, and keeps it
;; until the exit is over.
(define (exit-with-another-threads-claim)
  (let ((m (make-mutex)) (cv (make-condition))
        (claimed #f) (go #f) (released #f) (other-id #f) (the-loop #f))
    (define (other-thread)
      (let ((loop (with-mutex m (await m cv (lambda () the-loop)) the-loop)))
        (let ((claim (claim-loop! loop #f)))
          (with-mutex m
            (set! other-id (current-thread-id))
            (set! claimed claim)
            (condition-broadcast cv)
            (await m cv (lambda () go)))
          (unless (symbol? claim) (release-loop! loop))
          (with-mutex m
            (set! released #t)
            (condition-broadcast cv)))))
    (fork-thread other-thread)
    (let* ((exit (guard (e (#t (evidence e)))
                   (call-with-uv-loop
                    (lambda (loop)
                      (with-mutex m
                        (set! the-loop loop)
                        (condition-broadcast cv)
                        (await m cv (lambda () claimed)))
                      'body-returned))))
           (held (if (and other-id (eqv? (loop-holder the-loop) other-id))
                     'held-by-that-thread
                     (list 'held-by (and the-loop (loop-holder the-loop)) 'claim claimed)))
           (owner (if (and the-loop (eqv? (loop-owner-thread the-loop) (current-thread-id)))
                      'owner-kept
                      'owner-moved))
           (gave-back (with-mutex m
                        (set! go #t)
                        (condition-broadcast cv)
                        (if (await m cv (lambda () released)) 'released 'never-released)))
           (after (if (and the-loop (uv-loop-open? the-loop))
                      (tear-down the-loop)
                      'closed-under-the-claim)))
      (list exit held owner gave-back after))))

(test-equal "call-with-uv-loop's exit refuses a loop whose claim a close on another thread holds, though this thread still owns the loop"
  '((uv-loop-teardown! loop-running) held-by-that-thread owner-kept released torn-down)
  (exit-with-another-threads-claim))

;; --- the exit's re-claim, split by an engine (#96) ---------------------------

;; A teardown refused because another call took the claim between its
;; steps leaves the loop to that call: the exit must not claim it again. An
;; exit that re-claims after any refusal (N3) leaves the loop claimed by
;; this thread once that call is done, with no run in it, refused by every
;; verb for good. The exit race below catches that only when another
;; thread's run ends in the instant between the refusal and the re-claim:
;; 5 of 5 races on macOS and 1 of 10 on an arm64 Linux mirror (#91's
;; log), though 10 of 10 on x86_64 Linux (2026-10-09).
;;
;; Here the interleaving is forced on one thread, in an engine. A body
;; leaves call-with-uv-loop from inside a timer callback, so its exit tears
;; down holding the claim. The engine's first expiry must come inside that
;; exit: Chez runs a dynamic-wind exit at an engine's suspension, so an
;; expiry anywhere inside the body tears the loop down there and then, and
;; no later expiry can split that exit. The body is about 70 ticks, and its
;; first 46 or so are before the exit, so each run is given a first slice
;; of FUEL ticks, and one tick at a time after it. At the first expiry with
;; the claim free, which is the gap the teardown's first step leaves when
;; it gives the claim back, the claim is forged to another thread, so the
;; drain's claim is refused 'loop-running. CLEAR-AT expiries later the
;; forgery is cleared, as that thread's call would end. Swept over
;; CLEAR-AT up to the exit's end, the clears land at every expiry from the
;; forgery on: a correct exit leaves the loop unclaimed in every run.
;;
;; On a correct build no expiry comes between the drain's refusal and the
;; exit's return: the clears before the refusal let the teardown finish,
;; and the next run ends with the forgery still held. A re-claim brings
;; expiries of its own ahead of its claim, so N3's runs clear the forgery
;; between the refusal and the re-claim, and the re-claim succeeds.
;; Measured on Linux, 2026-10-09: the first expiry inside the exit at
;; tick 47 of the body; four clears before the drain's claim, and none
;; after it on a correct build, one under N3.

;; The most runs the sweep makes, and the most resumes a run may take
;; before it is given up: the engine's bound (the engine census in
;; tests/test-sweep.sps).
(define exit-split-cap 2000)
(define exit-split-resumes 100000)

;; exit-split-run : exact-positive-integer exact-positive-integer -> object
;; One run, with a first slice of FUEL ticks, clearing the forgery CLEAR-AT
;; expiries after it was placed: how the run left the loop.
;; - early: the first expiry came before the exit, which then ran at the
;;   suspension, so nothing split it;
;; - torn-down: the drain claimed after the clear, and the teardown ended;
;; - unclaimed: the teardown was refused and the exit left the loop alone;
;; - (forgery-held timer-state): the run ended before CLEAR-AT came, with
;;   the forged claim still in place, and the state of the body's timer.
;;   The drain is what finishes the timer's close, so 'closing means the
;;   drain was refused, and 'closed that the forgery came after it;
;; - claimed-by-this-thread: the exit claimed the loop after the refusal;
;; - (forgery-gone-at-clear holder): the clear found the forged claim
;;   replaced, by this thread's or erased, and left it as it was;
;; - forgery-erased: the run ended with no claim, though nothing cleared
;;   the forgery;
;; - (cleanup …): the loop left open did not tear down once taken back;
;; - never-forged, (body …) or (held-by …), when the run went otherwise
;;   than the row needs.
;; Only a claim still the forgery is cleared, and only a run whose final
;; holder is the forged thread counts as forgery-held: an exit that took
;; or cleared the other call's claim would otherwise pass as one that left
;; it alone (#96's review).
(define (exit-split-run fuel clear-at)
  (let ((the-loop #f) (the-timer #f) (escaping #f) (early #f) (expiries 0)
        (forged #f) (since-forged 0) (cleared #f) (gone-at-clear #f)
        (other (+ (current-thread-id) 1)))
    (define (body)
      (guard (e (#t (list 'raised (evidence e))))
        (call/cc
         (lambda (k)
           (call-with-uv-loop
            (lambda (loop)
              (set! the-loop loop)
              (set! the-timer (make-uv-timer loop))
              (uv-timer-start! the-timer
                               (lambda (t) (set! escaping #t) (k 'escaped))
                               0 0)
              (uv-run loop 'default)
              'returned))))))
    (define (at-expiry)
      (set! expiries (+ expiries 1))
      (when (and (= expiries 1)
                 (not (and escaping (uv-loop-open? the-loop))))
        (set! early #t))
      (cond
       (early #f)
       ((not forged)
        (when (and (uv-loop-open? the-loop) (not (loop-holder the-loop)))
          (set-loop-holder! the-loop other)
          (set! forged #t)))
       ((not (or cleared gone-at-clear))
        (set! since-forged (+ since-forged 1))
        (when (= since-forged clear-at)
          (let ((holder (loop-holder the-loop)))
            (if (eqv? holder other)
                (begin (set-loop-holder! the-loop #f)
                       (set! cleared #t))
                (set! gone-at-clear (list holder))))))))
    (let* ((answer
            (let run ((eng (make-engine body)) (ticks fuel) (resumes 0))
              (eng ticks
                   (lambda (ticks value) value)
                   (lambda (next)
                     (at-expiry)
                     (if (= resumes exit-split-resumes)
                         (list 'stuck-after-resumes exit-split-resumes)
                         (run next 1 (+ resumes 1)))))))
           (me (current-thread-id))
           (holder (and the-loop (loop-holder the-loop)))
           (left (cond (early 'early)
                       ((not (eq? answer 'escaped)) (list 'body answer))
                       ((not forged) 'never-forged)
                       ((not (uv-loop-open? the-loop)) 'torn-down)
                       (gone-at-clear (cons 'forgery-gone-at-clear gone-at-clear))
                       ((eqv? holder me) 'claimed-by-this-thread)
                       ((not cleared)
                        (cond ((eqv? holder other)
                               (list 'forgery-held (uv-handle-state the-timer)))
                              ((not holder) 'forgery-erased)
                              (else (list 'held-by holder))))
                       ((not holder) 'unclaimed)
                       (else (list 'held-by holder))))
           (cleanup (if (and the-loop (uv-loop-open? the-loop))
                        (take-back-and-tear-down the-loop)
                        'torn-down)))
      (if (eq? cleanup 'torn-down)
          left
          (list 'cleanup cleanup left)))))

;; exit-split : -> (list wrong torn-down end fuel)
;; exit-split-run at CLEAR-AT 1, 2, ..., starting at a first slice of one
;; tick and taking one more each time a run's first expiry comes too early,
;; for the same CLEAR-AT. It answers the runs that went wrong, with their
;; fuel and clear point; how many runs the teardown finished; how the sweep
;; ended: (reached timer-state) once a run ended with the forgery still
;; held, past the exit's last expiry, with that run's timer state; and the
;; first slice it ended at. A run left claimed by this thread is listed and
;; the sweep goes on. Any other run ends it, listed, since every later run
;; would go the same way: one never forged, one whose body did not escape,
;; one given up. A raise ends the sweep with (sweep-raised message),
;; keeping what came before.
(define (exit-split)
  (let sweep ((runs 1) (fuel 1) (clear-at 1) (wrong '()) (torn-down 0))
    (define (stop wrong end) (list (reverse wrong) torn-down end fuel))
    (define (noted left) (cons (list fuel clear-at left) wrong))
    (if (> runs exit-split-cap)
        (stop wrong 'cap-reached)
        (let ((left (guard (e (#t (list 'sweep-raised (describe e))))
                      (exit-split-run fuel clear-at)))
              (next (lambda (wrong torn-down)
                      (sweep (+ runs 1) fuel (+ clear-at 1) wrong torn-down))))
          (cond
           ((eq? left 'early) (sweep (+ runs 1) (+ fuel 1) clear-at wrong torn-down))
           ((eq? left 'torn-down) (next wrong (+ torn-down 1)))
           ((eq? left 'unclaimed) (next wrong torn-down))
           ((and (pair? left) (eq? (car left) 'forgery-held))
            (stop wrong (cons 'reached (cdr left))))
           ((eq? left 'claimed-by-this-thread) (next (noted left) torn-down))
           ((and (pair? left) (eq? (car left) 'sweep-raised)) (stop wrong left))
           (else (stop (noted left) 'ended-early)))))))

(define exit-splits (exit-split))

;; reached: the last run ended with the forgery held and the loop open,
;; so every clear point before it was tried.
(test-equal "an exit refused between its teardown's steps, split by an engine: at every point the other call's claim ends, the exit leaves the loop unclaimed"
  '(() reached)
  (list (car exit-splits)
        (let ((end (caddr exit-splits)))
          (if (and (pair? end) (eq? (car end) 'reached)) 'reached end))))

;; The forgery must come before the drain's claim, or the row splits some
;; other step. Then the clears before that claim let the teardown finish,
;; and in the last run, refused, the drain never finished the timer's
;; close: the timer is still closing. A forgery placed after the drain, in
;; the gap before the close's claim, leaves it closed.
(test-equal "precondition: the forgery came before the drain's claim: some runs' teardowns finished, and in the last the drain was refused"
  '(torn-down-somewhere drain-refused)
  (list (if (positive? (cadr exit-splits))
            'torn-down-somewhere
            (list 'torn-down (cadr exit-splits)))
        (if (equal? (caddr exit-splits) '(reached closing))
            'drain-refused
            (caddr exit-splits))))

;; The exit takes its own claim straight into the teardown, with no moment
;; unclaimed in between. Before #78's review it cleared the claim and then
;; let the teardown claim again: another thread's uv-run could take the loop
;; in between, the teardown was refused, and the exit wrote its own mark
;; over the other thread's claim, leaving the loop marked with no run in it,
;; refused by every verb for good. Here a body leaves from inside a timer
;; callback, again and again, while another thread runs every loop it sees
;; unclaimed. That thread may still get in between the teardown's steps,
;; and keeps the loop then: the row asks only that no loop is left claimed
;; once that thread has stopped.
;;
;; The race says nothing unless that thread got in at least once, which
;; the precondition holds. It gets in when the body's thread is slow
;; between two of the teardown's steps, mostly when a collection lands
;; there, and that is rare: with a fixed 2,000 bodies on one thread it never
;; got in, in 6 of 8 runs on Ubuntu 24.04 and in CI's first run on 26.04
;; (#91). So the bodies go on until the other thread has got in
;; exit-race-hits times, bounded by race-time-cap, never by a count of this
;; thread's own (#74). A machine that cannot get to that many by the cap
;; still passes the precondition with one.
;;
;; One run would prove the race happened, but a loop is left claimed only
;; when the other thread's run ends in the instant between a refused
;; teardown and the exit's next move. An exit that re-claims after any
;; refusal (N3 in .plans/loop-claim-mutation-log.md) strands a loop exactly
;; there. With 100 runs the main row caught it in 5 of 5 races on macOS
;; and 1 of 10 on an arm64 Linux mirror, where 2,000 bodies on one thread
;; caught it in none. The 100 runs took 1 to 5 s. The engine split above
;; now catches N3 in every run (#96); the race stays for what a forged
;; claim cannot be, a real other thread's run inside the loop.
;;
;; Each body leaves its callback by a continuation, and that strands the
;; C frames of the uv_run it left on its thread's stack for as long as the
;; thread lives (docs/api.md, "A callback ends only by returning"). 20,000
;; of them overflowed an 8 MB stack on Linux, and 2,000 a secondary
;; thread's on macOS, which then hung instead of crashing. So the bodies
;; run in batches of exit-race-batch, each on a thread of its own, whose
;; stack goes when it ends.
(define exit-race-attempts 2000)
(define exit-race-batch 250)
(define exit-race-hits 100)

;; exit-batch : box -> list
;; EXIT-RACE-BATCH bodies, each leaving call-with-uv-loop from inside a
;; timer callback after it has put its loop in SHARED: the loops the bodies
;; left open.
(define (exit-batch shared)
  (let attempt ((i 0) (left '()))
    (if (= i exit-race-batch)
        left
        (let ((the-loop #f))
          (guard (e (#t (evidence e)))
            (call/cc
             (lambda (k)
               (call-with-uv-loop
                (lambda (loop)
                  (set! the-loop loop)
                  (uv-timer-start! (make-uv-timer loop)
                                   (lambda (t) (set-box! shared loop) (k 'escaped))
                                   0 0)
                  (uv-run loop 'default)
                  'returned)))))
          (set-box! shared #f)
          (attempt (+ i 1)
                   (if (and the-loop (uv-loop-open? the-loop)) (cons the-loop left) left))))))

;; exit-race : -> list
;; (stranded stopped ran bodies): how many loops were left claimed once the
;; other thread stopped, whether it stopped, how many loops it ran, and how
;; many bodies were made; a batch that never ended within race-time-cap
;; adds (batch-never-ended).
(define (exit-race)
  (let ((shared (box #f)) (stop (box #f)) (ran (box 0)) (done (box #f))
        (m (make-mutex)) (cv (make-condition))
        (end (+ (real-time) race-time-cap)))
    (fork-thread
     (lambda ()
       (let spin ()
         (unless (unbox stop)
           (let ((loop (unbox shared)))
             (when (and loop (not (loop-running? loop)))
               (guard (e (#t #f))
                 (uv-run loop 'nowait)
                 (atomic-add! ran 1))))
           (spin)))
       (with-mutex m (set-box! done #t) (condition-broadcast cv))))
    (let batch ((bodies 0) (left '()))
      (if (and (< (real-time) end)
               (or (< bodies exit-race-attempts) (< (unbox ran) exit-race-hits)))
          (let ((made (box #f)))
            (fork-thread
             (lambda ()
               (let ((batch-left (exit-batch shared)))
                 (with-mutex m (set-box! made batch-left) (condition-broadcast cv)))))
            (if (with-mutex m (await m cv (lambda () (unbox made))))
                (batch (+ bodies exit-race-batch) (append (unbox made) left))
                (finish-exit-race stop m cv done ran bodies left '(batch-never-ended))))
          (finish-exit-race stop m cv done ran bodies left '())))))

;; finish-exit-race : box mutex condition box box integer list list -> list
;; Stops the other thread and answers exit-race's list.
(define (finish-exit-race stop m cv done ran bodies left more)
  (set-box! stop #t)
  (let* ((stopped (with-mutex m (await m cv (lambda () (unbox done)))))
         (stranded (length (filter loop-running? left))))
    (for-each (lambda (l) (unless (loop-running? l) (tear-down l))) left)
    (append (list stranded (if stopped 'stopped 'never-stopped) (unbox ran) bodies)
            more)))

;; --- an already-closed loop, closed from two threads at once ------------------

(define closed-close-rounds 20000)

;; --- engine splits ------------------------------------------------------------

;; The claim's take and its open check are one step, so no engine of the
;; claiming thread comes between them. A uv-run an engine suspends before
;; its claim, while the engine's own thread closes or tears the loop down,
;; must find the loop closed when it resumes, never run the freed one; one
;; suspended inside its claim keeps the loop from the close. Until #78 a run
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

;; ends-agree : object object -> (or 'accepted 'refused 'after #f)
;; For a close or a teardown: it was accepted and the resumed run then
;; refused the closed loop (split before the run's claim); it was refused
;; the claim the run held and the run went on (split inside it); it was
;; accepted and the run went on, having given its claim back (split after
;; it); or #f, if none of these.
(define (ends-agree verb-outcome run-outcome)
  (cond ((and (eq? verb-outcome 'accepted) (equal? run-outcome '(handle-closed loop)))
         'accepted)
        ((and (refused-claim? verb-outcome) (eq? run-outcome 'ran)) 'refused)
        ((and (eq? verb-outcome 'accepted) (eq? run-outcome 'ran)) 'after)
        (else #f)))

;; accepted : (uv-loop -> object) -> (uv-loop -> 'accepted)
(define (accepted verb) (lambda (loop) (verb loop) 'accepted))

;; split-sweep : (-> uv-loop) (uv-loop -> object) (uv-loop -> object)
;;               (object object -> (or 'accepted 'refused 'after #f))
;;               -> (list wrong accepted refused end)
;; Splits (RUN loop) at each fuel, calling VERB at the expiry (its value,
;; or how it was refused, is its outcome), and asks
;; (JUDGE verb-outcome run-outcome) whether the two agree: 'accepted or
;; 'refused for a split before the run's claim or inside it, 'after for one
;; after it, and #f if they do not. Then the loop is torn down, if it is
;; still open. Answers the fuels whose outcomes did not agree, or whose
;; teardown failed, with what happened; how many expiries had VERB accepted
;; and how many had it refused; and 'reached when a run finished with no
;; expiry before split-sweep-cap. A raise between runs ends the sweep with
;; (sweep-raised message), and keeps what came before.
(define (split-sweep make-loop verb run judge)
  (let sweep ((fuel 1) (wrong '()) (accepted 0) (refused 0))
    (define (stop end) (list (reverse wrong) accepted refused end))
    (if (> fuel split-sweep-cap)
        (stop 'cap-reached)
        (let ((step
               (guard (e (#t (list 'sweep-raised (describe e))))
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
                              (list verb-outcome run-outcome)))))
                        (cleanup (if (uv-loop-open? loop) (tear-down loop) 'torn-down)))
                   (list 'step outcome cleanup)))))
          (if (eq? (car step) 'sweep-raised)
              (stop step)
              (let ((outcome (cadr step)) (cleanup (caddr step)))
                (cond
                 ((not (eq? cleanup 'torn-down))
                  (sweep (+ fuel 1) (cons (list fuel 'teardown cleanup) wrong) accepted refused))
                 ((eq? outcome 'finished) (stop 'reached))
                 (else
                  (case (judge (car outcome) (cadr outcome))
                    ((accepted) (sweep (+ fuel 1) wrong (+ accepted 1) refused))
                    ((refused) (sweep (+ fuel 1) wrong accepted (+ refused 1)))
                    ((after) (sweep (+ fuel 1) wrong accepted refused))
                    (else (sweep (+ fuel 1) (cons (cons fuel outcome) wrong)
                                 accepted refused)))))))))))

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
;; Split inside the claim, VERB is refused, and the resumed run fires them
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
;; The run's outcome, then how many errors it deferred: read after the run,
;; whatever order Chez evaluates arguments in.
(define (run-and-its-deferrals loop)
  (let* ((outcome (guard (e ((uv-callback-error? e) 'raised) (#t (evidence e)))
                    (uv-run loop 'nowait)
                    'ran))
         (deferred (length (uv-loop-deferred-errors loop))))
    (list outcome deferred)))

(define (deferrals-agree verb-outcome run-outcome)
  (cond ((and (equal? verb-outcome '(raised 2)) (equal? run-outcome '(ran 0))) 'accepted)
        ((and (pair? verb-outcome) (refused-claim? (car verb-outcome))
              (equal? run-outcome '(raised 2)))
         'refused)
        ((and (equal? verb-outcome '(ran 0)) (pair? run-outcome)
              (eq? (car run-outcome) 'raised))
         'after)
        (else #f)))

(define deferral-split
  (split-sweep loop-with-raising-timers run-and-its-deferrals run-and-its-deferrals
               deferrals-agree))

(define (split-verdict s) (list (car s) (cadddr s)))

(define (split-seen s)
  (list (if (positive? (cadr s)) 'accepted-somewhere 'never-accepted)
        (if (positive? (caddr s)) 'refused-somewhere 'never-refused)))

(test-equal "a uv-run split by an engine while its thread closes the loop: at every expiry, the close and the resumed run agree"
  '(() reached)
  (split-verdict close-split))

(test-equal "precondition: the close split the run both before its claim and inside it"
  '(accepted-somewhere refused-somewhere)
  (split-seen close-split))

(test-equal "a uv-run split by an engine while its thread tears the loop down: at every expiry, the teardown and the resumed run agree"
  '(() reached)
  (split-verdict teardown-split))

(test-equal "precondition: the teardown split the run both before its claim and inside it"
  '(accepted-somewhere refused-somewhere)
  (split-seen teardown-split))

(test-equal "a uv-run split by an engine while its thread runs the loop: at every expiry, the resumed run defers only its own callbacks' errors"
  '(() reached)
  (split-verdict deferral-split))

(test-equal "precondition: the other run split the run both before its claim and inside it"
  '(accepted-somewhere refused-somewhere)
  (split-seen deferral-split))

;; --- engine drops ---------------------------------------------------------------

;; An engine that is dropped never runs anything after its expiry, so a
;; claim a dropped verb held is never given back. A close is one
;; interrupt-free step, and a teardown is steps that hold the claim only
;; while they call libuv, so a dropped close never leaves its loop claimed,
;; and a dropped teardown does only inside a run of its drain, as a dropped
;; uv-run does: a claim that covered the whole teardown left its loop
;; claimed for good at almost every expiry (#78's review). Each sweep runs
;; VERB on a fresh loop in an engine with fuel 1, 2, ..., drops it at its
;; first expiry, notes whether the loop was left claimed, and then calls
;; VERB again, or tears the loop down after a run, on the same thread, which
;; must finish the job.

;; drop-sweep : (-> uv-loop) (uv-loop -> object) (uv-loop -> object) boolean
;;              -> (list claimed wrong expiries end left)
;; The fuels at which the dropped VERB left its loop claimed; the fuels at
;; which RETRY, on a loop left unclaimed, did not close it, with what it
;; gave; how many runs expired; and 'reached when a run finished with no
;; expiry before split-sweep-cap. With TAKE-BACK?, a loop left claimed is
;; taken back and torn down: its loops are empty, so the run its claim
;; belongs to was not inside a callback, and nothing will resume it.
;; Without, it is left as it is, and listed in LEFT: a close dropped with
;; its claim held may have closed the loop in libuv already, and closing it
;; again aborts the process. A raise between runs ends the sweep with
;; (sweep-raised message).
(define (drop-sweep make-loop verb retry take-back?)
  (let sweep ((fuel 1) (claimed '()) (wrong '()) (expiries 0) (left '()))
    (define (stop end) (list (reverse claimed) (reverse wrong) expiries end left))
    (if (> fuel split-sweep-cap)
        (stop 'cap-reached)
        (let ((step
               (guard (e (#t (list 'sweep-raised (describe e))))
                 (let* ((loop (make-loop))
                        (outcome ((make-engine (lambda () (verb loop) 'done))
                                  fuel
                                  (lambda (ticks value) 'finished)
                                  (lambda (resume) 'dropped)))
                        (held (loop-running? loop))
                        (again (cond ((eq? outcome 'finished) (tear-down loop))
                                     (held (if take-back? (take-back-and-tear-down loop) loop))
                                     (else (guard (e (#t (evidence e)))
                                             (retry loop)
                                             (if (uv-loop-open? loop) 'still-open 'closed))))))
                   (list 'step outcome held again)))))
          (if (eq? (car step) 'sweep-raised)
              (stop step)
              (let ((outcome (cadr step)) (held (caddr step)) (retry (cadddr step)))
                (cond ((eq? outcome 'finished) (stop 'reached))
                      (held (sweep (+ fuel 1) (cons fuel claimed) wrong (+ expiries 1)
                                   (if (uv-loop? retry) (cons retry left) left)))
                      ((eq? retry 'closed) (sweep (+ fuel 1) claimed wrong (+ expiries 1) left))
                      (else (sweep (+ fuel 1) claimed (cons (list fuel retry) wrong)
                                   (+ expiries 1) left)))))))))

(define close-drops (drop-sweep make-uv-loop uv-loop-close! uv-loop-close! #f))
(define teardown-drops (drop-sweep make-uv-loop uv-loop-teardown! uv-loop-teardown! #f))
(define run-drops
  (drop-sweep make-uv-loop (lambda (loop) (uv-run loop 'default)) uv-loop-teardown! #t))

(test-equal "an engine dropped anywhere in a uv-loop-close! leaves its loop unclaimed, and a close on the same thread then closes it"
  '(() () reached)
  (list (car close-drops) (cadr close-drops) (cadddr close-drops)))

;; The loops a dropped teardown left claimed are taken back only when it
;; left them where a dropped run does, inside a run of its drain: a build
;; that strands a teardown elsewhere may have left one half closed.
(test-equal "an engine dropped in a uv-loop-teardown! leaves its loop unclaimed wherever a dropped run of it would, and a teardown then finishes the job"
  '(no-wider () reached all-torn-down)
  (let* ((teardown-claimed (length (car teardown-drops)))
         (run-claimed (length (car run-drops)))
         (no-wider (<= teardown-claimed run-claimed))
         (left (list-ref teardown-drops 4))
         (cleanup (if no-wider
                      (let ((ends (map take-back-and-tear-down left)))
                        (if (for-all (lambda (e) (eq? e 'torn-down)) ends) 'all-torn-down ends))
                      'left-claimed)))
    (list (if no-wider
              'no-wider
              (list 'teardown (car teardown-drops) 'run (car run-drops)))
          (cadr teardown-drops)
          (cadddr teardown-drops)
          cleanup)))

(test-equal "precondition: every drop sweep's verb was dropped, and a dropped run left its loop claimed"
  '(dropped dropped dropped run-claimed)
  (list (if (positive? (caddr close-drops)) 'dropped close-drops)
        (if (positive? (caddr teardown-drops)) 'dropped teardown-drops)
        (if (positive? (caddr run-drops)) 'dropped run-drops)
        (if (pair? (car run-drops)) 'run-claimed run-drops)))

;; --- races on one loop ------------------------------------------------------

;; The loop each race runs: timers that fire every millisecond, whose
;; callback notes how many of the loop's callbacks are running at once, and
;; whether the loop's claim names the thread the callback runs on.
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

;; witness: what a race's callbacks saw. MOST holds the most of the loop's
;; callbacks seen running at once, 0 until one has run; FOREIGN how many
;; callbacks found the loop's claim naming another thread than their own,
;; or none.
(define-record-type witness (fields most foreign))

;; make-witnessed-loop : (or exact-positive-integer #f) -> (values uv-loop witness)
;; A loop with timers-per-loop repeating timers, and their witness. With
;; FIRES, each timer closes itself after that many callbacks.
(define (make-witnessed-loop fires)
  (let ((loop (make-uv-loop))
        (inside (box 0))
        (seen (make-witness (box 0) (box 0))))
    (define (timer-callback count)
      (lambda (t)
        (atomic-max! (witness-most seen) (atomic-add! inside 1))
        (unless (eqv? (loop-holder loop) (current-thread-id))
          (atomic-add! (witness-foreign seen) 1))
        (let spin ((i 0)) (when (< i 2000) (spin (+ i 1))))
        (atomic-add! inside -1)
        (set-box! count (+ 1 (unbox count)))
        (when (and fires (= (unbox count) fires)) (uv-close! t))))
    (let make ((i 0))
      (when (< i timers-per-loop)
        (uv-timer-start! (make-uv-timer loop) (timer-callback (box 0)) 1 1)
        (make (+ i 1))))
    (values loop seen)))

;; seen : witness -> (list most foreign)
(define (seen w) (list (unbox (witness-most w)) (unbox (witness-foreign w))))

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
  (when refused?
    (vector-set! (race-state-refused state) me
                 (+ 1 (vector-ref (race-state-refused state) me))))
  (vector-set! (race-state-progress state) me (+ i 1)))

(define (both-moved? state)
  (let ((moved (race-state-moved state)))
    (and (vector-ref moved 0) (vector-ref moved 1))))

(define (both-moved-and-refused? state)
  (let ((refused (race-state-refused state)))
    (and (both-moved? state)
         (positive? (vector-ref refused 0))
         (positive? (vector-ref refused 1)))))

;; go-on? : race-state 0|1 exact-nonnegative-integer exact-nonnegative-integer
;;          exact-nonnegative-integer (race-state -> boolean) -> boolean
;; Whether thread ME does round I. SEEN is the other's progress when ME
;; last looked; a change marks it moved. Past ROUNDS, ME goes on until
;; (ENOUGH? STATE), or the other has finished, or the cap has passed.
(define (go-on? state me rounds i seen enough?)
  (let ((other (- 1 me)))
    (unless (= (vector-ref (race-state-progress state) other) seen)
      (vector-set! (race-state-moved state) me #t))
    (or (< i rounds)
        (and (not (finished? state other))
             (not (enough? state))
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
      (if (go-on? state me run-rounds i seen both-moved-and-refused?)
          (let* ((seen-now (vector-ref (race-state-progress state) (- 1 me)))
                 (refused? (guard (e ((refused-running? e) #t))
                             (uv-run loop 'nowait)
                             #f)))
            (note-progress! state me i refused?)
            (next (+ i 1) seen-now))
          'ok))))

;; shared-run-race : -> list
;; (verdicts seen after moved refused): the two threads' verdicts, what
;; the loop's callbacks saw, what this thread's own run and teardown of the
;; loop gave once both threads were done, and the precondition pairs. A
;; raise from the race's own plumbing is its answer, in the same shape.
(define (shared-run-race)
  (guard (e (#t (let ((raised (list 'raised (describe e))))
                  (list raised raised raised raised raised))))
    (let-values (((loop w) (make-witnessed-loop #f)))
      (let* ((state (make-race-state))
             (verdicts (run-pair state (run-rounds-work loop) (run-rounds-work loop))))
        (if (stuck? verdicts)
            (begin (set! stuck verdicts)
                   (list verdicts (seen w) 'stuck (moved-pair state) (refused-pair state)))
            (let* ((ran (guard (e (#t (evidence e))) (uv-run loop 'nowait) 'ran))
                   (after (list ran (tear-down loop))))
              (list verdicts (seen w) after (moved-pair state) (refused-pair state))))))))

;; --- one thread runs the loop, another closes or tears it down --------------

;; Each race makes this many loops, one after another. A close or a
;; teardown gets one chance per loop to come between the runner's check and
;; its run, so the race wants many loops.
(define end-race-loops 200)

;; How many times each of a close race's timers fires before it closes
;; itself: until then the close is refused 'EBUSY, after it the loop is
;; empty and the close can finish.
(define close-race-fires 3)

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
;; A refusal 'EBUSY, a close's while the runner's timers are open, is tried
;; again too.
(define (ender-work loop verb)
  (lambda (state me)
    (let wait ()
      (when (and (zero? (vector-ref (race-state-progress state) (- 1 me)))
                 (<= (real-time) (race-state-deadline state)))
        (wait)))
    (let next ((refusals 0))
      (let ((outcome (guard (e ((refused-running? e) 'running)
                               ((refused-busy? e) 'busy))
                       (verb loop)
                       'accepted)))
        (cond
         ((eq? outcome 'accepted) (list 'accepted refusals))
         ((> (real-time) (race-state-deadline state)) (list 'never-accepted refusals))
         ((eq? outcome 'running) (next (+ refusals 1)))
         (else (next refusals)))))))

;; end-race : (uv-loop -> object) (or exact-positive-integer #f) -> list
;; (verdict contended): the first loop whose race went wrong, as
;; (verdicts seen mark open?), or 'all-ok; and how many loops' VERB was
;; refused 'loop-running at least once. FIRES is make-witnessed-loop's. A
;; raise from the race's own plumbing ends it with that as its verdict.
(define (end-race verb fires)
  (let next ((n 0) (contended 0))
    (if (= n end-race-loops)
        (list 'all-ok contended)
        (let ((raced
               (guard (e (#t (list 'raised (describe e))))
                 (let-values (((loop w) (make-witnessed-loop fires)))
                   (let* ((state (make-race-state))
                          (verdicts (run-pair state (runner-work loop) (ender-work loop verb)))
                          (mark (marked loop))
                          (open (if (uv-loop-open? loop) 'open 'closed)))
                     (list verdicts (seen w) mark open))))))
          (if (eq? (car raced) 'raised)
              (list raced contended)
              (let* ((verdicts (car raced))
                     (ender (cadr verdicts))
                     (accepted? (and (pair? ender) (eq? (car ender) 'accepted)))
                     (contended (if (and accepted? (positive? (cadr ender)))
                                    (+ contended 1)
                                    contended)))
                (cond
                 ((stuck? verdicts) (set! stuck verdicts) (list raced contended))
                 ((and (equal? (car verdicts) '(closed-out))
                       accepted?
                       (memv (car (cadr raced)) '(0 1))
                       (eqv? (cadr (cadr raced)) 0)
                       (eq? (caddr raced) 'not-running)
                       (eq? (cadddr raced) 'closed))
                  (next (+ n 1) contended))
                 (else (list raced contended)))))))))

;; --- the races ---------------------------------------------------------------

(define skip-races? (getenv "CHEZ_LIBUV_UNDER_VALGRIND"))

(define race-runs 3)

(define (unless-stuck thunk)
  (if stuck (list 'skipped-after-stuck stuck) (thunk)))

;; closed-close-work : uv-loop -> (race-state 0|1 -> list)
;; closed-close-rounds closes of an already closed loop, each a quiet no-op:
;; (refused N), how many were refused.
(define (closed-close-work loop)
  (lambda (state me)
    (let next ((i 0) (seen (vector-ref (race-state-progress state) (- 1 me))) (refused 0))
      (if (go-on? state me closed-close-rounds i seen both-moved?)
          (let* ((seen-now (vector-ref (race-state-progress state) (- 1 me)))
                 (refused? (guard (e ((refused-running? e) #t))
                             (uv-loop-close! loop)
                             #f)))
            (note-progress! state me i #f)
            (next (+ i 1) seen-now (if refused? (+ refused 1) refused)))
          (list 'refused refused)))))

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
        (test-equal "...and no two of the loop's callbacks ever run at once, and inside each the loop's claim names the thread running it"
          (make-list race-runs '(1 0))
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

      (let ((teardowns (unless-stuck (lambda () (end-race uv-loop-teardown! #f)))))
        (test-equal "a thread tears a loop down while another runs it: the runner's calls run or are refused until the loop is gone, no two callbacks run at once or under another thread's claim, the teardown is accepted, and no claim is left"
          'all-ok
          (car teardowns))
        (test-equal "precondition: some of those teardowns were refused 'loop-running first"
          'contended
          (if (and (number? (cadr teardowns)) (positive? (cadr teardowns)))
              'contended
              teardowns)))

      (let ((closes (unless-stuck (lambda () (end-race uv-loop-close! close-race-fires)))))
        (test-equal "a thread closes a loop while another runs it: the runner's calls run or are refused until the loop is gone, no two callbacks run at once or under another thread's claim, the close is accepted, and no claim is left"
          'all-ok
          (car closes))
        (test-equal "precondition: some of those closes were refused 'loop-running first"
          'contended
          (if (and (number? (cadr closes)) (positive? (cadr closes)))
              'contended
              closes)))

      (let* ((state (make-race-state))
             (verdicts (unless-stuck
                        (lambda ()
                          (guard (e (#t (list 'raised (describe e))))
                            (let ((closed (make-uv-loop)))
                              (uv-loop-close! closed)
                              (run-pair state (closed-close-work closed)
                                        (closed-close-work closed))))))))
        (test-equal "two threads close an already closed loop at once: every close is a quiet no-op"
          '((refused 0) (refused 0))
          verdicts)
        (test-equal "precondition: each closing thread saw the other move during its own run"
          '(moved moved)
          (moved-pair state)))

      (let ((exits (unless-stuck exit-race)))
        (when (and (list? exits) (= (length exits) 4))
          (display "  [informational] exit race: the other thread ran ")
          (display (caddr exits))
          (display " loops in ")
          (display (cadddr exits))
          (display " bodies")
          (newline))
        (test-equal "bodies left from a timer callback, while another thread runs every loop it finds unclaimed: no loop is left claimed once that thread has stopped"
          '(0 stopped)
          (if (and (pair? exits) (number? (car exits)))
              (list (car exits) (cadr exits))
              exits))
        (test-equal "precondition: the other thread ran some of those loops"
          'ran-some
          (if (and (pair? exits) (pair? (cdr exits)) (pair? (cddr exits))
                   (number? (caddr exits)) (positive? (caddr exits)))
              'ran-some
              exits)))))

(test-end "loop-claim")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
