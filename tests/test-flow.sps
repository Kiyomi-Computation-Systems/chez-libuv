#!r6rs
;;; SRFI-64 suite for v0.5's flow-control surfaces. Task 1 writes the
;;; cross-stream isolation section; Tasks 2 and 3 append.
;;;
;;; NOT pure: reaches (libuv private native). Never add to PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv stream)
        (libuv tcp)
        (libuv timer)
        (libuv pipe)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "flow")

;; --- cross-stream isolation ----------------------------------------------
;; FOUR readers, not two: with two, "the survivor still reads" and "the
;; survivor got ITS OWN bytes" are the same assertion.
(define reader-count 4)
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(define port (bind-loopback! server))

(define accepted '())
(define collectors '())
(define clients '())

(uv-listen! server 16
  (lambda (err)
    (when (not err)
      (let ((peer (uv-accept! server))      ; ONE argument; returns the peer
            (col  (make-byte-collector)))
        (set! accepted (cons peer accepted))
        (set! collectors (cons col collectors))
        (uv-read-start! peer
                        (lambda (bv s e) (collect-span! col bv s e) (collect))
                        (lambda () #f)
                        (lambda (c) #f))))))

(let build ((i 0))
  (when (< i reader-count)
    (let ((c (make-uv-tcp loop)))
      (set! clients (cons c clients))
      (connect-loopback! c port (lambda (err) #f))
      (build (+ i 1)))))

(test-equal "seed: every client connected and was accepted"
  'satisfied
  (run-until/ticking loop (lambda () (= (length accepted) reader-count)) 4000))

(define peers (list->vector (reverse accepted)))
(define cols  (list->vector (reverse collectors)))
(define cli   (list->vector (reverse clients)))

;; Distinct payloads per survivor. A SHARED sentinel is the trap
;; test-echo.sps:163-172 names by title.
(define (payload-for i) (seeded-bytes 256 (+ 7000 (* i 131))))

(test-equal "seed: the survivors' payloads are pairwise distinct"
  '(distinct distinct distinct)
  (list (if (equal? (payload-for 1) (payload-for 2)) 'same 'distinct)
        (if (equal? (payload-for 1) (payload-for 3)) 'same 'distinct)
        (if (equal? (payload-for 2) (payload-for 3)) 'same 'distinct)))

;; Close reader 0 from inside its own read callback. The replacement callback
;; STILL COLLECTS: without that, cols[0] is frozen at 0 on both sides of the
;; comparison below and no src/ mutation could move it.
(define closed-fired 'not-yet)
(uv-read-stop! (vector-ref peers 0))
(uv-read-start! (vector-ref peers 0)
                (lambda (bv s e)
                  (collect-span! (vector-ref cols 0) bv s e)
                  (when (uv-handle-open? (vector-ref peers 0))
                    (uv-close! (vector-ref peers 0)
                               (lambda () (set! closed-fired 'fired)))))
                (lambda () #f)
                (lambda (c) #f))
(uv-write! (vector-ref cli 0) (seeded-bytes 32 1) (lambda (err) #f))

;; THE GATE. close-dispatch frees on a LATER loop iteration than the
;; uv-close! call (handles.sls:984-996), so a post-close write issued at
;; close-ISSUE time can complete before the window under test opens.
(test-equal "gate: the closed reader reached 'closed before survivors are written to"
  '(satisfied fired closed)
  (let ((r (run-until/ticking loop
                              (lambda () (eq? 'closed (uv-handle-state (vector-ref peers 0))))
                              4000)))
    (list r closed-fired (uv-handle-state (vector-ref peers 0)))))

(define closed-deliveries-at-gate (collector-count (vector-ref cols 0)))

(test-assert "seed: the closing reader received the trigger write before closing"
  (positive? closed-deliveries-at-gate))

(let write-survivors ((i 1))
  (when (< i reader-count)
    (uv-write! (vector-ref cli i) (payload-for i) (lambda (err) #f))
    (write-survivors (+ i 1))))

(test-equal "every survivor received its full payload"
  'satisfied
  (run-until/ticking loop
                     (lambda ()
                       (let check ((i 1))
                         (cond ((>= i reader-count) #t)
                               ((< (collector-count (vector-ref cols i))
                                   (bytevector-length (payload-for i))) #f)
                               (else (check (+ i 1))))))
                     8000))

;; compare-bytes answers 'identical, (wrong-length n), or
;; (differs-at i expected actual) -- never #f, which SRFI-64 also produces
;; for a raise.
;; Accept order is NOT contractually uv-tcp-connect! call order, so peers[i]
;; is not guaranteed to be cli[i]'s connection. Asserting an index-keyed
;; correspondence would risk a spurious failure unrelated to any regression.
;; The property under test does not need that mapping: each survivor must
;; have received ONE COMPLETE, UNCORRUPTED payload, and all three distinct
;; payloads must have arrived EXACTLY ONCE across the three survivors. That
;; is strictly stronger against cross-wiring -- two survivors handed the same
;; bytes fails here, where three index-keyed rows could each still pass under
;; some permutations.
;;
;; 0 marks "matched no payload at all", which is what a corrupting mutation
;; produces; it cannot be confused with a success value, since the expected
;; list contains only 1, 2 and 3.
(define (which-payload bv)
  (let scan ((i 1))
    (cond ((> i 3) 0)
          ((eq? 'identical (compare-bytes (payload-for i) bv)) i)
          (else (scan (+ i 1))))))

(test-equal "each survivor received exactly one complete, uncorrupted payload"
  '(1 2 3)
  (list-sort < (map (lambda (i) (which-payload (collector-bytes (vector-ref cols i))))
                    '(1 2 3))))

(test-equal "the closed reader received nothing further"
  closed-deliveries-at-gate (collector-count (vector-ref cols 0)))

(uv-loop-teardown! loop)
(uv-loop-close! loop)

(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))

(test-end "flow")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
