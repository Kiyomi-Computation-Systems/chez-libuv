#!r6rs
;;; SRFI-64 suite for where tests/test-tcp.sps lets a failed loopback seed
;;; reach, and for the caps its ticking waits give up at.
;;;
;;; Each loopback section of test-tcp.sps starts its peer as a placeholder,
;;; (define p 'never-accepted), which the server's accept callback replaces
;;; with the accepted handle. A handshake that misses its cap leaves the
;;; placeholder in place (2026-10-06, under load), and two shapes then cost
;;; the suite its summary and every row after the failure:
;;;
;;; 1. A top-level form that hands the placeholder to a verb raises outside
;;;    every row, and the suite dies with exit 255. A top-level form may name
;;;    a placeholder only where that cannot happen:
;;;    - in a row's tested expression, its last argument, which SRFI-64
;;;      catches. A row's name and expected value are evaluated outside that
;;;      catch (testing-impl.scm's %test-comp2body), so they count as
;;;      plumbing;
;;;    - inside a lambda or a procedure definition, which runs later, as a
;;;      callback or a predicate;
;;;    - as the argument of uv-tcp?, or under a gate on that same peer:
;;;      (when (uv-tcp? p) ...) or the consequent of (if (uv-tcp? p) ...).
;;;
;;; 2. A plain run-until steps with 'once, which blocks until an event, and a
;;;    listening server keeps the loop alive: a wait on a peer that never
;;;    arrives hangs the suite until the Makefile's timeout. A wait on a peer
;;;    must tick (run-until/ticking), so that it gives up at its cap.
;;;
;;; 3. A ticking wait should not give up early in the first place.
;;;    run-until/ticking spends an iteration on every 1 ms tick, so its cap is
;;;    a time budget, and `cap` (64) makes it one of about 64 ms. During an
;;;    8-pair loopback flood, deliveries to a connected peer outlasted that,
;;;    and the waits capped at 64 failed by name
;;;    (.plans/tcp-delivery-cap-mutation-log.md). So no ticking wait may give
;;;    up sooner than the longest delivery measured there,
;;;    flooded-delivery-ticks: its cap, a literal or a name test-tcp.sps
;;;    defines as one, must allow at least that many ticks. `cap` stays the
;;;    budget of a plain run-until, whose iterations count events.
;;;
;;; Neither of the first two rules sees a callback that raises inside a later
;;; wait, which a late handshake can cause. That was checked by forcing each
;;; seed to fail, in a scratch clone (.plans/tcp-seed-gates-mutation-log.md);
;;; make test does not repeat it.
;;;
;;; PURE: it reads a source file and imports no native code (PURE_TESTS).
(import (rnrs)
        (srfi :64))

;; SRFI-64 sets no process exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; read-forms : string -> (list-of datum)
(define (read-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms))))))))

;; placeholder-name : datum -> symbol or #f
;; The name FORM defines as 'never-accepted.
(define (placeholder-name form)
  (and (pair? form) (eq? (car form) 'define)
       (pair? (cdr form)) (symbol? (cadr form))
       (pair? (cddr form)) (null? (cdddr form))
       (equal? (caddr form) ''never-accepted)
       (cadr form)))

;; placeholders : (list-of datum) -> (list-of symbol), in definition order.
(define (placeholders forms)
  (filter symbol? (map placeholder-name forms)))

;; checked-peer : datum -> symbol or #f
;; The peer a test of the form (uv-tcp? p) checks.
(define (checked-peer test)
  (and (pair? test) (eq? (car test) 'uv-tcp?)
       (pair? (cdr test)) (symbol? (cadr test)) (null? (cddr test))
       (cadr test)))

;; all-but-last : list -> list
(define (all-but-last xs)
  (if (or (null? xs) (null? (cdr xs)))
      '()
      (cons (car xs) (all-but-last (cdr xs)))))

;; raising : (list-of symbol) datum -> (list-of symbol)
;; Each of PEERS that top-level FORM names where a failed seed would raise
;; from it (rule 1), once per occurrence.
(define (raising peers form)
  (define (walk x gated)
    (cond ((symbol? x)
           (if (and (memq x peers) (not (memq x gated))) (list x) '()))
          ((pair? x) (walk-form x gated))
          (else '())))
  (define (walk-each xs gated)
    (if (pair? xs)
        (append (walk (car xs) gated) (walk-each (cdr xs) gated))
        (walk xs gated)))
  (define (walk-form x gated)
    (let ((head (car x)) (args (cdr x)))
      (cond ((memq head '(quote lambda)) '())
            ((and (eq? head 'define) (pair? args))
             (if (pair? (car args)) '() (walk-each (cdr args) gated)))
            ((and (memq head '(test-equal test-eqv test-eq test-assert))
                  (list? args))
             (walk-each (all-but-last args) gated))
            ((checked-peer x) '())
            ((and (eq? head 'when) (pair? args) (checked-peer (car args)))
             (walk-each (cdr args) (cons (checked-peer (car args)) gated)))
            ((and (eq? head 'if) (pair? args) (checked-peer (car args))
                  (pair? (cdr args)))
             (append (walk (cadr args) (cons (checked-peer (car args)) gated))
                     (walk-each (cddr args) gated)))
            (else (walk-each x gated)))))
  (walk form '()))

;; blocking : (list-of symbol) datum -> (list-of symbol)
;; Each of PEERS that a plain run-until anywhere in FORM waits on (rule 2).
(define (blocking peers form)
  (define (named x)
    (cond ((symbol? x) (if (memq x peers) (list x) '()))
          ((and (pair? x) (eq? (car x) 'quote)) '())
          ((pair? x) (append (named (car x)) (named (cdr x))))
          (else '())))
  (define (walk x)
    (if (pair? x)
        (append (if (and (eq? (car x) 'run-until) (list? x) (= (length x) 4))
                    (named (caddr x))
                    '())
                (walk-each x))
        '()))
  (define (walk-each xs)
    (if (pair? xs) (append (walk (car xs)) (walk-each (cdr xs))) '()))
  (walk form))

;; ticking-waits : datum -> (list-of datum)
;; Each (run-until/ticking loop pred cap) anywhere in FORM, in order. Quoted
;; data is not a wait.
(define (ticking-waits form)
  (define (walk x)
    (cond ((not (pair? x)) '())
          ((eq? (car x) 'quote) '())
          ((and (eq? (car x) 'run-until/ticking) (list? x) (= (length x) 4))
           (cons x (walk-each (cdr x))))
          (else (walk-each x))))
  (define (walk-each xs)
    (if (pair? xs) (append (walk (car xs)) (walk-each (cdr xs))) '()))
  (walk form))

;; The longest a delivery took during an 8-pair loopback flood, in ticks: the
;; 1 MiB transfer's drain (.plans/tcp-delivery-cap-mutation-log.md). Rule 3's
;; floor.
(define flooded-delivery-ticks 1529)

;; integer-definitions : (list-of datum) -> (list-of (symbol . integer))
;; Each top-level (define name n) among FORMS whose n is an exact integer.
(define (integer-definitions forms)
  (filter pair?
          (map (lambda (form)
                 (and (pair? form) (eq? (car form) 'define)
                      (pair? (cdr form)) (symbol? (cadr form))
                      (pair? (cddr form)) (null? (cdddr form))
                      (integer? (caddr form)) (exact? (caddr form))
                      (cons (cadr form) (caddr form))))
               forms)))

;; budget : (list-of (symbol . integer)) datum -> integer or #f
;; How many ticks a wait's cap allows: a literal, or a name DEFS defines.
(define (budget defs cap-form)
  (cond ((and (integer? cap-form) (exact? cap-form)) cap-form)
        ((and (symbol? cap-form) (assq cap-form defs)) => cdr)
        (else #f)))

;; short-waits : (list-of (symbol . integer)) datum -> (list-of datum)
;; Each ticking wait in FORM whose cap allows fewer ticks than the floor, or
;; a number this scan cannot tell (rule 3), as (cap predicate), so that a
;; failure says which wait.
(define (short-waits defs form)
  (map (lambda (wait) (list (cadddr wait) (caddr wait)))
       (filter (lambda (wait)
                 (let ((ticks (budget defs (cadddr wait))))
                   (not (and ticks (>= ticks flooded-delivery-ticks)))))
               (ticking-waits form))))

;; first-uses : list -> list
;; XS without repeats, each kept where it first occurs.
(define (first-uses xs)
  (let loop ((xs xs) (seen '()))
    (cond ((null? xs) (reverse seen))
          ((member (car xs) seen) (loop (cdr xs) seen))
          (else (loop (cdr xs) (cons (car xs) seen))))))

;; findings : (symbol-list datum -> symbol-list) (list-of datum)
;;            -> (list-of (list symbol symbol datum))
;; Each peer SCAN reports, with the head and first argument of the top-level
;; form it is in, so that a failure says where to look.
(define (findings scan peers forms)
  (apply append
         (map (lambda (form)
                (map (lambda (peer)
                       (list peer (car form) (if (pair? (cdr form)) (cadr form) '())))
                     (scan peers form)))
              (filter pair? forms))))

;; report : string list -> unspecified
(define (report label found)
  (for-each (lambda (f) (display "  [") (display label) (display "] ") (write f) (newline))
            found))

(test-begin "seed-gates")

(define forms (read-forms "tests/test-tcp.sps"))
(define peers (placeholders forms))

;; The scans are live only if they found the placeholders: an empty list
;; would pass the last two rows against any file at all.
(test-equal "the scan finds every placeholder peer test-tcp.sps defines"
  '(accepted pa-peer pending-peer q-peer graise-peer s-peer
    m-peer b-peer x-peer wv-peer rt-peer ka-peer)
  peers)

;; One case per decision the scans make: what each must report, then what
;; it must not.
(test-equal "rule 1 flags a peer a failed seed would raise from, and only that"
  '((p) (p) (p) (p) (p) () () () () () () () () () ())
  (map (lambda (form) (raising '(p) form))
       '((uv-read-stop! p)
         (define x (stream-read-buf p))
         (test-equal "row" (stream-read-buf p) 1)
         (when (uv-tcp? q) (uv-read-stop! p))
         (define x (if (uv-tcp? p) 1 (stream-read-buf p)))
         (test-equal "row" 1 (stream-read-buf p))
         (test-assert "row" (stream-reading? p))
         (when (uv-tcp? p) (uv-read-stop! p))
         (define x (if (uv-tcp? p) (stream-read-buf p) 'never-accepted))
         (define ready (uv-tcp? p))
         (define x '(p))
         (uv-listen! s 1 (lambda (err) (set! p (uv-accept! s))))
         (define (on-data bv start end) (uv-read-stop! p))
         (define p 'never-accepted)
         (test-equal "row" 'a-tcp (if (uv-tcp? p) 'a-tcp 'never-accepted)))))

(test-equal "rule 2 flags a plain run-until that waits on a peer, and only that"
  '((p) (p) () () ())
  (map (lambda (form) (blocking '(p) form))
       '((run-until l (lambda () (uv-tcp? p)) 64)
         (test-equal "row" 'satisfied (run-until l (lambda () (uv-tcp? p)) 64))
         (run-until/ticking l (lambda () (uv-tcp? p)) 64)
         (run-until l (lambda () (positive? n)) 64)
         (run-until l (lambda () (eq? x 'p)) 64))))

(test-equal "a cap's ticks come from the file's own integer definitions"
  '((cap . 64) (delivery-cap . 4000))
  (integer-definitions '((define cap 64) (define (f) 64) (define x 'sym)
                         (define y 2.0) (define z (+ 1 2))
                         (define delivery-cap 4000))))

(test-equal "rule 3 flags a ticking wait that gives up sooner than a flooded delivery, and only that"
  '(((cap p)) ((64 p)) ((short p)) ((unknown p)) ((cap p)) ((cap p))
    () () () ())
  (let ((defs '((cap . 64) (short . 1528) (long . 1529))))
    (map (lambda (form) (short-waits defs form))
         '((run-until/ticking l p cap)
           (run-until/ticking l p 64)
           (run-until/ticking l p short)
           (run-until/ticking l p unknown)
           (define o (run-until/ticking l p cap))
           (test-equal "row" 'satisfied (if ok (run-until/ticking l p cap) 'skipped))
           (run-until/ticking l p long)
           (run-until/ticking l p 4000)
           (run-until l p cap)
           (define x '(run-until/ticking l p cap))))))

(test-equal "the findings name each flagged peer with the head and first argument of its form"
  '((p uv-read-stop! p) (p define x))
  (findings raising '(p)
            '((uv-read-stop! p)
              (define x (stream-read-buf p))
              (when (uv-tcp? p) (uv-read-stop! p)))))

(define raise-findings (findings raising peers forms))
(define block-findings (findings blocking peers forms))
(define cap-definitions (integer-definitions forms))
(define short-findings
  (apply append (map (lambda (form) (short-waits cap-definitions form)) forms)))

;; The runner prints only a failing row's name, so the findings are printed.
(report "raises" raise-findings)
(report "blocks" block-findings)
(report "short" short-findings)

(test-equal "no top-level form of test-tcp.sps names a placeholder peer where a failed seed would raise from it"
  '() raise-findings)

(test-equal "no plain run-until in test-tcp.sps waits on a placeholder peer"
  '() block-findings)

;; Live, and the whole vocabulary: a scan that found no ticking wait would
;; pass the row after it against any file. A ticking wait given a new cap,
;; or a literal, changes this list, so that choice gets made here on purpose.
(test-equal "the cap scan sees every cap test-tcp.sps's ticking waits give up at"
  '(handshake-cap 8000 delivery-cap 4000)
  (first-uses (map cadddr (apply append (map ticking-waits forms)))))

(test-equal "no ticking wait in test-tcp.sps gives up sooner than a delivery took during a loopback flood"
  '() short-findings)

(test-end "seed-gates")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
