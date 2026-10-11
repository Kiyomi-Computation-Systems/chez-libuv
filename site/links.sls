#!r6rs
;; PURE. Imports no library that loads a shared object.
(library (site links)
  (export rewrite-links)
  (import (rnrs))

  (define repo-blob
    "https://github.com/Kiyomi-Computation-Systems/chez-libuv/blob/")

  (define (prefix? pre s)
    (and (>= (string-length s) (string-length pre))
         (string=? pre (substring s 0 (string-length pre)))))
  (define (suffix? suf s)
    (let ((ls (string-length s)) (lf (string-length suf)))
      (and (>= ls lf) (string=? suf (substring s (- ls lf) ls)))))

  ;; -> (values path anchor-or-#f); anchor includes its leading '#'.
  (define (split-anchor target)
    (let loop ((i 0))
      (cond ((= i (string-length target)) (values target #f))
            ((char=? (string-ref target i) #\#)
             (values (substring target 0 i) (substring target i (string-length target))))
            (else (loop (+ i 1))))))

  (define (registry-has? registry page slug)
    (cond ((assoc page registry) => (lambda (kv) (and (member slug (cdr kv)) #t)))
          (else #f)))

  ;; "./page.md" names the same page as "page.md".
  (define (strip-dot-slash path)
    (if (prefix? "./" path) (substring path 2 (string-length path)) path))

  ;; Rewrite one href/src target. Returns (values new-target dangling?).
  (define (rewrite-target target page registry ref)
    (cond
      ((prefix? "http://" target) (values target #f))
      ((prefix? "https://" target) (values target #f))
      ((prefix? "#" target)                              ; same-page anchor
       (values target
               (not (registry-has? registry page (substring target 1 (string-length target))))))
      ((prefix? "../" target)                            ; escape -> GitHub blob
       (values (string-append repo-blob ref "/" (substring target 3 (string-length target))) #f))
      (else
       (let-values (((path anchor) (split-anchor target)))
         (if (suffix? ".md" path)
             (let* ((norm (strip-dot-slash path))
                    (base (substring norm 0 (- (string-length norm) 3)))
                    (target-page (string-append base ".md"))
                    (slug (and anchor (substring anchor 1 (string-length anchor)))))
               (values (string-append (if (string=? base "README") "index" base)
                                      ".html" (or anchor ""))
                       (not (and (assoc target-page registry)
                                 (or (not slug)
                                     (registry-has? registry target-page slug))))))
             (values target #f))))))          ; unrecognised: leave, don't dangle

  ;; Rewrite href/src targets across the SXML tree rooted at `body`, given
  ;; the site-wide id `registry` (a list of (page . (slug ...))), the
  ;; `page` this body belongs to (attached to any dangler it produces), and
  ;; the release `ref` used to pin ../ escapes to a GitHub blob URL.
  ;; Returns (values new-body danglers); danglers is a list of
  ;; (page . original-target) in document order.
  ;;
  ;; Only href/src attribute VALUES are ever rewritten, and only on (a) and
  ;; (img) elements -- walk-node gates on the tag before attr-map ever runs,
  ;; so an href/src carried by any other element passes through unchanged by
  ;; construction, not by coincidence of what the doc body happens to emit.
  ;; Everything else -- every string, every non-href/src attribute -- passes
  ;; through `eq?`-at-the-leaf untouched. That is what keeps a "javascript:"
  ;; URL sitting as text inside (pre (code "...")) safe: it is a string
  ;; child, never an attribute value, so it is never a candidate for
  ;; rewriting in the first place -- there is no text-scanning pass that
  ;; could mistake it for a link.
  (define (rewrite-links body registry page ref)
    (let ((danglers '()))

      ;; attr = (name value). Rewrite it if name is href/src; else pass
      ;; through unchanged.
      (define (attr-map attr)
        (if (and (memq (car attr) '(href src)) (pair? (cdr attr)) (string? (cadr attr)))
            (let-values (((new dangling?) (rewrite-target (cadr attr) page registry ref)))
              (when dangling? (set! danglers (cons (cons page (cadr attr)) danglers)))
              (list (car attr) new))
            attr))

      ;; R6RS leaves `map`'s application order unspecified, and attr-map has
      ;; a `set!` side effect (recording danglers) -- so a plain (map
      ;; attr-map attrs) could accumulate danglers out of document order.
      ;; Recurse explicitly left to right instead, as (site transform) does for
      ;; its own `set!`-during-walk accumulator: the
      ;; `let` forces and binds the head's result -- side effect included --
      ;; before the recursive call for the tail is ever evaluated.
      (define (walk-attrs attrs)
        (if (null? attrs)
            '()
            (let ((head (attr-map (car attrs))))
              (cons head (walk-attrs (cdr attrs))))))

      ;; Same reasoning, for an element's children.
      (define (walk-children nodes)
        (if (null? nodes)
            '()
            (let ((head (walk-node (car nodes))))
              (cons head (walk-children (cdr nodes))))))

      ;; A leading (^ ...) in an element's tail is its attribute list. Only
      ;; (a) and (img) elements ever carry href/src, so the rewrite is gated
      ;; on the tag itself: walk-attrs runs for those two tags, and every
      ;; other tag's attribute list passes through unchanged. Either way we
      ;; still recurse into the remaining children. Strings (and any other
      ;; non-pair leaf) come back unchanged.
      (define (walk-node node)
        (if (pair? node)
            (let ((tag (car node)) (rest (cdr node)))
              (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '^))
                  (cons tag (cons (cons '^ (if (memq tag '(a img))
                                                (walk-attrs (cdar rest))
                                                (cdar rest)))
                                  (walk-children (cdr rest))))
                  (cons tag (walk-children rest))))
            node))

      (let ((out (walk-node body)))
        (values out (reverse danglers))))))
