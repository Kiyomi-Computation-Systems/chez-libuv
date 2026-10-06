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
        (only (uv-evidence) live-count describe)
        ;; make-engine and bytevector-truncate! drive the shrinking-payload
        ;; sweep.
        (only (chezscheme) collect foreign-alloc foreign-free
              make-engine bytevector-truncate!))

(define runner (test-runner-simple))
(test-runner-current runner)
(define registry-count-at-start (registry-count))

;; The simple runner prints only a failing row's title. The sweep rows
;; return their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

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

;; --- a start libuv refuses leaves nothing behind (#45) -------------------
;; Each verb registers its request before libuv sees it, so a refusal has
;; to take the request back: deregistered, freed and uncounted, then
;; libuv's errno raised under the verb's own name. `let*` orders the reads
;; around the call (AGENTS.md's right-to-left trap).
(define (refusal-and-residue thunk)
  (let* ((write-reqs-before (live-count 'write-req))
         (registry-before (registry-count))
         (outcome (guard (e ((uv-errno-error? e) (list (condition-who e) 'errno))
                            (#t 'wrong-condition))
                    (thunk)
                    'accepted))
         (write-reqs-after (live-count 'write-req))
         (registry-after (registry-count)))
    (list outcome
          (- write-reqs-after write-reqs-before)
          (- registry-after registry-before))))

(test-equal "a uv-write! libuv refuses raises its errno as uv-write! and leaves no request"
  '((uv-write! errno) 0 0)
  (refusal-and-residue (lambda () (uv-write! pipe (make-bytevector 1 7) nop))))

(test-equal "a uv-write*! libuv refuses raises its errno as uv-write*! and leaves no request"
  '((uv-write*! errno) 0 0)
  (refusal-and-residue
   (lambda () (uv-write*! pipe (list (make-bytevector 1 7)) nop))))

(test-equal "a uv-shutdown! libuv refuses raises its errno as uv-shutdown! and leaves no request"
  '((uv-shutdown! errno) 0 0)
  (refusal-and-residue (lambda () (uv-shutdown! pipe nop))))

;; --- a payload that shrinks during the call -------------------------------
;; A write verb checks each span against its bytevector, allocates the
;; request block, and then copies the span in. The copy checks the span
;; again, in one interrupt-free step with the memcpy. An engine's timer can
;; expire between the two checks, and its handler can truncate the
;; bytevector (so can another thread). The copy then finds the span past the
;; new end while the block is allocated and not yet registered, and only the
;; verb can free it.
;;
;; Each sweep runs a verb in an engine at rising fuel. At the first expiry it
;; overwrites the payload with #xff, a byte no run's FILL takes, truncates it
;; to 16 bytes, and resumes the verb. Truncation only shortens the length, so
;; without the overwrite a copy that read past the new end would still send
;; FILL. Fuel 1 stops the engine at its first chance, before the verb's own
;; check, and the sweep stops at the first run no expiry reached, whatever
;; its verdict, so between them every point in the verb is visited. Each run
;; has one right answer:
;;   'refused   the verb refused the span under its own name, with no
;;              request left registered or counted;
;;   'written   the copy came first, and the peer received exactly the bytes
;;              the call was given;
;;   'untouched the last run, which no expiry reached.
;; Which refusals came after the block was allocated is invisible here: the
;; two refusals look the same by design, and the live counters count a
;; request from its registration on. So is a block a refusal fails to free;
;; Valgrind reports that one definitely lost when `make test-memory` runs
;; this suite on Linux.

(define s-loop (make-uv-loop))
(define s-server (make-uv-tcp s-loop))
(define s-port (bind-loopback! s-server))
(define s-received (make-byte-collector))   ; where the current run's bytes go
(define s-peer #f)
(uv-listen! s-server 1
            (lambda (err)
              (set! s-peer (uv-accept! s-server))
              (uv-read-start! s-peer
                              (lambda (bv start end)
                                (collect-span! s-received bv start end))
                              nop nop)))
(define s-client (make-uv-tcp s-loop))
(define s-connected #f)
(connect-loopback! s-client s-port (lambda (err) (set! s-connected #t)))

(test-equal "seed: the sweep's client connected and was accepted"
  'satisfied
  (run-until/ticking s-loop (lambda () (and s-connected s-peer)) 4000))

(define sweep-len 3001)
(define sweep-max-fuel 400)
;; A delivered write drains in one or two steps. The cap bounds what a broken
;; build spends on each of the few runs it can still reach.
(define drain-steps 256)
(define s-issued 0)
(define s-completed 0)
(define (on-swept err) (set! s-completed (+ s-completed 1)))

;; A variant names its verb, writes BV (filled with FILL) through it, and
;; says what the peer must receive and how the verb refuses a span.
(define-record-type sweep-variant
  (fields name write expected refusal))

(define sweep-variants
  (list
   (make-sweep-variant
    'uv-write!
    (lambda (bv fill) (uv-write! s-client bv 0 sweep-len on-swept))
    (lambda (fill) (make-bytevector sweep-len fill))
    '(uv-write! span-out-of-range))
   (make-sweep-variant
    'uv-write*!
    (lambda (bv fill) (uv-write*! s-client (list (list bv 0 sweep-len)) on-swept))
    (lambda (fill) (make-bytevector sweep-len fill))
    '(uv-write*! segment-span-out-of-range))
   ;; The shrinking segment second, so its copy refuses after the first's.
   (make-sweep-variant
    'uv-write*!-second-segment
    (lambda (bv fill)
      (uv-write*! s-client (list (make-bytevector 7 (- 255 fill))
                                 (list bv 0 sweep-len))
                  on-swept))
    (lambda (fill)
      (let ((out (make-bytevector (+ 7 sweep-len) fill)))
        (bytevector-fill-range! out 0 7 (- 255 fill))
        out))
    '(uv-write*! segment-span-out-of-range))))

(define (bytevector-fill-range! bv start end byte)
  (let fill ((i start))
    (when (< i end) (bytevector-u8-set! bv i byte) (fill (+ i 1)))))

;; shrink-verdict : sweep-variant exact-positive-integer
;;                  -> (values verdict boolean)
;; A verdict is one of the symbols above, or else the evidence, a list; the
;; second value says whether an expiry reached the run. FILL is unique to
;; the run among its neighbours and never 0 or #xff, so a run that sent a
;; zeroed or a stale block, or read past the truncated end, cannot match the
;; bytes it was given.
(define (shrink-verdict variant fuel)
  (let* ((fill (+ 1 (mod fuel 254)))
         (bv (make-bytevector sweep-len fill))
         (expired #f)
         (registry-before (registry-count))
         (requests-before (live-count 'write-req))
         (outcome
          (let run ((eng (make-engine
                          (lambda ()
                            (guard (e ((uv-invalid-argument? e)
                                       (list 'refused
                                             (uv-invalid-argument-who e)
                                             (uv-invalid-argument-reason e)))
                                      (#t (list 'raised (describe e))))
                              ((sweep-variant-write variant) bv fill)
                              '(written)))))
                    (ticks fuel))
            (eng ticks
                 (lambda (left v) v)
                 (lambda (next)
                   (unless expired
                     (set! expired #t)
                     (bytevector-fill! bv #xff)
                     (bytevector-truncate! bv 16))
                   (run next 100000)))))
         (registry-after (registry-count))
         (requests-after (live-count 'write-req)))
    (values
     (case (car outcome)
       ((refused)
        (if (and (equal? (cdr outcome) (sweep-variant-refusal variant))
                 (= registry-after registry-before)
                 (= requests-after requests-before))
            'refused
            (list 'refused-as (cdr outcome)
                  'registered (- registry-after registry-before)
                  'counted (- requests-after requests-before))))
       ((written)
        (set! s-issued (+ s-issued 1))
        (set! s-received (make-byte-collector))
        (let* ((expected ((sweep-variant-expected variant) fill))
               (drained (run-until/ticking
                         s-loop
                         (lambda ()
                           (and (= s-completed s-issued)
                                (>= (collector-count s-received)
                                    (bytevector-length expected))))
                         drain-steps))
               (sent (compare-bytes expected (collector-bytes s-received))))
          (cond ((not (and (eq? drained 'satisfied) (eq? sent 'identical)))
                 (list 'written-but-sent sent drained))
                (expired 'written)
                (else 'untouched))))
       (else outcome))
     expired)))

;; shrink-sweep : sweep-variant -> (list-of (list fuel verdict))
;; It stops at the first run no expiry reached, whatever that run's verdict:
;; a build that cannot deliver would otherwise exhaust a drain at every fuel
;; up to the cap, and outlast the suite's timeout before any row could say
;; why. A raise between runs would abort the suite, so the whole sweep is
;; caught and its evidence handed to the rows.
(define (shrink-sweep variant)
  (guard (e (#t (list (list 0 (list 'sweep-raised (describe e))))))
    (let run ((fuel 1) (acc '()))
      (let-values (((verdict expired) (shrink-verdict variant fuel)))
        (let ((acc (cons (list fuel verdict) acc)))
          (if (or (not expired) (= fuel sweep-max-fuel))
              (reverse acc)
              (run (+ fuel 1) acc)))))))

(define shrink-sweeps
  (map (lambda (v) (cons (sweep-variant-name v) (shrink-sweep v)))
       sweep-variants))

;; rows-where : (verdict -> boolean) -> (list-of (list name fuel verdict))
(define (rows-where bad?)
  (apply append
         (map (lambda (sweep)
                (map (lambda (row) (cons (car sweep) row))
                     (filter (lambda (row) (bad? (cadr row))) (cdr sweep))))
              shrink-sweeps)))

(define (verdict-is? kind) (lambda (v) (and (pair? v) (eq? (car v) kind))))

;; The rows below look for bad verdicts and must find none, which says
;; nothing unless each sweep began at the engine's first stop, saw the span
;; refused there, and ran its verb to the end.
(test-equal "each sweep began at fuel 1 with a refusal and ended in a run no expiry reached"
  (map (lambda (v) (list (sweep-variant-name v) '(1 refused) 'untouched))
       sweep-variants)
  (map (lambda (sweep)
         (let ((rows (cdr sweep)))
           (list (car sweep)
                 (car rows)
                 (cadr (list-ref rows (- (length rows) 1))))))
       shrink-sweeps))

(test-equal "a write whose payload shrank during the call is refused by the verb itself, leaving no request"
  '()
  (rows-where (lambda (v) (or ((verdict-is? 'refused-as) v)
                              ((verdict-is? 'raised) v)
                              ((verdict-is? 'sweep-raised) v)))))

(test-equal "a write the sweep let through sent the peer exactly the bytes it was given"
  '()
  (rows-where (verdict-is? 'written-but-sent)))

(uv-loop-teardown! s-loop)

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
