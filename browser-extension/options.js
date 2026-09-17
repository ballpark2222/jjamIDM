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
  };
  await chrome.storage.local.set({ settings });
  $('#saved').textContent = '저장됨';
  setTimeout(() => { $('#saved').textContent = ''; }, 2000);
};

load();
