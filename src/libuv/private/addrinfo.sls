#!r6rs
;;; Pure addrinfo records and symbolic DNS argument validation.
(library (libuv private addrinfo)
  (export uv-addrinfo make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname
          validate-hints validate-node-and-service)
  (import (rnrs)
          (libuv private conditions))

  ;; make-uv-addrinfo : symbol (or symbol exact-integer)
  ;;                    (or symbol exact-integer) (or string #f)
  ;;                    exact-nonnegative-integer (or string #f) -> uv-addrinfo
  ;; Fields are immutable; construction does not validate field values.
  (define-record-type (uv-addrinfo make-uv-addrinfo uv-addrinfo?)
    (fields (immutable family    uv-addrinfo-family)
            (immutable socktype  uv-addrinfo-socktype)
            (immutable protocol  uv-addrinfo-protocol)
            (immutable address   uv-addrinfo-address)
            (immutable port      uv-addrinfo-port)
            (immutable canonname uv-addrinfo-canonname)))

  (define hint-keys       '(family socktype protocol flags))
  (define hint-families   '(unspec inet inet6))
  (define hint-socktypes  '(stream dgram))
  (define hint-protocols  '(tcp udp))
  (define hint-flag-set   '(passive canonname numeric-host numeric-serv))

  (define (refuse who reason)
    (raise (make-uv-invalid-argument who reason)))

  ;; validate-hints : (or #f alist) symbol -> (or 'absent 'present)
  ;; Empty and false both mean absent; non-empty hints use closed symbol sets.
  (define (validate-hints hints who)
    (cond
      ((or (eq? hints #f) (null? hints)) 'absent)
      ((not (list? hints)) (refuse who 'hints-not-an-alist))
      (else
       (let walk ((rest hints) (seen '()))
         (if (null? rest)
             'present
             (let ((entry (car rest)))
               (unless (pair? entry) (refuse who 'hints-not-an-alist))
               (let ((key (car entry)) (value (cdr entry)))
                 (unless (memq key hint-keys) (refuse who 'unknown-hint-key))
                 (when (memq key seen) (refuse who 'duplicate-hint-key))
                 (validate-hint-value key value who)
                 (walk (cdr rest) (cons key seen)))))))))

  (define (validate-hint-value key value who)
    (case key
      ((family)
       (unless (memq value hint-families) (refuse who 'unknown-hint-family)))
      ((socktype)
       (unless (memq value hint-socktypes) (refuse who 'unknown-hint-socktype)))
      ((protocol)
       (unless (memq value hint-protocols) (refuse who 'unknown-hint-protocol)))
      ((flags)
       (unless (list? value) (refuse who 'hint-flags-not-a-list))
       (for-each (lambda (flag)
                   (unless (memq flag hint-flag-set)
                     (refuse who 'unknown-hint-flag)))
                 value))))

  ;; validate-node-and-service : (or string #f) (or string #f) symbol
  ;;                             -> 'validated
  ;; At least one value is required; embedded NUL would truncate at the FFI.
  (define (validate-node-and-service node service who)
    (unless (or (eq? node #f) (string? node))
      (refuse who 'node-not-a-string-or-false))
    (unless (or (eq? service #f) (string? service))
      (refuse who 'service-not-a-string-or-false))
    (when (and (eq? node #f) (eq? service #f))
      (refuse who 'node-and-service-both-absent))
    (when (and node (string-contains-nul? node))
      (refuse who 'node-contains-nul))
    (when (and service (string-contains-nul? service))
      (refuse who 'service-contains-nul))
    'validated)

  (define (string-contains-nul? s)
    (let scan ((i 0))
      (cond ((= i (string-length s)) #f)
            ((char=? (string-ref s i) #\nul) #t)
            (else (scan (+ i 1)))))))
