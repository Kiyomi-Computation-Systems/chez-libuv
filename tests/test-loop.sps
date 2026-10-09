#!r6rs
;;; SRFI-64 suite for (libuv loop) and the registry core of
;;; (libuv private handles) -- design spec S5 (loop operations, the registry
;;; as GC root), S8 (the store-and-reraise callback error policy), S10 (debug
;;; counters), S11 (testing strategy), and ADR-0008 (thirteen dispatcher
;;; slots, as amended through #45).
;;;
;;; This suite is NOT pure: (libuv loop) reaches (libuv private native),
;;; which loads libuv and the shim at library instantiation. It must never
;;; appear in the Makefile's PURE_TESTS.
;;;
;;; Tests import the private libraries directly and on purpose. The loop
;;; record's raw fields (loop-ptr, loop-state, loop-pending-error, ...) are
;;; where several design-spec decisions actually live -- "the freeing site
;;; zeroes the stored uptr immediately" (S10) is a statement about a field,
;;; and an assertion on the public surface alone cannot see it.
;;;
;;; THE DISPATCHER SLOTS AND THE CLOSE HOOK ARE ALREADY INSTALLED HERE. Both
;;; are process-global and install-once, and (libuv private handles) fills
;;; them in its own library body -- which this suite's import chain runs
;;; before the first test line. Their uninstalled behaviour is asserted in
;;; tests/test-native.sps instead, the one suite that never imports
;;; handles.sls; see the section below for why that split exists.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        ;; Stage 3: the teardown sweep is exercised with a REAL handle now,
        ;; so this suite needs the timer constructor and the generic handle
        ;; state accessor. Nothing else here goes through them.
        (libuv handle)
        (libuv timer)
        (libuv private handles)
        (libuv private conditions)
        ;; `only` rather than a plain import: (libuv private native) exports
        ;; uv-version, which the (libuv) facade also exports under the same
        ;; name as a different binding. Nothing here needs it -- the facade's
        ;; own surface is tests/test-facade.sps's job.
        (only (libuv private native)
              native-initialized? live-counts uv-loop-size
              dispatcher-names dispatcher-ref dispatchers-installed?
              install-callback-dispatchers!
              ;; v0.2 Stage 3: the synthetic handle-less request blocks the
              ;; ADR-0011 rows below build are real foreign allocations, so
              ;; complete-request!'s free! sees the same kind of pointer the
              ;; Stage 4 dispatchers will hand it.
              alloc-zeroed
              ;; The uv-update-time! affinity rows compare against it.
              current-thread-id)
        ;; step-refusal's errno row names an errno by its symbol.
        (only (libuv private constants) errno-symbol->value)
        ;; The uv-update-time! rows step their loops with the shared capped
        ;; stepper rather than a hand-rolled one.
        (only (uv-testing) run-until)
        (only (uv-evidence) live-count describe)
        ;; sleep and make-time pace the uv-update-time! rows' wait for the
        ;; clock to advance; that wait is bounded by a poll count, not by them.
        ;; make-engine suspends a run inside a callback (#45); getenv and
        ;; open-process-ports run tests/stranded-exit-child.sps.
        (only (chezscheme) collect sleep make-time make-engine
              getenv open-process-ports))

;; SRFI-64's default runner does not set a process exit code (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; Captured BEFORE anything in this suite creates a loop, so the seeds below
;; are real observations rather than restatements of the current state.
(define native-initialized-at-start (native-initialized?))
(define registry-count-at-start (registry-count))


(test-begin "loop")

;; --- seeds --------------------------------------------------------------
;; Every counter assertion in this suite requires the DEV shim (the
;; Makefile's CFLAGS_DEV, -DCHEZ_LIBUV_DEBUG_COUNTERS). Against a production
;; shim the live queries always answer 0, so the "moved" assertions would
;; fail while pointing at cross-wiring that is not there. Name that
;; precondition first, the way tests/test-native.sps does.
(test-equal "seed: no loop is live before this suite creates one"
  0 (live-count 'loop))

(test-equal "seed: the handle registry is empty before this suite registers anything"
  0 registry-count-at-start)

(test-equal "seed: the native layer is not initialised before the first make-uv-loop"
  #t (not native-initialized-at-start))

;; --- make-uv-loop -------------------------------------------------------
(define l0 (make-uv-loop))

(test-equal "make-uv-loop initialises the native layer itself"
  #t (native-initialized?))

(test-equal "make-uv-loop returns a uv-loop record"
  'a-loop (if (uv-loop? l0) 'a-loop 'not-a-loop))

(test-equal "a fresh loop is open"
  'open (if (uv-loop-open? l0) 'open 'not-open))

(test-equal "a fresh loop's state field reads 'open"
  'open (loop-state l0))

;; A real foreign-alloc'd block: positive, and exactly one loop-sized block
;; is what make-uv-loop was asked for. `positive?` is the discriminating
;; part -- 0 is what a zeroed (freed) slot holds.
(test-equal "make-uv-loop stores a non-null loop pointer"
  'positive
  (if (and (integer? (loop-ptr l0)) (exact? (loop-ptr l0)) (positive? (loop-ptr l0)))
      'positive
      'null-or-not-a-pointer))

(test-equal "seed: creating a loop moves the live loop counter"
  1 (live-count 'loop))

(test-equal "make-uv-loop registers the loop in the handle registry"
  1 (- (registry-count) registry-count-at-start))

(test-equal "the registry entry resolves the loop pointer back to the loop record"
  'same (if (eq? l0 (registry-ref (loop-ptr l0))) 'same 'different))

;; The loop is registered, but it is NOT one of its own live handles: the
;; snapshot filters on the entry kind, and a loop that swept itself would
;; hand its own record to close-handle! during teardown.
(test-equal "a fresh loop reports no live handles (and never itself)"
  '() (uv-loop-live-handles l0))

(test-equal "a fresh loop has no deferred errors"
  '() (uv-loop-deferred-errors l0))

(test-equal "a fresh loop is not marked running"
  'not-running (if (loop-running? l0) 'running 'not-running))

;; --- uv-run over an empty loop ------------------------------------------
;; Asserted as 'no-work / 'work rather than #f / #t: SRFI-64 turns a raise in
;; the actual expression into #f, so an expected-#f assertion would pass if
;; uv-run blew up, and in Scheme every value except #f is true, so
;; test-assert would pass on the raw int a truthiness-confused uv-run
;; returned (AGENTS.md).
(test-equal "uv-run 'default on an empty loop reports no work remaining"
  'no-work (if (uv-run l0 'default) 'work 'no-work))

(test-equal "uv-run 'once on an empty loop reports no work remaining"
  'no-work (if (uv-run l0 'once) 'work 'no-work))

(test-equal "uv-run 'nowait on an empty loop reports no work remaining"
  'no-work (if (uv-run l0 'nowait) 'work 'no-work))

;; Also proves the running? flag is cleared on the way out: a uv-run that
;; left it set would make every subsequent uv-run raise 'loop-running.
(test-equal "uv-run defaults to 'default when no mode is given"
  'no-work (if (uv-run l0) 'work 'no-work))

(test-equal "uv-run leaves the running flag clear after it returns"
  'not-running (if (loop-running? l0) 'running 'not-running))

(test-equal "uv-run rejects an unknown mode, naming who and why"
  '(uv-run unknown-run-mode)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-run l0 'sideways)
    'no-raise))

(test-equal "uv-run rejects a non-loop argument, naming who and why"
  '(uv-run not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-run 'not-a-loop 'nowait)
    'no-raise))

;; --- uv-loop-alive? -----------------------------------------------------
;; An empty loop is not alive before or after a run; the TRANSITION needs a
;; handle to hold the loop alive, which arrives with Task 7's timers. See
;; .plans/stage-2-mutation-log.md, "deferred coverage".
(test-equal "an empty loop is not alive"
  'not-alive (if (uv-loop-alive? l0) 'alive 'not-alive))

(test-equal "an empty loop is still not alive after a run"
  'not-alive
  (begin (uv-run l0 'nowait)
         (if (uv-loop-alive? l0) 'alive 'not-alive)))

;; --- uv-now -------------------------------------------------------------
(define now-before (uv-now l0))
(define now-run-result (uv-run l0 'nowait))
(define now-after (uv-now l0))

(test-equal "uv-now returns a positive exact integer (libuv's cached millisecond clock)"
  'positive-exact
  (if (and (integer? now-before) (exact? now-before) (positive? now-before))
      'positive-exact
      'not-a-timestamp))

(test-equal "uv-now does not go backwards across a run"
  'monotone (if (>= now-after now-before) 'monotone 'went-backwards))

;; --- uv-update-time! (issue #28) ----------------------------------------
;; uv-now is a CACHE: libuv refreshes it once per loop iteration, so a
;; callback that holds the loop leaves it behind, and a timer armed after that
;; callback is due relative to a "now" from before the callback ran.
;; uv-update-time! refreshes the cache on demand.
;;
;; THE REFERENCE CLOCK is a fresh loop per reading: uv_loop_init reads libuv's
;; clock into the new loop's cache (unix/loop.c and win/core.c both), so
;; `reference-now` reads the clock uv-update-time! reads without going through
;; the binding under test -- and without RUNNING any loop, so the scenario
;; below can take readings from inside another loop's callback without nesting
;; uv-run. Every assertion here is an ORDERING of readings of that one
;; monotonic clock. None measures an elapsed duration, so a slow host can only
;; widen the gaps they rely on, never close them.
(define (reference-now)
  (let* ((clock (make-uv-loop))
         (now (uv-now clock)))
    (uv-loop-close! clock)
    now))

;; Hold this thread until libuv's clock reads strictly past `threshold`, and
;; answer that first reading -- or 'clock-never-advanced once `cap` polls have
;; passed. The sleep only keeps the wait from spinning; the cap bounds it.
(define one-millisecond (make-time 'time-duration 1000000 0))

(define (await-clock-past threshold cap)
  (let poll ((i 0))
    (let ((now (reference-now)))
      (cond ((> now threshold) now)
            ((>= i cap) 'clock-never-advanced)
            (else (sleep one-millisecond) (poll (+ i 1)))))))

;; Outside a run. The cached now is read, the clock is let past it, and the
;; refreshed now must land between the reference readings either side of the
;; call. A refresh that did nothing leaves uv-now at the stale reading, which
;; the wait has already put strictly below `ut-before`.
(define ut-loop (make-uv-loop))
(define ut-stale (uv-now ut-loop))
(define ut-before (await-clock-past ut-stale 1000))
(define ut-outcome
  (guard (e (#t (list 'raised e)))
    (uv-update-time! ut-loop)
    'returned))
(define ut-fresh (uv-now ut-loop))
(define ut-after (reference-now))

(test-equal "precondition: libuv's clock moved past the loop's stale cached now"
  'advanced (if (number? ut-before) 'advanced ut-before))

(test-equal "uv-update-time! returns on an open loop"
  'returned ut-outcome)

(test-equal "uv-update-time! refreshes uv-now to libuv's current clock"
  'caught-up
  (if (and (number? ut-before) (<= ut-before ut-fresh ut-after))
      'caught-up
      (list 'stale ut-stale 'before ut-before 'fresh ut-fresh 'after ut-after)))

;; Runs nothing. A timer due at once is armed, and uv-update-time! must refresh
;; the clock without firing it: the loop fires timers, a refresh does not. A
;; refresh built on uv_run -- even NOWAIT, which never blocks -- would fire it.
;; The follow-up row runs the loop and watches the same timer fire, so the
;; zero read across the refresh is a timer that was due and live, not one that
;; could never have fired.
(define rn-loop (make-uv-loop))
(define rn-timer (make-uv-timer rn-loop))
(define rn-fires 0)
(uv-timer-start! rn-timer
                 (lambda (timer) (collect) (set! rn-fires (+ rn-fires 1)))
                 0 0)
(define rn-outcome
  (guard (e (#t (list 'raised e)))
    (uv-update-time! rn-loop)
    'returned))
(define rn-fires-across-refresh rn-fires)
(define rn-drive
  (guard (e (#t (list 'raised e)))
    (run-until rn-loop (lambda () (positive? rn-fires)) 32)))

(test-equal "uv-update-time! fires no timer, even one already due"
  'not-fired
  (if (and (eq? rn-outcome 'returned) (zero? rn-fires-across-refresh))
      'not-fired
      (list 'outcome rn-outcome 'fires rn-fires-across-refresh)))

(test-equal "...and that timer was live: the loop fires it once it runs"
  'satisfied rn-drive)

;; Loop thread only (ADR-0019, extended for #28). The owner field is pointed at
;; a thread id no real thread holds -- test-async.sps's technique, so no second
;; thread is needed -- and the refusal must come BEFORE the write: the clock is
;; let past the cached now first, so a check placed after the refresh would
;; leave uv-now moved even though the call raised. The positive control, the
;; same verb on the owning thread, is the refresh rows above.
(define foreign-owner 999999)
(define wt-loop (make-uv-loop))
(define wt-stale (uv-now wt-loop))
(define wt-advanced (await-clock-past wt-stale 1000))
(set-loop-owner-thread! wt-loop foreign-owner)
(define wt-refusal
  (guard (e ((uv-wrong-thread? e)
             (list (uv-wrong-thread-who e)
                   (uv-wrong-thread-expected e)
                   (uv-wrong-thread-actual e)))
            (#t 'wrong-condition))
    (uv-update-time! wt-loop)
    'no-raise))
(set-loop-owner-thread! wt-loop (current-thread-id))
(define wt-now-after-refusal (uv-now wt-loop))

(test-equal "uv-update-time! off the owning thread raises &uv-wrong-thread naming who, owner and caller"
  (list 'uv-update-time! foreign-owner (current-thread-id))
  wt-refusal)

(test-equal "a refused uv-update-time! leaves the cached now untouched"
  'untouched
  (if (and (number? wt-advanced) (= wt-now-after-refusal wt-stale))
      'untouched
      (list 'stale wt-stale 'clock wt-advanced 'after wt-now-after-refusal)))

;; Inside a run: the issue's own scenario. A callback holds the loop until
;; libuv's clock is `hold-ms` past the loop's cached now, calls
;; uv-update-time! -- with the loop RUNNING, which is the whole use case --
;; then arms a deadline `deadline-ms` out: chez-http-server's handler followed
;; by its write deadline. libuv arms a timer from the cached now (timer.c:
;; loop->time + timeout) and never fires one before loop->time reaches it, so
;; a deadline armed from the refreshed clock fires at a now at least
;; `deadline-ms` past the reference reading taken before the refresh.
;;
;; The hold is at least the deadline, so that a deadline armed from the STALE
;; now would already be overdue when the callback returns -- the issue's own
;; condition ("the write deadline had already passed when the loop's timers
;; next ran"). The two are separate constants, so a precondition row checks
;; the hold really carried the clock that far rather than trusting a comment.
;;
;; THE TRAFFIC TIMER IS WHAT MAKES THE DEADLINE ROW ABLE TO FAIL. libuv
;; computes its poll timeout from the cached now as well, so on a loop whose
;; only wakeup is the deadline, a deadline armed from the stale now still
;; sleeps its full timeout and looks right. Measured: with the refresh mutated
;; to a no-op and no traffic, the row passed at 26 ms. The issue's server is
;; never that quiet -- I/O wakes its loop, the clock is re-read, and the stale
;; deadline is found already overdue. A 1 ms repeating timer plays that
;; traffic, so a stale-armed deadline fires at the first wake after the hold
;; instead. A second precondition row checks the traffic really did land while
;; the deadline was pending. Like run-until/ticking's ticker, its callback
;; skips (collect): it is fixture, not code under test.
(define hold-ms 25)
(define deadline-ms 25)
(define sc-loop (make-uv-loop))
(define sc-trigger (make-uv-timer sc-loop))
(define sc-deadline (make-uv-timer sc-loop))
(define sc-traffic (make-uv-timer sc-loop))
(define sc-stale 'trigger-never-fired)
(define sc-armed-from 'trigger-never-fired)
(define sc-outcome 'trigger-never-fired)
(define sc-fired-at 'deadline-never-fired)
(define sc-wakes-while-pending 0)

(uv-timer-start! sc-trigger
                 (lambda (timer)
                   (collect)
                   (set! sc-stale (uv-now sc-loop))
                   (set! sc-armed-from
                         (await-clock-past (+ sc-stale hold-ms) 1000))
                   (set! sc-outcome
                         (guard (e (#t (list 'raised e)))
                           (uv-update-time! sc-loop)
                           'returned))
                   (uv-timer-start! sc-deadline
                                    (lambda (timer)
                                      (collect)
                                      (set! sc-fired-at (uv-now sc-loop)))
                                    deadline-ms 0))
                 0 0)

(uv-timer-start! sc-traffic
                 (lambda (timer)
                   (when (and (number? sc-armed-from)
                              (not (number? sc-fired-at)))
                     (set! sc-wakes-while-pending
                           (+ sc-wakes-while-pending 1))))
                 1 1)

;; Guarded, so a raise here fails the row below with its evidence instead of
;; aborting the suite (AGENTS.md). The traffic wakes the loop about once a
;; millisecond, so the deadline takes some `deadline-ms` steps; the cap is ten
;; times that.
(define sc-drive
  (guard (e (#t (list 'raised e)))
    (run-until sc-loop (lambda () (number? sc-fired-at)) (* 10 deadline-ms))))

(uv-timer-stop! sc-traffic)

(test-equal "the scenario ran through to the deadline's callback"
  'satisfied sc-drive)

(test-equal "precondition: the hold carried the clock past where a stale-armed deadline falls due"
  'overdue-if-stale
  (if (and (number? sc-stale) (number? sc-armed-from)
           (>= sc-armed-from (+ sc-stale deadline-ms)))
      'overdue-if-stale
      (list 'stale sc-stale 'armed-from sc-armed-from 'deadline-ms deadline-ms)))

(test-equal "precondition: traffic woke the loop while the deadline was pending"
  'woke
  (if (positive? sc-wakes-while-pending) 'woke sc-wakes-while-pending))

(test-equal "uv-update-time! returns when called from a callback while the loop runs"
  'returned sc-outcome)

(test-equal "a deadline armed after uv-update-time! runs from the refreshed clock, not the stale one"
  'from-refreshed-clock
  (if (and (number? sc-armed-from) (number? sc-fired-at)
           (>= sc-fired-at (+ sc-armed-from deadline-ms)))
      'from-refreshed-clock
      (list 'armed-from sc-armed-from 'fired-at sc-fired-at)))

(display "  [informational] uv-update-time! scenario: deadline fired ")
(display (if (and (number? sc-armed-from) (number? sc-fired-at))
             (- sc-fired-at sc-armed-from)
             (list sc-armed-from sc-fired-at)))
(display " ms after the pre-refresh reading (deadline ")
(display deadline-ms)
(display " ms, hold ")
(display hold-ms)
(display " ms; ")
(display sc-wakes-while-pending)
(display " traffic wakes while it was pending)")
(newline)

(test-equal "uv-update-time! rejects a non-loop argument, naming who and why"
  '(uv-update-time! not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-update-time! 'not-a-loop)
    'no-raise))

;; Each query refuses a non-loop on entry: its step reads the loop's
;; record, and nothing in a step may raise.
(test-equal "uv-stop!, uv-now and uv-loop-alive? reject a non-loop argument, naming who and why"
  '((uv-stop! not-a-uv-loop) (uv-now not-a-uv-loop) (uv-loop-alive? not-a-uv-loop))
  (map (lambda (query)
         (guard (e ((uv-invalid-argument? e)
                    (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
                   (#t 'wrong-condition))
           (query 'not-a-loop)
           'no-raise))
       (list uv-stop! uv-now uv-loop-alive?)))

;; A closed loop is refused as closed before its owner is asked, as
;; make-uv-async's order: closed, the loop has no owner left to run it.
(test-equal "uv-update-time! on a closed loop another thread owns is refused as closed"
  'loop
  (let ((l (make-uv-loop)))
    (uv-loop-close! l)
    (set-loop-owner-thread! l foreign-owner)
    (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
              ((uv-wrong-thread? e) 'wrong-thread)
              (#t 'wrong-condition))
      (uv-update-time! l)
      'no-raise)))

(uv-loop-teardown! sc-loop)
(uv-loop-teardown! rn-loop)
(uv-loop-close! wt-loop)
(uv-loop-close! ut-loop)

;; --- the thirteen callback dispatcher slots and the close hook (ADR-0008) -
;; Both are process-global and install-once, and as of Stage 3 both are
;; already filled before this suite's first line runs: (libuv private
;; handles) installs the thirteen dispatchers and the real close-handle! in its
;; own library body, and this suite imports it. So what is assertable HERE
;; is the installed state and the refusal of a second install.
;;
;; The pre-install state -- the raising stubs, the partial-install refusal,
;; the install itself -- is asserted in tests/test-native.sps, the one suite
;; whose import chain never reaches handles.sls and whose process therefore
;; still has empty slots. Moving those rows there rather than deleting them
;; is what keeps the uninstalled behaviour covered at all.
(test-equal "dispatcher-names names the thirteen callback types that cross into Scheme"
  '(read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo exit walk signal async)
  dispatcher-names)

(test-equal "importing (libuv private handles) has already installed the dispatchers"
  'installed (if (dispatchers-installed?) 'installed 'not-installed))

(test-equal "a second install is refused, naming who and why"
  '(uv-install-callback-dispatchers! dispatchers-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-callback-dispatchers!
     (map (lambda (name) (cons name (lambda args 'second))) dispatcher-names))
    'no-raise))

;; The refusal is not merely a raise: the slots must still hold handles.sls's
;; own dispatchers afterwards. A timer callback for a pointer the registry
;; does not know is the observable, side-effect-free way to ask -- the real
;; dispatcher records an orphan event and returns, where the raising stub
;; and any test-installed replacement would not.
(test-equal "the refused second install left handles.sls's dispatchers in place"
  'dispatched-by-handles
  (let ((before (length (orphan-callback-events))))
    ((dispatcher-ref 'timer) 5150)
    (if (equal? (list-tail (orphan-callback-events) before) '((timer . 5150)))
        'dispatched-by-handles
        'slot-was-rebound)))

(test-equal "the close-handle! hook was installed by handles.sls too"
  'installed (if (close-handle-installed?) 'installed 'not-installed))

(test-equal "a second close-handle! install is refused, naming who and why"
  '(uv-install-close-handle! close-handle-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-close-handle! (lambda (handle on-close) 'second))
    'no-raise))

(test-equal "the installed close-handle! refuses something that is not a handle"
  '(uv-close! not-a-uv-handle)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (close-handle! '(0 . not-a-handle))
    'no-raise))

;; --- the registry, directly ---------------------------------------------
(define other-loop (make-uv-loop))
(define fake-handle (cons 4242 'fake-timer))
(define registry-count-before-fake (registry-count))

(registry-register! (car fake-handle) 'timer l0 fake-handle)

(test-equal "registry-register! makes the entry retrievable by its pointer"
  'same (if (eq? fake-handle (registry-ref (car fake-handle))) 'same 'different))

(test-equal "registry-register! moves the registry count"
  1 (- (registry-count) registry-count-before-fake))

(test-equal "a registered handle appears in its own loop's live-handle snapshot"
  'listed
  (if (memq fake-handle (uv-loop-live-handles l0)) 'listed 'missing))

(test-equal "it does not appear in another loop's snapshot"
  '() (uv-loop-live-handles other-loop))

;; uv-loop-teardown! sweeps this snapshot and calls close-handle! on every
;; element, so it must contain HANDLES only. Requests live in the SAME table
;; (design spec S5: one registry "for both handles and requests
;; (discriminated by a kind field)"), and close-handle! rightly refuses
;; anything that is not a handle record -- so a snapshot that included
;; requests would make teardown raise 'not-a-uv-handle the moment a write was
;; in flight, which is exactly the state Stage 4's close-with-a-pending-write
;; row puts a loop in.
(define fake-req (cons 4243 'fake-write-req))
(registry-register! (car fake-req) 'write-req l0 fake-req)

(test-equal "seed: the request entry really is in the registry"
  'same (if (eq? fake-req (registry-ref (car fake-req))) 'same 'different))

(test-equal "a request entry is NOT in its loop's live-handle snapshot"
  'excluded
  (if (memq fake-req (uv-loop-live-handles l0)) 'included 'excluded))

(test-equal "the handle entry is still in that same snapshot"
  'listed (if (memq fake-handle (uv-loop-live-handles l0)) 'listed 'missing))

;; The close seam takes its pointer's entry out of the registry in the same
;; locked step that finds it (#87), and puts back one whose object is not a
;; handle: the close dispatcher records that as an orphan and frees nothing,
;; so the entry must stay where its owner left it.
(define close-orphans-before (length (orphan-callback-events)))
((dispatcher-ref 'close) (car fake-req))

(test-equal "the close seam leaves a request's entry in place, and records an orphan"
  (list 'same (list (cons 'close (car fake-req))))
  (list (if (eq? fake-req (registry-ref (car fake-req))) 'same 'disturbed)
        (list-tail (orphan-callback-events) close-orphans-before)))

(when (registry-ref (car fake-req)) (registry-deregister! (car fake-req)))

(test-equal "registering the same pointer twice is refused, naming who and why"
  '(uv-registry-register! pointer-already-registered)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-register! (car fake-handle) 'timer l0 fake-handle)
    'no-raise))

(test-equal "registry-register! rejects a null pointer, naming who and why"
  '(uv-registry-register! null-or-invalid-pointer)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-register! 0 'timer l0 fake-handle)
    'no-raise))

;; THE ENTRY'S LOOP FIELD IS THE SEAM GUARD'S LAST RESORT, and this is the
;; check that makes it total. `contain-dispatcher-raise!` -- the outermost
;; Scheme frame libuv can reach -- resolves a raised object's destination
;; with `registry-loop-of`, which reads THIS field, and then hands it to
;; `loop-record-error!`, whose own `require-loop` would RAISE on anything
;; that is not a loop record. That raise would be inside the guard's handler,
;; i.e. outside the guard, i.e. straight into a C stack frame (spike FINDINGS
;; Q2: exit 255, no teardown). Refusing the bad loop HERE, at the one place
;; the field is ever written, is what makes that unreachable by construction
;; rather than by hope.
(test-equal "registry-register! rejects an entry whose loop is not a uv-loop"
  '(uv-registry-register! loop-not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-register! 987654 'timer 'not-a-loop fake-handle)
    'no-raise))

(test-equal "the refused registration left nothing behind in the registry"
  'absent (if (registry-ref 987654) 'present 'absent))

(registry-deregister! (car fake-handle))

(test-equal "registry-deregister! removes the entry"
  'absent (if (registry-ref (car fake-handle)) 'present 'absent))

(test-equal "registry-deregister! returns the count to where it was"
  0 (- (registry-count) registry-count-before-fake))

(test-equal "deregistering an unregistered pointer is refused, naming who and why"
  '(uv-registry-deregister! pointer-not-registered)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-deregister! (car fake-handle))
    'no-raise))

;; --- the registry's step forms --------------------------------------------
;; A verb registers its request from inside an interrupt-free step, where a
;; raise would leave interrupts disabled for good (one-step). registry-add!
;; therefore answers each refusal registry-register! raises, and
;; registry-remove! tolerates an absent entry. SRFI-64 turns a raise into
;; #f, which none of these expected values is.
(define step-req (cons 4244 'fake-write-req))

(test-equal "registry-add! answers registered, and the entry is retrievable"
  '(registered same 1)
  (let* ((before (registry-count))
         (status (registry-add! (car step-req) 'write-req l0 step-req)))
    (list status
          (if (eq? step-req (registry-ref (car step-req))) 'same 'different)
          (- (registry-count) before))))

(test-equal "registry-add! answers each refusal registry-register! raises, and adds nothing"
  '(pointer-already-registered null-or-invalid-pointer loop-not-a-uv-loop
    same absent)
  (list (registry-add! (car step-req) 'timer l0 fake-handle)
        (registry-add! 0 'write-req l0 step-req)
        (registry-add! 4245 'write-req 'not-a-loop step-req)
        (if (eq? step-req (registry-ref (car step-req))) 'same 'replaced)
        (if (registry-ref 4245) 'present 'absent)))

(test-equal "registry-remove! removes an entry, and raises nothing for an absent one"
  '(absent absent)
  (begin
    (registry-remove! (car step-req))
    (let ((first (if (registry-ref (car step-req)) 'present 'absent)))
      (registry-remove! (car step-req))
      (list first (if (registry-ref (car step-req)) 'present 'absent)))))

;; step-refusal turns what a step answered into what its verb raises. The
;; closed handle or loop and the missing pointer are what require-open-handle,
;; require-open-loop and the checked accessors raise outside a step, so a verb
;; or constructor refuses the same way whichever check catches it.
(define (refusal-shape c)
  (cond ((uv-handle-closed? c) (list 'handle-closed (uv-handle-closed-kind c)))
        ((uv-wrong-thread? c)
         (list 'wrong-thread (uv-wrong-thread-who c)
               (uv-wrong-thread-expected c) (uv-wrong-thread-actual c)))
        ((uv-invalid-argument? c)
         (list 'invalid (uv-invalid-argument-who c) (uv-invalid-argument-reason c)))
        ((uv-errno-error? c) (list 'errno (condition-who c) (uv-errno-error-errno c)))
        (else (list 'other c))))

;; Two thread ids no thread here has, for owner checks that found them.
(define found-owner (+ (current-thread-id) 1))
(define found-caller (+ (current-thread-id) 2))

;; The owner-mismatch's owner, not the timer's loop's, which this thread
;; owns: built from a second read of that, the refusal named this thread.
(test-equal "step-refusal raises each status as the checks outside a step do"
  `((handle-closed timer)
    (wrong-thread uv-test-verb! ,found-owner ,(current-thread-id))
    (invalid uv-test-verb! null-handle-pointer)
    (handle-closed loop)
    (invalid uv-test-verb! null-loop-pointer)
    (errno uv-test-verb! ENOMEM)
    (invalid uv-registry-register! pointer-already-registered)
    (invalid uv-test-verb! span-out-of-range)
    (errno uv-test-verb! EBADF))
  (let* ((l (make-uv-loop))
         (t (make-uv-timer l))
         (shapes (map (lambda (status)
                        (refusal-shape (step-refusal status 'uv-test-verb! t)))
                      (list 'not-open (make-owner-mismatch found-owner (current-thread-id))
                            'no-pointer 'loop-not-open 'no-loop-pointer
                            'no-memory 'pointer-already-registered
                            'span-out-of-range (errno-symbol->value 'EBADF)))))
    (uv-loop-teardown! l)
    shapes))

;; A step with no handle to pass (a constructor's, a lookup's) needs none
;; for its owner refusal: the owner and the caller both come from what its
;; check found (#102).
(test-equal "step-refusal names the owner and the caller an owner check found, with no handle to pass"
  `(wrong-thread uv-test-verb! ,found-owner ,found-caller)
  (refusal-shape (step-refusal (make-owner-mismatch found-owner found-caller)
                               'uv-test-verb! #f)))

;; --- the callback error policy (design spec S8) -------------------------
;; The dispatcher guard that CALLS loop-record-error! arrives with Task 7;
;; the recording policy itself is exercised here by direct calls, which is
;; also the only way to reach the "second and later errors" arm without a
;; callback that raises twice.
(define policy-loop (make-uv-loop))
(define err-1 (make-uv-errno-error 'ECONNRESET -104 "connection reset by peer"))
(define err-2 (make-uv-errno-error 'EPIPE -32 "broken pipe"))
(define err-3 (make-uv-invalid-argument 'on-timer 'third-error))

(loop-record-error! policy-loop err-1)

(test-equal "the first callback error becomes the loop's pending error"
  'stored (if (eq? err-1 (loop-pending-error policy-loop)) 'stored 'not-stored))

(test-equal "the first callback error is not put on the deferred list"
  '() (uv-loop-deferred-errors policy-loop))

(loop-record-error! policy-loop err-2)

(test-equal "a second callback error leaves the pending error alone"
  'first-still-pending
  (if (eq? err-1 (loop-pending-error policy-loop))
      'first-still-pending
      'overwritten))

(test-equal "a second callback error is appended to the deferred list"
  'second-deferred
  (let ((d (uv-loop-deferred-errors policy-loop)))
    (if (and (= 1 (length d)) (eq? err-2 (car d))) 'second-deferred 'unexpected)))

(loop-record-error! policy-loop err-3)

(test-equal "deferred errors read back in occurrence order"
  'in-order
  (let ((d (uv-loop-deferred-errors policy-loop)))
    (if (and (= 2 (length d)) (eq? err-2 (car d)) (eq? err-3 (cadr d)))
        'in-order
        'out-of-order)))

;; uv-run's re-raise. The compound is the load-bearing part of S8: a guard
;; written against the ORIGINAL condition type still has to match.
(define raised-by-run
  (guard (e (#t e))
    (uv-run policy-loop 'nowait)
    'no-raise))

(test-equal "uv-run re-raises the pending callback error on the way out"
  'raised (if (condition? raised-by-run) 'raised 'no-raise))

(test-equal "the re-raised condition satisfies uv-callback-error?"
  'callback-error
  (if (uv-callback-error? raised-by-run) 'callback-error 'not-callback-error))

(test-equal "the re-raised condition ALSO satisfies the original condition's own predicate"
  'errno-error
  (if (uv-errno-error? raised-by-run) 'errno-error 'not-errno-error))

(test-equal "the compound still answers the original condition's field accessors"
  'ECONNRESET (uv-errno-error-errno raised-by-run))

(test-equal "the callback-error's cause is the original condition object"
  'same (if (eq? err-1 (uv-callback-error-cause raised-by-run)) 'same 'different))

(test-equal "the pending error is consumed by the re-raise (the loop stays usable)"
  'no-pending
  (if (loop-has-pending-error? policy-loop) 'still-pending 'no-pending))

;; WHAT THIS SEQUENCE CAN AND CANNOT SHOW. With real callbacks the order is:
;; the raises happen DURING run N, the caller reads them once run N has
;; returned (or re-raised), and run N+1 clears them. Without callbacks the
;; errors can only be recorded BEFORE a run, so the run that re-raises is
;; also the run whose start-clear discards the deferred list. The
;; readable-until-the-next-run half is what the three order assertions above
;; check, against a loop with no run in between; the clearing half is what
;; this one checks. The full end-to-end shape needs Task 7's timer callbacks
;; -- recorded under "deferred coverage" in .plans/stage-2-mutation-log.md.
(test-equal "uv-run clears the deferred list at the START of a run"
  '() (uv-loop-deferred-errors policy-loop))

(test-equal "the loop runs normally after the re-raise"
  'no-work (if (uv-run policy-loop 'nowait) 'work 'no-work))

;; A callback may raise a non-condition object (R6RS `raise` accepts any
;; value); the compound combinator does not apply to those, so they are
;; wrapped alone.
(loop-record-error! policy-loop 'a-bare-symbol)

(define raised-bare
  (guard (e (#t e))
    (uv-run policy-loop 'nowait)
    'no-raise))

(test-equal "a non-condition callback raise is wrapped in &uv-callback-error alone"
  'callback-error
  (if (uv-callback-error? raised-bare) 'callback-error 'not-callback-error))

(test-equal "its cause is the raised object itself"
  'a-bare-symbol (uv-callback-error-cause raised-bare))

;; ...and #f is one of those objects. This is the case that makes the loop
;; record's empty-pending marker a private sentinel rather than #f: a
;; callback's own (raise #f) must be recorded, must be re-raised, and must not
;; make the NEXT error look like the first one. With #f as the marker all
;; three go wrong silently -- the error is stored but read back as "none", so
;; uv_stop fires with nothing to show for it and uv-run drops the error.
(define false-loop (make-uv-loop))
(define after-false (make-uv-errno-error 'EPIPE -32 "broken pipe"))

(loop-record-error! false-loop #f)

(test-equal "a callback that raised #f leaves the loop holding a pending error"
  'has-pending
  (if (loop-has-pending-error? false-loop) 'has-pending 'looks-empty))

(test-equal "the pending slot holds the #f the callback raised"
  'false-is-pending
  (if (eq? #f (loop-pending-error false-loop)) 'false-is-pending 'something-else))

(loop-record-error! false-loop after-false)

(test-equal "the error after a #f is DEFERRED, not mistaken for the first one"
  'deferred
  (let ((d (uv-loop-deferred-errors false-loop)))
    (if (and (= 1 (length d)) (eq? after-false (car d))) 'deferred 'unexpected)))

(test-equal "the #f is still the pending error, not overwritten by the second"
  'false-still-pending
  (if (eq? #f (loop-pending-error false-loop))
      'false-still-pending
      'overwritten))

(define raised-false
  (guard (e (#t e))
    (uv-run false-loop 'nowait)
    'no-raise))

(test-equal "uv-run re-raises a #f callback error instead of dropping it silently"
  'callback-error
  (if (uv-callback-error? raised-false) 'callback-error 'not-callback-error))

(test-equal "the re-raised condition's cause is the #f the callback raised"
  'cause-is-false
  (if (eq? #f (uv-callback-error-cause raised-false))
      'cause-is-false
      'cause-is-something-else))

(test-equal "the loop is usable again after a #f callback error"
  'no-work (if (uv-run false-loop 'nowait) 'work 'no-work))

;; --- uv-stop! -----------------------------------------------------------
;; uv_stop's effect is only observable from inside a running loop, which
;; needs a callback (Task 7). What is asserted here is that it is accepted on
;; an open loop and refused on a closed one (below, in the use-after-close
;; matrix).
(test-equal "uv-stop! on an open loop returns without raising"
  'stopped
  (guard (e (#t (list 'raised e)))
    (uv-stop! policy-loop)
    'stopped))

;; --- uv-loop-close! -----------------------------------------------------
(define close-loop (make-uv-loop))
(define close-loop-ptr (loop-ptr close-loop))
(define registry-count-before-close (registry-count))
(define live-loops-before-close (live-count 'loop))

(test-equal "seed: the live loop counter is non-zero before the close under test"
  #t (positive? live-loops-before-close))

(test-equal "closing an open, empty loop returns without raising"
  'first-close-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-close! close-loop)
    'first-close-ok))

(test-equal "a closed loop's state field reads 'closed"
  'closed (loop-state close-loop))

(test-equal "uv-loop-open? is false for a closed loop"
  'not-open (if (uv-loop-open? close-loop) 'open 'not-open))

;; Design spec S10: "each allocation kind is freed in exactly one place, and
;; the freeing site zeroes the stored uptr immediately". This is the
;; assertion that guards the zeroing -- the free! itself is guarded only by
;; Valgrind/ASan (make test-memory), recorded honestly in the mutation log.
(test-equal "closing zeroes the stored loop pointer"
  0 (loop-ptr close-loop))

(test-equal "closing deregisters the loop from the registry"
  -1 (- (registry-count) registry-count-before-close))

(test-equal "the registry no longer resolves the closed loop's pointer"
  'absent (if (registry-ref close-loop-ptr) 'present 'absent))

(test-equal "closing decrements the live loop counter"
  -1 (- (live-count 'loop) live-loops-before-close))

(test-equal "closing an already-closed loop is a no-op, not an error"
  'second-close-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-close! close-loop)
    'second-close-ok))

(test-equal "the second close did not move the live loop counter again"
  -1 (- (live-count 'loop) live-loops-before-close))

(test-equal "uv-loop-close! rejects a non-loop argument, naming who and why"
  '(uv-loop-close! not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-loop-close! 'not-a-loop)
    'no-raise))

;; --- use after close ----------------------------------------------------
;; Every public loop operation, one row each. The KIND field value is what is
;; asserted, not merely that something was raised: 'loop is the discriminant
;; a caller branches on, and 'no-raise / 'wrong-condition are sentinels no
;; success path can produce.
(define dead-loop (make-uv-loop))
(uv-loop-close! dead-loop)

(define (closed-op-kind thunk)
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(for-each
 (lambda (entry)
   (test-equal (string-append "use after close: " (car entry)
                              " raises &uv-handle-closed with kind 'loop")
     'loop (closed-op-kind (cdr entry))))
 (list (cons "uv-run"                  (lambda () (uv-run dead-loop 'nowait)))
       (cons "uv-stop!"                (lambda () (uv-stop! dead-loop)))
       (cons "uv-loop-alive?"          (lambda () (uv-loop-alive? dead-loop)))
       (cons "uv-now"                  (lambda () (uv-now dead-loop)))
       (cons "uv-update-time!"         (lambda () (uv-update-time! dead-loop)))
       (cons "uv-loop-live-handles"    (lambda () (uv-loop-live-handles dead-loop)))
       (cons "uv-loop-deferred-errors" (lambda () (uv-loop-deferred-errors dead-loop)))))

;; --- pending-error delivery at close (v0.2) -----------------------------
;; The v0.1 obligation recorded in uv-loop-close!'s comment block, decided
;; 2026-08-21: a SUCCESSFUL close re-raises a stored pending callback
;; error, composed exactly as uv-run's exit path composes it -- the
;; alternative (discard) would silently lose the error for any caller who
;; skips the next uv-run and goes straight to close. The loop must be
;; CLOSED when the raise escapes: the error is a message from a callback,
;; not a reason to abandon the close.
(define pe-loop (make-uv-loop))
(define pe-err (make-uv-errno-error 'ECONNRESET -104 "connection reset by peer"))
(loop-record-error! pe-loop pe-err)

(define raised-by-close
  (guard (e (#t e))
    (uv-loop-close! pe-loop)
    'no-raise))

(test-equal "close with a pending error re-raises it instead of discarding it"
  'raised (if (condition? raised-by-close) 'raised raised-by-close))

(test-equal "the close-raised condition satisfies uv-callback-error?"
  'callback-error
  (if (uv-callback-error? raised-by-close) 'callback-error 'not-callback-error))

(test-equal "the close-raised condition ALSO satisfies the original condition's own predicate"
  'errno-error
  (if (uv-errno-error? raised-by-close) 'errno-error 'not-errno-error))

(test-equal "the close-raised compound still answers the original condition's field accessors"
  'ECONNRESET (uv-errno-error-errno raised-by-close))

(test-equal "the close-raised callback-error's cause is the original condition object"
  'same (if (eq? pe-err (uv-callback-error-cause raised-by-close)) 'same 'different))

(test-equal "the loop IS closed when the close's re-raise escapes"
  'closed (loop-state pe-loop))

(test-equal "a second close after the re-raise is the ordinary idempotent no-op"
  'second-close-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-close! pe-loop)
    'second-close-ok))

(test-equal "use after a re-raising close raises &uv-handle-closed with kind 'loop"
  'loop (closed-op-kind (lambda () (uv-run pe-loop 'nowait))))

(test-equal "the pending error was consumed by the close's re-raise"
  'no-pending
  (if (loop-has-pending-error? pe-loop) 'still-pending 'no-pending))

;; ...and a callback's (raise #f) keeps its delivery at close too. An
;; implementation testing the slot's truthiness instead of the predicate
;; would discard exactly this error (handles.sls's `no-pending` note) --
;; the same trap uv-run's own re-raise rows pin, re-pinned on this path.
(define pe-false-loop (make-uv-loop))
(loop-record-error! pe-false-loop #f)

(define false-raised-by-close
  (guard (e (#t e))
    (uv-loop-close! pe-false-loop)
    'no-raise))

(test-equal "close re-raises a #f callback error instead of dropping it silently"
  'callback-error
  (if (uv-callback-error? false-raised-by-close)
      'callback-error
      (list 'not-callback-error false-raised-by-close)))

(test-equal "the #f-close's callback-error carries the #f as its cause"
  'cause-is-false
  (if (eq? #f (uv-callback-error-cause false-raised-by-close))
      'cause-is-false
      'cause-is-something-else))

(test-equal "the #f-raising close still closed the loop"
  'closed (loop-state pe-false-loop))

;; The EBUSY path must NOT deliver: that close FAILED, the loop is still
;; open, and the error must stay pending for a later uv-run or close.
;; The unstarted timer is what makes uv_loop_close answer EBUSY (the
;; teardown section's trick, reused).
(define pe-busy-loop (make-uv-loop))
(define pe-busy-timer (make-uv-timer pe-busy-loop))
(define pe-busy-err (make-uv-errno-error 'EPIPE -32 "broken pipe"))
(loop-record-error! pe-busy-loop pe-busy-err)

(define raised-by-busy-close
  (guard (e (#t e))
    (uv-loop-close! pe-busy-loop)
    'no-raise))

(test-equal "a close refused with EBUSY raises the errno error, never the pending callback error"
  '(EBUSY not-callback-error)
  (list (if (uv-errno-error? raised-by-busy-close)
            (uv-errno-error-errno raised-by-busy-close)
            'not-an-errno-error)
        (if (uv-callback-error? raised-by-busy-close)
            'callback-error
            'not-callback-error)))

(test-equal "the refused close left the loop open"
  'open (loop-state pe-busy-loop))

(test-equal "the refused close left the error pending, untouched"
  'still-pending-same
  (if (and (loop-has-pending-error? pe-busy-loop)
           (eq? pe-busy-err (loop-pending-error pe-busy-loop)))
      'still-pending-same
      'lost-or-replaced))

;; ..."pending for a later uv-run" is real, not a comment: the run that
;; drains the timer's close delivers the error from ITS exit path.
(uv-close! pe-busy-timer)

(define busy-drain-raised
  (guard (e (#t e))
    (uv-run pe-busy-loop 'default)
    'no-raise))

(test-equal "the still-pending error is delivered by the next uv-run, cause intact"
  'same-cause
  (if (and (uv-callback-error? busy-drain-raised)
           (eq? pe-busy-err (uv-callback-error-cause busy-drain-raised)))
      'same-cause
      (list 'not-delivered busy-drain-raised)))

;; That delivering run was also a STOPPED run -- loop-record-error! calls
;; uv_stop when it stores the error (design spec S8), and the stored stop
;; flag makes uv_run return before its first iteration -- so it delivered
;; the ERROR but not the timer's close callback. One more run drains the
;; close quietly (nothing pending any more), and the loop then closes
;; cleanly. Probed before it was asserted: without this run the timer is
;; still 'closing and the close below answers EBUSY again.
(test-equal "one more run after the delivery drains the close sweep quietly"
  'drained
  (guard (e (#t (list 'raised e)))
    (uv-run pe-busy-loop 'default)
    'drained))

(test-equal "the timer's close completed in the drain run"
  'closed (uv-handle-state pe-busy-timer))

(test-equal "the loop then closes cleanly -- nothing left for close to re-raise"
  'closed-clean
  (guard (e (#t (list 'raised e)))
    (uv-loop-close! pe-busy-loop)
    (if (eq? 'closed (loop-state pe-busy-loop)) 'closed-clean 'not-closed)))

;; --- the cancel sweep and the completion machinery (ADR-0011) -----------
;; v0.2 Stage 3: uv-loop-teardown! runs cancel-requests-for-loop! before
;; its close sweep, and complete-request! resolves the owning loop from the
;; REGISTRY ENTRY rather than through the record's handle field, delivering
;; any extras behind the err argument. No DNS request can exist yet --
;; (libuv dns) is Stage 4 -- so what is assertable HERE is:
;;
;;   * the sweep's no-op contract on a loop with no DNS request entries:
;;     nothing deregistered, handle entries untouched, the loop and its
;;     counters exactly as they were;
;;   * the generalized complete-request!, driven synthetically the same way
;;     the registry rows above drive registry-register!: a plain
;;     alloc-zeroed block, a handle-less req record (handle = #f, the shape
;;     ADR-0011 documents), Stage 4's registry kinds, and a direct call --
;;     which is exactly how the Stage 4 dispatchers will call it.
;;
;; The sweep's positive arm -- a real in-flight DNS request cancelled at
;; teardown -- is Stage 5's teardown-with-in-flight row (design spec v0.2
;; S9); until then the TCP suites guard the substitution's equivalence for
;; the handle-owned kinds.
(define sweep-loop (make-uv-loop))
(define sweep-timer (make-uv-timer sweep-loop))
(define registry-before-sweep (registry-count))
(define timers-before-sweep (live-count 'timer))

(test-equal "seed: the sweep loop has a live handle entry for the kind filter to skip"
  'listed
  (if (memq sweep-timer (uv-loop-live-handles sweep-loop)) 'listed 'missing))

(test-equal "cancel-requests-for-loop! with no DNS entries returns without raising"
  'swept
  (guard (e (#t (list 'raised e)))
    (cancel-requests-for-loop! sweep-loop)
    'swept))

(test-equal "the no-op sweep deregistered nothing"
  registry-before-sweep (registry-count))

(test-equal "the no-op sweep left the timer open and its counter untouched"
  (list 'open timers-before-sweep)
  (list (uv-handle-state sweep-timer) (live-count 'timer)))

(test-equal "the swept loop is still usable"
  'still-usable
  (begin (uv-run sweep-loop 'nowait) 'still-usable))

;; The happy path: loop resolved from the entry, extras delivered via
;; apply, block freed and counted through the caller's thunk, pointer
;; zeroed. The sentinel is a value no failure path produces: an escaped
;; raise becomes ('raised ...) in the first row and #f in the others
;; (SRFI-64's catch), and an undelivered callback leaves 'not-delivered.
(define synth-block (alloc-zeroed 64))
(define synth-delivered 'not-delivered)
(define synth-freed 0)
(define synth-req
  (%make-uv-req-record synth-block 'getaddrinfo #f
                       (lambda (err . extras)
                         (set! synth-delivered (cons err extras)))))
(registry-register! synth-block 'getaddrinfo-req sweep-loop synth-req)

(test-equal "seed: the handle-less request entry is in the registry"
  'same (if (eq? synth-req (registry-ref synth-block)) 'same 'different))

(test-equal "complete-request! completes a handle-less request without raising"
  'completed
  (guard (e (#t (list 'raised e)))
    (complete-request! 'getaddrinfo 'uv-getaddrinfo!
                       (lambda () (set! synth-freed (+ synth-freed 1)))
                       synth-req synth-block 0 'record-a 'record-b)
    'completed))

(test-equal "the handle-less completion delivered err then the extras, via apply"
  '(#f record-a record-b) synth-delivered)

;; The seam takes a completing request's entry out of the registry before it
;; calls the dispatcher (#87), so complete-request! leaves the registry
;; alone: called directly, as here, it finds the entry still registered.
(test-equal "the handle-less completion counted and zeroed the block, and left the registry to the seam"
  (list 'still-registered 1 0)
  (list (if (registry-ref synth-block) 'still-registered 'deregistered)
        synth-freed
        (req-ptr synth-req)))

(when (registry-ref synth-block) (registry-deregister! synth-block))

;; abandon-request! is complete-request!'s release without a callback, for
;; the getaddrinfo dispatcher's conversion-failure arm, which no input can
;; reach (.plans/dns-stage-4-mutation-log.md). Its seam has taken the entry
;; already, so it too leaves the registry alone; driven directly, here. The
;; let* orders the reads after the call: Chez may evaluate a list's
;; arguments right to left.
(define abandon-block (alloc-zeroed 64))
(define abandon-delivered 'not-delivered)
(define abandon-req
  (%make-uv-req-record abandon-block 'getaddrinfo #f
                       (lambda args (set! abandon-delivered 'delivered))))
(registry-register! abandon-block 'getaddrinfo-req sweep-loop abandon-req)

(test-equal "abandon-request! zeroes the request, delivers nothing, and leaves the registry to the seam"
  '(released 0 still-registered not-delivered)
  (let* ((released (guard (e (#t (list 'raised e)))
                     (abandon-request! abandon-req)
                     'released))
         (ptr (req-ptr abandon-req))
         (entry (if (eq? abandon-req (registry-ref abandon-block))
                    'still-registered
                    'deregistered)))
    (list released ptr entry abandon-delivered)))

(when (registry-ref abandon-block) (registry-deregister! abandon-block))

;; The loop read must happen BEFORE the deregister pops the entry, and its
;; answer is where a raising on-complete lands. Since #45 the seam reads it,
;; before the dispatcher runs, and the seam is the only place a raise is
;; contained, so this completion goes through an installed slot. The
;; shutdown slot completes its request through complete-request!, as the DNS
;; slots do, and handles.sls installs it in every process. The raise must be
;; recorded on the loop the REGISTRY ENTRY named -- a loop no
;; (handle-loop (req-handle req)) read could have found, since the handle
;; field is #f.
(define synth-raise-block (alloc-zeroed 64))
(define synth-raise-req
  (%make-uv-req-record synth-raise-block 'shutdown #f
                       (lambda (err) (raise 'synthetic-on-complete-raise))))
(registry-register! synth-raise-block 'shutdown-req sweep-loop
                    synth-raise-req)

(test-equal "a raising handle-less on-complete is contained at the seam, not escaped"
  'contained
  (guard (e (#t (list 'escaped e)))
    ((dispatcher-ref 'shutdown) synth-raise-block 0)
    'contained))

(test-equal "the raise was recorded on the loop the registry entry named"
  'synthetic-on-complete-raise
  (if (loop-has-pending-error? sweep-loop)
      (loop-pending-error sweep-loop)
      'no-pending-error))

;; complete-request! calls on-complete last, so a raise there skips none of
;; its own steps (#45).
(test-equal "...and the request was deregistered and zeroed before on-complete raised"
  '(deregistered 0)
  (list (if (registry-ref synth-raise-block) 'still-registered 'deregistered)
        (req-ptr synth-raise-req)))

(clear-loop-pending-error! sweep-loop)

;; Teardown over this loop is the integration row for the new ordering:
;; the cancel sweep runs first (a no-op here), then the close sweep takes
;; the timer down exactly as it did in v0.1.
(test-equal "teardown still tears down a loop with a live handle after the cancel sweep"
  'torn-down
  (guard (e (#t (list 'raised e)))
    (uv-loop-teardown! sweep-loop)
    'torn-down))

(test-equal "the swept loop's timer was closed and freed by the teardown"
  (list 'closed (- timers-before-sweep 1))
  (list (uv-handle-state sweep-timer) (live-count 'timer)))

;; --- uv-loop-teardown! --------------------------------------------------
;; The sweep is exercised with a REGISTERED handle rather than over an empty
;; registry: an empty sweep passes whether the sweep loop is there or not.
;; Stage 3 replaced Stage 2's probe with a real timer, which makes the row
;; below an assertion about the actual close protocol.
;;
;; The timer is deliberately NEVER STARTED. An armed one would keep the loop
;; alive, so a teardown that failed to sweep would BLOCK in the drain's
;; uv-run rather than fail -- a hang is not a test result. An unstarted
;; timer is still in libuv's handle queue, so an unswept one makes
;; uv_loop_close answer EBUSY and the first row below fails by name.
(define td-loop (make-uv-loop))
(define td-timer (make-uv-timer td-loop))
(define td-live-before (live-count 'loop))

(test-equal "seed: the timer is listed as a live handle of its loop"
  'listed (if (memq td-timer (uv-loop-live-handles td-loop)) 'listed 'missing))

(test-equal "seed: the timer is live in the counters before teardown"
  1 (live-count 'timer))

(test-equal "uv-loop-teardown! on an open loop returns without raising"
  'torn-down
  (guard (e (#t (list 'raised e)))
    (uv-loop-teardown! td-loop)
    'torn-down))

(test-equal "teardown swept the loop's registered handles through close-handle!"
  'closed (uv-handle-state td-timer))

(test-equal "the swept handle was freed, not merely forgotten"
  0 (live-count 'timer))

(test-equal "teardown closed the loop after the sweep"
  'closed (loop-state td-loop))

(test-equal "teardown returned the live loop counter to its pre-teardown value"
  -1 (- (live-count 'loop) td-live-before))

(test-equal "teardown is idempotent on an already-torn-down loop"
  'second-teardown-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-teardown! td-loop)
    'second-teardown-ok))

;; --- call-with-uv-loop --------------------------------------------------
(define cwl-live-before (live-count 'loop))
(define cwl-seen-inside 'body-never-ran)

(define cwl-result
  (call-with-uv-loop
   (lambda (l)
     (set! cwl-seen-inside (if (uv-loop-open? l) (live-count 'loop) 'not-open))
     (uv-run l 'nowait)
     'body-value)))

(test-equal "call-with-uv-loop returns the body's value"
  'body-value cwl-result)

(test-equal "seed: the loop was open and live inside the body"
  (+ cwl-live-before 1) cwl-seen-inside)

(test-equal "call-with-uv-loop tears the loop down on a normal return"
  cwl-live-before (live-count 'loop))

(define cwl-raise-reason
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (call-with-uv-loop
     (lambda (l)
       (raise (make-uv-invalid-argument 'test-body 'deliberate))))
    'no-raise))

(test-equal "a raise from the body propagates out of call-with-uv-loop"
  'deliberate cwl-raise-reason)

(test-equal "the loop is torn down even when the body raises"
  cwl-live-before (live-count 'loop))

;; The re-entry guard of design spec S5 ("dynamic-wind is valid here, unlike
;; around an individual handle"), written in the shape the sibling
;; chez-cmark-gfm project's test-lifecycle uses for its own re-entry ADR --
;; this repo's ADR-0006 is about error codes being symbols and has nothing to
;; do with it. A continuation captured INSIDE the extent is invoked after the
;; extent has been left (and the loop torn down). dynamic-wind's before-thunk runs on
;; the way back in and must refuse, because the loop it would hand the body
;; is gone. `body-entries` is the sentinel: a re-entry that got past the
;; guard would run the body a second time.
(define resume-k #f)
(define body-entries 0)

(define reentry-outcome
  (call-with-current-continuation
   (lambda (done)
     (guard (e ((uv-handle-closed? e) (done (uv-handle-closed-kind e)))
               (#t (done 'wrong-condition)))
       (call-with-current-continuation
        (lambda (escape)
          (call-with-uv-loop
           (lambda (l)
             (set! body-entries (+ body-entries 1))
             (call-with-current-continuation
              (lambda (k) (set! resume-k k) (escape 'left-the-extent)))
             (done 'body-resumed-without-raising)))))
       (resume-k 'go-back-in)
       (done 'resume-returned-normally)))))

(test-equal "seed: the body ran exactly once before the escape"
  1 body-entries)

(test-equal "re-entering a torn-down call-with-uv-loop raises &uv-handle-closed with kind 'loop"
  'loop reentry-outcome)

(test-equal "the refused re-entry did not run the body a second time"
  1 body-entries)

(test-equal "the refused re-entry left no live loop behind"
  cwl-live-before (live-count 'loop))

;; --- a run left from inside a callback (#45) ----------------------------
;; uv-run marks its loop running for as long as uv_run's frame is on the
;; stack, and a callback that never returns leaves that frame there: an
;; engine that runs out of fuel in a callback suspends it, and a continuation
;; that escapes a callback abandons it. Either way libuv is in the middle of
;; an iteration that only a return into the frame can finish, so the loop
;; stays marked running and every verb that would run, close or tear it down
;; refuses it. Before #45 a dynamic-wind cleared the mark on the way out, so
;; a teardown during an engine's suspension was accepted, and resuming the
;; engine then died with "invalid memory reference".

;; raise-evidence : object -> object
;; A refusal as the rows below expect it, or else the raise's description.
(define (raise-evidence e)
  (cond ((uv-invalid-argument? e)
         (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
        ((uv-handle-closed? e) (list 'handle-closed (uv-handle-closed-kind e)))
        (else (describe e))))

(define (spin n) (let lp ((i 0)) (when (< i n) (lp (+ i 1)))))

;; tear-down-row-loop : uv-loop -> (or 'torn-down list)
;; Ends a row's loop inside a row of its own, so a build that left the loop
;; marked running, or owned by another thread, fails that row by name instead
;; of aborting the suite before the rows after it. The suite has finished
;; with the run by then, so it clears the mark and takes the loop back.
(define (tear-down-row-loop loop)
  (guard (e (#t (list 'raised (raise-evidence e))))
    (set-loop-holder! loop #f)
    (set-loop-owner-thread! loop (current-thread-id))
    (uv-loop-teardown! loop)
    'torn-down))

;; Fuel for an engine's first slice: far less than one spin of a callback.
(define slice-fuel 5000)

(define (run-slice engine fuel)
  (guard (e (#t (list 'raised (raise-evidence e))))
    (engine fuel
            (lambda (ticks value) (list 'finished value))
            (lambda (resume) (list 'suspended resume)))))

(define suspended-loop (make-uv-loop))
(define suspended-timer (make-uv-timer suspended-loop))
(define in-callback #f)
(define suspended-fires 0)
(uv-timer-start! suspended-timer
                 (lambda (t)
                   (set! in-callback #t)
                   (set! suspended-fires (+ suspended-fires 1))
                   (spin 200000)
                   (set! in-callback #f))
                 0 0)

(define first-slice
  (run-slice (make-engine (lambda () (uv-run suspended-loop 'default)))
             slice-fuel))

(test-equal "seed: the engine ran out of fuel inside the callback"
  '(suspended #t) (list (car first-slice) in-callback))

(test-equal "a loop whose run is suspended inside a callback is still marked running"
  'running (if (loop-running? suspended-loop) 'running 'not-running))

;; Each verb is tried only while the loop is marked running. On a build that
;; cleared the mark it would run or free the loop under the suspended
;; iteration, so the row names that instead of trying it.
(define (refusal-of-marked loop thunk)
  (if (loop-running? loop)
      (guard (e (#t (raise-evidence e)))
        (thunk)
        'accepted)
      'not-marked-running))

(test-equal "...so uv-run refuses it"
  '(uv-run loop-running)
  (refusal-of-marked suspended-loop (lambda () (uv-run suspended-loop 'nowait))))

(test-equal "...and uv-loop-close! refuses it"
  '(uv-loop-close! loop-running)
  (refusal-of-marked suspended-loop (lambda () (uv-loop-close! suspended-loop))))

(test-equal "...and uv-loop-teardown! refuses it"
  '(uv-loop-teardown! loop-running)
  (refusal-of-marked suspended-loop (lambda () (uv-loop-teardown! suspended-loop))))

(define resumed
  (if (eq? (car first-slice) 'suspended)
      (run-slice (cadr first-slice) 100000000)
      'never-suspended))

(test-equal "resuming the engine finishes the callback and the run"
  '((finished #f) 1 #f) (list resumed suspended-fires in-callback))

(test-equal "...after which the loop is no longer marked running"
  'not-running (if (loop-running? suspended-loop) 'running 'not-running))

(test-equal "the suspended run's loop tears down once the run is over"
  'torn-down (tear-down-row-loop suspended-loop))

;; A continuation that escapes a callback abandons the iteration for good.
;; The loop stays marked running, and every verb keeps refusing it: libuv may
;; have been anywhere in that iteration (escaping one close callback strands
;; the rest of libuv's batch of closes, which then never finish).
(define escaped-loop (make-uv-loop))
(define escaped-timer (make-uv-timer escaped-loop))
(define escaped-outcome
  (call/cc
   (lambda (k)
     (uv-timer-start! escaped-timer (lambda (t) (k 'escaped)) 0 0)
     (uv-run escaped-loop 'default)
     'returned)))

(test-equal "seed: the continuation escaped the callback"
  'escaped escaped-outcome)

(test-equal "a run escaped from inside a callback leaves its loop marked running"
  'running (if (loop-running? escaped-loop) 'running 'not-running))

(test-equal "...and uv-run refuses it from then on"
  '(uv-run loop-running)
  (refusal-of-marked escaped-loop (lambda () (uv-run escaped-loop 'nowait))))

;; The escape left a timer callback, after which libuv's state is whole, so
;; the suite may clear the mark by hand to free the loop.
(test-equal "the escaped run's loop tears down once the suite clears its mark"
  'torn-down (tear-down-row-loop escaped-loop))

;; --- call-with-uv-loop after a run left from inside a callback (#45) ----
;; call-with-uv-loop's loop does not outlive it. Its exit tears the loop down
;; even when the body left from inside one of the loop's callbacks, leaving
;; it marked running, as long as this thread is the one that left it so.
;; That is safe here, and only here, because the entry check refuses every
;; return into the body once the loop is gone, so nothing resumes the frame
;; the teardown took the loop from.
(define escaping-body-loop #f)
(define escaping-body-outcome
  (guard (e (#t (list 'raised (raise-evidence e))))
    (call/cc
     (lambda (k)
       (call-with-uv-loop
        (lambda (l)
          (set! escaping-body-loop l)
          (uv-timer-start! (make-uv-timer l) (lambda (t) (k 'escaped)) 0 0)
          (uv-run l 'default)
          'returned))))))

(test-equal "a continuation that escapes a callback leaves call-with-uv-loop with its value"
  'escaped escaping-body-outcome)

(test-equal "...and call-with-uv-loop tore its loop down on the way out"
  'closed (if (uv-loop-open? escaping-body-loop) 'open 'closed))

(define suspending-body-loop #f)
(define in-body-callback #f)
(define suspending-slice
  (run-slice
   (make-engine
    (lambda ()
      (call-with-uv-loop
       (lambda (l)
         (set! suspending-body-loop l)
         (uv-timer-start! (make-uv-timer l)
                          (lambda (t)
                            (set! in-body-callback #t)
                            (spin 200000)
                            (set! in-body-callback #f))
                          0 0)
         (uv-run l 'default)
         'body-finished))))
   slice-fuel))

(test-equal "seed: the engine ran out of fuel inside a callback of call-with-uv-loop's loop"
  '(suspended #t) (list (car suspending-slice) in-body-callback))

(test-equal "an engine suspended in a callback does not keep call-with-uv-loop's loop"
  'closed (if (uv-loop-open? suspending-body-loop) 'open 'closed))

(test-equal "...and resuming it is refused like any other return into the body"
  '(handle-closed loop)
  (if (eq? (car suspending-slice) 'suspended)
      (let ((outcome (run-slice (cadr suspending-slice) 100000000)))
        (if (eq? (car outcome) 'raised) (cadr outcome) outcome))
      'never-suspended))

;; A loop another thread is running is live under that thread's uv_run, and
;; the exit leaves it alone: its teardown refuses it, as before #45. The row
;; forges that state, a claim held by another thread's id, on a loop no
;; thread is running, so a build that tore the loop down anyway fails here by name
;; instead of racing a real thread.
(define foreign-run-loop #f)
(define foreign-run-outcome
  (guard (e (#t (raise-evidence e)))
    (call-with-uv-loop
     (lambda (l)
       (set! foreign-run-loop l)
       (set-loop-owner-thread! l (+ (current-thread-id) 1))
       (set-loop-holder! l (+ (current-thread-id) 1))
       'body-returned))))

(test-equal "call-with-uv-loop's exit refuses a loop another thread is running"
  '(uv-loop-teardown! loop-running) foreign-run-outcome)

(test-equal "...and leaves that thread's mark in place"
  'running (if (loop-running? foreign-run-loop) 'running 'not-running))

(test-equal "the forged run's loop tears down once the suite takes it back"
  'torn-down (tear-down-row-loop foreign-run-loop))

;; --- an exit whose teardown libuv cannot finish (#46's review) ----------
;; Left from inside one close callback while another close waits in libuv's
;; batch, the exit's teardown cannot close the loop: libuv walks that batch
;; from a list it has already detached, so the other close never finishes.
;; The exit contains that failure instead of raising it in the middle of the
;; escape or the engine's suspension, leaves the loop marked running, as any
;; abandoned run is, and refuses every return into the body. The loop stays
;; allocated for good, so tests/stranded-exit-child.sps runs the scenario in
;; a process of its own, which the memory gate does not follow, and this
;; suite checks the datum it prints.
(define chez-for-children (getenv "CHEZ_LIBUV_TEST_CHEZ"))

(define stranded-report
  (if (not chez-for-children)
      'no-chez
      (guard (e (#t (list 'spawn-failed (describe e))))
        (let-values (((to-child from-child errors pid)
                      (open-process-ports
                       (string-append chez-for-children
                                      " --program tests/stranded-exit-child.sps")
                       (buffer-mode block) (native-transcoder))))
          (close-port to-child)
          (let* ((out (get-string-all from-child))
                 (err (get-string-all errors)))
            (close-port from-child)
            (close-port errors)
            (let ((datum (guard (e (#t #f)) (read (open-string-input-port out)))))
              (if (list? datum) datum (list 'unreadable out err))))))))

;; stranded : symbol -> object, one entry of the child's report.
(define (stranded key)
  (let ((entry (and (list? stranded-report) (assq key stranded-report))))
    (if entry (cdr entry) (list 'no-entry key stranded-report))))

(if (eq? stranded-report 'no-chez)
    (test-equal "stranded-exit rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (begin
      (test-equal "seed: the child's engine ran out of fuel inside the close callback"
        #t (stranded 'engine-in-close))
      (test-equal "an escape out of a close callback, with another close pending, keeps its value"
        'escaped (stranded 'escape))
      (test-equal "...leaves the loop marked running, since libuv cannot finish closing it"
        'running (stranded 'escape-marked))
      (test-equal "...and refuses a return into the body"
        '(refused loop) (stranded 'reentry))
      (test-equal "an engine suspended there expires instead of failing mid-suspension"
        'expired (stranded 'engine))
      (test-equal "...leaves its loop marked running"
        'running (stranded 'engine-marked))
      (test-equal "...and its resume is refused like any other return into the body"
        '(refused loop) (stranded 'engine-resume))))

;; --- balance ------------------------------------------------------------
;; l0, other-loop, policy-loop and false-loop are still open at this point;
;; close them and confirm the whole suite balances.
(uv-loop-close! l0)
(uv-loop-close! other-loop)
(uv-loop-close! policy-loop)
(uv-loop-close! false-loop)

(test-equal "every loop this suite created has been freed"
  0 (live-count 'loop))

(test-equal "the registry is back to its starting size"
  registry-count-at-start (registry-count))

(collect)

(test-equal "a full collection after teardown changes nothing"
  0 (live-count 'loop))

(test-end "loop")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
