---
status: awaiting_human_verify
trigger: "Investigate Pushstr DM sync reliability, especially NIP-17/websocket receive handling and the first-load / sync window behavior."
created: 2026-03-24T00:00:00Z
updated: 2026-03-24T00:00:00Z
---

## Current Focus
hypothesis: Cold-start cache priming writes a partial DM window into persistent storage and advances the watermark, so later fetches treat that partial window as complete and stop backfilling.
test: Verify that `_primeProfileData` no longer writes `last_seen_ts`, that initial fetch backfills whenever no watermark exists, and that background sync starts from `0` instead of a 10-minute window.
expecting: The app should hydrate the same history on first load that the relay-backed fetches can access, without locking itself into a partial sync cursor.
next_action: Verify the edited paths and check for any remaining skip conditions.

## Symptoms
expected: Pushstr should reliably receive new NIP-17 messages like Amethyst/OxChat and backfill history on cold start.
actual: Some NIP-17 messages appear to be missed; first startup may only fetch a partial conversation set.
errors: No explicit runtime error, but sync completeness is questionable.
reproduction: Start with a profile that has NIP-17 DMs on the relay set; observe that Pushstr sometimes loads fewer conversations/messages than other clients.
started: Ongoing sync reliability concerns.

## Eliminated

## Evidence
- timestamp: 2026-03-24T00:00:00Z
  checked: mobile/lib/main.dart `_primeProfileData`
  found: It fetched `limit: 100` DMs, persisted them to `_messagesKeyFor(nsec)`, and also wrote `_lastSeenKeyFor(nsec)` from the newest message in that partial page.
  implication: The priming step could seed a partial history window as if it were a complete sync state.
- timestamp: 2026-03-24T00:00:00Z
  checked: mobile/lib/main.dart `_fetchMessages`
  found: Cold-start backfill only ran when `existingLen == 0 && lastSeen == 0`.
  implication: Any primed cache with a nonzero watermark would permanently skip the deeper history walk.
- timestamp: 2026-03-24T00:00:00Z
  checked: mobile/lib/sync/sync_controller.dart `performSyncTick`
  found: The background sync used `lastSeen` if present, otherwise only fetched the last 10 minutes.
  implication: A fresh or partially seeded profile could miss older NIP-17 messages outside that narrow window.

## Resolution
root_cause: A bounded warm-cache path was being treated as a sync watermark. `_primeProfileData` persisted only the latest 100 DMs and advanced `last_seen_ts`, `_fetchMessages` only backfilled when both the cache and watermark were empty, and background sync fell back to a 10-minute window when no watermark existed.
fix: Stop writing `last_seen_ts` from `_primeProfileData`, allow initial backfill whenever no watermark exists, and make background sync start from `0` instead of a 10-minute fallback.
verification:
  static: "Edited sync paths are internally consistent; flutter analyze completed with only pre-existing lint/info warnings, no new errors from the change."
  runtime: ""
files_changed:
  - mobile/lib/main.dart
  - mobile/lib/sync/sync_controller.dart
