import { nip19, getPublicKey } from 'nostr-tools';
import QRCode from 'qrcode';

function makeBrowser() {
  if (globalThis.browser) return globalThis.browser;
  if (globalThis.chrome) {
    const c = globalThis.chrome;
    const promisify =
      (api, fn) =>
      (...args) =>
        new Promise((resolve, reject) => {
          try {
            fn.apply(api, [
              ...args,
              (result) => {
                const err = c.runtime?.lastError;
                if (err) reject(new Error(err.message || String(err)));
                else resolve(result);
              },
            ]);
          } catch (err) {
            reject(err);
          }
        });
    return {
      ...c,
      runtime: {
        ...c.runtime,
        sendMessage: promisify(c.runtime, c.runtime.sendMessage),
        getURL: (...args) => c.runtime.getURL(...args),
        onMessage: c.runtime.onMessage,
      },
      storage: c.storage
        ? {
            ...c.storage,
            local: {
              ...c.storage.local,
              get: promisify(c.storage.local, c.storage.local.get),
              set: promisify(c.storage.local, c.storage.local.set),
              remove: promisify(c.storage.local, c.storage.local.remove),
            },
          }
        : undefined,
      downloads: c.downloads
        ? {
            ...c.downloads,
            download: promisify(c.downloads, c.downloads.download),
          }
        : undefined,
    };
  }
  return null;
}

const browser = makeBrowser();
const messageInput = document.getElementById('message');
const statusEl = document.getElementById('status');
const pubkeyEl = document.getElementById('pubkey');
const contactsEl = document.getElementById('contacts');
const historyEl = document.getElementById('history');
const attachBtn = document.getElementById('attach');
const sendBtn = document.getElementById('send');
const previewEl = document.getElementById('preview');
const previewContentEl = document.getElementById('previewContent');
const clearPreviewBtn = document.getElementById('clearPreview');
const warningEl = document.getElementById('upload-warning');
const showQrBtn = document.getElementById('show-qr');
const settingsBtn = document.getElementById('open-settings');
const dmToggleBtn = document.getElementById('dm-toggle');
const PUSHSTR_CLIENT_TAG = '[pushstr:client]';

async function safeSend(message, { attempts = 3, delayMs = 150 } = {}) {
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      return await browser.runtime.sendMessage(message);
    } catch (err) {
      lastErr = err;
      const msg = err?.message || '';
      if (!/port closed/i.test(msg)) break;
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}

const BLOSSOM_SERVER = 'https://blossom.primal.net';

let state = { messages: [], recipients: [], pubkey: null };
let selectedContact = null;
let pendingFile = null;
const localPreviewCache = {};
// Session cache for decrypted media (blob URLs)
const decryptedMediaCache = new Map();
// Track messages received in current session
const sessionMessages = new Set();
const sessionStartTime = Date.now();
const params = new URLSearchParams(window.location.search);
const isPopout = params.get('popout') === '1';
document.body.classList.add(isPopout ? 'popout' : 'popup');

document.getElementById('send').addEventListener('click', send);
document.getElementById('attach').addEventListener('click', attachFile);
const popoutBtn = document.getElementById('popout');
if (isPopout) {
  popoutBtn.style.display = 'none';
} else {
  popoutBtn.addEventListener('click', popout);
}
clearPreviewBtn.addEventListener('click', clearPreview);
showQrBtn?.addEventListener('click', showQrDialog);
settingsBtn?.addEventListener('click', openSettings);
dmToggleBtn?.addEventListener('click', toggleDmMode);
document.getElementById('dismiss-warning')?.addEventListener('click', () => {
  warningEl.classList.add('hidden');
  localStorage.setItem('pushstr_upload_warn_dismissed', '1');
});
messageInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    send();
  }
});
messageInput.addEventListener('paste', handlePaste);
messageInput.addEventListener('input', updateComposerMode);

browser.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'incoming') {
    console.log('[pushstr][popup] incoming message', msg);
    const other = msg.event.pubkey || 'unknown';
    if (!selectedContact) selectedContact = other;
    // Mark as session message (received while app is running)
    if (msg.event.id) sessionMessages.add(msg.event.id);
    refreshState().catch((err) => {
      console.error('[pushstr][popup] refreshState failed after incoming', err);
    });
  }
  if (msg.type === 'receipt') {
    refreshState().catch((err) => {
      console.error('[pushstr][popup] refreshState failed after receipt', err);
    });
  }
});

init();

async function init() {
  try {
    state = (await safeSend({ type: 'get-state' })) || {};
    console.info('[pushstr][popup] state', state);
  } catch (err) {
    console.error('[pushstr][popup] get-state failed', err);
    state = (await loadStateFallback()) || {};
  }
  const dismissed =
    localStorage.getItem('pushstr_upload_warn_dismissed') === '1';
  if (!dismissed) warningEl.classList.remove('hidden');
  if (!state.pubkey) {
    try {
      await safeSend({ type: 'generate-key' });
      state = (await safeSend({ type: 'get-state' })) || {};
    } catch (err) {
      console.error('[pushstr][popup] generate-key failed', err);
      status('Unable to initialize key');
    }
  }
  if (!state.pubkey) {
    status('No key');
    return;
  }
  pubkeyEl.textContent = state.pubkey ? `${short(state.pubkey)}` : 'No key';
  if (!selectedContact) {
    const recipients = Array.isArray(state.recipients) ? state.recipients : [];
    selectedContact =
      state.lastRecipient || (recipients[0] && recipients[0].pubkey) || null;
  }
  render();
  updateComposerMode();
}

function render() {
  renderContacts();
  renderHistory();
  updateDmToggle();
  requestAnimationFrame(() => {
    historyEl.scrollTop = historyEl.scrollHeight;
  });
}

function renderContacts() {
  const contacts = buildContacts();
  contactsEl.innerHTML = '';
  contacts.forEach((c) => {
    const el = document.createElement('div');
    el.className = 'contact' + (selectedContact === c.id ? ' active' : '');
    el.addEventListener('click', () => {
      selectedContact = c.id;
      browser.runtime.sendMessage({
        type: 'set-last-recipient',
        recipient: selectedContact,
      });
      render();
    });
    const avatar = document.createElement('div');
    avatar.className = 'avatar';
    avatar.textContent = c.label[0].toUpperCase();
    const meta = document.createElement('div');
    meta.className = 'meta';
    const name = document.createElement('p');
    name.className = 'name';
    name.textContent = c.label;
    const snippet = document.createElement('p');
    snippet.className = 'snippet';
    snippet.textContent = c.snippet || '';
    meta.appendChild(name);
    meta.appendChild(snippet);
    const actions = document.createElement('div');
    actions.className = 'contact-actions';
    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'icon-btn danger';
    del.title = 'Delete conversation';
    del.textContent = '🗑';
    del.addEventListener('click', async (e) => {
      e.stopPropagation();
      const ok = confirm(
        `Delete conversation with ${c.label}? This removes local history only.`,
      );
      if (!ok) return;
      await browser.runtime.sendMessage({
        type: 'delete-conversation',
        recipient: c.id,
      });
      await refreshState();
    });
    actions.appendChild(del);
    el.appendChild(avatar);
    el.appendChild(meta);
    el.appendChild(actions);
    contactsEl.appendChild(el);
  });

  const addBtn = document.createElement('button');
  addBtn.type = 'button';
  addBtn.className = 'add-contact-btn';
  addBtn.textContent = '+ Add Contact';
  addBtn.addEventListener('click', showAddContactDialog);
  contactsEl.appendChild(addBtn);
}

function renderHistory() {
  historyEl.innerHTML = '';
  if (!selectedContact) {
    historyEl.innerHTML =
      "<p style='color:#555;'>Pick a contact to start chatting.</p>";
    return;
  }
  console.log(
    '[pushstr][popup] renderHistory: total messages:',
    state.messages?.length,
    'selected:',
    selectedContact,
  );
  const convo = state.messages.filter((m) => otherParty(m) === selectedContact);
  console.log(
    '[pushstr][popup] renderHistory: filtered to',
    convo.length,
    'messages for contact',
  );
  convo.sort((a, b) => (a.created_at || 0) - (b.created_at || 0));
  convo.forEach((m) => {
    const row = document.createElement('div');
    row.className = 'msg-row ' + (m.direction === 'out' ? 'out' : 'in');
    const bubble = document.createElement('div');
    bubble.className = 'bubble ' + (m.direction === 'out' ? 'out' : 'in');
    const senderPubkey =
      m.direction === 'out'
        ? m.to || selectedContact || state.lastRecipient
        : m.from || state.pubkey;
    const renderResult = renderBubbleContent(
      bubble,
      m.content,
      senderPubkey,
      m.direction === 'out',
      m.id,
    );
    const actions = renderResult?.actions;
    const metaRow = document.createElement('div');
    metaRow.className = 'meta-row';
    const meta = document.createElement('div');
    meta.className = 'meta external';
    meta.textContent = friendlyTime(m.created_at);
    metaRow.appendChild(meta);
    const dmKind = normalizeDmKind(m);
    const dmBadge = buildDmBadge(dmKind);
    if (dmBadge) metaRow.appendChild(dmBadge);
    if (renderResult?.hasMedia) {
      metaRow.appendChild(
        buildLockBadge(renderResult.mediaEncrypted !== false),
      );
    }
    const receiptBadge = buildReceiptBadge(m);
    if (receiptBadge) metaRow.appendChild(receiptBadge);
    if (m.direction === 'out') {
      const resendBtn = document.createElement('button');
      resendBtn.className = 'resend-btn';
      resendBtn.title = 'Resend';
      resendBtn.textContent = '↻';
      resendBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        try {
          await safeSend({
            type: 'resend-message',
            recipient: m.to,
            content: m.content,
            dm_kind: m.dm_kind,
          });
          status('Resent');
        } catch (err) {
          status(`Resend failed: ${err?.message || err}`);
        }
      });
      metaRow.appendChild(resendBtn);
    }
    if (m.direction !== 'out') {
      const copyBtn = document.createElement('button');
      copyBtn.className = 'copy-btn';
      copyBtn.title = 'Copy message';
      copyBtn.textContent = '⧉';
      copyBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        try {
          await navigator.clipboard.writeText(m.content || '');
        } catch (_) {
          prompt('Copy message:', m.content || '');
        }
        flashCopyButton(copyBtn);
      });
      metaRow.appendChild(copyBtn);
    }
    if (actions) {
      metaRow.appendChild(actions);
    }
    row.appendChild(bubble);
    row.appendChild(metaRow);
    historyEl.appendChild(row);
  });
  requestAnimationFrame(() => {
    historyEl.scrollTop = historyEl.scrollHeight;
  });
}

function createDownloadButton(url, mime, size, sha, extraMeta) {
  const inferredName = extraMeta?.filename || filenameFromUrl(url, mime);
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.title = inferredName ? `Download ${inferredName}` : 'Download';
  btn.className = 'download-btn icon';
  btn.textContent = '⬇';
  btn.disabled = true;
  let decryptHandler = null;
  const clickHandler = async (targetUrl, targetName) => {
    const toDataUrlIfNeeded = async (u) => {
      if (!u) return null;
      if (u.startsWith('data:')) return u;
      if (u.startsWith('blob:')) {
        try {
          const res = await fetch(u);
          const blob = await res.blob();
          return await blobToDataUrl(blob);
        } catch (_) {
          return null;
        }
      }
      return u;
    };

    // Prefer background download so popup context doesn't get closed/blocked
    try {
      const finalUrl = await toDataUrlIfNeeded(targetUrl);
      const res = await browser.runtime.sendMessage({
        type: 'download-url',
        url: finalUrl || targetUrl,
        filename: targetName || undefined,
      });
      if (!res?.error) return;
    } catch (_) {
      // fall back below
    }

    // Fallback: direct download from popup context
    const href = (await toDataUrlIfNeeded(targetUrl)) || targetUrl;
    const a = document.createElement('a');
    a.href = href;
    a.download = targetName || '';
    document.body.appendChild(a);
    a.click();
    a.remove();
  };
  const setTarget = (targetUrl, targetName) => {
    btn.dataset.url = targetUrl;
    btn.dataset.filename = targetName || inferredName || '';
    btn.disabled = false;
  };
  const setDecryptHandler = (fn) => {
    decryptHandler = fn;
    btn.disabled = false;
  };
  if (url) setTarget(url, inferredName);
  else btn.disabled = true;
  btn.addEventListener('click', async (e) => {
    e.preventDefault();
    let targetUrl = btn.dataset.url;
    let targetName = btn.dataset.filename;
    if (!targetUrl && decryptHandler) {
      await decryptHandler();
      targetUrl = btn.dataset.url;
      targetName = btn.dataset.filename;
    }
    if (!targetUrl) return;
    clickHandler(targetUrl, targetName);
  });
  return { btn, setTarget, setDecryptHandler };
}

function renderEncryptedMedia(
  container,
  media,
  senderPubkey,
  fallbackUrl,
  fragMeta,
  downloadCtrl,
  isOut = false,
  messageId = null,
) {
  // Create cache key
  const cacheKey = media.cipher_sha256 || media.url;

  // Try to use cached preview for sender (check both in-memory and localStorage)
  const cached =
    localPreviewCache[fallbackUrl] ||
    localPreviewCache[media.url] ||
    localStorage.getItem(`pushstr_preview_${fallbackUrl}`) ||
    localStorage.getItem(`pushstr_preview_${media.url}`);

  if (isOut && cached) {
    // Sender preview: use local cached data URL and skip decrypting own upload
    container.innerHTML = '';
    const mime = media.mime || fragMeta.mime || '';
    if (mime.startsWith('image')) {
      const img = document.createElement('img');
      img.src = cached;
      img.style.maxWidth = '180px';
      img.style.maxHeight = '180px';
      img.style.display = 'block';
      makeZoomableImage(img, cached);
      container.appendChild(img);
    } else if (mime.startsWith('video')) {
      container.appendChild(buildVideoPlayer(cached));
    } else if (mime.startsWith('audio')) {
      const audio = document.createElement('audio');
      audio.src = cached;
      audio.controls = true;
      audio.className = 'audio-player';
      container.appendChild(audio);
    } else {
      const info = document.createElement('div');
      info.textContent = media.filename || 'Attachment';
      info.style.fontSize = '13px';
      container.appendChild(info);
    }
    if (downloadCtrl) downloadCtrl.setTarget(cached, media.filename);
    return;
  }

  // Check if already decrypted in this session
  const cachedBlob = decryptedMediaCache.get(cacheKey);
  if (cachedBlob) {
    displayDecryptedMedia(container, cachedBlob, media, fragMeta, downloadCtrl);
    return;
  }

  // Check persisted decrypted media
  const stored = loadPersistedMedia(
    cacheKey,
    media.mime || fragMeta.mime,
    media.filename,
  );
  if (stored) {
    decryptedMediaCache.set(cacheKey, stored);
    displayDecryptedMedia(container, stored, media, fragMeta, downloadCtrl);
    return;
  }

  // Check if this is an old message (not from current session)
  const isOldMessage = messageId && !sessionMessages.has(messageId);

  if (isOldMessage) {
    // Show decrypt button for old messages
    container.replaceChildren();
    const filename = media.filename || 'attachment';
    const decryptBtn = document.createElement('button');
    decryptBtn.textContent = `🔓 Decrypt: ${filename}`;
    decryptBtn.className = 'decrypt-btn';
    decryptBtn.style.cssText =
      'padding:8px 12px;background:#374151;border:1px solid #4b5563;border-radius:6px;cursor:pointer;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:200px;';
    decryptBtn.title = filename; // Show full filename on hover
    decryptBtn.onclick = () =>
      decryptAndCache(
        container,
        media,
        senderPubkey,
        cacheKey,
        fragMeta,
        downloadCtrl,
      );
    if (downloadCtrl) {
      downloadCtrl.setDecryptHandler(() =>
        decryptAndCache(
          container,
          media,
          senderPubkey,
          cacheKey,
          fragMeta,
          downloadCtrl,
        ),
      );
    }
    container.appendChild(decryptBtn);
    return;
  }

  // Auto-decrypt for new messages
  decryptAndCache(
    container,
    media,
    senderPubkey,
    cacheKey,
    fragMeta,
    downloadCtrl,
  );
}

async function decryptAndCache(
  container,
  media,
  senderPubkey,
  cacheKey,
  fragMeta,
  downloadCtrl,
) {
  renderContainerMessage(container, 'Decrypting attachment…', '#9ca3af');
  try {
    const res = await browser.runtime.sendMessage({
      type: 'decrypt-media',
      descriptor: media,
      senderPubkey,
    });
    if (!res || res.error || !res.base64) {
      const errMsg = res?.error || 'unknown error';
      renderContainerMessage(
        container,
        `Failed to decrypt: ${errMsg}`,
        '#ef4444',
      );
      return;
    }
    const bytes = b64ToBytes(res.base64);
    const blob = new Blob([bytes], {
      type: res.mime || media.mime || 'application/octet-stream',
    });
    const blobUrl = URL.createObjectURL(blob);

    // Cache the decrypted blob URL
    const cached = {
      blobUrl,
      mime: res.mime || media.mime,
      filename: media.filename,
      base64: res.base64,
    };
    decryptedMediaCache.set(cacheKey, cached);
    persistDecryptedMedia(cacheKey, res.base64, cached.mime, cached.filename);

    displayDecryptedMedia(container, cached, media, fragMeta, downloadCtrl);
  } catch (err) {
    renderContainerMessage(container, `Error: ${err.message}`, '#ef4444');
  }
}

function renderContainerMessage(container, message, color = '#9ca3af') {
  container.replaceChildren();
  const msgEl = document.createElement('div');
  msgEl.style.color = color;
  msgEl.style.fontSize = '12px';
  msgEl.textContent = message;
  container.appendChild(msgEl);
}

function buildVideoPlayer(url) {
  const wrapper = document.createElement('div');
  wrapper.className = 'media-video';
  const video = document.createElement('video');
  video.src = url;
  video.playsInline = true;
  video.preload = 'metadata';
  const overlay = document.createElement('div');
  overlay.className = 'video-overlay';
  const controls = document.createElement('div');
  controls.className = 'video-controls';
  const backBtn = document.createElement('button');
  backBtn.textContent = '⟲';
  backBtn.title = 'Back 10s';
  const playBtn = document.createElement('button');
  playBtn.classList.add('video-play');
  const playIcon = document.createElementNS(
    'http://www.w3.org/2000/svg',
    'svg',
  );
  playIcon.setAttribute('viewBox', '0 0 24 24');
  playIcon.setAttribute('aria-hidden', 'true');
  const playPath = document.createElementNS(
    'http://www.w3.org/2000/svg',
    'path',
  );
  playPath.setAttribute('d', 'M8 5v14l11-7z');
  playIcon.appendChild(playPath);
  playBtn.appendChild(playIcon);
  const forwardBtn = document.createElement('button');
  forwardBtn.textContent = '⟳';
  forwardBtn.title = 'Forward 10s';
  const scrubRow = document.createElement('div');
  scrubRow.className = 'video-scrub';
  const scrubber = document.createElement('input');
  scrubber.type = 'range';
  scrubber.min = '0';
  scrubber.max = '1';
  scrubber.step = '0.01';
  scrubber.value = '0';

  const syncScrub = () => {
    if (!video.duration) return;
    scrubber.value = String(video.currentTime / video.duration);
    if (video.paused) {
      playPath.setAttribute('d', 'M8 5v14l11-7z');
    } else {
      playPath.setAttribute('d', 'M7 5h4v14H7zm6 0h4v14h-4z');
    }
  };

  let hideTimer = null;
  const setControlsVisible = (visible) => {
    if (visible) {
      overlay.classList.remove('video-hidden');
      scrubRow.classList.remove('video-hidden');
    } else {
      overlay.classList.add('video-hidden');
      scrubRow.classList.add('video-hidden');
    }
  };
  const scheduleHide = () => {
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!video.paused) setControlsVisible(false);
    }, 2000);
  };

  backBtn.addEventListener('click', () => {
    video.currentTime = Math.max(0, (video.currentTime || 0) - 10);
  });
  forwardBtn.addEventListener('click', () => {
    if (!video.duration) return;
    video.currentTime = Math.min(video.duration, (video.currentTime || 0) + 10);
  });
  playBtn.addEventListener('click', () => {
    if (video.paused) video.play();
    else video.pause();
  });
  scrubber.addEventListener('input', () => {
    if (!video.duration) return;
    video.currentTime = Number(scrubber.value) * video.duration;
  });
  video.addEventListener('timeupdate', syncScrub);
  video.addEventListener('play', () => {
    syncScrub();
    scheduleHide();
  });
  video.addEventListener('pause', () => {
    syncScrub();
    setControlsVisible(true);
  });
  video.addEventListener('click', () => {
    const currentlyHidden = overlay.classList.contains('video-hidden');
    setControlsVisible(currentlyHidden);
    if (!video.paused && currentlyHidden) scheduleHide();
    if (!video.paused && !currentlyHidden) scheduleHide();
  });
  controls.addEventListener('click', (event) => event.stopPropagation());
  scrubRow.addEventListener('click', (event) => event.stopPropagation());

  controls.appendChild(backBtn);
  controls.appendChild(playBtn);
  controls.appendChild(forwardBtn);
  overlay.appendChild(controls);
  scrubRow.appendChild(scrubber);
  wrapper.appendChild(video);
  wrapper.appendChild(overlay);
  wrapper.appendChild(scrubRow);
  setControlsVisible(true);
  return wrapper;
}

function displayDecryptedMedia(
  container,
  cachedData,
  media,
  fragMeta,
  downloadCtrl,
) {
  container.replaceChildren();
  const mime = cachedData.mime || media.mime || fragMeta.mime;
  if (mime && mime.startsWith('image')) {
    const img = document.createElement('img');
    img.src = cachedData.blobUrl;
    img.style.maxWidth = '180px';
    img.style.maxHeight = '180px';
    img.style.display = 'block';
    makeZoomableImage(img, cachedData.blobUrl);
    container.appendChild(img);
  } else if (mime && mime.startsWith('video')) {
    container.appendChild(buildVideoPlayer(cachedData.blobUrl));
  } else if (mime && mime.startsWith('audio')) {
    const audio = document.createElement('audio');
    audio.src = cachedData.blobUrl;
    audio.controls = true;
    audio.className = 'audio-player';
    container.appendChild(audio);
  } else {
    const info = document.createElement('div');
    info.textContent = cachedData.filename || media.filename || 'Attachment';
    info.style.fontSize = '13px';
    container.appendChild(info);
  }
  if (downloadCtrl)
    downloadCtrl.setTarget(
      cachedData.blobUrl,
      cachedData.filename || media.filename,
    );
}

function b64ToBytes(b64) {
  const bin = atob(b64);
  const len = bin.length;
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result?.toString() || null);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

function persistDecryptedMedia(cacheKey, base64, mime, filename) {
  if (!cacheKey || !base64) return;
  const payload = {
    b64: base64,
    mime: mime || 'application/octet-stream',
    filename: filename || '',
  };
  try {
    localStorage.setItem(`pushstr_media_${cacheKey}`, JSON.stringify(payload));
  } catch (_) {
    // ignore quota errors
  }
}

function loadPersistedMedia(cacheKey, fallbackMime, fallbackFilename) {
  if (!cacheKey) return null;
  try {
    const raw = localStorage.getItem(`pushstr_media_${cacheKey}`);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (!data?.b64) return null;
    const bytes = b64ToBytes(data.b64);
    const mime = data.mime || fallbackMime || 'application/octet-stream';
    const blob = new Blob([bytes], { type: mime });
    const blobUrl = URL.createObjectURL(blob);
    return {
      blobUrl,
      mime,
      filename: data.filename || fallbackFilename || 'attachment',
    };
  } catch (_) {
    return null;
  }
}

function filenameFromUrl(url, mime) {
  try {
    const u = new URL(url, window.location.href);
    const base = u.pathname.split('/').filter(Boolean).pop();
    if (base) return base;
  } catch (_) {
    // ignore
  }
  if (mime && mime.startsWith('image/')) {
    const ext = mime.split('/')[1] || 'bin';
    return `attachment.${ext}`;
  }
  return 'attachment';
}

function buildContacts() {
  const counts = {};
  const recips = Array.isArray(state.recipients) ? state.recipients : [];
  recips.forEach(
    (r) =>
      (counts[r.pubkey] = counts[r.pubkey] || {
        id: r.pubkey,
        last: 0,
        snippet: '',
        nickname: r.nickname,
      }),
  );
  (state.messages || []).forEach((m) => {
    const other = otherParty(m);
    const entry = counts[other] || {
      id: other,
      last: 0,
      snippet: '',
      nickname: '',
    };
    entry.last = Math.max(entry.last, m.created_at || 0);
    entry.snippet = truncateSnippet(
      stripPushstrClientTag(stripNip18(m.content || '')),
    );
    counts[other] = entry;
  });
  return Object.values(counts)
    .sort((a, b) => (b.last || 0) - (a.last || 0))
    .map((c) => ({ ...c, label: c.nickname || short(c.id) }));
}

function otherParty(m) {
  return m.direction === 'out' ? m.to : m.from;
}

async function loadStateFallback() {
  try {
    const stored = await browser.storage.local.get();
    if (!stored) return null;
    const pubkey = stored.pubkey || derivePubkeyFromNsec(stored.nsec);
    return { ...stored, pubkey };
  } catch (err) {
    console.error('[pushstr][popup] fallback load failed', err);
    return null;
  }
}

function derivePubkeyFromNsec(nsec) {
  if (!nsec) return null;
  try {
    const dec = nip19.decode(nsec);
    const priv = dec.type === 'nsec' ? dec.data : nsec;
    return getPublicKey(priv);
  } catch (_) {
    return null;
  }
}

async function send() {
  const content = messageInput.value.trim();
  const fileToSend = pendingFile;
  if (!selectedContact) {
    status('Pick a contact first');
    return;
  }
  if (!content && !fileToSend) {
    status('Nothing to send');
    return;
  }
  status('Sending...');
  try {
    if (content) {
      const res = await browser.runtime.sendMessage({
        type: 'send-gift',
        recipient: selectedContact,
        content,
      });
      if (res && res.ok === false)
        throw new Error(res.error || 'publish failed');
    }
    if (fileToSend) {
      const arrayBuf = await fileToSend.arrayBuffer();
      const res = await browser.runtime.sendMessage({
        type: 'upload-blossom',
        data: arrayBuf,
        recipient: selectedContact,
        mime: fileToSend.type,
        filename: fileToSend.name || undefined,
      });
      if (!res || res.error) throw new Error(res?.error || 'upload failed');
      // Cache preview for images (check both file type and returned mime type)
      const isImage =
        fileToSend.type?.startsWith('image') || res.mime?.startsWith('image');
      if (isImage) {
        const dataUrl = await fileToDataUrl(fileToSend);
        localPreviewCache[res.url] = dataUrl;
        try {
          localStorage.setItem(`pushstr_preview_${res.url}`, dataUrl);
        } catch (_) {
          // ignore storage errors
        }
      }
      const payload = buildPushstrAttachmentPayload(content, res);
      const sendRes = await browser.runtime.sendMessage({
        type: 'send-gift',
        recipient: selectedContact,
        content: payload,
      });
      if (sendRes && sendRes.ok === false) {
        throw new Error(sendRes.error || 'publish failed');
      }
      showUploadedPreview(res.url, res.mime || fileToSend.type);
    }
    messageInput.value = '';
    pendingFile = null;
    clearPreview(!!fileToSend);
    updateComposerMode();
    await refreshState();
    status('Sent');
  } catch (err) {
    status('Failed: ' + err.message);
  }
}

async function refreshState() {
  try {
    const newState = await browser.runtime.sendMessage({ type: 'get-state' });
    console.log(
      '[pushstr][popup] refreshState got state:',
      newState?.messages?.length,
      'messages',
    );
    if (newState) {
      state = newState;
      render();
    } else {
      console.warn('[pushstr][popup] refreshState: no state returned');
      status('Background unavailable');
    }
  } catch (err) {
    console.error('[pushstr][popup] refreshState error:', err);
    status('Background unavailable');
  }
}

async function regen() {
  await browser.runtime.sendMessage({ type: 'generate-key' });
  await refreshState();
}

async function importNsec() {
  const val = prompt('Paste nsec...');
  if (!val) return;
  await browser.runtime.sendMessage({ type: 'import-nsec', value: val.trim() });
  await refreshState();
}

async function exportNsec() {
  const res = await browser.runtime.sendMessage({ type: 'export-nsec' });
  if (!res?.nsec) {
    status('No key to export');
    return;
  }
  try {
    await navigator.clipboard.writeText(res.nsec);
    status('Copied nsec to clipboard');
  } catch (err) {
    prompt('Your nsec (keep secret):', res.nsec);
    status('Copy failed; shown in prompt');
  }
}

async function exportNpub() {
  const res = await browser.runtime.sendMessage({ type: 'export-npub' });
  if (!res?.npub) {
    status('No key to export');
    return;
  }
  try {
    await navigator.clipboard.writeText(res.npub);
    status('Copied npub to clipboard');
  } catch (err) {
    prompt('Your npub:', res.npub);
    status('Copy failed; shown in prompt');
  }
}

async function copyContact() {
  if (!selectedContact) {
    status('No contact selected');
    return;
  }
  try {
    await navigator.clipboard.writeText(toNpub(selectedContact));
    status('Contact pubkey copied');
  } catch (err) {
    prompt('Contact pubkey:', toNpub(selectedContact));
    status('Copy failed; shown in prompt');
  }
}

function toNpub(pk) {
  if (!pk) return '';
  const cleaned = stripNostrPrefix(pk);
  if (cleaned.startsWith('npub')) return cleaned;
  try {
    const decoded = nip19.decode(cleaned);
    if (decoded.type === 'nprofile' && decoded.data?.pubkey) {
      return nip19.npubEncode(decoded.data.pubkey);
    }
    if (decoded.type === 'npub' && typeof decoded.data === 'string') {
      return cleaned;
    }
  } catch (_) {
    // fall through to encode attempt
  }
  try {
    return nip19.npubEncode(cleaned);
  } catch (_) {
    return pk;
  }
}

function stripNostrPrefix(value) {
  if (!value) return value;
  if (value.startsWith('nostr://')) return value.slice(8);
  if (value.startsWith('nostr:')) return value.slice(6);
  return value;
}

const PUSHSTR_MEDIA_START = '[pushstr:media]';
const PUSHSTR_MEDIA_END = '[/pushstr:media]';

function extractPushstrMedia(raw) {
  const startIdx = raw.indexOf(PUSHSTR_MEDIA_START);
  if (startIdx === -1) {
    return { text: raw, mediaJson: null };
  }
  const contentStart = startIdx + PUSHSTR_MEDIA_START.length;
  const endIdx = raw.indexOf(PUSHSTR_MEDIA_END, contentStart);
  const mediaJson = (
    endIdx === -1 ? raw.slice(contentStart) : raw.slice(contentStart, endIdx)
  ).trim();
  const before = raw.slice(0, startIdx);
  const after =
    endIdx === -1 ? '' : raw.slice(endIdx + PUSHSTR_MEDIA_END.length);
  const cleaned = (before + after).trim();
  return { text: cleaned, mediaJson: mediaJson || null };
}

function short(pk) {
  const npub = toNpub(pk);
  if (!npub) return 'unknown';
  if (npub.length <= 12) return npub;
  return npub.slice(0, 8) + '...' + npub.slice(-4);
}

function normalizePubkeyInput(input) {
  if (!input) throw new Error('Missing pubkey');
  const trimmed = stripNostrPrefix(input.trim());
  try {
    const decoded = nip19.decode(trimmed);
    if (decoded.type === 'npub' && typeof decoded.data === 'string')
      return decoded.data;
    if (decoded.type === 'nprofile' && decoded.data?.pubkey)
      return decoded.data.pubkey;
  } catch (_) {
    // fall through to hex handling
  }
  if (/^[0-9a-fA-F]{64}$/.test(trimmed)) return trimmed.toLowerCase();
  throw new Error('Enter a valid npub, nprofile, or hex pubkey');
}

function status(msg) {
  // Suppress UI toast; keep console only
  if (msg) console.info('[pushstr]', msg);
}

function showModal(title, contentNode) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    const dialog = document.createElement('div');
    dialog.className = 'modal-dialog';
    const header = document.createElement('div');
    header.className = 'modal-header';
    header.textContent = title;
    const body = document.createElement('div');
    body.className = 'modal-body';
    body.appendChild(contentNode);
    const footer = document.createElement('div');
    footer.className = 'modal-footer';
    const cancel = document.createElement('button');
    cancel.textContent = 'Cancel';
    const ok = document.createElement('button');
    ok.textContent = 'Add';
    ok.className = 'modal-primary';
    cancel.addEventListener('click', () => {
      overlay.remove();
      resolve(false);
    });
    ok.addEventListener('click', () => {
      overlay.remove();
      resolve(true);
    });
    footer.appendChild(cancel);
    footer.appendChild(ok);
    dialog.appendChild(header);
    dialog.appendChild(body);
    dialog.appendChild(footer);
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);
    ok.focus();
  });
}

function showInfoModal(title, contentNode) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  const dialog = document.createElement('div');
  dialog.className = 'modal-dialog';
  const header = document.createElement('div');
  header.className = 'modal-header';
  header.textContent = title;
  const body = document.createElement('div');
  body.className = 'modal-body';
  body.appendChild(contentNode);
  const footer = document.createElement('div');
  footer.className = 'modal-footer';
  const close = document.createElement('button');
  close.textContent = 'Close';
  const closeModal = () => overlay.remove();
  close.addEventListener('click', closeModal);
  overlay.addEventListener('click', (event) => {
    if (event.target === overlay) closeModal();
  });
  footer.appendChild(close);
  dialog.appendChild(header);
  dialog.appendChild(body);
  dialog.appendChild(footer);
  overlay.appendChild(dialog);
  document.body.appendChild(overlay);
  close.focus();
}

async function showQrDialog() {
  const pubkey = state?.pubkey;
  if (!pubkey) {
    status('No pubkey available');
    return;
  }
  const npub = toNpub(pubkey);
  const uri = `nostr:${npub}`;
  const wrapper = document.createElement('div');
  wrapper.className = 'qr-wrapper';
  const canvas = document.createElement('canvas');
  try {
    await QRCode.toCanvas(canvas, uri, {
      width: 200,
      margin: 1,
      color: { dark: '#0f172a', light: '#ffffff' },
    });
  } catch (err) {
    console.error('[pushstr][popup] QR render failed', err);
    status('QR render failed');
    return;
  }
  const label = document.createElement('div');
  label.className = 'qr-label';
  label.textContent = 'Scan to add';
  const text = document.createElement('div');
  text.className = 'qr-text';
  text.textContent = npub;
  const copyBtn = document.createElement('button');
  copyBtn.className = 'qr-copy';
  copyBtn.textContent = 'Copy';
  copyBtn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(uri);
      flashCopyButton(copyBtn);
    } catch (err) {
      prompt('nostr:', uri);
    }
  });
  wrapper.appendChild(canvas);
  wrapper.appendChild(label);
  wrapper.appendChild(text);
  wrapper.appendChild(copyBtn);
  showInfoModal('Your npub', wrapper);
}
async function showAddContactDialog() {
  const wrapper = document.createElement('div');
  wrapper.innerHTML = `
    <div style="display:flex;flex-direction:column;gap:8px;min-width:260px;">
      <label style="font-size:12px;color:#9ca3af;">Nickname (optional)</label>
      <input type="text" id="ac_nick" style="padding:6px 8px;border:1px solid #1f2937;border-radius:6px;background:#0f172a;color:#e5e7eb;">
      <label style="font-size:12px;color:#9ca3af;">npub, nprofile, or hex pubkey</label>
      <input type="text" id="ac_pub" style="padding:6px 8px;border:1px solid #1f2937;border-radius:6px;background:#0f172a;color:#e5e7eb;">
    </div>
  `;
  const nickInput = wrapper.querySelector('#ac_nick');
  const pubInput = wrapper.querySelector('#ac_pub');

  const result = await showModal('Add Contact', wrapper);
  if (!result) return;
  const nickname = nickInput.value.trim();
  const pubkey = pubInput.value.trim();
  if (!pubkey) return;
  let normalized;
  try {
    normalized = normalizePubkeyInput(pubkey);
  } catch (err) {
    status(err?.message || 'Invalid pubkey');
    return;
  }
  const recipients = (state.recipients || []).map((r) => ({ ...r }));
  recipients.push({ nickname, pubkey: normalized });
  try {
    await browser.runtime.sendMessage({ type: 'save-settings', recipients });
    selectedContact = normalized;
    await browser.runtime.sendMessage({
      type: 'set-last-recipient',
      recipient: normalized,
    });
    await refreshState();
  } catch (err) {
    status('Add contact failed');
  }
}
function popout() {
  const url = browser.runtime.getURL('popup.html?popout=1');
  const existing = window.popoutWindow;
  if (existing && !existing.closed) {
    existing.focus();
    return;
  }
  window.popoutWindow = window.open(
    url,
    'pushstr-popout',
    'noopener,noreferrer,width=800,height=640',
  );
}

function openSettings() {
  const url = browser.runtime.getURL('options.html');
  window.open(url, '_blank', 'noopener,noreferrer');
}

function makeZoomableImage(img, url) {
  img.style.cursor = 'zoom-in';
  img.addEventListener('click', () => showImageModal(url));
}

function showImageModal(url) {
  const overlay = document.createElement('div');
  overlay.className = 'image-modal';
  const img = document.createElement('img');
  img.src = url;
  let scale = 1;
  const setScale = (next) => {
    scale = Math.min(3, Math.max(1, next));
    img.style.transform = `scale(${scale})`;
    img.style.cursor = scale > 1 ? 'zoom-out' : 'zoom-in';
  };
  img.addEventListener('click', (event) => {
    event.stopPropagation();
    setScale(scale > 1 ? 1 : 2);
  });
  img.addEventListener(
    'wheel',
    (event) => {
      event.preventDefault();
      const delta = event.deltaY > 0 ? -0.1 : 0.1;
      setScale(scale + delta);
    },
    { passive: false },
  );
  overlay.addEventListener('click', () => overlay.remove());
  overlay.appendChild(img);
  document.body.appendChild(overlay);
}

function flashCopyButton(btn) {
  if (!btn) return;
  const original = btn.textContent;
  btn.textContent = '✔';
  btn.classList.add('copied');
  setTimeout(() => {
    btn.textContent = original;
    btn.classList.remove('copied');
  }, 1800);
}

function renderBubbleContent(
  container,
  content,
  senderPubkey,
  isOut,
  messageId = null,
) {
  const result = { actions: null, hasMedia: false, mediaEncrypted: null };
  const baseCleaned = stripPushstrClientTag(stripNip18(content));
  const extracted = extractPushstrMedia(baseCleaned);
  const cleaned = extracted.text;
  const mediaJson = extracted.mediaJson;
  const renderTextIfAny = (urlToStrip = null) => {
    let txt = cleaned;
    if (urlToStrip) {
      txt = txt.replace(urlToStrip, '').trim();
    }
    if (txt) {
      const target = container.childNodes.length
        ? document.createElement('div')
        : container;
      renderTextWithReadMore(target, txt);
      if (target !== container) container.appendChild(target);
    }
  };
  let jsonPart = mediaJson || cleaned;
  let fragPart = '';
  if (cleaned.includes('#')) {
    const idx = cleaned.indexOf('#');
    jsonPart = cleaned.slice(0, idx);
    fragPart = cleaned.slice(idx + 1);
  }

  let parsed = null;
  try {
    parsed = JSON.parse(jsonPart);
  } catch (_) {
    parsed = null;
    // Try decoding URI-encoded JSON then parse
    try {
      const decoded = decodeURIComponent(jsonPart.replace(/\+/g, '%20'));
      const trimmed = decoded.replace(/^"+|"+$/g, '');
      parsed = JSON.parse(trimmed);
    } catch (_) {
      parsed = null;
    }
  }

  const fragMeta = parseFragmentMeta(fragPart);
  if (parsed?.media?.url) {
    const media = parsed.media;
    const fullUrl = fragPart ? `${media.url}#${fragPart}` : media.url;
    const actionHolder = document.createElement('div');
    actionHolder.className = 'actions-col';
    const downloadCtrl = createDownloadButton(
      null,
      media.mime || fragMeta.mime,
      media.size || fragMeta.size,
      media.sha256 || fragMeta.sha256,
      {
        ...fragMeta,
        filename: media.filename,
      },
    );
    actionHolder.appendChild(downloadCtrl.btn);
    // Check if media is encrypted (has encryption marker and IV)
    const isEncrypted =
      (media.encryption === 'aes-gcm' || media.cipher_sha256) && media.iv;
    result.hasMedia = true;
    result.mediaEncrypted = isEncrypted;
    if (isEncrypted) {
      renderEncryptedMedia(
        container,
        media,
        senderPubkey,
        fullUrl,
        fragMeta,
        downloadCtrl,
        isOut,
        messageId,
      );
    } else {
      // Preview inside bubble (unencrypted)
      const mime = media.mime || '';
      if (mime.startsWith('image')) {
        const img = document.createElement('img');
        img.src = fullUrl;
        img.style.maxWidth = '180px';
        img.style.maxHeight = '180px';
        img.style.display = 'block';
        makeZoomableImage(img, fullUrl);
        container.appendChild(img);
      } else if (mime.startsWith('video')) {
        container.appendChild(buildVideoPlayer(fullUrl));
      } else if (mime.startsWith('audio')) {
        const audio = document.createElement('audio');
        audio.src = fullUrl;
        audio.controls = true;
        audio.className = 'audio-player';
        container.appendChild(audio);
      } else {
        const info = document.createElement('div');
        info.textContent = media.filename || 'Attachment';
        info.style.fontSize = '13px';
        container.appendChild(info);
      }
      downloadCtrl.setTarget(fullUrl, media.filename);
    }
    result.actions = actionHolder;
    return result;
  }
  if (parsed && parsed.url) {
    const fullUrl = fragPart ? `${parsed.url}#${fragPart}` : parsed.url;
    const meta = {
      ...fragMeta,
      url: fullUrl,
      mime: parsed.type || fragMeta.mime,
      size: parsed.size || fragMeta.size,
      sha256: parsed.sha256 || fragMeta.sha256,
      filename: parsed.filename,
    };
    if (isBlossomLink(fullUrl, meta)) {
      const actionHolder = document.createElement('div');
      actionHolder.className = 'actions-col';
      const dl = createDownloadButton(
        fullUrl,
        meta.mime,
        meta.size,
        meta.sha256,
        meta,
      );
      actionHolder.appendChild(dl.btn);
      if (meta.isImage || /\.(png|jpe?g|gif|webp)$/i.test(parsed.url)) {
        const img = document.createElement('img');
        img.src = fullUrl;
        img.style.maxWidth = '180px';
        img.style.maxHeight = '180px';
        img.style.display = 'block';
        makeZoomableImage(img, fullUrl);
        container.appendChild(img);
      }
      renderTextIfAny(fullUrl);
      result.actions = actionHolder;
      return result;
    }
    renderLink(container, fullUrl);
    renderTextIfAny(fullUrl);
    return null;
  }

  const meta = parseUrlMeta(cleaned);
  if (meta) {
    if (isBlossomLink(meta.url, meta)) {
      const actionHolder = document.createElement('div');
      actionHolder.className = 'actions-col';
      const dl = createDownloadButton(
        meta.url,
        meta.mime,
        meta.size,
        meta.sha256,
        meta,
      );
      actionHolder.appendChild(dl.btn);
      if (meta.isImage) {
        const img = document.createElement('img');
        img.src = meta.url;
        img.style.maxWidth = '180px';
        img.style.maxHeight = '180px';
        img.style.display = 'block';
        makeZoomableImage(img, meta.url);
        container.appendChild(img);
      }
      renderTextIfAny(meta.url);
      result.actions = actionHolder;
      return result;
    }
    renderLink(container, meta.url);
    renderTextIfAny(meta.url);
    return null;
  }

  const urlMatch = cleaned.match(/https?:\/\/\S+/i);
  if (urlMatch) {
    const metaFromUrl = parseUrlMeta(urlMatch[0]);
    if (metaFromUrl && isBlossomLink(metaFromUrl.url, metaFromUrl)) {
      const actionHolder = document.createElement('div');
      actionHolder.className = 'actions-col';
      const dl = createDownloadButton(
        metaFromUrl.url,
        metaFromUrl.mime,
        metaFromUrl.size,
        metaFromUrl.sha256,
        metaFromUrl,
      );
      actionHolder.appendChild(dl.btn);
      if (metaFromUrl.isImage) {
        const img = document.createElement('img');
        img.src = metaFromUrl.url;
        img.style.maxWidth = '180px';
        img.style.maxHeight = '180px';
        img.style.display = 'block';
        makeZoomableImage(img, metaFromUrl.url);
        container.appendChild(img);
      }
      renderTextIfAny(metaFromUrl.url);
      result.actions = actionHolder;
      return result;
    }
    renderLink(container, urlMatch[0]);
    renderTextIfAny(urlMatch[0]);
    return null;
  }

  renderTextWithReadMore(container, cleaned);
  return null;
}

function updateComposerMode() {
  const hasContent = messageInput.value.trim().length > 0 || pendingFile;
  if (hasContent) {
    attachBtn.classList.add('hidden');
    sendBtn.classList.remove('hidden');
  } else {
    attachBtn.classList.remove('hidden');
    sendBtn.classList.add('hidden');
  }
  updateDmToggle();
}

function getDmModeForContact(contact) {
  if (!contact) return 'nip17';
  const modes = state.dmModes || {};
  return modes[contact] || 'nip17';
}

async function toggleDmMode() {
  if (!selectedContact) return;
  const current = getDmModeForContact(selectedContact);
  const next = current === 'nip17' ? 'nip04' : 'nip17';
  state.dmModes = { ...(state.dmModes || {}), [selectedContact]: next };
  updateDmToggle();
  try {
    await safeSend({
      type: 'set-dm-mode',
      recipient: selectedContact,
      mode: next,
    });
  } catch (err) {
    console.error('[pushstr][popup] set-dm-mode failed', err);
  }
}

function updateDmToggle() {
  if (!dmToggleBtn) return;
  const mode = getDmModeForContact(selectedContact);
  dmToggleBtn.classList.toggle('active', mode === 'nip17');
  dmToggleBtn.dataset.mode = mode;
  dmToggleBtn.title =
    mode === 'nip17' ? 'NIP-17 (giftwrap)' : 'NIP-04 (legacy)';
}

function normalizeDmKind(message) {
  if (!message) return null;
  if (message.dm_kind === 'nip04' || message.dm_kind === 'nip17')
    return message.dm_kind;
  if (message.outerKind === 4) return 'nip04';
  if (message.outerKind === 1059 || message.outerKind === 14) return 'nip17';
  return null;
}

function buildDmBadge(kind) {
  if (!kind) return null;
  const badge = document.createElement('span');
  badge.className = `badge dm ${kind}`;
  badge.textContent = kind === 'nip04' ? '04' : '17';
  badge.title = kind === 'nip04' ? 'NIP-04' : 'NIP-17';
  return badge;
}

function buildReceiptBadge(message) {
  if (!message || message.direction !== 'out') return null;
  const hasRead = message.read_at || message.read;
  const badge = document.createElement('span');
  badge.className = `badge receipt ${hasRead ? 'read' : 'sent'}`;
  badge.textContent = hasRead ? 'R' : 'S';
  badge.title = hasRead ? 'Read' : 'Sent';
  return badge;
}

function buildLockBadge(encrypted) {
  const badge = document.createElement('span');
  badge.className = `badge lock ${encrypted ? 'encrypted' : 'unencrypted'}`;
  badge.textContent = encrypted ? '🔒' : '🔓';
  return badge;
}

function attachFile() {
  if (!isPopout) {
    // Attachments are more reliable in the popout; open it and let the user retry there.
    popout();
    status('Opened popout for attachments');
    return;
  }
  const input = document.createElement('input');
  input.type = 'file';
  input.onchange = async () => {
    const file = input.files?.[0];
    if (!file) return;
    await handleFileAttachment(file);
  };
  input.click();
}

async function handlePaste(event) {
  const items = event.clipboardData?.items || [];
  const files = [];
  for (const item of items) {
    if (item.kind === 'file') {
      const file = item.getAsFile();
      if (file) files.push(file);
    }
  }
  if (files.length) {
    event.preventDefault();
    await handleFileAttachment(files[0]);
    return;
  }
  for (const item of items) {
    if (item.kind === 'string') {
      const data = await new Promise((resolve) => item.getAsString(resolve));
      const trimmed = (data || '').trim();
      if (trimmed.startsWith('data:')) {
        event.preventDefault();
        const file = dataUrlToFile(trimmed, 'pasted');
        if (file) await handleFileAttachment(file);
        return;
      }
    }
  }
}

async function handleFileAttachment(file) {
  showPreview(file);
  try {
    pendingFile = file;
    const dismissed =
      localStorage.getItem('pushstr_upload_warn_dismissed') === '1';
    if (!dismissed) warningEl.classList.remove('hidden');
    updateComposerMode();
  } catch (err) {
    status(`Attachment failed: ${err.message}`);
    clearPreview();
  }
}

function buildPushstrAttachmentPayload(text, media) {
  const filename = media.filename || 'attachment';
  const sizeLabel =
    typeof media.size === 'number' ? formatSize(media.size) : null;
  const attachmentLine = sizeLabel
    ? `Attachment: ${filename} (${sizeLabel})`
    : `Attachment: ${filename}`;
  const url = media.url || '';
  const descriptorJson = JSON.stringify({ media });
  const lines = [];
  if (text) lines.push(text);
  lines.push(attachmentLine);
  if (url) lines.push(url);
  lines.push('', PUSHSTR_MEDIA_START, descriptorJson, PUSHSTR_MEDIA_END);
  return lines.join('\n');
}

function dataUrlToFile(dataUrl, basename) {
  try {
    const match = dataUrl.match(/^data:([^;]+);base64,(.+)$/);
    if (!match) return null;
    const mime = match[1];
    const b64 = match[2];
    const bytes = b64ToBytes(b64);
    const ext = mime.includes('/') ? mime.split('/')[1] : 'bin';
    return new File([bytes], `${basename}.${ext}`, { type: mime });
  } catch (_) {
    return null;
  }
}

function showPreview(file) {
  previewEl.classList.remove('uploaded');
  clearPreviewBtn.classList.remove('hidden');
  previewContentEl.replaceChildren();
  if (file) {
    if (file.type.startsWith('image')) {
      const url = URL.createObjectURL(file);
      const img = document.createElement('img');
      img.src = url;
      img.alt = 'preview';
      previewContentEl.appendChild(img);
    } else {
      const sizeLabel = formatSize(file.size);
      const chip = document.createElement('div');
      chip.className = 'file-chip';
      chip.textContent = `${file.name || 'attachment'} (${sizeLabel})`;
      previewContentEl.appendChild(chip);
    }
    previewEl.style.display = 'block';
  } else {
    previewContentEl.textContent = '';
    previewEl.style.display = 'none';
  }
}

function clearPreview(keepUploaded = false) {
  if (keepUploaded && previewEl.classList.contains('uploaded')) {
    // Leave uploaded preview visible
    return;
  }
  previewContentEl.textContent = '';
  previewEl.style.display = 'none';
  previewEl.classList.remove('uploaded');
  clearPreviewBtn.classList.remove('hidden');
  pendingFile = null;
  updateComposerMode();
}

async function deleteConversation() {
  if (!selectedContact) return;
  const label = contactLabel(selectedContact) || short(selectedContact);
  const ok = confirm(
    `Delete conversation with ${label}? This removes local history only.`,
  );
  if (!ok) return;
  try {
    await browser.runtime.sendMessage({
      type: 'delete-conversation',
      recipient: selectedContact,
    });
    await refreshState();
  } catch (err) {
    status(`Delete failed: ${err?.message || err}`);
  }
}

function contactLabel(pk) {
  if (!pk) return '';
  const found = (state.recipients || []).find((r) => r.pubkey === pk);
  return found?.nickname || short(pk);
}

function stripNip18(text) {
  if (!text) return '';
  return text.replace(/^\[\/\/\]:\s*#\s*\(nip18\)\s*/i, '').trim();
}

function stripPushstrClientTag(text) {
  if (!text) return '';
  if (!text.includes(PUSHSTR_CLIENT_TAG)) return text;
  return text
    .replace(/(^|\n)\[pushstr:client\](\n|$)/g, '\n')
    .trim();
}

function parseUrlMeta(text) {
  if (!text) return null;
  const trimmed = text.trim();
  if (!/^https?:\/\//i.test(trimmed)) return null;
  const [base, frag] = trimmed.split('#', 2);
  let mime = '';
  let size = '';
  let sha256 = '';
  if (frag) {
    const params = new URLSearchParams(frag);
    mime = params.get('m') || '';
    size = params.get('size') || '';
    sha256 = params.get('x') || params.get('sha256') || '';
  }
  const isImage =
    (mime && mime.startsWith && mime.startsWith('image')) ||
    /\.(png|jpe?g|gif|webp)$/i.test(base);
  return { url: base + (frag ? '#' + frag : ''), isImage, size, mime, sha256 };
}

function parseFragmentMeta(frag) {
  if (!frag) return {};
  const params = new URLSearchParams(frag);
  const mime = params.get('m') || '';
  const size = params.get('size') || '';
  const sha256 = params.get('x') || '';
  const isImage = mime.startsWith('image');
  return { mime, size, sha256, isImage };
}

function isBlossomLink(url, meta = {}) {
  const hasMeta = Boolean(
    meta.sha256 || meta.mime || meta.size || meta.iv || meta.cipher_sha256,
  );
  if (!url) return false;
  try {
    const parsed = new URL(url);
    const hostMatches = parsed.hostname.includes('blossom');
    const frag = parsed.hash || '';
    const fragHasMeta =
      frag.includes('m=') || frag.includes('size=') || frag.includes('x=');
    return hasMeta && (hostMatches || fragHasMeta);
  } catch (_) {
    return hasMeta;
  }
}

function formatSize(bytes) {
  if (!bytes && bytes !== 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let v = bytes;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(1)} ${units[i]}`;
}

function friendlyTime(ts) {
  if (!ts) return '';
  const date = new Date(ts * 1000);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  if (diffMs < 60 * 1000) return 'Just now';
  const midnight = (d) =>
    new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const todayStart = midnight(now);
  const yesterdayStart = todayStart - 24 * 60 * 60 * 1000;
  const dateStart = midnight(date);
  const timePart = date.toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
  });

  if (dateStart === todayStart) return `Today at ${timePart}`;
  if (dateStart === yesterdayStart) return `Yesterday at ${timePart}`;

  const opts = { weekday: 'long', month: 'long', day: 'numeric' };
  const base = date.toLocaleDateString(undefined, opts);
  return `${base} at ${timePart}`;
}

function truncateSnippet(text) {
  if (!text) return '';
  const max = 80;
  return text.length > max ? text.slice(0, max) + '…' : text;
}

function renderTextWithReadMore(container, text) {
  const MAX_LEN = 400;
  if (/https?:\/\/\S+/i.test(text)) {
    renderTextWithLinks(container, text);
    return;
  }
  if (!text || text.length <= MAX_LEN) {
    container.textContent = text;
    return;
  }
  const short = text.slice(0, MAX_LEN) + '…';
  const fullSpan = document.createElement('span');
  fullSpan.textContent = text;
  fullSpan.style.display = 'none';

  const shortSpan = document.createElement('span');
  shortSpan.textContent = short + ' ';

  const link = document.createElement('a');
  link.href = '#';
  link.textContent = 'Read more';
  link.classList.add('read-more');
  link.style.fontWeight = '700';
  link.addEventListener('click', (e) => {
    e.preventDefault();
    const expanded = fullSpan.style.display !== 'none';
    if (expanded) {
      fullSpan.style.display = 'none';
      shortSpan.style.display = 'inline';
      link.textContent = 'Read more';
    } else {
      fullSpan.style.display = 'inline';
      shortSpan.style.display = 'none';
      link.textContent = 'Show less';
      link.classList.add('expanded');
    }
  });

  container.appendChild(shortSpan);
  container.appendChild(fullSpan);
  container.appendChild(link);
}

function renderTextWithLinks(container, text) {
  container.replaceChildren();
  const parts = text.split(/(https?:\/\/\S+)/gi);
  for (const part of parts) {
    if (!part) continue;
    if (/^https?:\/\/\S+/i.test(part)) {
      const a = document.createElement('a');
      a.href = part;
      a.target = '_blank';
      a.rel = 'noreferrer noopener';
      a.textContent = part;
      a.className = 'inline-link';
      container.appendChild(a);
    } else {
      container.appendChild(document.createTextNode(part));
    }
  }
}

function renderLink(container, url, label = null) {
  const link = document.createElement('a');
  link.href = url;
  link.target = '_blank';
  link.rel = 'noreferrer noopener';
  link.textContent = label || url;
  link.className = 'inline-link';
  if (container.childNodes.length) {
    const spacer = document.createElement('div');
    spacer.appendChild(link);
    container.appendChild(spacer);
  } else {
    container.appendChild(link);
  }
}

function showUploadedPreview(url, mime = '') {
  // For now we clear the preview once sent to avoid lingering chips.
  clearPreview();
}

function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}
