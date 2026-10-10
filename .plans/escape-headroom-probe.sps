;;; #94 prototype: the C stack headroom a run has, measured from Scheme.
;;; .plans/2026-10-09-escape-headroom-check-design.md records what each mode
;;; measured. Build the helper, then run from the repository root:
;;;   cc -O2 -fPIC -dynamiclib -o /tmp/libstackprobe.dylib .plans/escape-headroom-probe.c
;;;     (Linux: cc -O2 -fPIC -shared -o /tmp/libstackprobe.so … -lpthread)
;;;   STACKPROBE=/tmp/libstackprobe.dylib CHEZSCHEMELIBDIRS=src:tests \
;;;     scheme --program .plans/escape-headroom-probe.sps MODE ARG... [thread]
;;; Modes:
;;;   info                 stack size and headroom here
;;;   trace N              escape N times from a timer callback, printing
;;;                        headroom every 50, and every escape below 64 KiB
;;;   trace-async N        escape N times from an async callback, which
;;;                        uv__io_poll calls, printing headroom every escape
;;;   guarded M N          escape until headroom < M, then refuse; check the
;;;                        thread can still collect and run a loop
;;;   margin H             escape until headroom < H, then one run whose
;;;                        timer callback allocates and collects
;;;   margin-async H       the same, from an async callback
;;;   cost N               time N empty 'nowait runs, with and without a probe
(import (chezscheme) (libuv loop) (libuv timer) (libuv handle) (libuv async))

(define lib (or (getenv "STACKPROBE") "/tmp/libstackprobe.dylib"))
(load-shared-object lib)
(define probe-sp (foreign-procedure "probe_sp" () uptr))
(define probe-stack-low (foreign-procedure "probe_stack_low" () uptr))
(define probe-stack-size (foreign-procedure "probe_stack_size" () uptr))
(define probe-headroom (foreign-procedure "probe_headroom" () uptr))

(define args (cdr (command-line)))
(define on-thread? (and (pair? args) (string=? (list-ref args (- (length args) 1)) "thread")))
(define argv (if on-thread? (reverse (cdr (reverse args))) args))
(define mode (string->symbol (car argv)))
(define (arg i) (string->number (list-ref argv i)))

(define (say . xs) (for-each display xs) (newline) (flush-output-port (current-output-port)))

(define (escape-once)
  (let ((v (call/cc
            (lambda (k)
              (call-with-uv-loop
               (lambda (loop)
                 (uv-timer-start! (make-uv-timer loop) (lambda (t) (k 'escaped)) 0 0)
                 (uv-run loop 'default)
                 'returned))))))
    (unless (eq? v 'escaped) (error 'probe "no escape" v))))

;; One escape from an async callback, which uv__io_poll calls.
(define (escape-async-once)
  (let ((v (call/cc
            (lambda (k)
              (call-with-uv-loop
               (lambda (loop)
                 (uv-async-send! (make-uv-async loop (lambda (a) (k 'escaped))))
                 (uv-run loop 'default)
                 'returned))))))
    (unless (eq? v 'escaped) (error 'probe "no escape" v))))

;; A run that returns normally, whose callback allocates and collects.
(define (collecting-run)
  (call-with-uv-loop
   (lambda (loop)
     (let ((seen #f))
       (uv-timer-start! (make-uv-timer loop)
                        (lambda (t)
                          (set! seen (length (iota 100000)))
                          (collect)
                          (uv-close! t))
                        0 0)
       (uv-run loop 'default)
       seen))))

;; A run whose async callback, called from uv__io_poll, allocates and collects.
(define (collecting-async-run)
  (call-with-uv-loop
   (lambda (loop)
     (let ((seen #f))
       (uv-async-send! (make-uv-async loop
                                      (lambda (a)
                                        (set! seen (length (iota 100000)))
                                        (collect)
                                        (uv-close! a))))
       (uv-run loop 'default)
       seen))))

(define (escape-until floor)
  (let loop ((i 0))
    (let ((h (probe-headroom)))
      (if (< h floor)
          (values i h)
          (begin (escape-once) (loop (+ i 1)))))))

(define (main)
  (case mode
    ((info)
     (say "size " (probe-stack-size) " headroom " (probe-headroom)
          " sp-low " (- (probe-sp) (probe-stack-low))))
    ((trace)
     (let ((n (arg 1)) (h0 (probe-headroom)))
       (say "size " (probe-stack-size) " headroom0 " h0)
       (let loop ((i 0) (prev h0))
         (when (< i n)
           (escape-once)
           (let ((h (probe-headroom)))
             (when (or (zero? (mod (+ i 1) 50)) (< h 65536))
               (say "escape " (+ i 1) " headroom " h " used/escape "
                    (exact->inexact (/ (- h0 h) (+ i 1)))))
             (loop (+ i 1) h))))
       (say "survived " n)))
    ((trace-async)
     (let ((n (arg 1)) (h0 (probe-headroom)))
       (say "size " (probe-stack-size) " headroom0 " h0)
       (let loop ((i 0))
         (when (< i n)
           (escape-async-once)
           (let ((h (probe-headroom)))
             (say "async escape " (+ i 1) " headroom " h " used/escape "
                  (exact->inexact (/ (- h0 h) (+ i 1))))
             (loop (+ i 1)))))
       (say "survived " n)))
    ((guarded)
     (let ((m (arg 1)) (n (arg 2)))
       (let loop ((i 0))
         (cond ((= i n) (say "no refusal in " n))
               ((< (probe-headroom) m)
                (say "refused at escape " i " headroom " (probe-headroom))
                (collect) (collect)
                (say "collected after refusal")
                (say "collecting-run answered " (collecting-run) " at headroom " (probe-headroom)))
               (else (escape-once) (loop (+ i 1)))))))
    ((margin)
     (let-values (((i h) (escape-until (arg 1))))
       (say "escapes " i " headroom " h)
       (say "collecting-run answered " (collecting-run))
       (say "after, headroom " (probe-headroom))))
    ((margin-async)
     (let-values (((i h) (escape-until (arg 1))))
       (say "escapes " i " headroom " h)
       (say "collecting-async-run answered " (collecting-async-run))))
    ((cost)
     (let ((n (arg 1)) (loop (make-uv-loop)))
       (define (time-it label thunk)
         (collect)
         (let ((t0 (current-time 'time-monotonic)))
           (thunk)
           (let ((d (time-difference (current-time 'time-monotonic) t0)))
             (say label ": "
                  (exact->inexact (/ (+ (* (time-second d) 1e9) (time-nanosecond d)) n))
                  " ns each"))))
       (do ((r 0 (+ r 1))) ((= r 3))
         (time-it "run 'nowait" (lambda () (do ((i 0 (+ i 1))) ((= i n)) (uv-run loop 'nowait))))
         (time-it "probe-headroom + run" (lambda () (do ((i 0 (+ i 1))) ((= i n))
                                                      (when (< (probe-headroom) 65536) (error 'x "low"))
                                                      (uv-run loop 'nowait))))
         (time-it "probe-headroom alone" (lambda () (do ((i 0 (+ i 1))) ((= i n)) (probe-headroom))))
         (time-it "probe-sp alone" (lambda () (do ((i 0 (+ i 1))) ((= i n)) (probe-sp))))
         (time-it "probe-stack-low alone (uncached)" (lambda () (do ((i 0 (+ i 1))) ((= i n)) (probe-stack-low)))))
       (uv-loop-close! loop)))
    (else (error 'probe "unknown mode" mode))))

(if on-thread?
    (let ((m (make-mutex)) (c (make-condition)) (fin #f))
      (fork-thread (lambda () (main) (with-mutex m (set! fin #t) (condition-signal c))))
      (with-mutex m (let w () (unless fin (condition-wait c m) (w))))
      (say "main: thread ended; main headroom " (probe-headroom))
      (collect)
      (say "main: collected"))
    (main))
