#!r6rs
;;; The C integer types a caller's number reaches libuv in, one predicate
;;; each.
;;;
;;; Chez's integer foreign argument types each accept -2^(N-1) .. 2^N-1 and
;;; keep the low N bits, so an int given 4294967295 reaches C as -1. At
;;; --optimize-level 3 they check nothing: a fixnum keeps its low bits and
;;; a bignum reaches C as bits of its address. And Chez's own refusal,
;;; raised inside an interrupt-free step, leaves interrupts disabled. So a
;;; caller's number is checked with one of these before the step. Each range
;;; is computed from foreign-sizeof here. Rule 14 of
;;; tests/test-source-rules.sps holds src/ to writing no bound out elsewhere,
;;; as a number or a power of two, and tests/test-c-types.sps holds each
;;; predicate's edges.
;;;
;;; Pure: no native code (PURE_TESTS).
(library (libuv private c-types)
  (export c-int? c-unsigned-int? c-u64? c-uptr? c-size?)
  (import (rnrs)
          ;; Ahead of (chezscheme), so a non-threaded Chez is refused by
          ;; name (tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme) foreign-sizeof))

  ;; bits : symbol -> exact-positive-integer
  (define (bits type) (* 8 (foreign-sizeof type)))

  (define int-max (- (expt 2 (- (bits 'int) 1)) 1))
  (define int-min (- -1 int-max))
  (define unsigned-int-max (- (expt 2 (bits 'unsigned-int)) 1))
  (define u64-max (- (expt 2 (bits 'unsigned-64)) 1))
  (define uptr-max (- (expt 2 (bits 'uptr)) 1))
  (define size-max (- (expt 2 (bits 'size_t)) 1))

  ;; within? : object exact-integer exact-integer -> boolean
  (define (within? x lo hi)
    (and (integer? x) (exact? x) (<= lo x hi)))

  ;; c-int? : object -> boolean
  (define (c-int? x) (within? x int-min int-max))

  ;; c-unsigned-int? : object -> boolean
  (define (c-unsigned-int? x) (within? x 0 unsigned-int-max))

  ;; c-u64? : object -> boolean
  ;; An unsigned 64-bit integer: uint64_t, libuv's timeouts.
  (define (c-u64? x) (within? x 0 u64-max))

  ;; c-uptr? : object -> boolean
  ;; A uintptr_t: an address, or a size as wide as one.
  (define (c-uptr? x) (within? x 0 uptr-max))

  ;; c-size? : object -> boolean
  ;; A size_t: a length or offset libuv or libc takes.
  (define (c-size? x) (within? x 0 size-max)))
