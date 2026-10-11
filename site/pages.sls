#!r6rs
(library (site pages)
  (export pages)
  (import (rnrs))
  ;; The nav's single source of order and labels. tests/site-check.sps
  ;; asserts the file set here equals docs/*.md; README.md is the home page.
  (define pages
    '(("README.md"        . "Home")
      ("installing.md"    . "Installing")
      ("quickstart.md"    . "Quickstart")
      ("loops.md"         . "The event loop")
      ("callbacks.md"     . "Callbacks")
      ("threads.md"       . "Threads")
      ("timers.md"        . "Timers")
      ("tcp.md"           . "TCP and streams")
      ("flow-control.md"  . "Flow control")
      ("processes.md"     . "Processes and pipes")
      ("signals.md"       . "Signals")
      ("dns.md"           . "DNS")
      ("errors.md"        . "Errors")
      ("reference.md"     . "API reference")
      ("building.md"      . "Building and testing"))))
