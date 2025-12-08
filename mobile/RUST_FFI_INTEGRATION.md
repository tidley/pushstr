# Pushstr Mobile - Rust FFI Integration Plan

## Overview

The **recommended solution** is to use **Rust with flutter_rust_bridge (FRB)** for all Nostr crypto operations, exactly like ForkIt does. This avoids pointycastle v3→v4 API migration headaches and uses battle-tested Rust libraries.

## Why Rust FFI?

1. **Battle-tested crypto**: `nostr-sdk` is the official Rust SDK with proper NIP-04, NIP-44, NIP-17
2. **Zero Dart crypto debugging**: No pointycastle API migration needed
3. **Cross-platform**: Works on Android, iOS, Linux, Windows, macOS
4. **Performance**: Native Rust performance for crypto operations
5. **Proven**: ForkIt demonstrates this works perfectly in production

## ForkIt's Working Implementation

Located at: `/home/tom/Documents/code/ForkIt/code/flutter_rust/`

### Key Functions Available:

```rust
// Key management
init_nostr(nsec: String) -> String  // Returns npub
get_npub() -> String
get_nsec() -> String

// NIP-17 Giftwrapped DMs (what desktop extension uses)
client.send_private_msg(pubkey, content, None) // Rust nostr-sdk handles giftwrap

// File uploads to Blossom with NIP-44 encryption
upload_encrypted_csv(csv_data: Vec<u8>) -> String  // Returns sha256

// DVM backend configuration
set_dvm_npub(npub: String) -> String
get_dvm_npub() -> String

// Relay management (built into nostr-sdk Client)
// Connects to multiple relays automatically
// Handles subscriptions, reconnections

// Message fetching
fetch_all_giftwrap_messages() -> String  // Returns JSON
wait_for_response(request_id: String, timeout_secs: u64) -> String
```

## Integration Steps for Pushstr Mobile

### 1. Create Rust Library (Similar to ForkIt)

```bash
cd /home/tom/Documents/code/nostr/pushstr_vibed
mkdir -p pushstr_rust/src
cd pushstr_rust
cargo init --lib
```

**Cargo.toml:**
```toml
[package]
name = "pushstr_rust"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
nostr-sdk = "0.37"
flutter_rust_bridge = "2.5"
tokio = { version = "1", features = ["full"] }
anyhow = "1.0"
serde_json = "1.0"
once_cell = "1.19"
uuid = { version = "1.10", features = ["v4"] }
base64 = "0.22"
sha2 = "0.10"

[build-dependencies]
flutter_rust_bridge_codegen = "2.5"
```

### 2. Minimal Rust API for Pushstr (src/api.rs)

```rust
use nostr_sdk::prelude::*;
use flutter_rust_bridge::frb;
use tokio::sync::Mutex;
use once_cell::sync::Lazy;

static RUNTIME: Lazy<tokio::runtime::Runtime> =
    Lazy::new(|| tokio::runtime::Runtime::new().unwrap());
static NOSTR_CLIENT: Mutex<Option<Arc<Client>>> = Mutex::const_new(None);
static NOSTR_KEYS: Mutex<Option<Keys>> = Mutex::const_new(None);

const RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.snort.social",
    "wss://offchain.pub",
];

/// Initialize with nsec, returns npub
#[frb(sync)]
pub fn init_nostr(nsec: String) -> Result<String, String> {
    RUNTIME.block_on(async {
        let keys = if nsec.is_empty() {
            Keys::generate()
        } else {
            Keys::parse(&nsec).map_err(|e| e.to_string())?
        };

        let client = Client::new(keys.clone());

        for relay in RELAYS {
            client.add_relay(*relay).await.map_err(|e| e.to_string())?;
        }

        client.connect().await;

        // Subscribe to DMs (kind 4)
        let filter = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .pubkey(keys.public_key());
        client.subscribe(filter, None).await.map_err(|e| e.to_string())?;

        *NOSTR_CLIENT.lock().await = Some(Arc::new(client));
        *NOSTR_KEYS.lock().await = Some(keys.clone());

        keys.public_key().to_bech32().map_err(|e| e.to_string())
    })
}

/// Get current npub
#[frb(sync)]
pub fn get_npub() -> Result<String, String> {
    RUNTIME.block_on(async {
        let keys = NOSTR_KEYS.lock().await;
        keys.as_ref()
            .ok_or("Not initialized".to_string())?
            .public_key()
            .to_bech32()
            .map_err(|e| e.to_string())
    })
}

/// Get current nsec (for backup)
#[frb(sync)]
pub fn get_nsec() -> Result<String, String> {
    RUNTIME.block_on(async {
        let keys = NOSTR_KEYS.lock().await;
        keys.as_ref()
            .ok_or("Not initialized".to_string())?
            .secret_key()
            .to_bech32()
            .map_err(|e| e.to_string())
    })
}

/// Send NIP-04 encrypted DM
#[frb(sync)]
pub fn send_dm(recipient_npub: String, message: String) -> Result<String, String> {
    RUNTIME.block_on(async {
        let client_lock = NOSTR_CLIENT.lock().await;
        let client = client_lock.as_ref().ok_or("Not initialized")?.clone();
        drop(client_lock);

        let recipient = PublicKey::from_bech32(&recipient_npub)
            .map_err(|e| e.to_string())?;

        let event = client.send_direct_msg(recipient, message, None)
            .await
            .map_err(|e| e.to_string())?;

        Ok(event.id.to_hex())
    })
}

/// Send NIP-17 Giftwrapped DM (like desktop extension)
#[frb(sync)]
pub fn send_giftwrap_dm(recipient_npub: String, message: String) -> Result<String, String> {
    RUNTIME.block_on(async {
        let client_lock = NOSTR_CLIENT.lock().await;
        let client = client_lock.as_ref().ok_or("Not initialized")?.clone();
        drop(client_lock);

        let recipient = PublicKey::from_bech32(&recipient_npub)
            .map_err(|e| e.to_string())?;

        let event = client.send_private_msg(recipient, message, None)
            .await
            .map_err(|e| e.to_string())?;

        Ok(event.id.to_hex())
    })
}

/// Fetch recent DMs as JSON
#[frb(sync)]
pub fn fetch_recent_dms() -> Result<String, String> {
    RUNTIME.block_on(async {
        let (client, keys) = {
            let client_lock = NOSTR_CLIENT.lock().await;
            let keys_lock = NOSTR_KEYS.lock().await;
            (
                client_lock.as_ref().ok_or("Not initialized")?.clone(),
                keys_lock.as_ref().ok_or("Not initialized")?.clone(),
            )
        };

        let filter = Filter::new()
            .kind(Kind::EncryptedDirectMessage)
            .pubkey(keys.public_key())
            .limit(100);

        let events = client
            .fetch_events(filter, std::time::Duration::from_secs(5))
            .await
            .map_err(|e| e.to_string())?;

        let messages: Vec<serde_json::Value> = events
            .iter()
            .map(|e| {
                serde_json::json!({
                    "id": e.id.to_hex(),
                    "pubkey": e.pubkey.to_hex(),
                    "created_at": e.created_at.as_u64(),
                    "content": e.content,
                })
            })
            .collect();

        serde_json::to_string(&messages).map_err(|e| e.to_string())
    })
}
```

### 3. Flutter Integration

**pubspec.yaml changes:**
```yaml
dependencies:
  flutter_rust_bridge: ^2.5.0
  ffi: ^2.0.0
  # REMOVE: pointycastle, hex, bech32, crypto, convert
  # Rust handles all crypto now!
```

**Dart service (lib/services/nostr_rust_service.dart):**
```dart
import 'package:pushstr_mobile/bridge_generated.dart/api.dart' as api;
import 'package:pushstr_mobile/bridge_generated.dart/frb_generated.dart';

class NostrRustService {
  static NostrRustService? _instance;
  static NostrRustService get instance {
    _instance ??= NostrRustService._();
    return _instance!;
  }

  NostrRustService._();

  static bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await RustLib.init();
    _initialized = true;
  }

  Future<String> initNostr({required String nsec}) async {
    await init();
    return api.initNostr(nsec: nsec);
  }

  String getNpub() => api.getNpub();
  String getNsec() => api.getNsec();

  String sendDm({required String recipientNpub, required String message}) {
    return api.sendDm(recipientNpub: recipientNpub, message: message);
  }

  String sendGiftwrapDm({required String recipientNpub, required String message}) {
    return api.sendGiftwrapDm(recipientNpub: recipientNpub, message: message);
  }

  String fetchRecentDms() => api.fetchRecentDms();
}
```

### 4. Build Setup

**build.rs:**
```rust
fn main() {
    flutter_rust_bridge_codegen::generate();
}
```

**Build commands:**
```bash
# Generate Dart bindings
flutter_rust_bridge_codegen generate

# Build Rust library
cargo build --release

# For Android
cargo build --release --target aarch64-linux-android
cargo build --release --target armv7-linux-androideabi

# Copy .so files to Flutter
cp target/release/libpushstr_rust.so mobile/android/app/src/main/jniLibs/arm64-v8a/
```

### 5. Update mobile/lib/main.dart

Replace the broken crypto imports with:
```dart
import 'services/nostr_rust_service.dart';

// In _init():
final npub = await NostrRustService.instance.initNostr(nsec: savedNsec);

// In _send():
final eventId = NostrRustService.instance.sendDm(
  recipientNpub: recipientNpub,
  message: text,
);

// In _handleDM():
// Rust SDK automatically decrypts DMs when fetching
final dmsJson = NostrRustService.instance.fetchRecentDms();
final dms = jsonDecode(dmsJson) as List;
```

## Benefits of This Approach

✅ **Zero pointycastle migration** - Delete all broken crypto code
✅ **NIP-17 giftwrap support** - Desktop extension compatibility
✅ **NIP-44 encryption** - Modern encryption, not legacy NIP-04
✅ **Relay management** - nostr-sdk handles connections, reconnects
✅ **Event signing** - Schnorr signatures handled in Rust
✅ **Bech32 encoding** - npub/nsec conversion works perfectly
✅ **WebSocket management** - Built into nostr-sdk
✅ **Notification support** - Can add push notifications via relay subscriptions

## Next Steps

1. Copy ForkIt's `flutter_rust` directory structure to `pushstr_rust`
2. Strip out DVM-specific code, keep core Nostr functions
3. Add simple DM send/receive functions
4. Generate Dart bindings with flutter_rust_bridge_codegen
5. Update Flutter app to use Rust service
6. Delete `lib/src/crypto/` and `lib/src/nostr/` - no longer needed!
7. Test on Android

## File Removal After Rust Integration

These files can be **deleted** once Rust FFI is working:
- `lib/src/crypto/nip04.dart` ❌
- `lib/src/crypto/nip44.dart` ❌
- `lib/src/crypto/secp256k1.dart` ❌
- `lib/src/crypto/bytes.dart` ❌
- `lib/src/nostr/event.dart` ❌ (Rust handles events)
- `lib/src/nostr/key_manager.dart` ❌ (Rust handles keys)
- `lib/src/nostr/relay_pool.dart` ❌ (Rust nostr-sdk handles relays)

## Estimated Integration Time

- **Initial setup**: 2-3 hours (copy ForkIt structure, adapt API)
- **Build configuration**: 1-2 hours (Android NDK setup)
- **Flutter integration**: 2-3 hours (update UI to call Rust)
- **Testing**: 2-3 hours (verify DM send/receive)

**Total**: ~8-12 hours to have a fully working Pushstr mobile companion app with perfect Nostr compatibility.

## Reference

- ForkIt source: `/home/tom/Documents/code/ForkIt/code/flutter_rust/`
- flutter_rust_bridge docs: https://cjycode.com/flutter_rust_bridge/
- nostr-sdk docs: https://rust-nostr.org/
