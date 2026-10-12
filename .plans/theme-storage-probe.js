// The theme script under storage that works, throws on access (site data
// blocked) and refuses setItem (some private modes). Prints what the page
// would show after load and after one click on the toggle, as JSON lines.
//   CHEZSCHEMELIBDIRS=.:build/akku/chez-cmark-gfm/src:build/scheme-libs scheme --program .plans/theme-script-print.sps > /tmp/theme.js
//   guix shell node -- node .plans/theme-storage-probe.js /tmp/theme.js
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
function run(mode) {
  const attrs = {}, label = { textContent: '(static)' }; let handler = null; const store = {};
  const sandbox = {
    document: { documentElement: { setAttribute: (k, v) => { attrs[k] = v; }, getAttribute: k => attrs[k] },
                getElementById: id => id === 'theme' ? { addEventListener: (e, f) => { handler = f; } } : label },
    matchMedia: () => ({ matches: false }) };
  if (mode === 'works') sandbox.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
  if (mode === 'set-throws') sandbox.localStorage = { getItem: () => null, setItem: () => { throw new Error('QuotaExceededError'); } };
  let error = null;
  const ctx = vm.createContext(sandbox);
  if (mode === 'getter-throws')
    vm.runInContext("Object.defineProperty(globalThis, 'localStorage', { get() { throw new Error('SecurityError'); } });", ctx);
  try { vm.runInContext(src, ctx); } catch (e) { error = e.message; }
  const out = { mode, error, load: [attrs['data-mode'], label.textContent], wired: !!handler };
  if (handler) { handler(); out.click = [attrs['data-mode'], label.textContent]; }
  if (mode === 'works') out.stored = store.theme;
  return out;
}
for (const m of ['works', 'getter-throws', 'set-throws']) console.log(JSON.stringify(run(m)));
