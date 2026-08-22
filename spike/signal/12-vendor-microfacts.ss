;;; spike/signal/12-vendor-microfacts.ss — SQ-S3: the vendor micro-facts the
;;; v0.4 signal design rests on, measured in one process against the pinned
;;; libuv (design spec §7: EV-1, EV-2, EV-4, EV-5 + resurrect corollary,
;;; EV-6, EV-8 both directions, EV-10).
;;;
;;; Usage:
;;;   chez --script spike/signal/12-vendor-microfacts.ss \
;;;        build/vendor/libuv.dylib
;;;
;;; Discipline (AGENTS.md / v0.2 lesson): every wait is ITERATION-capped,
;;; never wall-clock; a repeating 20ms watchdog timer guarantees every
;;; `uv_run ONCE` returns; sentinels are never #f/0; every callback calls
;;; (collect). Every self-send happens while at least one GUARD watcher is
;;; armed on the sent signum, so no delivery ever lands on SIG_DFL (§9.2's
;;; rule, applied to the spike itself).
;;;
;;; SPIKE-ONLY CONSTANTS: every (define NAME <int>) below comes from
;;; ./spike/signal/probe-signal; spike/dns/apply-probe-constants.sh
;;; rewrites them for the Linux CI leg. Legal IN THE SPIKE ONLY (ADR-0005).

(import (chezscheme))

(define argv (command-line-arguments))
(define lib-path
  (if (null? argv)
      (begin (display "usage: 12-vendor-microfacts.ss <libuv shared object>\n")
             (exit 2))
      (car argv)))

;;; --- probe-supplied constants (spike/signal/probe-signal) -------------------
(define UV_SIGNAL      16)
(define UV_TIMER       13)
(define UV_RUN_ONCE     1)
(define UV_RUN_NOWAIT   2)
(define SIG_USR1       30)
(define SIG_USR2       31)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size     (foreign-procedure "uv_loop_size"     ()              size_t))
(define uv-handle-size   (foreign-procedure "uv_handle_size"   (int)           size_t))
(define uv-loop-init     (foreign-procedure "uv_loop_init"     (uptr)          int))
(define uv-loop-close    (foreign-procedure "uv_loop_close"    (uptr)          int))
(define uv-loop-alive    (foreign-procedure "uv_loop_alive"    (uptr)          int))
(define uv-run           (foreign-procedure "uv_run"           (uptr int)      int))
(define uv-close         (foreign-procedure "uv_close"         (uptr uptr)     void))
(define uv-is-active     (foreign-procedure "uv_is_active"     (uptr)          int))
(define uv-signal-init   (foreign-procedure "uv_signal_init"   (uptr uptr)     int))
(define uv-signal-start  (foreign-procedure "uv_signal_start"  (uptr uptr int) int))
(define uv-signal-start-oneshot
                         (foreign-procedure "uv_signal_start_oneshot" (uptr uptr int) int))
(define uv-signal-stop   (foreign-procedure "uv_signal_stop"   (uptr)          int))
(define uv-timer-init    (foreign-procedure "uv_timer_init"    (uptr uptr)     int))
(define uv-timer-start   (foreign-procedure "uv_timer_start"
                                            (uptr uptr unsigned-64 unsigned-64) int))
(define uv-err-name      (foreign-procedure "uv_err_name"      (int)           uptr))
(define c-kill           (foreign-procedure "kill"             (int int)       int))
(define c-getpid         (foreign-procedure "getpid"           ()              int))

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

;;; One locked callable per watcher (spike-only; the binding uses one per
;;; TYPE, ADR-0008 — per-instance is fine for throwaway probes).
(define (make-sig-cb!)
  (let* ((count 0) (last -1)
         (cal (foreign-callable
               (lambda (h signum)
                 (set! count (+ count 1)) (set! last signum) (collect))
               (uptr int) void)))
    (lock-object cal)
    (values (foreign-callable-entry-point cal)
            (lambda () count)
            (lambda () last))))

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

;;; --- loop + watchdog --------------------------------------------------------
(define loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(define sig-size (uv-handle-size UV_SIGNAL))
(define watchdog (alloc-zeroed (uv-handle-size UV_TIMER)))
(uv-timer-init loop-ptr watchdog)
(uv-timer-start watchdog timer-cb-ptr 20 20)

(define STEP-CAP 400)

(define (steps-once-until! pred)      ; => steps taken, or #f capped out
  (let loop ((i 0))
    (cond ((pred) i)
          ((>= i STEP-CAP) #f)
          (else (uv-run loop-ptr UV_RUN_ONCE) (loop (+ i 1))))))
(define (steps-nowait-until! pred)
  (let loop ((i 0))
    (cond ((pred) i)
          ((>= i STEP-CAP) #f)
          (else (uv-run loop-ptr UV_RUN_NOWAIT) (loop (+ i 1))))))

(define (make-signal!)               ; init'd, not started
  (let ((h (alloc-zeroed sig-size)))
    (let ((rc (uv-signal-init loop-ptr h)))
      (unless (zero? rc) (say "FATAL uv_signal_init ~a\n" (rc-name rc)) (exit 1))
      h)))
(define (close-and-drain! h)
  (let ((before close-fires))
    (uv-close h close-cb-ptr)
    (steps-once-until! (lambda () (> close-fires before)))))

(define pid (c-getpid))
(define (kill-self! signum) (c-kill pid signum))

(define failures 0)
(define (verdict! name ok? detail)
  (unless ok? (set! failures (+ failures 1)))
  (say "~a: ~a — ~a\n" name (if ok? "AS PREDICTED" "SURPRISE") detail))

(say "spike/signal/12-vendor-microfacts — SQ-S3\n")
(say "machine-type   = ~s\n" (machine-type))
(say "libuv object   = ~a\n" lib-path)
(say "uv_loop_init   = ~a\n" (rc-name rc-loop-init))
(say "pid            = ~d\n\n" pid)

;;; === Section 1: EV-6 — two watchers, one signum, one delivery ===============
;;; A and B stay armed on SIGUSR1 for the whole script: they are the findings
;;; for EV-6 here and the GUARD watchers for every later SIGUSR1 send.
(define-values (cbA countA lastA) (make-sig-cb!))
(define-values (cbB countB lastB) (make-sig-cb!))
(define A (make-signal!))
(define B (make-signal!))
(say "s1 start A usr1              = ~a\n" (rc-name (uv-signal-start A cbA SIG_USR1)))
(say "s1 start B usr1              = ~a\n" (rc-name (uv-signal-start B cbB SIG_USR1)))
(kill-self! SIG_USR1)
(define s1-steps (steps-once-until! (lambda () (and (>= (countA) 1) (>= (countB) 1)))))
(say "s1 steps                     = ~s  A=~d B=~d lastA=~d lastB=~d\n"
     s1-steps (countA) (countB) (lastA) (lastB))
(verdict! "EV-6"
          (and s1-steps (= (countA) 1) (= (countB) 1)
               (= (lastA) SIG_USR1) (= (lastB) SIG_USR1))
          (format "both watchers fired once on one delivery (A=~d B=~d)" (countA) (countB)))

;;; === Section 2: EV-1a — continuous rearm across a signum change =============
;;; C: usr1 -> usr2 while armed. After the switch C is also the USR2 guard.
(define-values (cbC countC lastC) (make-sig-cb!))
(define C (make-signal!))
(say "\ns2 start C usr1              = ~a\n" (rc-name (uv-signal-start C cbC SIG_USR1)))
(kill-self! SIG_USR1)
(steps-once-until! (lambda () (>= (countC) 1)))
(say "s2 C after usr1 kill         = ~d\n" (countC))
(define s2-switch-rc (uv-signal-start C cbC SIG_USR2))
(say "s2 re-start C usr2 (armed)   = ~a\n" (rc-name s2-switch-rc))
(let ((a0 (countA)) (c0 (countC)))
  (kill-self! SIG_USR1)                       ; old signum: guards count, C must not
  (steps-once-until! (lambda () (> (countA) a0)))
  (let ((c-after-old (countC)))
    (kill-self! SIG_USR2)                     ; new signum: C counts
    (let ((s2-steps (steps-once-until! (lambda () (> (countC) c0)))))
      (say "s2 old-signum: C ~d -> ~d (guard A advanced); new-signum: C=~d steps=~s\n"
           c0 c-after-old (countC) s2-steps)
      (verdict! "EV-1a"
                (and (zero? s2-switch-rc) (= c-after-old c0) (= (countC) (+ c0 1))
                     (= (lastC) SIG_USR2))
                (format "signum-change rearm: rc=~a, old signum silent, new delivered"
                        (rc-name s2-switch-rc))))))

;;; === Section 3: EV-1b — same-signum restart swaps callback, keeps pending ===
(define-values (cbX countX lastX) (make-sig-cb!))
(define-values (cbY countY lastY) (make-sig-cb!))
(define D (make-signal!))
(say "\ns3 start D usr2 (cbX)        = ~a\n" (rc-name (uv-signal-start D cbX SIG_USR2)))
(let ((c0 (countC)))
  (kill-self! SIG_USR2)                       ; pending: handler ran inside kill
  (let ((s3-swap-rc (uv-signal-start D cbY SIG_USR2)))   ; same signum, BEFORE run
    (say "s3 re-start D usr2 (cbY, pre-run) = ~a\n" (rc-name s3-swap-rc))
    (let ((s3-steps (steps-once-until! (lambda () (> (countC) c0)))))
      (say "s3 steps=~s cbX=~d cbY=~d (guard C ~d -> ~d)\n"
           s3-steps (countX) (countY) c0 (countC))
      (verdict! "EV-1b"
                (and (zero? s3-swap-rc) (= (countX) 0) (= (countY) 1))
                (format "same-signum swap kept the pending delivery for the NEW callback (cbX=~d cbY=~d)"
                        (countX) (countY))))))
(close-and-drain! D)

;;; === Section 4: EV-5 — send -> stop -> run suppression =======================
(define-values (cbE countE lastE) (make-sig-cb!))
(define-values (cbF countF lastF) (make-sig-cb!))
(define E (make-signal!))
(define F (make-signal!))
(say "\ns4 start E usr1              = ~a\n" (rc-name (uv-signal-start E cbE SIG_USR1)))
(say "s4 start F usr1              = ~a\n" (rc-name (uv-signal-start F cbF SIG_USR1)))
(let ((f0 (countF)))
  (kill-self! SIG_USR1)                       ; accepted: handler ran inside kill
  (let* ((s4-stop-rc (uv-signal-stop E))      ; stop E BEFORE the next run
         (s4-steps (steps-once-until! (lambda () (> (countF) f0)))))
    (say "s4 stop E pre-run rc=~a; steps=~s E=~d F-delta=~d\n"
         (rc-name s4-stop-rc) s4-steps (countE) (- (countF) f0))
    (verdict! "EV-5"
              (and (zero? s4-stop-rc) s4-steps (= (countE) 0) (= (- (countF) f0) 1))
              (format "pending delivery suppressed for stopped E (E=~d) while F got it" (countE)))))

;;; === Section 5: EV-5 corollary — same-signum rearm resurrects pre-stop send ==
(define-values (cbG countG lastG) (make-sig-cb!))
(define G (make-signal!))
(say "\ns5 start G usr2              = ~a\n" (rc-name (uv-signal-start G cbG SIG_USR2)))
(let ((c0 (countC)))
  (kill-self! SIG_USR2)                       ; pending for G and guard C
  (uv-signal-stop G)                          ; stop ...
  (let* ((s5-rearm-rc (uv-signal-start G cbG SIG_USR2)) ; ... rearm same signum, pre-run
         (s5-steps (steps-once-until! (lambda () (> (countC) c0)))))
    (say "s5 rearm rc=~a steps=~s G=~d (resurrected? ~s)\n"
         (rc-name s5-rearm-rc) s5-steps (countG) (= (countG) 1))
    ;; The spec's §6 note PREDICTS resurrection (dispatch-time comparison, not
    ;; a purge). Either observed answer is a finding; record which.
    (verdict! "EV-5-corollary"
              (and (zero? s5-rearm-rc) s5-steps (= (countG) 1))
              (format "pre-stop delivery ~a a same-signum rearm (G=~d)"
                      (if (= (countG) 1) "RESURRECTED by" "stayed suppressed despite")
                      (countG)))))
(close-and-drain! G)
(close-and-drain! E)
(close-and-drain! F)

;;; === Section 6: EV-8a — continuous verb on a once-oneshot handle =============
(define-values (cbI countI lastI) (make-sig-cb!))
(define I (make-signal!))
(say "\ns6 start-oneshot I usr1      = ~a\n" (rc-name (uv-signal-start-oneshot I cbI SIG_USR1)))
(let ((a0 (countA)))
  (kill-self! SIG_USR1)
  (steps-once-until! (lambda () (> (countA) a0))))
(say "s6 I after oneshot fire      = ~d (active=~d)\n" (countI) (uv-is-active I))
(define s6-restart-rc (uv-signal-start I cbI SIG_USR1))  ; CONTINUOUS verb
(say "s6 re-start I continuous rc  = ~a (active=~d)\n" (rc-name s6-restart-rc) (uv-is-active I))
(let ((a0 (countA)))
  (kill-self! SIG_USR1)
  (steps-once-until! (lambda () (> (countA) a0))))
(define s6-i-after-1 (countI))
(let ((a0 (countA)))
  (kill-self! SIG_USR1)
  (steps-once-until! (lambda () (> (countA) a0))))
(say "s6 I after kills 1/2         = ~d / ~d (predict 2/2: the ONE_SHOT ratchet)\n"
     s6-i-after-1 (countI))
(verdict! "EV-8a"
          (and (zero? s6-restart-rc) (= s6-i-after-1 2) (= (countI) 2))
          (format "'continuous' restart of a once-oneshot handle fired once then disarmed (I=~d after two kills)"
                  (countI)))
(close-and-drain! I)

;;; === Section 7: EV-8b — oneshot verb on an armed same-signum continuous ======
(define-values (cbJ countJ lastJ) (make-sig-cb!))
(define J (make-signal!))
(say "\ns7 start J usr2 (continuous) = ~a\n" (rc-name (uv-signal-start J cbJ SIG_USR2)))
(define s7-oneshot-rc (uv-signal-start-oneshot J cbJ SIG_USR2))  ; same signum, armed
(say "s7 start-oneshot J usr2 rc   = ~a\n" (rc-name s7-oneshot-rc))
(let ((c0 (countC)))
  (kill-self! SIG_USR2)
  (steps-once-until! (lambda () (> (countC) c0))))
(define s7-j-after-1 (countJ))
(let ((c0 (countC)))
  (kill-self! SIG_USR2)
  (steps-once-until! (lambda () (> (countC) c0))))
(say "s7 J after kills 1/2         = ~d / ~d (predict 1/2: stayed CONTINUOUS)\n"
     s7-j-after-1 (countJ))
(verdict! "EV-8b"
          (and (zero? s7-oneshot-rc) (= s7-j-after-1 1) (= (countJ) 2))
          (format "'oneshot' restart of an armed same-signum continuous stayed continuous (J=~d after two kills)"
                  (countJ)))
(close-and-drain! J)

;;; === Section 8: EV-2 — stop on never-started / repeated stop =================
(define K (make-signal!))
(define s8-rc1 (uv-signal-stop K))
(define s8-rc2 (uv-signal-stop K))
(say "\ns8 stop never-started rc     = ~a, again = ~a\n" (rc-name s8-rc1) (rc-name s8-rc2))
(verdict! "EV-2" (and (zero? s8-rc1) (zero? s8-rc2)) "stop is rc 0 on never-started, idempotent")
(close-and-drain! K)

;;; === Section 9: EV-10 — close with a delivery pending ========================
(define-values (cbL countL lastL) (make-sig-cb!))
(define L (make-signal!))
(say "\ns9 start L usr1              = ~a\n" (rc-name (uv-signal-start L cbL SIG_USR1)))
(let ((a0 (countA)) (before close-fires))
  (kill-self! SIG_USR1)                       ; pending for L and guards A,B
  (uv-close L close-cb-ptr)                   ; close BEFORE the next run
  (let ((s9-steps (steps-once-until! (lambda () (> close-fires before)))))
    (say "s9 close_cb steps=~s L=~d guardA-delta=~d (close while pending)\n"
         s9-steps (countL) (- (countA) a0))
    (verdict! "EV-10"
              (and s9-steps (= (countL) 0) (= (- (countA) a0) 1))
              (format "close-with-pending: cb suppressed (L=~d), close_cb after ~s steps, guards delivered"
                      (countL) s9-steps))))

;;; === Section 10: EV-4 — an armed watcher keeps the loop alive ================
(close-and-drain! A)
(close-and-drain! B)
(close-and-drain! C)
(define-values (cbM countM lastM) (make-sig-cb!))
(define M (make-signal!))
(uv-signal-start M cbM SIG_USR1)
;; Close the watchdog; drain its close with NOWAIT (ONCE would now block on
;; the armed watcher — the §9.1 hazard, noted here as the reason for NOWAIT).
(let ((before close-fires))
  (uv-close watchdog close-cb-ptr)
  (steps-nowait-until! (lambda () (> close-fires before))))
(define alive-armed (uv-loop-alive loop-ptr))
(say "\ns10 uv_loop_alive (armed M only) = ~d (predict nonzero: EV-4)\n" alive-armed)
(let ((before close-fires))
  (uv-close M close-cb-ptr)
  (steps-nowait-until! (lambda () (> close-fires before))))
(define alive-closed (uv-loop-alive loop-ptr))
(define rc-loop-close (uv-loop-close loop-ptr))
(say "s10 uv_loop_alive after close    = ~d; uv_loop_close = ~a\n"
     alive-closed (rc-name rc-loop-close))
(verdict! "EV-4"
          (and (not (zero? alive-armed)) (zero? alive-closed) (zero? rc-loop-close))
          "armed watcher held the loop; close released it; loop closed clean")

(foreign-free loop-ptr)

;;; --- summary -----------------------------------------------------------------
(say "\n=== SQ-S3 summary ===\n")
(say "platform (machine-type) : ~s\n" (machine-type))
(say "watchdog ticks          : ~d\n" watchdog-ticks)
(say "close callbacks         : ~d\n" close-fires)
(say "surprises               : ~d\n" failures)
(say "VERDICT: ~a\n" (if (zero? failures)
                         "ALL MICRO-FACTS AS PREDICTED on this platform"
                         "SURPRISE(S) OBSERVED — see the per-section lines above"))
(exit 0)
