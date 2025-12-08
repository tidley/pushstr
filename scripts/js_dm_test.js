// Low-level JS/Nostr/wasm harness to exercise giftwrap + NIP-44 DMs.
// Run two instances (two terminals) with different NSEC/PEER values to send/receive.
// Defaults are placeholders; set via env vars or edit CONFIG below.
//
// Example (terminal A):
//   NSEC=<alice_nsec> PEER=<bob_npub_or_hex> node scripts/js_dm_test.js send
// Example (terminal B):
//   NSEC=<bob_nsec> PEER=<alice_npub_or_hex> node scripts/js_dm_test.js listen

import {
  SimplePool,
  finalizeEvent,
  generateSecretKey,
  getPublicKey,
  nip19,
} from "nostr-tools";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";
import initWasm, {
  nip44_get_conversation_key,
  nip44_encrypt,
  nip44_decrypt,
} from "../dist/wasm_crypto.js";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MODE = process.argv[2] || "both"; // send | listen | both

const CONFIG = {
  nsec: process.env.NSEC || "SET_ME",
  peer: process.env.PEER || "SET_PEER",
  relays: (process.env.RELAYS || "wss://relay.damus.io,wss://relay.snort.social,wss://offchain.pub")
    .split(",")
    .map((r) => r.trim())
    .filter(Boolean),
  text: process.env.TEXT || `hello from js @ ${new Date().toISOString()}`,
};

if (CONFIG.nsec === "SET_ME" || CONFIG.peer === "SET_PEER") {
  console.error("Please set NSEC and PEER (env vars or edit CONFIG).");
  process.exit(1);
}

const privHex = decodeNsec(CONFIG.nsec); // hex
const myPubHex = getPublicKey(hexToBytes(privHex));
const peerHex = toHexPub(CONFIG.peer);

console.log("[js-test] starting with pubkey", myPubHex);
console.log("[js-test] relays:", CONFIG.relays.join(", "));

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmPath = path.resolve(__dirname, "../dist/wasm_crypto_bg.wasm");
const wasmBytes = await fs.readFile(wasmPath);
await initWasm(wasmBytes);
console.log("[js-test] wasm crypto ready");

const pool = new SimplePool();

// Listen first so we don't miss the reply
const sub = pool.subscribeMany(
  CONFIG.relays,
  { kinds: [1059, 14, 4], "#p": [myPubHex] }, // single filter object (SimplePool flattens for us)
  { onevent: handleEvent, onnotice: (notice, relay) => console.warn("NOTICE from", relay.url, notice) },
);

if (MODE === "send" || MODE === "both") {
  await sendGift(CONFIG.text);
}

if (MODE === "listen" || MODE === "both") {
  console.log("[js-test] listening for new DMs (Ctrl+C to exit)...");
} else {
  // allow async publish to flush before exit
  setTimeout(() => process.exit(0), 1500);
}

async function handleEvent(event) {
  try {
    let target = event;
    if (event.kind === 1059) {
      const inner = await decryptGift(event);
      target = inner;
    }

    if (target.kind !== 14 && target.kind !== 4) return;
    if (!target.tags.some((t) => t[0] === "p" && t[1] === myPubHex)) return;

    const sender = target.pubkey;
    const plaintext = await decryptDm(target);
    console.log(
      `[js-test] received from ${short(sender)} (kind ${target.kind}, outer ${event.kind}):`,
      plaintext,
    );
  } catch (err) {
    console.warn("[js-test] failed to handle event", err);
  }
}

async function sendGift(plaintext) {
  const createdAt = Math.floor(Date.now() / 1000);
  const dmCipher = await encryptDmContent(privHex, peerHex, plaintext);
  const inner = {
    kind: 14,
    created_at: createdAt,
    tags: [["p", peerHex]],
    content: dmCipher,
  };
  const innerSigned = finalizeEvent(inner, privHex);

  const wrappingPrivHex = bytesToHex(generateSecretKey()); // ephemeral wrapper key
  const wrappingPubHex = getPublicKey(hexToBytes(wrappingPrivHex));

  const sealed = await encryptGiftContent(wrappingPrivHex, peerHex, JSON.stringify(innerSigned));

  const twoDays = 2 * 24 * 60 * 60;
  const randomTimestamp = createdAt - Math.floor(Math.random() * twoDays);
  const expiration = createdAt + 24 * 60 * 60;

  const gift = {
    kind: 1059,
    created_at: randomTimestamp,
    tags: [
      ["p", peerHex],
      ["expiration", expiration.toString()],
    ],
    content: sealed,
    pubkey: wrappingPubHex,
  };
  const signedGift = finalizeEvent(gift, wrappingPrivHex);

  await pool.publish(CONFIG.relays, signedGift);
  console.log("[js-test] sent giftwrap", signedGift.id, "to", short(peerHex));
}

async function decryptGift(event) {
  const conv = nip44_get_conversation_key(privHex, event.pubkey);
  const rumorJson = nip44_decrypt(conv, event.content);
  return JSON.parse(rumorJson);
}

async function decryptDm(targetEvent) {
  const conv = nip44_get_conversation_key(privHex, targetEvent.pubkey);
  return nip44_decrypt(conv, targetEvent.content);
}

async function encryptDmContent(priv, recipientHex, plaintext) {
  const conv = nip44_get_conversation_key(priv, recipientHex);
  return nip44_encrypt(conv, plaintext);
}

async function encryptGiftContent(wrappingPrivHex, recipientHex, innerJson) {
  const conv = nip44_get_conversation_key(wrappingPrivHex, recipientHex);
  return nip44_encrypt(conv, innerJson);
}

function decodeNsec(nsec) {
  const dec = nip19.decode(nsec);
  if (dec.type !== "nsec") throw new Error("Invalid nsec provided");
  return typeof dec.data === "string" ? dec.data : bytesToHex(dec.data);
}

function toHexPub(input) {
  if (!input) throw new Error("Missing peer pubkey");
  if (/^[0-9a-fA-F]{64}$/.test(input)) return input.toLowerCase();
  const dec = nip19.decode(input);
  if (dec.type === "npub") {
    return typeof dec.data === "string" ? dec.data : bytesToHex(dec.data);
  }
  if (dec.data?.pubkey) return dec.data.pubkey;
  throw new Error("Unsupported pubkey format");
}

function short(pk) {
  return pk.slice(0, 6) + "..." + pk.slice(-4);
}
