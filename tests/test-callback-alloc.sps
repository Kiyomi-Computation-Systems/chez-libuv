#!r6rs
;;; SRFI-64 suite for what the binding allocates around each callback it
;;; delivers (#45), with the callbacks themselves allocating nothing.
;;;
;;; A delivery crosses three layers: the native trampoline, the seam that
;;; contains whatever the callback raises, and the dispatcher that finds the
;;; handle and calls the user's procedure. v0.7.3 contained every raise
;;; twice, with a `guard` at the seam and another around the user's call,
;;; gathered each callback's arguments into a rest list, wrapped every uv-run
;;; in a dynamic-wind, and guarded every write only to free its block when
;;; libuv refused it. Each row below holds a path to a bound it can meet only
;;; without the cost it is named for.
;;;
;;; libuv's alloc callback no longer crosses at all. It crossed into Scheme
;;; before every read, only to answer the stream's own read buffer, and the
;;; shim answers it now (ADR-0002, amended 2026-10-05). The two read rows
;;; through libuv hold that.
;;;
;;; THE METER. (+ (bytes-allocated) (bytes-deallocated)) is the total ever
;;; allocated, so a collection cannot make it run backwards, and reading it
;;; allocates nothing. Each call is metered on its own, with the collector
;;; held off and its set-up outside the meter, and a row takes the FEWEST
;;; bytes over the calls that did the work. The fewest, because now and then
;;; a call is charged for a fresh 64 KiB stack segment, needed after earlier
;;; continuations split the stack, which has nothing to do with that call
;;; (measured: 2 calls in 600 of an unguarded uv-write!). One row takes a
;;; mean instead, for the one cost that lands only on such calls. The first
;;; rows check the meter itself.
;;;
;;; THE BOUNDS follow the Chez that runs the suite. Each path declares what it
;;; allocated on Chez 10.4.1 and how many guards it holds, and the suite
;;; measures a guard and a dynamic-wind of its own, so a path's bound moves
;;; with what a guard costs on this Chez:
;;;
;;;   bound = bytes on 10.4.1 + guards x (a guard now - a guard on 10.4.1)
;;;           + half a guard now
;;;
;;; Half a guard is far more than the platforms measured differ by (macOS
;;; arm64, Linux aarch64 and x86_64 agree to the byte), and less than any
;;; undone change adds back: a second guard around the user's call, or one
;;; around a write's native start. The idle run's margin is half a
;;; dynamic-wind instead, for the one uv-run held, and so is the stream
;;; verbs': their steps are bare interrupt pairs, and with-interrupts-disabled
;;; in their place is a dynamic-wind.
;;;
;;; One row holds a difference instead. A read through libuv crosses into
;;; Scheme once, as a timer does, so each costs over its delivery straight
;;; through the slot what the other does. An alloc callback answered in
;;; Scheme would add a crossing to every read, under half a guard when it
;;; has no seam around it. The figures are in
;;; .plans/callback-alloc-mutation-log.md, .plans/shim-alloc-mutation-log.md
;;; and .plans/stream-step-mutation-log.md.
;;;
;;; NOT pure: (libuv) reaches (libuv private native). Never add this to the
;;; Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv)
        (only (libuv private native)
              dispatcher-names dispatcher-ref live-counts alloc-zeroed free!
              count-write-req-new! count-connect-req-new!
              count-getaddrinfo-req-new! count-getnameinfo-req-new!)
        (only (libuv private handles)
              %make-uv-req-record %make-uv-process-record
              registry-register! registry-deregister! registry-count
              handle-ptr set-signal-on-signal! set-tcp-on-connection!)
        (only (libuv private constants) uv-eof errno-symbol->value sig-usr1)
        (only (uv-testing) run-until run-until/ticking
              bind-loopback! connect-loopback!)
        (only (uv-evidence) describe)
        (only (chezscheme) bytes-allocated bytes-deallocated
              collect-request-handler collect void procedure-arity-mask))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. Each row here
;; returns its measurement when it fails, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; (libuv process) and (libuv dns) install the exit and DNS slots from their
;; own library bodies, and Chez runs a library's body only for a program that
;; references one of its variables. Nothing below otherwise would, and those
;; slots would still hold the stub that raises.
(define late-installed-slots (list uv-os-getpid uv-getaddrinfo!))

(define registry-count-at-start (registry-count))

(test-begin "callback-alloc")

;; --- the meter -------------------------------------------------------------
(define (meter) (+ (bytes-allocated) (bytes-deallocated)))

(define calls-per-row 64)

;; fewest-bytes : (-> any) (-> any) (-> boolean)
;;                -> (or exact-nonnegative-integer 'never-did-the-work)
;; Runs (prepare) off the meter, then (call) on it, CALLS-PER-ROW times, and
;; answers the fewest bytes one (call) allocated among the calls after which
;; (did-work?) held.
(define (fewest-bytes prepare call did-work?)
  (let ((saved (collect-request-handler)))
    (dynamic-wind
     (lambda () (collect-request-handler void))
     (lambda ()
       (let run ((i 0) (fewest #f))
         (if (= i calls-per-row)
             (or fewest 'never-did-the-work)
             (begin
               (prepare)
               (let* ((before (meter))
                      (ignored (call))
                      (after (meter)))
                 (run (+ i 1)
                      (if (did-work?)
                          (let ((bytes (- after before)))
                            (if fewest (min fewest bytes) bytes))
                          fewest)))))))
     (lambda () (collect-request-handler saved)))))

(define (always) #t)

;; mean-bytes : (-> any) (-> any) (-> boolean) -> (or rational symbol)
;; Like fewest-bytes, but answers the least mean over three windows of a
;; thousand calls: the measure for a cost that lands on some calls only.
(define (mean-bytes prepare call did-work?)
  (let ((saved (collect-request-handler)))
    (dynamic-wind
     (lambda () (collect-request-handler void))
     (lambda ()
       (let window ((w 0) (least #f))
         (if (= w 3)
             (or least 'never-did-the-work)
             (let run ((i 0) (bytes 0) (counted 0))
               (if (= i 1000)
                   (window (+ w 1)
                           (if (zero? counted)
                               least
                               (let ((mean (div bytes counted)))
                                 (if least (min least mean) mean))))
                   (begin
                     (prepare)
                     (let* ((before (meter))
                            (ignored (call))
                            (after (meter)))
                       (if (did-work?)
                           (run (+ i 1) (+ bytes (- after before)) (+ counted 1))
                           (run (+ i 1) bytes counted)))))))))
     (lambda () (collect-request-handler saved)))))

;; --- what a guard and a dynamic-wind cost on this Chez ---------------------
;; Each is shaped like the code the paths hold or once held: a guard with an
;; else clause around a call through a variable, like a seam's, and a
;; dynamic-wind whose thunks set a field around a call, like uv-run's.
(define ref-cell (make-vector 1 #f))
(define (ref-record! e) (vector-set! ref-cell 0 e))
(define ref-callee (lambda (a) #f))
(define (ref-guarded a) (guard (e (else (ref-record! e))) (ref-callee a)))
(define (ref-wound a b)
  (dynamic-wind (lambda () (vector-set! ref-cell 0 a))
                (lambda () (ref-callee b))
                (lambda () (vector-set! ref-cell 0 #f))))

(define a-guard (fewest-bytes void (lambda () (ref-guarded 1)) always))
(define a-wind (fewest-bytes void (lambda () (ref-wound 1 2)) always))

;; What the same two shapes allocate on Chez 10.4.1.
(define a-guard-on-10.4.1 256)
(define a-wind-on-10.4.1 80)

(display "  [informational] a guard: ") (display a-guard)
(display " B, a dynamic-wind: ") (display a-wind) (display " B (on 10.4.1: ")
(display a-guard-on-10.4.1) (display " B, ") (display a-wind-on-10.4.1)
(display " B)") (newline)

;; A bound built from a measurement that answered nothing would be no bound.
(test-equal "seed: a guard and a dynamic-wind of the suite's own allocate"
  '(allocates allocates)
  (map (lambda (bytes) (if (and (integer? bytes) (positive? bytes)) 'allocates bytes))
       (list a-guard a-wind)))

;; Every path, in one place: what it allocated on Chez 10.4.1, and how many
;; guards it holds (see the header and the mutation log).
(define paths
  '((read-data 368 1) (read-eof 336 1) (read-error 944 1)
    (connection 336 1) (timer 320 1) (signal 336 1) (async 320 1)
    (exit 336 1) (write-done 336 1) (shutdown 336 1) (connect 336 1)
    ;; the dispatcher guards its conversion of the answer too
    (getaddrinfo 656 2)
    (getnameinfo 384 1)
    (idle-run 16 0) (timer-through-libuv 400 1) (close-through-libuv 400 1)
    (read-through-libuv 448 1)
    ;; the seam's guard and the callback's own
    (guarded-callback-through-libuv 787 2)
    ;; one interrupt-free step each, with no dynamic-wind
    (uv-write! 144 0) (uv-write*! 176 0) (uv-shutdown! 128 0)
    ;; 32 B a segment: a one-pair spec and the walk's spine pair (#64's
    ;; review); a list of three per segment cost 64
    (uv-write*-64 3200 0)))

;; bound : symbol -> exact-integer, per the header.
(define (bound name)
  (let* ((path (cdr (assq name paths)))
         (on-10.4.1 (car path))
         (guards (cadr path))
         (margin (case name
                   ((idle-run uv-write! uv-write*! uv-write*-64 uv-shutdown!)
                    (div a-wind 2))
                   ;; a mean, which a stray stack segment can move
                   ((guarded-callback-through-libuv) (* 2 a-guard))
                   (else (div a-guard 2)))))
    (+ on-10.4.1 (* guards (- a-guard a-guard-on-10.4.1)) margin)))

;; (row name title measurement) records the measurement in the output and
;; holds it to its bound: the row's value is 'within, or the measurement
;; beside the bound. A measurement that raises becomes the row's evidence,
;; so it cannot abort the rows after it.
(define measured (make-eq-hashtable))

(define-syntax row
  (syntax-rules ()
    ((_ name title measurement)
     (row-of name title
             (lambda ()
               (guard (e (#t (list 'raised (describe e))))
                 measurement))))))

(define (row-of name title measure)
  (let ((bytes (measure)) (limit (bound name)))
    (hashtable-set! measured name bytes)
    (display "  [informational] ") (display name) (display ": ")
    (display bytes) (display " B (at most ") (display limit)
    (display ")") (newline)
    (test-equal (string-append title ", at most "
                               (number->string limit) " bytes")
      'within
      (if (and (integer? bytes) (<= bytes limit))
          'within
          (list 'allocated bytes 'at-most limit)))))

(define keep (make-vector 1 #f))

(test-equal "the meter reads one pair as 16 bytes"
  16 (fewest-bytes void (lambda () (vector-set! keep 0 (cons 1 2))) always))

(test-equal "the meter reads a call that allocates nothing as 0 bytes"
  0 (fewest-bytes void (lambda () (vector-set! keep 0 keep)) always))

(test-equal "the meter counts only the calls that did the work"
  32 (let ((odd #f))
       (fewest-bytes (lambda () (set! odd (not odd)))
                     (lambda ()
                       (vector-set! keep 0 (if odd (cons (cons 1 2) 3) keep)))
                     (lambda () odd))))

;; --- the slots take fixed arguments ---------------------------------------
;; Each trampoline calls its slot with libuv's arguments for that callback
;; type. A slot with a rest parameter gathers them into a fresh list on every
;; callback, and procedure-arity-mask is negative for exactly those.
(define trampoline-arity
  '((read . 3) (connection . 2) (write-done . 2) (close . 1)
    (timer . 1) (shutdown . 2) (connect . 2) (getaddrinfo . 3)
    (getnameinfo . 4) (exit . 3) (walk . 2) (signal . 2) (async . 1)))

(test-equal "seed: the arity table names every dispatcher slot"
  dispatcher-names (map car trampoline-arity))

(test-equal "every installed slot takes its trampoline's arguments with no rest list"
  '()
  (let check ((names dispatcher-names) (bad '()))
    (if (null? names)
        (reverse bad)
        (let* ((name (car names))
               (mask (procedure-arity-mask (dispatcher-ref name)))
               (arity (cdr (assq name trampoline-arity))))
          (check (cdr names)
                 (if (and (>= mask 0) (bitwise-bit-set? mask arity))
                     bad
                     (cons (list name 'arity-mask mask) bad)))))))

;; --- one delivery per callback type, through its installed slot ----------
;; Each row calls the slot as its trampoline does, with the pointer of a
;; handle or request this suite registered, so what is metered is the seam,
;; the dispatcher and an empty user callback, without libuv.
(define r-loop (make-uv-loop))

;; (define-tally tally tally!) defines a counter read by (tally) and bumped
;; by (tally!), for a row to see that its user callback ran.
(define-syntax define-tally
  (syntax-rules ()
    ((_ tally tally!) (begin (define count 0)
                             (define (tally) count)
                             (define (tally!) (set! count (+ count 1)))))))

;; delivery-bytes : (-> exact-integer) (-> any) -> bytes
;; What one CALL allocates, counting the calls that ran the user's callback
;; exactly once, as read off TALLY.
(define (delivery-bytes tally call)
  (let ((before 0))
    (fewest-bytes (lambda () (set! before (tally)))
                  call
                  (lambda () (= (tally) (+ before 1))))))

;; A connected pair on r-loop. The peer reads, so it has its read buffer and
;; read callbacks; the rows hand it reads directly and nothing ever flows.
(define r-server (make-uv-tcp r-loop))
(define r-port (bind-loopback! r-server))
(define r-peer #f)
(uv-listen! r-server 8 (lambda (err) (set! r-peer (uv-accept! r-server))))
(define r-client (make-uv-tcp r-loop))
(define r-connected #f)
(connect-loopback! r-client r-port (lambda (err) (set! r-connected #t)))

(test-equal "seed: the direct-delivery pair connected and was accepted"
  'satisfied
  (run-until/ticking r-loop (lambda () (and r-connected r-peer)) 4000))

(define-tally data-tally data-tally!)
(define-tally eof-tally eof-tally!)
(define-tally error-tally error-tally!)
;; Gated on the seed: without a peer, the rows below fail by name, carrying
;; the raise as their evidence, instead of this line aborting the suite.
(when (uv-tcp? r-peer)
  (uv-read-start! r-peer
                  (lambda (bv start end) (data-tally!))
                  (lambda () (eof-tally!))
                  (lambda (err) (error-tally!))))

(row 'read-data "delivering 16 bytes read, with their copy"
     (let ((slot (dispatcher-ref 'read)) (ptr (handle-ptr r-peer)))
       (delivery-bytes data-tally (lambda () (slot ptr 16 0)))))

(row 'read-eof "delivering an end of stream"
     (let ((slot (dispatcher-ref 'read)) (ptr (handle-ptr r-peer))
           (eof (uv-eof)))
       (delivery-bytes eof-tally (lambda () (slot ptr eof 0)))))

(row 'read-error "delivering a read error, with its condition"
     (let ((slot (dispatcher-ref 'read)) (ptr (handle-ptr r-peer))
           (nread (errno-symbol->value 'ENOBUFS)))
       (delivery-bytes error-tally (lambda () (slot ptr nread 0)))))

(define-tally connection-tally connection-tally!)
(set-tcp-on-connection! r-server (lambda (err) (connection-tally!)))
(row 'connection "delivering a connection"
     (let ((slot (dispatcher-ref 'connection)) (ptr (handle-ptr r-server)))
       (delivery-bytes connection-tally (lambda () (slot ptr 0)))))

(define-tally timer-tally timer-tally!)
(define r-timer (make-uv-timer r-loop))
(uv-timer-start! r-timer (lambda (t) (timer-tally!)) 3600000 0)
(row 'timer "delivering a timer's firing"
     (let ((slot (dispatcher-ref 'timer)) (ptr (handle-ptr r-timer)))
       (delivery-bytes timer-tally (lambda () (slot ptr)))))

;; The callback is set without arming the watcher: the slot needs no more,
;; and the process keeps its own disposition for the signal.
(define-tally signal-tally signal-tally!)
(define r-signal (make-uv-signal r-loop))
(set-signal-on-signal! r-signal (lambda (sig) (signal-tally!)))
(row 'signal "delivering a signal"
     (let ((slot (dispatcher-ref 'signal)) (ptr (handle-ptr r-signal))
           (signum (sig-usr1)))
       (delivery-bytes signal-tally (lambda () (slot ptr signum)))))

(define-tally wake-tally wake-tally!)
(define r-async (make-uv-async r-loop (lambda (a) (wake-tally!))))
(row 'async "delivering an async wake"
     (let ((slot (dispatcher-ref 'async)) (ptr (handle-ptr r-async)))
       (delivery-bytes wake-tally (lambda () (slot ptr)))))

;; A process record registered under a pointer of its own: the exit slot
;; marks it exited and calls on-exit, and touches no native memory.
(define-tally exit-tally exit-tally!)
(define exit-key (alloc-zeroed 16))
(registry-register! exit-key 'process r-loop
                    (%make-uv-process-record exit-key r-loop
                                             (lambda (status sig) (exit-tally!))))
(row 'exit "delivering a process's exit"
     (let ((slot (dispatcher-ref 'exit)))
       (delivery-bytes exit-tally (lambda () (slot exit-key 0 0)))))
(registry-deregister! exit-key)
(free! exit-key)

;; Request completions. Each call completes a request registered just
;; before it, as the start verbs register theirs: the dispatcher deregisters
;; it, frees its block and counts the free, then calls on-complete.
(define pending-block 0)

;; request-bytes : symbol symbol (-> any) procedure (-> any)
;;                 (-> exact-integer) -> bytes
(define (request-bytes registry-kind req-kind count-new! on-complete call tally)
  (let ((before 0))
    (fewest-bytes (lambda ()
                    (set! before (tally))
                    (set! pending-block (alloc-zeroed 64))
                    (registry-register!
                     pending-block registry-kind r-loop
                     (%make-uv-req-record pending-block req-kind r-client
                                          on-complete))
                    (count-new!))
                  call
                  (lambda () (= (tally) (+ before 1))))))

(define-tally written-tally written-tally!)
(row 'write-done "delivering a write's completion"
     (let ((slot (dispatcher-ref 'write-done)))
       (request-bytes 'write-req 'write count-write-req-new!
                      (lambda (err) (written-tally!))
                      (lambda () (slot pending-block 0)) written-tally)))

(define-tally shut-tally shut-tally!)
(row 'shutdown "delivering a shutdown's completion"
     (let ((slot (dispatcher-ref 'shutdown)))
       (request-bytes 'shutdown-req 'shutdown void
                      (lambda (err) (shut-tally!))
                      (lambda () (slot pending-block 0)) shut-tally)))

(define-tally connected-tally connected-tally!)
(row 'connect "delivering a connect's completion"
     (let ((slot (dispatcher-ref 'connect)))
       (request-bytes 'connect-req 'connect count-connect-req-new!
                      (lambda (err) (connected-tally!))
                      (lambda () (slot pending-block 0)) connected-tally)))

;; An empty answer, status 0 and no chain: what is metered is the delivery,
;; not the conversion of a result.
(define-tally resolved-tally resolved-tally!)
(row 'getaddrinfo "delivering a getaddrinfo's completion"
     (let ((slot (dispatcher-ref 'getaddrinfo)))
       (request-bytes 'getaddrinfo-req 'getaddrinfo count-getaddrinfo-req-new!
                      (lambda (err infos) (resolved-tally!))
                      (lambda () (slot pending-block 0 0)) resolved-tally)))

(define-tally named-tally named-tally!)
(row 'getnameinfo "delivering a getnameinfo's completion"
     (let ((slot (dispatcher-ref 'getnameinfo)))
       (request-bytes 'getnameinfo-req 'getnameinfo count-getnameinfo-req-new!
                      (lambda (err host service) (named-tally!))
                      (lambda () (slot pending-block 0 0 0)) named-tally)))

;; --- through libuv ----------------------------------------------------------
(define idle-loop (make-uv-loop))
(row 'idle-run "a uv-run with nothing to do"
     (fewest-bytes void (lambda () (uv-run idle-loop 'nowait)) always))

;; A timer due now, and the one 'once that fires it. A run that returns
;; before the timer comes due does not count (AGENTS.md's 'once trap).
(define fire-loop (make-uv-loop))
(define fire-timer (make-uv-timer fire-loop))

;; firing-bytes : (procedure procedure procedure -> bytes) procedure
;;                -> bytes, for the uv-runs that fire ON-FIRE.
(define (firing-bytes measure tally on-fire)
  (let ((before 0))
    (measure (lambda ()
               (set! before (tally))
               (uv-timer-start! fire-timer on-fire 0 0))
             (lambda () (uv-run fire-loop 'once))
             (lambda () (= (tally) (+ before 1))))))

(define-tally fire-tally fire-tally!)
(row 'timer-through-libuv "a uv-run that delivers a timer's firing"
     (firing-bytes fewest-bytes fire-tally (lambda (t) (fire-tally!))))

;; A callback whose own code captures a full continuation, as any guard of
;; its own does. A seam that contained raises with a one-shot continuation
;; would allocate less for an empty callback, but Chez would promote that
;; continuation here and copy the stack 64 KiB at a time: ~4.1 KB a callback
;; on the mean, while the cheapest call stays under 600 B. Hence the mean.
(define-tally guarded-tally guarded-tally!)
(row 'guarded-callback-through-libuv
     "a uv-run that delivers a timer callback using a guard of its own, on the mean"
     (firing-bytes mean-bytes guarded-tally
                   (lambda (t)
                     (guard (e (else #f)) (guarded-tally!)))))

;; Each call closes a fresh timer, then meters the run that delivers its
;; close: the dispatcher deregisters and frees the handle, then calls
;; on-close.
(define close-loop (make-uv-loop))
(define-tally closed-tally closed-tally!)
(define (on-closed) (closed-tally!))
(row 'close-through-libuv "a uv-run that delivers a handle's close"
     (let ((before 0))
       (fewest-bytes (lambda ()
                       (set! before (closed-tally))
                       (uv-close! (make-uv-timer close-loop) on-closed))
                     (lambda () (uv-run close-loop 'once))
                     (lambda () (= (closed-tally) (+ before 1))))))

;; A read: libuv's alloc callback, the read itself, and the read callback,
;; which copies the 16 bytes out and calls on-data. The reader has a loop of
;; its own, so the metered run delivers that read and nothing else. Each
;; call's 16 bytes are written, and the write completed, on the writer's
;; loop, off the meter. Answered in Scheme instead, the alloc callback cost
;; 416 B more a read (.plans/shim-alloc-mutation-log.md).
(define rd-loop (make-uv-loop))
(define wr-loop (make-uv-loop))
(define rd-server (make-uv-tcp rd-loop))
(define rd-port (bind-loopback! rd-server))
(define rd-peer #f)
(uv-listen! rd-server 8 (lambda (err) (set! rd-peer (uv-accept! rd-server))))
(define wr-client (make-uv-tcp wr-loop))
(define wr-connected #f)
(connect-loopback! wr-client rd-port (lambda (err) (set! wr-connected #t)))

;; The kernel completes a loopback handshake into the listen backlog by
;; itself, so each loop can be waited on in turn.
(test-equal "seed: the read pair connected across its two loops and was accepted"
  '(satisfied satisfied)
  (let* ((connected (run-until/ticking wr-loop (lambda () wr-connected) 4000))
         (accepted (run-until/ticking rd-loop (lambda () rd-peer) 4000)))
    (list connected accepted)))

(define-tally read-tally read-tally!)
(define read-span 0)
;; Gated on the seed, as r-peer's start is.
(when (uv-tcp? rd-peer)
  (uv-read-start! rd-peer
                  (lambda (bv start end) (set! read-span (- end start)) (read-tally!))
                  (lambda () #f) (lambda (err) #f)))
(define rd-msg (make-bytevector 16 98))
(define-tally rd-written-tally rd-written-tally!)
(define (on-rd-written err) (rd-written-tally!))

;; Should a read never arrive, the watchdog ends the run that waits for it,
;; and that call does not count, rather than the suite hanging there. 50 ms
;; is plenty: a 'once run polls for I/O before it runs any timer, so a read
;; already on its way is delivered first, and a read took 2 ms at most under
;; Valgrind. At 1 s, a change that stopped reads cost 64 s to report.
(define rd-watchdog (make-uv-timer rd-loop))
(define (on-watchdog t) #f)

(row 'read-through-libuv
     "a uv-run that delivers a 16-byte read, its alloc callback answered in the shim"
     (let ((before 0))
       (fewest-bytes (lambda ()
                       (set! before (read-tally))
                       (uv-timer-start! rd-watchdog on-watchdog 50 0)
                       (let ((issued (rd-written-tally)))
                         (uv-write! wr-client rd-msg on-rd-written)
                         (run-until wr-loop (lambda () (> (rd-written-tally) issued)) 64)))
                     (lambda () (uv-run rd-loop 'once))
                     (lambda () (and (= (read-tally) (+ before 1)) (= read-span 16))))))

;; What a delivery through libuv costs over the same delivery straight
;; through its slot: one uv-run and one crossing into Scheme, for a timer.
;; A read must cost no more, or something else crossed for it: an alloc
;; callback answered in Scheme adds 64 B a read on Chez 10.4.1 with no seam
;; at all, and 416 B through one. The margin is half the timer's increment.
(define (through-libuv-increment through direct)
  (let ((t (hashtable-ref measured through #f))
        (d (hashtable-ref measured direct #f)))
    (if (and (integer? t) (integer? d)) (- t d) (list through t direct d))))

(let* ((timer (through-libuv-increment 'timer-through-libuv 'timer))
       (read (through-libuv-increment 'read-through-libuv 'read-data))
       (limit (and (integer? timer) (positive? timer) (+ timer (div timer 2)))))
  (display "  [informational] over a direct delivery, a read through libuv costs ")
  (display read) (display " B, a timer ") (display timer) (display " B") (newline)
  (test-equal (string-append
               "a read through libuv costs over its direct delivery what a timer"
               " does, one crossing, at most "
               (if limit (number->string limit) "?") " bytes")
    'within
    (if (and limit (integer? read) (<= read limit))
        'within
        (list 'read read 'timer timer 'at-most limit))))

;; --- the write verbs, the call alone -----------------------------------------
;; On a connected stream, with each call's completion drained before the
;; next. Nine clients: one for the write rows, and one for each call of the
;; shutdown row, since a stream shuts down once.
(define w-loop (make-uv-loop))
(define w-server (make-uv-tcp w-loop))
(define w-port (bind-loopback! w-server))
(define w-peers '())
(uv-listen! w-server 16
            (lambda (err)
              (let ((peer (uv-accept! w-server)))
                (set! w-peers (cons peer w-peers))
                (uv-read-start! peer (lambda (bv start end) #f)
                                (lambda () #f) (lambda (err) #f)))))
(define w-connected 0)
(define shutdown-calls 8)
(define w-clients
  (let make ((i 0) (acc '()))
    (if (> i shutdown-calls)
        acc
        (let ((c (make-uv-tcp w-loop)))
          (connect-loopback! c w-port
                             (lambda (err) (set! w-connected (+ w-connected 1))))
          (make (+ i 1) (cons c acc))))))

(test-equal "seed: the write clients connected and were accepted"
  'satisfied
  (run-until/ticking w-loop
                     (lambda () (= w-connected (length w-peers) (length w-clients)))
                     4000))

(define w-client (car w-clients))
(define msg (make-bytevector 16 97))
(define segs (list msg))
(define issued 0)
(define-tally w-done-tally w-done-tally!)
(define (on-written err) (w-done-tally!))

;; A write's completion is already queued when the call returns, so plain
;; capped steps deliver it without blocking.
(define (drain-writes!)
  (run-until w-loop (lambda () (= (w-done-tally) issued)) 64))

(row 'uv-write! "a uv-write! of 16 bytes, the call alone"
     (fewest-bytes drain-writes!
                   (lambda ()
                     (uv-write! w-client msg on-written)
                     (set! issued (+ issued 1)))
                   always))

(row 'uv-write*! "a uv-write*! of one 16-byte segment, the call alone"
     (fewest-bytes drain-writes!
                   (lambda ()
                     (uv-write*! w-client segs on-written)
                     (set! issued (+ issued 1)))
                   always))

;; The per-segment cost, which one segment's row cannot see: what a segment
;; adds is less than that row's margin.
(define segs-64 (let make ((i 0)) (if (= i 64) '() (cons msg (make (+ i 1))))))
(row 'uv-write*-64 "a uv-write*! of 64 16-byte segments, the call alone"
     (fewest-bytes drain-writes!
                   (lambda ()
                     (uv-write*! w-client segs-64 on-written)
                     (set! issued (+ issued 1)))
                   always))

;; Each call shuts down the next client; the calls after the last client
;; would raise, so the row stops counting there.
(define shutdown-targets (cdr w-clients))
(row 'uv-shutdown! "a uv-shutdown!, the call alone"
     (let ((shut #f))
       (fewest-bytes (lambda () (set! shut #f))
                     (lambda ()
                       (when (pair? shutdown-targets)
                         (uv-shutdown! (car shutdown-targets) (lambda (err) #f))
                         (set! shutdown-targets (cdr shutdown-targets))
                         (set! shut #t)))
                     (lambda () shut))))

(drain-writes!)

;; --- balance ----------------------------------------------------------------
(for-each uv-loop-teardown!
          (list r-loop idle-loop fire-loop close-loop rd-loop wr-loop w-loop))
(collect)

(test-equal "every allocation counter is back to zero"
  '() (filter (lambda (p) (not (zero? (cdr p)))) (live-counts)))

(test-equal "the registry is back to its starting size"
  registry-count-at-start (registry-count))

(test-end "callback-alloc")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
