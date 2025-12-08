# Pushstr Mobile - Rust FFI Integration Status

## ✅ COMPLETED

### 1. Rust Library Created
- Location: `/home/tom/Documents/code/nostr/pushstr_vibed/pushstr_rust/`
- Dependencies: nostr-sdk 0.43, flutter_rust_bridge 2.11.1
- Build status: ✅ Compiles successfully

### 2. Rust API Functions Implemented
All functions use NIP-17 giftwrapped DMs (same as desktop extension):

- `init_nostr(nsec: String) -> String` - Initialize with key, returns npub
- `get_npub() -> String` - Get current npub
- `get_nsec() -> String` - Get current nsec (for backup)
- `generate_new_key() -> String` - Generate new keypair
- `npub_to_hex(npub: String) -> String` - Convert npub to hex
- `hex_to_npub(hex: String) -> String` - Convert hex to npub
- `send_dm(recipient: String, message: String) -> String` - Send giftwrapped DM
- `fetch_recent_dms(limit: u64) -> String` - Fetch recent DMs as JSON
- `wait_for_new_dms(timeout_secs: u64) -> String` - Listen for new DMs
- `clear_returned_events_cache() -> Result<()>` - Clear event cache

### 3. Flutter Bindings Generated
- Tool: flutter_rust_bridge_codegen v2.11.1
- Output: `mobile/lib/bridge_generated.dart/`
- Status: ✅ Generated successfully

### 4. Flutter Dependencies Updated
- Added: flutter_rust_bridge ^2.5.0, ffi ^2.0.0
- Removed: pointycastle, hex, bech32, crypto, convert, web_socket_channel
- Status: ✅ `flutter pub get` successful

## 🔨 REMAINING WORK

### 1. Update nostr_rust_service.dart
Replace placeholders with actual Rust FFI calls:

```dart
import 'package:pushstr_mobile/bridge_generated.dart/api.dart' as api;
import 'package:pushstr_mobile/bridge_generated.dart/frb_generated.dart';

class NostrRustService {
  Future<void> init() async {
    await RustLib.init();
    final prefs = await SharedPreferences.getInstance();
    final savedNsec = prefs.getString('nostr_nsec') ?? '';

    try {
      final npub = api.initNostr(nsec: savedNsec);
      print('Initialized: $npub');
    } catch (e) {
      print('Init failed: $e');
    }
  }

  String sendDm({required String recipient, required String message}) {
    return api.sendDm(recipient: recipient, message: message);
  }

  // ... etc
}
```

### 2. Update main.dart
Replace broken crypto imports with NostrRustService:

```dart
import 'services/nostr_rust_service.dart';

// In _init():
await NostrRustService.instance.init();

// In _send():
final eventId = NostrRustService.instance.sendDm(
  recipient: selectedContact!,
  message: text,
);

// For receiving:
final dmsJson = NostrRustService.instance.fetchRecentDms(limit: 100);
final messages = NostrRustService.instance.parseMessages(dmsJson);
```

### 3. Build Rust Library for Android
```bash
# Install Android NDK targets
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi
rustup target add x86_64-linux-android

# Build for Android
cd pushstr_rust
cargo build --release --target aarch64-linux-android
cargo build --release --target armv7-linux-androideabi

# Copy to Flutter project
mkdir -p ../mobile/android/app/src/main/jniLibs/arm64-v8a/
mkdir -p ../mobile/android/app/src/main/jniLibs/armeabi-v7a/

cp target/aarch64-linux-android/release/libpushstr_rust.so \
   ../mobile/android/app/src/main/jniLibs/arm64-v8a/

cp target/armv7-linux-androideabi/release/libpushstr_rust.so \
   ../mobile/android/app/src/main/jniLibs/armeabi-v7a/
```

### 4. Delete Old Broken Code
Once Rust FFI is working, delete these:
```bash
rm -rf mobile/lib/src/crypto/
rm -rf mobile/lib/src/nostr/
rm mobile/FIXES_NEEDED.md
```

### 5. Test End-to-End
- Generate or import nsec
- Add a contact
- Send a DM
- Receive a DM
- Verify desktop extension compatibility

## ESTIMATED TIME REMAINING

- Update service & main.dart: **30 minutes**
- Build for Android: **15 minutes**
- Test & debug: **30 minutes**
- **Total: ~75 minutes**

## ARCHITECTURE

```
┌─────────────────────────────────────┐
│         Flutter UI (Dart)           │
│  mobile/lib/main.dart               │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│   NostrRustService (Dart wrapper)   │
│  mobile/lib/services/               │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Generated FFI Bindings (Dart)      │
│  mobile/lib/bridge_generated.dart/  │
└──────────────┬──────────────────────┘
               │ FFI
               ▼
┌─────────────────────────────────────┐
│    Rust Library (libpushstr_rust)   │
│    pushstr_rust/src/api.rs          │
│    - nostr-sdk 0.43                 │
│    - NIP-17 giftwrap support        │
└─────────────────────────────────────┘
```

## KEY ADVANTAGES

1. ✅ **No Dart crypto debugging** - All crypto in battle-tested Rust
2. ✅ **NIP-17 giftwrap** - Same as desktop extension
3. ✅ **nostr-sdk 0.43** - Latest stable version
4. ✅ **Cross-platform** - Works on Android, iOS, Linux, etc.
5. ✅ **Desktop compatibility** - Can use same nsec on both
6. ✅ **Proven approach** - ForkIt uses exact same method

## NEXT STEPS

1. Complete the service wrapper implementation (30 min)
2. Update main.dart to use the service (20 min)
3. Build Rust for Android targets (15 min)
4. Test on device/emulator (30 min)
5. Clean up old code (5 min)

**Total remaining: ~100 minutes to fully working app**
