#!r6rs
;;; SRFI-64 suite for rules about src/ that only a reading of the source can
;;; hold (#48's review).
;;;
;;; 1. A stream's data field has one writer. libuv's alloc callback, the
;;;    shim's chez_uv_alloc_cb, trusts data to point at the stream's uv_buf_t
;;;    descriptor, and hands libuv whatever it finds there as the buffer to
;;;    read into. A second writer could make that any memory at all: one that
;;;    pointed data at the handle itself passed every other suite, and libuv
;;;    was then told to read 4.3 GB into the handle. So uv-handle-set-data is
;;;    called from one place in src/.
;;;
;;; 2. Every entry native.sls takes from the shim is checked first. A shim
;;;    built from older sources must be refused by name, with
;;;    &uv-shim-unavailable, at whichever entry it lacks. So every
;;;    "chez_uv_..." name native.sls resolves goes through shim-procedure or
;;;    shim-entry, never a bare foreign-procedure or foreign-entry. The
;;;    fixtures in tests/test-shim-loading.sps can each reach one entry only:
;;;    with the other 46 resolved bare, every suite still passed.
;;;
;;; PURE: it reads source files and imports no native code (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (uv-source))

;; SRFI-64 sets no process exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; calls-of : symbol datum -> exact-nonnegative-integer
;; How many lists within X start with NAME: its call sites, since a
;; definition, an export or an import names it as a later element.
(define (calls-of name x)
  (if (pair? x)
      (+ (if (eq? (car x) name) 1 0)
         (let elements ((x x) (n 0))
           (if (pair? x)
               (elements (cdr x) (+ n (calls-of name (car x))))
               n)))
      0))

;; shim-name? : object -> boolean
(define (shim-name? x)
  (and (string? x)
       (>= (string-length x) 8)
       (string=? (substring x 0 8) "chez_uv_")))

;; unchecked-entries : datum -> (list-of string)
;; Every shim name within X that is not the entry of a (shim-procedure entry
;; ...) or (shim-entry entry) form.
(define (unchecked-entries x)
  (cond ((and (pair? x)
              (memq (car x) '(shim-procedure shim-entry))
              (pair? (cdr x))
              (shim-name? (cadr x)))
         (unchecked-in (cddr x)))
        ((pair? x) (unchecked-in x))
        ((shim-name? x) (list x))
        (else '())))

(define (unchecked-in xs)
  (let elements ((xs xs) (acc '()))
    (if (pair? xs)
        (elements (cdr xs) (append acc (unchecked-entries (car xs))))
        acc)))

(define (checked-entries x)
  (cond ((and (pair? x)
              (memq (car x) '(shim-procedure shim-entry))
              (pair? (cdr x))
              (shim-name? (cadr x)))
         1)
        ((pair? x)
         (let elements ((xs x) (n 0))
           (if (pair? xs) (elements (cdr xs) (+ n (checked-entries (car xs)))) n)))
        (else 0)))

(test-begin "source-rules")

;; --- the checkers, on seeded forms -------------------------------------------
;; A checker that never reported anything would pass every row on the real
;; tree below, so first it must see each of these.

(test-equal "a call counts, and so does a call nested in another"
  2 (calls-of 'f '(define (g) (f 1) (h (f 2)))))

(test-equal "a definition, an export and an import are not calls"
  0 (calls-of 'f '((define f (lambda () 1)) (export f g) (only (lib) f))))

(test-equal "an entry resolved bare is unchecked, whichever way it is resolved"
  '("chez_uv_zero" "chez_uv_alloc_cb")
  (unchecked-entries '((define z (foreign-procedure "chez_uv_zero" (uptr) void))
                       (define a (foreign-entry "chez_uv_alloc_cb")))))

(test-equal "an entry resolved through shim-procedure or shim-entry is checked"
  '(() 2)
  (let ((forms '((define z (shim-procedure "chez_uv_zero" (uptr size_t) void))
                 (define a (shim-entry "chez_uv_alloc_cb")))))
    (list (unchecked-entries forms) (checked-entries forms))))

;; --- the real tree ------------------------------------------------------------
;; Run from the repo root, as `make test` does.
(define libraries (src-libraries))

(define native-form
  (let ((e (assoc "src/libuv/private/native.sls" libraries)))
    (and e (cdr e))))

;; Live: an empty scan, from the wrong directory, would pass the rules.
(test-equal "the scan read native.sls and handles.sls"
  '(native handles)
  (list (if native-form 'native 'no-native)
        (if (assoc "src/libuv/private/handles.sls" libraries) 'handles 'no-handles)))

(test-equal "a stream's data has one writer: uv-handle-set-data is called once in src/, in handles.sls"
  '(("src/libuv/private/handles.sls" . 1))
  (filter (lambda (e) (positive? (cdr e)))
          (map (lambda (e) (cons (car e) (calls-of 'uv-handle-set-data (cdr e))))
               libraries)))

;; Live: native.sls resolves dozens of shim entries through the two forms.
(test-equal "the entry rule is live: native.sls resolves its shim entries through the checked forms"
  'many-checked
  (if (and native-form (> (checked-entries native-form) 40))
      'many-checked
      (list 'checked (and native-form (checked-entries native-form)))))

(test-equal "every shim entry native.sls resolves is checked first"
  '() (if native-form (unchecked-entries native-form) '(no-native-form)))

(test-end "source-rules")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
