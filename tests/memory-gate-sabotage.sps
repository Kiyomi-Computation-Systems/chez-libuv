#!r6rs
;;; memory-gate-sabotage.sps -- a PLANTED memory defect. Not a suite.
;;;
;;; `make check-memory-gate` runs this program through `make test-memory` and
;;; requires the memory gate to FAIL on it, with the memory tool's own report
;;; of the planted defect in the output. A gate nobody has watched fail is a
;;; comment: from #14 (2026-08-30) the Linux gate handed Valgrind timeout(1)
;;; instead of Chez, and the macOS ASan preload had never reached Chez at all,
;;; and every run stayed green (ADR-0003's 2026-09-27 amendment).
;;;
;;; Deliberately NOT named tests/test-*.sps: that wildcard feeds TESTS and
;;; MEMORY_TESTS, and this program must never run as part of either gate.
;;;
;;; CHEZ_LIBUV_SABOTAGE picks the defect. Each one runs clean WITHOUT a memory
;;; tool -- check-memory-gate proves that first, by requiring exit 0 and the
;;; final "planted" line from a plain run -- so a red gate can only mean the
;;; tool saw the defect:
;;;
;;;   store-overrun  one byte past a 23-byte foreign block, written by a
;;;                  Scheme store (foreign-set!), the class of the binding's own
;;;                  copy loops. Valgrind sees it. ASan cannot: Chez's generated
;;;                  code is not instrumented, so only libc calls are checked.
;;;   libc-overrun   one byte past a 29-byte foreign block, written by libc's
;;;                  memset. Valgrind sees it, and so does ASan's memset
;;;                  interceptor, which makes it the macOS arm's witness.
;;;   leak           777 bytes allocated and never freed. Valgrind only; the
;;;                  macOS arm makes no leak claim (no LeakSanitizer on arm64).
;;;
;;; The sizes are sentinels. The tool's report names them, and nothing else in
;;; a run allocates blocks of exactly these sizes to overrun or lose.
(import (chezscheme))

(define mode (getenv "CHEZ_LIBUV_SABOTAGE"))

(define (say what)
  (display "memory-gate-sabotage: ")
  (display what)
  (display " ")
  (display mode)
  (newline)
  (flush-output-port (current-output-port)))

;; memset is not a foreign entry on either platform until libc is loaded
;; (measured: foreign-entry? is #f under both macOS and Debian).
(define (libc-memset)
  (let* ((mt (symbol->string (machine-type)))
         (n (string-length mt)))
    (load-shared-object
     (if (and (>= n 3) (string=? "osx" (substring mt (- n 3) n)))
         "libc.dylib"
         "libc.so.6")))
  (foreign-procedure "memset" (uptr int size_t) uptr))

(say "planting")
(cond
  ((equal? mode "store-overrun")
   (let ((p (foreign-alloc 23)))
     (foreign-set! 'unsigned-8 p 23 1)
     (foreign-free p)))
  ((equal? mode "libc-overrun")
   (let* ((memset (libc-memset))
          (p (foreign-alloc 29)))
     (memset p 0 30)
     (foreign-free p)))
  ((equal? mode "leak")
   (foreign-alloc 777))
  (else
   (display "memory-gate-sabotage: set CHEZ_LIBUV_SABOTAGE to store-overrun, libc-overrun or leak\n"
            (current-error-port))
   (exit 2)))
(say "planted")
(exit 0)
