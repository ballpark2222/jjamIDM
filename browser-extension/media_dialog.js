// Media quality dialog — opened as an extension window by
// background.js when the floating chip / context menu targets a
// media page. Probes formats via the host, offers real qualities,
// submits the pick back for media.enqueue.
const $ = (s) => document.querySelector(s);
const token = location.hash.slice(1);

function fmtSize(b) {
  if (!b) return '';
  const u = ['B', 'KB', 'MB', 'GB'];
  let v = b, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return ` · ${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
}

function addOption(label, meta, v, a, checked) {
  const l = document.createElement('label');
  l.className = 'fmt';
  const r = document.createElement('input');
  r.type = 'radio';
  r.name = 'fmt';
  if (checked) r.checked = true;
  r.dataset.v = v || '';
  r.dataset.a = a || '';
  const q = document.createElement('span');
  q.className = 'q';
  q.textContent = label;
  const metaEl = document.createElement('span');
  metaEl.className = 'meta';
  metaEl.textContent = meta;
  l.append(r, q, metaEl);
  $('#formats').appendChild(l);
}

function renderProbe(r) {
  const status = $('#probe-status');
  if (status) status.remove();
  const list = $('#formats');
  if (!r || r.error) {
    list.innerHTML =
        `<div id="probe-status">형식 확인 실패: ${r?.error || '응답 없음'}</div>`;
    addOption('최고 화질 (자동)', '기본값으로 시도', null, null, true);
    $('#now').disabled = false;
    return;
  }
  if (r.supported === false) {
    list.innerHTML =
        '<div id="probe-status">지원하지 않는 페이지일 수 있습니다 — 그래도 시도할 수 있습니다.</div>';
    addOption('최고 화질 (자동)', '기본값으로 시도', null, null, true);
    $('#now').disabled = false;
    return;
  }
  if (r.title && !$('#filename').value) $('#filename').value = r.title;

  const fmts = Array.isArray(r.formats) ? r.formats : [];
  const vids = fmts.filter((f) => f.hasVideo);
  const auds = fmts.filter((f) => f.hasAudio && !f.hasVideo);
  // Best audio for pairing with video-only formats — highest
  // bitrate/size wins, mp4-family first for mux compatibility.
  const bestAudio = auds.slice().sort((a, b) =>
      (b.bitrateKbps || b.filesizeBytes || 0) -
      (a.bitrateKbps || a.filesizeBytes || 0))[0];

  // Auto = resolver default (yt-dlp best).
  addOption('최고 화질 (자동)', '', null, null, true);

  const seen = new Set();
  vids.sort((a, b) =>
      (b.height || 0) - (a.height || 0) ||
      (b.filesizeBytes || 0) - (a.filesizeBytes || 0));
  for (const f of vids) {
    const key = `${f.height || 0}|${f.ext}|${f.hasAudio ? 1 : 0}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const q = f.height ? `${f.height}p` : (f.label || f.formatId);
    const kind = f.hasAudio
        ? '영상+음성'
        : bestAudio ? '영상+최고음성' : '무음';
    const meta =
        `${f.ext || ''} · ${kind}` +
        (f.bitrateKbps ? ` · ${f.bitrateKbps}kbps` : '') +
        fmtSize(f.filesizeBytes);
    addOption(q, meta, f.formatId, f.hasAudio ? null : bestAudio?.formatId);
  }
  for (const f of auds) {
    const meta =
        `${f.ext || ''} · 음성만` +
        (f.bitrateKbps ? ` · ${f.bitrateKbps}kbps` : '') +
        fmtSize(f.filesizeBytes);
    addOption(f.label || '음성', meta, null, f.formatId);
  }

  const subs = Array.isArray(r.subtitles) ? r.subtitles : [];
  if (subs.length) {
    $('#subs-wrap').style.display = '';
    const box = $('#subs');
    const langs = [...new Set(subs.map((s) => s.lang))].sort();
    for (const lang of langs) {
      const l = document.createElement('label');
      const c = document.createElement('input');
      c.type = 'checkbox';
      c.value = lang;
      l.append(c, document.createTextNode(` ${lang}`));
      box.appendChild(l);
    }
  }
  $('#now').disabled = false;
}

async function submit() {
  const sel = document.querySelector('input[name=fmt]:checked');
  const subtitleLangs =
      [...document.querySelectorAll('#subs input:checked')]
          .map((c) => c.value);
  $('#err').textContent = '';
  $('#now').disabled = true;
  const r = await chrome.runtime.sendMessage({
    cmd: 'mediaDone',
    token,
    videoFormatId: sel?.dataset.v || undefined,
    audioFormatId: sel?.dataset.a || undefined,
    outputFileName: $('#filename').value.trim() || undefined,
    subtitleLangs,
  });
  if (r?.error) {
    $('#err').textContent = r.error;
    $('#now').disabled = false;
    return;
  }
  window.close();
}

async function init() {
  const req = await chrome.runtime.sendMessage({ cmd: 'mediaDialogGet', token });
  if (!req || req.error) {
    $('#probe-status').textContent = '요청을 찾을 수 없습니다.';
    return;
  }
  $('#url').textContent = req.pageUrl;
  $('#now').onclick = submit;
  $('#cancel').onclick = () => {
    chrome.runtime.sendMessage({ cmd: 'mediaCancel', token })
        .finally(() => window.close());
  };
  // Enter anywhere except a checkbox submits — same convention as
  // the file dialog.
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.isComposing &&
        e.target.type !== 'checkbox' && !$('#now').disabled) {
      submit();
    }
  });
  const r = await chrome.runtime.sendMessage({ cmd: 'mediaProbe', token });
  renderProbe(r);
}

init();
