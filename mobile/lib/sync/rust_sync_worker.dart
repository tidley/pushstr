import 'dart:async';
import 'dart:isolate';

import '../bridge_generated.dart/api.dart' as api;
import '../bridge_generated.dart/frb_generated.dart';

/// Runs blocking Rust calls off the UI isolate with short waits.
class RustSyncWorker {
  static final _dmWorker = _DmWaitWorker();
  static final _mutex = _AsyncMutex();

  /// Performs a bounded wait for new DMs on a background isolate.
  /// The `wait` should be short (2-3s) to avoid long blocks.
  static Future<String?> waitForNewDms({
    required String nsec,
    required Duration wait,
  }) async {
    if (nsec.isEmpty) return null;
    return _dmWorker.waitForNewDms(nsec: nsec, wait: wait);
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

  /// Fetches contact names from profile metadata on a background isolate.
  static Future<String?> fetchContactNames({
    required String nsec,
    required List<String> pubkeys,
  }) async {
    if (nsec.isEmpty || pubkeys.isEmpty) return null;
    if (!await _mutex.tryAcquire()) return null;
    try {
      return Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.fetchContactNames(pubkeys: pubkeys);
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

  /// Publishes the active profile relay list as a NIP-65 kind 10002 event.
  static Future<String?> publishRelayList({
    required String nsec,
    required List<String> relays,
  }) async {
    if (nsec.isEmpty || relays.isEmpty) return null;
    if (!await _mutex.tryAcquire()) return null;
    try {
      // ignore: avoid_print
      print('[relay-list] publishRelayList start relays=${relays.length}');
      final eventId = await Isolate.run(() async {
        try {
          await RustLib.init();
          api.initNostr(nsec: nsec);
          return api.publishRelayList(relays: relays);
        } catch (e) {
          // ignore: avoid_print
          print('[relay-list] publishRelayList isolate error: $e');
          return null;
        }
      });
      if (eventId != null) {
        // ignore: avoid_print
        print('[relay-list] publishRelayList ok id=$eventId');
      }
      return eventId;
    } finally {
      _mutex.release();
    }
  }

  /// Sends a DM on a background isolate to avoid blocking the UI.
  static Future<String?> sendGiftDm({
    required String recipient,
    required String content,
    required String nsec,
    bool useNip44 = true,
  }) async {
    if (recipient.isEmpty || content.isEmpty || nsec.isEmpty) return null;
    // ignore: avoid_print
    print('[dm] sendGiftDm start recipient=${recipient.substring(0, 8)}');
    final eventId = await Isolate.run(() async {
      try {
        await RustLib.init();
        api.initNostr(nsec: nsec);
        return api.sendGiftDm(
          recipient: recipient,
          content: content,
          useNip44: useNip44,
        );
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
  }

  /// Sends a legacy NIP-04 DM (kind 4).
  static Future<String?> sendLegacyDm({
    required String recipient,
    required String message,
    required String nsec,
  }) async {
    if (recipient.isEmpty || message.isEmpty || nsec.isEmpty) return null;
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
      print(
        '[dm] sendLegacyGiftDm start recipient=${recipient.substring(0, 8)}',
      );
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

class _DmWaitWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  Completer<SendPort>? _ready;
  ReceivePort? _controlPort;
  int _nextId = 0;

  Future<String?> waitForNewDms({
    required String nsec,
    required Duration wait,
  }) async {
    await _ensureStarted();
    final port = _sendPort;
    if (port == null) return '';

    final seconds = wait.inSeconds.clamp(1, 30);
    final id = ++_nextId;
    final replyPort = ReceivePort();
    port.send({
      'id': id,
      'cmd': 'wait_for_new_dms',
      'nsec': nsec,
      'timeoutSecs': seconds,
      'replyTo': replyPort.sendPort,
    });
    try {
      final response = await replyPort.first.timeout(
        Duration(seconds: seconds + 5),
        onTimeout: () {
          return '';
        },
      );
      if (response is Map && response['error'] != null) {
        return '';
      }
      if (response is Map) {
        return response['result']?.toString() ?? '';
      }
      return response?.toString() ?? '';
    } catch (_) {
      return '';
    } finally {
      replyPort.close();
    }
  }

  Future<void> _ensureStarted() async {
    if (_sendPort != null) return;
    _ready ??= Completer<SendPort>();
    if (_isolate == null) {
      _controlPort = ReceivePort();
      _isolate = await Isolate.spawn(_dmWaitWorkerMain, _controlPort!.sendPort);
      _controlPort!.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _ready?.complete(message);
          _ready = null;
        }
      });
    }
    await _ready!.future;
  }
}

@pragma('vm:entry-point')
Future<void> _dmWaitWorkerMain(SendPort mainSendPort) async {
  final commandPort = ReceivePort();
  mainSendPort.send(commandPort.sendPort);

  bool rustReady = false;
  String? currentNsec;

  Future<void> ensureRust(String nsec) async {
    if (!rustReady) {
      await RustLib.init();
      rustReady = true;
    }
    if (currentNsec != nsec) {
      api.initNostr(nsec: nsec);
      currentNsec = nsec;
    }
  }

  await for (final message in commandPort) {
    if (message is! Map) continue;
    final replyId = message['id'];
    final replyPort = message['replyTo'] as SendPort?;
    final cmd = message['cmd']?.toString();
    final nsec = message['nsec']?.toString() ?? '';
    final timeoutSecs = (message['timeoutSecs'] as num?)?.toInt() ?? 3;
    if (replyId is! int || replyPort == null || cmd == null) continue;

    try {
      await ensureRust(nsec);
      switch (cmd) {
        case 'wait_for_new_dms':
          final result = api.waitForNewDms(
            timeoutSecs: BigInt.from(timeoutSecs),
          );
          replyPort.send({'id': replyId, 'result': result});
          break;
        default:
          replyPort.send({'id': replyId, 'error': 'unknown command'});
      }
    } catch (e) {
      replyPort.send({'id': replyId, 'error': e.toString()});
    }
  }
}
