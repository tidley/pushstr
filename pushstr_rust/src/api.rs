#![allow(unexpected_cfgs)]

use anyhow::{Context, Result};
use base64::{engine::general_purpose, Engine as _};
use flutter_rust_bridge::frb;
use nostr_sdk::nips::nip04;
use nostr_sdk::prelude::*;
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use flate2::{write::GzEncoder, read::GzDecoder, Compression};
use std::io::{Read, Write};
use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::Mutex;
use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use secp256k1::{PublicKey as Secp256k1PublicKey, SecretKey as Secp256k1SecretKey, XOnlyPublicKey as Secp256k1XOnlyPublicKey, Secp256k1 as Secp256k1Context};
use ::hkdf::Hkdf;
use getrandom;
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb(non_opaque)]
pub struct MediaDescriptor {
    pub url: String,
    pub iv: String,
    pub sha256: String,
    pub cipher_sha256: String,
    pub mime: String,
    pub size: usize,
    pub encryption: String,
    pub filename: Option<String>,
}

// Blossom server configuration
const BLOSSOM_SERVER: &str = "https://blossom.primal.net";
const BLOSSOM_UPLOAD_PATH: &str = "upload";

fn parse_pubkey(input: &str) -> Result<PublicKey> {
    PublicKey::from_bech32(input).or_else(|_| PublicKey::from_hex(input)).context("Invalid pubkey")
}

fn event_p_tag_pubkey(event: &Event) -> Option<PublicKey> {
    event
        .tags
        .iter()
        .find(|t| t.kind() == TagKind::p())
        .and_then(|t| t.content())
        .and_then(|s| PublicKey::from_hex(s).ok())
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
}

fn random_timestamp_within_two_days() -> Timestamp {
    let now = Timestamp::now();
    let two_days_secs = 2 * 24 * 60 * 60;
    let earliest = now.as_u64().saturating_sub(two_days_secs);
    let span = now.as_u64().saturating_sub(earliest).max(1);
    let random_offset = rand::random::<u64>() % span;
    Timestamp::from(earliest + random_offset)
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

// Helper function to derive NIP-44 conversation key
fn get_nip44_conversation_key(secret_key: &SecretKey, public_key: &PublicKey) -> Result<String> {
    let secp = Secp256k1Context::new();

    // Convert nostr-sdk keys to secp256k1 keys
    let secret_bytes = secret_key.secret_bytes();
    let secp_secret = Secp256k1SecretKey::from_slice(&secret_bytes)?;

    // Parse x-only public key (32 bytes)
    let public_bytes = public_key.to_bytes();
    let xonly_pubkey = Secp256k1XOnlyPublicKey::from_slice(&public_bytes)?;

    // Compute shared point: multiply other's pubkey by our privkey
    let public_key_even = Secp256k1PublicKey::from_x_only_public_key(xonly_pubkey, secp256k1::Parity::Even);
    let shared_point = public_key_even.mul_tweak(&secp, &secp_secret.into())?;

    // Get x-coordinate of shared point (first 32 bytes after dropping the prefix byte)
    let shared_bytes = shared_point.serialize_uncompressed();
    let shared_x = &shared_bytes[1..33];

    // Derive conversation key using HKDF-SHA256
    let hkdf = Hkdf::<Sha256>::new(None, shared_x);
    let mut conversation_key = [0u8; 32];
    hkdf.expand(b"nip44-v2", &mut conversation_key)
        .map_err(|e| anyhow::anyhow!("HKDF failed: {}", e))?;

    Ok(hex::encode(conversation_key))
}

// Custom NIP-44 v2 encrypt that matches WASM implementation exactly
fn nip44_encrypt_custom(secret_key: &SecretKey, public_key: &PublicKey, plaintext: &str) -> Result<String> {
    use chacha20poly1305::{ChaCha20Poly1305 as ChaCha, KeyInit as ChaChaKeyInit, AeadInPlace};

    // Get conversation key
    let conv_key_hex = get_nip44_conversation_key(secret_key, public_key)?;
    let conv_key = hex::decode(&conv_key_hex)?;

    // Generate random 32-byte nonce
    let mut nonce = [0u8; 32];
    getrandom::getrandom(&mut nonce)?;

    // Derive encryption key and AAD using HKDF
    let hkdf = Hkdf::<Sha256>::new(Some(&nonce), &conv_key);
    let mut chacha_key = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-key", &mut chacha_key)
        .map_err(|e| anyhow::anyhow!("HKDF chacha key failed: {}", e))?;
    let mut aad = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-aad", &mut aad)
        .map_err(|e| anyhow::anyhow!("HKDF aad failed: {}", e))?;

    // Encrypt with ChaCha20-Poly1305
    let cipher = ChaCha::new(chacha_key.as_ref().into());
    let chacha_nonce = chacha20poly1305::Nonce::from_slice(&[0u8; 12]); // NIP-44 uses all-zero nonce

    let mut buffer = plaintext.as_bytes().to_vec();
    cipher.encrypt_in_place(chacha_nonce, &aad, &mut buffer)
        .map_err(|e| anyhow::anyhow!("Encryption failed: {}", e))?;

    // Construct payload: version (1) || nonce (32) || ciphertext+mac
    let mut payload = Vec::with_capacity(1 + 32 + buffer.len());
    payload.push(0x02); // version
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&buffer);

    Ok(base64::engine::general_purpose::STANDARD.encode(&payload))
}

// Custom NIP-44 v2 decrypt that matches WASM implementation exactly
fn nip44_decrypt_custom(secret_key: &SecretKey, public_key: &PublicKey, ciphertext_b64: &str) -> Result<String> {
    use chacha20poly1305::{ChaCha20Poly1305 as ChaCha, KeyInit as ChaChaKeyInit, AeadInPlace};

    // Get conversation key
    let conv_key_hex = get_nip44_conversation_key(secret_key, public_key)?;
    let conv_key = hex::decode(&conv_key_hex)?;

    // Decode base64
    let payload = base64::engine::general_purpose::STANDARD.decode(ciphertext_b64)?;

    // Check minimum size: version (1) + nonce (32) + mac (16) = 49 bytes
    if payload.len() < 49 {
        anyhow::bail!("ciphertext too short");
    }

    // Check version
    if payload[0] != 0x02 {
        anyhow::bail!("unsupported version: {}", payload[0]);
    }

    // Extract nonce and ciphertext+mac
    let nonce = &payload[1..33];
    let ciphertext_with_mac = &payload[33..];

    // Derive decryption key and AAD using HKDF
    let hkdf = Hkdf::<Sha256>::new(Some(nonce), &conv_key);
    let mut chacha_key = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-key", &mut chacha_key)
        .map_err(|e| anyhow::anyhow!("HKDF chacha key failed: {}", e))?;
    let mut aad = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-aad", &mut aad)
        .map_err(|e| anyhow::anyhow!("HKDF aad failed: {}", e))?;

    // Decrypt with ChaCha20-Poly1305
    let cipher = ChaCha::new(chacha_key.as_ref().into());
    let chacha_nonce = chacha20poly1305::Nonce::from_slice(&[0u8; 12]); // NIP-44 uses all-zero nonce

    let mut buffer = ciphertext_with_mac.to_vec();
    cipher.decrypt_in_place(chacha_nonce, &aad, &mut buffer)
        .map_err(|e| anyhow::anyhow!("Decryption failed: {}", e))?;

    String::from_utf8(buffer).map_err(|e| anyhow::anyhow!("Invalid UTF-8: {}", e))
}

fn wrap_gift_event(inner_event: &Event, recipient_pk: PublicKey, _use_nip44: bool) -> Result<Event> {
    // Build Rumor JSON from inner event (drop signature to match Amethyst).
    let mut rumor_value = serde_json::to_value(inner_event)?;
    if let serde_json::Value::Object(obj) = &mut rumor_value {
        obj.remove("sig");
    }
    let rumor_json = serde_json::to_string(&rumor_value)?;

    // Sealed rumor (kind 13), signed by sender, encrypted to recipient.
    let keys = {
        let guard = RUNTIME.block_on(async { NOSTR_KEYS.lock().await });
        guard
            .as_ref()
            .context("Nostr not initialized. Call init_nostr first.")?
            .clone()
    };
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
        .tag(Tag::public_key(recipient_pk));
    let gift = builder.sign_with_keys(&wrapper_keys)?;
    Ok(gift)
}

fn unwrap_gift_event(gift_event: &Event, keys: &Keys) -> Result<UnwrappedGift> {
    if gift_event.kind != Kind::GiftWrap {
        anyhow::bail!("Event is not kind 1059");
    }

    // Debug: Log conversation key
    let conv_key = get_nip44_conversation_key(keys.secret_key(), &gift_event.pubkey)
        .unwrap_or_else(|_| "ERROR".to_string());
    eprintln!("[mobile] Giftwrap decrypt - myPriv: {}... wrapperPub: {}...",
        hex::encode(keys.secret_key().secret_bytes()).chars().take(8).collect::<String>(),
        gift_event.pubkey.to_hex().chars().take(16).collect::<String>());
    eprintln!("[mobile] Giftwrap decrypt - convKey: {}...", conv_key.chars().take(16).collect::<String>());

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
        Ok(UnwrappedGift {
            rumor,
            sender_pubkey: sealed_event.pubkey.to_hex(),
            created_at,
        })
    } else {
        let mut event_value = serde_json::to_value(&sealed_event)?;
        if let serde_json::Value::Object(obj) = &mut event_value {
            obj.remove("sig");
        }
        let rumor: RumorData = serde_json::from_value(event_value)?;
        let created_at = rumor.created_at.unwrap_or_else(|| sealed_event.created_at.as_u64());
        Ok(UnwrappedGift {
            rumor,
            sender_pubkey: sealed_event.pubkey.to_hex(),
            created_at,
        })
    }
}

// Default relay configuration
const RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.snort.social",
    "wss://offchain.pub",
];

/// Initialize the Nostr service with a secret key (nsec)
/// If nsec is empty, generates a new key
/// Returns npub
#[frb(sync)]
pub fn init_nostr(nsec: String) -> Result<String> {
    RUNTIME.block_on(async {
        let keys = if nsec.is_empty() {
            Keys::generate()
        } else {
            Keys::parse(&nsec).context("Invalid nsec format")?
        };

        let client = Client::new(keys.clone());

        // Add relays
        for relay in RELAYS {
            client.add_relay(*relay).await?;
        }

        client.connect().await;
        eprintln!("🔌 Client connected to relays");

        // Wait a bit for connection to establish
        tokio::time::sleep(tokio::time::Duration::from_millis(1000)).await;

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
    RUNTIME.block_on(async {
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
    RUNTIME.block_on(async {
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

/// Send a giftwrapped DM (kind 1059 wrapping kind 4) using nip44 by default
#[frb(sync)]
pub fn send_gift_dm(recipient: String, content: String, use_nip44: bool) -> Result<String> {
    RUNTIME.block_on(async {
        let (client, keys) = get_client_and_keys().await?;
        let recipient_pk = parse_pubkey(&recipient)?;

        // NIP-17: Inner DM with plaintext content, signed by user - kind 14
        let inner_event = EventBuilder::new(Kind::Custom(14), content)
            .tag(Tag::public_key(recipient_pk))
            .sign_with_keys(&keys)?;

        let gift = wrap_gift_event(&inner_event, recipient_pk, use_nip44)?;
        let event_id = gift.id.to_hex();
        client.send_event(&gift).await?;
        Ok(event_id)
    })
}

/// Wrap a NIP-17 giftwrap from a provided inner event JSON
#[frb(sync)]
pub fn wrap_gift(inner_json: String, recipient: String, use_nip44: bool) -> Result<String> {
    let inner_event: Event =
        serde_json::from_str(&inner_json).context("inner_json must be a valid Nostr event JSON")?;
    let recipient_pk = parse_pubkey(&recipient)?;
    let gift = wrap_gift_event(&inner_event, recipient_pk, use_nip44)?;
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
        let guard = RUNTIME.block_on(async { NOSTR_KEYS.lock().await });
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
    let pubkey = PublicKey::from_bech32(&npub)?;
    Ok(pubkey.to_hex())
}

/// Convert hex pubkey to npub
#[frb(sync)]
pub fn hex_to_npub(hex: String) -> Result<String> {
    let pubkey = PublicKey::from_hex(&hex)?;
    Ok(pubkey.to_bech32()?)
}

/// Send an encrypted DM using NIP-04 (kind 4) - matches browser extension default
/// recipient can be npub or hex pubkey
/// Returns event ID
#[frb(sync)]
pub fn send_dm(recipient: String, message: String) -> Result<String> {
    RUNTIME.block_on(async {
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

        // Build event manually (kind 4 encrypted DM)
        let event = EventBuilder::new(Kind::EncryptedDirectMessage, encrypted_content)
            .tag(Tag::public_key(recipient_pubkey))
            .sign_with_keys(&keys)?;

        let event_id = event.id;
        client.send_event(&event).await?;

        eprintln!("✉️ Sent NIP-04 DM (kind 4): {}", event_id);
        Ok(event_id.to_hex())
    })
}

/// Fetch recent giftwrap DMs and return as JSON array
/// Fetches kind 1059 addressed to us, unwraps inner event
/// Each message contains: id, from, to, content (plaintext), created_at, direction
#[frb(sync)]
pub fn fetch_recent_dms(limit: u64, since_timestamp: u64) -> Result<String> {
    RUNTIME.block_on(async {
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

        let mut messages = Vec::new();
        let mut seen_ids: StdHashSet<String> = StdHashSet::new();

        for event in events_received.iter() {
            match unwrap_gift_event(event, &keys) {
                Ok(unwrapped) => {
                    let event_id = event.id.to_hex();
                    if !seen_ids.insert(event_id.clone()) {
                        continue;
                    }
                    let sender_hex = unwrapped
                        .rumor
                        .pubkey
                        .clone()
                        .unwrap_or_else(|| unwrapped.sender_pubkey.clone());
                    let direction = if sender_hex == my_pubkey.to_hex() { "out" } else { "in" };
                    let tags = unwrapped.rumor.tags.clone().unwrap_or_default();
                    let other = if direction == "out" {
                        tags
                            .iter()
                            .find(|t| t.first().map(|v| v == "p").unwrap_or(false))
                            .and_then(|t| t.get(1))
                            .cloned()
                            .unwrap_or_default()
                    } else {
                        sender_hex.clone()
                    };
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

                    messages.push(serde_json::json!({
                        "id": event_id,
                        "from": if direction == "out" { my_pubkey.to_hex() } else { sender_hex },
                        "to": if direction == "out" { other } else { my_pubkey.to_hex() },
                        "content": content,
                        "created_at": unwrapped.created_at,
                        "direction": direction,
                        "kind": 1059,
                        "dm_kind": "nip17",
                    }));
                }
                Err(e) => {
                    eprintln!("Failed to unwrap gift {}: {}", event.id, e);
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

        for event in events_nip04_in.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id.clone()) {
                continue;
            }
            let decrypted = nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content)
                .unwrap_or_else(|_| event.content.clone());
            messages.push(serde_json::json!({
                "id": event_id,
                "from": event.pubkey.to_hex(),
                "to": my_pubkey.to_hex(),
                "content": decrypted,
                "created_at": event.created_at.as_u64(),
                "direction": "in",
                "kind": 4,
                "dm_kind": "nip04",
            }));
        }

        for event in events_nip04_out.iter() {
            let event_id = event.id.to_hex();
            if !seen_ids.insert(event_id.clone()) {
                continue;
            }
            let recipient_pk = match event_p_tag_pubkey(event) {
                Some(pk) => pk,
                None => continue,
            };
            let decrypted = nip04::decrypt(keys.secret_key(), &recipient_pk, &event.content)
                .unwrap_or_else(|_| event.content.clone());
            messages.push(serde_json::json!({
                "id": event_id,
                "from": my_pubkey.to_hex(),
                "to": recipient_pk.to_hex(),
                "content": decrypted,
                "created_at": event.created_at.as_u64(),
                "direction": "out",
                "kind": 4,
                "dm_kind": "nip04",
            }));
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

/// Listen for new DMs and return them as JSON
/// This is a blocking call that waits for timeout_secs
/// Returns new messages that haven't been returned before
#[frb(sync)]
pub fn wait_for_new_dms(timeout_secs: u64) -> Result<String> {
    RUNTIME.block_on(async {
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
                            let sender_hex = unwrapped
                                .rumor
                                .pubkey
                                .clone()
                                .unwrap_or_else(|| unwrapped.sender_pubkey.clone());
                            let mut content = unwrapped.rumor.content.clone().unwrap_or_default();
                            if !content.is_empty() {
                                if let Ok(sender_pk) = PublicKey::from_hex(&sender_hex) {
                                    content = nip44_decrypt_custom(keys.secret_key(), &sender_pk, &content)
                                        .unwrap_or(content);
                                }
                            }
                            messages.push(serde_json::json!({
                                "id": event_id,
                                "from": sender_hex,
                                "to": my_pubkey.to_hex(),
                                "content": content,
                                "created_at": unwrapped.created_at,
                                "direction": "in",
                                "kind": 1059,
                                "dm_kind": "nip17",
                            }));
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

                        let decrypted = nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content)
                            .unwrap_or_else(|_| event.content.clone());

                        messages.push(serde_json::json!({
                            "id": event_id,
                            "from": event.pubkey.to_hex(),
                            "to": my_pubkey.to_hex(),
                            "content": decrypted,
                            "created_at": event.created_at.as_u64(),
                            "direction": "in",
                            "kind": 4,
                            "dm_kind": "nip04",
                        }));
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
    let recipient_pk = parse_pubkey(&recipient)
        .context(format!("Failed to parse recipient: {}", recipient))?;
    eprintln!("[encrypt_media] Parsed recipient pubkey");

    // Get current keys for conversation key derivation
    let keys = RUNTIME.block_on(async {
        let keys_lock = NOSTR_KEYS.lock().await;
        Ok::<Keys, anyhow::Error>(keys_lock.as_ref().context("Not initialized")?.clone())
    })?;
    eprintln!("[encrypt_media] Got current keys");

    // Derive shared secret using NIP-44's conversation key (32 bytes)
    let conversation_key_hex = get_nip44_conversation_key(keys.secret_key(), &recipient_pk)
        .context("Failed to derive conversation key")?;
    eprintln!("[encrypt_media] Derived conversation key (len: {})", conversation_key_hex.len());

    let key_bytes = hex::decode(&conversation_key_hex)
        .context("Failed to decode conversation key hex")?;

    if key_bytes.len() != 32 {
        anyhow::bail!("Conversation key must be 32 bytes, got {}", key_bytes.len());
    }
    eprintln!("[encrypt_media] Key bytes decoded: {} bytes", key_bytes.len());

    // Generate random 12-byte IV for AES-GCM
    let mut iv = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut iv);
    eprintln!("[encrypt_media] Generated IV");

    // Encrypt with AES-GCM (no size limit)
    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|e| anyhow::anyhow!("Failed to create cipher: {}", e))?;
    let nonce = Nonce::from_slice(&iv);
    let ciphertext = cipher.encrypt(nonce, bytes.as_ref())
        .map_err(|e| anyhow::anyhow!("Encryption failed: {}", e))?;
    eprintln!("[encrypt_media] Encrypted: {} bytes", ciphertext.len());

    // Hash plaintext and ciphertext
    let plain_hash = sha256_hex(&bytes)?;
    let cipher_hash = sha256_hex(&ciphertext)?;
    eprintln!("[encrypt_media] Hashed plain and cipher");

    // Upload to Blossom
    let url = upload_to_blossom(&ciphertext, &cipher_hash, &keys)
        .context("Failed to upload to Blossom")?;
    eprintln!("[encrypt_media] Uploaded to: {}", url);

    Ok(MediaDescriptor {
        url,
        iv: general_purpose::STANDARD.encode(&iv),
        sha256: plain_hash,
        cipher_sha256: cipher_hash,
        mime,
        size: bytes.len(),
        encryption: "aes-gcm".to_string(),
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

/// Decrypt media descriptor to raw bytes using provided or current key
/// sender_pubkey: hex or npub of the message sender (for deriving shared secret)
#[frb(sync)]
pub fn decrypt_media(descriptor_json: String, sender_pubkey: String, my_nsec: Option<String>) -> Result<Vec<u8>> {
    let descriptor: MediaDescriptor = serde_json::from_str(&descriptor_json)?;
    let keys = if let Some(nsec) = my_nsec {
        Keys::parse(&nsec)?
    } else {
        let guard = RUNTIME.block_on(async { NOSTR_KEYS.lock().await });
        if let Some(k) = guard.as_ref() {
            k.clone()
        } else {
            anyhow::bail!("Nostr not initialized. Call init_nostr first.")
        }
    };

    let sender_pk = parse_pubkey(&sender_pubkey)?;

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
        // Derive shared secret using NIP-44's conversation key
        let conversation_key_hex = get_nip44_conversation_key(keys.secret_key(), &sender_pk)?;
        let key_bytes = hex::decode(&conversation_key_hex)?;

        let iv_bytes = general_purpose::STANDARD.decode(&descriptor.iv)?;
        let cipher = Aes256Gcm::new_from_slice(&key_bytes)?;
        let nonce = Nonce::from_slice(&iv_bytes);

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

fn gzip_bytes(data: &[u8]) -> Result<Vec<u8>> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(data)?;
    let compressed = encoder.finish()?;
    Ok(compressed)
}

fn gunzip_bytes(data: &[u8]) -> Result<Vec<u8>> {
    if data.len() > 2 && data[0] == 0x1f && data[1] == 0x8b {
        let mut decoder = GzDecoder::new(data);
        let mut out = Vec::new();
        decoder.read_to_end(&mut out)?;
        return Ok(out);
    } else {
        return Ok(data.to_vec());
    }
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
