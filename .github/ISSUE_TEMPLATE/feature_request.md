---
name: Feature request
about: Propose an addition to the binding
labels: enhancement
---

**The problem**

What can't you do today?

**Proposed API surface**

Which module does it belong to (`(libuv tcp)`, `(libuv process)`, a new
one), and what would the exports look like?

**Does it mirror an existing libuv verb?**

This binding is a legible mirror of libuv's own vocabulary. If the
proposal wraps an existing `uv_*` function, name it. If it invents
vocabulary libuv doesn't have, expect a design conversation first —
see `CONTRIBUTING.md` in the repository root.
