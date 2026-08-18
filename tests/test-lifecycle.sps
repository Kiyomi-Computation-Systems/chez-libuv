#!r6rs
;;; SRFI-64 suite for allocation balance across whole lifecycles -- design
;;; spec S10 (GC invariants and the debug counters that enforce them) and
;;; S11 ("counters asserted mid-test nonzero, then balanced: after an
;;; ordinary close, after a callback raises, after 100 iterations plus
;;; (collect)").
;;;
;;; Stage 2 fills in the LOOP rows only. Handle rows (a timer's counters, the
;;; registry after close_cb, a deferred-error re-raise leaving the loop
;;; usable) arrive with Tasks 7-9, which extend this file rather than adding
;;; another one.
;;;
;;; Every assertion here needs the DEV shim (CFLAGS_DEV,
;;; -DCHEZ_LIBUV_DEBUG_COUNTERS); against a production shim the live queries
;;; are constant 0. The first assertion names that precondition, so it is
;;; what fails, by name, rather than a balance check that looks like
;;; cross-wiring.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)

(define (live-count kind) (cdr (assq kind (live-counts))))

(define registry-count-at-start (registry-count))

(test-begin "lifecycle")

;; --- baseline -----------------------------------------------------------
(test-equal "every allocation counter starts at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-equal "the handle registry starts empty"
  0 registry-count-at-start)

;; --- row 1: an ordinary make / close ------------------------------------
(define l (make-uv-loop))

(test-equal "seed: make-uv-loop moves the live loop counter off zero"
  1 (live-count 'loop))

(test-equal "seed: make-uv-loop puts exactly one entry in the registry"
  1 (- (registry-count) registry-count-at-start))

(uv-loop-close! l)

(test-equal "after an ordinary close the live loop counter is back to zero"
  0 (live-count 'loop))

(test-equal "after an ordinary close the registry is back to its baseline"
  registry-count-at-start (registry-count))

(test-equal "no other allocation class moved across a loop's whole lifetime"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

;; --- row 2: a raise out of call-with-uv-loop ----------------------------
;; The counter is sampled from INSIDE the body, so this cannot pass with a
;; call-with-uv-loop that never allocated a loop at all.
(define seen-inside 'body-never-ran)

(define raise-reason
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (call-with-uv-loop
     (lambda (loop)
       (set! seen-inside (live-count 'loop))
       (uv-run loop 'nowait)
       (raise (make-uv-invalid-argument 'test-body 'deliberate))))
    'no-raise))

(test-equal "seed: a loop was live inside the body that raised"
  1 seen-inside)

(test-equal "the body's raise propagates out of call-with-uv-loop"
  'deliberate raise-reason)

(test-equal "the loop is freed even though the body raised"
  0 (live-count 'loop))

(test-equal "the registry is back to its baseline after the raising body"
  registry-count-at-start (registry-count))

;; --- row 3: a loop torn down through uv-loop-teardown! ------------------
(define td (make-uv-loop))

(test-equal "seed: the teardown loop is live before teardown"
  1 (live-count 'loop))

(uv-loop-teardown! td)

(test-equal "uv-loop-teardown! frees the loop"
  0 (live-count 'loop))

(test-equal "uv-loop-teardown! leaves the registry at its baseline"
  registry-count-at-start (registry-count))

;; --- row 4: 100 iterations, with a full collection on each --------------
;; (collect) on every iteration is the GC-pressure axis design spec S11 asks
;; for: the registry is the only GC root for an open loop (ADR-0007), so a
;; collection between make and close must not disturb it.
(define peak-live 0)
(define peak-registry 0)

(let iterate ((i 0))
  (when (< i 100)
    (let ((one (make-uv-loop)))
      (uv-run one 'nowait)
      (set! peak-live (max peak-live (live-count 'loop)))
      (set! peak-registry
            (max peak-registry (- (registry-count) registry-count-at-start)))
      (collect)
      (uv-loop-close! one))
    (iterate (+ i 1))))

(test-equal "seed: every one of the 100 iterations held a live loop"
  1 peak-live)

(test-equal "seed: every one of the 100 iterations held a registry entry"
  1 peak-registry)

(test-equal "100 make/run/collect/close iterations leave no live loop"
  0 (live-count 'loop))

(test-equal "100 make/run/collect/close iterations leave the registry at its baseline"
  registry-count-at-start (registry-count))

(collect)

(test-equal "a final full collection leaves every counter at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-end "lifecycle")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
