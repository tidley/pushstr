# Pushstr Mobile - Nostr DM Companion App

A Flutter mobile companion app for the Pushstr browser extension, using Rust FFI for Nostr cryptography.

## ✅ COMPLETED

### Rust FFI Integration
- **Rust library**: Full nostr-sdk 0.43 implementation with NIP-04 encrypted DMs
- **Flutter bindings**: Generated via flutter_rust_bridge 2.11.1
- **All crypto in Rust**: No broken Dart pointycastle code
- **Desktop compatible**: Uses NIP-04 (kind 4) DMs matching browser extension default

### Features Implemented
- ✅ Key generation (automatic on first run)
- ✅ Import/export nsec
- ✅ Contact management with nicknames
- ✅ Send encrypted DMs (NIP-04, kind 4)
- ✅ Receive and decrypt DMs (NIP-04, kind 4)
- ✅ Message history
- ✅ Relay connections (3 default relays)
- ✅ Clean, intuitive UI
- ✅ Pushstr branding with orange icon (1024x1024)

### Code Status
- ✅ Compiles without errors
- ✅ All old broken crypto code deleted
- ✅ Tests pass
- ✅ Flutter analyze clean (only deprecation warnings)
- ✅ Android Rust libraries built (arm64-v8a, armeabi-v7a)

## 🚀 READY TO RUN

The app is now fully built and ready to run on both desktop and Android!

## 🔨 ANDROID BUILD (COMPLETED)

The Rust library has been successfully built for Android. If you need to rebuild:

### Requirements
```bash
# Install cargo-ndk (if not already installed)
cargo install cargo-ndk

# Install Android targets
rustup target add aarch64-linux-android armv7-linux-androideabi
```

### Build Command (from pushstr_rust directory)
```bash
cd ../pushstr_rust

# Build for both ARM architectures and copy to jniLibs automatically
cargo ndk -t arm64-v8a -t armeabi-v7a -o ../mobile/android/app/src/main/jniLibs build --release
```

This builds:
- `arm64-v8a/libpushstr_rust.so` (8.7 MB) - Modern 64-bit ARM devices
- `armeabi-v7a/libpushstr_rust.so` (6.2 MB) - Older 32-bit ARM devices

## 🎯 QUICK START

### Run on Android Device
```bash
cd mobile
flutter run  # Automatically detects connected device
```

### Run on Desktop/Linux
```bash
cd mobile
flutter run -d linux
```

## 📱 USAGE

1. **First Launch**: App generates a new nsec automatically
2. **Import Key**: Settings → Import nsec (use same key as desktop extension)
3. **Export Key**: Settings → Export nsec (backup or share with desktop)
4. **Add Contacts**: Drawer → Add contact (enter nickname and npub/hex)
5. **Send Messages**: Select contact from drawer, type message, send
6. **Receive Messages**: Tap refresh icon to fetch recent DMs

## 🏗️ ARCHITECTURE

```
Flutter UI (Dart)
    ↓
Rust FFI (flutter_rust_bridge)
    ↓
nostr-sdk 0.43 (Rust)
    ↓
Nostr Relays (WebSocket)
```

### Key Components

- **lib/main.dart**: Full UI implementation with Rust FFI calls
- **../pushstr_rust/src/api.rs**: Rust Nostr functions (init, send, receive)
- **lib/bridge_generated.dart/**: Auto-generated FFI bindings
- **../pushstr_rust/Cargo.toml**: Rust dependencies (nostr-sdk, flutter_rust_bridge)

### Rust API Functions

All Rust functions are synchronous (marked with `#[frb(sync)]`):

- `init_nostr(nsec: String) -> String` - Initialize, returns npub
- `get_npub() -> String` - Get current npub
- `get_nsec() -> String` - Get current nsec
- `generate_new_key() -> String` - Generate new keypair, returns nsec
- `npub_to_hex(npub: String) -> String` - Convert npub to hex
- `hex_to_npub(hex: String) -> String` - Convert hex to npub
- `send_dm(recipient: String, message: String) -> String` - Send NIP-04 encrypted DM
- `fetch_recent_dms(limit: u64) -> String` - Fetch DMs as JSON
- `wait_for_new_dms(timeout_secs: u64) -> String` - Listen for new DMs
- `clear_returned_events_cache() -> Result<()>` - Clear event cache

## 🔐 SECURITY

- **Keys stored**: nsec stored in SharedPreferences
- **End-to-end encrypted**: All DMs use NIP-04 encryption (kind 4)
- **No plaintext**: Messages are encrypted before leaving device
- **Rust crypto**: Battle-tested nostr-sdk, no custom Dart crypto
- **Compatible**: Matches browser extension default (useGiftwrap: false)

## 🚀 FUTURE ENHANCEMENTS

- [x] ~~Build for Android~~ **DONE!**
- [ ] Push notifications for incoming DMs
- [ ] QR code for easy nsec sharing
- [ ] File attachments via Blossom server
- [ ] Multiple key management (switch between identities)
- [ ] Relay management UI (add/remove relays)
- [ ] Message persistence (currently only last 100 fetched)
- [ ] Read receipts / delivery confirmations
- [ ] Search contacts and messages

## 📚 DOCUMENTATION

See also:
- `RUST_FFI_INTEGRATION.md` - Complete FFI integration guide
- `SOLUTION_SUMMARY.md` - Problem analysis and solution overview
- `INTEGRATION_STATUS.md` - Current status and remaining work

## 🙏 CREDITS

- **nostr-sdk**: Rust Nostr implementation
- **flutter_rust_bridge**: Flutter ↔ Rust FFI
- **ForkIt**: Reference implementation using same approach
