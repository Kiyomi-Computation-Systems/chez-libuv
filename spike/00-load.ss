;;; spike/00-load.ss — Q0: load libuv and call into it.
;;;
;;; Usage:
;;;   chez --script spike/00-load.ss /opt/homebrew/opt/libuv/lib/libuv.dylib
;;;
;;; Proves:
;;;   (a) the definition-order trap: what error a `foreign-procedure` raises
;;;       when it is evaluated BEFORE `load-shared-object` (AGENTS.md's named
;;;       trap; design spec §4 rule 3);
;;;   (b) `load-shared-object` + `foreign-procedure` reach `uv_version` and
;;;       `uv_version_string`;
;;;   (c) a `const char *` return bound as `uptr` can be copied byte-for-byte
;;;       into a Scheme string by hand, without binding the return as `string`
;;;       (ADR-0009 "copy at the boundary", applied to the smallest case).
;;;
;;; Every definition is at top level. Chez body syntax forbids a `define`
;;; following an expression inside a `let`/lambda body, and `foreign-procedure`
;;; resolves its C entry point when the defining expression is EVALUATED, so
;;; the load must be a top-level form that completes before any binding below.

(import (chezscheme))

(define lib-path
  (let ((args (command-line-arguments)))
    (if (null? args)
        (begin (display "usage: 00-load.ss <path-to-libuv.dylib>\n")
               (exit 2))
        (car args))))

;;; ---------------------------------------------------------------------------
;;; (a) The definition-order trap, demonstrated once, before any load.
;;;
;;; `eval` is used only so that the failure is catchable and the script can
;;; continue; a literal top-level `(define v (foreign-procedure ...))` here
;;; would abort the whole script with the same condition.
(display "--- (a) definition-order trap: foreign-procedure BEFORE load ---\n")
(display
 (call-with-string-output-port
  (lambda (port)
    (guard (e (#t (display "raised: " port)
                  (display-condition e port)
                  (newline port)))
      (let ((p (eval '(foreign-procedure "uv_version" () int)
                     (environment '(chezscheme)))))
        (display "NO ERROR RAISED -- got: " port)
        (write p port)
        (newline port))))))

;;; ---------------------------------------------------------------------------
;;; (b) Load, then bind. This is the only correct order.
(display "\n--- (b) load, then bind ---\n")

(load-shared-object lib-path)

;; Return type choice, recorded for FINDINGS: `int`. UV_VERSION_HEX is
;; (major<<16)|(minor<<8)|patch, so it never sets the sign bit for any 1.x
;; release and a signed 32-bit read is exact. `unsigned-int` is bound
;; alongside purely to show the two agree on this value.
(define uv-version           (foreign-procedure "uv_version" () int))
(define uv-version-unsigned  (foreign-procedure "uv_version" () unsigned-int))
(define uv-version-string    (foreign-procedure "uv_version_string" () uptr))
(define uv-loop-size         (foreign-procedure "uv_loop_size" () size_t))

;;; (c) Manual copy of a C string reached through a `uptr`. The return type is
;;; deliberately NOT bound as `string`: nothing here lets Chez decide the
;;; lifetime or the encoding for us.
(define (c-string->string addr)
  (if (= addr 0)
      #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))

(define ver  (uv-version))
(define uver (uv-version-unsigned))
(define vstr (c-string->string (uv-version-string)))

(printf "uv_version()          = ~d (#x~a)\n" ver (number->string ver 16))
(printf "uv_version() unsigned = ~d (#x~a)\n" uver (number->string uver 16))
(printf "decoded major.minor.patch = ~d.~d.~d\n"
        (bitwise-arithmetic-shift-right ver 16)
        (bitwise-and (bitwise-arithmetic-shift-right ver 8) #xFF)
        (bitwise-and ver #xFF))
(printf "uv_version_string()   = ~s\n" vstr)
(printf "uv_loop_size()        = ~d\n" (uv-loop-size))

;;; ---------------------------------------------------------------------------
;;; Assertions. Each expects a value only success can produce; the version
;;; numbers come from spike/probe (never transcribed from uv.h by hand).
(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual
          (if (equal? expected actual) "OK" "MISMATCH")))

(display "\n--- checks ---\n")
(check "uv_version() = #x013401" #x013401 ver)
(check "signed and unsigned agree" ver uver)
(check "uv_version_string() = 1.52.1" "1.52.1" vstr)
(check "version hex decodes to the string"
       vstr
       (format "~d.~d.~d"
               (bitwise-arithmetic-shift-right ver 16)
               (bitwise-and (bitwise-arithmetic-shift-right ver 8) #xFF)
               (bitwise-and ver #xFF)))

(define ok?
  (and (= ver #x013401) (= ver uver) (string=? vstr "1.52.1")))

(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
