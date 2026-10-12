;;; Prints the theme script exactly as a rendered page carries it, for
;;; .plans/theme-storage-probe.js. Run from the repository root.
(import (rnrs) (site serializer) (site template))
(define html
  (sxml->html (page->document '(("a.md" . "A")) "a.md" "A" '(*TOP* (p "x")) '() '("a.md" . "A") '("a.md" . "A"))))
(define (index-of hay needle start)
  (let loop ((i start))
    (cond ((> (+ i (string-length needle)) (string-length hay)) #f)
          ((string=? needle (substring hay i (+ i (string-length needle)))) i)
          (else (loop (+ i 1))))))
(let* ((s (+ (index-of html "<script>" 0) 8)) (e (index-of html "</script>" s)))
  (display (substring html s e)))
