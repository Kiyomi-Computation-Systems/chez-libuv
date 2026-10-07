#!r6rs
;;; SRFI-64 suite for where a failed loopback seed reaches in the suites that
;;; wait for an accepted peer, and for the caps test-tcp.sps's ticking waits
;;; give up at.
;;;
;;; A loopback section starts its peer as a placeholder, which the server's
;;; accept callback replaces with the accepted handle. A handshake that misses
;;; its cap leaves the placeholder in place (test-tcp.sps, 2026-10-06, under
;;; load), and two shapes then cost a suite its summary and every row after
;;; the failure:
;;;
;;; 1. A form that hands the placeholder to a verb outside every row raises,
;;;    and the suite dies with exit 255. Such a form may name a placeholder
;;;    only where that cannot happen:
;;;    - in a row's tested expression, its last argument, which SRFI-64
;;;      catches. A row's name and expected value are evaluated outside that
;;;      catch (testing-impl.scm's %test-comp2body), so they count as
;;;      plumbing;
;;;    - inside a lambda or a procedure definition, which runs later, as a
;;;      callback or a predicate. The body handed to with-loop or
;;;      call-with-uv-loop runs at once, so it counts as plumbing;
;;;    - as an argument of uv-tcp? or eq?, which answer for any value, or
;;;      under a gate on that same peer: (when (uv-tcp? p) ...) or the
;;;      consequent of (if (uv-tcp? p) ...).
;;;
;;; 2. A plain run-until steps with 'once, which blocks until an event, and a
;;;    listening server keeps the loop alive: a wait on anything that only an
;;;    accepted peer sets hangs the suite until the Makefile's timeout when
;;;    the peer never arrives. Such a wait must tick (run-until/ticking), so
;;;    that it gives up at its cap. What an accepted peer sets is each set!
;;;    in the form of an accept callback that accepts it: the placeholder, a
;;;    count or a list of peers, the peer's own callbacks' observers.
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
;;;    Rule 3 holds test-tcp.sps alone: only its ticking waits were measured
;;;    under a flood.
;;;
;;; 4. A suite that tests the address and DNS verbs calls them only where a
;;;    raise from one fails a row: in a row's tested expression, in a
;;;    procedure body, or in the body of a guard with an else or #t clause.
;;;    A verb that raises anywhere else ends the suite at that form, with no
;;;    summary and none of the evidence after it: under #61's mutations MV1
;;;    and MA8, test-dns.sps died at its first lookup and test-tcp.sps at its
;;;    first bind (#64). A procedure of the suite's own that such a raise can
;;;    leave counts as a verb.
;;;
;;; Neither of the first two rules sees a callback that raises inside a later
;;; wait, which a late handshake can cause. That was checked by forcing each seed to fail, in a
;;; scratch clone (.plans/tcp-seed-gates-mutation-log.md and
;;; .plans/sibling-seed-gates-mutation-log.md); make test does not repeat it.
;;;
;;; PURE: it reads source files and imports no native code (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (only (chezscheme) directory-list))

;; SRFI-64 sets no process exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; The suites the scan reads. Each says how it spells a peer not yet accepted
;; (spelt, quoted), and names the peers no spelling finds (named): #f starts
;; plenty of variables that are not peers, and a peer taken from a list the
;; accept callback builds is not defined as a placeholder at all. A suite may
;; have row forms of its own (rows), which catch their last argument as
;; SRFI-64's rows do.
(define suites
  '(("tests/test-tcp.sps" (spelt never-accepted))
    ("tests/test-stream.sps" (named s-peer sw-accepted))
    ("tests/test-flow.sps" (spelt not-accepted) (named closing-peer))
    ("tests/test-facade.sps" (spelt never-accepted))
    ("tests/test-lifecycle.sps" (spelt never-accepted))
    ("tests/test-callback-alloc.sps" (named r-peer rd-peer) (rows row))
    ("tests/test-process.sps" (named accepted))
    ("tests/test-echo.sps")
    ("tests/test-constructors.sps")))

;; calls? : datum symbol -> boolean
;; Whether X calls NAME anywhere outside quoted data.
(define (calls? x name)
  (and (pair? x)
       (not (eq? (car x) 'quote))
       (or (eq? (car x) name)
           (let each ((xs x))
             (and (pair? xs) (or (calls? (car xs) name) (each (cdr xs))))))))

;; suite-files : -> (list-of string)
;; Every tests/test-*.sps, sorted. A dotfile an editor leaves there is not
;; one.
(define (suite-files)
  (define (suite? n)
    (let ((len (string-length n)))
      (and (> len 9)
           (string=? (substring n 0 5) "test-")
           (string=? (substring n (- len 4) len) ".sps"))))
  (map (lambda (n) (string-append "tests/" n))
       (list-sort string<? (filter suite? (directory-list "tests")))))

;; read-forms : string -> (list-of datum)
(define (read-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms))))))))

;; runs-at-once? : datum -> boolean
;; A call handing a lambda to with-loop or call-with-uv-loop, which run it
;; before they return.
(define (runs-at-once? form)
  (and (pair? form) (memq (car form) '(with-loop call-with-uv-loop))
       (pair? (cdr form)) (null? (cddr form))
       (pair? (cadr form)) (eq? (car (cadr form)) 'lambda)
       (pair? (cdr (cadr form))) (list? (cddr (cadr form)))))

;; plumbing : (list-of datum) -> (list-of datum)
;; The forms that run as plumbing: the top-level forms, with the body of a
;; lambda that runs at once in place of the call that runs it.
(define (plumbing forms)
  (apply append
         (map (lambda (form)
                (if (runs-at-once? form)
                    (plumbing (cddr (cadr form)))
                    (list form)))
              forms)))

;; placeholder-name : (list-of symbol) (list-of symbol) datum -> symbol or #f
;; The name FORM defines as a placeholder: as one of SPELT, quoted, or as one
;; of NAMED, however it starts.
(define (placeholder-name spelt named form)
  (and (pair? form) (eq? (car form) 'define)
       (pair? (cdr form)) (symbol? (cadr form))
       (pair? (cddr form)) (null? (cdddr form))
       (let ((name (cadr form)) (init (caddr form)))
         (and (or (memq name named)
                  (and (pair? init) (eq? (car init) 'quote)
                       (pair? (cdr init)) (symbol? (cadr init))
                       (memq (cadr init) spelt)))
              name))))

;; placeholders : (list-of symbol) (list-of symbol) (list-of datum)
;;                -> (list-of symbol), in definition order.
(define (placeholders spelt named forms)
  (filter symbol? (map (lambda (form) (placeholder-name spelt named form)) forms)))

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

;; SRFI-64's row forms.
(define row-heads '(test-equal test-eqv test-eq test-assert))

;; raising : (list-of symbol) datum [(list-of symbol)] -> (list-of symbol)
;; Each of PEERS that plumbing FORM names where a failed seed would raise
;; from it (rule 1), once per occurrence. ROWS are the suite's own row forms.
(define raising
  (case-lambda
    ((peers form) (raising peers form '()))
    ((peers form rows)
     (let ((heads (append rows row-heads)))
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
                 ((and (memq head heads) (list? args))
                  (walk-each (all-but-last args) gated))
                 ((checked-peer x) '())
                 ((and (eq? head 'eq?) (list? args))
                  (walk-each (filter (lambda (a) (not (symbol? a))) args) gated))
                 ((and (eq? head 'when) (pair? args) (checked-peer (car args)))
                  (walk-each (cdr args) (cons (checked-peer (car args)) gated)))
                 ((and (eq? head 'if) (pair? args) (checked-peer (car args))
                       (pair? (cdr args)))
                  (append (walk (cadr args) (cons (checked-peer (car args)) gated))
                          (walk-each (cddr args) gated)))
                 (else (walk-each x gated)))))
       (walk form '())))))

;; contains? : datum symbol -> boolean
(define (contains? x name)
  (cond ((eq? x name) #t)
        ((pair? x) (or (contains? (car x) name) (contains? (cdr x) name)))
        (else #f)))

;; set-targets : datum -> (list-of symbol)
;; Each variable a set! anywhere in X assigns, in order.
(define (set-targets x)
  (cond ((and (pair? x) (eq? (car x) 'set!) (pair? (cdr x)) (symbol? (cadr x)))
         (cons (cadr x) (set-targets (cddr x))))
        ((pair? x) (append (set-targets (car x)) (set-targets (cdr x))))
        (else '())))

;; accept-callbacks : datum -> (list-of datum)
;; The callback of each (uv-listen! server backlog (lambda (err) ...))
;; anywhere in X.
(define (accept-callbacks x)
  (cond ((and (pair? x) (eq? (car x) 'uv-listen!) (list? x) (= (length x) 4)
              (pair? (cadddr x)) (eq? (car (cadddr x)) 'lambda)
              (pair? (cdr (cadddr x))) (list? (cddr (cadddr x))))
         (cons (cadddr x) (accept-callbacks (cdr x))))
        ((pair? x) (append (accept-callbacks (car x)) (accept-callbacks (cdr x))))
        (else '())))

;; seeded : (list-of datum) -> (list-of symbol)
;; What an accepted peer sets: each set! target in a body form of an accept
;; callback that calls uv-accept!, anywhere in FORMS, in order.
(define (seeded forms)
  (apply append
         (map (lambda (callback)
                (set-targets
                 (filter (lambda (f) (contains? f 'uv-accept!)) (cddr callback))))
              (apply append (map accept-callbacks forms)))))

;; accept-stored : (list-of datum) -> (list-of symbol)
;; Each variable a (set! v (uv-accept! ...)) anywhere in FORMS stores the
;; accepted peer in.
(define (accept-stored forms)
  (define (walk x)
    (cond ((and (pair? x) (eq? (car x) 'set!) (list? x) (= (length x) 3)
                (symbol? (cadr x)) (pair? (caddr x)) (eq? (car (caddr x)) 'uv-accept!))
           (list (cadr x)))
          ((pair? x) (append (walk (car x)) (walk (cdr x))))
          (else '())))
  (apply append (map walk forms)))

;; blocking : (list-of symbol) datum -> (list-of symbol)
;; Each of NAMES that a plain run-until anywhere in FORM waits on (rule 2).
(define (blocking names form)
  (define (named x)
    (cond ((symbol? x) (if (memq x names) (list x) '()))
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
;; Each peer SCAN reports, with the head and first argument of the form it is
;; in, so that a failure says where to look.
(define (findings scan peers forms)
  (apply append
         (map (lambda (form)
                (map (lambda (peer)
                       (list peer (car form) (if (pair? (cdr form)) (cadr form) '())))
                     (scan peers form)))
              (filter pair? forms))))

;; --- rule 4 -------------------------------------------------------------------
;; The suites that test the address and DNS verbs, and those verbs.
(define verb-suites
  '("tests/test-dns.sps" "tests/test-tcp.sps" "tests/test-address.sps"))

(define address-verbs
  '(uv-getaddrinfo! uv-getnameinfo! uv-cancel! uv-tcp-bind! uv-tcp-connect!
    fill-sockaddr!))

;; catch-all? : datum -> boolean
;; A guard clause that catches every raise.
(define (catch-all? clause)
  (and (pair? clause) (memq (car clause) '(else #t)) #t))

;; procedure-body : datum -> (list-of datum) or #f
;; The body of the procedure FORM defines, as (define (f ...) ...) or
;; (define f (lambda ...)), else #f.
(define (procedure-body form)
  (and (pair? form) (eq? (car form) 'define) (pair? (cdr form))
       (cond ((pair? (cadr form)) (cddr form))
             ((and (pair? (cddr form)) (pair? (caddr form))
                   (memq (car (caddr form)) '(lambda case-lambda)))
              (cdr (caddr form)))
             (else #f))))

;; escaping : (list-of symbol) datum -> (list-of symbol)
;; Each call of NAMES in FORM that a raise would leave FORM from, once per
;; call: one not in a row's tested expression, a lambda, a procedure
;; definition, quoted data, or the body of a guard with a catch-all clause.
(define (escaping names form)
  (define (walk x)
    (cond ((not (pair? x)) '())
          ((memq (car x) '(quote quasiquote lambda case-lambda)) '())
          ((procedure-body x) '())
          ((and (memq (car x) row-heads) (list? (cdr x)))
           (walk-each (all-but-last (cdr x))))
          ((and (eq? (car x) 'guard) (pair? (cdr x)) (pair? (cadr x))
                (list? (cdadr x)) (exists catch-all? (cdadr x)))
           (walk-each (cdadr x)))
          (else (append (if (memq (car x) names) (list (car x)) '())
                        (walk-each x)))))
  (define (walk-each xs)
    (if (pair? xs) (append (walk (car xs)) (walk-each (cdr xs))) '()))
  (walk form))

;; procedure-definitions : (list-of datum) -> (list-of (symbol . body))
;; Each procedure FORMS define, with its body.
(define (procedure-definitions forms)
  (filter pair?
          (map (lambda (form)
                 (let ((body (procedure-body form)))
                   (and body
                        (let ((head (cadr form)))
                          (cons (if (pair? head) (car head) head) body)))))
               forms)))

;; raising-procedures : (list-of symbol) (list-of datum) -> (list-of symbol)
;; The procedures FORMS define whose bodies a raise from one of VERBS, or
;; from another such procedure, can leave, in the order found.
(define (raising-procedures verbs forms)
  (let ((defs (procedure-definitions forms)))
    (let grow ((found '()))
      (let ((more
             (map car
                  (filter (lambda (def)
                            (and (not (memq (car def) found))
                                 (exists (lambda (body-form)
                                           (pair? (escaping (append verbs found)
                                                            body-form)))
                                         (cdr def))))
                          defs))))
        (if (null? more) found (grow (append found more)))))))

;; uncaught : (list-of symbol) (list-of datum) -> (list-of list)
;; Rule 4's findings in a suite's FORMS: each call of VERBS, or of a
;; procedure raising-procedures finds, that a raise would leave the suite
;; from, as (verb head first-argument) of its plumbing form.
(define (uncaught verbs forms)
  (let ((names (append verbs (raising-procedures verbs forms))))
    (apply append
           (map (lambda (form)
                  (map (lambda (name)
                         (list name (car form) (if (pair? (cdr form)) (cadr form) '())))
                       (escaping names form)))
                (filter pair? (plumbing forms))))))

;; scan : list (list-of datum) -> list
;; What the rows below hold for one suite, from its SPEC (its entry in
;; suites, less the path) and its FORMS: the placeholders found, what an
;; accepted peer sets, the peers stored from an accept that are not known
;; placeholders, and the findings of rules 1 and 2.
(define (scan spec forms)
  (define (field key)
    (let ((f (assq key spec))) (if f (cdr f) '())))
  (let* ((run (plumbing forms))
         (peers (placeholders (field 'spelt) (field 'named) run))
         (sets (seeded forms)))
    (list (cons 'placeholders peers)
          (cons 'seeded sets)
          (cons 'unknown (filter (lambda (v) (not (memq v peers))) (accept-stored forms)))
          (cons 'raises (findings (lambda (ps form) (raising ps form (field 'rows)))
                                  peers run))
          (cons 'blocks (findings blocking sets run)))))

;; report : string string list -> unspecified
(define (report path label found)
  (for-each (lambda (f)
              (display "  [") (display path) (display " ") (display label)
              (display "] ") (write f) (newline))
            found))

(test-begin "seed-gates")

;; One case per decision the scans make: what each must report, then what
;; it must not.
(test-equal "rule 1 flags a peer a failed seed would raise from, and only that"
  '((p) (p) (p) (p) (p) (p) () () () () () () () () () () ())
  (map (lambda (form) (raising '(p) form))
       '((uv-read-stop! p)
         (define x (stream-read-buf p))
         (test-equal "row" (stream-read-buf p) 1)
         (when (uv-tcp? q) (uv-read-stop! p))
         (define x (if (uv-tcp? p) 1 (stream-read-buf p)))
         (eq? (stream-read-buf p) 'x)
         (test-equal "row" 1 (stream-read-buf p))
         (test-assert "row" (stream-reading? p))
         (when (uv-tcp? p) (uv-read-stop! p))
         (define x (if (uv-tcp? p) (stream-read-buf p) 'never-accepted))
         (define ready (uv-tcp? p))
         (define x '(p))
         (uv-listen! s 1 (lambda (err) (set! p (uv-accept! s))))
         (define (on-data bv start end) (uv-read-stop! p))
         (define p 'never-accepted)
         (test-equal "row" 'a-tcp (if (uv-tcp? p) 'a-tcp 'never-accepted))
         (let drain ((i 0)) (when (and (< i 32) (eq? p 'never-accepted)) (drain (+ i 1)))))))

(test-equal "rule 1 counts a suite's own row form as a row, and only that suite's"
  '((p) (p p))
  (list (raising '(p) '(row 'name (title-of p) (handle-ptr p)) '(row))
        (raising '(p) '(row 'name (title-of p) (handle-ptr p)))))

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

(test-equal "a placeholder is a suite's spelling, quoted, or a name it lists, and only that"
  '(p q q #f #f #f #f)
  (map (lambda (form) (placeholder-name '(never-accepted) '(q) form))
       '((define p 'never-accepted)
         (define q #f)
         (define q (vector-ref peers 0))
         (define r #f)
         (define s 'not-accepted)
         (define t "never-accepted")
         (define (p) 'never-accepted))))

(test-equal "the plumbing is the top-level forms, with a body that runs at once in place of its call"
  '((define a 1) (define p 'x) (f p) (g l) (other (lambda (l) (h l))))
  (plumbing '((define a 1)
              (with-loop (lambda (loop) (define p 'x) (f p)))
              (call-with-uv-loop (lambda (l) (g l)))
              (other (lambda (l) (h l))))))

(test-equal "what an accepted peer sets is each set! in the accept callback's form that accepts it"
  '((p d) (p) (ps) () () (a))
  (map (lambda (form) (seeded (list form)))
       '((uv-listen! s 1 (lambda (err)
                           (set! c (+ c 1))
                           (when (not err)
                             (set! p (uv-accept! s))
                             (uv-read-start! p (lambda (bv a b) (set! d 1)) n n))))
         (uv-listen! s 1 (lambda (err) (set! p (uv-accept! s))))
         (uv-listen! s 1 (lambda (err)
                           (let ((x (uv-accept! s))) (set! ps (cons x ps)))))
         (uv-listen! s 1 (lambda (err) (set! c 1)))
         (begin (set! p (uv-accept! s)))
         (with-loop (lambda (loop)
                      (uv-listen! s 1 (lambda (err)
                                        (when (not err) (set! a (uv-accept! s))))))))))

(test-equal "a peer stored from an accept is each (set! v (uv-accept! ...)), and only that"
  '(p)
  (accept-stored '((uv-listen! s 1 (lambda (err) (set! p (uv-accept! s))))
                   (let ((x (uv-accept! s))) (set! q x))
                   (set! r (f (uv-accept! s))))))

(test-equal "the findings name each flagged peer with the head and first argument of its form"
  '((p uv-read-stop! p) (p define x))
  (findings raising '(p)
            '((uv-read-stop! p)
              (define x (stream-read-buf p))
              (when (uv-tcp? p) (uv-read-stop! p)))))

;; The scan reads every suite that accepts a loopback peer, and only those:
;; a new one joins the list by failing this row. Each side keeps the other
;; live: an empty list of files, or one that reads quoted data as a call,
;; fails it too.
(test-equal "the scan reads exactly the suites that call uv-accept!"
  (list-sort string<? (map car suites))
  (filter (lambda (path) (exists (lambda (f) (calls? f 'uv-accept!)) (read-forms path)))
          (suite-files)))

(test-equal "calls? finds a call at any depth, and not in quoted data"
  '(#t #t #t #f #f #f)
  (map (lambda (form) (calls? form 'f))
       '((f x)
         (define (g) (h (f x)))
         (let ((y 1)) (when y (f y)))
         (define x '(f x))
         (g f)
         (quote (f)))))

;; The rows below read scan's answer for each suite; one synthetic suite
;; holds what scan hands to which rule.
(test-equal "a suite's scan finds its placeholders, what its peers set, unknown peers, and each rule's findings"
  '((placeholders p q)
    (seeded p n u)
    (unknown u)
    (raises (q uv-close! q) (p check 'name))
    (blocks (n run-until l)))
  (scan '((spelt never-accepted) (named q) (rows check))
        '((define p 'never-accepted)
          (define n 0)
          (define u #f)
          (uv-listen! s 1 (lambda (err)
                            (when (not err) (set! p (uv-accept! s)) (set! n (+ n 1)))))
          (uv-listen! s2 1 (lambda (err) (set! u (uv-accept! s2))))
          (with-loop (lambda (loop) (define q 'not-yet) (uv-close! q)))
          (check 'name (f p) (g p))
          (call-with-uv-loop (lambda (l) (run-until l (lambda () (= n 1)) 64))))))

;; Each suite's placeholders and what its accepted peers set, as found. A
;; scan that found none would pass the rules below against any file at all.
(define expected-placeholders
  '(("tests/test-tcp.sps" accepted pa-peer pending-peer q-peer graise-peer s-peer
     m-peer b-peer x-peer wv-peer rt-peer ka-peer)
    ("tests/test-stream.sps" s-peer sw-accepted)
    ("tests/test-flow.sps" closing-peer cpeer cidle-peer)
    ("tests/test-facade.sps" f-accepted c-accepted)
    ("tests/test-lifecycle.sps" w-peer)
    ("tests/test-callback-alloc.sps" r-peer rd-peer)
    ("tests/test-process.sps" accepted)
    ("tests/test-echo.sps")
    ("tests/test-constructors.sps")))

(define expected-seeded
  '(("tests/test-tcp.sps" accepted pa-peer pending-peer q-peer graise-peer s-peer
     m-peer b-peer x-peer x-data-fires x-eof-fires x-error wv-peer rt-peer ka-peer)
    ("tests/test-stream.sps" s-peer sw-accepted)
    ("tests/test-flow.sps" accepted collectors cpeer cidle-peer)
    ("tests/test-facade.sps" f-accepted f-read f-eof f-read-error c-accepted)
    ("tests/test-lifecycle.sps" w-peer accepts)
    ("tests/test-callback-alloc.sps" r-peer rd-peer w-peers)
    ("tests/test-process.sps" accepted)
    ("tests/test-echo.sps" accept-error peers)
    ("tests/test-constructors.sps")))

(for-each
 (lambda (suite)
   (let* ((path (car suite))
          (found (scan (cdr suite) (read-forms path)))
          (answer (lambda (key) (cdr (assq key found)))))
     ;; The runner prints only a failing row's name, so the findings are
     ;; printed.
     (report path "unknown" (answer 'unknown))
     (report path "raises" (answer 'raises))
     (report path "blocks" (answer 'blocks))
     (test-equal (string-append "the scan finds every placeholder peer " path " defines")
       (cdr (assoc path expected-placeholders))
       (answer 'placeholders))
     (test-equal (string-append "the scan finds what an accepted peer sets in " path)
       (cdr (assoc path expected-seeded))
       (answer 'seeded))
     (test-equal (string-append "every peer " path " stores from an accept is a placeholder the scan knows")
       '() (answer 'unknown))
     (test-equal (string-append "no plumbing in " path
                                " names a placeholder peer where a failed seed would raise from it")
       '() (answer 'raises))
     (test-equal (string-append "no plain run-until in " path " waits on what an accepted peer sets")
       '() (answer 'blocks))))
 suites)

;; Rule 3, on test-tcp.sps alone.
(define tcp-forms (read-forms "tests/test-tcp.sps"))
(define cap-definitions (integer-definitions tcp-forms))
(define short-findings
  (apply append (map (lambda (form) (short-waits cap-definitions form)) tcp-forms)))

(report "tests/test-tcp.sps" "short" short-findings)

;; Live, and the whole vocabulary: a scan that found no ticking wait would
;; pass the row after it against any file. A ticking wait given a new cap,
;; or a literal, changes this list, so that choice gets made here on purpose.
(test-equal "the cap scan sees every cap test-tcp.sps's ticking waits give up at"
  '(handshake-cap 8000 delivery-cap 4000)
  (first-uses (map cadddr (apply append (map ticking-waits tcp-forms)))))

(test-equal "no ticking wait in test-tcp.sps gives up sooner than a delivery took during a loopback flood"
  '() short-findings)

;; Rule 4, first on seeded forms: what the scan must report, then what it
;; must not.
(test-equal "rule 4 flags a verb a raise would leave the suite from, and only that"
  '((v) (v) (v) (v) (v) (v) (v) () () () () () () () ())
  (map (lambda (form) (escaping '(v) form))
       '((v 1)
         (define x (v 1))
         (let loop ((i 0)) (when (< i 2) (v i) (loop (+ i 1))))
         (test-equal (v 1) 'expected (f))
         (test-equal "row" (v 1) (f))
         (guard (e ((symbol? e) 'caught)) (v 1))
         (guard (e (#t (v 2))) (f))
         (test-equal "row" 'started (v 1))
         (test-assert "row" (v 1))
         (define (f) (v 1))
         (define f (lambda () (v 1)))
         (g (lambda () (v 1)))
         (guard (e (#t 'caught)) (v 1))
         (guard (e (else 'caught)) (v 1))
         (define x '(v 1)))))

(test-equal "a procedure a raise from a verb can leave counts as one, through another too"
  '(a b c)
  (raising-procedures '(v)
                      '((define (c) (b))
                        (define (a) (v 1))
                        (define b (lambda () (a)))
                        (define (d) (guard (e (#t #f)) (v 1)))
                        (define (e) (g (lambda () (v 1))))
                        (define (f) (test-equal "row" 1 (v 1)))
                        (define x (v 1)))))

(test-equal "rule 4's findings name each call with its form's head and first argument, in a body that runs at once too"
  '((a a ()) (v v 2) (a define x))
  (uncaught '(v)
            '((define (a) (v 1))
              (a)
              (with-loop (lambda (l) (v 2)))
              (define x (a))
              (test-equal "row" 1 (a)))))

;; Live: a list naming a verb these suites never call, or a scan that read
;; no file or no procedure, would pass the rows after it.
(define verb-suite-forms (map read-forms verb-suites))

(test-equal "rule 4's scan is live: it reads each suite, each verb is called there, and test-dns.sps's raising procedures are found"
  'live
  (let ((uncalled (filter (lambda (verb)
                            (not (exists (lambda (forms)
                                           (exists (lambda (f) (calls? f verb)) forms))
                                         verb-suite-forms)))
                          address-verbs))
        (dns-procedures (raising-procedures address-verbs (car verb-suite-forms))))
    (if (and (for-all pair? verb-suite-forms) (null? uncalled)
             (memq 'h-submit! dns-procedures)
             (memq 'make-synthetic-sockaddr dns-procedures))
        'live
        (list 'forms (map length verb-suite-forms) 'uncalled uncalled
              'dns-procedures dns-procedures))))

(for-each
 (lambda (path forms)
   (let ((found (uncaught address-verbs forms)))
     (report path "uncaught" found)
     (test-equal (string-append "no plumbing in " path
                                " calls an address or DNS verb where a raise would end the suite")
       '() found)))
 verb-suites verb-suite-forms)

(test-end "seed-gates")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
