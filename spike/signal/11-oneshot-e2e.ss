;;; spike/signal/11-oneshot-e2e.ss — SQ-S2: oneshot end-to-end. A child
;;; process arms a ONESHOT SIGTERM watcher; the parent sends SIGTERM twice.
;;; Expected: the first delivery runs the handler (graceful), the second
;;; kills the child with SIG_DFL — measuring auto-disarm + disposition
;;; reversion together (design spec §10 SQ-S2; EV-2, EV-9 in-process legs).
;;;
;;; Usage:
;;;   parent:  chez --script spike/signal/11-oneshot-e2e.ss \
;;;                 build/vendor/libuv.dylib /path/to/chez
;;;   child:   (spawned by the parent) ... --child <handshake-file>
;;;
;;; Handshake (why THREE lines, not the spec's two): the child appends
;;;   READY     after arming, before the parent may send kill #1
;;;   GOT1      from INSIDE the sigterm callback (the spec §9.3 shape)
;;;   DISARMED  from a LATER dispatch (a watchdog tick after the callback
;;;             returned)
;;; The parent gates kill #2 on DISARMED, not GOT1: per EV-9's mechanism the
;;; vendor auto-stop runs only AFTER signal_cb returns, so at the moment GOT1
;;; is written libuv's sigaction handler may still be installed and a fast
;;; kill #2 would be queued-then-dropped (stopped handle), leaving the child
;;; alive — the in-callback ack proves delivery, NOT disarm. If this matters
;;; in practice it is a finding against §9.3's two-byte handshake; either way
;;; the three-line shape is the deterministic one.
;;;
;;; SPIKE-ONLY CONSTANTS: from ./spike/signal/probe-signal;
;;; spike/dns/apply-probe-constants.sh rewrites them for the Linux CI leg.

(import (chezscheme))

(define argv (command-line-arguments))
(when (or (null? argv) (null? (cdr argv)))
  (display "usage: 11-oneshot-e2e.ss <libuv-so> (<chez-binary> | --child <handshake-file>)\n")
  (exit 2))

(define lib-path (car argv))
(define child-mode? (equal? (cadr argv) "--child"))
(define handshake-file (and child-mode? (caddr argv)))
(define chez-binary (and (not child-mode?) (cadr argv)))
(define self-script
  (let ((cl (command-line)))
    (if (pair? cl) (car cl) "spike/signal/11-oneshot-e2e.ss")))

;;; --- probe-supplied constants (spike/signal/probe-signal) -------------------
(define UV_SIGNAL                  16)
(define UV_TIMER                   13)
(define UV_PROCESS                 10)
(define UV_RUN_ONCE                 1)
(define UV_RUN_NOWAIT               2)
(define SIG_TERM                   15)
(define SIG_USR1                   30)
(define SIG_USR2                   31)
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

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()              size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size"  (int)           size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)          int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)          int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)      int))
(define uv-close        (foreign-procedure "uv_close"        (uptr uptr)     void))
(define uv-is-active    (foreign-procedure "uv_is_active"    (uptr)          int))
(define uv-signal-init  (foreign-procedure "uv_signal_init"  (uptr uptr)     int))
(define uv-signal-start (foreign-procedure "uv_signal_start" (uptr uptr int) int))
(define uv-signal-start-oneshot
                        (foreign-procedure "uv_signal_start_oneshot" (uptr uptr int) int))
(define uv-signal-stop  (foreign-procedure "uv_signal_stop"  (uptr)          int))
(define uv-spawn        (foreign-procedure "uv_spawn"        (uptr uptr uptr) int))
(define uv-timer-init   (foreign-procedure "uv_timer_init"   (uptr uptr)     int))
(define uv-timer-start  (foreign-procedure "uv_timer_start"
                                           (uptr uptr unsigned-64 unsigned-64) int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)           uptr))
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

(define (append-line! path line)
  ;; no-fail + no-truncate + append: open-or-create, keep contents, write at
  ;; the end. Without no-truncate, no-fail TRUNCATES an existing file on every
  ;; open and each "append" replaces the file (measured the hard way).
  (let ((p (open-file-output-port path (file-options no-fail no-truncate append)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p line) (put-string p "\n")
    (close-port p)))
(define (line-count path)
  (if (file-exists? path)
      (let* ((p (open-input-file path)) (s (get-string-all p)))
        (close-port p)
        (if (eof-object? s) 0
            (let loop ((i 0) (n 0))
              (if (= i (string-length s)) n
                  (loop (+ i 1) (if (char=? (string-ref s i) #\newline) (+ n 1) n))))))
      0))

(define close-fires 0)
(define close-callable
  (foreign-callable
   (lambda (h) (set! close-fires (+ close-fires 1)) (foreign-free h))
   (uptr) void))
(lock-object close-callable)
(define close-cb-ptr (foreign-callable-entry-point close-callable))

(define loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(define watchdog (alloc-zeroed (uv-handle-size UV_TIMER)))

(define STEP-CAP 400)
(define (steps-once-until! pred cap)
  (let loop ((i 0))
    (cond ((pred) i)
          ((>= i cap) #f)
          (else (uv-run loop-ptr UV_RUN_ONCE) (loop (+ i 1))))))

(define pid (c-getpid))
(define sig-size (uv-handle-size UV_SIGNAL))

;;; ============================ child mode =====================================
(when child-mode?
  (let ((got-signal 0) (disarm-written #f) (h (alloc-zeroed sig-size)))
    (define sig-callable
      (foreign-callable
       (lambda (hh signum)
         (set! got-signal (+ got-signal 1))
         (append-line! handshake-file "GOT1")   ; the spec §9.3 in-callback ack
         (collect))
       (uptr int) void))
    (define tick-callable                        ; watchdog doubles as DISARMED ack
      (foreign-callable
       (lambda (hh)
         (when (and (> got-signal 0) (not disarm-written))
           (set! disarm-written #t)
           ;; A dispatch AFTER the signal callback returned: auto-stop has run.
           (append-line! handshake-file
                         (if (zero? (uv-is-active h)) "DISARMED" "STILL-ACTIVE"))))
       (uptr) void))
    (lock-object sig-callable)
    (lock-object tick-callable)
    (uv-timer-init loop-ptr watchdog)
    (uv-timer-start watchdog (foreign-callable-entry-point tick-callable) 20 20)
    (uv-signal-init loop-ptr h)
    (let ((rc (uv-signal-start-oneshot h (foreign-callable-entry-point sig-callable)
                                       SIG_TERM)))
      (say "child pid=~d start-oneshot rc=~a\n" pid (rc-name rc))
      (unless (zero? rc) (exit 1)))
    (append-line! handshake-file "READY")
    ;; Step until killed. 2000 capped 'once steps (watchdog-bounded) is the
    ;; harness ceiling, not a wall-clock assertion: kill #2 should end this
    ;; process long before. Surviving to the cap is the SURPRISE exit 43.
    (steps-once-until! (lambda () #f) 2000)
    (say "child SURVIVED to cap: got=~d (SURPRISE)\n" got-signal)
    (exit 43)))

;;; ============================ parent mode ====================================
(define timer-tick-callable
  (foreign-callable (lambda (h) (void)) (uptr) void))
(lock-object timer-tick-callable)
(uv-timer-init loop-ptr watchdog)
(uv-timer-start watchdog (foreign-callable-entry-point timer-tick-callable) 20 20)

(say "spike/signal/11-oneshot-e2e — SQ-S2\n")
(say "machine-type   = ~s\n" (machine-type))
(say "libuv object   = ~a\n" lib-path)
(say "uv_loop_init   = ~a\n" (rc-name rc-loop-init))
(say "pid            = ~d\n\n" pid)

(define failures 0)
(define (verdict! name ok? detail)
  (unless ok? (set! failures (+ failures 1)))
  (say "~a: ~a — ~a\n" name (if ok? "AS PREDICTED" "SURPRISE") detail))

;;; --- in-process legs ---------------------------------------------------------
(define (make-sig-cb!)
  (let* ((count 0)
         (cal (foreign-callable
               (lambda (h signum) (set! count (+ count 1)) (collect))
               (uptr int) void)))
    (lock-object cal)
    (values (foreign-callable-entry-point cal) (lambda () count))))

;; Leg 1: oneshot fires once; guard counts every send; rearm OUTSIDE works.
(define-values (cbG countG) (make-sig-cb!))
(define-values (cbH countH) (make-sig-cb!))
(define G (alloc-zeroed sig-size))
(define H (alloc-zeroed sig-size))
(uv-signal-init loop-ptr G)
(uv-signal-init loop-ptr H)
(say "leg1 start G usr1 (guard)    = ~a\n" (rc-name (uv-signal-start G cbG SIG_USR1)))
(say "leg1 start-oneshot H usr1    = ~a\n" (rc-name (uv-signal-start-oneshot H cbH SIG_USR1)))
(let ((g0 (countG)))
  (c-kill pid SIG_USR1)
  (steps-once-until! (lambda () (> (countG) g0)) STEP-CAP))
(let ((g0 (countG)))
  (c-kill pid SIG_USR1)
  (steps-once-until! (lambda () (> (countG) g0)) STEP-CAP))
(say "leg1 after two kills: G=~d H=~d (predict 2/1: auto-disarm)\n" (countG) (countH))
(define leg1-stop-rc (uv-signal-stop H))
(say "leg1 stop fired-oneshot rc   = ~a (EV-2)\n" (rc-name leg1-stop-rc))
(define leg1-rearm-rc (uv-signal-start-oneshot H cbH SIG_USR1))
(let ((g0 (countG)))
  (c-kill pid SIG_USR1)
  (steps-once-until! (lambda () (> (countG) g0)) STEP-CAP))
(say "leg1 rearm-outside rc=~a; after kill: H=~d (predict 2)\n"
     (rc-name leg1-rearm-rc) (countH))
(verdict! "leg1-oneshot+rearm-outside"
          (and (= (countG) 3) (= (countH) 2)
               (zero? leg1-stop-rc) (zero? leg1-rearm-rc))
          (format "oneshot fired once per arm (H=~d over 3 kills), stop rc 0, out-of-callback rearm delivered"
                  (countH)))

;; Leg 2: EV-9 — in-callback rearm is undone by the post-callback auto-stop.
(define-values (cbG2 countG2) (make-sig-cb!))
(define G2 (alloc-zeroed sig-size))
(define H2 (alloc-zeroed sig-size))
(uv-signal-init loop-ptr G2)
(uv-signal-init loop-ptr H2)
(define h2-count 0)
(define h2-rearm-rc 'none)
(define h2-callable
  (foreign-callable
   (lambda (hh signum)
     (set! h2-count (+ h2-count 1))
     ;; the in-callback rearm attempt (same signum, oneshot verb again)
     (set! h2-rearm-rc (uv-signal-start-oneshot H2 h2-cb-ptr SIG_USR2))
     (collect))
   (uptr int) void))
(lock-object h2-callable)
(define h2-cb-ptr (foreign-callable-entry-point h2-callable))
(say "\nleg2 start G2 usr2 (guard)   = ~a\n" (rc-name (uv-signal-start G2 cbG2 SIG_USR2)))
(say "leg2 start-oneshot H2 usr2   = ~a\n" (rc-name (uv-signal-start-oneshot H2 h2-cb-ptr SIG_USR2)))
(let ((g0 (countG2)))
  (c-kill pid SIG_USR2)
  (steps-once-until! (lambda () (> (countG2) g0)) STEP-CAP))
(say "leg2 after kill 1: H2=~d in-cb rearm rc=~s active=~d\n"
     h2-count h2-rearm-rc (uv-is-active H2))
(let ((g0 (countG2)))
  (c-kill pid SIG_USR2)
  (steps-once-until! (lambda () (> (countG2) g0)) STEP-CAP))
(say "leg2 after kill 2: H2=~d G2=~d (predict 1/2: in-cb rearm undone)\n"
     h2-count (countG2))
(verdict! "EV-9"
          (and (= h2-count 1) (= (countG2) 2) (equal? h2-rearm-rc 0))
          (format "in-callback rearm returned rc ~s yet was undone by auto-stop (H2=~d after two kills)"
                  h2-rearm-rc h2-count))

;;; --- E2E: the spawned child --------------------------------------------------
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
    arr))

(define handshake (format "spike/signal/tmp-handshake-~d.txt" pid))
(when (file-exists? handshake) (delete-file handshake))

(define child-h (alloc-zeroed (uv-handle-size UV_PROCESS)))
(define stdio (alloc-zeroed (* 3 SIZEOF_UV_STDIO_CONTAINER)))
(foreign-set! 'int stdio OFFSETOF_CONTAINER_FLAGS UV_STDIO_IGNORE)
(do ((fd 1 (+ fd 1))) ((> fd 2))
  (let ((base (* fd SIZEOF_UV_STDIO_CONTAINER)))
    (foreign-set! 'int stdio (+ base OFFSETOF_CONTAINER_FLAGS) UV_STDIO_INHERIT_FD)
    (foreign-set! 'int stdio (+ base OFFSETOF_CONTAINER_DATA) fd)))
(define opts (alloc-zeroed SIZEOF_UV_PROCESS_OPTIONS))
(foreign-set! 'unsigned-64 opts OFFSETOF_OPT_EXIT_CB exit-cb-ptr)
(foreign-set! 'unsigned-64 opts OFFSETOF_OPT_FILE (c-string chez-binary))
(foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ARGS
              (c-string-array (list chez-binary "--script" self-script
                                    lib-path "--child" handshake)))
(foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ENV 0)
(foreign-set! 'unsigned-64 opts OFFSETOF_OPT_CWD 0)
(foreign-set! 'unsigned-32 opts OFFSETOF_OPT_FLAGS 0)
(foreign-set! 'int opts OFFSETOF_OPT_STDIO_COUNT 3)
(foreign-set! 'unsigned-64 opts OFFSETOF_OPT_STDIO stdio)

(define spawn-rc (uv-spawn loop-ptr child-h opts))
(say "\ne2e spawn rc = ~a\n" (rc-name spawn-rc))
(if (zero? spawn-rc)
    (let ((child-pid (foreign-ref 'int child-h OFFSETOF_PROCESS_PID)))
      (say "e2e child pid = ~d\n" child-pid)
      (let ((s-ready (steps-once-until! (lambda () (>= (line-count handshake) 1)) STEP-CAP)))
        (say "e2e READY after ~s steps\n" s-ready)
        (c-kill child-pid SIG_TERM)                          ; kill #1
        (let ((s-got (steps-once-until! (lambda () (>= (line-count handshake) 2)) STEP-CAP)))
          (say "e2e GOT1 after ~s steps\n" s-got)
          (let ((s-disarm (steps-once-until! (lambda () (>= (line-count handshake) 3)) STEP-CAP)))
            (say "e2e third line after ~s steps\n" s-disarm)
            (c-kill child-pid SIG_TERM)                      ; kill #2
            (let ((s-exit (steps-once-until! (lambda () (>= exit-fires 1)) STEP-CAP)))
              (say "e2e exit_cb after ~s steps: ~s\n" s-exit last-exit)
              (verdict! "SQ-S2-e2e"
                        (and s-ready s-got s-disarm s-exit
                             (equal? last-exit (cons 0 SIG_TERM)))
                        (format "graceful-then-killed: exit ~s (predict (0 . ~d))"
                                last-exit SIG_TERM)))))))
    (verdict! "SQ-S2-e2e" #f (format "spawn failed: ~a" (rc-name spawn-rc))))

;;; --- teardown ----------------------------------------------------------------
(define closes-before close-fires)
(uv-close child-h close-cb-ptr)
(uv-close G close-cb-ptr) (uv-close H close-cb-ptr)
(uv-close G2 close-cb-ptr) (uv-close H2 close-cb-ptr)
(uv-close watchdog close-cb-ptr)
(let loop ((i 0))
  (when (and (< i 200) (< close-fires (+ closes-before 6)))
    (uv-run loop-ptr UV_RUN_NOWAIT) (loop (+ i 1))))
(define rc-loop-close (uv-loop-close loop-ptr))
(foreign-free loop-ptr)
(when (file-exists? handshake)
  (let* ((p (open-input-file handshake)) (s (get-string-all p)))
    (close-port p)
    (say "handshake file contents:\n~a" (if (eof-object? s) "" s)))
  (delete-file handshake))

(say "\n=== SQ-S2 summary ===\n")
(say "platform (machine-type) : ~s\n" (machine-type))
(say "uv_loop_close           : ~a\n" (rc-name rc-loop-close))
(say "surprises               : ~d\n" failures)
(say "VERDICT: ~a\n" (if (zero? failures)
                         "ONESHOT E2E AS PREDICTED on this platform"
                         "SURPRISE(S) OBSERVED — see above"))
(exit 0)
