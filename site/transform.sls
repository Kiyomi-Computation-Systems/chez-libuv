#!r6rs
;; PURE. Imports no library that loads a shared object.
(library (site transform)
  (export transform-body)
  (import (rnrs) (site slug))

  (define heading-tags '(h1 h2 h3 h4 h5 h6))

  (define (heading-tag? t) (and (memq t heading-tags) #t))

  ;; 'h2 -> 2, by reading the digit out of the tag's own name.
  (define (level tag)
    (- (char->integer (string-ref (symbol->string tag) 1))
       (char->integer #\0)))

  ;; A blockquote whose first rendered character is the warning sign U+26A0
  ;; (⚠, with or without the following U+FE0F emoji-presentation selector).
  (define (warning-blockquote? node)
    (and (pair? node)
         (eq? (car node) 'blockquote)
         (let ((t (heading-text node)))
           (and (positive? (string-length t))
                (char=? (string-ref t 0) #\x26A0)))))

  ;; Single tree walk: inject (^ (id slug)) on every heading (collecting the
  ;; TOC as we go) and rewrap ⚠️-led blockquotes as warning callout divs.
  (define (transform-body top)
    (let ((slug (make-slugger)) (toc '()))
      (define (walk node)
        (cond
          ((string? node) node)
          ((and (pair? node) (heading-tag? (car node)))
           (let* ((text (heading-text node))
                  (s (slug text)))
             (set! toc (cons (list (level (car node)) text s) toc))
             (cons (car node) (cons (list '^ (list 'id s)) (cdr node)))))
          ((warning-blockquote? node)
           (list 'div (list '^ (list 'class "callout warning")) node))
          ((pair? node) (cons (car node) (walk-children (cdr node))))
          (else node)))
      ;; R6RS leaves map's application order unspecified, and it is NOT
      ;; left-to-right here in practice: since `walk` mutates `toc` and the
      ;; `slug` dedup counter, (map walk ...) can assign duplicate-heading
      ;; suffixes and TOC order out of document order. Sequence explicitly:
      ;; `walk` on the head is bound (fully evaluated, side effects done)
      ;; before we ever recurse into the tail.
      (define (walk-children nodes)
        (if (null? nodes)
            '()
            (let ((head (walk (car nodes))))
              (cons head (walk-children (cdr nodes))))))
      (let ((body (walk top)))
        (values body (reverse toc)))))
)
