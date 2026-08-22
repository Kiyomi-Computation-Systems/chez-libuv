# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.4.x (latest) | ✅ |
| < 0.4 | ❌ |

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub:
**Security → Report a vulnerability** on this repository. Do not open a
public issue.

You can expect an acknowledgement within 7 days.

This is an FFI binding around a C library: reports touching the native
boundary (memory safety, lifetime bugs, argument validation) are
especially welcome. Please include your platform, Chez version, and
`make deps-info` output where relevant.
