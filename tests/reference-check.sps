#!r6rs
;;; `make check-reference` -- compare the authored API reference with the
;;; actual export clauses of every public library (src/libuv.sls and src/libuv/*.sls, not private/).
;;;
;;; This is the imperative shell around pure `(site reference)`: it owns file
;;; discovery and reading, but it never imports `(cmark gfm)` and never loads a
;;; shared object. Kept outside tests/test-*.sps because it asserts on the real
;;; source tree and real docs/reference.md rather than fixtures.
(import (rnrs)
        (only (chezscheme) directory-list)
        (site reference))

(define (die . parts)
  (for-each (lambda (part) (display part (current-error-port))) parts)
  (newline (current-error-port))
  (exit 1))

(define (string-ends-with? suffix s)
  (let ((ls (string-length s)) (lf (string-length suffix)))
    (and (>= ls lf)
         (string=? suffix (substring s (- ls lf) ls)))))

(define (slurp path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((chars '()) (c (get-char port)))
        (if (eof-object? c)
            (list->string (reverse chars))
            (loop (cons c chars) (get-char port)))))))

(define (public-source-files)
  (cons
   "src/libuv.sls"
   (map (lambda (name) (string-append "src/libuv/" name))
        (list-sort
         string<?
         (filter (lambda (name) (string-ends-with? ".sls" name))
                 (directory-list "src/libuv"))))))

(define (read-module-apis paths)
  (let loop ((rest paths) (apis '()) (problems '()))
    (if (null? rest)
        (values (reverse apis) (reverse problems))
        (let ((path (car rest)))
          (let-values (((name exports problem)
                        (library-datum->api
                         (call-with-input-file path read))))
            (if problem
                (loop (cdr rest) apis (cons (list path problem) problems))
                (loop (cdr rest) (cons (cons name exports) apis) problems)))))))

(define (unique-symbols xs)
  (let loop ((rest xs) (seen '()) (out '()))
    (cond ((null? rest) (reverse out))
          ((memq (car rest) seen) (loop (cdr rest) seen out))
          (else
           (loop (cdr rest) (cons (car rest) seen) (cons (car rest) out))))))

(unless (file-exists? "docs/reference.md")
  (die "check-reference: reference page missing: docs/reference.md"))

(let-values (((module-apis source-problems)
              (read-module-apis (public-source-files))))
  (unless (null? source-problems)
    (die "check-reference: unsupported or malformed source exports="
         source-problems))
  (let* ((analysis (markdown->reference-analysis (slurp "docs/reference.md")))
         (diagnostics (reference-diagnostics module-apis analysis)))
    (unless (null? diagnostics)
      (for-each
       (lambda (diagnostic)
         (display "check-reference: " (current-error-port))
         (display (car diagnostic) (current-error-port))
         (display "=" (current-error-port))
         (write (cdr diagnostic) (current-error-port))
         (newline (current-error-port)))
       diagnostics)
      (exit 1))
    (let ((binding-count
           (length (unique-symbols (apply append (map cdr module-apis))))))
      (display "check-reference: COMPLETE -- ")
      (display (length module-apis))
      (display " modules, ")
      (display binding-count)
      (display " unique bindings")
      (newline))))
