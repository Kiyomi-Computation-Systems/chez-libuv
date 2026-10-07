#!r6rs
;;; SRFI-64 suite for loops that run on different threads at once (#70).
;;;
;;; docs/api.md gives each loop to one thread, and ADR-0019 names a thread
;;; per core as its driver: several threads, each running a loop of its own.
;;; Until #70 every such thread wrote the binding's process-wide state with
;;; no lock:
;;; - the handle registry, one table for every loop. Two threads making and
;;;   closing timers on loops of their own corrupted it in 4 of 4 runs: a
;;;   constructor raised pointer-already-registered or invalid memory
;;;   reference, or a teardown found an entry that was not one;
;;; - the cell that handle-in-loop-queue? collects uv_walk's pointers in.
;;;   One thread's walk reset it while another's was being read, so a
;;;   handle in a loop's queue was reported as out of it, the test that
;;;   decides how uv-spawn! cleans up a failed spawn (ADR-0015);
;;; - the orphan event list, which lost events;
;;; - the debug shim's allocation counters, which lost updates.
;;;
;;; Each race below runs the same work on two threads at once, each on a
;;; loop of its own, and asks for what one thread alone would see. On a
;;; broken build a race is lost within a few hundred rounds, and the row
;;; fails by name with what each thread saw. Each thread also counts how
;;; often the other's progress counter moved during its own run, and a
;;; precondition row requires both to have seen it move: two threads that
;;; ran one after the other would pass every row. At a load average of 173
;;; one pair did run that way, so a thread whose rounds are done carries on,
;;; up to race-extension times its rounds, until each has seen the other
;;; move or the other has finished. Valgrind runs one thread at a time, so
;;; under it the races are skipped (CHEZ_LIBUV_UNDER_VALGRIND).
;;;
;;; No verdict on a correct build depends on timing: each race asks only
;;; for what every schedule gives. Timing decides only how soon a broken
;;; build loses.
;;;
;;; The registry and the orphan list now hold one lock, which every loop's
;;; thread takes, so no thread may ever keep it. It is taken and released
;;; only with interrupts disabled (with-registry-lock), so no engine is
;;; suspended while its thread holds it: an engine dropped there, as a
;;; timeout drops one, would keep the lock for good, and every other loop's
;;; thread would wait on it. The sweeps run each kind of call that takes the
;;; lock in an engine at fuel 1, 2, ..., and at each expiry ask another
;;; thread whether the lock is free. They need no race, so they run under
;;; Valgrind too.
;;;
;;; NOT pure: it runs loops. Never add this to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop) (libuv handle) (libuv timer) (libuv process)
        (libuv private conditions)
        (only (libuv private native) live-counts count-timer-new! count-timer-free!)
        (only (libuv private handles)
              registry-count registry-lock handle-in-loop-queue?
              record-orphan-callback! orphan-callback-events)
        (only (uv-evidence) describe)
        (only (chezscheme) fork-thread thread-join getenv make-engine
              make-mutex make-condition with-mutex mutex-acquire mutex-release
              condition-wait condition-broadcast))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. Each row here
;; returns its evidence when it fails, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "loop-threads")

;; Taken before any race: the work below must leave both where it found
;; them.
(define counts-at-start (live-counts))
(define registry-at-start (registry-count))

;; --- the lock across engine suspensions --------------------------------------

;; lock-seen-from-another-thread : -> (or 'free 'held list)
;; The probe thread tries the registry's lock without blocking and answers
;; what it found. It is one thread for the whole suite: Chez mutexes are
;; recursive, so only a thread that does not hold the lock can see it held,
;; and a new thread can be given the id of one that has exited, and with it
;; any lock that thread still held (tests/test-async-fence.sps).
(define probe-lock (make-mutex))
(define probe-changed (make-condition))
(define probe-pending #f)
(define probe-answer #f)

(define (serve-probes)
  (let serve ()
    (with-mutex probe-lock
      (let wait ()
        (unless probe-pending
          (condition-wait probe-changed probe-lock)
          (wait))))
    (let ((answer (guard (e (#t (list 'raised (describe e))))
                    (if (mutex-acquire registry-lock #f)
                        (begin (mutex-release registry-lock) 'free)
                        'held))))
      (with-mutex probe-lock
        (set! probe-pending #f)
        (set! probe-answer answer)
        (condition-broadcast probe-changed))
      (serve))))

(fork-thread serve-probes)

(define (lock-seen-from-another-thread)
  (with-mutex probe-lock
    (set! probe-answer #f)
    (set! probe-pending #t)
    (condition-broadcast probe-changed)
    (let wait ()
      (or probe-answer
          (begin (condition-wait probe-changed probe-lock) (wait))))))

;; Every sweep row below that finds the lock free at each expiry is empty
;; unless the probe can see it held. So first, the probe sees the lock this
;; thread holds. The probe never blocks, so holding the lock here cannot
;; hold up a collection.
(test-equal "another thread sees the registry's lock held while this thread holds it"
  '(held free)
  (let* ((while-held (with-mutex registry-lock (lock-seen-from-another-thread)))
         (after (lock-seen-from-another-thread)))
    (list while-held after)))

;; The most fuel a sweep tries before it gives up on reaching a run that
;; finishes with no expiry.
(define lock-sweep-cap 5000)

;; lock-sweep : (-> (-> object)) -> (list (list-of fuel) expiries reached)
;; For FUEL = 1, 2, ..., makes a fresh call with (PREPARE), runs it in an
;; engine with FUEL ticks, and at its first expiry asks the probe whether
;; the lock is free, then resumes it to the end. Answers the fuels at which
;; the lock was not free, how many runs expired, and 'reached when a run
;; finished with no expiry before lock-sweep-cap; the sweep stops there.
(define (lock-sweep prepare)
  (let sweep ((fuel 1) (held '()) (expiries 0))
    (if (> fuel lock-sweep-cap)
        (list (reverse held) expiries 'cap-reached)
        (let* ((call (prepare))
               (outcome
                ((make-engine call)
                 fuel
                 (lambda (ticks value) 'finished)
                 (lambda (suspended)
                   (let ((seen (lock-seen-from-another-thread)))
                     (suspended 10000000
                                (lambda (ticks value) #f)
                                (lambda (more) #f))
                     seen)))))
          (if (eq? outcome 'finished)
              (list (reverse held) expiries 'reached)
              (sweep (+ fuel 1)
                     (if (eq? outcome 'free) held (cons (list fuel outcome) held))
                     (+ expiries 1)))))))

;; Each kind of call that takes the lock with interrupts enabled. A
;; constructor or a request registers inside an interrupt-free step of its
;; own, where no engine expires, so the sweeps take the calls that do not:
;; the registry's readers, the orphan list, and the seams and the close
;; dispatcher, which a uv-run delivers.
(define sweep-loop (make-uv-loop))

(define (count-call) (lambda () (registry-count)))

(define (orphan-call) (lambda () (record-orphan-callback! 'lock-sweep 0)))

;; A uv-run that delivers a timer's callback: the seam looks it up.
(define (firing-call)
  (let ((t (make-uv-timer sweep-loop)))
    (uv-timer-start! t (lambda (t) (uv-close! t)) 0 0)
    (lambda () (uv-run sweep-loop 'once))))

;; A uv-run that delivers a close: the seam looks it up, and the close
;; dispatcher deregisters it.
(define (close-call)
  (let ((t (make-uv-timer sweep-loop)))
    (uv-close! t)
    (lambda () (uv-run sweep-loop 'once))))

;; One after another, so each sweep has the loop to itself. A raise is
;; caught as the sweep's answer, for the rows to carry.
(define lock-sweeps
  (let next ((todo (list (cons 'count count-call) (cons 'orphan orphan-call)
                         (cons 'firing firing-call) (cons 'close close-call)))
             (acc '()))
    (if (null? todo)
        (reverse acc)
        (next (cdr todo)
              (cons (cons (caar todo)
                          (guard (e (#t (list 'sweep-raised (describe e))))
                            (lock-sweep (cdar todo))))
                    acc)))))

;; sweep-ok? : object -> boolean
(define (sweep-ok? s) (and (list? s) (= (length s) 3)))

(display "  [informational] lock sweeps, expiries before a run finished:")
(for-each (lambda (e)
            (display " ")
            (display (car e))
            (display " ")
            (display (if (sweep-ok? (cdr e)) (caddr e) '?)))
          lock-sweeps)
(newline)

(test-equal "no engine is suspended holding the registry's lock: at every expiry in each sweep, another thread finds it free"
  '((count () reached) (orphan () reached) (firing () reached) (close () reached))
  (map (lambda (e)
         (if (sweep-ok? (cdr e))
             (list (car e) (cadr e) (cadddr e))
             e))
       lock-sweeps))

;; Each sweep crossed points inside its call, not only its end.
(test-equal "precondition: every lock sweep was suspended at least once before it reached a run that finished"
  '((count expired) (orphan expired) (firing expired) (close expired))
  (map (lambda (e)
         (list (car e)
               (if (and (sweep-ok? (cdr e)) (positive? (caddr e))) 'expired (cdr e))))
       lock-sweeps))

(test-equal "the sweeps' loop is torn down"
  'torn-down
  (guard (e (#t (list 'raised (describe e))))
    (uv-run sweep-loop 'nowait)
    (uv-loop-teardown! sweep-loop)
    'torn-down))

;; --- the race harness ------------------------------------------------------

;; Each race runs this many times, on fresh threads and loops each time.
(define race-runs 3)

;; How long a thread waits, in steps, for the other to start.
(define race-wait-cap 100000000)

;; How far past its rounds a thread carries on, as a multiple of them,
;; while it waits to see the other move or be seen moving by it.
(define race-extension 20)

;; repeat : exact-nonnegative-integer object -> list
(define (repeat n x)
  (if (zero? n) '() (cons x (repeat (- n 1) x))))

;; race-pair : ((exact-nonnegative-integer exact-nonnegative-integer -> boolean)
;;              -> object)
;;             -> (list verdict verdict moves moves)
;; Runs (WORK go-on?) on two new threads at once, and answers each thread's
;; verdict, then how often each saw the other's counter move while its own
;; WORK ran. WORK asks (go-on? ROUNDS I) before its round I, and does that
;; round only if the answer is true: past ROUNDS, a thread goes on while it
;; has not seen the other move or the other has not seen it move, unless
;; the other has finished, up to race-extension times ROUNDS. A thread whose
;; WORK raised answers (raised message), and one that never answered leaves
;; 'unset. Each thread first waits, up to race-wait-cap steps, for the other
;; to start, and both threads are joined before race-pair answers.
(define (race-pair work)
  (let ((progress (vector 0 0))
        (started (vector #f #f))
        (moves (vector 0 0))
        (finished (vector #f #f))
        (verdicts (vector 'unset 'unset)))
    (define (run me)
      (let ((other (- 1 me)))
        (vector-set! started me #t)
        (let wait ((k 0))
          (unless (or (vector-ref started other) (= k race-wait-cap))
            (wait (+ k 1))))
        (let ((seen (vector-ref progress other)))
          (define (go-on? rounds i)
            (vector-set! progress me i)
            (let ((now (vector-ref progress other)))
              (unless (= now seen)
                (set! seen now)
                (vector-set! moves me (+ (vector-ref moves me) 1))))
            (or (< i rounds)
                (and (< i (* race-extension rounds))
                     (not (vector-ref finished other))
                     (or (zero? (vector-ref moves me))
                         (zero? (vector-ref moves other))))))
          (vector-set! verdicts me
                       (guard (e (#t (list 'raised (describe e))))
                         (work go-on?)))
          (vector-set! finished me #t))))
    (let* ((first (fork-thread (lambda () (run 0))))
           (second (fork-thread (lambda () (run 1)))))
      (thread-join first)
      (thread-join second)
      (list (vector-ref verdicts 0) (vector-ref verdicts 1)
            (vector-ref moves 0) (vector-ref moves 1)))))

;; race : ((-> unspecified) -> object) -> (listof race-pair-answer)
;; race-runs answers of race-pair, run one after another.
(define (race work)
  (let next ((i 0) (acc '()))
    (if (= i race-runs)
        (reverse acc)
        (next (+ i 1) (cons (race-pair work) acc)))))

;; verdicts : (listof race-pair-answer) -> (listof (list verdict verdict))
(define (verdicts answers)
  (map (lambda (a) (list (car a) (cadr a))) answers))

;; overlap : (listof race-pair-answer) -> (listof (list symbol symbol))
;; For each run, whether each thread saw the other move.
(define (overlap answers)
  (map (lambda (a)
         (list (if (positive? (caddr a)) 'moved 'still)
               (if (positive? (cadddr a)) 'moved 'still)))
       answers))

;; teardown-verdict : uv-loop object -> object
;; ANSWER once LOOP is torn down, or what the teardown raised.
(define (teardown-verdict loop answer)
  (guard (e (#t (list 'teardown-raised (describe e))))
    (uv-loop-teardown! loop)
    answer))

;; --- the work each thread does ---------------------------------------------

;; Each round registers a timer, and its close deregisters it in the run
;; that follows: the registry's add, its lookup in the close callback's
;; seam, and its delete.
(define timer-rounds 2000)

(define (make-and-close-timers go-on?)
  (let ((loop (make-uv-loop)))
    (let next ((i 0))
      (when (go-on? timer-rounds i)
        (uv-close! (make-uv-timer loop))
        (uv-run loop 'nowait)
        (next (+ i 1))))
    (teardown-verdict loop 'ok)))

;; Each round asks whether the loop's one timer is in the loop's queue: a
;; reset of the walk's cell, a walk that collects one pointer, and a read.
(define walk-rounds 20000)

(define (ask-about-own-timer go-on?)
  (let* ((loop (make-uv-loop))
         (timer (make-uv-timer loop)))
    (let next ((i 0) (missed 0))
      (if (go-on? walk-rounds i)
          (next (+ i 1)
                (if (handle-in-loop-queue? loop timer) missed (+ missed 1)))
          (begin (uv-close! timer)
                 (teardown-verdict loop (list 'missed missed)))))))

;; Each round spawns a file that does not exist. libuv reports the failed
;; exec as ENOENT with the process handle still in the loop's queue, which
;; the spawn finds by a walk, and closes; the run that follows delivers the
;; close (ADR-0015).
(define spawn-rounds 40)

(define (spawn-missing-files go-on?)
  (let ((loop (make-uv-loop)))
    (let next ((i 0) (other '()))
      (if (go-on? spawn-rounds i)
          (let ((outcome
                 (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
                           (#t (list 'raised (describe e))))
                   (uv-spawn! loop "/nonexistent/chez-libuv-loop-threads"
                              '("chez-libuv-loop-threads") #f)
                   'spawned)))
            (uv-run loop 'nowait)
            (next (+ i 1) (if (eq? outcome 'ENOENT) other (cons outcome other))))
          (teardown-verdict loop (list 'not-enoent (reverse other)))))))

;; Each round records an orphan event, as a seam does for a callback whose
;; pointer nothing registered.
(define orphan-rounds 20000)

(define (orphan-tag) 'loop-threads-probe)

;; It answers how many it recorded, since a thread can go past its rounds.
(define (record-orphans go-on?)
  (let next ((i 0))
    (if (go-on? orphan-rounds i)
        (begin (record-orphan-callback! (orphan-tag) i)
               (next (+ i 1)))
        (list 'recorded i))))

;; Each round counts a timer made and freed, as a constructor and a close
;; dispatcher do, through the debug shim's counters.
(define counter-rounds 100000)

(define (count-and-uncount go-on?)
  (let next ((i 0))
    (if (go-on? counter-rounds i)
        (begin (count-timer-new!)
               (count-timer-free!)
               (next (+ i 1)))
        'counted)))

;; tagged-orphans : -> exact-nonnegative-integer
(define (tagged-orphans)
  (let count ((events (orphan-callback-events)) (n 0))
    (cond ((null? events) n)
          ((eq? (caar events) (orphan-tag)) (count (cdr events) (+ n 1)))
          (else (count (cdr events) n)))))

;; --- the races ---------------------------------------------------------------

(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] the races between two loops' threads:")
      (display " skipped under Valgrind, which runs one thread at a time")
      (newline))
    (let ((timers (race make-and-close-timers)))
      (test-equal "two loops on two threads make and close timers at once, and neither thread raises"
        (repeat race-runs '(ok ok))
        (verdicts timers))
      (test-equal "precondition: in every timer race, each thread saw the other move during its own run"
        (repeat race-runs '(moved moved))
        (overlap timers))

      (let ((walks (race ask-about-own-timer)))
        (test-equal "a walk of one loop finds that loop's timer every time, while another thread walks its own loop"
          (repeat race-runs '((missed 0) (missed 0)))
          (verdicts walks))
        (test-equal "precondition: in every walk race, each thread saw the other move during its own run"
          (repeat race-runs '(moved moved))
          (overlap walks)))

      (let ((spawns (race spawn-missing-files)))
        (test-equal "two loops on two threads spawn a missing file at once, and each spawn fails with ENOENT alone"
          (repeat race-runs '((not-enoent ()) (not-enoent ())))
          (verdicts spawns))
        (test-equal "precondition: in every spawn race, each thread saw the other move during its own run"
          (repeat race-runs '(moved moved))
          (overlap spawns)))

      (let* ((before (tagged-orphans))
             (orphans (race record-orphans))
             (recorded (apply + (map (lambda (v) (if (and (pair? v) (eq? (car v) 'recorded))
                                                     (cadr v)
                                                     0))
                                     (apply append (verdicts orphans))))))
        (test-equal "orphan events recorded by two threads at once are all kept"
          (list 'kept recorded)
          (list (if (for-all (lambda (v) (and (pair? v) (eq? (car v) 'recorded)))
                             (apply append (verdicts orphans)))
                    'kept
                    (verdicts orphans))
                (- (tagged-orphans) before)))
        (test-equal "precondition: in every orphan race, each thread saw the other move during its own run"
          (repeat race-runs '(moved moved))
          (overlap orphans)))

      ;; Against the release shim, whose counters are always 0, this holds
      ;; trivially; the suites run against the debug shim.
      (let* ((before (cdr (assq 'timer (live-counts))))
             (counts (race count-and-uncount)))
        (test-equal "the debug counters keep every update two threads make at once"
          (list (repeat race-runs '(counted counted)) before)
          (list (verdicts counts) (cdr (assq 'timer (live-counts)))))
        (test-equal "precondition: in every counter race, each thread saw the other move during its own run"
          (repeat race-runs '(moved moved))
          (overlap counts)))))

;; --- balance -----------------------------------------------------------------

(test-equal "every allocation counter is back where it started, once both threads of every race are done"
  counts-at-start (live-counts))

(test-equal "the registry is back to its starting size"
  registry-at-start (registry-count))

(test-end "loop-threads")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
