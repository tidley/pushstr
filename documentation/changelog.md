# Pushstr Changelog

## 0.1.0

### Added
- Linux desktop support for the mobile app, including a native `pushstr` app name and bundle wiring.
- Manual relay-list publishing for the active profile on both mobile and extension.
- Linux desktop compose shortcuts: Enter sends, Shift+Enter inserts a newline.
- Linux attach flow now opens the file picker directly and hides camera/video/record options.

### Improved
- Attachment descriptors now use a clean `k` + `nonce` format across Rust, mobile, and extension.
- Desktop attachment saves preserve the original filename and the saved-folder toast can open the file browser.
- Message text uses a lighter weight on desktop for a cleaner conversation view.
- The error banner can now be dismissed with a close button.

### Fixed
- Attachment decryption compatibility between Linux/mobile and the browser extension.
- Automatic relay resend behavior was disabled to avoid duplicate sends.
- Manual resend is blocked once a message already has a read receipt.
- Read-state handling now avoids stale resend prompts after acknowledgements.
- Linux startup no longer runs the Nostr init path on the UI isolate, which avoids the desktop "Not Responding" stall.
- Linux notifications now initialize with Linux settings, and the Android share listener is skipped on Linux.
- Default relay list expanded with `wss://nip17.com` and `wss://nip17.tomdwyer.uk`.
- Client identification marker was made less obvious by replacing the plaintext body tag.

## 0.0.8

### Added
- Attachment and link sharing from the mobile app, including decrypted media shares.
- Automatic mobile resend for outbound messages that do not come back from relays.
- Cancel/reset control in extension settings to discard unsaved edits.

### Improved
- Extension popout notifications now focus the existing chat window instead of opening duplicates.
- Extension media caching now uses bounded in-memory and persisted caches to reduce popup memory/storage use.
- Extension resend action is more visible in chat history.

### Fixed
- Extension read receipts no longer trigger repeated refresh/resync loops when duplicates arrive.
- Gap recovery reconnect requests are throttled to avoid repeated background sync churn.

## 0.0.7

### Added
- Read receipts with client tagging; receipts only sent between Pushstr clients.
- FIFO send queue in Rust to preserve ordering on burst sends.
- Sequence tags on DMs with gap detection and placeholder rendering (mobile + extension).
- Profile backup and import via JSON on mobile and extension.
- Extension keep-alive reconnect and relay expansion.
- Optimistic send in extension UI (instant history updates).

### Improved
- Faster mobile startup: cached messages load immediately; background refresh continues.
- Profile npub derivation moved to Rust; profile switching no longer reinitializes Rust in Settings.
- Message normalization and receipt parsing moved into Rust outputs.
- Extension history rendering, DM mode badges, and read receipt badges now show immediately.
- Reduced visual noise: toned down history accent green and tightened sent bubble spacing.
- Settings layout reorganized (Actions, Key Management, Backup/Restore, Connectivity).
- App version display pulled from mobile build metadata.
- Profile switches focus the most recent contact and clear history when none exist.
- Backup JSON format standardized to a profiles array, with multi-profile import support.
- Extension side panel layout tightened (wider pane, edit pen, topbar settings).
- Extension settings UI now mirrors mobile sections with active/all profile backups.

### Fixed
- Duplicate notifications for already-received messages.
- Giftwrap send serialization bug (missing tags on sealed events).
- Read receipt parsing when Pushstr client tag is present.
- Swipe-to-delete removal on mobile contacts list to prevent accidental deletes.
- Extension contact delete now removes the contact entry, not just the conversation.
- Extension notifications show npub/nickname instead of raw hex pubkey.
- Extension profile nickname refreshes on profile switch.

## 0.0.6

### Added
- Mobile app with NIP-04 + NIP-59 giftwrap DMs.
- Encrypted attachments via Blossom and inline media previews.
- Multi-profile support and relay management.
- Extension popout chat window and per-contact DM mode toggle.

### Improved
- Cross-client compatibility with legacy giftwrap.
- Relay retry/backoff and cooldown logic.

## 0.0.4

### Added
- Browser extension with giftwrap DMs and attachment support.
- Relay list storage and editing.

### Improved
- NIP-44 v2 compatibility updates.
- UI refinements for contacts and history.

## 0.0.1

### Added
- Initial prototype with NIP-04 DMs.
- Basic relay connectivity and key import/export.
