# Pushstr Changelog

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
