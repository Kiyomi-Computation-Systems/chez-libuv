;;; spike/threading/03-auto-gc-and-workaround.ss — does AUTOMATIC (allocation-
;;; triggered) GC stall or error under a plain uv_run, and does the interim
;;; "arm a short-period timer" workaround #19 proposes actually help?
;;;
;;; Usage:
;;;   chez --script spike/threading/03-auto-gc-and-workaround.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib (plain|safe|plain-ticker) [block-ms]
;;;
;;; T2 used EXPLICIT (collect) and got a hard error under plain. But #19 quotes
;;; a *stall* (10.27 s), which implies ALLOCATION-triggered GC WAITS rather than
;;; erroring, and is the premise of its documented workaround: a short-period
;;; timer makes the loop thread's uv_run return often, opening GC windows. This
;;; script drives the worker with allocation ONLY (no explicit collect), so the
;;; collector fires on its own, and measures how long a fixed allocation load
;;; takes while the loop thread is in uv_run:
;;;   plain         -> loop thread blocks ~block-ms in ONE poll; worker's auto-GC
;;;   safe          -> loop thread deactivated; worker allocates freely
;;;   plain-ticker  -> loop thread runs a 1 ms repeating timer (uv_run returns
;;;                    constantly), the workaround #19 documents, still PLAIN.

(import (chezscheme))

(define argv (command-line-arguments))
(define lib-path
  (if (null? argv)
      (begin (display "usage: ... <libuv.dylib> (plain|safe|plain-ticker) [block-ms]\n") (exit 2))
      (car argv)))
(define mode (if (and (pair? argv) (pair? (cdr argv))) (cadr argv) "plain"))
(define safe? (string=? mode "safe"))
(define ticker? (or (string=? mode "plain-ticker") (string=? mode "plain-once-ticker")))
;; plain-once-ticker drives the loop with UV_RUN_ONCE in a Scheme loop, so
;; uv_run RETURNS between iterations (a Scheme safepoint each time), vs the
;; single long UV_RUN_DEFAULT poll every other mode uses.
(define once-loop? (string=? mode "plain-once-ticker"))
(define UV_RUN_ONCE 1)
(define block-ms
  (if (and (pair? argv) (pair? (cdr argv)) (pair? (cddr argv)))
      (string->number (caddr argv)) 600))
(define ALLOC-ROUNDS 4000)   ; each round conses a 1000-element list => forces GC

(unless (threaded?) (display "SKIP: not threaded\n") (exit 3))

(define UV_TIMER 13)
(define UV_RUN_DEFAULT 0)
(load-shared-object lib-path)

(define uv-run-plain (foreign-procedure                "uv_run" (uptr int) int))
(define uv-run-safe  (foreign-procedure __collect_safe  "uv_run" (uptr int) int))
(define uv-run (if safe? uv-run-safe uv-run-plain))
(define uv-loop-size   (foreign-procedure "uv_loop_size"   ()          size_t))
(define uv-handle-size (foreign-procedure "uv_handle_size" (int)       size_t))
(define uv-loop-init   (foreign-procedure "uv_loop_init"   (uptr)      int))
(define uv-loop-close  (foreign-procedure "uv_loop_close"  (uptr)      int))
(define uv-timer-init  (foreign-procedure "uv_timer_init"  (uptr uptr) int))
(define uv-timer-start (foreign-procedure "uv_timer_start"
                                          (uptr uptr unsigned-64 unsigned-64) int))
(define uv-timer-stop  (foreign-procedure "uv_timer_stop"  (uptr)      int))
(define uv-stop        (foreign-procedure "uv_stop"        (uptr)      void))
(define uv-close       (foreign-procedure "uv_close"       (uptr uptr) void))
(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p) (foreign-set! 'unsigned-8 p i 0))))

(define loop-ptr  (alloc-zeroed (uv-loop-size)))
(define timer-ptr (alloc-zeroed (uv-handle-size UV_TIMER)))
(define fires 0)

;; plain/plain-ticker use plain callables; safe uses collect-safe ones.
(define (mk-cb thunk)
  (if safe?
      (foreign-callable __collect_safe (lambda (h) (thunk)) (uptr) void)
      (foreign-callable                (lambda (h) (thunk)) (uptr) void)))
;; oneshot for plain/safe (fires once, stops the loop after block-ms);
;; repeating 1 ms for plain-ticker (returns constantly). A cap stops the ticker.
(define timer-callable
  (mk-cb (lambda ()
           (set! fires (+ fires 1))
           (when (or (not ticker?) (>= fires 400)) (uv-stop loop-ptr)))))
(define close-callable (mk-cb (lambda () #f)))
(lock-object timer-callable)
(lock-object close-callable)

(define m (make-mutex))
(define done-cond (make-condition))
(define loop-entered #f)
(define worker-done #f)
(define worker-ms 0)
(define worker-err #f)

(define (worker)
  (let spin () (unless loop-entered (sleep (make-time 'time-duration 0 0)) (spin)))
  (sleep (make-time 'time-duration 20000000 0)) ; 20 ms: let the loop thread reach uv_run
  (let ((t0 (real-time)))
    (guard (e (#t (let ((p (open-output-string)))
                    (display-condition e p) (set! worker-err (get-output-string p)))))
      (let loop ((i 0))
        (when (< i ALLOC-ROUNDS)
          (let build ((k 0) (acc '())) (if (< k 1000) (build (+ k 1) (cons k acc)) acc))
          (loop (+ i 1)))))
    (set! worker-ms (- (real-time) t0)))
  (with-mutex m (set! worker-done #t) (condition-signal done-cond)))

(uv-loop-init loop-ptr)
(uv-timer-init loop-ptr timer-ptr)
;; oneshot at block-ms, or 1 ms repeating for the ticker workaround.
(if ticker?
    (uv-timer-start timer-ptr (foreign-callable-entry-point timer-callable) 1 1)
    (uv-timer-start timer-ptr (foreign-callable-entry-point timer-callable) block-ms 0))

(fork-thread worker)
(set! loop-entered #t)
(define t0 (real-time))
(if once-loop?
    ;; UV_RUN_ONCE in a Scheme loop: uv_run returns each iteration (a safepoint),
    ;; the timer keeps the loop alive, and the cap in the callable stops it.
    (let loop () (uv-run-plain loop-ptr UV_RUN_ONCE) (when (< fires 400) (loop)))
    (uv-run loop-ptr UV_RUN_DEFAULT))
(define run-ms (- (real-time) t0))
(with-mutex m (let w () (unless worker-done (condition-wait done-cond m) (w))))

(uv-timer-stop timer-ptr)
(uv-close timer-ptr (foreign-callable-entry-point close-callable))
(uv-run loop-ptr UV_RUN_DEFAULT)
(uv-loop-close loop-ptr)
(foreign-free timer-ptr)
(foreign-free loop-ptr)

(printf "mode                        = ~a\n" mode)
(printf "uv_run wall time (ms)       = ~d\n" run-ms)
(printf "worker alloc load (ms)      = ~d (~d rounds x 1000-cons, auto-GC only)\n"
        worker-ms ALLOC-ROUNDS)
(printf "worker error                = ~a\n" (or worker-err "none"))
(exit 0)
