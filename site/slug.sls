#!r6rs
;; PURE. Imports no library that loads a shared object.
(library (site slug)
  (export slugify heading-text make-slugger)
  (import (rnrs))

  ;; slugify : String -> String
  ;; GitHub's heading anchor: lower case; keep word characters (letters,
  ;; marks, decimal digits, connector punctuation such as _), hyphens and
  ;; spaces; then each space becomes a hyphen. Nothing collapses and nothing
  ;; is trimmed, so "a - b" is a---b and a slug may start or end with -.
  (define (slugify str)
    (list->string
      (map (lambda (c) (if (char=? c #\space) #\- c))
           (filter kept? (string->list (string-downcase str))))))

  ;; Chez's char-numeric? holds for circled digits, which GitHub drops, so
  ;; digits are the decimal ones only.
  (define (kept? c)
    (or (char-alphabetic? c)
        (memq (char-general-category c) '(Mn Mc Me Nd Pc))
        (char=? c #\space)
        (char=? c #\-)))

  ;; heading-text : SXML -> String
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

  ;; make-slugger : -> (String -> String)
  ;; A per-page slug factory that numbers repeats as GitHub does: a slug
  ;; already handed out gets -1, -2 and so on, counted per base slug, and a
  ;; numbered slug already handed out moves on to the next number.
  (define (make-slugger)
    (let ((seen '()))   ; (slug . count), newest first; count is for a base
      (lambda (str)
        (let ((base (slugify str)))
          (let loop ((s base))
            (if (assoc s seen)
                (let ((n (+ 1 (cdr (assoc base seen)))))
                  (set! seen (cons (cons base n) seen))
                  (loop (string-append base "-" (number->string n))))
                (begin (set! seen (cons (cons s 0) seen)) s))))))))
