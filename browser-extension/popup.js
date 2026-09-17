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
};

async function sendBg(m) {
  return chrome.runtime.sendMessage(m);
}

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
  box.innerHTML = '';
  for (const [id, t] of Object.entries(tasks).slice(-15).reverse()) {
    const div = document.createElement('div');
    div.className = 'task';
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
    div.innerHTML = `
      <div class="id">${id.slice(0, 12)}… — ${label}</div>
      <progress max="100" value="${pct}"></progress>
      <div>${fmt(t.receivedBytes)} / ${fmt(t.totalBytes)}
        ${dead ? '' : `
        <button data-a="pause">⏸</button>
        <button data-a="resume">▶</button>
        <button data-a="cancel">✕</button>`}</div>`;
    div.querySelectorAll('button').forEach((b) => {
      b.onclick = async () => { await sendBg({ cmd: b.dataset.a, taskId: id }); };
    });
    box.appendChild(div);
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
