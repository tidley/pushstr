import 'dart:async';
import 'dart:isolate';

import '../bridge_generated.dart/api.dart' as api;
import '../bridge_generated.dart/frb_generated.dart';

/// Runs blocking Rust calls off the UI isolate with short waits.
class RustSyncWorker {
  /// Single-flight guard so only one Rust wait runs at a time across isolates.
  static final _mutex = _AsyncMutex();

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
        } catch (_) {
          // Ignore double-init warnings across isolates.
        }
        try {
          api.initNostr(nsec: nsec);
        } catch (_) {
          // If init fails, surface empty result to avoid crashes.
          return '';
        }
        return api.waitForNewDms(timeoutSecs: BigInt.from(seconds));
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
        } catch (_) {}
        try {
          api.initNostr(nsec: nsec);
        } catch (_) {}
        try {
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
