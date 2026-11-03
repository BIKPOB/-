const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const kotlin = fs.readFileSync('platform_templates/android/ConfigBrowserActivity.kt', 'utf8');
const script = kotlin.match(/val CAPTURE_SCRIPT = """([\s\S]*?)"""\.trimIndent/)[1];
const listeners = {};
let normalClicks = 0;
class Anchor { constructor(href) { this.href = href; } click() { normalClicks++; } }
const window = {};
vm.runInNewContext(script, {window, HTMLAnchorElement: Anchor,
  document: {addEventListener: (name, callback) => {listeners[name] = callback;}}, fetch});
(async () => {
  const profile = '[Interface]\nPrivateKey = fixture\n[Peer]\nPublicKey = fixture\n';
  const uri = URL.createObjectURL(new Blob([profile]));
  try {
    await window.__quietVpnCapture(uri);
    assert.equal(window.__quietVpnDownloaded, profile);
    window.__quietVpnDownloaded = null;
    await window.__quietVpnCapture('data:text/plain,' + encodeURIComponent(profile));
    assert.equal(window.__quietVpnDownloaded, profile);
    window.__quietVpnDownloaded = null;
    await window.__quietVpnCapture('data:text/plain,' + encodeURIComponent('[Interface]\n[Peer]\n' + 'a'.repeat(131073)));
    assert.equal(window.__quietVpnDownloaded, 'ERROR_SIZE');
    window.__quietVpnDownloaded = null;
    await window.__quietVpnCapture('data:text/html,hello');
    assert.equal(window.__quietVpnDownloaded, 'ERROR_FORMAT');
    window.__quietVpnDownloaded = null;
    await window.__quietVpnCapture('https://example.invalid/never-requested');
    assert.equal(window.__quietVpnDownloaded, null);
    new Anchor('https://example.invalid/page').click();
    assert.equal(normalClicks, 1);
    new Anchor(uri).click();
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.equal(window.__quietVpnDownloaded, profile);
    assert.equal(normalClicks, 1);
    let prevented = false;
    listeners.click({target:{closest:()=>new Anchor(uri)},preventDefault:()=>{prevented=true;}});
    assert.equal(prevented, true);
    console.log('Browser capture: blob, data, anchor interception and bounds passed');
  } finally { URL.revokeObjectURL(uri); }
})().catch(error => { console.error(error); process.exitCode = 1; });
