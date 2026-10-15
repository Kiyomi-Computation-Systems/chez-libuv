#!r6rs
;; PURE. Imports no library that loads a shared object.
(library (site template)
  (export page->document)
  (import (rnrs))

  (define (nav-item current)
    (lambda (entry)
      (let ((file (car entry)) (label (cdr entry)))
        (if (string=? file current)
            `(a (^ (href ,(md->html-name file)) (class "on") (aria-current "page")) ,label)
            `(a (^ (href ,(md->html-name file))) ,label)))))

  ;; README.md, the home page, is written as index.html.
  (define (md->html-name file)
    (if (string=? file "README.md")
        "index.html"
        (string-append (substring file 0 (- (string-length file) 3)) ".html")))

  (define (toc-item entry)
    `(a (^ (href ,(string-append "#" (caddr entry)))) ,(cadr entry)))

  ;; Prev/next footer nav. `prev`/`next` are each a (file . label) pair or #f
  ;; (the ends of the sequence, and the home page, have no neighbour on one
  ;; or both sides). Returns a list to splice: the .pagenav div when either
  ;; neighbour exists, or '() so the home page gets no footer nav at all.
  ;; A missing side is an empty <span> so flex space-between still pins the
  ;; present link to its edge. Arrows are U+2190/U+2192 (not '<'/'>', which
  ;; the pre-safe serializer would escape).
  (define (pagenav prev next)
    (if (or prev next)
        (list
         `(div (^ (class "pagenav"))
           ,(if prev
                `(a (^ (href ,(md->html-name (car prev))))
                    (span (^ (class "lbl")) "Previous")
                    ,(string-append "\x2190; " (cdr prev)))
                '(span))
           ,(if next
                `(a (^ (href ,(md->html-name (car next))) (class "next"))
                    (span (^ (class "lbl")) "Next")
                    ,(string-append (cdr next) " \x2192;"))
                '(span))))
        '()))

  ;; theme: prefers-color-scheme + a persisted toggle (localStorage). Pinned
  ;; on load so the CSS and the label never disagree (no flash of the wrong mode).
  ;;
  ;; This string is emitted verbatim inside a <script> element by the
  ;; pre-safe serializer (site serializer), which HTML-escapes every text
  ;; node -- including a script's. Browsers do NOT decode entities inside
  ;; <script>, so this string must never contain '<', '>', or '&': written
  ;; with === and nested ternaries instead of &&/</> so it survives
  ;; serialization byte-for-byte. Do not introduce any of those characters
  ;; here without giving the serializer script-awareness first.
  ;;
  ;; A browser that refuses the page storage (site data blocked, some private
  ;; modes) throws from localStorage, so g and p reach it only inside a try:
  ;; the toggle then works for the life of the page and is not remembered.
  ;; tests/site-unit.sps holds every access to a try block.
  (define theme-script
    (string-append
     "(function(){var r=document.documentElement,b=document.getElementById('theme'),"
     "l=document.getElementById('theme-label');"
     "function g(){try{return localStorage.getItem('theme');}catch(e){return null;}}"
     "function p(x){try{localStorage.setItem('theme',x);}catch(e){}}"
     "function m(){var s=g();"
     "return s?s:(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');}"
     "function a(x){r.setAttribute('data-mode',x);p(x);"
     "l.textContent=x==='dark'?'Light mode':'Dark mode';}a(m());"
     "b.addEventListener('click',function(){a(r.getAttribute('data-mode')==='dark'?'light':'dark');});})();"))

  (define (page->document nav current title body toc prev next)
    `(*TOP*
      (html
       (head
        (meta (^ (charset "utf-8")))
        (meta (^ (name "viewport") (content "width=device-width, initial-scale=1")))
        (meta (^ (name "description") (content "R6RS bindings to libuv for Chez Scheme")))
        (meta (^ (name "keywords") (content "libuv scheme chez r6rs")))
        (title ,title)
        (link (^ (rel "stylesheet") (href "style.css"))))
       (body
        (div (^ (class "topbar"))
             (a (^ (class "source-link") (href "https://github.com/Kiyomi-Computation-Systems/chez-libuv")) "Source code")
             (button (^ (id "theme") (class "toggle") (aria-label "Toggle theme"))
                     (span (^ (class "knob") (aria-hidden "true")))
                     (span (^ (id "theme-label")) "Dark mode")))
        (div (^ (class "layout"))
             (aside (^ (class "side"))
                    (a (^ (class "mark") (href "index.html")) "chez-libuv")
                    (nav ,@(map (nav-item current) nav)))
             (main (^ (class "main"))
                   (div (^ (class "col")) ,@(cdr body) ,@(pagenav prev next)))
             (aside (^ (class "toc"))
                    (div (^ (class "lbl")) "On this page")
                    ,@(map toc-item toc)))
        (script ,theme-script)))))
  )
