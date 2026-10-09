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
          (uv-describe)
          (only (chezscheme) open-process-ports
                input-port-ready? sleep make-time system current-time
                time-difference time-second))

  ;; How long a child may run, by the monotonic clock. A healthy child takes
  ;; under a second; a poll count of 10 ms sleeps, as #69's runner kept, came
  ;; to about 81 s for 6,000 polls on macOS, whose sleeps overshoot.
  (define level-3-deadline-seconds 60)

  ;; level-3-run : string string (list-of symbol) [seconds] -> (or alist list)
  ;; The datum CHEZ printed running PROGRAM at --optimize-level 3 with NAMES
  ;; as its arguments, or why there is none: (spawn-failed text),
  ;; (unreadable out err), or (killed-at-cap out err) for a child still
  ;; running when the deadline passed. The deadline is
  ;; level-3-deadline-seconds unless given. The command execs Chez, so the
  ;; pid is Chez's own and the kill reaches the child.
  ;;
  ;; Both pipes are drained on every pass, until the child closes both or
  ;; the deadline passes (#88). A child blocked writing to a full stderr
  ;; pipe never finishes its stdout, and a read that waits for stdout's end
  ;; has no deadline: either way the suite lost the output that said why.
  (define level-3-run
    (case-lambda
      ((chez program names)
       (level-3-run chez program names level-3-deadline-seconds))
      ((chez program names deadline-seconds)
       (run-child chez program names deadline-seconds))))

  (define (run-child chez program names deadline-seconds)
    (guard (e (#t (list 'spawn-failed (describe e))))
      (let-values (((to-child from-child errors pid)
                    (open-process-ports
                     (apply string-append "exec " chez " --optimize-level 3 --program "
                            program
                            (map (lambda (name) (string-append " " (symbol->string name)))
                                 names))
                     (buffer-mode block) #f)))
        (close-port to-child)
        (let ((start (current-time 'time-monotonic)))
          ;; OUT and ERR are the chunks read so far, newest first; OUT-DONE
          ;; and ERR-DONE say each pipe has reached its end.
          (let wait ((out '()) (err '()) (out-done #f) (err-done #f))
            (cond
              ((and out-done err-done)
               (close-port from-child)
               (close-port errors)
               (finished (chunks->string out) (chunks->string err)))
              ((>= (time-second (time-difference (current-time 'time-monotonic) start))
                   deadline-seconds)
               (system (string-append "kill -9 " (number->string pid)))
               (close-port from-child)
               (close-port errors)
               (list 'killed-at-cap (chunks->string out) (chunks->string err)))
              (else
               (let ((o (if out-done #f (take-ready from-child)))
                     (e (if err-done #f (take-ready errors))))
                 (unless (or o e)
                   (sleep (make-time 'time-duration 10000000 0)))
                 (wait (if (bytevector? o) (cons o out) out)
                       (if (bytevector? e) (cons e err) err)
                       (or out-done (eof-object? o))
                       (or err-done (eof-object? e)))))))))))

  ;; take-ready : binary-input-port -> (or bytevector eof-object #f)
  ;; What PORT has without blocking: the bytes waiting in it, its end, or
  ;; #f for nothing yet. One read a pass, so a child that floods one pipe
  ;; cannot keep the other, or the deadline, from being looked at.
  (define (take-ready port)
    (and (input-port-ready? port) (get-bytevector-some port)))

  ;; chunks->string : (list-of bytevector) -> string
  ;; CHUNKS, newest first, as one string.
  (define (chunks->string chunks)
    (utf8->string
     (call-with-bytevector-output-port
      (lambda (p)
        (for-each (lambda (chunk) (put-bytevector p chunk)) (reverse chunks))))))

  ;; finished : string string -> (or list (list 'unreadable string string))
  ;; The datum a child that ran to its end printed on OUT, or why there is
  ;; none, with ERR.
  (define (finished out err)
    (let ((datum (guard (e (#t #f)) (read (open-string-input-port out)))))
      (if (list? datum) datum (list 'unreadable out err))))

  ;; level-3-entry : object symbol -> object
  ;; The entry KEY of a child's REPORT, or what stood in its way. Total: a
  ;; report that is a failure's shape rather than an alist, (killed-at-cap
  ;; out err) or (unreadable out err), comes back whole inside (no-entry …),
  ;; where assq would raise and SRFI-64 would swallow the raise and the
  ;; child's output with it.
  (define (level-3-entry report key)
    (let ((entry (and (list? report) (for-all pair? report) (assq key report))))
      (if entry (cdr entry) (list 'no-entry key report)))))
