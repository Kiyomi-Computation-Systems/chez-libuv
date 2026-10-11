#!r6rs
(library (site serializer)
  (export sxml->html)
  (import (rnrs))

  (define void-tags
    '(area base br col embed hr img input link meta param source track wbr))

  (define (void? tag) (and (memq tag void-tags) #t))

  (define (escape-text s)
    (escape s '((#\& . "&amp;") (#\< . "&lt;") (#\> . "&gt;"))))
  (define (escape-attr s)
    (escape s '((#\& . "&amp;") (#\< . "&lt;") (#\> . "&gt;") (#\" . "&quot;"))))
  (define (escape s table)
    (call-with-string-output-port
      (lambda (p)
        (string-for-each
          (lambda (c) (cond ((assv c table) => (lambda (kv) (put-string p (cdr kv))))
                            (else (put-char p c)))) s))))

  (define (attrs-node? x) (and (pair? x) (pair? (car x)) (eq? (caar x) '^)))

  (define (render-attrs attr-node p)
    ;; attr-node = (^ (name value) …)
    (for-each
      (lambda (a)
        (put-string p " ") (put-string p (symbol->string (car a)))
        (put-string p "=\"") (put-string p (escape-attr (cadr a))) (put-string p "\""))
      (cdr attr-node)))

  (define (sxml->html node)
    (call-with-string-output-port (lambda (p) (emit node p))))

  (define (emit node p)
    (cond
      ((string? node) (put-string p (escape-text node)))
      ((and (pair? node) (eq? (car node) '*TOP*))
       (for-each (lambda (k) (emit k p) (put-string p "\n")) (cdr node)))
      ((and (pair? node) (eq? (car node) '*COMMENT*))
       (put-string p "<!--") (put-string p (cadr node)) (put-string p "-->"))
      ((pair? node)
       (let* ((tag (car node))
              (rest (cdr node))
              (attr (and (pair? rest) (attrs-node? rest) (car rest)))
              (kids (if attr (cdr rest) rest)))
         (put-string p "<") (put-string p (symbol->string tag))
         (when attr (render-attrs attr p))
         (put-string p ">")
         (unless (void? tag)
           (for-each (lambda (k) (emit k p)) kids)
           (put-string p "</") (put-string p (symbol->string tag)) (put-string p ">"))))
      (else (error 'sxml->html "unrenderable node" node)))))
