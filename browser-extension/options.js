// Options page — persists the `settings` object used by
// background.js (capture filters, folders, limits, UI toggles).
const $ = (s) => document.querySelector(s);

const DEFAULTS = {
  notifications: true,
  askBeforeDownload: true,
  floatingButton: true,
  maxConnections: 8,
  captureFilter: '',
  excludeFilter: '',
  typeFolders: '',
  excludedSites: '',
};

async function load() {
  const { settings } = await chrome.storage.local.get({ settings: {} });
  const s = { ...DEFAULTS, ...settings };
  $('#maxConnections').value = s.maxConnections;
  $('#askBeforeDownload').checked = s.askBeforeDownload;
  $('#notifications').checked = s.notifications;
  $('#floatingButton').checked = s.floatingButton;
  $('#typeFolders').value = s.typeFolders;
  $('#captureFilter').value = s.captureFilter;
  $('#excludeFilter').value = s.excludeFilter;
  $('#excludedSites').value = s.excludedSites;
}

$('#save').onclick = async () => {
  const settings = {
    notifications: $('#notifications').checked,
    askBeforeDownload: $('#askBeforeDownload').checked,
    floatingButton: $('#floatingButton').checked,
    maxConnections: Math.min(16, Math.max(1, +$('#maxConnections').value || 8)),
    captureFilter: $('#captureFilter').value.trim(),
    excludeFilter: $('#excludeFilter').value.trim(),
    typeFolders: $('#typeFolders').value.trim(),
    excludedSites: $('#excludedSites').value.trim(),
  };
  await chrome.storage.local.set({ settings });
  $('#saved').textContent = '저장됨';
  setTimeout(() => { $('#saved').textContent = ''; }, 2000);
};

// ---- download history --------------------------------------------------
// Reads the same persisted `tasks` map the popup uses — records carry
// status/type, bytes, fileName/outputPath, and a last-activity stamp.
const STATUS_LABELS = {
  completed: '완료', failed: '실패', cancelled: '취소됨',
  progress: '다운로드 중', downloading: '다운로드 중',
  downloadingVideo: '영상 다운로드', downloadingAudio: '음성 다운로드',
  resolving: '분석 중', resolvingMedia: '미디어 분석 중',
  resolved: '분석 완료', ready: '대기 중', queued: '대기열',
  created: '생성됨', paused: '일시정지', pausing: '일시정지 중',
  verifying: '검증 중', muxing: '합치는 중',
  subtitleProcessing: '자막 처리', retryWait: '재시도 대기',
};
const DOT = { completed: 'ok', failed: 'err', cancelled: 'etc' };

function fmtBytes(n) {
  if (!n && n !== 0) return '?';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
}

function nameOf(t, id) {
  const base = (p) => (p || '').split(/[\\/]/).pop();
  return t.fileName || (t.output && t.output.fileName)
      || base(t.outputPath)
      || base((t.url || (t.source && t.source.initialUrl) || '')
          .split('?')[0])
      || id;
}

function tsOf(t) {
  if (t.seenAt) return t.seenAt;                    // ms epoch (stamped)
  const iso = t.updatedAt || t.createdAt;           // media snapshots
  const ms = iso ? Date.parse(iso) : 0;
  return Number.isFinite(ms) ? ms : 0;
}

async function renderHistory() {
  const { tasks } = await chrome.storage.local.get({ tasks: {} });
  const rows = Object.entries(tasks)
    .map(([id, t]) => ({ id, t, ts: tsOf(t) }))
    .sort((a, b) => b.ts - a.ts)
    .slice(0, 200);
  const box = $('#hist');
  box.textContent = '';
  if (!rows.length) {
    const d = document.createElement('div');
    d.id = 'histEmpty';
    d.textContent = '기록 없음';
    box.appendChild(d);
    return;
  }
  for (const { id, t, ts } of rows) {
    const st = t.status || t.type || '?';
    const row = document.createElement('div');
    row.className = 'hrow';

    const dot = document.createElement('span');
    dot.className = `hdot ${DOT[st] || 'run'}`;
    dot.title = STATUS_LABELS[st] || st;

    const name = document.createElement('span');
    name.className = 'hname';
    name.textContent = (t.media ? '[미디어] ' : '') + nameOf(t, id);
    name.title = t.outputPath || t.url ||
        (t.source && t.source.initialUrl) || '';

    const meta = document.createElement('span');
    meta.className = 'hmeta';
    const size = t.totalBytes || t.receivedBytes;
    const when = ts ? new Date(ts).toLocaleString('ko-KR',
        { month: 'short', day: 'numeric',
          hour: '2-digit', minute: '2-digit' }) : '';
    meta.textContent =
        `${STATUS_LABELS[st] || st} · ${fmtBytes(size)} · ${when}`;
    // Why it failed — the stored ErrorCode alone ('unknown') tells
    // the user nothing; the engine's detail does.
    const why = st === 'failed' &&
        (t.lastErrorDetail || (t.metadata && t.metadata.lastErrorDetail));
    if (why) {
      meta.textContent = `${STATUS_LABELS[st]} · ${why}`;
      meta.title = `${t.error || t.lastError || ''} — ${why}`;
    }

    row.append(dot, name, meta);
    if (st === 'completed' && t.outputPath) {
      for (const [cmd, label] of [['open', '열기'], ['reveal', '폴더']]) {
        const b = document.createElement('button');
        b.className = 'hbtn';
        b.textContent = label;
        b.onclick = () =>
            chrome.runtime.sendMessage({ cmd, path: t.outputPath });
        row.appendChild(b);
      }
    }
    box.appendChild(row);
  }
}

$('#clearHist').onclick = async () => {
  await chrome.runtime.sendMessage({ cmd: 'clearHistory' });
  renderHistory();
};

// Live-update while the options page is open — the background flush
// writes `tasks` to storage.local and fires this listener.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.tasks) renderHistory();
});

load();
renderHistory();
