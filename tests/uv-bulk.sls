#!r6rs
;;; Reference helpers for the bulk-move rows (issue #35) in test-native.sps
;;; and test-stream.sps.
;;;
;;; A bulk row times one of this binding's moves against libc's own
;;; memcpy or memset over the same bytes, a moment apart in the same process,
;;; and wants it within bulk-bar times of libc. The reference is libc, not a
;;; Scheme loop: a Scheme loop's speed depends on how Chez compiled it (about
;;; 30 ns a byte in safe code, about 1 ns at --optimize-level 3), while libc
;;; runs the same code in every build and under Memcheck, which replaces it
;;; for both sides alike. Measured (see .plans/bulk-copy-mutation-log.md):
;;; the helpers and the write verbs run at 0.95-1.10x libc on macOS and
;;; 0.97-1.05x in the Linux image, at optimize levels 0 and 3 and under
;;; Memcheck. A byte-at-a-time Scheme loop runs at 140x or more at the default
;;; level, 570x or more under Memcheck, and still 4.7x at optimize-level 3 in
;;; the Linux image, where glibc's memcpy is slowest. That last figure is why
;;; bulk-bar is 3, not higher.
;;;
;;; libc's memcpy and memset are bound directly here. They resolve only once
;;; a library that links libc is loaded, which is why this library reads
;;; shim-file first: referencing it runs (libuv private native)'s body, which
;;; loads libuv and the shim, and never runs ensure-native-loaded!, whose
;;; first run test-native.sps observes. The library itself keeps its copies
;;; in the shim (ADR-0002, amended for #35); a test may lean on the
;;; transitive symbol.
;;;
;;; NOT pure: importing this loads libuv and the shim.
(library (uv-bulk)
  (export bulk-bar bulk-verdict
          libc-available?
          libc-memcpy-to-foreign! libc-memcpy-from-foreign! libc-memset!
          libc-bytevector-address
          foreign->bytevector)
  (import (rnrs)
          (only (chezscheme)
                foreign-procedure foreign-entry? collect
                current-time time-difference time-second time-nanosecond)
          (only (libuv private native) shim-file))

  ;; The factor a move may take over libc before its row fails.
  (define bulk-bar 3)

  (define native-loaded (shim-file))

  (define libc-available?
    (and (foreign-entry? "memcpy") (foreign-entry? "memset")))

  (define (unavailable . args)
    (error 'uv-bulk "libc's memcpy/memset did not resolve"))

  ;; libc-memcpy-to-foreign! : uptr bytevector exact-nonnegative-integer -> uptr
  ;; Copies the first len bytes of bv to dst.
  (define libc-memcpy-to-foreign!
    (if libc-available?
        (foreign-procedure "memcpy" (uptr u8* size_t) uptr)
        unavailable))

  ;; libc-memcpy-from-foreign! : bytevector uptr exact-nonnegative-integer -> uptr
  (define libc-memcpy-from-foreign!
    (if libc-available?
        (foreign-procedure "memcpy" (u8* uptr size_t) uptr)
        unavailable))

  ;; libc-memset! : uptr int exact-nonnegative-integer -> uptr
  (define libc-memset!
    (if libc-available?
        (foreign-procedure "memset" (uptr int size_t) uptr)
        unavailable))

  ;; libc-bytevector-address : bytevector -> exact-nonnegative-integer
  ;; The address a u8* argument passes for bv, read back as memset's return
  ;; value (memset returns its first argument; a zero length writes nothing).
  (define libc-bytevector-address
    (if libc-available?
        (let ((memset-u8 (foreign-procedure "memset" (u8* int size_t) uptr)))
          (lambda (bv) (memset-u8 bv 0 0)))
        unavailable))

  ;; foreign->bytevector : uptr exact-nonnegative-integer -> bytevector
  ;; A fresh copy of len foreign bytes, made by libc rather than by the
  ;; binding under test.
  (define (foreign->bytevector addr len)
    (let ((bv (make-bytevector len)))
      (libc-memcpy-from-foreign! bv addr len)
      bv))

  ;; timed-ns : thunk -> exact-nonnegative-integer
  ;; One run, started from a fresh collection so a 4 MiB allocation cannot
  ;; trigger one mid-run. Over 20 copy-out verdicts that took the worst ratio
  ;; from 1.59x to 1.22x (bulk-copy mutation log).
  (define (timed-ns thunk)
    (collect)
    (let* ((t0 (current-time 'time-monotonic))
           (ignored (thunk))
           (d (time-difference (current-time 'time-monotonic) t0)))
      (+ (* (time-second d) 1000000000) (time-nanosecond d))))

  ;; least-ns : thunk thunk -> (values exact-nonnegative-integer
  ;;                                    exact-nonnegative-integer)
  ;; The least of seven timings of each, taken in pairs -- reference, then
  ;; move -- so a stretch of machine load lands on both sides alike instead
  ;; of on all of one side's runs, and the least discards a preemption
  ;; landing in any one run. The reference runs first in each pair, so both
  ;; find the pages already touched.
  (define (least-ns move reference)
    (let loop ((i 0) (best-move #f) (best-reference #f))
      (if (= i 7)
          (values best-move best-reference)
          (let* ((r (timed-ns reference))
                 (m (timed-ns move)))
            (loop (+ i 1)
                  (if (or (not best-move) (< m best-move)) m best-move)
                  (if (or (not best-reference) (< r best-reference)) r best-reference))))))

  ;; bulk-verdict : symbol exact-nonnegative-integer thunk thunk -> 'bulk | list
  ;; 'bulk is the only success value and no failure path yields it: a raise
  ;; becomes #f under SRFI-64, and a slow move answers both timings. Each
  ;; call prints its timings, since SRFI-64's FAIL line shows no values.
  (define (bulk-verdict name bytes move reference)
    (let-values (((move-ns reference-ns) (least-ns move reference)))
      (display "  [informational] ")
      (display name) (display " ") (display bytes) (display " B: ")
      (display move-ns) (display " ns vs libc ")
      (display reference-ns) (display " ns")
      (newline)
      (if (<= move-ns (* bulk-bar (max reference-ns 1)))
          'bulk
          (list 'move-ns move-ns 'libc-ns reference-ns)))))
