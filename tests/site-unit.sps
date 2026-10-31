#!r6rs
;; PURE SUITE. Imports no library that loads a shared object. Not named
;; test-*.sps, so `make test` does not run it. Run it from the repository root:
;;   CHEZSCHEMELIBDIRS=.:tests:build/scheme-libs chez --program tests/site-unit.sps
(import (rnrs) (srfi :64) (site slug) (site serializer) (site transform)
        (site links) (site template) (site io))

(define (string-contains-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

;; (heading . anchor) rows, each anchor the one GitHub gave that heading on a
;; page it rendered: docs here and in the other Kiyomi repositories, a Hindi
;; README, and github-slugger's fixtures, which it made from GitHub's
;; rendering. No two rows share a slug, so each stands as if alone on its page.
(define github-anchors
  '(("Bodies and streaming" . "bodies-and-streaming")
    ("Keep strings, not the request" . "keep-strings-not-the-request")
    ("A file server, like Python's" . "a-file-server-like-pythons")
    ("Testing: (http-server testing)" . "testing-http-server-testing")
    ("&http-server-error, http-server-error?"
     . "http-server-error-http-server-error")
    ("1. Answer every request" . "1-answer-every-request")
    ("Is the abandoned iteration's UV_EOF lost, or merely deferred?"
     . "is-the-abandoned-iterations-uv_eof-lost-or-merely-deferred")
    ("Q1 — THE GATE: C→Scheme re-entry from inside a blocking uv_run, under GC pressure"
     . "q1--the-gate-cscheme-re-entry-from-inside-a-blocking-uv_run-under-gc-pressure")
    ("8.1 Read side (peer → handler)" . "81-read-side-peer--handler")
    ("§4 — reentrancy-test.sps" . "4--reentrancy-testsps")
    ("① (uri query)" . "-uri-query")
    ("Decisions to record (Slice ⓪)" . "decisions-to-record-slice-")
    ("स\x94D;थ\x93E;पन\x93E; करन\x93E;"
     . "स\x94D;थ\x93E;पन\x93E;-करन\x93E;")
    ("heading with an _ underscore" . "heading-with-an-_-underscore")
    ("I ♥ unicode" . "i--unicode")
    ("Привет non-latin 你好" . "привет-non-latin-你好")
    ("a_ ‿ ⁀ ⁔ ︳ ︴ ﹍ ﹎ ﹏ ＿b" . "a_-‿-⁀-⁔-︳-︴-﹍-﹎-﹏-＿b")
    ("a\x488; \x489; \x1ABE; \x20DD; \x20DE; \x20DF; \x20E0; \x20E2; \x20E3; \x20E4; \xA670; \xA671; \xA672;b"
     . "a\x488;-\x489;-\x1ABE;-\x20DD;-\x20DE;-\x20DF;-\x20E0;-\x20E2;-\x20E3;-\x20E4;-\xA670;-\xA671;-\xA672;b")
    ;; This repository's docs, as GitHub renders them.
    ("Living alongside Chez's own processes" . "living-alongside-chezs-own-processes")
    ("uv-loop-alive? (procedure)" . "uv-loop-alive-procedure")
    ("&uv-wrong-thread (condition type)" . "uv-wrong-thread-condition-type")
    ("make-uv-addrinfo (record constructor)"
     . "make-uv-addrinfo-record-constructor")))

;; github-slugger's fixture rows on repeated headings, in their page order;
;; the headings between them on that page share none of these slugs.
(define github-repeats
  '(("echo" . "echo") ("echo" . "echo-1") ("echo 1" . "echo-1-1")
    ("echo-1" . "echo-1-2") ("echo" . "echo-2")
    ("foxtrot-1" . "foxtrot-1") ("foxtrot" . "foxtrot") ("foxtrot" . "foxtrot-2")
    (" a " . "-a-") ("-a-" . "-a--1")))

;; slug-each : (String -> String) (Listof String) -> (Listof String)
;; Calls slug on each heading in order, as a page meets them.
(define (slug-each slug headings)
  (let loop ((hs headings) (out '()))
    (if (null? hs)
        (reverse out)
        (loop (cdr hs) (cons (slug (car hs)) out)))))

;; This repository's reference page: entries whose names differ only in
;; punctuation, in their page order, with the ids GitHub gave them. The
;; headings between them share none of these slugs.
(define reference-repeats
  '(("uv-send-buffer-size (procedure)" . "uv-send-buffer-size-procedure")
    ("uv-send-buffer-size! (procedure)" . "uv-send-buffer-size-procedure-1")
    ("uv-write! (procedure)" . "uv-write-procedure")
    ("uv-write*! (procedure)" . "uv-write-procedure-1")))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "site-unit")

;; --- slugify -------------------------------------------------------------
(test-equal "spaces to single hyphen, lowercased"
  "resource-limits" (slugify "Resource limits"))
(test-equal "commas dropped, 'and' kept"
  "rhel-fedora-and-alpine" (slugify "RHEL, Fedora, and Alpine"))
(for-each (lambda (row) (test-equal (car row) (cdr row) (slugify (car row))))
          github-anchors)
;; GitHub keeps a spacing mark that is not a letter. github-slugger's
;; Spacing_Mark row shows it, but also holds code points newer than some
;; Chez's Unicode tables; GitHub's rule goes a character at a time, so
;; four of that row's marks stand here alone.
(test-equal "spacing marks that are not letters are kept"
  "a\xF3E;-\xF3F;-\x1B44;-\xA9C0;b" (slugify "a\xF3E; \xF3F; \x1B44; \xA9C0;b"))
(test-equal "backtick code in a heading is stripped to its text"
  "What make build does" (heading-text '(h2 "What " (code "make build") " does")))
(test-equal "the whole heading-to-slug path"
  "what-make-build-does"
  (slugify (heading-text '(h2 "What " (code "make build") " does"))))

;; --- make-slugger --------------------------------------------------------
(test-equal "duplicate headings get -1, -2 suffixes"
  '("options" "options-1" "options-2")
  (let ((s (make-slugger))) (list (s "Options") (s "Options") (s "Options"))))
(test-equal "a repeated heading's second slug carries the -1 suffix"
  "timers-1"
  (let ((s (make-slugger))) (s "Timers") (s "Timers")))
(test-equal "a taken slug moves on to the next number, as GitHub numbers it"
  (map cdr github-repeats) (slug-each (make-slugger) (map car github-repeats)))
(test-equal "the reference page's repeats are numbered as GitHub numbers them"
  (map cdr reference-repeats)
  (slug-each (make-slugger) (map car reference-repeats)))
(test-equal "heading-text skips the ^ attr node and inline tags"
  "Some text" (heading-text '(h2 (^ (id "foo")) "Some " (code "text"))))

;; --- serializer ----------------------------------------------------------
(test-equal "text is escaped on output, not before"
  "<p>a &amp; &lt;b&gt;</p>" (sxml->html '(p "a & <b>")))
(test-equal "text does not escape a double quote"
  "<p>say \"hi\"</p>" (sxml->html '(p "say \"hi\"")))
(test-equal "attributes render from the caret marker and are quoted"
  "<a href=\"/x\">l</a>" (sxml->html '(a (^ (href "/x")) "l")))
(test-equal "escape-attr turns a double quote into &quot;"
  "<a title=\"say &quot;hi&quot;\">l</a>"
  (sxml->html '(a (^ (title "say \"hi\"")) "l")))
(test-equal "escape-attr escapes & < > in an attribute value"
  "<a title=\"a&amp;b&lt;c&gt;d\">l</a>"
  (sxml->html '(a (^ (title "a&b<c>d")) "l")))
(test-equal "void elements self-close without a body"
  "<hr>" (sxml->html '(hr)))
(test-equal "*TOP* is a fragment: it emits its children only"
  "<h1>a</h1>\n<p>b</p>\n" (sxml->html '(*TOP* (h1 "a") (p "b"))))
(test-equal "indentation inside pre/code is content, preserved byte-for-byte"
  "<pre><code>(define (f x)\n    (g\n      x))\n</code></pre>"
  (sxml->html '(pre (code "(define (f x)\n    (g\n      x))\n"))))
(test-equal "a *COMMENT* node renders as an HTML comment, not a bogus tag"
  "<!-- raw HTML omitted -->" (sxml->html '(*COMMENT* " raw HTML omitted ")))

;; --- transform -----------------------------------------------------------
(let-values (((body toc)
              (transform-body '(*TOP* (h2 "Node shape") (p "x") (h2 "Node shape")))))
  (test-equal "headings gain a caret id from their slug"
    '(*TOP* (h2 (^ (id "node-shape")) "Node shape") (p "x")
            (h2 (^ (id "node-shape-1")) "Node shape"))
    body)
  (test-equal "the toc lists (level text slug) in document order"
    '((2 "Node shape" "node-shape") (2 "Node shape" "node-shape-1"))
    toc))

(let-values (((body toc)
              (transform-body '(*TOP* (blockquote (p "⚠️ The AST is untrusted."))))))
  (test-equal "a warning-sign blockquote is rewrapped as a warning callout div"
    '(*TOP* (div (^ (class "callout warning")) (blockquote (p "⚠️ The AST is untrusted."))))
    body))

(let-values (((body toc)
              (transform-body '(*TOP* (blockquote (p "A plain note."))))))
  (test-equal "a blockquote without the warning sign is left as it is"
    '(*TOP* (blockquote (p "A plain note.")))
    body))

;; --- links ---------------------------------------------------------------
(define reg '(("README.md" . ("overview"))
              ("timers.md" . ("resource-limits"))
              ("loops.md" . ("run-modes"))))
(define (rw body page)
  (let-values (((b d) (rewrite-links body reg page "main"))) b))
(define (link href) `(*TOP* (p (a (^ (href ,href)) "x"))))
(define (dangling href page)
  (let-values (((b d) (rewrite-links (link href) reg page "main"))) d))

(test-equal "doc .md link (with anchor) becomes .html, anchor kept"
  (link "timers.html#resource-limits")
  (rw (link "timers.md#resource-limits") "loops.md"))
(test-equal "bare doc .md link becomes .html"
  (link "loops.html") (rw (link "loops.md") "timers.md"))
(test-equal "a link to README.md becomes index.html"
  (link "index.html") (rw (link "README.md") "timers.md"))
(test-equal "a link to README.md#overview becomes index.html#overview"
  (link "index.html#overview") (rw (link "README.md#overview") "timers.md"))
(test-equal "a link to ./README.md becomes index.html"
  (link "index.html") (rw (link "./README.md") "timers.md"))
(test-equal "a ./page.md link has its ./ stripped"
  (link "loops.html#run-modes") (rw (link "./loops.md#run-modes") "timers.md"))
(test-equal "same-page anchor is left as-is"
  (link "#run-modes") (rw (link "#run-modes") "loops.md"))
(test-equal "a ../ escape is pinned to the GitHub blob at the ref"
  (link "https://github.com/Kiyomi-Computation-Systems/chez-libuv/blob/main/examples/echo.sps")
  (rw (link "../examples/echo.sps") "loops.md"))
(test-equal "an absolute URL is untouched"
  (link "https://example.com") (rw (link "https://example.com") "loops.md"))
(test-equal "a non-.md relative target is left untouched"
  (link "style.css") (rw (link "style.css") "loops.md"))
(test-equal "a javascript: URL in a code block is not a link, untouched"
  '(*TOP* (pre (code "[x](javascript:alert(1))")))
  (rw '(*TOP* (pre (code "[x](javascript:alert(1))"))) "loops.md"))
(test-equal "an href on a non-a/img element is left untouched"
  '(*TOP* (span (^ (href "timers.md")) "x"))
  (rw '(*TOP* (span (^ (href "timers.md")) "x")) "loops.md"))
(test-equal "an img src is rewritten like an href"
  '(*TOP* (img (^ (src "index.html"))))
  (rw '(*TOP* (img (^ (src "README.md")))) "loops.md"))

(test-equal "an anchor absent from the registry is reported as a dangler"
  '(("loops.md" . "timers.md#nonesuch"))
  (dangling "timers.md#nonesuch" "loops.md"))
(test-equal "a README.md anchor absent from the registry is a dangler"
  '(("loops.md" . "README.md#nonesuch"))
  (dangling "README.md#nonesuch" "loops.md"))
(test-equal "a bare .md link to a page absent from the registry is a dangler"
  '(("loops.md" . "missing.md")) (dangling "missing.md" "loops.md"))
(test-equal "an anchored .md link to a page absent from the registry is a dangler"
  '(("loops.md" . "missing.md#foo")) (dangling "missing.md#foo" "loops.md"))
(test-equal "a bare .md link to a page in the registry is not a dangler"
  '() (dangling "timers.md" "loops.md"))
(test-equal "a same-page anchor absent from the page is a dangler"
  '(("loops.md" . "#gone")) (dangling "#gone" "loops.md"))

;; --- page-file-name (site io) -------------------------------------------
(test-equal "README.md is written as index.html"
  "index.html" (page-file-name "README.md"))
(test-equal "another page's .md becomes .html"
  "loops.html" (page-file-name "loops.md"))

;; --- template ------------------------------------------------------------
(define doc-out
  (page->document '(("README.md" . "Home") ("loops.md" . "The event loop")
                    ("timers.md" . "Timers"))
                  "loops.md" "The event loop"
                  '(*TOP* (h2 (^ (id "run-modes")) "Run modes"))
                  '((2 "Run modes" "run-modes"))
                  '("README.md" . "Home") '("timers.md" . "Timers")))
(define doc-html (sxml->html doc-out))

(test-assert "the document is rooted at html"
  (and (pair? doc-out) (eq? (car doc-out) '*TOP*)
       (eq? (car (cadr doc-out)) 'html)))
(test-assert "the stylesheet is linked in head"
  (and (string-contains-sub? doc-html "<link")
       (string-contains-sub? doc-html "style.css")))
(test-assert "the current page is marked in the nav"
  (string-contains-sub? doc-html "<a href=\"loops.html\" class=\"on\" aria-current=\"page\">"))
(test-assert "the TOC lists the page's headings"
  (string-contains-sub? doc-html "href=\"#run-modes\""))
(test-assert "the wordmark names chez-libuv and links the home page"
  (string-contains-sub? doc-html "<a class=\"mark\" href=\"index.html\">chez-libuv</a>"))
(test-assert "a README.md nav entry links index.html"
  (string-contains-sub? doc-html "<a href=\"index.html\">Home</a>"))
(test-assert "the embedded theme script survives serialization unescaped"
  (and (string-contains-sub? doc-html "<script>(function(){var r=document.documentElement")
       (not (string-contains-sub? doc-html "&amp;"))
       (not (string-contains-sub? doc-html "&lt;"))
       (not (string-contains-sub? doc-html "&gt;"))))

;; index-of : string string integer -> (or integer #f)
;; The first offset at or after START where NEEDLE begins in HAY.
(define (index-of hay needle start)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i start))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) i)
            (else (loop (+ i 1)))))))

;; offsets-of : string string -> (list-of integer)
;; Every offset where NEEDLE begins in HAY, in order.
(define (offsets-of hay needle)
  (let loop ((i (index-of hay needle 0)) (acc '()))
    (if i
        (loop (index-of hay needle (+ i 1)) (cons i acc))
        (reverse acc))))

;; script-of : string -> string
;; The text of the first <script> element in HTML; raises if there is none.
(define (script-of html)
  (let* ((open (index-of html "<script>" 0))
         (start (+ open (string-length "<script>"))))
    (substring html start (index-of html "</script>" start))))

;; unguarded-storage : string -> (list-of integer)
;; The offset of each `localStorage` in SCRIPT that no try block holds:
;; no `try{` comes before it, or a `}` closes something between the last
;; `try{` and it.
(define (unguarded-storage script)
  (filter (lambda (at)
            (let ((tries (filter (lambda (t) (< t at)) (offsets-of script "try{"))))
              (or (null? tries)
                  (let ((last (apply max tries)))
                    (index-of (substring script last at) "}" 0)))))
          (offsets-of script "localStorage")))

;; A browser that refuses the page storage (site data blocked, some private
;; modes) throws from localStorage. Unguarded, that ends the script before
;; it wires the toggle, and the toggle does nothing.
(test-equal "the theme script reaches localStorage twice, each time inside a try block"
  '(2 ())
  (let ((js (script-of doc-html)))
    (list (length (offsets-of js "localStorage")) (unguarded-storage js))))

(test-assert "the mode toggle carries the knob icon"
  (string-contains-sub? doc-html "class=\"knob\""))
(test-assert "the footer nav links the previous and next pages"
  (and (string-contains-sub? doc-html "class=\"pagenav\"")
       (string-contains-sub? doc-html "<a href=\"index.html\"><span class=\"lbl\">Previous</span>")
       (string-contains-sub? doc-html "<a href=\"timers.html\" class=\"next\">")))
(test-equal "a page with no neighbours has no footer nav"
  'agree
  (if (string-contains-sub?
       (sxml->html (page->document '(("README.md" . "Home")) "README.md" "Home"
                                   '(*TOP* (h1 "Home")) '() #f #f))
       "class=\"pagenav\"")
      'pagenav-present 'agree))

(test-end "site-unit")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
