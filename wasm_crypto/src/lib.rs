use aes_gcm::{aead::{Aead, KeyInit, generic_array::GenericArray}, Aes256Gcm, Nonce};
use sha2::{Digest, Sha256};
use wasm_bindgen::prelude::*;
use secp256k1::{XOnlyPublicKey, SecretKey, PublicKey, Secp256k1};
use hkdf::Hkdf;
use chacha20poly1305::{ChaCha20Poly1305, AeadInPlace, Nonce as ChaCha20Nonce, KeyInit as ChaChaKeyInit};
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

    // Derive conversation key using HKDF-SHA256
    let hkdf = Hkdf::<Sha256>::new(None, shared_x);
    let mut conversation_key = [0u8; 32];
    hkdf.expand(b"nip44-v2", &mut conversation_key)
        .map_err(|e| JsValue::from_str(&format!("HKDF failed: {}", e)))?;

    Ok(hex::encode(conversation_key))
}

/// Encrypts plaintext using NIP-44 v2
/// Returns base64-encoded ciphertext with version prefix
#[wasm_bindgen]
pub fn nip44_encrypt(conversation_key_hex: &str, plaintext: &str) -> Result<String, JsValue> {
    let plaintext_bytes = plaintext.as_bytes();

    // Check size limits (1 to 65535 bytes)
    if plaintext_bytes.is_empty() || plaintext_bytes.len() > 65535 {
        return Err(JsValue::from_str("plaintext size must be between 1 and 65535 bytes"));
    }

    // Parse conversation key
    let key_bytes = hex::decode(conversation_key_hex)
        .map_err(|e| JsValue::from_str(&format!("Invalid conversation key hex: {}", e)))?;
    if key_bytes.len() != 32 {
        return Err(JsValue::from_str("conversation key must be 32 bytes"));
    }

    // Generate random nonce (32 bytes for NIP-44 v2)
    let mut nonce = [0u8; 32];
    getrandom::getrandom(&mut nonce)
        .map_err(|e| JsValue::from_str(&format!("Failed to generate nonce: {}", e)))?;

    // Derive encryption key and AAD using HKDF
    let hkdf = Hkdf::<Sha256>::new(Some(&nonce), &key_bytes);
    let mut chacha_key = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-key", &mut chacha_key)
        .map_err(|e| JsValue::from_str(&format!("HKDF chacha key failed: {}", e)))?;
    let mut aad = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-aad", &mut aad)
        .map_err(|e| JsValue::from_str(&format!("HKDF aad failed: {}", e)))?;

    // Encrypt with ChaCha20-Poly1305
    let cipher = ChaCha20Poly1305::new(chacha_key.as_ref().into());
    let chacha_nonce = ChaCha20Nonce::from_slice(&[0u8; 12]); // NIP-44 uses all-zero nonce

    let mut buffer = plaintext_bytes.to_vec();
    cipher.encrypt_in_place(chacha_nonce, &aad, &mut buffer)
        .map_err(|e| JsValue::from_str(&format!("Encryption failed: {}", e)))?;

    // Construct payload: version (1) || nonce (32) || ciphertext+mac
    let mut payload = Vec::with_capacity(1 + 32 + buffer.len());
    payload.push(0x02); // version
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&buffer);

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

    // Check minimum size: version (1) + nonce (32) + mac (16) = 49 bytes
    if payload.len() < 49 {
        return Err(JsValue::from_str("ciphertext too short"));
    }

    // Check version
    if payload[0] != 0x02 {
        return Err(JsValue::from_str(&format!("unsupported version: {}", payload[0])));
    }

    // Extract nonce and ciphertext+mac
    let nonce = &payload[1..33];
    let ciphertext_with_mac = &payload[33..];

    // Derive decryption key and AAD using HKDF
    let hkdf = Hkdf::<Sha256>::new(Some(nonce), &key_bytes);
    let mut chacha_key = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-key", &mut chacha_key)
        .map_err(|e| JsValue::from_str(&format!("HKDF chacha key failed: {}", e)))?;
    let mut aad = [0u8; 32];
    hkdf.expand(b"nip44-v2-chacha-aad", &mut aad)
        .map_err(|e| JsValue::from_str(&format!("HKDF aad failed: {}", e)))?;

    // Decrypt with ChaCha20-Poly1305
    let cipher = ChaCha20Poly1305::new(chacha_key.as_ref().into());
    let chacha_nonce = ChaCha20Nonce::from_slice(&[0u8; 12]); // NIP-44 uses all-zero nonce

    let mut buffer = ciphertext_with_mac.to_vec();
    cipher.decrypt_in_place(chacha_nonce, &aad, &mut buffer)
        .map_err(|e| JsValue::from_str(&format!("Decryption failed: {}", e)))?;

    // Convert to string
    String::from_utf8(buffer)
        .map_err(|e| JsValue::from_str(&format!("Invalid UTF-8: {}", e)))
}
