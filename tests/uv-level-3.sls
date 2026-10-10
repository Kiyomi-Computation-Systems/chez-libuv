#!r6rs
;;; Running a child program at --optimize-level 3 under a deadline, shared by
;;; tests/test-addrinfo.sps (tests/flags-level-3-child.sps) and
;;; tests/test-process.sps (tests/spawn-level-3-child.sps), on
;;; tests/uv-child.sls's runner.
;;;
;;; A program compiled at --optimize-level 3 compiles the libraries it loads
;;; from source at that level too, where Chez's length, car and cdr check
;;; nothing: a read that leaves a malformed list to them reads through a
;;; non-pair, or walks a circular list forever, where no guard can catch it
;;; and no engine can stop it. So each child runs in a process of its own,
;;; killed if it is still running at the deadline, and prints one datum, an
;;; alist, for its suite's rows. Each child reports the optimize level it ran
;;; at and the object file each library under test came from: a library
;;; loaded from a compiled .so beside its source keeps the level it was
;;; compiled at, and the child would test that code while its own level said
;;; 3.
;;;
;;; PURE, as (uv-child) is.
(library (uv-level-3)
  (export level-3-run level-3-entry)
  (import (rnrs)
          (uv-child))

  ;; level-3-run : string string (list-of symbol) [seconds] -> (or alist list)
  ;; child-run's answer for PROGRAM run at --optimize-level 3.
  (define level-3-run
    (case-lambda
      ((chez program names)
       (child-run chez '("--optimize-level" "3") program names))
      ((chez program names deadline-seconds)
       (child-run chez '("--optimize-level" "3") program names deadline-seconds))))

  ;; level-3-entry : object symbol -> object
  ;; child-entry, under the name the level-3 suites read.
  (define (level-3-entry report key)
    (child-entry report key)))
