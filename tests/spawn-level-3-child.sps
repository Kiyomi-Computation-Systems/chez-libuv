#!r6rs
;;; Child program for tests/test-process.sps, run at --optimize-level 3. At
;;; that level Chez compiles length, car and cdr with no checks, and the
;;; libraries this imports are compiled from source at the same level. A
;;; read that leaves a malformed list to one of them reads through a
;;; non-pair, or walks a circular list forever, with interrupts disabled,
;;; where nothing in this process can stop it (#66). So this runs in a
;;; process of its own, which the suite kills if it outlasts its cap. It runs
;;; what its arguments name from tests/spawn-list-races.sls, the races and
;;; `malformed`, the lists malformed from the start, and prints what it saw
;;; as one datum, an alist, for the suite to check.
(import (rnrs)
        (spawn-list-races)
        (only (chezscheme) optimize-level))

(define names (map string->symbol (cdr (command-line))))

(write (cons (cons 'level (optimize-level))
             (append (if (memq 'malformed names)
                         (list (cons 'malformed (malformed-refusals)))
                         '())
                     (list-races (filter (lambda (name) (not (eq? name 'malformed)))
                                         names)))))
(newline)
