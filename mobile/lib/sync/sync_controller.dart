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
      final lastNotifiedTs = prefs.getInt('last_notified_ts_$nsec') ?? 0;
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
      await _persistIncoming(nsec, incoming);

      final notifiedIds = prefs.getStringList('notified_dm_ids') ?? <String>[];
      final seen = notifiedIds.toSet();
      var emitted = 0;
      var maxSeenTs = lastNotifiedTs;
      for (final msg in incoming) {
        if (remaining().inMilliseconds <= 0) break;
        if (emitted >= 3) break; // rate-limit per tick
        final id = msg['id']?.toString();
        if (id != null && seen.contains(id)) continue;
        final createdAt = _createdAtSeconds(msg);
        if (createdAt > 0 && createdAt <= lastNotifiedTs) continue; // don't notify old items
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
      if (maxSeenTs > lastNotifiedTs) {
        await prefs.setInt('last_notified_ts_$nsec', maxSeenTs);
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

  static int _createdAtSeconds(Map<String, dynamic> msg) {
    final raw = msg['created_at'];
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    if (raw is String) {
      return int.tryParse(raw) ?? 0;
    }
    return 0;
  }

  static Map<String, dynamic> _normalizedIncoming(Map<String, dynamic> msg) {
    final copy = Map<String, dynamic>.from(msg);
    final dir = (copy['direction'] ?? copy['dir'] ?? '').toString().toLowerCase();
    if (dir == 'incoming') {
      copy['direction'] = 'in';
    }
    if (copy['created_at'] == null) {
      copy['created_at'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
    return copy;
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
