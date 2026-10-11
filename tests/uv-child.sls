#!r6rs
;;; Running a child Chez program under a deadline, and reading the one datum
;;; it prints. tests/uv-level-3.sls runs its children at --optimize-level 3
;;; through it (test-addrinfo, test-process), and tests/test-loop.sps runs
;;; tests/stranded-exit-child.sps, whose teardown libuv cannot finish (#117).
;;;
;;; A child runs in a process of its own when what it does cannot be undone
;;; or contained in the suite's: a hang no guard or engine can stop, or a
;;; loop left allocated for good. It is killed if it is still running at the
;;; deadline, and prints one datum, an alist, for its suite's rows.
;;;
;;; PURE: none of the binding's native code, so the pure suites can use it
;;; (PURE_TESTS). It loads libc for waitpid, which make check-purity allows:
;;; it poisons only the shim. Where libc does not load, every status is
;;; (wait-unavailable), so the rows fail carrying it: the import itself must
;;; not raise, or every row of a suite that imports it is lost with it.
(library (uv-child)
  (export child-run child-entry)
  (import (rnrs)
          (uv-describe)
          (only (chezscheme) open-process-ports
                input-port-ready? sleep make-time system current-time
                add-duration time>=? foreign-procedure load-shared-object
                foreign-ref collect-request-handler void
                with-interrupts-disabled make-mutex mutex-acquire
                mutex-release))

  ;; waitpid, or #f where libc did not load. open-process-ports gives the
  ;; child's pid and nothing that waits on it, so the runner waits through
  ;; libc (#110). The load comes first: foreign-procedure resolves its entry
  ;; when it is evaluated.
  (define waitpid
    (guard (e (#t #f))
      (let load ((names '("libc.so.6" "libc.dylib" "libc.so")))
        (guard (e ((pair? (cdr names)) (load (cdr names))))
          (load-shared-object (car names))))
      (foreign-procedure "waitpid" (int u8* int) int)))

  ;; WNOHANG, 1 on Linux and on macOS.
  (define wnohang 1)

  ;; errno-location : (or (-> uptr) #f)
  ;; The address of the calling thread's errno: glibc's __errno_location,
  ;; macOS's __error, or #f where neither resolves. A wait that fails says
  ;; why with it (#128).
  (define errno-location
    (and waitpid
         (guard (e (#t #f))
           (let try ((names '("__errno_location" "__error")))
             (guard (e ((pair? (cdr names)) (try (cdr names))))
               (foreign-procedure (car names) () uptr))))))

  ;; errno-name : integer -> object
  ;; ECHILD, 10 on Linux and on macOS, by its name: the refusal a WNOHANG
  ;; wait for a pid it has already given up answers. Any other errno stays
  ;; a number.
  (define (errno-name n)
    (if (= n 10) 'ECHILD n))

  ;; How long a child may run, by the monotonic clock. A healthy child takes
  ;; under a second; a poll count of 10 ms sleeps, as #69's runner kept, came
  ;; to about 81 s for 6,000 polls on macOS, whose sleeps overshoot.
  (define child-deadline-seconds 60)

  ;; child-run : string (list-of string) string (list-of symbol) [seconds]
  ;;             -> (or alist list)
  ;; The datum CHEZ printed running PROGRAM with OPTIONS before --program and
  ;; NAMES as its arguments, if it then exited 0, or why there is none. Each
  ;; option and name reaches the shell as it is, unquoted:
  ;;   (spawn-failed text)
  ;;   (unreadable out err status) for a child that ended with no datum
  ;;   (bad-exit out err status) for one that printed its datum but did
  ;;     not exit 0
  ;;   (killed-at-cap out err status) for a child still running when the
  ;;     deadline passed
  ;;   (run-failed text status) for a raise while it ran, after which the
  ;;     child is killed too.
  ;; A status is (exit code), (signal number), (not-reaped) for a child
  ;; that had not ended a second after its kill, (wait-failed errno) for a
  ;; waitpid that refused, with errno's name (ECHILD, as for a child the
  ;; system reaped itself with SIGCHLD ignored) or number, or #f where it
  ;; could not be read, (wait-raised text) for a raise while waiting, or
  ;; (wait-unavailable) where libc did not load. Only (exit 0) lets a
  ;; datum through. Every child that ends is waited on, so none is left a
  ;; zombie (#110).
  ;;
  ;; No collection runs while a child does. Chez records each child
  ;; open-process-ports starts, and every collection reaps those that have
  ;; ended, keeping no status (c/gc.c); one between the child's end and the
  ;; runner's wait left the wait ECHILD (#128). Collections are deferred
  ;; through collect-request-handler, for every thread, from the spawn to
  ;; the last wait, and the handler put back once no run is left. An
  ;; explicit collect meanwhile, on any thread, can still take the status,
  ;; and an engine dropped inside a run leaves collections off for good:
  ;; child-run is not for engines. The
  ;; deadline is child-deadline-seconds unless given. The command execs
  ;; Chez, so the pid is Chez's own: the kill reaches the child, and the
  ;; status is its own.
  ;;
  ;; Both pipes are drained on every pass, until the child closes both or
  ;; the deadline passes (#88). A child blocked writing to a full stderr
  ;; pipe never finishes its stdout, and a read that waits for stdout's end
  ;; has no deadline: either way the suite lost the output that said why.
  (define child-run
    (case-lambda
      ((chez options program names)
       (child-run chez options program names child-deadline-seconds))
      ((chez options program names deadline-seconds)
       (without-collections
        (lambda ()
         (let ((spawned
                (guard (e (#t (list 'spawn-failed (describe e))))
                  (let-values (((to-child from-child errors pid)
                                (open-process-ports
                                 (apply string-append
                                        "exec " chez
                                        (append
                                         (map (lambda (option) (string-append " " option))
                                              options)
                                         (list " --program " program)
                                         (map (lambda (name)
                                                (string-append " " (symbol->string name)))
                                              names)))
                                 (buffer-mode block) #f)))
                    (close-port to-child)
                    (list from-child errors pid)))))
           (if (eq? (car spawned) 'spawn-failed)
               spawned
               (apply (lambda (from-child errors pid)
                        (watch from-child errors pid deadline-seconds))
                      spawned))))))))

  ;; The runs under way on every thread, and the collect-request-handler
  ;; the first of them found. Runs on two threads need not end in the order
  ;; they began, so the handler goes back when the last run ends, not when
  ;; each does. deferral-lock is taken and released with interrupts
  ;; disabled, so no engine or collection stops a thread holding it.
  (define deferral-lock (make-mutex))
  (define runs-deferring 0)
  (define handler-found #f)

  ;; without-collections : (-> object) -> object
  ;; THUNK's value, called with every collection request dropped until no
  ;; run is left.
  (define (without-collections thunk)
    (dynamic-wind
      (lambda ()
        (with-interrupts-disabled
         (mutex-acquire deferral-lock)
         (when (= runs-deferring 0)
           (set! handler-found (collect-request-handler))
           (collect-request-handler void))
         (set! runs-deferring (+ runs-deferring 1))
         (mutex-release deferral-lock)))
      thunk
      (lambda ()
        (with-interrupts-disabled
         (mutex-acquire deferral-lock)
         (set! runs-deferring (- runs-deferring 1))
         (when (= runs-deferring 0)
           (collect-request-handler handler-found)
           (set! handler-found #f))
         (mutex-release deferral-lock)))))

  ;; How long the pipes are drained after the kill, for what the child wrote
  ;; since the last pass and what the pipes still hold, and then how long
  ;; the child is waited on. The kill closes the child's ends, so the drain
  ;; ends sooner unless something else holds them.
  (define drain-after-kill-seconds 1)

  ;; watch : port port pid seconds -> (or alist list)
  ;; child-run's report for the child PID, whose stdout and stderr are
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
    (guard (e (#t (list 'wait-raised (describe e))))
      (if (not waitpid)
          '(wait-unavailable)
          (let ((cell (make-bytevector 4 0)))
            (let-values (((r errno) (wait-once pid cell)))
              (cond
                ((= r pid) (decode-status (bytevector-s32-native-ref cell 0)))
                ((= r 0) #f)
                (else (list 'wait-failed (and errno (errno-name errno))))))))))

  ;; wait-once : pid bytevector -> (values integer (or integer #f))
  ;; waitpid's answer for PID with WNOHANG, its status in CELL, and errno
  ;; read straight after it, or #f where errno cannot be read. Interrupts
  ;; are disabled between the two, so no timer, engine or keyboard handler
  ;; runs there and makes a call that sets errno.
  (define (wait-once pid cell)
    (with-interrupts-disabled
     (let* ((r (waitpid pid cell wnohang))
            (errno (and errno-location (foreign-ref 'int (errno-location) 0))))
       (values r errno))))

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

  ;; child-entry : object symbol -> object
  ;; The entry KEY of a child's REPORT, or what stood in its way. Total: a
  ;; report that is a failure's shape rather than an alist, such as
  ;; (killed-at-cap out err status) or (unreadable out err status), comes
  ;; back whole inside (no-entry …), where assq would raise and SRFI-64
  ;; would swallow the raise and the child's output with it.
  (define (child-entry report key)
    (let ((entry (and (list? report) (for-all pair? report) (assq key report))))
      (if entry (cdr entry) (list 'no-entry key report)))))
