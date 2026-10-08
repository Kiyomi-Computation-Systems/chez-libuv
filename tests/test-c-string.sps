#!r6rs
;;; SRFI-64 suite for (libuv private c-string): read-utf8 and nul-free?, the
;;; copy and the NUL scan that uv-spawn! and c-string-bytes share (#64 item
;;; 4); c-string?; and what c-string-bytes costs. tests/test-addrinfo.sps's
;;; node sweeps and race hold the copy against a string that changes, and
;;; tests/test-address.sps and tests/test-native.sps hold the address verbs'
;;; use of these.
;;;
;;; Pure: the library loads no native code, and make check-purity runs this
;;; suite with the shim poisoned (PURE_TESTS). So a change that breaks these
;;; procedures fails rows here by name even when it stops native.sls
;;; working: a c-string? that refuses well-formed names makes every constant
;;; unavailable at the first ensure-native-loaded!, before most of the native
;;; suites' rows run (#72's lookup-constant checks each name with it).
(import (rnrs)
        (srfi :64)
        (libuv private c-string)
        (libuv private conditions)
        ;; The interrupt pair checks that read-utf8 leaves interrupts
        ;; enabled; the meter and describe are pure.
        (only (chezscheme) disable-interrupts enable-interrupts)
        (uv-meter)
        (uv-describe))

;; SRFI-64 sets no exit status; the runner's fail count drives it
;; (AGENTS.md).
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

(test-begin "c-string")

;; --- read-utf8 --------------------------------------------------------------
;; It reads a caller's string once, into a copy taken with interrupts
;; disabled, and encodes the copy. uv-spawn! reads its strings with it inside
;; its own read step; c-string-bytes reads with it and then scans.
(test-equal "read-utf8 answers a string's UTF-8, and #f for anything but a string"
  (list (u8-list->bytevector '(120 206 187)) (u8-list->bytevector '()) #f #f #f)
  (list (read-utf8 "x\x3bb;") (read-utf8 "") (read-utf8 'x) (read-utf8 #f)
        (read-utf8 (string->utf8 "x"))))

;; undo-disables! : -> exact-nonnegative-integer
;; How many interrupt disables were outstanding, each now undone:
;; enable-interrupts answers the disable count it leaves.
(define (undo-disables!)
  (let undo ((n 0))
    (if (zero? (begin (disable-interrupts) (enable-interrupts)))
        n
        (begin (enable-interrupts) (undo (+ n 1))))))

;; read-utf8 turns interrupts off and on as a bare pair, which a raise
;; between the two would leave off for good, so it hands string-copy only a
;; string. The row undoes any disable left outstanding, so that a read-utf8
;; which leaves one fails here, rather than stalling every engine after it.
(test-equal "read-utf8 leaves interrupts enabled, given a string or anything else"
  '((answered #f) 0)
  (let* ((answer (guard (e (#t (list 'raised (describe e))))
                   (read-utf8 "abc")
                   (list 'answered (read-utf8 'not-a-string))))
         (left (undo-disables!)))
    (list answer left)))

;; --- nul-free? and c-string? ------------------------------------------------
(test-equal "nul-free? finds a NUL anywhere in the first END bytes, and looks no further"
  '(#t #f #f #f #t #t)
  (list (nul-free? (u8-list->bytevector '(1 2 3)) 3)
        (nul-free? (u8-list->bytevector '(0 2 3)) 3)
        (nul-free? (u8-list->bytevector '(1 0 3)) 3)
        (nul-free? (u8-list->bytevector '(1 2 0)) 3)
        (nul-free? (u8-list->bytevector '(1 2 0)) 2)
        (nul-free? (u8-list->bytevector '()) 0)))

;; One C string is a bytevector whose only NUL is its last byte: libuv reads
;; up to the first NUL, so any other would end the string early, and without
;; one it would read past the bytevector.
(test-equal "c-string? accepts a bytevector whose only NUL is its last byte, and nothing else"
  '(#t #t #f #f #f #f #f)
  (list (c-string? (u8-list->bytevector '(97 0)))
        (c-string? (u8-list->bytevector '(0)))
        (c-string? (u8-list->bytevector '(97)))
        (c-string? (u8-list->bytevector '()))
        (c-string? (u8-list->bytevector '(0 97 0)))
        (c-string? (u8-list->bytevector '(97 0 0)))
        (c-string? "a")))

;; --- c-string-bytes ---------------------------------------------------------
(test-equal "c-string-bytes answers a string's UTF-8 and one NUL, and refuses a NUL of its own, naming its caller and why"
  (list (u8-list->bytevector '(120 206 187 0))
        (u8-list->bytevector '(0))
        '(refused test-who test-reason)
        '(refused test-who test-reason))
  (map (lambda (s)
         (guard (e ((uv-invalid-argument? e)
                    (list 'refused (uv-invalid-argument-who e)
                          (uv-invalid-argument-reason e)))
                   (#t (list 'raised (describe e))))
           (c-string-bytes s 'test-who 'test-reason)))
       (list "x\x3bb;" "" "a\x0;b" "ab\x0;")))

;; Its callers refuse a non-string themselves, each for its own reason, so
;; one reaching c-string-bytes is the binding's own fault: refused under
;; c-string-bytes's name, never its caller's, and never read through as a
;; bytevector, as #f was at --optimize-level 3.
(test-equal "c-string-bytes refuses anything but a string under its own name, not its caller's"
  '((refused c-string-bytes not-a-string)
    (refused c-string-bytes not-a-string)
    (refused c-string-bytes not-a-string))
  (map (lambda (x)
         (guard (e ((uv-invalid-argument? e)
                    (list 'refused (uv-invalid-argument-who e)
                          (uv-invalid-argument-reason e)))
                   (#t (list 'raised (describe e))))
           (c-string-bytes x 'test-who 'test-reason)
           'not-refused))
       (list 'x #f (u8-list->bytevector '(120)))))

;; c-string-bytes took its copy inside with-interrupts-disabled, a
;; dynamic-wind, and paid 64 B a call for it: 176 B for "127.0.0.1". Its
;; copy now takes a bare interrupt pair (read-utf8), so it allocates what
;; the same three objects cost made directly: the copy, the copy's UTF-8
;; and the answer. uv-spawn! reads each of its strings with read-utf8 too,
;; inside its own interrupt-free step, where a dynamic-wind nested there
;; would cost the same 64 B a string; main's read-string took no fence of
;; its own. tests/uv-meter.sls has the meter; the second element shows it
;; sees an allocation.

(test-equal "c-string-bytes allocates its copy, the copy's UTF-8 and its answer, and nothing more"
  '(0 meter-live)
  (let* ((s "127.0.0.1")
         (made (fewest-bytes
                (lambda ()
                  (let ((utf8 (string->utf8 (string-copy s))))
                    (make-bytevector (+ (bytevector-length utf8) 1) 0))))))
    (list (- (fewest-bytes (lambda () (c-string-bytes s 'test-cost 'contains-nul)))
             made)
          (if (positive? made) 'meter-live 'meter-blind))))

(test-end "c-string")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
