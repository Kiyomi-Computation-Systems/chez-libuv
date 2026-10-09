#!r6rs
;;; SRFI-64 suite for rules about src/ that only a reading of the source can
;;; hold (#48's review).
;;;
;;; 1. A stream's data field has one writer. libuv's alloc callback, the
;;;    shim's chez_uv_alloc_cb, trusts data to point at the stream's uv_buf_t
;;;    descriptor, and hands libuv whatever it finds there as the buffer to
;;;    read into. A second writer could make that any memory at all: one that
;;;    pointed data at the handle itself passed every other suite, and libuv
;;;    was then told to read 4.3 GB into the handle. So uv-handle-set-data is
;;;    called from one place in src/.
;;;
;;; 2. Every entry native.sls takes from the shim is checked first. A shim
;;;    built from older sources must be refused by name, with
;;;    &uv-shim-unavailable, at whichever entry it lacks. So every
;;;    "chez_uv_..." name native.sls resolves goes through shim-procedure or
;;;    shim-entry, never a bare foreign-procedure or foreign-entry. The
;;;    fixtures in tests/test-shim-loading.sps can each reach one entry only:
;;;    with the other 46 resolved bare, every suite still passed.
;;;
;;; 3. No string crosses the FFI as a string argument. Chez encodes a
;;;    string, wstring or utf-N argument during the foreign call: it counts,
;;;    allocates and encodes, so a string changed after it was checked
;;;    reaches C changed, and an embedded NUL cuts it short (#51, #61). A
;;;    string crosses as its C string's bytes, passed as u8*.
;;;
;;; 4. No __collect_safe foreign call takes an argument in Scheme memory:
;;;    u8*, u16*, u32*, scheme-object or its alias ptr, ftype-pointer, or
;;;    ftype-scheme-object-pointer. A collect-safe call deactivates its
;;;    thread, so another thread's collection can move the object while C
;;;    reads it, and copies made that way were corrupted under a concurrent
;;;    collection (#35). Chez accepts these types there without a word. It
;;;    refuses a string argument there itself.
;;;
;;; 5. Every foreign call in src/ is one rules 3 and 4 read: a
;;;    foreign-procedure or shim-procedure form with its types spelt out. So
;;;    src/ defines no function ftype, which is a foreign call by another
;;;    spelling, and no ftype alias of ftype-pointer or
;;;    ftype-scheme-object-pointer, which carries an address under another
;;;    name. No macro but shim-procedure wraps foreign-procedure, and nothing
;;;    is imported from (chezscheme) renamed or prefixed. The type families
;;;    are complete for this Chez: every parameter type its expander accepts
;;;    is a string type, an address type, or a scalar this suite lists.
;;;
;;; 6. Process-wide state is shared by every loop's thread. ADR-0019 kept
;;;    the handle registry unlocked because only a loop's own thread uses
;;;    that loop's handles, but the registry is one table for every loop,
;;;    and two loops run on two threads at once corrupted it (#70). So this
;;;    suite lists, saying how threads share it, each variable a library in
;;;    src/ defines at its top level that the library assigns, changes in
;;;    place (passes first to a procedure whose name ends in !), or makes,
;;;    while its body runs, with a table, a box, a vector, a parameter, a
;;;    lock or a guardian, or as a closure over a variable it assigns. It
;;;    lists each static variable in the C shim too. A new one fails here
;;;    until it is listed. Each word for how threads share a variable is
;;;    checked against the source, by where the variable is written or by
;;;    what makes it. The registry and the orphan list are used only inside
;;;    with-registry-lock, whose bodies call only table operations and cons,
;;;    and registry-lock is named only there; the shim's counters change
;;;    only through count_add. What the scan cannot see: a structure changed
;;;    only through a procedure that takes it as an argument, or by a macro
;;;    whose name does not end in ! (.plans/registry-lock-mutation-log.md).
;;;
;;; 7. A loop's claim is taken and given back only through claim-loop! and
;;;    release-loop! (#78). set-loop-holder!, which sets the mark outright,
;;;    is for the tests' forgeries: src/ never calls it. A call there could
;;;    clear a claim another thread holds, as call-with-uv-loop's exit did
;;;    until #78's review, or leave one no call will give back.
;;;
;;; 8. A verb that checks its handle's owner on entry checks it again in
;;;    its step. Every verb entering through require-open-handle checks on
;;;    entry that this thread owns the loop, and an engine can suspend it
;;;    after that while the loop is handed to another thread. So its step
;;;    takes the handle's pointer from owned-handle-ptr, which checks again.
;;;    The stream verbs and the process kill and pid took open-handle-ptr
;;;    until #86, and a kill resumed after a handoff signalled its process
;;;    from a thread that no longer owned the loop. So this suite holds each
;;;    route from a handle record to its pointer to the definitions that
;;;    take it, named and counted, whether called or passed as a value:
;;;    - open-handle-ptr, which asks only whether the handle is open:
;;;      owned-handle-ptr, and three steps that need no owner check of their
;;;      own. begin-close! is uv-close!'s step, loop-thread-only by contract
;;;      and unchecked. uv-accept!'s step builds its client with
;;;      try-construct-handle, which checks the owner of the server's loop.
;;;      uv-spawn!'s step checks its loop's owner before stdio-refusal, and
;;;      every stdio handle is on that loop.
;;;    - The pointer field, handle-ptr: open-handle-ptr; handle-pointer, the
;;;      checked accessor outside a step; uv-async-send!, the one verb any
;;;      thread may call, inside its send fence; handle-in-loop-queue?,
;;;      which only compares it with what uv_walk reports; uv-accept!, for
;;;      the client its step has just made; and, in uv-spawn!'s step,
;;;      fill-stdio-containers!, for the stdio handles stdio-refusal has just
;;;      checked, and clean-up-failed-spawn!, for the process the step has
;;;      just made.
;;;    - handle-pointer: discard-failed-handle!, for a failed spawn's
;;;      process.
;;;    A definition with a parameter named handle-ptr shadows the field's
;;;    accessor for its whole body, and is not counted: the dispatchers and
;;;    native.sls name a raw pointer that way. What the scan cannot see: an
;;;    accessor imported under another name.
;;;
;;; 9. A refusal for the wrong thread names the owner its check compared
;;;    against (#102). An owner check that finds another thread owning the
;;;    loop answers an owner-mismatch holding that owner and the caller,
;;;    and &uv-wrong-thread is built from it. Until #102 the check answered
;;;    'wrong-thread, and the refusal read the owner again once the step
;;;    was over: a loop handed on and back to the caller in between was
;;;    named as owned by the very thread it refused. So this suite holds,
;;;    named and counted as rule 8's routes are:
;;;    - make-uv-wrong-thread to wrong-thread-refusal, which builds from an
;;;      owner-mismatch, and its definition in conditions.sls;
;;;    - the owner field's accessor, loop-owner-thread, to
;;;      loop-owner-mismatch, which reads it once, and the record that
;;;      defines it;
;;;    - symbol? to the definitions listed. A pointer check's answer, and
;;;      a step's, can be an owner-mismatch, which symbol? would take for a
;;;      pointer and hand to libuv, so they are tested with refused?. #109
;;;      turned eight steps' open-handle-ptr into owned-handle-ptr; a step
;;;      that kept its symbol? through such a change would pass every sweep
;;;      but the hand-back, and only for a verb an engine can stop between
;;;      its entry check and its step.
;;;    What the scan cannot see: a name imported under another one.
;;;
;;; PURE: it reads source files and imports no native code (PURE_TESTS).
;;; Rules 3 to 5 also ask Chez's expander about types, in forms it expands
;;; and never runs, so no entry is resolved.
(import (rnrs)
        (rnrs eval)
        (srfi :64)
        (only (chezscheme) expand oblist)
        (uv-source))

;; SRFI-64 sets no process exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The rule rows answer
;; what offends as their actual value, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; calls-of : symbol datum -> exact-nonnegative-integer
;; How many lists within X start with NAME: its call sites, since a
;; definition, an export or an import names it as a later element.
(define (calls-of name x)
  (if (pair? x)
      (+ (if (eq? (car x) name) 1 0)
         (let elements ((x x) (n 0))
           (if (pair? x)
               (elements (cdr x) (+ n (calls-of name (car x))))
               n)))
      0))

;; shim-name? : object -> boolean
(define (shim-name? x)
  (and (string? x)
       (>= (string-length x) 8)
       (string=? (substring x 0 8) "chez_uv_")))

;; unchecked-entries : datum -> (list-of string)
;; Every shim name within X that is not the entry of a (shim-procedure entry
;; ...) or (shim-entry entry) form.
(define (unchecked-entries x)
  (cond ((and (pair? x)
              (memq (car x) '(shim-procedure shim-entry))
              (pair? (cdr x))
              (shim-name? (cadr x)))
         (unchecked-in (cddr x)))
        ((pair? x) (unchecked-in x))
        ((shim-name? x) (list x))
        (else '())))

(define (unchecked-in xs)
  (let elements ((xs xs) (acc '()))
    (if (pair? xs)
        (elements (cdr xs) (append acc (unchecked-entries (car xs))))
        acc)))

(define (checked-entries x)
  (cond ((and (pair? x)
              (memq (car x) '(shim-procedure shim-entry))
              (pair? (cdr x))
              (shim-name? (cadr x)))
         1)
        ((pair? x)
         (let elements ((xs x) (n 0))
           (if (pair? xs) (elements (cdr xs) (+ n (checked-entries (car xs)))) n)))
        (else 0)))

;; --- foreign calls (rules 3 to 5) -----------------------------------------------
;; A foreign call is a (foreign-procedure convention ... entry (type ...)
;; result) form, or a shim-procedure form, which expands to one. A
;; foreign-callable form is not a call: C passes its arguments to Scheme.

;; Chez encodes these during the call.
(define string-types
  '(string wstring utf-8 utf-16 utf-16le utf-16be utf-32 utf-32le utf-32be))

;; These hand C the address of a Scheme object's own storage: a bytevector's,
;; any object's, or the one a pointer from make-ftype-scheme-object-pointer
;; points into, which an ftype-pointer parameter takes too.
(define address-types
  '(u8* u16* u32* scheme-object ptr ftype-scheme-object-pointer ftype-pointer))

;; Everything else this Chez accepts: values C receives as copies.
(define scalar-types
  '(boolean char double double-float fixnum float int
    integer-8 integer-16 integer-24 integer-32
    integer-40 integer-48 integer-56 integer-64
    iptr long long-long ptrdiff_t short single-float size_t ssize_t stdbool
    unsigned unsigned-8 unsigned-16 unsigned-24 unsigned-32
    unsigned-40 unsigned-48 unsigned-56 unsigned-64
    unsigned-int unsigned-long unsigned-long-long unsigned-short
    uptr void* wchar wchar_t))

;; mentions? : datum symbol -> boolean
;; Whether NAME occurs within X outside quoted data.
(define (mentions? x name)
  (cond ((eq? x name) #t)
        ((pair? x)
         (and (not (eq? (car x) 'quote))
              (or (mentions? (car x) name) (mentions? (cdr x) name))))
        (else #f)))

;; forms-headed : (list-of symbol) datum -> (list-of datum)
;; Every list within X, outside quoted data, whose head is one of HEADS.
(define (forms-headed heads x)
  (cond ((not (pair? x)) '())
        ((eq? (car x) 'quote) '())
        ((memq (car x) heads) (list x))
        (else
         (let elements ((xs x) (acc '()))
           (if (pair? xs)
               (elements (cdr xs) (append acc (forms-headed heads (car xs))))
               acc)))))

;; foreign-calls : datum -> (list-of datum)
;; Every foreign call within X.
(define (foreign-calls x)
  (forms-headed '(foreign-procedure shim-procedure) x))

;; call-parts : datum -> (list (list-of datum) datum (list-of datum))
;; A call's conventions, entry and parameter types. The types are its
;; next-to-last element, the entry the one before, and the conventions (such
;; as __collect_safe) everything between the keyword and the entry. A form
;; too short to have them has none.
(define (call-parts call)
  (let ((n (if (list? call) (length call) 0)))
    (if (< n 4)
        (list '() #f '())
        (let split ((xs (cdr call)) (k (- n 4)) (conventions '()))
          (if (zero? k)
              (list (reverse conventions)
                    (car xs)
                    (if (list? (cadr xs)) (cadr xs) '()))
              (split (cdr xs) (- k 1) (cons (car xs) conventions)))))))

(define (call-conventions call) (car (call-parts call)))
(define (call-entry call) (cadr (call-parts call)))
(define (call-types call) (caddr (call-parts call)))

;; types-in : (list-of symbol) datum -> (list-of symbol)
;; The parameter types of CALL that are in TYPES.
(define (types-in types call)
  (filter (lambda (t) (memq t types)) (call-types call)))

;; string-callers : (list-of datum) -> (list-of datum)
;; The entry of each call that takes a string type.
(define (string-callers calls)
  (map call-entry
       (filter (lambda (call) (pair? (types-in string-types call))) calls)))

(define (collect-safe? call)
  (and (memq '__collect_safe (call-conventions call)) #t))

;; collect-safe-address-callers : (list-of datum) -> (list-of datum)
;; (entry type ...) for each __collect_safe call that takes an address type,
;; naming those types.
(define (collect-safe-address-callers calls)
  (map (lambda (call) (cons (call-entry call) (types-in address-types call)))
       (filter (lambda (call)
                 (and (collect-safe? call) (pair? (types-in address-types call))))
               calls)))

;; hiding-ftypes : datum -> (list-of datum)
;; What each define-ftype within X names, when its definition is a function
;; type or mentions ftype-pointer or ftype-scheme-object-pointer.
(define (hiding-ftypes x)
  (map (lambda (form) (if (pair? (cdr form)) (cadr form) form))
       (filter (lambda (form)
                 (exists (lambda (t) (mentions? (cdr form) t))
                         '(function ftype-pointer ftype-scheme-object-pointer)))
               (forms-headed '(define-ftype) x))))

;; foreign-wrappers : datum -> (list-of datum)
;; What each macro definition within X names, when its definition mentions
;; foreign-procedure: a define-syntax's name, or the list of a let-syntax's.
(define (foreign-wrappers x)
  (map (lambda (form)
         (cond ((not (pair? (cdr form))) form)
               ((and (memq (car form) '(let-syntax letrec-syntax)) (list? (cadr form)))
                (map (lambda (b) (if (pair? b) (car b) b)) (cadr form)))
               (else (cadr form))))
       (filter (lambda (form) (mentions? (cdr form) 'foreign-procedure))
               (forms-headed '(define-syntax let-syntax letrec-syntax) x))))

;; renamed-chez-imports : datum -> (list-of datum)
;; Each rename or prefix import spec within the library form X that applies
;; to (chezscheme), under which foreign-procedure could arrive by another
;; name.
(define (renamed-chez-imports x)
  (let ((imports (filter (lambda (f) (and (pair? f) (eq? (car f) 'import)))
                         (if (list? x) x '()))))
    (filter (lambda (spec) (and (pair? (cdr spec)) (mentions? (cadr spec) 'chezscheme)))
            (apply append (map (lambda (i) (forms-headed '(rename prefix) (cdr i)))
                               imports)))))

;; One environment for every question put to the expander: a fresh one
;; costs a full copy of (chezscheme)'s bindings, kept for good.
(define chez-env (environment '(chezscheme)))

;; chez-verdict : (or symbol #f) symbol -> symbol
;; What this Chez's expander makes of a foreign call taking TYPE, under
;; CONVENTION or none: 'accepted; 'string-refused, its refusal of a string
;; argument under __collect_safe; or 'invalid. The call is expanded, never
;; run, so no entry is resolved.
(define (chez-verdict convention type)
  (guard (e ((and (message-condition? e)
                  (equal? (condition-message e)
                          "string argument not allowed with __collect_safe procedure"))
             'string-refused)
            (else 'invalid))
    (expand `(lambda ()
               (foreign-procedure ,@(if convention (list convention) '())
                                  "strlen" (,type) void))
            chez-env)
    'accepted))

;; symbols<? : symbol symbol -> boolean
(define (symbols<? a b) (string<? (symbol->string a) (symbol->string b)))

;; accepted-types : -> (list-of symbol)
;; Every symbol this Chez's expander accepts as a parameter type, in name
;; order. Chez names its types with symbols its own code interns, so the
;; oblist holds every one.
(define (accepted-types)
  (list-sort symbols<?
             (filter (lambda (s) (eq? (chez-verdict #f s) 'accepted)) (oblist))))

;; --- process-wide state (rule 6) ------------------------------------------------
;; A library's process-wide state is what its top-level definitions bind
;; and something later changes: a variable a form in the library sets, a
;; structure a form changes in place, or anything a top-level initializer
;; makes that changes in place.

(define mutable-makers
  '(make-eq-hashtable make-eqv-hashtable make-hashtable
    make-weak-eq-hashtable make-weak-eqv-hashtable make-weak-hashtable
    make-ephemeron-eq-hashtable make-ephemeron-eqv-hashtable
    make-ephemeron-hashtable
    box make-vector vector make-bytevector make-string make-fxvector
    make-flvector make-guardian
    make-thread-parameter make-parameter make-mutex make-condition))

;; library-body : datum -> (list-of datum)
;; The forms after a library form's name, export and import.
(define (library-body lib)
  (if (and (list? lib) (>= (length lib) 4)) (cddddr lib) '()))

;; library-exports : datum -> (list-of datum)
;; What a library form's export form names.
(define (library-exports lib)
  (if (and (list? lib) (>= (length lib) 3) (pair? (caddr lib))
           (eq? (car (caddr lib)) 'export))
      (cdr (caddr lib))
      '()))

;; top-level-forms : datum -> (list-of datum)
;; The library form LIB's body, with every top-level begin spliced in, as
;; the expander reads it.
(define (top-level-forms lib)
  (let splice ((forms (library-body lib)))
    (apply append
           (map (lambda (f)
                  (if (and (pair? f) (eq? (car f) 'begin) (list? f))
                      (splice (cdr f))
                      (list f)))
                forms))))

;; defined-name : datum -> (or symbol #f)
;; What a top-level (define x ...) or (define (f ...) ...) names.
(define (defined-name form)
  (and (pair? form) (eq? (car form) 'define) (pair? (cdr form))
       (let ((target (cadr form)))
         (cond ((symbol? target) target)
               ((and (pair? target) (symbol? (car target))) (car target))
               (else #f)))))

;; definition-names : datum -> (list-of symbol)
;; Every variable a top-level form defines: one for define, each one for
;; define-values.
(define (definition-names form)
  (cond ((defined-name form) => list)
        ((and (pair? form) (eq? (car form) 'define-values) (pair? (cdr form)))
         (let names ((t (cadr form)))
           (cond ((symbol? t) (list t))
                 ((pair? t) (append (names (car t)) (names (cdr t))))
                 (else '()))))
        (else '())))

;; initializer : datum -> (or datum #f)
;; The expression a top-level variable definition runs while its library's
;; body runs; #f for anything else, a procedure definition included.
(define (initializer form)
  (and (pair? form) (memq (car form) '(define define-values))
       (pair? (cdr form)) (pair? (cddr form))
       (or (eq? (car form) 'define-values) (symbol? (cadr form)))
       (caddr form)))

;; form-label : datum -> object
;; How a row names a top-level form: what it defines, else the form itself.
(define (form-label form)
  (let ((names (definition-names form)))
    (cond ((pair? names) (car names))
          ((and (pair? form) (memq (car form) '(define-syntax define-record-type))
                (pair? (cdr form)))
           (let ((t (cadr form))) (if (pair? t) (car t) t)))
          (else form))))

;; all-forms-where : (datum -> boolean) datum -> (list-of datum)
;; Every list within X, X included, that PRED accepts, outside quoted data.
(define (all-forms-where pred x)
  (cond ((not (pair? x)) '())
        ((eq? (car x) 'quote) '())
        (else
         (append (if (pred x) (list x) '())
                 (let elements ((xs x) (acc '()))
                   (if (pair? xs)
                       (elements (cdr xs) (append acc (all-forms-where pred (car xs))))
                       acc))))))

;; all-forms-headed : (list-of symbol) datum -> (list-of datum)
;; Every list within X, X included, headed by one of HEADS, outside quoted
;; data.
(define (all-forms-headed heads x)
  (all-forms-where (lambda (f) (and (memq (car f) heads) #t)) x))

;; mutator? : object -> boolean
;; A name for a procedure or macro that changes something in place: by
;; convention, one that ends in !.
(define (mutator? head)
  (and (symbol? head)
       (let ((s (symbol->string head)))
         (and (> (string-length s) 1)
              (char=? (string-ref s (- (string-length s) 1)) #\!)))))

;; assigned-names : datum -> (list-of symbol)
;; Each name X assigns: a set! target, or a fluid-let binding.
(define (assigned-names x)
  (append
   (map cadr (all-forms-where (lambda (f) (and (eq? (car f) 'set!) (pair? (cdr f))
                                               (symbol? (cadr f))))
                              x))
   (apply append
          (map (lambda (f)
                 (filter symbol? (map (lambda (b) (and (pair? b) (car b)))
                                      (if (list? (cadr f)) (cadr f) '()))))
               (all-forms-where (lambda (f) (and (eq? (car f) 'fluid-let) (pair? (cdr f))))
                                x)))))

;; changed-in-place : datum -> (list-of symbol)
;; Each name X passes first to a mutator, as in (hashtable-set! table ...)
;; or (set-car! pair ...): what it may change in place.
(define (changed-in-place x)
  (map cadr (all-forms-where (lambda (f) (and (mutator? (car f)) (not (eq? (car f) 'set!))
                                              (pair? (cdr f)) (symbol? (cadr f))))
                             x)))

;; procedure-form? : datum -> boolean
;; A lambda or case-lambda: a procedure, which nothing changes in place.
(define (procedure-form? x)
  (and (pair? x) (memq (car x) '(lambda case-lambda)) #t))

;; eager-forms : datum -> (list-of datum)
;; The lists within X that run when X runs: every one outside a lambda or
;; case-lambda body and outside quoted data.
(define (eager-forms x)
  (all-forms-where (lambda (f) #t)
                   (let strip ((x x))
                     (cond ((not (pair? x)) x)
                           ((memq (car x) '(quote lambda case-lambda)) #f)
                           (else (let elements ((xs x))
                                   (if (pair? xs)
                                       (cons (strip (car xs)) (elements (cdr xs)))
                                       xs)))))))

;; holds-state? : datum -> boolean
;; Whether a top-level initializer makes something that changes in place, or
;; a closure over something it changes: a maker in mutable-makers it calls
;; while its library's body runs, or a set! or fluid-let anywhere in it.
(define (holds-state? init)
  (or (exists (lambda (f) (and (memq (car f) mutable-makers) #t)) (eager-forms init))
      (pair? (all-forms-headed '(set! fluid-let) init))))

;; process-wide-state : datum -> (list-of symbol)
;; Each variable a top-level definition of the library form LIB binds that
;; a form in LIB assigns; or, unless it is a procedure, that a form in LIB
;; changes in place, or whose initializer holds state. A local variable
;; that shares a top-level name counts too, which errs only toward listing.
(define (process-wide-state lib)
  (let* ((forms (top-level-forms lib))
         (assigned (assigned-names forms))
         (changed (changed-in-place forms)))
    (apply append
           (map (lambda (form)
                  (let ((init (initializer form)))
                    (filter (lambda (name)
                              (or (and (memq name assigned) #t)
                                  (and init (not (procedure-form? init))
                                       (or (and (memq name changed) #t)
                                           (holds-state? init)))))
                            (definition-names form))))
                forms))))

;; made-by : symbol datum -> (or symbol #f)
;; The maker NAME's top-level definition in the library form LIB calls, when
;; it is (define NAME (maker ...)) for a maker in mutable-makers and nothing
;; in LIB changes NAME; else #f.
(define (made-by name lib)
  (let* ((forms (top-level-forms lib))
         (form (find (lambda (f) (and (eq? (defined-name f) name) (symbol? (cadr f))))
                     forms)))
    (and form
         (pair? (cddr form))
         (pair? (caddr form))
         (memq (car (caddr form)) mutable-makers)
         (not (memq name (assigned-names forms)))
         (not (memq name (changed-in-place forms)))
         (car (caddr form)))))

;; constant-datum? : datum -> boolean
;; A literal that nothing can change: a quoted symbol or (), a boolean, a
;; number or a character.
(define (constant-datum? x)
  (or (boolean? x) (number? x) (char? x)
      (and (pair? x) (eq? (car x) 'quote) (pair? (cdr x)) (null? (cddr x))
           (or (symbol? (cadr x)) (null? (cadr x))))))

;; per-thread? : symbol datum -> boolean
;; Whether NAME is (define NAME (make-thread-parameter C)) for a constant C,
;; and nothing changes it. A thread inherits its creator's current value, so
;; a value that changes in place would be one value for every thread.
(define (per-thread? name lib)
  (let ((form (find (lambda (f) (and (eq? (defined-name f) name) (symbol? (cadr f))))
                    (top-level-forms lib))))
    (and (eq? (made-by name lib) 'make-thread-parameter)
         (= (length (caddr form)) 2)
         (constant-datum? (cadr (caddr form))))))

;; mentions-outside? : (list-of symbol) (list-of symbol) datum -> boolean
;; Whether the form X names one of NAMES outside every form headed by one of
;; BARRIERS. Only a form's head makes it one of those: a barrier's name
;; quoted among a call's arguments does not. Vectors are read too.
(define (mentions-outside? names barriers x)
  (cond ((symbol? x) (and (memq x names) #t))
        ((vector? x) (exists (lambda (e) (mentions-outside? names barriers e))
                             (vector->list x)))
        ((pair? x)
         (and (not (memq (car x) barriers))
              (let elements ((xs x))
                (cond ((pair? xs)
                       (or (mentions-outside? names barriers (car xs)) (elements (cdr xs))))
                      (else (mentions-outside? names barriers xs))))))
        (else #f)))

;; unlocked-mention? : (list-of symbol) datum -> boolean
;; Whether the form X names one of NAMES outside quoted data and outside
;; every with-registry-lock form.
(define (unlocked-mention? names x)
  (mentions-outside? names '(quote with-registry-lock) x))

;; unlocked-uses : (list-of symbol) datum -> (list-of object)
;; The label of each top-level form of the library form LIB that names one
;; of NAMES outside with-registry-lock: definitions, macros, record types
;; and expressions alike. A define or define-syntax is read past the name it
;; defines, so the definition of one of NAMES is not a use.
(define (unlocked-uses names lib)
  (map form-label
       (filter (lambda (f)
                 (unlocked-mention? names
                                    (if (and (pair? f) (memq (car f) '(define define-syntax))
                                             (pair? (cdr f)))
                                        (cddr f)
                                        f)))
               (top-level-forms lib))))

;; The operations a with-registry-lock body may call: table operations and
;; a cons, none of which raises or waits for the pointers and entries the
;; registry holds. A table operation alone may take the table.
(define lock-table-operations
  '(hashtable-ref hashtable-set! hashtable-delete! hashtable-contains?
    hashtable-size hashtable-entries))

;; lock-body-offenses : datum -> (list-of datum)
;; Each subform of a with-registry-lock body within X that such a body may
;; not hold: a call of anything but a table operation or cons, a lambda
;; (but call-with-values's producer), or the registry anywhere but as a
;; table operation's table. Each could raise or wait inside the lock, or
;; let the table out of it.
(define (lock-body-offenses x)
  (define (body-offenses x)
    (cond ((eq? x 'registry) (list x))
          ((not (pair? x)) '())
          (else
           (let ((head (car x)) (args (cdr x)))
             (cond ((eq? head 'quote) '())
                   ((not (list? args)) (list x))
                   ((memq head '(if when unless begin))
                    (apply append (map body-offenses args)))
                   ((memq head '(let let*))
                    (if (and (pair? args) (list? (car args))
                             (for-all (lambda (b) (and (list? b) (= (length b) 2) (symbol? (car b))))
                                      (car args)))
                        (append (apply append (map (lambda (b) (body-offenses (cadr b))) (car args)))
                                (apply append (map body-offenses (cdr args))))
                        (list x)))
                   ((eq? head 'set!)
                    (if (and (= (length args) 2) (symbol? (car args)))
                        (body-offenses (cadr args))
                        (list x)))
                   ((eq? head 'call-with-values)
                    (let ((producer (and (= (length args) 2) (car args))))
                      (if (and (list? producer) (>= (length producer) 3)
                               (eq? (car producer) 'lambda) (null? (cadr producer))
                               (memq (cadr args) (cons 'cons lock-table-operations)))
                          (apply append (map body-offenses (cddr producer)))
                          (list x))))
                   ((memq head lock-table-operations)
                    (apply append
                           (map body-offenses
                                (if (and (pair? args) (eq? (car args) 'registry)) (cdr args) args))))
                   ((eq? head 'cons) (apply append (map body-offenses args)))
                   (else (list x)))))))
  (apply append
         (map (lambda (lock-form) (apply append (map body-offenses (cdr lock-form))))
              (all-forms-headed '(with-registry-lock) x))))

;; How each piece of process-wide state in src/ is shared by threads, and
;; what the rows below check of each:
;; - library-init: written only by an installer, or by a top-level
;;   initializer, while a library's body runs, and only read after. Chez
;;   runs a library's body before a program that references the library, or
;;   at its first reference through eval. Each installer is called only from
;;   a top-level initializer, which a row checks;
;; - init-lock: set only while native.sls's init-mutex is held, or by
;;   constants-init!, which is called only under it, which a row checks;
;; - registry-lock: used only inside with-registry-lock, which a row checks;
;; - thread-local: a thread parameter made with a constant, so each thread
;;   has a value of its own, which a row checks;
;; - lock: a mutex, made once and never set, which a row checks.
(define state-classes '(library-init init-lock registry-lock thread-local lock))

(define shared-state
  '(("src/libuv/private/constants.sls"
     (snapshot init-lock) (lookup init-lock) (init-count init-lock)
     (errno-value-table init-lock) (errno-symbol-table init-lock)
     (errno-name-list init-lock))
    ("src/libuv/private/handles.sls"
     (registry registry-lock) (registry-lock lock)
     (orphan-events registry-lock) (walk-query-cell thread-local)
     (close-handle-proc library-init) (close-handle-installed library-init)
     (dispatch-table library-init) (installed-dispatch-names library-init))
    ("src/libuv/private/native.sls"
     (dispatchers library-init) (dispatchers-installed library-init)
     (init-mutex lock) (initialized? init-lock) (init-count init-lock))))

;; The procedures that may write a library-init variable, each called only
;; while a library's body runs.
(define installers
  '(install-close-handle! install-dispatch-procedure! install-callback-dispatchers!))

;; unknown-classes : (list-of (string . (list-of (symbol . list)))) -> (list-of list)
;; Each listed variable whose class is not one of state-classes.
(define (unknown-classes listing)
  (filter (lambda (v) (not (and (pair? (cdr v)) (memq (cadr v) state-classes))))
          (apply append (map cdr listing))))

;; sites : (datum -> boolean) datum -> (list-of (list object boolean boolean))
;; For each list within the library form LIB that PRED accepts: the label of
;; the top-level form it sits in, whether it sits inside (with-mutex
;; init-mutex ...), and whether that top-level form runs while the library's
;; body runs (a variable definition or an expression, not a procedure or a
;; macro). A define or define-syntax is read past the name it defines, so a
;; procedure's own header is not a call of it.
(define (sites pred lib)
  (apply append
         (map (lambda (form)
                (let ((eager (not (and (pair? form)
                                       (or (memq (car form) '(define-syntax define-record-type))
                                           (and (eq? (car form) 'define) (pair? (cdr form))
                                                (pair? (cadr form))))))))
                  (let walk ((x (if (and (pair? form) (memq (car form) '(define define-syntax))
                                         (pair? (cdr form)))
                                    (cddr form)
                                    form))
                             (locked #f))
                    (cond ((not (pair? x)) '())
                          ((eq? (car x) 'quote) '())
                          (else
                           (let ((locked (or locked
                                             (and (eq? (car x) 'with-mutex) (pair? (cdr x))
                                                  (eq? (cadr x) 'init-mutex)))))
                             (append (if (pred x) (list (list (form-label form) locked eager)) '())
                                     (let elements ((xs x) (acc '()))
                                       (if (pair? xs)
                                           (elements (cdr xs) (append acc (walk (car xs) locked)))
                                           acc)))))))))
              (top-level-forms lib))))

;; writes-of : symbol -> (datum -> boolean)
;; Accepts a form that writes NAME: a set! of it, or a mutator call with it
;; as the first argument.
(define (writes-of name)
  (lambda (f)
    (and (pair? (cdr f)) (eq? (cadr f) name)
         (or (eq? (car f) 'set!) (mutator? (car f))))))

;; calls-to : (list-of symbol) -> (datum -> boolean)
(define (calls-to names)
  (lambda (f) (and (memq (car f) names) #t)))

;; init-lock-offenses : (list-of (string . datum)) -> (list-of list)
;; Each write of an init-lock variable outside native.sls's init-mutex and
;; outside constants-init!, and each call of constants-init! outside the
;; mutex.
(define (init-lock-offenses libraries listing)
  (append
   (apply append
          (map (lambda (lib)
                 (let ((form (cond ((assoc (car lib) libraries) => cdr) (else #f))))
                   (apply append
                          (map (lambda (v)
                                 (if (and form (eq? (cadr v) 'init-lock))
                                     (map (lambda (s) (list (car lib) (car v) (car s)))
                                          (filter (lambda (s) (not (or (cadr s)
                                                                       (eq? (car s) 'constants-init!))))
                                                  (sites (writes-of (car v)) form)))
                                     '()))
                               (cdr lib)))))
               listing))
   (apply append
          (map (lambda (e)
                 (map (lambda (s) (list (car e) 'constants-init! (car s)))
                      (filter (lambda (s) (not (cadr s)))
                              (sites (calls-to '(constants-init!)) (cdr e)))))
               libraries))))

;; library-init-offenses : (list-of (string . datum)) -> (list-of list)
;; Each write of a library-init variable outside an installer and outside a
;; top-level initializer, and each call of an installer outside a top-level
;; initializer.
(define (library-init-offenses libraries listing)
  (append
   (apply append
          (map (lambda (lib)
                 (let ((form (cond ((assoc (car lib) libraries) => cdr) (else #f))))
                   (apply append
                          (map (lambda (v)
                                 (if (and form (eq? (cadr v) 'library-init))
                                     (map (lambda (s) (list (car lib) (car v) (car s)))
                                          (filter (lambda (s) (not (or (caddr s)
                                                                       (memq (car s) installers))))
                                                  (sites (writes-of (car v)) form)))
                                     '()))
                               (cdr lib)))))
               listing))
   (apply append
          (map (lambda (e)
                 (map (lambda (s) (list (car e) 'installer-called-in (car s)))
                      (filter (lambda (s) (not (caddr s)))
                              (sites (calls-to installers) (cdr e)))))
               libraries))))

;; --- the C shim's state (rule 6) -------------------------------------------------
;; The shim's static variables are process-wide too: each loop's thread
;; reaches them through the shim.

;; text-lines : string -> (list-of string)
(define (text-lines text)
  (let split ((start 0) (i 0) (acc '()))
    (cond ((= i (string-length text))
           (reverse (if (< start i) (cons (substring text start i) acc) acc)))
          ((char=? (string-ref text i) #\newline)
           (split (+ i 1) (+ i 1) (cons (substring text start i) acc)))
          (else (split start (+ i 1) acc)))))

;; c-word-char? : char -> boolean
(define (c-word-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

;; string-index-of : string string integer -> (or integer #f)
(define (string-index-of s pat from)
  (let ((n (string-length s)) (m (string-length pat)))
    (let scan ((i from))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) pat) i)
            (else (scan (+ i 1)))))))

;; trim-left : string -> string
(define (trim-left s)
  (let skip ((i 0))
    (if (and (< i (string-length s)) (char-whitespace? (string-ref s i)))
        (skip (+ i 1))
        (substring s i (string-length s)))))

;; static-objects : (list-of string) -> (list-of symbol)
;; The name each line of C defines with `static`, when it defines a
;; variable: not a const, and not a function.
(define (static-objects lines)
  (filter symbol?
          (map (lambda (line)
                 (let ((t (trim-left line)))
                   (and (>= (string-length t) 7)
                        (string=? (substring t 0 7) "static ")
                        (not (string-index-of t "const" 0))
                        (not (string-index-of t "(" 0))
                        (let* ((stop (or (string-index-of t "=" 0) (string-index-of t ";" 0)
                                         (string-length t)))
                               (head (substring t 0 stop))
                               (end (let back ((i (string-length head)))
                                      (if (and (> i 0) (not (c-word-char? (string-ref head (- i 1)))))
                                          (back (- i 1))
                                          i)))
                               (start (let back ((i end))
                                        (if (and (> i 0) (c-word-char? (string-ref head (- i 1))))
                                            (back (- i 1))
                                            i))))
                          (and (< start end) (string->symbol (substring head start end)))))))
               lines)))

;; bare-counter-uses : (list-of symbol) (list-of string) -> (list-of list)
;; Each use of one of the counters NAMES in the C LINES that is neither its
;; definition nor an argument &NAME to count_add or count_read: a use that
;; could read or write the counter without an atomic operation.
(define (bare-counter-uses names lines)
  (let each-line ((lines lines) (number 1) (acc '()))
    (if (null? lines)
        (reverse acc)
        (let ((line (car lines)))
          (each-line
           (cdr lines) (+ number 1)
           (append
            (reverse
             (filter (lambda (x) x)
                     (map (lambda (name)
                            (let ((s (symbol->string name)))
                              (let scan ((from 0) (found #f))
                                (let ((i (string-index-of line s from)))
                                  (cond ((not i) found)
                                        ((or (and (> i 0) (c-word-char? (string-ref line (- i 1))))
                                             (and (< (+ i (string-length s)) (string-length line))
                                                  (c-word-char? (string-ref line (+ i (string-length s))))))
                                         (scan (+ i 1) found))
                                        ((or (and (>= i 11) (string=? (substring line (- i 11) i) "count_add(&"))
                                             (and (>= i 12) (string=? (substring line (- i 12) i) "count_read(&"))
                                             (let ((t (trim-left line)))
                                               (and (>= (string-length t) 7)
                                                    (string=? (substring t 0 7) "static "))))
                                         (scan (+ i 1) found))
                                        (else (scan (+ i 1) (list number name))))))))
                          names)))
            acc))))))

;; Every static variable the shim defines: the debug counters, each updated
;; only through count_add and read only through count_read, which are
;; atomic. Pinned, so that the row cannot pass by reading nothing.
(define shim-counters
  '(live_loop live_tcp live_timer live_write_req live_connect_req
    live_getaddrinfo_req live_getnameinfo_req live_read_buffer live_pipe
    live_process live_spawn_options live_signal live_async live_block))

(test-begin "source-rules")

;; --- the checkers, on seeded forms -------------------------------------------
;; A checker that never reported anything would pass every row on the real
;; tree below, so first it must see each of these.

(test-equal "a call counts, and so does a call nested in another"
  2 (calls-of 'f '(define (g) (f 1) (h (f 2)))))

(test-equal "a definition, an export and an import are not calls"
  0 (calls-of 'f '((define f (lambda () 1)) (export f g) (only (lib) f))))

(test-equal "an entry resolved bare is unchecked, whichever way it is resolved"
  '("chez_uv_zero" "chez_uv_alloc_cb")
  (unchecked-entries '((define z (foreign-procedure "chez_uv_zero" (uptr) void))
                       (define a (foreign-entry "chez_uv_alloc_cb")))))

(test-equal "an entry resolved through shim-procedure or shim-entry is checked"
  '(() 2)
  (let ((forms '((define z (shim-procedure "chez_uv_zero" (uptr size_t) void))
                 (define a (shim-entry "chez_uv_alloc_cb")))))
    (list (unchecked-entries forms) (checked-entries forms))))

;; Each type is written out here rather than taken from string-types, so a
;; type dropped from that list fails this row.
(test-equal "the string rule finds each string type in either kind of call, and only as a parameter"
  '("t_string" "t_wstring" "t_utf_8" "t_utf_16" "t_utf_16le" "t_utf_16be"
    "t_utf_32" "t_utf_32le" "t_utf_32be" "chez_uv_t_shim")
  (string-callers
   (foreign-calls
    '((define a (foreign-procedure "t_string" (uptr string) int))
      (define b (foreign-procedure "t_wstring" (wstring) int))
      (define c (foreign-procedure "t_utf_8" (utf-8) int))
      (define d (foreign-procedure "t_utf_16" (utf-16) int))
      (define e (foreign-procedure "t_utf_16le" (utf-16le) int))
      (define f (foreign-procedure "t_utf_16be" (utf-16be) int))
      (define g (foreign-procedure "t_utf_32" (utf-32) int))
      (define h (foreign-procedure "t_utf_32le" (utf-32le) int))
      (define i (foreign-procedure "t_utf_32be" (utf-32be int) int))
      (define j (shim-procedure "chez_uv_t_shim" (string uptr) int))
      ;; A string result comes from C, and a callable's arguments too.
      (define k (foreign-procedure "t_result" (uptr) string))
      (define l (foreign-callable (lambda (s) s) (string) void))
      (define m (foreign-procedure "t_bytes" (uptr u8* int) int))
      ;; Quoted data is not a call.
      (define n '(foreign-procedure "t_quoted" (string) int))))))

(test-equal "the collect-safe rule finds each address type, after another convention too, and only in a __collect_safe call"
  '(("t_u8" u8*) ("t_u16" u16*) ("t_u32" u32*) ("t_object" scheme-object)
    ("t_ptr" ptr) ("t_sop" ftype-scheme-object-pointer) ("t_fp" ftype-pointer)
    ("t_two" u8*))
  (collect-safe-address-callers
   (foreign-calls
    '((define a (foreign-procedure __collect_safe "t_u8" (uptr u8*) int))
      (define b (foreign-procedure __collect_safe "t_u16" (u16*) int))
      (define c (foreign-procedure __collect_safe "t_u32" (u32*) int))
      (define d (foreign-procedure __collect_safe "t_object" (scheme-object) int))
      (define e (foreign-procedure __collect_safe "t_ptr" (ptr) int))
      (define f (foreign-procedure __collect_safe "t_sop"
                                   (ftype-scheme-object-pointer) int))
      (define f2 (foreign-procedure __collect_safe "t_fp" (ftype-pointer) int))
      (define g (foreign-procedure (__varargs_after 1) __collect_safe "t_two"
                                   (u8* int) int))
      ;; A plain call keeps its thread active, scalars hold no address, and
      ;; a callable's arguments come from C.
      (define h (foreign-procedure "t_plain" (u8* scheme-object ptr) int))
      (define i (foreign-procedure __collect_safe "t_scalars" (uptr int) int))
      (define j (foreign-callable __collect_safe (lambda (p) p) (u8*) void))))))

(test-equal "rule 5 finds a function ftype and an alias of either pointer type, alone or among several, and only those"
  '(a b c (d (function __collect_safe (u8*) void)))
  (hiding-ftypes
   '((define-ftype a (function (u8* int) int))
     (define-ftype b ftype-pointer)
     (define-ftype c (struct (p ftype-scheme-object-pointer)))
     (define-ftype (d (function __collect_safe (u8*) void)) (e (* f)))
     (define-ftype f (struct (base uptr) (len size_t)))
     (define g '(define-ftype h ftype-pointer)))))

(test-equal "rule 5 finds each macro that wraps foreign-procedure, and only those"
  '(shim-procedure wrapped (local-wrapper))
  (foreign-wrappers
   '((define-syntax shim-procedure
       (syntax-rules ()
         ((_ entry (arg ...) result)
          (foreign-procedure (shim-entry entry) (arg ...) result))))
     (define-syntax wrapped
       (syntax-rules ()
         ((_ e t r) (foreign-procedure __collect_safe e t r))))
     (define-syntax unrelated (syntax-rules () ((_ x) (list x))))
     (define (f)
       (let-syntax ((local-wrapper
                     (syntax-rules () ((_ e) (foreign-procedure e () void)))))
         (local-wrapper "x"))))))

(test-equal "rule 5 finds a (chezscheme) import renamed or prefixed, however nested, and only those"
  '((rename (chezscheme) (foreign-procedure fp))
    (prefix (only (chezscheme) foreign-procedure) c:))
  (renamed-chez-imports
   '(library (seeded)
      (export)
      (import (rnrs)
              (rename (chezscheme) (foreign-procedure fp))
              (prefix (only (chezscheme) foreign-procedure) c:)
              (only (chezscheme) foreign-procedure)
              (prefix (rnrs) r:))
      (define rename 1))))

(test-equal "rule 6 finds each top-level variable its library changes, or whose initializer makes something that changes, and only those"
  '(counter table cell param lock flag nested weak guardian next-id! pair rec fluid
    both-a both-b spliced)
  (process-wide-state
   '(library (seeded)
      (export)
      (import (rnrs))
      (define counter 0)
      (define table (make-eqv-hashtable))
      (define cell (box 0))
      (define param (make-thread-parameter #f))
      (define lock (make-mutex))
      (define flag #f)
      (define nested (let ((t (make-eqv-hashtable))) t))
      (define weak (make-weak-hashtable equal-hash equal?))
      (define guardian (make-guardian))
      (define next-id! (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
      (define pair (list 0 0))
      (define rec (make-point 0 0))
      (define fluid 0)
      (define-values (both-a both-b) (values (make-eqv-hashtable) 1))
      (begin (define spliced (make-eqv-hashtable)))
      (define constant 1)
      (define quoted '(set! constant 2))
      (define fresh (lambda () (make-eqv-hashtable)))
      (define maker (let () (lambda () (make-eqv-hashtable))))
      (define (made) (make-eqv-hashtable))
      (define (bump!) (set! counter (+ counter 1)))
      (define (local) (let ((n 0)) (set! n 1) n))
      (define (raise-flag!) (set! flag #t))
      (define (touch!) (set-car! pair 1) (set-point-x! rec 1))
      (define (dynamic) (fluid-let ((fluid 1)) fluid)))))

(test-equal "rule 6 sees a set! inside another set!'s value"
  '(outer inner)
  (process-wide-state
   '(library (seeded)
      (export)
      (import (rnrs))
      (define outer #f)
      (define inner #f)
      (define (f) (set! outer (begin (set! inner 1) 2))))))

(test-equal "rule 6 reads a variable's maker only when it is made once and never set"
  '(make-thread-parameter make-mutex #f #f #f)
  (let ((lib '(library (seeded)
                (export)
                (import (rnrs))
                (define cell (make-thread-parameter '()))
                (define lock (make-mutex))
                (define reset (make-thread-parameter '()))
                (define plain '())
                (define (f) (set! reset (make-thread-parameter 1))))))
    (map (lambda (name) (made-by name lib)) '(cell lock reset plain missing))))

(test-equal "rule 6 counts a thread parameter as one value for each thread only when it starts from a constant"
  '(#t #t #f #f)
  (let ((lib '(library (seeded)
                (export)
                (import (rnrs))
                (define cell (make-thread-parameter '()))
                (define flag (make-thread-parameter #f))
                (define shared (make-thread-parameter (make-eqv-hashtable)))
                (define filtered (make-thread-parameter '() list)))))
    (map (lambda (name) (per-thread? name lib)) '(cell flag shared filtered))))

(test-equal "rule 6 finds a use of a locked variable outside with-registry-lock, in any top-level form, and only those"
  '(bare in-macro after-lock mentions-the-keyword in-record spliced-use in-vector both-x
    (hashtable-clear! registry))
  (unlocked-uses
   '(registry orphans)
   '(library (seeded)
      (export)
      (import (rnrs))
      (define registry (make-eqv-hashtable))
      (define orphans '())
      (define (locked p) (with-registry-lock (hashtable-ref registry p #f)))
      (define (bare p) (hashtable-ref registry p #f))
      (define-syntax in-macro
        (syntax-rules () ((_ p) (hashtable-ref registry p #f))))
      (define (after-lock e)
        (with-registry-lock 1)
        (set! orphans (cons e orphans)))
      (define (quoted) '(registry orphans))
      (define (mentions-the-keyword p)
        (list 'with-registry-lock (hashtable-ref registry p #f)))
      (define-record-type in-record
        (fields p)
        (protocol (lambda (new) (lambda (p) (hashtable-set! registry p #t) (new p)))))
      (begin (define (spliced-use p) (hashtable-delete! registry p)))
      (define (in-vector) `#(,(hashtable-size registry)))
      (define-values (both-x both-y) (values (hashtable-size registry) 0))
      (hashtable-clear! registry))))

(test-equal "rule 6 finds each with-registry-lock body that calls anything but a table operation or cons, makes a procedure, or lets the table out, and only those"
  '((registry-entry-loop (hashtable-ref registry p #f))
    registry
    (lambda () (hashtable-ref registry p #f))
    (uv-cancel p))
  (lock-body-offenses
   '(library (seeded)
      (export)
      (import (rnrs))
      (define (ref p) (with-registry-lock (hashtable-ref registry p #f)))
      (define (add! p e)
        (with-registry-lock
         (if (hashtable-contains? registry p)
             'taken
             (begin (hashtable-set! registry p e) 'added))))
      (define (take! p)
        (with-registry-lock
         (let ((e (hashtable-ref registry p #f)))
           (when e (hashtable-delete! registry p))
           e)))
      (define (all) (with-registry-lock (hashtable-entries registry)))
      (define (both)
        (with-registry-lock
         (call-with-values (lambda () (hashtable-entries registry)) cons)))
      (define (note! e) (with-registry-lock (set! orphans (cons e orphans))))
      (define (raising p)
        (with-registry-lock (registry-entry-loop (hashtable-ref registry p #f))))
      (define (table-out) (with-registry-lock registry))
      (define (closure-out p) (with-registry-lock (lambda () (hashtable-ref registry p #f))))
      (define (native p) (with-registry-lock (uv-cancel p))))))

(test-equal "rule 6 finds a listed variable with no word, or a word not the suite's"
  '((spelled init-locks) (bare))
  (unknown-classes '(("seeded.sls" (fine library-init) (spelled init-locks) (bare)))))

(test-equal "rule 6 finds each init-lock write outside init-mutex and constants-init!, and each call of constants-init! outside init-mutex"
  '(("seeded.sls" count late) ("seeded.sls" constants-init! early))
  (let ((lib '(library (seeded)
                (export)
                (import (rnrs))
                (define init-mutex (make-mutex))
                (define count 0)
                (define (init!)
                  (with-mutex init-mutex (set! count (+ count 1)) (constants-init! 1)))
                (define (constants-init! x) (set! count x))
                (define (late) (set! count 0))
                (define (early) (constants-init! 2)))))
    (init-lock-offenses (list (cons "seeded.sls" lib))
                        '(("seeded.sls" (count init-lock))))))

(test-equal "rule 6 finds each library-init write outside an installer and a top-level initializer, and each installer called from a procedure"
  '(("seeded.sls" table later) ("seeded.sls" installer-called-in lazy))
  (let ((lib '(library (seeded)
                (export)
                (import (rnrs))
                (define table (let ((t (make-eq-hashtable))) (hashtable-set! t 'a #f) t))
                (define (install-dispatch-procedure! name proc)
                  (hashtable-set! table name proc))
                (define installed (install-dispatch-procedure! 'a car))
                (define (later) (hashtable-set! table 'b cdr))
                (define (lazy) (install-dispatch-procedure! 'c cons)))))
    (library-init-offenses (list (cons "seeded.sls" lib))
                           '(("seeded.sls" (table library-init))))))

(test-equal "rule 6 reads a static variable in C, and not a static constant or a function"
  '(count table_size)
  (static-objects '("static long count = 0;"
                    "static const char *names[] = {"
                    "static void bump(long *c) {"
                    "  static int table_size;"
                    "int global;")))

(test-equal "rule 6 finds a counter used outside count_add and count_read"
  '((3 live_a) (4 live_b))
  (bare-counter-uses '(live_a live_b)
                     '("static long live_a = 0;"
                       "void a_new(void) { count_add(&live_a, 1); }"
                       "void a_bad(void) { live_a += 1; }"
                       "long b_read(void) { return live_b; }"
                       "long chez_uv_live_a(void) { return count_read(&live_a); }")))

;; What Chez makes of a type decides which rule it needs, so the lists are
;; checked against this Chez. A misspelt type is 'invalid here.
(test-equal "the verdict tells Chez's answers apart: a scalar is accepted, an unknown type is invalid"
  '(accepted accepted invalid)
  (list (chez-verdict #f 'uptr) (chez-verdict '__collect_safe 'uptr)
        (chez-verdict #f 'not-a-type)))

(test-equal "Chez encodes each string type: it accepts each in a plain call, and refuses each under __collect_safe as a string"
  (map (lambda (t) (list t 'accepted 'string-refused)) string-types)
  (map (lambda (t) (list t (chez-verdict #f t) (chez-verdict '__collect_safe t)))
       string-types))

(test-equal "Chez accepts each address type under __collect_safe, so only rule 4 stops one there"
  (map (lambda (t) (list t 'accepted)) address-types)
  (map (lambda (t) (list t (chez-verdict '__collect_safe t))) address-types))

;; Complete, both ways: a type a later Chez adds fails here until it joins a
;; family, and so does a listed type this Chez does not accept.
(test-equal "every parameter type this Chez accepts is in one of the three families, and each type listed is one it accepts"
  '(unlisted () not-accepted ())
  (let ((accepted (accepted-types))
        (listed (append string-types address-types scalar-types)))
    (list 'unlisted (filter (lambda (t) (not (memq t listed))) accepted)
          'not-accepted (filter (lambda (t) (not (memq t accepted))) listed))))

;; --- the real tree ------------------------------------------------------------
;; Run from the repo root, as `make test` does.
(define libraries (src-libraries))

(define native-form
  (let ((e (assoc "src/libuv/private/native.sls" libraries)))
    (and e (cdr e))))

;; Live: an empty scan, from the wrong directory, would pass the rules.
(test-equal "the scan read native.sls and handles.sls"
  '(native handles)
  (list (if native-form 'native 'no-native)
        (if (assoc "src/libuv/private/handles.sls" libraries) 'handles 'no-handles)))

(test-equal "a stream's data has one writer: uv-handle-set-data is called once in src/, in handles.sls"
  '(("src/libuv/private/handles.sls" . 1))
  (filter (lambda (e) (positive? (cdr e)))
          (map (lambda (e) (cons (car e) (calls-of 'uv-handle-set-data (cdr e))))
               libraries)))

;; calls-in-src : symbol -> (listof (cons string exact-positive-integer))
;; Each library in src/ that calls NAME, with how many times.
(define (calls-in-src name)
  (filter (lambda (e) (positive? (cdr e)))
          (map (lambda (e) (cons (car e) (calls-of name (cdr e)))) libraries)))

;; Live: the scan finds the claim's own release, which loop.sls calls.
(test-equal "rule 7 is live: the scan finds loop.sls giving claims back with release-loop!"
  'found
  (if (assoc "src/libuv/loop.sls" (calls-in-src 'release-loop!))
      'found
      (calls-in-src 'release-loop!)))

;; The one list headed by set-loop-holder! is its definition's own header.
(test-equal "rule 7: no library in src/ sets a loop's claim outright with set-loop-holder!"
  '(("src/libuv/private/handles.sls" . 1))
  (calls-in-src 'set-loop-holder!))

;; mentions-of : symbol datum -> exact-nonnegative-integer
;; How many times NAME occurs anywhere within X: called, or passed as a
;; value, as loop.sls passes open-loop-ptr to its loop-call macro.
(define (mentions-of name x)
  (cond ((eq? x name) 1)
        ((pair? x) (+ (mentions-of name (car x)) (mentions-of name (cdr x))))
        ((vector? x) (mentions-of name (vector->list x)))
        (else 0)))

;; definition-name : datum -> (or symbol #f)
;; The name a define, define-syntax, define-record-type or
;; define-condition-type form defines.
(define (definition-name form)
  (and (pair? form)
       (memq (car form) '(define define-syntax define-record-type define-condition-type))
       (pair? (cdr form))
       (let ((target (cadr form)))
         (cond ((symbol? target) target)
               ((and (pair? target) (symbol? (car target))) (car target))
               (else #f)))))

;; binds-parameter? : symbol datum -> boolean
;; Whether FORM is a (define (f param ...) ...) that takes NAME as a
;; parameter, which shadows NAME for the whole body: the dispatchers and
;; native.sls name a handle's raw pointer handle-ptr.
(define (binds-parameter? name form)
  (and (pair? form)
       (eq? (car form) 'define)
       (pair? (cdr form))
       (pair? (cadr form))
       (let params ((ps (cdadr form)))
         (cond ((pair? ps) (or (eq? (car ps) name) (params (cdr ps))))
               (else (eq? ps name))))))

;; namers-in-src : symbol -> (listof (list string symbol exact-positive-integer))
;; Each top-level form of a library in src/ that names NAME, as (file
;; definition count), in file and source order: 'top-level for a form that
;; defines nothing. NAME's own definition does not count, nor does a
;; definition whose parameter shadows NAME.
(define (namers-in-src name)
  (apply append
         (map (lambda (e)
                (let ((body (list-tail (cdr e) 4)))  ; after library, name, export, import
                  (map (lambda (form)
                         (list (car e) (or (definition-name form) 'top-level)
                               (mentions-of name form)))
                       (filter (lambda (form)
                                 (and (not (eq? (definition-name form) name))
                                      (not (binds-parameter? name form))
                                      (positive? (mentions-of name form))))
                               body))))
              libraries)))

(test-equal "rule 8: open-handle-ptr is named only by owned-handle-ptr and three steps that check the owner another way or not at all, once each"
  '(("src/libuv/private/handles.sls" owned-handle-ptr 1)
    ("src/libuv/private/handles.sls" begin-close! 1)
    ("src/libuv/process.sls" stdio-refusal 1)
    ("src/libuv/tcp.sls" uv-accept! 1))
  (namers-in-src 'open-handle-ptr))

(test-equal "rule 8: a handle's pointer field is read only by the definitions listed, once each"
  '(("src/libuv/async.sls" uv-async-send! 1)
    ("src/libuv/private/handles.sls" uv-handle-record 1)
    ("src/libuv/private/handles.sls" handle-pointer 1)
    ("src/libuv/private/handles.sls" open-handle-ptr 1)
    ("src/libuv/private/handles.sls" handle-in-loop-queue? 1)
    ("src/libuv/process.sls" fill-stdio-containers! 1)
    ("src/libuv/process.sls" clean-up-failed-spawn! 1)
    ("src/libuv/tcp.sls" uv-accept! 1))
  (namers-in-src 'handle-ptr))

(test-equal "rule 8: handle-pointer, the checked accessor outside a step, is named only by discard-failed-handle!"
  '(("src/libuv/private/handles.sls" discard-failed-handle! 1))
  (namers-in-src 'handle-pointer))

(test-equal "rule 9: make-uv-wrong-thread is named only by its condition type and wrong-thread-refusal, once each"
  '(("src/libuv/private/conditions.sls" &uv-wrong-thread 1)
    ("src/libuv/private/handles.sls" wrong-thread-refusal 1))
  (namers-in-src 'make-uv-wrong-thread))

(test-equal "rule 9: a loop's owner is read only by its record and loop-owner-mismatch, once each"
  '(("src/libuv/private/handles.sls" uv-loop-record 1)
    ("src/libuv/private/handles.sls" loop-owner-mismatch 1))
  (namers-in-src 'loop-owner-thread))

(test-equal "rule 9: symbol? is named only by the definitions listed, none of which tests a step's answer"
  '(("src/libuv/private/handles.sls" refused? 1)
    ("src/libuv/private/handles.sls" step-refusal 1)
    ("src/libuv/private/native.sls" signal-symbol->int 1))
  (namers-in-src 'symbol?))

;; Live: native.sls resolves dozens of shim entries through the two forms.
(test-equal "the entry rule is live: native.sls resolves its shim entries through the checked forms"
  'many-checked
  (if (and native-form (> (checked-entries native-form) 40))
      'many-checked
      (list 'checked (and native-form (checked-entries native-form)))))

(test-equal "every shim entry native.sls resolves is checked first"
  '() (if native-form (unchecked-entries native-form) '(no-native-form)))

(define calls
  (apply append (map (lambda (e) (foreign-calls (cdr e))) libraries)))

;; Live: a scan that missed either kind of call, the convention or the
;; types would pass rules 3 and 4 below with nothing found. native.sls
;; makes 60 foreign-procedure and 50 shim-procedure calls.
(test-equal "the foreign-call scan is live: it reads native.sls's calls of both kinds, uv_run's __collect_safe and the u8* arguments"
  'live
  (let ((collect-safe (map call-entry (filter collect-safe? calls)))
        (u8 (map call-entry
                 (filter (lambda (c) (memq 'u8* (call-types c))) calls))))
    (if (and (> (length calls) 80)
             (member "uv_run" collect-safe)
             (member "chez_uv_copy_in" u8) (member "uv_getaddrinfo" u8))
        'live
        (list 'calls (length calls) 'collect-safe collect-safe 'u8* u8))))

(test-equal "no foreign call in src/ takes a string type"
  '() (string-callers calls))

(test-equal "no __collect_safe foreign call in src/ takes an argument in Scheme memory"
  '() (collect-safe-address-callers calls))

;; Live: native.sls defines an ftype and imports from (chezscheme), and
;; shim-procedure wraps foreign-procedure, so each scan below has something
;; to read.
(test-equal "the rule-5 scans are live: they read native.sls's define-ftype and its (chezscheme) imports"
  'live
  (let ((ftypes (if native-form (forms-headed '(define-ftype) native-form) '()))
        (imports (if native-form (forms-headed '(import) native-form) '())))
    (if (and (pair? ftypes) (pair? imports) (mentions? (car imports) 'chezscheme))
        'live
        (list 'ftypes (length ftypes) 'imports imports))))

(test-equal "no define-ftype in src/ is a function type or an alias of a pointer type"
  '() (apply append (map (lambda (e) (hiding-ftypes (cdr e))) libraries)))

(test-equal "no macro in src/ but shim-procedure wraps foreign-procedure"
  '(shim-procedure)
  (apply append (map (lambda (e) (foreign-wrappers (cdr e))) libraries)))

(test-equal "no library in src/ imports from (chezscheme) renamed or prefixed"
  '() (apply append (map (lambda (e) (renamed-chez-imports (cdr e))) libraries)))

;; Each listed variable as (path name).
(define listed-state
  (apply append
         (map (lambda (lib) (map (lambda (v) (list (car lib) (car v))) (cdr lib)))
              shared-state)))

;; Each found as (path name). The scan is live while anything is listed: a
;; scan that found nothing would report every listed variable gone.
(define found-state
  (apply append
         (map (lambda (e) (map (lambda (name) (list (car e) name))
                               (process-wide-state (cdr e))))
              libraries)))

(test-equal "every process-wide variable in src/ is listed with how threads share it, and every listed one is still there"
  '(unlisted () gone ())
  (list 'unlisted (filter (lambda (v) (not (member v listed-state))) found-state)
        'gone (filter (lambda (v) (not (member v found-state))) listed-state)))

(test-equal "every listed variable says how threads share it in one of the suite's words"
  '() (unknown-classes shared-state))

;; Two of the words can be read off the definition: a thread-local variable
;; is a thread parameter made with a constant, and a lock a mutex, each made
;; once and never changed.
(test-equal "each variable listed as thread-local is a thread parameter made with a constant, and each lock a mutex, made once and never set"
  '()
  (apply append
         (map (lambda (lib)
                (let ((form (cond ((assoc (car lib) libraries) => cdr) (else #f))))
                  (filter (lambda (x) x)
                          (map (lambda (v)
                                 (and (memq (cadr v) '(thread-local lock))
                                      (not (and form
                                                (if (eq? (cadr v) 'thread-local)
                                                    (per-thread? (car v) form)
                                                    (eq? (made-by (car v) form) 'make-mutex))))
                                      (list (car lib) (car v) (cadr v))))
                               (cdr lib)))))
              shared-state)))

;; The other two are read off where each variable is written. The rows are
;; live only if they find the writes to check.
(test-equal "the init-lock and library-init rows find writes and installer calls to check"
  '(live live)
  (let ((count-sites
         (lambda (class pred-of)
           (apply + (map (lambda (lib)
                           (let ((form (cond ((assoc (car lib) libraries) => cdr) (else #f))))
                             (apply + (map (lambda (v)
                                             (if (and form (eq? (cadr v) class))
                                                 (length (sites (pred-of (car v)) form))
                                                 0))
                                           (cdr lib)))))
                         shared-state)))))
    (list (if (positive? (count-sites 'init-lock writes-of)) 'live 'none)
          (if (positive? (apply + (map (lambda (e) (length (sites (calls-to installers) (cdr e))))
                                       libraries)))
              'live 'none))))

(test-equal "each init-lock variable is set only under native.sls's init-mutex or by constants-init!, which is called only under it"
  '() (init-lock-offenses libraries shared-state))

(test-equal "each library-init variable is written only by an installer or a top-level initializer, and each installer is called only from one"
  '() (library-init-offenses libraries shared-state))

;; The variables listed as under the registry's lock, which the rows below
;; hold to it. Pinned, so that the rows cannot pass by checking nothing.
(define registry-locked
  (let ((handles (assoc "src/libuv/private/handles.sls" shared-state)))
    (if handles
        (map car (filter (lambda (v) (eq? (cadr v) 'registry-lock)) (cdr handles)))
        '())))

(define handles-form
  (cond ((assoc "src/libuv/private/handles.sls" libraries) => cdr) (else #f)))

(test-equal "the registry and the orphan list are used only inside with-registry-lock"
  '((registry orphan-events) ())
  (list registry-locked
        (if handles-form
            (unlocked-uses registry-locked handles-form)
            '(no-handles-form))))

(test-equal "every with-registry-lock body in src/ calls only table operations and cons, makes no procedure, and keeps the table in"
  '(read ())
  (list (if (and handles-form (pair? (all-forms-headed '(with-registry-lock) handles-form)))
            'read
            'no-lock-forms)
        (apply append (map (lambda (e) (lock-body-offenses (cdr e))) libraries))))

(test-equal "registry-lock is named in src/ only where it is made and in with-registry-lock"
  '((registry-lock with-registry-lock) ())
  (list (if handles-form
            (map form-label
                 (filter (lambda (f) (mentions-outside? '(registry-lock) '(quote) f))
                         (top-level-forms handles-form)))
            '(no-handles-form))
        (map car (filter (lambda (e)
                           (and (not (string=? (car e) "src/libuv/private/handles.sls"))
                                (mentions-outside? '(registry-lock) '(quote) (cdr e))))
                         libraries))))

(test-equal "no library in src/ exports the registry or the orphan list"
  '()
  (apply append
         (map (lambda (e)
                (map (lambda (name) (list (car e) name))
                     (filter (lambda (x) (memq x '(registry orphan-events)))
                             (library-exports (cdr e)))))
              libraries)))

;; The C shim, read as lines of text.
(define shim-lines
  (text-lines (call-with-input-file "src/libuv-shim.c" get-string-all)))

(test-equal "every static variable in the C shim is a counter this suite lists, and every listed one is still there"
  '(unlisted () gone ())
  (let ((found (static-objects shim-lines)))
    (list 'unlisted (filter (lambda (n) (not (memq n shim-counters))) found)
          'gone (filter (lambda (n) (not (memq n found))) shim-counters))))

(test-equal "the shim's counters are changed only through count_add and read only through count_read, which are atomic"
  '() (bare-counter-uses shim-counters shim-lines))

(test-end "source-rules")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
