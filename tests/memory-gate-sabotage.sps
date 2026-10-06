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
;;;   shim-overrun   one byte past a 19-byte foreign block, written by the
;;;                  binding's own bulk copy: copy-in!, which is one memcpy
;;;                  in src/libuv-shim.c (chez_uv_copy_in). Valgrind sees it.
;;;                  ASan sees it only because that memcpy ends in libc's,
;;;                  which ASan interposes; a copy that bypassed libc would
;;;                  be as invisible to it as a Scheme store. The only mode
;;;                  that loads the binding, at run time, so that the others
;;;                  stay the programs their reports were measured on.
;;;   leak           777 bytes allocated and never freed. Valgrind only; the
;;;                  macOS arm makes no leak claim (no LeakSanitizer on arm64).
;;;   possible-leak  555 bytes whose only reference is an interior pointer,
;;;                  kept as raw bytes in a live bytevector. Memcheck scans
;;;                  the Scheme heap, finds the pointer, and counts the block
;;;                  "possibly lost". Not a defect the gate must catch: it
;;;                  checks that the gate never fails on a leak kind it does
;;;                  not print. Linux only.
;;;
;;; The sizes are sentinels. The tool's report names them, and nothing else in
;;; a run allocates blocks of exactly these sizes to overrun or lose.
(import (chezscheme))

(define mode (getenv "CHEZ_LIBUV_SABOTAGE"))

;; possible-leak's pointer lives here. The final keep-live holds the
;; bytevector, and so the pointer's bytes, until the program exits.
(define interior-pointer-holder (make-bytevector 16 0))

(define (say what)
  (display "memory-gate-sabotage: ")
  (display what)
  (display " ")
  (display mode)
  (newline)
  (flush-output-port (current-output-port)))

;; memset is not a foreign entry until a C library is loaded (measured on
;; macOS and Debian), and each platform names that library differently. So
;; rather than guess the name from (machine-type), try each candidate until
;; memset resolves. If none does, say so and exit 4: a plain run that fails
;; for this reason has to read as "no C library found", not as a sabotage
;; that went wrong.
(define libc-candidates
  '("libc.so.6" "libc.dylib" "libc.so.7" "libc.so" "msvcrt.dll"))

(define (libc-memset)
  (let try ((names libc-candidates))
    (cond
      ((foreign-entry? "memset")
       (foreign-procedure "memset" (uptr int size_t) uptr))
      ((null? names)
       (let ((err (current-error-port)))
         (display "memory-gate-sabotage: no C library providing memset loaded; tried " err)
         (write libc-candidates err)
         (newline err))
       (exit 4))
      (else
       (guard (e (#t #f)) (load-shared-object (car names)))
       (try (cdr names))))))

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
  ((equal? mode "shim-overrun")
   (let* ((native (environment '(libuv private native)))
          (alloc-zeroed (eval 'alloc-zeroed native))
          (copy-in! (eval 'copy-in! native))
          (free! (eval 'free! native))
          (p (alloc-zeroed 19)))
     (copy-in! p (make-bytevector 20 1) 0 20)
     (free! p)))
  ((equal? mode "leak")
   (foreign-alloc 777))
  ((equal? mode "possible-leak")
   (let ((p (foreign-alloc 555)))
     (bytevector-uint-set! interior-pointer-holder 8 (+ p 8)
                           (native-endianness) (foreign-sizeof 'uptr))))
  (else
   (display "memory-gate-sabotage: set CHEZ_LIBUV_SABOTAGE to store-overrun, libc-overrun, shim-overrun, leak or possible-leak\n"
            (current-error-port))
   (exit 2)))
(say "planted")
(keep-live interior-pointer-holder)
(exit 0)
