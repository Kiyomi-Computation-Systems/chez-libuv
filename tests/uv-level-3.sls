#!r6rs
;;; Running a child program at --optimize-level 3 under a deadline, shared by
;;; tests/test-addrinfo.sps (tests/flags-level-3-child.sps) and
;;; tests/test-process.sps (tests/spawn-level-3-child.sps).
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
;;; PURE: no native code, so the pure suites can use it (PURE_TESTS).
(library (uv-level-3)
  (export level-3-run level-3-entry)
  (import (rnrs)
          (only (chezscheme) display-condition open-process-ports
                input-port-ready? sleep make-time system current-time
                time-difference time-second))

  ;; How long a child may run, by the monotonic clock. A healthy child takes
  ;; under a second; a poll count of 10 ms sleeps, as #69's runner kept, came
  ;; to about 81 s for 6,000 polls on macOS, whose sleeps overshoot.
  (define level-3-deadline-seconds 60)

  ;; describe : object -> string
  ;; A raised object's message, total. (tests/uv-evidence.sls has one too,
  ;; but it is not pure.)
  (define (describe e)
    (guard (err (#t "<the raised object could not be printed>"))
      (call-with-string-output-port
       (lambda (p) (if (condition? e) (display-condition e p) (write e p))))))

  ;; level-3-run : string string (list-of symbol) -> (or alist symbol list)
  ;; The datum CHEZ printed running PROGRAM at --optimize-level 3 with NAMES
  ;; as its arguments, or why there is none: (spawn-failed text),
  ;; (unreadable out err), or killed-at-cap for a child still running when
  ;; the deadline passed. The command execs Chez, so the pid is Chez's own
  ;; and the kill reaches the child.
  (define (level-3-run chez program names)
    (guard (e (#t (list 'spawn-failed (describe e))))
      (let-values (((to-child from-child errors pid)
                    (open-process-ports
                     (apply string-append "exec " chez " --optimize-level 3 --program "
                            program
                            (map (lambda (name) (string-append " " (symbol->string name)))
                                 names))
                     (buffer-mode block) (native-transcoder))))
        (close-port to-child)
        (let ((start (current-time 'time-monotonic)))
          (let wait ()
            (cond
              ((input-port-ready? from-child)
               (let* ((out (get-string-all from-child))
                      (err (get-string-all errors)))
                 (close-port from-child)
                 (close-port errors)
                 (let ((datum (guard (e (#t #f))
                                (read (open-string-input-port out)))))
                   (if (list? datum) datum (list 'unreadable out err)))))
              ((>= (time-second (time-difference (current-time 'time-monotonic) start))
                   level-3-deadline-seconds)
               (system (string-append "kill -9 " (number->string pid)))
               (close-port from-child)
               (close-port errors)
               'killed-at-cap)
              (else
               (sleep (make-time 'time-duration 10000000 0))
               (wait))))))))

  ;; level-3-entry : object symbol -> object
  ;; The entry KEY of a child's REPORT, or what stood in its way. Total: a
  ;; report that is a failure's shape rather than an alist, killed-at-cap or
  ;; (unreadable out err), comes back whole inside (no-entry …), where assq
  ;; would raise and SRFI-64 would swallow the raise and the child's output
  ;; with it.
  (define (level-3-entry report key)
    (let ((entry (and (list? report) (for-all pair? report) (assq key report))))
      (if entry (cdr entry) (list 'no-entry key report)))))
