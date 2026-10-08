#!r6rs
;;; What a row keeps as evidence, shared by the suites: one debug counter by
;;; kind, and a printable account of whatever a guard caught.
;;;
;;; NOT pure: the counters come from (libuv private native). Nothing here
;;; reaches (libuv private handles), so tests/test-native.sps, whose process
;;; must keep the dispatcher slots empty, can import it. The pure suites
;;; (PURE_TESTS) cannot; they import `describe` from the pure (uv-describe),
;;; which this library re-exports. tests/test-echo.sps keeps its own
;;; `live-count`, over a counter query renamed at the facade's boundary.
(library (uv-evidence)
  (export live-count describe print-actual-on-failure!)
  (import (rnrs)
          (srfi :64)
          ;; describe, re-exported: one copy for every suite.
          (uv-describe)
          (only (libuv private native) live-counts))

  ;; print-actual-on-failure! : test-runner -> unspecified
  ;; The simple runner prints only a failing row's title. A row that returns
  ;; its evidence when it fails needs that printed too: without it, a
  ;; one-off failure leaves nothing to diagnose (test-threading-stress's
  ;; careless pool, 2026-10-06).
  (define (print-actual-on-failure! runner)
    (let ((simple-end (test-runner-on-test-end runner)))
      (test-runner-on-test-end! runner
        (lambda (r)
          (simple-end r)
          (when (eq? (test-result-kind r) 'fail)
            (display "  actual: ")
            (write (test-result-ref r 'actual-value))
            (newline))))))

  ;; live-count : symbol -> exact-integer
  ;; One debug counter by kind. Constant 0 against a prod shim.
  (define (live-count kind) (cdr (assq kind (live-counts)))))
