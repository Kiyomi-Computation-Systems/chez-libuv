#!r6rs
;;; SRFI-64 suite for tests/uv-child.sls's runner, child-run, and
;;; tests/uv-level-3.sls's level-3-run on it, which test-addrinfo and
;;; test-process use to run their level-3 children (#88). test-loop runs its
;;; stranded child through child-run (#117). It runs
;;; tests/level-3-stand-in-child.sps, which misbehaves on purpose, under
;;; deadlines short enough for a row.
;;;
;;; Pure: the runner and the stand-in import no native code, and make
;;; check-purity runs this suite with the shim poisoned (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (uv-level-3)
        (uv-child)
        (only (chezscheme) getenv current-time time-difference time-second
              cpu-time open-process-ports sleep make-time foreign-procedure
              load-shared-object machine-type))

;; SRFI-64 sets no exit status; the runner's fail count drives it
;; (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The rows return
;; their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "level-3")

(define chez (getenv "CHEZ_LIBUV_TEST_CHEZ"))
(define stand-in "tests/level-3-stand-in-child.sps")

;; timed-run : symbol seconds -> (list report seconds milliseconds)
;; What level-3-run answered for the stand-in in MODE under DEADLINE, how
;; many whole seconds it took by the monotonic clock, and how much CPU time
;; this process spent meanwhile.
(define (timed-run mode deadline)
  (let* ((start (current-time 'time-monotonic))
         (cpu-start (cpu-time))
         (report (level-3-run chez stand-in (list mode) deadline)))
    (list report
          (time-second (time-difference (current-time 'time-monotonic) start))
          (- (cpu-time) cpu-start))))

;; How long past its deadline the runner may take to answer: it polls every
;; 10 ms, the kill is a shell's `kill -9`, and the pipes are drained for up
;; to a second after it.
(define slack-seconds 5)

;; in-time : (list report seconds milliseconds) seconds
;;           -> (list report symbol-or-list)
;; The report, and at-the-deadline if it came no sooner than DEADLINE and
;; within the slack after it, else how long it took. The lower bound holds
;; the runner to the deadline it was given: one that kills early would
;; otherwise pass, still carrying what the child printed.
(define (in-time timed deadline)
  (list (car timed)
        (if (<= deadline (cadr timed) (+ deadline slack-seconds -1))
            'at-the-deadline
            (list 'took (cadr timed) 'seconds))))

;; brief : object -> object
;; OBJECT with each string longer than 200 characters cut to its length and
;; last 40, so a failing row's evidence is not the flood child's 1 MiB.
(define (brief x)
  (cond
    ((and (string? x) (> (string-length x) 200))
     (list 'string-of (string-length x) 'ending
           (substring x (- (string-length x) 40) (string-length x))))
    ((pair? x) (cons (brief (car x)) (brief (cdr x))))
    (else x)))

;; The zombie probe, the suite's own and not the runner's: a runner whose
;; waitpid is broken must not break the check of it too.
(define libc
  (guard (e (#t (load-shared-object "libc.dylib")))
    (load-shared-object "libc.so.6")))
(define waitpid (foreign-procedure "waitpid" (int u8* int) int))

;; wait-any : -> integer
;; Reaps one finished child of this process without waiting: its pid, 0
;; while every child is still running, or -1 when there is none.
(define (wait-any)
  (waitpid -1 (make-bytevector 4 0) 1))

;; wait-any-within : -> integer
;; wait-any, polled every 10 ms for up to 5 s while it answers 0.
(define (wait-any-within)
  (let poll ((tries 500))
    (let ((r (wait-any)))
      (if (and (= r 0) (> tries 0))
          (begin (sleep (make-time 'time-duration 10000000 0))
                 (poll (- tries 1)))
          r))))

;; wait-within : pid -> integer
;; waitpid for PID without waiting, polled every 10 ms for up to 5 s while
;; it answers 0.
(define (wait-within pid)
  (let poll ((tries 500))
    (let ((r (waitpid pid (make-bytevector 4 0) 1)))
      (if (and (= r 0) (> tries 0))
          (begin (sleep (make-time 'time-duration 10000000 0))
                 (poll (- tries 1)))
          r))))

;; with-sigchld-ignored : (-> object) -> object
;; THUNK's value, called with SIGCHLD's action SIG_IGN (1 on Linux and
;; macOS), and the action before it put back after.
(define signal-action (foreign-procedure "signal" (int uptr) uptr))
(define sigchld
  (let ((machine (symbol->string (machine-type))))
    (if (string=? (substring machine (- (string-length machine) 3)
                             (string-length machine))
                  "osx")
        20
        17)))
(define (with-sigchld-ignored thunk)
  (let ((before #f))
    (dynamic-wind
      (lambda () (set! before (signal-action sigchld 1)))
      thunk
      (lambda () (signal-action sigchld before)))))

;; spawn-true : -> pid
;; Runs `true` and reads its stdout to the end, leaving it unreaped.
(define (spawn-true)
  (let-values (((to-child from-child errors pid)
                (open-process-ports "exec true" (buffer-mode block) #f)))
    (close-port to-child)
    (get-bytevector-all from-child)
    (close-port from-child)
    (close-port errors)
    pid))

;; Before any level-3 run, so the only child is the probe's own. Without
;; it, the last row's -1 could come from a probe that sees no zombies.
(test-equal "precondition: the zombie probe answers a finished child's pid"
  'saw-it
  (let* ((pid (spawn-true)) (r (wait-any-within)))
    (if (= r pid) 'saw-it (list 'got r 'for pid))))

(if (not chez)
    (test-equal "level-3 runner rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (begin
      ;; child-run hands its options to Chez ahead of --program (#117). Two
      ;; levels other than 3, so a runner that drops its options and one
      ;; that runs level 3 whatever it is given each fail a row.
      (test-equal "child-run runs the child with the options it is given"
        '((level . 2))
        (child-run chez '("--optimize-level" "2") stand-in '(level) 20))

      (test-equal "child-run with no options runs the child at Chez's default level"
        '((level . 0))
        (child-run chez '() stand-in '(level) 20))

      (test-equal "level-3-run runs the child at --optimize-level 3"
        '((level . 3))
        (level-3-run chez stand-in '(level) 20))

      ;; The deadline is long enough for any healthy child, so a runner that
      ;; leaves the child blocked on stderr is caught by what it answers,
      ;; killed-at-cap, and not by a slow machine.
      (test-equal "a child that writes 1 MiB to stderr before its datum answers the datum"
        '((stderr-bytes . 1048576))
        (brief (level-3-run chez stand-in '(flood) 20)))

      ;; 10 s leaves the stand-in time to start and print under load before
      ;; the deadline counts against it; it sleeps 60.
      (let ((stalled (timed-run 'stall 10)))
        (test-equal "a child that prints half a datum and stalls is killed at the deadline, carrying what it printed"
          '((killed-at-cap "((level . 3) (objects" "stall child: stalling\n"
                           (signal 9))
            at-the-deadline)
          (in-time stalled 10))

        ;; A runner that polls without sleeping spends the whole wait on the
        ;; CPU, 4,982 ms in a 5 s wait, and a minute for each hung child in
        ;; a real suite. One that sleeps between polls spent 13-19 ms
        ;; (2026-10-09). The wait must have lasted, or a runner that
        ;; answered early would pass whatever it spent.
        (test-equal "the runner sleeps between polls: under 1,000 ms of CPU in a 10 s wait"
          'slept
          (let ((seconds (cadr stalled)) (ms (caddr stalled)))
            (cond
              ((< seconds 10) (list 'wait-ended-after seconds 'seconds))
              ((< ms 1000) 'slept)
              (else (list 'spent ms 'ms))))))

      ;; A deadline that is not a number makes the wait raise once the
      ;; child is running: a fault after the spawn, which the runner must
      ;; not report as one in it. The child is killed and waited on.
      (test-equal "a raise while the child runs answers run-failed, not spawn-failed, with the killed child's status"
        '(run-failed (signal 9))
        (let ((report (level-3-run chez stand-in '(stall) 'not-a-number)))
          (if (and (list? report) (= (length report) 3))
              (list (car report) (caddr report))
              report)))

      (test-equal "a child that prints no datum answers unreadable, with its stdout, stderr and status"
        '(unreadable "garbage\n" "garbage child: no datum\n" (exit 0))
        (level-3-run chez stand-in '(garbage) 20))

      ;; Both pipes' end is not the child's: one that closed them and kept
      ;; running was answered unreadable at once, and left running. The
      ;; stand-in's line is the precondition: a child killed before it
      ;; closed its pipes would pass a runner that stops at their end. 10 s,
      ;; as for stall.
      (test-equal "a child that closes both pipes and keeps running is killed at the deadline"
        '((killed-at-cap "" "hush child: closing\n" (signal 9)) at-the-deadline)
        (in-time (timed-run 'hush 10) 10))

      ;; #110: a child that dies before printing anything said nothing
      ;; about why. Its status is the one datum that does.
      (test-equal "a child that exits 3 with no output answers its exit status"
        '(unreadable "" "" (exit 3))
        (level-3-run chez stand-in '(quiet-exit) 20))

      (test-equal "a child that aborts with no output answers its signal"
        '(unreadable "" "" (signal 6))
        (level-3-run chez stand-in '(abort) 20))

      ;; A datum alone is not success: the child must also exit 0.
      (test-equal "a child that prints its datum and exits 5 answers bad-exit, not the datum"
        '(bad-exit "((level . 3))\n" "" (exit 5))
        (level-3-run chez stand-in '(datum-then-exit) 20))

      ;; With SIGCHLD ignored, the system reaps each child itself, and
      ;; waitpid refuses it. A runner that took the refusal for a child
      ;; still running would wait out the deadline and kill a pid that was
      ;; no longer its child.
      (test-equal "precondition: with SIGCHLD ignored, the system reaps a finished child itself"
        'reaped-by-the-system
        (with-sigchld-ignored
         (lambda ()
           (let* ((pid (spawn-true)) (r (wait-within pid)))
             (if (= r -1) 'reaped-by-the-system (list 'waitpid-answered r 'for pid))))))

      (test-equal "a child the system reaps first answers wait-failed, not killed-at-cap"
        '(unreadable "" "" (wait-failed))
        (with-sigchld-ignored
         (lambda () (level-3-run chez stand-in '(quiet-exit) 20))))))

;; Last, after every run: a child the runner never waited on stays a zombie
;; until this process exits (#110).
(test-equal "no child is left unreaped: every run's child was waited on"
  'none-left
  (let collect ((zombies '()))
    (let ((r (wait-any)))
      (cond
        ((> r 0) (collect (cons r zombies)))
        ((and (= r -1) (null? zombies)) 'none-left)
        (else (list 'zombies (reverse zombies) 'then r))))))

(test-end "level-3")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
