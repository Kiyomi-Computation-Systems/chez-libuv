#!r6rs
;;; SRFI-64 suite holding every variable a file directly under tests/
;;; assigns to being read, other than in its own assignment.
;;;
;;; A placeholder that a callback sets and no row reads checks nothing, and
;;; reads as though something did: a peer that an accept callback sets, and
;;; that test-seed-gates' peer census lists, gates nothing if no row reads
;;; it.
;;;
;;; The walk reads scope, because the suites reuse names across sections
;;; (test-process.sps binds proc in 19 places): a read of another binding
;;; of the same name does not count. A read inside the variable's own set!
;;; does not count either, unless a lambda there holds it: the lambda runs
;;; later and reads the value stored.
;;;
;;; It reads the binding forms the tests use: define and define-values,
;;; lambda and case-lambda, the let family with let-values and let*-values,
;;; do, guard, and a record type's protocol. Anything else is read as a call
;;; whose arguments form a body, as a macro's would, so a definition in a
;;; with-mutex or parameterize body binds for the rest of it. A syntax-rules
;;; template is read only for the names it mentions: its pattern variables
;;; shadow, its quoted parts and vectors are data, and its own forms are its
;;; expansion's, not taken apart. A binding form outside this list counts
;;; its names as reads, and what a macro use binds is not seen; each can
;;; hide a finding.
;;;
;;; PURE: it reads source files and imports no native code (PURE_TESTS).
(import (rnrs)
        (srfi :64)
        (only (uv-source) source-file? test-sources read-forms))

;; SRFI-64 sets no process exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. A row that answers
;; what it found as its actual value fails carrying it, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; A variable the walk found bound, and what it saw done to it.
(define-record-type binding (fields name (mutable assigned) (mutable read)))

;; formals-names : datum -> (list-of symbol)
;; The names a lambda's formals bind: a list, an improper list or one name.
(define (formals-names formals)
  (cond ((symbol? formals) (list formals))
        ((pair? formals) (append (formals-names (car formals))
                                 (formals-names (cdr formals))))
        (else '())))

;; datum-symbols : datum -> (list-of symbol)
;; Every symbol in X, in pairs and vectors: a syntax-rules pattern's
;; variables, with its keyword, literals and ellipses.
(define (datum-symbols x)
  (cond ((symbol? x) (list x))
        ((pair? x) (append (datum-symbols (car x)) (datum-symbols (cdr x))))
        ((vector? x) (datum-symbols (vector->list x)))
        (else '())))

;; body-names : (list-of datum) -> (list-of symbol)
;; The names a body's definitions bind, a begin's included.
(define (body-names forms)
  (apply append
         (map (lambda (f)
                (cond ((not (pair? f)) '())
                      ((and (eq? (car f) 'define) (pair? (cdr f)))
                       (let head ((target (cadr f)))
                         (cond ((symbol? target) (list target))
                               ((pair? target) (head (car target)))
                               (else '()))))
                      ((and (eq? (car f) 'define-values) (pair? (cdr f)))
                       (formals-names (cadr f)))
                      ((eq? (car f) 'begin) (body-names (cdr f)))
                      (else '())))
              forms)))

;; assignments : (list-of datum) -> (list-of (symbol . boolean))
;; Each variable FORMS bind that a set! assigns, with whether anything
;; reads it, in the order they are bound. FORMS is a program's forms, or a
;; list holding one library form.
(define (assignments forms)
  (define made '())
  (define (bind names env)
    (let ((frame (map (lambda (n) (cons n (make-binding n #f #f))) names)))
      (set! made (append (reverse (map cdr frame)) made))
      (cons frame env)))
  (define (lookup name env)
    (and (pair? env)
         (let ((hit (assq name (car env))))
           (if hit (cdr hit) (lookup name (cdr env))))))
  (define (walk-each xs env self)
    (cond ((pair? xs) (walk (car xs) env self) (walk-each (cdr xs) env self))
          ((null? xs) #f)
          (else (walk xs env self))))
  (define (walk-body forms env self)
    (let ((env (bind (body-names forms) env)))
      (for-each (lambda (f) (walk-form f env self)) forms)))
  ;; A body's own forms, where each definition's name is already bound.
  (define (walk-form f env self)
    (cond ((not (pair? f)) (walk f env self))
          ((and (eq? (car f) 'define) (pair? (cdr f)))
           (if (pair? (cadr f))
               (walk-lambda (cdadr f) (cddr f) env)
               (walk-each (cddr f) env self)))
          ((eq? (car f) 'define-values) (walk-each (cddr f) env self))
          ((eq? (car f) 'begin) (for-each (lambda (g) (walk-form g env self)) (cdr f)))
          ((eq? (car f) 'import) #f)
          (else (walk f env self))))
  ;; A lambda's body runs later, so a read there sees the value stored.
  (define (walk-lambda formals body env)
    (walk-body body (bind (formals-names formals) env) #f))
  (define (walk-scope names body env self)
    (walk-body body (bind names env) self))
  (define (walk-quasi x env self depth)
    (cond ((vector? x) (walk-quasi (vector->list x) env self depth))
          ((not (pair? x)) #f)
          ((memq (car x) '(unquote unquote-splicing))
           (if (= depth 1)
               (walk-each (cdr x) env self)
               (walk-quasi (cdr x) env self (- depth 1))))
          ((eq? (car x) 'quasiquote) (walk-quasi (cdr x) env self (+ depth 1)))
          (else (walk-quasi (car x) env self depth)
                (walk-quasi (cdr x) env self depth))))
  ;; A template, read for the names it mentions and nothing more. A vector
  ;; there is data, as is a quoted part.
  (define (walk-names x env self)
    (cond ((symbol? x) (walk x env self))
          ((and (pair? x) (not (eq? (car x) 'quote)))
           (walk-names (car x) env self)
           (walk-names (cdr x) env self))
          (else #f)))
  (define (walk x env self)
    (cond
     ((symbol? x)
      (let ((b (lookup x env)))
        (when (and b (not (eq? b self))) (binding-read-set! b #t))))
     ((not (pair? x)) #f)
     (else
      (let ((rest (cdr x)))
        (case (car x)
          ((quote) #f)
          ((quasiquote) (walk-quasi (car rest) env self 1))
          ((set!)
           (let ((b (lookup (car rest) env)))
             (when b (binding-assigned-set! b #t))
             (walk-each (cdr rest) env (or b self))))
          ((lambda) (walk-lambda (car rest) (cdr rest) env))
          ((case-lambda)
           (for-each (lambda (clause) (walk-lambda (car clause) (cdr clause) env)) rest))
          ((let)
           (if (symbol? (car rest))
               (begin (walk-each (map cadr (cadr rest)) env self)
                      (walk-scope (map car (cadr rest)) (cddr rest)
                                  (bind (list (car rest)) env) self))
               (begin (walk-each (map cadr (car rest)) env self)
                      (walk-scope (map car (car rest)) (cdr rest) env self))))
          ((let* let*-values)
           (let each ((bindings (car rest)) (env env))
             (if (null? bindings)
                 (walk-body (cdr rest) env self)
                 (begin (walk-each (cdar bindings) env self)
                        (each (cdr bindings)
                              (bind (formals-names (caar bindings)) env))))))
          ((letrec letrec*)
           (let ((env (bind (map car (car rest)) env)))
             (walk-each (map cadr (car rest)) env self)
             (walk-body (cdr rest) env self)))
          ((let-values)
           (walk-each (map cadr (car rest)) env self)
           (walk-scope (apply append (map (lambda (b) (formals-names (car b))) (car rest)))
                       (cdr rest) env self))
          ((do)
           (walk-each (map cadr (car rest)) env self)
           (let ((env (bind (map car (car rest)) env)))
             (walk-each (map cddr (car rest)) env self)
             (walk-each (cadr rest) env self)
             (walk-body (cddr rest) env self)))
          ((guard)
           (walk-each (cdar rest) (bind (list (caar rest)) env) self)
           (walk-body (cdr rest) env self))
          ((case)
           (walk (car rest) env self)
           (for-each (lambda (clause) (walk-each (cdr clause) env self)) (cdr rest)))
          ((syntax-rules)
           (for-each (lambda (clause)
                       (walk-names (cdr clause)
                                   (bind (datum-symbols (car clause)) env) self))
                     (cdr rest)))
          ((define-record-type)
           (for-each (lambda (clause)
                       (when (and (pair? clause) (eq? (car clause) 'protocol))
                         (walk-each (cdr clause) env self)))
                     (cdr rest)))
          ;; A call, or a form this walk does not know. Its arguments are
          ;; read as a body, as a macro's body would be (with-mutex,
          ;; parameterize): a definition there binds for the rest of them.
          (else (walk (car x) env self)
                (walk-body rest env self)))))))
  (walk-body forms '() #f)
  (map (lambda (b) (cons (binding-name b) (binding-read b)))
       (filter binding-assigned (reverse made))))

;; unread-assignments : (list-of datum) -> (list-of symbol)
;; The variables FORMS bind that a set! assigns and nothing reads.
(define (unread-assignments forms)
  (map car (filter (lambda (a) (not (cdr a))) (assignments forms))))

;; file-findings : string -> list
;; (PATH name ...) for each variable the file at PATH assigns and never
;; reads, or (PATH (raised message irritants)) when reading or walking it
;; raised, so that a row that fails names the file either way.
(define (file-findings path)
  (cons path
        (guard (e (#t (list (list 'raised
                                  (if (message-condition? e) (condition-message e) e)
                                  (if (irritants-condition? e) (condition-irritants e) '())))))
          (unread-assignments (read-forms path)))))

(test-begin "unread-assignments")

;; First on seeded bodies: one case for each decision the walk makes, what
;; it must report and then what it must not.
(test-equal "a variable assigned and never read is flagged, and only that"
  '((x) () () (x) (x) () () (x) () (x) ())
  (map unread-assignments
       '(((define x 0) (set! x 1))
         ((define x 0) (set! x 1) (display x))
         ((define f 0) (set! f car) (f 1))
         ((define x 0) (set! x 1) (f 'x))
         ((define x 0) (set! x (+ x 1)))
         ((define x 0) (set! x (g (lambda () x))))
         ((define x 0) (set! x 1) (f `(a ,x)))
         ((define x 0) (set! x 1) (f `(a x)))
         ((define x 0) (set! x 1) (f `#(a ,x)))
         ((define x 0) (set! x 1) (import (only (lib) x)))
         ((set! y 1)))))

(test-equal "a read counts only for the binding in scope"
  '((x) (x) (x) (x) (x) (r) (a)
    (a) () (a) (loop) () (a) (a) (i) () (e) () (a) (a) () (x) (x))
  (map unread-assignments
       '(((define x 0) (define (f x) x) (set! x 1))
         ((define x 0) (display x) (let ((x 1)) (set! x 2)))
         ((define x 0) (set! x 1) (define (f) (define x 2) x))
         ((define x 0) (display x) (define (f) (begin (define x 1)) (set! x 2)))
         ((define x 0) (set! x 1) (define (f) (define-values (x y) (values 1 2)) x))
         ((define r 0) (set! r 1) (lambda (a . r) r))
         ((define a 0) (set! a 1) (case-lambda ((a) a)))
         ((define a 0) (set! a 1) (let* ((a 2) (b a)) b))
         ((define a 0) (set! a 1) (let ((a 2) (b a)) b))
         ((define a 0) (set! a 1) (letrec ((a (lambda () 2)) (b (lambda () (a)))) (b)))
         ((define loop 0) (set! loop 1) (let loop ((i 0)) (when (< i 1) (loop (+ i 1)))))
         ((define i 0) (set! i 1) (let lp ((i i)) i))
         ((define a 0) (set! a 1) (let-values (((a b) (values 1 2))) (+ a b)))
         ((define a 0) (set! a 1) (let*-values (((a) (values 2)) ((b) (values a))) b))
         ((define i 0) (set! i 1) (do ((i 0 (+ i 1))) ((= i 2)) (display i)))
         ((define i 0) (set! i 1) (do ((i i (+ i 1))) ((= i 2))))
         ((define e 0) (set! e 1) (guard (e (#t e)) (f)))
         ((define e 0) (set! e 1) (guard (e (#t 1)) e))
         ((define a 0) (set! a 1) (case k ((a) 1) (else 2)))
         ((define a 0) (set! a 1) (define-record-type r (fields a)))
         ((define a 0) (set! a 1) (define-record-type r (fields x) (protocol (lambda (new) (lambda () (new a))))))
         ((library (l) (export f) (import (rnrs)) (define x 0) (define (f) (set! x 1))))
         ((define x 0) (set! x 1) (with-mutex m (define x 2) x)))))

;; Templates hold ellipses and dotted tails no binding form's reading can
;; take apart, so a template is read for its names alone.
(test-equal "a syntax-rules template is read for the names it mentions, and nothing more"
  '((a) () () () () () (a) (x) (a))
  (map unread-assignments
       '(((define a 0) (set! a 1) (define-syntax m (syntax-rules () ((_ a) a))))
         ((define a 0) (set! a 1) (define-syntax m (syntax-rules () ((_ b) (f a b)))))
         ((define-syntax inc! (syntax-rules () ((_ v) (set! v (+ v 1))))))
         ((define-syntax m (syntax-rules () ((_) (begin (define n 0) (define (bump!) (set! n (+ n 1))))))))
         ((define a 0) (set! a 1) (define-syntax m (syntax-rules () ((_ (n v) ...) (let ((n v) ...) a)))))
         ((define a 0) (set! a 1) (define-syntax m (syntax-rules () ((_ x . r) (list a x . r)))))
         ((define a 0) (set! a 1) (define-syntax m (syntax-rules () ((_ b) (f 'a b)))))
         ((define x 0) (set! x 1) (define-syntax m (syntax-rules () ((_ #(x ...)) (f x ...)))))
         ((define a 0) (set! a 1) (define-syntax m (syntax-rules () ((_) #(a))))))))

(test-equal "the sources read are every .sps and .sls file directly under tests/, and no other file"
  '((#t #t #t #t) (#t #t #f #f #f #f))
  (list (map (lambda (path) (and (member path (test-sources)) #t))
             '("tests/test-tcp.sps" "tests/signal-child.sps" "tests/uv-testing.sls"
               "tests/test-unread-assignments.sps"))
        (map source-file? '("a.sps" "a.sls" ".#a.sps" "a.ss" "a.sps~" "sps"))))

(test-equal "a file the walk cannot read is named, with what was raised"
  '("tests/no-such-file.sps" raised)
  (let ((found (file-findings "tests/no-such-file.sps")))
    (list (car found) (car (cadr found)))))

;; The seed: a walk that read nothing, or saw no assignment, would pass the
;; row after it. test-process.sps assigns proc in two sections, and the
;; close-from-on-exit section's is read only by the on-exit callback inside
;; its own set!.
(test-equal "the walk sees both procs test-process.sps assigns, and that each is read"
  '((proc . #t) (proc . #t))
  (filter (lambda (a) (eq? (car a) 'proc))
          (assignments (read-forms "tests/test-process.sps"))))

(test-equal "no file directly under tests/ assigns a variable it never reads"
  '()
  (filter (lambda (found) (pair? (cdr found)))
          (map file-findings (test-sources))))

(test-end "unread-assignments")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
