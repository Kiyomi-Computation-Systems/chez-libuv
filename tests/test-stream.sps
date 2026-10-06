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
        ;; set-cdr! changes a segment list in the segment-list sweeps.
        (rnrs mutable-pairs)
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
        ;; make-engine drives the engine sweeps, and bytevector-truncate!
        ;; the shrinking-payload one; the interrupt pair checks that no
        ;; refusal leaves interrupts disabled; foreign-procedure binds the
        ;; libuv queries the split sweeps' witnesses read. The thread
        ;; primitives run the span race, and getenv skips it under Valgrind.
        (only (chezscheme) collect foreign-alloc foreign-free foreign-procedure
              make-engine bytevector-truncate!
              disable-interrupts enable-interrupts
              fork-thread make-mutex make-condition with-mutex
              condition-wait condition-broadcast getenv))

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
;;
;; Any other raise is kept as the evidence, so that the row below fails by
;; name rather than this plumbing aborting the suite (the #49 review's M8).
(define unconnected-errno
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'raised (describe e))))
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
;; around the call (AGENTS.md's right-to-left trap). The block counter
;; sees the free itself.
(define (refusal-and-residue thunk)
  (let* ((write-reqs-before (live-count 'write-req))
         (registry-before (registry-count))
         (blocks-before (live-count 'block))
         (outcome (guard (e ((uv-errno-error? e) (list (condition-who e) 'errno))
                            (#t 'wrong-condition))
                    (thunk)
                    'accepted))
         (write-reqs-after (live-count 'write-req))
         (registry-after (registry-count))
         (blocks-after (live-count 'block)))
    (list outcome
          (- write-reqs-after write-reqs-before)
          (- registry-after registry-before)
          (- blocks-after blocks-before))))

(test-equal "a uv-write! libuv refuses raises its errno as uv-write! and leaves no request"
  '((uv-write! errno) 0 0 0)
  (refusal-and-residue (lambda () (uv-write! pipe (make-bytevector 1 7) nop))))

(test-equal "a uv-write*! libuv refuses raises its errno as uv-write*! and leaves no request"
  '((uv-write*! errno) 0 0 0)
  (refusal-and-residue
   (lambda () (uv-write*! pipe (list (make-bytevector 1 7)) nop))))

(test-equal "a uv-shutdown! libuv refuses raises its errno as uv-shutdown! and leaves no request"
  '((uv-shutdown! errno) 0 0 0)
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
;; A delivered write drains in one or two steps on a quiet machine. With the
;; machine's load average at 43, a drain once outran 256 steps, and the
;; write's bytes then landed in the next run's count. The cap bounds what a
;; broken build spends on each of the few runs it can still reach.
(define drain-steps 2000)
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

;; change-verdict : exact-positive-integer (fill -> argument)
;;                  (argument fill -> object) (argument -> unspecified)
;;                  (fill -> bytevector) list -> (values verdict boolean)
;; One run of a sweep: CALL the verb on the argument MAKE gives for the run's
;; FILL, in an engine with FUEL, and CHANGE! that argument at the first
;; expiry. The peer must then receive EXPECTED-FOR's bytes, or the verb
;; refuse with REFUSAL. A verdict is one of the symbols above, or else the
;; evidence, a list; the second value says whether an expiry reached the run.
;; FILL is unique to the run among its neighbours and never 0 or #xff, so a
;; run that sent a zeroed or a stale block, or read past the truncated end,
;; cannot match the bytes it was given. A call still running after
;; resume-cap resumes is given up there, so a walk that never ends fails its
;; run by name.
(define resume-cap 20)

(define (change-verdict fuel make call change! expected-for refusal)
  (let* ((fill (+ 1 (mod fuel 254)))
         (argument (make fill))
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
                              (call argument fill)
                              '(written)))))
                    (ticks fuel)
                    (resumes 0))
            (eng ticks
                 (lambda (left v) v)
                 (lambda (next)
                   (unless expired
                     (set! expired #t)
                     (change! argument))
                   (if (= resumes resume-cap)
                       (list 'stuck-after-resumes resumes)
                       (run next 100000 (+ resumes 1)))))))
         (registry-after (registry-count))
         (requests-after (live-count 'write-req)))
    (values
     (case (car outcome)
       ((refused)
        (if (and (equal? (cdr outcome) refusal)
                 (= registry-after registry-before)
                 (= requests-after requests-before))
            'refused
            (list 'refused-as (cdr outcome)
                  'registered (- registry-after registry-before)
                  'counted (- requests-after requests-before))))
       ((written)
        (set! s-issued (+ s-issued 1))
        (set! s-received (make-byte-collector))
        (let* ((expected (expected-for fill))
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

(define (shrink! bv)
  (bytevector-fill! bv #xff)
  (bytevector-truncate! bv 16))

;; shrink-verdict : sweep-variant exact-positive-integer
;;                  -> (values verdict boolean)
(define (shrink-verdict variant fuel)
  (change-verdict fuel
                  (lambda (fill) (make-bytevector sweep-len fill))
                  (sweep-variant-write variant)
                  shrink!
                  (sweep-variant-expected variant)
                  (sweep-variant-refusal variant)))

(define (verdict-is? kind) (lambda (v) (and (pair? v) (eq? (car v) kind))))

;; A written run whose drain ran out of steps: one that cannot deliver.
(define (drain-ran-out? verdict)
  (and ((verdict-is? 'written-but-sent) verdict)
       (not (eq? (caddr verdict) 'satisfied))))

;; sweep-runs : (exact-positive-integer -> (values verdict boolean))
;;              -> (list-of (list fuel verdict))
;; It stops at the first run no expiry reached, whatever that run's verdict.
;; It stops at a run whose drain ran out, too, and at one given up after
;; resume-cap resumes: a build that cannot deliver, or a walk that never
;; ends, would cost every later run the same, and outlast the suite's
;; timeout before any row could say why (the segment-list sweeps below write
;; three dozen runs each). A raise between runs would abort the suite, so
;; the whole sweep is caught and its evidence handed to the rows.
(define (sweep-runs verdict-at)
  (guard (e (#t (list (list 0 (list 'sweep-raised (describe e))))))
    (let run ((fuel 1) (acc '()))
      (let-values (((verdict expired) (verdict-at fuel)))
        (let ((acc (cons (list fuel verdict) acc)))
          (if (or (not expired)
                  (drain-ran-out? verdict)
                  ((verdict-is? 'stuck-after-resumes) verdict)
                  (= fuel sweep-max-fuel))
              (reverse acc)
              (run (+ fuel 1) acc)))))))

(define (shrink-sweep variant)
  (sweep-runs (lambda (fuel) (shrink-verdict variant fuel))))

(define shrink-sweeps
  (map (lambda (v) (cons (sweep-variant-name v) (shrink-sweep v)))
       sweep-variants))

;; rows-in : sweeps (verdict -> boolean) -> (list-of (list name fuel verdict))
(define (rows-in sweeps bad?)
  (apply append
         (map (lambda (sweep)
                (map (lambda (row) (cons (car sweep) row))
                     (filter (lambda (row) (bad? (cadr row))) (cdr sweep))))
              sweeps)))

;; sweep-reach : sweeps -> (list-of (list name first-row last-verdict))
;; The rows that look for bad verdicts must find none, which says nothing
;; unless each sweep began at the engine's first stop, before the verb's own
;; check, and ran its verb to the end.
(define (sweep-reach sweeps)
  (map (lambda (sweep)
         (let ((rows (cdr sweep)))
           (list (car sweep)
                 (car rows)
                 (cadr (list-ref rows (- (length rows) 1))))))
       sweeps))

(define (one-right-answer? verdict)
  (and (memq verdict '(refused written untouched)) #t))

;; Anything but a right answer or a write the peer received wrongly, which
;; its own row reports.
(define (wrong-answer? verdict)
  (not (or (one-right-answer? verdict)
           ((verdict-is? 'written-but-sent) verdict))))

(test-equal "each sweep began at fuel 1 with a refusal and ended in a run no expiry reached"
  (map (lambda (v) (list (sweep-variant-name v) '(1 refused) 'untouched))
       sweep-variants)
  (sweep-reach shrink-sweeps))

(test-equal "a write whose payload shrank during the call is refused by the verb itself, leaving no request"
  '()
  (rows-in shrink-sweeps wrong-answer?))

(test-equal "a write the sweep let through sent the peer exactly the bytes it was given"
  '()
  (rows-in shrink-sweeps (verdict-is? 'written-but-sent)))

;; --- a segment list that changes during the call (#64) ---------------------
;; uv-write*! reads the caller's segment list before its step. It used to
;; read it with Chez's map, which measures a list and then walks it without
;; checking its pairs. An engine's handler, or another thread, that put a
;; non-pair in the list during the walk had the walk read through it, an
;; `invalid memory reference` wherever the non-pair pointed. A list made
;; circular there was walked without end, in a walk no engine's fuel stops:
;; the process grew to about 6 GB before it was killed. The verb now counts
;; the list with proper-length, walks at most that many pairs checking each
;; one, and reads each (bytevector start end) span once the same way.
;;
;; Each sweep writes twelve 5-byte segments through uv-write*! in an engine
;; at rising fuel, as the payload sweeps above do, and changes the list at
;; the first expiry:
;;   segments-cut            the third pair's cdr becomes a vector;
;;   segments-made-circular  the third pair's cdr becomes the list's head;
;;   segments-two-cycles     the sixth pair's cdr becomes the fifth, and the
;;                           twelfth's the eleventh: a count that walked a
;;                           second pointer behind the first could be left
;;                           on one cycle while the first went round the
;;                           other, and never end (#64's review);
;;   span-cut                the third segment, a (bv 0 5) span, loses its end.
;; Each run has one right answer: 'refused under the verb's own name with no
;; request left, or 'written with the peer receiving exactly the twelve
;; segments the call was given ('untouched for the last run, as above).
;;
;; The two cyclic sweeps run only when every run of the cut sweep had one of
;; those answers. A build whose walk reads through a non-pair would walk a
;; cyclic list without end and take the machine's memory instead of failing,
;; so there they are skipped, and their rows fail by name.
(define seg-count 12)
(define seg-len 5)

;; seg-byte : fill exact-nonnegative-integer -> byte
;; Segment I's byte: never 0 or #xff, and different for each segment, so a
;; walk that read a segment twice or out of order cannot send the bytes the
;; call was given.
(define (seg-byte fill i) (+ 1 (mod (+ fill (* 19 i)) 254)))

(define (seg-list fill)
  (let make ((i 0))
    (if (= i seg-count)
        '()
        (cons (make-bytevector seg-len (seg-byte fill i)) (make (+ i 1))))))

;; The same list, with the third segment a (bv 0 5) span of a longer
;; bytevector.
(define (seg-list-with-span fill)
  (let ((segs (seg-list fill)))
    (set-car! (cddr segs)
              (list (make-bytevector (+ seg-len 4) (seg-byte fill 2)) 0 seg-len))
    segs))

(define (seg-bytes fill)
  (let ((out (make-bytevector (* seg-count seg-len))))
    (let fill-in ((i 0))
      (when (< i seg-count)
        (bytevector-fill-range! out (* i seg-len) (* (+ i 1) seg-len)
                                (seg-byte fill i))
        (fill-in (+ i 1))))
    out))

(define (cut-third! segs) (set-cdr! (cddr segs) (vector 'not 'a 'pair)))
(define (circle-third! segs) (set-cdr! (cddr segs) segs))
(define (two-cycles! segs)
  (let ((p4 (list-tail segs 4)) (p5 (list-tail segs 5))
        (p10 (list-tail segs 10)) (p11 (list-tail segs 11)))
    (set-cdr! p5 p4)
    (set-cdr! p11 p10)))
(define (cut-span! segs) (set-cdr! (cdr (caddr segs)) 'oops))

;; list-sweep : (fill -> segments) (segments -> unspecified) list -> sweep
(define (list-sweep make change! refusal)
  (sweep-runs
   (lambda (fuel)
     (change-verdict fuel
                     make
                     (lambda (segs fill) (uv-write*! s-client segs on-swept))
                     change!
                     seg-bytes
                     refusal))))

(define cut-sweep
  (list-sweep seg-list cut-third! '(uv-write*! segments-not-a-list)))

(define walk-checked?
  (for-all (lambda (row) (one-right-answer? (cadr row))) cut-sweep))

(define (cyclic-sweep change!)
  (if walk-checked?
      (list-sweep seg-list change! '(uv-write*! segments-not-a-list))
      '((0 (skipped the-cut-sweep-had-another-answer)))))

(define list-sweeps
  (list (cons 'segments-cut cut-sweep)
        (cons 'segments-made-circular (cyclic-sweep circle-third!))
        (cons 'segments-two-cycles (cyclic-sweep two-cycles!))
        (cons 'span-cut
              (list-sweep seg-list-with-span cut-span!
                          '(uv-write*! segment-not-a-bytevector)))))

(test-equal "each segment-list sweep began at fuel 1 with a refusal and ended in a run no expiry reached"
  '((segments-cut (1 refused) untouched)
    (segments-made-circular (1 refused) untouched)
    (segments-two-cycles (1 refused) untouched)
    (span-cut (1 refused) untouched))
  (sweep-reach list-sweeps))

(test-equal "a uv-write*! whose segment list changed during the call is refused by the verb itself, leaving no request"
  '()
  (rows-in list-sweeps wrong-answer?))

(test-equal "a uv-write*! the segment-list sweeps let through sent the peer exactly the segments it was given"
  '()
  (rows-in list-sweeps (verdict-is? 'written-but-sent)))

;; --- a span another thread changes during the call (#64) -------------------
;; An engine stops a call only at a trap check, but another thread can
;; change a span between any two instructions. A flipper turns a (bv 0 5)
;; span's tail between (5) and 'oops while this thread writes the span
;; through uv-write*! to a pipe that is not connected, so a write that
;; parses is refused by libuv's errno and sends nothing. Every call must be
;; refused under the verb's own name: by the parse, or with libuv's errno. A
;; span read twice, checked the first time, would raise Chez's own
;; condition the second, which no engine sweep can split. As in
;; test-addrinfo's cross-thread row, the row asserts only what no schedule
;; can make fail on a right answer, and the informational line counts the
;; calls the flipper's change reached. Not under Valgrind, which runs one
;; thread at a time.
(define span-race-calls 20000)

;; span-race : -> (list calls bad first-bad cut)
;; Every exit stops the flipper, waits for it, and closes what it made.
(define (span-race)
  (let* ((l (make-uv-loop))
         (p (make-uv-pipe l))
         (span (list (make-bytevector 9 7) 0 5))
         (second (cdr span))
         (tail (cdr second))
         (segs (list span))
         (stop #f)
         (stopped #f)
         (m (make-mutex))
         (c (make-condition)))
    (fork-thread
     (lambda ()
       (let flip ()
         (unless stop
           (set-cdr! second 'oops)
           (set-cdr! second tail)
           (flip)))
       (with-mutex m (set! stopped #t) (condition-broadcast c))))
    (let ((result
           (let call ((i 0) (bad 0) (first-bad #f) (cut 0))
             (if (= i span-race-calls)
                 (list i bad first-bad cut)
                 (let ((outcome
                        (guard (e ((uv-invalid-argument? e)
                                   (list 'refused (uv-invalid-argument-who e)
                                         (uv-invalid-argument-reason e)))
                                  ((uv-errno-error? e) (list 'errno (condition-who e)))
                                  (#t (list 'raised (describe e))))
                          (uv-write*! p segs nop)
                          '(written))))
                   (cond ((equal? outcome '(refused uv-write*! segment-not-a-bytevector))
                          (call (+ i 1) bad first-bad (+ cut 1)))
                         ((equal? outcome '(errno uv-write*!))
                          (call (+ i 1) bad first-bad cut))
                         (else (call (+ i 1) (+ bad 1)
                                     (or first-bad (list i outcome)) cut))))))))
      (set! stop #t)
      (with-mutex m (let wait () (unless stopped (condition-wait c m) (wait))))
      (uv-close! p)
      (uv-loop-teardown! l)
      result)))

(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] span race: skipped under Valgrind,")
      (display " which runs one thread at a time")
      (newline))
    (let ((race (span-race)))
      (display "  [informational] span race: ")
      (display (cadddr race))
      (display " of ")
      (display (car race))
      (display " calls found the span cut")
      (newline)
      (test-equal "a uv-write*! whose span another thread changes is refused by the verb, never by Chez"
        (list span-race-calls 0 #f)
        (list (car race) (cadr race) (caddr race)))))

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
;; A spawn that raises is kept as the evidence, so that the rows below fail
;; by name rather than this plumbing aborting the suite. They require a
;; process first: anything else is refused as 'not-a-uv-stream too.
(define loop2 (make-uv-loop))
(define proc
  (guard (e (#t (list 'raised (describe e))))
    (uv-spawn! loop2 "/bin/sh" '("sh" "-c" "exit 0") #f)))
(test-assert "uv-write! refuses a process handle"
  (and (uv-process? proc)
       (guard (e (#t (and (uv-invalid-argument? e)
                          (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
         (uv-write! proc (make-bytevector 1 0) (lambda (err) #f)) #f)))
(test-assert "uv-write*! refuses a process handle"
  (and (uv-process? proc)
       (guard (e (#t (and (uv-invalid-argument? e)
                          (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
         (uv-write*! proc (list (make-bytevector 1 0)) (lambda (err) #f)) #f)))
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

;; --- a verb split by an engine ---------------------------------------------
;; A green-thread scheduler on the loop thread runs each task in an engine,
;; and a task's fuel can run out anywhere inside a stream verb. Two things
;; can then go wrong, and both did on every verb here before each verb's
;; check, allocation, registration and native call became one interrupt-free
;; step (one-step in (libuv private handles)):
;; - Another task closes the stream and runs the loop, which frees the
;;   uv_tcp_t, and the verb resumes past its open check with the stale
;;   pointer. Valgrind reports libuv reading the freed block. If a new
;;   connection has been given the same address meanwhile, as it was on every
;;   macOS run, the verb acts on that connection instead: a write delivers
;;   its bytes to the new connection's peer and reports success.
;; - The scheduler drops the task, as a timeout does, and never resumes it.
;;   Whatever the verb had allocated and not yet handed to libuv is lost: a
;;   block, or a request registered and counted that libuv never saw.
;;
;; Each sweep runs a verb in an engine at rising fuel. Fuel 1 expires before
;; the verb's own open check, and the sweep stops at the first run no expiry
;; reaches, so between them every point in the verb is visited. At the
;; expiry, the split sweep asks libuv whether the verb's native call has
;; been made, closes the stream, steps the loop until the close has freed
;; it, and resumes the verb. So each run has one right answer:
;;   'refused           not yet made: resumed, the verb sees the stream
;;                      closed and raises &uv-handle-closed;
;;   'made-before-close made before the close (or the verb had returned),
;;                      its effect landed, and resumed, the verb returns;
;;   'untouched         no expiry: it ran whole, and its effect landed.
;; A verb that returns after the close without having been made made its
;; native call on the freed stream. The reuse sweeps open a new connection
;; after the free, before resuming, and its peer must receive nothing. The
;; drop sweep drops the engine instead, and requires the registry, every
;; counter and the blocks alive back where the run began once the
;; connection is closed.

(define (interrupts-enabled?)
  (disable-interrupts)
  (zero? (enable-interrupts)))

(define sw-loop (make-uv-loop))
(define sw-server (make-uv-tcp sw-loop))
(define sw-port (bind-loopback! sw-server))
(define sw-accepted #f)
(uv-listen! sw-server 16
            (lambda (err) (set! sw-accepted (uv-accept! sw-server))))

;; libuv's own view of a stream, for the witnesses below: whether it is
;; active (reading, here) and whether it can still be written (a shutdown
;; clears that at once, in uv_shutdown itself). Neither is bound by the
;; library; the loop above has loaded libuv.
(define uv-is-active (foreign-procedure "uv_is_active" (uptr) int))
(define uv-is-writable (foreign-procedure "uv_is_writable" (uptr) int))

;; A link is one connection: the client a verb runs on, the peer the server
;; accepted for it, what each received, whether the peer saw EOF, and
;; whether the verb's own callback has run.
(define-record-type link
  (fields client (mutable peer) (mutable connected)
          peer-got client-got (mutable peer-eof) (mutable called-back)))

;; connect-link! : -> (or link #f)
(define (connect-link!)
  (let ((lk (make-link (make-uv-tcp sw-loop) #f #f
                       (make-byte-collector) (make-byte-collector) #f #f)))
    (set! sw-accepted #f)
    (connect-loopback! (link-client lk) sw-port
                       (lambda (err) (link-connected-set! lk (if err 'failed #t))))
    (run-until/ticking sw-loop
                       (lambda () (or (eq? (link-connected lk) 'failed)
                                      (and (link-connected lk) sw-accepted)))
                       4000)
    (and (eq? (link-connected lk) #t) sw-accepted
         (begin
           (link-peer-set! lk sw-accepted)
           (uv-read-start! sw-accepted
                           (lambda (bv start end)
                             (collect-span! (link-peer-got lk) bv start end))
                           (lambda () (link-peer-eof-set! lk #t))
                           nop)
           lk))))

;; poll! : (-> boolean) -> boolean
;; Steps the loop until (DONE?) holds, at most 16 times, and answers it.
;; 'nowait, never 'once: with nothing due, 'once would block on the server.
;; For what the loop delivers by itself (a callback libuv has queued, a
;; close); bytes crossing the kernel's loopback want settle!.
(define (poll! done?)
  (let step ((i 0))
    (cond ((done?) #t)
          ((= i 16) #f)
          (else (uv-run sw-loop 'nowait) (step (+ i 1))))))

;; settle! : (-> boolean) exact-positive-integer -> boolean
;; Steps the loop until (DONE?) holds, waking at least every millisecond, at
;; most STEPS times, and answers it. Bytes cross the kernel's loopback after
;; the call that sent them: macOS hands the packets to a kernel thread.
;; - Waiting for something to land, a run waits LANDING-STEPS. On a quiet
;;   machine it lands in one or two steps, but with the machine's load
;;   average at 43, an untouched write once missed a cap of 20. Only a build
;;   whose effect never lands pays the full wait.
;; - Waiting to see that nothing lands, a run waits STRAY-STEPS. A late
;;   arrival there can only let a broken build pass, never fail a sound one.
(define landing-steps 2000)
(define stray-steps 20)

(define (settle! done? steps)
  (eq? 'satisfied (run-until/ticking sw-loop done? steps)))

(define (closed-or-absent? h) (or (not h) (eq? 'closed (uv-handle-state h))))

;; close-link! : link -> unspecified
;; Closes whatever of the link is still open, and steps the loop until the
;; closes have freed it all. A 'nowait step runs the closes due, so poll!
;; suffices, and a close that never finishes cannot block the suite.
(define (close-link! lk)
  (for-each (lambda (h) (when (and h (uv-handle-open? h)) (uv-close! h)))
            (list (link-client lk) (link-peer lk)))
  (poll! (lambda () (and (closed-or-absent? (link-client lk))
                         (closed-or-absent? (link-peer lk))))))

;; What the run must leave as it found it: the registry, and every debug
;; counter, blocks included.
(define (balance) (cons (registry-count) (live-counts)))

(define (residue before)
  (let ((after (balance)))
    (append
     (if (= (car before) (car after))
         '()
         (list (list 'registry (- (car after) (car before)))))
     (filter (lambda (x) x)
             (map (lambda (b a)
                    (and (not (= (cdr b) (cdr a)))
                         (list (car b) (- (cdr a) (cdr b)))))
                  (cdr before) (cdr after))))))

;; A variant names a verb, readies a link for it, and starts it on the
;; link's client. MADE? says, with the stream still open, whether the verb's
;; native call has been made, or 'unobservable for a call that leaves no
;; trace. LANDED? checks the effect of a call that was made.
(define-record-type variant (fields name prepare start made? landed?))

(define payload-len 64)

(define (no-prepare lk fill) #f)

;; The verb's own callback records its answer: #t, or the error it got.
(define (calls-back lk)
  (lambda (err) (link-called-back-set! lk (if err (describe err) #t))))

;; A write's callback is queued once uv_write has written, and the next
;; loop step runs it.
(define (called-back? lk fill) (poll! (lambda () (link-called-back lk))))

;; link-evidence : link -> list
;; What a run that never landed carries, for whoever reads its row: the
;; callback's answer, what each side received, and whether libuv has each
;; side reading and how much it still holds to write.
(define (link-evidence lk)
  (define (state h)
    (if (uv-handle-open? h)
        (list 'active (uv-is-active (handle-ptr h))
              'queued (uv-stream-write-queue-size h))
        (list (uv-handle-state h))))
  (list 'called-back (link-called-back lk)
        'peer-got (collector-count (link-peer-got lk))
        'client-got (collector-count (link-client-got lk))
        'peer-eof (link-peer-eof lk)
        'client (state (link-client lk))
        'peer (state (link-peer lk))))

;; Whether the peer received exactly the payload: PAYLOAD-LEN bytes of FILL.
(define (peer-got-payload? lk fill)
  (settle! (lambda () (>= (collector-count (link-peer-got lk)) payload-len))
           landing-steps)
  (eq? 'identical (compare-bytes (make-bytevector payload-len fill)
                                 (collector-bytes (link-peer-got lk)))))

(define (client-reader lk)
  (lambda (bv start end) (collect-span! (link-client-got lk) bv start end)))

(define (client-got-a-byte? lk)
  (positive? (collector-count (link-client-got lk))))

;; The peer sends the client one byte; answers whether its write completed.
(define (peer-sends-a-byte! lk fill)
  (let ((done #f))
    (uv-write! (link-peer lk) (make-bytevector 1 fill) (lambda (err) (set! done #t)))
    (poll! (lambda () done))))

(define (client-active? lk) (= 1 (uv-is-active (handle-ptr (link-client lk)))))

(define variants
  (list
   (make-variant
    'uv-write! no-prepare
    (lambda (lk fill)
      (uv-write! (link-client lk) (make-bytevector payload-len fill) 0 payload-len
                 (calls-back lk)))
    called-back? peer-got-payload?)
   (make-variant
    'uv-write*! no-prepare
    (lambda (lk fill)
      (let ((half (div payload-len 2)))
        (uv-write*! (link-client lk)
                    (list (make-bytevector half fill)
                          (list (make-bytevector payload-len fill) 0 half))
                    (calls-back lk))))
    called-back? peer-got-payload?)
   (make-variant
    'uv-shutdown! no-prepare
    (lambda (lk fill) (uv-shutdown! (link-client lk) nop))
    (lambda (lk fill) (zero? (uv-is-writable (handle-ptr (link-client lk)))))
    (lambda (lk fill) (settle! (lambda () (link-peer-eof lk)) landing-steps)))
   ;; The peer's byte waits until reading starts.
   (make-variant
    'uv-read-start! peer-sends-a-byte!
    (lambda (lk fill) (uv-read-start! (link-client lk) (client-reader lk) nop nop))
    (lambda (lk fill) (client-active? lk))
    (lambda (lk fill) (settle! (lambda () (client-got-a-byte? lk)) landing-steps)))
   ;; The client reads before the call; once stopped, it is delivered nothing.
   (make-variant
    'uv-read-stop!
    (lambda (lk fill) (uv-read-start! (link-client lk) (client-reader lk) nop nop))
    (lambda (lk fill) (uv-read-stop! (link-client lk)))
    (lambda (lk fill) (not (client-active? lk)))
    (lambda (lk fill)
      (and (peer-sends-a-byte! lk fill)
           (not (settle! (lambda () (client-got-a-byte? lk)) stray-steps)))))
   ;; A split run counts as made only if the verb had returned.
   (make-variant
    'uv-stream-write-queue-size no-prepare
    (lambda (lk fill) (uv-stream-write-queue-size (link-client lk)))
    (lambda (lk fill) 'unobservable)
    (lambda (lk fill) #t))))

;; split-run : variant exact-positive-integer symbol -> verdict
;; MODE is 'free, or 'reuse to open a new connection after the free.
(define (split-run v fuel mode)
  (let* ((before (balance))
         (lk (connect-link!)))
    (if (not lk)
        '(connect-failed)
        (let* ((fill (+ 1 (mod fuel 250)))
               (prepared ((variant-prepare v) lk fill))
               (returned #f)
               (eng (make-engine
                     (lambda ()
                       (guard (e ((uv-handle-closed? e) 'refused)
                                 (#t (list 'raised (describe e))))
                         ((variant-start v) lk fill)
                         (set! returned #t)
                         'returned))))
               (verdict
                (eng fuel
                     (lambda (ticks outcome)
                       (cond ((not (eq? outcome 'returned)) (list 'untouched outcome))
                             ((not ((variant-made? v) lk fill)) '(untouched not-made))
                             ((not ((variant-landed? v) lk fill))
                              (list 'untouched 'never-landed (link-evidence lk)))
                             (else 'untouched)))
                     (lambda (resume)
                       (let* ((made-before (or (eq? #t ((variant-made? v) lk fill))
                                               returned))
                              (landed (and made-before ((variant-landed? v) lk fill))))
                         (uv-close! (link-client lk))
                         (poll! (lambda () (closed-or-absent? (link-client lk))))
                         (let* ((new (and (eq? mode 'reuse) (connect-link!)))
                                (outcome (resume 1000000 (lambda (ticks o) o)
                                                 (lambda (more) 'still-running)))
                                (stray (and new
                                            (settle! (lambda ()
                                                       (positive? (collector-count
                                                                   (link-peer-got new))))
                                                     stray-steps))))
                           (when new (close-link! new))
                           ;; A reuse run without its new connection has
                           ;; nothing to see a misdirected write with.
                           (cond (stray (list 'the-new-connection-got-bytes outcome))
                                 ((and (eq? mode 'reuse) (not new))
                                  (list 'no-new-connection outcome))
                                 ((and (eq? outcome 'refused) (not made-before)) 'refused)
                                 ((and (eq? outcome 'returned) landed) 'made-before-close)
                                 (else (list outcome
                                             (cond ((not made-before) 'not-made-before-close)
                                                   ((not landed)
                                                    (list 'made-but-never-landed
                                                          (link-evidence lk)))
                                                   (else 'made-before-close)))))))))))
          (close-link! lk)
          (let ((left (residue before)))
            (cond ((not (interrupts-enabled?))
                   (enable-interrupts)
                   (list 'interrupts-left-disabled verdict))
                  ((pair? left) (list verdict 'left left))
                  (else verdict)))))))

;; drop-run : variant exact-positive-integer -> verdict
(define (drop-run v fuel)
  (let* ((before (balance))
         (lk (connect-link!)))
    (if (not lk)
        '(connect-failed)
        (let* ((fill (+ 1 (mod fuel 250)))
               (prepared ((variant-prepare v) lk fill))
               (eng (make-engine
                     (lambda ()
                       (guard (e (#t (list 'raised (describe e))))
                         ((variant-start v) lk fill)
                         'returned))))
               (outcome (eng fuel
                             (lambda (ticks o) (if (eq? o 'returned) 'untouched (list 'untouched o)))
                             (lambda (resume) 'dropped))))
          (close-link! lk)
          (let ((left (residue before)))
            (cond ((not (interrupts-enabled?))
                   (enable-interrupts)
                   (list 'interrupts-left-disabled outcome))
                  ((pair? left) (list outcome 'left left))
                  (else outcome)))))))

(define sweep-fuel-cap 400)

(define (untouched? verdict)
  (or (eq? verdict 'untouched) (and (pair? verdict) (eq? (car verdict) 'untouched))))

;; A run whose connection failed: the next would wait the same handshake out
;; again, at every fuel up to the cap.
(define (unconnected? verdict)
  (and (pair? verdict) (memq (car verdict) '(connect-failed no-new-connection)) #t))

;; sweep : (exact-positive-integer -> verdict) -> (list-of (cons fuel verdict))
;; From fuel 1 to the first run no expiry reaches, whatever its verdict, or
;; to the first run whose connection failed, or to the cap. A raise between
;; runs would abort the suite, so the sweep is caught and its evidence handed
;; to the rows.
(define (sweep run)
  (guard (e (#t (list (cons 0 (list 'sweep-raised (describe e))))))
    (let next ((fuel 1) (acc '()))
      (let* ((verdict (run fuel))
             (acc (cons (cons fuel verdict) acc)))
        (if (or (untouched? verdict) (unconnected? verdict) (= fuel sweep-fuel-cap))
            (reverse acc)
            (next (+ fuel 1) acc))))))

(define (named-sweeps run vs)
  (map (lambda (v) (cons (variant-name v) (sweep (lambda (fuel) (run v fuel))))) vs))

(define split-sweeps
  (named-sweeps (lambda (v fuel) (split-run v fuel 'free)) variants))
(define reuse-sweeps
  (named-sweeps (lambda (v fuel) (split-run v fuel 'reuse))
                (filter (lambda (v) (memq (variant-name v) '(uv-write! uv-write*!)))
                        variants)))
(define drop-sweeps (named-sweeps drop-run variants))

;; bad-runs : (verdict -> boolean) sweeps -> (list-of (list name fuel verdict))
(define (bad-runs good? sweeps)
  (apply append
         (map (lambda (s)
                (map (lambda (run) (list (car s) (car run) (cdr run)))
                     (filter (lambda (run) (not (good? (cdr run)))) (cdr s))))
              sweeps)))

;; reach : sweeps symbol -> (list-of (list name first last))
;; The rows below look for bad runs and must find none, which says nothing
;; unless each sweep caught its verb before the step (FIRST) and ran it to
;; the end (the last run untouched).
(define (reach sweeps)
  (map (lambda (s)
         (let ((runs (cdr s)))
           (list (car s) (cdar runs) (cdr (list-ref runs (- (length runs) 1))))))
       sweeps))

(define (expected-reach sweeps first)
  (map (lambda (s) (list (car s) first 'untouched)) sweeps))

;; fuel-map : sweep -> list, e.g. ((refused 1 9) (untouched 10 10)): each
;; run of equal verdicts with its first and last fuel, for the record.
(define (fuel-map runs)
  (let collect ((runs runs) (acc '()))
    (cond ((null? runs) (reverse acc))
          ((and (pair? acc) (equal? (caar acc) (cdar runs)))
           (collect (cdr runs)
                    (cons (list (caar acc) (cadar acc) (caar runs)) (cdr acc))))
          (else (collect (cdr runs)
                         (cons (list (cdar runs) (caar runs) (caar runs)) acc))))))

(for-each
 (lambda (kind sweeps)
   (for-each (lambda (s)
               (display "  [informational] ") (display kind) (display " ")
               (display (car s)) (display ": ")
               (write (fuel-map (cdr s))) (newline))
             sweeps))
 '(split reuse drop)
 (list split-sweeps reuse-sweeps drop-sweeps))

(test-equal "a stream verb split by a close is refused, or had made its call before the close"
  '()
  (bad-runs (lambda (v) (memq v '(refused made-before-close untouched))) split-sweeps))

(test-equal "each split sweep caught its verb before the close and ran it to the end"
  (expected-reach split-sweeps 'refused)
  (reach split-sweeps))

(test-equal "a write split by a close never reaches a new connection given the stream's address"
  '()
  (bad-runs (lambda (v) (memq v '(refused made-before-close untouched))) reuse-sweeps))

(test-equal "each reuse sweep caught its write before the close and ran it to the end"
  (expected-reach reuse-sweeps 'refused)
  (reach reuse-sweeps))

(test-equal "a stream verb whose engine is dropped leaves no request, block or registry entry"
  '()
  (bad-runs (lambda (v) (memq v '(dropped untouched))) drop-sweeps))

(test-equal "each drop sweep dropped its verb and ran it to the end"
  (expected-reach drop-sweeps 'dropped)
  (reach drop-sweeps))

(uv-close! sw-server)
(uv-loop-teardown! sw-loop)

(uv-loop-teardown! loop)
(collect)
(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))

;; --- a stream left open with no native block --------------------------------
;; No path in the library leaves a stream open with its pointer zeroed, but
;; a step must not fault if one ever does: the fault would be raised with
;; interrupts disabled. Each step checks the pointer and answers a status,
;; and the refusal is the one handle-pointer raises outside a step. The
;; private setter forces the state. This row comes last, because a fault here
;; would leave interrupts disabled for any row after it.
(test-equal "a stream verb on a stream left open with no native block is refused, not made"
  '((uv-write! null-handle-pointer) (uv-write*! null-handle-pointer)
    (uv-shutdown! null-handle-pointer) (uv-read-start! null-handle-pointer)
    (uv-read-stop! null-handle-pointer)
    (uv-stream-write-queue-size null-handle-pointer)
    interrupts-enabled)
  (let* ((l (make-uv-loop))
         (t (make-uv-tcp l)))
    (uv-close! t)
    (uv-run l 'nowait)            ; the close callback frees the block, zeroes the pointer
    (set-handle-state! t 'open)
    (let ((refusals
           (map (lambda (call)
                  (guard (e ((uv-invalid-argument? e)
                             (list (uv-invalid-argument-who e)
                                   (uv-invalid-argument-reason e)))
                            (#t (list 'raised (describe e))))
                    (call)
                    'made))
                (list (lambda () (uv-write! t (make-bytevector 1 7) nop))
                      (lambda () (uv-write*! t (list (make-bytevector 1 7)) nop))
                      (lambda () (uv-shutdown! t nop))
                      (lambda () (uv-read-start! t nop nop nop))
                      (lambda () (uv-read-stop! t))
                      (lambda () (uv-stream-write-queue-size t))))))
      (set-handle-state! t 'closed)
      (uv-loop-teardown! l)
      (append refusals
              (list (if (interrupts-enabled?)
                        'interrupts-enabled
                        'interrupts-left-disabled))))))

(test-end "stream")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
