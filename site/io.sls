#!r6rs
;; NOT pure: reads and writes files. The imperative shell around the pure
;; (site render) pipeline -- this library owns the only filesystem access
;; the site generator makes.
(library (site io)
  (export read-site-inputs write-site page-file-name)
  (import (rnrs) (site pages) (site render) (site serializer))

  (define (slurp path)
    (call-with-input-file path
      (lambda (p)
        (let loop ((cs '()) (c (get-char p)))
          (if (eof-object? c) (list->string (reverse cs)) (loop (cons c cs) (get-char p)))))))

  ;; Every page, the home page included, is read from docs/.
  (define (source-path name) (string-append "docs/" name))

  ;; (site pages)'s `pages` is the single source of order AND file set --
  ;; read every source in that order, into (name . markdown-string) pairs.
  (define (read-site-inputs)
    (map (lambda (entry) (let ((name (car entry))) (cons name (slurp (source-path name)))))
         pages))

  ;; The file a page is written to: README.md, the home page, is written as
  ;; index.html. tests/site-check.sps holds every link to these names.
  (define (page-file-name name)
    (if (string=? name "README.md")
        "index.html"
        (string-append (substring name 0 (- (string-length name) 3)) ".html")))

  ;; `make site` reruns into a `build/site` that may already hold a
  ;; previous run's output, so every write must overwrite rather than fail
  ;; when the target already exists. (file-options no-fail), with no
  ;; `no-truncate`, both permits and truncates on an existing file:
  ;; a second, shorter write leaves no trailing bytes from the first.
  ;; Writing goes through a binary port and explicit `string->utf8` rather
  ;; than a textual port's transcoder: a transcoder can translate line
  ;; endings on the way to disk (native eol-style is CRLF on Windows),
  ;; which would make the shipped HTML depend on the host that built it.
  (define (write-site result out-dir)
    (for-each
      (lambda (pg)
        (let ((p (open-file-output-port
                   (string-append out-dir "/" (page-file-name (car pg)))
                   (file-options no-fail))))
          (put-bytevector p (string->utf8 (string-append "<!doctype html>\n" (sxml->html (cdr pg)))))
          (close-port p)))
      (site-result-pages result))))
