# Pushstr Mobile App - Setup & Usage Guide

## Overview

The Pushstr mobile app is a fully-functional Flutter companion app for Android and iOS that uses **Rust FFI** for all Nostr cryptographic operations. It provides the same functionality as the browser extension, allowing you to send and receive encrypted Nostr DMs on your mobile device.

## ✅ Current Status

### Completed Features
- ✅ **Rust FFI Integration**: All crypto handled by nostr-sdk 0.43 in Rust
- ✅ **Key Management**: Generate, import, export nsec keys
- ✅ **NIP-04 Encrypted DMs**: Send and receive encrypted direct messages (kind 4)
- ✅ **Contact Management**: Store contacts with nicknames
- ✅ **Message History**: View sent and received messages with persistence
- ✅ **Multi-Relay Support**: Connect to 3 default Nostr relays
- ✅ **Android Native Libraries**: Pre-built for arm64-v8a and armeabi-v7a
- ✅ **Share Intent Support**: Share text and images to Pushstr
- ✅ **Material Design UI**: Clean, intuitive interface with Pushstr branding
- ✅ **Cross-Platform Compatible**: Same nsec works on browser extension and mobile

### Architecture

```
┌─────────────────────────────────────┐
│      Flutter UI (Dart)              │
│      mobile/lib/main.dart           │
└──────────────┬──────────────────────┘
               │ FFI Calls
               ▼
┌─────────────────────────────────────┐
│   Generated FFI Bindings            │
│   mobile/lib/bridge_generated.dart/ │
└──────────────┬──────────────────────┘
               │ Native Interface
               ▼
┌─────────────────────────────────────┐
│   Rust Library (libpushstr_rust.so) │
│   pushstr_rust/src/api.rs           │
│   - nostr-sdk 0.43                  │
│   - NIP-04 encryption               │
│   - WebSocket relay connections     │
└─────────────────────────────────────┘
```

## 📋 Prerequisites

### For Running the App

1. **Flutter SDK 3.10+**
   ```bash
   flutter --version
   ```

2. **Android SDK** (for Android development)
   - Android Studio with SDK tools
   - Or Android command line tools

3. **Xcode** (for iOS development, macOS only)
   - Xcode 14+
   - iOS SDK

### For Building Rust Libraries (Optional)

Only needed if you want to rebuild the Rust library:

1. **Rust toolchain**
   ```bash
   rustup --version
   cargo --version
   ```

2. **Android NDK** (for Android builds)
   ```bash
   cargo install cargo-ndk
   rustup target add aarch64-linux-android armv7-linux-androideabi
   ```

3. **iOS targets** (for iOS builds, macOS only)
   ```bash
   rustup target add aarch64-apple-ios x86_64-apple-ios
   ```

## 🚀 Quick Start

### 1. Navigate to Mobile Directory

```bash
cd /home/tom/code/pushstr/mobile
```

### 2. Install Flutter Dependencies

```bash
flutter pub get
```

### 3. Run on Android

**Option A: With connected device**
```bash
flutter run
```

**Option B: With Android emulator**
```bash
# Start emulator first
flutter emulators --launch <emulator_id>

# Then run
flutter run
```

**Option C: Build APK**
```bash
flutter build apk --release
# APK will be at: build/app/outputs/flutter-apk/app-release.apk
```

### 4. Run on iOS (macOS only)

```bash
flutter run -d ios
```

Or open in Xcode:
```bash
open ios/Runner.xcworkspace
```

## 📱 Using the App

### First Launch

1. **Automatic Key Generation**: On first launch, the app automatically generates a new Nostr keypair (nsec)
2. The generated nsec is saved securely in SharedPreferences
3. Your npub (public key) is displayed on the home screen

### Import Existing Key

To use the same key as your browser extension:

1. In browser extension: Click **Export nsec**, copy the key
2. In mobile app: Tap menu (≡) → **Settings** → **Import nsec**
3. Paste your nsec key
4. Your contacts and settings are stored per-device, but messages sync via Nostr relays

### Add Contacts

1. Tap menu (≡) → Drawer
2. Tap **Add Contact** (+ icon)
3. Enter:
   - **Nickname**: Friendly name (e.g., "Alice")
   - **Public Key**: Their npub or hex pubkey
4. Tap **Add**

### Send Messages

1. Select a contact from the drawer
2. Type your message in the input field at the bottom
3. Tap **Send** (paper plane icon)
4. Message is encrypted and sent via Nostr relays

### Receive Messages

**Manual Refresh:**
1. Tap the refresh icon in the top-right
2. App fetches recent DMs from relays
3. New messages appear in the chat

**Auto-Refresh:**
- The app includes a listener that polls for new messages
- Currently runs when app is in foreground

### Share to Pushstr

From any app with text:
1. Tap **Share**
2. Select **Pushstr**
3. App opens with shared text pre-filled
4. Select recipient and send

## ⚙️ Configuration

### Default Relays

The app connects to these relays by default:
- wss://relay.damus.io
- wss://relay.snort.social
- wss://offchain.pub

### Encryption

- **Protocol**: NIP-04 (AES-256-CBC)
- **Message Format**: kind 4 (Direct Message)
- **Compatible with**: Browser extension (when Giftwrap is disabled)

### Storage

- **Private Keys**: SharedPreferences (consider migrating to flutter_secure_storage)
- **Contacts**: SharedPreferences (per-device)
- **Messages**: SharedPreferences (last 100 messages, local only)

## 🔧 Development

### Project Structure

```
mobile/
├── lib/
│   ├── main.dart                    # Main app with UI and logic
│   └── bridge_generated.dart/       # Auto-generated Rust FFI bindings
├── android/
│   └── app/
│       └── src/main/
│           ├── AndroidManifest.xml  # Permissions and intents
│           └── jniLibs/             # Rust native libraries
│               ├── arm64-v8a/       # 64-bit ARM (8.7 MB)
│               └── armeabi-v7a/     # 32-bit ARM (6.2 MB)
├── ios/                             # iOS project files
├── pubspec.yaml                     # Flutter dependencies
└── README.md                        # Project documentation
```

### Rust API Functions

All functions in `pushstr_rust/src/api.rs`:

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `init_nostr` | `nsec: String` | `String` (npub) | Initialize with key |
| `get_npub` | - | `String` | Get current npub |
| `get_nsec` | - | `String` | Get current nsec |
| `generate_new_key` | - | `String` (nsec) | Generate new keypair |
| `npub_to_hex` | `npub: String` | `String` | Convert npub to hex |
| `hex_to_npub` | `hex: String` | `String` | Convert hex to npub |
| `send_dm` | `recipient: String`, `message: String` | `String` (event ID) | Send encrypted DM |
| `fetch_recent_dms` | `limit: u64` | `String` (JSON) | Fetch recent DMs |
| `wait_for_new_dms` | `timeout_secs: u64` | `String` (JSON) | Listen for new DMs |
| `clear_returned_events_cache` | - | `Result<()>` | Clear event cache |

### Rebuilding Rust Libraries

**For Android:**

```bash
cd /home/tom/code/pushstr/pushstr_rust

# Build for both ARM architectures
cargo ndk \
  -t arm64-v8a \
  -t armeabi-v7a \
  -o ../mobile/android/app/src/main/jniLibs \
  build --release
```

**For iOS (macOS only):**

```bash
cd /home/tom/code/pushstr/pushstr_rust

# Build for iOS
cargo build --release --target aarch64-apple-ios
cargo build --release --target x86_64-apple-ios

# Create universal library
lipo -create \
  target/aarch64-apple-ios/release/libpushstr_rust.a \
  target/x86_64-apple-ios/release/libpushstr_rust.a \
  -output ios/libpushstr_rust.a
```

### Running Tests

```bash
cd /home/tom/code/pushstr/mobile

# Dart/Flutter tests
flutter test

# Rust tests
cd ../pushstr_rust
cargo test
```

### Code Analysis

```bash
flutter analyze
flutter pub run dart_code_metrics:metrics analyze lib
```

## 🔐 Security Notes

### ⚠️ Important Security Considerations

1. **Key Storage**: Currently uses SharedPreferences for nsec storage
   - **Recommendation**: Migrate to flutter_secure_storage for encrypted key storage
   - On Android: Uses KeyStore
   - On iOS: Uses Keychain

2. **Backup Your Keys**: Always export and securely backup your nsec
   - Lost nsec = lost identity
   - No password recovery available

3. **Key Sharing**: Never share your nsec with anyone
   - Share only your npub (public key)
   - Nsec gives full control of your identity

4. **Encryption**: All messages use NIP-04 end-to-end encryption
   - Messages encrypted on device before sending
   - Only you and recipient can read messages
   - Relay operators cannot read message content

5. **Network Security**: All relay connections use WSS (WebSocket Secure)

### Security Improvements TODO

- [ ] Migrate nsec storage to flutter_secure_storage
- [ ] Add PIN/biometric lock for app access
- [ ] Implement key rotation
- [ ] Add message auto-delete after X days
- [ ] Implement NIP-17 Giftwrap for metadata privacy
- [ ] Add NIP-44 encryption option (more secure than NIP-04)

## 🐛 Troubleshooting

### Build Errors

**"libpushstr_rust.so not found"**
- Check that native libraries exist:
  ```bash
  ls -la android/app/src/main/jniLibs/arm64-v8a/
  ls -la android/app/src/main/jniLibs/armeabi-v7a/
  ```
- If missing, rebuild Rust libraries (see above)

**"Flutter SDK not found"**
- Ensure Flutter is in PATH:
  ```bash
  which flutter
  flutter doctor
  ```

**"Android licenses not accepted"**
```bash
flutter doctor --android-licenses
```

### Runtime Errors

**"Failed to connect to relays"**
- Check internet connection
- Check AndroidManifest.xml has INTERNET permission
- Try different relays in settings

**"Failed to decrypt message"**
- Ensure sender used same encryption (NIP-04)
- Check that recipient pubkey is correct
- Verify nsec key is valid

**"Messages not syncing"**
- Messages are stored locally, not synced between devices
- Each device fetches from relays independently
- Try manual refresh (tap refresh icon)

### Performance Issues

**App slow to start**
- Normal: Rust FFI initialization takes ~1-2 seconds
- Check that native libraries aren't too large
- Consider lazy loading Rust functions

**Messages slow to load**
- Increase fetch limit in code
- Reduce number of relays
- Clear old messages

## 📈 Future Enhancements

### Planned Features

- [ ] **Push Notifications**: Background service for incoming DMs
- [ ] **QR Code Sharing**: Scan QR to add contacts or share nsec
- [ ] **File Attachments**: Upload to Blossom server (NIP-18)
- [ ] **Multiple Keys**: Switch between identities
- [ ] **Relay Management**: Add/remove relays in-app
- [ ] **Message Search**: Search contacts and messages
- [ ] **Read Receipts**: Optional delivery confirmations
- [ ] **Group Messaging**: NIP-28 public channels
- [ ] **Desktop Sync**: Sync settings between devices
- [ ] **Backup/Restore**: Export/import app data

### Technical Improvements

- [ ] Migrate to flutter_secure_storage for keys
- [ ] Add local database (sqflite) for message persistence
- [ ] Implement background service for Android
- [ ] Add iOS background fetch for notifications
- [ ] Optimize Rust library size
- [ ] Add integration tests
- [ ] Implement CI/CD pipeline
- [ ] Add Sentry/crash reporting

## 📄 Related Documentation

- **Main README**: `/home/tom/code/pushstr/README.md`
- **Rust FFI Integration**: `mobile/RUST_FFI_INTEGRATION.md`
- **Integration Status**: `mobile/INTEGRATION_STATUS.md`
- **Browser Extension**: See root `README.md` for extension details

## 🙏 Credits

- **nostr-sdk**: Battle-tested Rust Nostr implementation
- **flutter_rust_bridge**: Seamless Flutter ↔ Rust FFI
- **Nostr Protocol**: Decentralized messaging protocol
- **ForkIt**: Reference implementation using similar architecture

## 📝 License

Same as main Pushstr project - see root LICENSE file.

## 🆘 Support

For issues, questions, or contributions:
1. Check existing issues in main Pushstr repository
2. Review Nostr NIPs: https://github.com/nostr-protocol/nips
3. Flutter documentation: https://docs.flutter.dev
4. nostr-sdk docs: https://docs.rs/nostr-sdk

---

**Last Updated**: November 30, 2025
**Status**: ✅ Ready for Android testing
**Next Steps**: Test on real Android device, implement push notifications
