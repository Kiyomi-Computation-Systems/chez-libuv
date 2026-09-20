;;; spike/threading/02-two-thread-gc.ss — T2: can a SECOND Scheme thread collect
;;; while the loop thread is inside uv_run? Plain vs __collect_safe.
;;;
;;; Usage:
;;;   chez --script spike/threading/02-two-thread-gc.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib (plain|safe) [block-ms]
;;;
;;; WHAT WE LEARNED (and why this is sharper than "stall"). Chez's collector is
;;; stop-the-world and, for an EXPLICIT (collect), raises
;;;   "cannot collect when multiple threads are active"
;;; unless every OTHER thread is deactivated. A thread is deactivated while it
;;; is inside a `__collect_safe` foreign call (or blocked on a mutex/condition);
;;; a thread inside a PLAIN foreign call stays ACTIVE. So a loop thread blocked
;;; in a plain uv_run keeps the whole process un-collectable: a worker thread's
;;; (collect) fails outright. Rebinding uv_run __collect_safe deactivates the
;;; loop thread for the blocking poll, and the worker collects freely.
;;;
;;; DESIGN. The loop thread arms a oneshot timer at block-ms and enters uv_run,
;;; blocking in the poll. A worker thread waits until the loop thread is safely
;;; inside the poll, then attempts N guarded (collect)s and reports how many
;;; SUCCEEDED vs. the first error. The worker guards each collect, so a failure
;;; is DATA (recorded and reported), never an unhandled exception that would
;;; kill the thread and hang the join.
;;;   plain -> 0 successes, error = "cannot collect when multiple threads..."
;;;   safe  -> all N succeed

(import (chezscheme))

(define argv (command-line-arguments))
(define lib-path
  (if (null? argv)
      (begin (display "usage: 02-two-thread-gc.ss <libuv.dylib> (plain|safe) [block-ms]\n") (exit 2))
      (car argv)))
(define mode (if (and (pair? argv) (pair? (cdr argv))) (cadr argv) "plain"))
(define safe? (string=? mode "safe"))
(define block-ms
  (if (and (pair? argv) (pair? (cdr argv)) (pair? (cddr argv)))
      (string->number (caddr argv)) 400))
(define N 50)  ; collect attempts by the worker

(unless (threaded?)
  (display "SKIP: this Chez is not a threaded build\n") (exit 3))

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

;; Callables' collect-safe-ness must match uv_run's: a __collect_safe foreign
;; call may only invoke __collect_safe callables.
(define timer-callable
  (if safe?
      (foreign-callable __collect_safe (lambda (h) (uv-stop loop-ptr)) (uptr) void)
      (foreign-callable                (lambda (h) (uv-stop loop-ptr)) (uptr) void)))
(define close-callable
  (if safe?
      (foreign-callable __collect_safe (lambda (h) #f) (uptr) void)
      (foreign-callable                (lambda (h) #f) (uptr) void)))
(lock-object timer-callable)
(lock-object close-callable)

(define m (make-mutex))
(define done-cond (make-condition))
(define loop-entered #f)
(define worker-done #f)
(define ok-collects 0)
(define first-error #f)

(define (worker)
  (let spin () (unless loop-entered (sleep (make-time 'time-duration 0 0)) (spin)))
  ;; Let the loop thread get INTO the poll (deactivated in safe mode) before the
  ;; first attempt, so safe mode isn't judged by the pre-poll instant.
  (sleep (make-time 'time-duration 20000000 0))  ; 20 ms
  (let loop ((i 0))
    (when (< i N)
      (let ((outcome (guard (e (#t (let ((p (open-output-string)))
                                     (display-condition e p)
                                     (get-output-string p))))
                       (let build ((k 0) (acc '()))
                         (if (< k 500) (build (+ k 1) (cons k acc)) acc))
                       (collect)
                       'ok)))
        (if (eq? outcome 'ok)
            (begin (set! ok-collects (+ ok-collects 1)) (loop (+ i 1)))
            (begin (unless first-error (set! first-error outcome))
                   ;; stop on first failure: retrying just re-hits the same wall
                   (set! i N))))))
  (with-mutex m (set! worker-done #t) (condition-signal done-cond)))

(uv-loop-init loop-ptr)
(uv-timer-init loop-ptr timer-ptr)
(uv-timer-start timer-ptr (foreign-callable-entry-point timer-callable) block-ms 0)

(fork-thread worker)
(set! loop-entered #t)
(define t0 (real-time))
(uv-run loop-ptr UV_RUN_DEFAULT)
(define run-ms (- (real-time) t0))

(with-mutex m (let w () (unless worker-done (condition-wait done-cond m) (w))))

(uv-timer-stop timer-ptr)
(uv-close timer-ptr (foreign-callable-entry-point close-callable))
(uv-run loop-ptr UV_RUN_DEFAULT)
(uv-loop-close loop-ptr)
(foreign-free timer-ptr)
(foreign-free loop-ptr)

(printf "mode                              = ~a\n" mode)
(printf "uv_run wall time (ms)             = ~d (block-ms=~d)\n" run-ms block-ms)
(printf "worker collects that SUCCEEDED    = ~d of ~d\n" ok-collects N)
(printf "first collect error               = ~a\n" (or first-error "none"))
(printf "VERDICT                           = ~a\n"
        (cond ((and safe? (= ok-collects N)) "SAFE: worker collected freely while loop thread blocked")
              ((and (not safe?) (= ok-collects 0)) "PLAIN: worker could NOT collect (loop thread active in uv_run)")
              (else "UNEXPECTED — investigate")))
(exit 0)
