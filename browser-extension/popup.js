// Popup: enable toggle, host health, live task list.
const $ = (s) => document.querySelector(s);

function fmt(n) {
  if (n == null) return '?';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(1)} ${u[i]}`;
}

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
    const pct = t.totalBytes ? Math.round(100 * (t.receivedBytes || 0) / t.totalBytes) : 0;
    div.innerHTML = `
      <div class="id">${id.slice(0, 12)}… — ${t.type || '?'}</div>
      <progress max="100" value="${pct}"></progress>
      <div>${fmt(t.receivedBytes)} / ${fmt(t.totalBytes)}
        <button data-a="pause">⏸</button>
        <button data-a="resume">▶</button>
        <button data-a="cancel">✕</button></div>`;
    div.querySelectorAll('button').forEach((b) => {
      b.onclick = async () => { await sendBg({ cmd: b.dataset.a, taskId: id }); };
    });
    box.appendChild(div);
  }
}

$('#enabled').onchange = (e) =>
  chrome.storage.local.set({ enabled: e.target.checked });
chrome.storage.onChanged.addListener(refresh);
refresh();
setInterval(refresh, 3000);
