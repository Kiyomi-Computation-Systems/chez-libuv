#!r6rs
;;; The imperative shell: read docs/*.md, render, write HTML.
;;;
;;;   make site
;;; or directly:
;;;   CHEZSCHEMELIBDIRS=src:tests:.:build/akku/chez-cmark-gfm/src chez --program build-site.sps
;;;
;;; SITE_REF pins the ../-escape rewrite in (site links) to a git ref for the
;;; GitHub blob URLs it produces (default "main"). SITE_OUT overrides the
;;; output directory (default "build/site").
(import (rnrs) (only (chezscheme) getenv) (site io) (site render))

(define ref (or (getenv "SITE_REF") "main"))
(define out (or (getenv "SITE_OUT") "build/site"))

(let ((result (render-site (read-site-inputs) ref)))
  (write-site result out)
  (display "site: wrote ") (display (length (site-result-pages result)))
  (display " pages to ") (display out) (newline))
