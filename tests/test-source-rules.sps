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
;;;    and two loops run on two threads at once corrupted it (#70). So each
;;;    variable a library in src/ defines at its top level and then sets,
;;;    or binds to a table, a box, a vector, a parameter or a lock, is one
;;;    this suite lists, saying how threads share it. A new one fails here
;;;    until it is listed. And the variables listed as under the registry's
;;;    lock are used only inside with-registry-lock.
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
;; and something later changes: a variable a form in the library sets, or
;; anything made by a call whose result changes in place.

(define mutable-makers
  '(make-eq-hashtable make-eqv-hashtable make-hashtable
    make-weak-eq-hashtable make-weak-eqv-hashtable
    make-ephemeron-eq-hashtable make-ephemeron-eqv-hashtable
    box make-vector vector make-bytevector make-string
    make-thread-parameter make-parameter make-mutex make-condition))

;; library-body : datum -> (list-of datum)
;; The forms after a library form's name, export and import.
(define (library-body lib)
  (if (and (list? lib) (>= (length lib) 4)) (cddddr lib) '()))

;; defined-name : datum -> (or symbol #f)
;; What a top-level (define x ...) or (define (f ...) ...) names.
(define (defined-name form)
  (and (pair? form) (eq? (car form) 'define) (pair? (cdr form))
       (let ((target (cadr form)))
         (cond ((symbol? target) target)
               ((and (pair? target) (symbol? (car target))) (car target))
               (else #f)))))

;; all-forms-headed : (list-of symbol) datum -> (list-of datum)
;; forms-headed, but looking inside each form it finds as well.
(define (all-forms-headed heads x)
  (cond ((not (pair? x)) '())
        ((eq? (car x) 'quote) '())
        (else
         (append (if (memq (car x) heads) (list x) '())
                 (let elements ((xs x) (acc '()))
                   (if (pair? xs)
                       (elements (cdr xs) (append acc (all-forms-headed heads (car xs))))
                       acc))))))

;; process-wide-state : datum -> (list-of symbol)
;; Each name a top-level definition of the library form LIB binds, when a
;; set! anywhere in LIB names it, or when the definition is (define x (maker
;; ...)) for a maker in mutable-makers. A local variable that shares a
;; top-level name counts too, which errs only toward listing.
(define (process-wide-state lib)
  (let* ((body (library-body lib))
         (targets (map (lambda (form) (and (pair? (cdr form)) (cadr form)))
                       (all-forms-headed '(set!) body))))
    (filter symbol?
            (map (lambda (form)
                   (let ((name (defined-name form)))
                     (and name
                          (or (memq name targets)
                              (and (symbol? (cadr form))
                                   (pair? (cddr form))
                                   (pair? (caddr form))
                                   (memq (car (caddr form)) mutable-makers)))
                          name)))
                 body))))

;; made-by : symbol datum -> (or symbol #f)
;; The maker NAME's top-level definition in the library form LIB calls, when
;; it is (define NAME (maker ...)) for a maker in mutable-makers and no set!
;; in LIB names NAME; else #f.
(define (made-by name lib)
  (let* ((body (library-body lib))
         (form (find (lambda (f) (and (eq? (defined-name f) name) (symbol? (cadr f))))
                     body)))
    (and form
         (pair? (cddr form))
         (pair? (caddr form))
         (memq (car (caddr form)) mutable-makers)
         (not (exists (lambda (s) (and (pair? (cdr s)) (eq? (cadr s) name)))
                      (all-forms-headed '(set!) body)))
         (car (caddr form)))))

;; unlocked-mention? : (list-of symbol) datum -> boolean
;; Whether the form X names one of NAMES outside quoted data and outside
;; every with-registry-lock form. Only a form's head makes it one of those:
;; the keyword quoted among a call's arguments does not.
(define (unlocked-mention? names x)
  (cond ((symbol? x) (and (memq x names) #t))
        ((pair? x)
         (and (not (memq (car x) '(quote with-registry-lock)))
              (let elements ((xs x))
                (cond ((pair? xs)
                       (or (unlocked-mention? names (car xs)) (elements (cdr xs))))
                      (else (unlocked-mention? names xs))))))
        (else #f)))

;; unlocked-uses : (list-of symbol) datum -> (list-of symbol)
;; The name of each top-level define or define-syntax in the library form
;; LIB that names one of NAMES outside with-registry-lock. Each is read past
;; the name it defines, so the definition of one of NAMES is not a use.
(define (unlocked-uses names lib)
  (let ((forms (filter (lambda (f)
                         (and (pair? f) (memq (car f) '(define define-syntax))
                              (pair? (cdr f))))
                       (library-body lib))))
    (map (lambda (f) (let ((target (cadr f))) (if (pair? target) (car target) target)))
         (filter (lambda (f) (unlocked-mention? names (cddr f))) forms))))

;; How each piece of process-wide state in src/ is shared by threads:
;; - library-init: set or filled while its library's body runs, which a
;;   program's imports run before its own code, and only read after;
;; - init-lock: set only while native.sls's init-mutex is held, by
;;   ensure-native-loaded!, which every constructor calls first;
;; - registry-lock: used only inside with-registry-lock, which the last row
;;   checks;
;; - thread-local: a thread parameter, with a value for each thread;
;; - lock: a mutex.
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

(test-equal "rule 6 finds each top-level variable its library sets, or binds to a table, a box, a parameter or a lock, and only those"
  '(counter table cell param lock flag)
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
      (define constant 1)
      (define quoted '(set! constant 2))
      (define (bump!) (set! counter (+ counter 1)))
      (define (local) (let ((n 0)) (set! n 1) n))
      (define (raise-flag!) (set! flag #t)))))

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

(test-equal "rule 6 finds a use of a locked variable outside with-registry-lock, in a procedure or a macro, and only those"
  '(bare in-macro after-lock mentions-the-keyword)
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
        (list 'with-registry-lock (hashtable-ref registry p #f))))))

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
  '()
  (filter (lambda (v) (not (and (pair? (cdr v)) (memq (cadr v) state-classes))))
          (apply append (map cdr shared-state))))

;; Two of the words can be read off the definition: a thread-local variable
;; is a thread parameter, and a lock a mutex, each made once and never set.
(test-equal "each variable listed as thread-local is a thread parameter, and each lock a mutex, made once and never set"
  '()
  (apply append
         (map (lambda (lib)
                (let ((form (cond ((assoc (car lib) libraries) => cdr) (else #f))))
                  (filter (lambda (x) x)
                          (map (lambda (v)
                                 (let ((want (case (cadr v)
                                               ((thread-local) 'make-thread-parameter)
                                               ((lock) 'make-mutex)
                                               (else #f))))
                                   (and want
                                        (not (eq? (and form (made-by (car v) form)) want))
                                        (list (car lib) (car v) (cadr v)))))
                               (cdr lib)))))
              shared-state)))

;; The variables listed as under the registry's lock, which the row below
;; holds to it. Pinned, so that the row cannot pass by checking nothing.
(define registry-locked
  (let ((handles (assoc "src/libuv/private/handles.sls" shared-state)))
    (if handles
        (map car (filter (lambda (v) (eq? (cadr v) 'registry-lock)) (cdr handles)))
        '())))

(test-equal "the registry and the orphan list are used only inside with-registry-lock"
  '((registry orphan-events) ())
  (let ((handles (assoc "src/libuv/private/handles.sls" libraries)))
    (list registry-locked
          (if handles
              (unlocked-uses registry-locked (cdr handles))
              '(no-handles-form)))))

(test-end "source-rules")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
