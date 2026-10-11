#!r6rs
;;; `make check-site` -- the gate that proves the generated site cannot rot
;;; silently. Named tests/site-check.sps, NOT tests/test-site-check.sps: the
;;; Makefile's TESTS := $(wildcard tests/test-*.sps) must not pick this up,
;;; because this program asserts on the REAL docs/*.md, not
;;; on fixtures, and belongs on its own `make check-site` target instead of
;;; inside `make test`'s loop.
;;;
;;; NOT pure: imports (site render), which imports (cmark gfm) and so loads
;;; a shared object.
;;;
;;; Run like the repo's other native suites/gates:
;;;   CHEZSCHEMELIBDIRS=src:tests:.:build/akku/chez-cmark-gfm/src SITE_REF=main \
;;;     $CHEZ --program tests/site-check.sps
;;; or simply `make check-site`.
;;;
;;; Asserts four invariants directly on render-site's return value -- no filesystem write, no
;;; `build/site/` dependency:
;;;   1. nav completeness -- (site pages) names exactly docs/*.md on disk,
;;;      README.md (the home page) included.
;;;   2. anchor resolution -- render-site left no dangling intra-site link.
;;;   3. no relative .md leak -- every serialized href/src either resolves
;;;      to .html, is a same-page #anchor, or is an absolute (http...) URL;
;;;      none is a relative link still ending in .md.
;;;   4. no <pre> reflow -- the serializer never reindents preformatted code.
;;;   5. every relative link names a written file -- a page under the name
;;;      (site io) writes it to, or the stylesheet.
;;;   6. every link out to the repository (a ../ escape) names a file the
;;;      checkout has.
;;;   7. every heading's anchor is the same on GitHub as on the site.
;;;
;;; Each invariant `die`s with its own name on failure and a non-zero exit,
;;; per AGENTS.md ("Expect a value only success can produce"): a caller
;;; grepping this program's stderr for which invariant broke gets an answer,
;;; not a guess.
(import (rnrs) (only (chezscheme) getenv directory-list)
        (cmark gfm)
        (site io) (site render) (site pages) (site serializer)
        (only (site links) repo-blob) (only (site slug) slugify)
        (site transform))

(define (die . parts)
  (for-each (lambda (x) (display x (current-error-port))) parts)
  (newline (current-error-port))
  (exit 1))

;; --- small string helpers, deliberately dumb ------------------------------
;; No general HTML/URL parsing anywhere below: (3)'s scan only ever asks two
;; questions of an already-delimited attribute value ("does it start with
;; http", "does it end in .md or carry .md#"), so a fragile hand-rolled URL
;; parser would buy nothing a straight substring search doesn't already give.

(define (string-starts-with? prefix s)
  (and (>= (string-length s) (string-length prefix))
       (string=? prefix (substring s 0 (string-length prefix)))))

(define (string-ends-with? suffix s)
  (let ((ls (string-length s)) (lf (string-length suffix)))
    (and (>= ls lf) (string=? suffix (substring s (- ls lf) ls)))))

(define (string-contains? needle hay)
  (let ((hn (string-length hay)) (nn (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i nn) hn) #f)
            ((string=? needle (substring hay i (+ i nn))) #t)
            (else (loop (+ i 1)))))))

;; Index of the first occurrence of `needle` in `hay` at or after `start`,
;; or #f. Used only to find the closing '"' of an attribute value.
(define (string-search hay needle start)
  (let ((hn (string-length hay)) (nn (string-length needle)))
    (let loop ((i start))
      (cond ((> (+ i nn) hn) #f)
            ((string=? needle (substring hay i (+ i nn))) i)
            (else (loop (+ i 1)))))))

(define (md-file-name? name)
  (and (string-ends-with? ".md" name) (> (string-length name) 3)))

;; --- (1) nav completeness -------------------------------------------------
;; (site pages)'s own file (site/pages.sls) is documented as "the nav's
;; single source of order and labels"; this asserts that it names exactly
;; the docs/*.md files on disk, README.md included as the home page. Named by the actual set difference in
;; each direction, not by dumping both full lists, so the failure reads as
;; "here is what's wrong" rather than "here is everything, go diff it".
(define (list-minus a b) (filter (lambda (x) (not (member x b))) a))

(define nav-docs
  (list-sort string<? (map car pages)))
(define disk-docs
  (list-sort string<? (filter md-file-name? (directory-list "docs"))))

(define missing-from-nav (list-minus disk-docs nav-docs))  ; on disk, absent from the nav
(define extra-in-nav (list-minus nav-docs disk-docs))      ; in the nav, absent from disk

(unless (and (null? missing-from-nav) (null? extra-in-nav))
  (die "check-site: nav completeness FAILED. "
       "missing-from-site/pages.sls=" missing-from-nav " "
       "extra-in-site/pages.sls=" extra-in-nav))

;; --- render the real site once, for checks (2) and (3) --------------------
(define ref (or (getenv "SITE_REF") "main"))
(define result (render-site (read-site-inputs) ref))

;; --- (2) anchor resolution -------------------------------------------------
;; site-result-leaked is render-site's own accumulator of every href/src
;; whose target -- a same-page #slug or a cross-page page.md#slug -- was not
;; found in the id-registry built from every page's actual headings. An
;; empty list here is also the only mechanism proving the slug algorithm
;; (site/slug.sls) matches the anchors docs/*.md write by hand in prose.
(unless (null? (site-result-leaked result))
  (die "check-site: anchor resolution FAILED. danglers=" (site-result-leaked result)))

;; --- (3) no relative .md leak ----------------------------------------------
;; Find every href="..."/src="..." VALUE in a serialized page and flag one
;; that (a) does not start with "http" -- ruling out the absolute GitHub
;; blob URLs a ../ escape produces, which legitimately end in .md -- and
;; (b) ends in ".md" or carries ".md#" -- a relative link (site/links.sls)
;; failed to rewrite to .html. escape-attr (site/serializer.sls) turns any
;; literal '"' inside an attribute's own text into &quot; before this string
;; ever exists, so scanning for the next bare '"' to close the value is safe
;; -- it can never fire early on a quote that is part of the value itself.
(define (attr-values html marker)
  (let ((hn (string-length html)) (mn (string-length marker)))
    (let loop ((i 0) (acc '()) (in-tag #f))
      (cond
        ((> (+ i mn) hn) (reverse acc))
        ((char=? (string-ref html i) #\<) (loop (+ i 1) acc #t))
        ((char=? (string-ref html i) #\>) (loop (+ i 1) acc #f))
        ((and in-tag (string=? marker (substring html i (+ i mn))))
         (let* ((start (+ i mn))
                (end (or (string-search html "\"" start) hn)))
           (loop (+ end 1) (cons (substring html start end) acc) #t)))
        (else (loop (+ i 1) acc in-tag))))))

;; Only markup is scanned. escape-text turns every < and > in text into
;; &lt; and &gt;, so a raw < opens a tag and a raw > closes it. Text is not
;; scanned: a code sample showing href="x.md" is not a link. This probe holds
;; that: a code sample with an href in it, then a real link.
(let ((probe (sxml->html '(p (code "<a href=\"x.md\">") (a (^ (href "y.md")) "y")))))
  (unless (equal? (attr-values probe "href=\"") '("y.md"))
    (die "check-site: the link scan reads text as links: "
         (attr-values probe "href=\""))))

(define (relative-md-leak? v)
  (and (not (string-starts-with? "http" v))
       (or (string-ends-with? ".md" v) (string-contains? ".md#" v))))

(define (leaked-md-values html)
  (filter relative-md-leak?
          (append (attr-values html "href=\"") (attr-values html "src=\""))))

(for-each
  (lambda (pg)
    (let* ((html (sxml->html (cdr pg)))
           (leaks (leaked-md-values html)))
      (unless (null? leaks)
        (die "check-site: a relative .md link leaked into " (car pg) ": " leaks))))
  (site-result-pages result))

;; --- (5) every relative link names a written file ---------------------------
;; A relative href/src must name a file `make site` writes: a page, by the
;; name (site io) writes it under, or the stylesheet. Without this, a link
;; to README.md rewritten to README.html (the home page is index.html)
;; passes (2), which looks pages up by their .md name, and (3), which only
;; looks for .md.
(define written
  (cons "style.css" (map (lambda (pg) (page-file-name (car pg))) pages)))

(define (link-path v)
  (let ((hash (string-search v "#" 0)))
    (if hash (substring v 0 hash) v)))

(define (unwritten-targets html)
  (filter (lambda (v)
            (let ((path (link-path v)))
              (and (not (string-starts-with? "http" v))
                   (not (string=? path ""))
                   (not (member path written)))))
          (append (attr-values html "href=\"") (attr-values html "src=\""))))

(for-each
  (lambda (pg)
    (let ((bad (unwritten-targets (sxml->html (cdr pg)))))
      (unless (null? bad)
        (die "check-site: a link names a file the site does not write, in "
             (car pg) ": " bad))))
  (site-result-pages result))

;; --- (6) every link out to the repository names a file it has -------------
;; A ../ escape becomes a GitHub URL under repo-blob at SITE_REF, which
;; nothing on the site resolves. The file it names must exist in this
;; checkout, or the published page links to a 404.
(define blob-prefix (string-append repo-blob ref "/"))

(define (missing-repo-files html)
  (filter (lambda (v)
            (and (string-starts-with? blob-prefix v)
                 (let ((path (link-path (substring v (string-length blob-prefix)
                                                   (string-length v)))))
                   (or (string-starts-with? "../" path)
                       (not (file-exists? path))))))
          (attr-values html "href=\"")))

(for-each
  (lambda (pg)
    (let ((bad (missing-repo-files (sxml->html (cdr pg)))))
      (unless (null? bad)
        (die "check-site: a link out to the repository names no file in it, in "
             (car pg) ": " bad))))
  (site-result-pages result))

;; --- (7) every heading's anchor is GitHub's too ---------------------------
;; docs/ is read on GitHub as well as on the site, so an anchor must be the
;; same in both. GitHub keeps underscores and turns each space into a
;; hyphen, where (site slug) drops underscores and collapses runs; the two
;; agree on plain headings. A heading on which they differ is refused, so
;; every page.md#anchor link works in both places.
(define (github-slug text)
  (list->string
   (map (lambda (c) (if (char=? c #\space) #\- c))
        (filter (lambda (c)
                  (or (char-alphabetic? c) (char-numeric? c)
                      (memv c '(#\space #\- #\_))))
                (string->list (string-downcase (trim-spaces text)))))))

(define (trim-spaces s)
  (let* ((cs (string->list s))
         (drop (lambda (cs) (let loop ((cs cs))
                              (if (and (pair? cs) (char=? (car cs) #\space))
                                  (loop (cdr cs))
                                  cs)))))
    (list->string (reverse (drop (reverse (drop cs)))))))

(for-each
  (lambda (in)
    (let-values (((body toc) (transform-body (markdown->sxml (cdr in)
                                                             (default-cmark-options)))))
      (for-each
        (lambda (entry)
          (let ((text (cadr entry)))
            (unless (string=? (slugify text) (github-slug text))
              (die "check-site: a heading's anchor differs on GitHub, in "
                   (car in) ": " text " -> site " (slugify text)
                   ", GitHub " (github-slug text)))))
        toc)))
  (read-site-inputs))

;; --- (4) no <pre> reflow ----------------------------------------------------
;; A fixed probe, independent of the real corpus: a deeply-indented code
;; block must round-trip byte-for-byte, so `make check-site` alone catches
;; a serializer that reindents preformatted code.
(let ((probe (sxml->html '(pre (code "a\n        b\n")))))
  (unless (string=? probe "<pre><code>a\n        b\n</code></pre>")
    (die "check-site: <pre> reflow FAILED: " probe)))

(display "check-site: nav, anchors, no .md leak, every link written, repository links exist, GitHub anchors, no <pre> reflow -- all green\n")
(exit 0)
