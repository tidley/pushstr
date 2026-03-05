# Technology Stack

**Analysis Date:** 2026-03-05

## Languages

**Primary:**
- JavaScript (ES modules) - Browser extension runtime and UI logic in `src/background.js`, `src/popup.js`, and `src/options.js`.
- Rust (edition 2021) - Nostr protocol + crypto core in `pushstr_rust/src/api.rs` and WASM crypto module in `wasm_crypto/src/lib.rs`.
- Dart (SDK `^3.10.1`) - Flutter mobile app in `mobile/lib/main.dart` and sync/notification code in `mobile/lib/sync/sync_controller.dart`.

**Secondary:**
- TypeScript - Type-checking/types only via `tsconfig.json` and `src/types.ts`.
- Kotlin - Android platform channel and storage/share integration in `mobile/android/app/src/main/kotlin/com/pushstr/pushstr_mobile/MainActivity.kt`.
- Swift - iOS platform channel integration in `mobile/ios/Runner/AppDelegate.swift`.
- HTML/CSS - Extension views in `src/popup.html`, `src/options.html`, `src/background.html`, `src/popup.css`, and `src/options.css`.

## Runtime

**Environment:**
- Browser extension runtime (Firefox MV2 + Chrome MV3) configured by `manifest.json` and `manifest.chrome.json`.
- Node.js 18+ required for extension build/package tooling (documented in `README.md`; scripts in `package.json` and `scripts/*.js`).
- Rust stable toolchain for `pushstr_rust` and `wasm_crypto` crates (`pushstr_rust/Cargo.toml`, `wasm_crypto/Cargo.toml`).
- Flutter mobile runtime for Android/iOS with generated Rust FFI bridge (`mobile/pubspec.yaml`, `flutter_rust_bridge.yaml`).

**Package Manager:**
- npm (lockfile v3 in `package-lock.json`) for extension/web tooling.
- Cargo (lockfile present in `pushstr_rust/Cargo.lock`) for Rust core and dependencies.
- Flutter pub for Dart/mobile dependencies in `mobile/pubspec.yaml`.

## Frameworks

**Core:**
- `nostr-tools` (`^2.18.2`) for extension-side Nostr event/relay operations (`package.json`, `src/background.js`).
- `nostr-sdk` (`0.43` with `nip44`, `nip04`, `nip59`) for Rust Nostr client, relay subscriptions, and DM flow (`pushstr_rust/Cargo.toml`, `pushstr_rust/src/api.rs`).
- Flutter SDK + Material UI for mobile app shell and screens (`mobile/pubspec.yaml`, `mobile/lib/main.dart`).
- `flutter_rust_bridge` (`2.11.1`) for Dart-to-Rust FFI bindings (`mobile/pubspec.yaml`, `pushstr_rust/Cargo.toml`, `mobile/lib/bridge_generated.dart/*`).

**Testing:**
- Vitest (`vitest`, `@vitest/coverage-v8`) configured in `vitest.config.ts`.
- Playwright (`@playwright/test`) configured in `playwright.config.ts`.
- Flutter test framework configured via `mobile/pubspec.yaml` with sample test in `mobile/test/widget_test.dart`.

**Build/Dev:**
- esbuild for extension bundling in `scripts/build.js`.
- wasm-pack + post-build patching for WASM glue in `README.md` and `scripts/patch_wasm_crypto.js`.
- TypeScript compiler for static type checks (`package.json` script `type-check`, config `tsconfig.json`).
- Android Gradle/Kotlin plugin setup in `mobile/android/build.gradle.kts` and `mobile/android/settings.gradle.kts`.

## Key Dependencies

**Critical:**
- `nostr-tools` - Extension relay subscriptions, event signing, NIP-04 operations (`src/background.js`, `src/options.js`).
- `nostr-sdk` - Rust-side relay connectivity, fetch/subscribe/send for kinds `4`/`1059`/`10050` (`pushstr_rust/src/api.rs`).
- `flutter_rust_bridge` - Mobile bridge generation and runtime invocation of Rust APIs (`flutter_rust_bridge.yaml`, `mobile/lib/sync/rust_sync_worker.dart`).
- `reqwest` - Rust HTTP transport used for Blossom upload/download (`pushstr_rust/Cargo.toml`, `pushstr_rust/src/api.rs`).
- `shared_preferences` - Mobile local persistence for keys, relays, contacts, pending DMs (`mobile/pubspec.yaml`, `mobile/lib/main.dart`).

**Infrastructure:**
- `pako` - gzip/ungzip helper paths in extension background processing (`package.json`, `src/background.js`).
- `qrcode`/`qr_flutter`/`mobile_scanner` - QR encode/decode flows in extension and mobile (`src/options.js`, `mobile/pubspec.yaml`).
- `flutter_local_notifications`, `flutter_foreground_task`, and `workmanager` - mobile notification + periodic sync lifecycle (`mobile/pubspec.yaml`, `mobile/lib/notifications.dart`, `mobile/lib/main.dart`).

## Configuration

**Environment:**
- No `.env`/`.env.example`-driven runtime configuration detected at repo root.
- Runtime/user config is persisted in browser local extension storage (`browser.storage.local` in `src/background.js`) and device shared preferences (`mobile/lib/main.dart`, `mobile/lib/sync/sync_controller.dart`).
- Dev test helper `scripts/js_dm_test.js` reads environment variables (`NSEC`, `PEER`, `RELAYS`) for manual relay testing.

**Build:**
- Extension build/packaging: `package.json`, `scripts/build.js`, `scripts/package.js`, `manifest.json`, `manifest.chrome.json`.
- Type system: `tsconfig.json` and ambient types under `types/`.
- Rust/FFI: `pushstr_rust/Cargo.toml`, `wasm_crypto/Cargo.toml`, `pushstr_rust/build.rs`, `flutter_rust_bridge.yaml`.
- Mobile platform config: `mobile/pubspec.yaml`, `mobile/android/app/build.gradle.kts`, `mobile/android/app/src/main/AndroidManifest.xml`, `mobile/ios/Podfile`, `mobile/ios/Runner/Info.plist`.

## Platform Requirements

**Development:**
- Node + npm for extension build/test/package (`README.md`, `package.json`).
- Rust toolchain + `wasm-pack` + `flutter_rust_bridge_codegen` for crypto/FFI artifacts (`README.md`, `flutter_rust_bridge.yaml`).
- Flutter SDK, Android SDK, and Xcode/CocoaPods for mobile targets (`README.md`, `mobile/ios/Podfile`).

**Production:**
- Browser extension artifacts from `dist/` and packaged `pushstr.zip` (`scripts/package.js`).
- Chrome target uses MV3 manifest (`manifest.chrome.json`); Firefox target uses MV2 manifest (`manifest.json`).
- Mobile app deploy targets are Android/iOS Flutter app bundles (`mobile/android/`, `mobile/ios/`, release metadata in `zapstore.yaml`).

---

*Stack analysis: 2026-03-05*
