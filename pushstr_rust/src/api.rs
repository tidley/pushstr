#![allow(unexpected_cfgs)]

use anyhow::{Context, Result};
use base64::{engine::general_purpose, Engine as _};
use flutter_rust_bridge::frb;
use nostr_sdk::nips::nip04;
use nostr_sdk::nips::nip19::{FromBech32, Nip19};
use nostr_sdk::prelude::*;
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex as StdMutex, Once};
use std::future::Future;
use tokio::sync::{Mutex, Notify, oneshot};
use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use secp256k1::{PublicKey as Secp256k1PublicKey, SecretKey as Secp256k1SecretKey, XOnlyPublicKey as Secp256k1XOnlyPublicKey, Secp256k1 as Secp256k1Context};
use getrandom;
use hmac::{Hmac, Mac};
use ::hkdf::Hkdf;
use chacha20::cipher::{KeyIvInit, StreamCipher};
use std::collections::HashSet as StdHashSet;

// Global tokio runtime for all FFI calls
static RUNTIME: Lazy<tokio::runtime::Runtime> =
    Lazy::new(|| tokio::runtime::Runtime::new().expect("Failed to create tokio runtime"));

// Global state for the Nostr client
static NOSTR_CLIENT: Mutex<Option<Arc<Client>>> = Mutex::const_new(None);
static NOSTR_KEYS: Mutex<Option<Keys>> = Mutex::const_new(None);

// Track events that have been returned to prevent duplicates
static RETURNED_EVENT_IDS: Lazy<StdMutex<HashSet<String>>> =
    Lazy::new(|| StdMutex::new(HashSet::new()));
static RETURNED_EVENT_IDS_QUEUE: Lazy<StdMutex<VecDeque<String>>> =
    Lazy::new(|| StdMutex::new(VecDeque::new()));
const RETURNED_EVENT_IDS_MAX: usize = 512;
static SEND_SEQ_BY_RECIPIENT: Lazy<StdMutex<HashMap<String, u64>>> =
    Lazy::new(|| StdMutex::new(HashMap::new()));
const PUSHSTR_CLIENT_TAG_KIND: &str = "c";
const PUSHSTR_CLIENT_TAG_VALUE: &str = "1";

static SEND_QUEUE: Lazy<Mutex<VecDeque<SendRequest>>> =
    Lazy::new(|| Mutex::new(VecDeque::new()));
static SEND_NOTIFY: Lazy<Notify> = Lazy::new(Notify::new);
static SEND_WORKER_ONCE: Once = Once::new();
static RECIPIENT_DM_RELAY_CACHE: Lazy<Mutex<HashMap<String, Vec<String>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static GIFTWRAP_DECRYPT_BATCH: Lazy<StdMutex<GiftwrapDecryptBatch>> =
    Lazy::new(|| StdMutex::new(GiftwrapDecryptBatch::default()));

#[derive(Debug)]
enum SendKind {
    Gift {
        recipient: String,
        content: String,
        use_nip44: bool,
    },
    Legacy {
        recipient: String,
        content: String,
    },
}

struct SendRequest {
    kind: SendKind,
    reply: oneshot::Sender<Result<String>>,
}

fn run_block_on<F: Future>(fut: F) -> F::Output {
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        tokio::task::block_in_place(|| handle.block_on(fut))
    } else {
        RUNTIME.block_on(fut)
    }
}

fn start_send_worker() {
    SEND_WORKER_ONCE.call_once(|| {
        RUNTIME.spawn(async move {
            loop {
                let req = {
                    let mut queue = SEND_QUEUE.lock().await;
                    queue.pop_front()
                };
                if let Some(req) = req {
                    let result = match req.kind {
                        SendKind::Gift {
                            recipient,
                            content,
                            use_nip44,
                        } => send_gift_dm_direct(recipient, content, use_nip44).await,
                        SendKind::Legacy { recipient, content } => {
                            send_dm_direct(recipient, content).await
                        }
                    };
                    let _ = req.reply.send(result);
                    continue;
                }
                SEND_NOTIFY.notified().await;
            }
        });
    });
}

async fn enqueue_send(kind: SendKind) -> Result<String> {
    start_send_worker();
    let (tx, rx) = oneshot::channel();
    {
        let mut queue = SEND_QUEUE.lock().await;
        queue.push_back(SendRequest { kind, reply: tx });
    }
    SEND_NOTIFY.notify_one();
    rx.await.context("send queue closed")?
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb(non_opaque)]
pub struct MediaDescriptor {
    pub url: String,
    /// Base64-encoded 32-byte symmetric key.
    pub k: String,
    /// Base64-encoded nonce (12 bytes for AES-GCM, 24 bytes for XChaCha20-Poly1305).
    pub nonce: String,
    pub sha256: String,
    pub cipher_sha256: String,
    pub mime: String,
    pub size: usize,
    /// "aes-gcm" | "xchacha20poly1305" | "none"
    pub encryption: String,
    pub filename: Option<String>,
}

// Blossom server configuration
const BLOSSOM_SERVER: &str = "https://blossom.primal.net";
const PUBLISH_RETRY_ATTEMPTS: usize = 3;
const PUBLISH_RETRY_BASE_MS: u64 = 400;
const BLOSSOM_UPLOAD_PATH: &str = "upload";
const READ_RECEIPT_KEY: &str = "pushstr_ack";
const PUSHSTR_CLIENT_TAG: &str = "[pushstr:client]";

fn parse_pubkey(input: &str) -> Result<PublicKey> {
    let trimmed = input.trim();
    let normalized = trimmed
        .strip_prefix("nostr://")
        .or_else(|| trimmed.strip_prefix("nostr:"))
        .unwrap_or(trimmed);
    if normalized.starts_with("npub") || normalized.starts_with("nprofile") {
        let nip19 = Nip19::from_bech32(normalized)?;
        match nip19 {
            Nip19::Pubkey(pubkey) => Ok(pubkey),
            Nip19::Profile(profile) => Ok(profile.public_key),
            _ => anyhow::bail!("Unsupported NIP-19 pubkey"),
        }
    } else {
        PublicKey::from_hex(normalized).context("Invalid pubkey")
    }
}

fn event_p_tag_pubkey(event: &Event) -> Option<PublicKey> {
    event
        .tags
        .iter()
        .find(|t| t.kind() == TagKind::p())
        .and_then(|t| t.content())
        .and_then(|s| PublicKey::from_hex(s).ok())
}

fn strip_pushstr_client_tag(content: &str) -> String {
    if !content.contains(PUSHSTR_CLIENT_TAG) {
        return content.to_string();
    }
    let mut out = Vec::new();
    for line in content.lines() {
        if line.trim() == PUSHSTR_CLIENT_TAG {
            continue;
        }
        out.push(line);
    }
    out.join("\n").trim().to_string()
}

fn event_has_pushstr_client_tag(tags: &Tags) -> bool {
    let tag_kind = TagKind::Custom(PUSHSTR_CLIENT_TAG_KIND.into());
    tags.iter().any(|tag| {
        tag.kind() == tag_kind
            && tag
                .content()
                .map(|value| value.eq_ignore_ascii_case(PUSHSTR_CLIENT_TAG_VALUE))
                .unwrap_or(false)
    })
}

fn tag_list_has_pushstr_client_tag(tags: &[Vec<String>]) -> bool {
    tags.iter().any(|tag| {
        tag.len() >= 2
            && tag[0] == PUSHSTR_CLIENT_TAG_KIND
            && tag[1].eq_ignore_ascii_case(PUSHSTR_CLIENT_TAG_VALUE)
    })
}

fn parse_read_receipt_id(content: &str) -> Option<String> {
    let trimmed = content.trim_start();
    if !trimmed.starts_with('{') || !trimmed.contains(READ_RECEIPT_KEY) {
        return None;
    }
    let parsed: serde_json::Value = serde_json::from_str(trimmed).ok()?;
    parsed
        .get(READ_RECEIPT_KEY)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

fn is_read_receipt_content(content: &str) -> bool {
    let stripped = strip_pushstr_client_tag(content);
    parse_read_receipt_id(&stripped).is_some()
}

fn normalize_message_content(raw: &str, is_pushstr_client_tagged: bool) -> (String, bool, Option<String>) {
    let is_pushstr_client = is_pushstr_client_tagged || raw.contains(PUSHSTR_CLIENT_TAG);
    let stripped = strip_pushstr_client_tag(raw);
    let receipt_for = parse_read_receipt_id(&stripped);
    (stripped, is_pushstr_client, receipt_for)
}

fn push_normalized_dm_message(
    messages: &mut Vec<serde_json::Value>,
    id: String,
    from: String,
    to: String,
    content: String,
    created_at: u64,
    direction: &'static str,
    kind: u64,
    dm_kind: String,
    tags_have_pushstr_client: bool,
    seq: Option<u64>,
) {
    let (cleaned, pushstr_client, receipt_for) =
        normalize_message_content(&content, tags_have_pushstr_client);
    messages.push(serde_json::json!({
        "id": id,
        "from": from,
        "to": to,
        "content": cleaned,
        "created_at": created_at,
        "direction": direction,
        "kind": kind,
        "dm_kind": dm_kind,
        "pushstr_client": pushstr_client,
        "receipt_for": receipt_for,
        "seq": seq,
    }));
}

fn push_giftwrap_dm(
    messages: &mut Vec<serde_json::Value>,
    event: &Event,
    unwrapped: UnwrappedGift,
    keys: &Keys,
    my_pubkey_hex: &str,
) {
    let event_id = event.id.to_hex();

    let sender_hex = unwrapped
        .rumor
        .pubkey
        .clone()
        .unwrap_or_else(|| unwrapped.sender_pubkey.clone());
    let direction = if sender_hex == my_pubkey_hex { "out" } else { "in" };
    let tags = unwrapped.rumor.tags.clone().unwrap_or_default();
    let other = if direction == "out" {
        tags.iter()
            .find(|t| t.first().map(|v| v == "p").unwrap_or(false))
            .and_then(|t| t.get(1))
            .cloned()
            .unwrap_or_default()
    } else {
        sender_hex.clone()
    };
    let seq = seq_from_tag_list(&tags);
    let mut content = unwrapped.rumor.content.clone().unwrap_or_default();
    if direction == "in" && !content.is_empty() {
        if let Ok(sender_pk) = PublicKey::from_hex(&sender_hex) {
            content = nip44_decrypt_custom(keys.secret_key(), &sender_pk, &content)
                .unwrap_or(content);
        }
    } else if direction == "out" && !content.is_empty() {
        if let Ok(recipient_pk) = PublicKey::from_hex(&other) {
            content = nip44_decrypt_custom(keys.secret_key(), &recipient_pk, &content)
                .unwrap_or(content);
        }
    }

    push_normalized_dm_message(
        messages,
        event_id,
        if direction == "out" { my_pubkey_hex.to_string() } else { sender_hex },
        if direction == "out" { other } else { my_pubkey_hex.to_string() },
        content,
        unwrapped.created_at,
        direction,
        1059,
        unwrapped.format,
        tag_list_has_pushstr_client_tag(&tags),
        seq,
    );
}

fn push_nip04_dm(
    messages: &mut Vec<serde_json::Value>,
    event: &Event,
    keys: &Keys,
    my_pubkey_hex: &str,
    inbound: bool,
) {
    let event_id = event.id.to_hex();
    if inbound {
        let decrypted = nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content)
            .unwrap_or_else(|e| {
                eprintln!("[dm] NIP-04 inbound decrypt failed {}: {}", event_id, e);
                event.content.clone()
            });
        let seq = seq_from_event_tags(&event.tags);
        push_normalized_dm_message(
            messages,
            event_id,
            event.pubkey.to_hex(),
            my_pubkey_hex.to_string(),
            decrypted,
            event.created_at.as_u64(),
            "in",
            4,
            "nip04".to_string(),
            event_has_pushstr_client_tag(&event.tags),
            seq,
        );
        return;
    }

    let recipient_pk = match event_p_tag_pubkey(event) {
        Some(pk) => pk,
        None => return,
    };
    let decrypted = nip04::decrypt(keys.secret_key(), &recipient_pk, &event.content)
        .unwrap_or_else(|e| {
            eprintln!("[dm] NIP-04 outbound decrypt failed {}: {}", event_id, e);
            event.content.clone()
        });
    let seq = seq_from_event_tags(&event.tags);
    push_normalized_dm_message(
        messages,
        event_id,
        my_pubkey_hex.to_string(),
        recipient_pk.to_hex(),
        decrypted,
        event.created_at.as_u64(),
        "out",
        4,
        "nip04".to_string(),
        event_has_pushstr_client_tag(&event.tags),
        seq,
    );
}

fn derive_contact_name(metadata: &serde_json::Value) -> Option<String> {
    for key in ["display_name", "name"] {
        if let Some(value) = metadata.get(key).and_then(|v| v.as_str()).map(str::trim) {
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    if let Some(nip05) = metadata.get("nip05").and_then(|v| v.as_str()).map(str::trim) {
        if let Some(local) = nip05.split('@').next() {
            let local = local.trim();
            if !local.is_empty() {
                return Some(local.to_string());
            }
        }
    }
    None
}

fn relay_tags(event: &Event) -> Vec<String> {
    let relay_kind = TagKind::Custom("relay".into());
    event
        .tags
        .iter()
        .filter(|t| t.kind() == relay_kind)
        .filter_map(|t| t.content())
        .map(|s| s.to_string())
        .collect()
}

fn next_send_seq(recipient_hex: &str) -> u64 {
    let mut map = SEND_SEQ_BY_RECIPIENT.lock().unwrap();
    let entry = map.entry(recipient_hex.to_string()).or_insert(0);
    *entry += 1;
    *entry
}

fn seq_from_tag_list(tags: &[Vec<String>]) -> Option<u64> {
    for tag in tags {
        if tag.len() >= 2 && tag[0] == "seq" {
            if let Ok(val) = tag[1].parse::<u64>() {
                return Some(val);
            }
        }
    }
    None
}

fn seq_from_event_tags(tags: &Tags) -> Option<u64> {
    let seq_kind = TagKind::Custom("seq".into());
    for tag in tags.iter() {
        if tag.kind() == seq_kind {
            if let Some(val) = tag.content() {
                if let Ok(seq) = val.parse::<u64>() {
                    return Some(seq);
                }
            }
        }
    }
    None
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RumorData {
    id: Option<String>,
    pubkey: Option<String>,
    created_at: Option<u64>,
    kind: Option<u64>,
    tags: Option<Vec<Vec<String>>>,
    content: Option<String>,
}

struct UnwrappedGift {
    rumor: RumorData,
    sender_pubkey: String,
    created_at: u64,
    format: String,
}

#[derive(Default)]
pub struct GiftwrapDecryptBatch {
    pub count: usize,
    pub gen: u64,
}

fn note_giftwrap_decrypt() {
    let token = {
        let mut st = GIFTWRAP_DECRYPT_BATCH.lock().unwrap();
        st.count += 1;
        st.gen += 1;
        st.gen
    };

    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(1));
        let mut st = GIFTWRAP_DECRYPT_BATCH.lock().unwrap();
        if st.gen == token && st.count > 0 {
            eprintln!("[dm] giftwrap decrypt batch: {} message(s)", st.count);
            st.count = 0;
        }
    });
}

fn random_timestamp_within_two_days() -> Timestamp {
    Timestamp::now()
}

async fn get_client_and_keys() -> Result<(Arc<Client>, Keys)> {
    let client_lock = NOSTR_CLIENT.lock().await;
    let keys_lock = NOSTR_KEYS.lock().await;
    Ok((
        client_lock
            .as_ref()
            .context("Not initialized")?
            .clone(),
        keys_lock.as_ref().context("Not initialized")?.clone(),
    ))
}

async fn ensure_recipient_dm_relays(client: &Client, recipient_pk: &PublicKey) -> Result<()> {
    let recipient_hex = recipient_pk.to_hex();
    if let Some(cached) = {
        let cache = RECIPIENT_DM_RELAY_CACHE.lock().await;
        cache.get(&recipient_hex).cloned()
    } {
        if !cached.is_empty() {
            eprintln!(
                "[dm] recipient relay cache hit {} relays for {}",
                cached.len(),
                recipient_hex
            );
            for relay in cached {
                let _ = client.add_relay(relay).await;
            }
        }
        return Ok(());
    }

    let filter = Filter::new()
        .kind(Kind::Custom(10050))
        .author(recipient_pk.clone())
        .limit(1);
    let events = match tokio::time::timeout(
        std::time::Duration::from_secs(2),
        client.fetch_events(filter, std::time::Duration::from_secs(2)),
    )
    .await
    {
        Ok(res) => res?,
        Err(_) => {
            eprintln!("[dm] recipient relay lookup timed out for {}", recipient_hex);
            return Ok(());
        }
    };
    if let Some(event) = events.first() {
        let relays = relay_tags(event);
        if !relays.is_empty() {
            eprintln!("[dm] recipient relay list detected: {:?}", relays);
            {
                let mut cache = RECIPIENT_DM_RELAY_CACHE.lock().await;
                cache.insert(recipient_hex.clone(), relays.clone());
            }
            for relay in relays {
                let _ = client.add_relay(relay).await;
            }
        }
    } else {
        eprintln!("[dm] no recipient relay list found");
    }
    Ok(())
}

fn normalize_relay_list(relays: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for relay in relays {
        let trimmed = relay.trim();
        if !(trimmed.starts_with("ws://") || trimmed.starts_with("wss://")) {
            continue;
        }
        if seen.insert(trimmed.to_string()) {
            out.push(trimmed.to_string());
        }
    }
    out
}

// Helper function to derive NIP-44 conversation key
type HmacSha256 = Hmac<Sha256>;

struct Nip44MessageKeys {
    chacha_key: [u8; 32],
    chacha_nonce: [u8; 12],
    hmac_key: [u8; 32],
}

fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> Result<[u8; 32]> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key)
        .map_err(|e| anyhow::anyhow!("HMAC init failed: {}", e))?;
    for part in parts {
        mac.update(part);
    }
    let result = mac.finalize().into_bytes();
    let mut out = [0u8; 32];
    out.copy_from_slice(&result);
    Ok(out)
}

fn nip44_calc_padded_len(len: usize) -> usize {
    if len <= 32 {
        return 32;
    }
    let len_minus = len - 1;
    let mut next_power = len_minus.next_power_of_two();
    if next_power == len_minus {
        next_power = next_power.saturating_mul(2);
    }
    let chunk = if next_power <= 256 { 32 } else { next_power / 8 };
    chunk * ((len_minus / chunk) + 1)
}

fn nip44_pad(plaintext: &str) -> Result<Vec<u8>> {
    let unpadded = plaintext.as_bytes();
    let unpadded_len = unpadded.len();
    if unpadded_len == 0 {
        anyhow::bail!("Message is empty");
    }
    const MAX_PLAINTEXT: usize = 0xFFFF;
    const EXT_MAX_PLAINTEXT: usize = 0xFFFF_FFFE;

    let mut prefix = Vec::with_capacity(6);
    if unpadded_len <= MAX_PLAINTEXT {
        prefix.push(((unpadded_len >> 8) & 0xFF) as u8);
        prefix.push((unpadded_len & 0xFF) as u8);
    } else if unpadded_len <= EXT_MAX_PLAINTEXT {
        prefix.extend_from_slice(&[0, 0]);
        prefix.push(((unpadded_len >> 24) & 0xFF) as u8);
        prefix.push(((unpadded_len >> 16) & 0xFF) as u8);
        prefix.push(((unpadded_len >> 8) & 0xFF) as u8);
        prefix.push((unpadded_len & 0xFF) as u8);
    } else {
        anyhow::bail!("Message is too long ({})", unpadded_len);
    }

    let padded_len = nip44_calc_padded_len(unpadded_len);
    let mut out = Vec::with_capacity(prefix.len() + padded_len);
    out.extend_from_slice(&prefix);
    out.extend_from_slice(unpadded);
    out.resize(prefix.len() + padded_len, 0u8);
    Ok(out)
}

fn nip44_unpad(padded: &[u8]) -> Result<String> {
    if padded.len() < 2 {
        anyhow::bail!("Invalid padded payload");
    }
    let len_pre = ((padded[0] as usize) << 8) | padded[1] as usize;
    if len_pre == 0 {
        if padded.len() < 6 {
            anyhow::bail!("Invalid extended padding");
        }
        let len_ext = ((padded[2] as usize) << 24)
            | ((padded[3] as usize) << 16)
            | ((padded[4] as usize) << 8)
            | (padded[5] as usize);
        if len_ext == 0 || len_ext > 0xFFFF_FFFE {
            anyhow::bail!("Invalid size {}", len_ext);
        }
        let expected = 6 + nip44_calc_padded_len(len_ext);
        if padded.len() != expected {
            anyhow::bail!("Invalid padding {} != {}", padded.len(), expected);
        }
        return String::from_utf8(padded[6..6 + len_ext].to_vec())
            .map_err(|e| anyhow::anyhow!("Invalid UTF-8: {}", e));
    }
    if len_pre > 0xFFFF {
        anyhow::bail!("Invalid size {}", len_pre);
    }
    let expected = 2 + nip44_calc_padded_len(len_pre);
    if padded.len() != expected {
        anyhow::bail!("Invalid padding {} != {}", padded.len(), expected);
    }
    String::from_utf8(padded[2..2 + len_pre].to_vec())
        .map_err(|e| anyhow::anyhow!("Invalid UTF-8: {}", e))
}

fn nip44_hmac_aad(key: &[u8; 32], message: &[u8], aad: &[u8; 32]) -> Result<[u8; 32]> {
    hmac_sha256(key, &[aad, message])
}

fn nip44_fast_expand(
    conversation_key: &[u8; 32],
    nonce: &[u8; 32],
    ciphertext: Option<&[u8]>,
    mac: Option<&[u8]>,
) -> Result<Nip44MessageKeys> {
    let round1 = hmac_sha256(conversation_key, &[nonce, &[1u8]])?;
    let round2 = hmac_sha256(conversation_key, &[&round1, nonce, &[2u8]])?;
    let round3 = hmac_sha256(conversation_key, &[&round2, nonce, &[3u8]])?;

    let mut hmac_key = [0u8; 32];
    hmac_key[0..20].copy_from_slice(&round2[12..32]);
    hmac_key[20..32].copy_from_slice(&round3[0..12]);

    if let (Some(ciphertext), Some(mac)) = (ciphertext, mac) {
        if mac.len() != 32 {
            anyhow::bail!("Invalid mac length {}", mac.len());
        }
        let calc = nip44_hmac_aad(&hmac_key, ciphertext, nonce)?;
        if calc.as_ref() != mac {
            anyhow::bail!("Invalid Mac");
        }
    }

    let mut chacha_nonce = [0u8; 12];
    chacha_nonce.copy_from_slice(&round2[0..12]);

    Ok(Nip44MessageKeys {
        chacha_key: round1,
        chacha_nonce,
        hmac_key,
    })
}

fn get_nip44_conversation_key(secret_key: &SecretKey, public_key: &PublicKey) -> Result<[u8; 32]> {
    let secp = Secp256k1Context::new();

    let secret_bytes = secret_key.secret_bytes();
    let secp_secret = Secp256k1SecretKey::from_slice(&secret_bytes)?;

    let public_bytes = public_key.to_bytes();
    let xonly_pubkey = Secp256k1XOnlyPublicKey::from_slice(&public_bytes)?;

    let public_key_even =
        Secp256k1PublicKey::from_x_only_public_key(xonly_pubkey, secp256k1::Parity::Even);
    let shared_point = public_key_even.mul_tweak(&secp, &secp_secret.into())?;

    let shared_bytes = shared_point.serialize_uncompressed();
    let shared_x = &shared_bytes[1..33];

    let (prk, _) = Hkdf::<Sha256>::extract(Some(b"nip44-v2"), shared_x);
    let mut conversation_key = [0u8; 32];
    conversation_key.copy_from_slice(&prk[..]);
    Ok(conversation_key)
}

// NIP-44 v2 encrypt compatible with Amethyst/NIP-59
fn nip44_encrypt_custom(secret_key: &SecretKey, public_key: &PublicKey, plaintext: &str) -> Result<String> {
    let conv_key = get_nip44_conversation_key(secret_key, public_key)?;

    let mut nonce = [0u8; 32];
    getrandom::getrandom(&mut nonce)?;

    let keys = nip44_fast_expand(&conv_key, &nonce, None, None)?;
    let mut buffer = nip44_pad(plaintext)?;

    let mut cipher = chacha20::ChaCha20::new((&keys.chacha_key).into(), (&keys.chacha_nonce).into());
    cipher.apply_keystream(&mut buffer);

    let mac = nip44_hmac_aad(&keys.hmac_key, &buffer, &nonce)?;

    let mut payload = Vec::with_capacity(1 + 32 + buffer.len() + 32);
    payload.push(0x02);
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&buffer);
    payload.extend_from_slice(&mac);

    Ok(base64::engine::general_purpose::STANDARD.encode(&payload))
}

// NIP-44 v2 decrypt compatible with Amethyst/NIP-59
fn nip44_decrypt_custom(secret_key: &SecretKey, public_key: &PublicKey, ciphertext_b64: &str) -> Result<String> {
    let conv_key = get_nip44_conversation_key(secret_key, public_key)?;

    let payload = base64::engine::general_purpose::STANDARD.decode(ciphertext_b64)?;
    if payload.len() < 65 {
        anyhow::bail!("ciphertext too short");
    }
    if payload[0] != 0x02 {
        anyhow::bail!("unsupported version: {}", payload[0]);
    }
    if payload.len() < 1 + 32 + 32 {
        anyhow::bail!("ciphertext too short");
    }
    let mut nonce = [0u8; 32];
    nonce.copy_from_slice(&payload[1..33]);
    let mac_offset = payload.len() - 32;
    let ciphertext = &payload[33..mac_offset];
    let mac = &payload[mac_offset..];

    let keys = nip44_fast_expand(&conv_key, &nonce, Some(ciphertext), Some(mac))?;
    let mut buffer = ciphertext.to_vec();
    let mut cipher = chacha20::ChaCha20::new((&keys.chacha_key).into(), (&keys.chacha_nonce).into());
    cipher.apply_keystream(&mut buffer);

    nip44_unpad(&buffer)
}

fn wrap_gift_event(inner_event: &Event, recipient_pk: PublicKey, keys: &Keys) -> Result<Event> {
    // Build Rumor JSON from inner event (drop signature to match Amethyst).
    let mut rumor_value = serde_json::to_value(inner_event)?;
    if let serde_json::Value::Object(obj) = &mut rumor_value {
        obj.remove("sig");
    }
    let rumor_json = serde_json::to_string(&rumor_value)?;

    // Sealed rumor (kind 13), signed by sender, encrypted to recipient.
    let sealed_content = nip44_encrypt_custom(keys.secret_key(), &recipient_pk, &rumor_json)?;
    let sealed_event = EventBuilder::new(Kind::Custom(13), sealed_content)
        .custom_created_at(random_timestamp_within_two_days())
        .sign_with_keys(&keys)?;

    // Giftwrap (kind 1059), random key, encrypted to recipient.
    let wrapper_keys = Keys::generate();
    let sealed_json = serde_json::to_string(&sealed_event)?;
    let gift_ciphertext = nip44_encrypt_custom(wrapper_keys.secret_key(), &recipient_pk, &sealed_json)?;
    let builder = EventBuilder::new(Kind::GiftWrap, gift_ciphertext)
        .custom_created_at(random_timestamp_within_two_days())
        .tag(Tag::custom(TagKind::Custom("p".into()), vec![recipient_pk.to_hex()]));
    let gift = builder.sign_with_keys(&wrapper_keys)?;
    Ok(gift)
}

fn unwrap_gift_event(gift_event: &Event, keys: &Keys) -> Result<UnwrappedGift> {
    if gift_event.kind != Kind::GiftWrap {
        anyhow::bail!("Event is not kind 1059");
    }

    note_giftwrap_decrypt();

    // Try custom NIP-44 first (matches WASM exactly)
    // Fall back to NIP-04 for old messages
    let decrypted = nip44_decrypt_custom(keys.secret_key(), &gift_event.pubkey, &gift_event.content)
        .or_else(|e| {
            eprintln!("[mobile] NIP-44 giftwrap decrypt failed: {}", e);
            nip04::decrypt(keys.secret_key(), &gift_event.pubkey, gift_event.content.clone())
        })?;
    let sealed_event: Event = serde_json::from_str(&decrypted)?;

    // NIP-59 sealed rumor path (kind 13). Otherwise fall back to legacy inner event.
    if sealed_event.kind == Kind::Custom(13) {
        let rumor_json = nip44_decrypt_custom(keys.secret_key(), &sealed_event.pubkey, &sealed_event.content)
            .or_else(|e| {
                eprintln!("[mobile] NIP-44 sealed decrypt failed: {}", e);
                nip04::decrypt(keys.secret_key(), &sealed_event.pubkey, sealed_event.content.clone())
            })?;
        let rumor: RumorData = serde_json::from_str(&rumor_json)?;
        let created_at = rumor.created_at.unwrap_or_else(|| sealed_event.created_at.as_u64());
        let sender_pubkey = rumor
            .pubkey
            .clone()
            .unwrap_or_else(|| sealed_event.pubkey.to_hex());
        Ok(UnwrappedGift {
            rumor,
            sender_pubkey,
            created_at,
            format: "nip59".to_string(),
        })
    } else {
        let mut event_value = serde_json::to_value(&sealed_event)?;
        if let serde_json::Value::Object(obj) = &mut event_value {
            obj.remove("sig");
        }
        let rumor: RumorData = serde_json::from_value(event_value)?;
        let created_at = rumor.created_at.unwrap_or_else(|| sealed_event.created_at.as_u64());
        let sender_pubkey = rumor
            .pubkey
            .clone()
            .unwrap_or_else(|| sealed_event.pubkey.to_hex());
        Ok(UnwrappedGift {
            rumor,
            sender_pubkey,
            created_at,
            format: "legacy_giftwrap".to_string(),
        })
    }
}

// Default relay configuration
const RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nip17.com",
    "wss://nip17.tomdwyer.uk",
    "wss://nos.lol",
    "wss://nostr.mom",
    "wss://relay.nostr.band",
];
const DM_RELAYS: &[&str] = &[
    "wss://nos.lol",
    "wss://nip17.com",
    "wss://nip17.tomdwyer.uk",
    "wss://auth.nostr1.com",
    "wss://relay.0xchat.com",
    "wss://inbox.nostr.wine",
];

/// Initialize the Nostr service with a secret key (nsec)
/// If nsec is empty, generates a new key
/// Returns npub
#[frb(sync)]
pub fn init_nostr(nsec: String) -> Result<String> {
    run_block_on(async {
        let keys = if nsec.is_empty() {
            Keys::generate()
        } else {
            Keys::parse(&nsec).context("Invalid nsec format")?
        };

        let client = Client::new(keys.clone());

        // Add default relays
        for relay in RELAYS {
            client.add_relay(*relay).await?;
        }
        // Add default DM relays (popular inbox relays)
        for relay in DM_RELAYS {
            let _ = client.add_relay(*relay).await;
        }

        client.connect().await;
        eprintln!("🔌 Client connected to default relays");

        // Wait a bit for connection to establish
        tokio::time::sleep(tokio::time::Duration::from_millis(1000)).await;

        // Fetch NIP-17 relay list (kind 10050) and add any custom relays
        let filter_nip17_relays = Filter::new()
            .kind(Kind::Custom(10050))
            .author(keys.public_key())
            .limit(1);
        let nip17_events = client
            .fetch_events(filter_nip17_relays, std::time::Duration::from_secs(5))
            .await?;
        if let Some(event) = nip17_events.first() {
            let relays = relay_tags(event);
            if !relays.is_empty() {
                eprintln!("[dm] NIP-17 relays detected: {:?}", relays);
                for relay in relays {
                    let _ = client.add_relay(relay).await;
                }
                client.connect().await;
                tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
            }
        } else {
            eprintln!("[dm] No NIP-17 relay list found");
            // Publish a default NIP-17 relay list so other clients can DM us.
            let mut builder = EventBuilder::new(Kind::Custom(10050), "");
            for relay in DM_RELAYS {
                builder = builder.tag(Tag::custom(TagKind::Custom("relay".into()), vec![relay.to_string()]));
            }
            builder = builder.tag(Tag::custom(
                TagKind::Custom("alt".into()),
                vec!["Relay list to receive private messages".to_string()],
            ));
            let list_event = builder.sign_with_keys(&keys)?;
            let _ = client.send_event(&list_event).await;
        }

        // Subscribe to encrypted DMs (kind 4 - NIP-04, matching browser extension default)
        let filter_dms = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .custom_tag(
                SingleLetterTag::lowercase(Alphabet::P),
                keys.public_key().to_hex(),
            );
        let _ = client.subscribe(filter_dms, None).await;
        eprintln!("📡 Subscribed to encrypted DMs (kind 4)");
        // Subscribe to giftwraps (kind 1059)
        let filter_gift = Filter::new()
            .kind(Kind::GiftWrap)
            .custom_tag(
                SingleLetterTag::lowercase(Alphabet::P),
                keys.public_key().to_hex(),
            );
        let _ = client.subscribe(filter_gift, None).await;
        eprintln!("📡 Subscribed to giftwraps (kind 1059)");

        // Store globally
        *NOSTR_CLIENT.lock().await = Some(Arc::new(client));
        *NOSTR_KEYS.lock().await = Some(keys.clone());

        let npub = keys.public_key().to_bech32()?;
        eprintln!("✅ Nostr client initialized: {}", npub);
        Ok(npub)
    })
}

/// Get the current user's npub
#[frb(sync)]
pub fn get_npub() -> Result<String> {
    run_block_on(async {
        let keys_lock = NOSTR_KEYS.lock().await;
        let keys = keys_lock
            .as_ref()
            .context("Nostr not initialized. Call init_nostr first.")?;

        Ok(keys.public_key().to_bech32()?)
    })
}

/// Get the current user's nsec (for backup purposes)
#[frb(sync)]
pub fn get_nsec() -> Result<String> {
    run_block_on(async {
        let keys_lock = NOSTR_KEYS.lock().await;
        let keys = keys_lock
            .as_ref()
            .context("Nostr not initialized. Call init_nostr first.")?;

        Ok(keys.secret_key().to_bech32()?)
    })
}

/// Generate a new keypair and return nsec
#[frb(sync)]
pub fn generate_new_key() -> Result<String> {
    let keys = Keys::generate();
    Ok(keys.secret_key().to_bech32()?)
}

/// Publish the active profile relay list as a NIP-65 kind 10002 event.
#[frb(sync)]
pub fn publish_relay_list(relays: Vec<String>) -> Result<String> {
    run_block_on(async {
        let (client, keys) = get_client_and_keys().await?;
        let relay_list = normalize_relay_list(relays);
        if relay_list.is_empty() {
            anyhow::bail!("no relays available");
        }

        for relay in &relay_list {
            let _ = client.add_relay(relay.clone()).await;
        }
        client.connect().await;

        let mut builder = EventBuilder::new(Kind::Custom(10002), "");
        for relay in &relay_list {
            builder = builder.tag(Tag::custom(TagKind::Custom("r".into()), vec![relay.clone()]));
        }
        let event = builder.sign_with_keys(&keys)?;
        let event_id = event.id.to_hex();
        eprintln!("[relay-list] Publishing kind 10002 id={}", event_id);

        let mut last_err = None;
        for attempt in 1..=PUBLISH_RETRY_ATTEMPTS {
            match client.send_event(&event).await {
                Ok(_) => {
                    eprintln!("[relay-list] Published kind 10002 id={}", event_id);
                    last_err = None;
                    break;
                }
                Err(e) => {
                    last_err = Some(e);
                    eprintln!(
                        "[relay-list] Publish failed id={} attempt={} err={}",
                        event_id,
                        attempt,
                        last_err.as_ref().unwrap()
                    );
                    if attempt < PUBLISH_RETRY_ATTEMPTS {
                        let delay_ms = PUBLISH_RETRY_BASE_MS * (1u64 << (attempt - 1));
                        tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
                    }
                }
            }
        }
        if let Some(err) = last_err {
            return Err(err.into());
        }
        Ok(event_id)
    })
}

async fn send_gift_dm_direct(
    recipient: String,
    content: String,
    use_nip44: bool,
) -> Result<String> {
    let (client, keys) = get_client_and_keys().await?;
    let recipient_pk = parse_pubkey(&recipient)?;
    {
        let client = client.clone();
        let recipient_pk = recipient_pk.clone();
        tokio::spawn(async move {
            let _ = ensure_recipient_dm_relays(client.as_ref(), &recipient_pk).await;
        });
    }

    // NIP-17: Inner DM with plaintext content, signed by user - kind 14
    let seq = if is_read_receipt_content(&content) {
        None
    } else {
        Some(next_send_seq(&recipient_pk.to_hex()))
    };
    let mut inner_builder = EventBuilder::new(Kind::Custom(14), content)
        .tag(Tag::custom(TagKind::Custom("p".into()), vec![recipient_pk.to_hex()]));
    if let Some(seq) = seq {
        inner_builder = inner_builder
            .tag(Tag::custom(TagKind::Custom("seq".into()), vec![seq.to_string()]));
    }
    let inner_event = inner_builder
        .tag(Tag::custom(
            TagKind::Custom("alt".into()),
            vec!["Direct message".to_string()],
        ))
        .tag(Tag::custom(
            TagKind::Custom(PUSHSTR_CLIENT_TAG_KIND.into()),
            vec![PUSHSTR_CLIENT_TAG_VALUE.to_string()],
        ))
        .sign_with_keys(&keys)?;

    let gift = wrap_gift_event(&inner_event, recipient_pk, &keys)?;
    let event_id = gift.id.to_hex();
    eprintln!("[dm] Sending giftwrap id={}", event_id);
    let mut last_err = None;
    for attempt in 1..=PUBLISH_RETRY_ATTEMPTS {
        match client.send_event(&gift).await {
            Ok(_) => {
                eprintln!("[dm] Giftwrap sent id={}", event_id);
                last_err = None;
                break;
            }
            Err(e) => {
                last_err = Some(e);
                eprintln!(
                    "[dm] Giftwrap send failed id={} attempt={} err={}",
                    event_id, attempt, last_err.as_ref().unwrap()
                );
                if attempt < PUBLISH_RETRY_ATTEMPTS {
                    let delay_ms = PUBLISH_RETRY_BASE_MS * (1u64 << (attempt - 1));
                    tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
                }
            }
        }
    }
    if let Some(err) = last_err {
        return Err(err.into());
    }
    Ok(event_id)
}

/// Send a giftwrapped DM (kind 1059 wrapping kind 4) using nip44 by default
#[frb(sync)]
pub fn send_gift_dm(recipient: String, content: String, use_nip44: bool) -> Result<String> {
    run_block_on(enqueue_send(SendKind::Gift {
        recipient,
        content,
        use_nip44,
    }))
}

/// Send a giftwrap DM using the standard NIP-59 sealed rumor path.
#[frb(sync)]
pub fn send_legacy_gift_dm(recipient: String, content: String) -> Result<String> {
    send_gift_dm(recipient, content, true)
}

/// Wrap a NIP-17 giftwrap from a provided inner event JSON
#[frb(sync)]
pub fn wrap_gift(inner_json: String, recipient: String, _use_nip44: bool) -> Result<String> {
    let inner_event: Event =
        serde_json::from_str(&inner_json).context("inner_json must be a valid Nostr event JSON")?;
    let recipient_pk = parse_pubkey(&recipient)?;
    let keys = {
        let guard = run_block_on(async { NOSTR_KEYS.lock().await });
        guard
            .as_ref()
            .context("Nostr not initialized. Call init_nostr first.")?
            .clone()
    };
    let gift = wrap_gift_event(&inner_event, recipient_pk, &keys)?;
    Ok(serde_json::to_string(&gift)?)
}

/// Unwrap a NIP-17 giftwrap to recover the inner event
#[frb(sync)]
pub fn unwrap_gift(gift_json: String, my_nsec: Option<String>) -> Result<String> {
    let gift_event: Event =
        serde_json::from_str(&gift_json).context("gift_json must be an event JSON")?;

    let keys = if let Some(nsec) = my_nsec {
        Keys::parse(&nsec)?
    } else {
        let guard = run_block_on(async { NOSTR_KEYS.lock().await });
        if let Some(k) = guard.as_ref() {
            k.clone()
        } else {
            anyhow::bail!("Nostr not initialized. Call init_nostr first.")
        }
    };

    let unwrapped = unwrap_gift_event(&gift_event, &keys)?;
    let sender_pk = PublicKey::from_hex(&unwrapped.sender_pubkey)?;
    let output = serde_json::json!({
        "event": unwrapped.rumor,
        "sender_hex": unwrapped.sender_pubkey,
        "sender_npub": sender_pk.to_bech32()?,
        "recipient_npub": keys.public_key().to_bech32()?,
        "recipient_hex": keys.public_key().to_hex(),
    });
    Ok(serde_json::to_string(&output)?)
}

/// Convert npub to hex pubkey
#[frb(sync)]
pub fn npub_to_hex(npub: String) -> Result<String> {
    let pubkey = parse_pubkey(&npub)?;
    Ok(pubkey.to_hex())
}

/// Convert hex pubkey to npub
#[frb(sync)]
pub fn hex_to_npub(hex: String) -> Result<String> {
    let pubkey = PublicKey::from_hex(&hex)?;
    Ok(pubkey.to_bech32()?)
}

/// Derive npubs for a list of nsecs without mutating global state.
#[frb(sync)]
pub fn derive_npubs(nsecs: Vec<String>) -> Result<Vec<String>> {
    let mut out = Vec::with_capacity(nsecs.len());
    for nsec in nsecs {
        let trimmed = nsec.trim();
        if trimmed.is_empty() {
            out.push(String::new());
            continue;
        }
        match Keys::parse(trimmed) {
            Ok(keys) => out.push(keys.public_key().to_bech32()?),
            Err(_) => out.push(String::new()),
        }
    }
    Ok(out)
}

async fn send_dm_direct(recipient: String, message: String) -> Result<String> {
    let client_lock = NOSTR_CLIENT.lock().await;
    let client = client_lock
        .as_ref()
        .context("Not initialized")?
        .clone();
    drop(client_lock);

    // Parse recipient (try npub first, then hex)
    let recipient_pubkey = if recipient.starts_with("npub") {
        PublicKey::from_bech32(&recipient)?
    } else {
        PublicKey::from_hex(&recipient)?
    };

    // Send NIP-04 encrypted DM (kind 4) - same as browser extension default
    let keys_lock = NOSTR_KEYS.lock().await;
    let keys = keys_lock.as_ref().context("Not initialized")?.clone();
    drop(keys_lock);

    // Encrypt with NIP-04
    let encrypted_content = nip04::encrypt(
        keys.secret_key(),
        &recipient_pubkey,
        &message,
    )?;

    let seq = if is_read_receipt_content(&message) {
        None
    } else {
        Some(next_send_seq(&recipient_pubkey.to_hex()))
    };
    // Build event manually (kind 4 encrypted DM)
    let mut builder = EventBuilder::new(Kind::EncryptedDirectMessage, encrypted_content)
        .tag(Tag::public_key(recipient_pubkey));
    if let Some(seq) = seq {
        builder = builder.tag(Tag::custom(TagKind::Custom("seq".into()), vec![seq.to_string()]));
    }
    builder = builder.tag(Tag::custom(
        TagKind::Custom(PUSHSTR_CLIENT_TAG_KIND.into()),
        vec![PUSHSTR_CLIENT_TAG_VALUE.to_string()],
    ));
    let event = builder.sign_with_keys(&keys)?;

    let event_id = event.id;
    let event_id_hex = event_id.to_hex();
    eprintln!("[dm] Sending nip04 id={}", event_id_hex);
    let mut last_err = None;
    for attempt in 1..=PUBLISH_RETRY_ATTEMPTS {
        match client.send_event(&event).await {
            Ok(_) => {
                eprintln!("[dm] NIP-04 sent id={}", event_id_hex);
                last_err = None;
                break;
            }
            Err(e) => {
                last_err = Some(e);
                eprintln!(
                    "[dm] NIP-04 send failed id={} attempt={} err={}",
                    event_id_hex, attempt, last_err.as_ref().unwrap()
                );
                if attempt < PUBLISH_RETRY_ATTEMPTS {
                    let delay_ms = PUBLISH_RETRY_BASE_MS * (1u64 << (attempt - 1));
                    tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
                }
            }
        }
    }
    if let Some(err) = last_err {
        return Err(err.into());
    }

    eprintln!("✉️ Sent NIP-04 DM (kind 4): {}", event_id);
    Ok(event_id_hex)
}

/// Send an encrypted DM using NIP-04 (kind 4) - matches browser extension default
/// recipient can be npub or hex pubkey
/// Returns event ID
#[frb(sync)]
pub fn send_dm(recipient: String, message: String) -> Result<String> {
    run_block_on(enqueue_send(SendKind::Legacy { recipient, content: message }))
}

/// Fetch recent giftwrap DMs and return as JSON array
/// Fetches kind 1059 addressed to us, unwraps inner event
/// Each message contains: id, from, to, content (plaintext), created_at, direction
#[frb(sync)]
pub fn fetch_recent_dms(limit: u64, since_timestamp: u64) -> Result<String> {
    run_block_on(async {
        let (client, keys) = get_client_and_keys().await?;

        let my_pubkey = keys.public_key();

        // Fetch giftwraps addressed to me
        let mut filter_received = Filter::new()
            .kind(Kind::GiftWrap)
            .custom_tag(SingleLetterTag::lowercase(Alphabet::P), my_pubkey.to_hex())
            .limit(limit as usize);

        // Use optional watermark to bound history
        if since_timestamp > 0 {
            filter_received = filter_received.since(Timestamp::from(since_timestamp));
        }

        let events_received = client
            .fetch_events(filter_received, std::time::Duration::from_secs(5))
            .await?;
        eprintln!(
            "[dm] fetch giftwraps: {} events",
            events_received.len()
        );

        let mut messages = Vec::new();
        let mut seen_ids: StdHashSet<String> = StdHashSet::new();
        let my_pubkey_hex = my_pubkey.to_hex();

        for event in events_received.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id) {
                continue;
            }
            match unwrap_gift_event(event, &keys) {
                Ok(unwrapped) => {
                    push_giftwrap_dm(
                        &mut messages,
                        event,
                        unwrapped,
                        &keys,
                        &my_pubkey_hex,
                    );
                }
                Err(e) => {
                    eprintln!("[dm] Failed to unwrap gift {}: {}", event.id, e);
                }
            }
        }

        // Fetch NIP-04 encrypted DMs (kind 4)
        let mut filter_nip04_in = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .custom_tag(SingleLetterTag::lowercase(Alphabet::P), my_pubkey.to_hex())
            .limit(limit as usize);
        let mut filter_nip04_out = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .author(my_pubkey)
            .limit(limit as usize);

        if since_timestamp > 0 {
            let since = Timestamp::from(since_timestamp);
            filter_nip04_in = filter_nip04_in.since(since);
            filter_nip04_out = filter_nip04_out.since(since);
        }

        let events_nip04_in = client
            .fetch_events(filter_nip04_in, std::time::Duration::from_secs(5))
            .await?;
        let events_nip04_out = client
            .fetch_events(filter_nip04_out, std::time::Duration::from_secs(5))
            .await?;
        eprintln!(
            "[dm] fetch nip04: in={}, out={}",
            events_nip04_in.len(),
            events_nip04_out.len()
        );

        for event in events_nip04_in.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id) {
                continue;
            }
            push_nip04_dm(
                &mut messages,
                event,
                &keys,
                &my_pubkey_hex,
                true,
            );
        }

        for event in events_nip04_out.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id) {
                continue;
            }
            push_nip04_dm(
                &mut messages,
                event,
                &keys,
                &my_pubkey_hex,
                false,
            );
        }

        // Sort by timestamp
        messages.sort_by(|a, b| {
            let a_time = a["created_at"].as_u64().unwrap_or(0);
            let b_time = b["created_at"].as_u64().unwrap_or(0);
            a_time.cmp(&b_time)
        });

        Ok(serde_json::to_string(&messages)?)
    })
}

/// Fetch contact display names for pubkeys from kind 0 profile metadata.
/// Returns a JSON object keyed by hex pubkey with `name` and `nip05`.
#[frb(sync)]
pub fn fetch_contact_names(pubkeys: Vec<String>) -> Result<String> {
    run_block_on(async {
        let (client, _) = get_client_and_keys().await?;
        let mut parsed = Vec::new();
        for pk in pubkeys {
            if let Ok(pubkey) = PublicKey::from_hex(&pk) {
                parsed.push((pk, pubkey));
            }
        }
        if parsed.is_empty() {
            return Ok("{}".to_string());
        }

        let filter = Filter::new()
            .kind(Kind::Metadata)
            .authors(parsed.iter().map(|(_, pubkey)| *pubkey).collect::<Vec<_>>())
            .limit(parsed.len());
        let events = client
            .fetch_events(filter, std::time::Duration::from_secs(5))
            .await?;

        let wanted: StdHashSet<String> = parsed.into_iter().map(|(hex, _)| hex).collect();
        let mut best: HashMap<String, (u64, serde_json::Value)> = HashMap::new();
        for event in events.iter() {
            let hex = event.pubkey.to_hex();
            if !wanted.contains(&hex) {
                continue;
            }
            let created = event.created_at.as_u64();
            let entry = best.entry(hex).or_insert_with(|| (0, serde_json::Value::Null));
            if created >= entry.0 {
                let parsed = serde_json::from_str::<serde_json::Value>(&event.content)
                    .unwrap_or(serde_json::Value::Null);
                entry.0 = created;
                entry.1 = parsed;
            }
        }

        let mut output = serde_json::Map::new();
        for pubkey in wanted {
            let (name, nip05) = best
                .get(&pubkey)
                .map(|(_, metadata)| {
                    let name = derive_contact_name(metadata).unwrap_or_default();
                    let nip05 = metadata
                        .get("nip05")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    (name, nip05)
                })
                .unwrap_or_else(|| (String::new(), String::new()));
            output.insert(
                pubkey,
                serde_json::json!({
                    "name": name,
                    "nip05": nip05,
                }),
            );
        }

        Ok(serde_json::Value::Object(output).to_string())
    })
}

/// Fetch older DMs before a timestamp and return as JSON array.
/// Fetches kind 1059 addressed to us, unwraps inner event.
/// Each message contains: id, from, to, content (plaintext), created_at, direction.
#[frb(sync)]
pub fn fetch_older_dms(limit: u64, until_timestamp: u64) -> Result<String> {
    run_block_on(async {
        let (client, keys) = get_client_and_keys().await?;

        let my_pubkey = keys.public_key();
        let my_pubkey_hex = my_pubkey.to_hex();

        let mut filter_received = Filter::new()
            .kind(Kind::GiftWrap)
            .custom_tag(SingleLetterTag::lowercase(Alphabet::P), my_pubkey.to_hex())
            .limit(limit as usize);

        if until_timestamp > 0 {
            filter_received = filter_received.until(Timestamp::from(until_timestamp));
        }

        let events_received = client
            .fetch_events(filter_received, std::time::Duration::from_secs(5))
            .await?;

        let mut messages = Vec::new();
        let mut seen_ids: StdHashSet<String> = StdHashSet::new();

        for event in events_received.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id) {
                continue;
            }
            match unwrap_gift_event(event, &keys) {
                Ok(unwrapped) => {
                    push_giftwrap_dm(
                        &mut messages,
                        event,
                        unwrapped,
                        &keys,
                        &my_pubkey_hex,
                    );
                }
                Err(e) => {
                    eprintln!("[dm] Failed to unwrap older gift {}: {}", event.id, e);
                }
            }
        }

        let mut filter_nip04_in = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .custom_tag(SingleLetterTag::lowercase(Alphabet::P), my_pubkey.to_hex())
            .limit(limit as usize);
        let mut filter_nip04_out = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .author(my_pubkey)
            .limit(limit as usize);

        if until_timestamp > 0 {
            let until = Timestamp::from(until_timestamp);
            filter_nip04_in = filter_nip04_in.until(until);
            filter_nip04_out = filter_nip04_out.until(until);
        }

        let events_nip04_in = client
            .fetch_events(filter_nip04_in, std::time::Duration::from_secs(5))
            .await?;
        let events_nip04_out = client
            .fetch_events(filter_nip04_out, std::time::Duration::from_secs(5))
            .await?;

        for event in events_nip04_in.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id) {
                continue;
            }
            push_nip04_dm(
                &mut messages,
                event,
                &keys,
                &my_pubkey_hex,
                true,
            );
        }

        for event in events_nip04_out.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id) {
                continue;
            }
            push_nip04_dm(
                &mut messages,
                event,
                &keys,
                &my_pubkey_hex,
                false,
            );
        }

        messages.sort_by(|a, b| {
            let a_time = a["created_at"].as_u64().unwrap_or(0);
            let b_time = b["created_at"].as_u64().unwrap_or(0);
            a_time.cmp(&b_time)
        });

        Ok(serde_json::to_string(&messages)?)
    })
}

/// Listen for new DMs and return them as JSON
/// This is a blocking call that waits for timeout_secs
/// Returns new messages that haven't been returned before
#[frb(sync)]
pub fn wait_for_new_dms(timeout_secs: u64) -> Result<String> {
    run_block_on(async {
        let (client, keys) = {
            let client_lock = NOSTR_CLIENT.lock().await;
            let keys_lock = NOSTR_KEYS.lock().await;
            (
                client_lock
                    .as_ref()
                    .context("Not initialized")?
                    .clone(),
                keys_lock.as_ref().context("Not initialized")?.clone(),
            )
        };

        let my_pubkey = keys.public_key();
        let start_time = std::time::Instant::now();
        let timeout = std::time::Duration::from_secs(timeout_secs);
        let mut messages = Vec::new();
        let mut notifications = client.notifications();

        while start_time.elapsed() < timeout {
            let notification_timeout = tokio::time::Duration::from_secs(2);
            match tokio::time::timeout(notification_timeout, notifications.recv()).await {
                Ok(Ok(RelayPoolNotification::Event { event, .. })) => {
                    eprintln!(
                        "[dm] notif event kind={} id={}",
                        event.kind.as_u16(),
                        event.id.to_hex()
                    );
                    if event.kind == Kind::GiftWrap {
                        let event_id = event.id.to_hex();

                        // Check if already returned
                        {
                            let mut returned = RETURNED_EVENT_IDS.lock().unwrap();
                            if returned.contains(&event_id) {
                                continue;
                            }
                            returned.insert(event_id.clone());

                            // Maintain bounded dedupe queue to avoid unbounded growth
                            let mut queue = RETURNED_EVENT_IDS_QUEUE.lock().unwrap();
                            queue.push_back(event_id.clone());
                            while queue.len() > RETURNED_EVENT_IDS_MAX {
                                if let Some(oldest) = queue.pop_front() {
                                    returned.remove(&oldest);
                                }
                            }
                        }

                        if let Ok(unwrapped) = unwrap_gift_event(&event, &keys) {
                            push_giftwrap_dm(
                                &mut messages,
                                &event,
                                unwrapped,
                                &keys,
                                &my_pubkey.to_hex(),
                            );
                        } else {
                            eprintln!("[dm] Giftwrap event ignored (could not unwrap) {}", event_id);
                        }
                    } else if event.kind == Kind::EncryptedDirectMessage {
                        let event_id = event.id.to_hex();

                        // Check if already returned
                        {
                            let mut returned = RETURNED_EVENT_IDS.lock().unwrap();
                            if returned.contains(&event_id) {
                                continue;
                            }
                            returned.insert(event_id.clone());

                            let mut queue = RETURNED_EVENT_IDS_QUEUE.lock().unwrap();
                            queue.push_back(event_id.clone());
                            while queue.len() > RETURNED_EVENT_IDS_MAX {
                                if let Some(oldest) = queue.pop_front() {
                                    returned.remove(&oldest);
                                }
                            }
                        }

                        let recipient_pk = match event_p_tag_pubkey(&event) {
                            Some(pk) => pk,
                            None => continue,
                        };
                        if recipient_pk != my_pubkey {
                            continue;
                        }
                        push_nip04_dm(
                            &mut messages,
                            &event,
                            &keys,
                            &my_pubkey.to_hex(),
                            true,
                        );
                    } else {
                        eprintln!(
                            "[dm] notif ignored kind={} id={}",
                            event.kind.as_u16(),
                            event.id.to_hex()
                        );
                    }
                }
                Ok(_) => {}
                Err(_) => {
                    // Timeout on this iteration, continue waiting
                }
            }

            if !messages.is_empty() {
                break;
            }
        }

        Ok(serde_json::to_string(&messages)?)
    })
}

/// Encrypt media and upload to Blossom, returning a descriptor
#[frb(sync)]
pub fn encrypt_media(bytes: Vec<u8>, recipient: String, mime: String, filename: Option<String>) -> Result<MediaDescriptor> {
    eprintln!("[encrypt_media] Starting encryption for {} bytes", bytes.len());
    // recipient is kept for API symmetry with DM sending, but file encryption uses a random per-file key.
    let _ = recipient;

    // Get current keys for Blossom auth event signing.
    let keys = run_block_on(async {
        let keys_lock = NOSTR_KEYS.lock().await;
        Ok::<Keys, anyhow::Error>(keys_lock.as_ref().context("Not initialized")?.clone())
    })?;

    // Generate random 32-byte key and 12-byte nonce for AES-GCM.
    let mut key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut key);
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);

    // Encrypt with AES-256-GCM
    use aes_gcm::aead::{Aead as _, KeyInit as _};

    let cipher = Aes256Gcm::new_from_slice(&key)?;
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce), bytes.as_ref())
        .map_err(|e| anyhow::anyhow!("Encryption failed: {e:?}"))?;

    // Hash plaintext and ciphertext
    let plain_hash = sha256_hex(&bytes)?;
    let cipher_hash = sha256_hex(&ciphertext)?;

    // Upload ciphertext to Blossom
    let url = upload_to_blossom(&ciphertext, &cipher_hash, &keys)
        .context("Failed to upload to Blossom")?;

    Ok(MediaDescriptor {
        url,
        k: general_purpose::STANDARD.encode(&key),
        nonce: general_purpose::STANDARD.encode(&nonce),
        sha256: plain_hash,
        cipher_sha256: cipher_hash,
        mime,
        size: bytes.len(),
        encryption: "aes-gcm".to_string(),
        filename,
    })
}

/// Upload unencrypted media to Blossom and return a descriptor.
#[frb(sync)]
pub fn upload_media_unencrypted(bytes: Vec<u8>, mime: String, filename: Option<String>) -> Result<MediaDescriptor> {
    let keys = run_block_on(async {
        let guard = NOSTR_KEYS.lock().await;
        if let Some(k) = guard.as_ref() {
            Ok(k.clone())
        } else {
            anyhow::bail!("Nostr not initialized. Call init_nostr first.")
        }
    })?;

    let plain_hash = sha256_hex(&bytes)?;
    let url = upload_to_blossom(&bytes, &plain_hash, &keys)
        .context("Failed to upload to Blossom")?;

    Ok(MediaDescriptor {
        url,
        k: String::new(),
        nonce: String::new(),
        sha256: plain_hash,
        cipher_sha256: String::new(),
        mime,
        size: bytes.len(),
        encryption: "none".to_string(),
        filename,
    })
}

/// Upload encrypted data to Blossom server
fn upload_to_blossom(data: &[u8], hash: &str, keys: &Keys) -> Result<String> {
    let created_at = timestamp();
    let expiration = created_at + 300; // 5 minutes

    // Create Blossom auth event
    let event = EventBuilder::new(
        Kind::Custom(24242),
        "Upload file".to_string(),
    )
    .tag(Tag::custom(TagKind::Custom("t".into()), vec!["upload"]))
    .tag(Tag::custom(TagKind::Custom("expiration".into()), vec![expiration.to_string()]))
    .tag(Tag::custom(TagKind::Custom("x".into()), vec![hash.to_string()]))
    .sign_with_keys(keys)?;

    let auth_json = serde_json::to_string(&event)?;
    let auth_header = format!("Nostr {}", general_purpose::STANDARD.encode(auth_json));

    // Upload to Blossom
    let url = format!("{}/{}", BLOSSOM_SERVER.trim_end_matches('/'), BLOSSOM_UPLOAD_PATH);
    let client = reqwest::blocking::Client::new();
    let response = client
        .put(&url)
        .header("Authorization", auth_header)
        .header("Content-Type", "application/octet-stream")
        .header("Content-Length", data.len().to_string())
        .body(data.to_vec())
        .send()?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().unwrap_or_default();
        anyhow::bail!("Upload failed ({}): {}", status, &text[..text.len().min(200)]);
    }

    // Try to get URL from response
    let location = response.headers().get("location").and_then(|v| v.to_str().ok()).map(String::from);
    let text = response.text().unwrap_or_default();

    if let Some(loc) = location {
        return Ok(loc);
    }

    // Try parsing JSON response
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
        if let Some(url) = json.get("url").and_then(|v| v.as_str()) {
            return Ok(url.to_string());
        }
    }

    // Fallback to text or construct URL
    if !text.is_empty() && text.starts_with("http") {
        Ok(text.trim().to_string())
    } else {
        Ok(format!("{}/{}", url, hash))
    }
}

/// Decrypt media descriptor to raw bytes.
///
/// Clean-break format: the descriptor contains the symmetric key + nonce, so no Nostr keys
/// (and no sender pubkey) are required for decryption.
#[frb(sync)]
pub fn decrypt_media(
    descriptor_json: String,
    sender_pubkey: String,
    my_nsec: Option<String>,
) -> Result<Vec<u8>> {
    let _ = sender_pubkey;
    let _ = my_nsec;
    let descriptor: MediaDescriptor = serde_json::from_str(&descriptor_json)?;

    // Fetch encrypted data from URL
    let resp = reqwest::blocking::get(&descriptor.url)?;
    if !resp.status().is_success() {
        anyhow::bail!("Fetch failed: {}", resp.status());
    }
    let ciphertext = resp.bytes()?.to_vec();

    // Verify cipher hash if provided
    if !descriptor.cipher_sha256.is_empty() {
        let fetched_hash = sha256_hex(&ciphertext)?;
        if fetched_hash != descriptor.cipher_sha256 {
            anyhow::bail!("Cipher hash mismatch (got {}, expected {})", fetched_hash, descriptor.cipher_sha256);
        }
    }

    // Decrypt based on encryption type
    let plaintext = if descriptor.encryption == "aes-gcm" {
        let key_bytes = general_purpose::STANDARD
            .decode(&descriptor.k)
            .context("Invalid media key")?;
        if key_bytes.len() != 32 {
            anyhow::bail!("Invalid media key length: expected 32 bytes, got {}", key_bytes.len());
        }
        let nonce_bytes = general_purpose::STANDARD
            .decode(&descriptor.nonce)
            .context("Invalid media nonce")?;
        if nonce_bytes.len() != 12 {
            anyhow::bail!(
                "Invalid media nonce length: expected 12 bytes, got {}",
                nonce_bytes.len()
            );
        }
        let cipher = Aes256Gcm::new_from_slice(&key_bytes)?;
        let nonce = Nonce::from_slice(&nonce_bytes);

        cipher.decrypt(nonce, ciphertext.as_ref())
            .map_err(|e| anyhow::anyhow!("Decryption failed: {}", e))?
    } else if descriptor.encryption == "xchacha20poly1305" {
        let key_bytes = general_purpose::STANDARD
            .decode(&descriptor.k)
            .context("Invalid media key")?;
        if key_bytes.len() != 32 {
            anyhow::bail!("Invalid media key length: expected 32 bytes, got {}", key_bytes.len());
        }
        let nonce_bytes = general_purpose::STANDARD
            .decode(&descriptor.nonce)
            .context("Invalid media nonce")?;
        if nonce_bytes.len() != 24 {
            anyhow::bail!(
                "Invalid media nonce length: expected 24 bytes, got {}",
                nonce_bytes.len()
            );
        }
        use chacha20poly1305::aead::{Aead as _, KeyInit as _};
        use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};

        let cipher = XChaCha20Poly1305::new(Key::from_slice(&key_bytes));
        let nonce = XNonce::from_slice(&nonce_bytes);

        cipher.decrypt(nonce, ciphertext.as_ref())
            .map_err(|e| anyhow::anyhow!("Decryption failed: {}", e))?
    } else {
        anyhow::bail!("Unsupported encryption type: {}", descriptor.encryption);
    };

    // Verify plaintext hash if provided
    if !descriptor.sha256.is_empty() {
        let hash = sha256_hex(&plaintext)?;
        if hash != descriptor.sha256 {
            anyhow::bail!("Attachment hash mismatch (got {}, expected {})", hash, descriptor.sha256);
        }
    }

    Ok(plaintext)
}

fn sha256_hex(bytes: &[u8]) -> Result<String> {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(hex::encode(hasher.finalize()))
}

fn timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Clear the cache of returned event IDs
#[frb(sync)]
pub fn clear_returned_events_cache() -> Result<()> {
    let set_res = RETURNED_EVENT_IDS.lock();
    let queue_res = RETURNED_EVENT_IDS_QUEUE.lock();
    match (set_res, queue_res) {
        (Ok(mut set), Ok(mut queue)) => {
            set.clear();
            queue.clear();
            Ok(())
        }
        (Err(e), _) => Err(anyhow::anyhow!("Failed to clear cache set: {}", e)),
        (_, Err(e)) => Err(anyhow::anyhow!("Failed to clear cache queue: {}", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{sleep, timeout, Duration};

    async fn make_client(keys: &Keys, relays: &[&str]) -> Result<Client> {
        let client = Client::new(keys.clone());
        for relay in relays {
            let _ = client.add_relay((*relay).to_string()).await;
        }
        client.connect().await;
        Ok(client)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore]
    async fn nip17_websocket_roundtrip_smoke() -> Result<()> {
        let sender_keys = Keys::generate();
        let recipient_keys = Keys::generate();
        let recipient_hex = recipient_keys.public_key().to_hex();
        let sender_hex = sender_keys.public_key().to_hex();

        let recipient_client = make_client(&recipient_keys, DM_RELAYS).await?;
        let sender_client = make_client(&sender_keys, DM_RELAYS).await?;

        let mut relay_builder = EventBuilder::new(Kind::Custom(10050), "");
        for relay in DM_RELAYS {
            relay_builder = relay_builder.tag(Tag::custom(
                TagKind::Custom("relay".into()),
                vec![relay.to_string()],
            ));
        }
        relay_builder = relay_builder.tag(Tag::custom(
            TagKind::Custom("alt".into()),
            vec!["Relay list to receive private messages".to_string()],
        ));
        let relay_event = relay_builder.sign_with_keys(&recipient_keys)?;
        recipient_client.send_event(&relay_event).await?;

        sleep(Duration::from_secs(2)).await;
        ensure_recipient_dm_relays(&sender_client, &recipient_keys.public_key()).await?;

        let inner_event = EventBuilder::new(Kind::Custom(14), "relay smoke test")
            .tag(Tag::custom(
                TagKind::Custom("p".into()),
                vec![recipient_hex.clone()],
            ))
            .tag(Tag::custom(
                TagKind::Custom("alt".into()),
                vec!["Direct message".to_string()],
            ))
            .tag(Tag::custom(
                TagKind::Custom(PUSHSTR_CLIENT_TAG_KIND.into()),
                vec![PUSHSTR_CLIENT_TAG_VALUE.to_string()],
            ))
            .sign_with_keys(&sender_keys)?;

        let gift = wrap_gift_event(&inner_event, recipient_keys.public_key(), &sender_keys)?;
        let filter = Filter::new()
            .kind(Kind::GiftWrap)
            .custom_tag(
                SingleLetterTag::lowercase(Alphabet::P),
                recipient_hex.clone(),
            );
        recipient_client.subscribe(filter, None).await?;
        let mut notifications = recipient_client.notifications();

        sender_client.send_event(&gift).await?;

        let got_event = timeout(Duration::from_secs(20), async {
            loop {
                match notifications.recv().await {
                    Ok(RelayPoolNotification::Event { event, .. }) if event.kind == Kind::GiftWrap => {
                        return event;
                    }
                    Ok(_) => continue,
                    Err(_) => continue,
                }
            }
        })
        .await
        .context("timed out waiting for giftwrap notification")?;

        let unwrapped = unwrap_gift_event(&got_event, &recipient_keys)?;
        assert_eq!(unwrapped.rumor.content.as_deref(), Some("relay smoke test"));
        assert_eq!(unwrapped.rumor.pubkey.as_deref(), Some(sender_hex.as_str()));
        Ok(())
    }
}
