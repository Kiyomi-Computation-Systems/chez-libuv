# Task 3 Mutation Probes: process/pipe constants + counters

## Probe 1: Delete SIGTERM constant row

**Mutation:** Deleted `{ "SIGTERM", SIGTERM },` from `src/libuv-shim.c` constant table.

**Build & test output:**
```
=== tests/test-native.sps ===
%%%% Starting test native
Exception occurred with condition components:
  0. &uv-constant-unavailable: SIGTERM
```

**Result:** GREEN (failure detected). The init at constants-init! failed with the expected structured error: `&uv-constant-unavailable` naming the missing constant `SIGTERM`.

---

## Probe 2: Delete OFFSETOF_UV_PROCESS_OPTIONS_T_FILE constant row

**Mutation:** Deleted `{ "OFFSETOF_UV_PROCESS_OPTIONS_T_FILE", ... },` from `src/libuv-shim.c` constant table.

**Build & test output:**
```
=== tests/test-native.sps ===
%%%% Starting test native
Exception occurred with condition components:
  0. &uv-constant-unavailable: OFFSETOF_UV_PROCESS_OPTIONS_T_FILE
```

**Result:** GREEN (failure detected). The init at constants-init! failed with the expected structured error: `&uv-constant-unavailable` naming the missing constant `OFFSETOF_UV_PROCESS_OPTIONS_T_FILE`.

---

## Verification

Both probes confirm:
1. The constant table rows are actually read and validated at init time
2. Missing constants raise fail-closed (ADR-0005), not silent defaults
3. The accessor "every options offset lies inside the struct" test assertion catches the omission
