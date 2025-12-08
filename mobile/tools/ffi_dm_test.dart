// Lightweight Dart/FFI harness to exercise giftwrap + NIP-44 via the Rust bridge.
// Run two instances (two terminals) with different nsec/peer values to send/receive.
//
// Example (terminal A):
//   dart run mobile/tools/ffi_dm_test.dart --nsec <alice_nsec> --peer <bob_pub> --mode send
// Example (terminal B):
//   dart run mobile/tools/ffi_dm_test.dart --nsec <bob_nsec> --peer <alice_pub> --mode listen
//
// The Rust library must be built for your host first:
//   (cd pushstr_rust && cargo build --release)

import 'dart:convert';
import 'dart:io';

import '../lib/bridge_generated.dart/api.dart' as api;
import '../lib/bridge_generated.dart/frb_generated.dart';

enum Mode { send, listen, both }

class Config {
  Config({
    required this.nsec,
    required this.peer,
    required this.mode,
    required this.text,
  });

  final String nsec;
  final String peer; // npub or hex
  final Mode mode;
  final String text;
}

Future<void> main(List<String> args) async {
  final config = parseArgs(args);

  await ensureRustLibLoaded();
  final npub = api.initNostr(nsec: config.nsec);
  stdout.writeln('[ffi-test] initialized as $npub');

  if (config.mode == Mode.send || config.mode == Mode.both) {
    final eventId = api.sendGiftDm(
      recipient: config.peer,
      content: config.text,
      useNip44: true,
    );
    stdout.writeln('[ffi-test] sent gift DM to ${config.peer} (id: $eventId)');
  }

  if (config.mode == Mode.listen || config.mode == Mode.both) {
    stdout.writeln('[ffi-test] listening for new DMs (Ctrl+C to exit)...');
    await listenLoop();
  }
}

Future<void> listenLoop() async {
  while (true) {
    try {
      final jsonStr = api.waitForNewDms(timeoutSecs: BigInt.from(30));
      final list = jsonDecode(jsonStr);
      if (list is List && list.isNotEmpty) {
        for (final m in list) {
          final sender = m['from'] ?? 'unknown';
          final direction = m['direction'] ?? 'in';
          final content = m['content'] ?? '';
          stdout.writeln(
            '[ffi-test] received (${direction}) from $sender: $content',
          );
        }
      }
    } catch (e) {
      stderr.writeln('[ffi-test] listen error: $e');
      await Future.delayed(const Duration(seconds: 2));
    }
  }
}

Config parseArgs(List<String> args) {
  String? nsec;
  String? peer;
  Mode mode = Mode.both;
  String text = 'hello from dart @ ${DateTime.now().toIso8601String()}';

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--nsec':
        nsec = args[++i];
        break;
      case '--peer':
        peer = args[++i];
        break;
      case '--mode':
        final v = args[++i].toLowerCase();
        if (v == 'send') mode = Mode.send;
        if (v == 'listen') mode = Mode.listen;
        break;
      case '--text':
        text = args[++i];
        break;
    }
  }

  if (nsec == null || peer == null) {
    stderr.writeln(
      'Usage: dart run mobile/tools/ffi_dm_test.dart --nsec <nsec1...> --peer <npub|hex> [--mode send|listen|both] [--text "message"]',
    );
    exit(1);
  }

  return Config(
    nsec: nsec,
    peer: peer,
    mode: mode,
    text: text,
  );
}

Future<void> ensureRustLibLoaded() async {
  try {
    await RustLib.init();
  } catch (e) {
    stderr.writeln(
      '[ffi-test] Failed to load Rust lib. Build it with "cd pushstr_rust && cargo build --release" (the Dart loader expects ../pushstr_rust/target/release/libpushstr_rust.*). Error: $e',
    );
    rethrow;
  }
}
