# Pushstr Mobile

A Flutter companion app for Pushstr - send and receive push notifications using Nostr Giftwrapped DMs.

## Features

- **Key Management**: Generate or import Nostr keys (nsec/npub format)
- **Secure Storage**: Private keys stored securely using flutter_secure_storage
- **Relay Pool**: Connect to multiple Nostr relays simultaneously
- **NIP-17 Giftwrap**: Enhanced privacy with ephemeral envelope encryption
- **Dual Encryption**: Support for both NIP-04 and NIP-44 encryption
- **Push Notifications**: Local notifications for incoming messages
- **Recipient Management**: Store and manage contact list
- **Message History**: View sent and received messages
- **Cross-Platform**: Supports both Android and iOS

## Architecture

### Core Services

1. **NostrCrypto** (`lib/utils/nostr_crypto.dart`)
   - secp256k1 key generation and management
   - NIP-04 (AES-256-CBC) encryption/decryption
   - NIP-44 (ChaCha20-Poly1305) encryption/decryption
   - Bech32 encoding/decoding for nsec/npub

2. **NostrEvent** (`lib/models/nostr_event.dart`)
   - Event creation and signing
   - NIP-17 Giftwrap helpers
   - Plain NIP-04 DM support
   - Event validation

3. **RelayPool** (`lib/services/relay_pool.dart`)
   - WebSocket connection management
   - Automatic reconnection
   - Event subscription and publishing
   - Multi-relay support

4. **KeyManager** (`lib/services/key_manager.dart`)
   - Secure key storage
   - Key import/export
   - Multiple key support
   - Key switching

5. **PushstrService** (`lib/services/pushstr_service.dart`)
   - Main app state management
   - Message send/receive orchestration
   - Settings persistence
   - Recipient management

6. **NotificationService** (`lib/services/notification_service.dart`)
   - Local push notifications
   - Android 13+ permission handling
   - iOS notification support

### UI Screens

- **SetupScreen**: Initial key generation/import
- **HomeScreen**: Message list and status
- **SendMessageScreen**: Compose and send messages
- **SettingsScreen**: Configure keys, relays, and protocol options

## Getting Started

### Prerequisites

- Flutter SDK 3.10+
- Android SDK (for Android development)
- Xcode (for iOS development, macOS only)

### Installation

1. Clone the repository:
   ```bash
   cd pushstr_mobile
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run on Android:
   ```bash
   flutter run
   ```

4. Build APK:
   ```bash
   flutter build apk --release
   ```

5. Build iOS (macOS only):
   ```bash
   flutter build ios --release
   ```

## Configuration

### Android

The app is configured with:
- **minSdk**: 24 (Android 7.0)
- **targetSdk**: 34 (Android 14)
- **Permissions**: Internet, notifications, wake lock

### iOS

Ensure you have proper code signing configured in Xcode. Push notification entitlements are included.

## Usage

### First Launch

1. **Generate Key**: Create a new Nostr identity
2. **Import Key**: Use an existing nsec key
3. **Add Recipients**: Configure who you want to send messages to
4. **Configure Relays**: Default relays are pre-configured

### Sending Messages

1. Tap the **Send** button
2. Select a recipient (or add a new one)
3. Type your message
4. Tap **Send Message**

### Settings

- **Protocol**: Toggle Giftwrap (NIP-17) and NIP-44 encryption
- **Relays**: Add/remove Nostr relays
- **Recipients**: Manage your contact list
- **Keys**: Export your private key (nsec)

## Security Notes

⚠️ **Important**:
- Your private key (nsec) is stored securely on device
- Never share your nsec with anyone
- Export and backup your nsec in a secure location
- Messages are end-to-end encrypted using Nostr protocols

## Compatibility

This app is compatible with:
- Pushstr browser extension
- Other NIP-17 compatible Nostr clients
- NIP-04 DM clients (when Giftwrap is disabled)

## Development

### Project Structure

```
lib/
├── main.dart                    # App entry point
├── models/
│   └── nostr_event.dart        # Event models
├── screens/
│   ├── home_screen.dart        # Main message list
│   ├── send_message_screen.dart # Send UI
│   ├── settings_screen.dart    # Settings UI
│   └── setup_screen.dart       # Initial setup
├── services/
│   ├── key_manager.dart        # Key storage
│   ├── notification_service.dart # Push notifications
│   ├── pushstr_service.dart    # Main app service
│   └── relay_pool.dart         # Relay connections
└── utils/
    └── nostr_crypto.dart       # Crypto utilities
```

### Testing

Run tests:
```bash
flutter test
```

### Known Limitations

1. **Schnorr Signatures**: Currently using ECDSA as PointyCastle doesn't have native Schnorr support. For production, consider using a proper Schnorr implementation.

2. **NIP-44**: Simplified implementation. Full NIP-44 spec with ChaCha20-Poly1305 should be implemented for production.

3. **Background Service**: Messages are only received when app is active. Consider implementing a background service for Android/iOS.

4. **Message Persistence**: Messages are stored in memory. Consider adding local database persistence.

## Contributing

This is a companion app to the Pushstr browser extension. Contributions are welcome!

## License

Same as main Pushstr project.
