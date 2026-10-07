#!r6rs
;;; SRFI-64 suite for v0.5's flow-control surfaces. Task 1 writes the
;;; cross-stream isolation section; Tasks 2 and 3 append.
;;;
;;; NOT pure: reaches (libuv private native). Never add to PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv stream)
        (libuv tcp)
        (libuv timer)
        (libuv pipe)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (uv-evidence) describe)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. A row that catches a
;; raise answers the condition as its actual value, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "flow")

;; --- cross-stream isolation ----------------------------------------------
;; FOUR readers, not two: with two, "the survivor still reads" and "the
;; survivor got ITS OWN bytes" are the same assertion.
(define reader-count 4)
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(define port (bind-loopback! server))

(define accepted '())
(define collectors '())
(define clients '())

(uv-listen! server 16
  (lambda (err)
    (when (not err)
      (let ((peer (uv-accept! server))      ; ONE argument; returns the peer
            (col  (make-byte-collector)))
        (set! accepted (cons peer accepted))
        (set! collectors (cons col collectors))
        (uv-read-start! peer
                        (lambda (bv s e) (collect-span! col bv s e) (collect))
                        (lambda () #f)
                        (lambda (c) #f))))))

(let build ((i 0))
  (when (< i reader-count)
    (let ((c (make-uv-tcp loop)))
      (set! clients (cons c clients))
      (connect-loopback! c port (lambda (err) #f))
      (build (+ i 1)))))

(test-equal "seed: every client connected and was accepted"
  'satisfied
  (run-until/ticking loop (lambda () (= (length accepted) reader-count)) 4000))

(define peers (list->vector (reverse accepted)))
(define cols  (list->vector (reverse collectors)))
(define cli   (list->vector (reverse clients)))

;; Distinct payloads per survivor. A SHARED sentinel is the trap
;; test-echo.sps:163-172 names by title.
(define (payload-for i) (seeded-bytes 256 (+ 7000 (* i 131))))

(test-equal "seed: the survivors' payloads are pairwise distinct"
  '(distinct distinct distinct)
  (list (if (equal? (payload-for 1) (payload-for 2)) 'same 'distinct)
        (if (equal? (payload-for 1) (payload-for 3)) 'same 'distinct)
        (if (equal? (payload-for 2) (payload-for 3)) 'same 'distinct)))

;; Reader 0, the one that closes itself, and its collector. Until the seed
;; above accepts it, the reader is a placeholder and its collector stays
;; empty, and each use of the reader outside a row is gated on it: a failed
;; seed then fails the rows below by name instead of aborting the suite
;; between them (AGENTS.md).
(define closing-peer
  (if (positive? (vector-length peers)) (vector-ref peers 0) 'not-accepted))
(define closing-col
  (if (positive? (vector-length cols)) (vector-ref cols 0) (make-byte-collector)))

;; Close reader 0 from inside its own read callback. The replacement callback
;; STILL COLLECTS: without that, its collector is frozen at 0 on both sides of
;; the comparison below and no src/ mutation could move it.
(define closed-fired 'not-yet)
(when (uv-tcp? closing-peer)
  (uv-read-stop! closing-peer)
  (uv-read-start! closing-peer
                  (lambda (bv s e)
                    (collect-span! closing-col bv s e)
                    (when (uv-handle-open? closing-peer)
                      (uv-close! closing-peer
                                 (lambda () (set! closed-fired 'fired)))))
                  (lambda () #f)
                  (lambda (c) #f)))
(uv-write! (vector-ref cli 0) (seeded-bytes 32 1) (lambda (err) #f))

;; THE GATE. close-dispatch frees on a LATER loop iteration than the
;; uv-close! call (handles.sls:984-996), so a post-close write issued at
;; close-ISSUE time can complete before the window under test opens.
(test-equal "gate: the closed reader reached 'closed before survivors are written to"
  '(satisfied fired closed)
  (let ((r (run-until/ticking loop
                              (lambda () (eq? 'closed (uv-handle-state closing-peer)))
                              4000)))
    (list r closed-fired (uv-handle-state closing-peer))))

(define closed-deliveries-at-gate (collector-count closing-col))

(test-assert "seed: the closing reader received the trigger write before closing"
  (positive? closed-deliveries-at-gate))

(let write-survivors ((i 1))
  (when (< i reader-count)
    (uv-write! (vector-ref cli i) (payload-for i) (lambda (err) #f))
    (write-survivors (+ i 1))))

(test-equal "every survivor received its full payload"
  'satisfied
  (run-until/ticking loop
                     (lambda ()
                       (let check ((i 1))
                         (cond ((>= i reader-count) #t)
                               ((< (collector-count (vector-ref cols i))
                                   (bytevector-length (payload-for i))) #f)
                               (else (check (+ i 1))))))
                     8000))

;; compare-bytes answers 'identical, (wrong-length n), or
;; (differs-at i expected actual) -- never #f, which SRFI-64 also produces
;; for a raise.
;; Accept order is NOT contractually uv-tcp-connect! call order, so peers[i]
;; is not guaranteed to be cli[i]'s connection. Asserting an index-keyed
;; correspondence would risk a spurious failure unrelated to any regression.
;; The property under test does not need that mapping: each survivor must
;; have received ONE COMPLETE, UNCORRUPTED payload, and all three distinct
;; payloads must have arrived EXACTLY ONCE across the three survivors. That
;; is strictly stronger against cross-wiring -- two survivors handed the same
;; bytes fails here, where three index-keyed rows could each still pass under
;; some permutations.
;;
;; 0 marks "matched no payload at all", which is what a corrupting mutation
;; produces; it cannot be confused with a success value, since the expected
;; list contains only 1, 2 and 3.
(define (which-payload bv)
  (let scan ((i 1))
    (cond ((> i 3) 0)
          ((eq? 'identical (compare-bytes (payload-for i) bv)) i)
          (else (scan (+ i 1))))))

(test-equal "each survivor received exactly one complete, uncorrupted payload"
  '(1 2 3)
  (list-sort < (map (lambda (i) (which-payload (collector-bytes (vector-ref cols i))))
                    '(1 2 3))))

(test-equal "the closed reader received nothing further"
  closed-deliveries-at-gate (collector-count closing-col))

;; --- OS socket buffer sizes ------------------------------------------------
(define bloop (make-uv-loop))
(define btcp (make-uv-tcp bloop))

;; A bind is enough; no connection is needed. A bind that raises fails this
;; row by name, where at top level it would end the suite
;; (tests/test-seed-gates.sps, rule 4). An unbound handle has no socket, so
;; the sizes below are set and read only after a bind.
(define b-bind
  (guard (e (#t (list 'raised (describe e))))
    (uv-tcp-bind! btcp "127.0.0.1" 0)
    'bound))

(test-equal "the buffer-size handle binds 127.0.0.1, port 0" 'bound b-bind)

;; set-then-read : (uv-tcp -> unspecified) (uv-tcp -> object) -> object
;; WRITE then READ on btcp once it is bound, else the bind's outcome.
(define (set-then-read write read)
  (if (eq? b-bind 'bound) (begin (write btcp) (read btcp)) b-bind))

;; TWO-POINT: set low, read; set high, read; assert the readings track the
;; direction. Not (< after default): Linux stores max(2n, SOCK_MIN_SNDBUF),
;; so 8192 lands exactly on tcp_wmem[1] and "below default" is false there.
(define send-low
  (set-then-read (lambda (h) (uv-send-buffer-size! h 8192)) uv-send-buffer-size))
(define send-high
  (set-then-read (lambda (h) (uv-send-buffer-size! h 262144)) uv-send-buffer-size))

(test-equal "the send buffer tracks the value set, at two points"
  '(positive tracks-upward)
  (list (if (and (integer? send-low) (exact? send-low) (positive? send-low))
            'positive 'not-positive)
        (if (> send-high send-low) 'tracks-upward 'did-not-track)))

;; Different from the send section's 8192/262144 on purpose: if the recv
;; setter is ever cross-wired to write SO_SNDBUF, last-write-wins semantics
;; mean identical constants would silently land back on send-high and
;; send-unmoved would pass anyway, giving that assertion no probe at all.
(define recv-low
  (set-then-read (lambda (h) (uv-recv-buffer-size! h 16384)) uv-recv-buffer-size))
(define recv-high
  (set-then-read (lambda (h) (uv-recv-buffer-size! h 131072)) uv-recv-buffer-size))

(test-equal "the receive buffer tracks independently of the send buffer"
  '(tracks-upward send-unmoved)
  (list (if (> recv-high recv-low) 'tracks-upward 'did-not-track)
        (if (= send-high (uv-send-buffer-size btcp)) 'send-unmoved 'send-moved)))

;; Validation BEFORE allocation, one row per setter.
(test-equal "the send setter refuses a non-positive size"
  '(uv-send-buffer-size! buffer-size-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (list 'wrong-condition e)))
    (uv-send-buffer-size! btcp 0)
    'no-raise))

(test-equal "the receive setter refuses a size that does not fit an int"
  '(uv-recv-buffer-size! buffer-size-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (list 'wrong-condition e)))
    (uv-recv-buffer-size! btcp 2147483648)
    'no-raise))

;; The kind gate, failing closed.
(test-equal "a timer is refused as a socket handle"
  'not-a-socket-handle
  (let ((t (make-uv-timer bloop)))
    (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
              (#t (list 'wrong-condition e)))
      (uv-send-buffer-size t)
      'no-raise)))

;; NATIVE FAILURE, one row per wrapper. An unconnected pipe passes the kind
;; allowlist but has no fd, so uv_send_buffer_size reaches getsockopt(-1) and
;; answers EBADF -- AFTER the int cell is allocated. These four rows are what
;; give the Valgrind lane a failure path to walk; without them §8's
;; free-on-every-path claim is untested.
(define bpipe (make-uv-pipe bloop))

(test-equal "the send getter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-send-buffer-size bpipe) 'no-raise))

(test-equal "the send setter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-send-buffer-size! bpipe 8192) 'no-raise))

(test-equal "the receive getter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-recv-buffer-size bpipe) 'no-raise))

(test-equal "the receive setter surfaces the native failure on a pipe with no fd"
  'EBADF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-recv-buffer-size! bpipe 8192) 'no-raise))

;; THE CLOSING GATE, one row per wrapper. 'closing, not 'closed: on a closing
;; handle the pointer is still live, so a missing gate silently SUCCEEDS.
(define bclosing (make-uv-tcp bloop))

(test-equal "the closing-gate handle binds 127.0.0.1, port 0"
  'bound
  (guard (e (#t (list 'raised (describe e))))
    (uv-tcp-bind! bclosing "127.0.0.1" 0)
    'bound))

(uv-close! bclosing)                       ; not run: state is 'closing

(test-equal "all four refuse a closing handle with &uv-handle-closed"
  '(closed closed closed closed)
  (map (lambda (thunk)
         (guard (e ((uv-handle-closed? e) 'closed)
                   (#t (list 'wrong-condition e)))
           (thunk) 'no-raise))
       (list (lambda () (uv-send-buffer-size bclosing))
             (lambda () (uv-send-buffer-size! bclosing 8192))
             (lambda () (uv-recv-buffer-size bclosing))
             (lambda () (uv-recv-buffer-size! bclosing 8192)))))

(uv-loop-teardown! bloop)
(uv-loop-close! bloop)

;; --- write-queue congestion ------------------------------------------------
;; A gauge test that only ever sees 0 passes against a stub, a misbound
;; pointer, and a size_t marshalling bug -- and 0 is truthy. So: observe a
;; POSITIVE value, then observe it FALL. Two assertions, two mutations.
(define cloop (make-uv-loop))
(define cserver (make-uv-tcp cloop))
(define cport (bind-loopback! cserver))
(define cpeer 'not-accepted)
(define cclient (make-uv-tcp cloop))

(uv-listen! cserver 4
  (lambda (err)
    (when (and (not err) (eq? cpeer 'not-accepted))
      (set! cpeer (uv-accept! cserver)))))   ; deliberately NOT reading

;; The idle stream gets its OWN listener: sharing cserver would race for which
;; connection becomes cpeer.
(define cidle-server (make-uv-tcp cloop))
(define cidle-port (bind-loopback! cidle-server))
(define cidle-peer 'not-accepted)
(uv-listen! cidle-server 1
  (lambda (err)
    (when (and (not err) (eq? cidle-peer 'not-accepted))
      (set! cidle-peer (uv-accept! cidle-server)))))
(define cidle (make-uv-tcp cloop))

(connect-loopback! cclient cport (lambda (err) #f))
(connect-loopback! cidle cidle-port (lambda (err) #f))

(test-equal "seed: both congestion pairs connected"
  'satisfied
  (run-until/ticking cloop
                     (lambda () (and (not (eq? cpeer 'not-accepted))
                                     (not (eq? cidle-peer 'not-accepted))))
                     4000))

;; Shrink BOTH: shrinking only the writer's does not bound loopback
;; buffering, because the peer's receive buffer absorbs independently. The
;; peer's is gated on the seed, as its read start below is: without a peer,
;; the rows fail by name instead of these lines aborting the suite.
(uv-send-buffer-size! cclient 4096)
(when (uv-tcp? cpeer) (uv-recv-buffer-size! cpeer 4096))

(define chunk (seeded-bytes 65536 4242))
(define submissions 0)
(define completions 0)

(define congested
  (let push ((i 0))
    (cond ((>= i 64) 'gauge-never-went-positive)
          (else
           (uv-write! cclient chunk (lambda (err) (set! completions (+ completions 1))))
           (set! submissions (+ submissions 1))
           ;; Sampled synchronously after uv-write! returns and BEFORE any
           ;; uv-run: stream.sls:100-104 submits inline, so this is the
           ;; moment the queue is deepest.
           (let ((q (uv-stream-write-queue-size cclient)))
             (if (positive? q) q (begin (uv-run cloop 'nowait) (push (+ i 1)))))))))

(test-equal "the write queue goes positive against an unreading peer"
  'positive
  (if (and (integer? congested) (positive? congested)) 'positive congested))

;; THE per-stream discriminator: the only row separating a real per-stream
;; read from a per-loop total or a misbound pointer.
(test-equal "an idle stream on the same loop reads zero while the other is congested"
  '(congested-positive idle-zero)
  (list (if (positive? (uv-stream-write-queue-size cclient)) 'congested-positive 'congested-zero)
        (if (zero? (uv-stream-write-queue-size cidle)) 'idle-zero 'idle-nonzero)))

;; Drain, requiring BOTH halves. Without the completions half, a gauge
;; stubbed to 0 passes this row trivially.
(when (uv-tcp? cpeer)
  (uv-read-start! cpeer (lambda (bv s e) (collect)) (lambda () #f) (lambda (c) #f)))

(test-equal "the queue falls to zero AND every write completed once the peer reads"
  '(satisfied all-completed)
  (let ((r (run-until/ticking cloop
                              (lambda () (and (zero? (uv-stream-write-queue-size cclient))
                                              (= completions submissions)))
                              20000)))
    (list r (if (= completions submissions) 'all-completed
                (list 'short completions submissions)))))

;; The gate, on a CLOSING stream.
(test-equal "a closing stream refuses the gauge with &uv-handle-closed"
  'closed
  (let ((doomed (make-uv-tcp cloop)))
    (uv-tcp-bind! doomed "127.0.0.1" 0)
    (uv-close! doomed)
    (guard (e ((uv-handle-closed? e) 'closed)
              (#t (list 'wrong-condition e)))
      (uv-stream-write-queue-size doomed)
      'no-raise)))

(uv-loop-teardown! cloop)
(uv-loop-close! cloop)

(uv-loop-teardown! loop)
(uv-loop-close! loop)

(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))

(test-end "flow")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
