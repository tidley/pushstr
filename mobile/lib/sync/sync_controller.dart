import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications.dart';
import 'rust_sync_worker.dart';

enum SyncTrigger { foregroundService, backgroundFetch, manual }

class SyncController {
  static final _lock = _AsyncMutex();

  /// Performs one bounded sync tick. Returns quickly and never overlaps.
  static Future<void> performSyncTick({
    required SyncTrigger trigger,
    required Duration budget,
  }) async {
    final start = DateTime.now();
    if (!await _lock.tryAcquire()) {
      debugPrint('[sync] skip overlapping tick ($trigger)');
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final nsec = prefs.getString('nostr_nsec') ?? '';
      if (nsec.isEmpty) {
        debugPrint('[sync] skip (no nsec)');
        return;
      }
      await ensureDmChannel();

      Duration remaining() => budget - DateTime.now().difference(start);
      if (remaining().isNegative) return;

      final wait = Duration(seconds: remaining().inSeconds.clamp(1, 3));
      final rustStart = DateTime.now();
      final result = await RustSyncWorker.waitForNewDms(nsec: nsec, wait: wait);
      final rustMs = DateTime.now().difference(rustStart).inMilliseconds;
      if (result == null || result.isEmpty || result == '[]') {
        debugPrint('[sync] no data (trigger=$trigger, rust=${rustMs}ms)');
        return;
      }

      if (remaining().isNegative) {
        debugPrint('[sync] budget exceeded before parse');
        return;
      }

      final decoded = await Isolate.run(() => jsonDecode(result) as List<dynamic>);
      final incoming = decoded
          .whereType<Map<String, dynamic>>()
          .where((m) {
            final dir = (m['direction'] ?? m['dir'] ?? '').toString().toLowerCase();
            return dir == 'incoming' || dir == 'in';
          })
          .toList();

      if (incoming.isEmpty) {
        debugPrint('[sync] no incoming messages');
        return;
      }

      final notifiedIds = prefs.getStringList('notified_dm_ids') ?? <String>[];
      final seen = notifiedIds.toSet();
      var emitted = 0;
      for (final msg in incoming) {
        if (remaining().inMilliseconds <= 0) break;
        if (emitted >= 3) break; // rate-limit per tick
        final id = msg['id']?.toString();
        if (id != null && seen.contains(id)) continue;
        final from = (msg['from'] ?? '').toString();
        final content = (msg['content'] ?? '').toString();
        await showDmNotification(
          title: 'New message from ${_shortPubkey(from)}',
          body: content.isNotEmpty ? content : 'New message',
        );
        emitted++;
        if (id != null && id.isNotEmpty) {
          seen.add(id);
        }
      }

      // Trim cache
      final trimmed = seen.toList().reversed.take(50).toList();
      await prefs.setStringList('notified_dm_ids', trimmed);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      debugPrint('[sync] done trigger=$trigger emitted=$emitted rust=${rustMs}ms total=${elapsed}ms');
    } catch (e, st) {
      debugPrint('[sync] error: $e\n$st');
    } finally {
      _lock.release();
    }
  }

  static String _shortPubkey(String pubkey) {
    if (pubkey.length <= 16) return pubkey;
    return '${pubkey.substring(0, 8)}...${pubkey.substring(pubkey.length - 8)}';
  }
}

class _AsyncMutex {
  Completer<void>? _c;

  Future<bool> tryAcquire() async {
    if (_c != null) return false;
    _c = Completer<void>();
    return true;
  }

  void release() {
    _c?.complete();
    _c = null;
  }
}
