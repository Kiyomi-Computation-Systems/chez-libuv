#!r6rs
;;; Child program for tests/test-addrinfo.sps, run at --optimize-level 3. At
;;; that level Chez compiles length, car and cdr with no checks, and the
;;; libraries this imports are compiled from source at the same level. A
;;; validator that leaves a malformed list to one of them reads through a
;;; non-pair, or walks a circular list forever where no engine can stop it
;;; (#66). So this runs in a process of its own, which the suite kills if it
;;; outlasts its cap. It runs the flag lists its arguments name, and prints
;;; what it saw as one datum, an alist, for the suite to check row by row.
;;;
;;; Pure, as the suite is: it needs no shim.
(import (rnrs)
        (rnrs mutable-pairs)
        (libuv private addrinfo)
        (libuv private conditions)
        (only (chezscheme) optimize-level))

;; outcome : object -> list
;; What validate-hints did with FLAGS as a hints flags entry.
(define (outcome flags)
  (guard (e ((uv-invalid-argument? e) (list 'refused (uv-invalid-argument-reason e)))
            ((message-condition? e) (list 'raised (condition-message e)))
            (#t (list 'raised e)))
    (list 'answered (validate-hints (list (cons 'flags flags)) 'level-3))))

;; flag-lists : (list-of (symbol . (-> object)))
(define flag-lists
  (list (cons 'proper (lambda () (list 'passive 'canonname)))
        (cons 'improper (lambda () (cons 'passive 'canonname)))
        (cons 'circular (lambda ()
                          (let ((l (list 'passive 'canonname)))
                            (set-cdr! (cdr l) l)
                            l)))))

(write (cons (cons 'level (optimize-level))
             (map (lambda (arg)
                    (let ((name (string->symbol arg)))
                      (cons name (outcome ((cdr (assq name flag-lists)))))))
                  (cdr (command-line)))))
(newline)
