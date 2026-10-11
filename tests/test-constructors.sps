#!r6rs
;;; SRFI-64 suite for the constructors split or dropped by an engine: the
;;; handle constructors (make-uv-timer, -tcp, -pipe, -signal, -async),
;;; uv-accept!, which makes the client it accepts into, make-uv-loop and
;;; call-with-uv-loop.
;;;
;;; NOT pure: it drives real loops. Never add this to the Makefile's
;;; PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv tcp)
        (libuv pipe)
        (libuv signal)
        (libuv async)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts init-mutex
              uv-timer-init uv-loop-init count-timer-new!)
        ;; The refused-step rows answer an errno by its symbol.
        (only (libuv private constants) errno-symbol->value)
        (uv-testing)
        (only (uv-evidence) describe)
        (uv-sweep)
        ;; make-engine and engine-block drive the sweeps; the thread forms
        ;; probe the init lock from another thread; directory-list counts
        ;; this process's open descriptors.
        (only (chezscheme) make-engine engine-block
              fork-thread make-mutex make-condition with-mutex
              mutex-acquire mutex-release condition-wait condition-signal
              directory-list foreign-procedure))

(define runner (test-runner-simple))
(test-runner-current runner)
(define registry-count-at-start (registry-count))

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

(test-begin "constructors")

(define (nop . args) #f)

;; --- what a run must leave as it found it ------------------------------------
;; A green-thread scheduler on the loop thread runs each task in an engine,
;; and a task's fuel can run out anywhere inside a constructor. Unless the
;; constructor is one interrupt-free step (try-construct-handle,
;; try-construct-loop), two things can then go wrong:
;; - Split: another task tears the loop down, freeing the uv_loop_t, and the
;;   constructor resumes past its open check and initialises its handle on
;;   the freed loop. Or the teardown finds the handle initialised but not
;;   yet registered, cannot close it, and fails with EBUSY for good.
;; - Dropped, as a timeout drops a task: whatever the constructor had made
;;   and not yet registered is lost. A block, or a handle linked into the
;;   loop that no teardown can close: uv_loop_close fails with EBUSY for
;;   good, and for an async, which keeps the loop alive, the teardown's
;;   drain never returns. A dropped make-uv-loop loses the loop and its
;;   descriptors. And a drop in the exit of the init gate's with-mutex
;;   leaves its lock held for good, so another thread's next constructor
;;   waits on it forever, unless the lock is taken and released with
;;   interrupts disabled.
;;
;; Each sweep runs a constructor in an engine at rising fuel. Fuel 1 expires
;; before the constructor's own checks, and the sweep stops at the first run
;; no expiry reaches, so between them every point in it is visited.

;; libuv opens a pipe of its own with the first loop a process makes, and
;; keeps it open for the life of the process. One loop, made and torn down
;; before any run counts descriptors, keeps that out of every run's count.
(uv-loop-teardown! (make-uv-loop))

;; lock-free? : -> boolean
;; Whether another thread can take the init gate's lock at the call. The
;; lock is recursive, so the thread that holds it cannot see it held.
(define (lock-free?)
  (let ((m (make-mutex)) (c (make-condition)) (answer 'pending))
    (fork-thread
     (lambda ()
       (let ((got (mutex-acquire init-mutex #f)))
         (when got (mutex-release init-mutex))
         (with-mutex m (set! answer got) (condition-signal c)))))
    (with-mutex m
      (let wait () (when (eq? answer 'pending) (condition-wait c m) (wait))))
    answer))

;; A run that finds the lock held releases it, from this thread, which holds
;; it, so the next run starts clean and its own verdict is its own.
(define (release-lock!)
  (let release ()
    (unless (lock-free?)
      (mutex-release init-mutex)
      (release))))

;; This process's open descriptors, or 0 where /dev/fd cannot be listed.
(define (fd-count)
  (guard (e (#t 0))
    (length (directory-list "/dev/fd"))))

;; The registry, every debug counter (blocks included), and descriptors,
;; as (name . count).
(define (balance)
  (cons (cons 'registry (registry-count))
        (append (live-counts) (list (cons 'fds (fd-count))))))

;; finish! : uv-loop -> (or 'torn-down 'would-hang list)
;; Tears LOOP down as uv-loop-teardown! does, without letting it hang the
;; suite: it closes the registered handles, steps the loop with 'nowait
;; until their closes are done, and stops short if the loop is still alive,
;; for then only an unregistered active handle can be holding it, and
;; teardown's 'default drain would block on it for good.
(define (finish! loop)
  (guard (e (#t (list 'teardown-raised (describe e))))
    (for-each (lambda (h) (when (uv-handle-open? h) (uv-close! h)))
              (uv-loop-live-handles loop))
    (let poll ((i 0))
      (unless (or (null? (uv-loop-live-handles loop)) (= i 64))
        (uv-run loop 'nowait)
        (poll (+ i 1))))
    (if (uv-loop-alive? loop)
        'would-hang
        (begin (uv-loop-teardown! loop) 'torn-down))))

;; lock-finished : boolean -> (or 'finished 'init-lock-held)
;; How a run that found the init lock FREE, or held, left it: a held lock
;; is released, so the next run starts clean.
(define (lock-finished free)
  (if free 'finished (begin (release-lock!) 'init-lock-held)))

;; --- the constructors ---------------------------------------------------------
;; A variant prepares a fresh loop, answering what its start needs, or #f
;; if the fixture could not be made, and starts the constructor on it.
(define-record-type variant (fields name prepare start))

(define (constructor name make)
  (make-variant name (lambda (loop) #t) (lambda (loop ctx) (make loop))))

;; The server has a connection waiting to be accepted, from a client on the
;; same loop. Steps span a loopback handshake, which a loaded machine can
;; stretch past a hundred.
(define handshake-steps 4000)

(define (accept-prepare loop)
  (let* ((server (make-uv-tcp loop))
         (port (bind-loopback! server))
         (client (make-uv-tcp loop))
         (pending #f))
    (uv-listen! server 8 (lambda (err) (set! pending (if err 'failed #t))))
    (connect-loopback! client port nop)
    (run-until/ticking loop (lambda () pending) handshake-steps)
    (and (eq? pending #t) server)))

(define variants
  (list (constructor 'make-uv-timer make-uv-timer)
        (constructor 'make-uv-tcp make-uv-tcp)
        (constructor 'make-uv-pipe make-uv-pipe)
        (constructor 'make-uv-signal make-uv-signal)
        (constructor 'make-uv-async (lambda (loop) (make-uv-async loop nop)))
        (make-variant 'uv-accept! accept-prepare
                      (lambda (loop server) (uv-accept! server)))))

;; --- split by a teardown --------------------------------------------------------
;; At the expiry the scheduler tears the loop down, and the constructor
;; resumes. Whether the constructor had made its handle by then is read
;; from the registry: a handle the loop's teardown can close is registered.
;; Each run has one right answer:
;;   'refused               not yet made: the teardown succeeds, and resumed,
;;                          the constructor raises &uv-handle-closed;
;;   'made-before-teardown  made and registered: the teardown closes it, and
;;                          resumed, the constructor returns it, closed;
;;   'untouched             no expiry: it ran whole.
;; A constructor that returns an open handle on the torn-down loop made it
;; on the freed uv_loop_t.

;; split-run : variant exact-positive-integer -> (values verdict boolean)
;; The run's verdict, and whether an expiry reached it.
(define (split-run v fuel)
  (let* ((before (balance))
         (loop (make-uv-loop))
         (ctx ((variant-prepare v) loop)))
    (if (not ctx)
        (begin (finish! loop) (values '(prepare-failed) #f))
        (let* ((fixtures (length (uv-loop-live-handles loop)))
               (expired #f)
               (eng (make-engine
                     (lambda ()
                       (guard (e ((uv-handle-closed? e) 'refused)
                                 (#t (list 'raised (describe e))))
                         (list 'returned ((variant-start v) loop ctx))))))
               (verdict
                (eng fuel
                     (lambda (ticks o)
                       (if (and (pair? o) (eq? (car o) 'returned))
                           'untouched
                           (list 'untouched o)))
                     (lambda (resume)
                       (set! expired #t)
                       (let* ((made (> (length (uv-loop-live-handles loop)) fixtures))
                              (torn (finish! loop))
                              (o (resume 1000000 (lambda (ticks o) o)
                                         (lambda (more) 'still-running))))
                         (cond ((not (eq? torn 'torn-down))
                                (list 'teardown torn o))
                               ((and (eq? o 'refused) (not made)) 'refused)
                               ((and (pair? o) (eq? (car o) 'returned) made
                                     (eq? (uv-handle-state (cadr o)) 'closed))
                                'made-before-teardown)
                               ((and (pair? o) (eq? (car o) 'returned))
                                (list 'returned (uv-handle-state (cadr o))
                                      (if made 'made-before 'made-after-teardown)))
                               (else (list o (if made 'made-before 'not-made)))))))))
          (when (uv-loop-open? loop) (finish! loop))
          (values (checked-verdict verdict 'finished before balance) expired)))))

;; --- uv-accept! split by its server's close ---------------------------------------
;; A teardown closes the loop, which a constructor's own check refuses.
;; uv-accept! also reads its server: here the scheduler closes only the
;; server at the expiry, and the accept resumes, while the close is pending
;; ('closing) or once the loop has run it and freed the server ('freed):
;;   'refused            not yet made: &uv-handle-closed;
;;   'made-before-close  the client was made, and accepted, before the close;
;;   'untouched          no expiry.
(define (server-close-run mode fuel)
  (let* ((before (balance))
         (loop (make-uv-loop))
         (server (accept-prepare loop)))
    (if (not server)
        (begin (finish! loop) (values '(prepare-failed) #f))
        (let* ((fixtures (length (uv-loop-live-handles loop)))
               (expired #f)
               (eng (make-engine
                     (lambda ()
                       (guard (e ((uv-handle-closed? e) 'refused)
                                 (#t (list 'raised (describe e))))
                         (list 'returned (uv-accept! server))))))
               (verdict
                (eng fuel
                     (lambda (ticks o)
                       (if (and (pair? o) (eq? (car o) 'returned)) 'untouched (list 'untouched o)))
                     (lambda (resume)
                       (set! expired #t)
                       (let ((made (> (length (uv-loop-live-handles loop)) fixtures)))
                         (uv-close! server)
                         (when (eq? mode 'freed)
                           (let poll ((i 0))
                             (unless (or (eq? (uv-handle-state server) 'closed) (= i 64))
                               (uv-run loop 'nowait)
                               (poll (+ i 1)))))
                         (let ((o (resume 1000000 (lambda (ticks o) o)
                                          (lambda (more) 'still-running))))
                           (cond ((and (eq? o 'refused) (not made)) 'refused)
                                 ((and (pair? o) (eq? (car o) 'returned) made)
                                  'made-before-close)
                                 (else (list o (if made 'made-before 'not-made))))))))))
          (let ((torn (finish! loop)))
            (values (checked-verdict
                     (if (eq? torn 'torn-down) verdict (list verdict 'teardown torn))
                     'finished before balance)
                    expired))))))

;; --- a loop that changes hands -------------------------------------------------
;; Every constructor is loop-thread-only, and checks the owner on entry and
;; again in its step. Here the scheduler hands the loop to another thread
;; at the expiry, as uv-run on that thread would, and the constructor
;; resumes on this one:
;;   'refused              not yet made: &uv-wrong-thread;
;;   'made-before-handoff  made and registered while this thread owned it;
;;   'untouched            no expiry.
;; A constructor that resumes past its entry check and makes its handle
;; anyway has run libuv's init on a loop another thread may be running.
(define (handoff-run v fuel)
  (let* ((before (balance))
         (loop (make-uv-loop))
         (ctx ((variant-prepare v) loop)))
    (if (not ctx)
        (begin (finish! loop) (values '(prepare-failed) #f))
        (let* ((fixtures (length (uv-loop-live-handles loop)))
               (expired #f)
               (eng (make-engine
                     (lambda ()
                       (guard (e ((uv-wrong-thread? e) 'refused)
                                 (#t (list 'raised (describe e))))
                         (list 'returned ((variant-start v) loop ctx))))))
               (verdict
                (eng fuel
                     (lambda (ticks o)
                       (if (and (pair? o) (eq? (car o) 'returned)) 'untouched (list 'untouched o)))
                     (lambda (resume)
                       (set! expired #t)
                       (let ((made (> (length (uv-loop-live-handles loop)) fixtures)))
                         (set-loop-owner-thread! loop other-thread)
                         (let ((o (resume 1000000 (lambda (ticks o) o)
                                          (lambda (more) 'still-running))))
                           (set-loop-owner-thread! loop me)
                           (cond ((and (eq? o 'refused) (not made)) 'refused)
                                 ((and (pair? o) (eq? (car o) 'returned) made)
                                  'made-before-handoff)
                                 (else (list (if (and (pair? o) (eq? (car o) 'returned)) 'returned o)
                                             (if made 'made-before 'made-after-handoff))))))))))
          (finish! loop)
          (values (checked-verdict verdict 'finished before balance) expired)))))

;; --- dropped ----------------------------------------------------------------------
;; The scheduler drops the engine at the expiry, and the loop is torn down
;; after. Right answers: 'dropped or 'untouched, with the teardown done,
;; nothing left behind, interrupts enabled, and the init lock free.

;; drop-run : variant exact-positive-integer -> (values verdict boolean)
(define (drop-run v fuel)
  (let* ((before (balance))
         (loop (make-uv-loop))
         (ctx ((variant-prepare v) loop)))
    (if (not ctx)
        (begin (finish! loop) (values '(prepare-failed) #f))
        (let* ((expired #f)
               (eng (make-engine
                     (lambda ()
                       (guard (e (#t (list 'raised (describe e))))
                         ((variant-start v) loop ctx)
                         'returned))))
               (outcome (eng fuel
                             (lambda (ticks o)
                               (if (eq? o 'returned) 'untouched (list 'untouched o)))
                             (lambda (resume) (set! expired #t) 'dropped)))
               (lock (lock-free?))
               (torn (finish! loop)))
          (values (checked-verdict
                   (if (eq? torn 'torn-down) outcome (list outcome 'teardown torn))
                   (lock-finished lock) before balance)
                  expired)))))

;; A dropped make-uv-loop has no loop to tear down. The loop it made, if it
;; reached the engine's thunk, is torn down here.
(define (loop-drop-run fuel)
  (let* ((before (balance))
         (made #f)
         (expired #f)
         (eng (make-engine
               (lambda ()
                 (guard (e (#t (list 'raised (describe e))))
                   (set! made (make-uv-loop))
                   'returned))))
         (outcome (eng fuel
                       (lambda (ticks o)
                         (if (eq? o 'returned) 'untouched (list 'untouched o)))
                       (lambda (resume) (set! expired #t) 'dropped)))
         (lock (lock-free?))
         (torn (if made (finish! made) 'torn-down)))
    (values (checked-verdict (if (eq? torn 'torn-down) outcome (list outcome 'teardown torn))
                             (lock-finished lock) before balance)
            expired)))

;; call-with-uv-loop tears its loop down however its body is left, an
;; engine's expiry included. The body here blocks its engine as soon as it
;; is entered, and the sweep stops at the first run that reached it: past
;; that point the body's own expiry does the teardown. Right answers:
;; 'dropped before the body, or 'reached-body, with nothing left behind.
(define (cwl-drop-run fuel)
  (let* ((before (balance))
         (entered #f)
         (expired #f)
         (eng (make-engine
               (lambda ()
                 (guard (e (#t (list 'raised (describe e))))
                   (call-with-uv-loop
                    (lambda (loop) (set! entered loop) (engine-block) 'body))
                   'returned))))
         (outcome (eng fuel
                       (lambda (ticks o) (list 'completed o))
                       (lambda (resume)
                         (set! expired #t)
                         (if entered 'reached-body 'dropped))))
         (lock (lock-free?))
         (torn (if (and entered (uv-loop-open? entered))
                   (list 'left-open (finish! entered))
                   'torn-down)))
    (values (checked-verdict (if (eq? torn 'torn-down) outcome (list outcome torn))
                             (lock-finished lock) before balance)
            expired)))

;; --- the sweeps -------------------------------------------------------------------
(define sweep-fuel-cap 400)

;; A run whose fixture could not be made: the next would wait the same
;; handshake out again, at every fuel up to the cap.
(define (unprepared? verdict) (equal? verdict '(prepare-failed)))

;; A call-with-uv-loop drop run whose body was reached: past it, the body's
;; own expiry does the teardown, so a later run would show nothing new.
(define (past-the-body? verdict) (eq? verdict 'reached-body))

;; sweep : (exact-positive-integer -> (values verdict boolean))
;;         -> (list-of (list fuel verdict expired?))
;; From fuel 1 to the first run no expiry reaches, whatever its verdict, to
;; the first run whose fixture could not be made or that reached a body,
;; or to the cap. The driver ends the sweep at a raise between runs,
;; keeping the runs before it (tests/uv-sweep.sls).
(define (sweep run)
  (sweep-fuels run sweep-fuel-cap
               (lambda (verdict) (or (unprepared? verdict) (past-the-body? verdict)))))

(define (named-sweeps run vs)
  (let next ((vs vs) (acc '()))
    (if (null? vs)
        (reverse acc)
        (next (cdr vs)
              (cons (cons (variant-name (car vs))
                          (sweep (lambda (fuel) (run (car vs) fuel))))
                    acc)))))

(define split-sweeps (named-sweeps split-run variants))
(define server-close-sweeps
  (list (cons 'closing (sweep (lambda (fuel) (server-close-run 'closing fuel))))
        (cons 'freed (sweep (lambda (fuel) (server-close-run 'freed fuel))))))
(define handoff-sweeps (named-sweeps handoff-run variants))
(define drop-sweeps
  (append (named-sweeps drop-run variants)
          (list (cons 'make-uv-loop (sweep loop-drop-run))
                (cons 'call-with-uv-loop (sweep cwl-drop-run)))))

(for-each report!
          '(split server-close handoff drop)
          (list split-sweeps server-close-sweeps handoff-sweeps drop-sweeps))

(test-equal "a constructor split by a teardown is refused, or had made its handle before it"
  '()
  (bad-runs (lambda (v) (memq v '(refused made-before-teardown untouched))) split-sweeps))

(test-equal "each split sweep caught its constructor before its checks and ran it to the end"
  (expected-reach split-sweeps 'refused)
  (reach split-sweeps))

(test-equal "an accept split by its server's close is refused, or had accepted before it"
  '()
  (bad-runs (lambda (v) (memq v '(refused made-before-close untouched))) server-close-sweeps))

(test-equal "each server-close sweep caught uv-accept! before its checks and ran it to the end"
  '((closing refused untouched) (freed refused untouched))
  (reach server-close-sweeps))

(test-equal "a constructor whose loop changes hands is refused, or had made its handle before"
  '()
  (bad-runs (lambda (v) (memq v '(refused made-before-handoff untouched))) handoff-sweeps))

(test-equal "each handoff sweep caught its constructor before its checks and ran it to the end"
  (expected-reach handoff-sweeps 'refused)
  (reach handoff-sweeps))

(test-equal "a constructor whose engine is dropped leaves no block, handle, descriptor or held lock"
  '()
  (bad-runs (lambda (v) (memq v '(dropped untouched reached-body))) drop-sweeps))

(test-equal "each drop sweep dropped its constructor at fuel 1 and ran it to the end"
  (map (lambda (s)
         (list (car s) 'dropped
               (if (eq? (car s) 'call-with-uv-loop) 'reached-body 'untouched)))
       drop-sweeps)
  (reach drop-sweeps))

;; --- a stream's descriptor ----------------------------------------------------------
;; libuv's alloc callback, the shim's, trusts a stream's handle data to point
;; at its descriptor (tests/test-source-rules.sps). The step that makes a
;; stream points it there, before any read can start. The loop above has
;; loaded libuv.
(define handle-data (foreign-procedure "uv_handle_get_data" (uptr) uptr))

(test-equal "a stream's data points at its descriptor from construction: tcp, pipe, accepted"
  '(at-its-descriptor at-its-descriptor at-its-descriptor)
  (let* ((loop (make-uv-loop))
         (server (accept-prepare loop))
         (streams (list (make-uv-tcp loop) (make-uv-pipe loop)
                        (if server (uv-accept! server) 'no-connection)))
         (answers (map (lambda (s)
                         (if (uv-stream-record? s)
                             (let ((data (handle-data (handle-ptr s))))
                               (if (= data (stream-descriptor s))
                                   'at-its-descriptor
                                   (list 'data data 'descriptor (stream-descriptor s))))
                             s))
                       streams)))
    (finish! loop)
    answers))

;; --- a refused step leaves nothing behind --------------------------------------
;; libuv's inits do not fail on an open loop, and a fresh block is never
;; registered already, so the steps' refusals are driven through the steps
;; themselves: an init that answers an errno, a record whose block another
;; entry already holds, and a size no block is made for. Each must leave the
;; registry, every counter, the blocks and the loop as it found them.
(define emfile (errno-symbol->value 'EMFILE))
(define (failing-init . args) emfile)
(define (timer-maker loop) (lambda (ptr) (%make-uv-timer-record ptr loop)))

;; refused-step : (uv-loop -> object) -> list
;; What a step on a fresh loop answered, what it left, and the teardown.
(define (refused-step step)
  (let* ((loop (make-uv-loop))
         (before (balance))
         (made (step loop))
         (left (residue before (balance))))
    (list made left (finish! loop))))

(test-equal "a handle whose init fails is refused with its errno, leaving nothing behind"
  (list emfile '() 'torn-down)
  (refused-step
   (lambda (loop)
     (try-construct-handle loop 64 failing-init (timer-maker loop) count-timer-new!))))

(test-equal "a handle whose block is already registered is refused, its block freed"
  (list 'pointer-already-registered '() 'torn-down)
  (refused-step
   (lambda (loop)
     (let* ((squatted #f)
            (made (try-construct-handle
                   loop 64 uv-timer-init
                   (lambda (ptr)
                     (registry-add! ptr 'timer loop 'squatter)
                     (set! squatted ptr)
                     ((timer-maker loop) ptr))
                   count-timer-new!)))
       (when squatted (registry-remove! squatted))
       made))))

(test-equal "a handle no block is made for is refused with no-memory, leaving nothing behind"
  (list 'no-memory '() 'torn-down)
  (refused-step
   (lambda (loop)
     (try-construct-handle loop 0 uv-timer-init (timer-maker loop) count-timer-new!))))

(test-equal "a loop whose init fails is refused with its errno, leaving nothing behind"
  (list emfile '() 'not-kept)
  (let* ((before (balance))
         (kept 'not-kept)
         (made (try-construct-loop failing-init (lambda (l) (set! kept l)))))
    (list made (residue before (balance)) kept)))

(test-equal "a loop's step hands KEEP! the loop it answers"
  'kept
  (let* ((kept #f)
         (made (try-construct-loop uv-loop-init (lambda (l) (set! kept l))))
         (answer (if (and (uv-loop? made) (eq? kept made)) 'kept (list made kept))))
    (when (uv-loop? made) (uv-loop-teardown! made))
    answer))

(test-equal "registry back to baseline" registry-count-at-start (registry-count))
(test-equal "counters all zero" '()
  (filter (lambda (kv) (not (zero? (cdr kv)))) (live-counts)))

;; --- a loop left open with no native block ---------------------------------------
;; No path in the library leaves a loop, or a server, open with its pointer
;; zeroed, but a step must not fault if one ever does: the fault would be
;; raised with interrupts disabled. Each step checks the pointer and answers
;; a status, and the refusal is the one the checked accessors raise outside
;; a step. The private setters force the state. This row comes last, because
;; a fault here would leave interrupts disabled for any row after it.
(test-equal "a constructor on a loop left open with no native block is refused, not made"
  '((make-uv-timer null-loop-pointer) (make-uv-tcp null-loop-pointer)
    (make-uv-pipe null-loop-pointer) (make-uv-signal null-loop-pointer)
    (make-uv-async null-loop-pointer) (uv-accept! null-handle-pointer)
    interrupts-enabled)
  (let* ((l (make-uv-loop))
         (server-loop (make-uv-loop))
         (server (make-uv-tcp server-loop)))
    (uv-loop-teardown! l)               ; frees the loop, zeroes its pointer
    (set-loop-state! l 'open)
    (uv-close! server)
    (uv-run server-loop 'nowait)        ; the close callback frees the server
    (set-handle-state! server 'open)
    (let ((refusals
           (map (lambda (call)
                  (guard (e ((uv-invalid-argument? e)
                             (list (uv-invalid-argument-who e)
                                   (uv-invalid-argument-reason e)))
                            (#t (list 'raised (describe e))))
                    (call)
                    'made))
                (list (lambda () (make-uv-timer l))
                      (lambda () (make-uv-tcp l))
                      (lambda () (make-uv-pipe l))
                      (lambda () (make-uv-signal l))
                      (lambda () (make-uv-async l nop))
                      (lambda () (uv-accept! server))))))
      (set-loop-state! l 'closed)
      (set-handle-state! server 'closed)
      (uv-loop-teardown! server-loop)
      (append refusals
              (list (if (interrupts-enabled?)
                        'interrupts-enabled
                        'interrupts-left-disabled))))))

(test-end "constructors")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
