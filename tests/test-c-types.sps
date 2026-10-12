#!r6rs
;;; SRFI-64 suite for (libuv private c-types): each C integer type's
;;; predicate, at the edges of its range.
;;;
;;; Chez's integer foreign argument types each accept -2^(N-1) .. 2^N-1 and
;;; wrap at optimize level 0, so an int given 4294967295 reaches C as -1;
;;; at level 3 they check nothing. So a caller's number is checked against
;;; its C type here first. The predicates take their ranges from
;;; foreign-sizeof; the edges below are written out, so a range computed
;;; wrongly, such as the unsigned range for a signed type, fails its row.
;;;
;;; PURE: (libuv private c-types) loads no native code (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (libuv private c-types)
        (only (chezscheme) greatest-fixnum))

;; SRFI-64 sets no exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The rows return
;; their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "c-types")

;; verdicts : procedure (list-of object) -> (list-of symbol)
;; 'in or 'out for each of XS, by PRED. A predicate that raised would make
;; the row's actual #f, which no expected value here is.
(define (verdicts pred xs)
  (map (lambda (x) (if (pred x) 'in 'out)) xs))

;; edges : exact-integer exact-integer -> (list-of exact-integer)
(define (edges lo hi) (list (- lo 1) lo hi (+ hi 1)))

(define non-integers (list 1.0 1/2 "1" #f 'one))

(test-equal "c-int? holds a C int: -2^31 to 2^31-1, and nothing past either end"
  '(out in in out)
  (verdicts c-int? (edges -2147483648 2147483647)))

(test-equal "c-unsigned-int? holds a C unsigned int: 0 to 2^32-1, and nothing past either end"
  '(out in in out)
  (verdicts c-unsigned-int? (edges 0 4294967295)))

(test-equal "c-u64? holds a 64-bit unsigned integer: 0 to 2^64-1, and nothing past either end"
  '(out in in out)
  (verdicts c-u64? (edges 0 18446744073709551615)))

(test-equal "c-uptr? holds an address: 0 to 2^64-1 on a 64-bit platform, and nothing past either end"
  '(out in in out)
  (verdicts c-uptr? (edges 0 18446744073709551615)))

(test-equal "c-size? holds a size_t: 0 to 2^64-1 on a 64-bit platform, and nothing past either end"
  '(out in in out)
  (verdicts c-size? (edges 0 18446744073709551615)))

;; alloc-block takes a positive fixnum, and passes it on as a size_t.
(test-equal "every non-negative fixnum is a size_t"
  '(in in)
  (verdicts c-size? (list 0 (greatest-fixnum))))

(test-equal "no predicate holds a number that is not an exact integer, or anything else"
  '((out out out out out) (out out out out out) (out out out out out)
    (out out out out out) (out out out out out))
  (map (lambda (pred) (verdicts pred non-integers))
       (list c-int? c-unsigned-int? c-u64? c-uptr? c-size?)))

(test-end "c-types")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
