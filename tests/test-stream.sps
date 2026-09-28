#!r6rs
;;; SRFI-64 suite for (libuv stream) -- THE SPEC §9.3's gating matrix: the
;;; five stream verbs (uv-write!, uv-write*!, uv-shutdown!, uv-read-start!,
;;; uv-read-stop!) accept any STREAM handle -- tcp or pipe -- refuse a
;;; non-stream kind with 'not-a-uv-stream, and refuse a closed stream with
;;; &uv-handle-closed carrying ITS kind. tcp's own write/read/shutdown
;;; coverage (payload integrity, backpressure, the counters) stays in
;;; test-tcp.sps and test-echo.sps -- both run UNCHANGED here, through
;;; (libuv tcp)'s re-export, as this task's regression evidence. The
;;; refuses-process row is deferred to test-process.sps (Task 10), once
;;; uv-spawn! can construct a process record.
;;;
;;; NOT pure: (libuv stream) reaches (libuv private native). Never add this
;;; to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv stream)
        (libuv tcp)
        (libuv timer)
        (libuv pipe)
        (libuv process)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (uv-bulk)
        (only (chezscheme) collect foreign-alloc foreign-free))

(define runner (test-runner-simple))
(test-runner-current runner)
(define registry-count-at-start (registry-count))

(test-begin "stream")

(define loop (make-uv-loop))
(define tcp (make-uv-tcp loop))
(define pipe (make-uv-pipe loop))
(define timer (make-uv-timer loop))
(define (nop . args) #f)

;; --- the gating matrix (THE SPEC §9.3) -----------------------------------
;; Each verb: accepts tcp (proved by the untouched v0.1/v0.2 suites),
;; refuses a non-stream kind with 'not-a-uv-stream, refuses a closed
;; stream with &uv-handle-closed carrying ITS kind. The refuses-process
;; row lands in Task 10 (test-process.sps), once uv-spawn! can construct
;; one -- recorded there, not here.
(define (refuses-timer? thunk)
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (thunk) #f))

(test-assert "uv-write! refuses a timer"
  (refuses-timer? (lambda () (uv-write! timer (make-bytevector 1 0) nop))))
(test-assert "uv-write*! refuses a timer"
  (refuses-timer? (lambda () (uv-write*! timer (list (make-bytevector 1 0)) nop))))
(test-assert "uv-shutdown! refuses a timer"
  (refuses-timer? (lambda () (uv-shutdown! timer nop))))
(test-assert "uv-read-start! refuses a timer"
  (refuses-timer? (lambda () (uv-read-start! timer nop nop nop))))
(test-assert "uv-read-stop! refuses a timer"
  (refuses-timer? (lambda () (uv-read-stop! timer))))

;; --- stream verbs on an UNCONNECTED pipe (THE SPEC §4.6, §9.3) -----------
;; A fresh pipe has no fd yet -- uv_spawn is what connects it (V3). The
;; verbs pass the kind gate and libuv answers an errno; this row PINS
;; whatever that errno is (bind what you test): expected 'EBADF-class.
;; The assertion accepts the symbol family rather than one platform's
;; spelling; the informational row prints the observed symbol so the
;; pinned value is recorded in every run's output.
(define unconnected-errno
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
    (uv-write! pipe (make-bytevector 1 7) nop)
    'no-error))
(test-assert "uv-write! on an unconnected pipe surfaces an errno symbol"
  (and (symbol? unconnected-errno) (not (eq? 'no-error unconnected-errno))))
(test-assert "[informational] unconnected-pipe errno recorded"
  (begin (display "  [informational] unconnected pipe write: ")
         (display unconnected-errno) (newline) #t))

;; --- the write verbs move their payload in bulk (issue #35) -------------
;; A write to the unconnected pipe runs the verb's whole synchronous prefix --
;; the checks, the block's allocation and zeroing, the payload copy, the
;; uv_buf_t, the registry -- then libuv answers the errno above and the block
;; is abandoned. That prefix is what held the loop ~250 ms per 4 MiB before
;; #35, and half of it was alloc-zeroed, which test-native's helper rows do
;; not reach. Each row times the verb against libc allocating, zeroing and
;; copying the same bytes (tests/uv-bulk.sls) and wants it within bulk-bar;
;; a regression to a byte loop anywhere in the prefix lands 100x or more away.
(define bulk-size (* 4 1024 1024))
(define bulk-payload (make-bytevector bulk-size 7))
(define bulk-segments                   ; 16 spans of 256 KiB
  (map (lambda (i) (list bulk-payload (* i 262144) (* (+ i 1) 262144)))
       (list 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)))

(define (libc-write-block)
  (let* ((header 256)
         (block (foreign-alloc (+ header bulk-size))))
    (libc-memset! block 0 (+ header bulk-size))
    (libc-memcpy-to-foreign! (+ block header) bulk-payload bulk-size)
    (foreign-free block)))

(define (refused-by-the-pipe thunk)
  (lambda () (guard (e ((uv-errno-error? e) 'refused)) (thunk))))

(test-equal (string-append "uv-write! moves its payload at libc speed: within "
                           (number->string bulk-bar)
                           "x of allocating, zeroing and copying it")
  'bulk
  (bulk-verdict 'uv-write! bulk-size
                (refused-by-the-pipe
                 (lambda () (uv-write! pipe bulk-payload nop)))
                libc-write-block))
(test-equal (string-append "uv-write*! moves its segments at libc speed: within "
                           (number->string bulk-bar)
                           "x of allocating, zeroing and copying them")
  'bulk
  (bulk-verdict 'uv-write*! bulk-size
                (refused-by-the-pipe
                 (lambda () (uv-write*! pipe bulk-segments nop)))
                libc-write-block))

;; --- closed-stream refusals ---------------------------------------------
(uv-close! pipe)
(run-until loop (lambda () (eq? 'closed (uv-handle-state pipe))) 64)
(test-assert "uv-write! on a closed pipe raises &uv-handle-closed kind 'pipe"
  (guard (e (#t (and (uv-handle-closed? e)
                     (eq? 'pipe (uv-handle-closed-kind e)))))
    (uv-write! pipe (make-bytevector 1 0) nop) #f))
(test-assert "uv-write*! on a closed pipe raises &uv-handle-closed kind 'pipe"
  (guard (e (#t (and (uv-handle-closed? e)
                     (eq? 'pipe (uv-handle-closed-kind e)))))
    (uv-write*! pipe (list (make-bytevector 1 0)) nop) #f))

;; --- tcp still works through the re-export (regression canary) ----------
(test-assert "uv-write! still accepts an open tcp (kind gate only -- EBADF-class errno is fine)"
  (guard (e ((uv-errno-error? e) #t))   ;; unbound tcp: libuv may refuse; the KIND gate passed
    (uv-write! tcp (make-bytevector 1 0) nop) #t))

;; --- the refuses-process row (deferred here from Task 7) -----------------
(define loop2 (make-uv-loop))
(define proc (uv-spawn! loop2 "/bin/sh" '("sh" "-c" "exit 0") #f))
(test-assert "uv-write! refuses a process handle"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (uv-write! proc (make-bytevector 1 0) (lambda (err) #f)) #f))
(test-assert "uv-write*! refuses a process handle"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (uv-write*! proc (list (make-bytevector 1 0)) (lambda (err) #f)) #f))
(uv-loop-teardown! loop2)

;; --- a CLOSED handle of the WRONG kind (Task 7's mutation probe 2 forward
;; obligation, .plans/process-stage-4-mutation-log.md): require-open-stream's
;; kind check runs FIRST, so a closed timer still raises 'not-a-uv-stream --
;; never &uv-handle-closed. That ordering is exactly what probe 2 (swapping
;; the kind/state check order) could not observe, because every closed
;; handle this suite exercised elsewhere was already a real stream kind.
(uv-close! timer)
(run-until loop (lambda () (eq? 'closed (uv-handle-state timer))) 64)
(test-assert "uv-write! on a CLOSED timer raises 'not-a-uv-stream, not &uv-handle-closed"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (uv-write! timer (make-bytevector 1 0) nop) #f))
(test-assert "uv-write*! on a CLOSED timer raises 'not-a-uv-stream, not &uv-handle-closed"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (uv-write*! timer (list (make-bytevector 1 0)) nop) #f))

(uv-loop-teardown! loop)
(collect)
(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))

(test-end "stream")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
