#!r6rs
;;; SRFI-64 suite for allocation balance across whole lifecycles -- design
;;; spec S10 (GC invariants and the debug counters that enforce them) and
;;; S11 ("counters asserted mid-test nonzero, then balanced: after an
;;; ordinary close, after a callback raises, after 100 iterations plus
;;; (collect)").
;;;
;;; Stage 2 filled in the LOOP rows; Stage 3 added the TIMER rows (rows 6-8
;;; below: a timer's counters across an ordinary close, across a callback
;;; that raises, and across 100 make/start/fire/close iterations with a full
;;; collection on each). Stage 4 added the TCP and REQUEST rows (rows 9-11: a
;;; tcp handle across an ordinary close, the connect and write request blocks
;;; across a close that races an in-flight write, and 100
;;; connect/accept/close iterations with a full collection on each). The read
;;; buffer's own row arrives with Stage 5.
;;;
;;; Every assertion here needs the DEV shim (CFLAGS_DEV,
;;; -DCHEZ_LIBUV_DEBUG_COUNTERS); against a production shim the live queries
;;; are constant 0. The first assertion names that precondition, so it is
;;; what fails, by name, rather than a balance check that looks like
;;; cross-wiring.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv tcp)
        (libuv signal)
        (libuv process)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (uv-evidence) live-count)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)

(define registry-count-at-start (registry-count))

(test-begin "lifecycle")

;; --- baseline -----------------------------------------------------------
(test-equal "every allocation counter starts at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-equal "the handle registry starts empty"
  0 registry-count-at-start)

;; --- row 1: an ordinary make / close ------------------------------------
(define l (make-uv-loop))

(test-equal "seed: make-uv-loop moves the live loop counter off zero"
  1 (live-count 'loop))

(test-equal "seed: make-uv-loop puts exactly one entry in the registry"
  1 (- (registry-count) registry-count-at-start))

(uv-loop-close! l)

(test-equal "after an ordinary close the live loop counter is back to zero"
  0 (live-count 'loop))

(test-equal "after an ordinary close the registry is back to its baseline"
  registry-count-at-start (registry-count))

(test-equal "no other allocation class moved across a loop's whole lifetime"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

;; --- row 2: a raise out of call-with-uv-loop ----------------------------
;; The counter is sampled from INSIDE the body, so this cannot pass with a
;; call-with-uv-loop that never allocated a loop at all.
(define seen-inside 'body-never-ran)

(define raise-reason
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (call-with-uv-loop
     (lambda (loop)
       (set! seen-inside (live-count 'loop))
       (uv-run loop 'nowait)
       (raise (make-uv-invalid-argument 'test-body 'deliberate))))
    'no-raise))

(test-equal "seed: a loop was live inside the body that raised"
  1 seen-inside)

(test-equal "the body's raise propagates out of call-with-uv-loop"
  'deliberate raise-reason)

(test-equal "the loop is freed even though the body raised"
  0 (live-count 'loop))

(test-equal "the registry is back to its baseline after the raising body"
  registry-count-at-start (registry-count))

;; --- row 3: a loop torn down through uv-loop-teardown! ------------------
(define td (make-uv-loop))

(test-equal "seed: the teardown loop is live before teardown"
  1 (live-count 'loop))

(uv-loop-teardown! td)

(test-equal "uv-loop-teardown! frees the loop"
  0 (live-count 'loop))

(test-equal "uv-loop-teardown! leaves the registry at its baseline"
  registry-count-at-start (registry-count))

;; --- row 4: the registry is the GC root (ADR-0007, design spec S5) ------
;; "An open handle and its stored closures stay reachable through this table
;; for as long as it is open, even if the caller drops every other reference
;; to it -- closing is therefore never GC-timed." That is a claim about what
;; survives a collection, and it is the one loop-lifecycle property in this
;; stage that needs no handle type to test.
;;
;; The loop record is created inside a `let` whose binding dies with it, so
;; after the collection below the ONLY strong reference left in the program
;; is the registry's own entry. The pointer is kept (an integer, which holds
;; nothing alive) purely as the key to ask the registry with.
(define held-ptr
  (let ((dropped (make-uv-loop)))
    (loop-ptr dropped)))

(collect)

(test-equal "seed: the dropped loop is still allocated after a full collection"
  1 (live-count 'loop))

;; Resolved ONCE and guarded at each use below, so that a registry which
;; stopped holding the record fails these assertions by name instead of
;; aborting the suite on the first accessor that gets handed #f.
(define recovered (registry-ref held-ptr))

(test-equal "a loop the caller dropped is still resolvable through the registry"
  'resolved
  (if (uv-loop? recovered) 'resolved 'not-in-the-registry))

(test-equal "the dropped loop is still open"
  'open
  (if (and (uv-loop? recovered) (uv-loop-open? recovered)) 'open 'not-open))

;; Still FUNCTIONAL, not merely present: this drives the real uv_loop_t
;; through libuv, so a loop whose pointer had been freed out from under the
;; registry would fail here rather than pass on a stale record.
(test-equal "the dropped loop still runs"
  'no-work
  (if (and (uv-loop? recovered) (not (uv-run recovered 'nowait)))
      'no-work
      'work-or-unrecoverable))

(when (uv-loop? recovered) (uv-loop-close! recovered))

(test-equal "closing it through the registry restores the counter balance"
  0 (live-count 'loop))

(test-equal "closing it through the registry restores the registry baseline"
  registry-count-at-start (registry-count))

;; --- row 5: 100 iterations, with a full collection on each --------------
;; (collect) on every iteration is the GC-pressure axis design spec S11 asks
;; for: the registry is the only GC root for an open loop (ADR-0007), so a
;; collection between make and close must not disturb it.
(define peak-live 0)
(define peak-registry 0)

(let iterate ((i 0))
  (when (< i 100)
    (let ((one (make-uv-loop)))
      (uv-run one 'nowait)
      (set! peak-live (max peak-live (live-count 'loop)))
      (set! peak-registry
            (max peak-registry (- (registry-count) registry-count-at-start)))
      (collect)
      (uv-loop-close! one))
    (iterate (+ i 1))))

(test-equal "seed: every one of the 100 iterations held a live loop"
  1 peak-live)

(test-equal "seed: every one of the 100 iterations held a registry entry"
  1 peak-registry)

(test-equal "100 make/run/collect/close iterations leave no live loop"
  0 (live-count 'loop))

(test-equal "100 make/run/collect/close iterations leave the registry at its baseline"
  registry-count-at-start (registry-count))

;; --- row 6: a timer's whole lifecycle, closed normally ------------------
;; Stage 3's handle rows. The counters are asserted to MOVE first and to
;; balance second, per design spec S10 -- a counter stuck at zero throughout
;; would otherwise satisfy every "balanced" assertion in this file.
(define timer-loop (make-uv-loop))
(define timer-live-inside 0)
(define timer-registry-inside 0)

(let ((t (make-uv-timer timer-loop)))
  (uv-timer-start! t (lambda (handle) (collect)) 3600000 0)
  (set! timer-live-inside (live-count 'timer))
  (set! timer-registry-inside (- (registry-count) registry-count-at-start))
  (uv-close! t)
  (uv-run timer-loop 'default))

(test-equal "seed: an open timer is live in the counters"
  1 timer-live-inside)

(test-equal "seed: an open timer holds a registry entry (alongside its loop)"
  2 timer-registry-inside)

(test-equal "an ordinary close returns the live timer counter to zero"
  0 (live-count 'timer))

(test-equal "an ordinary close returns the registry to its baseline"
  1 (- (registry-count) registry-count-at-start))

(uv-loop-teardown! timer-loop)

(test-equal "the timer's loop tore down cleanly afterwards"
  registry-count-at-start (registry-count))

;; --- row 7: the counters after a callback RAISES ------------------------
;; ADR-0008: "test-lifecycle asserts the counters return to baseline after a
;; callback raises -- the check that would fail if a trampoline were ever
;; left unguarded". An unguarded raise terminates the process outright
;; (spike FINDINGS Q2, exit 255), so this row is also the in-suite witness
;; that the guard exists at all.
(define raise-loop (make-uv-loop))
(define raise-timer (make-uv-timer raise-loop))
(define raise-live-inside 0)

(uv-timer-start! raise-timer
                 (lambda (handle)
                   (collect)
                   (set! raise-live-inside (live-count 'timer))
                   (uv-close! handle)
                   (raise (make-uv-invalid-argument 'on-timeout 'deliberate)))
                 1 0)

(define raise-outcome
  (guard (e ((uv-callback-error? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (uv-run raise-loop 'default)
    'no-raise))

(test-equal "seed: the timer was live at the moment its callback raised"
  1 raise-live-inside)

(test-equal "the callback's raise reached the caller through uv-run"
  'deliberate raise-outcome)

;; MEASURED, not assumed. uv_run runs timers BEFORE entering its while loop
;; in UV_RUN_DEFAULT mode (vendor/libuv/src/unix/core.c), and
;; uv__run_closing_handles runs INSIDE that loop -- so the uv_stop this
;; error policy performs (design spec S8) means the close this callback
;; started is still pending when uv-run returns. The handle is 'closing, its
;; pointer is still live, and the counter has not moved yet. That is the
;; state a caller actually gets after a callback raise, so it is the state
;; asserted here rather than the one that would be convenient.
(test-equal "the close the raising callback started is still pending when uv-run returns"
  'closing (uv-handle-state raise-timer))

(test-equal "seed: the timer is still counted while its close is pending"
  1 (live-count 'timer))

(test-equal "running the loop again completes the pending close"
  'closed (begin (uv-run raise-loop 'default) (uv-handle-state raise-timer)))

(test-equal "the counters balance after a callback raise"
  0 (live-count 'timer))

(uv-loop-teardown! raise-loop)

(test-equal "the loop of the raising callback tore down cleanly"
  registry-count-at-start (registry-count))

;; --- row 7b: the ticking fixture disarms itself when the body raises ----
;; uv-testing's run-until/ticking arms a 1 ms timer of its OWN for the length
;; of a wait. Row 7 above proves a raising callback reaches the caller through
;; uv-run; this row proves that when it does so from inside a ticking wait,
;; the fixture's timer does not stay behind on the loop.
;;
;; This is a row about the TEST PLUMBING, and it lives here because the
;; counters are the only thing that can see the difference: a leaked ticker is
;; not visible in the fixture's return value (there isn't one -- the wait
;; raised), only in the next assertion that asks the loop what is still live.
;; Every suite that waits through a raising callback would otherwise measure a
;; loop the fixture is still holding open, and the capstone
;; (tests/test-echo.sps) waits that way on every error path it has.
(define ticking-loop (make-uv-loop))
(define ticking-timer (make-uv-timer ticking-loop))
(define ticking-live-inside 0)

(uv-timer-start! ticking-timer
                 (lambda (handle)
                   (collect)
                   ;; Two: this timer and the fixture's ticker. Reading it
                   ;; from INSIDE the callback is what makes the count below
                   ;; a difference rather than an absolute -- the fixture's
                   ;; timer demonstrably existed at this instant.
                   (set! ticking-live-inside (live-count 'timer))
                   (raise (make-uv-invalid-argument 'on-timeout 'deliberate)))
                 1 0)

;; A predicate that can never hold: the wait ends by the raise or not at all.
(define ticking-outcome
  (guard (e ((uv-callback-error? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (run-until/ticking ticking-loop (lambda () #f) 32)
    'no-raise))

(test-equal "seed: the ticking fixture's own timer was live alongside the raising one"
  2 ticking-live-inside)

(test-equal "a raise inside a ticking wait still reaches the caller"
  'deliberate ticking-outcome)

;; ONE, not two: the raising timer is still live (nothing closed it), and the
;; fixture's ticker is gone -- closed AND drained on the way out. An
;; unwind-unsafe fixture leaves 2 here.
(test-equal "the ticking fixture disarmed its own timer on the unwind path"
  1 (live-count 'timer))

(uv-loop-teardown! ticking-loop)

(test-equal "the loop of the raising ticking wait tore down cleanly"
  registry-count-at-start (registry-count))

;; --- row 8: 100 timer iterations, with a full collection on each --------
(define timer-peak-live 0)
(define timer-fires 0)

(call-with-uv-loop
 (lambda (loop)
   (let iterate ((i 0))
     (when (< i 100)
       (let ((t (make-uv-timer loop)))
         (uv-timer-start! t
                          (lambda (handle)
                            (collect)
                            (set! timer-fires (+ timer-fires 1))
                            (uv-close! handle))
                          1 0)
         (set! timer-peak-live (max timer-peak-live (live-count 'timer)))
         (collect)
         (uv-run loop 'default))
       (iterate (+ i 1))))))

(test-equal "seed: every one of the 100 iterations held a live timer"
  1 timer-peak-live)

(test-equal "every one of the 100 timers actually fired"
  100 timer-fires)

(test-equal "100 timer make/start/fire/close iterations leave no live timer"
  0 (live-count 'timer))

(test-equal "100 timer iterations leave the registry at its baseline"
  registry-count-at-start (registry-count))

;; --- row 9: a tcp handle's whole lifecycle, closed normally -------------
;; Stage 4's handle rows. Same shape as row 6, on the second handle type: the
;; counters are asserted to MOVE first and to balance second, so a 'tcp arm
;; missing from the freeing site's counter switch (design spec S10) fails
;; here rather than passing as "balanced at zero throughout".
(define tcp-loop (make-uv-loop))
(define tcp-live-inside 0)
(define tcp-registry-inside 0)

(let ((s (make-uv-tcp tcp-loop)))
  (bind-loopback! s)
  (set! tcp-live-inside (live-count 'tcp))
  (set! tcp-registry-inside (- (registry-count) registry-count-at-start))
  (uv-close! s)
  (uv-run tcp-loop 'default))

(test-equal "seed: an open tcp handle is live in the counters"
  1 tcp-live-inside)

(test-equal "seed: an open tcp handle holds a registry entry (alongside its loop)"
  2 tcp-registry-inside)

(test-equal "an ordinary close returns the live tcp counter to zero"
  0 (live-count 'tcp))

(test-equal "an ordinary close of a tcp handle returns the registry to its loop alone"
  1 (- (registry-count) registry-count-at-start))

(uv-loop-teardown! tcp-loop)

(test-equal "the tcp handle's loop tore down cleanly afterwards"
  registry-count-at-start (registry-count))

;; --- row 10: the request blocks, including a close that races a write ---
;; A connect request and a write request are separate allocation classes
;; (design spec S10), each freed in exactly one place -- its own completion
;; dispatcher -- and each asserted to MOVE before it is asserted to balance.
;; The write is deliberately still in flight when uv-close! is called, which
;; is the 'ECANCELED path design spec S5 says request dispatchers must
;; tolerate on a 'closing handle. Whichever ordering the platform produces,
;; the block is freed exactly once.
(define wl (make-uv-loop))
(define w-connect-err 'connect-cb-never-fired)
(define w-write-err 'write-cb-never-fired)
(define w-closed 'on-close-never-ran)
(define w-connect-req-inside 0)
(define w-write-req-inside 0)

(define wserver (make-uv-tcp wl))
(define wport (bind-loopback! wserver))

(uv-listen! wserver 128
            (lambda (err)
              (collect)
              (when (not err) (uv-accept! wserver))))

(define wclient (make-uv-tcp wl))

(connect-loopback! wclient wport
                   (lambda (err) (collect) (set! w-connect-err err)))

(set! w-connect-req-inside (live-count 'connect-req))

(run-until wl (lambda () (not (eq? w-connect-err 'connect-cb-never-fired))) 64)

(test-equal "seed: an in-flight connect request is live in the counters"
  1 w-connect-req-inside)

(test-equal "the connect request's block is freed when the connect completes"
  0 (live-count 'connect-req))

(uv-write! wclient (string->utf8 "in flight")
           (lambda (err) (collect) (set! w-write-err err)))

(set! w-write-req-inside (live-count 'write-req))

(uv-close! wclient (lambda () (collect) (set! w-closed 'on-close-ran)))

(run-until wl
           (lambda () (and (not (eq? w-write-err 'write-cb-never-fired))
                           (eq? w-closed 'on-close-ran)))
           64)

(test-equal "seed: the write request was live when the close started"
  1 w-write-req-inside)

(test-equal "the on-close callback of the closed client ran"
  'on-close-ran w-closed)

(test-equal "a write racing a close still frees its block exactly once"
  0 (live-count 'write-req))

(uv-loop-teardown! wl)

(test-equal "the request loop tore down with the registry at its baseline"
  registry-count-at-start (registry-count))

(test-equal "no tcp handle survived the request row"
  0 (live-count 'tcp))

;; --- row 11: 100 connect/accept/close iterations, collecting on each ----
;; The GC-pressure axis of design spec S11, applied to the TCP path: the
;; registry is the only GC root for an open handle or an in-flight request
;; (ADR-0007), so a collection between connect and close must not disturb
;; either.
(define tcp-peak-live 0)
(define connect-req-peak 0)
(define accepts 0)
(define connects 0)

(call-with-uv-loop
 (lambda (loop)
   (let ((srv (make-uv-tcp loop)))
     ;; `srv` is bound BEFORE the callback below is written, so the accept
     ;; needs no forward reference (uv-testing's bind-loopback! comment).
     (let ((port (bind-loopback! srv)))
       (uv-listen! srv 128
                   (lambda (err)
                     (collect)
                     (when (not err)
                       (set! accepts (+ accepts 1))
                       (uv-close! (uv-accept! srv)))))
       (let iterate ((i 0))
         (when (< i 100)
           (let ((c (make-uv-tcp loop))
                 (done #f))
             (connect-loopback! c port
                                (lambda (err) (collect) (set! done #t)))
             ;; Sampled BEFORE the loop runs: at this instant exactly the
             ;; server and this client are live and exactly one connect
             ;; request is outstanding, so both peaks are deterministic
             ;; rather than a function of when the peer's close lands.
             (set! tcp-peak-live (max tcp-peak-live (live-count 'tcp)))
             (set! connect-req-peak
                   (max connect-req-peak (live-count 'connect-req)))
             ;; The wait ticks: a plain 'once blocks for good on an accept
             ;; that never comes, since the listening server keeps the loop
             ;; alive. It spans a handshake, so its cap is a time budget, and
             ;; the iterations stop at the first that ran out of it: the rows
             ;; below then fail by name, after one cap rather than a hundred.
             ;; A connect counts only once its callback came, since the last
             ;; iteration's has nothing after it to stop.
             (let ((outcome (run-until/ticking
                             loop (lambda () (and done (= accepts (+ i 1)))) 4000)))
               (when done (set! connects (+ connects 1)))
               (collect)
               (uv-close! c)
               (run-until loop
                          (lambda () (eq? 'closed (uv-handle-state c)))
                          64)
               (when (eq? outcome 'satisfied) (iterate (+ i 1)))))))))))

(test-equal "seed: every iteration held the server plus its own client"
  2 tcp-peak-live)

(test-equal "seed: every iteration held exactly one outstanding connect request"
  1 connect-req-peak)

(test-equal "every one of the 100 connects completed"
  100 connects)

(test-equal "every one of the 100 connections was accepted"
  100 accepts)

(test-equal "100 connect/accept/collect/close iterations leave no live tcp handle"
  0 (live-count 'tcp))

(test-equal "100 connect/accept/collect/close iterations leave no live connect request"
  0 (live-count 'connect-req))

(test-equal "100 connect/accept/collect/close iterations leave the registry at its baseline"
  registry-count-at-start (registry-count))

;; --- v0.4 signal rows (design spec §9.3; ADR-0007) ----------------------
(define sig-base (live-count 'signal))

;; Row: ordinary close balances.
(let ((l (make-uv-loop)))
  (let ((s (make-uv-signal l)))
    (test-equal "signal counter counts a construction" (+ sig-base 1) (live-count 'signal))
    (uv-close! s)
    (run-until l (lambda () (eq? (uv-handle-state s) 'closed)) 64))
  (uv-loop-teardown! l))
(test-equal "signal counter balanced after an ordinary close" sig-base (live-count 'signal))

;; Row: a raising callback still balances (the guard invariant, ADR-0008).
(let ((l (make-uv-loop)))
  (let ((s (make-uv-signal l)))
    (uv-signal-start! s 'sigusr1 (lambda (x) (collect) (raise 'lifecycle-boom)))
    (uv-kill! (uv-os-getpid) 'sigusr1)
    (guard (e (#t 'reraised))
      (let drain ((i 0)) (when (< i 256) (uv-run l 'once) (drain (+ i 1))))))
  (uv-loop-teardown! l))
(test-equal "signal counter balanced after a raising callback" sig-base (live-count 'signal))

;; Row: 100 make/arm/fire/close iterations with a full collection each.
(let ((l (make-uv-loop)))
  (let loop ((i 0))
    (when (< i 100)
      (let ((fired 0))
        (let ((s (make-uv-signal l)))
          (uv-signal-start! s 'sigusr1
                            (lambda (x) (set! fired (+ fired 1)) (collect)))
          (uv-kill! (uv-os-getpid) 'sigusr1)
          (run-until/ticking l (lambda () (positive? fired)) 512)
          (uv-close! s)
          (run-until l (lambda () (eq? (uv-handle-state s) 'closed)) 64)
          (collect)))
      (loop (+ i 1))))
  (uv-loop-teardown! l))
(test-equal "signal counter balanced after 100 arm/fire/close iterations"
  sig-base (live-count 'signal))

(collect)

(test-equal "a final full collection leaves every counter at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

(test-end "lifecycle")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
