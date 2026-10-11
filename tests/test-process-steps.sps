#!r6rs
;;; SRFI-64 suite for the process verbs an engine splits or drops:
;;; uv-process-kill! and uv-process-pid. uv-spawn!'s own sweeps are in
;;; test-process.sps.
;;;
;;; NOT pure: it spawns children. Never add this to the Makefile's
;;; PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv pipe)
        (libuv process)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts term-signal->value
              alloc-block free-block! uv-handle-size uv-process-get-pid)
        (only (libuv private constants) uv-process-type)
        (uv-testing)
        (only (uv-evidence) describe exact-block-sizes? under-memory-tool?)
        (uv-sweep)
        ;; make-engine drives the sweeps; enable-interrupts restores them
        ;; for a run that left them disabled; foreign-procedure binds waitpid,
        ;; which reaps a child whose handle a run closed, and sleep paces
        ;; it; foreign-ref and foreign-set! copy a handle into the block a
        ;; reuse run places at a freed address.
        (only (chezscheme) make-engine enable-interrupts
              collect foreign-procedure foreign-ref foreign-set!
              sleep make-time))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The sweep rows
;; return their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "process-steps")

;; --- a verb split by an engine ------------------------------------------------
;; A green-thread scheduler on the loop thread runs each task in an engine,
;; and a task's fuel can run out anywhere inside uv-process-kill! or
;; uv-process-pid. A verb that checks that its process is open, reads the
;; handle's pointer, and calls libuv, in separate steps, lets another task
;; close the process in between and run the loop, which frees the
;; uv_process_t, and the verb resumes with the stale pointer. When a new
;; process's handle has been given the freed address meanwhile, a resumed
;; kill signals the NEW process and returns normally, and a resumed pid
;; answers the new process's pid. So each verb checks, reads and calls in
;; one interrupt-free step (one-step). The step checks the loop's owner as
;; well as that the process is open (owned-handle-ptr): a step that checked
;; only the process would let a verb resumed after its loop was handed to
;; another thread make its call anyway, on a loop that thread owns.
;;
;; Each sweep runs a verb in an engine at rising fuel. Fuel 1 expires before
;; the verb's own open check, and the sweep stops at the first run no expiry
;; reaches, so between them every point in the verb is visited. At the
;; expiry the split sweep closes the process, child A, steps the loop until
;; the close has freed it, and resumes the verb. Each run has one right
;; answer:
;;   'refused           not yet called: resumed, the verb sees A closed and
;;                      raises &uv-handle-closed;
;;   'made-before-close the verb had returned before the expiry, with A's
;;                      answer;
;;   'untouched         no expiry: it ran whole, with A's answer.
;; Neither verb has a trap check after its step, and neither allocates, so
;; no engine expires after the step here, and a verb that returns after the
;; close without having returned before it made its call on the freed
;; handle. A collection that came due inside a step would be taken where
;; the step ends and spend fuel there, so each run starts with a
;; (collect): a run allocates far too little to bring the next one due.
;;
;; The reuse sweep puts child B's handle at A's freed address before
;; resuming, and B must come through untouched. The handoff sweep hands the
;; loop to another thread in place of the close, and hands it back once the
;; verb has run: a run not returned before the handoff must be refused with
;; &uv-wrong-thread, A left unsignalled, and one returned before it is
;; 'made-before-handoff. The drop sweep drops the engine instead, and
;; requires every counter as the run found it, blocks included, and
;; interrupts enabled.
;;
;; A kill resumed on a freed handle signals whatever pid it reads there, and
;; 0 there is kill(0, sig): this process's own group. So the split and drop
;; sweeps send signal 0, which reaches no one; the reuse sweep sends SIGTERM,
;; and resumes only a run whose block at A's address holds B's handle, where
;; a stale call can reach only B.

;; A memory tool never hands a freed block back: Memcheck's freelist and
;; ASan's quarantine hold it, and the reuse rows then ask less.
;; under-memory-tool? asks the environment and the allocator both
;; (tests/uv-evidence.sls), so a plain run that inherits ASAN_OPTIONS from a
;; shell still asks everything.
(define counts-at-start (live-counts))

(define loop (make-uv-loop))

;; waitpid reaps a child whose handle a run closed: libuv waits only for the
;; children of open process handles. WNOHANG is 1 on macOS and Linux. The
;; loop above has loaded libuv, and libc with it.
(define waitpid (foreign-procedure "waitpid" (int u8* int) int))
(define wnohang 1)

;; poll! : (-> boolean) -> boolean
;; Steps the loop until (DONE?) holds, at most 64 times, and answers it.
;; 'nowait: a close is run by the next step, and a child's open handle keeps
;; the loop alive, so 'once could block.
(define (poll! done?)
  (let step ((i 0))
    (cond ((done?) #t)
          ((= i 64) #f)
          (else (uv-run loop 'nowait) (step (+ i 1))))))

(define (closed? h) (eq? 'closed (uv-handle-state h)))

;; A child is /bin/cat blocked reading its stdin, a pipe from the suite,
;; until the suite closes it: then it exits 0, unless a signal ended it
;; first. FATE is what on-exit reported, (status signal), while the handle
;; was open, or 'running.
(define-record-type child (fields proc pipe pid (mutable fate)))

;; spawn-child! : -> child
;; A spawn that raises closes its pipe first: a failed uv-spawn! leaves its
;; pipes for the caller to close.
(define (spawn-child!)
  (let* ((pipe (make-uv-pipe loop))
         (c #f)
         (proc (guard (e (#t (uv-close! pipe)
                             (poll! (lambda () (closed? pipe)))
                             (raise e)))
                 (uv-spawn! loop "/bin/cat" '("cat")
                            (list (cons 'stdio (list (list 'pipe pipe 'to-child))))
                            (lambda (status sig)
                              (collect)
                              (child-fate-set! c (list status sig)))))))
    (set! c (make-child proc pipe (uv-process-pid proc) 'running))
    c))

(define (close-stdin! c)
  (when (uv-handle-open? (child-pipe c)) (uv-close! (child-pipe c))))

;; Steps for a child to exit after its stdin closes, or after a signal.
(define exit-steps 4000)

;; reap-polls waitpid polls, a millisecond apart, for a child whose handle
;; is closed.
(define reap-polls 4000)
(define status-word (make-bytevector 4 0))

;; wait-once : exact-integer -> (or (list status signal) 'running list)
;; The child's fate as on-exit gives it: (status #f) after an exit, and
;; (0 signal) after a signal, the signal a symbol where it has one.
(define (wait-once pid)
  (let ((r (waitpid pid status-word wnohang)))
    (cond ((= r pid)
           (let* ((s (bytevector-s32-native-ref status-word 0))
                  (sig (bitwise-and s #x7f)))
             (if (zero? sig)
                 (list (bitwise-and (bitwise-arithmetic-shift-right s 8) #xff) #f)
                 (list 0 (term-signal->value sig)))))
          ((zero? r) 'running)
          (else (list 'waitpid-answered r)))))

(define (reap-within pid)
  (let poll ((i 0))
    (let ((fate (wait-once pid)))
      (cond ((not (eq? fate 'running)) fate)
            ((= i reap-polls) 'running)
            (else (sleep (make-time 'time-duration 1000000 0)) (poll (+ i 1)))))))

;; reap! : child -> fate
;; For a child whose handle the run closed: closes its stdin, and reaps it.
;; A child still running at the cap is killed, so that none outlives the
;; suite, and its fate says so.
(define (reap! c)
  (close-stdin! c)
  (poll! (lambda () (closed? (child-pipe c))))
  (let ((fate (reap-within (child-pid c))))
    (if (eq? fate 'running)
        (begin
          (guard (e (#t #f)) (uv-kill! (child-pid c) 'sigkill))
          (list 'running-at-the-cap (reap-within (child-pid c))))
        fate)))

;; finish! : child -> fate
;; For a child whose handle is open: closes its stdin, waits for its exit,
;; then closes its handle, and steps the loop until both handles are freed.
;; A child that never exited is reaped as reap! does, once its handle is
;; closed.
(define (finish! c)
  (close-stdin! c)
  (let ((exited (eq? 'satisfied
                     (run-until/ticking loop (lambda () (pair? (child-fate c)))
                                        exit-steps))))
    (when (uv-handle-open? (child-proc c)) (uv-close! (child-proc c)))
    (poll! (lambda () (and (closed? (child-proc c)) (closed? (child-pipe c)))))
    (if exited
        (child-fate c)
        (list 'never-exited (reap! c)))))

;; What a run must leave as it found it: every debug counter, blocks
;; included. live-counts reads them as (name . count).

;; --- seeds ----------------------------------------------------------------------
;; The sweeps read a child's fate two ways: from on-exit while its handle is
;; open, and from waitpid once a run has closed it. Each must report a
;; signal it did not send, or a fate of (0 #f) would say nothing.
(test-equal "seed: a child killed through its open handle reports (0 sigterm), and its stdin's close alone (0 #f)"
  '((0 sigterm) (0 #f))
  (let* ((a (spawn-child!))
         (b (spawn-child!)))
    (uv-process-kill! (child-proc a) 'sigterm)
    (let* ((a-fate (finish! a)) (b-fate (finish! b)))
      (list a-fate b-fate))))

(test-equal "seed: a child whose handle was closed is reaped with its fate, (0 sigterm) after a kill by pid, (0 #f) after its stdin's close"
  '((0 sigterm) (0 #f))
  (let* ((a (spawn-child!))
         (b (spawn-child!)))
    (uv-close! (child-proc a))
    (uv-close! (child-proc b))
    (poll! (lambda () (and (closed? (child-proc a)) (closed? (child-proc b)))))
    (uv-kill! (child-pid a) 'sigterm)
    (let* ((a-fate (reap! a)) (b-fate (reap! b)))
      (list a-fate b-fate))))

;; A kill made on a process that has exited and been reaped answers libuv's
;; errno under the verb's own name: the step answers the call's status,
;; and step-refusal raises it as libuv's errno naming the verb.
(test-equal "uv-process-kill! on a child already reaped raises ESRCH as uv-process-kill!"
  '(uv-process-kill! ESRCH)
  (let ((a (spawn-child!)))
    (close-stdin! a)
    (run-until/ticking loop (lambda () (pair? (child-fate a))) exit-steps)
    (let ((answer (guard (e ((uv-errno-error? e)
                             (list (condition-who e) (uv-errno-error-errno e)))
                            (#t (list 'raised (describe e))))
                    (uv-process-kill! (child-proc a) 0)
                    'no-raise)))
      (finish! a)
      answer)))

;; --- the variants ------------------------------------------------------------------
;; A variant is a verb as a run calls it on child A. ANSWER-OK? says whether
;; what the call returned is right for A; MADE-FATE is how A ends once the
;; call has been made on it.
(define-record-type variant (fields name call answer-ok? made-fate))

(define kill-0
  (make-variant 'uv-process-kill!-0
                (lambda (c) (uv-process-kill! (child-proc c) 0) 'sent)
                (lambda (c answer) (eq? answer 'sent))
                '(0 #f)))

(define kill-sigterm
  (make-variant 'uv-process-kill!-sigterm
                (lambda (c) (uv-process-kill! (child-proc c) 'sigterm) 'sent)
                (lambda (c answer) (eq? answer 'sent))
                '(0 sigterm)))

(define pid-query
  (make-variant 'uv-process-pid
                (lambda (c) (uv-process-pid (child-proc c)))
                (lambda (c answer) (eqv? answer (child-pid c)))
                '(0 #f)))

;; --- B at A's address ----------------------------------------------------------------
;; A spawn made after A's close took A's freed address by itself in 24 to 30
;; of 30 runs on macOS, and in none of 30 on glibc 2.36 or 2.39. So a reuse
;; run spawns B wherever it lands and puts a copy of B's handle at A's
;; address: it allocates blocks of a process handle's size until one lands
;; there, and copies B's handle into it. A stale call reads B's pid there,
;; as it would from B's own handle. The run resumes only once libuv's own
;; getter has read B's pid from the copy: from a block holding 0 there, a
;; stale kill would be kill(0, sig).
;;
;; Seven blocks of that size are freed first, before A's close. The search
;; then found A's address at its first try in 60 of 60 runs on macOS and on
;; both glibcs; without them it missed one run of 60 on each.
(define handle-size (uv-handle-size (uv-process-type)))
(define squat-fill 7)
(define squat-tries 16)

(define (fill-before-free!)
  (let make ((i 0) (blocks '()))
    (if (= i squat-fill)
        (for-each free-block! blocks)
        (make (+ i 1) (cons (alloc-block handle-size) blocks)))))

;; squat! : uptr -> (or uptr #f)
;; The block that landed at ADDRESS, or #f once SQUAT-TRIES blocks have not;
;; the others are freed.
(define (squat! address)
  (let search ((i 0) (misses '()))
    (if (= i squat-tries)
        (begin (for-each free-block! misses) #f)
        (let ((block (alloc-block handle-size)))
          (if (eqv? block address)
              (begin (for-each free-block! misses) block)
              (search (+ i 1) (cons block misses)))))))

(define (copy-handle! from to)
  (do ((i 0 (+ i 1))) ((= i handle-size))
    (foreign-set! 'unsigned-8 to i (foreign-ref 'unsigned-8 from i))))

;; --- one run ------------------------------------------------------------------------
;; Each run answers (cons expired? verdict): whether an expiry reached the
;; verb, and the run's verdict.

;; split-run : variant symbol exact-positive-integer -> (cons boolean verdict)
;; MODE is 'free, 'reuse to put B's handle at A's address after the free, or
;; 'handoff to hand the loop to another thread in place of the close.
;; A reuse run counts its expiry, and whether its block landed there; a run
;; whose block did not is never resumed, since a stale call would read a
;; pid from whatever holds A's address. What the expiry does to A and B is
;; plumbing: a raise there is the run's verdict, and the run still reaps A,
;; finishes B and frees the block, so nothing it made reaches the next run.
(define reuse-expiries 0)
(define reused-runs 0)

(define (split-run v mode fuel)
  (collect)
  (let* ((before (live-counts))
         (a (spawn-child!))
         (address (handle-ptr (child-proc a)))
         (returned #f)
         (b #f)
         (squatter #f)
         (eng (make-engine
               (lambda ()
                 (guard (e ((uv-handle-closed? e) 'closed)
                           ((uv-wrong-thread? e) 'wrong-thread)
                           (#t (list 'raised (describe e))))
                   (let ((answer ((variant-call v) a)))
                     (set! returned #t)
                     (list 'returned answer))))))
         (result
          (eng fuel
               (lambda (ticks o) (list 'no-expiry o))
               (lambda (resume)
                 (let ((made returned)
                       (plumbing #f))
                   (guard (e (#t (set! plumbing (describe e))))
                     (when (eq? mode 'reuse) (fill-before-free!))
                     (if (eq? mode 'handoff)
                         (set-loop-owner-thread! loop other-thread)
                         (begin (uv-close! (child-proc a))
                                (poll! (lambda () (closed? (child-proc a))))))
                     (when (eq? mode 'reuse)
                       (set! reuse-expiries (+ reuse-expiries 1))
                       (set! squatter (squat! address))
                       (set! b (spawn-child!))
                       (when squatter
                         (copy-handle! (handle-ptr (child-proc b)) squatter)
                         (if (eqv? (uv-process-get-pid squatter) (child-pid b))
                             (set! reused-runs (+ reused-runs 1))
                             (begin (free-block! squatter) (set! squatter #f))))))
                   (let ((o (cond (plumbing (list 'plumbing-raised plumbing))
                                  ((or (memq mode '(free handoff)) squatter made)
                                   (resume 1000000 (lambda (ticks o) o)
                                           (lambda (more) 'still-running)))
                                  (else 'not-resumed))))
                     (set-loop-owner-thread! loop me)
                     (list 'expired made o))))))
         (enabled (interrupts-enabled?)))
    (unless enabled (enable-interrupts))
    (when squatter (free-block! squatter))
    (let* ((a-fate (if (uv-handle-open? (child-proc a)) (finish! a) (reap! a)))
           (b-fate (and b (finish! b)))
           (b-pid (and b (child-pid b)))
           (b-untouched (or (not b) (equal? b-fate '(0 #f))))
           (verdict
            (if (eq? (car result) 'no-expiry)
                (let ((o (cadr result)))
                  (if (and (pair? o) (eq? (car o) 'returned)
                           ((variant-answer-ok? v) a (cadr o))
                           (equal? a-fate (variant-made-fate v)))
                      'untouched
                      (list 'untouched-but o 'a a-fate)))
                (let ((made (cadr result)) (o (caddr result)))
                  (cond ((eq? o 'not-resumed)
                         (if b-untouched 'not-reused (list 'not-reused 'b b-fate)))
                        ((and (eq? o (if (eq? mode 'handoff) 'wrong-thread 'closed))
                              (not made) (equal? a-fate '(0 #f)) b-untouched)
                         'refused)
                        ((and made (pair? o) (eq? (car o) 'returned)
                              ((variant-answer-ok? v) a (cadr o))
                              (equal? a-fate (variant-made-fate v)) b-untouched)
                         (if (eq? mode 'handoff) 'made-before-handoff 'made-before-close))
                        (else (list o (if made 'returned-before-change 'not-returned-before-change)
                                    'a a-fate 'a-pid (child-pid a)
                                    'b b-fate 'b-pid b-pid)))))))
      (let ((left (residue before (live-counts))))
        (cons (eq? (car result) 'expired)
              (cond ((not enabled) (list 'interrupts-left-disabled verdict))
                    ((pair? left) (list verdict 'left left))
                    (else verdict)))))))

;; drop-run : variant exact-positive-integer -> (cons boolean verdict)
(define (drop-run v fuel)
  (collect)
  (let* ((before (live-counts))
         (a (spawn-child!))
         (eng (make-engine
               (lambda ()
                 (guard (e (#t (list 'raised (describe e))))
                   (list 'returned ((variant-call v) a))))))
         (o (eng fuel (lambda (ticks o) (list 'no-expiry o)) (lambda (resume) 'dropped)))
         (enabled (interrupts-enabled?)))
    (unless enabled (enable-interrupts))
    (let* ((a-fate (finish! a))
           (verdict
            (cond ((eq? o 'dropped)
                   (if (member a-fate (list '(0 #f) (variant-made-fate v)))
                       'dropped
                       (list 'dropped 'a a-fate)))
                  ((let ((r (cadr o)))
                     (and (pair? r) (eq? (car r) 'returned)
                          ((variant-answer-ok? v) a (cadr r))
                          (equal? a-fate (variant-made-fate v))))
                   'untouched)
                  (else (list 'untouched-but (cadr o) 'a a-fate))))
           (left (residue before (live-counts))))
      (cons (eq? o 'dropped)
            (cond ((not enabled) (list 'interrupts-left-disabled verdict))
                  ((pair? left) (list verdict 'left left))
                  (else verdict))))))

;; --- the sweeps -----------------------------------------------------------------------
(define sweep-fuel-cap 200)

;; A run stalled if a child never exited or a resumed verb never finished:
;; every later run would wait the same caps out.
(define (mentions? x sym)
  (or (eq? x sym)
      (and (pair? x) (or (mentions? (car x) sym) (mentions? (cdr x) sym)))))

(define (stalled? verdict)
  (exists (lambda (sym) (mentions? verdict sym))
          '(never-exited running-at-the-cap still-running)))

;; sweep : (exact-positive-integer -> (cons boolean verdict))
;;         -> (list-of (list fuel verdict expired?))
;; From fuel 1 to the first run no expiry reaches, whatever its verdict, to
;; the first stalled run, or to the cap. A wrong run is not a reason to
;; stop: no run here can reach anything but its own children, since the
;; split and drop sweeps send signal 0 and a reuse run is resumed only onto
;; B. The driver ends the sweep at a raise between runs, keeping the runs
;; before it (tests/uv-sweep.sls).
(define (sweep run)
  (sweep-fuels (lambda (fuel)
                 (let ((r (run fuel)))
                   (values (cdr r) (car r))))
               sweep-fuel-cap stalled?))

;; named-sweeps runs one sweep per variant, in the list's order: Chez's map
;; applies its procedure in no fixed order.
(define (named-sweeps run vs)
  (let next ((vs vs) (acc '()))
    (if (null? vs)
        (reverse acc)
        (next (cdr vs)
              (cons (cons (variant-name (car vs))
                          (sweep (lambda (fuel) (run (car vs) fuel))))
                    acc)))))

(define (split-good? v) (and (memq v '(refused made-before-close untouched)) #t))
(define (reuse-good? v) (and (memq v '(refused made-before-close untouched not-reused)) #t))
(define (handoff-good? v) (and (memq v '(refused made-before-handoff untouched)) #t))
(define (drop-good? v) (and (memq v '(dropped untouched)) #t))

;; Each sweep's rows run as soon as the sweep ends, so a later sweep that
;; dies cannot take an earlier one's evidence with it.

(define split-sweeps
  (named-sweeps (lambda (v fuel) (split-run v 'free fuel)) (list kill-0 pid-query)))
(report! 'split split-sweeps)

(test-equal "a uv-process-kill! or uv-process-pid split by its process's close is refused, or had returned before the close"
  '()
  (bad-runs split-good? split-sweeps))

(test-equal "each split sweep caught its verb before its check and ran it to the end"
  '((uv-process-kill!-0 refused untouched)
    (uv-process-pid refused untouched))
  (reach split-sweeps))

(define reuse-sweeps
  (named-sweeps (lambda (v fuel) (split-run v 'reuse fuel)) (list kill-sigterm pid-query)))
(report! 'reuse reuse-sweeps)

(test-equal "a uv-process-kill! or uv-process-pid split by a close never reaches a new process given the old one's address"
  '()
  (bad-runs reuse-good? reuse-sweeps))

(test-equal "each reuse sweep caught its verb before its check and ran it to the end"
  (let ((first (if under-memory-tool? 'not-reused 'refused)))
    (list (list 'uv-process-kill!-sigterm first 'untouched)
          (list 'uv-process-pid first 'untouched)))
  (reach reuse-sweeps))

;; The reuse sweeps say nothing unless B's handle was at A's freed address:
;; a run whose block did not land there is never resumed. A memory tool
;; never hands the block back.
(display "  [informational] reuse: B's handle was at A's address in ")
(display reused-runs) (display " of ") (display reuse-expiries)
(display " expired runs; under a memory tool: ")
(display (if under-memory-tool? "yes" "no"))
(display " (exact block sizes: ")
(display (if exact-block-sizes? "yes" "no"))
(display ")\n")

(if under-memory-tool?
    (test-equal "seed: the reuse sweeps ran (a memory tool: reuse unobservable by design)"
      'ran
      (if (positive? reuse-expiries) 'ran 'no-expired-runs))
    (test-equal "seed: in every expired reuse run, B's handle was at A's freed address"
      'every-run
      (if (and (positive? reuse-expiries) (= reused-runs reuse-expiries))
          'every-run
          (list reused-runs 'of reuse-expiries))))

;; The process stays open through a handoff, so a kill made after it
;; reaches only A, and SIGTERM tells a made kill from one never made.
(define handoff-sweeps
  (named-sweeps (lambda (v fuel) (split-run v 'handoff fuel)) (list kill-sigterm pid-query)))
(report! 'handoff handoff-sweeps)

(test-equal "a uv-process-kill! or uv-process-pid split by its loop's handoff is refused, or had returned before the handoff"
  '()
  (bad-runs handoff-good? handoff-sweeps))

(test-equal "each handoff sweep caught its verb before its checks and ran it to the end"
  '((uv-process-kill!-sigterm refused untouched)
    (uv-process-pid refused untouched))
  (reach handoff-sweeps))

(define drop-sweeps (named-sweeps drop-run (list kill-0 pid-query)))
(report! 'drop drop-sweeps)

(test-equal "a uv-process-kill! or uv-process-pid whose engine is dropped leaves every counter as it found it, and interrupts enabled"
  '()
  (bad-runs drop-good? drop-sweeps))

(test-equal "each drop sweep dropped its verb and ran it to the end"
  '((uv-process-kill!-0 dropped untouched)
    (uv-process-pid dropped untouched))
  (reach drop-sweeps))

;; --- the suite's end ------------------------------------------------------------------
;; The counters are read once the teardown is over: counts-at-start was read
;; before the suite's loop was made, and Chez fixes no order for a call's
;; arguments, so a list of the two could read them with the loop alive.
(test-equal "the suite's loop tears down, and every counter is back where the suite began"
  '(torn-down ())
  (let* ((torn (guard (e (#t (list 'teardown-raised (describe e))))
                 (uv-loop-teardown! loop)
                 'torn-down))
         (left (residue counts-at-start (live-counts))))
    (list torn left)))

;; A process left open with no native block, as a broken close would leave
;; it, is refused inside the step: open-handle-ptr answers a status, and the
;; refusal is the one the checked accessor raises outside a step. A call
;; made on the null pointer would fault inside the step and leave interrupts
;; disabled, so this row comes last.
(test-equal "a process left open with no native block is refused, not called"
  '((uv-process-kill! null-handle-pointer) (uv-process-pid null-handle-pointer)
    interrupts-enabled)
  (let* ((l (make-uv-loop))
         (p (make-uv-pipe l))
         (proc (uv-spawn! l "/bin/cat" '("cat")
                          (list (cons 'stdio (list (list 'pipe p 'to-child))))
                          #f))
         (pid (uv-process-pid proc)))
    (uv-close! proc)
    (uv-close! p)
    (let step ((i 0))                   ; the close callbacks free both
      (unless (or (and (closed? proc) (closed? p)) (= i 16))
        (uv-run l 'nowait)
        (step (+ i 1))))
    (set-handle-state! proc 'open)
    (let ((refusals
           (map (lambda (call)
                  (guard (e ((uv-invalid-argument? e)
                             (list (uv-invalid-argument-who e)
                                   (uv-invalid-argument-reason e)))
                            (#t (list 'raised (describe e))))
                    (call)
                    'called))
                (list (lambda () (uv-process-kill! proc 0))
                      (lambda () (uv-process-pid proc))))))
      (set-handle-state! proc 'closed)
      (guard (e (#t #f)) (uv-kill! pid 'sigkill))
      (reap-within pid)
      (uv-loop-teardown! l)
      (append refusals
              (list (if (interrupts-enabled?)
                        'interrupts-enabled
                        'interrupts-left-disabled))))))

(test-end "process-steps")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
