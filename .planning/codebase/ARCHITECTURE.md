# Architecture

**Analysis Date:** 2026-03-05

## Pattern Overview

**Overall:** Multi-client messaging monorepo with a shared Rust core and platform-specific shells (browser extension + Flutter app).

**Key Characteristics:**
- Polyglot runtime split: browser JavaScript in `src/`, Flutter/Dart in `mobile/lib/`, and Rust core logic in `pushstr_rust/src/`.
- Event-driven messaging over Nostr relays, with both NIP-04 and NIP-59/NIP-17 support in `src/background.js` and `pushstr_rust/src/api.rs`.
- Shared cryptographic behavior across platforms using Rust implementations exposed via WASM in `wasm_crypto/src/lib.rs` and via FFI in `mobile/lib/bridge_generated.dart/api.dart`.
- Local-first state with per-profile storage, backed by `browser.storage.local` in `src/background.js` and `SharedPreferences` in `mobile/lib/main.dart` and `mobile/lib/sync/sync_controller.dart`.

## Layers

**Presentation Layer (Extension UI + Mobile UI):**
- Purpose: Render conversations/settings and capture user actions.
- Contains: `src/popup.js`, `src/options.js`, `src/popup.html`, `src/options.html`, and widget/state code in `mobile/lib/main.dart`.
- Depends on: Message orchestration APIs exposed by `src/background.js` and FFI wrappers in `mobile/lib/bridge_generated.dart/api.dart`.
- Used by: End users through browser extension popups/options and mobile screens.

**Client Orchestration Layer:**
- Purpose: Translate UI intents into relay/crypto operations and maintain session state.
- Contains: Runtime message handler and state machine in `src/background.js`; mobile controller logic in `mobile/lib/main.dart`; bounded sync orchestration in `mobile/lib/sync/sync_controller.dart`.
- Depends on: Nostr clients, crypto helpers, and persistence adapters.
- Used by: Presentation layer and background triggers.

**Messaging/Transport Layer:**
- Purpose: Connect to relays, subscribe, publish, and retry with cooldown behavior.
- Contains: Relay connection/subscription/publish logic in `src/background.js` (`connect`, `publishWithRetry`) and `pushstr_rust/src/api.rs` (`init_nostr`, `fetch_recent_dms`, `wait_for_new_dms`).
- Depends on: `nostr-tools` in extension and `nostr-sdk` in Rust.
- Used by: Client orchestration layer for send/receive paths.

**Crypto and Envelope Layer:**
- Purpose: Encrypt/decrypt DMs, unwrap/wrap gift envelopes, and process attachment encryption.
- Contains: NIP-44/AES helpers in `wasm_crypto/src/lib.rs`, DM decrypt/encrypt path in `src/background.js` (`encryptGift`, `decryptGift`, `decryptDmContent`), and canonical Rust logic in `pushstr_rust/src/api.rs` (`wrap_gift_event`, `unwrap_gift_event`, `encrypt_media`, `decrypt_media`).
- Depends on: Shared key derivation and platform crypto primitives.
- Used by: Messaging layer and media workflows.

**Persistence Layer:**
- Purpose: Persist profiles, relays, contacts, messages, and sync watermarks.
- Contains: Profile-scoped maps in `src/background.js` (`recipientsByKey`, `messagesByKey`, `dmModesByKey`) and preference-backed stores in `mobile/lib/main.dart`/`mobile/lib/sync/sync_controller.dart`.
- Depends on: Browser extension storage and Flutter shared preferences.
- Used by: All runtime layers.

## Data Flow

**Extension Outbound DM Flow:**

1. User composes in `src/popup.js` (`send`).
2. Popup sends `{ type: 'send-gift' }` via `browser.runtime.sendMessage` to `src/background.js`.
3. `handleMessage` dispatches to `sendGift` in `src/background.js`.
4. `sendGift` selects per-contact DM mode (`nip04`/`nip17`) and tags with `[pushstr:client]` + `seq`.
5. For NIP-04, event is encrypted and signed in `src/background.js`; for giftwrap, a kind-14 inner event is sealed/wrapped in kind-1059.
6. Relay publish runs through `publishWithRetry` in `src/background.js`.
7. Sent message is stored through `recordMessage` in `src/background.js`.
8. Popup refreshes state with `{ type: 'get-state' }` in `src/popup.js`.

**Extension Inbound DM Flow:**

1. Subscription established by `connect` in `src/background.js`.
2. Incoming relay events are routed to `handleGiftEvent` in `src/background.js`.
3. Giftwrap events are unwrapped/decrypted (`decryptGift`, `decryptDmContent`).
4. Read receipts are parsed via `parseReadReceipt`; normal messages are normalized.
5. Message/contact updates are persisted with `recordMessage` and `ensureContact`.
6. UI receives push notifications via `browser.runtime.sendMessage({ type: 'incoming' })`.
7. Popup listener in `src/popup.js` schedules coalesced refresh (`scheduleRefreshState`).

**Mobile Sync Tick Flow:**

1. Foreground/background triggers call `SyncController.performSyncTick` in `mobile/lib/sync/sync_controller.dart`.
2. Sync reads active nsec/contact metadata from `SharedPreferences`.
3. `RustSyncWorker.fetchRecentDms` in `mobile/lib/sync/rust_sync_worker.dart` calls `api.fetchRecentDms`.
4. Rust side fetches + decrypts events in `pushstr_rust/src/api.rs`.
5. Sync merges new items into `pending_dms_*` and emits local notifications via `mobile/lib/notifications.dart`.

**Attachment Encryption Flow:**

1. UI chooses file in `src/popup.js` or `mobile/lib/main.dart`.
2. Extension calls `upload-blossom` in `src/background.js`; mobile calls `api.encryptMedia` / `api.uploadMediaUnencrypted` in `mobile/lib/bridge_generated.dart/api.dart`.
3. Ciphertext upload happens through Blossom auth events in `src/background.js` (`uploadToBlossom`) or `pushstr_rust/src/api.rs` (`upload_to_blossom`).
4. Descriptor metadata is carried in DM payload and decrypted by `decrypt-media` in `src/background.js` or `api.decryptMedia` from mobile.

**State Management:**
- Extension runtime state is singleton-like and process-local in `src/background.js`, persisted to `browser.storage.local`.
- Mobile state is widget-owned in `mobile/lib/main.dart`, with background-safe snapshots in `SharedPreferences`.
- Rust uses global mutex-protected state (`NOSTR_CLIENT`, `NOSTR_KEYS`, queues) in `pushstr_rust/src/api.rs`.

## Key Abstractions

**Runtime Message Command Bus (Extension):**
- Purpose: Formal boundary between UI scripts and background orchestration.
- Examples: `handleMessage` command cases (`get-state`, `send-gift`, `upload-blossom`) in `src/background.js`.
- Pattern: Stringly-typed command dispatcher over browser runtime messaging.

**Profile-Scoped State Maps:**
- Purpose: Isolate contacts/messages/settings by active keypair.
- Examples: `recipientsByKey`, `messagesByKey`, `dmModesByKey` in `src/background.js`; profile keys in `mobile/lib/main.dart`.
- Pattern: Active-profile projection over shared persisted object state.

**Serialized Send Queue (Rust):**
- Purpose: Preserve outbound ordering and avoid overlapping writes.
- Examples: `SEND_QUEUE`, `SEND_NOTIFY`, `enqueue_send` in `pushstr_rust/src/api.rs`.
- Pattern: Single-worker queue with oneshot response channels.

**Generated Bridge Surface:**
- Purpose: Keep platform bindings stable while Rust API evolves.
- Examples: `mobile/lib/bridge_generated.dart/api.dart`, `pushstr_rust/src/frb_generated.rs`, `pushstr_rust/src/src/frb_generated.rs`.
- Pattern: Code-generated FFI adapters over `#[frb(sync)]` Rust exports in `pushstr_rust/src/api.rs`.

## Entry Points

**Browser Extension Runtime:**
- Location: `manifest.json` (MV2) and `manifest.chrome.json` (MV3).
- Triggers: Browser extension startup and popup/options interactions.
- Responsibilities: Launch `src/background.js` plus UI pages (`src/popup.html`, `src/options.html`).

**Extension Background Bootstrap:**
- Location: `src/background.js` (`ready` async bootstrap).
- Triggers: Script load in background page/service worker.
- Responsibilities: WASM init, settings load, key bootstrap, relay subscribe, context menu setup.

**Mobile App Bootstrap:**
- Location: `mobile/lib/main.dart` (`main`).
- Triggers: App launch / OS lifecycle.
- Responsibilities: Rust library init, Android workmanager registration, app widget tree startup.

**Rust FFI API Surface:**
- Location: `pushstr_rust/src/api.rs`.
- Triggers: Calls from `mobile/lib/bridge_generated.dart/api.dart` and isolate worker wrappers in `mobile/lib/sync/rust_sync_worker.dart`.
- Responsibilities: Key init, DM send/fetch/wait, media encrypt/decrypt, relay setup.

**Build/Packaging Entry Points:**
- Location: `scripts/build.js`, `scripts/package.js`, `scripts/patch_wasm_crypto.js`.
- Triggers: npm scripts in `package.json`.
- Responsibilities: Bundle extension assets, package zip, patch WASM glue for CSP safety.

## Error Handling

**Strategy:** Localized try/catch with best-effort recovery in JS/Dart, `Result<T, anyhow::Error>` propagation in Rust.

**Patterns:**
- Extension handlers return `{ ok: false, error }` or `{ error }` from `src/background.js` instead of throwing to UI.
- Popup/options use resilient messaging (`safeSend`) with retry on transient port closure in `src/popup.js` and `src/options.js`.
- Rust APIs keep error context via `anyhow::Context` in `pushstr_rust/src/api.rs`.
- Background tasks are guarded with mutex/single-flight semantics in `mobile/lib/sync/sync_controller.dart` and `mobile/lib/sync/rust_sync_worker.dart`.

## Cross-Cutting Concerns

**Logging:**
- Console-based tracing in extension and Flutter (`console.*`, `debugPrint`) in `src/background.js`, `src/popup.js`, and `mobile/lib/main.dart`.

**Input Normalization:**
- Pubkey/npub/nprofile normalization is centralized in `normalizePubkey` (`src/background.js`) and `parse_pubkey` (`pushstr_rust/src/api.rs`).

**Reliability and Ordering:**
- Retry/backoff and relay cooldown in `src/background.js`; bounded send queue and retry loops in `pushstr_rust/src/api.rs`.
- Sequence tags (`seq`) are attached and parsed in both JS and Rust pipelines.

**Security/Privacy Boundaries:**
- Keys remain local and are derived/decoded on device in `src/background.js` and `pushstr_rust/src/api.rs`.
- Attachment encryption uses shared-secret-derived AES-GCM in `src/background.js` and `pushstr_rust/src/api.rs`.

---

*Architecture analysis: 2026-03-05*
*Update when major patterns change*
