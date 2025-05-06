// src/api/nostr.rs

// — remove or comment out this if you’re not using any std::net types:
// use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use std::time::Duration;

use nostr_sdk::nips::nip04;
use nostr_sdk::prelude::*;
use serde_json::json;

#[flutter_rust_bridge::frb(dart_async)]
pub async fn fetch_last_event(npub: String) -> Result<String, String> {
    let author_pk = PublicKey::from_bech32(&npub).map_err(|e| format!("Invalid npub: {}", e))?;

    let filter = Filter::new().pubkeys(vec![author_pk.clone()]).limit(1);

    let client = Client::default();
    client
        .add_relay("wss://relay.damus.io")
        .await
        .map_err(|e| format!("Relay add error: {}", e))?;
    client.connect().await;

    let events = client
        .fetch_events(filter, Duration::from_secs(10))
        .await
        .map_err(|e| format!("Fetch error: {}", e))?;

    if let Some(evt) = events.into_iter().next() {
        Ok(evt.as_json())
    } else {
        Err("No events found".into())
    }
}

#[flutter_rust_bridge::frb(dart_async)]
pub async fn fetch_dms(npriv: String, utc_from: String, utc_to: String) -> Result<String, String> {
    // decode Bech32 → SecretKey
    let secret_key = SecretKey::from_bech32(&npriv).map_err(|e| format!("Invalid npriv: {}", e))?;
    let keys = Keys::new(secret_key.clone());
    let my_pubkey = keys.public_key();

    // parse RFC3339 or default to (now – 7d)…now
    let until = if utc_to.trim().is_empty() {
        Utc::now()
    } else {
        DateTime::parse_from_rfc3339(&utc_to)
            .map_err(|e| format!("Invalid utc_to: {}", e))?
            .with_timezone(&Utc)
    };
    let since = if utc_from.trim().is_empty() {
        until - ChronoDuration::days(7)
    } else {
        DateTime::parse_from_rfc3339(&utc_from)
            .map_err(|e| format!("Invalid utc_from: {}", e))?
            .with_timezone(&Utc)
    };

    let client = Client::builder().signer(keys.clone()).build();
    client
        .add_relay("wss://relay.damus.io")
        .await
        .map_err(|e| format!("Relay error: {}", e))?;
    client.connect().await;

    let filter = Filter::new()
        .kinds(vec![Kind::EncryptedDirectMessage])
        .pubkeys(vec![my_pubkey.clone()])
        .since(Timestamp::from_secs(since.timestamp() as u64))
        .until(Timestamp::from_secs(until.timestamp() as u64));

    let events = client
        .fetch_events(filter, Duration::from_secs(10))
        .await
        .map_err(|e| format!("Fetch error: {}", e))?;

    let mut messages = Vec::new();
    for evt in events {
        if let Ok(plain) = nip04::decrypt(&secret_key, &evt.pubkey, &evt.content) {
            messages.push(json!({
                "id":         evt.id.to_hex(),
                "from":       evt.pubkey.to_hex(),
                "content":    plain,
                "created_at": evt.created_at.as_u64()
            }));
        }
    }

    serde_json::to_string(&messages).map_err(|e| format!("Serialization error: {}", e))
}
