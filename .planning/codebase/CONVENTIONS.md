# Coding Conventions

**Analysis Date:** 2026-03-05

## Scope

This repository is polyglot:
- Extension UI/runtime JavaScript in `src/background.js`, `src/popup.js`, `src/options.js`
- Shared TypeScript interfaces in `src/types.ts`
- Flutter/Dart app code in `mobile/lib/main.dart`, `mobile/lib/sync/sync_controller.dart`, `mobile/lib/notifications.dart`
- Rust core and Rust/WASM crypto in `pushstr_rust/src/api.rs`, `wasm_crypto/src/lib.rs`
- Generated FFI bridge code in `mobile/lib/bridge_generated.dart/*` and `pushstr_rust/src/frb_generated.rs`

## Naming Patterns

### Files
- JavaScript entry files use lowercase names by role: `src/background.js`, `src/popup.js`, `src/options.js`.
- Dart files use snake_case: `mobile/lib/sync/rust_sync_worker.dart`, `mobile/lib/notifications.dart`.
- Rust modules use snake_case files with module wiring in `pushstr_rust/src/lib.rs` (`mod api;`, `mod frb_generated;`).
- Generated bridge files include `frb_generated` in filename: `mobile/lib/bridge_generated.dart/frb_generated.dart`, `pushstr_rust/src/frb_generated.rs`.

### Functions
- JavaScript uses lowerCamelCase for functions and helpers (`makeBrowser`, `safeSend`, `scheduleRefreshState`) in `src/popup.js` and `src/options.js`.
- Dart uses lowerCamelCase methods/functions, with private members prefixed `_` (`_init`, `_finishInit`, `_persistIncoming`) in `mobile/lib/main.dart` and `mobile/lib/sync/sync_controller.dart`.
- Rust uses snake_case for functions (`parse_pubkey`, `enqueue_send`, `send_gift_dm_direct`) in `pushstr_rust/src/api.rs`.

### Types and Classes
- TypeScript interfaces/types use PascalCase in `src/types.ts` (`NostrEvent`, `Settings`, `RuntimeMessage`).
- Dart classes use PascalCase, private classes prefixed with underscore (`PushstrApp`, `_HomeScreenState`, `_AsyncMutex`) in `mobile/lib/main.dart` and `mobile/lib/sync/rust_sync_worker.dart`.
- Rust structs/enums use PascalCase (`MediaDescriptor`, `SendKind`, `RumorData`) in `pushstr_rust/src/api.rs`.

### Constants
- JavaScript uses UPPER_SNAKE_CASE for constants (`DEFAULT_RELAYS`, `MESSAGE_LIMIT`, `PUBLISH_RETRY_BASE_MS`) in `src/background.js`.
- Dart uses `static const` with lowerCamel private names for class-scoped constants (`_maxAttachmentBytes`, `_relayResendDelay`) in `mobile/lib/main.dart`.
- Rust uses `const` with UPPER_SNAKE_CASE (`BLOSSOM_SERVER`, `RETURNED_EVENT_IDS_MAX`) in `pushstr_rust/src/api.rs`.

## Code Style

### JavaScript / TypeScript
- Semicolons are used consistently in `src/*.js` and `scripts/*.js`.
- Quote style is not uniform:
  - Double quotes dominate `src/background.js` and `src/options.js`.
  - Single quotes dominate `src/popup.js`.
- Modules use ESM imports/exports (see `package.json` `"type": "module"` and imports in `scripts/build.js`).
- Path alias `@/* -> src/*` is defined in `tsconfig.json` and `vitest.config.ts`, but runtime JS in `src/*.js` mostly uses relative imports.

### Dart
- Uses standard Flutter/Dart formatting and lint baseline via `mobile/analysis_options.yaml` (`include: package:flutter_lints/flutter.yaml`).
- Private state and helpers are underscore-prefixed across `mobile/lib/main.dart`.
- Async-heavy code prefers `Future<void>`/`Future<T?>` return types in sync workers and app init flows.

### Rust
- `edition = "2021"` in `pushstr_rust/Cargo.toml` and `wasm_crypto/Cargo.toml`.
- Uses `Result<T>` and `anyhow::Context` for error propagation in `pushstr_rust/src/api.rs`.
- Generated bridge code in `pushstr_rust/src/frb_generated.rs` carries permissive lint allowances; treat as generated output, not style source.

### Lint/Format Tooling Posture
- TypeScript strict flags exist in `tsconfig.json`, but source is primarily `.js`; `include` only covers `src/**/*.ts`.
- `package.json` defines lint scripts (`eslint src/**/*.ts`) and `lint-staged` with `prettier`, but no ESLint/Prettier config files are present in repo root.

## Import Organization

- JavaScript files generally group imports with external packages first, then local modules:
  - Example: `src/popup.js` imports `nostr-tools` and `qrcode` before local/runtime calls.
  - Example: `src/background.js` imports `pako`, `nostr-tools`, and `./wasm_crypto.js`.
- Dart files follow common Flutter grouping:
  - Dart SDK imports first (`dart:*`)
  - Package imports next (`package:flutter/...`)
  - Relative app imports last (`import 'sync/rust_sync_worker.dart';`) in `mobile/lib/main.dart`.
- Rust imports are grouped by crate/std in blocks at top of `pushstr_rust/src/api.rs`.

## Dominant Patterns

### Browser API Compatibility Wrapper
- A `makeBrowser()` compatibility shim appears in `src/background.js`, `src/popup.js`, and `src/options.js` to normalize `browser` vs `chrome` plus callback-to-promise adapters.
- Pattern: wrap callback APIs once, then use `await` everywhere else.

### Message-Driven Extension Architecture
- `src/background.js` uses a `handleMessage(msg)` dispatcher keyed on `msg.type` for command-style runtime requests.
- UI pages (`src/popup.js`, `src/options.js`) interact through `browser.runtime.sendMessage`.
- Expected operational failures return payload objects (`{ ok: false, error: "..." }`); hard failures throw and are caught at boundary handlers.

### Shared Reliability Helpers
- Retry helper `safeSend()` appears in `src/popup.js` and `src/options.js` with "port closed" retry logic.
- Rate limiting/coalescing uses timers and maps (`scheduleRefreshState`, cooldown maps) in `src/popup.js`.
- Single-flight/mutex patterns appear in Dart (`_AsyncMutex` in `mobile/lib/sync/*`) and Rust (`Once`, `Mutex`, queues in `pushstr_rust/src/api.rs`).

### Generated-Code Boundaries
- Do not hand-edit generated bridge files:
  - `mobile/lib/bridge_generated.dart/frb_generated.dart`
  - `mobile/lib/bridge_generated.dart/frb_generated.io.dart`
  - `mobile/lib/bridge_generated.dart/frb_generated.web.dart`
  - `pushstr_rust/src/frb_generated.rs`
- Source-of-truth for bridge generation config is `flutter_rust_bridge.yaml`.

## Error Handling Conventions

### JavaScript
- Boundary `try/catch` is standard for initialization and async event handlers:
  - Startup guard in `src/background.js` (`ready` async IIFE).
  - UI init guards in `src/popup.js` and `src/options.js`.
- Errors are logged with contextual prefixes (for example `[pushstr][popup]`), then surfaced to UI status or returned as `error` fields.
- Non-critical cleanup/fallback operations intentionally swallow errors with empty `catch` blocks (for example local cache cleanup in `src/popup.js`).

### Dart
- Background sync paths in `mobile/lib/sync/sync_controller.dart` and `mobile/lib/sync/rust_sync_worker.dart` favor resilience:
  - Catch, log (`debugPrint`), and continue when possible.
  - Return `null`/empty results on recoverable bridge failures.
- App entry and plugin initialization in `mobile/lib/main.dart` wrap platform-sensitive calls in `try/catch` to avoid crash loops.

### Rust
- Uses `anyhow::Result` with `Context` in `pushstr_rust/src/api.rs`.
- Validation failures return explicit errors (`anyhow::bail!`, parse failures, content checks).
- Queue and runtime orchestration isolate fallible external operations behind worker boundaries.

## Logging Conventions

- JavaScript logs with `console.info`, `console.log`, `console.warn`, `console.error` and prefixed tags:
  - `[pushstr][background]` in `src/background.js`
  - `[pushstr][popup]` in `src/popup.js`
  - `[pushstr][options]` in `src/options.js`
- Dart logging uses `debugPrint` in background/sync flows (`mobile/lib/sync/sync_controller.dart`) and occasional `print` in CLI-like helpers (`mobile/lib/sync/rust_sync_worker.dart` with lint ignore).
- Rust-side logging is minimal; most observable logs are emitted at Dart/JS boundaries.

## Comments and Documentation Style

- Code comments are mostly practical and local:
  - File-level purpose comments in `src/background.js`
  - Short intent comments for rate limits, cache behavior, and fallback logic in `src/popup.js` and `mobile/lib/sync/rust_sync_worker.dart`
- Generated files carry explicit "do not edit" headers (`mobile/lib/bridge_generated.dart/frb_generated.dart`, `pushstr_rust/src/frb_generated.rs`).
- Ad hoc test/integration notes are documented in `test/test.md`.

## Practical Authoring Rules For New Code

- Match language-native naming:
  - lowerCamelCase in JS/Dart functions
  - snake_case in Rust functions/modules
  - PascalCase for interfaces/classes/structs/enums.
- Keep extension cross-context communication message-driven through `browser.runtime.sendMessage` and `msg.type` handlers (`src/background.js`).
- Wrap unreliable boundaries (runtime messaging, storage, bridge calls, relay/network paths) with explicit `try/catch` and recoverable return values.
- Keep generated bridge files untouched and regenerate via `flutter_rust_bridge.yaml` workflow instead of manual edits.
- When editing JS extension files, preserve existing file-local quote convention (`src/background.js`/`src/options.js` use double quotes, `src/popup.js` uses single quotes) unless a coordinated formatting pass is planned.

---

*Convention analysis: 2026-03-05*
