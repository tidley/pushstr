# Pushstr - Pushbullet on Nostr

Pushbullet-style messaging over Nostr Giftwrapped DMs. Runs as a Firefox/Chrome extension and as a mobile app (Android/iOS).

Quick, secure, private, anonymous multi-media messaging between devices to help improve productivity.

Android and Firefox are stable - Chrome and iOS function but are a little buggy.

## What it does
- Generates or imports a profile (`nsec`), wraps messages as NIP-17 giftwrap (`kind:1059` with inner `kind:4`), and sends through your relays.
- Listens for messages, decrypts locally and displays messages or download links for larger files.
- Browser extension UI for quick send + options; mobile app mirrors the flow with native share intent and chat view.
- Larger files encrypted for recipient and distributed via Blossom.

## Prereqs
- Node 18+, npm
- For browsers: Firefox or Chrome/Chromium
- For mobile: Flutter 3.10+, Android SDK; Xcode for iOS. Rust + `cargo-ndk` only if you want to rebuild the native library.

## Build & run
### Browser extension
```bash
npm install
# Firefox (MV2)
npm run package
# Chrome (MV3)
MANIFEST_FILE=manifest.chrome.json npm run package
```
- Output: `dist/` plus `pushstr.zip`. Load `dist/` as a temporary add-on (`about:debugging` in Firefox) or an unpacked extension (`chrome://extensions` in Chrome).

### Mobile app (Android/iOS)
```bash
cd mobile
flutter pub get
# Run on attached device/emulator (Android or iOS)
flutter run
# Android release APK
flutter build apk --release
# Load to connected mobile
flutter install --use-application-binary build/app/outputs/flutter-apk/app-release.apk
```
- Optional Rust rebuild (refresh FFI + native libs):
```bash
flutter_rust_bridge_codegen generate
cd pushstr_rust
cargo ndk -t arm64-v8a -t armeabi-v7a -o ../mobile/android/app/src/main/jniLibs build --release
```
See `mobile/QUICKSTART.md` for more detail.

## Notes
- No cloud backups. Export your `nsec` and keep it safe.
- Relay outages aren’t retried automatically; reload/refresh to reconnect.
- Vendored `vendor/nostr-tools.bundle.js`; bump there to update nostr-tools.

# Browser extension
![alt text](image.png)

# Mobile app
![alt text](image-1.png)

![alt text](image-3.png)

## Next Steps

1. Publish to Zapstore / mobile app stores
1. Distribute browser extensions
