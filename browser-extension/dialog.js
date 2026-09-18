// Download-start dialog — opened as an extension window by
// background.js. The pending request rides in the URL hash token;
// edits come back via runtime messages and the window closes.
const $ = (s) => document.querySelector(s);
const token = location.hash.slice(1);

// An absolute dir returned by the host's OS folder picker — the
// only kind of absolute path a download may target.
let pickedAbs = null;

async function init() {
  const { settings } = await chrome.storage.local.get({ settings: {} });
  const req = await chrome.runtime.sendMessage({ cmd: 'dialogGet', token });
  if (!req || req.error) {
    $('#err').textContent = '요청을 찾을 수 없습니다.';
    return;
  }
  $('#url').textContent = req.url;
  // Split the suggested name into stem + ext — the two boxes are
  // edited independently and recombined on submit.
  const raw = req.filename || guessName(req.url);
  const dot = raw.lastIndexOf('.');
  if (dot > 0 && /^[A-Za-z0-9]{1,10}$/.test(raw.slice(dot + 1))) {
    $('#filename').value = raw.slice(0, dot);
    $('#ext').value = raw.slice(dot + 1);
  } else {
    $('#filename').value = raw;
  }
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

  // Browse → host opens the OS folder dialog. Inside downloadDir it
  // comes back as a relative subdir; outside, as a consent-picked
  // absolute path (absDir).
  $('#browse').onclick = async () => {
    $('#err').textContent = '';
    const r = await chrome.runtime.sendMessage({ cmd: 'pickFolder' });
    if (!r || r.cancelled) return;
    if (r.error) { $('#err').textContent = r.error; return; }
    if (r.absDir) {
      pickedAbs = r.absDir;
      $('#customdir').value = r.absDir;
    } else if (typeof r.subdir === 'string') {
      pickedAbs = null;
      $('#customdir').value = r.subdir;
    }
  };
  // Editing the box after a pick demotes it back to a plain subdir
  // string — a typed absolute path is never sent as absDir.
  $('#customdir').addEventListener('input', () => {
    if (pickedAbs && $('#customdir').value.trim() !== pickedAbs) {
      pickedAbs = null;
    }
  });
  // Choosing a preset from the dropdown clears the custom/picked
  // folder — one folder source wins, never a silent mix.
  sel.addEventListener('change', () => {
    pickedAbs = null;
    $('#customdir').value = '';
  });

  const done = (startNow) => async () => {
    const custom = $('#customdir').value.trim();
    if (!pickedAbs && (custom.includes(':') || custom.startsWith('\\')
        || custom.startsWith('/'))) {
      $('#err').textContent =
          '절대 경로는 찾아보기 버튼으로 선택하세요.';
      return;
    }
    const ext = $('#ext').value.trim()
        .replace(/^\.+/, '').replace(/[\\/:*?"<>|.]/g, '');
    const stem = $('#filename').value.trim();
    if (!stem) {
      $('#err').textContent = '파일 이름을 입력하세요.';
      return;
    }
    // Don't double up — 'a.mp4' + ext 'mp4' stays 'a.mp4'.
    const already = ext
        && stem.toLowerCase().endsWith(`.${ext.toLowerCase()}`);
    const r = await chrome.runtime.sendMessage({
      cmd: 'dialogDone',
      token,
      startNow,
      filename: !ext || already ? stem : `${stem}.${ext}`,
      subdir: pickedAbs ? undefined : (custom || sel.value),
      absDir: pickedAbs || undefined,
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

  // Enter in any text field = 지금 받기. isComposing guards Korean
  // IME — an Enter that only commits a syllable must not submit.
  for (const el of document.querySelectorAll('input')) {
    el.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.isComposing) {
        e.preventDefault();
        $('#now').click();
      }
    });
  }
}

function guessName(url) {
  try {
    const seg = new URL(url).pathname.split('/').filter(Boolean);
    return decodeURIComponent(seg.pop() || 'download.bin');
  } catch { return 'download.bin'; }
}

init();
