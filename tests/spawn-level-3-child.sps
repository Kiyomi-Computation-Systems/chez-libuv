#!r6rs
;;; Child program for tests/test-process.sps, run at --optimize-level 3. At
;;; that level Chez compiles length, car and cdr with no checks, and the
;;; libraries this imports are compiled from source at the same level. A
;;; read that leaves a malformed list to one of them reads through a
;;; non-pair, or walks a circular list forever, with interrupts disabled,
;;; where nothing in this process can stop it. So this runs in a process of
;;; its own, which the suite kills if it outlasts its deadline
;;; (tests/uv-level-3.sls).
;;;
;;; It runs tests/spawn-list-races.sls's lists malformed from the start, and
;;; prints one datum, an alist: its optimize level, the object file each
;;; library under test came from (#f for one compiled here from source),
;;; and what uv-spawn! did with each list. The cross-thread races run at the
;;; default level only. At level 3 a guarded read hides what it reads
;;; through just as it hides a raise, so the races catch nothing here that
;;; they do not catch there; a list circular from the start is what hangs a
;;; read that counts with length.
(import (rnrs)
        (spawn-list-races)
        ;; Each library the report names, imported for its own sake, so that
        ;; naming it cannot raise: library-object-filename raises for a
        ;; library not loaded, and the report must not depend on which
        ;; private libraries (libuv process) happens to import.
        (only (libuv process))
        (only (libuv private lists))
        (only (libuv private c-string))
        (only (chezscheme) optimize-level library-object-filename))

(write (list (cons 'level (optimize-level))
             (cons 'objects
                   (map library-object-filename
                        '((libuv process) (libuv private lists)
                          (libuv private c-string) (spawn-list-races))))
             (cons 'malformed (malformed-refusals))))
(newline)
