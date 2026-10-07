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

(test-end "source-rules")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
