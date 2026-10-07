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
          (only (libuv private c-string) c-string-bytes)
          (only (libuv private lists) read-proper-list))

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
  ;; Present hints answer a copy that shares no pair with them. The alist is
  ;; read once, by read-proper-list, into fresh entries, each entry's key and
  ;; value read once; the checks then walk that copy, which nothing else
  ;; reaches. Measured with Chez's list? first, as it was until #66, an alist
  ;; changed twice at one engine expiry, a self-loop at each of its first two
  ;; pairs, left list?'s two walkers on separate cycles, and the call never
  ;; returned; one made circular after list? was refused as a duplicate key
  ;; (tests/test-addrinfo.sps's spine sweeps).
  (define (validate-hints hints who)
    (if (or (eq? hints #f) (null? hints))
        'absent
        (let ((entries (read-proper-list hints read-hint-entry)))
          (unless entries (refuse who 'hints-not-an-alist))
          (let check ((rest entries) (seen '()))
            (if (null? rest)
                '()
                (let ((entry (car rest)))
                  (unless entry (refuse who 'hints-not-an-alist))
                  (let ((key (car entry)) (value (cdr entry)))
                    (unless (memq key hint-keys) (refuse who 'unknown-hint-key))
                    (when (memq key seen) (refuse who 'duplicate-hint-key))
                    (let ((checked (checked-hint-value key value who)))
                      (cons (cons key checked)
                            (check (cdr rest) (cons key seen)))))))))))

  ;; read-hint-entry : object -> (or pair #f)
  ;; A fresh (key . value) for a caller's hints entry, its car and cdr each
  ;; read once, or #f for anything but a pair.
  (define (read-hint-entry entry)
    (and (pair? entry) (cons (car entry) (cdr entry))))

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
  ;; A fresh list of the flags: read once by read-proper-list, which ends
  ;; and raises nothing whatever the list is or becomes, then checked on
  ;; that copy, which nothing else reaches. A guarded length cost a guard a
  ;; call, and at --optimize-level 3 Chez's length checks nothing, so a
  ;; circular list hung the call where no engine could stop it (#66;
  ;; tests/flags-level-3-child.sps).
  (define (checked-flags value who)
    (let ((flags (read-proper-list value (lambda (flag) flag))))
      (unless flags (refuse who 'hint-flags-not-a-list))
      (let check ((rest flags))
        (unless (null? rest)
          (unless (memq (car rest) hint-flag-set)
            (refuse who 'unknown-hint-flag))
          (check (cdr rest))))
      flags))

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
