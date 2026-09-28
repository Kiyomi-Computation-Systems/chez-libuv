#!r6rs
;;; SRFI-64 suite for the async send fence (#33). uv-async-send! may run on
;;; any thread, while uv-close! runs on the loop thread, and the close frees
;;; the handle's native block at the end of that uv-run iteration. A send
;;; that has checked the handle is open but not yet made its native call can
;;; therefore reach the block after it is freed. The fence rules that out:
;;; each send either completes before the close begins, or is refused with
;;; &uv-handle-closed without touching the handle.
;;;
;;; On the default gate and the memory gate. The engine sweep is
;;; single-threaded and deterministic. The rows after it each fork a thread,
;;; because Chez mutexes are recursive: only a thread that does not hold the
;;; fence can see it held, or wait on it. Their verdicts on a
;;; correct build do not depend on timing. A row waits for events; where it
;;; also has a time bound, the bound caps how long it gives a broken build to
;;; show itself, or how long a retry may take.
(import (rnrs)
        (srfi :64)
        (libuv)
        (only (libuv private handles) async-fence)
        ;; make-engine drives the sweep; the thread primitives drive the rows
        ;; after it.
        (only (chezscheme) make-engine
              fork-thread make-mutex make-condition with-mutex
              mutex-acquire mutex-release condition-wait condition-broadcast
              collect collect-trip-bytes sleep make-time current-time add-duration
              open-output-string get-output-string display-condition))

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

;; describe : object -> string
;; A raised object's message, for a row to carry as evidence. Total, so a
;; handler that calls it cannot raise in turn.
(define (describe e)
  (guard (err (#t "<the raised object could not be printed>"))
    (let ((p (open-output-string)))
      (if (condition? e) (display-condition e p) (write e p))
      (get-output-string p))))

(test-begin "async-fence")

;; --- the engine sweep: a close at every point inside a send ---------------
;; An engine runs uv-async-send! for FUEL ticks. Where the fuel runs out, the
;; send is suspended somewhere inside the verb, and the sweep closes the
;; handle and frees its block before resuming it. That is what a green-thread
;; scheduler on the loop thread does when one engine sends while another
;; closes. Stepping FUEL up from 1 suspends the send at every point in it in
;; turn, so the race is deterministic here, with no second thread.
;;
;; Before closing, the sweep polls the loop to learn whether the send's
;; native call has already run: if it has, its wake is pending and on-wake
;; fires. So each suspended row has exactly one right answer:
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

;; send-then-close : exact-positive-integer -> (or symbol list)
;; One row: a sentinel symbol when the row held, and otherwise the evidence.
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
              (if (and (eq? outcome 'sent) woke-at-all)
                  'finished
                  (list 'finished outcome (if woke-at-all 'woke 'no-wake)))))
          (lambda (suspended)
            (poll-for-wake! loop (lambda () woke))
            (let ((woke-before-close woke))
              (uv-close! a)
              (uv-run loop 'nowait)       ; the close callback frees the block
              (let ((outcome (suspended 1000000
                                        (lambda (ticks v) v)
                                        (lambda (more) 'still-running))))
                (uv-loop-teardown! loop)
                (cond ((and (eq? outcome 'refused) (not woke-before-close))
                       'refused)
                      ((and (eq? outcome 'sent) woke-before-close)
                       'sent-before-close)
                      (else
                       (list 'resumed outcome
                             (if woke-before-close
                                 'woke-before-close
                                 'no-wake-before-close))))))))))

;; A raise between rows would abort the suite, so the whole sweep is caught
;; here and its evidence handed to the rows.
(define sweep
  (guard (e (#t (list (list 'sweep-raised (describe e)))))
    (let run ((fuel 1) (acc '()))
      (if (> fuel sweep-max-fuel)
          (reverse acc)
          (run (+ fuel 1) (cons (cons fuel (send-then-close fuel)) acc))))))

(define (sweep-violations)
  (filter (lambda (row)
            (not (and (pair? row)
                      (memq (cdr row) '(refused sent-before-close finished)))))
          sweep))

(test-equal "a send suspended anywhere in uv-async-send! sent before the close or is refused after it"
  '() (sweep-violations))

;; The precondition the row above depends on: the sweep reached the send
;; before it decided, and its fuel outlasted the whole verb. Without this, a
;; sweep that never got inside the send would pass the row above.
(test-equal "the sweep caught the send undecided and also ran it to completion"
  '(refused finished)
  (list (if (exists (lambda (row) (and (pair? row) (eq? (cdr row) 'refused)))
                    sweep)
            'refused
            'never-refused)
        (let ((last-row (list-ref sweep (- (length sweep) 1))))
          (if (and (pair? last-row) (eq? (cdr last-row) 'finished))
              'finished
              last-row))))

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
        (cond ((ready?) => (lambda (v) v))
              ((not deadline)
               (condition-wait (board-changed b) (board-lock b))
               (wait))
              ((condition-wait (board-changed b) (board-lock b) deadline)
               (wait))
              (else (ready?)))))))

;; while-holding-fence : uv-async (-> object) -> object
;; Runs THUNK on this thread while it holds A's send fence, with collections
;; triggered by allocation put off. A thread blocked on the fence with
;; interrupts disabled stays active, and a collection this thread started
;; would wait for it for good, while it waits for the fence. The row that
;; checks for such blocking reports it by name; without this, an earlier
;; row would hang on it instead.
(define (while-holding-fence a thunk)
  (let ((saved (collect-trip-bytes)))
    (dynamic-wind
     (lambda () (collect-trip-bytes (expt 2 40)))
     (lambda () (with-mutex (async-fence a) (thunk)))
     (lambda () (collect-trip-bytes saved)))))

;; spawn! : board symbol (-> object) -> unspecified
;; Runs THUNK on a new thread and posts its value under KEY, or
;; (raised message) if it raised. An uncaught raise would end only that
;; thread, and nothing would post.
(define (spawn! b key thunk)
  (fork-thread
   (lambda ()
     (post! b key (guard (e (#t (list 'raised (describe e)))) (thunk))))))

;; --- the closer waits for a send inside the fence --------------------------
;; The sweep runs on one thread, so it cannot tell whether uv-close! takes
;; the fence: on the thread that holds the fence, a close would take it
;; anyway. Here the main thread holds the fence, as a sender does between
;; its open check and its native call, while another thread -- the loop's
;; owner -- calls uv-close!. The close must wait for the release, so the
;; holder sees the handle open for as long as it holds the fence.

(define hold-ms 100)     ; how long the holder gives an unfenced close

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
                       (uv-run loop 'nowait)    ; this thread now owns the loop
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

;; --- a refusal is raised after the fence is released -----------------------
;; A with-exception-handler handler runs in the raise's dynamic extent. If
;; the refusal were raised inside the fence, the caller's handler would run
;; holding it, and a handler that waits on the loop thread would deadlock
;; against a close.

;; fence-seen-from-another-thread : uv-async -> (or 'free 'held list)
(define (fence-seen-from-another-thread a)
  (let ((b (make-board)))
    (spawn! b 'probe
            (lambda ()
              (if (mutex-acquire (async-fence a) #f)
                  (begin (mutex-release (async-fence a)) 'free)
                  'held)))
    (cdr (await b (lambda () (posted b 'probe))))))

(test-equal "a refused send reaches the caller's handler with the fence released"
  'free
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f))))
    (uv-close! a)                       ; closing: every send is now refused
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

;; --- a sender waiting for the fence does not stop a collection -------------
;; A thread blocked taking a mutex is deactivated, so another thread can
;; collect. Blocked with interrupts disabled, it stays active, and an
;; explicit (collect) raises "cannot collect when multiple threads are
;; active". So the fence must be taken before interrupts are disabled. The
;; main thread holds the fence while a sender blocks on it, and collects.
;; The sender is active until it reaches the fence, so the main thread
;; retries, up to a cap; a sender blocked the wrong way never lets it
;; succeed.

(define collect-attempts 2000)   ; 1 ms apart

(test-equal "a sender waiting for the send fence does not keep another thread from collecting"
  '(collected sent)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (b (make-board))
         (collected
          (while-holding-fence a
           (lambda ()
             (spawn! b 'sender
                     (lambda ()
                       (post! b 'sending #t)
                       (uv-async-send! a)
                       'sent))
             (await b (lambda () (or (posted b 'sending) (posted b 'sender))))
             (let retry ((i 0) (last 'never-tried))
               (if (= i collect-attempts)
                   last
                   (let ((outcome (guard (e (#t (describe e))) (collect) 'collected)))
                     (if (eq? outcome 'collected)
                         'collected
                         (begin
                           (sleep (make-time 'time-duration 1000000 0))
                           (retry (+ i 1) outcome))))))))))
    (let ((sender (cdr (await b (lambda () (posted b 'sender))))))
      (uv-close! a)
      (uv-loop-teardown! loop)
      (list collected sender))))

(test-end "async-fence")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
