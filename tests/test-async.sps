#!r6rs
;;; SRFI-64 suite for the #20 threading model: enforced per-loop thread
;;; affinity (this file's first section) and uv_async cross-thread wakeup
;;; (added in the async section below). It is a DETERMINISTIC suite on the
;;; default `make test` gate — it forks no OS threads. The affinity check is
;;; exercised by pointing a loop's owner field at a foreign thread id and
;;; confirming the verb refuses; uv_async_send is exercised same-thread, since
;;; libuv permits a loop-thread send too. The genuinely multi-threaded proofs
;;; (a real worker raising, owner transfer to a real thread, a worker pool
;;; posting via uv-async-send!) live in tests/test-threading-stress.sps, off
;;; the default gate (ADR-0010 companion), because they fork threads and are
;;; timing-dependent.
(import (rnrs)
        (srfi :64)
        (libuv)
        (only (libuv private handles) loop-owner-thread set-loop-owner-thread!)
        (only (libuv private native) current-thread-id live-counts))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "async")

;; A thread id no real thread in this process will hold, used to simulate a
;; loop owned by another thread without actually forking one. Deterministic on
;; any Chez: on a non-threaded build current-thread-id is a constant (0) and
;; this is still != it, so the check still fires (design D5).
(define foreign-owner 999999)

;; --- enforced per-loop thread affinity (design §6) ----------------------

;; Positive control: on the owning thread a verb runs normally. Without this,
;; a check that raised unconditionally would still pass the refusal tests.
(test-equal "a handle verb on the loop's owning thread does not raise"
  'ran
  (let* ((loop (make-uv-loop)) (timer (make-uv-timer loop)))
    (guard (e (#t 'raised))
      (uv-timer-start! timer (lambda (t) #f) 100 0)
      (uv-timer-stop! timer)
      (uv-loop-teardown! loop)
      'ran)))

;; The refusal: a verb invoked while the loop is owned by another thread raises
;; &uv-wrong-thread. Restore the owner before teardown so cleanup runs normally.
(test-equal "a handle verb from a non-owning thread raises &uv-wrong-thread"
  'wrong-thread
  (let* ((loop (make-uv-loop)) (timer (make-uv-timer loop)))
    (set-loop-owner-thread! loop foreign-owner)
    (let ((outcome (guard (e ((uv-wrong-thread? e) 'wrong-thread)
                             (#t 'other-condition))
                     (uv-timer-start! timer (lambda (t) #f) 100 0)
                     'no-raise)))
      (set-loop-owner-thread! loop (current-thread-id))
      (uv-loop-teardown! loop)
      outcome)))

(test-equal "the refusal names who, the expected owner, and the actual caller"
  (list 'uv-timer-start! foreign-owner (current-thread-id))
  (let* ((loop (make-uv-loop)) (timer (make-uv-timer loop)))
    (set-loop-owner-thread! loop foreign-owner)
    (let ((outcome (guard (e ((uv-wrong-thread? e)
                              (list (uv-wrong-thread-who e)
                                    (uv-wrong-thread-expected e)
                                    (uv-wrong-thread-actual e)))
                             (#t 'other-condition))
                     (uv-timer-start! timer (lambda (t) #f) 100 0)
                     'no-raise)))
      (set-loop-owner-thread! loop (current-thread-id))
      (uv-loop-teardown! loop)
      outcome)))

;; uv-run transfers ownership to the calling thread. Simulate a loop owned
;; elsewhere, run it (no handles, so the poll returns at once), and confirm the
;; caller now owns it — the create-on-A/run-on-B handoff, minus the second
;; thread (which test-threading-stress.sps supplies).
(test-equal "uv-run transfers loop ownership to the calling thread"
  #t
  (let ((loop (make-uv-loop)))
    (set-loop-owner-thread! loop foreign-owner)
    (uv-run loop 'default)
    (let ((owned (eqv? (loop-owner-thread loop) (current-thread-id))))
      (uv-loop-teardown! loop)
      owned)))

;; --- uv_async construction, send, and the callback (design §6.1) --------
;; uv_async_send is thread-safe and may be called from the loop thread too, so
;; the send->wake path is exercised deterministically here without a fork. The
;; cross-thread proofs are in tests/test-threading-stress.sps.

(define (live-async-count)
  (cdr (assq 'async (live-counts))))

(test-equal "make-uv-async yields an open async handle"
  '(#t #t)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f))))
    (let ((r (list (uv-async? a) (uv-handle-open? a))))
      (uv-close! a)
      (uv-loop-teardown! loop)
      r)))

(test-equal "an async handle balances its allocation counter across close"
  '(1 0)
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f)))
         (after-create (live-async-count)))
    (uv-close! a)
    (uv-loop-teardown! loop)
    (list after-create (live-async-count))))

;; A same-thread send wakes the loop; the callback runs and receives the very
;; handle it was registered for. The callback closes the async so uv-run
;; 'default returns (an open async keeps the loop alive).
(test-equal "uv-async-send! delivers a wake callback that receives its handle"
  '(fired same-handle)
  (let* ((loop (make-uv-loop))
         (fired #f)
         (got-same #f)
         (a #f))
    (set! a (make-uv-async loop
                           (lambda (h)
                             (set! fired #t)
                             (set! got-same (eq? h a))
                             (uv-close! h))))
    (uv-async-send! a)
    (uv-run loop 'default)
    (uv-loop-teardown! loop)
    (list (if fired 'fired 'not-fired)
          (if got-same 'same-handle 'other-handle))))

;; Coalescing: N sends before an iteration may collapse to one callback. The
;; design forbids assuming one-callback-per-send, so tolerate 1..N.
(test-equal "N sends before an iteration yield between 1 and N callbacks"
  'coalesced-ok
  (let* ((loop (make-uv-loop))
         (n 8)
         (count 0)
         (a (make-uv-async loop (lambda (h) (set! count (+ count 1))))))
    (let send ((i 0)) (when (< i n) (uv-async-send! a) (send (+ i 1))))
    (uv-run loop 'once)
    (uv-close! a)
    (uv-loop-teardown! loop)
    (if (and (>= count 1) (<= count n)) 'coalesced-ok (list 'count count))))

;; --- gating: construction is checked, send is exempt --------------------

(test-equal "make-uv-async from a non-owning thread raises &uv-wrong-thread"
  'wrong-thread
  (let ((loop (make-uv-loop)))
    (set-loop-owner-thread! loop foreign-owner)
    (let ((outcome (guard (e ((uv-wrong-thread? e) 'wrong-thread)
                             (#t 'other-condition))
                     (make-uv-async loop (lambda (h) #f))
                     'no-raise)))
      (set-loop-owner-thread! loop (current-thread-id))
      (uv-loop-teardown! loop)
      outcome)))

;; The exemption, proved without a fork: with the loop owned elsewhere, a
;; normal verb would raise, but uv-async-send! still succeeds — it is the one
;; call libuv makes thread-safe.
(test-equal "uv-async-send! is exempt from the affinity check"
  'sent
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f))))
    (set-loop-owner-thread! loop foreign-owner)
    (let ((outcome (guard (e ((uv-wrong-thread? e) 'wrongly-refused)
                             (#t 'other-condition))
                     (uv-async-send! a)
                     'sent)))
      (set-loop-owner-thread! loop (current-thread-id))
      (uv-close! a)
      (uv-loop-teardown! loop)
      outcome)))

(test-equal "uv-async-send! on a closed async raises &uv-handle-closed"
  'closed
  (let* ((loop (make-uv-loop))
         (a (make-uv-async loop (lambda (h) #f))))
    (uv-close! a)
    (let ((outcome (guard (e ((uv-handle-closed? e) 'closed) (#t 'other-condition))
                     (uv-async-send! a)
                     'no-raise)))
      (uv-loop-teardown! loop)
      outcome)))

(test-equal "uv-async-send! rejects a non-async handle"
  '(uv-async-send! not-a-uv-async)
  (let* ((loop (make-uv-loop))
         (timer (make-uv-timer loop)))
    (let ((outcome (guard (e ((uv-invalid-argument? e)
                              (list (uv-invalid-argument-who e)
                                    (uv-invalid-argument-reason e)))
                             (#t 'other-condition))
                     (uv-async-send! timer)
                     'no-raise)))
      (uv-close! timer)
      (uv-loop-teardown! loop)
      outcome)))

(test-end "async")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
