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

;; --- row 4: the registry is the GC root (ADR-0007, design spec S5) ------
;; "An open handle and its stored closures stay reachable through this table
;; for as long as it is open, even if the caller drops every other reference
;; to it -- closing is therefore never GC-timed." That is a claim about what
;; survives a collection, and it is the one loop-lifecycle property in this
;; stage that needs no handle type to test.
;;
;; The loop record is created inside a `let` whose binding dies with it, so
;; after the collection below the ONLY strong reference left in the program
;; is the registry's own entry. The pointer is kept (an integer, which holds
;; nothing alive) purely as the key to ask the registry with.
(define held-ptr
  (let ((dropped (make-uv-loop)))
    (loop-ptr dropped)))

(collect)

(test-equal "seed: the dropped loop is still allocated after a full collection"
  1 (live-count 'loop))

;; Resolved ONCE and guarded at each use below, so that a registry which
;; stopped holding the record fails these assertions by name instead of
;; aborting the suite on the first accessor that gets handed #f.
(define recovered (registry-ref held-ptr))

(test-equal "a loop the caller dropped is still resolvable through the registry"
  'resolved
  (if (uv-loop? recovered) 'resolved 'not-in-the-registry))

(test-equal "the dropped loop is still open"
  'open
  (if (and (uv-loop? recovered) (uv-loop-open? recovered)) 'open 'not-open))

;; Still FUNCTIONAL, not merely present: this drives the real uv_loop_t
;; through libuv, so a loop whose pointer had been freed out from under the
;; registry would fail here rather than pass on a stale record.
(test-equal "the dropped loop still runs"
  'no-work
  (if (and (uv-loop? recovered) (not (uv-run recovered 'nowait)))
      'no-work
      'work-or-unrecoverable))

(when (uv-loop? recovered) (uv-loop-close! recovered))

(test-equal "closing it through the registry restores the counter balance"
  0 (live-count 'loop))

(test-equal "closing it through the registry restores the registry baseline"
  registry-count-at-start (registry-count))

;; --- row 5: 100 iterations, with a full collection on each --------------
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
