#!r6rs
;;; Caller strings as the C strings libuv reads.
;;;
;;; A string the caller can still reach is read once, here, into bytes the
;;; caller cannot reach, and only those bytes cross to C. The native wrappers
;;; check with c-string? that what crosses is one C string. uv-spawn! reads
;;; its strings with read-utf8 inside its own read step, and checks them with
;;; nul-free? after it (process.sls), where c-string-bytes reads and checks
;;; at once.
(library (libuv private c-string)
  (export c-string-bytes c-string? read-utf8 nul-free?)
  (import (rnrs)
          ;; Ahead of (chezscheme), so a non-threaded Chez is refused by
          ;; name (tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme) disable-interrupts enable-interrupts)
          (libuv private conditions))

  ;; read-utf8 : object -> (or bytevector #f)
  ;; S's UTF-8, or #f when S is no string. S is read once, into a private
  ;; copy, and the copy is encoded, never S.
  ;;
  ;; Chez's string->utf8 counts a string's bytes, allocates, and then
  ;; encodes, and an engine's handler or another thread that widens S in
  ;; between makes it write past what it allocated. Its string-copy reads
  ;; S's length before it copies, and a handler that truncates S and
  ;; collects in between makes it read past S. So the copy is taken with
  ;; interrupts disabled, which runs no handler and no collection inside it.
  ;; A copy is fixed-width, so another thread cannot make it overrun.
  ;; tests/test-addrinfo.sps's node sweeps and cross-thread race hold each of
  ;; these through c-string-bytes (measured on Chez 10.4.1);
  ;; tests/test-address.sps's widened sweeps hold the copy against a widening
  ;; through the address verbs, and test-process.sps's changing-data sweeps
  ;; and narrower race through uv-spawn!.
  ;;
  ;; Interrupts go off and on as a bare pair, which allocates nothing.
  ;; with-interrupts-disabled, a dynamic-wind, would cost a 9-byte address
  ;; 64 B more a call, and each string uv-spawn! reads inside its own
  ;; interrupt-free step 64 B more too. A raise between the two would leave
  ;; interrupts off for good, so string-copy is handed only a string, which
  ;; it copies without raising (tests/test-c-string.sps).
  (define (read-utf8 s)
    (and (string? s)
         (begin
           (disable-interrupts)
           (let ((copy (string-copy s)))
             (enable-interrupts)
             (string->utf8 copy)))))

  ;; nul-free? : bytevector exact-nonnegative-integer -> boolean
  ;; Whether BV's first END bytes hold no NUL, the byte C reads as a
  ;; string's end. UTF-8 encodes NUL, and nothing else, as a zero byte, so a
  ;; string's UTF-8 is free of NUL exactly when the string is.
  (define (nul-free? bv end)
    (let scan ((i 0))
      (cond ((= i end) #t)
            ((zero? (bytevector-u8-ref bv i)) #f)
            (else (scan (+ i 1))))))

  ;; c-string-bytes : string symbol symbol -> bytevector
  ;; S's UTF-8 and a terminating NUL, read once (read-utf8), or a refusal
  ;; naming WHO with REASON when S holds a NUL of its own, which C would read
  ;; as the end of the string. Its callers refuse a non-string themselves,
  ;; each with its own reason; one that reaches here is the binding's own
  ;; fault, refused under this procedure's name. Unchecked, it would be
  ;; read through as a bytevector at --optimize-level 3
  ;; (tests/test-c-string.sps).
  (define (c-string-bytes s who reason)
    (let ((utf8 (read-utf8 s)))
      (unless utf8
        (raise (make-uv-invalid-argument 'c-string-bytes 'not-a-string)))
      (let ((n (bytevector-length utf8)))
        (unless (nul-free? utf8 n)
          (raise (make-uv-invalid-argument who reason)))
        (let ((bytes (make-bytevector (+ n 1) 0)))
          (bytevector-copy! utf8 0 bytes 0 n)
          bytes))))

  ;; c-string? : object -> boolean
  ;; Whether X is one C string: a bytevector whose only NUL is its last byte.
  (define (c-string? x)
    (and (bytevector? x)
         (let ((last (- (bytevector-length x) 1)))
           (and (>= last 0)
                (zero? (bytevector-u8-ref x last))
                (nul-free? x last))))))
