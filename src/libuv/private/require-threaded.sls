#!r6rs
;;; (libuv private require-threaded): refuse a non-threaded Chez by name.
;;;
;;; The binding uses Chez's thread system (make-mutex, with-mutex, ...), which
;;; Chez builds only into threaded builds, so on a --nothreads Chez a library
;;; importing those names dies at import with a bare "missing import for
;;; make-mutex". This library raises a message naming the requirement
;;; instead. It raises from a macro, so the refusal comes while this library
;;; is being EXPANDED: before the library importing it goes on to its next
;;; import.
;;;
;;; Hence its one condition: it must be imported AHEAD of every (chezscheme)
;;; import. Chez processes a library's imports in order, and a thread
;;; primitive imported first still fails with the bare message (measured on a
;;; --nothreads Chez 10.4.1). tests/test-require-threaded.sps holds that order
;;; for every library in src/, and `make check-nothreads-docker` proves the
;;; message on a real --nothreads Chez. It exports nothing.
(library (libuv private require-threaded)
  (export)
  (import (rnrs) (only (chezscheme) threaded?))

  (define-syntax require-threaded-chez
    (lambda (x)
      (if (threaded?)
          #'(define threaded-chez-checked #t)
          (syntax-violation
           'chez-libuv
           "chez-libuv needs a threaded Chez Scheme, and (threaded?) is #f in this one. Chez builds threaded unless configured with --nothreads"
           x))))

  (require-threaded-chez))
