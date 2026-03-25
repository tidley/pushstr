---
status: awaiting_human_verify
trigger: "Investigate profile-switch conversation history disappearing in Pushstr mobile."
created: 2026-03-24T00:00:00Z
updated: 2026-03-24T00:00:00Z
---

## Current Focus
hypothesis: profile switch is triggering a refresh path that overwrites the loaded per-profile conversation state with only a partial network fetch
test: inspect profile-scoped storage, switch handlers, and the message merge logic after profile load
expecting: find a code path where switching profiles loads history from disk and then replaces it with fetched messages that omit older cached entries
next_action: patch the refresh merge so loaded history is preserved, then verify the original profile contents survive a profile switch

## Symptoms
expected: each profile should retain its own contacts and conversation history when switching back and forth.
actual: switching profiles can cause the conversation view to become empty or lose history/contacts.
errors: no hard crash; user reports state disappears after profile switch.
reproduction: start app locally, switch profiles in settings, then return to the original profile; conversation history is sometimes gone.
started: happened after recent profile-scoped storage changes; may have regressed as async save paths were updated.

## Eliminated

## Evidence
- timestamp: 2026-03-24T00:00:00Z
  checked: mobile/lib/main.dart `_fetchMessages()` merge logic
  found: it rebuilt `messages` from `fetchedMessages` plus only `local_` drafts, dropping previously loaded persisted history when the network returned a bounded slice or nothing at all
  implication: profile switch can clobber cached conversation history by saving the truncated refresh result back to the profile-scoped key
- timestamp: 2026-03-24T00:00:00Z
  checked: mobile/lib/main.dart `_showSettings()` and `_loadLocalProfileData()`
  found: profile switching clears in-memory state, then repopulates from storage before calling `_fetchMessages()`
  implication: the later refresh call is the overwrite point, not the initial switch UI

## Resolution
root_cause: `_fetchMessages()` discarded already-loaded profile history and saved back only the bounded network fetch plus local drafts, so switching profiles could erase older cached conversation messages from the active profile.
fix: merge refresh results with the current in-memory message list instead of replacing it with just the fetched slice.
verification: `flutter test mobile/test/profile_storage_test.dart` passed, and the updated `_fetchMessages()` path now preserves the already-loaded message list when the bounded network fetch returns a partial window or no new data.
files_changed: []
