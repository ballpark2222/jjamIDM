// Download-start dialog — opened as an extension window by
// background.js. The pending request rides in the URL hash token;
// edits come back via runtime messages and the window closes.
const $ = (s) => document.querySelector(s);
const token = location.hash.slice(1);

async function init() {
  const { settings } = await chrome.storage.local.get({ settings: {} });
  const req = await chrome.runtime.sendMessage({ cmd: 'dialogGet', token });
  if (!req || req.error) {
    $('#err').textContent = '요청을 찾을 수 없습니다.';
    return;
  }
  $('#url').textContent = req.url;
  $('#filename').value = req.filename || guessName(req.url);
  $('#conns').value = req.maxConnections || settings.maxConnections || 8;

  // Folder dropdown = configured type folders + the rule's pick.
  const subs = new Set();
  for (const line of (settings.typeFolders || '').split('\n')) {
    const m = line.split('=');
    if (m[1] && m[1].trim()) subs.add(m[1].trim());
  }
  const sel = $('#subdir');
  for (const name of subs) {
    const o = document.createElement('option');
    o.value = name; o.textContent = name;
    sel.appendChild(o);
  }
  if (req.subdir) sel.value = req.subdir;

  const done = (startNow) => async () => {
    const r = await chrome.runtime.sendMessage({
      cmd: 'dialogDone',
      token,
      startNow,
      filename: $('#filename').value.trim(),
      subdir: sel.value,
      maxConnections: Math.min(16, Math.max(1, +$('#conns').value || 8)),
    });
    if (r && r.error) $('#err').textContent = r.error;
    else window.close();
  };
  $('#now').onclick = done(true);
  $('#later').onclick = done(false);
  $('#cancel').onclick = () =>
    chrome.runtime.sendMessage({ cmd: 'dialogCancel', token })
        .finally(() => window.close());
}

function guessName(url) {
  try {
    const seg = new URL(url).pathname.split('/').filter(Boolean);
    return decodeURIComponent(seg.pop() || 'download.bin');
  } catch { return 'download.bin'; }
}

init();
