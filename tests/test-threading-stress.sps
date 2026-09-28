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
        (only (libuv private native) copy-in! copy-out)
        (only (chezscheme)
              collect collect-trip-bytes foreign-alloc foreign-free
              fork-thread
              make-mutex make-condition condition-wait condition-signal with-mutex
              get-thread-id sleep make-time real-time
              open-output-string get-output-string display-condition
              make-list iota))

(define runner (test-runner-simple))
(test-runner-current runner)

;; describe : object -> string
;; A raised object's message, for a row to carry as evidence. Total: if
;; printing it raises too (a record writer that raises, say), the answer is a
;; fixed string, because a raise escaping the handler that called this would
;; skip whatever follows -- a worker that never signals hangs its join.
(define (describe e)
  (guard (err (#t "<the raised object could not be printed>"))
    (let ((p (open-output-string)))
      (if (condition? e) (display-condition e p) (write e p))
      (get-output-string p))))

(test-begin "threading-stress")

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
        (let ((outcome (guard (e (#t (describe e)))
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
    #f first-error))

;; --- bulk copies stay plain, not __collect_safe (issue #35) -------------
;; The mirror of the rows above. copy-in! and copy-out hand a bytevector to
;; the shim as a u8*, which is only safe while the collector cannot move it:
;; the binding is PLAIN, so the calling thread stays active and no collection
;; can run until the copy returns. Chez accepts __collect_safe on those
;; bindings without complaint, and then a concurrent collection moves the
;; bytevector mid-copy and corrupts it (review of #36: 31-49 of 50 slowed
;; copies). No single-threaded suite can see the difference, so it is pinned
;; here: a helper thread keeps calling (collect) while the main thread copies
;; 64 MiB, and none of its attempts made wholly inside a copy may succeed.
;;
;; A collection that did run inside the call would be the defect, so the
;; buffers are 64 MiB, a size Chez's collector does not move, and a broken
;; binding fails the row instead of crashing the suite. collect-trip-bytes is
;; raised for the duration so no allocation-triggered request can stall the
;; helper inside an interval; each copy-out interval allocates 64 MiB, so
;; there are only 3 of them.
(let ()
  (define n (* 64 1024 1024))
  (define bv (make-bytevector n 1))
  (define buf (foreign-alloc n))
  (define epoch 0)                   ; odd while the main thread is inside a copy
  (define stop #f)
  (define attempts-inside 0)
  (define collections-inside 0)
  (define m (make-mutex))
  (define helper-done-cond (make-condition))
  (define helper-done #f)
  (define saved-trip (collect-trip-bytes))

  ;; Each refused (collect) allocates a little, and nothing collects it
  ;; while the trip is raised, so the helper pauses 50 us between attempts;
  ;; a 64 MiB copy still sees dozens.
  (define (helper)
    (let loop ()
      (unless stop
        (let* ((e0 epoch)
               (collected (guard (e (#t #f)) (collect) #t))
               (e1 epoch))
          (when (and (odd? e0) (= e0 e1))
            (set! attempts-inside (+ attempts-inside 1))
            (when collected (set! collections-inside (+ collections-inside 1)))))
        (sleep (make-time 'time-duration 50000 0))
        (loop)))
    (with-mutex m (set! helper-done #t) (condition-signal helper-done-cond)))

  ;; inside-verdict : exact-positive-integer thunk -> (list symbol count)
  ;; '(tried 0) is the only success value: attempts landed inside the
  ;; copies, and not one of them collected.
  (define (inside-verdict intervals thunk)
    (set! attempts-inside 0)
    (set! collections-inside 0)
    (let loop ((i 0))
      (when (< i intervals)
        (set! epoch (+ epoch 1))
        (thunk)
        (set! epoch (+ epoch 1))
        (loop (+ i 1))))
    (list (if (> attempts-inside 0) 'tried 'never-tried) collections-inside))

  (copy-in! buf bv 0 n)
  (collect-trip-bytes (expt 2 40))
  (fork-thread helper)
  (let* ((copy-in-verdict
          (guard (e (#t (list 'raised (describe e))))
            (inside-verdict 10 (lambda () (copy-in! buf bv 0 n)))))
         (copy-out-verdict
          (guard (e (#t (list 'raised (describe e))))
            (inside-verdict 3 (lambda () (copy-out buf n))))))
    (set! stop #t)
    (with-mutex m (let w () (unless helper-done (condition-wait helper-done-cond m) (w))))
    (collect-trip-bytes saved-trip)
    (foreign-free buf)
    (test-equal "no collection completes while copy-in! is inside its foreign call"
      '(tried 0) copy-in-verdict)
    (test-equal "no collection completes while copy-out is inside its foreign call"
      '(tried 0) copy-out-verdict)))

;; --- real cross-thread affinity refusal (design §6.3) -------------------
;; The deterministic suite (test-async.sps) simulates a foreign owner by
;; setting the owner field. Here a genuinely different OS thread calls a verb
;; on a main-owned loop and must be refused with &uv-wrong-thread.
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
    'wrong-thread outcome))

;; --- real owner transfer to a second thread (design §6.2) ---------------
;; A loop created on the main thread and run by thread B becomes owned by B —
;; the worker-pool handoff, with a real second thread.
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
    #t b-owns))

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
(let ()
  (define rounds 30)
  (define k 4)
  (define close-after 400)             ; deliveries before the close begins
  (define cap 1000000)                 ; a worker still unrefused after this many
                                       ; posts stops, and fails the refusal row
                                       ; (the busiest measured: ~20000)
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
      (define stopped-early 0)             ; workers that stopped unrefused
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
      ;; A worker that stopped before being refused makes the next wake close
      ;; at once: the round has already failed, and waiting for posts that
      ;; may never come would leave uv-run blocked, a hang, not a failing row.
      (define (on-wake h)
        (let ((closing? (with-mutex qm
                          (and (or (positive? stopped-early)
                                   (and (>= delivered close-after)
                                        (pair? queue)))
                               (begin (set! open? #f)
                                      (set! queued-at-close (length queue))
                                      #t)))))
          (when closing? (uv-close! h))
          (deliver! (with-mutex qm (take-queue!)))))
      ;; Any raise is a failure, recorded as evidence rather than left to kill
      ;; the thread: under this discipline the handle never refuses a send.
      ;; A worker that stops unrefused (it raised, or reached CAP) wakes the
      ;; loop thread, under the discipline, so the round closes and uv-run
      ;; returns. That wake can itself raise only when the discipline is
      ;; already broken -- the handle closing under an open flag -- and the
      ;; outcome has already recorded the failure, so it is dropped.
      (define (worker id)
        (let ((outcome
               (guard (e (#t (list 'raised (describe e))))
                 (let push ((seq 0))
                   (cond ((= seq cap) (list 'never-refused seq))
                         ((post! (cons id seq))
                          (vector-set! accepted id (+ seq 1))
                          (push (+ seq 1)))
                         (else 'refused))))))
          (unless (eq? outcome 'refused)
            (guard (e (#t #f))
              (with-mutex qm
                (when open?
                  (set! stopped-early (+ stopped-early 1))
                  (uv-async-send! async)))))
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
        ;; Already clear if the closing wake ran. If uv-run raised first, this
        ;; refuses the workers now, before the join and before teardown
        ;; closes the async, instead of letting each post to CAP into a loop
        ;; that no longer drains.
        (with-mutex qm (set! open? #f))
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
      (make-list rounds 'empty) (every-round 3))))

(test-end "threading-stress")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
