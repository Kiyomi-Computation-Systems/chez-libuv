#!r6rs
;;; THE CAPSTONE (design spec S11, S12 stage 6): an echo SERVER and eight
;;; concurrent in-process clients, on one loop, built from the PUBLIC API and
;;; nothing else.
;;;
;;; WHAT THIS SUITE IS FOR, and why it is not just another TCP test. Every
;;; other suite reaches into whichever library owns the thing it is checking
;;; -- (libuv tcp) for the verbs, (libuv private handles) for the registry,
;;; (libuv private native) for the counters -- because that is what a unit
;;; test of a binding has to do. This one is the opposite experiment: it
;;; writes a whole working program the way a CONSUMER would have to, out of
;;; `(import (libuv))`, and its import list is therefore part of the test. If
;;; the echo server below cannot be written without reaching past the facade,
;;; the facade is incomplete, and the failure shows up here as an unbound
;;; identifier at expand time rather than as an opinion in a review.
;;;
;;; THE ONE NAME THAT IS NOT FROM THE FACADE, and why it is not a hole in
;;; that claim: `live-counts` is (libuv private native)'s debug-counter query,
;;; renamed on the way in so it cannot stand in for a facade export that went
;;; missing. This is tests/test-facade.sps's `libuv-packed-version` precedent,
;;; for the same reason -- the counters are a DEV-BUILD-ONLY observability
;;; facility (design spec S10; a prod shim's queries answer a constant 0, see
;;; tests/check-prod.sps), so making them public would put a procedure in the
;;; API that silently lies in release builds. No name the echo server itself
;;; uses comes from anywhere but (libuv).
;;;
;;; So that the memory claim below does not rest on that private import
;;; alone, every counter row has a PUBLIC counterpart asserted beside it:
;;; uv-loop-live-handles is the facade's own answer to "what is still live on
;;; this loop", and it is asserted at the same two points -- the seventeen-
;;; handle peak and the empty end.
;;;
;;; THE SHAPE OF THE EXCHANGE (design spec S12):
;;;   * one server, bound to 127.0.0.1:0 (ADR-0010: never a fixed port, never
;;;     an external peer, never a subprocess), accepting into per-connection
;;;     closures; each peer echoes the EXACT span it was handed and shuts down
;;;     and closes when it sees EOF;
;;;   * eight clients on the SAME loop, each writing a DISTINCT 32 KiB
;;;     seeded-deterministic payload in three uneven chunks, accumulating what
;;;     comes back, and shutting itself down once it has all 32 KiB;
;;;   * one designated pair applies BACKPRESSURE in the middle of all that:
;;;     client 0 stops its own read from inside a delivery, and the restart is
;;;     issued from inside a DIFFERENT client's delivery -- uv-read-start!
;;;     called from within a callback, which is the one shape Stage 5 left
;;;     untested;
;;;   * teardown: seventeen handles closed, the loop drained, every counter
;;;     back to zero.
;;;
;;; NOTHING HERE ASSERTS ELAPSED TIME, and nothing here asserts how libuv
;;; FRAGMENTED the stream: how many on-data deliveries a 32 KiB transfer takes
;;; is kernel policy, so the delivery counts are printed as informational
;;; lines and never asserted. What is asserted is what the API promises: the
;;; bytes, in order, byte for byte.
;;;
;;; NOT pure: (libuv) reaches (libuv private native). Never add this to the
;;; Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv)
        ;; Test plumbing only -- the loopback address dance (ADR-0010), the
        ;; seeded payload generator, the span collector, and the iteration-
        ;; capped drain. Every libuv name it uses is a public one; it supplies
        ;; nothing the echo server itself calls.
        (uv-testing)
        ;; See the header: renamed so it cannot substitute for a facade export.
        (rename (only (libuv private native) live-counts)
                (live-counts debug-live-counts))
        ;; design spec S11's GC-pressure rule: every callback collects.
        (only (chezscheme) collect))

;; SRFI-64's default runner sets no process exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

(define (live-count kind) (cdr (assq kind (debug-live-counts))))

;; A callback's `err` argument is #f on success, and #f is the value AGENTS.md
;; names as the worst possible expected value: it is what a missing key, a
;; defaulting accessor and an SRFI-64-swallowed exception all produce. Every
;; assertion below compares a SYMBOL, and this is the one place the mapping
;; happens.
(define (err->symbol err)
  (cond ((not err) 'no-error)
        ;; The portable SYMBOL from uv_err_name_r (ADR-0006), not the raw
        ;; platform int uv-errno-error-code carries.
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else (list 'unexpected-err-object err))))

;; --- the shape of the exchange ------------------------------------------
(define client-count 8)
(define payload-size 32768)

;; Uneven ON PURPOSE. Three equal chunks would let an off-by-one in a span
;; land on a boundary that a wrongly-framed echo could still reproduce; these
;; three sizes share no factor with the buffer size or with each other.
(define chunk-spans '((0 . 13000) (13000 . 26000) (26000 . 32768)))

;; Iteration caps, not timeouts (design spec S11). Generous enough that a slow
;; machine never reaches them, small enough that a genuinely stuck exchange is
;; a NAMED failure -- 'iterations-exhausted -- rather than a hung suite.
(define cap 4096)
(define drain-cap 512)

;; --- what each side remembers -------------------------------------------
;; Per-connection state, because that is what the API's callback shapes
;; require: on-data is handed (bv start end) and no handle, so a server that
;; serves more than one connection has to close over the connection it is
;; serving. That is not a limitation being worked around here -- it is the
;; design being exercised (see (libuv tcp)'s note on uv-listen!).
(define-record-type (client %make-client client?)
  (fields index tcp payload collector
          (mutable connected client-connected set-client-connected!)
          (mutable deliveries client-deliveries set-client-deliveries!)
          (mutable writes-done client-writes-done set-client-writes-done!)
          (mutable write-error client-write-error set-client-write-error!)
          (mutable read-error client-read-error set-client-read-error!)
          (mutable eofs client-eofs set-client-eofs!)
          (mutable finishing client-finishing set-client-finishing!)
          (mutable on-data client-on-data set-client-on-data!)
          (mutable on-eof client-on-eof set-client-on-eof!)
          (mutable on-error client-on-error set-client-on-error!))
  (protocol
   (lambda (new)
     (lambda (index tcp payload)
       (new index tcp payload (make-byte-collector)
            'connect-callback-never-fired 0 0
            'no-write-error 'on-error-never-fired 0 #f #f #f #f)))))

(define-record-type (peer %make-peer peer?)
  (fields tcp
          (mutable deliveries peer-deliveries set-peer-deliveries!)
          (mutable echoed peer-echoed set-peer-echoed!)
          (mutable write-error peer-write-error set-peer-write-error!)
          (mutable read-error peer-read-error set-peer-read-error!)
          (mutable eofs peer-eofs set-peer-eofs!)
          (mutable shutdown-error peer-shutdown-error set-peer-shutdown-error!))
  (protocol
   (lambda (new)
     (lambda (tcp)
       (new tcp 0 0 'no-write-error 'on-error-never-fired 0 'no-shutdown-error)))))

;; --- payloads ------------------------------------------------------------
;; Seeded by CLIENT INDEX and by nothing else: no clock, no `random`. Two runs
;; of this suite compare the same bytes, so "byte 20481 differs" means the same
;; thing tomorrow (uv-testing's note on seeded-bytes).
(define payloads
  (let build ((i 0) (acc '()))
    (if (= i client-count)
        (list->vector (reverse acc))
        (build (+ i 1) (cons (seeded-bytes payload-size i) acc)))))

;; Every pair, compared. THIS ROW IS WHAT MAKES THE EIGHT EQUALITY ROWS MEAN
;; ANYTHING: if two clients shared a payload, a server that crossed their
;; streams would still hand each of them 32 KiB that compares equal to what it
;; sent, and eight green rows would be reporting a cross-wired echo as correct.
(define (payload-distinctness)
  (let outer ((i 0))
    (if (= i client-count)
        'all-distinct
        (let inner ((j (+ i 1)))
          (cond ((= j client-count) (outer (+ i 1)))
                ((bytevector=? (vector-ref payloads i) (vector-ref payloads j))
                 (list 'duplicate-payloads i j))
                (else (inner (+ j 1))))))))

;; 'identical, or the FIRST index that differs and both bytes there. A bare
;; test-equal on two 32 KiB bytevectors reports a failure by printing both of
;; them; this reports the one number that says what went wrong.
(define (compare-bytes expected actual)
  (cond ((not (= (bytevector-length expected) (bytevector-length actual)))
         (list 'wrong-length (bytevector-length actual)))
        (else
         (let scan ((i 0))
           (cond ((= i (bytevector-length expected)) 'identical)
                 ((= (bytevector-u8-ref expected i) (bytevector-u8-ref actual i))
                  (scan (+ i 1)))
                 (else (list 'differs-at i
                             (bytevector-u8-ref expected i)
                             (bytevector-u8-ref actual i))))))))

(test-begin "echo")

;; --- seeds ---------------------------------------------------------------
;; Every counter row below needs the DEV shim (the Makefile's CFLAGS_DEV,
;; -DCHEZ_LIBUV_DEBUG_COUNTERS); against a production shim the live queries
;; answer a constant 0 and the "moved" rows would fail pointing at a leak that
;; is not there. Name that precondition first, before anything is allocated.
(test-equal "seed: no tcp handle is live before this suite creates one"
  0 (live-count 'tcp))

(test-equal "seed: no read buffer is live before this suite creates one"
  0 (live-count 'read-buffer))

(test-equal "seed: the eight client payloads are pairwise distinct"
  'all-distinct (payload-distinctness))

;; --- the server ----------------------------------------------------------
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(define port (bind-loopback! server))

(define peers '())                     ; newest first
(define listen-error 'listen-callback-never-fired)
(define accept-error 'no-accept-error)

;; Bytes whose echo write has COMPLETED, across every peer. Completion, not
;; issue: the backpressure row below turns on this number meaning "the kernel
;; has it", and a write that libuv has merely queued has not reached the
;; client's receive buffer yet.
(define server-echoed 0)

;; The whole server, per connection. Each of the three callbacks closes over
;; its own peer record -- the only way to serve more than one connection,
;; since on-data is handed a span and no handle.
(define (serve! p)
  (let ((tcp (peer-tcp p)))
    (uv-read-start!
     tcp
     ;; on-data: echo the EXACT span back. Not (bv 0 (bytevector-length bv)),
     ;; and not a re-framed copy: whatever span the read path delivered is
     ;; what goes back on the wire, which is the property the eight
     ;; byte-for-byte rows at the end are measuring.
     (lambda (bv start end)
       (collect)
       (set-peer-deliveries! p (+ 1 (peer-deliveries p)))
       (uv-write! tcp bv start end
                  (lambda (err)
                    (collect)
                    (if err
                        (set-peer-write-error! p (err->symbol err))
                        (let ((n (- end start)))
                          (set-peer-echoed! p (+ n (peer-echoed p)))
                          (set! server-echoed (+ n server-echoed)))))))
     ;; on-eof: the client has shut its write side. Flush ours with a
     ;; shutdown, then close from inside the shutdown's own callback -- the
     ;; close is what frees the handle, and doing it before the shutdown
     ;; completes would abandon bytes libuv has not handed the kernel yet.
     (lambda ()
       (collect)
       (set-peer-eofs! p (+ 1 (peer-eofs p)))
       (uv-shutdown! tcp
                     (lambda (err)
                       (collect)
                       (when err (set-peer-shutdown-error! p (err->symbol err)))
                       (uv-close! tcp))))
     ;; on-error: a read error does NOT close the handle by itself (design
     ;; spec S6) -- that decision is the caller's, and this caller makes it
     ;; here.
     (lambda (err)
       (collect)
       (set-peer-read-error! p (err->symbol err))
       (uv-close! tcp)))))

(uv-listen! server 128
            (lambda (err)
              (collect)
              (set! listen-error (err->symbol err))
              (when (not err)
                ;; uv-accept! can fail (EAGAIN if the queue emptied under us),
                ;; and a raise here would cross the callback boundary, so it is
                ;; caught and recorded like every other error in this suite.
                (guard (e (#t (set! accept-error (err->symbol e))))
                  (let ((p (%make-peer (uv-accept! server))))
                    (set! peers (cons p peers))
                    (serve! p))))))

;; --- the clients ---------------------------------------------------------
(define (start-client-read! c)
  ;; The buffer-size argument is OMITTED, deliberately: an omitted size asks
  ;; for nothing, which is what makes the restart below legal against the
  ;; buffer this first call fixed (design spec S6).
  (uv-read-start! (client-tcp c)
                  (client-on-data c) (client-on-eof c) (client-on-error c)))

(define (client-total c) (collector-count (client-collector c)))

;; Shut down and close, once, from inside the delivery that completed the
;; transfer. Idempotent by an explicit flag rather than by luck: on-data can
;; fire again between the shutdown and the close.
(define (finish-client! c)
  (unless (client-finishing c)
    (set-client-finishing! c #t)
    (uv-shutdown! (client-tcp c)
                  (lambda (err)
                    (collect)
                    (when err (set-client-write-error! c (err->symbol err)))
                    (uv-close! (client-tcp c))))))

;; --- the backpressure smoke, folded into the real traffic ----------------
;; Client 0 stops its own read from inside its first delivery. Client 1 --
;; whose payload is deliberately not written until the stop has been observed
;; -- issues the RESTART from inside ITS first delivery, so uv-read-start! is
;; exercised from within a callback against a handle that is not the one being
;; delivered to. Stage 5 tested the stop from inside a callback and the restart
;; only from the suite's own top level; this closes that gap.
(define stopper-index 0)
(define restarter-index 1)
(define bp-stopped-at 'never-stopped)   ; client 0's byte count when it stopped
(define bp-restarted-at 'never-restarted) ; ... and when the restart ran
(define bp-echoed-at-restart 'never-restarted)

(define clients (make-vector client-count #f))
(define (client-at i) (vector-ref clients i))

(define (backpressure-hook c)
  (cond ((and (= (client-index c) stopper-index)
              (eq? bp-stopped-at 'never-stopped))
         (uv-read-stop! (client-tcp c))
         (set! bp-stopped-at (client-total c)))
        ((and (= (client-index c) restarter-index)
              (not (eq? bp-stopped-at 'never-stopped))
              (eq? bp-restarted-at 'never-restarted))
         ;; Both numbers are READ before the restart -- they describe the
         ;; instant at which the stopped client's read was still stopped --
         ;; but they are only RECORDED once uv-read-start! has returned
         ;; normally, so a restart that RAISED (against a handle that closed
         ;; under it, say) leaves the 'never-restarted sentinel in place
         ;; rather than reporting a restart that did not take.
         (let ((stopper (client-at stopper-index))
               (at (client-total (client-at stopper-index)))
               (echoed server-echoed))
           ;; If the "stopped" client has already finished and closed itself,
           ;; its read never actually stopped -- restarting there would raise
           ;; &uv-handle-closed out of this callback and kill the suite with a
           ;; condition instead of a named row. Record a sentinel no correct
           ;; run can produce and let the rows below say so.
           (cond ((uv-handle-open? (client-tcp stopper))
                  (start-client-read! stopper)
                  (set! bp-restarted-at at)
                  (set! bp-echoed-at-restart echoed))
                 (else
                  (set! bp-restarted-at 'stopper-already-finished)
                  (set! bp-echoed-at-restart 'stopper-already-finished)))))
        (else #f)))

(define (make-client! i)
  (let* ((tcp (make-uv-tcp loop))
         (c (%make-client i tcp (vector-ref payloads i))))
    (set-client-on-data!
     c (lambda (bv start end)
         (collect)
         (set-client-deliveries! c (+ 1 (client-deliveries c)))
         (collect-span! (client-collector c) bv start end)
         (backpressure-hook c)
         (when (>= (client-total c) payload-size) (finish-client! c))))
    (set-client-on-eof! c (lambda () (collect) (set-client-eofs! c (+ 1 (client-eofs c)))))
    (set-client-on-error!
     c (lambda (err) (collect) (set-client-read-error! c (err->symbol err))))
    (connect-loopback! tcp port
                       (lambda (err)
                         (collect)
                         (set-client-connected! c (err->symbol err))
                         (when (not err) (start-client-read! c))))
    (vector-set! clients i c)
    c))

(let create ((i 0))
  (when (< i client-count)
    (make-client! i)
    (create (+ i 1))))

(define (write-chunk! c n)
  (let ((span (list-ref chunk-spans n)))
    (uv-write! (client-tcp c) (client-payload c) (car span) (cdr span)
               (lambda (err)
                 (collect)
                 (if err
                     (set-client-write-error! c (err->symbol err))
                     (set-client-writes-done! c (+ 1 (client-writes-done c))))))))

(define (write-all-chunks! c)
  (write-chunk! c 0) (write-chunk! c 1) (write-chunk! c 2))

(define (all-clients pred)
  (let scan ((i 0))
    (cond ((= i client-count) 'all)
          ((pred (client-at i)) (scan (+ i 1)))
          (else (list 'client i 'failed)))))

;; --- the connection phase ------------------------------------------------
(define connect-outcome
  (run-until/ticking loop
                     (lambda ()
                       (and (= client-count (length peers))
                            (eq? 'all (all-clients
                                       (lambda (c) (eq? 'no-error (client-connected c)))))))
                     cap))

(test-equal "all eight clients connected and the server accepted all eight"
  '(satisfied all no-error no-accept-error 8)
  (list connect-outcome
        (all-clients (lambda (c) (eq? 'no-error (client-connected c))))
        listen-error accept-error (length peers)))

;; THE PEAK, and it is deterministic at exactly this point: every connect
;; callback has fired (so every connect REQUEST has completed and deregistered
;; itself) and nothing has been closed yet. 8 clients + 8 accepted peers + 1
;; listener = 17.
(test-equal "seventeen tcp handles are live at the peak of the exchange"
  17 (live-count 'tcp))

;; The same claim, from the PUBLIC API, so it survives the private import
;; above being removed. uv-loop-live-handles answers the registry snapshot for
;; this loop, which at this instant holds those seventeen handles and no
;; in-flight request.
(test-equal "the facade's own live-handle snapshot agrees: seventeen"
  17 (length (uv-loop-live-handles loop)))

;; Sixteen, not seventeen: the listener never reads, so it never allocated the
;; per-handle read buffer of design spec S6.
(test-equal "sixteen read buffers are live at the peak -- one per reading handle"
  16 (live-count 'read-buffer))

;; --- the transfer, with one reader deliberately stopped ------------------
;; Client 0 writes only its FIRST chunk, so that its first delivery cannot be
;; the whole payload -- a client that had already received all 32 KiB before
;; stopping would make the backpressure rows vacuous. Client 1 writes nothing
;; yet: its first delivery is what issues the restart, and it has to happen
;; after the stop.
(write-chunk! (client-at stopper-index) 0)

(let write-rest ((i 2))
  (when (< i client-count)
    (write-all-chunks! (client-at i))
    (write-rest (+ i 1))))

(define stop-outcome
  (run-until/ticking loop (lambda () (not (eq? bp-stopped-at 'never-stopped))) cap))

(test-equal "the designated client stopped its own read from inside a delivery"
  '(satisfied stopped)
  (list stop-outcome (if (eq? bp-stopped-at 'never-stopped) 'never-stopped 'stopped)))

;; Written while its reader is stopped: these are the bytes the echo will hold
;; back. 32 KiB per connection is well inside a loopback socket's buffers on
;; both supported platforms, so nothing here depends on the server's writes
;; completing only after the client resumes -- and if that ever stopped being
;; true, the wait below fails as 'iterations-exhausted rather than hanging.
(write-chunk! (client-at stopper-index) 1)
(write-chunk! (client-at stopper-index) 2)

;; Seven clients have written a full payload each (everyone but client 1).
(define echoed-target (* 7 payload-size))

(define echo-outcome
  (run-until/ticking loop (lambda () (>= server-echoed echoed-target)) cap))

(test-equal "the server echoed all seven writing clients' payloads back"
  (list 'satisfied echoed-target)
  (list echo-outcome (min server-echoed echoed-target)))

;; THE BACKPRESSURE CLAIM, and the reason the row above had to come first:
;; the server has now echoed 229376 bytes -- including every byte client 0
;; sent -- and client 0 still holds exactly what it had when it stopped.
(test-equal "a stopped reader receives nothing, however much the server echoes"
  (list bp-stopped-at 'still-stopped)
  (list (client-total (client-at stopper-index))
        (if (eq? bp-restarted-at 'never-restarted) 'still-stopped 'restarted)))

;; --- the restart, issued from inside a delivery --------------------------
(write-all-chunks! (client-at restarter-index))

(define restart-outcome
  (run-until/ticking loop (lambda () (not (eq? bp-restarted-at 'never-restarted))) cap))

(test-equal "the restart ran from inside another client's delivery, with the stopped client's count unmoved"
  (list 'satisfied bp-stopped-at 'all-echoed)
  (list restart-outcome bp-restarted-at
        (if (and (integer? bp-echoed-at-restart)
                 (>= bp-echoed-at-restart echoed-target))
            'all-echoed
            (list 'only-echoed bp-echoed-at-restart))))

;; --- everyone finishes ---------------------------------------------------
(define transfer-outcome
  (run-until/ticking loop
                     (lambda ()
                       (eq? 'all (all-clients
                                  (lambda (c) (>= (client-total c) payload-size)))))
                     cap))

(test-equal "every client received a full 32 KiB back"
  '(satisfied all)
  (list transfer-outcome
        (all-clients (lambda (c) (= (client-total c) payload-size)))))

;; THE ROWS THE WHOLE SUITE EXISTS FOR. Byte for byte, per client, against the
;; payload that client and no other one sent -- which the distinctness seed
;; above is what makes meaningful.
(let compare ((i 0))
  (when (< i client-count)
    (let ((c (client-at i)))
      (test-equal (string-append "client "
                                 (number->string i)
                                 " received back exactly the bytes it sent")
        (list i 'identical payload-size)
        (list i
              (compare-bytes (client-payload c) (collector-bytes (client-collector c)))
              (client-total c))))
    (compare (+ i 1))))

(test-equal "every client's three chunks were written, and no write failed"
  '(all all)
  (list (all-clients (lambda (c) (= 3 (client-writes-done c))))
        (all-clients (lambda (c) (eq? 'no-write-error (client-write-error c))))))

(test-equal "no client's read ended in an error"
  'all
  (all-clients (lambda (c) (eq? 'on-error-never-fired (client-read-error c)))))

;; --- teardown ------------------------------------------------------------
;; Each client shut down and closed itself from inside the delivery that
;; completed it; each peer does the same on the EOF that follows. The listener
;; is the one handle nothing closes on its own.
(define close-outcome
  (run-until/ticking loop
                     (lambda ()
                       (and (eq? 'all (all-clients
                                       (lambda (c) (eq? 'closed (uv-handle-state (client-tcp c))))))
                            (for-all (lambda (p) (eq? 'closed (uv-handle-state (peer-tcp p))))
                                     peers)))
                     drain-cap))

(uv-close! server)

(define listener-outcome
  (run-until/ticking loop
                     (lambda () (eq? 'closed (uv-handle-state server)))
                     drain-cap))

(test-equal "all seventeen handles closed cleanly"
  '(satisfied satisfied all closed)
  (list close-outcome listener-outcome
        (all-clients (lambda (c) (eq? 'closed (uv-handle-state (client-tcp c)))))
        (uv-handle-state server)))

(test-equal "every peer saw exactly one EOF, and none of them read an error"
  (list client-count 'no-read-errors)
  (list (fold-left + 0 (map peer-eofs peers))
        (if (for-all (lambda (p) (eq? 'on-error-never-fired (peer-read-error p))) peers)
            'no-read-errors
            (map peer-read-error peers))))

(test-equal "no peer's echo write failed"
  'no-write-errors
  (if (for-all (lambda (p) (eq? 'no-write-error (peer-write-error p))) peers)
      'no-write-errors
      (map peer-write-error peers)))

;; #f, from a procedure whose #t means "work remains" -- a loop that ran dry
;; (design spec S5). Read with 'nowait so it cannot block.
(test-equal "the loop has nothing left to run"
  #f (uv-run loop 'nowait))

(test-equal "the facade's live-handle snapshot is empty before teardown"
  '() (uv-loop-live-handles loop))

;; 'torn-down is producible only by both calls returning: the guard turns any
;; condition into a value that is not it, and the second close is the
;; idempotence claim (closing an already-closed loop is a no-op, not an error).
(define teardown-outcome
  (guard (e (#t (list 'raised e)))
    (uv-loop-teardown! loop)
    (uv-loop-close! loop)
    'torn-down))

(test-equal "uv-loop-teardown! and a second uv-loop-close! both succeed"
  'torn-down teardown-outcome)

(test-equal "the loop is closed afterwards"
  #f (uv-loop-open? loop))

;; --- balance -------------------------------------------------------------
(collect)

(test-equal "a full collection after teardown leaves every counter at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (debug-live-counts)))

;; INFORMATIONAL, never asserted: how libuv fragmented 512 KiB of loopback
;; traffic into deliveries is kernel policy and differs between platforms,
;; between kernels, and between runs.
(display "  [informational] on-data deliveries: clients=")
(display (fold-left + 0 (map (lambda (i) (client-deliveries (client-at i)))
                             '(0 1 2 3 4 5 6 7))))
(display " peers=")
(display (fold-left + 0 (map peer-deliveries peers)))
(display " bytes echoed=")
(display server-echoed)
(newline)

(test-end "echo")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
