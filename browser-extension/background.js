// jjamIDM background service worker (MV3).
// Captures browser downloads and forwards them to the native host
// over a persistent native-messaging port (Browser Protocol v1).
// Task events stream back on the same port and are mirrored into
// chrome.storage for the popup.

const HOST_NAME = 'ai.jjam.idm';
const PROTOCOL = 1;
const EXT_VERSION = '0.1.0';

let port = null;
let reqSeq = 0;
const pending = new Map(); // requestId -> {resolve, reject}
const tasks = new Map();   // taskId -> latest event snapshot
const doneNotified = new Set(); // taskIds already notified terminal

// In-session stores are bounded — the service worker is long-lived
// and we don't want unbounded growth across many downloads.
function boundedPut(map, key, value, cap) {
  map.set(key, value);
  while (map.size > cap) map.delete(map.keys().next().value);
}
const boundedAdd = (set, key, cap) =>
  boundedPut(set, key, true, cap);
const TASK_CAP = 500, SET_CAP = 1000;

const notifPaths = new Map(); // notificationId -> outputPath

// ---- user settings ---------------------------------------------------
const SETTING_DEFAULTS = {
  notifications: true,
  askBeforeDownload: true,
  floatingButton: true,
  maxConnections: 8,
  captureFilter: '',
  excludeFilter: '',
  typeFolders: '',
};
async function getSettings() {
  const { settings } = await chrome.storage.local.get({ settings: {} });
  return { ...SETTING_DEFAULTS, ...settings };
}

function extOf(url) {
  try {
    const last = new URL(url).pathname.split('/').pop() || '';
    const dot = last.lastIndexOf('.');
    return dot > 0 ? last.slice(dot + 1).toLowerCase() : '';
  } catch { return ''; }
}
const parseExtList = (s) => new Set(
    (s || '').split(',').map((x) => x.trim().toLowerCase())
        .filter(Boolean));

// Auto-capture filter: include-list (empty = all) minus exclude-list.
function passesFilter(url, s) {
  const ext = extOf(url);
  const inc = parseExtList(s.captureFilter);
  const exc = parseExtList(s.excludeFilter);
  if (exc.has(ext)) return false;
  if (inc.size && !inc.has(ext)) return false;
  return true;
}

// Type → subfolder routing ("mp4,mkv=비디오" lines → '비디오').
function subdirFor(url, filename, s) {
  const ext = extOf(filename ? `x/${filename}` : url);
  for (const line of (s.typeFolders || '').split('\n')) {
    const [exts, folder] = line.split('=');
    if (!folder) continue;
    if (parseExtList(exts).has(ext)) return folder.trim();
  }
  return '';
}

async function notify(title, message) {
  if (!(await getSettings()).notifications) return;
  chrome.notifications.create({
    type: 'basic',
    iconUrl: 'icons/icon48.png',
    title,
    message,
  });
}

// IDM-style completion popup: buttons to open the file / its folder.
// Chrome forbids opening real popups programmatically, so the
// notification is the closest allowed surface. requireInteraction
// keeps it on screen until dismissed — a transient toast is gone
// in seconds and reads as "no notification ever arrived".
async function notifyDone(name, outputPath) {
  if (!(await getSettings()).notifications) return;
  const id = `done-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  if (outputPath) notifPaths.set(id, outputPath);
  chrome.notifications.create(id, {
    type: 'basic',
    iconUrl: 'icons/icon48.png',
    title: 'jjamIDM — 다운로드 완료',
    message: name,
    requireInteraction: true,
    priority: 2,
    silent: false,
    buttons: outputPath
      ? [{ title: '파일 열기' }, { title: '폴더 열기' }]
      : [],
  }).catch((e) => console.warn('notify failed:', e));
  setTimeout(() => notifPaths.delete(id), 10 * 60 * 1000);
}

// Body click = 파일 열기 (IDM opens the file on notification click).
chrome.notifications.onClicked.addListener((id) => {
  const path = notifPaths.get(id);
  if (!path) return;
  notifPaths.delete(id);
  call('open', { path }).catch(() => {});
});

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

// storage.local has a write-ops quota — progress events arrive
// several times a second per task, so coalesce into a short flush.
let tasksFlushTimer = null;
function flushTasksSoon() {
  if (tasksFlushTimer) return;
  tasksFlushTimer = setTimeout(() => {
    tasksFlushTimer = null;
    chrome.storage.local.set({ tasks: Object.fromEntries(tasks) });
    updateBadge();
  }, 400);
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
      // Media snapshots carry the delivered path under metadata —
      // surface it so open/reveal and the popup see a real path.
      if (rec.media && !rec.outputPath && rec.metadata &&
          rec.metadata.outputPath) {
        rec.outputPath = rec.metadata.outputPath;
      }
      const prev = tasks.get(id) || {};
      boundedPut(tasks, id, { ...prev, ...rec }, TASK_CAP);
      // File events carry `type`; media task snapshots carry `status`.
      const st = rec.status || rec.type;
      // A fresh attempt (resume/retry) clears the terminal flag so a
      // later completion/failure notifies again — exactly once each.
      if (st !== 'completed' && st !== 'failed') doneNotified.delete(id);
      // Notify terminal states exactly once per task — engine retries
      // can interleave progress events between failure emissions.
      if (st === 'completed' && !doneNotified.has(id)) {
        boundedAdd(doneNotified, id, SET_CAP);
        const name = rec.fileName ||
            (rec.output && rec.output.fileName) ||
            (rec.outputPath || '').split(/[\\/]/).pop() || id;
        notifyDone(name, rec.outputPath);
      }
      if (st === 'failed' && !doneNotified.has(id)) {
        boundedAdd(doneNotified, id, SET_CAP);
        notify('jjamIDM — 다운로드 실패',
            rec.error || rec.detail || rec.lastError || id);
      }
      flushTasksSoon();
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

function call(command, payload = {}, timeoutMs = 30000) {
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
    }, timeoutMs);
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

async function sendToFreeDM({
  url, referer, filename, pageUrl, subdir, absDir, startNow = true,
  maxConnections, priority,
}) {
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
    subdir: subdir || undefined,
    // Only a host-picked path is accepted — the host rejects any
    // absDir it did not hand out through the OS folder dialog.
    absDir: absDir || undefined,
    start: startNow,
    maxConnections,
    priority,
  });
  notify('jjamIDM — 다운로드 시작',
      `${filename || url}${startNow ? '' : ' (대기열에 추가)'}`);
  return res.taskId;
}

// Media page (YouTube watch etc.) → host-side media pipeline.
// The engine resolves formats with yt-dlp and muxes with FFmpeg.
async function sendMediaToFreeDM(pageUrl) {
  // Login-gated media needs the browser's session — forward cookies,
  // UA and Referer like a file download does.
  const headers = {};
  const cookie = await cookiesFor(pageUrl);
  if (cookie) headers.cookie = cookie;
  headers['user-agent'] = navigator.userAgent;
  headers['referer'] = pageUrl;
  const res = await call('media', { pageUrl, headers });
  notify('jjamIDM — 미디어 다운로드 시작', pageUrl);
  return res.taskId;
}

async function enabled() {
  const s = await chrome.storage.local.get({ enabled: true });
  return s.enabled;
}

// ---- start dialog ----------------------------------------------------
// Requests waiting on the user in dialog.html. The dialog window is
// opened via chrome.windows.create (allowed in response to user
// gestures — a programmatic action-popup is not).
const pendingDialog = new Map(); // token -> request payload
const dialogWins = new Map();    // windowId -> token

function dialogClosed(winId) {
  const token = dialogWins.get(winId);
  if (!token) return;
  dialogWins.delete(winId);
  const req = pendingDialog.get(token);
  pendingDialog.delete(token);
  if (req?.url) {
    boundedAdd(captureFailed, req.url, SET_CAP);
    chrome.downloads.download({ url: req.url }).catch(() => {});
  }
}

function openStartDialog(payload) {
  const token = `d${Date.now()}-${Math.random().toString(36).slice(2)}`;
  pendingDialog.set(token, payload);
  chrome.windows.create({
    url: `dialog.html#${token}`,
    type: 'popup',
    width: 540,
    height: 400,
    focused: true,
  }).then((w) => {
    if (!w || w.id == null) return;
    dialogWins.set(w.id, token);
    // The window may already be gone — closed in the gap before
    // registration; run the same cleanup onRemoved would have.
    chrome.windows.get(w.id).catch(() => dialogClosed(w.id));
  }).catch(() => {
    // Popup blocked (shouldn't happen for windows) → just enqueue.
    pendingDialog.delete(token);
    sendToFreeDM(payload).catch(() => {});
  });
}

// Closing the dialog window via X never reaches dialogCancel — treat
// it the same: hand the download back to the browser and drop the
// pending request so nothing is lost or leaked.
chrome.windows.onRemoved.addListener(dialogClosed);

// Entry point for every file download: applies settings, routes to
// the dialog when askBeforeDownload is on, else sends directly.
async function requestDownload(payload) {
  const s = await getSettings();
  payload.subdir ??= subdirFor(payload.url, payload.filename, s);
  payload.maxConnections ??= s.maxConnections;
  if (s.askBeforeDownload) {
    openStartDialog(payload);
    return null;
  }
  return sendToFreeDM(payload);
}

// ---- capture: browser decided it's a download → take over ----------
// URLs whose capture failed and were handed back to the browser.
// Without this, restarting the browser download re-fires onCreated
// → re-capture → re-fail → infinite notification loop.
const captureFailed = new Set();
chrome.downloads.onCreated.addListener(async (item) => {
  try {
    if (!(await enabled())) return;
    if (!/^https?:/.test(item.url)) return;
    if (item.state !== 'in_progress') return;
    const url = item.finalUrl || item.url;
    if (captureFailed.has(url) || captureFailed.has(item.url)) return;
    const s = await getSettings();
    if (!passesFilter(url, s)) return;
    await chrome.downloads.cancel(item.id);
    await chrome.downloads.erase({ id: item.id });
    const taskId = await requestDownload({
      url,
      referer: item.referrer,
      filename: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
      pageUrl: item.referrer,
    });
    if (taskId) {
      boundedPut(tasks, taskId,
          { taskId, type: 'progress', receivedBytes: 0 }, TASK_CAP);
    }
  } catch (e) {
    console.warn('capture failed, leaving browser download off', e);
    notify('jjamIDM — 전송 실패 (브라우저 다운로드로 복구)', String(e));
    // Hand it back to the browser once — and never recapture this
    // URL, or we'd loop failing downloads forever.
    boundedAdd(captureFailed, item.url, SET_CAP);
    if (item.finalUrl) boundedAdd(captureFailed, item.finalUrl, SET_CAP);
    try { await chrome.downloads.download({ url: item.url }); } catch {}
  }
});

// ---- context menu ----------------------------------------------------
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'freedm-link',
    title: 'Download with jjamIDM',
    contexts: ['link'],
  });
  chrome.contextMenus.create({
    id: 'freedm-page',
    title: 'Download this page media with jjamIDM',
    contexts: ['page', 'video', 'audio'],
  });
  chrome.contextMenus.create({
    id: 'freedm-selected',
    title: 'Download selected links with jjamIDM',
    contexts: ['selection'],
  });
  chrome.contextMenus.create({
    id: 'freedm-all',
    title: 'Download all links on this page with jjamIDM',
    contexts: ['page'],
  });
});

// Links whose last path segment has an extension that looks like a
// file (not a page route) — "all links" only queues real files.
const PAGE_LIKE = new Set(['html', 'htm', 'php', 'aspx', 'asp', 'jsp', '']);
function looksLikeFile(url) {
  return !PAGE_LIKE.has(extOf(url));
}

async function collectPageLinks(tabId) {
  try {
    const r = await chrome.tabs.sendMessage(
        tabId, { type: 'jjamidm-collect-links' });
    return r?.urls || [];
  } catch {
    // Content script not injected on this page — fall back to a
    // one-shot scripting eval.
    const [r] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => [...document.querySelectorAll('a[href]')]
          .map((a) => a.href).filter((u) => /^https?:/.test(u)),
    });
    return r.result || [];
  }
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === 'freedm-link' && info.linkUrl) {
      await requestDownload({
        url: info.linkUrl, pageUrl: info.pageUrl, referer: info.pageUrl,
      });
    } else if (info.menuItemId === 'freedm-page') {
      // Direct media file URL → engine download; embedded/blob
      // players (YouTube…) → media pipeline on the page URL.
      const src = info.srcUrl || '';
      if (/^https?:/.test(src)) {
        await requestDownload({
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
      // Batch path: one dialog per link would open a window storm —
      // selected links enqueue directly like "all links" does.
      const s2 = await getSettings();
      for (const url of r.result || []) {
        sendToFreeDM({
          url, pageUrl: info.pageUrl, referer: info.pageUrl,
          maxConnections: s2.maxConnections,
          subdir: subdirFor(url, null, s2),
        }).catch((e) => console.warn('selected enqueue failed', url, e));
      }
    } else if (info.menuItemId === 'freedm-all' && tab) {
      const s = await getSettings();
      const all = await collectPageLinks(tab.id);
      const urls = [...new Set(all)]
          .filter((u) => looksLikeFile(u) && passesFilter(u, s))
          .slice(0, 200); // bulk cap — a page can carry thousands
      if (!urls.length) {
        notify('jjamIDM', '이 페이지에서 다운로드할 파일 링크가 없습니다.');
        return;
      }
      notify('jjamIDM — 전체 링크 다운로드',
          `${urls.length}개 파일을 대기열에 추가합니다.`);
      for (const url of urls) {
        sendToFreeDM({
          url, pageUrl: info.pageUrl, referer: info.pageUrl,
          maxConnections: s.maxConnections,
          subdir: subdirFor(url, null, s),
        }).catch((e) => console.warn('bulk enqueue failed', url, e));
      }
    }
  } catch (e) {
    console.warn('context-menu send failed', e);
    notify('jjamIDM — 전송 실패', String(e));
  }
});

// ---- messages: popup, dialog, content script -------------------------
chrome.runtime.onMessage.addListener((m, _s, send) => {
  (async () => {
    if (m.cmd === 'ping') send(await call('ping'));
    else if (['pause', 'resume', 'cancel', 'start'].includes(m.cmd)) {
      send(await call(m.cmd, { taskId: m.taskId }));
    } else if (m.cmd === 'status') {
      send(await call('status', { taskId: m.taskId }));
    } else if (m.cmd === 'open' || m.cmd === 'reveal') {
      // Popup open/reveal buttons — the host canonicalizes the path
      // and refuses anything outside downloadDir.
      send(await call(m.cmd, { path: m.path }));
    // -- start-dialog round trip --
    } else if (m.cmd === 'pickFolder') {
      // OS picker can sit open while the user browses — the default
      // 30s host timeout is too short for a human decision.
      send(await call('pickFolder', {}, 180000));
    } else if (m.cmd === 'dialogGet') {
      send(pendingDialog.get(m.token) || { error: 'expired' });
    } else if (m.cmd === 'dialogDone') {
      const req = pendingDialog.get(m.token);
      pendingDialog.delete(m.token);
      if (!req) return send({ error: 'expired' });
      try {
        const id = await sendToFreeDM({
          ...req,
          filename: m.filename || req.filename,
          subdir: m.subdir,
          absDir: m.absDir,
          maxConnections: m.maxConnections,
          startNow: m.startNow,
        });
        if (id) {
          boundedPut(tasks, id,
              { taskId: id, type: 'progress', receivedBytes: 0 }, TASK_CAP);
        }
        send({ ok: true });
      } catch (e) { send({ error: String(e) }); }
    } else if (m.cmd === 'dialogCancel') {
      const req = pendingDialog.get(m.token);
      pendingDialog.delete(m.token);
      // A cancelled capture shouldn't lose the file — let the
      // browser take it (captureFailed stops the re-capture loop).
      if (req?.url) {
        boundedAdd(captureFailed, req.url, SET_CAP);
        chrome.downloads.download({ url: req.url }).catch(() => {});
      }
      send({ ok: true });
    // -- floating video chip --
    } else if (m.type === 'jjamidm-video') {
      if (/^https?:/.test(m.srcUrl || '')) {
        send(await requestDownload({
          url: m.srcUrl, pageUrl: m.pageUrl, referer: m.pageUrl,
        }));
      } else {
        send(await sendMediaToFreeDM(m.pageUrl));
      }
    }
  })().catch((e) => send({ ok: false, error: String(e) }));
  return true; // async response
});
