# Pushstr

Private, relay-backed messaging over Nostr. Pushstr ships as a browser extension (Firefox/Chrome), a Flutter mobile app, and a Linux desktop build backed by a Rust core.

## Features
- NIP-04 DMs (kind 4).
- NIP-59 giftwrap DMs (kind 1059 + sealed rumor kind 13 + inner kind 14) using NIP-44 v2.
- Legacy giftwrap compatibility for older clients.
- Read receipts (between Pushstr clients).
- Ordered delivery hints via per-recipient sequence tags and gap placeholders.
- Encrypted attachments via Blossom-compatible uploads with inline previews.
- Desktop attachment saves preserve the original filename and can open the save folder.
- Per-contact DM mode toggle (04 vs giftwrap).
- Multi-relay delivery with retry/backoff and relay cooldown.
- Manual relay-list publishing for the active profile.
- JSON profile backup/import (mobile + extension).
- Optimistic send in extension UI.
- Linux desktop compose shortcuts: Enter sends, Shift+Enter inserts a newline.
- Linux desktop attachment flow opens the file picker directly.
- Streamlined settings: actions, key management, backup/restore, connectivity toggle.
- Extension sidebar refresh (settings in header, edit nickname, wider contacts pane).
- Extension settings aligned to mobile sections with active/all profile backups.

## Architecture
- UI: Flutter (mobile + Linux desktop), HTML/CSS/JS (extension).
- Crypto/relays: Rust (nostr-sdk), exposed via flutter_rust_bridge.
- Extension crypto: WASM bundle (built from `wasm_crypto`).
- Rust handles message normalization, receipt parsing, and FIFO send ordering; Dart/JS focus on UI.

## Repo Layout
- `src/` extension source
- `dist/` extension build output
- `manifest.chrome.json` MV3 manifest for Chrome
- `mobile/` Flutter app
- `pushstr_rust/` Rust core
- `wasm_crypto/` WASM crypto build
- `documentation/pushstr_fsd.md` functional spec

## Requirements
- Node 18+ and npm
- Rust (stable)
- Flutter 3.10+ and Android SDK (Xcode for iOS)
- `wasm-pack` for the extension WASM build
- `flutter_rust_bridge_codegen`

## Build and Run

### One-shot Full Rebuild

From the repo root:
```bash
flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml

cd pushstr_rust
cargo build
cargo ndk -t arm64-v8a -t armeabi-v7a -o ../mobile/android/app/src/main/jniLibs build --release

cd ..
npm install
cd wasm_crypto
wasm-pack build --release --target web --out-dir ../src --out-name wasm_crypto
npm run patch:wasm

# Firefox (MV2)
npm run package

cd ..
cd mobile
flutter pub get
flutter run -d linux

```

If you are also working on Linux desktop:
```bash
flutter run -d linux
```

If you want a release Linux build later:
```bash
cd pushstr_rust
cargo build --release
cd ..
cd mobile
flutter build linux --release
```

To run it:
```bash
cd build/linux/x64/release/bundle
./pushstr
```

If you want a single distributable artifact, tar the bundle:
```bash
cd ..
tar -czf pushstr-linux-x64-v0.1.0.tar.gz bundle
```

To run it locally:
```bash
sudo mkdir -p /opt/pushstr
sudo cp -a mobile/build/linux/x64/release/bundle /opt/pushstr
/opt/pushstr/pushstr
```

To make it show up like a normal pinnable app in your desktop shell:
```bash
mobile/linux/install_desktop.sh mobile/build/linux/x64/release/bundle
```

If you want a system-wide install instead of the default per-user install:
```bash
sudo mobile/linux/install_desktop.sh mobile/build/linux/x64/release/bundle /usr/local
```

### Browser Extension

From repo root:
```bash
# if currently in /wasm_crypto
cd ..

npm install
cd wasm_crypto
wasm-pack build --release --target web --out-dir ../src --out-name wasm_crypto
npm run patch:wasm

# Firefox (MV2)
npm run package

# Chrome (MV3)
MANIFEST_FILE=manifest.chrome.json npm run package
```

Outputs:
- Build output in `dist/`
- Packaged zip at `pushstr.zip`

Load the unpacked extension:
- Chrome: `chrome://extensions` -> Load unpacked -> select `dist/`
- Firefox: `about:debugging` -> This Firefox -> Load Temporary Add-on -> select `pushstr.zip`

### Mobile (Android/iOS)

Optional Rust rebuild (FFI + native libs):
```bash
flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
cd pushstr_rust
cargo build
cargo ndk -t arm64-v8a -t armeabi-v7a -o ../mobile/android/app/src/main/jniLibs build --release
```

Run Flutter:
```bash
cd mobile
flutter pub get
# Mobile
flutter run
```

Linux build notes:
- Linux uses the same Flutter app and Rust core, but desktop-only controls hide camera, video, record, and QR scan actions.
- If attachments fail to decrypt, make sure both sides are on the current `k` + `nonce` attachment format.
- Linux startup now keeps Nostr init off the UI thread, so the app should no longer trip the desktop "Not Responding" dialog on launch.
- If Linux still warns about notifications, make sure the app is using the current Linux notification settings path; the Android share hook is not active on Linux.
- The Linux bundle now includes `share/applications/pushstr.desktop` and `share/icons/hicolor/1024x1024/apps/pushstr.png`. If you want a real desktop install, copy those into `~/.local/share/applications` and `~/.local/share/icons/hicolor/1024x1024/apps` or the system-wide equivalents.
- To get the shell icon and pinning behavior, install the desktop file and icon with `mobile/linux/install_desktop.sh` after building the Linux bundle.

APK build:
```bash
flutter build apk --release
flutter install --use-application-binary build/app/outputs/flutter-apk/app-release.apk
```

## Troubleshooting
- If messages do not appear, reload extension, verify relays and check background logs (`background.js`).
- If giftwrap appears but content is missing, confirm inner kind 14 is plaintext (NIP-59 compatible).
- If Linux shows a Rust/Dart bridge hash mismatch, rebuild the Rust shared library and restart the app.
- If Linux shows a startup freeze or "Not Responding" prompt, restart after rebuilding so the UI-isolate init change takes effect.
- If the extension shows a new npub after reload, the extension ID likely changed.

## Documentation
- Functional spec: `documentation/pushstr_fsd.md`
- Mobile notes: `MOBILE_APP_GUIDE.md`, `MOBILE_APP_SUMMARY.md`

---

## Images

### Desktop extension
<img width="727" height="489" alt="browser extension conversation window" src="https://github.com/user-attachments/assets/0e6d0c6b-ce03-4978-b01b-2eece68fc53b" />

### Mobile app
<img width="360" height="800" alt="mobile conversation window" src="https://github.com/user-attachments/assets/3d5d5c7f-5508-4072-95af-2bb54c144002" />

<img width="360" height="800" alt="mobile settings" src="https://github.com/user-attachments/assets/c9e2a955-5ac1-4410-9bd5-73d6fcc1c1ff" />
