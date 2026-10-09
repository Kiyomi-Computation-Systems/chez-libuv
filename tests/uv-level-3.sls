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
;;; PURE: none of the binding's native code, so the pure suites can use it
;;; (PURE_TESTS). It loads libc for waitpid, which make check-purity allows:
;;; it poisons only the shim.
(library (uv-level-3)
  (export level-3-run level-3-entry)
  (import (rnrs)
          (uv-describe)
          (only (chezscheme) open-process-ports
                input-port-ready? sleep make-time system current-time
                add-duration time>=? foreign-procedure load-shared-object))

  ;; open-process-ports gives the child's pid and nothing that waits on it,
  ;; so the runner waits through libc (#110). Loaded ahead of the binding
  ;; below: foreign-procedure resolves its entry when it is evaluated.
  (define libc
    (guard (e (#t (load-shared-object "libc.dylib")))
      (load-shared-object "libc.so.6")))

  (define waitpid (foreign-procedure "waitpid" (int u8* int) int))

  ;; WNOHANG, 1 on Linux and on macOS.
  (define wnohang 1)

  ;; How long a child may run, by the monotonic clock. A healthy child takes
  ;; under a second; a poll count of 10 ms sleeps, as #69's runner kept, came
  ;; to about 81 s for 6,000 polls on macOS, whose sleeps overshoot.
  (define level-3-deadline-seconds 60)

  ;; level-3-run : string string (list-of symbol) [seconds] -> (or alist list)
  ;; The datum CHEZ printed running PROGRAM at --optimize-level 3 with NAMES
  ;; as its arguments, if it then exited 0, or why there is none:
  ;;   (spawn-failed text)
  ;;   (unreadable out err status) for a child that ended with no datum
  ;;   (bad-exit out err status) for one that printed its datum but did
  ;;     not exit 0
  ;;   (killed-at-cap out err status) for a child still running when the
  ;;     deadline passed
  ;;   (run-failed text status) for a raise while it ran, after which the
  ;;     child is killed too.
  ;; A status is (exit code), (signal number), (not-reaped) for a child
  ;; that had not ended a second after its kill, or (wait-failed). Every
  ;; child that ends is waited on, so none is left a zombie (#110). The
  ;; deadline is level-3-deadline-seconds unless given. The command execs
  ;; Chez, so the pid is Chez's own: the kill reaches the child, and the
  ;; status is its own.
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
       (let ((spawned
              (guard (e (#t (list 'spawn-failed (describe e))))
                (let-values (((to-child from-child errors pid)
                              (open-process-ports
                               (apply string-append
                                      "exec " chez " --optimize-level 3 --program " program
                                      (map (lambda (name)
                                             (string-append " " (symbol->string name)))
                                           names))
                               (buffer-mode block) #f)))
                  (close-port to-child)
                  (list from-child errors pid)))))
         (if (eq? (car spawned) 'spawn-failed)
             spawned
             (apply (lambda (from-child errors pid)
                      (watch from-child errors pid deadline-seconds))
                    spawned))))))

  ;; How long the pipes are drained after the kill, for what the child wrote
  ;; since the last pass and what the pipes still hold, and then how long
  ;; the child is waited on. The kill closes the child's ends, so the drain
  ;; ends sooner unless something else holds them.
  (define drain-after-kill-seconds 1)

  ;; watch : port port pid seconds -> (or alist list)
  ;; level-3-run's report for the child PID, whose stdout and stderr are
  ;; FROM-CHILD and ERRORS.
  ;;
  ;; A child that closes both pipes may still be running, so its end is its
  ;; reaping, by the same deadline. Once reaped, its pid is free for the
  ;; system to reuse, so nothing kills it after that: STATUS records it.
  (define (watch from-child errors pid deadline-seconds)
    (let ((status #f))
      (guard (e (#t (unless status (kill! pid))
                    (close-quietly from-child)
                    (close-quietly errors)
                    (list 'run-failed (describe e) (or status (reap-killed pid)))))
        (let ((until (seconds-from-now deadline-seconds)))
          (let-values (((out err out-done err-done)
                        (collect from-child errors '() '() #f #f until)))
            (set! status (and out-done err-done (reap pid until)))
            (if status
                (begin
                  (close-port from-child)
                  (close-port errors)
                  (finished (chunks->string out) (chunks->string err) status))
                (begin
                  (kill! pid)
                  (let-values (((out err out-done err-done)
                                (collect from-child errors out err out-done err-done
                                         (seconds-from-now drain-after-kill-seconds))))
                    (close-port from-child)
                    (close-port errors)
                    (set! status (reap-killed pid))
                    (list 'killed-at-cap (chunks->string out) (chunks->string err)
                          status)))))))))

  ;; seconds-from-now : seconds -> time
  (define (seconds-from-now seconds)
    (add-duration (current-time 'time-monotonic)
                  (make-time 'time-duration 0 seconds)))

  ;; reap : pid time -> (or status #f)
  ;; PID's status once it has ended, polled every 10 ms until the monotonic
  ;; clock reaches UNTIL, or #f if it is still running then.
  (define (reap pid until)
    (let poll ()
      (or (try-reap pid)
          (and (not (time>=? (current-time 'time-monotonic) until))
               (begin
                 (sleep (make-time 'time-duration 10000000 0))
                 (poll))))))

  ;; reap-killed : pid -> status
  ;; The status of PID, just sent SIGKILL.
  (define (reap-killed pid)
    (or (reap pid (seconds-from-now drain-after-kill-seconds))
        '(not-reaped)))

  ;; try-reap : pid -> (or status #f)
  ;; PID's status if it has ended, reaping it, or #f if it is still
  ;; running. Raises nothing: it also runs from watch's handler.
  (define (try-reap pid)
    (guard (e (#t '(wait-failed)))
      (let* ((cell (make-bytevector 4 0))
             (r (waitpid pid cell wnohang)))
        (cond
          ((= r pid) (decode-status (bytevector-s32-native-ref cell 0)))
          ((= r 0) #f)
          (else '(wait-failed))))))

  ;; decode-status : integer -> status
  ;; A wait status as (exit code) or (signal number), by the encoding Linux
  ;; and macOS share: the low 7 bits are the terminating signal, 0 for an
  ;; exit, whose code is the next 8. A stopped child is not reported
  ;; without WUNTRACED.
  (define (decode-status raw)
    (let ((signal (bitwise-and raw #x7f)))
      (if (zero? signal)
          (list 'exit (bitwise-and (bitwise-arithmetic-shift-right raw 8) #xff))
          (list 'signal signal))))

  ;; collect : port port chunks chunks boolean boolean time
  ;;           -> (values chunks chunks boolean boolean)
  ;; Reads FROM-CHILD and ERRORS until both have ended or the monotonic
  ;; clock reaches UNTIL. OUT and ERR are the chunks read so far, newest
  ;; first; OUT-DONE and ERR-DONE say each pipe has reached its end.
  (define (collect from-child errors out err out-done err-done until)
    (let pass ((out out) (err err) (out-done out-done) (err-done err-done))
      (if (or (and out-done err-done)
              (time>=? (current-time 'time-monotonic) until))
          (values out err out-done err-done)
          (let ((o (if out-done #f (take-ready from-child)))
                (e (if err-done #f (take-ready errors))))
            (unless (or o e)
              (sleep (make-time 'time-duration 10000000 0)))
            (pass (if (bytevector? o) (cons o out) out)
                  (if (bytevector? e) (cons e err) err)
                  (or out-done (eof-object? o))
                  (or err-done (eof-object? e)))))))

  ;; kill! : pid -> unspecified
  ;; Sends PID SIGKILL. Raises nothing: it also runs from watch's handler.
  (define (kill! pid)
    (guard (e (#t #f))
      (system (string-append "kill -9 " (number->string pid) " 2>/dev/null"))))

  ;; close-quietly : port -> unspecified
  (define (close-quietly port)
    (guard (e (#t #f)) (close-port port)))

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

  ;; finished : string string status
  ;;           -> (or list (list symbol string string status))
  ;; The datum a child that ended with STATUS printed on OUT, if it exited
  ;; 0, or why there is none, with ERR.
  (define (finished out err status)
    (let ((datum (guard (e (#t #f)) (read (open-string-input-port out)))))
      (cond
        ((not (list? datum)) (list 'unreadable out err status))
        ((equal? status '(exit 0)) datum)
        (else (list 'bad-exit out err status)))))

  ;; level-3-entry : object symbol -> object
  ;; The entry KEY of a child's REPORT, or what stood in its way. Total: a
  ;; report that is a failure's shape rather than an alist, such as
  ;; (killed-at-cap out err status) or (unreadable out err status), comes
  ;; back whole inside (no-entry …), where assq would raise and SRFI-64
  ;; would swallow the raise and the child's output with it.
  (define (level-3-entry report key)
    (let ((entry (and (list? report) (for-all pair? report) (assq key report))))
      (if entry (cdr entry) (list 'no-entry key report)))))
