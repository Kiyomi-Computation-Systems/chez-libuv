#!r6rs
;;; A raised object's message, for a row to carry as evidence: one copy for
;;; every suite and test library. tests/uv-evidence.sls exports it too.
;;;
;;; PURE: (rnrs) and display-condition only, so the pure suites can use it
;;; (PURE_TESTS; make check-purity holds it).
(library (uv-describe)
  (export describe)
  (import (rnrs)
          (only (chezscheme) display-condition))

  ;; describe : object -> string
  ;; Total, so a guard that calls it cannot raise in turn and abort the
  ;; suite.
  (define (describe e)
    (guard (err (#t "<the raised object could not be printed>"))
      (call-with-string-output-port
       (lambda (p) (if (condition? e) (display-condition e p) (write e p)))))))
