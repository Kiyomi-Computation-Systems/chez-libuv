#!r6rs
;;; SRFI-64 suite for the handle verbs an engine splits or drops:
;;; - the scratch verbs, which borrow a block for the call: uv-tcp-bind!,
;;;   uv-tcp-getsockname-port, uv-tcp-sockname-address, uv-tcp-peer-address,
;;;   and the four buffer-size verbs (uv-send-buffer-size,
;;;   uv-send-buffer-size!, uv-recv-buffer-size, uv-recv-buffer-size!);
;;; - the other TCP verbs: uv-listen!, uv-tcp-nodelay!, uv-tcp-keepalive!;
;;; - the timer verbs: uv-timer-start!, uv-timer-stop!, uv-timer-again!,
;;;   uv-timer-repeat, uv-timer-set-repeat!;
;;; - the signal verbs: uv-signal-start!, uv-signal-start-oneshot!,
;;;   uv-signal-stop!;
;;; - the loop queries, which take a loop: uv-stop!, uv-now, uv-loop-alive?
;;;   and uv-update-time!.
;;;
;;; A green-thread scheduler on the loop thread runs each task in an engine,
;;; and a task's fuel can run out anywhere inside one of these verbs. Each
;;; checks its handle or loop, reads its pointer and calls libuv in one
;;; interrupt-free step (one-step): a scratch verb allocates and frees its
;;; scratch inside that step, a start stores its callback there once libuv
;;; has started it, and a signal start checks and fixes its mode there.
;;; Spread across interrupt-enabled code instead -- a scratch verb
;;; allocating its scratch before the call and freeing it in a guard, a
;;; start storing its callback before its call, a signal start checking its
;;; mode before and fixing it after -- a verb fails two ways:
;;; - Split: another task closes the handle, or hands its loop to another
;;;   thread, or starts the signal in the other mode, and the verb resumes
;;;   past its checks. It calls libuv with the freed handle, or with
;;;   whatever handle took its address, or races the new owner's thread on
;;;   the handle; a signal start returns normally where it owes
;;;   'signal-mode-fixed. A loop query split by its loop's teardown calls
;;;   libuv on the freed loop, or on a new loop given its address, and
;;;   uv-update-time! split by a handoff writes the clock of a loop another
;;;   thread owns.
;;; - Dropped, as a timeout drops a task: no guard runs after the
;;;   suspension, so the scratch is lost, or a start is left half made,
;;;   its callback stored and nothing started. A loop query holds nothing
;;;   and makes one native call, so it has no drop sweep.
;;;
;;; Each sweep runs a verb in an engine at rising fuel (uv-sweep's
;;; sweep-fuels). Fuel 1 expires before the verb's own checks, and a sweep
;;; stops at the first run no expiry reaches, so between them every point in
;;; the verb is visited.
;;;
;;; NOT pure: it drives a real loop. Never add this to the Makefile's
;;; PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv tcp)
        (libuv timer)
        (libuv signal)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts alloc-block free-block!
              uv-handle-size uv-loop-size uv-timer-get-repeat)
        (only (libuv private constants) uv-tcp-type uv-timer-type uv-signal-type)
        (uv-sweep)
        (only (uv-testing) run-until/ticking)
        (only (uv-evidence) describe under-memory-tool?)
        ;; make-engine drives the sweeps; collect starts each run with no
        ;; collection due; foreign-procedure binds libuv's uv_is_active.
        (only (chezscheme) make-engine collect foreign-procedure))

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

(test-begin "handle-steps")

;; Every target is a new handle of this loop, which the run that made it
;; closes, so once its handles have closed, the loop is not alive.
(define h-loop (make-uv-loop))

;; libuv's own view of whether a handle is active (started, listening),
;; for observe below. The library does not bind it; h-loop has loaded libuv.
(define uv-is-active (foreign-procedure "uv_is_active" (uptr) int))

;; --- what a run must leave as it found it ------------------------------------

;; The registry, and every debug counter, blocks included, as (name . count).
(define (balance) (cons (cons 'registry (registry-count)) (live-counts)))

;; --- the verbs ------------------------------------------------------------------
;; Each attempt calls its verb by name, inside a guard that catches every
;; raise (tests/test-seed-gates.sps's rule 4 reads that from the source),
;; and answers:
;;   'returned          the verb returned;
;;   'closed            it raised &uv-handle-closed;
;;   'wrong-thread      it raised &uv-wrong-thread;
;;   'mode-fixed        it refused a signal start in the mode not fixed;
;;   (raised message)   it raised something else.
;; uv-tcp-keepalive! has a form to enable and a form to disable, and each is
;; swept: uv-tcp-keepalive!/off names the second.
(define scratch-verbs
  '(uv-tcp-bind! uv-tcp-getsockname-port uv-tcp-sockname-address
    uv-tcp-peer-address uv-send-buffer-size uv-send-buffer-size!
    uv-recv-buffer-size uv-recv-buffer-size!))

(define tcp-verbs
  '(uv-listen! uv-tcp-nodelay! uv-tcp-keepalive! uv-tcp-keepalive!/off))

(define timer-verbs
  '(uv-timer-start! uv-timer-stop! uv-timer-again! uv-timer-repeat
    uv-timer-set-repeat!))

(define signal-verbs '(uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!))

(define swept-verbs (append scratch-verbs tcp-verbs timer-verbs signal-verbs))

;; The loop queries take a loop, not a handle: each run's target is a new
;; loop with nothing on it.
(define loop-verbs '(uv-stop! uv-now uv-loop-alive? uv-update-time!))

(define (verb-kind verb)
  (cond ((memq verb timer-verbs) 'timer)
        ((memq verb signal-verbs) 'signal)
        ((memq verb loop-verbs) 'loop)
        (else 'tcp)))

;; The callback each start passes, the one a target that must already be
;; started was started with, and the one the mode change below starts with.
;; None ever runs: the timers are due in an hour, nothing sends the signal,
;; and nothing connects to a listening target.
(define the-callback (lambda args 'the-verbs))
(define prepared-callback (lambda args 'prepared))
(define changed-callback (lambda args 'changed))

(define an-hour 3600000)

(define (callback-name proc)
  (cond ((not proc) 'none)
        ((eq? proc the-callback) 'the-verbs)
        ((eq? proc prepared-callback) 'prepared)
        ((eq? proc changed-callback) 'changed)
        (else 'another)))

(define (refusal e)
  (cond ((uv-handle-closed? e) 'closed)
        ((uv-wrong-thread? e) 'wrong-thread)
        ((and (uv-invalid-argument? e)
              (eq? (uv-invalid-argument-reason e) 'signal-mode-fixed))
         'mode-fixed)
        (else (list 'raised (describe e)))))

;; By quoted name: rule 4 would read a case clause's datum list,
;; ((uv-tcp-bind!) ...), as a call of the verb.
(define (call-verb verb h)
  (cond ((eq? verb 'uv-tcp-bind!) (uv-tcp-bind! h "127.0.0.1" 0))
        ((eq? verb 'uv-tcp-getsockname-port) (uv-tcp-getsockname-port h))
        ((eq? verb 'uv-tcp-sockname-address) (uv-tcp-sockname-address h))
        ((eq? verb 'uv-tcp-peer-address) (uv-tcp-peer-address h))
        ((eq? verb 'uv-send-buffer-size) (uv-send-buffer-size h))
        ((eq? verb 'uv-send-buffer-size!) (uv-send-buffer-size! h 65536))
        ((eq? verb 'uv-recv-buffer-size) (uv-recv-buffer-size h))
        ((eq? verb 'uv-recv-buffer-size!) (uv-recv-buffer-size! h 65536))
        ((eq? verb 'uv-listen!) (uv-listen! h 16 the-callback))
        ((eq? verb 'uv-tcp-nodelay!) (uv-tcp-nodelay! h #t))
        ((eq? verb 'uv-tcp-keepalive!) (uv-tcp-keepalive! h #t 60))
        ((eq? verb 'uv-tcp-keepalive!/off) (uv-tcp-keepalive! h #f))
        ((eq? verb 'uv-timer-start!) (uv-timer-start! h the-callback an-hour 0))
        ((eq? verb 'uv-timer-stop!) (uv-timer-stop! h))
        ((eq? verb 'uv-timer-again!) (uv-timer-again! h))
        ((eq? verb 'uv-timer-repeat) (uv-timer-repeat h))
        ((eq? verb 'uv-timer-set-repeat!) (uv-timer-set-repeat! h 5000))
        ((eq? verb 'uv-signal-start!) (uv-signal-start! h 'sigusr2 the-callback))
        ((eq? verb 'uv-signal-start-oneshot!)
         (uv-signal-start-oneshot! h 'sigusr2 the-callback))
        ((eq? verb 'uv-signal-stop!) (uv-signal-stop! h))
        ((eq? verb 'uv-stop!) (uv-stop! h))
        ((eq? verb 'uv-now) (uv-now h))
        ((eq? verb 'uv-loop-alive?) (uv-loop-alive? h))
        (else (uv-update-time! h))))

(define (attempt verb h)
  (guard (e (#t (refusal e)))
    (call-verb verb h)
    'returned))

;; The peer query's target is connected, to a server listening on a loop of
;; its own, which accepts and closes each connection when finish! runs it.
;; Unconnected, the query raises ENOTCONN after its step, and the work of
;; that raise is where an engine could expire after the call, which the
;; split oracle below rules out. The server's setup can fail, so it answers
;; what it saw, and a row below names it before any sweep relies on it.
(define sv-loop (make-uv-loop))
(define sv (make-uv-tcp sv-loop))

(define sv-port
  (guard (e (#t (list 'server-bind-raised (describe e))))
    (uv-tcp-bind! sv "127.0.0.1" 0)
    (uv-tcp-getsockname-port sv)))

(define sv-listening
  (guard (e (#t (list 'listen-raised (describe e))))
    (uv-listen! sv 128
                (lambda (err)
                  (unless err
                    (guard (e (#t #f))
                      (uv-close! (uv-accept! sv))))))
    'listening))

;; connect! : uv-tcp -> (or 'connected object)
;; Connects TCP to the server and runs h-loop until the connect completes,
;; ticking, so that a connect that never completes gives up after about 4 s
;; instead of blocking 'once until the kernel's own timeout.
(define (connect! tcp)
  (let ((status #f))
    (guard (e (#t (list 'connect-raised (describe e))))
      (uv-tcp-connect! tcp "127.0.0.1" sv-port
                       (lambda (err) (set! status (if err (describe err) 'connected))))
      (if (eq? (run-until/ticking h-loop (lambda () status) 4000) 'satisfied)
          status
          'connect-never-completed))))

;; make-handle : symbol -> (or uv-handle uv-loop)
;; A new handle of h-loop of KIND, 'tcp, 'timer or 'signal, or for 'loop a
;; new loop.
(define (make-handle kind)
  (case kind
    ((timer) (make-uv-timer h-loop))
    ((signal) (make-uv-signal h-loop))
    ((loop) (make-uv-loop))
    (else (make-uv-tcp h-loop))))

;; A run's target is a handle, or a loop for a loop query.
(define (target? x) (or (uv-handle? x) (uv-loop? x)))

(define (target-ptr target)
  (if (uv-loop? target) (loop-ptr target) (handle-ptr target)))

;; prepare : symbol -> (or uv-handle uv-loop list)
;; A new target for VERB:
;; - a TCP client of h-loop: unbound for the bind, which binds it,
;;   connected for the peer query, and bound to a loopback port for every
;;   other verb, which needs a socket to ask;
;; - a timer of h-loop, started for the stop and the again, which need one
;;   running;
;; - a signal handle of h-loop, started for the stop;
;; - a new loop for a loop query.
;; A handle it cannot prepare is closed, and the close run to its end, so
;; that no later run counts it in its balance and finds it gone.
(define (prepare verb)
  (let ((h (make-handle (verb-kind verb))))
    (define (refuse why)
      (uv-close! h)
      (poll! (lambda () (settled? h)))
      why)
    (define (started start!)
      (guard (e (#t (refuse (list 'start-raised (describe e)))))
        (start!)
        h))
    (cond ((uv-loop? h) h)
          ((memq verb '(uv-tcp-bind! uv-timer-start! uv-timer-repeat
                        uv-timer-set-repeat! uv-signal-start!
                        uv-signal-start-oneshot!))
           h)
          ((eq? verb 'uv-tcp-peer-address)
           (let ((connected (connect! h)))
             (if (eq? connected 'connected)
                 h
                 (refuse (list 'not-connected connected)))))
          ((memq verb '(uv-timer-stop! uv-timer-again!))
           (started (lambda () (uv-timer-start! h prepared-callback an-hour an-hour))))
          ((eq? verb 'uv-signal-stop!)
           (started (lambda () (uv-signal-start! h 'sigusr2 prepared-callback))))
          (else
           (guard (e (#t (refuse (list 'bind-raised (describe e)))))
             (uv-tcp-bind! h "127.0.0.1" 0)
             h)))))

(define (closed-or-absent? h) (or (not h) (eq? 'closed (uv-handle-state h))))

;; poll! : (-> boolean) -> boolean
;; Steps h-loop until (DONE?) holds, at most 16 times, and answers it.
;; 'nowait: nothing here waits on the kernel, only on closes.
(define (poll! done?)
  (let step ((i 0))
    (cond ((done?) #t)
          ((= i 16) #f)
          (else (uv-run h-loop 'nowait) (step (+ i 1))))))

(define (settled? . handles)
  (and (for-all closed-or-absent? handles)
       (not (uv-loop-alive? h-loop))))

;; finish! : target (or target #f) -> object
;; Gives the loop back to this thread, then closes whatever the run made,
;; or for a loop query tears down the loops it made, and answers 'finished,
;; or what was left.
(define (finish! target new)
  (if (uv-loop? target)
      (begin
        (set-loop-owner-thread! target me)
        (guard (e (#t (list 'teardown-raised (describe e))))
          (for-each (lambda (l) (when (and l (uv-loop-open? l)) (uv-loop-teardown! l)))
                    (list target new))
          'finished))
      (begin
        (set-loop-owner-thread! h-loop me)
        (for-each (lambda (h) (when (and h (uv-handle-open? h)) (uv-close! h)))
                  (list target new))
        (drain-server!)
        (if (poll! (lambda () (settled? target new)))
            'finished
            (list 'loop-still-alive (uv-loop-live-handles h-loop))))))

;; drain-server! : -> unspecified
;; Runs sv-loop until it has accepted and closed every connection made of
;; it, so none waits in the listen queue for the next run: a few turns.
(define (drain-server!)
  (let step ((i 0))
    (when (< i 4)
      (uv-run sv-loop 'nowait)
      (step (+ i 1)))))

;; --- the changes ------------------------------------------------------------------
;; At the engine's first expiry the scheduler, still on this thread, does
;; one of these to the target, then resumes the verb:
;;   'close       closes it and runs the loop until the close has freed it,
;;                or tears a target loop down, which frees it;
;;   'reuse       frees it as above, then makes a new handle of its kind or
;;                a new loop, which the allocator gives the freed address: a
;;                call that kept the old pointer acts on the new one;
;;   'handoff     hands the loop to another thread, which leaves the loop's
;;                memory alone;
;;   'other-mode  starts a signal target in the mode its verb does not ask
;;                for, which fixes that mode.
;; change! answers the new handle, #f, or why the change failed.
;;
;; The new handle must take the freed address, or a stale call could not
;; reach it. glibc's calloc takes no block from the thread's cache, where a
;; free of a small block goes first, so seven blocks of the handle's size
;; freed before the close fill that cache, and the handle's block goes
;; where calloc looks (tests/test-request-steps.sps's cancel sweep).
;; macOS's malloc sometimes hands out other blocks first, so the run takes
;; blocks of that size until one lands at the freed address, frees just
;; that one, and makes the handle, which takes it back. And at times macOS
;; keeps the freed block where no allocation on this thread finds it
;; (measured: one run, the same one in every suite run, the block free all
;; along), so split-run starts a run whose handle missed again.
(define (block-size kind)
  (case kind
    ((timer) (uv-handle-size (uv-timer-type)))
    ((signal) (uv-handle-size (uv-signal-type)))
    ((loop) (uv-loop-size))
    (else (stream-block-size (uv-handle-size (uv-tcp-type))))))

(define (fill-cache! size)
  (let ((seven (map (lambda (i) (alloc-block size)) '(1 2 3 4 5 6 7))))
    (for-each free-block! seven)))

;; occupy! : uptr exact-positive-integer -> (list-of uptr)
;; Blocks of SIZE until one lands at FREED, or 64 of them: every block
;; made, the one at FREED first if one did.
(define (occupy! freed size)
  (let next ((made '()) (i 0))
    (let ((b (alloc-block size)))
      (cond ((= b freed) (cons b made))
            ((= i 63) (cons b made))
            (else (next (cons b made) (+ i 1)))))))

;; new-handle-at! : symbol uptr -> (or uv-handle uv-loop)
;; A new handle of h-loop of KIND, or a new loop, made where FREED was if
;; the allocator allows. Under a memory tool, which never hands a freed
;; block back, it is made wherever the tool puts it.
(define (new-handle-at! kind freed)
  (if under-memory-tool?
      (make-handle kind)
      (let* ((held (occupy! freed (block-size kind)))
             (landed? (= (car held) freed)))
        (when landed? (free-block! (car held)))
        (let ((new (make-handle kind)))
          (for-each free-block! (if landed? (cdr held) held))
          new))))

(define (change! mode verb target)
  (case mode
    ((handoff)
     (set-loop-owner-thread! (if (uv-loop? target) target h-loop) other-thread)
     #f)
    ((other-mode)
     (guard (e (#t (list 'change-raised (describe e))))
       (if (eq? verb 'uv-signal-start-oneshot!)
           (uv-signal-start! target 'sigusr2 changed-callback)
           (uv-signal-start-oneshot! target 'sigusr2 changed-callback))
       #f))
    (else
     (let ((kind (verb-kind verb))
           (old (target-ptr target))
           (reuse? (eq? mode 'reuse)))
       (when (and reuse? (not under-memory-tool?)) (fill-cache! (block-size kind)))
       (guard (e (#t (list 'change-raised (describe e))))
         (if (uv-loop? target)
             (uv-loop-teardown! target)
             (begin (uv-close! target)
                    (poll! (lambda () (settled? target)))))
         (and reuse? (new-handle-at! kind old)))))))

;; The refusal a resumed verb owes each change.
(define (refusal-for mode)
  (case mode
    ((handoff) 'wrong-thread)
    ((other-mode) 'mode-fixed)
    (else 'closed)))

;; --- split by a change -------------------------------------------------------------
;; Each run has one right answer:
;;   'refused     expired: resumed, the verb raises the change's refusal
;;                (&uv-handle-closed, or &uv-wrong-thread after a handoff);
;;   'untouched   no expiry: it ran whole and returned.
;; The premise: no expiry lands after a verb's step, whose native call is
;; its last act but for answering. A collection that came due inside the
;; step would be taken where the step ends and spend fuel there, so
;; each attempt starts with a (collect). So a verb that returns, or raises
;; anything else, once resumed made its call after the change.
;;
;; A reuse run whose new handle missed the freed address drops its engine
;; and starts again with a new target, at most four times; the fourth
;; resumes anyway. The run's balance is taken once, before the first, so
;; whatever a dropped attempt left behind still shows. Under a memory tool,
;; which never hands a freed block back, no attempt could land, so none is
;; made again.

;; The fuels of the reuse sweeps' expired runs whose new handle missed the
;; freed address in every attempt, as (verb fuel), latest first.
(define missed-landings '())

;; How many reuse runs were started again, for the record.
(define restarts 0)

;; split-run : symbol symbol exact-positive-integer -> (values verdict boolean)
;; The run's verdict, and whether an expiry reached it.
(define (split-run verb mode fuel)
  (let ((before (balance)))
    (let attempt-run ((tries 1))
      (collect)
      (let ((target (prepare verb)))
        (if (not (target? target))
            (values (list 'not-prepared target) #f)
            (let* ((new #f)
                   (eng (make-engine (lambda () (attempt verb target))))
                   (verdict
                    (eng fuel
                         (lambda (ticks outcome)
                           (if (eq? outcome 'returned) 'untouched (list 'untouched outcome)))
                         (lambda (resume)
                           (let ((old (target-ptr target)))
                             (set! new (change! mode verb target))
                             (cond ((pair? new)
                                    (let ((why new))
                                      (set! new #f)
                                      (list 'change-failed why)))
                                   ((and new (not (eqv? (target-ptr new) old))
                                         (not under-memory-tool?) (< tries 4))
                                    'missed)
                                   (else
                                    (when (and new (not (eqv? (target-ptr new) old)))
                                      (set! missed-landings
                                            (cons (list verb fuel) missed-landings)))
                                    (let ((outcome (resume 1000000 (lambda (ticks o) o)
                                                           (lambda (more) 'still-running))))
                                      (if (equal? outcome (refusal-for mode))
                                          'refused
                                          (list outcome 'after-the-change)))))))))
                   (finished (finish! target new)))
              (if (eq? verdict 'missed)
                  (begin (set! restarts (+ restarts 1))
                         (attempt-run (+ tries 1)))
                  (values (checked-verdict verdict finished before balance)
                          (not (untouched? verdict))))))))))

;; --- dropped ----------------------------------------------------------------------
;; The scheduler drops the engine at the expiry, and the run then closes
;; the handle. Right answers: 'dropped or 'untouched, with nothing left
;; behind, blocks included, interrupts enabled, and the verb's effect whole
;; or not begun: the handle as the run found it, or as a call nothing
;; interrupts leaves one (whole, which a row holds to what the verb
;; promises).

;; observe : symbol uv-handle -> list
;; What a verb's effect changes in its open handle, as libuv and the
;; handle's record see it: whether libuv counts the handle active, the
;; callback the record holds, and a timer's repeat or a signal's mode.
(define (observe verb h)
  (let ((ptr (handle-ptr h)))
    (case (verb-kind verb)
      ((timer) (list (uv-is-active ptr) (callback-name (timer-on-timeout h))
                     (uv-timer-get-repeat ptr)))
      ((signal) (list (uv-is-active ptr) (callback-name (signal-on-signal h))
                      (signal-mode h)))
      (else (list (uv-is-active ptr) (callback-name (tcp-on-connection h)))))))

;; promised-whole : symbol -> list
;; How VERB promises to leave the handle prepare made for it: a start
;; active with its callback (a timer's repeat 0, a signal's mode fixed), a
;; stop inactive with the callback kept, an again active, a set repeat at
;; 5000, a listen active with its callback, and every other TCP verb with
;; nothing active and no callback.
(define promised-wholes
  '((uv-timer-start! 1 the-verbs 0)
    (uv-timer-stop! 0 prepared 3600000)
    (uv-timer-again! 1 prepared 3600000)
    (uv-timer-repeat 0 none 0)
    (uv-timer-set-repeat! 0 none 5000)
    (uv-signal-start! 1 the-verbs continuous)
    (uv-signal-start-oneshot! 1 the-verbs oneshot)
    (uv-signal-stop! 0 prepared continuous)
    (uv-listen! 1 the-verbs)))

(define (promised-whole verb)
  (let ((entry (assq verb promised-wholes)))
    (if entry (cdr entry) '(0 none))))

;; whole : symbol -> list
;; How a call of VERB that nothing interrupts leaves its handle, or why
;; that could not be seen. A row below holds each to promised-whole, so
;; that a verb which does nothing cannot pass for one done whole.
(define (whole verb)
  (let ((h (prepare verb)))
    (if (uv-handle? h)
        (let* ((outcome (attempt verb h))
               (seen (observe verb h)))
          (finish! h #f)
          (if (eq? outcome 'returned) seen (list 'whole-call outcome)))
        (list 'not-prepared h))))

;; drop-run : symbol list exact-positive-integer -> (values verdict boolean)
;; WHOLE is (whole verb).
(define (drop-run verb whole fuel)
  (collect)
  (let* ((before (balance))
         (target (prepare verb)))
    (if (not (uv-handle? target))
        (values (list 'not-prepared target) #f)
        (let* ((found (observe verb target))
               (eng (make-engine (lambda () (attempt verb target))))
               (outcome (eng fuel
                             (lambda (ticks o)
                               (if (eq? o 'returned) 'untouched (list 'untouched o)))
                             (lambda (resume) 'dropped)))
               (left (observe verb target))
               (verdict (if (or (equal? left found) (equal? left whole))
                            outcome
                            (list outcome 'half-made left))))
          (values (checked-verdict verdict (finish! target #f) before balance)
                  (eq? outcome 'dropped))))))

;; --- the sweeps -------------------------------------------------------------------
(define sweep-fuel-cap 400)

;; A wrong run in a split by a close may have handed libuv a freed handle,
;; and the next run's loop could fault on it, so that sweep stops at its
;; first wrong run. The others run to the end.
(define (split-sweep verb mode)
  (sweep-fuels (lambda (fuel) (split-run verb mode fuel))
               sweep-fuel-cap
               (if (eq? mode 'close)
                   (lambda (v) (not (memq v '(refused untouched))))
                   (lambda (v) #f))))

;; Each verb's whole state, as (verb . state). map applies its procedure
;; in no fixed order, so the row below looks each verb up.
(define wholes '())

(define (drop-sweep verb)
  (let ((w (whole verb)))
    (set! wholes (cons (cons verb w) wholes))
    (sweep-fuels (lambda (fuel) (drop-run verb w fuel)) sweep-fuel-cap (lambda (v) #f))))

(define (good-split? v) (memq v '(refused untouched)))

;; The peer query's sweeps connect to this server, and stop at their first
;; run with (not-prepared ...) if they cannot.
(test-equal "precondition: the peer query's server listens on a loopback port"
  'listening
  (if (integer? sv-port) sv-listening (list 'no-port sv-port)))

;; The sweeps that can only fail by name run first, the one a wrong run
;; could fault in last, after the others' rows are out: a fault ends the
;; process and takes every row not yet emitted with it.
(define reuse-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'reuse))) swept-verbs))
(report! 'reuse reuse-sweeps)
(test-equal "a handle verb resumed after its handle was freed and made anew never reaches the new one"
  '()
  (bad-runs good-split? reuse-sweeps))
(test-equal "each reuse sweep caught its verb before its checks and ran it to the end"
  (expected-reach reuse-sweeps 'refused)
  (reach reuse-sweeps))

(define loop-reuse-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'reuse))) loop-verbs))
(report! 'reuse loop-reuse-sweeps)
(test-equal "a loop query resumed after its loop was torn down and made anew never reaches the new loop"
  '()
  (bad-runs good-split? loop-reuse-sweeps))
(test-equal "each loop query's reuse sweep caught it before its checks and ran it to the end"
  (expected-reach loop-reuse-sweeps 'refused)
  (reach loop-reuse-sweeps))

;; The witness: the new handle or loop took the freed address in every run
;; the engine expired in. A run where it did not could not have shown a
;; stale call reaching the new one. Memory tools never hand a freed block
;; back, so there the witness lands in no run.
(display "  [informational] reuse runs started again for a missed landing: ")
(display restarts) (newline)
(test-equal "the reuse sweeps' new handle or loop took the freed address in every expired run"
  '()
  (if under-memory-tool? '() (reverse missed-landings)))

(define handoff-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'handoff))) swept-verbs))
(report! 'handoff handoff-sweeps)
(test-equal "a handle verb whose loop changes hands is refused"
  '()
  (bad-runs good-split? handoff-sweeps))
(test-equal "each handoff sweep caught its verb before its checks and ran it to the end"
  (expected-reach handoff-sweeps 'refused)
  (reach handoff-sweeps))

;; Of the loop queries only uv-update-time! is loop-thread-only by a check:
;; the other three are by contract, unchecked (docs/threads.md).
(define loop-handoff-sweeps
  (list (cons 'uv-update-time! (split-sweep 'uv-update-time! 'handoff))))
(report! 'handoff loop-handoff-sweeps)
(test-equal "uv-update-time! resumed after its loop changed hands is refused"
  '()
  (bad-runs good-split? loop-handoff-sweeps))
(test-equal "uv-update-time!'s handoff sweep caught it before its checks and ran it to the end"
  (expected-reach loop-handoff-sweeps 'refused)
  (reach loop-handoff-sweeps))

(define mode-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'other-mode)))
       '(uv-signal-start! uv-signal-start-oneshot!)))
(report! 'other-mode mode-sweeps)
(test-equal "a signal start resumed after its handle started in the other mode is refused"
  '()
  (bad-runs good-split? mode-sweeps))
(test-equal "each mode sweep caught its start before its checks and ran it to the end"
  (expected-reach mode-sweeps 'refused)
  (reach mode-sweeps))

(define drop-sweeps
  (map (lambda (verb) (cons verb (drop-sweep verb))) swept-verbs))
(report! 'drop drop-sweeps)
(test-equal "a handle verb whose engine is dropped leaves no block behind, and its effect whole or not begun"
  '()
  (bad-runs (lambda (v) (memq v '(dropped untouched))) drop-sweeps))
(test-equal "each drop sweep dropped its verb and ran it to the end"
  (expected-reach drop-sweeps 'dropped)
  (reach drop-sweeps))
(test-equal "a call of each verb that nothing interrupts leaves its handle as the verb promises"
  (map (lambda (verb) (cons verb (promised-whole verb))) swept-verbs)
  (map (lambda (verb) (or (assq verb wholes) (list verb 'no-drop-sweep))) swept-verbs))

(define close-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'close))) swept-verbs))
(report! 'close close-sweeps)
(test-equal "a handle verb split by its handle's close is refused"
  '()
  (bad-runs good-split? close-sweeps))
(test-equal "each close sweep caught its verb before its checks and ran it to the end"
  (expected-reach close-sweeps 'refused)
  (reach close-sweeps))

(define loop-close-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'close))) loop-verbs))
(report! 'close loop-close-sweeps)
(test-equal "a loop query split by its loop's teardown is refused"
  '()
  (bad-runs good-split? loop-close-sweeps))
(test-equal "each loop query's close sweep caught it before its checks and ran it to the end"
  (expected-reach loop-close-sweeps 'refused)
  (reach loop-close-sweeps))

;; --- refused inside the step ------------------------------------------------------
;; A refusal the step comes to after its allocation frees the block: an
;; address libuv cannot parse, found once the block is made, and libuv's
;; own refusals. Each answers the refusal with what the run left.

;; refused-run : symbol boolean (uv-handle -> object) -> object
;; CALL's refusal on a new handle of h-loop of KIND, a client bound first
;; when BIND?, as (refused who reason) or (refused errno), with what the
;; run left.
(define (refused-run kind bind? call)
  (let* ((before (balance))
         (h (make-handle kind))
         (bound (if bind?
                    (guard (e (#t (list 'bind-raised (describe e))))
                      (uv-tcp-bind! h "127.0.0.1" 0)
                      'bound)
                    'bound))
         (answer (if (eq? bound 'bound)
                     (guard (e ((uv-invalid-argument? e)
                                (list 'refused (uv-invalid-argument-who e)
                                      (uv-invalid-argument-reason e)))
                               ((uv-errno-error? e) (list 'refused (uv-errno-error-errno e)))
                               (#t (list 'raised (describe e))))
                       (call h)
                       'returned)
                     bound)))
    (checked-verdict answer (finish! h #f) before balance)))

(test-equal "a bind to an address libuv cannot parse is refused, its block freed"
  '(refused uv-tcp-bind! bad-address)
  (refused-run 'tcp #f (lambda (tcp) (uv-tcp-bind! tcp "not-an-ip" 0))))

(test-equal "a second bind of a bound client is refused by libuv, its block freed"
  '(refused EINVAL)
  (refused-run 'tcp #t (lambda (tcp) (uv-tcp-bind! tcp "127.0.0.1" 0))))

(test-equal "the address and port queries of a client with no socket are refused by libuv, their blocks freed"
  '((refused EBADF) (refused EBADF) (refused EBADF))
  (list (refused-run 'tcp #f uv-tcp-getsockname-port)
        (refused-run 'tcp #f uv-tcp-sockname-address)
        (refused-run 'tcp #f uv-tcp-peer-address)))

(test-equal "the peer query of a bound client that never connected is refused ENOTCONN, its block freed"
  '(refused ENOTCONN)
  (refused-run 'tcp #t uv-tcp-peer-address))

(test-equal "the buffer-size verbs on a client with no socket are refused by libuv, their blocks freed"
  '((refused EBADF) (refused EBADF) (refused EBADF) (refused EBADF))
  (list (refused-run 'tcp #f uv-send-buffer-size)
        (refused-run 'tcp #f (lambda (tcp) (uv-send-buffer-size! tcp 65536)))
        (refused-run 'tcp #f uv-recv-buffer-size)
        (refused-run 'tcp #f (lambda (tcp) (uv-recv-buffer-size! tcp 65536)))))

;; A listen libuv refuses: a client bound to the server's port, which the
;; bind takes and libuv holds back as an error for the listen to answer.
(test-equal "a listen libuv refuses is refused with its errno, storing no callback"
  '((refused EADDRINUSE) none)
  (let* ((client #f)
         (answer (refused-run 'tcp #f
                              (lambda (tcp)
                                (set! client tcp)
                                (uv-tcp-bind! tcp "127.0.0.1" sv-port)
                                (uv-listen! tcp 16 the-callback)))))
    (list answer (and client (callback-name (tcp-on-connection client))))))

;; --- refused on entry -------------------------------------------------------------
;; A number its C parameter cannot take would raise from Chez's own check
;; of a foreign call's arguments, inside the step, with interrupts
;; disabled. Each verb refuses one by name on entry instead, and the
;; largest each parameter takes still reaches libuv. A listening client is
;; bound to loopback first: unbound, the kernel would bind it to every
;; interface.

;; past-entry : object -> object
;; 'reached-libuv for a call that returned or that libuv refused; any other
;; answer as it came.
(define (past-entry answer)
  (if (or (eq? answer 'returned)
          (and (pair? answer) (eq? (car answer) 'refused)
               (symbol? (cadr answer)) (null? (cddr answer))))
      'reached-libuv
      answer))

(test-equal "a timeout, repeat, backlog or delay too large for its C parameter is refused by name"
  '((refused uv-timer-start! timeout-out-of-range)
    (refused uv-timer-start! repeat-out-of-range)
    (refused uv-timer-set-repeat! repeat-out-of-range)
    (refused uv-listen! backlog-out-of-range)
    (refused uv-tcp-keepalive! delay-out-of-range))
  (list (refused-run 'timer #f (lambda (t) (uv-timer-start! t the-callback (expt 2 64) 0)))
        (refused-run 'timer #f (lambda (t) (uv-timer-start! t the-callback 0 (expt 2 64))))
        (refused-run 'timer #f (lambda (t) (uv-timer-set-repeat! t (expt 2 64))))
        (refused-run 'tcp #t (lambda (tcp) (uv-listen! tcp (expt 2 31) the-callback)))
        (refused-run 'tcp #f (lambda (tcp) (uv-tcp-keepalive! tcp #t (expt 2 32))))))

(test-equal "the largest timeout, repeat, backlog and delay their C parameters take reach libuv"
  '(reached-libuv reached-libuv reached-libuv reached-libuv reached-libuv)
  (map past-entry
       (list (refused-run 'timer #f
                          (lambda (t) (uv-timer-start! t the-callback (- (expt 2 64) 1) 0)))
             (refused-run 'timer #f
                          (lambda (t) (uv-timer-start! t the-callback an-hour (- (expt 2 64) 1))))
             (refused-run 'timer #f (lambda (t) (uv-timer-set-repeat! t (- (expt 2 64) 1))))
             (refused-run 'tcp #t (lambda (tcp) (uv-listen! tcp (- (expt 2 31) 1) the-callback)))
             (refused-run 'tcp #f (lambda (tcp) (uv-tcp-keepalive! tcp #t (- (expt 2 32) 1)))))))

(test-equal "h-loop and the server's loop tear down"
  '(torn-down torn-down)
  (map (lambda (loop)
         (guard (e (#t (list 'teardown-raised (describe e))))
           (uv-loop-teardown! loop)
           'torn-down))
       (list h-loop sv-loop)))

(test-end "handle-steps")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
