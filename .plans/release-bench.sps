;;; The release timing bench, run from a built tree's root:
;;;   CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program .plans/release-bench.sps THREADS REPS
;;; It is #116's bench.sps (.plans/registry-lock-once-mutation-log.md)
;;; with a fifth column, "run": 2,000 empty (uv-run loop 'nowait) calls on
;;; the drained loop, for #126's headroom check. It prints THREADS, then
;;; the median over the threads of each thread's best of REPS repetitions,
;;; in ns per operation: make, fire, close, complete, run.
;;; Build each tree with `make prod` (the release shim). Alternate the
;;; builds for at least 5 rounds of `1 30`, and give the load average with
;;; the figures. CHANGELOG.md's 0.9.0 entry ran 10 rounds at a load of
;;; 45-95.
;;; Unlike the meter, it reaches private names: registry-register!,
;;; %make-uv-req-record, dispatcher-ref and alloc-zeroed. They are the same
;;; from v0.8.0 to v0.9.0. An older or newer tree may need them changed.
(import (chezscheme)
        (libuv loop) (libuv handle) (libuv timer)
        (libuv private handles)
        (only (libuv private native) alloc-zeroed dispatcher-ref))

(define n 2000)
(define threads (string->number (cadr (command-line))))
(define reps (string->number (caddr (command-line))))

(define (now-ns)
  (let ((t (current-time 'time-monotonic)))
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (run-until loop done?)
  (let spin ((i 0))
    (unless (done?)
      (when (> i 10000000) (error 'bench "loop never finished"))
      (uv-run loop 'once)
      (spin (+ i 1)))))

(define (one-rep loop)
  (let* ((fired 0) (closed 0)
         (t0 (now-ns))
         (timers (let make ((i 0) (acc '()))
                   (if (= i n) acc (make (+ i 1) (cons (make-uv-timer loop) acc)))))
         (t1 (now-ns)))
    (for-each (lambda (t) (uv-timer-start! t (lambda (h) (set! fired (+ fired 1))) 0 0)) timers)
    (let ((t2 (now-ns)))
      (run-until loop (lambda () (= fired n)))
      (let ((t3 (now-ns)))
        (for-each (lambda (t) (uv-close! t (lambda () (set! closed (+ closed 1))))) timers)
        (run-until loop (lambda () (= closed n)))
        (let ((t4 (now-ns)) (slot (dispatcher-ref 'shutdown)) (done 0))
          (let complete ((i 0))
            (when (< i n)
              (let ((block (alloc-zeroed 64)))
                (registry-register! block 'shutdown-req loop
                                    (%make-uv-req-record block 'shutdown #f
                                                         (lambda (err) (set! done (+ done 1)))))
                (slot block 0))
              (complete (+ i 1))))
          (let ((t5 (now-ns)))
            (unless (= done n) (error 'bench "completions missing" done))
            (do ((i 0 (+ i 1))) ((= i n)) (uv-run loop 'nowait))
            (let ((t6 (now-ns)))
              (vector (/ (- t1 t0) n) (/ (- t3 t2) n) (/ (- t4 t3) n) (/ (- t5 t4) n)
                      (/ (- t6 t5) n)))))))))

(define (thread-best)
  (let ((loop (make-uv-loop)))
    (let rep ((i 0) (best #f))
      (if (= i reps)
          (begin (uv-loop-teardown! loop) best)
          (let ((r (one-rep loop)))
            (rep (+ i 1) (if best (vector-map min best r) r)))))))

(define (median xs)
  (let ((v (list->vector (sort < xs))))
    (vector-ref v (quotient (vector-length v) 2))))

(collect)
(collect-trip-bytes (expt 2 29))
(define m (make-mutex))
(define c (make-condition))
(define results '())
(define go #f)
(do ((i 0 (+ i 1))) ((= i threads))
  (fork-thread
   (lambda ()
     (with-mutex m (let wait () (unless go (condition-wait c m) (wait))))
     (let ((r (thread-best)))
       (with-mutex m (set! results (cons r results)) (condition-broadcast c))))))
(with-mutex m (set! go #t) (condition-broadcast c))
(with-mutex m (let wait () (unless (= (length results) threads) (condition-wait c m) (wait))))
(let ((cols (map (lambda (k) (median (map (lambda (r) (vector-ref r k)) results))) '(0 1 2 3 4))))
  (printf "~a ~{~a ~}~%" threads (map (lambda (x) (exact (round x))) cols)))
