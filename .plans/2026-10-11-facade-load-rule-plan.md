# Rule 13: a public verb reaches native code only once it is loaded

## The bug class

Importing `(libuv)` loads the shim and resolves every foreign binding, but
checks no version, reads no constant and validates no `uv_buf_t` layout.
`ensure-native-loaded!` does all three, once per process. Every constructor
calls it, so a verb that takes a loop, handle or request runs after one
has. A verb that takes none of these has had nothing run before it, and
must load for itself. `uv-kill!` did not: as a process's first call it
raised `'constants-not-initialized` (fixed in #137). Nothing held the rule,
and the next loop-free verb could forget the same way.

## Measured (probe on 6766f8d, the suite's own scan)

Of the exports of `(libuv)`, those that reach a foreign binding or a
constant reader (`reaching` over foreign bindings and `require-initialized`):

- **name `ensure-native-loaded!` in their own definition:** `make-uv-loop`,
  `call-with-uv-loop`, `make-uv-timer`, `make-uv-tcp`, `make-uv-pipe`,
  `make-uv-signal`, `make-uv-async`, `uv-kill!`, `uv-os-getpid`,
  `uv-version-compatible?`, and `uv-version` (facade's own definition; the
  name-keyed probe found native.sls's same-named binding first).
- **take a loop** (name `require-loop`): `uv-run`, `uv-stop!`,
  `uv-loop-alive?`, `uv-now`, `uv-update-time!`, `uv-loop-close!`,
  `uv-loop-teardown!`, `uv-getaddrinfo!`, `uv-getnameinfo!`, `uv-spawn!`
  (which also reaches a load through a helper).
- **take a handle** (name `require-open-handle`, or `uv-async-record?`): every
  timer, tcp, stream, signal, buffer-size and process verb, and
  `uv-async-send!`.
- **take a request** (name `uv-dns-request?`): `uv-cancel!`.

`uv-close!` reaches no foreign binding the scan sees: its close is installed
at run time (`install-close-handle!`). `uv-loop-open?`, the predicates, the
record accessors and the condition vocabulary reach nothing native.

## Design

1. **A table in test-source-rules.sps, `native-verbs`:** every export of
   `(libuv)` that reaches native code, each with one word:
   `loads`, `loop`, `handle` or `request`.
2. **Coverage, both ways:** the table's names equal the facade exports that
   reach native code (each side non-empty on its own, as rule 9's row is).
   A new export that reaches native code fails until listed, and a listed
   one that stops reaching it fails until removed.
3. **Each word checked against the source,** on the definition the export
   names: `(libuv)`'s own definition when `src/libuv.sls` defines it,
   otherwise the one in the public library under `src/libuv/` that defines
   and exports it. This is keyed by file, not name, since `uv-version` is
   defined in both `src/libuv.sls` and `native.sls`.
   - `loads`: the definition names `ensure-native-loaded!`.
   - `loop`: it names `require-loop`, `require-open-loop` or
     `require-loop-thread`, or reaches one.
   - `handle`: it names `require-open-handle`, `require-handle`, or a
     handle record predicate (`uv-async-record?`, `uv-process-record?`…), or
     reaches one.
   - `request`: it names `uv-dns-request?`.
4. **The order the scan cannot see, run instead:** a child program,
   `tests/first-call-child.sps`, generalizing `first-kill-child.sps`, makes
   one `loads` verb the first call in a fresh process and reports
   `native-initialized?` before (`#f`) and after (`#t`), plus the verb's
   result. A new suite, `tests/test-first-call.sps`, runs it once per
   `loads` verb, through `child-run`. The rows test-process.sps has for
   `uv-kill!` move there. "After" is what makes a row fail for a verb that
   never loads but needs no constant, such as `uv-os-getpid` without its
   load: it answers a pid either way.
5. **The child's verb list is the table's `loads` words:** test-source-rules
   reads the child's list from source, as rule 9 reads the hand-back
   sweep's, and fails when they differ. So a new `loads` verb is run as a
   first call too.

## What the scan cannot see (stated in the rule)

- a reach through a procedure installed at run time (`uv-close!`);
- a name imported under another one;
- for `loop`/`handle`/`request`, that the check comes before the first
  constant read: a verb that reads a constant before checking its argument
  raises `'constants-not-initialized` for a non-record argument, not the
  argument's refusal. It is not a crash, and every verb today checks first.

## Mutations planned

- Each `loads` verb's `(ensure-native-loaded!)` removed: rule 13's word check
  fails, and that verb's first-call row fails on "after" (or on its errno
  for `uv-kill!`).
- Load moved after the constant read in `uv-kill!`: the `'sigterm` first-call
  row.
- A new exported verb reaching a foreign binding, unlisted: coverage row.
- A listed verb's word changed (`uv-cancel!` to `loop`): word row.
- A verb dropped from the child's list: the list-agreement row.
- `uv-version`'s facade definition without its load: the word row
  (catches the file-keyed lookup).

## Not in scope

The `int` range rule (rule 14), surveyed separately.

## Revised after the adversarial review (as built)

An Opus review of this plan found the design above too loose. What was
built instead:

- **Quoted data no longer counts as a reach.** `symbols-of`, under rule 9's
  `reaching`, skipped nothing: a refusal's `'uv-getaddrinfo!` made
  `family-symbol->int` and five other dns.sls helpers "reach"
  `require-loop`, so a loop-free verb built on one would have passed the
  `loop` word. It now skips `(quote …)` forms. Rule 9's sweep agreement is
  unchanged by it.
- **Two words, chosen by argument:** `loads` for the six verbs that take no
  record (`make-uv-loop`, `call-with-uv-loop`, `uv-kill!`, `uv-os-getpid`,
  `uv-version`, `uv-version-compatible?`), and `record` for every other. The
  constructors that take a loop are `record`, though they also load.
- **`loads` holds the order:** `(ensure-native-loaded!)` must be a body form
  of the definition, with no body form ahead of it naming native code.
  Moving the load after the native call in `uv-os-getpid` fails it; the
  first-call row cannot see that, since the call answers a pid either way.
- **Resolution rows:** every export of `(libuv)` is bound by exactly one form
  in src/ (definitions, and record and condition types' clause names, which
  `src-definitions` now carries with their form's names), with
  `src/libuv.sls`'s own shadowing what it imports; and no public library
  exports a name `(libuv)` does not.
- **The sweep:** `tests/first-call-child.sps records` calls every `record`
  verb, each arity, with a symbol for its record and nothing loaded, and
  requires its own `not-a-…` refusal with nothing loaded after it. That
  holds the order the scan cannot see (a constant read before the record
  check), and covers `uv-close!`, whose close the scan cannot follow. The
  constructors and `uv-spawn!`, which load first, run last.
- **A suite of its own,** `tests/test-first-call.sps`, holds
  `first-call-verbs`; test-process's `uv-kill!` first-call rows moved there,
  and `tests/first-kill-child.sps` is gone. Tokens are short words, since
  `child-run` passes them to the shell unquoted. Every expected value is a
  sentinel, never `#f`.
- **Cross-file rows:** test-source-rules holds `first-call-verbs` to the
  `loads` words and the sweep's verbs to the `record` words, both ways.

Mutations: `.plans/facade-load-rule-mutation-log.md`.
