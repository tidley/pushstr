# External Integrations

**Analysis Date:** 2026-03-05

## APIs & External Services

**Nostr Relay Network (Primary Messaging Transport):**
- Public Nostr relays - DM publish/subscribe over WebSocket for kinds `4`, `14`, `1059`, and relay-list kind `10050`.
  - SDK/Client:
    - Extension: `nostr-tools` `SimplePool` in `src/background.js`.
    - Mobile/Rust: `nostr-sdk` client in `pushstr_rust/src/api.rs`.
  - Auth: Nostr private key (`nsec`) signs events locally; no centralized auth server (`src/background.js`, `pushstr_rust/src/api.rs`, `mobile/lib/main.dart`).
  - Endpoints used: relay URLs such as `wss://relay.damus.io`, `wss://relay.primal.net`, `wss://nos.lol`, etc. defined in `src/background.js`, `pushstr_rust/src/api.rs`, and `mobile/lib/main.dart`.

**Attachment Hosting API:**
- Blossom server (`https://blossom.primal.net/upload`) - encrypted and unencrypted attachment upload/download.
  - SDK/Client:
    - Extension: `fetch` in `src/background.js`.
    - Rust/mobile: `reqwest::blocking` in `pushstr_rust/src/api.rs`.
  - Auth: `Authorization: Nostr <base64(event-json)>` header built from signed kind `24242` event tags (`t=upload`, `expiration`, `x` hash) in `src/background.js` and `pushstr_rust/src/api.rs`.
  - Response handling: consumes `location` header, JSON `url`, or fallback URL composition in both `src/background.js` and `pushstr_rust/src/api.rs`.

**Browser Platform APIs (Host Environment Integrations):**
- WebExtension APIs - local persistence, notifications, context menu actions, and download handoff.
  - Integration points: `browser.storage.local`, `browser.notifications`, `browser.contextMenus`, and `browser.downloads` in `src/background.js`, `src/options.js`, `src/popup.js`.
  - Permissions declared in `manifest.json` and `manifest.chrome.json`.

## Data Storage

**Databases:**
- No server-side relational/NoSQL database integration detected.
- No ORM/migration stack detected in repository root, `pushstr_rust/`, or `mobile/`.

**File Storage:**
- Blossom (`https://blossom.primal.net`) stores uploaded attachment blobs referenced by URL descriptors (`src/background.js`, `pushstr_rust/src/api.rs`, `mobile/lib/main.dart`).
- Local download/share integration:
  - Extension download API in `src/background.js`.
  - Android file export/share via platform channel methods in `mobile/android/app/src/main/kotlin/com/pushstr/pushstr_mobile/MainActivity.kt`.
  - iOS share-sheet bridge in `mobile/ios/Runner/AppDelegate.swift`.

**Caching / Local Persistence:**
- Extension durable state in `browser.storage.local` (`src/background.js`).
- Extension UI media caches in `localStorage` (`src/popup.js`).
- Mobile durable state in `SharedPreferences` (`mobile/lib/main.dart`, `mobile/lib/sync/sync_controller.dart`).
- In-memory relay health and send/retry maps in `src/background.js` and `mobile/lib/main.dart`.

## Authentication & Identity

**Identity Provider Pattern:**
- Self-custodied Nostr keypairs; keys are generated/imported locally and never delegated to a third-party identity provider.
  - Extension key generation/import in `src/background.js` and `src/options.js`.
  - Mobile key init/generation in `mobile/lib/main.dart` and Rust APIs in `pushstr_rust/src/api.rs`.

**Service Auth:**
- Relay auth is implicit event-signature auth via Nostr protocol (signed events, no API key flow).
- Blossom uploads are authorized by signed Nostr auth events serialized into request headers (`src/background.js`, `pushstr_rust/src/api.rs`).

**OAuth / Federated Login:**
- Not detected.

**External Signer (NIP-07) Status:**
- Type surfaces exist (`src/types.ts`), including `window.nostr` and message types for external signer toggles.
- No active implementation path found in runtime handlers of `src/background.js`/`src/options.js`.

## Monitoring & Observability

**Error Tracking:**
- No Sentry/Crashlytics SDK wiring detected in JS/Rust/Dart runtime code.
- Android manifest explicitly disables Firebase analytics/crashlytics collection flags in `mobile/android/app/src/main/AndroidManifest.xml`.

**Analytics:**
- No product analytics SDK integration detected.

**Logs:**
- Console/debug logging only (`console.*`, `debugPrint`, `eprintln!`) in `src/background.js`, `mobile/lib/main.dart`, and `pushstr_rust/src/api.rs`.

## CI/CD & Deployment

**Hosting/Distribution:**
- Browser extension build output and zip packaging are local-script based (`scripts/build.js`, `scripts/package.js`).
- Mobile release metadata references GitHub releases and Zapstore asset matching in `zapstore.yaml`.

**CI Pipeline:**
- No `.github/workflows/` pipeline detected in repository.
- Build/test commands are locally defined in `package.json` and Flutter tooling files.

## Environment Configuration

**Development:**
- No repo-level env template for app runtime; state is runtime-generated and stored locally.
- Manual relay/DM script uses env vars (`NSEC`, `PEER`, `RELAYS`) in `scripts/js_dm_test.js`.
- Browser host permissions and CSP are manifest-driven in `manifest.json` and `manifest.chrome.json`.

**Staging:**
- Not detected as a separate environment tier.

**Production:**
- Secrets are user key material (`nsec`) stored in extension/mobile local storage paths (`src/background.js`, `mobile/lib/main.dart`).
- No managed secret vault integration detected in codebase.

## Webhooks & Callbacks

**Incoming Webhooks (HTTP):**
- None detected.

**Incoming Callbacks (Platform/Event Callbacks):**
- Extension callback/event listeners:
  - `browser.runtime.onMessage` and notification click handlers in `src/background.js`.
  - context menu click callback in `src/background.js`.
- Mobile callback channels:
  - Flutter `MethodChannel` callbacks (`com.pushstr.share`, `com.pushstr.storage`) in `mobile/lib/main.dart` and platform implementations in `mobile/android/app/src/main/kotlin/com/pushstr/pushstr_mobile/MainActivity.kt` and `mobile/ios/Runner/AppDelegate.swift`.
  - Android share `intent-filter` callbacks in `mobile/android/app/src/main/AndroidManifest.xml`.

**Outgoing Webhooks:**
- None detected.

---

*Integration audit: 2026-03-05*
