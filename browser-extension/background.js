// FreeDM background service worker (MV3).
// Captures browser downloads and forwards them to the native host
// over a persistent native-messaging port (Browser Protocol v1).
// Task events stream back on the same port and are mirrored into
// chrome.storage for the popup.

const HOST_NAME = 'ai.devin.freedm';
const PROTOCOL = 1;
const EXT_VERSION = '0.1.0';

let port = null;
let reqSeq = 0;
const pending = new Map(); // requestId -> {resolve, reject}
const tasks = new Map();   // taskId -> latest event snapshot

const notifPaths = new Map(); // notificationId -> outputPath

function notify(title, message) {
  chrome.notifications.create({
    type: 'basic',
    iconUrl: 'icons/icon48.png',
    title,
    message,
  });
}

// IDM-style completion popup: buttons to open the file / its folder.
// Chrome forbids opening real popups programmatically, so the
// notification is the closest allowed surface.
function notifyDone(name, outputPath) {
  const id = `done-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  if (outputPath) notifPaths.set(id, outputPath);
  chrome.notifications.create(id, {
    type: 'basic',
    iconUrl: 'icons/icon48.png',
    title: 'FreeDM — 다운로드 완료',
    message: name,
    buttons: outputPath
      ? [{ title: '파일 열기' }, { title: '폴더 열기' }]
      : [],
  });
  setTimeout(() => notifPaths.delete(id), 10 * 60 * 1000);
}

chrome.notifications.onButtonClicked.addListener((id, btn) => {
  const path = notifPaths.get(id);
  if (!path) return;
  notifPaths.delete(id);
  call(btn === 0 ? 'open' : 'reveal', { path }).catch(() => {});
});

function updateBadge() {
  const active = [...tasks.values()].filter(
    (t) => !['completed', 'failed', 'cancelled'].includes(t.status || t.type),
  ).length;
  chrome.action.setBadgeText({ text: active ? String(active) : '' });
  chrome.action.setBadgeBackgroundColor({ color: '#1565c0' });
}

function ensurePort() {
  if (port) return port;
  port = chrome.runtime.connectNative(HOST_NAME);
  port.onMessage.addListener((msg) => {
    if (msg && msg.type === 'taskEvent') {
      const p = msg.event && msg.event.params;
      if (!p) return;
      // File events carry fields at top level; media events carry a
      // TaskCodec snapshot under `task`. Normalize to a flat record.
      const rec = p.task ? { ...p.task, media: true }
                         : { ...p };
      const id = rec.taskId || (rec.task && rec.task.id) || rec.id;
      if (!id) return;
      const prev = tasks.get(id) || {};
      tasks.set(id, { ...prev, ...rec });
      // File events carry `type`; media task snapshots carry `status`.
      const st = rec.status || rec.type;
      const prevSt = prev.status || prev.type;
      if (st === 'completed' && prevSt !== 'completed') {
        const name = rec.fileName ||
            (rec.output && rec.output.fileName) ||
            (rec.outputPath || '').split(/[\\/]/).pop() || id;
        notifyDone(name, rec.outputPath);
      }
      if (st === 'failed' && prevSt !== 'failed') {
        notify('FreeDM — 다운로드 실패',
            rec.error || rec.detail || rec.lastError || id);
      }
      chrome.storage.local.set({ tasks: Object.fromEntries(tasks) });
      updateBadge();
      return;
    }
    if (msg && msg.requestId != null) {
      const h = pending.get(msg.requestId);
      if (h) {
        pending.delete(msg.requestId);
        msg.ok === false ? h.reject(new Error(msg.error)) : h.resolve(msg.result);
      }
    }
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    port = null;
    for (const h of pending.values()) h.reject(new Error('host disconnected'));
    pending.clear();
    if (err) console.warn('native host disconnected:', err.message);
  });
  return port;
}

function call(command, payload = {}) {
  return new Promise((resolve, reject) => {
    const requestId = ++reqSeq;
    pending.set(requestId, { resolve, reject });
    ensurePort().postMessage({
      protocol: PROTOCOL,
      requestId,
      source: 'extension',
      extensionVersion: EXT_VERSION,
      command,
      payload,
    });
    setTimeout(() => {
      if (pending.delete(requestId)) reject(new Error('host timeout'));
    }, 30000);
  });
}

async function cookiesFor(url) {
  try {
    const list = await chrome.cookies.getAll({ url });
    if (!list.length) return null;
    return list.map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {
    return null; // no permission for this scheme — fine
  }
}

async function sendToFreeDM({ url, referer, filename, pageUrl }) {
  const headers = {};
  const cookie = await cookiesFor(url);
  if (cookie) headers.cookie = cookie;
  const res = await call('download', {
    url,
    referer,
    pageUrl,
    suggestedFilename: filename,
    userAgent: navigator.userAgent,
    headers,
  });
  notify('FreeDM — 다운로드 시작', filename || url);
  return res.taskId;
}

// Media page (YouTube watch etc.) → host-side media pipeline.
// The engine resolves formats with yt-dlp and muxes with FFmpeg.
async function sendMediaToFreeDM(pageUrl) {
  const res = await call('media', { pageUrl });
  notify('FreeDM — 미디어 다운로드 시작', pageUrl);
  return res.taskId;
}

async function enabled() {
  const s = await chrome.storage.local.get({ enabled: true });
  return s.enabled;
}

// ---- capture: browser decided it's a download → take over ----------
chrome.downloads.onCreated.addListener(async (item) => {
  try {
    if (!(await enabled())) return;
    if (!/^https?:/.test(item.url)) return;
    if (item.state !== 'in_progress') return;
    await chrome.downloads.cancel(item.id);
    await chrome.downloads.erase({ id: item.id });
    const taskId = await sendToFreeDM({
      url: item.finalUrl || item.url,
      referer: item.referrer,
      filename: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
      pageUrl: item.referrer,
    });
    tasks.set(taskId, { taskId, type: 'progress', receivedBytes: 0 });
  } catch (e) {
    console.warn('capture failed, leaving browser download off', e);
    notify('FreeDM — 전송 실패 (브라우저 다운로드로 복구)', String(e));
    // If capture failed after cancel, restart it in the browser.
    try { await chrome.downloads.download({ url: item.url }); } catch {}
  }
});

// ---- context menu ----------------------------------------------------
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'freedm-link',
    title: 'Download with FreeDM',
    contexts: ['link'],
  });
  chrome.contextMenus.create({
    id: 'freedm-page',
    title: 'Download this page media with FreeDM',
    contexts: ['page', 'video', 'audio'],
  });
  chrome.contextMenus.create({
    id: 'freedm-selected',
    title: 'Download selected links with FreeDM',
    contexts: ['selection'],
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === 'freedm-link' && info.linkUrl) {
      await sendToFreeDM({
        url: info.linkUrl, pageUrl: info.pageUrl, referer: info.pageUrl,
      });
    } else if (info.menuItemId === 'freedm-page') {
      // Direct media file URL → engine download; embedded/blob
      // players (YouTube…) → media pipeline on the page URL.
      const src = info.srcUrl || '';
      if (/^https?:/.test(src)) {
        await sendToFreeDM({
          url: src, pageUrl: info.pageUrl, referer: info.pageUrl,
        });
      } else {
        await sendMediaToFreeDM(info.pageUrl);
      }
    } else if (info.menuItemId === 'freedm-selected' && tab) {
      const [r] = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => {
          const sel = window.getSelection();
          const urls = new Set();
          if (sel && sel.rangeCount) {
            const frag = sel.getRangeAt(0).cloneContents();
            frag.querySelectorAll('a[href]').forEach((a) => urls.add(a.href));
          }
          // also catch plain-text selected URLs
          (sel ? sel.toString() : '')
            .match(/https?:\/\/[^\s"'<>]+/g)?.forEach((u) => urls.add(u));
          return [...urls];
        },
      });
      for (const url of r.result || []) {
        await sendToFreeDM({ url, pageUrl: info.pageUrl, referer: info.pageUrl });
      }
    }
  } catch (e) {
    console.warn('context-menu send failed', e);
    notify('FreeDM — 전송 실패', String(e));
  }
});

// ---- messages from the popup ------------------------------------------
chrome.runtime.onMessage.addListener((m, _s, send) => {
  (async () => {
    if (m.cmd === 'ping') send(await call('ping'));
    else if (m.cmd === 'pause' || m.cmd === 'resume' || m.cmd === 'cancel') {
      send(await call(m.cmd, { taskId: m.taskId }));
    } else if (m.cmd === 'status') {
      send(await call('status', { taskId: m.taskId }));
    }
  })().catch((e) => send({ ok: false, error: String(e) }));
  return true; // async response
});
