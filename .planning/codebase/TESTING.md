# Testing Patterns

**Analysis Date:** 2026-03-05

## Test Framework Matrix

### JavaScript / Extension
- Runner: Vitest (`vitest` in `package.json`, config in `vitest.config.ts`)
- Environment: `jsdom` in `vitest.config.ts`
- Coverage provider: V8 with reporters `text`, `json`, `html` in `vitest.config.ts`

### Browser E2E
- Runner: Playwright (`@playwright/test` in `package.json`, config in `playwright.config.ts`)
- Target project: Firefox desktop profile in `playwright.config.ts`

### Flutter / Mobile
- Runner: `flutter_test` in `mobile/pubspec.yaml`
- Analyzer/lint baseline: `flutter_lints` via `mobile/analysis_options.yaml`

### Rust / WASM
- No committed Rust unit/integration test modules detected in:
  - `pushstr_rust/src/*.rs`
  - `wasm_crypto/src/*.rs`
- Rust code is primarily exercised via integration harnesses (`mobile/tools/ffi_dm_test.dart`, `scripts/js_dm_test.js`) rather than `cargo test` fixtures.

## Run Commands

### Root Node Commands (`package.json`)
```bash
npm test                 # Vitest run
npm run test:watch       # Vitest watch
npm run test:coverage    # Vitest coverage with V8 reporters
npm run test:e2e         # Playwright run
```

### Flutter Commands (`mobile/`)
```bash
flutter test             # Runs widget tests in mobile/test/
flutter analyze          # Static analysis using mobile/analysis_options.yaml
```

### Manual Integration Harnesses
```bash
node scripts/js_dm_test.js [send|listen|both]
dart run mobile/tools/ffi_dm_test.dart --nsec <nsec> --peer <npub|hex> --mode <send|listen|both>
```

## Test File Organization

## Current Layout

Only one standard automated test file is present:
- `mobile/test/widget_test.dart`

Manual test/harness files:
- `scripts/js_dm_test.js` (Node + Nostr relay harness)
- `mobile/tools/ffi_dm_test.dart` (Dart + Rust bridge harness)
- `test/test.md` (manual command cookbook)

Declared-but-missing test tree for extension tests:
- `vitest.config.ts` references `./tests/setup.ts` (not present)
- `playwright.config.ts` sets `testDir: './tests/e2e'` (directory not present)

## Naming Conventions

- Flutter widget tests follow default `*_test.dart` naming (`mobile/test/widget_test.dart`).
- No `*.test.js`, `*.test.ts`, or `*.spec.*` files are present under `src/`, `scripts/`, `pushstr_rust/`, or `wasm_crypto/`.
- Integration harnesses are named by purpose (`js_dm_test.js`, `ffi_dm_test.dart`) and run directly as scripts.

## Test Structure Patterns

### Widget Test Pattern (Flutter)
`mobile/test/widget_test.dart` uses a minimal smoke pattern:
1. `testWidgets(...)` entry
2. `pumpWidget(const PushstrApp())`
3. single UI assertion (`expect(find.text(...), findsOneWidget)`)

This is a shallow render check and does not validate relay, storage, notification, or bridge behavior.

### Scripted Integration Pattern
Both `scripts/js_dm_test.js` and `mobile/tools/ffi_dm_test.dart` follow CLI-driven integration flows:
1. Parse CLI/env args for identity/peer
2. Initialize crypto/runtime (WASM or Rust bridge)
3. Send and/or listen on real relay connections
4. Print outcomes to stdout/stderr

These scripts are useful for protocol interoperability checks, but are not assertion-driven test suites and are not integrated into the standard test runners.

## Mocking Posture

## In-Repo Usage

- No active mocking examples are present in committed tests:
  - no `vi.mock(...)` usage in JS/TS test files (no JS/TS test files exist)
  - no Flutter mock libraries in `mobile/test/widget_test.dart`
- Runtime integration scripts use live dependencies (real relays, real crypto paths).

## Available Mocking Hooks

- Vitest supports module and function mocks by default, configured in `vitest.config.ts`.
- Flutter bridge layer exposes mock entrypoint support in generated code:
  - `RustLib.initMock(...)` in `mobile/lib/bridge_generated.dart/frb_generated.dart`
  - This can enable deterministic unit tests for Dart logic without loading native libraries.

## Practical Mocking Guidance For This Repo

- Mock at boundaries:
  - Extension runtime APIs (`browser.runtime.sendMessage`, `browser.storage`) for unit tests of `src/popup.js` and `src/options.js`
  - Network/relay clients and upload endpoints for `src/background.js`
  - Rust bridge calls for Dart-side controller logic in `mobile/lib/sync/sync_controller.dart`
- Keep crypto algorithm correctness checks in integration tests (WASM/Rust paths), not mocks.

## Fixtures and Test Data

- No shared fixture/factory directories are present (`tests/fixtures`, `mobile/test/fixtures`, or similar not detected).
- Test data is inline:
  - hardcoded smoke expectation in `mobile/test/widget_test.dart`
  - runtime-generated messages and CLI args in `scripts/js_dm_test.js` and `mobile/tools/ffi_dm_test.dart`

## Coverage Posture

## Configured

- JS coverage command exists (`npm run test:coverage`) with config in `vitest.config.ts`.
- Exclusions configured in `vitest.config.ts`:
  - `node_modules/`
  - `tests/`
  - `scripts/`
  - `dist/`
  - `vendor/`
  - `*.config.*`

## Enforcement

- No coverage thresholds are defined in `vitest.config.ts`.
- No CI workflow files are detected under `.github/workflows/` to enforce coverage or test pass gates.
- Given absent JS/TS test files, configured coverage tooling is present but effective JS coverage is functionally near-zero until tests are added.

## Test-Type Coverage Map

- Unit tests:
  - Minimal Flutter UI smoke in `mobile/test/widget_test.dart`
  - No extension JS unit tests
  - No Rust unit tests
- Integration tests:
  - Manual CLI harnesses only (`scripts/js_dm_test.js`, `mobile/tools/ffi_dm_test.dart`)
- E2E tests:
  - Playwright config exists (`playwright.config.ts`) but no committed test specs in `tests/e2e/`

## Quality Risks To Preserve In Planning

- Config drift risk: declared test setup paths (`vitest.config.ts`, `playwright.config.ts`) do not match committed directories/files.
- Reliability risk: integration checks rely on live relays, so results vary with network and relay state.
- Regression risk: core extension flows in `src/background.js`, `src/popup.js`, and `src/options.js` have no automated assertions.
- Bridge risk: Rust/Dart boundary code in `pushstr_rust/src/api.rs` and `mobile/lib/sync/*.dart` lacks deterministic automated tests despite high coupling.

---

*Testing analysis: 2026-03-05*
