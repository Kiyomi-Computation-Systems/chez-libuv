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
;;;   handle in a loop's queue was reported as out of it. uv-spawn! asks
;;;   that to decide how to clean up a failed spawn (ADR-0015), but there
;;;   the window is too narrow to race: two threads spawning at once passed
;;;   under every mutation (.plans/registry-lock-mutation-log.md). So the
;;;   walk race asks handle-in-loop-queue? directly;
;;; - the orphan event list, which lost events;
;;; - the debug shim's allocation counters, which lost updates.
;;;
;;; Each race below runs the same work on two threads at once, each on a
;;; loop of its own, and asks for what one thread alone would see. On a
;;; broken build a race is lost within a few hundred rounds, and the row
;;; fails by name with what each thread saw. Two threads that ran one after
;;; the other would pass every row, so each thread also notes whether the
;;; other's progress moved during its own run, and a precondition row
;;; requires both to have seen it move. A thread whose rounds are done
;;; carries on until each has seen the other move, or the other has
;;; finished: a schedule that runs the two apart only makes a race longer.
;;; Every wait on the other thread gives up at race-time-cap, which bounds
;;; how long a broken build takes to show itself. Valgrind runs one thread
;;; at a time, so under it the races are skipped (CHEZ_LIBUV_UNDER_VALGRIND).
;;;
;;; No verdict on a correct build depends on timing: each race asks only
;;; for what every schedule gives. Timing decides only how soon a broken
;;; build loses.
;;;
;;; The registry and the orphan list now hold one lock, which every loop's
;;; thread takes, so no thread may ever keep it. It is taken and released
;;; only with interrupts disabled (with-step-lock), so no engine is
;;; suspended while its thread holds it: an engine dropped there, as a
;;; timeout drops one, would keep the lock for good, and every other loop's
;;; thread would wait on it. The sweeps run the calls that cross trap
;;; checks on their way to and from the lock in an engine at fuel 1, 2,
;;; ..., and at each expiry ask another thread whether the lock is free.
;;; They need no race, so they run under Valgrind too.
;;;
;;; NOT pure: it runs loops. Never add this to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop) (libuv handle) (libuv timer)
        (only (libuv process) uv-spawn!)
        (libuv private conditions)
        (only (libuv private native) live-counts
              count-loop-new! count-loop-free! count-tcp-new! count-tcp-free!
              count-timer-new! count-timer-free!
              count-write-req-new! count-write-req-free!
              count-connect-req-new! count-connect-req-free!
              count-getaddrinfo-req-new! count-getaddrinfo-req-free!
              count-getnameinfo-req-new! count-getnameinfo-req-free!
              count-read-buffer-new! count-read-buffer-free!
              count-pipe-new! count-pipe-free!
              count-process-new! count-process-free!
              count-spawn-options-new! count-spawn-options-free!
              count-signal-new! count-signal-free!
              count-async-new! count-async-free!)
        (only (libuv private handles)
              registry-count registry-lock with-step-lock handle-in-loop-queue?
              registry-register! registry-deregister!
              record-orphan-callback! orphan-callback-events)
        (only (uv-evidence) describe live-count print-actual-on-failure!)
        (only (chezscheme) fork-thread thread-join getenv make-engine make-list
              real-time disable-interrupts enable-interrupts
              make-mutex make-condition with-mutex mutex-acquire mutex-release
              condition-wait condition-broadcast))

(define runner (test-runner-simple))
(test-runner-current runner)

;; Each row returns its evidence when it fails, so print that too.
(print-actual-on-failure! runner)

(test-begin "loop-threads")

;; Taken before any race: the work below must leave both where it found
;; them.
(define counts-at-start (live-counts))
(define registry-at-start (registry-count))

;; --- the lock, seen from another thread --------------------------------------

;; lock-seen-from-another-thread : mutex -> (or 'free 'held list)
;; The probe thread tries MUTEX without blocking and answers what it found.
;; It is one thread for the whole suite: Chez mutexes are recursive, so only
;; a thread that does not hold a lock can see it held, and a new thread can
;; be given the id of one that has exited, and with it any lock that thread
;; still held (tests/test-async-fence.sps). It tries the lock with
;; interrupts disabled, as every holder in src/ takes it, so nothing stops
;; it while it holds the lock.
(define probe-lock (make-mutex))
(define probe-changed (make-condition))
(define probe-request #f)
(define probe-answer #f)

(define (serve-probes)
  (let serve ()
    (let ((m (with-mutex probe-lock
               (let wait ()
                 (or probe-request
                     (begin (condition-wait probe-changed probe-lock) (wait)))))))
      (let ((answer (guard (e (#t (list 'raised (describe e))))
                      (disable-interrupts)
                      (let ((free? (mutex-acquire m #f)))
                        (when free? (mutex-release m))
                        (enable-interrupts)
                        (if free? 'free 'held)))))
        (with-mutex probe-lock
          (set! probe-request #f)
          (set! probe-answer answer)
          (condition-broadcast probe-changed))
        (serve)))))

(fork-thread serve-probes)

(define (lock-seen-from-another-thread m)
  (with-mutex probe-lock
    (set! probe-answer #f)
    (set! probe-request m)
    (condition-broadcast probe-changed)
    (let wait ()
      (or probe-answer
          (begin (condition-wait probe-changed probe-lock) (wait))))))

;; Every row below that finds the lock free is empty unless the probe can
;; see it held. So first, the probe sees the lock this thread holds. This
;; thread holds it with interrupts enabled, unlike every holder in src/,
;; because it waits on the probe while it holds it: a wait with interrupts
;; disabled would keep this thread active, and a collection the probe
;; asked for would wait on it for good. That is safe only because no other
;; thread takes the registry's lock yet: no loop thread exists before the
;; races.
(test-equal "another thread sees the registry's lock held while this thread holds it"
  '(held free)
  (let* ((while-held (with-mutex registry-lock
                       (lock-seen-from-another-thread registry-lock)))
         (after (lock-seen-from-another-thread registry-lock)))
    (list while-held after)))

;; with-step-lock hands back each value its body answers, however many, and
;; releases its lock either way: a body that answers two values, as
;; hashtable-entries does, must not raise inside the lock and keep it.
(define step-lock (make-mutex))

(test-equal "with-step-lock answers each of its body's values, and leaves its lock free"
  '((1 2) () free)
  (let* ((two (call-with-values (lambda () (with-step-lock step-lock (values 1 2)))
                list))
         (none (call-with-values (lambda () (with-step-lock step-lock (values)))
                 list)))
    (list two none (lock-seen-from-another-thread step-lock))))

;; A refused registration or deregistration raises after the registry's
;; lock is released, never inside it: a raise there would leave the lock
;; held and interrupts disabled, and every other loop's thread would wait
;; for it. So the caller's handler runs with the lock free.
(define sweep-loop (make-uv-loop))

;; A pointer no allocation returns.
(define refusal-ptr 4096)

;; refused-with-lock : (-> object) -> (list object (or 'free 'held list))
;; The reason CALL was refused, and the lock as another thread sees it from
;; inside the caller's handler; 'not-refused if CALL returned.
(define (refused-with-lock call)
  (call/cc
    (lambda (k)
      (with-exception-handler
        (lambda (e)
          (k (list (if (uv-invalid-argument? e) (uv-invalid-argument-reason e) (describe e))
                   (lock-seen-from-another-thread registry-lock))))
        (lambda () (call) 'not-refused)))))

(test-equal "a refused deregistration reaches the caller's handler with the registry's lock free"
  '(pointer-not-registered free)
  (refused-with-lock (lambda () (registry-deregister! refusal-ptr))))

(test-equal "a refused registration reaches the caller's handler with the registry's lock free"
  '(pointer-already-registered free)
  (begin
    (registry-register! refusal-ptr 'refusal-probe sweep-loop 'probe)
    (let ((answer (refused-with-lock
                   (lambda ()
                     (registry-register! refusal-ptr 'refusal-probe sweep-loop 'probe)))))
      (registry-deregister! refusal-ptr)
      answer)))

;; --- the lock across engine suspensions --------------------------------------

;; The most fuel a sweep tries before it gives up on reaching a run that
;; finishes with no expiry.
(define lock-sweep-cap 5000)

;; lock-sweep : (-> (-> object)) -> (list (list-of (list fuel answer)) expiries reached)
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
                   (let ((seen (lock-seen-from-another-thread registry-lock)))
                     (suspended 10000000
                                (lambda (ticks value) #f)
                                (lambda (more) #f))
                     seen)))))
          (if (eq? outcome 'finished)
              (list (reverse held) expiries 'reached)
              (sweep (+ fuel 1)
                     (if (eq? outcome 'free) held (cons (list fuel outcome) held))
                     (+ expiries 1)))))))

;; The calls that take the lock with interrupts enabled and cross trap
;; checks on their way to and from it: a timer's firing, whose seam looks
;; the timer up, and a close, whose seam looks the handle up and whose
;; dispatcher deregisters it, each delivered by a uv-run. An engine that
;; took the lock with interrupts enabled would expire holding it at one of
;; those checks. The registry's readers and the orphan list cross none
;; between taking the lock and releasing it, so no engine can expire there
;; whatever the lock's macro does, and every site goes through that one
;; macro (rule 6 of tests/test-source-rules.sps).

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
;; caught as the sweep's answer, in a sweep's shape, for the rows to carry.
(define lock-sweeps
  (let next ((todo (list (cons 'firing firing-call) (cons 'close close-call)))
             (acc '()))
    (if (null? todo)
        (reverse acc)
        (next (cdr todo)
              (cons (cons (caar todo)
                          (guard (e (#t (list (list (list 'sweep-raised (describe e)))
                                              0 'raised)))
                            (lock-sweep (cdar todo))))
                    acc)))))

(display "  [informational] lock sweeps, expiries before a run finished:")
(for-each (lambda (e) (display " ") (display (car e)) (display " ") (display (caddr e)))
          lock-sweeps)
(newline)

(test-equal "no engine is suspended holding the registry's lock: at every expiry in each sweep, another thread finds it free"
  '((firing () reached) (close () reached))
  (map (lambda (e) (list (car e) (cadr e) (cadddr e))) lock-sweeps))

(test-equal "precondition: every lock sweep was suspended at least once before it reached a run that finished"
  '((firing expired) (close expired))
  (map (lambda (e) (list (car e) (if (positive? (caddr e)) 'expired (cdr e))))
       lock-sweeps))

(test-equal "the sweeps' loop is torn down"
  'torn-down
  (guard (e (#t (list 'raised (describe e))))
    (uv-run sweep-loop 'nowait)
    (uv-loop-teardown! sweep-loop)
    'torn-down))

;; --- the counters across threads ---------------------------------------------

;; Every counter row below compares counts this thread reads. They are
;; empty unless a count another thread makes reaches this thread: against
;; a release shim every count is 0, and counters kept per thread would
;; balance on each thread whatever the races did.
(test-equal "seed: a timer counted on another thread moves this thread's count by one, and its free moves it back"
  '(1 0)
  (let* ((before (live-count 'timer))
         (made (begin (thread-join (fork-thread (lambda () (count-timer-new!))))
                      (- (live-count 'timer) before)))
         (freed (begin (thread-join (fork-thread (lambda () (count-timer-free!))))
                       (- (live-count 'timer) before))))
    (list made freed)))

;; --- the race harness ------------------------------------------------------

;; Each race runs this many times, on fresh threads and loops each time.
(define race-runs 3)

;; How long, in milliseconds, a race thread waits on the other: to start,
;; and past its own rounds, to be seen moving or to see the other move. It
;; bounds only how long a broken build takes to show itself; on a correct
;; build the two threads meet long before it.
(define race-time-cap 10000)

;; race-pair : ((exact-nonnegative-integer exact-nonnegative-integer -> boolean)
;;              -> object)
;;             -> (list verdict verdict boolean boolean)
;; Runs (WORK go-on?) on two new threads at once, and answers each thread's
;; verdict, then whether each saw the other's progress move while its own
;; WORK ran. WORK asks (go-on? ROUNDS I) before its round I, and does that
;; round only if the answer is true. Past ROUNDS a thread goes on until
;; each has seen the other move or the other has finished, bounded by the
;; other thread's progress, never by a count of its own (#74). A thread
;; whose WORK raised answers (raised message). Each thread first waits for
;; the other to start, and both threads are joined before race-pair answers.
(define (race-pair work)
  (let ((progress (vector 0 0))
        (started (vector #f #f))
        (moved (vector #f #f))
        (verdicts (vector 'unset 'unset)))
    (define (run me)
      (let ((other (- 1 me))
            (deadline (+ (real-time) race-time-cap)))
        (vector-set! started me #t)
        (let wait ()
          (unless (or (vector-ref started other) (> (real-time) deadline))
            (wait)))
        (let ((seen (vector-ref progress other)))
          (define (go-on? rounds i)
            (vector-set! progress me i)
            (let ((now (vector-ref progress other)))
              (unless (= now seen)
                (set! seen now)
                (vector-set! moved me #t)))
            (or (< i rounds)
                (and (eq? (vector-ref verdicts other) 'unset)
                     (not (and (vector-ref moved me) (vector-ref moved other)))
                     (<= (real-time) deadline))))
          (vector-set! verdicts me
                       (guard (e (#t (list 'raised (describe e))))
                         (work go-on?))))))
    (let* ((first (fork-thread (lambda () (run 0))))
           (second (fork-thread (lambda () (run 1)))))
      (thread-join first)
      (thread-join second)
      (list (vector-ref verdicts 0) (vector-ref verdicts 1)
            (vector-ref moved 0) (vector-ref moved 1)))))

;; race : ((exact-nonnegative-integer exact-nonnegative-integer -> boolean)
;;         -> object)
;;        -> (listof race-pair-answer)
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
         (list (if (caddr a) 'moved 'still)
               (if (cadddr a) 'moved 'still)))
       answers))

;; overlap-row : string (listof race-pair-answer) -> unspecified
;; The precondition every race's rows rest on.
(define (overlap-row race-name answers)
  (test-equal (string-append "precondition: in every " race-name
                             " race, each thread saw the other move during its own run")
    (make-list race-runs '(moved moved))
    (overlap answers)))

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
;; The walk delivers its pointers through the walk dispatcher, which
;; (libuv process)'s body installs: uv-spawn! is the one caller in src/.
;; A reference to one of that library's exports runs its body before this
;; program's own code.
(define walk-dispatcher-installed-by uv-spawn!)

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

;; Each round records an orphan event, as a seam does for a callback whose
;; pointer nothing registered.
(define orphan-rounds 20000)

(define orphan-tag 'loop-threads-probe)

;; It answers how many it recorded, since a thread can go past its rounds.
(define (record-orphans go-on?)
  (let next ((i 0))
    (if (go-on? orphan-rounds i)
        (begin (record-orphan-callback! orphan-tag i)
               (next (+ i 1)))
        (list 'recorded i))))

;; recorded? : object -> boolean
(define (recorded? v) (and (pair? v) (eq? (car v) 'recorded)))

;; tagged-orphans : -> exact-nonnegative-integer
(define (tagged-orphans)
  (let count ((events (orphan-callback-events)) (n 0))
    (cond ((null? events) n)
          ((eq? (caar events) orphan-tag) (count (cdr events) (+ n 1)))
          (else (count (cdr events) n)))))

;; Each round counts one of everything made and freed, as constructors and
;; close dispatchers do, through every one of the debug shim's counters.
(define counter-pairs
  (list (cons count-loop-new! count-loop-free!)
        (cons count-tcp-new! count-tcp-free!)
        (cons count-timer-new! count-timer-free!)
        (cons count-write-req-new! count-write-req-free!)
        (cons count-connect-req-new! count-connect-req-free!)
        (cons count-getaddrinfo-req-new! count-getaddrinfo-req-free!)
        (cons count-getnameinfo-req-new! count-getnameinfo-req-free!)
        (cons count-read-buffer-new! count-read-buffer-free!)
        (cons count-pipe-new! count-pipe-free!)
        (cons count-process-new! count-process-free!)
        (cons count-spawn-options-new! count-spawn-options-free!)
        (cons count-signal-new! count-signal-free!)
        (cons count-async-new! count-async-free!)))

(define counter-rounds 20000)

(define (count-and-uncount go-on?)
  (let next ((i 0))
    (if (go-on? counter-rounds i)
        (begin (for-each (lambda (pair) ((car pair)) ((cdr pair))) counter-pairs)
               (next (+ i 1)))
        'counted)))

;; --- the races ---------------------------------------------------------------

(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] the races between two loops' threads:")
      (display " skipped under Valgrind, which runs one thread at a time")
      (newline))
    (begin
      (let ((timers (race make-and-close-timers)))
        (test-equal "two loops on two threads make and close timers at once, and neither thread raises"
          (make-list race-runs '(ok ok))
          (verdicts timers))
        (overlap-row "timer" timers))

      (let ((walks (race ask-about-own-timer)))
        (test-equal "a walk of one loop finds that loop's timer every time, while another thread walks its own loop"
          (make-list race-runs '((missed 0) (missed 0)))
          (verdicts walks))
        (overlap-row "walk" walks))

      (let* ((before (tagged-orphans))
             (orphans (race record-orphans))
             (answers (apply append (verdicts orphans)))
             (recorded (apply + (map (lambda (v) (if (recorded? v) (cadr v) 0)) answers))))
        (test-equal "orphan events recorded by two threads at once are all kept"
          (list 'kept recorded)
          (list (if (for-all recorded? answers) 'kept (verdicts orphans))
                (- (tagged-orphans) before)))
        (overlap-row "orphan" orphans))

      (let* ((before (live-counts))
             (counts (race count-and-uncount)))
        (test-equal "the debug counters keep every update two threads make at once"
          (list (make-list race-runs '(counted counted)) before)
          (list (verdicts counts) (live-counts)))
        (overlap-row "counter" counts))))

;; --- balance -----------------------------------------------------------------

(test-equal "every allocation counter is back where it started, once both threads of every race are done"
  counts-at-start (live-counts))

(test-equal "the registry is back to its starting size"
  registry-at-start (registry-count))

(test-end "loop-threads")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
