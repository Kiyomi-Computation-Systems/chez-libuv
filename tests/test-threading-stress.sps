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
        (only (libuv private conditions) uv-wrong-thread? uv-handle-closed?)
        (only (libuv private handles) loop-owner-thread)
        (only (chezscheme)
              collect threaded? fork-thread
              make-mutex make-condition condition-wait condition-signal with-mutex
              get-thread-id sleep make-time real-time
              open-output-string get-output-string display-condition))

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
;; K workers each push M items to a shared queue and wake the loop thread. The
;; wake callback drains the WHOLE queue each time, so coalescing (N sends -> 1
;; callback) never loses an item. When all are delivered it closes the async so
;; uv-run returns. This is the driver's real shape and the #20 payoff.
(when (threaded?)
  (let ()
    (define k 4)
    (define per-worker 25)
    (define expected (* k per-worker))
    (define loop (make-uv-loop))
    (define qm (make-mutex))
    (define queue '())
    (define delivered 0)
    (define async #f)
    (define (drain! h)
      (let ((batch (with-mutex qm
                     (let ((b queue)) (set! queue '()) b))))
        (set! delivered (+ delivered (length batch)))
        (when (>= delivered expected) (uv-close! h))))
    ;; The item is queued before the send, and the callback closes the async
    ;; only once every item is delivered — so a straggler's final send can race
    ;; the close. That send is redundant (its item is already drained), so a
    ;; closed-handle refusal here is expected and ignored; nothing is lost.
    (define (worker id)
      (let push ((i 0))
        (when (< i per-worker)
          (with-mutex qm (set! queue (cons (cons id i) queue)))
          (guard (e ((uv-handle-closed? e) #t)) (uv-async-send! async))
          (push (+ i 1)))))
    (set! async (make-uv-async loop drain!))
    (let spawn ((id 0))
      (when (< id k) (fork-thread (lambda () (worker id))) (spawn (+ id 1))))
    (uv-run loop 'default)                  ; blocks, draining wakes, until closed
    (uv-loop-teardown! loop)
    (test-equal "a worker pool delivers every posted item through one async handle"
      expected delivered)
    (test-equal "the shared queue is fully drained"
      #t (null? queue))))

(test-end "threading-stress")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
