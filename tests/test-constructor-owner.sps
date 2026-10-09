#!r6rs
;;; SRFI-64 suite for the owner check on every verb that makes something on
;;; a loop: the handle constructors (make-uv-timer, -tcp, -pipe, -signal,
;;; -async), uv-accept!, uv-spawn!, uv-getaddrinfo! and uv-getnameinfo!, and
;;; on uv-cancel!, which a lookup's completion races (#79; ADR-0019's #79
;;; amendment).
;;;
;;; A loop belongs to one thread: the one that made it, then whichever
;;; thread most recently entered uv-run on it (docs/api.md). Until #79 only
;;; make-uv-async checked that. The others called libuv's init from any
;;; thread, and an init links the handle into the loop's handle queue, which
;;; the loop's own thread unlinks from as it finishes closes: a second
;;; thread making timers on a loop the first was running corrupted that
;;; queue in 11 of 13 runs, and the teardown still answered ok. The DNS
;;; verbs count their request in the loop with a plain increment, which the
;;; loop's thread decrements, so the loop could exit early or never. The
;;; registry lock (#70) guards the binding's table, not libuv's lists.
;;;
;;; So each verb here is called from a thread that does not own the loop,
;;; and must be refused with &uv-wrong-thread, naming itself, the owner and
;;; the caller, leaving nothing registered, counted, allocated or open. And
;;; each is called from the owner, the creator first, then a thread the loop
;;; was handed to by running it, and must make what it makes. A check that
;;; refused every call would fail the second; no check at all, the first.
;;;
;;; An engine can also hand a loop over in the middle of a constructor or a
;;; spawn: those sweeps are in tests/test-constructors.sps and
;;; tests/test-process.sps.
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
        (only (libuv process) uv-spawn!)
        (only (libuv dns) uv-getaddrinfo! uv-getnameinfo! uv-cancel! uv-dns-request?)
        (libuv private conditions)
        (only (libuv private handles) registry-count)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (uv-evidence) describe print-actual-on-failure!)
        ;; The thread forms run a verb on another thread and wait for it,
        ;; with a cap; directory-list counts this process's descriptors.
        (only (chezscheme) fork-thread get-thread-id make-mutex make-condition
              with-mutex condition-wait condition-signal make-time
              directory-list))

(define runner (test-runner-simple))
(test-runner-current runner)

;; Each row returns its evidence when it fails, so print that too.
(print-actual-on-failure! runner)

(test-begin "constructor-owner")

(define me (get-thread-id))
(define counts-at-start (live-counts))
(define registry-at-start (registry-count))

(define (nop . args) #f)

;; libuv opens a pipe of its own with the first loop a process makes, and
;; keeps it for the life of the process. One loop, made and torn down before
;; any row counts descriptors, keeps that out of every row's count.
(uv-loop-teardown! (make-uv-loop))

;; --- another thread -------------------------------------------------------------

;; Every wait on the other thread gives up after this many seconds, so a
;; broken build fails a row where it would otherwise hang the suite.
(define thread-wait-cap 10)

;; on-other-thread : (-> object) -> (or (list thread-id object) list)
;; Runs THUNK on a new thread and answers that thread's id with what THUNK
;; answered, or what it raised, or that no answer came within the cap.
;; answered? tells the two apart: a row whose thread never answered must not
;; tear its loop down, as the thread may still be using it.
(define (on-other-thread thunk)
  (let ((m (make-mutex)) (c (make-condition)) (answer #f))
    (fork-thread
     (lambda ()
       (let ((outcome (guard (e (#t (list 'raised (describe e))))
                        (thunk))))
         (with-mutex m
           (set! answer (list (get-thread-id) outcome))
           (condition-signal c)))))
    (with-mutex m
      (let wait ((waits 0))
        (cond (answer answer)
              ((= waits thread-wait-cap) (list 'no-answer-within-seconds thread-wait-cap))
              (else (condition-wait c m (make-time 'time-duration 0 1))
                    (wait (+ waits 1))))))))

(define (answered? seen) (number? (car seen)))

;; --- what a row must leave as it found it ---------------------------------------

;; This process's open descriptors, or 0 where /dev/fd cannot be listed.
(define (fd-count)
  (guard (e (#t 0))
    (length (directory-list "/dev/fd"))))

;; The registry, every debug counter (blocks included), and descriptors.
(define (balance) (list (registry-count) (live-counts) (fd-count)))

;; residue : list -> list
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
                  (cadr before) (cadr after)))
     (if (= (caddr before) (caddr after))
         '()
         (list (list 'fds (- (caddr after) (caddr before))))))))

;; --- the verbs ------------------------------------------------------------------
;; A verb prepares a fresh loop, answering a context its call needs, or #f
;; if the fixture could not be made, and calls the verb on it. Its context
;; is a cell holding 'pending until a spawn's child exits or a lookup
;; completes; made? says whether the call made what it should, or for
;; uv-cancel!, answered as it should.
(define-record-type verb (fields name prepare call made?))

(define (pending-cell loop) (vector 'pending))
(define (settle! cell) (vector-set! cell 0 'settled))
(define (settled? ctx) (not (and (vector? ctx) (eq? (vector-ref ctx 0) 'pending))))

(define (constructor name make made?)
  (make-verb name (lambda (loop) 'no-context) (lambda (loop ctx) (make loop)) made?))

;; The server has a connection waiting to be accepted, from a client on the
;; same loop, so a call that went unrefused would accept it. Steps span a
;; loopback handshake, which a loaded machine can stretch past a hundred.
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

;; Each call answers what it made, or a guarded raise of anything but the
;; refusal as evidence, so a verb that raises otherwise fails its row with
;; what it raised.
(define (spawn-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'spawn-raised (describe e))))
    (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
               (lambda (status signal) (settle! cell)))))

(define (getaddrinfo-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'getaddrinfo-raised (describe e))))
    (uv-getaddrinfo! loop "localhost" #f (lambda (err results) (settle! cell)))))

(define (getnameinfo-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'getnameinfo-raised (describe e))))
    (uv-getnameinfo! loop "127.0.0.1" 80 (lambda (err host service) (settle! cell)))))

;; uv-cancel!'s context is the cell with a lookup made on the loop and run
;; to its completion. The resolver opens and closes descriptors of its own
;; on libuv's worker thread while a lookup runs, which a row counting
;; descriptors meanwhile would see; so the lookup is over before any row
;; counts. The owner check comes before uv-cancel! reads the request, so a
;; completed request is refused off the owner's thread all the same, and
;; answers #f on it.
(define (lookup-prepare loop)
  (let ((cell (vector 'pending #f)))
    (vector-set! cell 1 (uv-getaddrinfo! loop "localhost" #f
                                         (lambda (err results) (settle! cell))))
    (run-until/ticking loop (lambda () (settled? cell)) 20000)
    (and (settled? cell) cell)))

(define (cancel-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'cancel-raised (describe e))))
    (uv-cancel! (vector-ref cell 1))))

(define verbs
  (list (constructor 'make-uv-timer make-uv-timer uv-timer?)
        (constructor 'make-uv-tcp make-uv-tcp uv-tcp?)
        (constructor 'make-uv-pipe make-uv-pipe uv-pipe?)
        (constructor 'make-uv-signal make-uv-signal uv-signal?)
        (constructor 'make-uv-async (lambda (loop) (make-uv-async loop nop)) uv-async?)
        (make-verb 'uv-accept! accept-prepare
                   (lambda (loop server) (uv-accept! server)) uv-tcp?)
        (make-verb 'uv-spawn! pending-cell spawn-call uv-process?)
        (make-verb 'uv-getaddrinfo! pending-cell getaddrinfo-call uv-dns-request?)
        (make-verb 'uv-getnameinfo! pending-cell getnameinfo-call uv-dns-request?)
        (make-verb 'uv-cancel! lookup-prepare cancel-call boolean?)))

;; The verbs that take arguments, called with arguments they refuse. From
;; the wrong thread, each must say so before it reads them, as a handle verb
;; does before it reads its handle's state (require-open-handle). Never made.
(define (never-made? x) #f)

(define (bad-spawn-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'spawn-raised (describe e))))
    (uv-spawn! loop "/bin/sh" '() #f)))

(define (bad-getaddrinfo-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'getaddrinfo-raised (describe e))))
    (uv-getaddrinfo! loop 'not-a-node #f nop)))

(define (bad-getnameinfo-call loop cell)
  (guard (e ((uv-wrong-thread? e) (raise e))
            (#t (list 'getnameinfo-raised (describe e))))
    (uv-getnameinfo! loop 'not-an-address 80 nop)))

(define bad-argument-verbs
  (list (make-verb 'uv-spawn! pending-cell bad-spawn-call never-made?)
        (make-verb 'uv-getaddrinfo! pending-cell bad-getaddrinfo-call never-made?)
        (make-verb 'uv-getnameinfo! pending-cell bad-getnameinfo-call never-made?)))

;; attempt : verb uv-loop object -> list
;; Calls V, answering (made), (wrong-thread who expected actual), (returned
;; x) for anything else it answered, or (raised ...) for anything else it
;; raised. It raises nothing, so a row always reaches its loop's teardown.
(define (attempt v loop ctx)
  (guard (e ((uv-wrong-thread? e)
             (list 'wrong-thread (uv-wrong-thread-who e)
                   (uv-wrong-thread-expected e) (uv-wrong-thread-actual e)))
            (#t (list 'raised (describe e))))
    (let ((x ((verb-call v) loop ctx)))
      (if ((verb-made? v) x) '(made) (list 'returned x)))))

;; finish! : uv-loop object -> (or 'torn-down list)
;; Takes LOOP back to this thread by running it, waits for a child or a
;; lookup a call started, and tears the loop down. A call that was refused
;; started nothing, and leaves nothing active on the loop: its cell is
;; never settled, and a wait on it would tick to its cap, about 24 s a row
;; (2026-10-09). So the wait is made only while libuv holds something.
(define (finish! loop ctx)
  (guard (e (#t (list 'finish-raised (describe e))))
    (uv-run loop 'nowait)
    (when (uv-loop-alive? loop)
      (run-until/ticking loop (lambda () (settled? ctx)) 20000))
    (uv-loop-teardown! loop)
    'torn-down))

;; --- refused off the owner's thread ---------------------------------------------
;; The loop is this thread's, which made it. Another thread calls the verb
;; and must be refused, naming the verb, this thread as the owner and itself
;; as the caller, before anything is made.

;; refusal-run : verb -> (or 'refused-leaving-nothing list)
(define (refusal-run v)
  (let* ((loop (make-uv-loop))
         (ctx ((verb-prepare v) loop)))
    (if (not ctx)
        (list 'prepare-failed (finish! loop ctx))
        (let* ((before (balance))
               (seen (on-other-thread (lambda () (attempt v loop ctx))))
               (left (residue before))
               (torn (if (answered? seen) (finish! loop ctx) 'left-to-its-thread)))
          (if (and (answered? seen)
                   (equal? (cadr seen) (list 'wrong-thread (verb-name v) me (car seen)))
                   (null? left)
                   (eq? torn 'torn-down))
              'refused-leaving-nothing
              (list 'seen seen 'left left 'finish torn))))))

(for-each
 (lambda (v)
   (test-equal (string-append (symbol->string (verb-name v))
                              " from a thread that does not own the loop is refused, leaving nothing")
     'refused-leaving-nothing
     (refusal-run v)))
 verbs)

(for-each
 (lambda (v)
   (test-equal (string-append (symbol->string (verb-name v))
                              " from a thread that does not own the loop is refused before its arguments are read")
     'refused-leaving-nothing
     (refusal-run v)))
 bad-argument-verbs)

;; --- made by the owner ----------------------------------------------------------
;; The thread that made the loop owns it until another runs it.

;; owner-run : verb -> (or 'made list)
(define (owner-run v)
  (let* ((loop (make-uv-loop))
         (ctx ((verb-prepare v) loop)))
    (if (not ctx)
        (list 'prepare-failed (finish! loop ctx))
        (let* ((seen (attempt v loop ctx))
               (torn (finish! loop ctx)))
          (if (and (equal? seen '(made)) (eq? torn 'torn-down))
              'made
              (list 'seen seen 'finish torn))))))

(for-each
 (lambda (v)
   (test-equal (string-append (symbol->string (verb-name v))
                              " on the thread that made the loop makes it")
     'made
     (owner-run v)))
 verbs)

;; --- a loop handed to another thread --------------------------------------------
;; The loop is made and prepared here, and handed to another thread, which
;; runs it once and then calls the verb: that thread owns it now, and makes
;; what the verb makes. Then this thread, its maker, calls the verb and is
;; refused, naming the other thread as the owner.

;; handoff-run : verb -> (or 'made-there-refused-here list)
(define (handoff-run v)
  (let* ((loop (make-uv-loop))
         (ctx ((verb-prepare v) loop)))
    (if (not ctx)
        (list 'prepare-failed (finish! loop ctx))
        (let* ((there (on-other-thread
                       (lambda ()
                         (uv-run loop 'nowait)
                         (attempt v loop ctx))))
               (here (if (answered? there) (attempt v loop ctx) 'not-tried))
               (torn (if (answered? there) (finish! loop ctx) 'left-to-its-thread)))
          (if (and (answered? there)
                   (equal? (cadr there) '(made))
                   (equal? here (list 'wrong-thread (verb-name v) (car there) me))
                   (eq? torn 'torn-down))
              'made-there-refused-here
              (list 'there there 'here here 'finish torn))))))

(for-each
 (lambda (v)
   (test-equal (string-append (symbol->string (verb-name v))
                              " is made by the thread a loop was handed to, and refused to its maker")
     'made-there-refused-here
     (handoff-run v)))
 verbs)

;; --- the whole suite --------------------------------------------------------------

(test-equal "the registry is back where the suite began"
  registry-at-start (registry-count))

(test-equal "every counter is back where the suite began"
  counts-at-start (live-counts))

(define fails (test-runner-fail-count runner))
(test-end "constructor-owner")
(exit (if (zero? fails) 0 1))
