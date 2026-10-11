#!r6rs
;; PURE. Imports no library that loads a shared object.
;;
;; The reference checker deliberately parses a narrow Markdown authoring
;; convention rather than implementing Markdown a second time. Source export
;; forms and the reference page remain ordinary data supplied by the caller;
;; filesystem discovery belongs to tests/reference-check.sps.
(library (site reference)
  (export library-datum->api
          markdown->reference-analysis
          reference-analysis? reference-analysis-modules
          reference-analysis-entries reference-analysis-problems
          reference-entry? reference-entry-name reference-entry-kind
          reference-entry-modules reference-entry-body?
          reference-entry-availability-count
          reference-diagnostics)
  (import (rnrs))

  (define-record-type reference-entry
    (fields name kind modules body? availability-count))

  (define-record-type reference-analysis
    (fields modules entries problems))

  (define-record-type pending-entry
    (fields name kind modules body? availability-count))

  ;; --- small string operations -----------------------------------------

  (define (string-prefix? prefix s)
    (and (>= (string-length s) (string-length prefix))
         (string=? prefix (substring s 0 (string-length prefix)))))

  (define (space? c)
    (memv c '(#\space #\tab #\newline #\return)))

  (define (trim s)
    (let ((n (string-length s)))
      (let left ((a 0))
        (if (and (< a n) (space? (string-ref s a)))
            (left (+ a 1))
            (let right ((b n))
              (if (and (> b a) (space? (string-ref s (- b 1))))
                  (right (- b 1))
                  (substring s a b)))))))

  (define (blank? s) (string=? "" (trim s)))

  (define (string-find-char s wanted start)
    (let loop ((i start))
      (cond ((= i (string-length s)) #f)
            ((char=? wanted (string-ref s i)) i)
            (else (loop (+ i 1))))))

  (define (string-lines s)
    (let ((n (string-length s)))
      (let loop ((start 0) (i 0) (out '()))
        (cond
          ((= i n) (reverse (cons (substring s start i) out)))
          ((char=? #\newline (string-ref s i))
           (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
          (else (loop start (+ i 1) out))))))

  (define (module<? a b)
    (cond ((null? a) (not (null? b)))
          ((null? b) #f)
          ((string<? (symbol->string (car a)) (symbol->string (car b))) #t)
          ((string<? (symbol->string (car b)) (symbol->string (car a))) #f)
          (else (module<? (cdr a) (cdr b)))))

  (define (symbol<? a b)
    (string<? (symbol->string a) (symbol->string b)))

  (define (read-one s)
    (guard (e (else #f))
      (let ((port (open-string-input-port s)))
        (let ((x (read port)))
          (if (eof-object? x) #f x)))))

  (define (library-name? x)
    (and (list? x) (not (null? x)) (for-all symbol? x)))

  ;; --- library export forms --------------------------------------------

  (define (find-export-form forms)
    (cond ((null? forms) #f)
          ((and (pair? (car forms)) (eq? 'export (caar forms))) (car forms))
          (else (find-export-form (cdr forms)))))

  (define (first-non-symbol xs)
    (cond ((null? xs) #f)
          ((symbol? (car xs)) (first-non-symbol (cdr xs)))
          (else (car xs))))

  (define (library-datum->api datum)
    (cond
      ((or (not (pair? datum))
           (not (eq? 'library (car datum)))
           (not (pair? (cdr datum)))
           (not (library-name? (cadr datum))))
       (values #f '() (list 'malformed-library-datum datum)))
      (else
       (let ((export-form (find-export-form (cddr datum))))
         (cond
           ((not export-form)
            (values (cadr datum) '() '(missing-export-form)))
           ((first-non-symbol (cdr export-form))
            => (lambda (bad)
                 (values (cadr datum) '()
                         (list 'unsupported-export-spec bad))))
           (else
            (values (cadr datum) (cdr export-form) #f)))))))

  ;; --- constrained Markdown analysis ----------------------------------

  (define kind-table
    '(("procedure" . procedure)
      ("record constructor" . record-constructor)
      ("predicate" . predicate)
      ("accessor" . accessor)
      ("condition type" . condition-type)))

  (define (heading-entry line)
    (let ((s (trim line)))
      (and (string-prefix? "### `" s)
           (let ((close (string-find-char s #\` 5)))
             (and close
                  (> close 5)
                  (let* ((name-text (substring s 5 close))
                         (tail (trim (substring s (+ close 1)
                                                (string-length s))))
                         (kind
                          (let loop ((ks kind-table))
                            (cond
                              ((null? ks) #f)
                              ((string=? tail
                                         (string-append "(" (caar ks) ")"))
                               (cdar ks))
                              (else (loop (cdr ks)))))))
                    (and kind
                         (cons (string->symbol name-text) kind))))))))

  (define (h2? line) (string-prefix? "## " (trim line)))
  (define (h3? line) (string-prefix? "### " (trim line)))

  (define (fence? line)
    (let ((s (trim line)))
      (or (string-prefix? "```" s) (string-prefix? "~~~" s))))

  (define (html-comment? line)
    (string-prefix? "<!--" (trim line)))

  (define availability-prefix "**Available from:**")

  (define (availability? line)
    (string-prefix? availability-prefix (trim line)))

  (define (code-library-names line)
    (let loop ((at 0) (out '()))
      (let ((open (string-find-char line #\` at)))
        (if (not open)
            (reverse out)
            (let ((close (string-find-char line #\` (+ open 1))))
              (if (not close)
                  (reverse out)
                  (let ((x (read-one (substring line (+ open 1) close))))
                    (loop (+ close 1)
                          (if (library-name? x) (cons x out) out)))))))))

  (define (module-row line)
    (let ((s (trim line)))
      (and (string-prefix? "| `(" s)
           (let ((open (string-find-char s #\` 0)))
             (and open
                  (let ((close (string-find-char s #\` (+ open 1))))
                    (and close
                         (let ((x (read-one (substring s (+ open 1) close))))
                           (and (library-name? x) x)))))))))

  (define (pending-with-availability p modules)
    (make-pending-entry
     (pending-entry-name p)
     (pending-entry-kind p)
     (append (pending-entry-modules p) modules)
     (pending-entry-body? p)
     (+ 1 (pending-entry-availability-count p))))

  (define (pending-with-body p)
    (make-pending-entry
     (pending-entry-name p)
     (pending-entry-kind p)
     (pending-entry-modules p)
     #t
     (pending-entry-availability-count p)))

  (define (finish-entry pending entries)
    (if pending
        (cons (make-reference-entry
               (pending-entry-name pending)
               (pending-entry-kind pending)
               (pending-entry-modules pending)
               (pending-entry-body? pending)
               (pending-entry-availability-count pending))
              entries)
        entries))

  (define (markdown->reference-analysis markdown)
    (let loop ((lines (string-lines markdown))
               (in-fence? #f)
               (in-modules? #f)
               (modules '())
               (entries '())
               (problems '())
               (pending #f))
      (if (null? lines)
          (make-reference-analysis
           (reverse modules)
           (reverse (finish-entry pending entries))
           (reverse problems))
          (let* ((line (car lines)) (s (trim line)))
            (cond
              ;; Fence markers are substantive entry content, but everything
              ;; inside a fence is opaque to the heading/module grammar.
              ((fence? line)
               (loop (cdr lines) (not in-fence?) in-modules?
                     modules entries problems
                     (if pending (pending-with-body pending) pending)))
              (in-fence?
               (loop (cdr lines) in-fence? in-modules?
                     modules entries problems
                     (if (and pending (not (blank? line)))
                         (pending-with-body pending)
                         pending)))
              ((h2? line)
               (loop (cdr lines) #f (string=? s "## Modules")
                     modules (finish-entry pending entries) problems #f))
              ((h3? line)
               (let ((parsed (heading-entry line)))
                 (if parsed
                     (loop (cdr lines) #f #f modules
                           (finish-entry pending entries) problems
                           (make-pending-entry (car parsed) (cdr parsed)
                                               '() #f 0))
                     (loop (cdr lines) #f #f modules
                           (finish-entry pending entries)
                           (cons (cons 'malformed-entry-heading s) problems)
                           #f))))
              ((and in-modules? (module-row line))
               => (lambda (name)
                    (loop (cdr lines) #f in-modules?
                          (cons name modules) entries problems pending)))
              ((and pending (availability? line))
               (loop (cdr lines) #f in-modules? modules entries problems
                     (pending-with-availability
                      pending (code-library-names line))))
              ((and pending (not (blank? line)) (not (html-comment? line)))
               (loop (cdr lines) #f in-modules? modules entries problems
                     (pending-with-body pending)))
              (else
               (loop (cdr lines) #f in-modules?
                     modules entries problems pending)))))))

  ;; --- diagnostics -----------------------------------------------------

  (define (member-equal? x xs)
    (and (member x xs) #t))

  (define (unique-equal xs)
    (let loop ((rest xs) (seen '()) (out '()))
      (cond ((null? rest) (reverse out))
            ((member-equal? (car rest) seen)
             (loop (cdr rest) seen out))
            (else
             (loop (cdr rest) (cons (car rest) seen) (cons (car rest) out))))))

  (define (duplicates-equal xs)
    (let loop ((rest xs) (seen '()) (dups '()))
      (cond ((null? rest) (reverse dups))
            ((member-equal? (car rest) seen)
             (loop (cdr rest) seen
                   (if (member-equal? (car rest) dups)
                       dups
                       (cons (car rest) dups))))
            (else (loop (cdr rest) (cons (car rest) seen) dups)))))

  (define (list-minus xs ys)
    (filter (lambda (x) (not (member-equal? x ys))) xs))

  (define (same-set? a b)
    (and (null? (list-minus a b)) (null? (list-minus b a))))

  (define (sort-symbols xs) (list-sort symbol<? xs))
  (define (sort-modules xs) (list-sort module<? xs))

  (define (problem-values tag problems)
    (map cdr (filter (lambda (p) (eq? tag (car p))) problems)))

  (define (actual-modules-for name module-apis)
    (map car (filter (lambda (api) (memq name (cdr api))) module-apis)))

  (define (entry-module-mismatches entries public-bindings module-apis)
    (let loop ((rest entries) (out '()))
      (if (null? rest)
          (reverse out)
          (let* ((entry (car rest))
                 (name (reference-entry-name entry)))
            (if (and (memq name public-bindings)
                     (= 1 (reference-entry-availability-count entry)))
                (let ((expected
                       (sort-modules
                        (unique-equal (actual-modules-for name module-apis))))
                      (actual
                       (sort-modules
                        (unique-equal (reference-entry-modules entry)))))
                  (loop (cdr rest)
                        (if (same-set? expected actual)
                            out
                            (cons (list name expected actual) out))))
                (loop (cdr rest) out))))))

  (define (add-diagnostic tag values out)
    (if (null? values) out (cons (cons tag values) out)))

  (define (reference-diagnostics module-apis analysis)
    (let* ((public-modules (map car module-apis))
           (public-bindings (unique-equal (apply append (map cdr module-apis))))
           (reference-modules (reference-analysis-modules analysis))
           (entries (reference-analysis-entries analysis))
           (reference-bindings (map reference-entry-name entries))
           (missing-modules
            (sort-modules
             (list-minus (unique-equal public-modules)
                         (unique-equal reference-modules))))
           (extra-modules
            (sort-modules
             (list-minus (unique-equal reference-modules)
                         (unique-equal public-modules))))
           (missing-bindings
            (sort-symbols
             (list-minus public-bindings (unique-equal reference-bindings))))
           (extra-bindings
            (sort-symbols
             (list-minus (unique-equal reference-bindings) public-bindings)))
           (duplicate-modules
            (sort-modules (duplicates-equal reference-modules)))
           (duplicate-bindings
            (sort-symbols (duplicates-equal reference-bindings)))
           (empty-bodies
            (sort-symbols
             (map reference-entry-name
                  (filter (lambda (e) (not (reference-entry-body? e)))
                          entries))))
           (missing-availability
            (sort-symbols
             (map reference-entry-name
                  (filter
                   (lambda (e) (= 0 (reference-entry-availability-count e)))
                   entries))))
           (duplicate-availability
            (sort-symbols
             (map reference-entry-name
                  (filter
                   (lambda (e) (> (reference-entry-availability-count e) 1))
                   entries))))
           (membership-mismatches
            (entry-module-mismatches entries public-bindings module-apis))
           (malformed
            (list-sort string<?
                       (problem-values 'malformed-entry-heading
                                       (reference-analysis-problems analysis)))))
      (reverse
       (let* ((out '())
              (out (add-diagnostic 'no-public-modules
                                   (if (null? public-modules) '(empty) '()) out))
              (out (add-diagnostic 'no-public-bindings
                                   (if (null? public-bindings) '(empty) '()) out))
              (out (add-diagnostic 'no-reference-modules
                                   (if (null? reference-modules) '(empty) '()) out))
              (out (add-diagnostic 'no-reference-bindings
                                   (if (null? reference-bindings) '(empty) '()) out))
              (out (add-diagnostic 'missing-modules missing-modules out))
              (out (add-diagnostic 'extra-modules extra-modules out))
              (out (add-diagnostic 'duplicate-modules duplicate-modules out))
              (out (add-diagnostic 'missing-bindings missing-bindings out))
              (out (add-diagnostic 'extra-bindings extra-bindings out))
              (out (add-diagnostic 'duplicate-bindings duplicate-bindings out))
              (out (add-diagnostic 'empty-entry-bodies empty-bodies out))
              (out (add-diagnostic 'missing-availability missing-availability out))
              (out (add-diagnostic 'duplicate-availability duplicate-availability out))
              (out (add-diagnostic 'module-membership-mismatches
                                   membership-mismatches out))
              (out (add-diagnostic 'malformed-entry-headings malformed out)))
         out))))
)
