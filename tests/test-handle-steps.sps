#!r6rs
;;; SRFI-64 suite for the handle verbs an engine splits or drops (#86;
;;; ADR-0019's decision 3 amendments). Here, the scratch verbs, which borrow
;;; a block for the call: uv-tcp-bind!, uv-tcp-getsockname-port,
;;; uv-tcp-sockname-address, uv-tcp-peer-address, and the four buffer-size
;;; verbs (uv-send-buffer-size, uv-send-buffer-size!, uv-recv-buffer-size,
;;; uv-recv-buffer-size!).
;;;
;;; A green-thread scheduler on the loop thread runs each task in an engine,
;;; and a task's fuel can run out anywhere inside one of these verbs. Each
;;; checked its handle, allocated its scratch, read the handle's pointer and
;;; called libuv, and freed the scratch in a guard, with interrupts enabled
;;; between, so:
;;; - Split: another task closed the handle, or handed its loop to another
;;;   thread, and the verb resumed past its checks. It called libuv with the
;;;   freed handle, or with whatever handle took its address, or raced the
;;;   new owner's thread on the handle.
;;; - Dropped, as a timeout drops a task: no guard runs after the
;;;   suspension, so the scratch was lost.
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
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts alloc-block free-block!
              uv-handle-size)
        (only (libuv private constants) uv-tcp-type)
        (uv-sweep)
        (only (uv-evidence) describe under-memory-tool?)
        ;; make-engine drives the sweeps; the interrupt pair checks that no
        ;; run leaves interrupts disabled; collect starts each run with no
        ;; collection due.
        (only (chezscheme) make-engine disable-interrupts enable-interrupts
              get-thread-id collect))

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

(define me (get-thread-id))

;; Another thread's id, for a loop handed to it: no thread runs the loop,
;; but its owner is no longer this one.
(define other-thread (+ me 1))

;; Every target is a new client of this loop. Nothing here makes a client
;; active, so once its clients have closed, the loop is not alive.
(define h-loop (make-uv-loop))

;; --- what a run must leave as it found it ------------------------------------

(define (interrupts-enabled?)
  (disable-interrupts)
  (zero? (enable-interrupts)))

;; The registry, and every debug counter, blocks included.
(define (balance) (cons (registry-count) (live-counts)))

;; residue : pair -> list
;; What changed since BEFORE, as (name delta) pairs; '() when nothing did.
(define (residue before)
  (let ((after (balance)))
    (append
     (if (= (car before) (car after))
         '()
         (list (list 'registry (- (car after) (car before)))))
     (filter (lambda (x) x)
             (map (lambda (b a)
                    (and (not (= (cdr b) (cdr a)))
                         (list (car b) (- (cdr a) (cdr b)))))
                  (cdr before) (cdr after))))))

;; run-verdict : pair verdict object -> verdict
;; The verdict, or what the run left behind with it. FINISHED is what
;; finish! answered: 'finished, or why the run could not be tidied.
(define (run-verdict before verdict finished)
  (let ((left (residue before)))
    (cond ((not (interrupts-enabled?))
           (enable-interrupts)
           (list 'interrupts-left-disabled verdict))
          ((not (eq? finished 'finished)) (list verdict 'finish finished))
          ((pair? left) (list verdict 'left left))
          (else verdict))))

;; --- the verbs ------------------------------------------------------------------
;; Each attempt calls its verb by name, inside a guard that catches every
;; raise (tests/test-seed-gates.sps's rule 4 reads that from the source),
;; and answers:
;;   'returned          the verb returned;
;;   'closed            it raised &uv-handle-closed;
;;   'wrong-thread      it raised &uv-wrong-thread;
;;   (raised message)   it raised something else.
(define scratch-verbs
  '(uv-tcp-bind! uv-tcp-getsockname-port uv-tcp-sockname-address
    uv-tcp-peer-address uv-send-buffer-size uv-send-buffer-size!
    uv-recv-buffer-size uv-recv-buffer-size!))

(define (refusal e)
  (cond ((uv-handle-closed? e) 'closed)
        ((uv-wrong-thread? e) 'wrong-thread)
        (else (list 'raised (describe e)))))

;; By quoted name: rule 4 would read a case clause's datum list,
;; ((uv-tcp-bind!) ...), as a call of the verb.
(define (call-verb verb tcp)
  (cond ((eq? verb 'uv-tcp-bind!) (uv-tcp-bind! tcp "127.0.0.1" 0))
        ((eq? verb 'uv-tcp-getsockname-port) (uv-tcp-getsockname-port tcp))
        ((eq? verb 'uv-tcp-sockname-address) (uv-tcp-sockname-address tcp))
        ((eq? verb 'uv-tcp-peer-address) (uv-tcp-peer-address tcp))
        ((eq? verb 'uv-send-buffer-size) (uv-send-buffer-size tcp))
        ((eq? verb 'uv-send-buffer-size!) (uv-send-buffer-size! tcp 65536))
        ((eq? verb 'uv-recv-buffer-size) (uv-recv-buffer-size tcp))
        (else (uv-recv-buffer-size! tcp 65536))))

(define (attempt verb tcp)
  (guard (e (#t (refusal e)))
    (call-verb verb tcp)
    'returned))

;; The peer query's target is connected, to a server listening on a loop of
;; its own, which accepts and closes each connection when finish! runs it.
;; Unconnected, the query raises ENOTCONN after its step, and the work of
;; that raise is where an engine could expire after the call, which the
;; split oracle below rules out.
(define sv-loop (make-uv-loop))
(define sv (make-uv-tcp sv-loop))

(define sv-port
  (guard (e (#t (list 'server-bind-raised (describe e))))
    (uv-tcp-bind! sv "127.0.0.1" 0)
    (uv-tcp-getsockname-port sv)))

(uv-listen! sv 128
            (lambda (err)
              (unless err
                (guard (e (#t #f))
                  (uv-close! (uv-accept! sv))))))

;; connect! : uv-tcp -> (or 'connected list)
;; Connects TCP to the server, running h-loop until the connect completes,
;; at most 64 times.
(define (connect! tcp)
  (let ((status #f))
    (guard (e (#t (list 'connect-raised (describe e))))
      (uv-tcp-connect! tcp "127.0.0.1" sv-port
                       (lambda (err) (set! status (if err (describe err) 'connected))))
      (let step ((i 0))
        (cond (status status)
              ((= i 64) 'connect-never-completed)
              (else (uv-run h-loop 'once) (step (+ i 1))))))))

;; prepare : symbol -> (or uv-tcp list)
;; A new client of h-loop: unbound for the bind, which binds it, connected
;; for the peer query, and bound to a loopback port for every other verb,
;; which needs a socket to ask.
(define (prepare verb)
  (let ((tcp (make-uv-tcp h-loop)))
    (cond ((eq? verb 'uv-tcp-bind!) tcp)
          ((eq? verb 'uv-tcp-peer-address)
           (let ((connected (connect! tcp)))
             (if (eq? connected 'connected)
                 tcp
                 (begin (uv-close! tcp) (list 'not-connected connected)))))
          (else
           (guard (e (#t (uv-close! tcp) (list 'bind-raised (describe e))))
             (uv-tcp-bind! tcp "127.0.0.1" 0)
             tcp)))))

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

;; finish! : uv-tcp (or uv-tcp #f) -> object
;; Gives the loop back to this thread, then closes whatever the run made,
;; and answers 'finished, or what was left.
(define (finish! target new)
  (set-loop-owner-thread! h-loop me)
  (for-each (lambda (h) (when (and h (uv-handle-open? h)) (uv-close! h)))
            (list target new))
  (drain-server!)
  (if (poll! (lambda () (settled? target new)))
      'finished
      (list 'loop-still-alive (uv-loop-live-handles h-loop))))

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
;;   'close     closes it and runs the loop until the close has freed it;
;;   'reuse     closes it as above, then makes a new client, which the
;;              allocator gives the freed address: a call that kept the old
;;              pointer acts on the new client;
;;   'handoff   hands the loop to another thread, which leaves the loop's
;;              memory alone.
;; change! answers the new client, or #f.
;;
;; The new client must take the freed address, or a stale call could not
;; reach it. glibc's calloc takes no block from the thread's cache, where a
;; free of a small block goes first, so seven blocks of the client's size
;; freed before the close fill that cache, and the client's block goes
;; where calloc looks (tests/test-request-steps.sps's cancel sweep, #75).
;; macOS's malloc sometimes hands out other blocks first, so the run takes
;; blocks of that size until one lands at the freed address, frees just
;; that one, and makes the client, which takes it back. And now and then
;; macOS keeps the freed block where no allocation on this thread finds it
;; (one run against main's verbs, the same one in every suite run, the
;; block free all along), so split-run starts a run whose client missed
;; again.
(define tcp-block-size (stream-block-size (uv-handle-size (uv-tcp-type))))

(define (fill-cache!)
  (let ((seven (map (lambda (i) (alloc-block tcp-block-size)) '(1 2 3 4 5 6 7))))
    (for-each free-block! seven)))

;; occupy! : uptr -> (list-of uptr)
;; Blocks of the client's size until one lands at FREED, or 64 of them:
;; every block made, the one at FREED first if one did.
(define (occupy! freed)
  (let next ((made '()) (i 0))
    (let ((b (alloc-block tcp-block-size)))
      (cond ((= b freed) (cons b made))
            ((= i 63) (cons b made))
            (else (next (cons b made) (+ i 1)))))))

;; new-client-at! : uptr -> uv-tcp
;; A new client of h-loop, made where FREED was if the allocator allows.
(define (new-client-at! freed)
  (let* ((held (occupy! freed))
         (landed? (= (car held) freed)))
    (when landed? (free-block! (car held)))
    (let ((new (make-uv-tcp h-loop)))
      (for-each free-block! (if landed? (cdr held) held))
      new)))

(define (change! mode target)
  (case mode
    ((handoff) (set-loop-owner-thread! h-loop other-thread) #f)
    (else
     (let ((old (handle-ptr target)))
       (fill-cache!)
       (uv-close! target)
       (poll! (lambda () (settled? target)))
       (and (eq? mode 'reuse) (new-client-at! old))))))

;; The refusal a resumed verb owes each change.
(define (refusal-for mode)
  (if (eq? mode 'handoff) 'wrong-thread 'closed))

;; --- split by a change -------------------------------------------------------------
;; Each run has one right answer:
;;   'refused     expired: resumed, the verb raises the change's refusal
;;                (&uv-handle-closed, or &uv-wrong-thread after a handoff);
;;   'untouched   no expiry: it ran whole and returned.
;; The premise: no expiry lands after a verb's step, whose native call is
;; its last act but for answering. A collection that came due inside the
;; step would be taken where the step ends and spend fuel there (#68), so
;; each attempt starts with a (collect). So a verb that returns, or raises
;; anything else, once resumed made its call after the change.
;;
;; A reuse run whose new client missed the freed address drops its engine
;; and starts again with a new target, at most four times; the fourth
;; resumes anyway. The run's balance is taken once, before the first, so
;; whatever a dropped attempt left behind still shows. Under a memory tool,
;; which never hands a freed block back, no attempt could land, so none is
;; made again.

;; The fuels of the reuse sweeps' expired runs whose new client missed the
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
        (if (not (uv-handle? target))
            (values (list 'not-prepared target) #f)
            (let* ((new #f)
                   (eng (make-engine (lambda () (attempt verb target))))
                   (verdict
                    (eng fuel
                         (lambda (ticks outcome)
                           (if (eq? outcome 'returned) 'untouched (list 'untouched outcome)))
                         (lambda (resume)
                           (let ((old (handle-ptr target)))
                             (set! new (change! mode target))
                             (cond ((and new (not (eqv? (handle-ptr new) old))
                                         (not under-memory-tool?) (< tries 4))
                                    'missed)
                                   (else
                                    (when (and new (not (eqv? (handle-ptr new) old)))
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
                  (values (run-verdict before verdict finished)
                          (not (untouched? verdict))))))))))

(define (untouched? verdict)
  (or (eq? verdict 'untouched)
      (and (pair? verdict) (eq? (car verdict) 'untouched))))

;; --- dropped ----------------------------------------------------------------------
;; The scheduler drops the engine at the expiry, and the run then closes
;; the client. Right answers: 'dropped or 'untouched, with nothing left
;; behind, blocks included, and interrupts enabled.

;; drop-run : symbol exact-positive-integer -> (values verdict boolean)
(define (drop-run verb fuel)
  (collect)
  (let* ((before (balance))
         (target (prepare verb)))
    (if (not (uv-handle? target))
        (values (list 'not-prepared target) #f)
        (let* ((eng (make-engine (lambda () (attempt verb target))))
               (outcome (eng fuel
                             (lambda (ticks o)
                               (if (eq? o 'returned) 'untouched (list 'untouched o)))
                             (lambda (resume) 'dropped))))
          (values (run-verdict before outcome (finish! target #f))
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

(define (drop-sweep verb)
  (sweep-fuels (lambda (fuel) (drop-run verb fuel)) sweep-fuel-cap (lambda (v) #f)))

;; bad-runs : (verdict -> boolean) sweeps -> (list-of (list name fuel verdict))
(define (bad-runs good? sweeps)
  (apply append
         (map (lambda (s)
                (map (lambda (run) (list (car s) (car run) (cadr run)))
                     (filter (lambda (run) (not (good? (cadr run)))) (cdr s))))
              sweeps)))

;; reach : sweeps -> (list-of (list name first last))
;; The rows that look for bad runs and find none say nothing unless each
;; sweep caught its verb before its checks (FIRST) and ran it to the end
;; (the last run untouched).
(define (reach sweeps)
  (map (lambda (s)
         (let ((runs (cdr s)))
           (list (car s) (cadar runs) (cadr (list-ref runs (- (length runs) 1))))))
       sweeps))

(define (expected-reach sweeps first)
  (map (lambda (s) (list (car s) first 'untouched)) sweeps))

;; fuel-map : runs -> list, e.g. ((refused 1 9) (untouched 10 10)): each
;; run of equal verdicts with its first and last fuel, for the record.
(define (fuel-map runs)
  (let collect ((runs runs) (acc '()))
    (cond ((null? runs) (reverse acc))
          ((and (pair? acc) (equal? (caar acc) (cadar runs)))
           (collect (cdr runs)
                    (cons (list (caar acc) (cadar acc) (caar runs)) (cdr acc))))
          (else (collect (cdr runs)
                         (cons (list (cadar runs) (caar runs) (caar runs)) acc))))))

(define (report! kind sweeps)
  (for-each (lambda (s)
              (display "  [informational] ") (display kind) (display " ")
              (display (car s)) (display ": ")
              (write (fuel-map (cdr s))) (newline))
            sweeps))

(define (good-split? v) (memq v '(refused untouched)))

;; The sweeps that can only fail by name run first, the one a wrong run
;; could fault in last (AGENTS.md: emit a sweep's row as soon as it ends).
(define reuse-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'reuse))) scratch-verbs))
(report! 'reuse reuse-sweeps)
(test-equal "a scratch verb resumed after its client was freed and made anew never reaches the new one"
  '()
  (bad-runs good-split? reuse-sweeps))
(test-equal "each reuse sweep caught its verb before its checks and ran it to the end"
  (expected-reach reuse-sweeps 'refused)
  (reach reuse-sweeps))

;; The witness: the new client took the freed client's address in every
;; run the engine expired in. A run where it did not could not have shown
;; a stale call reaching the new client. Memory tools never hand a freed
;; block back, so there the witness lands in no run.
(display "  [informational] reuse runs started again for a missed landing: ")
(display restarts) (newline)
(test-equal "the reuse sweeps' new client took the freed client's address in every expired run"
  '()
  (if under-memory-tool? '() (reverse missed-landings)))

(define handoff-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'handoff))) scratch-verbs))
(report! 'handoff handoff-sweeps)
(test-equal "a scratch verb whose loop changes hands is refused"
  '()
  (bad-runs good-split? handoff-sweeps))
(test-equal "each handoff sweep caught its verb before its checks and ran it to the end"
  (expected-reach handoff-sweeps 'refused)
  (reach handoff-sweeps))

(define drop-sweeps
  (map (lambda (verb) (cons verb (drop-sweep verb))) scratch-verbs))
(report! 'drop drop-sweeps)
(test-equal "a scratch verb whose engine is dropped leaves no block behind"
  '()
  (bad-runs (lambda (v) (memq v '(dropped untouched))) drop-sweeps))
(test-equal "each drop sweep dropped its verb and ran it to the end"
  (expected-reach drop-sweeps 'dropped)
  (reach drop-sweeps))

(define close-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'close))) scratch-verbs))
(report! 'close close-sweeps)
(test-equal "a scratch verb split by its client's close is refused"
  '()
  (bad-runs good-split? close-sweeps))
(test-equal "each close sweep caught its verb before its checks and ran it to the end"
  (expected-reach close-sweeps 'refused)
  (reach close-sweeps))

;; --- refused inside the step ------------------------------------------------------
;; A refusal the step comes to after its allocation frees the block: an
;; address libuv cannot parse, found once the block is made, and libuv's
;; own refusals. Each answers the refusal with what the run left.

;; refused-run : boolean (uv-tcp -> object) -> object
;; CALL's refusal on a new client of h-loop, bound first when BIND?, as
;; (refused who reason) or (refused errno), with what the run left.
(define (refused-run bind? call)
  (let* ((before (balance))
         (tcp (make-uv-tcp h-loop))
         (bound (if bind?
                    (guard (e (#t (list 'bind-raised (describe e))))
                      (uv-tcp-bind! tcp "127.0.0.1" 0)
                      'bound)
                    'bound))
         (answer (if (eq? bound 'bound)
                     (guard (e ((uv-invalid-argument? e)
                                (list 'refused (uv-invalid-argument-who e)
                                      (uv-invalid-argument-reason e)))
                               ((uv-errno-error? e) (list 'refused (uv-errno-error-errno e)))
                               (#t (list 'raised (describe e))))
                       (call tcp)
                       'returned)
                     bound)))
    (run-verdict before answer (finish! tcp #f))))

(test-equal "a bind to an address libuv cannot parse is refused, its block freed"
  '(refused uv-tcp-bind! bad-address)
  (refused-run #f (lambda (tcp) (uv-tcp-bind! tcp "not-an-ip" 0))))

(test-equal "a second bind of a bound client is refused by libuv, its block freed"
  '(refused EINVAL)
  (refused-run #t (lambda (tcp) (uv-tcp-bind! tcp "127.0.0.1" 0))))

(test-equal "the address and port queries of a client with no socket are refused by libuv, their blocks freed"
  '((refused EBADF) (refused EBADF) (refused EBADF))
  (list (refused-run #f uv-tcp-getsockname-port)
        (refused-run #f uv-tcp-sockname-address)
        (refused-run #f uv-tcp-peer-address)))

(test-equal "the peer query of a bound client that never connected is refused ENOTCONN, its block freed"
  '(refused ENOTCONN)
  (refused-run #t uv-tcp-peer-address))

(test-equal "the buffer-size verbs on a client with no socket are refused by libuv, their blocks freed"
  '((refused EBADF) (refused EBADF) (refused EBADF) (refused EBADF))
  (list (refused-run #f uv-send-buffer-size)
        (refused-run #f (lambda (tcp) (uv-send-buffer-size! tcp 65536)))
        (refused-run #f uv-recv-buffer-size)
        (refused-run #f (lambda (tcp) (uv-recv-buffer-size! tcp 65536)))))

(test-equal "h-loop and the server's loop tear down"
  '(torn-down torn-down)
  (map (lambda (loop)
         (guard (e (#t (list 'teardown-raised (describe e))))
           (uv-loop-teardown! loop)
           'torn-down))
       (list h-loop sv-loop)))

(test-end "handle-steps")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
