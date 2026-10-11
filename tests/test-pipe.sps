#!r6rs
;;; SRFI-64 suite for (libuv pipe) — construction and lifecycle only:
;;; a pipe is unconnected until uv-spawn! consumes it, so everything a pipe
;;; DOES is covered by test-stream.sps (verb gating) and test-process.sps
;;; (stdio). NOT pure; never add to PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv pipe)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (uv-evidence) live-count)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)
(define registry-count-at-start (registry-count))

(test-begin "pipe")

;; --- construction --------------------------------------------------------
(define loop (make-uv-loop))
(define p (make-uv-pipe loop))

(test-assert "make-uv-pipe answers an open pipe handle"
  (and (uv-handle? p) (uv-pipe? p) (uv-handle-open? p)))
(test-assert "a pipe is not a tcp and a tcp predicate refuses it"
  (not (uv-tcp? p)))
(test-equal "pipe counter counts the construction" 1 (live-count 'pipe))
(test-assert "a fresh pipe is unconnected (spawn-consumption state)"
  (not (pipe-connected? p)))
(test-equal "the registry holds the pipe" (+ registry-count-at-start 2)
  (registry-count)) ;; loop entry + pipe entry

;; --- refusals ------------------------------------------------------------
(test-assert "make-uv-pipe refuses a non-loop"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-loop (uv-invalid-argument-reason e)))))
    (make-uv-pipe 42) #f))

;; --- explicit close ------------------------------------------------------
(define closed (list 'not-yet))
(uv-close! p (lambda () (collect) (set! closed 'closed)))
(test-equal "close drains through the loop"
  'satisfied (run-until loop (lambda () (eq? closed 'closed)) 64))
(test-equal "pipe counter returns to zero" 0 (live-count 'pipe))
(test-equal "closed state reads back" 'closed (uv-handle-state p))

;; --- teardown sweep covers an unclosed pipe ------------------------------
(define p2 (make-uv-pipe loop))
(test-equal "second pipe counted" 1 (live-count 'pipe))
(uv-loop-teardown! loop)
(test-equal "teardown swept the unclosed pipe" 0 (live-count 'pipe))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))

(collect)
(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))

(test-end "pipe")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
