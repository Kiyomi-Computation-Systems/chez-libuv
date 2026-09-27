#!r6rs
;;; STRESS TIER (ADR-0010 companion) — deliberately OFF the default `make test`
;;; gate. This suite forks a real OS thread and is timing-dependent by nature;
;;; it runs via `make test-threading`, not the deterministic suite. It is the
;;; red→green oracle for issue #19: a loop thread blocked in `uv-run` must not
;;; freeze garbage collection for other Scheme threads.
;;;
;;; The mechanism (proved in spike/threading/): Chez's collector is stop-the-
;;; world and needs every OTHER thread deactivated. A thread inside a PLAIN
;;; foreign `uv_run` stays ACTIVE, so a worker thread's `(collect)` raises
;;;   "cannot collect when multiple threads are active".
;;; Rebinding `uv_run` __collect_safe (and the callables it invokes)
;;; deactivates the loop thread for the blocking poll, and the worker collects
;;; freely. So this suite is RED before that conversion and GREEN after.
;;;
;;; NOT pure: reaches (libuv private native). Never add to PURE_TESTS, and it is
;;; filtered out of the default TESTS in the Makefile (STRESS_TESTS).
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv timer)
        (libuv handle)
        (libuv async)
        (only (libuv private conditions) uv-wrong-thread?)
        (only (libuv private handles) loop-owner-thread)
        (only (chezscheme)
              collect threaded? fork-thread
              make-mutex make-condition condition-wait condition-signal with-mutex
              get-thread-id sleep make-time real-time
              open-output-string get-output-string display-condition
              make-list iota))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "threading-stress")

;; On a non-threaded Chez there is no second thread to starve; the whole premise
;; is vacuous, so record a skip and pass. (#19's affinity work degenerates to
;; one owner there too.)
(cond
  ((not (threaded?))
   (test-assert "[skipped] non-threaded Chez — GC-freedom test is vacuous" #t))
  (else
   (let ()
     (define N 50)                 ; collect attempts by the worker
     (define block-ms 500)         ; how long the loop thread sits in the poll
     (define loop (make-uv-loop))
     (define timer (make-uv-timer loop))
     (define m (make-mutex))
     (define done-cond (make-condition))
     (define loop-entered #f)
     (define worker-done #f)
     (define ok-collects 0)
     (define first-error #f)

     (define (worker)
       (let spin () (unless loop-entered (sleep (make-time 'time-duration 0 0)) (spin)))
       ;; Let the loop thread reach the poll (deactivated, once collect-safe)
       ;; before the first attempt, so we measure the blocking window.
       (sleep (make-time 'time-duration 20000000 0)) ; 20 ms
       (let loop ((i 0))
         (when (< i N)
           (let ((outcome (guard (e (#t (let ((p (open-output-string)))
                                          (display-condition e p)
                                          (get-output-string p))))
                            (let build ((k 0) (acc '()))
                              (if (< k 500) (build (+ k 1) (cons k acc)) acc))
                            (collect)
                            'ok)))
             (if (eq? outcome 'ok)
                 (begin (set! ok-collects (+ ok-collects 1)) (loop (+ i 1)))
                 (begin (unless first-error (set! first-error outcome))
                        (set! i N))))) ) ; stop on first failure
       (with-mutex m (set! worker-done #t) (condition-signal done-cond)))

     ;; Oneshot: fires once at block-ms, then the loop has no active handle and
     ;; uv-run returns. The callback is a no-op — the WORKER does the collecting;
     ;; a (collect) on the loop thread here would just race its own callback
     ;; window. Keeping the loop thread idle in the poll is the whole point.
     (uv-timer-start! timer (lambda (t) #f) block-ms 0)
     (fork-thread worker)
     (set! loop-entered #t)
     (uv-run loop 'default)          ; blocks ~block-ms in the poll
     (with-mutex m (let w () (unless worker-done (condition-wait done-cond m) (w))))
     (uv-loop-teardown! loop)

     ;; The load-bearing assertion: with a collect-safe uv_run the worker
     ;; completes every collect while the loop thread is blocked. RED (0/N,
     ;; "cannot collect when multiple threads are active") until #19 lands.
     (test-equal "a worker thread collects freely while the loop thread blocks in uv-run"
       N ok-collects)
     (test-equal "the worker hit no collector error"
       #f first-error))))

;; --- real cross-thread affinity refusal (design §6.3) -------------------
;; The deterministic suite (test-async.sps) simulates a foreign owner by
;; setting the owner field. Here a genuinely different OS thread calls a verb
;; on a main-owned loop and must be refused with &uv-wrong-thread.
(when (threaded?)
  (let ()
    (define loop (make-uv-loop))
    (define timer (make-uv-timer loop))
    (define m (make-mutex))
    (define done (make-condition))
    (define finished #f)
    (define outcome 'unset)
    (fork-thread
     (lambda ()
       (set! outcome
             (guard (e ((uv-wrong-thread? e) 'wrong-thread) (#t 'other-condition))
               (uv-timer-start! timer (lambda (t) #f) 100 0)
               'no-raise))
       (with-mutex m (set! finished #t) (condition-signal done))))
    (with-mutex m (let w () (unless finished (condition-wait done m) (w))))
    (uv-loop-teardown! loop)
    (test-equal "a real worker thread's handle verb is refused with &uv-wrong-thread"
      'wrong-thread outcome)))

;; --- real owner transfer to a second thread (design §6.2) ---------------
;; A loop created on the main thread and run by thread B becomes owned by B —
;; the worker-pool handoff, with a real second thread.
(when (threaded?)
  (let ()
    (define loop (make-uv-loop))
    (define m (make-mutex))
    (define done (make-condition))
    (define finished #f)
    (define b-owns #f)
    (fork-thread
     (lambda ()
       (uv-run loop 'default)               ; no active handles: returns at once
       (set! b-owns (eqv? (loop-owner-thread loop) (get-thread-id)))
       (with-mutex m (set! finished #t) (condition-signal done))))
    (with-mutex m (let w () (unless finished (condition-wait done m) (w))))
    (uv-loop-teardown! loop)               ; drains via uv-run, owner back to main
    (test-equal "a loop run by a second thread is owned by that thread"
      #t b-owns)))

;; --- worker pool posting work via uv-async-send! (design §6.1) ----------
;; K workers push items to a shared queue and wake the loop thread. The wake
;; callback drains the WHOLE queue each time, so coalescing (N sends -> 1
;; callback) never loses an item. This is the driver's real shape and the #20
;; payoff, shutdown included: the loop thread closes the async while the
;; workers are still posting.
;;
;; uv-async-send!'s open-state check is a courtesy (async.sls): it cannot stop
;; the loop thread from closing -- and freeing -- the handle between that check
;; and the native send, so every send must be over before uv-close! starts.
;; The close discipline this block exercises (docs/api.md, Async):
;;   - a worker holds QM while it checks OPEN?, queues its item, and sends;
;;   - the loop thread clears OPEN? under QM, then calls uv-close!, so no send
;;     is between check and native call at the close, and none starts after;
;;   - then it drains once more: on-wake never runs once a close has started,
;;     even for a send made before it, so the items queued since the last
;;     drain would otherwise be stranded.
;; Workers post until the cleared flag refuses them, and the main thread joins
;; every worker before teardown, so no send can outlive the handle or the loop.
;;
;; A slip in this discipline loses its race only some of the time: a flag
;; cleared after uv-close!, a send outside QM, or a missing join was caught by
;; only 2 to 11 of 20 single-pool runs (measured; see
;; .plans/async-close-discipline-mutation-log.md). So the pool runs ROUNDS
;; times, fresh each time, and a row passes only if it held in every round.
(when (threaded?)
  (let ()
    (define rounds 30)
    (define k 4)
    (define close-after 400)             ; deliveries before the close begins
    (define cap 1000000)                 ; a worker still unrefused after this many
                                         ; posts stops, and fails the refusal row
                                         ; (the busiest measured: ~20000)
    (define (describe e)
      (let ((p (open-output-string)))
        (if (condition? e) (display-condition e p) (write e p))
        (get-output-string p)))
    ;; run-pool : -> (list closed refusals delivery drained)
    ;; One pool, from make-uv-loop to teardown. Each verdict is a sentinel
    ;; symbol when its property held, and otherwise the evidence.
    (define (run-pool)
      (let ()
        (define loop (make-uv-loop))
        (define qm (make-mutex))             ; guards open?, queue, every send
        (define open? #t)
        (define queue '())                   ; (worker-id . seq), newest first
        (define async #f)
        (define delivered 0)
        (define seen (make-vector k '()))    ; per worker: every seq delivered
        (define accepted (make-vector k 0))  ; per worker: posts queued; each
                                             ; worker writes only its own slot
        (define queued-at-close #f)
        (define dm (make-mutex))             ; guards results, for the join
        (define all-done (make-condition))
        (define results '())                 ; (worker-id . outcome), one each
        ;; post! : pair -> boolean. #t: queued, and the loop woken. #f:
        ;; refused -- the loop thread has begun closing; nothing was queued.
        (define (post! item)
          (with-mutex qm
            (and open?
                 (begin (set! queue (cons item queue))
                        (uv-async-send! async)
                        #t))))
        (define (take-queue!)                ; with qm held
          (let ((b queue)) (set! queue '()) b))
        (define (deliver! batch)
          (for-each (lambda (item)
                      (let ((id (car item)))
                        (vector-set! seen id (cons (cdr item) (vector-ref seen id)))))
                    batch)
          (set! delivered (+ delivered (length batch))))
        ;; Drains every wake until CLOSE-AFTER items are delivered; then closes
        ;; at the first wake that finds items queued, without draining them
        ;; first -- so the drain after uv-close! is always what delivers them.
        (define (on-wake h)
          (let ((closing? (with-mutex qm
                            (and (>= delivered close-after)
                                 (pair? queue)
                                 (begin (set! open? #f)
                                        (set! queued-at-close (length queue))
                                        #t)))))
            (when closing? (uv-close! h))
            (deliver! (with-mutex qm (take-queue!)))))
        ;; Any raise is a failure, recorded as evidence rather than left to kill
        ;; the thread: under this discipline the handle never refuses a send.
        (define (worker id)
          (let ((outcome
                 (guard (e (#t (list 'raised (describe e))))
                   (let push ((seq 0))
                     (cond ((= seq cap) (list 'never-refused seq))
                           ((post! (cons id seq))
                            (vector-set! accepted id (+ seq 1))
                            (push (+ seq 1)))
                           (else 'refused))))))
            (with-mutex dm
              (set! results (cons (cons id outcome) results))
              (condition-signal all-done))))
        ;; 'exact when worker ID's delivered seqs are 0 .. accepted-1, each once.
        (define (delivery-verdict id)
          (let ((n (vector-ref accepted id))
                (got (list-sort < (vector-ref seen id))))
            (if (equal? got (iota n))
                'exact
                (list 'worker id 'accepted n 'delivered (length got)))))
        (set! async (make-uv-async loop on-wake))
        (let spawn ((id 0))
          (when (< id k) (fork-thread (lambda () (worker id))) (spawn (+ id 1))))
        (let ((run (guard (e (#t (list 'raised (describe e))))
                     (uv-run loop 'default)  ; drains wakes until the close
                     'returned)))
          (with-mutex dm                     ; join every worker before teardown
            (let join ()
              (unless (= (length results) k)
                (condition-wait all-done dm)
                (join))))
          (uv-loop-teardown! loop)
          (list
           (cond ((not (eq? run 'returned)) (list 'uv-run run))
                 ((and queued-at-close (positive? queued-at-close))
                  'closed-with-posts-queued)
                 (else (list 'queued-at-close queued-at-close)))
           (let ((outcomes (map cdr (list-sort (lambda (a b) (< (car a) (car b)))
                                               results))))
             (if (equal? outcomes (make-list k 'refused))
                 'every-worker-refused
                 outcomes))
           (let ((verdicts (map delivery-verdict (iota k))))
             (if (equal? verdicts (make-list k 'exact)) 'exactly-once verdicts))
           (if (null? queue) 'empty (list 'stranded (length queue)))))))
    (let ((pools (let more ((i 0) (acc '()))
                   (if (= i rounds)
                       (reverse acc)
                       (more (+ i 1) (cons (run-pool) acc))))))
      (define (every-round n) (map (lambda (pool) (list-ref pool n)) pools))
      ;; The precondition the rows below depend on: each close met items still
      ;; queued, so the final drain had work and the queue was once non-empty.
      (test-equal "the loop thread closed the async with posts still queued"
        (make-list rounds 'closed-with-posts-queued) (every-round 0))
      (test-equal "every worker posted until the close refused it, and no send raised"
        (make-list rounds 'every-worker-refused) (every-round 1))
      (test-equal "a worker pool delivers every accepted item exactly once through one async handle"
        (make-list rounds 'exactly-once) (every-round 2))
      (test-equal "the shared queue is fully drained"
        (make-list rounds 'empty) (every-round 3)))))

(test-end "threading-stress")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
