#!r6rs
;;; SRFI-64 suite for tests/uv-level-3.sls's runner, level-3-run, which
;;; test-addrinfo and test-process use to run their level-3 children (#88).
;;; It runs tests/level-3-stand-in-child.sps, which misbehaves on purpose,
;;; under deadlines short enough for a row.
;;;
;;; Pure: the runner and the stand-in import no native code, and make
;;; check-purity runs this suite with the shim poisoned (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (uv-level-3)
        (only (chezscheme) getenv current-time time-difference time-second
              cpu-time))

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

(if (not chez)
    (test-equal "level-3 runner rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (begin
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
          '((killed-at-cap "((level . 3) (objects" "stall child: stalling\n")
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
      ;; not report as one in it.
      (test-equal "a raise while the child runs answers run-failed, not spawn-failed"
        'run-failed
        (let ((report (level-3-run chez stand-in '(stall) 'not-a-number)))
          (if (pair? report) (car report) report)))

      (test-equal "a child that prints no datum answers unreadable, with its stdout and stderr"
        '(unreadable "garbage\n" "garbage child: no datum\n")
        (level-3-run chez stand-in '(garbage) 20))))

(test-end "level-3")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
