#!r6rs
;;; What a row keeps as evidence, shared by the suites: one debug counter by
;;; kind, and a printable account of whatever a guard caught.
;;;
;;; NOT pure: the counters come from (libuv private native). Nothing here
;;; reaches (libuv private handles), so tests/test-native.sps, whose process
;;; must keep the dispatcher slots empty, can import it. The pure suites
;;; (PURE_TESTS) cannot, and tests/test-require-threaded.sps keeps its own
;;; `describe` for that reason. tests/test-echo.sps keeps its own
;;; `live-count`, over a counter query renamed at the facade's boundary.
(library (uv-evidence)
  (export live-count describe)
  (import (rnrs)
          (only (chezscheme) display-condition)
          (only (libuv private native) live-counts))

  ;; live-count : symbol -> exact-integer
  ;; One debug counter by kind. Constant 0 against a prod shim.
  (define (live-count kind) (cdr (assq kind (live-counts))))

  ;; describe : object -> string
  ;; A raised object's message, for a row to carry as evidence. Total, so a
  ;; guard that calls it cannot raise in turn and abort the suite.
  (define (describe e)
    (guard (err (#t "<the raised object could not be printed>"))
      (call-with-string-output-port
       (lambda (p) (if (condition? e) (display-condition e p) (write e p)))))))
