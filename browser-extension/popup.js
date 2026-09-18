// Popup: enable toggle, host health, live task list.
const $ = (s) => document.querySelector(s);

function fmt(n) {
  if (n == null) return '?';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(1)} ${u[i]}`;
}

const LABELS = {
  created: '대기열에 보류', resolving: '분석 중', ready: '대기 중',
  downloading: '다운로드 중', progress: '다운로드 중',
  pausing: '일시정지 중', paused: '일시정지', retryWait: '재시도 대기',
  verifying: '검증 중', postProcessing: '후처리 중',
  resolvingMedia: '미디어 분석 중', downloadingVideo: '영상 다운로드',
  downloadingAudio: '오디오 다운로드', muxing: '합치는 중',
  subtitleProcessing: '자막 처리',
  completed: '완료', failed: '실패', cancelled: '취소됨',
  urlExpired: '링크 만료 — 재시도 대기',
};

async function sendBg(m) {
  return chrome.runtime.sendMessage(m);
}

// Persistent rows — refresh() runs on every 400ms storage flush
// during active downloads; rebuilding innerHTML each pass made the
// list flash. Rows are created once, then only their fields and
// (on mode change) buttons are touched.
const rows = new Map(); // taskId -> {div, idEl, bar, bytes, btns, mode}

async function refresh() {
  const { enabled } = await chrome.storage.local.get({ enabled: true });
  $('#enabled').checked = enabled;
  try {
    const r = await sendBg({ cmd: 'ping' });
    $('#status').textContent = r && r.ok !== false && r.engineReachable
      ? 'engine: up' : 'engine: down';
  } catch {
    $('#status').textContent = 'host: unreachable';
  }
  const { tasks } = await chrome.storage.local.get({ tasks: {} });
  const box = $('#tasks');
  const seen = new Set();
  for (const [id, t] of Object.entries(tasks).slice(-15).reverse()) {
    seen.add(id);
    const st = t.status || t.type || '?';
    const terminal = ['completed', 'failed', 'cancelled'].includes(st);
    const stLabel = LABELS[st] || st;
    // Engine was restarted → task unknown → controls can't work.
    let dead = terminal;
    // media tasks live in the coordinator — task.status doesn't know
    // them, so the liveness probe only applies to engine tasks.
    if (!dead && !t.media) {
      try {
        const r = await sendBg({ cmd: 'status', taskId: id });
        if (r && r.known === false) dead = true;
      } catch { dead = true; }
    }
    const label = dead && !terminal ? `${stLabel} — 종료됨` : stLabel;
    const pct = t.totalBytes ? Math.round(100 * (t.receivedBytes || 0) / t.totalBytes) : 0;
    // Completed → open/reveal buttons (host validates the path is
    // under downloadDir, same as the notification buttons).
    const openable = st === 'completed' && t.outputPath;
    const mode = dead
      ? (openable ? 'open' : 'none')
      : 'ctl';
    let row = rows.get(id);
    if (!row) {
      const div = document.createElement('div');
      div.className = 'task';
      div.innerHTML = '<div class="id"></div><progress max="100"></progress>'
        + '<div class="bytes"></div><div class="btns"></div>';
      row = {
        div,
        idEl: div.querySelector('.id'),
        bar: div.querySelector('progress'),
        bytes: div.querySelector('.bytes'),
        btns: div.querySelector('.btns'),
        mode: null,
      };
      rows.set(id, row);
    }
    const idTxt = `${id.slice(0, 12)}… — ${label}`;
    if (row.idEl.textContent !== idTxt) row.idEl.textContent = idTxt;
    if (row.bar.value !== pct) row.bar.value = pct;
    const byteTxt = `${fmt(t.receivedBytes)} / ${fmt(t.totalBytes)}`;
    if (row.bytes.textContent !== byteTxt) row.bytes.textContent = byteTxt;
    if (row.mode !== mode) {
      row.mode = mode;
      row.btns.textContent = '';
      const defs = mode === 'ctl'
        ? [['pause', '⏸'], ['resume', '▶'], ['cancel', '✕']]
        : mode === 'open'
          ? [['open', '파일 열기'], ['reveal', '폴더 열기']]
          : [];
      for (const [a, txt] of defs) {
        const b = document.createElement('button');
        b.dataset.a = a;
        b.textContent = txt;
        b.onclick = async () => {
          if (a === 'open' || a === 'reveal') {
            await sendBg({ cmd: a, path: t.outputPath });
            return;
          }
          // A parked (created/ready) task isn't paused — resume() is
          // a no-op on it; `start` admits it into the queue. Paused
          // (incl. media) tasks still go through resume.
          const cmd = a === 'resume' &&
              (st === 'created' || st === 'ready') ? 'start' : a;
          await sendBg({ cmd, taskId: id });
        };
        row.btns.appendChild(b);
      }
    }
    // Re-append in display order — moving an existing node keeps its
    // state (no teardown flicker).
    box.appendChild(row.div);
  }
  for (const [id, row] of rows) {
    if (!seen.has(id)) {
      row.div.remove();
      rows.delete(id);
    }
  }
}

$('#enabled').onchange = (e) =>
  chrome.storage.local.set({ enabled: e.target.checked });
$('#opts').onclick = (e) => {
  e.preventDefault();
  chrome.runtime.openOptionsPage();
};
chrome.storage.onChanged.addListener(refresh);
refresh();
setInterval(refresh, 3000);
