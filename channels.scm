;;; The Guix revision the development container is built from.
;;; scripts/guix-env passes this to `guix time-machine`. Generated with
;;; `guix describe -f channels`, keeping only the guix channel. To bump it,
;;; change the commit and run `make check-guix`.
(list (channel
       (name 'guix)
       (url "https://git.guix.gnu.org/guix.git")
       (branch "master")
       (commit "b532aa7d0bb345aafabf6b63cbfbda45abbec091")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
