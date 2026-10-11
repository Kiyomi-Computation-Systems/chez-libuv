#!r6rs
;;; SRFI-64 suite for the async send fence. uv-async-send! may run on
;;; any thread, while uv-close! runs on the loop thread, and the close frees
;;; the handle's native block at the end of that uv-run iteration. A send
;;; that has checked the handle is open but not yet made its native call can
;;; therefore reach the block after it is freed. The fence rules that out:
;;; each send either completes before the close begins, or is refused with
;;; &uv-handle-closed without touching the handle.
;;;
;;; The fence is taken and released only with interrupts disabled, so no
;;; engine is ever suspended, and no collection ever stops a thread, while it
;;; holds the fence. The engine sweeps check that from another thread at
;;; every point where a send or a close can be suspended. Chez mutexes are
;;; recursive, so only a thread that does not hold the fence can see it held.
;;;
;;; It runs on the default gate and the memory gate.
;;; The rows fork threads, but no verdict on a correct build depends on
;;; timing: each row waits for an event. Where a row also has a time bound,
;;; the bound only caps how long a broken build gets to show itself.
(import (rnrs)
        (srfi :64)
        (libuv)
        (only (libuv private handles) async-fence set-handle-state!)
        ;; make-engine drives the sweeps; the thread primitives drive the
        ;; probes and the rows that hold the fence.
        (only (chezscheme) make-engine
              fork-thread make-mutex make-condition with-mutex
              mutex-acquire mutex-release condition-wait condition-broadcast
              collect-trip-bytes make-time current-time add-duration)
        (only (uv-evidence) describe))

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

(test-begin "async-fence")

;; --- plumbing for the rows that need another thread -----------------------
;; A row's threads share one board: a mutex, a condition, and the posts they
;; make under that mutex. Every wait is for a predicate over the posts, and
;; every thread posts its outcome when it ends, raised or not. So a waiter
;; can always wait for "the flag, or the thread that would raise it ended",
;; and no row hangs on a flag a failed thread never raised.

(define-record-type board
  (fields (immutable lock) (immutable changed) (mutable posts))
  (protocol (lambda (new) (lambda () (new (make-mutex) (make-condition) '())))))

(define (post! b key value)
  (with-mutex (board-lock b)
    (board-posts-set! b (cons (cons key value) (board-posts b)))
    (condition-broadcast (board-changed b))))

;; posted : board symbol -> (or pair #f)
(define (posted b key) (assq key (board-posts b)))

;; await : board (-> object) [exact-positive-integer] -> object
;; Waits until (READY?) is true, and answers it. Given MS, waits at most MS
;; milliseconds, and then answers (READY?) whatever it is.
(define (await b ready? . ms)
  (let ((deadline (and (pair? ms)
                       (add-duration (current-time 'time-utc)
                                     (make-time 'time-duration
                                                (* (mod (car ms) 1000) 1000000)
                                                (div (car ms) 1000))))))
    (with-mutex (board-lock b)
      (let wait ()
        (cond ((ready?))
              ((not deadline)
               (condition-wait (board-changed b) (board-lock b))
               (wait))
              ((condition-wait (board-changed b) (board-lock b) deadline)
               (wait))
              (else (ready?)))))))

;; spawn! : board symbol (-> object) -> unspecified
;; Runs THUNK on a new thread and posts its value under KEY, or
;; (raised message) if it raised. An uncaught raise would end only that
;; thread, and nothing would post.
(define (spawn! b key thunk)
  (fork-thread
   (lambda ()
     (post! b key (guard (e (#t (list 'raised (describe e)))) (thunk))))))

;; fence-seen-from-another-thread : uv-async -> (or 'free 'held list)
;; The probe thread tries the fence without blocking and answers what it
;; found. It is one thread for the whole suite, not a new one per probe.
;; Chez treats a thread whose id matches a mutex's recorded owner as its
;; owner, and a new thread can be given the id of one that has exited
;; (measured: 19 or 20 of 20 new threads took, without blocking, a mutex a
;; dead thread still held). A fresh probe could then report a fence left
;; held by a dead thread as free. The probe thread outlives every thread that
;; could hold the fence, so none of them can share its id.
(define probe-lock (make-mutex))
(define probe-changed (make-condition))
(define probe-request #f)            ; the fence to try, while a probe is pending
(define probe-answer #f)             ; its answer, once the probe thread has one

(define (serve-probes)
  (let serve ()
    (let ((fence (with-mutex probe-lock
                   (let wait ()
                     (or probe-request
                         (begin (condition-wait probe-changed probe-lock)
                                (wait)))))))
      (let ((answer (guard (e (#t (list 'raised (describe e))))
                      (if (mutex-acquire fence #f)
                          (begin (mutex-release fence) 'free)
                          'held))))
        (with-mutex probe-lock
          (set! probe-request #f)
          (set! probe-answer answer)
          (condition-broadcast probe-changed))
        (serve)))))

(fork-thread serve-probes)

(define (fence-seen-from-another-thread a)
  (with-mutex probe-lock
    (set! probe-answer #f)
    (set! probe-request (async-fence a))
    (condition-broadcast probe-changed)
    (let wait ()
      (or probe-answer
          (begin (condition-wait probe-changed probe-lock) (wait))))))

;; while-holding-fence : uv-async (-> object) -> object
;; Runs THUNK on this thread while it holds A's send fence, as only a test
;; does: the library holds it inside interrupt-free steps alone. A thread
;; that waits for the fence waits with interrupts disabled, so it stays
;; active, and a collection this thread started while holding the fence
;; would wait for that thread for good. So collections triggered by
;; allocation are put off meanwhile.
(define (while-holding-fence a thunk)
  (let ((saved (collect-trip-bytes)))
    (dynamic-wind
     (lambda () (collect-trip-bytes (expt 2 40)))
     (lambda () (with-mutex (async-fence a) (thunk)))
     (lambda () (collect-trip-bytes saved)))))

;; Every row below that answers 'free from the probe is empty unless the
;; probe can answer 'held. So first, the probe sees a fence this thread
;; holds.
(test-equal "another thread sees the fence held while this thread holds it"
  '(held free)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (while-held (with-mutex (async-fence a)
                       (fence-seen-from-another-thread a)))
         (after (fence-seen-from-another-thread a)))
    (uv-close! a)
    (uv-loop-teardown! loop)
    (list while-held after)))

;; --- the engine sweep: a close at every point inside a send ---------------
;; An engine runs uv-async-send! for FUEL ticks. Where the fuel runs out, the
;; send is suspended somewhere inside the verb, and the sweep closes the
;; handle and frees its block before resuming it. That is what a green-thread
;; scheduler on the loop thread does when one engine sends while another
;; closes. Stepping FUEL up from 1 suspends the send at every point in it in
;; turn, so the race is deterministic here, with no second thread.
;;
;; At each suspension another thread first tries the fence: a send is never
;; suspended holding it, or an engine dropped there would keep it for good.
;;
;; Then the sweep polls the loop to learn whether the send's native call has
;; already run: if it has, its wake is pending and on-wake fires. So each
;; suspended row has exactly one right answer:
;;   'refused            the send had not yet decided; resumed after the
;;                       close, it must see the handle closing and raise
;;                       &uv-handle-closed;
;;   'sent-before-close  its native call ran before the suspension, so its
;;                       wake landed before the close.
;; A send that returns normally although no wake landed before the close
;; made its native call after the close, on the freed block. On Linux that
;; is otherwise silent: the stale call returns normally. On macOS it raises
;; "invalid memory reference"; under Valgrind it is an invalid read.
;;
;; Rows whose fuel outlasts the verb finish before any close: 'finished,
;; which also requires their wake to land, the check the oracle above relies
;; on to tell the two apart.

(define sweep-max-fuel 200)
(define wake-polls 8)          ; 'nowait polls allowed for a pending wake

;; poll-for-wake! : uv-loop (-> boolean) -> unspecified
;; 'nowait, never 'once: an open async keeps the loop alive, so 'once with
;; no wake pending would block for good.
(define (poll-for-wake! loop woke?)
  (let step ((i 0))
    (unless (or (woke?) (= i wake-polls))
      (uv-run loop 'nowait)
      (step (+ i 1)))))

;; send-then-close : exact-positive-integer -> (list verdict fence)
;; VERDICT is a sentinel symbol when the row held, and otherwise the
;; evidence. FENCE is what another thread saw at the suspension.
(define (send-then-close fuel)
  (let* ((loop (make-uv-loop))
         (woke #f)
         (a (make-uv-async loop (lambda (h) (set! woke #t))))
         (send (make-engine
                (lambda ()
                  (guard (c ((uv-handle-closed? c) 'refused)
                            (#t (describe c)))
                    (uv-async-send! a)
                    'sent)))))
    (send fuel
          (lambda (ticks outcome)
            (poll-for-wake! loop (lambda () woke))
            (let ((woke-at-all woke))
              (uv-close! a)
              (uv-loop-teardown! loop)
              (list (if (and (eq? outcome 'sent) woke-at-all)
                        'finished
                        (list 'finished outcome (if woke-at-all 'woke 'no-wake)))
                    'not-suspended)))
          (lambda (suspended)
            (let ((fence (fence-seen-from-another-thread a)))
              (poll-for-wake! loop (lambda () woke))
              (let ((woke-before-close woke))
                (uv-close! a)
                (uv-run loop 'nowait)     ; the close callback frees the block
                (let ((outcome (suspended 1000000
                                          (lambda (ticks v) v)
                                          (lambda (more) 'still-running))))
                  (uv-loop-teardown! loop)
                  (list (cond ((and (eq? outcome 'refused) (not woke-before-close))
                               'refused)
                              ((and (eq? outcome 'sent) woke-before-close)
                               'sent-before-close)
                              (else
                               (list 'resumed outcome
                                     (if woke-before-close
                                         'woke-before-close
                                         'no-wake-before-close))))
                        fence))))))))

;; sweep-rows : (exact-positive-integer -> list) exact-positive-integer
;;              -> (list-of (cons fuel list))
;; One row per fuel. A raise between rows would abort the suite, so the
;; whole sweep is caught and its evidence handed to the rows.
(define (sweep-rows row max-fuel)
  (guard (e (#t (list (list 'sweep-raised (describe e)))))
    (let run ((fuel 1) (acc '()))
      (if (> fuel max-fuel)
          (reverse acc)
          (run (+ fuel 1) (cons (cons fuel (row fuel)) acc))))))

;; row-verdict, row-fence : sweep row -> object
(define (row-verdict row) (and (pair? (cdr row)) (cadr row)))
(define (row-fence row) (and (pair? (cdr row)) (pair? (cddr row)) (caddr row)))

;; rows-where : (object -> boolean) (row -> object) list -> list
(define (rows-where bad? field rows)
  (filter (lambda (row) (bad? (field row))) rows))

(define send-sweep (sweep-rows send-then-close sweep-max-fuel))

(test-equal "a send suspended anywhere in uv-async-send! sent before the close or is refused after it"
  '() (rows-where (lambda (v) (not (memq v '(refused sent-before-close finished))))
                  row-verdict send-sweep))

(test-equal "no send is suspended by an engine while it holds the fence"
  '() (rows-where (lambda (f) (not (memq f '(free not-suspended))))
                  row-fence send-sweep))

;; The precondition the rows above depend on: the sweep caught the send
;; before it decided, and its fuel outlasted the whole verb, so every point
;; in between was visited. Without this, a sweep that never got inside the
;; send would pass the rows above. In the fenced shape nothing in the verb
;; can be suspended after its step: an engine timer that expires inside it
;; is taken only once the verb has returned. A send fenced by with-mutex,
;; even one wrapped around with-interrupts-disabled, can be suspended just
;; after its native call, in with-mutex's exit, still holding the fence:
;; the row above catches that.
(test-equal "the send sweep caught the send before it decided and ran it to the end"
  '(refused finished)
  (list (if (exists (lambda (row) (eq? (row-verdict row) 'refused)) send-sweep)
            'refused
            'never-refused)
        (let ((last-row (list-ref send-sweep (- (length send-sweep) 1))))
          (if (eq? (row-verdict last-row) 'finished) 'finished last-row))))

;; --- the engine sweep: a close suspended at every point --------------------
;; The same sweep over uv-close! of an async: at each point where the close
;; can be suspended, another thread tries the fence. Scheme's closing state
;; and libuv's are checked against each other in test-timer.sps's close
;; sweep, for this kind and a timer. As with the send, nothing in the fenced
;; close can be suspended after its step; a close fenced by with-mutex,
;; even one wrapped around with-interrupts-disabled, can be, and holds the
;; fence there.

(define close-sweep-max-fuel 80)

;; close-suspended : exact-positive-integer -> (list verdict fence)
;; VERDICT is the handle's state at the suspension ('open: the close had not
;; begun; 'closing: it had), 'finished, or evidence.
(define (close-suspended fuel)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (close (make-engine
                 (lambda ()
                   (guard (c (#t (describe c)))
                     (uv-close! a)
                     'closed)))))
    (close fuel
           (lambda (ticks v)
             (uv-loop-teardown! loop)
             (list (if (eq? v 'closed) 'finished (list 'finished v))
                   'not-suspended))
           (lambda (suspended)
             (let* ((fence (fence-seen-from-another-thread a))
                    (state (uv-handle-state a))
                    (v (suspended 1000000 (lambda (ticks v) v)
                                  (lambda (more) 'still-running))))
               (uv-loop-teardown! loop)
               (list (if (eq? v 'closed) state (list 'resumed v)) fence))))))

(define close-sweep (sweep-rows close-suspended close-sweep-max-fuel))

(test-equal "no close is suspended by an engine while it holds the fence"
  '() (rows-where (lambda (f) (not (memq f '(free not-suspended))))
                  row-fence close-sweep))

(test-equal "the close sweep caught the close before it began and ran it to the end"
  '(open finished)
  (list (if (exists (lambda (row) (eq? (row-verdict row) 'open)) close-sweep)
            'open
            'never-before)
        (let ((last-row (list-ref close-sweep (- (length close-sweep) 1))))
          (if (eq? (row-verdict last-row) 'finished) 'finished last-row))))

;; --- the closer waits for a send inside the fence --------------------------
;; The sweeps run on one thread, so they cannot tell whether uv-close! takes
;; the fence: on the thread that holds the fence, a close would take it
;; anyway. Here the main thread holds the fence, as a sender does between
;; its open check and its native call, while another thread -- the loop's
;; owner -- calls uv-close!. The close must wait for the release, so the
;; holder sees the handle open for as long as it holds the fence.

(define hold-ms 20)     ; how long a holder gives a verb that ignores the fence

(test-equal "uv-close! waits while another thread holds the async's send fence"
  '(open torn-down)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (b (make-board))
         (seen
          (while-holding-fence a
           (lambda ()
             (spawn! b 'closer
                     (lambda ()
                       (uv-run loop 'nowait)    ; this thread takes the loop
                       (post! b 'closing #t)
                       (uv-close! a)
                       (post! b 'close-returned #t)
                       (uv-loop-teardown! loop)
                       'torn-down))
             (await b (lambda () (or (posted b 'closing) (posted b 'closer))))
             (await b (lambda () (or (posted b 'close-returned) (posted b 'closer)))
                    hold-ms)
             (uv-handle-state a)))))
    (list seen (cdr (await b (lambda () (posted b 'closer)))))))

;; --- a sender waits for a send or close inside the fence -------------------
;; The mirror of the row above: the main thread holds the fence while a real
;; sender on another thread calls uv-async-send!. The send must not return
;; until the release. A send that skipped the fence would pass every sweep
;; (they run on one thread) and still reach a block freed by a close on
;; another thread.

(test-equal "uv-async-send! waits while another thread holds the async's send fence"
  '(waiting sent)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (b (make-board))
         (seen
          (while-holding-fence a
           (lambda ()
             (spawn! b 'sender
                     (lambda ()
                       (post! b 'sending #t)
                       (uv-async-send! a)
                       (post! b 'send-returned #t)
                       'sent))
             (await b (lambda () (or (posted b 'sending) (posted b 'sender))))
             (if (await b (lambda () (or (posted b 'send-returned) (posted b 'sender)))
                        hold-ms)
                 'returned-while-held
                 'waiting)))))
    (let* ((sender (cdr (await b (lambda () (posted b 'sender)))))
           (fence (fence-seen-from-another-thread a)))
      ;; A send that left the fence held, by a thread that has since ended,
      ;; would block the close below for good. The release row names that
      ;; defect; here it is reported, and the loop leaked, instead of hung on.
      (cond ((eq? fence 'held) (list seen sender 'fence-left-held))
            (else (uv-close! a)
                  (uv-loop-teardown! loop)
                  (list seen sender))))))

;; --- a refusal is raised after the fence is released -----------------------
;; A with-exception-handler handler runs in the raise's dynamic extent. If
;; the refusal were raised inside the fence, the caller's handler would run
;; holding it, and a handler that waits on the loop thread would deadlock
;; against a close.

(test-equal "a refused send reaches the caller's handler with the fence released"
  'free
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f))))
    (uv-close! a)                       ; closing: every later send is refused
    (let ((seen (call/cc
                 (lambda (k)
                   (with-exception-handler
                    (lambda (c)
                      (k (if (uv-handle-closed? c)
                             (fence-seen-from-another-thread a)
                             (list 'raised (describe c)))))
                    (lambda () (uv-async-send! a) 'not-refused))))))
      (uv-loop-teardown! loop)
      seen)))

;; --- the fence is released on every way out --------------------------------
;; After a send that was made, after a close, after a send the close refused,
;; and after a close of a handle already closing (the idempotent path). A
;; fence left held on any of them would block every later send from another
;; thread, and the loop thread's teardown.

(test-equal "the fence is free after a send, a close, a refused send and a repeated close"
  '(free free free free)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (after-send (begin (uv-async-send! a)
                            (fence-seen-from-another-thread a)))
         (after-close (begin (uv-close! a)
                             (fence-seen-from-another-thread a)))
         (after-refusal (begin (guard (e ((uv-handle-closed? e) #f))
                                 (uv-async-send! a))
                               (fence-seen-from-another-thread a)))
         (after-second-close (begin (uv-close! a)
                                    (fence-seen-from-another-thread a))))
    (uv-loop-teardown! loop)
    (list after-send after-close after-refusal after-second-close)))

;; --- an async left open with no native block --------------------------------
;; No path in the library leaves an async open with its pointer zeroed, but
;; the fence's steps must not fault if one ever does: a fault there would be
;; raised with interrupts disabled and the fence held. Each step checks the
;; pointer and answers a status instead, and the refusal is the one the
;; checked accessor, handle-pointer, raises. The private setter forces the
;; state.
;; This row comes last, because a fault here would leave interrupts disabled
;; for any row after it.

(test-equal "a send or close on an async left open with no native block is refused, not made"
  '((uv-async-send! null-handle-pointer) (uv-close! null-handle-pointer))
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f))))
    (uv-close! a)
    (uv-run loop 'nowait)       ; the close callback frees the block, zeroes the pointer
    (set-handle-state! a 'open)
    (let* ((send (guard (e ((uv-invalid-argument? e)
                            (list (uv-invalid-argument-who e)
                                  (uv-invalid-argument-reason e)))
                           (#t (list 'raised (describe e))))
                   (uv-async-send! a)
                   'sent))
           (close (guard (e ((uv-invalid-argument? e)
                             (list (uv-invalid-argument-who e)
                                   (uv-invalid-argument-reason e)))
                            (#t (list 'raised (describe e))))
                    (uv-close! a)
                    'closed)))
      (set-handle-state! a 'closed)
      (uv-loop-teardown! loop)
      (list send close))))

(test-end "async-fence")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
