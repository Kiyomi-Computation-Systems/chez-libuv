#!r6rs
;;; Caller strings as the C strings libuv reads.
;;;
;;; A string the caller can still reach is read once, here, into bytes the
;;; caller cannot reach, and only those bytes cross to C. The native wrappers
;;; check with c-string? that what crosses is one C string.
(library (libuv private c-string)
  (export c-string-bytes c-string?)
  (import (rnrs)
          ;; Ahead of (chezscheme) (#41; tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme) with-interrupts-disabled)
          (libuv private conditions))

  ;; c-string-bytes : string symbol symbol -> bytevector
  ;; S's UTF-8 and a terminating NUL, or a refusal naming WHO with REASON
  ;; when S holds a NUL of its own, which C would read as the end of the
  ;; string.
  ;;
  ;; Both steps run on a private copy of S, never on S. Chez's string->utf8
  ;; counts a string's bytes, allocates, and then encodes, and an engine's
  ;; handler or another thread that widens S in between makes it write past
  ;; what it allocated. Its string-copy reads S's length before it copies,
  ;; and a handler that truncates S and collects in between makes it read
  ;; past S. So the copy is taken with interrupts disabled, which runs no
  ;; handler and no collection inside it. A copy is fixed-width, so another
  ;; thread cannot make it overrun. tests/test-addrinfo.sps's node sweeps
  ;; and cross-thread race hold each of these (measured on Chez 10.4.1);
  ;; tests/test-address.sps's widened sweeps hold the copy against a widening
  ;; through the address verbs.
  (define (c-string-bytes s who reason)
    (let* ((utf8 (string->utf8 (with-interrupts-disabled (string-copy s))))
           (n (bytevector-length utf8))
           (bytes (make-bytevector (+ n 1) 0)))
      (bytevector-copy! utf8 0 bytes 0 n)
      (let scan ((i 0))
        (cond ((= i n) bytes)
              ((zero? (bytevector-u8-ref bytes i))
               (raise (make-uv-invalid-argument who reason)))
              (else (scan (+ i 1)))))))

  ;; c-string? : object -> boolean
  ;; Whether X is one C string: a bytevector whose only NUL is its last byte.
  (define (c-string? x)
    (and (bytevector? x)
         (let ((last (- (bytevector-length x) 1)))
           (and (>= last 0)
                (let scan ((i 0))
                  (cond ((= i last) (zero? (bytevector-u8-ref x i)))
                        ((zero? (bytevector-u8-ref x i)) #f)
                        (else (scan (+ i 1))))))))))
