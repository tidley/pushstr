# Codebase Concerns

## Scope
This document captures high-impact concerns found in the current Pushstr codebase, with concrete references to affected files and practical remediation directions.

## Priority Summary
- Critical: Plaintext secret handling and secret leakage via logs.
- High: Tooling/test drift that weakens release confidence.
- High: Large monolithic modules and repeated blocking operations.
- Medium: Cross-platform behavior drift risks (extension JS/WASM vs mobile Rust/Flutter).

## Security Concerns

### 1) Secrets are widely stored and propagated in plaintext
- `src/background.js` persists `settings.nsec` and `settings.keys[*].nsec` via `browser.storage.local`.
- `src/options.js` stores nsec values in UI state (`<option value="nsec...">`), increasing accidental exposure risk in DOM/devtools.
- `mobile/lib/main.dart` stores active key and profile keys in `SharedPreferences` (`nostr_nsec`, `profiles`, and profile-indexed data keys).
- `mobile/lib/sync/sync_controller.dart` and `mobile/lib/main.dart` use storage keys derived from raw nsec values (for example `contacts_<nsec>`, `pending_dms_<nsec>`), leaking secret material into metadata.
- `pushstr_rust/src/api.rs` exposes `get_nsec()` over FFI, expanding secret read surface.

Practical fix:
- Move secret material to secure enclaves/storage APIs (`flutter_secure_storage`/platform keystore for mobile, encrypted-at-rest strategy for extension).
- Never use raw secrets in preference key names; use a keyed hash (for example SHA-256(prefix+secret)).

### 2) Sensitive data is logged (keys, conversation keys, message content)
- `src/background.js` logs decryption internals, key snippets, and decrypted message content.
- `pushstr_rust/src/api.rs` logs secret-derived values and conversation-key fragments in `unwrap_gift_event`.
- `mobile/lib/sync/rust_sync_worker.dart` prints recipient/event diagnostics for send paths.

Practical fix:
- Remove or gate sensitive logs behind a strict compile-time debug flag.
- Add a log redaction helper and ban direct key/content logs in CI checks.

### 3) Backup/export flows increase exfiltration risk
- `src/background.js` and `src/options.js` backup/export flows include raw nsec in JSON.
- `mobile/lib/main.dart` backup flows export profile payloads containing nsec to Downloads/share sheets.
- `mobile/android/app/src/main/kotlin/com/pushstr/pushstr_mobile/PushstrApplication.kt` renames oversized shared prefs to a backup XML file, leaving sensitive data in plain backup artifacts.

Practical fix:
- Encrypt backup payloads with user passphrase-derived keys.
- Require explicit warning/confirmation before exporting secret-bearing backups.

### 4) Broad extension resource exposure and permissive runtime behavior
- `manifest.chrome.json` exposes `vendor/nostr-tools.bundle.js`, `wasm_crypto.js`, and `wasm_crypto_bg.wasm` to `<all_urls>` in `web_accessible_resources`.
- `manifest.chrome.json` uses CSP with `'wasm-unsafe-eval'`.
- `src/popup.js`/`src/background.js` accept and process remote URLs from message content/descriptor payloads, increasing trust in untrusted metadata paths.

Practical fix:
- Restrict `web_accessible_resources` match patterns.
- Keep CSP as tight as possible and document why each relaxation is required.
- Enforce stricter URL allowlisting for attachment fetch/decrypt flows.

## Performance Risks

### 1) High write amplification in extension storage
- `src/background.js` persists broad settings snapshots frequently (`persistSettings()` after many message and relay events), including message arrays and key data.
- `src/background.js` message recording writes on almost every incoming/outgoing event.

Impact:
- Higher latency/jank risk in popup/background interactions.
- Increased chance of browser storage quota pressure.

Practical fix:
- Batch writes (debounce/throttle) and split hot/cold state keys.
- Persist deltas for messages instead of full object rewrites.

### 2) Repeated Rust init/connect work in mobile sync/send paths
- `mobile/lib/sync/rust_sync_worker.dart` calls `RustLib.init()` and `api.initNostr(nsec: ...)` inside each isolate task.
- `pushstr_rust/src/api.rs` `init_nostr` connects relays, fetches relay lists, and subscribes each time it runs.

Impact:
- Avoidable network and CPU overhead per sync/send tick.
- More connection churn and transient failures under weak networks.

Practical fix:
- Keep a long-lived initialized Rust session per active profile.
- Separate key-switch from relay re-bootstrap logic.

### 3) Large local caches and payload transforms in popup UI
- `src/popup.js` stores decrypted media/previews in `localStorage` (base64) and in-memory maps.
- `src/popup.js` frequently converts blobs/base64/data URLs and can re-fetch blob/data URLs for download fallback behavior.

Impact:
- Memory growth and storage pressure in long-running sessions.
- Slow UI on media-heavy conversations.

Practical fix:
- Reduce persisted cache size/time-to-live and prefer indexed storage strategies.
- Separate preview cache from decrypted file cache with stricter eviction.

### 4) Very large single-file modules
- `src/background.js` (~1748 lines), `src/popup.js` (~2264 lines), and `mobile/lib/main.dart` (~6928 lines).

Impact:
- Slow onboarding and risky edits.
- Higher regression probability during feature changes.

Practical fix:
- Incrementally extract domain modules (key management, relay/client, media, UI rendering, sync).

## Technical Debt

### 1) Tooling and language drift
- `package.json` scripts expect `scripts/dev.js`, but `scripts/dev.js` is absent.
- `package.json` lint targets `src/**/*.ts`, while primary extension runtime code is `.js`.
- `tsconfig.json` includes only `src/**/*.ts`, so core JS code is outside TypeScript checking.
- No visible ESLint config file exists at repo root (`.eslintrc*` or `eslint.config.*`).
- `vitest.config.ts` points to `./tests/setup.ts`, but `tests/setup.ts` is missing.
- `playwright.config.ts` points to `./tests/e2e`, but `tests/e2e` is missing.

Consequence:
- CI confidence is weakened; declared checks may not cover real runtime paths.

### 2) Generated-code and source-layout duplication
- Both `pushstr_rust/src/frb_generated.rs` and `pushstr_rust/src/src/frb_generated.rs` exist.

Consequence:
- Higher confusion risk about source-of-truth generated bindings.

### 3) Repository includes build and release artifacts
- Committed artifacts in `dist/`, `release-test/`, and packaged archives (`pushstr.zip`, `chrome.zip`) increase drift risk between source and shipped output.

Consequence:
- Harder review signal-to-noise and reproducibility concerns.

### 4) Documentation drift and contradictory status notes
- `mobile/FIXES_NEEDED.md`, `mobile/INTEGRATION_STATUS.md`, and current `mobile/lib/main.dart` state show overlapping but partly conflicting narratives.

Consequence:
- Onboarding friction and incorrect implementation assumptions.

## Fragile Areas

### 1) Cross-platform crypto behavior split across multiple implementations
- Extension path: `src/background.js` + `src/wasm_crypto.js` + `wasm_crypto/src/lib.rs`.
- Mobile path: `pushstr_rust/src/api.rs` via FRB.

Risk:
- NIP-44/NIP-04 fallback differences can silently diverge across clients.

### 2) Decrypt and parse heuristics are permissive and multi-path
- `src/background.js` and `src/popup.js` use multiple fallback parse/decrypt branches (JSON parse variants, plaintext/base64 heuristics, NIP-44->NIP-04 fallbacks).

Risk:
- Edge cases can bypass expected paths and produce inconsistent message interpretation.

### 3) Relay/network lifecycle handling is spread and stateful
- Extension relay state/cooldown/retry logic in `src/background.js`.
- Mobile relay init/subscription/fetch lifecycle in `pushstr_rust/src/api.rs`.

Risk:
- Hard-to-reproduce delivery and ordering bugs under intermittent relay conditions.

### 4) SharedPreferences size and backup recovery path is brittle
- Android backup migration logic in `mobile/android/app/src/main/kotlin/com/pushstr/pushstr_mobile/PushstrApplication.kt` and export helpers in `MainActivity.kt`.

Risk:
- Data loss or unexpected state transitions when prefs file crosses size threshold.

## Known Issues (Observed)
- `npm` is unavailable in the current analysis environment, so runtime script execution was not validated here.
- `scripts/dev.js` is referenced but not present.
- Test/lint config paths reference missing files/directories (`tests/setup.ts`, `tests/e2e`).

## Recommended Remediation Order
1. Remove/redact sensitive logging and stop using raw nsec in storage keys.
2. Move secrets to secure storage strategy and encrypt backup/export payloads.
3. Stabilize developer tooling (lint/test configs, missing scripts, effective CI checks).
4. Reduce monolith size and isolate relay/crypto/media responsibilities per module.
5. Consolidate Rust generated artifacts and clean committed build outputs policy.
