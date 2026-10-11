#!r6rs
;; NATIVE SUITE: imports (cmark gfm) through (site render), which loads a
;; shared object. Not named test-*.sps, so `make test` does not run it; it
;; needs chez-cmark-gfm from `make site-deps`. Run it from the repository root:
;;   CHEZSCHEMELIBDIRS=.:tests:build/scheme-libs:build/akku/chez-cmark-gfm/src \
;;     chez --program tests/site-render-unit.sps
(import (rnrs) (srfi :64) (site render) (site serializer))

(define (string-contains-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

;; Non-overlapping occurrence count.
(define (count-substring hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0) (count 0))
      (cond ((> (+ i n) h) count)
            ((string=? needle (substring hay i (+ i n))) (loop (+ i n) (+ count 1)))
            (else (loop (+ i 1) count))))))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "site-render-unit")

;; Two pages; the home page links to a heading on loops.md, and loops.md links
;; back to the home page. The anchor is only knowable after loops.md is slugged.
(define inputs
  '(("README.md" . "# Home\n\nSee [run modes](loops.md#run-modes).\n")
    ("loops.md"  . "# The loop\n\n## Run modes\n\ntext\n\n### Mode detail\n\nmore text\n\n[home](README.md)\n")))

(define r (render-site inputs "main"))

(test-equal "every input yields a page"
  '("README.md" "loops.md") (map car (site-result-pages r)))

(test-equal "the registry carries every one of a page's heading slugs, including its h1"
  '("the-loop" "run-modes" "mode-detail")
  (cond ((assoc "loops.md" (site-result-registry r)) => cdr) (else 'missing)))

(test-equal "resolvable cross-page links, README.md among them, do not dangle"
  '() (site-result-leaked r))

(let ((html (sxml->html (cond ((assoc "loops.md" (site-result-pages r)) => cdr)
                              (else (error 'site-render-unit "loops.md page missing"))))))
  (test-assert "the rail links the h2 anchor"
    (string-contains-sub? html "href=\"#run-modes\""))
  (test-equal "the rail does not link the h1 anchor"
    'agree
    (if (string-contains-sub? html "href=\"#the-loop\"") 'h1-in-rail 'agree))
  (test-equal "an h3 remains a rendered link target"
    'present
    (if (string-contains-sub? html "id=\"mode-detail\"") 'present 'missing))
  (test-equal "the rail lists h2 sections, not h3 details"
    'agree
    (if (string-contains-sub? html "href=\"#mode-detail\"") 'h3-in-rail 'agree))
  (test-equal "a link to README.md is written as index.html, beside the wordmark's"
    2 (count-substring html "href=\"index.html\""))
  (test-equal "no link keeps the README.md name"
    'agree
    (if (string-contains-sub? html "README") 'readme-left 'agree))
  (test-assert "the wordmark names chez-libuv"
    (string-contains-sub? html ">chez-libuv</a>")))

;; The home page is reached from the wordmark and the page text, not listed as
;; a nav item: only the wordmark links index.html on a page that does not link
;; it in its text.
(let ((html (sxml->html (cdr (assoc "README.md" (site-result-pages r))))))
  (test-equal "index.html is linked exactly once on the home page: the wordmark, not a nav item"
    1 (count-substring html "href=\"index.html\""))
  (test-equal "the home page has no footer nav"
    'agree
    (if (string-contains-sub? html "class=\"pagenav\"") 'pagenav-present 'agree)))

;; A page in the nav order gets its neighbours as footer links.
(let* ((r3 (render-site '(("installing.md" . "# Installing\n")
                          ("quickstart.md" . "# Quickstart\n")
                          ("loops.md" . "# Loops\n")) "main"))
       (html (sxml->html (cdr (assoc "quickstart.md" (site-result-pages r3))))))
  (test-assert "a middle page links its previous and next pages"
    (and (string-contains-sub? html "<a href=\"installing.html\"><span class=\"lbl\">Previous")
         (string-contains-sub? html "<a href=\"loops.html\" class=\"next\">"))))

;; A warning-led blockquote passes through the whole pipeline as a callout.
(let* ((r4 (render-site '(("loops.md" . "> ⚠️ Careful.\n")) "main"))
       (html (sxml->html (cdr (assoc "loops.md" (site-result-pages r4))))))
  (test-assert "a warning blockquote is rendered inside a callout div"
    (string-contains-sub? html "<div class=\"callout warning\"><blockquote>")))

;; A dangling anchor is reported, README.md targets included.
(define r2 (render-site
            '(("README.md" . "[x](loops.md#gone)\n") ("loops.md" . "# The loop\n")) "main"))
(test-equal "an unresolvable cross-page anchor is reported"
  '(("README.md" . "loops.md#gone")) (site-result-leaked r2))

(define r5 (render-site
            '(("README.md" . "# Home\n") ("loops.md" . "[x](README.md#gone)\n")) "main"))
(test-equal "an unresolvable README.md anchor is reported"
  '(("loops.md" . "README.md#gone")) (site-result-leaked r5))

(test-end "site-render-unit")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
