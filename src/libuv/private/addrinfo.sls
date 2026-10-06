#!r6rs
;;; Pure addrinfo records and symbolic DNS argument validation.
;;;
;;; The validators answer copies of what they checked, and (libuv dns)
;;; allocates and writes from those copies alone. A caller's alist or string
;;; can change during the call, from an engine's timer handler or another
;;; thread, and is read once, here (tests/test-addrinfo.sps's sweeps).
(library (libuv private addrinfo)
  (export uv-addrinfo make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname
          validate-hints validate-node-and-service)
  (import (rnrs)
          (libuv private conditions)
          (only (libuv private c-string) c-string-bytes))

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

  ;; validate-hints : (or #f alist) symbol -> (or 'absent alist)
  ;; Empty and false both mean absent; non-empty hints use closed symbol sets.
  ;; Present hints answer a copy, made by the walk that checks them: each
  ;; entry and value is read once, and the copy shares no pair with them.
  (define (validate-hints hints who)
    (cond
      ((or (eq? hints #f) (null? hints)) 'absent)
      ((not (list? hints)) (refuse who 'hints-not-an-alist))
      (else
       (let walk ((rest hints) (seen '()))
         (cond
           ((null? rest) '())
           ((not (pair? rest)) (refuse who 'hints-not-an-alist))
           (else
            (let ((entry (car rest)))
              (unless (pair? entry) (refuse who 'hints-not-an-alist))
              (let ((key (car entry)) (value (cdr entry)))
                (unless (memq key hint-keys) (refuse who 'unknown-hint-key))
                (when (memq key seen) (refuse who 'duplicate-hint-key))
                (let ((checked (checked-hint-value key value who)))
                  (cons (cons key checked)
                        (walk (cdr rest) (cons key seen))))))))))))

  ;; checked-hint-value : symbol object symbol -> object
  ;; VALUE if it is in KEY's closed set; flags answer a fresh list.
  (define (checked-hint-value key value who)
    (case key
      ((family)
       (if (memq value hint-families) value (refuse who 'unknown-hint-family)))
      ((socktype)
       (if (memq value hint-socktypes) value (refuse who 'unknown-hint-socktype)))
      ((protocol)
       (if (memq value hint-protocols) value (refuse who 'unknown-hint-protocol)))
      (else (checked-flags value who))))

  ;; checked-flags : object symbol -> (list-of symbol)
  ;; A fresh list of the flags, each read once and checked as it is copied.
  ;; The walk takes at most as many steps as the list had when it was found
  ;; proper, so a list changed during it is refused, never walked forever.
  ;; The length comes from one call, whose raise for an improper or circular
  ;; list is the refusal. Asking list? first leaves a gap an engine can
  ;; expire in, and a list made circular there makes length raise a
  ;; condition of its own (the flags-made-circular sweep).
  (define (checked-flags value who)
    (let ((n (guard (e (#t #f)) (length value))))
      (unless n (refuse who 'hint-flags-not-a-list))
      (let copy ((rest value) (left n))
        (cond
          ((zero? left) '())
          ((not (pair? rest)) (refuse who 'hint-flags-not-a-list))
          (else
           (let ((flag (car rest)))
             (unless (memq flag hint-flag-set) (refuse who 'unknown-hint-flag))
             (cons flag (copy (cdr rest) (- left 1)))))))))

  ;; validate-node-and-service : (or string #f) (or string #f) symbol
  ;;                             -> (pair (or bytevector #f) (or bytevector #f))
  ;; At least one value is required. Each present string answers the bytes C
  ;; reads for it (c-string-bytes), and an absent one #f, which crosses as
  ;; NULL; node is the car.
  (define (validate-node-and-service node service who)
    (unless (or (eq? node #f) (string? node))
      (refuse who 'node-not-a-string-or-false))
    (unless (or (eq? service #f) (string? service))
      (refuse who 'service-not-a-string-or-false))
    (when (and (eq? node #f) (eq? service #f))
      (refuse who 'node-and-service-both-absent))
    (let* ((node-bytes (and node (c-string-bytes node who 'node-contains-nul)))
           (service-bytes
            (and service (c-string-bytes service who 'service-contains-nul))))
      (cons node-bytes service-bytes))))
