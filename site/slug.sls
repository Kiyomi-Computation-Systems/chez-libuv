#!r6rs
(library (site slug)
  (export slugify heading-text make-slugger)
  (import (rnrs))

  ;; GitHub's heading-anchor algorithm, ASCII subset: lowercase; keep only
  ;; alphanumerics, spaces, and hyphens; collapse space runs to one hyphen;
  ;; trim leading/trailing hyphens.
  (define (slugify str)
    (let* ((lowered (string-downcase str))
           (kept (list->string
                   (filter (lambda (c)
                             (or (char-alphabetic? c) (char-numeric? c)
                                 (char=? c #\space) (char=? c #\-)))
                           (string->list lowered)))))
      (trim-hyphens (spaces->hyphen kept))))

  (define (spaces->hyphen s)
    ;; each maximal run of spaces (or existing hyphens) becomes one hyphen
    (let loop ((cs (string->list s)) (out '()) (in-gap #f))
      (cond
        ((null? cs) (list->string (reverse out)))
        ((or (char=? (car cs) #\space) (char=? (car cs) #\-))
         (loop (cdr cs) (if in-gap out (cons #\- out)) #t))
        (else (loop (cdr cs) (cons (car cs) out) #f)))))

  (define (trim-hyphens s)
    (let* ((n (string-length s))
           (a (let lo ((i 0)) (if (and (< i n) (char=? (string-ref s i) #\-)) (lo (+ i 1)) i)))
           (b (let hi ((j n)) (if (and (> j a) (char=? (string-ref s (- j 1)) #\-)) (hi (- j 1)) j))))
      (substring s a b)))

  ;; Concatenate a heading's text descendants, ignoring the (^ …) attr node
  ;; and inline element tags (code, em, strong, a). SXML strings are text.
  (define (heading-text node)
    (call-with-string-output-port
      (lambda (p)
        (let walk ((n node))
          (cond
            ((string? n) (put-string p n))
            ((pair? n)
             (cond
               ((eq? (car n) '^) #f)                        ; skip attrs
               ((symbol? (car n)) (for-each walk (cdr n)))  ; element: skip tag
               (else (for-each walk n))))
            (else #f))))))

  ;; A per-page slug factory that disambiguates collisions GitHub-style.
  (define (make-slugger)
    (let ((seen '()))
      (lambda (str)
        (let* ((base (slugify str))
               (n (cond ((assoc base seen) => cdr) (else 0))))
          (set! seen (cons (cons base (+ n 1))
                           (filter (lambda (kv) (not (string=? (car kv) base))) seen)))
          (if (zero? n) base (string-append base "-" (number->string n))))))))
