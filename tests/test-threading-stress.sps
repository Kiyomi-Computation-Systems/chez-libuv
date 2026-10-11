#!r6rs
;;; STRESS TIER — deliberately OFF the default `make test` gate. This suite
;;; forks real OS threads and is timing-dependent by nature; it runs via
;;; `make test-threading`, not the deterministic suite. Its first rows hold
;;; that a loop thread blocked in `uv-run` does not freeze garbage
;;; collection for other Scheme threads.
;;;
;;; The mechanism: Chez's collector is stop-the-world and needs every OTHER
;;; thread deactivated. A thread inside a PLAIN foreign `uv_run` stays
;;; ACTIVE, so a worker thread's `(collect)` raises
;;;   "cannot collect when multiple threads are active".
;;; Binding `uv_run` __collect_safe (and the callables it invokes)
;;; deactivates the loop thread for the blocking poll, and the worker
;;; collects freely. Binding it plain fails the first rows.
;;;
;;; NOT pure: reaches (libuv private native). Never add to PURE_TESTS, and it is
;;; filtered out of the default TESTS in the Makefile (STRESS_TESTS).
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv timer)
        (libuv handle)
        (libuv async)
        (only (libuv private conditions) uv-wrong-thread? uv-handle-closed?)
        (only (libuv private handles) loop-owner-thread)
        (only (libuv private native) copy-in! copy-out)
        (only (chezscheme)
              collect collect-trip-bytes bytes-allocated
              foreign-alloc foreign-free
              fork-thread
              make-mutex make-condition condition-wait condition-signal
              condition-broadcast with-mutex
              get-thread-id sleep make-time real-time
              make-list iota)
        ;; describe is total: a raise escaping a worker's handler would skip
        ;; its signal, and a worker that never signals hangs its join.
        (only (uv-evidence) describe print-actual-on-failure!))

(define runner (test-runner-simple))
(test-runner-current runner)
;; Each row here returns its evidence when it fails.
(print-actual-on-failure! runner)

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
  ;; completes every collect while the loop thread is blocked. A plain
  ;; uv_run binding fails it at 0 of N, with "cannot collect when multiple
  ;; threads are active" as the first error.
  (test-equal "a worker thread collects freely while the loop thread blocks in uv-run"
    N ok-collects)
  (test-equal "the worker hit no collector error"
    #f first-error))

;; --- bulk copies stay plain, not __collect_safe -------------------------
;; The mirror of the rows above. copy-in! and copy-out hand a bytevector to
;; the shim as a u8*, which is only safe while the collector cannot move it:
;; the binding is PLAIN, so the calling thread stays active and no collection
;; can run until the copy returns. Chez accepts __collect_safe on those
;; bindings without complaint, and then a concurrent collection moves the
;; bytevector mid-copy and corrupts it (31-49 of 50 slowed copies,
;; measured). No single-threaded suite can see the difference, so it is pinned
;; here: a helper thread keeps calling (collect) while the main thread copies
;; 64 MiB, and none of its attempts made wholly inside a copy may succeed.
;;
;; A collection that did run inside the call would be the defect, so the
;; buffers are 64 MiB, a size Chez's collector does not move, and a broken
;; binding fails the row instead of crashing the suite: always idle, though
;; under heavy load it can abort Chez outright ("nonrecoverable invalid
;; memory reference"). collect-trip-bytes is raised for the duration so no
;; allocation-triggered request can stall the helper inside an interval.
;;
;; Each row runs intervals until the helper has tried inside one: at least
;; its minimum (10 for copy-in!, 3 for copy-out) and at most MAX-INTERVALS.
;; A fixed count of intervals fails a correct build at loads of 170-340,
;; with the helper scheduled inside none (`(never-tried 0)`, in either
;; row). Copy-out's minimum is 3 because each further interval is another
;; chance for a broken binding to abort Chez. Between intervals the helper
;; is parked, and it collects while parked, when the main thread is waiting
;; for it and no other thread is active. So every interval starts with the
;; helper just woken, and a copy-out interval's 64 MiB result is collected
;; before the next one: only one is ever alive, which the third row holds.
(let ()
  (define n (* 64 1024 1024))
  (define bv (make-bytevector n 1))
  (define buf (foreign-alloc n))
  (define max-intervals 100)
  (define park-waits 1000)           ; waits of 10 ms: 10 s to park the helper
  (define ten-ms (make-time 'time-duration 10000000 0))
  (define epoch 0)                   ; odd while the main thread is inside a copy
  (define stop #f)
  (define attempts-inside 0)
  (define collections-inside 0)
  (define m (make-mutex))
  (define cv (make-condition))       ; parks, releases and the helper's end
  (define park-requested #t)         ; the helper starts parked
  (define park-for 0)                ; the last park the main thread asked for
  (define parked-for 0)              ; the last park the helper collected in
  (define helper-done #f)
  (define saved-trip (collect-trip-bytes))

  ;; park! : -> unspecified. Holds the helper while a park is requested. The
  ;; first time it sees each new request, it collects and acknowledges. The
  ;; main thread is then waiting on CV, so no other thread is active; the
  ;; guard keeps a collect refused anyway (the main thread gave up waiting)
  ;; from killing the helper.
  (define (park!)
    (with-mutex m
      (let w ()
        (when (and park-requested (not stop))
          (unless (= parked-for park-for)
            (guard (e (#t #f)) (collect))
            (set! parked-for park-for)
            (condition-broadcast cv))
          (condition-wait cv m)
          (w)))))

  ;; Each refused (collect) allocates a little, and nothing collects it
  ;; outside a park while the trip is raised, so the helper pauses 50 us
  ;; between attempts; a 64 MiB copy still sees dozens.
  (define (helper)
    (let loop ()
      (unless stop
        (when park-requested (park!))
        (let* ((e0 epoch)
               (collected (guard (e (#t #f)) (collect) #t))
               (e1 epoch))
          (when (and (odd? e0) (= e0 e1))
            (set! attempts-inside (+ attempts-inside 1))
            (when collected (set! collections-inside (+ collections-inside 1)))))
        (sleep (make-time 'time-duration 50000 0))
        (loop)))
    (with-mutex m (set! helper-done #t) (condition-broadcast cv)))

  ;; park-helper! : -> boolean. Requests a park and waits, at most PARK-WAITS
  ;; waits, until the helper has collected in it. Answers whether it did.
  (define (park-helper!)
    (with-mutex m
      (set! park-for (+ park-for 1))
      (set! park-requested #t)
      (condition-broadcast cv)
      (let wait ((k 0))
        (cond ((= parked-for park-for) #t)
              ((= k park-waits) #f)
              (else (condition-wait cv m ten-ms) (wait (+ k 1)))))))

  (define (release-helper!)
    (with-mutex m (set! park-requested #f) (condition-broadcast cv)))

  ;; intervals-run and peak-growth describe the last inside-verdict's run:
  ;; how many intervals it ran, and the most (bytes-allocated) rose above
  ;; its start at the end of any of them.
  (define intervals-run 0)
  (define peak-growth 0)

  ;; inside-verdict : exact-positive-integer thunk -> list
  ;; '(tried 0) is the only success value: attempts landed inside the
  ;; copies, and not one of them collected. Every other value names why.
  ;; The thunk's result is dropped, for the next park to collect.
  (define (inside-verdict min-intervals thunk)
    (set! attempts-inside 0)
    (set! collections-inside 0)
    (set! intervals-run 0)
    (set! peak-growth 0)
    (if (not (park-helper!))
        (list 'never-parked 'after 0 'intervals)
        (let ((base (bytes-allocated)))
          (let loop ((i 0))
            (set! intervals-run i)
            (cond
              ((and (>= i min-intervals) (> attempts-inside 0))
               (list 'tried collections-inside))
              ((= i max-intervals)
               (list 'never-tried collections-inside 'in i 'intervals))
              (else
               (release-helper!)
               (set! epoch (+ epoch 1))
               (thunk)
               (set! epoch (+ epoch 1))
               (set! peak-growth (max peak-growth (- (bytes-allocated) base)))
               (if (park-helper!)
                   (loop (+ i 1))
                   (list 'never-parked 'after (+ i 1) 'intervals))))))))

  (copy-in! buf bv 0 n)
  (collect-trip-bytes (expt 2 40))
  (fork-thread helper)
  (let* ((copy-in-verdict
          (guard (e (#t (list 'raised (describe e))))
            (inside-verdict 10 (lambda () (copy-in! buf bv 0 n)))))
         (copy-out-verdict
          (guard (e (#t (list 'raised (describe e))))
            (inside-verdict 3 (lambda () (copy-out buf n)))))
         ;; 'bounded needs a run long enough to show growth, and a peak
         ;; that held one result: a copy-out that allocated nothing, or a
         ;; run that ended early, cannot produce it.
         (copy-out-memory
          (cond ((< intervals-run 2) (list 'ran intervals-run 'intervals))
                ((< peak-growth n) (list 'peak-below-one-result peak-growth))
                ((< peak-growth (* 2 n)) 'bounded)
                (else
                 (list 'grew peak-growth 'over intervals-run 'intervals)))))
    (with-mutex m
      (set! stop #t)
      (condition-broadcast cv)
      (let w () (unless helper-done (condition-wait cv m) (w))))
    (collect-trip-bytes saved-trip)
    (foreign-free buf)
    (test-equal "no collection completes while copy-in! is inside its foreign call"
      '(tried 0) copy-in-verdict)
    (test-equal "no collection completes while copy-out is inside its foreign call"
      '(tried 0) copy-out-verdict)
    (test-equal "copy-out's intervals keep at most one 64 MiB result alive"
      'bounded copy-out-memory)))

;; --- real cross-thread affinity refusal ---------------------------------
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

;; --- real owner transfer to a second thread -----------------------------
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

;; --- plumbing shared by the two worker pools below --------------------------
;; A worker in either pool ends at its next send or post once its round has
;; closed, so each round's join waits only for that. JOIN-WAITS bounds the
;; wait anyway: without it, a worker that never ends hangs the suite with no
;; row named. The bound caps only how long a broken round gets to show
;; itself; no verdict on a correct build depends on it.
(define join-waits 1000)               ; waits of 10 ms: 10 s for a broken round
(define ten-ms (make-time 'time-duration 10000000 0))

;; join-workers! : mutex condition (-> boolean) -> boolean
;; With M held, waits on CV until (DONE?) holds, at most JOIN-WAITS waits.
;; Answers whether it held.
(define (join-workers! m cv done?)
  (let wait ((n 0))
    (cond ((done?) #t)
          ((= n join-waits) #f)
          (else (condition-wait cv m ten-ms) (wait (+ n 1))))))

;; run-rounds : exact-nonnegative-integer (-> list) (list -> boolean) -> list
;; Runs up to N rounds in order, and stops after the first that STUCK?
;; names. Such a round spent a wait's whole bound, and every round after it
;; would too, so the suite would hang after all; the rows fail on it anyway.
(define (run-rounds n run-round stuck?)
  (let more ((i 0) (acc '()))
    (if (or (= i n) (and (pair? acc) (stuck? (car acc))))
        (reverse acc)
        (more (+ i 1) (cons (run-round) acc)))))

;; ran-out? : (or symbol list) -> boolean
;; Whether a round's outcomes name a worker that spent a wait's bound: one
;; its join gave up on ('never-ended), or one that found no room in the
;; discipline pool's queue through every wait for a drain ((no-room seq)).
(define (ran-out? outcomes)
  (and (pair? outcomes)
       (exists (lambda (o)
                 (or (eq? o 'never-ended)
                     (and (pair? o) (eq? (car o) 'no-room))))
               outcomes)))

;; --- worker pool posting work via uv-async-send! ------------------------
;; K workers push items to a shared queue and wake the loop thread. The wake
;; callback drains the WHOLE queue each time, so coalescing (N sends -> 1
;; callback) never loses an item. This is the shape uv-async exists for, a
;; worker pool waking its loop, shutdown included: the loop thread closes
;; the async while the workers are still posting.
;;
;; The binding keeps every send off a closing handle by itself (the careless
;; pool below holds that). It cannot tell a worker which of its items arrive:
;; a close drops a wake still pending, and a refused send may follow an item
;; its worker already queued. Exact delivery is the caller's, and this block
;; exercises the discipline for it (docs/api.md, Async):
;;   - a worker holds QM while it checks OPEN?, queues its item, and sends,
;;     so it queues an item only while the loop thread will still drain it;
;;   - the loop thread clears OPEN? under QM, then calls uv-close!, so no item
;;     is queued after the close, and none is queued by a worker it refused;
;;   - then it drains once more: on-wake never runs once a close has started,
;;     even for a send made before it, so the items queued since the last
;;     drain would otherwise be stranded.
;; Workers post until the cleared flag refuses them, and the main thread joins
;; every worker before teardown.
;;
;; A slip in this discipline loses its race only some of the time: a flag
;; cleared after uv-close!, a send outside QM, or a missing join is caught by
;; only 2 to 11 of 20 single-pool runs (measured). So the pool runs ROUNDS
;; times, fresh each time, and a row passes only if it held in every round.
;;
;; The loop thread's drains pace the posts: a worker that finds ROOM items
;; queued waits for the next drain. A fixed cap alone lets a starved loop
;; thread fail a correct build: unpaced, under CPU load, the busiest worker
;; posts up to 304,839 items before the close, and at a load average of 200
;; one reaches a cap of 1,000,000. Paced, a worker reaches CAP only if the
;; loop thread drains over and over without closing. The wait for a drain
;; is bounded too, so a loop thread that stops draining without closing
;; fails a row, where a worker waiting for good would hang the suite inside
;; uv-run.
(let ()
  (define rounds 30)
  (define k 4)
  (define close-after 400)             ; deliveries before the close begins
  (define room 4096)                   ; items queued before a post waits
  (define room-waits 1000)             ; waits of 10 ms for a drain: 10 s
  (define cap 1000000)                 ; a worker still unrefused after this many
                                       ; posts stops, and fails the refusal row
  ;; run-pool : -> (list closed refusals delivery drained)
  ;; One pool, from make-uv-loop to teardown. Each verdict is a sentinel
  ;; symbol when its property held, and otherwise the evidence.
  (define (run-pool)
    (let ()
      (define loop (make-uv-loop))
      (define qm (make-mutex))             ; guards open?, queue, every send
      (define drained (make-condition))    ; broadcast, with QM, at each drain
      (define open? #t)
      (define queue '())                   ; (worker-id . seq), newest first
      (define queued 0)                    ; QUEUE's length, kept with it
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
      ;; post! : pair -> (or #t #f 'no-room). #t: queued, and the loop woken.
      ;; #f: refused -- the loop thread has begun closing; nothing was
      ;; queued. 'no-room: the queue stayed full through ROOM-WAITS waits for
      ;; a drain, so the loop thread stopped draining without closing.
      (define (post! item)
        (with-mutex qm
          (let wait ((n 0))
            (cond ((not open?) #f)
                  ((< queued room)
                   (set! queue (cons item queue))
                   (set! queued (+ queued 1))
                   (uv-async-send! async)
                   #t)
                  ((= n room-waits) 'no-room)
                  (else (condition-wait drained qm ten-ms)
                        (wait (+ n 1)))))))
      (define (take-queue!)                ; with qm held
        (let ((b queue))
          (set! queue '())
          (set! queued 0)
          (condition-broadcast drained)
          b))
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
      ;; A worker that stops unrefused (it raised, found no room, or reached
      ;; CAP) wakes the loop thread, under the discipline, so the round closes
      ;; and uv-run returns. That wake can itself raise only when the
      ;; discipline is already broken -- the handle closing under an open
      ;; flag -- and the outcome has already recorded the failure, so it is
      ;; dropped.
      (define (worker id)
        (let ((outcome
               (guard (e (#t (list 'raised (describe e))))
                 (let push ((seq 0))
                   (if (= seq cap)
                       (list 'never-refused seq)
                       (case (post! (cons id seq))
                         ((#t) (vector-set! accepted id (+ seq 1))
                               (push (+ seq 1)))
                         ((no-room) (list 'no-room seq))
                         (else 'refused)))))))
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
        ;; refuses the workers now, and wakes any waiting for a drain, before
        ;; the join and before teardown closes the async.
        (with-mutex qm
          (set! open? #f)
          (condition-broadcast drained))
        (let* ((ended (with-mutex dm      ; join every worker before teardown
                        (join-workers! dm all-done
                                       (lambda () (= (length results) k)))
                        results))
               (torn (guard (e (#t (list 'raised (describe e))))
                       (uv-loop-teardown! loop)
                       'torn-down)))
          (list
           (cond ((not (eq? run 'returned)) (list 'uv-run run))
                 ((not (eq? torn 'torn-down)) (list 'teardown torn))
                 ((and queued-at-close (positive? queued-at-close))
                  'closed-with-posts-queued)
                 (else (list 'queued-at-close queued-at-close)))
           (let ((outcomes (map (lambda (id)
                                  (cond ((assv id ended) => cdr)
                                        (else 'never-ended)))
                                (iota k))))
             (if (equal? outcomes (make-list k 'refused))
                 'every-worker-refused
                 outcomes))
           (let ((verdicts (map delivery-verdict (iota k))))
             (if (equal? verdicts (make-list k 'exact)) 'exactly-once verdicts))
           (if (null? queue) 'empty (list 'stranded (length queue))))))))
  (let ((pools (run-rounds rounds run-pool
                           (lambda (pool) (ran-out? (cadr pool))))))
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

;; --- a careless pool: sends that race the close ---------------------------
;; The pool above sends only under its own lock. This one takes no lock: K
;; workers send until refused, and the loop thread closes the async from
;; on-wake while they are still sending. Without the binding's fence around
;; each send, this shape reaches the freed handle. Every worker must end
;; refused with &uv-handle-closed, and nothing else may raise.
;;
;; A worker has no cap on its sends: it sends for as long as the loop thread
;; takes to close. A worker bounded by its own count, not the loop thread's
;; progress, can fail a correct build: at a load average of 140 the starved
;; loop thread lets one worker reach a cap of 1,000,000 sends before the
;; 50th wake. What ends a worker on a build that never refuses is the
;; contract instead (docs/api.md, Async): a send made once a close has begun
;; is refused. Workers spin while the loop thread is stalled, and that
;; spinning is what races the close: with an unfenced send, backing off in
;; stalls cuts the failing rounds from 150 to 35 in 40 runs.
;;
;; How often the refusal row catches an unfenced send depends on load: in
;; 6 of 6 runs at a load average near 170, and in 44 of 80 near 10. It
;; catches a wrong refusal in every round, and a send that returns after
;; its worker saw the close begin. It never sees the closer's half of the
;; fence: the closer row in tests/test-async-fence.sps holds that, and
;; holds both halves on the default gate. The first row is the
;; precondition: the loop thread closed the async while the workers sent,
;; and the round's own close and teardown raised nothing.
(let ()
  (define rounds 30)
  (define k 4)
  (define close-at 50)                 ; the wake that closes the async
  ;; run-careless-round : -> (list run outcomes)
  (define (run-careless-round)
    (let ()
      (define loop (make-uv-loop))
      (define async #f)
      (define wakes 0)
      (define close-begun #f)              ; #t once a close of ASYNC has begun
      (define dm (make-mutex))             ; guards results, for the join
      (define all-done (make-condition))
      (define results '())                 ; one outcome per worker
      ;; Begins the close, then tells the workers it has begun. Told first,
      ;; a worker could send before the close began and look as if it had
      ;; sent after.
      (define (close! h)
        (uv-close! h)
        (set! close-begun #t))
      ;; Closes at the CLOSE-AT'th wake, or at once if a worker has ended
      ;; unrefused: the round has failed, and the wakes it waits for may
      ;; never come, which would leave uv-run blocked.
      (define (on-wake h)
        (set! wakes (+ wakes 1))
        (when (or (= wakes close-at)
                  (with-mutex dm
                    (exists (lambda (o) (not (eq? o 'refused))) results)))
          (close! h)))
      ;; Reads CLOSE-BEGUN before each send; read after it, a send made
      ;; before the close began could look as if it came after. A send made
      ;; after the worker saw it set must be refused, so one that returns
      ;; ends the worker unrefused, with its count of sends. A worker that
      ;; ends unrefused sends one more wake so the loop thread sees it. The
      ;; fence makes that safe even if the close has begun.
      (define (worker)
        (let ((outcome
               (guard (e ((uv-handle-closed? e) 'refused)
                         (#t (list 'raised (describe e))))
                 (let send ((n 0))
                   (let ((begun close-begun))
                     (uv-async-send! async)
                     (if begun
                         (list 'sent-after-close n)
                         (send (+ n 1))))))))
          (with-mutex dm
            (set! results (cons outcome results))
            (condition-signal all-done))
          (unless (eq? outcome 'refused)
            (guard (e (#t #f)) (uv-async-send! async)))))
      (set! async (make-uv-async loop on-wake))
      (let spawn ((i 0))
        (when (< i k) (fork-thread worker) (spawn (+ i 1))))
      (let* ((run (guard (e (#t (list 'raised (describe e))))
                    (uv-run loop 'default)  ; returns once the close completes
                    'returned))
             ;; If uv-run returned early, close now, so the workers are
             ;; refused instead of sending into a loop nothing runs. A handle
             ;; already closing or closed makes this a no-op. A raise here or
             ;; in the teardown is the round's evidence, not the suite's end.
             (closed (guard (e (#t (list 'raised (describe e))))
                       (close! async)
                       'closed))
             (ended (with-mutex dm
                      (join-workers! dm all-done
                                     (lambda () (= (length results) k)))
                      results))
             (torn (guard (e (#t (list 'raised (describe e))))
                     (uv-loop-teardown! loop)
                     'torn-down))
             (outcomes (append ended
                               (make-list (- k (length ended)) 'never-ended))))
        (list (if (and (eq? run 'returned) (eq? closed 'closed)
                       (eq? torn 'torn-down))
                  'returned
                  (list run closed torn))
              (if (equal? outcomes (make-list k 'refused))
                  'every-worker-refused
                  outcomes)))))
  (let ((round-results (run-rounds rounds run-careless-round
                                   (lambda (r) (ran-out? (cadr r))))))
    (test-equal "a careless pool's loop closes its async while workers send"
      (make-list rounds 'returned) (map car round-results))
    (test-equal "every careless sender is refused with &uv-handle-closed, and nothing else raises"
      (make-list rounds 'every-worker-refused) (map cadr round-results))))

(test-end "threading-stress")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
