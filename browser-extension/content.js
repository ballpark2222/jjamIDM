// jjamIDM content script — IDM-style floating "download this video"
// chip over <video>/<audio> elements, plus page-link collection for
// the "all links" context menu.
//
// The chip lives in a shadow root on <html> so page CSS can't style
// or remove it; position is recomputed from the element's bounding
// rect so SPA navigation and player replacement still work.
(() => {
  if (window.__jjamidmContentLoaded) return;
  window.__jjamidmContentLoaded = true;

  // Per-site opt-out: the popup/options exclusion list gates the
  // floating chip the same way the global toggle does.
  function hostExcluded(listStr) {
    const h = location.hostname.toLowerCase();
    return (listStr || '').split(',')
      .map((x) => x.trim().toLowerCase()).filter(Boolean)
      .some((d) => h === d || h.endsWith('.' + d));
  }
  let floatingOn = true;
  let siteExcluded = false;
  function applySettings(s) {
    floatingOn = s.floatingButton !== false;
    siteExcluded = hostExcluded(s.excludedSites);
    if (siteExcluded) chip.style.display = 'none';
  }
  chrome.storage.local.get({ settings: {} })
      .then(({ settings }) => applySettings(settings));
  chrome.storage.onChanged.addListener((chg) => {
    if (chg.settings) applySettings(chg.settings.newValue || {});
  });

  // ---- floating chip ------------------------------------------------
  const host = document.createElement('div');
  host.id = 'jjamidm-float-host';
  const shadow = host.attachShadow({ mode: 'closed' });
  shadow.innerHTML = `
    <style>
      #chip {
        position: fixed; z-index: 2147483647; display: none;
        padding: 5px 10px; border-radius: 4px;
        background: rgba(21, 101, 192, .95); color: #fff;
        font: 12px 'Segoe UI', sans-serif; cursor: pointer;
        box-shadow: 0 2px 8px rgba(0,0,0,.4); user-select: none;
        white-space: nowrap; pointer-events: auto;
      }
      #chip:hover { background: #0d47a1; }
    </style>
    <div id="chip">⬇ 이 영상 다운로드</div>`;
  const chip = shadow.getElementById('chip');
  let chipTarget = null;

  function attach() {
    if (!host.isConnected) (document.documentElement || document.body)
        .appendChild(host);
  }
  attach();
  new MutationObserver(attach).observe(
      document.documentElement, { childList: true, subtree: false });

  const media = new Set(); // live <video>/<audio> elements
  function scan() {
    // Drop detached elements too — the set would otherwise pin dead
    // players forever on SPA pages.
    for (const el of media) {
      if (!el.isConnected) media.delete(el);
    }
    document.querySelectorAll('video, audio').forEach((el) => media.add(el));
  }
  scan();
  // Catch players created later (SPA nav, lazy mounts). Mutations
  // fire constantly on dynamic pages — debounce instead of running
  // a full-document query per batch.
  let scanTimer = null;
  new MutationObserver(() => {
    if (scanTimer) return;
    scanTimer = setTimeout(() => { scanTimer = null; scan(); }, 400);
  }).observe(
      document.documentElement, { childList: true, subtree: true });

  let lastMove = 0;
  document.addEventListener('mousemove', (ev) => {
    const now = Date.now();
    if (now - lastMove < 120) return; // ~8fps hit-test is plenty
    lastMove = now;
    if (!floatingOn || siteExcluded) {
      chip.style.display = 'none';
      return;
    }
    let hit = null;
    for (const el of media) {
      if (!el.isConnected) { media.delete(el); continue; }
      const r = el.getBoundingClientRect();
      if (r.width < 160 || r.height < 90) continue; // skip tiny widgets
      if (ev.clientX >= r.left && ev.clientX <= r.right &&
          ev.clientY >= r.top && ev.clientY <= r.bottom) {
        hit = { el, r };
        break;
      }
    }
    if (hit) {
      chipTarget = hit.el;
      chip.style.display = 'block';
      chip.style.left = `${Math.max(4, hit.r.right - 130)}px`;
      chip.style.top = `${Math.max(4, hit.r.top + 8)}px`;
    } else if (!chip.matches(':hover')) {
      chipTarget = null;
      chip.style.display = 'none';
    }
  }, { passive: true });

  chip.addEventListener('mouseleave', () => {
    if (!chipTarget) chip.style.display = 'none';
  });

  // The chip is fixed-positioned off the hover-time rect — a page
  // scroll leaves it hovering over the wrong spot until the next
  // mousemove. Reposition on scroll (capture phase: the video can
  // live inside a scrollable container, not just the document).
  function reposition() {
    if (!chipTarget || chip.style.display === 'none') return;
    const r = chipTarget.getBoundingClientRect();
    if (r.width < 160 || r.height < 90 ||
        r.bottom < 0 || r.top > window.innerHeight) {
      chipTarget = null;
      chip.style.display = 'none';
      return;
    }
    chip.style.left = `${Math.max(4, r.right - 130)}px`;
    chip.style.top = `${Math.max(4, r.top + 8)}px`;
  }
  document.addEventListener('scroll', reposition,
      { passive: true, capture: true });

  chip.addEventListener('click', (ev) => {
    ev.stopPropagation();
    ev.preventDefault();
    const el = chipTarget;
    if (!el) return;
    chrome.runtime.sendMessage({
      type: 'jjamidm-video',
      // Blob/empty src → background routes the PAGE url to the
      // media pipeline; a real http(s) src goes to file download.
      srcUrl: el.currentSrc || el.src || '',
      pageUrl: location.href,
    }).catch(() => {});
    chip.style.display = 'none';
  }, true);

  // ---- all-links collection (context menu) ---------------------------
  chrome.runtime.onMessage.addListener((m, _s, send) => {
    if (m.type === 'jjamidm-collect-links') {
      const urls = new Set();
      document.querySelectorAll('a[href]').forEach((a) => {
        try {
          const u = new URL(a.href, location.href);
          if (/^https?:$/.test(u.protocol)) urls.add(u.href);
        } catch {}
      });
      send({ urls: [...urls] });
    }
    return true;
  });
})();
