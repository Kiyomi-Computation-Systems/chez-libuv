;;; spike/dns/05-cancel-race.ss — Q3: the cancel race histogram.
;;;
;;; Usage:
;;;   chez --script spike/dns/05-cancel-race.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib <pinned|default-control> [trials]
;;;
;;; What this measures:
;;;   Per trial: submit FOUR blocker getaddrinfo requests, then a TAIL
;;;   request, then call uv_cancel(tail) in the SAME TURN (no loop iteration
;;;   in between), then run the loop to quiescence. Record the pair
;;;   (uv_cancel rc, tail callback status) into a histogram, and assert the
;;;   branch invariant the design's tolerant cancel test depends on: EVERY
;;;   request's callback fires EXACTLY ONCE in EVERY outcome
;;;   (vendor/libuv/src/threadpool.c:399-441).
;;;
;;;   `pinned` runs after `putenv UV_THREADPOOL_SIZE=1`, issued before ANY
;;;   threadpool touch — the pool is process-global and reads the variable
;;;   once, at the first uv__work_submit (threadpool.c:194-217), which is
;;;   also why the two modes are separate PROCESSES, not two phases of one.
;;;   `default-control` is the same trials at the untouched default pool.
;;;
;;; The two legal histogram branches, from the pinned source (spec section 7):
;;;   cancel rc 0      -> the request was still queued; the callback still
;;;                       fires, with UV_ECANCELED rewritten to
;;;                       UV_EAI_CANCELED (getaddrinfo.c:128-133);
;;;   cancel rc EBUSY  -> the request was already running or completed; the
;;;                       callback delivers the normal result (status 0).
;;; Any other (rc . status) pair lands in the histogram as an unexpected key
;;; and fails the run.
;;;
;;; THE HISTOGRAM COUNTS ARE A MEASURED RACE — they are the one part of this
;;; script's stdout that is legitimately not byte-identical across runs, and
;;; FINDINGS.md names them as such. The invariant lines and the verdict are
;;; deterministic.
;;;
;;; Blockers are numeric lookups (ADR-0013: zero network), which complete in
;;; microseconds — the race is real and the histogram records whichever side
;;; won each trial. No wall-clock sleeps anywhere; each trial's quiescence is
;;; one blocking uv_run(DEFAULT), bounded by the threadpool completing five
;;; pure-libc calls.
;;;
;;; SPIKE-ONLY CONSTANTS: from spike/dns/probe-dns (Darwin arm64); production
;;; snapshots them in the shim (ADR-0005).

(import (chezscheme))

(define argv (command-line-arguments))

(define (usage)
  (display "usage: 05-cancel-race.ss <libuv.dylib> <pinned|default-control> [trials]\n")
  (exit 2))

(define lib-path (if (null? argv) (usage) (car argv)))
(define mode
  (if (or (null? argv) (null? (cdr argv))) (usage) (cadr argv)))
(unless (member mode '("pinned" "default-control")) (usage))
(define trials
  (if (or (null? argv) (null? (cdr argv)) (null? (cddr argv)))
      1000
      (string->number (caddr argv))))

;;; --- probe-supplied constants (spike/dns/probe-dns output, Darwin arm64) ---
(define UV_GETADDRINFO      8)
(define UV_RUN_DEFAULT      0)
(define AF_INET             2)
(define SOCK_STREAM         1)
(define AI_NUMERICHOST      4)
(define AI_NUMERICSERV      4096)
(define SIZEOF_ADDRINFO     48)
(define OFFSETOF_AI_FLAGS    0)
(define OFFSETOF_AI_FAMILY   4)
(define OFFSETOF_AI_SOCKTYPE 8)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()          size_t))
(define uv-req-size     (foreign-procedure "uv_req_size"     (int)       size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)      int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)      int))
(define uv-loop-alive   (foreign-procedure "uv_loop_alive"   (uptr)      int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)  int))
(define uv-getaddrinfo  (foreign-procedure "uv_getaddrinfo"
                                           (uptr uptr uptr string string uptr) int))
(define uv-cancel       (foreign-procedure "uv_cancel"       (uptr)      int))
(define uv-freeaddrinfo (foreign-procedure "uv_freeaddrinfo" (uptr)      void))
(define uv-os-getenv    (foreign-procedure "uv_os_getenv"    (string u8* uptr) int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)       uptr))

(define (c-string->string addr)
  (if (= addr 0)
      #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))

(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p)
      (foreign-set! 'unsigned-8 p i 0))))

(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-err-name rc))))

;;; --- pool pinning, BEFORE any threadpool touch ------------------------------
(when (string=? mode "pinned")
  (putenv "UV_THREADPOOL_SIZE" "1"))

(define (getenv-via-uv name)
  (let ((buf (make-bytevector 64 0))
        (szp (foreign-alloc 8)))
    (foreign-set! 'unsigned-64 szp 0 64)
    (let ((rc (uv-os-getenv name buf szp)))
      (let ((out (if (zero? rc)
                     (let* ((n (foreign-ref 'unsigned-64 szp 0))
                            (bv (make-bytevector n)))
                       (bytevector-copy! buf 0 bv 0 n)
                       (utf8->string bv))
                     (rc-name rc))))
        (foreign-free szp)
        out))))

(printf "mode                              = ~a\n" mode)
(printf "uv_os_getenv(UV_THREADPOOL_SIZE)  = ~s\n" (getenv-via-uv "UV_THREADPOOL_SIZE"))
(printf "trials                            = ~d\n" trials)

;;; --- shared lookup machinery ------------------------------------------------
(define hints (alloc-zeroed SIZEOF_ADDRINFO))
(foreign-set! 'int hints OFFSETOF_AI_FLAGS (bitwise-ior AI_NUMERICHOST AI_NUMERICSERV))
(foreign-set! 'int hints OFFSETOF_AI_FAMILY AF_INET)
(foreign-set! 'int hints OFFSETOF_AI_SOCKTYPE SOCK_STREAM)

(define loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(printf "uv_loop_init                      = ~a\n" (rc-name rc-loop-init))
(define gai-req-size (uv-req-size UV_GETADDRINFO))

;; Per-trial state, reset at the top of each trial. fired-counts maps
;; req-ptr -> fire count, so "exactly one callback per request" is checked
;; per REQUEST, not per trial in aggregate (four fires of one blocker and
;; zero of another would aggregate to the same total).
(define fired-counts (make-eqv-hashtable))
(define tail-req 0)
(define tail-status 'never-fired)  ; sentinel: no callback path produces it

(define blocker-callable
  (foreign-callable
   (lambda (req status res)
     (hashtable-update! fired-counts req (lambda (n) (+ n 1)) 0)
     (uv-freeaddrinfo res))
   (uptr int uptr) void))

(define tail-callable
  (foreign-callable
   (lambda (req status res)
     (hashtable-update! fired-counts req (lambda (n) (+ n 1)) 0)
     (set! tail-status status)
     ;; res is NULL on every failure path, incl. cancel, and
     ;; uv_freeaddrinfo(NULL) is a no-op — unconditional free, as in 04.
     (uv-freeaddrinfo res))
   (uptr int uptr) void))

(lock-object blocker-callable)
(lock-object tail-callable)
(define blocker-cb (foreign-callable-entry-point blocker-callable))
(define tail-cb (foreign-callable-entry-point tail-callable))

;;; --- the trials -------------------------------------------------------------
(define submit-fail-count 0)
(define invariant-violations 0)
(define first-violation 'none)     ; sentinel
(define histogram (make-hashtable equal-hash equal?))

(define (run-one-trial! trial-no)
  (set! fired-counts (make-eqv-hashtable))
  (set! tail-status 'never-fired)
  (let ((reqs (let loop ((i 0) (acc '()))
                (if (= i 5) (reverse acc)
                    (loop (+ i 1) (cons (foreign-alloc gai-req-size) acc))))))
    ;; submit 4 blockers, then the tail — all in this turn
    (for-each
     (lambda (req cb)
       (let ((rc (uv-getaddrinfo loop-ptr req cb "127.0.0.1" "80" hints)))
         (unless (zero? rc)
           (set! submit-fail-count (+ submit-fail-count 1)))))
     reqs
     (list blocker-cb blocker-cb blocker-cb blocker-cb tail-cb))
    (set! tail-req (list-ref reqs 4))
    ;; SAME TURN: cancel the tail before the loop has run at all
    (let ((rc-cancel (uv-cancel tail-req)))
      ;; quiescence: every callback (cancelled or completed) has fired when
      ;; this returns — bounded by the pool completing five pure-libc calls
      (uv-run loop-ptr UV_RUN_DEFAULT)
      ;; branch invariant: exactly one callback per request
      (for-each
       (lambda (req)
         (let ((n (hashtable-ref fired-counts req 0)))
           (unless (= n 1)
             (set! invariant-violations (+ invariant-violations 1))
             (when (eq? first-violation 'none)
               (set! first-violation
                     (list 'trial trial-no 'req-fired n))))))
       reqs)
      ;; histogram
      (let ((key (cons (rc-name rc-cancel)
                       (if (symbol? tail-status)
                           (symbol->string tail-status)
                           (rc-name tail-status)))))
        (hashtable-update! histogram key (lambda (n) (+ n 1)) 0))
      (for-each foreign-free reqs))))

(let loop ((i 1))
  (when (<= i trials)
    (run-one-trial! i)
    (when (zero? (mod i 100)) (collect))
    (loop (+ i 1))))

;;; --- results ----------------------------------------------------------------
;; Sorted for a stable PRESENTATION; the counts themselves are the measured
;; race and vary between runs.
(define (histogram->sorted-alist)
  (let-values (((keys vals) (hashtable-entries histogram)))
    (let ((alist (map cons (vector->list keys) (vector->list vals))))
      (list-sort (lambda (a b)
                   (string<? (string-append (caar a) "/" (cdar a))
                             (string-append (caar b) "/" (cdar b))))
                 alist))))

(define sorted (histogram->sorted-alist))
(printf "\nhistogram (cancel-rc . tail-status) — counts are the measured race:\n")
(for-each
 (lambda (e)
   (printf "  (~a . ~a) = ~d\n" (caar e) (cdar e) (cdr e)))
 sorted)

(define cancelled-count
  (fold-left + 0 (map (lambda (e) (if (equal? (car e) '("0" . "EAI_CANCELED")) (cdr e) 0))
                      sorted)))
(define completed-count
  (fold-left + 0 (map (lambda (e) (if (equal? (car e) '("EBUSY" . "0")) (cdr e) 0))
                      sorted)))
(define unexpected-count
  (- (fold-left + 0 (map cdr sorted)) cancelled-count completed-count))

(printf "\ncancelled branch (0 . EAI_CANCELED) trials = ~d\n" cancelled-count)
(printf "completed branch (EBUSY . 0) trials        = ~d\n" completed-count)
(printf "trials in any OTHER branch                 = ~d\n" unexpected-count)
(printf "exactly-one-callback violations            = ~d\n" invariant-violations)
(printf "first violation                            = ~s\n" first-violation)
(printf "submit failures                            = ~d\n" submit-fail-count)
(printf "cancelled branch dominates?                = ~s\n"
        (> cancelled-count completed-count))

;;; --- teardown ---------------------------------------------------------------
(define alive-after (uv-loop-alive loop-ptr))
(define rc-loop-close (uv-loop-close loop-ptr))
(printf "uv_loop_alive after trials                 = ~d\n" alive-after)
(printf "uv_loop_close                              = ~a\n" (rc-name rc-loop-close))
(foreign-free loop-ptr)
(foreign-free hints)
(collect (collect-maximum-generation))
(display "post-teardown collect done\n")

;;; --- verdict ----------------------------------------------------------------
;; Deterministic PASS criteria; the raw counts above are observations.
;; `pinned` additionally requires the cancelled branch to dominate — the
;; design's exit criterion for licensing the tolerant cancel test.
(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual (if (equal? expected actual) "OK" "MISMATCH")))

(display "\n--- checks ---\n")
(check "every trial in a legal branch"  0 unexpected-count)
(check "exactly-one-callback held"      0 invariant-violations)
(check "first violation sentinel"       'none first-violation)
(check "no submit failures"             0 submit-fail-count)
(check "trials accounted for"           trials (+ cancelled-count completed-count
                                                  unexpected-count))
(when (string=? mode "pinned")
  (check "cancelled branch dominates (pinned)" #t (> cancelled-count completed-count)))
(check "loop alive after trials"        0 alive-after)
(check "uv_loop_close rc"               0 rc-loop-close)

(define ok?
  (and (zero? unexpected-count)
       (zero? invariant-violations)
       (eq? first-violation 'none)
       (zero? submit-fail-count)
       (= trials (+ cancelled-count completed-count unexpected-count))
       (or (string=? mode "default-control")
           (> cancelled-count completed-count))
       (zero? alive-after)
       (zero? rc-loop-close)))

(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
