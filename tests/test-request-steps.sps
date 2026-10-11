#!r6rs
;;; SRFI-64 suite for the request verbs split or dropped by an engine:
;;; uv-tcp-connect!, uv-getaddrinfo! and uv-getnameinfo!, and, in its own
;;; section at the end, uv-cancel!.
;;;
;;; A green-thread scheduler on the loop thread runs each task in an engine,
;;; and a task's fuel can run out anywhere inside one of these verbs. Each
;;; of the first three checks its handle or loop, reads its pointer,
;;; allocates its request, fills it, registers and counts it, and calls
;;; libuv, all in one interrupt-free step (one-step). With interrupts
;;; enabled between those steps:
;;; - Split: another task closes the handle, tears the loop down or hands
;;;   the loop to another thread, and the verb resumes past its checks. It
;;;   calls libuv with a freed handle or loop, or races the new owner's
;;;   uv_run on the loop's request count.
;;; - Dropped, as a timeout drops a task: whatever the verb had allocated
;;;   and not yet handed to libuv is lost: a block, or a request
;;;   registered and counted that libuv never saw.
;;;
;;; Each sweep runs a verb in an engine at rising fuel (uv-sweep's
;;; sweep-fuels). Fuel 1 expires before the verb's own checks, and a sweep
;;; stops at the first run no expiry reaches, so between them every point in
;;; the verb is visited.
;;;
;;; NOT pure: it drives real loops. Never add this to the Makefile's
;;; PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv tcp)
        (libuv dns)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts alloc-block free-block!
              uv-req-size align-16)
        (only (libuv private constants) uv-getaddrinfo-req-type sizeof-addrinfo)
        (uv-testing)
        (uv-sweep)
        (only (uv-evidence) describe under-memory-tool?)
        ;; make-engine drives the sweeps; collect starts each cancel run with
        ;; no collection due.
        (only (chezscheme) make-engine collect))

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

(test-begin "request-steps")

(define (nop . args) #f)
;; libuv opens a pipe of its own with the first loop a process makes, and
;; its threadpool's threads with the first lookup; both last for the life of
;; the process. One lookup, run to its end on a loop torn down after, keeps
;; both out of every run's balance.
(let ((loop (make-uv-loop)) (done #f))
  (guard (e (#t (display "  [informational] the warm-up lookup raised: ")
                (display (describe e)) (newline)))
    (uv-getaddrinfo! loop "127.0.0.1" #f (list (cons 'flags '(numeric-host)))
                     (lambda (err results) (set! done #t))))
  (run-until/ticking loop (lambda () done) 4000)
  (uv-loop-teardown! loop))

;; --- what a run must leave as it found it ------------------------------------

;; The registry, and every debug counter, blocks included, as (name . count).
(define (balance) (cons (cons 'registry (registry-count)) (live-counts)))

;; --- the verbs ------------------------------------------------------------------
;; Each attempt calls its verb by name, inside a guard that catches every
;; raise (tests/test-seed-gates.sps's rule 4 reads that from the source),
;; and answers:
;;   'returned          the verb returned its request;
;;   'closed            it raised &uv-handle-closed;
;;   'wrong-thread      it raised &uv-wrong-thread;
;;   (raised message)   it raised something else.
(define (refusal e)
  (cond ((uv-handle-closed? e) 'closed)
        ((uv-wrong-thread? e) 'wrong-thread)
        (else (list 'raised (describe e)))))

;; A connect goes to a server listening on a loop of its own, which nothing
;; runs: the kernel completes a handshake into the listen queue without it,
;; and no run lets the client's loop deliver one before the client closes.
(define sv-loop (make-uv-loop))
(define sv (make-uv-tcp sv-loop))
(define sv-port (bind-loopback! sv))
(uv-listen! sv 128 nop)

(define (connect-attempt tcp)
  (guard (e (#t (refusal e)))
    (uv-tcp-connect! tcp "127.0.0.1" sv-port nop)
    'returned))

;; Numeric lookups never consult a resolver.
(define (getaddrinfo-attempt loop)
  (guard (e (#t (refusal e)))
    (uv-getaddrinfo! loop "127.0.0.1" #f (list (cons 'flags '(numeric-host))) nop)
    'returned))

(define (getnameinfo-attempt loop)
  (guard (e (#t (refusal e)))
    (uv-getnameinfo! loop "127.0.0.1" 80 '(numeric-host numeric-serv) nop)
    'returned))

;; By quoted name: rule 4 would read a case clause's datum list,
;; ((uv-tcp-connect!) ...), as a call of the verb.
(define (attempt verb target)
  (cond ((eq? verb 'uv-tcp-connect!) (connect-attempt target))
        ((eq? verb 'uv-getaddrinfo!) (getaddrinfo-attempt target))
        (else (getnameinfo-attempt target))))

(define (connect? verb) (eq? verb 'uv-tcp-connect!))

;; A connect is made on a new client of one loop the suite keeps; a lookup
;; on a new loop of its own. That loop, and only it, is alive once libuv
;; holds the verb's request: the client is not active until it connects.
;; So whether a verb has made its native call is libuv's own answer, read
;; with the loop's owner unchanged.
(define cl-loop (make-uv-loop))

(define (prepare verb)
  (if (connect? verb) (make-uv-tcp cl-loop) (make-uv-loop)))

(define (target-loop verb target)
  (if (connect? verb) cl-loop target))

(define (closed-or-absent? h) (or (not h) (eq? 'closed (uv-handle-state h))))

;; poll-cl! : (-> boolean) -> boolean
;; Steps the client loop until (DONE?) holds, at most 16 times, and answers
;; it. 'nowait: nothing here waits on the kernel, only on closes and the
;; cancellations they deliver.
(define (poll-cl! done?)
  (let step ((i 0))
    (cond ((done?) #t)
          ((= i 16) #f)
          (else (uv-run cl-loop 'nowait) (step (+ i 1))))))

(define (settled-client? . handles)
  (and (for-all closed-or-absent? handles)
       (not (uv-loop-alive? cl-loop))))

;; teardown : uv-loop -> (or 'torn-down list)
;; A teardown cancels the loop's lookups, runs them to their ends and
;; closes the loop.
(define (teardown loop)
  (guard (e (#t (list 'teardown-raised (describe e))))
    (when (uv-loop-open? loop) (uv-loop-teardown! loop))
    'torn-down))

;; --- the changes ------------------------------------------------------------------
;; At the engine's first expiry the scheduler, still on this thread, does
;; one of these to what the verb was given, then resumes the verb:
;;   'close     closes the client and runs its loop until the close has
;;              freed it (connect);
;;   'teardown  tears the lookup's loop down, freeing it (lookups);
;;   'handoff   hands the verb's loop to another thread, which leaves the
;;              loop's memory alone;
;;   'reuse     closes or tears down as above, then makes a new client or
;;              loop, which macOS's malloc gives the freed address: a call
;;              that kept the old pointer acts on the new one.
;; change! answers the new client or loop, or #f.
(define (change! verb mode target)
  (case mode
    ((handoff) (set-loop-owner-thread! (target-loop verb target) other-thread) #f)
    (else
     (if (connect? verb)
         (begin (uv-close! target)
                (poll-cl! (lambda () (settled-client? target)))
                (and (eq? mode 'reuse) (make-uv-tcp cl-loop)))
         (begin (teardown target)
                (and (eq? mode 'reuse) (make-uv-loop)))))))

;; The refusal a resumed verb owes each change when its call was not made.
(define (refusal-for mode)
  (if (eq? mode 'handoff) 'wrong-thread 'closed))

;; stale? : symbol symbol (or uv-tcp uv-loop #f) -> boolean
;; Whether libuv holds a request the change should have kept out: once a
;; client has closed and its loop run, nothing keeps that loop alive but a
;; call made after the close, on the new client if there is one; a new loop
;; is alive only if a lookup was started on it. A lookup on a freed loop
;; has no loop left to ask.
(define (stale? verb mode new)
  (cond ((eq? mode 'handoff) #f)
        ((connect? verb) (uv-loop-alive? cl-loop))
        (new (uv-loop-alive? new))
        (else #f)))

;; finish! : symbol uv-tcp-or-loop (or uv-tcp uv-loop #f) -> object
;; Gives the loop back to this thread, then closes whatever the run made,
;; and answers 'finished, or what was left.
(define (finish! verb target new)
  (set-loop-owner-thread! (target-loop verb target) me)
  (if (connect? verb)
      (begin
        (for-each (lambda (h) (when (and h (uv-handle-open? h)) (uv-close! h)))
                  (list target new))
        (if (poll-cl! (lambda () (settled-client? target new)))
            'finished
            (list 'client-loop-still-alive (uv-loop-live-handles cl-loop))))
      (let ((torn (list (teardown target) (if new (teardown new) 'torn-down))))
        (if (equal? torn '(torn-down torn-down)) 'finished torn))))

;; --- split by a change -------------------------------------------------------------
;; Each run has one right answer:
;;   'refused             not yet made at the expiry: resumed, the verb
;;                        raises the change's refusal (&uv-handle-closed,
;;                        or &uv-wrong-thread after a handoff);
;;   'made-before-change  made by the expiry: resumed, it returns;
;;   'untouched           no expiry: it ran whole and was made.
;; A verb that returns without having been made by the expiry made its call
;; after the change, and one that leaves libuv holding a request after a
;; close or a teardown made it on what the change freed.

(define (split-verdict mode made outcome stale)
  (cond (stale (list 'a-call-after-the-change-reached-libuv outcome))
        ((and (not made) (equal? outcome (refusal-for mode))) 'refused)
        ((and made (eq? outcome 'returned)) 'made-before-change)
        (else (list outcome (if made 'made-before-change 'not-made-before-change)))))

;; split-run : symbol symbol exact-positive-integer -> (values verdict boolean)
;; The run's verdict, and whether an expiry reached it.
(define (split-run verb mode fuel)
  (let* ((before (balance))
         (target (prepare verb))
         (loop (target-loop verb target))
         (new #f)
         (eng (make-engine (lambda () (attempt verb target))))
         (verdict
          (eng fuel
               (lambda (ticks outcome)
                 (cond ((not (eq? outcome 'returned)) (list 'untouched outcome))
                       ((not (uv-loop-alive? loop)) '(untouched not-made))
                       (else 'untouched)))
               (lambda (resume)
                 (let ((made (uv-loop-alive? loop)))
                   (set! new (change! verb mode target))
                   (let* ((outcome (resume 1000000 (lambda (ticks o) o)
                                           (lambda (more) 'still-running)))
                          (stale (stale? verb mode new)))
                     (split-verdict mode made outcome stale)))))))
    (values (checked-verdict verdict (finish! verb target new) before balance)
            (not (untouched? verdict)))))

;; --- dropped ----------------------------------------------------------------------
;; The scheduler drops the engine at the expiry, and the run then closes
;; the client or tears the loop down. Right answers: 'dropped or
;; 'untouched, with nothing left behind and interrupts enabled.

;; drop-run : symbol exact-positive-integer -> (values verdict boolean)
(define (drop-run verb fuel)
  (let* ((before (balance))
         (target (prepare verb))
         (eng (make-engine (lambda () (attempt verb target))))
         (outcome (eng fuel
                       (lambda (ticks o) (if (eq? o 'returned) 'untouched (list 'untouched o)))
                       (lambda (resume) 'dropped))))
    (values (checked-verdict outcome (finish! verb target #f) before balance)
            (eq? outcome 'dropped))))

;; --- the sweeps -------------------------------------------------------------------
(define sweep-fuel-cap 400)

;; A wrong run in a split by a close or a teardown may have handed libuv a
;; freed handle or loop, and the next run's loop could fault on it, so those
;; sweeps stop at their first wrong run. The others run to the end.
(define (split-sweep verb mode)
  (sweep-fuels (lambda (fuel) (split-run verb mode fuel))
               sweep-fuel-cap
               (if (memq mode '(close teardown))
                   (lambda (v) (not (memq v '(refused made-before-change untouched))))
                   (lambda (v) #f))))

(define (drop-sweep verb)
  (sweep-fuels (lambda (fuel) (drop-run verb fuel)) sweep-fuel-cap (lambda (v) #f)))

(define lookups '(uv-getaddrinfo! uv-getnameinfo!))

;; The sweeps that can only fail by name run first, the ones a wrong run
;; could fault in last, after the others' rows are out: a fault ends the
;; process and takes every row not yet emitted with it.
(define reuse-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'reuse)))
       (cons 'uv-tcp-connect! lookups)))
(define handoff-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'handoff)))
       (cons 'uv-tcp-connect! lookups)))
(define drop-sweeps
  (map (lambda (verb) (cons verb (drop-sweep verb)))
       (cons 'uv-tcp-connect! lookups)))

(define (good-split? v) (memq v '(refused made-before-change untouched)))

(report! 'reuse reuse-sweeps)
(test-equal "a request verb resumed after its client or loop was freed and made anew never reaches the new one"
  '()
  (bad-runs good-split? reuse-sweeps))
(test-equal "each reuse sweep caught its verb before its checks and ran it to the end"
  (expected-reach reuse-sweeps 'refused)
  (reach reuse-sweeps))

(report! 'handoff handoff-sweeps)
(test-equal "a request verb whose loop changes hands is refused, or had made its call before"
  '()
  (bad-runs good-split? handoff-sweeps))
(test-equal "each handoff sweep caught its verb before its checks and ran it to the end"
  (expected-reach handoff-sweeps 'refused)
  (reach handoff-sweeps))

(report! 'drop drop-sweeps)
(test-equal "a request verb whose engine is dropped leaves no block, request or registry entry"
  '()
  (bad-runs (lambda (v) (memq v '(dropped untouched))) drop-sweeps))
(test-equal "each drop sweep dropped its verb and ran it to the end"
  (expected-reach drop-sweeps 'dropped)
  (reach drop-sweeps))

(define close-sweeps
  (list (cons 'uv-tcp-connect! (split-sweep 'uv-tcp-connect! 'close))))
(report! 'close close-sweeps)
(test-equal "a connect split by its client's close is refused, or had made its call before the close"
  '()
  (bad-runs good-split? close-sweeps))
(test-equal "the close sweep caught uv-tcp-connect! before its checks and ran it to the end"
  (expected-reach close-sweeps 'refused)
  (reach close-sweeps))

(define teardown-sweeps
  (map (lambda (verb) (cons verb (split-sweep verb 'teardown))) lookups))
(report! 'teardown teardown-sweeps)
(test-equal "a lookup split by its loop's teardown is refused, or had made its call before"
  '()
  (bad-runs good-split? teardown-sweeps))
(test-equal "each teardown sweep caught its lookup before its checks and ran it to the end"
  (expected-reach teardown-sweeps 'refused)
  (reach teardown-sweeps))

;; --- refused inside the step ------------------------------------------------------
;; A refusal the step comes to after its allocation frees the block and
;; leaves nothing registered or counted: an address libuv cannot parse,
;; found once the block is made, and libuv's own refusal of a client that
;; is already connecting (EALREADY), which comes after the request is
;; registered and counted. Each answers the refusal with what the run left.

(define (bad-address-connect)
  (let* ((before (balance))
         (tcp (make-uv-tcp cl-loop))
         (answer (guard (e ((uv-invalid-argument? e)
                            (list 'refused (uv-invalid-argument-who e)
                                  (uv-invalid-argument-reason e)))
                           (#t (list 'raised (describe e))))
                   (uv-tcp-connect! tcp "not-an-ip" sv-port nop)
                   'returned)))
    (checked-verdict answer (finish! 'uv-tcp-connect! tcp #f) before balance)))

(test-equal "a connect to an address libuv cannot parse is refused, its block freed"
  '(refused uv-tcp-connect! bad-address)
  (bad-address-connect))

(define (bad-address-getnameinfo)
  (let* ((before (balance))
         (loop (make-uv-loop))
         (answer (guard (e ((uv-invalid-argument? e)
                            (list 'refused (uv-invalid-argument-who e)
                                  (uv-invalid-argument-reason e)))
                           (#t (list 'raised (describe e))))
                   (uv-getnameinfo! loop "not-an-ip" 80 '(numeric-host) nop)
                   'returned)))
    (checked-verdict answer (finish! 'uv-getnameinfo! loop #f) before balance)))

(test-equal "a getnameinfo of an address libuv cannot parse is refused, its block freed"
  '(refused uv-getnameinfo! bad-address)
  (bad-address-getnameinfo))

(define (second-connect)
  (let* ((before (balance))
         (tcp (make-uv-tcp cl-loop))
         (first (connect-attempt tcp))
         (second (guard (e ((uv-errno-error? e) (list 'refused (uv-errno-error-errno e)))
                           (#t (list 'raised (describe e))))
                   (uv-tcp-connect! tcp "127.0.0.1" sv-port nop)
                   'returned)))
    (checked-verdict (list first second) (finish! 'uv-tcp-connect! tcp #f) before balance)))

(test-equal "a second connect on a connecting client is refused by libuv, leaving nothing behind"
  '(returned (refused EALREADY))
  (second-connect))

;; --- uv-cancel! -------------------------------------------------------------------
;; uv-cancel! reads its request's pointer and hands it to uv_cancel. A
;; scheduler can suspend it in between and run the loop, which completes the
;; request and frees its block, or hand the loop to another thread. Each run
;; starts a lookup on a new loop and cancels it in an engine.
;;
;; Split by the completion: at the expiry the run steps the loop until the
;; lookup has completed and freed its block, then takes that block's address
;; back with a zeroed block of the same size from the binding's allocator,
;; and resumes. A cancel resumed there must answer #f, the request being
;; done, without calling libuv: one that kept the old pointer hands
;; uv_cancel the zeroed block, whose request type is none libuv cancels,
;; and libuv answers EINVAL. glibc's calloc takes no block from the
;; thread's cache, where a free of a small block goes first, so seven
;; same-size blocks freed beforehand fill that cache, and the request's
;; block goes where calloc looks. Memory tools never hand a freed block
;; back, so there the witness lands in no run.
;;
;; Split by a handoff: resumed, the cancel must be refused with
;; &uv-wrong-thread. This oracle has one premise: an expiry never lands
;; after the cancel's step, as the step is its last act but for answering.
;; A collection due inside the step would spend fuel at its end, so each
;; run starts with a collection.

(define lookup-block-size
  (+ (align-16 (uv-req-size (uv-getaddrinfo-req-type))) (sizeof-addrinfo)))

(define (start-lookup loop done)
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! loop "127.0.0.1" #f (list (cons 'flags '(numeric-host)))
                     (lambda (err results) (vector-set! done 0 #t)))))

(define (cancel-attempt req)
  (guard (e (#t (refusal e)))
    (list 'answered (uv-cancel! req))))

;; occupy! : uptr -> (list-of uptr)
;; Same-size blocks from the binding's allocator until one lands at FREED,
;; or 64 of them: every block made, the one at FREED first if one did.
(define (occupy! freed)
  (let next ((made '()) (i 0))
    (let ((b (alloc-block lookup-block-size)))
      (cond ((= b freed) (cons b made))
            ((= i 63) (cons b made))
            (else (next (cons b made) (+ i 1)))))))

(define (fill-cache!)
  (let ((seven (map (lambda (i) (alloc-block lookup-block-size)) '(1 2 3 4 5 6 7))))
    (for-each free-block! seven)))

;; The fuels of the completion sweep's expired runs whose zeroed blocks
;; missed the freed request's address, latest first.
(define missed-landings '())

;; cancel-run : symbol exact-positive-integer -> (values verdict boolean)
;; MODE is 'complete or 'handoff.
(define (cancel-run mode fuel)
  (collect)
  (let* ((before (balance))
         (loop (make-uv-loop))
         (done (vector #f))
         (req (start-lookup loop done)))
    (if (not (uv-dns-request? req))
        (begin (teardown loop) (values (list 'lookup-not-started req) #f))
        (let* ((ptr (req-ptr req))
               (eng (make-engine (lambda () (cancel-attempt req))))
               (verdict
                (eng fuel
                     (lambda (ticks outcome)
                       (if (and (pair? outcome) (eq? (car outcome) 'answered))
                           'untouched
                           (list 'untouched outcome)))
                     (lambda (resume)
                       (if (eq? mode 'handoff)
                           (begin
                             (set-loop-owner-thread! loop other-thread)
                             (let ((outcome (resume 1000000 (lambda (ticks o) o)
                                                    (lambda (more) 'still-running))))
                               (set-loop-owner-thread! loop me)
                               (if (eq? outcome 'wrong-thread)
                                   'refused
                                   (list outcome 'after-the-handoff))))
                           (begin
                             (fill-cache!)
                             (run-until/ticking loop (lambda () (vector-ref done 0)) 4000)
                             (let* ((blocks (occupy! ptr))
                                    (outcome (resume 1000000 (lambda (ticks o) o)
                                                     (lambda (more) 'still-running))))
                               (for-each free-block! blocks)
                               (unless (= (car blocks) ptr)
                                 (set! missed-landings (cons fuel missed-landings)))
                               (cond ((not (vector-ref done 0))
                                      (list 'lookup-never-completed outcome))
                                     ((not (= (car blocks) ptr))
                                      (if (equal? outcome '(answered #f))
                                          'answered-done-no-reuse
                                          (list outcome 'no-reuse)))
                                     ((equal? outcome '(answered #f)) 'answered-done)
                                     (else (list outcome 'after-completion))))))))))
          (values (checked-verdict verdict
                                   (let ((torn (teardown loop)))
                                     (if (eq? torn 'torn-down) 'finished torn))
                                   before balance)
                  (not (untouched? verdict)))))))

(define cancel-complete-sweep
  (sweep-fuels (lambda (fuel) (cancel-run 'complete fuel)) sweep-fuel-cap (lambda (v) #f)))
(define cancel-handoff-sweep
  (sweep-fuels (lambda (fuel) (cancel-run 'handoff fuel)) sweep-fuel-cap (lambda (v) #f)))

(report! 'complete (list (cons 'uv-cancel! cancel-complete-sweep)))
(report! 'handoff (list (cons 'uv-cancel! cancel-handoff-sweep)))

(test-equal "a cancel resumed after its lookup completed answers #f, and never hands libuv the freed block"
  '()
  (bad-runs (lambda (v) (memq v '(answered-done answered-done-no-reuse untouched)))
            (list (cons 'uv-cancel! cancel-complete-sweep))))

;; A run whose zeroed block missed the freed address answers the same, and
;; counts for the reach: the witness row below names it.
(define (landed-or-not run)
  (if (eq? (cadr run) 'answered-done-no-reuse)
      (cons (car run) (cons 'answered-done (cddr run)))
      run))

(test-equal "the completion sweep caught uv-cancel! before its checks and ran it to the end"
  '((uv-cancel! answered-done untouched))
  (reach (list (cons 'uv-cancel! (map landed-or-not cancel-complete-sweep)))))

;; The witness: a zeroed block took the freed request's address in every
;; run the engine expired in. A run where none did could not have shown a
;; stale cancel, so a row that asked for only one landing would let every
;; other run prove nothing. The reach row above holds that the sweep's runs
;; expired at all: only an expired run answers 'answered-done.
(test-equal "the completion sweep's zeroed block took the freed request's address in every expired run"
  '()
  (if under-memory-tool? '() (reverse missed-landings)))

(test-equal "a cancel resumed after its loop changed hands is refused"
  '()
  (bad-runs (lambda (v) (memq v '(refused untouched)))
            (list (cons 'uv-cancel! cancel-handoff-sweep))))

(test-equal "the handoff sweep caught uv-cancel! before its checks and ran it to the end"
  '((uv-cancel! refused untouched))
  (reach (list (cons 'uv-cancel! cancel-handoff-sweep))))

(uv-close! sv)
(teardown sv-loop)
(teardown cl-loop)

(test-end "request-steps")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
