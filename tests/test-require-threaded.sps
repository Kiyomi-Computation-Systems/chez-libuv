#!r6rs
;;; SRFI-64 suite for #41: chez-libuv needs a threaded Chez, and must refuse
;;; any other by name.
;;;
;;; Chez builds make-mutex, with-mutex and the rest of its thread system only
;;; into threaded builds, so on a --nothreads Chez a library importing them
;;; dies at import with "missing import for make-mutex". The refusal
;;; (libuv private require-threaded) raises a readable message instead, while
;;; it is being expanded -- which only helps if it is expanded first: Chez
;;; processes a library's imports in order, and a (chezscheme) import listed
;;; ahead of the refusal still fails with the old message (measured on a
;;; --nothreads 10.4.1). So every library in src/ that imports from
;;; (chezscheme) must import (libuv private require-threaded) before it. This
;;; suite reads each library's import form and holds that order; `make
;;; check-nothreads-docker` proves the refusal itself on a --nothreads Chez.
;;;
;;; PURE: it reads source files and imports no native code (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (only (chezscheme) directory-list file-directory?))

;; SRFI-64 sets no process exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

(define guard-library '(libuv private require-threaded))
(define thread-libraries '((chezscheme) (scheme)))

;; spec-library : import-spec -> library-reference
;; The library an import spec draws on, seen through only / except / prefix /
;; rename / for and the (library ...) escape.
(define (spec-library spec)
  (if (and (pair? spec)
           (memq (car spec) '(only except prefix rename for library))
           (pair? (cdr spec))
           (pair? (cadr spec)))
      (spec-library (cadr spec))
      spec))

;; library-name : library-reference -> (list-of symbol)
;; The reference without its optional trailing version: (chezscheme (10)).
(define (library-name ref)
  (if (or (not (pair? ref)) (pair? (car ref)))
      '()
      (cons (car ref) (library-name (cdr ref)))))

;; import-order : (list-of import-spec) -> symbol
;; 'ordered when the refusal comes before the first (chezscheme) import,
;; 'unguarded when a (chezscheme) import comes first or alone, and
;; 'no-chezscheme when there is nothing to guard.
(define (import-order specs)
  (let scan ((specs specs) (guarded? #f))
    (if (null? specs)
        'no-chezscheme
        (let ((name (library-name (spec-library (car specs)))))
          (cond
            ((equal? name guard-library) (scan (cdr specs) #t))
            ((member name thread-libraries) (if guarded? 'ordered 'unguarded))
            (else (scan (cdr specs) guarded?)))))))

(define (sls-file? name)
  (let ((n (string-length name)))
    (and (> n 4) (string=? (substring name (- n 4) n) ".sls"))))

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

(define (library-form? form)
  (and (list? form)
       (>= (length form) 4)
       (eq? (car form) 'library)
       (pair? (cadddr form))
       (eq? (car (cadddr form)) 'import)))

;; verdict : datum -> symbol
;; import-order of a file's library form, or 'not-a-library.
(define (verdict form)
  (if (library-form? form)
      (import-order (cdr (cadddr form)))
      'not-a-library))

(define (form-name form)
  (and (library-form? form) (cadr form)))

(test-begin "require-threaded")

;; --- the checker, on seeded import forms ------------------------------------
;; A checker that never reported anything would pass every row on the real
;; tree below, so first it must see each of these.

(test-equal "a (chezscheme) import with nothing before it is unguarded"
  'unguarded
  (import-order '((rnrs) (only (chezscheme) make-mutex))))

(test-equal "the refusal listed AFTER the (chezscheme) import does not guard it"
  'unguarded
  (import-order '((rnrs)
                  (only (chezscheme) make-mutex)
                  (libuv private require-threaded))))

(test-equal "the refusal listed before the (chezscheme) import guards it"
  'ordered
  (import-order '((rnrs)
                  (libuv private require-threaded)
                  (only (chezscheme) make-mutex))))

(test-equal "a library importing nothing from (chezscheme) needs no guard"
  'no-chezscheme
  (import-order '((rnrs) (libuv private conditions))))

(test-equal "(scheme) is (chezscheme) under its other name"
  'unguarded
  (import-order '((rnrs) (scheme))))

(test-equal "a versioned reference is the same library"
  'unguarded
  (import-order '((chezscheme (10)))))

(test-equal "wrapped import sets are seen through"
  '(unguarded unguarded unguarded unguarded unguarded)
  (map (lambda (spec) (import-order (list spec)))
       '((prefix (chezscheme) c:)
         (rename (only (chezscheme) sleep) (sleep nap))
         (except (chezscheme) sleep)
         (for (chezscheme) run expand)
         (library (chezscheme)))))

(test-equal "a wrapped refusal still guards"
  'ordered
  (import-order '((only (libuv private require-threaded)) (chezscheme))))

;; --- the real tree ------------------------------------------------------------
;; Run from the repo root, as `make test` does.

(define libraries                      ; ((path . form) ...)
  (map (lambda (path) (cons path (call-with-input-file path read)))
       (sls-files "src")))

(define library-names (map (lambda (e) (form-name (cdr e))) libraries))

;; Live: a scan rooted anywhere narrower than src/ (src/libuv, say, which still
;; holds private/) would miss the facade and pass on what it did read.
(test-equal "the scan read the whole tree: (libuv) and (libuv private native)"
  'both-read
  (if (and (member '(libuv) library-names)
           (member '(libuv private native) library-names))
      'both-read
      'missed))

(test-equal "src/ defines (libuv private require-threaded)"
  'defined
  (if (member guard-library library-names) 'defined 'absent))

;; Every library the order rule covers: those importing from (chezscheme),
;; except the refusal itself, which must.
(define covered
  (filter (lambda (e)
            (and (not (equal? (form-name (cdr e)) guard-library))
                 (not (eq? (verdict (cdr e)) 'no-chezscheme))))
          libraries))

;; Live: the rows below exist only for covered libraries, so an empty scan
;; (the wrong directory, say) would otherwise pass with no rows at all.
(test-equal "the order rows are live: native.sls imports from (chezscheme)"
  'covered
  (if (assoc "src/libuv/private/native.sls" covered) 'covered 'not-covered))

(for-each
 (lambda (e)
   (test-equal (string-append (car e)
                              " imports (libuv private require-threaded)"
                              " before (chezscheme)")
     'ordered
     (verdict (cdr e))))
 covered)

(test-end "require-threaded")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
