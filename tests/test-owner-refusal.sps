#!r6rs
;;; SRFI-64 suite for what &uv-wrong-thread names: a verb refused because
;;; another thread owns its loop names the owner its check compared
;;; against, as `expected`, and this thread, as `actual`.
;;;
;;; Every verb that checks its loop's owner checks it in its step, and
;;; raises once the step is over. A step that answered a bare 'wrong-thread
;;; would leave the refusal to read the loop's owner again to build the
;;; condition, after the step, with interrupts enabled. A loop handed on in
;;; between, by another thread's uv-run or by a scheduler on this one, would
;;; be named instead of the owner the step saw. Handed back to this thread,
;;; the condition would say `expected` = `actual`: refused for being on the
;;; wrong thread, it would name the right one. Built that way, an engine
;;; alone does that to fifteen verbs: uv-accept!, the eight scratch verbs,
;;; uv-tcp-connect!, both signal starts, uv-write!, uv-write*! and
;;; uv-shutdown!.
;;;
;;; So an owner check answers an owner-mismatch holding the owner it
;;; compared against and the caller, and the refusal is built from that
;;; alone. The first rows hold the checks to what they answer; the
;;; builder's rows are with step-refusal's, in tests/test-loop.sps, and
;;; rule 9 of tests/test-source-rules.sps keeps every other read of the
;;; owner out of a refusal.
;;;
;;; The hand-back sweep runs each verb in an engine at fuel 1, 2, 3, ...
;;; At the first expiry the scheduler hands the loop to another thread, as
;;; uv-run there would; it resumes the verb with one tick, and at the
;;; second expiry hands the loop back to this thread. An expiry that comes
;;; due inside a step waits for the step's end, so one tick puts the hand-
;;; back at the earliest point an expiry can come after the step. A run
;;; whose verb was refused must name the other thread and this one. A verb
;;; may also have made its call, before the first handoff or after the
;;; hand-back; the handoff sweeps in the suites that own each verb hold
;;; that it never makes one in between.
;;;
;;; The verbs that check the owner, and where their other sweeps live:
;;; - the handle constructors and uv-accept!: tests/test-constructors.sps;
;;; - uv-update-time!, the scratch, TCP, timer and signal verbs:
;;;   tests/test-handle-steps.sps;
;;; - the stream verbs: tests/test-stream.sps;
;;; - uv-tcp-connect!, the lookups and uv-cancel!:
;;;   tests/test-request-steps.sps;
;;; - uv-spawn!: tests/test-process.sps; uv-process-kill! and
;;;   uv-process-pid: tests/test-process-steps.sps.
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
        (libuv stream)
        (libuv dns)
        (libuv process)
        (libuv private handles)
        (libuv private conditions)
        (only (uv-testing) bind-loopback! connect-loopback! run-until/ticking)
        (only (uv-evidence) describe)
        (uv-sweep)
        ;; make-engine drives the sweeps; collect starts each run with no
        ;; collection due, which would otherwise be taken where a step ends
        ;; and spend fuel there.
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

(test-begin "owner-refusal")

(define (nop . args) #f)

;; --- the owner checks -------------------------------------------------------------
;; Each check that finds another thread owning the loop answers what it
;; found, and the refusal is built from that alone: no second read of the
;; owner can name one the check did not see.

(define (found x)
  (if (owner-mismatch? x)
      (list (owner-mismatch-owner x) (owner-mismatch-caller x))
      (list 'not-a-mismatch x)))

(test-equal "an owner check on a loop another thread owns answers that owner and this thread"
  (list (list other-thread me) (list other-thread me) (list other-thread me)
        (list 'wrong-thread 'uv-test-verb! other-thread me))
  (let* ((l (make-uv-loop))
         (t (make-uv-timer l)))
    (set-loop-owner-thread! l other-thread)
    (let ((answers
           (list (found (loop-owner-mismatch l))
                 (found (owned-loop-ptr l))
                 (found (owned-handle-ptr t))
                 (guard (e ((uv-wrong-thread? e)
                            (list 'wrong-thread (uv-wrong-thread-who e)
                                  (uv-wrong-thread-expected e) (uv-wrong-thread-actual e)))
                           (#t (list 'raised (describe e))))
                   (require-loop-thread l 'uv-test-verb!)
                   'not-refused))))
      (set-loop-owner-thread! l me)
      (uv-loop-teardown! l)
      answers)))

(test-equal "an owner check on this thread's loop answers no mismatch, and the pointer"
  '(no-mismatch loop-pointer handle-pointer not-refused)
  (let* ((l (make-uv-loop))
         (t (make-uv-timer l))
         (answers
          (list (or (loop-owner-mismatch l) 'no-mismatch)
                (if (eqv? (owned-loop-ptr l) (loop-ptr l)) 'loop-pointer (owned-loop-ptr l))
                (if (eqv? (owned-handle-ptr t) (handle-ptr t))
                    'handle-pointer
                    (owned-handle-ptr t))
                (guard (e (#t (list 'raised (describe e))))
                  (require-loop-thread l 'uv-test-verb!)
                  'not-refused))))
    (uv-loop-teardown! l)
    answers))

;; A step tests its pointer with refused?, which must know an owner
;; check's refusal from a pointer as well as a symbol's.
(test-equal "refused? answers for an owner check's refusal and a symbol, not for a pointer"
  '(refused refused pointer)
  (map (lambda (x) (if (refused? x) 'refused 'pointer))
       (list (make-owner-mismatch other-thread me) 'not-open 4096)))

;; --- the verbs --------------------------------------------------------------------
;; uv-tcp-keepalive! has a form to enable and a form to disable, and each is
;; swept: uv-tcp-keepalive!/off names the second. Rule 9 of
;; tests/test-source-rules.sps holds this list to every verb (libuv)
;; exports that reaches an owner check.
(define verbs
  '(make-uv-timer make-uv-tcp make-uv-pipe make-uv-signal make-uv-async uv-accept!
    uv-update-time!
    uv-tcp-bind! uv-tcp-getsockname-port uv-tcp-sockname-address uv-tcp-peer-address
    uv-send-buffer-size uv-send-buffer-size! uv-recv-buffer-size uv-recv-buffer-size!
    uv-listen! uv-tcp-nodelay! uv-tcp-keepalive! uv-tcp-keepalive!/off
    uv-timer-start! uv-timer-stop! uv-timer-again! uv-timer-repeat uv-timer-set-repeat!
    uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!
    uv-write! uv-write*! uv-shutdown! uv-read-start! uv-read-stop!
    uv-stream-write-queue-size
    uv-tcp-connect! uv-getaddrinfo! uv-getnameinfo! uv-cancel!
    uv-spawn! uv-process-kill! uv-process-pid))

;; The name each verb's refusal carries as `who`.
(define (who-of verb)
  (if (eq? verb 'uv-tcp-keepalive!/off) 'uv-tcp-keepalive! verb))

;; --- the fixtures -----------------------------------------------------------------
;; Each run has a loop of its own, and prepare makes on it what the verb
;; needs. Steps span a loopback handshake, which a loaded machine can
;; stretch past a hundred.
(define handshake-steps 4000)

;; Every child this suite starts calls this when it exits, and finish!
;; waits until as many have exited as were started, so none outlives its
;; loop as a zombie.
(define started 0)
(define exited 0)
(define (child-exited status signal) (set! exited (+ exited 1)))

;; A fixture is the verb's target and the pipes finish! closes, a child's
;; stdin among them.
(define-record-type fixture (fields target pipes))

(define (bound loop)
  (let ((t (make-uv-tcp loop)))
    (bind-loopback! t)
    t))

;; A server on LOOP with a connection waiting to be accepted, or #f.
(define (pending-server loop)
  (let* ((server (make-uv-tcp loop))
         (port (bind-loopback! server))
         (client (make-uv-tcp loop))
         (pending #f))
    (uv-listen! server 8 (lambda (err) (set! pending (if err 'failed #t))))
    (connect-loopback! client port nop)
    (run-until/ticking loop (lambda () pending) handshake-steps)
    (and (eq? pending #t) server)))

;; A client on LOOP and the port of a server of LOOP listening for it, as
;; (client . port): the connect's arguments, made before it, so that only
;; the connect can be refused.
(define (connect-target loop)
  (let* ((server (make-uv-tcp loop))
         (port (bind-loopback! server)))
    (uv-listen! server 8 nop)
    (cons (make-uv-tcp loop) port)))

;; A client on LOOP connected to a server of LOOP that accepted it, or #f.
(define (connected-client loop)
  (let* ((server (make-uv-tcp loop))
         (port (bind-loopback! server))
         (client (make-uv-tcp loop))
         (accepted #f)
         (connected #f))
    (uv-listen! server 8
                (lambda (err)
                  (unless err
                    (set! accepted (guard (e (#t 'accept-raised))
                                     (uv-accept! server)
                                     #t)))))
    (connect-loopback! client port
                       (lambda (err) (set! connected (if err 'failed #t))))
    (run-until/ticking loop (lambda () (and accepted connected)) handshake-steps)
    (and (eq? accepted #t) (eq? connected #t) client)))

;; A child of LOOP that runs until its stdin closes.
(define (cat-child loop)
  (let* ((pipe (make-uv-pipe loop))
         (proc (uv-spawn! loop "/bin/cat" '("cat")
                          (list (cons 'stdio (list (list 'pipe pipe 'to-child))))
                          child-exited)))
    (set! started (+ started 1))
    (make-fixture proc (list pipe))))

(define (timer-started loop)
  (let ((t (make-uv-timer loop)))
    (uv-timer-start! t nop 3600000 3600000)
    t))

(define (signal-started loop)
  (let ((s (make-uv-signal loop)))
    (uv-signal-start! s 'sigusr2 nop)
    s))

;; prepare : symbol uv-loop -> (or fixture list)
;; VERB's fixture on LOOP, or why it could not be made.
(define (prepare verb loop)
  (define (on target)
    (if target (make-fixture target '()) (list 'no-fixture verb)))
  (cond ((memq verb '(make-uv-timer make-uv-tcp make-uv-pipe make-uv-signal make-uv-async
                      uv-update-time! uv-getaddrinfo! uv-getnameinfo! uv-spawn!))
         (on loop))
        ((eq? verb 'uv-accept!) (on (pending-server loop)))
        ((eq? verb 'uv-tcp-connect!) (on (connect-target loop)))
        ((eq? verb 'uv-tcp-bind!) (on (make-uv-tcp loop)))
        ((memq verb '(uv-tcp-peer-address uv-write! uv-write*! uv-shutdown!
                      uv-read-start! uv-read-stop! uv-stream-write-queue-size))
         (on (connected-client loop)))
        ((memq verb '(uv-timer-start! uv-timer-repeat uv-timer-set-repeat!))
         (on (make-uv-timer loop)))
        ((memq verb '(uv-timer-stop! uv-timer-again!)) (on (timer-started loop)))
        ((memq verb '(uv-signal-start! uv-signal-start-oneshot!)) (on (make-uv-signal loop)))
        ((eq? verb 'uv-signal-stop!) (on (signal-started loop)))
        ((eq? verb 'uv-cancel!)
         (on (uv-getaddrinfo! loop "127.0.0.1" "80" nop)))
        ((memq verb '(uv-process-kill! uv-process-pid)) (cat-child loop))
        (else (on (bound loop)))))

;; By quoted name: rule 4 of tests/test-seed-gates.sps would read a case
;; clause's datum list as a call of the verb. T is the fixture's target.
(define (call-verb verb t)
  (cond ((eq? verb 'make-uv-timer) (make-uv-timer t))
        ((eq? verb 'make-uv-tcp) (make-uv-tcp t))
        ((eq? verb 'make-uv-pipe) (make-uv-pipe t))
        ((eq? verb 'make-uv-signal) (make-uv-signal t))
        ((eq? verb 'make-uv-async) (make-uv-async t nop))
        ((eq? verb 'uv-accept!) (uv-accept! t))
        ((eq? verb 'uv-update-time!) (uv-update-time! t))
        ((eq? verb 'uv-tcp-bind!) (uv-tcp-bind! t "127.0.0.1" 0))
        ((eq? verb 'uv-tcp-getsockname-port) (uv-tcp-getsockname-port t))
        ((eq? verb 'uv-tcp-sockname-address) (uv-tcp-sockname-address t))
        ((eq? verb 'uv-tcp-peer-address) (uv-tcp-peer-address t))
        ((eq? verb 'uv-send-buffer-size) (uv-send-buffer-size t))
        ((eq? verb 'uv-send-buffer-size!) (uv-send-buffer-size! t 65536))
        ((eq? verb 'uv-recv-buffer-size) (uv-recv-buffer-size t))
        ((eq? verb 'uv-recv-buffer-size!) (uv-recv-buffer-size! t 65536))
        ((eq? verb 'uv-listen!) (uv-listen! t 16 nop))
        ((eq? verb 'uv-tcp-nodelay!) (uv-tcp-nodelay! t #t))
        ((eq? verb 'uv-tcp-keepalive!) (uv-tcp-keepalive! t #t 60))
        ((eq? verb 'uv-tcp-keepalive!/off) (uv-tcp-keepalive! t #f))
        ((eq? verb 'uv-timer-start!) (uv-timer-start! t nop 3600000 0))
        ((eq? verb 'uv-timer-stop!) (uv-timer-stop! t))
        ((eq? verb 'uv-timer-again!) (uv-timer-again! t))
        ((eq? verb 'uv-timer-repeat) (uv-timer-repeat t))
        ((eq? verb 'uv-timer-set-repeat!) (uv-timer-set-repeat! t 5000))
        ((eq? verb 'uv-signal-start!) (uv-signal-start! t 'sigusr2 nop))
        ((eq? verb 'uv-signal-start-oneshot!) (uv-signal-start-oneshot! t 'sigusr2 nop))
        ((eq? verb 'uv-signal-stop!) (uv-signal-stop! t))
        ((eq? verb 'uv-write!) (uv-write! t (make-bytevector 16 7) nop))
        ((eq? verb 'uv-write*!) (uv-write*! t (list (make-bytevector 16 7)) nop))
        ((eq? verb 'uv-shutdown!) (uv-shutdown! t nop))
        ((eq? verb 'uv-read-start!) (uv-read-start! t nop nop nop))
        ((eq? verb 'uv-read-stop!) (uv-read-stop! t))
        ((eq? verb 'uv-stream-write-queue-size) (uv-stream-write-queue-size t))
        ((eq? verb 'uv-tcp-connect!) (uv-tcp-connect! (car t) "127.0.0.1" (cdr t) nop))
        ((eq? verb 'uv-getaddrinfo!) (uv-getaddrinfo! t "127.0.0.1" "80" nop))
        ((eq? verb 'uv-getnameinfo!)
         (uv-getnameinfo! t "127.0.0.1" 80 '(numeric-host numeric-serv) nop))
        ((eq? verb 'uv-cancel!) (uv-cancel! t))
        ((eq? verb 'uv-spawn!)
         (let ((proc (uv-spawn! t "/bin/sh" '("sh" "-c" "exit 7") '() child-exited)))
           (set! started (+ started 1))
           proc))
        ((eq? verb 'uv-process-kill!) (uv-process-kill! t 0))
        (else (uv-process-pid t))))

;; attempt : symbol object -> verdict
;;   'returned                             the verb returned;
;;   (wrong-thread who expected actual)    it raised &uv-wrong-thread;
;;   (raised message)                      it raised something else.
(define (attempt verb target)
  (guard (e ((uv-wrong-thread? e)
             (list 'wrong-thread (uv-wrong-thread-who e)
                   (uv-wrong-thread-expected e) (uv-wrong-thread-actual e)))
            (#t (list 'raised (describe e))))
    (call-verb verb target)
    'returned))

;; finish! : uv-loop fixture -> object
;; Gives LOOP back to this thread, closes the fixture's pipes, waits for
;; every child started to exit, and tears LOOP down: 'finished, or what
;; stood in the way.
(define (finish! loop fx)
  (set-loop-owner-thread! loop me)
  (guard (e (#t (list 'finish-raised (describe e))))
    (when (fixture? fx)
      (for-each (lambda (p) (when (uv-handle-open? p) (uv-close! p))) (fixture-pipes fx)))
    (let ((waited (if (= exited started)
                      'satisfied
                      (run-until/ticking loop (lambda () (= exited started))
                                         handshake-steps))))
      (uv-loop-teardown! loop)
      (if (eq? waited 'satisfied)
          'finished
          (list 'children-still-running (- started exited))))))

;; --- the hand-back sweep ----------------------------------------------------------
;; Each run's verdict:
;;   'untouched   no expiry: the verb ran whole;
;;   'returned    the verb made its call, before the handoff or after the
;;                hand-back;
;;   'refused     &uv-wrong-thread naming the verb, the other thread as
;;                `expected` and this one as `actual`.
;; Anything else is wrong: a refusal naming any other owner or caller, any
;; other raise, a fixture not made, a verb still running at its cap, or a
;; finish that could not tidy the run.

;; verdict : symbol object -> verdict
(define (verdict verb outcome)
  (cond ((eq? outcome 'returned) 'returned)
        ((equal? outcome (list 'wrong-thread (who-of verb) other-thread me)) 'refused)
        (else outcome)))

;; handback-run : symbol exact-positive-integer -> (values verdict boolean)
;; The run's verdict, and whether an expiry reached it.
(define (handback-run verb fuel)
  (collect)
  (let* ((loop (make-uv-loop))
         (fx (guard (e (#t (list 'prepare-raised (describe e))))
               (prepare verb loop))))
    (if (not (fixture? fx))
        (values (list 'not-prepared fx (finish! loop #f)) #f)
        (let* ((expired #f)
               (eng (make-engine (lambda () (attempt verb (fixture-target fx)))))
               (outcome
                (eng fuel
                     (lambda (ticks o) o)
                     (lambda (resume)
                       (set! expired #t)
                       (set-loop-owner-thread! loop other-thread)
                       (resume 1
                               (lambda (ticks o) o)
                               (lambda (resume)
                                 (set-loop-owner-thread! loop me)
                                 (resume 1000000 (lambda (ticks o) o)
                                         (lambda (more) 'still-running)))))))
               (finished (finish! loop fx))
               (v (cond ((not expired)
                         (if (eq? outcome 'returned) 'untouched (list 'untouched outcome)))
                        (else (verdict verb outcome)))))
          (values (if (eq? finished 'finished) v (list v 'finish finished))
                  expired)))))

(define sweep-fuel-cap 400)

;; handback-sweep : symbol -> (list-of (list fuel verdict expired?))
;; From fuel 1 to the first run no expiry reaches, or the cap. A run whose
;; fixture could not be made answers no expiry, so it ends the sweep: the
;; next would fail the same.
(define (handback-sweep verb)
  (sweep-fuels (lambda (fuel) (handback-run verb fuel)) sweep-fuel-cap (lambda (v) #f)))

(define (good? v) (and (memq v '(refused returned untouched)) #t))

(define handback-sweeps
  (map (lambda (verb) (cons verb (handback-sweep verb))) verbs))

(report! 'handback handback-sweeps)

(test-equal "a verb refused after its loop was handed on and back names the owner its check saw, and this thread"
  '()
  (bad-runs good? handback-sweeps))

;; The row above says nothing unless each sweep's verb was refused in some
;; run, and the sweep ran it to the end. The first verdict is no witness:
;; in a sweep's first runs the hand-back comes one tick after the handoff,
;; and the loop is back with this thread by the time the verb's checks read
;; its owner, so the verb makes its call and returns.
(test-equal "each hand-back sweep had its verb refused and ran it to the end"
  (map (lambda (verb) (list verb #t 'untouched)) verbs)
  (reach-any 'refused handback-sweeps))

(test-equal "every child the sweeps started has exited"
  0
  (- started exited))

(test-end "owner-refusal")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
