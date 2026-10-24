;;; Development toolchain for chez-libuv.
;;;
;;; Enter it with scripts/guix-env, which pins Guix to channels.scm and runs
;;; this manifest in a container with no network. Plain
;;; `guix shell -m manifest.scm` also loads this file, but against whatever
;;; Guix you have pulled.

(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix utils)
             (gnu packages chez)
             (gnu packages libevent))

;; Chez at this project's floor, 10.4.1 (README.org, ci.yml's
;; CHEZ_FLOOR_VERSION). The pin packages 10.4.0, so this is Guix's own
;; recipe at the v10.4.1 tag. The first `scripts/guix-env` builds it, in
;; about two minutes; later ones reuse the store item.
;;
;; - Its boot files are rebuilt from the same source: Chez refuses to build
;;   from boot files of another version. The input keeps
;;   chez-scheme-for-racket's label, which chez-scheme's own recipe
;;   replaces under that name.
;; - Chez's own test suite is off. It takes over an hour, and no substitute
;;   server will ever have this variant, so every machine and every pin bump
;;   would pay it. `make check-guix` checks this Chez's version and
;;   threading, then runs this project's suites on it.
;; - Overriding the arguments evaluates the parent's with this-package bound
;;   to the parent, so its unpack phase would unpack 10.4.0's source. It is
;;   replaced with one that unpacks this source.
(define chez-scheme-source
  (origin
    (inherit (package-source chez-scheme))
    (uri (git-reference
          (url "https://github.com/cisco/ChezScheme")
          (commit "v10.4.1")))
    (sha256
     (base32 "0hkqh86hqgrs7lyapm26iq3nz7n2hr0hr9d524wf2rlp8ky3iik5"))
    (file-name (git-file-name "chez-scheme" "10.4.1"))))

(define chez-scheme-bootfiles-at-floor
  (package
    (inherit chez-scheme-bootstrap-bootfiles)
    (version "10.4.1")
    (source chez-scheme-source)))

(define chez-scheme-at-floor
  (package
    (inherit chez-scheme)
    (version "10.4.1")
    (source chez-scheme-source)
    (arguments
     (substitute-keyword-arguments (package-arguments chez-scheme)
       ((#:tests? _ #t) #f)
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'unpack
              (lambda _
                ((assoc-ref %standard-phases 'unpack)
                 #:source #$chez-scheme-source)))))))
    (inputs
     (modify-inputs (package-inputs chez-scheme)
       (replace "chez-scheme-for-racket-bootstrap-bootfiles"
         chez-scheme-bootfiles-at-floor)))))

(concatenate-manifests
 (list
  (packages->manifest
   (list chez-scheme-at-floor
         ;; libuv 1.52.1, the vendored submodule's version. The pin's public
         ;; `libuv` is 1.44.2, below the floor (1.48.0), which the Makefile
         ;; would pass over for the vendored build. This one is node's,
         ;; hidden from `guix search` but public in (gnu packages libevent).
         libuv-for-node-lts))
  (specifications->manifest
   '(;; pkg-config finds the libuv above; gcc-toolchain links the shim
     ;; against it. cmake builds the vendored libuv for the HAVE_PKG=no leg.
     "pkg-config" "gcc-toolchain" "cmake"
     ;; The memory gate (make test-memory).
     "valgrind"
     ;; `make site` renders docs/ through chez-cmark-gfm, which loads
     ;; this C library when it is imported.
     "cmark-gfm"
     ;; `make deps`, `make vendor` and `make check-pins` read the
     ;; repository and its submodules. The container gives git no
     ;; identity, credentials or network.
     "git"
     ;; What the Makefile, the scripts and the suites' children shell out
     ;; to. The container has nothing else.
     "bash" "coreutils" "make" "grep" "sed" "gawk" "findutils"
     "diffutils" "tar"))))
