# Pushstr Mobile - Fixes Needed

## Summary

The mobile directory has been consolidated from two separate implementations. The current code has working crypto primitives but needs updates for Flutter/Dart v3 compatibility.

## Issues Found

### 1. Pointycastle v3 API Changes
The crypto implementations (nip04.dart, nip44.dart, secp256k1.dart) use pointycastle v3.9.1 with the old API:
- `KeyIvParameters` has been removed/changed
- `HKDFParameters` API changed
- ECCurve methods changed (`q` getter, `createPoint`, etc.)
- Null-safety issues with EC point operations

**Solution**: Upgrade pointycastle to v4.0.0 and update crypto code, OR use a proven Nostr Dart library like `nostr_core_dart` or similar.

### 2. Bech32 Helper Functions Missing
`key_manager.dart` uses `toWords()` and `fromWords()` which aren't imported.

**Solution**: Import from `package:bech32/bech32.dart` properly or use the library's API correctly.

### 3. Test Files Need Updating
`test/widget_test.dart` references old widget structure.

**Solution**: Update test to match current `MyApp` widget that requires `state` parameter.

## Desktop Extension Features (Implemented)

The browser extension has these features that the mobile app should match:

✅ **Core Features:**
- Multi-key management (generate, import, export nsec/npub)
- Per-key recipient lists with nicknames
- NIP-04 encrypted direct messages (kind 4)
- NIP-17 Giftwrapped DMs (kind 1059) - optional
- NIP-44 encryption - optional
- Message history (last 200 messages)
- Relay pool management
- Context menu integration (desktop only)
- Browser notifications
- File upload to Blossom server with NIP-18 format

## Current Mobile Implementation Status

### ✅ Working:
- Project structure (Flutter/Android)
- Key management UI (generate, import, export)
- Basic crypto primitives structure
- Storage (flutter_secure_storage for keys, shared_preferences for settings)

### ⚠️ Needs Fixes:
- Crypto libraries (point ycastle v3→v4 upgrade OR library replacement)
- Bech32 encoding/decoding
- WebSocket relay connections
- DM send/receive flow
- Message persistence
- UI for contacts and messaging

### 📋 Not Yet Implemented:
- NIP-17 Giftwrapped DMs
- NIP-44 encryption option
- File upload/download
- Push notifications (Android)
- QR code for key import/export

## Recommended Next Steps

### Option A: Use Proven Libraries (RECOMMENDED)
1. Replace custom crypto with `nostr_core_dart` or `dart_nostr`
2. These handle NIP-04, NIP-44, signing, verification
3. Focus on UI and UX instead of crypto debugging

### Option B: Fix Current Implementation
1. Upgrade to pointycastle v4.0.0
2. Update all crypto code for new API
3. Fix bech32 helpers
4. Test thoroughly

## Companion App Goal

The mobile app should be an excellent companion to the desktop extension:

**Must Have:**
- Same key management (generate/import nsec, use same keys across devices)
- Send/receive NIP-04 DMs to same contacts
- Connect to same relays
- Message history syncs via Nostr (not local sync)
- Clean, simple UI

**Nice to Have:**
- Push notifications for incoming DMs
- QR code for easy key sharing between devices
- File attachments (Blossom)
- NIP-17 giftwrap support

## Files Structure

```
mobile/
├── lib/
│   ├── main.dart                 # Main app (key mgmt UI only, no crypto yet)
│   └── src/
│       ├── crypto/
│       │   ├── nip04.dart        # ⚠️ Needs pointycastle v4 fixes
│       │   ├── nip44.dart        # ⚠️ Needs pointycastle v4 fixes
│       │   ├── secp256k1.dart    # ⚠️ Needs pointycastle v4 fixes
│       │   └── bytes.dart        # ✅ OK
│       └── nostr/
│           ├── event.dart        # ✅ OK
│           ├── key_manager.dart  # ⚠️ Needs bech32 fixes
│           └── relay_pool.dart   # ✅ OK structure, needs testing
├── pubspec.yaml                  # Dependencies configured
└── README.md                     # Documentation
```

## Quick Start to Fix

```bash
cd mobile

# Option A: Use proven library
flutter pub remove pointycastle hex crypto convert
flutter pub add nostr_core_dart
# Then update imports and use library's crypto functions

# Option B: Upgrade pointycastle
flutter pub upgrade pointycastle
# Then fix all the crypto files for v4 API

flutter pub get
flutter analyze
flutter test
flutter run
```
