# The theme script's storage: mutation log

The docs site's theme script (`site/template.sls`) called `localStorage`
with no `try`. A browser that refuses the page storage throws there, and the
script stopped before it wired the toggle. The same defect and fix are in
chez-cmark-gfm (its PR #25), whose site generator this one copies; the
fixed script is byte-for-byte the same in both.

The live site served the unguarded script: the `<script>` fetched from
https://kiyomi-computation-systems.github.io/chez-libuv/ matched, byte for
byte, the one origin/main's template renders.

## The row

`tests/site-unit.sps`'s new row, "the theme script reaches localStorage
twice, each time inside a try block", expects `(2 ())`: two accesses, none
outside a try block.

- Before the fix, on the worktree, `make check-site`: it fails by name (53
  passed, 1 failed).
- After: 54 passed.

Mutants, each in a full copy of the worktree outside the repository
(`$SCRATCH/libuv-theme-copy`), run under the copy's own `scripts/guix-env`.
The copy's `build/scheme-libs/srfi` links were re-pointed at its own
`vendor/chez-srfi`. The container has no python3, so each mutated template
was made on the host and swapped in:

| Mutant | Result |
|---|---|
| T1: `g` reads `localStorage.getItem` with no try | the row fails by name, 53 passed |
| T2: `p` closes its try before `setItem` (`try{}catch(e){}localStorage.setItem(…)`) | the row fails by name, 53 passed |
| T3: a third, guarded access (`localStorage.length` inside `p`'s try) | the row fails by name, 53 passed |
| none | 54 passed |

The host has no libcmark-gfm, which `site-unit.sps` loads, so the row
cannot run with host Chez.

## Behaviour, checked under node

`.plans/theme-script-print.sps` prints the script as a rendered page carries
it, and `.plans/theme-storage-probe.js` runs it under node (`guix shell
node`, v24.18.0) with a stub document, after load and after one click on
the toggle:

| Storage | origin/main's script | fixed script |
|---|---|---|
| works | `light`, "Dark mode"; click → `dark`, "Light mode"; stored `dark` | the same |
| access throws `SecurityError` (site data blocked) | throws; no mode set, label left as written, toggle not wired | `light`, "Dark mode"; click → `dark`, "Light mode" |
| `setItem` throws (some private modes) | throws; mode set, label left as written, toggle not wired | the same as above |

## Gates

`make site-deps` on the host (it downloads the locked chez-cmark-gfm), then
in the container: `make check-site` (`site-unit` 54, `site-render-unit` 16,
`site-check` all green) and `make check-history` (133 files).
