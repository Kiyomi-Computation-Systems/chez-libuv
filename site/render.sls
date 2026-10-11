#!r6rs
;; NOT pure: imports (cmark gfm), which loads a shared object. This is the
;; integration point where the pure site/* libraries meet the native parser.
(library (site render)
  (export render-site site-result? site-result-pages
          site-result-registry site-result-leaked)
  (import (rnrs) (cmark gfm) (site transform) (site links)
          (site template) (site pages))

  (define-record-type site-result
    (fields pages registry leaked))

  (define (label-for name)
    (cond ((assoc name pages) => cdr) (else name)))

  ;; The id-registry and the rendered "On this page" rail are built from the
  ;; SAME toc but are not the same list. transform-body's toc covers every
  ;; heading level, h1 through h6, because every heading is a legitimate
  ;; anchor target -- a cross-page link to `page.md#the-page-title` (its h1)
  ;; must resolve just as one to `page.md#some-section` does. The rail,
  ;; though, lists only top-level sections under "On this page"; it must not
  ;; turn the page's own h1 title or individual h3 API entries into rail
  ;; items. So: the registry keeps every slug, and only the copy handed to
  ;; page->document is filtered to level 2.
  (define (rail-toc toc) (filter (lambda (entry) (= (car entry) 2)) toc))

  ;; The home page, README.md, is reached from the wordmark and is not
  ;; listed as a nav item: the wordmark's own href="index.html" lives in
  ;; site/template.sls and is unconditional. `pages` (site/pages.sls) still
  ;; carries the README.md entry because read-site-inputs and check-site's
  ;; nav-completeness check both need it, so the filtering happens here,
  ;; once, on the copy handed to page->document as the nav -- not on
  ;; `pages` itself.
  (define nav (filter (lambda (entry) (not (string=? (car entry) "README.md"))) pages))

  ;; Prev/next neighbours for a page's footer nav, over the `nav` order (the
  ;; docs, README.md excluded). Returns (values prev next), each a
  ;; (file . label) pair or #f. A page not in `nav` (README.md itself) yields
  ;; (values #f #f), so the home page renders no footer nav.
  (define (neighbors name)
    (let loop ((ps nav) (prev #f))
      (cond ((null? ps) (values #f #f))
            ((string=? (caar ps) name)
             (values prev (if (null? (cdr ps)) #f (cadr ps))))
            (else (loop (cdr ps) (car ps))))))

  ;; Pass 1: parse + slug every page, building the id-registry.
  ;; Pass 2: rewrite links against the full registry, then template.
  ;;
  ;; Pass 1 is a plain `map` over `inputs` -- safe despite R6RS leaving
  ;; map's evaluation order unspecified, because each call to
  ;; `transform-body` creates its OWN slugger (site/transform.sls) with no
  ;; state shared across pages; page order in the output is `map`'s
  ;; structural guarantee, independent of application order. Pass 2 cannot
  ;; use `map`: it accumulates `leaked` danglers across pages via `rewrite-
  ;; links`'s per-page result, so it is an explicit left-to-right `let loop`
  ;; instead, the same discipline (site transform) and (site links) each
  ;; apply internally for their own accumulators.
  (define (render-site inputs ref)
    (let* ((parsed                                   ; pass 1
            (map (lambda (in)
                   (let-values (((body toc)
                                 (transform-body (markdown->sxml (cdr in)
                                                                  (default-cmark-options)))))
                     (list (car in) body toc (map caddr toc))))  ; caddr = slug
                 inputs))
           (registry (map (lambda (pg) (cons (car pg) (cadddr pg))) parsed)))
      (let loop ((ps parsed) (pages-out '()) (leaked '()))     ; pass 2
        (if (null? ps)
            (make-site-result (reverse pages-out) registry (reverse leaked))
            (let* ((pg (car ps)) (name (car pg)) (body (cadr pg)) (toc (caddr pg)))
              (let-values (((body* dangling) (rewrite-links body registry name ref))
                           ((prev next) (neighbors name)))
                (loop (cdr ps)
                      (cons (cons name
                                  (page->document nav name (label-for name)
                                                   body* (rail-toc toc) prev next))
                            pages-out)
                      (append (reverse dangling) leaked)))))))))
