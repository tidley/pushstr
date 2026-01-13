use aes_gcm::{aead::{Aead, KeyInit, generic_array::GenericArray}, Aes256Gcm, Nonce};
use sha2::{Digest, Sha256};
use wasm_bindgen::prelude::*;
use secp256k1::{XOnlyPublicKey, SecretKey, PublicKey, Secp256k1};
use hkdf::Hkdf;
use chacha20::cipher::{KeyIvInit, StreamCipher};
use hmac::{Hmac, Mac};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use hex;

#[wasm_bindgen]
pub fn encrypt_aes_gcm(key: &[u8], iv: &[u8], plaintext: &[u8]) -> Result<Box<[u8]>, JsValue> {
    if key.len() != 32 {
        return Err(JsValue::from_str("key must be 32 bytes"));
    }
    if iv.len() != 12 {
        return Err(JsValue::from_str("iv must be 12 bytes"));
    }
    let cipher = Aes256Gcm::new(GenericArray::from_slice(key));
    let nonce = Nonce::from_slice(iv);
    cipher
        .encrypt(nonce, plaintext)
        .map(|v| v.into_boxed_slice())
        .map_err(|e| JsValue::from_str(&format!("encrypt failed: {e}")))
}

#[wasm_bindgen]
pub fn decrypt_aes_gcm(key: &[u8], iv: &[u8], ciphertext: &[u8]) -> Result<Box<[u8]>, JsValue> {
    if key.len() != 32 {
        return Err(JsValue::from_str("key must be 32 bytes"));
    }
    if iv.len() != 12 {
        return Err(JsValue::from_str("iv must be 12 bytes"));
    }
    let cipher = Aes256Gcm::new(GenericArray::from_slice(key));
    let nonce = Nonce::from_slice(iv);
    cipher
        .decrypt(nonce, ciphertext)
        .map(|v| v.into_boxed_slice())
        .map_err(|e| JsValue::from_str(&format!("decrypt failed: {e}")))
}

#[wasm_bindgen]
pub fn sha256_bytes(data: &[u8]) -> Box<[u8]> {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().to_vec().into_boxed_slice()
}

// NIP-44 v2 Implementation

type HmacSha256 = Hmac<Sha256>;

fn hmac_sha256(key: &[u8; 32], parts: &[&[u8]]) -> Result<[u8; 32], JsValue> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key)
        .map_err(|e| JsValue::from_str(&format!("HMAC init failed: {e}")))?;
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

fn nip44_pad(plaintext: &str) -> Result<Vec<u8>, JsValue> {
    let unpadded = plaintext.as_bytes();
    let unpadded_len = unpadded.len();
    if unpadded_len == 0 {
        return Err(JsValue::from_str("Message is empty"));
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
        return Err(JsValue::from_str("Message is too long"));
    }

    let padded_len = nip44_calc_padded_len(unpadded_len);
    let mut out = Vec::with_capacity(prefix.len() + padded_len);
    out.extend_from_slice(&prefix);
    out.extend_from_slice(unpadded);
    out.resize(prefix.len() + padded_len, 0u8);
    Ok(out)
}

fn nip44_unpad(padded: &[u8]) -> Result<String, JsValue> {
    if padded.len() < 2 {
        return Err(JsValue::from_str("Invalid padded payload"));
    }
    let len_pre = ((padded[0] as usize) << 8) | padded[1] as usize;
    if len_pre == 0 {
        if padded.len() < 6 {
            return Err(JsValue::from_str("Invalid extended padding"));
        }
        let len_ext = ((padded[2] as usize) << 24)
            | ((padded[3] as usize) << 16)
            | ((padded[4] as usize) << 8)
            | (padded[5] as usize);
        if len_ext == 0 || len_ext > 0xFFFF_FFFE {
            return Err(JsValue::from_str("Invalid size"));
        }
        let expected = 6 + nip44_calc_padded_len(len_ext);
        if padded.len() != expected {
            return Err(JsValue::from_str("Invalid padding"));
        }
        return String::from_utf8(padded[6..6 + len_ext].to_vec())
            .map_err(|e| JsValue::from_str(&format!("Invalid UTF-8: {e}")));
    }
    if len_pre > 0xFFFF {
        return Err(JsValue::from_str("Invalid size"));
    }
    let expected = 2 + nip44_calc_padded_len(len_pre);
    if padded.len() != expected {
        return Err(JsValue::from_str("Invalid padding"));
    }
    String::from_utf8(padded[2..2 + len_pre].to_vec())
        .map_err(|e| JsValue::from_str(&format!("Invalid UTF-8: {e}")))
}

fn nip44_hmac_aad(key: &[u8; 32], message: &[u8], aad: &[u8; 32]) -> Result<[u8; 32], JsValue> {
    hmac_sha256(key, &[aad, message])
}

struct Nip44MessageKeys {
    chacha_key: [u8; 32],
    chacha_nonce: [u8; 12],
    hmac_key: [u8; 32],
}

fn nip44_fast_expand(
    conversation_key: &[u8; 32],
    nonce: &[u8; 32],
    ciphertext: Option<&[u8]>,
    mac: Option<&[u8]>,
) -> Result<Nip44MessageKeys, JsValue> {
    let round1 = hmac_sha256(conversation_key, &[nonce, &[1u8]])?;
    let round2 = hmac_sha256(conversation_key, &[&round1, nonce, &[2u8]])?;
    let round3 = hmac_sha256(conversation_key, &[&round2, nonce, &[3u8]])?;

    let mut hmac_key = [0u8; 32];
    hmac_key[0..20].copy_from_slice(&round2[12..32]);
    hmac_key[20..32].copy_from_slice(&round3[0..12]);

    if let (Some(ciphertext), Some(mac)) = (ciphertext, mac) {
        if mac.len() != 32 {
            return Err(JsValue::from_str("Invalid mac length"));
        }
        let calc = nip44_hmac_aad(&hmac_key, ciphertext, nonce)?;
        if calc.as_ref() != mac {
            return Err(JsValue::from_str("Invalid Mac"));
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

/// Derives the conversation key from a private key and public key using ECDH + HKDF
/// Returns hex-encoded 32-byte conversation key
#[wasm_bindgen]
pub fn nip44_get_conversation_key(privkey_hex: &str, pubkey_hex: &str) -> Result<String, JsValue> {
    let secp = Secp256k1::new();

    // Parse secret key
    let secret_key = SecretKey::from_slice(
        &hex::decode(privkey_hex).map_err(|e| JsValue::from_str(&format!("Invalid private key hex: {}", e)))?
    ).map_err(|e| JsValue::from_str(&format!("Invalid private key: {}", e)))?;

    // Parse x-only public key (32 bytes)
    let pubkey_bytes = hex::decode(pubkey_hex)
        .map_err(|e| JsValue::from_str(&format!("Invalid public key hex: {}", e)))?;
    let xonly_pubkey = XOnlyPublicKey::from_slice(&pubkey_bytes)
        .map_err(|e| JsValue::from_str(&format!("Invalid public key: {}", e)))?;

    // Compute shared point: multiply other's pubkey by our privkey
    // Use both parities and take the x-coordinate (same for both)
    let public_key_even = PublicKey::from_x_only_public_key(xonly_pubkey, secp256k1::Parity::Even);
    let mut shared_point = public_key_even.clone();
    shared_point = shared_point.mul_tweak(&secp, &secret_key.into())
        .map_err(|e| JsValue::from_str(&format!("ECDH multiplication failed: {}", e)))?;

    // Get x-coordinate of shared point (first 32 bytes after dropping the prefix byte)
    let shared_bytes = shared_point.serialize_uncompressed();
    let shared_x = &shared_bytes[1..33];

    // Derive conversation key using HKDF-SHA256 extract with nip44-v2 salt
    let (prk, _) = Hkdf::<Sha256>::extract(Some(b"nip44-v2"), shared_x);
    let mut conversation_key = [0u8; 32];
    conversation_key.copy_from_slice(&prk[..]);
    Ok(hex::encode(conversation_key))
}

/// Encrypts plaintext using NIP-44 v2
/// Returns base64-encoded ciphertext with version prefix
#[wasm_bindgen]
pub fn nip44_encrypt(conversation_key_hex: &str, plaintext: &str) -> Result<String, JsValue> {
    // Parse conversation key
    let key_bytes = hex::decode(conversation_key_hex)
        .map_err(|e| JsValue::from_str(&format!("Invalid conversation key hex: {}", e)))?;
    if key_bytes.len() != 32 {
        return Err(JsValue::from_str("conversation key must be 32 bytes"));
    }
    let mut conv_key = [0u8; 32];
    conv_key.copy_from_slice(&key_bytes);

    // Generate random nonce (32 bytes for NIP-44 v2)
    let mut nonce = [0u8; 32];
    getrandom::getrandom(&mut nonce)
        .map_err(|e| JsValue::from_str(&format!("Failed to generate nonce: {}", e)))?;

    let keys = nip44_fast_expand(&conv_key, &nonce, None, None)?;
    let mut buffer = nip44_pad(plaintext)?;
    let mut cipher = chacha20::ChaCha20::new((&keys.chacha_key).into(), (&keys.chacha_nonce).into());
    cipher.apply_keystream(&mut buffer);
    let mac = nip44_hmac_aad(&keys.hmac_key, &buffer, &nonce)?;

    // Construct payload: version (1) || nonce (32) || ciphertext || mac (32)
    let mut payload = Vec::with_capacity(1 + 32 + buffer.len() + 32);
    payload.push(0x02); // version
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&buffer);
    payload.extend_from_slice(&mac);

    Ok(BASE64.encode(&payload))
}

/// Decrypts NIP-44 v2 ciphertext
/// Returns decrypted plaintext string
#[wasm_bindgen]
pub fn nip44_decrypt(conversation_key_hex: &str, ciphertext_b64: &str) -> Result<String, JsValue> {
    // Parse conversation key
    let key_bytes = hex::decode(conversation_key_hex)
        .map_err(|e| JsValue::from_str(&format!("Invalid conversation key hex: {}", e)))?;
    if key_bytes.len() != 32 {
        return Err(JsValue::from_str("conversation key must be 32 bytes"));
    }

    // Decode base64
    let payload = BASE64.decode(ciphertext_b64)
        .map_err(|e| JsValue::from_str(&format!("Invalid base64: {}", e)))?;

    // Check minimum size: version (1) + nonce (32) + mac (32)
    if payload.len() < 65 {
        return Err(JsValue::from_str("ciphertext too short"));
    }

    // Check version
    if payload[0] != 0x02 {
        return Err(JsValue::from_str(&format!("unsupported version: {}", payload[0])));
    }

    // Extract nonce and ciphertext+mac
    let mut nonce = [0u8; 32];
    nonce.copy_from_slice(&payload[1..33]);
    let mac_offset = payload.len() - 32;
    let ciphertext = &payload[33..mac_offset];
    let mac = &payload[mac_offset..];

    let mut conv_key = [0u8; 32];
    conv_key.copy_from_slice(&key_bytes);

    let keys = nip44_fast_expand(&conv_key, &nonce, Some(ciphertext), Some(mac))?;
    let mut buffer = ciphertext.to_vec();
    let mut cipher = chacha20::ChaCha20::new((&keys.chacha_key).into(), (&keys.chacha_nonce).into());
    cipher.apply_keystream(&mut buffer);
    nip44_unpad(&buffer)
}
