#!r6rs
;;; The allocation meter the cost rows share: tests/test-native.sps,
;;; tests/test-addrinfo.sps, tests/test-c-string.sps and
;;; tests/test-process.sps. One copy, so a change to how it measures reaches
;;; every row that compares its figures.
;;;
;;; PURE: (rnrs) and named (chezscheme) procedures only, so the pure suites
;;; can use it (PURE_TESTS; make check-purity holds it).
(library (uv-meter)
  (export fewest-bytes)
  (import (rnrs)
          (only (chezscheme) bytes-allocated bytes-deallocated
                collect-request-handler void))

  ;; fewest-bytes : (-> any) -> exact-nonnegative-integer
  ;; The fewest bytes one call of CALL allocated, of 64 calls. The meter
  ;; reads (+ (bytes-allocated) (bytes-deallocated)) around each call with
  ;; the collector held off, so a collection inside a call cannot hide what
  ;; it allocated, and the fewest of 64 sheds the one-off costs a first call
  ;; pays (tests/test-callback-alloc.sps's meter).
  (define (fewest-bytes call)
    (let ((saved (collect-request-handler)))
      (dynamic-wind
       (lambda () (collect-request-handler void))
       (lambda ()
         (let run ((i 0) (fewest #f))
           (if (= i 64)
               fewest
               (let* ((before (+ (bytes-allocated) (bytes-deallocated)))
                      (ignored (call))
                      (after (+ (bytes-allocated) (bytes-deallocated))))
                 (run (+ i 1) (let ((b (- after before)))
                                (if fewest (min fewest b) b)))))))
       (lambda () (collect-request-handler saved))))))
