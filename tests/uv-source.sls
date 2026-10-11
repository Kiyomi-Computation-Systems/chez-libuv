#!r6rs
;;; This repo's own sources, read as data, for the suites that hold rules
;;; only a reading of the source can hold (tests/test-require-threaded.sps,
;;; tests/test-source-rules.sps, tests/test-sweep.sps,
;;; tests/test-seed-gates.sps, tests/test-unread-assignments.sps).
;;;
;;; PURE: it reads files and imports no library of this repo, so pure suites
;;; (PURE_TESTS) can use it.
(library (uv-source)
  (export sls-file? sls-files src-libraries library-exports
          source-file? test-sources read-forms)
  (import (rnrs)
          (only (chezscheme) directory-list file-directory?))

  ;; sls-file? : string -> boolean
  ;; A library source: named *.sls, and not a dotfile. Editors leave dotfiles
  ;; with the same suffix beside the sources (an Emacs lock file is a dangling
  ;; symlink named .#native.sls), and reading one raises and aborts a whole
  ;; suite.
  (define (sls-file? name)
    (let ((n (string-length name)))
      (and (> n 4)
           (not (char=? (string-ref name 0) #\.))
           (string=? (substring name (- n 4) n) ".sls"))))

  ;; sls-files : string -> (list-of string)
  ;; Every .sls file under dir, depth first, in a stable order.
  (define (sls-files dir)
    (apply append
           (map (lambda (name)
                  (let ((path (string-append dir "/" name)))
                    (cond ((file-directory? path) (sls-files path))
                          ((sls-file? name) (list path))
                          (else '()))))
                (list-sort string<? (directory-list dir)))))

  ;; source-file? : string -> boolean
  ;; A program or library source: named *.sps or *.sls, and not a dotfile.
  ;; A name no longer than its suffix, such as the scratch directory
  ;; tests/tmp, is not one, and is not read past.
  (define (source-file? name)
    (let ((len (string-length name)))
      (and (> len 4)
           (not (char=? (string-ref name 0) #\.))
           (member (substring name (- len 4) len) '(".sps" ".sls"))
           #t)))

  ;; test-sources : -> (list-of string)
  ;; Every source directly under tests/, sorted, read from the repo root.
  (define (test-sources)
    (map (lambda (n) (string-append "tests/" n))
         (list-sort string<? (filter source-file? (directory-list "tests")))))

  ;; read-forms : string -> (list-of datum)
  ;; Every datum in the file at PATH, in order.
  (define (read-forms path)
    (call-with-input-file path
      (lambda (port)
        (let loop ((forms '()))
          (let ((form (read port)))
            (if (eof-object? form)
                (reverse forms)
                (loop (cons form forms))))))))

  ;; library-exports : datum -> (list-of datum)
  ;; What a library form's export form names: '() for a datum that is not
  ;; a library form with its export form third.
  (define (library-exports lib)
    (if (and (list? lib) (>= (length lib) 3) (pair? (caddr lib))
             (eq? (car (caddr lib)) 'export))
        (cdr (caddr lib))
        '()))

  ;; src-libraries : -> (list-of (string . datum))
  ;; Each library under src/ as (path . its library form), read from the repo
  ;; root, where `make test` runs the suites.
  (define (src-libraries)
    (map (lambda (path) (cons path (call-with-input-file path read)))
         (sls-files "src"))))
