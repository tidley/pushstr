import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../bridge_generated.dart/api.dart' as api;
import '../bridge_generated.dart/frb_generated.dart';

/// Runs blocking Rust calls off the UI isolate with short waits.
class RustSyncWorker {
  /// Single-flight guard so only one Rust wait runs at a time across isolates.
  static final _mutex = _AsyncMutex();
  static final _sendMutex = _AsyncMutex();
  static const int _sendMutexRetries = 20;
  static const Duration _sendMutexDelay = Duration(milliseconds: 50);

  static Future<bool> _acquireSendMutex() async {
    for (var attempt = 0; attempt < _sendMutexRetries; attempt++) {
      if (await _sendMutex.tryAcquire()) return true;
      await Future.delayed(_sendMutexDelay);
    }
    return false;
  }

  /// Performs a bounded wait for new DMs on a background isolate.
  /// The `wait` should be short (2-3s) to avoid long blocks.
  static Future<String?> waitForNewDms({
    required String nsec,
    required Duration wait,
  }) async {
    if (nsec.isEmpty) return null;
    if (!await _mutex.tryAcquire()) return null;
    try {
      final seconds = wait.inSeconds.clamp(1, 3);
      return Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.waitForNewDms(timeoutSecs: BigInt.from(seconds));
        } catch (_) {
          // If init or wait fails, return empty to keep listener alive.
          return '';
        }
      });
    } finally {
      _mutex.release();
    }
  }

  /// Fetches recent DMs (bounded) on a background isolate.
  static Future<String?> fetchRecentDms({
    required String nsec,
    int limit = 50,
    int sinceTimestamp = 0,
  }) async {
    if (nsec.isEmpty) return null;
    if (!await _mutex.tryAcquire()) return null;
    try {
      return Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.fetchRecentDms(
            limit: BigInt.from(limit),
            sinceTimestamp: BigInt.from(sinceTimestamp),
          );
        } catch (_) {
          return null;
        }
      });
    } finally {
      _mutex.release();
    }
  }

  static Future<void> clearReturnedCache() async {
    try {
      await RustLib.init();
    } catch (_) {}
    try {
      api.clearReturnedEventsCache();
    } catch (_) {}
  }

  /// Sends a DM on a background isolate to avoid blocking the UI.
  static Future<String?> sendGiftDm({
    required String recipient,
    required String content,
    required String nsec,
    bool useNip44 = true,
  }) async {
    if (recipient.isEmpty || content.isEmpty || nsec.isEmpty) return null;
    if (!await _acquireSendMutex()) return null;
    try {
      // ignore: avoid_print
      print('[dm] sendGiftDm start recipient=${recipient.substring(0, 8)}');
      final eventId = await Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.sendGiftDm(recipient: recipient, content: content, useNip44: useNip44);
        } catch (e) {
          // ignore: avoid_print
          print('[dm] sendGiftDm isolate error: $e');
          return null;
        }
      });
      if (eventId != null) {
        // ignore: avoid_print
        print('[dm] sendGiftDm ok id=$eventId');
      }
      return eventId;
    } finally {
      _sendMutex.release();
    }
  }

  /// Sends a legacy NIP-04 DM (kind 4).
  static Future<String?> sendLegacyDm({
    required String recipient,
    required String message,
    required String nsec,
  }) async {
    if (recipient.isEmpty || message.isEmpty || nsec.isEmpty) return null;
    if (!await _acquireSendMutex()) return null;
    try {
      // ignore: avoid_print
      print('[dm] sendLegacyDm start recipient=${recipient.substring(0, 8)}');
      final eventId = await Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.sendDm(recipient: recipient, message: message);
        } catch (e) {
          // ignore: avoid_print
          print('[dm] sendLegacyDm isolate error: $e');
          return null;
        }
      });
      if (eventId != null) {
        // ignore: avoid_print
        print('[dm] sendLegacyDm ok id=$eventId');
      }
      return eventId;
    } finally {
      _sendMutex.release();
    }
  }

  /// Sends a legacy giftwrap DM compatible with the browser extension.
  static Future<void> sendLegacyGiftDm({
    required String recipient,
    required String message,
    required String nsec,
  }) async {
    if (recipient.isEmpty || message.isEmpty || nsec.isEmpty) return;
    if (!await _mutex.tryAcquire()) return;
    try {
      // ignore: avoid_print
      print('[dm] sendLegacyGiftDm start recipient=${recipient.substring(0, 8)}');
      final eventId = await Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.sendLegacyGiftDm(recipient: recipient, content: message);
        } catch (e) {
          // ignore: avoid_print
          print('[dm] sendLegacyGiftDm isolate error: $e');
          return null;
        }
      });
      if (eventId != null) {
        // ignore: avoid_print
        print('[dm] sendLegacyGiftDm ok id=$eventId');
      }
    } finally {
      _mutex.release();
    }
  }
}

class _AsyncMutex {
  Completer<void>? _completer;

  Future<bool> tryAcquire() async {
    if (_completer != null) return false;
    _completer = Completer<void>();
    return true;
  }

  void release() {
    _completer?.complete();
    _completer = null;
  }
}
