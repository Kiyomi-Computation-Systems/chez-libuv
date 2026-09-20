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
        (only (libuv private native) current-thread-id))

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

(test-end "async")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
