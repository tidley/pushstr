import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
      final contacts = _loadContacts(prefs, nsec);
      final seenState = _loadSeenState(prefs, nsec);
      var lastNotifiedTs = prefs.getInt('last_notified_ts_$nsec') ?? 0;
      var lastSeenTs = seenState.maxTs > 0 ? seenState.maxTs : (prefs.getInt('last_seen_ts_$nsec') ?? 0);
      if (lastSeenTs < lastNotifiedTs) {
        lastSeenTs = lastNotifiedTs;
      }
      await ensureDmChannel();

      Duration remaining() => budget - DateTime.now().difference(start);
      if (remaining().isNegative) return;

      final rustStart = DateTime.now();
      final result = await RustSyncWorker.fetchRecentDms(nsec: nsec, limit: 50);
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
      final incomingAll = decoded.whereType<Map<String, dynamic>>().map(_normalizedIncoming).toList();
      final newMessages = incomingAll.where((m) {
        final createdAt = _createdAtSeconds(m);
        final id = m['id']?.toString();
        if (id != null && seenState.ids.contains(id)) return false;
        if (id == null && createdAt > 0 && createdAt <= lastSeenTs) return false;
        return true;
      }).toList();

      if (newMessages.isEmpty) {
        debugPrint('[sync] no new incoming messages');
        return;
      }
      await _persistIncoming(nsec, newMessages);

      final notifiedIds = prefs.getStringList('notified_dm_ids') ?? <String>[];
      final seen = notifiedIds.toSet();
      var emitted = 0;
      var maxSeenTs = lastSeenTs;
      for (final msg in newMessages) {
        if (remaining().inMilliseconds <= 0) break;
        if (emitted >= 3) break; // rate-limit per tick
        final id = msg['id']?.toString();
        if (id != null && seen.contains(id)) continue;
        final createdAt = _createdAtSeconds(msg);
        if (createdAt > 0 && createdAt <= lastNotifiedTs) continue; // don't notify old items
        if (id != null && seenState.ids.contains(id)) continue; // already displayed/stored
        final from = (msg['from'] ?? '').toString();
        final content = (msg['content'] ?? '').toString();
        await showDmNotification(
          title: 'DM from ${_displayName(from, contacts)}',
          body: content.isNotEmpty ? content : 'New message',
        );
        emitted++;
        if (id != null && id.isNotEmpty) {
          seen.add(id);
        }
        if (createdAt > maxSeenTs) {
          maxSeenTs = createdAt;
        }
      }

      // Trim cache
      final trimmed = seen.toList().reversed.take(50).toList();
      await prefs.setStringList('notified_dm_ids', trimmed);
      if (maxSeenTs > lastSeenTs) {
        await prefs.setInt('last_seen_ts_$nsec', maxSeenTs);
      }
      if (emitted > 0 && maxSeenTs > lastNotifiedTs) {
        lastNotifiedTs = maxSeenTs;
        await prefs.setInt('last_notified_ts_$nsec', lastNotifiedTs);
      }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      debugPrint('[sync] done trigger=$trigger emitted=$emitted rust=${rustMs}ms total=${elapsed}ms');
      await _updateForegroundStatus(DateTime.now());
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

  static Map<String, String> _loadContacts(SharedPreferences prefs, String nsec) {
    final key = 'contacts_$nsec';
    final entries = prefs.getStringList(key) ?? prefs.getStringList('contacts') ?? <String>[];
    final Map<String, String> map = {};
    for (final entry in entries) {
      final parts = entry.split('|');
      if (parts.length >= 2) {
        final nickname = parts[0].trim();
        final pubkey = parts[1].trim();
        if (pubkey.isNotEmpty) {
          map[pubkey] = nickname;
        }
      }
    }
    return map;
  }

  static String _displayName(String pubkey, Map<String, String> contacts) {
    final nick = contacts[pubkey]?.trim();
    if (nick != null && nick.isNotEmpty) return nick;
    return _shortPubkey(pubkey);
  }

  static Future<void> _updateForegroundStatus(DateTime ts) async {
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (!running) return;
      final h = ts.hour.toString().padLeft(2, '0');
      final m = ts.minute.toString().padLeft(2, '0');
      final s = ts.second.toString().padLeft(2, '0');
      final text = 'Staying connected · Last sync $h:$m:$s';
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Pushstr running',
        notificationText: text,
      );
    } catch (_) {
      // best-effort; ignore update errors
    }
  }

  static Future<void> _persistIncoming(String nsec, List<Map<String, dynamic>> incoming) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'pending_dms_$nsec';
      final existingJson = prefs.getString(key);
      final List<Map<String, dynamic>> existing = [];
      if (existingJson != null && existingJson.isNotEmpty) {
        try {
          final parsed = jsonDecode(existingJson) as List<dynamic>;
          for (final item in parsed) {
            if (item is Map<String, dynamic>) {
              existing.add(item);
            } else if (item is Map) {
              existing.add(Map<String, dynamic>.from(item));
            }
          }
        } catch (_) {
          // ignore parse errors
        }
      }
      final seen = existing.map((e) => e['id']?.toString()).whereType<String>().toSet();
      for (final msg in incoming) {
        final id = msg['id']?.toString();
        if (id != null && seen.contains(id)) continue;
        existing.add(_normalizedIncoming(msg));
        if (id != null) seen.add(id);
      }
      // keep last 200
      final trimmed = existing.length > 200 ? existing.sublist(existing.length - 200) : existing;
      await prefs.setString(key, jsonEncode(trimmed));
    } catch (_) {
      // best-effort
    }
  }

  static _SeenState _loadSeenState(SharedPreferences prefs, String nsec) {
    final ids = <String>{};
    var maxTs = 0;

    void ingestList(List<dynamic>? list) {
      if (list == null) return;
      for (final item in list) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final id = map['id']?.toString();
          if (id != null) ids.add(id);
          final ts = _createdAtSeconds(map);
          if (ts > maxTs) maxTs = ts;
        }
      }
    }

    String? safeGet(String key) {
      try {
        return prefs.getString(key);
      } catch (_) {
        return null;
      }
    }

    for (final key in ['messages_$nsec', 'messages', 'pending_dms_$nsec', 'pending_dms']) {
      final json = safeGet(key);
      if (json == null || json.isEmpty) continue;
      try {
        final list = jsonDecode(json) as List<dynamic>;
        ingestList(list);
      } catch (_) {
        // ignore bad json
      }
    }
    return _SeenState(ids: ids, maxTs: maxTs);
  }

  static int _createdAtSeconds(Map<String, dynamic> msg) {
    final raw = msg['created_at'];
    int ts;
    if (raw is int) ts = raw;
    else if (raw is double) ts = raw.round();
    else if (raw is String) {
      ts = int.tryParse(raw) ?? 0;
    } else {
      ts = 0;
    }
    if (ts <= 0) return 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Clamp to avoid future timestamps blocking later messages.
    if (ts > now + 300) return now;
    return ts;
  }

  static Map<String, dynamic> _normalizedIncoming(Map<String, dynamic> msg) {
    final copy = Map<String, dynamic>.from(msg);
    final dir = (copy['direction'] ?? copy['dir'] ?? '').toString().toLowerCase();
    if (dir == 'incoming') {
      copy['direction'] = 'in';
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ts = _createdAtSeconds(copy);
    copy['created_at'] = ts > 0 ? ts : nowSec;
    return copy;
  }
}

class _SeenState {
  final Set<String> ids;
  final int maxTs;

  _SeenState({required this.ids, required this.maxTs});
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
