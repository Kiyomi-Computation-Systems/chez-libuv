---
name: Bug report
about: Something broke or behaved unexpectedly
labels: bug
---

**Environment**

- OS and architecture (e.g. macOS 15 arm64, Ubuntu 24.04 x86_64):
- Chez Scheme version (`chez --version`):
- libuv acquisition path and version (paste `make deps-info` output; add
  `(uv-version)` if the library loads):

**What happened**

**What you expected**

**Minimal reproduction**

Ideally a small standalone `.sps` program, run as
`CHEZSCHEMELIBDIRS=src chez --program repro.sps`.

**Does `make test` pass locally?**
