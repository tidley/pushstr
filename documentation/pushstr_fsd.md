# Pushstr Functional Specification Document

Version: 0.1
Last updated: 2025-01-11
Owner: Pushstr

## 1. Purpose
Define the functional scope, behavior, and system boundaries for the Pushstr project, including the browser extension, mobile app, and Rust core.

## 2. Product Summary
Pushstr is a private, relay-backed messenger built on Nostr. It enables secure, end-to-end encrypted direct messaging (DMs) and file sharing between devices using NIP-04 and NIP-59 (giftwrap) flows, without centralized servers or accounts. Users control their keys and can create multiple identities for privacy.

## 3. Goals
- Fast, private, reliable messaging across devices.
- No central server dependency; use multiple relays for resilience.
- Simple onboarding: generate or import keys and start messaging quickly.
- Secure file transfer with end-to-end encryption and relay-backed transport.
- Compatibility with other Nostr clients (e.g., Amethyst) for DMs.

## 4. In-Scope Components
- Browser extension (Firefox/Chrome) for quick messaging and file sending.
- Mobile app (Android/iOS) for messaging, contacts, and media.
- Rust cryptography and relay client library exposed via Flutter FFI.
- Blossom-compatible encrypted media upload and download.

## 5. User Roles
- Primary user: individual who sends and receives DMs between devices.
- Secondary user: recipient using another Nostr client or Pushstr instance.

## 6. Functional Requirements

### 6.1 Onboarding & Profiles
- Generate a new Nostr keypair (nsec/npub).
- Import an existing nsec.
- Display the active npub and a QR code for sharing.
- Support multiple profiles (disposable or long-lived).
- Store profile-specific settings (contacts, messages, DM mode overrides).

### 6.2 Contacts
- Add a contact using npub or hex pubkey.
- Optionally store a nickname.
- Edit or delete contacts.
- Select an active contact for messaging.
- Add contact via QR scan.

### 6.3 Messaging
- Send and receive text DMs.
- Support NIP-04 (kind 4) encrypted DMs.
- Support NIP-59 giftwrap DMs (kind 1059 with sealed rumor kind 13 and inner kind 14).
- Tag messages with their DM type (04/17) in history.
- Allow per-contact DM mode override (NIP-04 vs giftwrap).
- Persist message history locally.

### 6.4 Attachments
- Attach images, audio, video, or arbitrary files.
- Encrypt files for the recipient before upload.
- Upload encrypted content to Blossom-compatible server.
- Transmit encrypted media descriptors in DMs.
- Render local previews for newly sent/received media.
- Allow download of attachments from the message list.
- Warn users about large files (default recommended max 20MB).

### 6.5 Relay Handling
- Connect to default public relays for general messaging.
- Connect to default DM relays (popular inbox relays).
- Publish a relay list (kind 10050) for DMs if none exists.
- Read recipient relay list (kind 10050) when sending giftwraps.
- Send events through all connected relays.

### 6.6 Sync & Background Processing (Mobile)
- Fetch recent messages at startup and on manual refresh.
- Poll for new messages while app is active.
- Optional foreground service for Android to keep connections alive.
- Periodic background fetch via Workmanager (Android).

### 6.7 Sharing (Mobile)
- Share text/media into Pushstr via system share sheet (Android).
- Pre-fill composer with shared content.
- Allow user to select recipient and send.

### 6.8 Settings & Utilities
- Export and back up nsec.
- Copy message contents to clipboard.
- Manage relay preferences (read-only defaults in current UI).
- Display status/errors in-app.

### 6.9 Logging & Diagnostics
- Log DM send/receive state transitions.
- Capture decrypt or parse errors for diagnostics.

## 7. Data Model

### 7.1 Profile
- nsec (private key)
- npub (public key)
- contacts list
- messages list
- DM mode overrides per contact
- giftwrap format preferences per contact

### 7.2 Contact
- pubkey (hex or npub)
- nickname

### 7.3 Message
- id
- from (pubkey)
- to (pubkey)
- created_at
- direction (in/out)
- kind (4 or 1059)
- dm_kind (nip04, nip59, legacy_giftwrap)
- content (plaintext)
- media (optional)

### 7.4 Media Descriptor
- url
- iv
- sha256
- cipher_sha256
- size
- mime
- encryption (aes-gcm)
- filename

### 7.5 Giftwrap Envelope
- Giftwrap event (kind 1059)
- Sealed rumor (kind 13) encrypted with NIP-44 v2
- Rumor/inner event (kind 14) unsigned

## 8. Workflows

### 8.1 Send Giftwrap DM
1. Compose message for contact.
2. Build inner kind 14 event with p-tag and alt.
3. Convert to rumor (unsigned JSON).
4. Encrypt rumor into sealed event (kind 13) using NIP-44.
5. Encrypt sealed event into giftwrap (kind 1059) with ephemeral key.
6. Publish to recipient DM relays.

### 8.2 Receive Giftwrap DM
1. Listen for kind 1059 events tagged with our pubkey.
2. Decrypt giftwrap with NIP-44.
3. Parse sealed event and decrypt rumor.
4. Render message in history and update contact activity.

### 8.3 Send NIP-04 DM
1. Encrypt message with NIP-04 using recipient pubkey.
2. Publish kind 4 event to relays.

### 8.4 Attachment Flow
1. Encrypt file using NIP-44-derived AES-GCM key.
2. Upload encrypted bytes to Blossom server.
3. Send media descriptor in DM.
4. On receive, decrypt descriptor and optionally decrypt file.

### 8.5 Contact Add via QR
1. Scan QR containing npub.
2. Normalize to hex pubkey.
3. Add to contact list.

## 9. Non-Functional Requirements
- Security: private keys never leave device; E2E encryption.
- Reliability: multi-relay delivery and redundancy.
- Performance: responsive UI; avoid main-thread blocking on mobile.
- Privacy: no analytics by default; optional telemetry disabled in manifest.
- Portability: Android/iOS mobile app and browser extension.

## 10. Dependencies
- Flutter (mobile UI).
- Rust + nostr-sdk (core crypto/relay client).
- Flutter Rust Bridge (FFI).
- Blossom server for encrypted media storage.
- Browser extension uses wasm crypto bundle for client-side operations.

## 11. Constraints & Risks
- Relay availability and policy differences may affect delivery.
- Background execution limits on mobile OSs can delay sync.
- Large attachments may exceed device memory limits.
- Cross-client NIP-59 compatibility depends on correct relay lists and encryption.

## 12. Out of Scope (Current)
- Group chats or public channels.
- Centralized push notification service.
- Server-side message storage beyond relays.
- Desktop native app.
