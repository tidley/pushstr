import { nip19, getPublicKey } from "nostr-tools";
import QRCode from "qrcode";

function makeBrowser() {
  if (globalThis.browser) return globalThis.browser;
  if (globalThis.chrome) {
    const c = globalThis.chrome;
    const promisify = (api, fn) => (...args) =>
      new Promise((resolve, reject) => {
        try {
          fn.apply(api, [
            ...args,
            (result) => {
              const err = c.runtime?.lastError;
              if (err) reject(new Error(err.message || String(err)));
              else resolve(result);
            }
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
        onMessage: c.runtime.onMessage
      },
      storage: c.storage
        ? {
            ...c.storage,
            local: {
              ...c.storage.local,
              get: promisify(c.storage.local, c.storage.local.get),
              set: promisify(c.storage.local, c.storage.local.set),
              remove: promisify(c.storage.local, c.storage.local.remove)
            }
          }
        : undefined,
      downloads: c.downloads
        ? {
            ...c.downloads,
            download: promisify(c.downloads, c.downloads.download)
          }
        : undefined
    };
  }
  return null;
}

const browser = makeBrowser();
const pubkeyLabel = document.getElementById("pubkeyLabel");
const contactsBody = document.getElementById("contactsBody");
const keySelect = document.getElementById("keySelect");
const keyNicknameEl = document.getElementById("keyNickname");
const saveBtn = document.getElementById("save");
const copyNsecBtn = document.getElementById("export");
const copyNpubBtn = document.getElementById("exportNpub");
const relayInput = document.getElementById("relayInput");
const relayError = document.getElementById("relayError");
const relayList = document.getElementById("relayList");
const contactPub = document.getElementById("contactPub");
const contactNick = document.getElementById("contactNick");
const contactError = document.getElementById("contactError");
const saveStatus = document.getElementById("saveStatus");
const editTimers = new WeakMap();

async function safeSend(message, { attempts = 3, delayMs = 150 } = {}) {
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      return await browser.runtime.sendMessage(message);
    } catch (err) {
      lastErr = err;
      const msg = err?.message || "";
      if (!/port closed/i.test(msg)) break;
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}

function setSaveStatus(message, tone = "muted") {
  if (!saveStatus) return;
  saveStatus.textContent = message;
  saveStatus.dataset.tone = tone;
  saveStatus.classList.remove("flash");
  // Force reflow so the flash animation restarts
  void saveStatus.offsetWidth;
  saveStatus.classList.add("flash");
}

function syncFloatingState(el) {
  if (!el) return;
  const field = el.closest(".field");
  if (!field) return;
  if (el.value?.trim()) field.classList.add("filled");
  else field.classList.remove("filled");
}

saveBtn.addEventListener("click", save);
document.getElementById("regen").addEventListener("click", regen);
document.getElementById("import").addEventListener("click", importNsec);
copyNsecBtn.addEventListener("click", exportNsec);
copyNpubBtn.addEventListener("click", exportNpub);
document.getElementById("showNpubQr").addEventListener("click", showNpubQr);
document.getElementById("removeProfile").addEventListener("click", removeProfile);
document.getElementById("addContact").addEventListener("click", addContactFromForm);
document.getElementById("addRelay").addEventListener("click", addRelayFromInput);
keySelect.addEventListener("change", async () => {
  const nsec = keySelect.value;
  if (nsec) await switchKey(nsec);
  syncFloatingState(keySelect);
});

[keyNicknameEl, relayInput, contactPub, contactNick].forEach((el) => {
  if (!el) return;
  el.addEventListener("input", () => syncFloatingState(el));
  el.addEventListener("blur", () => syncFloatingState(el));
});

init();

async function init() {
  let state;
  try {
    state = await safeSend({ type: "get-state" });
    console.info("[pushstr][options] state", state);
  } catch (err) {
    console.error("[pushstr][options] get-state failed", err);
    state = await loadStateFallback();
  }
  if (!state) {
    console.error("[pushstr][options] no state returned");
    status("Background unavailable. Reload extension and retry.");
    return;
  }
  try {
    const relays = Array.isArray(state.relays) ? state.relays : [];
    const recipients = Array.isArray(state.recipients) ? state.recipients : [];
    const keys = Array.isArray(state.keys) ? state.keys : [];
    renderContacts(recipients, true);
    renderRelays(relays, true);
    populateKeys(keys, state.pubkey);
    fillKeyNickname(keys, state.pubkey);
    saveBtn.disabled = true;
    saveBtn.textContent = "Save";
    setSaveStatus("All changes saved", "muted");
    syncFloatingState(keySelect);
    syncFloatingState(keyNicknameEl);
    syncFloatingState(relayInput);
    syncFloatingState(contactPub);
    syncFloatingState(contactNick);
  } catch (err) {
    console.error("[pushstr][options] render failed", err, state);
  }
  if (!state.pubkey) {
    try {
      await browser.runtime.sendMessage({ type: "generate-key" });
      const refreshed = await browser.runtime.sendMessage({ type: "get-state" });
      state = refreshed || state;
    } catch (_) {
      status("Unable to initialize key");
    }
  }
  pubkeyLabel.textContent = state.pubkey ? `Active npub: ${shortKey(state.pubkey)}` : "No key";
}

async function loadStateFallback() {
  try {
    const stored = await browser.storage.local.get();
    if (!stored) return null;
    const pubkey = stored.pubkey || derivePubkeyFromNsec(stored.nsec);
    return { ...stored, pubkey };
  } catch (err) {
    console.error("[pushstr][options] fallback load failed", err);
    return null;
  }
}

function derivePubkeyFromNsec(nsec) {
  if (!nsec) return null;
  try {
    const dec = nip19.decode(nsec);
    const priv = dec.type === "nsec" ? dec.data : nsec;
    return getPublicKey(priv);
  } catch (_) {
    return null;
  }
}

async function save() {
  if (saveBtn.disabled) {
    setSaveStatus("No changes to save", "muted");
    return;
  }
  const relays = readRelays();
  const recipients = readContacts();
  const keyNickname = keyNicknameEl.value.trim();
  try {
    setSaveStatus("Saving...", "warn");
    saveBtn.textContent = "Saving...";
    saveBtn.disabled = true;
    await safeSend({
      type: "save-settings",
      relays,
      recipients,
      useGiftwrap: true,
      useNip44: true,
      keyNickname
    });
    saveBtn.textContent = "Saved";
    setSaveStatus("Saved", "success");
    setTimeout(() => {
      saveBtn.textContent = "Save";
      setSaveStatus("All changes saved", "muted");
    }, 2000);
    await init();
  } catch (err) {
    console.error("Save failed", err);
    saveBtn.textContent = "Save";
    saveBtn.disabled = false;
    setSaveStatus("Save failed", "warn");
  }
}

function status(msg, tone = "warn") {
  setSaveStatus(msg, tone);
}

function markDirty() {
  saveBtn.disabled = false;
  saveBtn.textContent = "Save";
  setSaveStatus("Unsaved changes", "warn");
}

function showEditedTag(wrapper) {
  if (!wrapper) return;
  wrapper.classList.add("just-edited");
  const existing = editTimers.get(wrapper);
  if (existing) clearTimeout(existing);
  const timer = setTimeout(() => wrapper.classList.remove("just-edited"), 1800);
  editTimers.set(wrapper, timer);
}

async function regen() {
  try {
    await safeSend({ type: "generate-key" });
    await init();
  } catch (err) {
    status("Generate failed: background unavailable");
  }
}

function renderContacts(list, initial = false) {
  contactsBody.innerHTML = "";
  list.forEach((r) => addContactRow(r.nickname, r.pubkey));
  if (!initial) markDirty();
}

function addContactRow(nickname = "", pubkey = "") {
  const tr = document.createElement("tr");
  const tdPub = document.createElement("td");
  tdPub.className = "pubcol";
  const tdNick = document.createElement("td");
  tdNick.className = "nickcol";
  const tdDel = document.createElement("td");
  tdDel.className = "delcol";
  const hiddenPub = document.createElement("input");
  hiddenPub.type = "hidden";
  hiddenPub.value = pubkey || "";
  const nickInput = document.createElement("input");
  nickInput.type = "text";
  nickInput.placeholder = "Nickname";
  nickInput.value = nickname || "";
  const nickId = `nick-${Math.random().toString(36).slice(2, 8)}`;
  nickInput.id = nickId;
  const nickLabel = document.createElement("label");
  nickLabel.htmlFor = nickId;
  nickLabel.textContent = "Nickname";
  const nickField = document.createElement("div");
  nickField.className = "field floating";
  nickField.appendChild(nickInput);
  nickField.appendChild(nickLabel);
  const nickWrap = document.createElement("div");
  nickWrap.className = "nick-wrapper";
  nickWrap.appendChild(nickField);
  const editedTag = document.createElement("span");
  editedTag.className = "edit-indicator";
  editedTag.textContent = "Edited";
  nickWrap.appendChild(editedTag);
  nickInput.addEventListener("input", () => {
    markDirty();
    syncFloatingState(nickInput);
    showEditedTag(nickWrap);
  });
  const pubLabel = document.createElement("span");
  pubLabel.className = "truncate";
  const fullNpub = toNpub(pubkey);
  pubLabel.textContent = fullNpub || pubkey;
  pubLabel.title = fullNpub || pubkey;
  const delBtn = document.createElement("button");
  delBtn.type = "button";
  delBtn.className = "icon-btn danger";
  delBtn.setAttribute("aria-label", "Remove contact");
  delBtn.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 3h6a1 1 0 0 1 1 1v2h3v2h-1v11a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V8H5V6h3V4a1 1 0 0 1 1-1zm1 3h4V5h-4zm-1 4v7h2v-7zm4 0v7h2v-7z"/></svg>';
  delBtn.addEventListener("click", () => {
    if (!confirm("Remove this contact?")) return;
    tr.remove();
    markDirty();
  });
  tdPub.appendChild(pubLabel);
  tdPub.appendChild(hiddenPub);
  tdNick.appendChild(nickWrap);
  tdDel.appendChild(delBtn);
  tr.appendChild(tdPub);
  tr.appendChild(tdNick);
  tr.appendChild(tdDel);
  contactsBody.appendChild(tr);
  syncFloatingState(nickInput);
}

function readContacts() {
  const rows = Array.from(contactsBody.querySelectorAll("tr"));
  return rows
    .map((tr) => {
      const hiddenPub = tr.querySelector('input[type="hidden"]');
      const nicknameInput = tr.querySelector('input[type="text"]');
      const pubkey = hiddenPub?.value.trim() || "";
      const nickname = nicknameInput?.value.trim() || "";
      if (!pubkey) return null;
      return { nickname, pubkey };
    })
    .filter(Boolean);
}

function addContactFromForm() {
  contactError.textContent = "";
  const pubkey = contactPub.value.trim();
  const nickname = contactNick.value.trim();
  if (!pubkey) {
    contactError.textContent = "Pubkey is required";
    return;
  }
  const normalized = normalizePubkeyInput(pubkey);
  if (!normalized) {
    contactError.textContent = "Enter a valid npub or hex pubkey";
    return;
  }
  const exists = Array.from(contactsBody.querySelectorAll('input[type="hidden"]')).find((el) => el.value === normalized);
  if (exists) {
    contactError.textContent = "Contact already added";
    return;
  }
  addContactRow(nickname, normalized);
  contactPub.value = "";
  contactNick.value = "";
  syncFloatingState(contactPub);
  syncFloatingState(contactNick);
  markDirty();
}

async function importNsec() {
  const val = prompt("Paste nsec...");
  if (!val) return;
  try {
    await safeSend({ type: "import-nsec", value: val.trim() });
    await init();
  } catch (err) {
    status("Import failed: background unavailable");
  }
}

async function exportNsec() {
  let res;
  try {
    res = await safeSend({ type: "export-nsec" });
  } catch (err) {
    status("Background unavailable");
    return;
  }
  if (!res?.nsec) {
    status("No key to export");
    return;
  }
  try {
    await navigator.clipboard.writeText(res.nsec);
    flashButton(copyNsecBtn, "Copied");
  } catch (err) {
    prompt("Your nsec (keep secret):", res.nsec);
    status("Copy failed; shown in prompt");
  }
}

async function exportNpub() {
  let res;
  try {
    res = await safeSend({ type: "export-npub" });
  } catch (err) {
    status("Background unavailable");
    return;
  }
  if (!res?.npub) {
    status("No key to export");
    return;
  }
  try {
    await navigator.clipboard.writeText(res.npub);
    flashButton(copyNpubBtn, "Copied");
  } catch (err) {
    prompt("Your npub:", res.npub);
    status("Copy failed; shown in prompt");
  }
}

async function showNpubQr() {
  let res;
  try {
    res = await safeSend({ type: "export-npub" });
  } catch (err) {
    status("Background unavailable");
    return;
  }
  const npub = res?.npub;
  if (!npub) {
    status("No key to show");
    return;
  }
  try {
    const dataUrl = await QRCode.toDataURL(npub, { margin: 1, scale: 6 });
    const overlay = document.createElement("div");
    overlay.className = "qr-overlay";
    const card = document.createElement("div");
    card.className = "qr-card";
    const img = document.createElement("img");
    img.src = dataUrl;
    img.alt = "npub QR";
    const label = document.createElement("p");
    label.textContent = npub;
    const closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className = "close-qr";
    closeBtn.textContent = "Close";
    card.appendChild(img);
    card.appendChild(label);
    card.appendChild(closeBtn);
    overlay.appendChild(card);
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay || e.target.classList.contains("close-qr")) {
        overlay.remove();
      }
    });
    document.body.appendChild(overlay);
  } catch (err) {
    status("QR failed: " + err.message);
  }
}

function populateKeys(keys = [], currentPub) {
  keySelect.innerHTML = "";
  const unique = [];
  (keys || []).forEach((k) => {
    if (!k?.pubkey || !k?.nsec) return;
    if (!unique.find((u) => u.pubkey === k.pubkey || u.nsec === k.nsec)) unique.push(k);
  });
  if (unique.length === 0 && currentPub) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = shortKey(toNpub(currentPub));
    keySelect.appendChild(opt);
    pubkeyLabel.textContent = `Active npub:`;
    return;
  }
  unique.forEach((k) => {
    const opt = document.createElement("option");
    opt.value = k.nsec;
    opt.textContent = `${shortKey(k.pubkey) || shortKey(k.nsec)}`;
    if (currentPub && k.pubkey === currentPub) opt.selected = true;
    keySelect.appendChild(opt);
  });
  if (!keySelect.value && unique[0]) keySelect.value = unique[0].nsec;
  if (currentPub) pubkeyLabel.textContent = `Active npub: ${shortKey(currentPub)}`;
  syncFloatingState(keySelect);
}

relayInput?.addEventListener("input", () => {
  relayError.textContent = "";
  syncFloatingState(relayInput);
});
keyNicknameEl.addEventListener("input", () => {
  markDirty();
  syncFloatingState(keyNicknameEl);
});

async function switchKey() {
  const nsec = keySelect.value;
  if (!nsec) return;
  await safeSend({ type: 'switch-key', nsec });
  await init();
}

function toNpub(pk) {
  if (!pk) return "";
  if (pk.startsWith("npub")) return pk;
  try {
    const decoded = nip19.decode(pk);
    if (decoded.type === "nprofile" && decoded.data?.pubkey) {
      return nip19.npubEncode(decoded.data.pubkey);
    }
    if (decoded.type === "npub" && typeof decoded.data === "string") {
      return pk;
    }
  } catch (_) {
    // fall through to encode attempt
  }
  try {
    return nip19.npubEncode(pk);
  } catch (_) {
    return pk;
  }
}

function shortKey(pk) {
  if (!pk) return "";
  if (pk.startsWith("nsec")) return `${pk.slice(0, 8)}...${pk.slice(-4)}`;
  const npub = toNpub(pk);
  if (!npub) return "";
  if (npub.length <= 12) return npub;
  return `${npub.slice(0, 8)}...${npub.slice(-4)}`;
}

function fillKeyNickname(keys, currentPub) {
  const entry = (keys || []).find((k) => k.pubkey === currentPub);
  keyNicknameEl.value = entry?.nickname || "";
  syncFloatingState(keyNicknameEl);
}

function flashButton(btn, label = "Copied") {
  if (!btn) return;
  const original = btn.textContent;
  btn.textContent = label;
  setTimeout(() => {
    btn.textContent = original;
  }, 1500);
}

function removeProfile() {
  const selected = keySelect.value;
  if (!selected) return;
  const options = Array.from(keySelect.options);
  if (options.length <= 1) {
    alert("Cannot remove the only profile");
    return;
  }
  if (!confirm("Remove this profile?")) return;
  safeSend({ type: "remove-key", nsec: selected }).then(() => init()).catch((err) => {
    console.error("[pushstr][options] remove-key failed", err);
  });
}

function renderRelays(relays = [], initial = false) {
  relayList.innerHTML = "";
  relays.forEach((relay) => relayList.appendChild(renderRelayRow(relay)));
  if (!initial) markDirty();
}

function renderRelayRow(relay) {
  const row = document.createElement("div");
  row.className = "relay-row";
  const info = document.createElement("div");
  info.className = "relay-info";
  const statusDot = document.createElement("span");
  statusDot.className = "status-dot status-idle";
  statusDot.title = "Status unknown";
  const span = document.createElement("span");
  span.className = "relay-url";
  span.textContent = relay;
  span.title = relay;
  info.appendChild(statusDot);
  info.appendChild(span);
  const btn = document.createElement("button");
  btn.className = "icon-btn danger";
  btn.type = "button";
  btn.setAttribute("aria-label", "Remove relay");
  btn.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 3h6a1 1 0 0 1 1 1v2h3v2h-1v11a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V8H5V6h3V4a1 1 0 0 1 1-1zm1 3h4V5h-4zm-1 4v7h2v-7zm4 0v7h2v-7z"/></svg>';
  btn.addEventListener("click", () => {
    if (!confirm("Remove this relay?")) return;
    row.remove();
    markDirty();
  });
  row.appendChild(info);
  row.appendChild(btn);
  return row;
}

function addRelayFromInput() {
  relayError.textContent = "";
  const val = relayInput.value.trim();
  if (!val || !(val.startsWith("ws://") || val.startsWith("wss://"))) {
    relayError.textContent = "Enter a valid ws:// or wss:// URL";
    return;
  }
  const existing = Array.from(relayList.querySelectorAll(".relay-row span")).find((s) => s.textContent === val);
  if (existing) {
    relayError.textContent = "Relay already added";
    return;
  }
  relayList.appendChild(renderRelayRow(val));
  relayInput.value = "";
  syncFloatingState(relayInput);
  markDirty();
}

function readRelays() {
  return Array.from(relayList.querySelectorAll(".relay-row .relay-url")).map((s) => s.textContent).filter(Boolean);
}

function normalizePubkeyInput(input) {
  const trimmed = input.trim();
  if (!trimmed) return null;
  if (/^npub/i.test(trimmed)) return toNpub(trimmed);
  if (/^[0-9a-fA-F]{64}$/.test(trimmed)) return trimmed.toLowerCase();
  return null;
}
