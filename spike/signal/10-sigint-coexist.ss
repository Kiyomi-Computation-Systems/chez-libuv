;;; spike/signal/10-sigint-coexist.ss — SQ-S1: does uv_signal watching SIGINT
;;; coexist with the Chez runtime's own SIGINT handling, and what disposition
;;; does uv_signal_stop leave behind? (design spec §10 SQ-S1; EV-3, EV-7)
;;;
;;; Usage:
;;;   chez --script spike/signal/10-sigint-coexist.ss \
;;;        build/vendor/libuv.dylib spike/signal/sig-probe.so [<chez-binary>]
;;;
;;; With a <chez-binary> argument the script additionally spawns two
;;; SACRIFICIAL CHILDREN (this same file in --die-leg / --die-leg-registered
;;; mode) whose death-by-SIGINT is the post-stop behavioral evidence: EV-3
;;; predicts SIG_DFL after the last watcher stops, and SIG_DFL for SIGINT
;;; terminates — so that observation must be the last act of its process.
;;;
;;; Measurements, main mode:
;;;   M1  baseline: the disposition Chez installs for SIGINT in --script mode
;;;   M2  armed:    disposition while a uv_signal watcher holds SIGINT
;;;   M3  EV-7:     kill(self,SIGINT) fires NOTHING until uv_run dispatches;
;;;                 the Chez keyboard-interrupt-handler never fires
;;;   M4  stopped:  disposition after uv_signal_stop (EV-3: SIG_DFL, i.e.
;;;                 neither Chez's baseline nor anything else restored)
;;;   M5  children: die-leg exits by SIGINT (EV-3 behaviorally); the
;;;                 -registered variant answers whether a register-signal-handler
;;;                 handler survives libuv's start/stop (predict: it does not)
;;;
;;; Discipline: iteration-capped waits with a 20ms watchdog; sentinels never
;;; #f/0; (collect) in every callback; the only SIGINT sends to a process with
;;; SIG_DFL happen in children whose death is the assertion.
;;;
;;; SPIKE-ONLY CONSTANTS: from ./spike/signal/probe-signal;
;;; spike/dns/apply-probe-constants.sh rewrites them for the Linux CI leg.

(import (chezscheme))

(define argv (command-line-arguments))
(when (or (null? argv) (null? (cdr argv)))
  (display "usage: 10-sigint-coexist.ss <libuv-so> <sig-probe-so> [--die-leg | --die-leg-registered | <chez-binary>]\n")
  (exit 2))

(define lib-path   (car argv))
(define probe-path (cadr argv))
(define mode-arg   (if (null? (cddr argv)) #f (caddr argv)))
(define die-leg?            (equal? mode-arg "--die-leg"))
(define die-leg-registered? (equal? mode-arg "--die-leg-registered"))
(define chez-binary (and mode-arg (not die-leg?) (not die-leg-registered?) mode-arg))
(define self-script
  (let ((cl (command-line)))
    (if (pair? cl) (car cl) "spike/signal/10-sigint-coexist.ss")))

;;; --- probe-supplied constants (spike/signal/probe-signal) -------------------
(define UV_SIGNAL                  16)
(define UV_TIMER                   13)
(define UV_PROCESS                 10)
(define UV_RUN_ONCE                 1)
(define UV_RUN_NOWAIT               2)
(define SIG_INT                     2)
(define SIZEOF_UV_PROCESS_OPTIONS  64)
(define OFFSETOF_OPT_EXIT_CB        0)
(define OFFSETOF_OPT_FILE           8)
(define OFFSETOF_OPT_ARGS          16)
(define OFFSETOF_OPT_ENV           24)
(define OFFSETOF_OPT_CWD           32)
(define OFFSETOF_OPT_FLAGS         40)
(define OFFSETOF_OPT_STDIO_COUNT   44)
(define OFFSETOF_OPT_STDIO         48)
(define OFFSETOF_PROCESS_PID      104)
(define SIZEOF_UV_STDIO_CONTAINER  16)
(define OFFSETOF_CONTAINER_FLAGS    0)
(define OFFSETOF_CONTAINER_DATA     8)
(define UV_STDIO_IGNORE             0)
(define UV_STDIO_INHERIT_FD         2)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)
(load-shared-object probe-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()              size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size"  (int)           size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)          int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)          int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)      int))
(define uv-close        (foreign-procedure "uv_close"        (uptr uptr)     void))
(define uv-signal-init  (foreign-procedure "uv_signal_init"  (uptr uptr)     int))
(define uv-signal-start (foreign-procedure "uv_signal_start" (uptr uptr int) int))
(define uv-signal-stop  (foreign-procedure "uv_signal_stop"  (uptr)          int))
(define uv-spawn        (foreign-procedure "uv_spawn"        (uptr uptr uptr) int))
(define uv-timer-init   (foreign-procedure "uv_timer_init"   (uptr uptr)     int))
(define uv-timer-start  (foreign-procedure "uv_timer_start"
                                           (uptr uptr unsigned-64 unsigned-64) int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)           uptr))
(define sig-disposition (foreign-procedure "spike_sig_disposition" (int)     int))
(define sig-handler-addr (foreign-procedure "spike_sig_handler_addr" (int)   unsigned-long))
(define c-kill          (foreign-procedure "kill"            (int int)       int))
(define c-getpid        (foreign-procedure "getpid"          ()              int))

;;; --- helpers ----------------------------------------------------------------
(define (c-string->string addr)
  (if (= addr 0) #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))
(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-err-name rc))))
(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p)
      (foreign-set! 'unsigned-8 p i 0))))
(define (say . args) (apply printf args) (flush-output-port (current-output-port)))
(define (disposition-name d)
  (case d ((0) "SIG_DFL") ((1) "SIG_IGN") ((2) "handler") ((3) "sa_sigaction")
    (else "sigaction-error")))
(define (report-disposition tag)
  (let ((d (sig-disposition SIG_INT)) (a (sig-handler-addr SIG_INT)))
    (say "~a: disposition=~a addr=~x\n" tag (disposition-name d) a)
    (cons d a)))

(define sig-fires 0)
(define sig-last -1)
(define sig-callable
  (foreign-callable
   (lambda (h signum)
     (set! sig-fires (+ sig-fires 1)) (set! sig-last signum) (collect))
   (uptr int) void))
(lock-object sig-callable)
(define sig-cb-ptr (foreign-callable-entry-point sig-callable))

(define close-fires 0)
(define close-callable
  (foreign-callable
   (lambda (h) (set! close-fires (+ close-fires 1)) (foreign-free h))
   (uptr) void))
(lock-object close-callable)
(define close-cb-ptr (foreign-callable-entry-point close-callable))

(define watchdog-ticks 0)
(define timer-callable
  (foreign-callable
   (lambda (h) (set! watchdog-ticks (+ watchdog-ticks 1)))
   (uptr) void))
(lock-object timer-callable)
(define timer-cb-ptr (foreign-callable-entry-point timer-callable))

(define chez-ki-fires 0)     ; Chez keyboard-interrupt-handler observations
(keyboard-interrupt-handler
 (lambda () (set! chez-ki-fires (+ chez-ki-fires 1))))

(define chez-rsh-fires 0)    ; register-signal-handler observations (die-leg-registered)

(define loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(define watchdog (alloc-zeroed (uv-handle-size UV_TIMER)))
(uv-timer-init loop-ptr watchdog)
(uv-timer-start watchdog timer-cb-ptr 20 20)

(define STEP-CAP 200)
(define (steps-once-until! pred)
  (let loop ((i 0))
    (cond ((pred) i)
          ((>= i STEP-CAP) #f)
          (else (uv-run loop-ptr UV_RUN_ONCE) (loop (+ i 1))))))

(define pid (c-getpid))

;;; ============================ die legs =======================================
;;; Sacrificial children: arm SIGINT, (optionally register a Chez handler
;;; first), stop the watcher, self-kill. If EV-3 holds (SIG_DFL) the process
;;; dies by SIGINT and the PARENT observes term_signal=SIGINT. Exit codes if
;;; it survives instead: 42 = survived, no Chez handler fired (disposition is
;;; something non-fatal but not Chez's); 44 = survived AND the registered
;;; Chez handler fired (libuv restored Chez's handling); 45 = the leg was
;;; skipped (no register-signal-handler in this Chez).
(when (or die-leg? die-leg-registered?)
  (say "die-leg~a: pid=~d\n" (if die-leg-registered? "-registered" "") pid)
  (when die-leg-registered?
    (if (top-level-bound? 'register-signal-handler)
        (begin
          ((top-level-value 'register-signal-handler)
           SIG_INT (lambda (sig) (set! chez-rsh-fires (+ chez-rsh-fires 1))))
          (report-disposition "die-leg after register-signal-handler"))
        (begin (say "die-leg: register-signal-handler UNBOUND — leg skipped\n")
               (exit 45))))
  (let ((h (alloc-zeroed (uv-handle-size UV_SIGNAL))))
    (uv-signal-init loop-ptr h)
    (say "die-leg start rc = ~a\n" (rc-name (uv-signal-start h sig-cb-ptr SIG_INT)))
    (report-disposition "die-leg armed")
    (say "die-leg stop rc  = ~a\n" (rc-name (uv-signal-stop h)))
    (report-disposition "die-leg stopped")
    (say "die-leg self-killing with SIGINT now (death expected if EV-3 holds)\n")
    (c-kill pid SIG_INT)
    ;; Only reached if SIGINT did not terminate us.
    (steps-once-until! (lambda () #f))    ; give any async handler time to run
    (say "die-leg SURVIVED: uv-cb=~d chez-ki=~d chez-rsh=~d\n"
         sig-fires chez-ki-fires chez-rsh-fires)
    (exit (if (> chez-rsh-fires 0) 44 42))))

;;; ============================ main mode ======================================
(say "spike/signal/10-sigint-coexist — SQ-S1\n")
(say "machine-type   = ~s\n" (machine-type))
(say "libuv object   = ~a\n" lib-path)
(say "uv_loop_init   = ~a\n" (rc-name rc-loop-init))
(say "pid            = ~d\n\n" pid)

(define failures 0)
(define (verdict! name ok? detail)
  (unless ok? (set! failures (+ failures 1)))
  (say "~a: ~a — ~a\n" name (if ok? "AS PREDICTED" "SURPRISE") detail))

;;; M1 baseline
(define baseline (report-disposition "M1 baseline (Chez --script)"))

;;; M2 armed
(define H (alloc-zeroed (uv-handle-size UV_SIGNAL)))
(uv-signal-init loop-ptr H)
(say "start H sigint rc = ~a\n" (rc-name (uv-signal-start H sig-cb-ptr SIG_INT)))
(define armed (report-disposition "M2 armed"))
(verdict! "M2-libuv-owns"
          (and (= (car armed) 2)
               (not (= (cdr armed) (cdr baseline))))
          (format "armed disposition is a plain handler, address differs from baseline (~x vs ~x)"
                  (cdr armed) (cdr baseline)))

;;; M3 EV-7: nothing fires inside kill(); delivery only via uv_run; Chez KI silent
(c-kill pid SIG_INT)
(define fires-at-kill sig-fires)
(define m3-steps (steps-once-until! (lambda () (>= sig-fires 1))))
(say "M3: fires-at-kill=~d after-run fires=~d last=~d steps=~s chez-ki=~d\n"
     fires-at-kill sig-fires sig-last m3-steps chez-ki-fires)
(verdict! "EV-7"
          (and (= fires-at-kill 0) (= sig-fires 1) (= sig-last SIG_INT)
               m3-steps (= chez-ki-fires 0))
          "delivery only via uv_run on the loop thread; Chez keyboard interrupt never fired")

;;; M4 EV-3 structural: stop, then read
(say "stop H rc = ~a\n" (rc-name (uv-signal-stop H)))
(define stopped (report-disposition "M4 stopped"))
(verdict! "EV-3-structural"
          (= (car stopped) 0)
          (format "post-stop disposition is ~a (predict SIG_DFL; Chez baseline was ~a@~x, NOT restored)"
                  (disposition-name (car stopped))
                  (disposition-name (car baseline)) (cdr baseline)))

;;; M5 the sacrificial children (only with a chez binary)
(define exit-fires 0)
(define last-exit 'none)
(define exit-callable
  (foreign-callable
   (lambda (h status signal)
     (set! exit-fires (+ exit-fires 1))
     (set! last-exit (cons status signal))
     (collect))
   (uptr integer-64 int) void))
(lock-object exit-callable)
(define exit-cb-ptr (foreign-callable-entry-point exit-callable))

(define (c-string s)
  (let* ((bv (string->utf8 s)) (n (bytevector-length bv))
         (p (foreign-alloc (+ n 1))))
    (do ((i 0 (+ i 1))) ((= i n))
      (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
    (foreign-set! 'unsigned-8 p n 0)
    p))
(define (c-string-array strs)
  (let* ((ptrs (map c-string strs)) (n (length ptrs))
         (arr (foreign-alloc (* 8 (+ n 1)))))
    (let loop ((i 0) (ps ptrs))
      (if (null? ps)
          (foreign-set! 'unsigned-64 arr (* 8 i) 0)
          (begin (foreign-set! 'unsigned-64 arr (* 8 i) (car ps))
                 (loop (+ i 1) (cdr ps)))))
    (values arr (cons arr ptrs))))

(define (spawn-die-leg! mode)
  ;; stdio: 0 ignored, 1/2 inherited so the child's evidence prints here.
  (let* ((args (list chez-binary "--script" self-script lib-path probe-path mode))
         (h (alloc-zeroed (uv-handle-size UV_PROCESS)))
         (stdio (alloc-zeroed (* 3 SIZEOF_UV_STDIO_CONTAINER)))
         (opts (alloc-zeroed SIZEOF_UV_PROCESS_OPTIONS)))
    (foreign-set! 'int stdio OFFSETOF_CONTAINER_FLAGS UV_STDIO_IGNORE)
    (do ((fd 1 (+ fd 1))) ((> fd 2))
      (let ((base (* fd SIZEOF_UV_STDIO_CONTAINER)))
        (foreign-set! 'int stdio (+ base OFFSETOF_CONTAINER_FLAGS) UV_STDIO_INHERIT_FD)
        (foreign-set! 'int stdio (+ base OFFSETOF_CONTAINER_DATA) fd)))
    (let-values (((argv-arr blocks) (c-string-array args)))
      (let ((file-ptr (c-string chez-binary)))
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_EXIT_CB exit-cb-ptr)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_FILE file-ptr)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ARGS argv-arr)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ENV 0)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_CWD 0)
        (foreign-set! 'unsigned-32 opts OFFSETOF_OPT_FLAGS 0)
        (foreign-set! 'int opts OFFSETOF_OPT_STDIO_COUNT 3)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_STDIO stdio)
        (let ((rc (uv-spawn loop-ptr h opts))
              (before exit-fires))
          (say "spawn ~a rc = ~a\n" mode (rc-name rc))
          (if (zero? rc)
              (let ((steps (steps-once-until! (lambda () (> exit-fires before)))))
                (let ((result last-exit)
                      (closed close-fires))
                  (uv-close h close-cb-ptr)
                  (steps-once-until! (lambda () (> close-fires closed)))
                  (say "~a exit = ~s (steps ~s)\n" mode result steps)
                  result))
              (begin (uv-close h close-cb-ptr) 'spawn-failed)))))))

(if chez-binary
    (let ((r1 (spawn-die-leg! "--die-leg")))
      (verdict! "EV-3-behavioral"
                (equal? r1 (cons 0 SIG_INT))
                (format "die-leg child exited ~s (predict (0 . ~d): killed by SIGINT)" r1 SIG_INT))
      (let ((r2 (spawn-die-leg! "--die-leg-registered")))
        (cond
         ((equal? r2 (cons 0 SIG_INT))
          (verdict! "M5-registered" #t
                    "register-signal-handler handling was NOT restored by uv_signal_stop (child died by SIGINT)"))
         ((equal? r2 (cons 45 0))
          (say "M5-registered: SKIPPED (no register-signal-handler in this Chez)\n"))
         ((equal? r2 (cons 44 0))
          (verdict! "M5-registered" #f
                    "SURPRISE: child survived and the Chez handler fired — libuv RESTORED Chez's handling"))
         (else
          (verdict! "M5-registered" #f (format "unexpected child result ~s" r2))))))
    (say "\n(no chez binary argument — M5 die-leg children skipped)\n"))

;;; --- teardown ----------------------------------------------------------------
(define closes-before-teardown close-fires)
(uv-close H close-cb-ptr)
(uv-close watchdog close-cb-ptr)
(let loop ((i 0))
  (when (and (< i 100) (< close-fires (+ closes-before-teardown 2)))
    (uv-run loop-ptr UV_RUN_NOWAIT) (loop (+ i 1))))
(define rc-loop-close (uv-loop-close loop-ptr))
(foreign-free loop-ptr)

(say "\n=== SQ-S1 summary ===\n")
(say "platform (machine-type) : ~s\n" (machine-type))
(say "chez keyboard-interrupts: ~d\n" chez-ki-fires)
(say "watchdog ticks          : ~d\n" watchdog-ticks)
(say "uv_loop_close           : ~a\n" (rc-name rc-loop-close))
(say "surprises               : ~d\n" failures)
(say "VERDICT: ~a\n" (if (zero? failures)
                         "COEXISTENCE SHAPE AS PREDICTED on this platform"
                         "SURPRISE(S) OBSERVED — see above"))
(exit 0)
