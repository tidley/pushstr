// Background script: manages key material, relay connections, and Giftwrapped DM send/receive.
import pako from "pako";
import * as WasmCrypto from "./wasm_crypto.js";
import * as nt from "nostr-tools";

function makeBrowser() {
  if (globalThis.browser) return globalThis.browser;
  if (globalThis.chrome) {
    const c = globalThis.chrome;
    const promisify = (api, fn) => (...args) =>
      new Promise((resolve, reject) => {
        try {
          fn.apply(api, [...args, (result) => {
            const err = c.runtime?.lastError;
            if (err) reject(err);
            else resolve(result);
          }]);
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

// nt is ready immediately via static import
let pool;
let sub;
let CryptoWasm = WasmCrypto; // WASM crypto module
let activeRelays = [];
const DEFAULT_RELAYS = [
  "wss://relay.damus.io",
  "wss://relay.primal.net",
  "wss://nos.lol",
  "wss://nostr.mom",
  "wss://relay.nostr.band",
  "wss://relay.snort.social",
  "wss://relay.nostr.bg",
  "wss://eden.nostr.land",
  "wss://relay.nostr.wine",
  "wss://relay.plebstr.com"
];
let settings = {
  relays: [...DEFAULT_RELAYS],
  recipients: [],
  recipientsByKey: {},
  messagesByKey: {},
  nsec: null,
  keys: [],
  useGiftwrap: true, // default to giftwrap
  useNip44: true, // default to nip44 for inner/gift encryption
  lastRecipient: null,
  relayFailures: {}
};
let messages = [];
const MESSAGE_LIMIT = 200;
let messageIds = new Set();
let contextMenuReady = false;
const BLOSSOM_SERVER = "https://blossom.primal.net";
const PUBLISH_RETRY_ATTEMPTS = 3;
const PUBLISH_RETRY_BASE_MS = 400;
const RELAY_COOLDOWN_MS = 10 * 60 * 1000;
const KEEP_ALIVE_MS = 5 * 60 * 1000;
const READ_RECEIPT_KEY = "pushstr_ack";
const PUSHSTR_CLIENT_TAG = "[pushstr:client]";
const BLOSSOM_UPLOAD_PATH = "upload";
let suppressNotifications = true;
const sendSeqByRecipient = new Map();
let keepAliveTimer = null;
let keepAliveRunning = false;
const pendingReceipts = new Set();
const sentReceipts = new Set();
let lastConnectAt = 0;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

// Defer bootstrapping until WASM crypto loads.
const ready = (async () => {
  try {
    // Initialize WASM crypto
    // Use relative path - wasm_crypto.js will handle loading the .wasm file
    await WasmCrypto.default();

    await loadSettings();
    await ensureKey();
    await connect();
    await setupContextMenus();
    quietNotifications();
    startKeepAlive();
  } catch (err) {
    console.error("[pushstr][background] init failed", err);
  }
})();

browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    try {
      const res = await handleMessage(msg);
      sendResponse(res);
    } catch (err) {
      console.error("[pushstr][background] onMessage error", err);
      sendResponse({ error: err?.message || String(err) });
    }
  })();
  return true; // keep port open
});

async function handleMessage(msg) {
  await ready;
  if (msg.type === "get-state") {
    syncRecipientsForCurrent();
    console.log("[pushstr][background] get-state: returning", messages.length, "messages");
    return {
      pubkey: currentPubkey(),
      relays: settings.relays,
      recipients: getRecipientsForCurrent(),
      messages,
      dmModes: getDmModesForCurrent(),
      useGiftwrap: true,
      useNip44: true,
      lastRecipient: settings.lastRecipient,
      keys: settings.keys || []
    };
  }

  if (msg.type === "import-nsec") {
    return importNsec(msg.value);
  }

  if (msg.type === "generate-key") {
    return generateNewKey();
  }

  if (msg.type === "export-nsec") {
    return { nsec: settings.nsec || null };
  }

  if (msg.type === "export-npub") {
    await ensureKey();
    const priv = currentPrivkeyHex();
    if (!priv) return { npub: null };
    const pub = nt.getPublicKey(priv);
    return { npub: nt.nip19.npubEncode(pub) };
  }

  if (msg.type === "backup-profile") {
    const backup = buildProfileBackup();
    return { ok: true, backup };
  }

  if (msg.type === "backup-profiles") {
    const backup = buildProfilesBackup();
    return { ok: true, backup };
  }

  if (msg.type === "import-profile") {
    const backup = msg.backup;
    if (!backup || typeof backup !== "object") {
      return { ok: false, error: "invalid backup payload" };
    }
    const res = await importProfileBackup(backup);
    return res;
  }

  if (msg.type === "set-last-recipient") {
    settings.lastRecipient = normalizePubkey(msg.recipient);
    await persistSettings();
    return { ok: true };
  }

  if (msg.type === "resend-message") {
    const payload = msg.content || msg.message?.content;
    const recipientRaw = msg.recipient || msg.message?.to || msg.message?.recipient;
    if (!payload || !recipientRaw) {
      return { ok: false, error: "missing payload or recipient" };
    }
    const recipient = normalizePubkey(recipientRaw);
    const dmKind = msg.dm_kind || msg.message?.dm_kind || msg.message?.outerKind;
    const modeOverride = dmKind === "nip04" || dmKind === 4 ? "nip04" : "nip17";
    return await sendGift(recipient, payload, modeOverride);
  }

  if (msg.type === "set-dm-mode") {
    const recipient = normalizePubkey(msg.recipient);
    const mode = msg.mode === "nip04" ? "nip04" : "nip17";
    if (!recipient) return { error: "missing recipient" };
    setDmModeForCurrent(recipient, mode);
    await persistSettings();
    return { ok: true, mode };
  }

  if (msg.type === "upload-blossom") {
    return uploadToBlossom(msg.data, msg.recipient, msg.mime, msg.filename);
  }

  if (msg.type === "switch-key") {
    const next = msg.nsec;
    if (!next) return { ok: false };
    settings.nsec = next;
    addKeyToList(next);
    loadMessagesForCurrent();
    quietNotifications();
    syncRecipientsForCurrent();
    await persistSettings();
    await connect();
    return { ok: true };
  }

  if (msg.type === "save-settings") {
    settings.relays = msg.relays || settings.relays;
    setRecipientsForCurrent(msg.recipients || settings.recipients);
    settings.useGiftwrap = true;
    settings.useNip44 = true;
    if (typeof msg.keyNickname === "string") {
      const pk = currentPubkey();
      settings.keys = (settings.keys || []).map((k) =>
        k.pubkey === pk ? { ...k, nickname: msg.keyNickname } : k
      );
    }
    await persistSettings();
    await connect();
    return { ok: true };
  }

  if (msg.type === "remove-key") {
    const target = msg.nsec;
    if (!target) return { ok: false };
    settings.keys = (settings.keys || []).filter((k) => k.nsec !== target);
    if (settings.keys.length === 0) {
      await generateNewKey();
    } else if (settings.nsec === target) {
      settings.nsec = settings.keys[0].nsec;
    }
    loadMessagesForCurrent();
    syncRecipientsForCurrent();
    await persistSettings();
    await connect();
    return { ok: true };
  }

  if (msg.type === "download-url") {
    const { url, filename } = msg;
    if (!url) return { error: "missing url" };
    try {
      await browser.downloads.download({ url, filename: filename || undefined, saveAs: true });
      return { ok: true };
    } catch (err) {
      return { error: err?.message || "download failed" };
    }
  }

  if (msg.type === "send-gift") {
    return sendGift(msg.recipient, msg.content);
  }

  if (msg.type === "decrypt-media") {
    return decryptMediaDescriptor(msg.descriptor, msg.senderPubkey);
  }

  if (msg.type === "ensure-connect") {
    await connect();
    return { ok: true };
  }

  if (msg.type === "delete-conversation") {
    const target = normalizePubkey(msg.recipient);
    if (!target) return { error: "missing recipient" };
    const before = messages.length;
    messages = messages.filter((m) => m.from !== target && m.to !== target);
    messageIds = new Set(messages.map((m) => m.id).filter(Boolean));
    const recipients = getRecipientsForCurrent();
    const filtered = recipients.filter((r) => normalizePubkey(r.pubkey) !== target);
    if (filtered.length !== recipients.length) {
      setRecipientsForCurrent(filtered);
      if (settings.lastRecipient === target) {
        settings.lastRecipient = filtered[0]?.pubkey || null;
      }
    }
    const pub = currentPubkey();
    if (pub) {
      settings.messagesByKey = settings.messagesByKey || {};
      settings.messagesByKey[pub] = messages;
    }
    await persistSettings();
    return { ok: true, removed: before - messages.length };
  }

  return { ok: true };
}

async function importProfileBackup(backup) {
  const entries = Array.isArray(backup.profiles)
    ? backup.profiles
    : backup.profile
      ? [{ profile: backup.profile, contacts: backup.contacts || [] }]
      : [backup];
  let imported = 0;

  for (const entry of entries) {
    const profile = entry.profile || {};
    const nsec = profile.nsec;
    if (!nsec || typeof nsec !== "string") continue;
    addKeyToList(nsec);
    const pub = (() => {
      try {
        const decoded = nt.nip19.decode(nsec);
        const priv = decoded.type === "nsec" ? decoded.data : nsec;
        return nt.getPublicKey(priv);
      } catch (_) {
        try {
          return nt.getPublicKey(nsec);
        } catch (err) {
          return null;
        }
      }
    })();
    if (pub && profile.nickname) {
      settings.keys = settings.keys || [];
      settings.keys = settings.keys.map((k) =>
        k.pubkey === pub ? { ...k, nickname: profile.nickname } : k
      );
    }

    const contacts = Array.isArray(entry.contacts) ? entry.contacts : [];
    if (contacts.length) {
      const list = contacts.map((c) => ({
        pubkey: c.pubkey,
        nickname: c.nickname || ""
      }));
      const activePub = currentPubkey();
      if (activePub && pub === activePub) {
        setRecipientsForCurrent(list);
      } else {
        setRecipientsForKey(pub, list);
      }
    }
    imported++;
  }

  if (!imported) {
    return { ok: false, error: "missing nsec" };
  }
  await persistSettings();
  await connect();
  await setupContextMenus();
  syncRecipientsForCurrent();
  return { ok: true, imported };
}

function buildProfileBackup() {
  const pub = currentPubkey();
  const npub = pub ? nt.nip19.npubEncode(pub) : null;
  const keyEntry = (settings.keys || []).find((k) => k.pubkey === pub || k.nsec === settings.nsec);
  const contacts = getRecipientsForCurrent().map((c) => ({
    pubkey: c.pubkey,
    nickname: c.nickname || ""
  }));
  return {
    type: "pushstr_profile_backup",
    version: 1,
    created_at: new Date().toISOString(),
    profiles: [
      {
        profile: {
          nsec: settings.nsec || null,
          npub,
          nickname: keyEntry?.nickname || ""
        },
        contacts
      }
    ]
  };
}

function buildProfilesBackup() {
  const keys = settings.keys || [];
  const profiles = [];
  for (const key of keys) {
    const nsec = key.nsec || null;
    const pub = key.pubkey || (nsec ? derivePubkeyFromNsec(nsec) : null);
    if (!nsec || !pub) continue;
    const npub = nt.nip19.npubEncode(pub);
    const contacts = (settings.recipientsByKey?.[pub] || []).map((c) => ({
      pubkey: c.pubkey,
      nickname: c.nickname || ""
    }));
    profiles.push({
      profile: {
        nsec,
        npub,
        nickname: key.nickname || ""
      },
      contacts
    });
  }
  if (!profiles.length && settings.nsec) {
    const fallback = buildProfileBackup();
    profiles.push(...(fallback.profiles || []));
  }
  return {
    type: "pushstr_profile_backup",
    version: 1,
    created_at: new Date().toISOString(),
    profiles
  };
}

async function loadSettings() {
  const stored = await browser.storage.local.get();
  const prevKeys = (settings.keys || []).length;
  const prevRelays = Array.isArray(settings.relays) ? settings.relays : [];
  settings = { ...settings, ...stored };
  settings.useGiftwrap = true;
  settings.useNip44 = true;
  settings.relays = mergeDefaultRelays(settings.relays);
  settings.recipientsByKey = settings.recipientsByKey || {};
  settings.messagesByKey = settings.messagesByKey || {};
  settings.relayFailures = settings.relayFailures || {};
  settings.recipients = normalizeRecipients(settings.recipients || []);
  if (settings.lastRecipient) settings.lastRecipient = normalizePubkey(settings.lastRecipient);
  settings.keys = settings.keys || [];
  if (settings.nsec) addKeyToList(settings.nsec);
  loadMessagesForCurrent(stored.messages || []);
  const relaysChanged = JSON.stringify(settings.relays) !== JSON.stringify(prevRelays);
  if ((settings.keys || []).length !== prevKeys || relaysChanged) await persistSettings();
  syncRecipientsForCurrent();
}

function mergeDefaultRelays(relays) {
  if (!Array.isArray(relays) || relays.length === 0) return [...DEFAULT_RELAYS];
  if (relays.length >= DEFAULT_RELAYS.length) return relays;
  const merged = [...relays];
  for (const relay of DEFAULT_RELAYS) {
    if (!merged.includes(relay)) {
      merged.push(relay);
      if (merged.length >= DEFAULT_RELAYS.length) break;
    }
  }
  return merged;
}

async function persistSettings() {
  const pub = currentPubkey();
  settings.messagesByKey = settings.messagesByKey || {};
  if (pub) {
    settings.messagesByKey[pub] = messages;
  }
  await browser.storage.local.set({ ...settings, messages, messagesByKey: settings.messagesByKey });
}

function currentPrivkeyHex() {
  if (!settings.nsec) return null;
  try {
    const decoded = nt.nip19.decode(settings.nsec);
    return decoded.type === "nsec" ? decoded.data : settings.nsec;
  } catch (err) {
    return settings.nsec;
  }
}

function derivePubkeyFromNsec(nsec) {
  if (!nsec) return null;
  try {
    const decoded = nt.nip19.decode(nsec);
    const priv = decoded.type === "nsec" ? decoded.data : nsec;
    return nt.getPublicKey(priv);
  } catch (_) {
    try {
      return nt.getPublicKey(nsec);
    } catch (err) {
      return null;
    }
  }
}

function currentPubkey() {
  const priv = currentPrivkeyHex();
  return priv ? nt.getPublicKey(priv) : null;
}

function loadMessagesForCurrent(legacyMessages = []) {
  const pub = currentPubkey();
  settings.messagesByKey = settings.messagesByKey || {};
  if (legacyMessages.length && pub && !settings.messagesByKey[pub]) {
    settings.messagesByKey[pub] = legacyMessages;
  }
  messages = pub ? settings.messagesByKey[pub] || [] : legacyMessages;
  messageIds = new Set(messages.map((m) => m.id).filter(Boolean));
}

async function ensureKey() {
  if (currentPrivkeyHex()) return;
  await generateNewKey();
  syncRecipientsForCurrent();
}

async function importNsec(nsec) {
  settings.nsec = nsec;
  addKeyToList(settings.nsec);
  loadMessagesForCurrent();
  quietNotifications();
  await persistSettings();
  await connect();
  await setupContextMenus();
  syncRecipientsForCurrent();
  return { pubkey: currentPubkey() };
}

async function generateNewKey() {
  const priv = nt.generateSecretKey();
  settings.nsec = nt.nip19.nsecEncode(priv);
  addKeyToList(settings.nsec);
  loadMessagesForCurrent();
  quietNotifications();
  await persistSettings();
  await connect();
  syncRecipientsForCurrent();
  return { pubkey: nt.getPublicKey(priv), nsec: settings.nsec };
}

async function connect() {
  if (!nt) return;
  const priv = currentPrivkeyHex();
  if (!priv) return;
  syncRecipientsForCurrent();

  if (sub) {
    sub.close?.();
    sub = null;
  }

  pool = pool || new nt.SimplePool();
  activeRelays = await resolveRelays(settings.relays);
  const me = currentPubkey();
  // Subscribe to: 1059 (giftwrap), 14 (NIP-17 DM), 4 (legacy DM)
  const kinds = settings.useGiftwrap ? [1059, 14, 4] : [14, 4];
  const filter = { kinds, "#p": [me] };
  const relayList = activeRelays.length ? activeRelays : settings.relays;
  if (relayList.length) {
    sub = pool.subscribeMany(relayList, filter, {
      onevent: handleGiftEvent
    });
    lastConnectAt = Date.now();
    console.info("[pushstr] subscribed", [filter], "relays", relayList);
  } else {
    console.warn("[pushstr] no relays available to subscribe");
  }
}

function startKeepAlive() {
  if (keepAliveTimer) return;
  keepAliveTimer = setInterval(() => {
    keepAliveTick().catch((err) => {
      console.warn("[pushstr] keep-alive failed", err?.message || String(err));
    });
  }, KEEP_ALIVE_MS);
}

async function keepAliveTick() {
  if (keepAliveRunning) return;
  keepAliveRunning = true;
  try {
    if (!pool) {
      await connect();
      return;
    }
    const relays = activeRelays.length ? activeRelays : settings.relays;
    if (!relays.length || !sub) {
      await connect();
      return;
    }
    const needsReconnect = Date.now() - lastConnectAt > 10 * 60 * 1000;
    if (needsReconnect) {
      await connect();
      return;
    }
    await Promise.allSettled(relays.map((url) => pool.ensureRelay(url)));
  } finally {
    keepAliveRunning = false;
  }
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function relayFailureMap() {
  settings.relayFailures = settings.relayFailures || {};
  return settings.relayFailures;
}

function nextSendSeq(recipientHex) {
  const current = sendSeqByRecipient.get(recipientHex) || 0;
  const next = current + 1;
  sendSeqByRecipient.set(recipientHex, next);
  return next;
}

function extractSeqFromTags(tags) {
  if (!Array.isArray(tags)) return null;
  for (const tag of tags) {
    if (!Array.isArray(tag) || tag.length < 2) continue;
    if (tag[0] === "seq") {
      const val = parseInt(tag[1], 10);
      if (!Number.isNaN(val)) return val;
    }
  }
  return null;
}

function cleanupRelayFailures() {
  const failures = relayFailureMap();
  const now = Date.now();
  let changed = false;
  for (const [url, ts] of Object.entries(failures)) {
    if (!ts || now - ts > RELAY_COOLDOWN_MS) {
      delete failures[url];
      changed = true;
    }
  }
  if (changed) {
    persistSettings().catch(() => {});
  }
}

function isRelayInCooldown(url) {
  const ts = relayFailureMap()[url];
  return typeof ts === "number" && Date.now() - ts < RELAY_COOLDOWN_MS;
}

function markRelayFailure(url) {
  relayFailureMap()[url] = Date.now();
  persistSettings().catch(() => {});
}

async function resolveRelays(relays) {
  if (!pool) return relays;
  cleanupRelayFailures();
  const candidates = relays.filter((url) => !isRelayInCooldown(url));
  const results = await Promise.all(
    candidates.map(async (url) => {
      try {
        await Promise.race([
          pool.ensureRelay(url),
          delay(2500).then(() => {
            throw new Error("relay connect timeout");
          })
        ]);
        return url;
      } catch (err) {
        console.warn("[pushstr] relay failed", {
          relay: url,
          error: err?.message || String(err)
        });
        markRelayFailure(url);
        return null;
      }
    })
  );
  return results.filter(Boolean);
}

async function awaitPublishResult(result) {
  if (Array.isArray(result)) {
    const settled = await Promise.allSettled(result);
    const ok = settled.some((entry) => entry.status === "fulfilled");
    if (!ok) {
      const reason = settled.find((entry) => entry.status === "rejected")?.reason;
      throw reason || new Error("publish failed");
    }
    return {
      ok: true,
      failed: settled.filter((entry) => entry.status === "rejected").length
    };
  }
  await result;
  return { ok: true, failed: 0 };
}

async function publishWithRetry(relays, event, label = "event") {
  const relayList = relays && relays.length ? relays : [];
  if (!relayList.length) {
    return { ok: false, error: "no relays available" };
  }
  let lastErr;
  let backoff = PUBLISH_RETRY_BASE_MS;
  for (let attempt = 1; attempt <= PUBLISH_RETRY_ATTEMPTS; attempt++) {
    try {
      const result = pool.publish(relayList, event);
      const info = await awaitPublishResult(result);
      if (info.failed > 0) {
        console.warn("[pushstr] publish partial failures", {
          label,
          failed: info.failed
        });
      }
      return { ok: true };
    } catch (err) {
      lastErr = err;
      console.warn("[pushstr] publish attempt failed", {
        label,
        attempt,
        error: err?.message || String(err)
      });
      if (attempt < PUBLISH_RETRY_ATTEMPTS) {
        await delay(backoff);
        backoff *= 2;
      }
    }
  }
  return { ok: false, error: lastErr?.message || String(lastErr) };
}

function parseReadReceipt(content) {
  if (!content || typeof content !== "string") return null;
  const cleaned = stripPushstrClientTag(content).trimStart();
  if (!cleaned.includes(READ_RECEIPT_KEY)) return null;
  if (!cleaned.startsWith("{")) return null;
  try {
    const decoded = JSON.parse(cleaned);
    if (decoded && typeof decoded === "object") {
      const receiptId = decoded[READ_RECEIPT_KEY];
      if (typeof receiptId === "string" && receiptId.length) {
        return receiptId;
      }
    }
  } catch (_) {
    // ignore receipt parse failures
  }
  return null;
}

async function applyReadReceipt(receiptId) {
  if (!receiptId) return false;
  let updated = false;
  const now = Math.floor(Date.now() / 1000);
  for (const msg of messages) {
    if (msg.id !== receiptId) continue;
    if (msg.direction !== "out") continue;
    if (!msg.read_at) {
      msg.read_at = now;
      msg.read = true;
      updated = true;
    }
  }
  if (!updated) {
    pendingReceipts.add(receiptId);
    return false;
  }
  settings.messagesByKey = settings.messagesByKey || {};
  const pub = currentPubkey();
  if (pub) settings.messagesByKey[pub] = messages;
  await persistSettings();
  return true;
}

async function sendReadReceipt(recipientHex, messageId, dmKind) {
  if (!recipientHex || !messageId) return;
  if (sentReceipts.has(messageId)) return;
  sentReceipts.add(messageId);
  const content = JSON.stringify({
    [READ_RECEIPT_KEY]: messageId,
    ts: Math.floor(Date.now() / 1000)
  });
  const mode = dmKind === "nip04" ? "nip04" : "nip17";
  const created_at = Math.floor(Date.now() / 1000);
  const relayList = activeRelays.length ? activeRelays : settings.relays;
  if (mode === "nip04") {
    const priv = currentPrivkeyHex();
    if (!priv) return;
    const cipherText = await nt.nip04.encrypt(priv, recipientHex, content);
    const dm = {
      kind: 4,
      created_at,
      tags: [["p", recipientHex]],
      content: cipherText
    };
    const signedDm = finalizeEvent(dm, priv);
    await publishWithRetry(relayList, signedDm, "receipt-nip04");
    return;
  }

  const inner = {
    kind: 14,
    created_at,
    tags: [
      ["p", recipientHex],
      ["alt", "Read receipt"]
    ],
    content
  };
  const priv = currentPrivkeyHex();
  if (!priv) return;
  const innerSigned = finalizeEvent(inner, priv);
  const rumor = { ...innerSigned };
  delete rumor.sig;
  const twoDaysAgo = created_at - (2 * 24 * 60 * 60);
  const sealedTimestamp = Math.floor(Math.random() * (created_at - twoDaysAgo)) + twoDaysAgo;
  const sealedContent = await encryptGift(priv, recipientHex, JSON.stringify(rumor));
  const sealedEvent = finalizeEvent({
    kind: 13,
    created_at: sealedTimestamp,
    tags: [],
    content: sealedContent
  }, priv);
  const wrappingPriv = nt.generateSecretKey();
  const wrappingPub = nt.getPublicKey(wrappingPriv);
  const giftCiphertext = await encryptGift(wrappingPriv, recipientHex, JSON.stringify(sealedEvent));
  const randomTimestamp = Math.floor(Math.random() * (created_at - twoDaysAgo)) + twoDaysAgo;
  const expiration = created_at + (24 * 60 * 60);
  const giftwrap = {
    kind: 1059,
    created_at: randomTimestamp,
    tags: [
      ["p", recipientHex],
      ["expiration", expiration.toString()]
    ],
    content: giftCiphertext,
    pubkey: wrappingPub
  };
  const signedGift = finalizeEvent(giftwrap, wrappingPriv);
  await publishWithRetry(relayList, signedGift, "receipt-giftwrap");
}

function hasPushstrClientTag(content) {
  return typeof content === "string" && content.includes(PUSHSTR_CLIENT_TAG);
}

function stripPushstrClientTag(content) {
  if (typeof content !== "string") return content;
  if (!content.includes(PUSHSTR_CLIENT_TAG)) return content;
  const pattern = /(^|\n)\[pushstr:client\](\n|$)/g;
  return content.replace(pattern, "\n").trim();
}

function appendPushstrClientTag(content) {
  if (typeof content !== "string") return content;
  if (content.includes(PUSHSTR_CLIENT_TAG)) return content;
  if (!content.length) return PUSHSTR_CLIENT_TAG;
  return `${content}\n${PUSHSTR_CLIENT_TAG}`;
}

async function handleGiftEvent(event) {
  try {
    const priv = currentPrivkeyHex();
    if (!priv) return;
    let targetEvent = event;
    if (event.kind === 1059) {
      const innerJson = await decryptGift(priv, event.pubkey, event.content);
      console.info("[pushstr] giftwrap inner raw", {
        len: innerJson?.length || 0,
        preview: innerJson?.slice(0, 120)
      });
      let inner;
      try {
        inner = JSON.parse(innerJson);
      } catch (err) {
        console.warn("[pushstr] giftwrap inner JSON parse failed", {
          err: err?.message || String(err),
          preview: innerJson?.slice(0, 80)
        });
        return;
      }
      console.info("[pushstr] giftwrap inner parsed", {
        id: inner?.id,
        pubkey: inner?.pubkey,
        kind: inner?.kind,
        tags: inner?.tags
      });
      if (!nt.verifyEvent(inner)) {
        console.warn("[pushstr] giftwrap inner verify failed", {
          id: inner?.id,
          pubkey: inner?.pubkey,
          kind: inner?.kind
        });
        return;
      }
      console.info("[pushstr] giftwrap inner verified", {
        id: inner?.id,
        kind: inner?.kind
      });
      if (inner.kind === 13 && inner.content) {
        let rumorJson;
        try {
          rumorJson = await decryptDmContent(priv, inner.pubkey, inner.content);
        } catch (err) {
          console.warn("[pushstr] sealed rumor decrypt failed", {
            err: err?.message || String(err),
            id: inner?.id
          });
          return;
        }
        let rumor;
        try {
          rumor = JSON.parse(rumorJson);
        } catch (err) {
          console.warn("[pushstr] sealed rumor JSON parse failed", {
            err: err?.message || String(err),
            preview: rumorJson?.slice(0, 80)
          });
          return;
        }
        console.info("[pushstr] sealed rumor parsed", {
          kind: rumor?.kind,
          pubkey: rumor?.pubkey,
          tags: rumor?.tags
        });
        targetEvent = {
          ...rumor,
          pubkey: rumor?.pubkey || inner.pubkey
        };
      } else {
        targetEvent = inner;
      }
    }
    // Accept both kind 4 (old) and kind 14 (NIP-17)
    if (targetEvent.kind !== 4 && targetEvent.kind !== 14) return;
    const me = currentPubkey();
    const hasRecipient = targetEvent.tags.some((t) => {
      if (t[0] !== "p") return false;
      try {
        return normalizePubkey(t[1]) === me;
      } catch (_) {
        return t[1] === me;
      }
    });
    const hasOuterRecipient = event.tags?.some((t) => {
      if (t[0] !== "p") return false;
      try {
        return normalizePubkey(t[1]) === me;
      } catch (_) {
        return t[1] === me;
      }
    });
    if (!hasRecipient && !hasOuterRecipient) {
      console.warn("[pushstr] DM ignored: missing recipient tag", {
        kind: targetEvent.kind,
        outerKind: event.kind,
        innerTags: targetEvent.tags,
        outerTags: event.tags
      });
      return;
    }
    const sender = targetEvent.pubkey || "unknown";
    const seq = extractSeqFromTags(targetEvent.tags || event.tags || []);
    const message = await decryptDmContent(priv, sender, targetEvent.content);
    console.info("[pushstr] dm decrypted", {
      from: sender,
      kind: targetEvent.kind,
      len: message?.length || 0
    });
    const dmKind = event.kind === 1059 ? "nip17" : (targetEvent.kind === 4 ? "nip04" : "nip17");
    console.info("[pushstr] received DM", { from: sender, kind: targetEvent.kind, outerKind: event.kind, message });
    const receiptId = parseReadReceipt(message);
    if (receiptId) {
      await applyReadReceipt(receiptId);
      browser.runtime.sendMessage({ type: "receipt", id: receiptId, from: sender }).catch(() => {});
      return;
    }
    const isPushstrClient = hasPushstrClientTag(message);
    const cleanedMessage = stripPushstrClientTag(message);
    await ensureContact(sender);
    const isGiftwrap = event.kind === 1059;
    const primaryId = isGiftwrap ? event.id : (targetEvent.id || event.id);
    if ((primaryId && messageIds.has(primaryId)) ||
        (targetEvent.id && messageIds.has(targetEvent.id)) ||
        (event.id && messageIds.has(event.id))) {
      return;
    }
    await recordMessage({
      id: isGiftwrap ? event.id : (targetEvent.id || event.id),
      direction: "in",
      from: sender,
      to: currentPubkey(),
      content: cleanedMessage,
      created_at: targetEvent.created_at || Math.floor(Date.now() / 1000),
      outerKind: event.kind,
      dm_kind: dmKind,
      relayFrom: settings.relays,
      seq
    });
    const receiptTargetId = isGiftwrap ? event.id : (targetEvent.id || event.id);
    if (receiptTargetId && isPushstrClient) {
      await sendReadReceipt(sender, receiptTargetId, dmKind);
    }
    if (cleanedMessage && !suppressNotifications) {
      notify(`DM from ${formatSenderLabel(sender)}`, cleanedMessage);
    }
    browser.runtime.sendMessage({ type: "incoming", event: targetEvent, outer: event, message: cleanedMessage }).catch(() => {});
  } catch (err) {
    console.warn("Failed to unwrap gift/DM", err);
  }
}

async function sendGift(recipient, content, modeOverride = null) {
  const priv = currentPrivkeyHex();
  if (!priv) throw new Error("No key configured");
  const chosen = recipient || settings.lastRecipient || (settings.recipients[0] && settings.recipients[0].pubkey);
  if (!chosen) throw new Error("No recipient set");
  const recipientHex = normalizePubkey(chosen);
  const dmMode = modeOverride || getDmModeForRecipient(recipientHex);
  settings.lastRecipient = recipientHex;
  await persistSettings();
  const created_at = Math.floor(Date.now() / 1000);
  const taggedContent = appendPushstrClientTag(content);
  const seq = nextSendSeq(recipientHex);

  if (dmMode === "nip04") {
    const cipherText = await nt.nip04.encrypt(priv, recipientHex, taggedContent);
    const dm = {
      kind: 4,
      created_at,
      tags: [["p", recipientHex], ["seq", seq.toString()]],
      content: cipherText
    };
    const signedDm = finalizeEvent(dm, priv);
    const relayList = activeRelays.length ? activeRelays : settings.relays;
    const pubRes = await publishWithRetry(relayList, signedDm, "nip04");
    if (!pubRes.ok) {
      return { ok: false, error: pubRes.error || "publish failed" };
    }
    console.info("[pushstr] sent DM kind 4 (nip04)", { to: recipientHex, relays: settings.relays });
    await recordMessage({
      id: signedDm.id,
      direction: "out",
      from: currentPubkey(),
      to: recipientHex,
      content: taggedContent,
      created_at,
      outerKind: 4,
      dm_kind: "nip04",
      relays: settings.relays,
      seq
    });
    return { ok: true, id: signedDm.id };
  }

  // NIP-59/NIP-17 Giftwrap: sealed rumor (kind 13) inside kind 1059.
  const senderPubkey = nt.getPublicKey(priv);
  const inner = {
    kind: 14,
    created_at,
    tags: [
      ["p", recipientHex],
      ["seq", seq.toString()],
      ["alt", "Direct message"]
    ],
    content: taggedContent
  };
  const innerSigned = finalizeEvent(inner, priv);
  const rumor = { ...innerSigned };
  delete rumor.sig;

  const twoDaysAgo = created_at - (2 * 24 * 60 * 60);
  const sealedTimestamp = Math.floor(Math.random() * (created_at - twoDaysAgo)) + twoDaysAgo;
  const sealedContent = await encryptGift(priv, recipientHex, JSON.stringify(rumor));
  const sealedEvent = finalizeEvent({
    kind: 13,
    created_at: sealedTimestamp,
    tags: [],
    content: sealedContent
  }, priv);

  const wrappingPriv = nt.generateSecretKey();
  const wrappingPub = nt.getPublicKey(wrappingPriv);
  const giftCiphertext = await encryptGift(wrappingPriv, recipientHex, JSON.stringify(sealedEvent));

  const randomTimestamp = Math.floor(Math.random() * (created_at - twoDaysAgo)) + twoDaysAgo;
  const expiration = created_at + (24 * 60 * 60);
  const giftwrap = {
    kind: 1059,
    created_at: randomTimestamp,
    tags: [
      ["p", recipientHex],
      ["expiration", expiration.toString()]
    ],
    content: giftCiphertext,
    pubkey: wrappingPub
  };
  const signedGift = finalizeEvent(giftwrap, wrappingPriv);
  const relayList = activeRelays.length ? activeRelays : settings.relays;
  const pubRes = await publishWithRetry(relayList, signedGift, "giftwrap");
  if (!pubRes.ok) {
    return { ok: false, error: pubRes.error || "publish failed" };
  }
  console.info("[pushstr] sent giftwrap kind 1059", { to: recipientHex, relays: settings.relays });
  await recordMessage({
    id: signedGift.id,
    direction: "out",
    from: senderPubkey,
    to: recipientHex,
    content: taggedContent,
    created_at,
    outerKind: 1059,
    dm_kind: "nip17",
    relays: settings.relays,
    seq
  });
  return { ok: true, id: signedGift.id };
}

function notify(title, message) {
  try {
    browser.notifications.create({
      type: 'basic',
      iconUrl: browser.runtime.getURL('pushstr_96.png'),
      title,
      message,
    });
  } catch (err) {
    console.warn("Notifications unavailable", err);
  }
}

if (browser?.notifications?.onClicked) {
  browser.notifications.onClicked.addListener(async (notificationId) => {
    try {
      await focusOrOpenChat();
    } catch (err) {
      console.warn("[pushstr] notification click failed", err);
    } finally {
      try {
        await browser.notifications.clear(notificationId);
      } catch (_) {
        // ignore
      }
    }
  });
}

async function focusOrOpenChat() {
  const url = browser.runtime.getURL("popup.html?popout=1");
  try {
    const tabs = await browser.tabs.query({ url: `${url}*` });
    if (tabs && tabs.length) {
      const tab = tabs[0];
      if (tab.id) await browser.tabs.update(tab.id, { active: true });
      if (tab.windowId) await browser.windows.update(tab.windowId, { focused: true });
      return;
    }
  } catch (err) {
    console.warn("[pushstr] failed to focus existing chat window, opening new one", err);
  }
  try {
    await browser.windows.create({ url, type: "popup", width: 820, height: 640, focused: true });
  } catch (err) {
    console.warn("[pushstr] unable to open chat window", err);
    try {
      await browser.tabs.create({ url });
    } catch (_) {
      // final fallback ignored
    }
  }
}

function normalizePubkey(input) {
  if (!input) throw new Error("Missing pubkey");
  let normalized = input.trim();
  if (normalized.startsWith("nostr://")) normalized = normalized.slice(8);
  else if (normalized.startsWith("nostr:")) normalized = normalized.slice(6);
  try {
    const decoded = nt.nip19.decode(normalized);
    if (decoded.type === "npub" || decoded.type === "nprofile") {
      return decoded.data.pubkey || decoded.data;
    }
  } catch (_) {
    // fall through to raw hex handling
  }
  const hex = normalized.trim();
  if (/^[0-9a-fA-F]{64}$/.test(hex)) return hex.toLowerCase();
  throw new Error("Invalid recipient pubkey (expect hex, npub, or nprofile)");
}

function normalizeRecipientEntry(entry) {
  if (!entry) return null;
  if (typeof entry === "string") {
    return { pubkey: normalizePubkey(entry), nickname: "" };
  }
  return {
    pubkey: normalizePubkey(entry.pubkey),
    nickname: entry.nickname || ""
  };
}

function normalizeRecipients(list) {
  return (list || []).map(normalizeRecipientEntry).filter(Boolean);
}

function finalizeEvent(evt, priv) {
  return nt.finalizeEvent(evt, priv);
}

async function encryptGift(priv, recipientPub, content) {
  // Use Rust WASM NIP-44 for cross-platform compatibility
  // Both mobile (Rust FFI) and browser (Rust WASM) use the same implementation
  try {
    // Ensure keys are hex strings
    const privHex = typeof priv === 'string' ? priv : bytesToHex(priv);
    const recipientHex = typeof recipientPub === 'string' ? recipientPub : bytesToHex(recipientPub);

    const conversationKey = CryptoWasm.nip44_get_conversation_key(privHex, recipientHex);
    console.log("[pushstr] Giftwrap encrypt - convKey:", conversationKey.substring(0, 16) + "...");
    return CryptoWasm.nip44_encrypt(conversationKey, content);
  } catch (err) {
    console.error("[pushstr] WASM NIP-44 encrypt failed:", err);
    throw err;
  }
}

async function decryptGift(priv, wrapperPub, content) {
  // Use Rust WASM NIP-44 for cross-platform compatibility
  try {
    // Ensure keys are hex strings
    const privHex = typeof priv === 'string' ? priv : bytesToHex(priv);
    const wrapperHex = typeof wrapperPub === 'string' ? wrapperPub : bytesToHex(wrapperPub);

    console.log("[pushstr] Giftwrap decrypt - myPriv:", privHex.substring(0, 8) + "...", "wrapperPub:", wrapperHex.substring(0, 16) + "...");
    const conversationKey = CryptoWasm.nip44_get_conversation_key(privHex, wrapperHex);
    console.log("[pushstr] Giftwrap decrypt - convKey:", conversationKey.substring(0, 16) + "...");
    return CryptoWasm.nip44_decrypt(conversationKey, content);
  } catch (err) {
    console.error("[pushstr] WASM NIP-44 decrypt failed:", err);
    // Fallback to NIP-04 for old messages encrypted with NIP-04
    try {
      return await nt.nip04.decrypt(priv, wrapperPub, content);
    } catch (nip04err) {
      console.error("[pushstr] NIP-04 fallback also failed:", nip04err);
      throw err;
    }
  }
}

async function decryptDmContent(priv, senderPub, cipher) {
  if (cipher instanceof ArrayBuffer) cipher = new Uint8Array(cipher);
  if (cipher instanceof Uint8Array) {
    try {
      cipher = new TextDecoder().decode(cipher);
    } catch (_) {
      cipher = toBase64(cipher);
    }
  }
  if (!cipher) return "";
  const rawCipher = String(cipher);
  const trimmedCipher = rawCipher.replace(/^"+|"+$/g, "");
  const base64Like = /^[A-Za-z0-9+/=]+$/.test(trimmedCipher);
  if (trimmedCipher.length < 16 && !trimmedCipher.includes("?iv=")) {
    console.info("[pushstr] dm content looks plaintext, skipping decrypt", {
      len: trimmedCipher.length
    });
    return trimmedCipher;
  }
  if (!base64Like && !trimmedCipher.includes("?iv=")) {
    console.info("[pushstr] dm content not base64, treating as plaintext");
    return trimmedCipher;
  }

  // Debug logging
  console.log("[pushstr] decryptDmContent - cipher type:", typeof cipher, "length:", cipher?.length, "first 50 chars:", cipher?.substring(0, 50));

  const variants = [];
  variants.push(trimmedCipher);

  // REMOVED: atob(trimmed) - this creates binary data that breaks NIP-04 bech32 decoder
  // NIP-04 expects base64 string input, not decoded binary

  // Try Rust WASM NIP-44 first (cross-platform compatible)
  try {
    // Ensure keys are hex strings
    const privHex = typeof priv === 'string' ? priv : bytesToHex(priv);
    const senderHex = typeof senderPub === 'string' ? senderPub : bytesToHex(senderPub);

    console.log("[pushstr] DM decrypt - keys:", {
      privLen: privHex.length,
      senderPubLen: senderHex.length,
      senderPubSample: senderHex.substring(0, 16) + "..."
    });

    const conversationKey = CryptoWasm.nip44_get_conversation_key(privHex, senderHex);
    console.log("[pushstr] DM decrypt - convKey:", conversationKey.substring(0, 16) + "...");

    for (const v of variants) {
      if (!v) continue;
      try {
        const result = CryptoWasm.nip44_decrypt(conversationKey, v);
        console.log("[pushstr] WASM NIP-44 dm decrypt SUCCESS");
        return result;
      } catch (err) {
        console.log("[pushstr] WASM NIP-44 dm decrypt attempt failed:", err.message);
      }
    }
  } catch (err) {
    console.warn("[pushstr] WASM NIP-44 dm decrypt failed:", err);
  }
  console.warn("[pushstr] WASM NIP-44 dm decrypt failed, falling back to nip04");

  // Fallback to NIP-04 for old messages - only try with base64 string
  try {
    console.log("[pushstr] Trying NIP-04 with original cipher (base64 string)");
    return await nt.nip04.decrypt(priv, senderPub, trimmedCipher);
  } catch (err) {
    console.error("[pushstr] NIP-04 decrypt failed:", err);
    throw new Error(`All decryption methods failed. Last error: ${err.message}`);
  }
}

function deriveConversationKey(privHex, otherPubHex) {
  // Use Rust WASM NIP-44 conversation key derivation
  // Ensure keys are hex strings
  const priv = typeof privHex === 'string' ? privHex : bytesToHex(privHex);
  const otherPub = typeof otherPubHex === 'string' ? otherPubHex : bytesToHex(otherPubHex);
  return CryptoWasm.nip44_get_conversation_key(priv, otherPub);
}

async function decryptMediaDescriptor(descriptor, senderPubkey) {
  const priv = currentPrivkeyHex();
  if (!priv) return { error: "No key configured" };
  if (!descriptor?.url) return { error: "Missing URL" };
  if (!descriptor?.iv) return { error: "Missing IV" };
  const sender = senderPubkey || currentPubkey();
  try {
    // Fetch encrypted data from URL
    const resp = await fetch(descriptor.url);
    if (!resp.ok) {
      throw new Error(`fetch failed: ${resp.status} ${resp.statusText}`);
    }
    const cipherBytes = new Uint8Array(await resp.arrayBuffer());

    // Verify cipher hash if provided
    if (descriptor.cipher_sha256) {
      const fetchedHash = await sha256Hex(cipherBytes);
      if (fetchedHash !== descriptor.cipher_sha256) {
        throw new Error(`cipher hash mismatch (got ${fetchedHash}, expected ${descriptor.cipher_sha256})`);
      }
    }

    // Decrypt using AES-GCM
    const conversationKey = deriveConversationKey(priv, sender);
    const keyBytes = conversationKey instanceof Uint8Array ? conversationKey : hexToBytes(conversationKey);
    const iv = fromBase64(descriptor.iv);
    const plainBytes = new Uint8Array(CryptoWasm.decrypt_aes_gcm(keyBytes, iv, cipherBytes));

    // Verify plaintext hash if provided
    if (descriptor.sha256) {
      const hash = await sha256Hex(plainBytes);
      if (hash !== descriptor.sha256) {
        throw new Error(`attachment hash mismatch (got ${hash}, expected ${descriptor.sha256})`);
      }
    }

    const outB64 = toBase64(plainBytes);
    return {
      base64: outB64,
      mime: descriptor.mime || "application/octet-stream",
      sha256: descriptor.sha256 || null,
      size: descriptor.size || plainBytes.length,
      filename: descriptor.filename || null
    };
  } catch (err) {
    console.error("[pushstr] Decrypt error:", err);
    return { error: err.message || "decrypt failed" };
  }
}

async function recordMessage(entry) {
  const pub = currentPubkey();
  if (!pub) return;
  const clean = {
    ...entry,
    created_at: entry.created_at || Math.floor(Date.now() / 1000)
  };
  if (clean.id && messageIds.has(clean.id)) {
    console.log("[pushstr][background] recordMessage: duplicate message", clean.id);
    return;
  }
  if (clean.id) messageIds.add(clean.id);
  if (clean.id && clean.direction === "out" && pendingReceipts.has(clean.id)) {
    clean.read_at = Math.floor(Date.now() / 1000);
    clean.read = true;
    pendingReceipts.delete(clean.id);
  }
  messages.push(clean);
  console.log("[pushstr][background] recordMessage: added message, total now:", messages.length, "direction:", clean.direction, "to/from:", clean.to || clean.from);
  if (messages.length > MESSAGE_LIMIT) {
    messages = messages.slice(messages.length - MESSAGE_LIMIT);
    messageIds = new Set(messages.map((m) => m.id).filter(Boolean));
  }
  settings.messagesByKey = settings.messagesByKey || {};
  settings.messagesByKey[pub] = messages;
  await persistSettings();
  console.log("[pushstr][background] recordMessage: persisted to storage");
}

async function ensureContact(pubkey) {
  if (!pubkey) return;
  const list = getRecipientsForCurrent();
  if (list.find((r) => r.pubkey === pubkey)) return;
  list.push({ pubkey, nickname: "" });
  setRecipientsForCurrent(list);
  await persistSettings();
}

async function setupContextMenus() {
  if (!browser.contextMenus) return;
  try {
    await browser.contextMenus.removeAll();
    const hasRecipients = settings.recipients && settings.recipients.length > 0;
    browser.contextMenus.create({ id: "pushstr-root", title: "Send to Pushstr", contexts: ["selection", "link", "page"] });
    if (hasRecipients) {
      browser.contextMenus.create({
        id: "pushstr-last",
        parentId: "pushstr-root",
        title: "Last contact",
        contexts: ["selection", "link", "page"]
      });
      settings.recipients.forEach((r) => {
        const label = r.nickname ? `${r.nickname}` : short(r.pubkey);
        browser.contextMenus.create({
          id: `pushstr-recipient-${r.pubkey}`,
          parentId: "pushstr-root",
          title: label,
          contexts: ["selection", "link", "page"]
        });
      });
    } else {
      browser.contextMenus.create({
        id: "pushstr-none",
        parentId: "pushstr-root",
        title: "No recipients configured",
        contexts: ["selection", "link", "page"],
        enabled: false
      });
    }
    contextMenuReady = true;
  } catch (err) {
    console.warn("Context menu setup failed", err);
  }
}

browser.contextMenus && browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!info.menuItemId || !String(info.menuItemId).startsWith("pushstr")) return;
  try {
    let recipient = settings.lastRecipient || (settings.recipients[0] && settings.recipients[0].pubkey);
    if (info.menuItemId === "pushstr-last") {
      recipient = settings.lastRecipient || recipient;
    } else if (String(info.menuItemId).startsWith("pushstr-recipient-")) {
      recipient = info.menuItemId.replace("pushstr-recipient-", "");
    }
    if (!recipient) {
      notify("Pushstr", "No recipient configured");
      return;
    }
    let content = info.selectionText || "";
    if (info.linkUrl) {
      content = content ? `${content}\n${info.linkUrl}` : info.linkUrl;
    } else if (!content && info.pageUrl) {
      content = info.pageUrl;
    }
    await sendGift(recipient, content || "(no content)");
  } catch (err) {
    console.warn("Context menu send failed", err);
  }
});

function short(pk) {
  if (!pk) return "unknown";
  return pk.slice(0, 6) + "..." + pk.slice(-4);
}

function formatNpubForNotify(pubkey) {
  if (!pubkey) return "unknown";
  try {
    const npub = nt.nip19.npubEncode(pubkey);
    return short(npub);
  } catch (_) {
    return short(pubkey);
  }
}

function formatSenderLabel(pubkey) {
  const recips = getRecipientsForCurrent();
  const match = recips.find((r) => normalizePubkey(r.pubkey) === pubkey);
  const nickname = match?.nickname?.trim();
  if (nickname) return nickname;
  return formatNpubForNotify(pubkey);
}

function addKeyToList(nsec) {
  if (!nsec) return;
  const privHex = (() => {
    try {
      const dec = nt.nip19.decode(nsec);
      return dec.type === "nsec" ? dec.data : nsec;
    } catch (_) {
      return nsec;
    }
  })();
  const pub = nt.getPublicKey(privHex);
  const existing = (settings.keys || []).find((k) => k.nsec === nsec || k.pubkey === pub);
  if (!existing) {
    settings.keys = settings.keys || [];
    settings.keys.push({ nsec, pubkey: pub, nickname: "" });
  }
}

function quietNotifications() {
  suppressNotifications = true;
  setTimeout(() => {
    suppressNotifications = false;
  }, 2000);
}

function getRecipientsForCurrent() {
  const pk = currentPubkey();
  settings.recipientsByKey = settings.recipientsByKey || {};
  if (pk) return settings.recipientsByKey[pk] || [];
  return settings.recipients || [];
}

function getDmModesForCurrent() {
  const pk = currentPubkey();
  settings.dmModesByKey = settings.dmModesByKey || {};
  if (pk) return settings.dmModesByKey[pk] || {};
  return settings.dmModes || {};
}

function setDmModeForCurrent(recipient, mode) {
  const pk = currentPubkey();
  settings.dmModesByKey = settings.dmModesByKey || {};
  if (pk) {
    const existing = settings.dmModesByKey[pk] || {};
    settings.dmModesByKey[pk] = { ...existing, [recipient]: mode };
  } else {
    settings.dmModes = settings.dmModes || {};
    settings.dmModes[recipient] = mode;
  }
}

function getDmModeForRecipient(recipient) {
  const modes = getDmModesForCurrent();
  return modes[recipient] || "nip17";
}

function setRecipientsForCurrent(list) {
  const normalized = normalizeRecipients(list);
  const pk = currentPubkey();
  settings.recipientsByKey = settings.recipientsByKey || {};
  if (pk) {
    settings.recipientsByKey[pk] = normalized;
    settings.recipients = normalized;
  } else {
    settings.recipients = normalized;
  }
}

function setRecipientsForKey(pubkey, list) {
  const normalized = normalizeRecipients(list);
  settings.recipientsByKey = settings.recipientsByKey || {};
  if (!pubkey) return;
  settings.recipientsByKey[pubkey] = normalized;
}

function syncRecipientsForCurrent() {
  const pk = currentPubkey();
  settings.recipientsByKey = settings.recipientsByKey || {};
  if (pk) {
    const existing = settings.recipientsByKey[pk];
    const list = existing ? normalizeRecipients(existing) : [];
    settings.recipientsByKey[pk] = list;
    settings.recipients = list;
  } else {
    settings.recipients = normalizeRecipients(settings.recipients || []);
  }
}

async function uploadToBlossom(arrayBuffer, recipientOverride, mimeOverride, filename) {
  const priv = currentPrivkeyHex();
  if (!priv) return { error: "No key configured" };
  try {
    const bytes = new Uint8Array(arrayBuffer);
    const origSize = bytes.length;
    const recipient = normalizePubkey(recipientOverride || settings.lastRecipient || (settings.recipients[0] && settings.recipients[0].pubkey));

    // Use AES-GCM for encryption (no size limit, unlike NIP-44's 64KB limit)
    // Derive shared secret using NIP-44's conversation key
    const conversationKey = deriveConversationKey(priv, recipient);
    const keyBytes = conversationKey instanceof Uint8Array ? conversationKey : hexToBytes(conversationKey);

    // Encrypt with AES-GCM
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const cipherBytes = new Uint8Array(CryptoWasm.encrypt_aes_gcm(keyBytes, iv, bytes));

    const plainHashHex = await sha256Hex(bytes);
    const hashHex = await sha256Hex(cipherBytes);
    const created_at = Math.floor(Date.now() / 1000);
    const expiration = created_at + 300; // 5 minutes
    const authEvent = finalizeEvent(
      {
        kind: 24242,
        created_at,
        tags: [
          ["t", "upload"],
          ["expiration", expiration.toString()],
          ["x", hashHex]
        ],
        content: "Upload file"
      },
      priv
    );
    const authHeader = "Nostr " + btoa(unescape(encodeURIComponent(JSON.stringify(authEvent))));
    const base = BLOSSOM_SERVER.replace(/\/$/, "");
    const url = `${base}/${BLOSSOM_UPLOAD_PATH}`;
    const resp = await fetch(url, {
      method: "PUT",
      headers: {
        Authorization: authHeader,
        "Content-Type": "application/octet-stream",
        "Content-Length": cipherBytes.length.toString()
      },
      body: cipherBytes
    });
    if (!resp.ok) {
      const text = await resp.text();
      return { error: `upload failed (${resp.status}): ${text.slice(0, 200)}` };
    }
    const location = resp.headers.get("location");
    const text = await resp.text();
    let link = location || text.trim() || `${url}/${hashHex}`;
    try {
      const parsed = JSON.parse(text);
      link = parsed.url || parsed.location || link;
    } catch (_) {
      // not JSON; keep link as-is
    }
    return {
      url: link,
      sha256: plainHashHex,
      cipher_sha256: hashHex,
      size: origSize,
      mime: mimeOverride || "application/octet-stream",
      encryption: "aes-gcm",
      iv: toBase64(iv),
      filename: filename || defaultFilename(hashHex, mimeOverride)
    };
  } catch (err) {
    return { error: err.message || "upload failed" };
  }
}

async function sha256Hex(bytes) {
  const hashBytes = CryptoWasm.sha256_bytes(bytes);
  return Array.from(hashBytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function utf8Bytes(str) {
  return new TextEncoder().encode(str);
}

function hexToBytes(hex) {
  if (nt.utils?.hexToBytes) return nt.utils.hexToBytes(hex);
  if (typeof hex !== 'string') return hex;
  return Uint8Array.from(hex.match(/.{1,2}/g).map(byte => parseInt(byte, 16)));
}

function bytesToHex(bytes) {
  if (nt.utils?.bytesToHex) return nt.utils.bytesToHex(bytes);
  if (typeof bytes === 'string') return bytes; // Already hex
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}

function toBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function fromBase64(b64) {
  const bin = atob(b64);
  const len = bin.length;
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function defaultFilename(hashHex, mime) {
  const prefix = (hashHex || "attachment").slice(0, 12);
  const map = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "text/plain": "txt",
    "application/pdf": "pdf",
    "application/json": "json"
  };
  let ext = "bin";
  if (mime) {
    ext = map[mime] || mime.split("/")[1]?.split(/[+.;]/)[0] || ext;
    ext = ext.replace(/[^a-zA-Z0-9_-]/g, "") || "bin";
  }
  return `${prefix}.${ext}`;
}

function gzip(bytes) {
  try {
    return pako.gzip(bytes);
  } catch (err) {
    console.warn("gzip failed, sending raw", err);
    return bytes;
  }
}

function maybeGunzip(bytes) {
  try {
    return pako.ungzip(bytes);
  } catch (err) {
    return bytes;
  }
}
