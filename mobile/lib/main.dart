import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import 'bridge_generated.dart/api.dart' as api;
import 'bridge_generated.dart/frb_generated.dart';
import 'notifications.dart';
import 'sync/rust_sync_worker.dart';
import 'sync/sync_controller.dart';

class _HoldDeleteIcon extends StatelessWidget {
  final bool active;
  final double progress;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  const _HoldDeleteIcon({
    required this.active,
    required this.progress,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    final eased = Curves.easeIn.transform(clamped);
    final pulse = 0.5 + 0.5 * math.sin(math.pi * (1 + clamped * 4) * clamped);
    final intensity = (0.25 + 0.75 * pulse) * eased;
    final color = Color.lerp(
      Colors.white,
      Colors.redAccent.shade200,
      intensity.clamp(0, 1),
    )!;
    final scale = active ? (1.0 + 0.12 * eased) : 1.0;
    final iconSize = 24.0 + 4.0 * eased;
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: (_) => onHoldStart(),
      onLongPressEnd: (_) => onHoldEnd(),
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 120),
        child: IconButton(
          icon: Icon(Icons.delete, color: color, size: iconSize),
          onPressed: null,
          style: IconButton.styleFrom(
            backgroundColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
          ),
        ),
      ),
    );
  }
}

@pragma('vm:entry-point')
void workmanagerCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await RustLib.init();
    } catch (_) {}
    try {
      await SyncController.performSyncTick(
        trigger: SyncTrigger.background,
        budget: const Duration(seconds: 10),
      );
    } catch (e, st) {
      debugPrint('Workmanager task error: $e\n$st');
    }
    return true;
  });
}

@pragma('vm:entry-point')
void foregroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_PushstrTaskHandler());
}

class _PushstrTaskHandler extends TaskHandler {
  bool _bindingsReady = false;

  Future<void> _ensureBindings() async {
    if (_bindingsReady) return;
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    _bindingsReady = true;
  }

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    await _ensureBindings();
    await SyncController.performSyncTick(
      trigger: SyncTrigger.foregroundService,
      budget: const Duration(seconds: 10),
    );
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    await _ensureBindings();
    await SyncController.performSyncTick(
      trigger: SyncTrigger.foregroundService,
      budget: const Duration(seconds: 10),
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ExternalLibrary? externalLibrary;
  // On iOS, explicitly load the embedded framework from the app bundle.
  if (Platform.isIOS) {
    externalLibrary = ExternalLibrary.open(
      'Frameworks/pushstr_rust.framework/pushstr_rust',
    );
  }
  await RustLib.init(externalLibrary: externalLibrary);
  if (Platform.isAndroid) {
    await Workmanager().initialize(workmanagerCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'pushstr_periodic_sync',
      'pushstr_periodic_sync',
      initialDelay: const Duration(minutes: 1),
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }
  runApp(const WithForegroundTask(child: PushstrApp()));
}

class PushstrApp extends StatelessWidget {
  const PushstrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pushstr Mobile',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(primary: Color(0xFF22C55E)),
        scaffoldBackgroundColor: const Color(0xFF0E0E10),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _shareChannel = MethodChannel('com.pushstr.share');
  static const MethodChannel _storageChannel = MethodChannel(
    'com.pushstr.storage',
  );
  static const int _maxAttachmentBytes = 20 * 1024 * 1024;
  static const String _pushstrClientTag = '[pushstr:client]';
  static const Color _historyAccentGreen = Color(0xFF2F8F62);
// Color.fromARGB(255, 18, 113, 53);
  final TextEditingController messageCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocus = FocusNode();
  _PendingAttachment? _pendingAttachment;
  double _lastViewInsets = 0;
  String? npub;
  String? nsec;
  String? lastExport;
  String? lastError;
  List<Map<String, dynamic>> contacts = [];
  String? selectedContact;
  List<Map<String, dynamic>> messages = [];
  final Map<String, String> _dmModes = {};
  final Map<String, String> _dmOverrides = {};
  final Map<String, String> _giftwrapFormats = {};
  bool isConnected = false;
  bool _listening = false;
  bool _didInitRust = false;
  bool _foregroundEnabled = false;
  bool _startingForeground = false;
  bool _appVisible = true;
  final ImagePicker _imagePicker = ImagePicker();
  late final AudioRecorder _recorder;
  // StreamSubscription? _intentDataStreamSubscription;
  final Map<String, bool> _copiedMessages = {};
  final Map<String, Timer> _copiedMessageTimers = {};
  final Map<String, Timer> _holdTimersHome = {};
  final Map<String, double> _holdProgressHome = {};
  final Set<String> _pendingReceipts = {};
  final Set<String> _sentReceipts = {};
  final Map<String, int> _missingFetchTs = {};
  final Map<String, bool> _holdActiveHome = {};
  final Map<String, int> _holdLastSecondHome = {};
  static const int _holdMillis = 4000;
  static const String _pushstrMediaStart = '[pushstr:media]';
  static const String _pushstrMediaEnd = '[/pushstr:media]';
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  // Session-based decryption caching
  final Map<String, Uint8List> _decryptedMediaCache = {};
  final Set<String> _sessionMessages = {};
  bool _showScrollToBottom = false;
  bool _hasNewMessages = false;
  bool _encryptPendingAttachment = true;
  bool _isRecordingAudio = false;
  Timer? _recordingTimer;
  int _recordingElapsed = 0;

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _messageFocus.addListener(() {
      if (_messageFocus.hasFocus) {
        _scrollToBottom(force: true);
      }
    });
    _recorder = AudioRecorder();
    super.initState();
    _init();
    // TODO: Re-enable Android share support when API is stable
    // // Handle shared content (when app is already running)
    // _intentDataStreamSubscription = ReceiveSharingIntent.textStream.listen((String value) {
    //   setState(() {
    //     messageCtrl.text = value;
    //   });
    // }, onError: (err) {
    //   print("Error receiving shared text: $err");
    // });

    // // Handle shared content (when app is opened from share)
    // ReceiveSharingIntent.initialText.then((String? value) {
    //   if (value != null && value.isNotEmpty) {
    //     setState(() {
    //       messageCtrl.text = value;
    //     });
    //   }
    // });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _messageFocus.dispose();
    _recorder.dispose();
    for (final t in _copiedMessageTimers.values) {
      t.cancel();
    }
    for (final t in _holdTimersHome.values) {
      t.cancel();
    }
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _recordingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // _intentDataStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final bottom = WidgetsBinding.instance.window.viewInsets.bottom;
    if (bottom != _lastViewInsets) {
      _lastViewInsets = bottom;
      if (bottom > 0) {
        _scrollToBottom(force: true);
      }
    }
    super.didChangeMetrics();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _appVisible = true;
      _persistVisibleState();
      unawaited(
        SyncController.performSyncTick(
          trigger: SyncTrigger.manual,
          budget: const Duration(seconds: 10),
        ),
      );
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _appVisible = false;
      _persistVisibleState();
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedNsec = prefs.getString('nostr_nsec') ?? '';
    final profileIndex = prefs.getInt('selected_profile_index') ?? 0;
    _foregroundEnabled = prefs.getBool('foreground_service_enabled') ?? false;
    _appVisible = true;
    unawaited(_persistVisibleState());
    unawaited(initLocalNotifications());

    // Handle shared content from Android intents
    _initShareListener();

    final profileList = prefs.getStringList('profiles') ?? [];
    String? profileNsec;
    if (profileIndex >= 0 && profileIndex < profileList.length) {
      final parts = profileList[profileIndex].split('|');
      profileNsec = parts.isNotEmpty ? parts[0] : null;
    }
    profileNsec ??= savedNsec.isNotEmpty ? savedNsec : null;
    final contactsKey = profileNsec != null && profileNsec.isNotEmpty
        ? _contactsKeyFor(profileNsec)
        : 'contacts';
    final messagesKey = profileNsec != null && profileNsec.isNotEmpty
        ? _messagesKeyFor(profileNsec)
        : 'messages';
    final pendingKey = profileNsec != null && profileNsec.isNotEmpty
        ? _pendingDmsKeyFor(profileNsec)
        : 'pending_dms';
    final savedContacts =
        prefs.getStringList(contactsKey) ??
        prefs.getStringList('contacts') ??
        [];
    final savedMessages =
        prefs.getString(messagesKey) ?? prefs.getString('messages');
    final pendingMessagesJson = prefs.getString(pendingKey);
    List<Map<String, dynamic>> loadedMessages = [];
    List<Map<String, dynamic>> pendingMessages = [];
    if (savedMessages != null && savedMessages.isNotEmpty) {
      try {
        final List<dynamic> msgsList = jsonDecode(savedMessages);
        loadedMessages = msgsList.cast<Map<String, dynamic>>();
      } catch (e) {
        print('Failed to load saved messages: $e');
      }
    }
    if (pendingMessagesJson != null && pendingMessagesJson.isNotEmpty) {
      try {
        final List<dynamic> msgsList = jsonDecode(pendingMessagesJson);
        pendingMessages = msgsList
            .map((e) => Map<String, dynamic>.from(e as Map))
            .map(_normalizeIncomingMessage)
            .toList();
      } catch (_) {
        // ignore pending parse errors
      }
    }
    if (mounted) {
      setState(() {
        isConnected = false;
        messages = _mergeMessages([...loadedMessages, ...pendingMessages]);
        contacts = _dedupeContacts(
          savedContacts
              .map((c) {
                final parts = c.split('|');
                return <String, dynamic>{
                  'nickname': parts[0],
                  'pubkey': parts.length > 1 ? parts[1] : '',
                };
              })
              .where((c) => c['pubkey']!.isNotEmpty)
              .toList(),
        );
        _sortContactsByActivity();
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_finishInit(savedNsec: savedNsec, profileIndex: profileIndex));
    });
  }

  Future<void> _finishInit({
    required String savedNsec,
    required int profileIndex,
  }) async {
    unawaited(_checkPrefsBackup());
    try {
      final initResult = await _initRustClientInBackground(savedNsec);
      if (!mounted) return;
      nsec = initResult['nsec'];
      setState(() {
        npub = initResult['npub'];
        isConnected = true;
      });
      unawaited(
        _loadLocalProfileData(profileIndex: profileIndex, overrideLoaded: true),
      );
      _ensureSelectedContact();
      unawaited(_persistVisibleState());

      if (savedNsec.isEmpty && nsec != null && nsec!.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('nostr_nsec', nsec!);
      }

      unawaited(_fetchMessages());
      unawaited(_startDmListener());
      if (_foregroundEnabled && Platform.isAndroid) {
        unawaited(_startForegroundService());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        lastError = 'Init failed: $e';
        isConnected = false;
      });
    }
  }

  Future<Map<String, String>> _initRustClientInBackground(
    String savedNsec,
  ) async {
    return Isolate.run(() async {
      try {
        await RustLib.init();
      } catch (_) {}
      final npub = api.initNostr(nsec: savedNsec);
      final nsec = savedNsec.isNotEmpty ? savedNsec : api.getNsec();
      return {'npub': npub, 'nsec': nsec};
    });
  }

  String _contactsKeyFor(String profileNsec) => 'contacts_$profileNsec';

  String _messagesKeyFor(String profileNsec) => 'messages_$profileNsec';
  String _pendingDmsKeyFor(String profileNsec) => 'pending_dms_$profileNsec';
  String _lastSeenKeyFor(String profileNsec) => 'last_seen_ts_$profileNsec';
  String _dmModesKeyFor(String profileNsec) => 'dm_modes_$profileNsec';
  String _dmOverridesKeyFor(String profileNsec) => 'dm_overrides_$profileNsec';
  String _dmGiftwrapKeyFor(String profileNsec) =>
      'dm_giftwrap_formats_$profileNsec';
  static const String _readReceiptKey = 'pushstr_ack';

  bool _containsPushstrClientTag(String content) {
    return content.contains(_pushstrClientTag);
  }

  String _stripPushstrClientTag(String content) {
    if (!content.contains(_pushstrClientTag)) return content;
    final pattern = RegExp(r'(^|\n)\[pushstr:client\](\n|$)', multiLine: true);
    final stripped = content.replaceAll(pattern, '\n').trim();
    return stripped;
  }

  String _withPushstrClientTag(String content) {
    if (content.contains(_pushstrClientTag)) return content;
    if (content.isEmpty) return _pushstrClientTag;
    return '$content\n$_pushstrClientTag';
  }

  String _buildReadReceiptPayload(String messageId) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return jsonEncode({_readReceiptKey: messageId, 'ts': now});
  }

  String? _extractReadReceiptId(String content) {
    final cleaned = _stripPushstrClientTag(content).trimLeft();
    if (!cleaned.contains(_readReceiptKey)) return null;
    if (!cleaned.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map && decoded[_readReceiptKey] is String) {
        return decoded[_readReceiptKey] as String;
      }
    } catch (_) {
      // ignore parse failures
    }
    return null;
  }

  Map<String, dynamic> _normalizeIncomingMessage(Map<String, dynamic> msg) {
    final dir = (msg['direction'] ?? msg['dir'] ?? '').toString().toLowerCase();
    if (dir == 'incoming') {
      msg['direction'] = 'in';
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int ts = 0;
    final raw = msg['created_at'];
    if (raw is int)
      ts = raw;
    else if (raw is double)
      ts = raw.round();
    else if (raw is String)
      ts = int.tryParse(raw) ?? 0;
    if (ts <= 0) ts = nowSec;
    if (ts > nowSec + 300) ts = nowSec; // clamp future to avoid ordering issues
    msg['created_at'] = ts;
    return msg;
  }

  Future<void> _saveMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null ? _messagesKeyFor(nsec!) : 'messages';
      await prefs.setString(key, jsonEncode(_messagesForStorage(messages)));
      if (nsec != null) {
        // Clear legacy shared storage to avoid cross-profile bleed
        await prefs.remove('messages');
      }
    } catch (e) {
      print('Failed to save messages: $e');
    }
  }

  List<Map<String, dynamic>> _messagesForStorage(
    List<Map<String, dynamic>> source,
  ) {
    return source.map((message) {
      final cloned = Map<String, dynamic>.from(message);
      final media = cloned['media'];
      if (media is Map) {
        final mediaCopy = Map<String, dynamic>.from(media);
        if (mediaCopy['bytes'] != null) {
          mediaCopy['bytes'] = null;
          final descriptor = mediaCopy['descriptor'];
          final encryption = descriptor is Map
              ? descriptor['encryption']?.toString()
              : mediaCopy['encryption']?.toString();
          if (encryption == 'aes-gcm') {
            mediaCopy['needsDecryption'] = true;
            mediaCopy['senderPubkey'] ??= cloned['from']?.toString() ?? '';
            mediaCopy['cacheKey'] ??=
                (descriptor is Map && descriptor['cipher_sha256'] != null)
                ? descriptor['cipher_sha256'].toString()
                : (descriptor is Map
                          ? descriptor['url']?.toString()
                          : mediaCopy['url']?.toString()) ??
                      '';
          }
          if (descriptor is Map && descriptor['url'] != null) {
            mediaCopy['url'] ??= descriptor['url'];
          }
        }
        cloned['media'] = mediaCopy;
      }
      return cloned;
    }).toList();
  }

  Future<bool> _confirmLargeAttachment(int bytes) async {
    if (bytes <= _maxAttachmentBytes) return true;
    if (!mounted) return false;
    final maxMb = (_maxAttachmentBytes / (1024 * 1024)).round();
    final sizeMb = (bytes / (1024 * 1024)).toStringAsFixed(1);
    final shouldContinue = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Large attachment'),
        content: Text(
          'This file is ${sizeMb}MB. Larger files may fail or be slow. Recommended max is ${maxMb}MB.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return shouldContinue ?? false;
  }

  Future<void> _saveContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null ? _contactsKeyFor(nsec!) : 'contacts';
      await prefs.setStringList(
        key,
        contacts
            .map((c) => '${c['nickname'] ?? ''}|${c['pubkey'] ?? ''}')
            .toList(),
      );
      if (nsec != null) {
        await prefs.remove('contacts');
      }
    } catch (e) {
      print('Failed to save contacts: $e');
    }
  }

  Future<void> _saveDmModes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null ? _dmModesKeyFor(nsec!) : 'dm_modes';
      await prefs.setString(key, jsonEncode(_dmModes));
    } catch (e) {
      print('Failed to save DM modes: $e');
    }
  }

  Future<void> _saveDmOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null ? _dmOverridesKeyFor(nsec!) : 'dm_overrides';
      await prefs.setString(key, jsonEncode(_dmOverrides));
    } catch (e) {
      print('Failed to save DM overrides: $e');
    }
  }

  Future<void> _saveGiftwrapFormats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null
          ? _dmGiftwrapKeyFor(nsec!)
          : 'dm_giftwrap_formats';
      await prefs.setString(key, jsonEncode(_giftwrapFormats));
    } catch (e) {
      print('Failed to save DM giftwrap formats: $e');
    }
  }

  int _messageKind(Map<String, dynamic> message) {
    final raw = message['kind'];
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  int? _messageSeq(Map<String, dynamic> message) {
    final raw = message['seq'];
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  void _requestMissingMessages(String contact) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _missingFetchTs[contact] ?? 0;
    if (now - last < 30000) return;
    _missingFetchTs[contact] = now;
    unawaited(_fetchMessages());
  }

  void _updateDmModesFromMessages(List<Map<String, dynamic>> incoming) {
    bool changed = false;
    bool giftwrapChanged = false;
    for (final msg in incoming) {
      if (msg['direction'] != 'in') continue;
      final pubkey = msg['from']?.toString() ?? '';
      if (pubkey.isEmpty) continue;
      final hasOverride = _dmOverrides.containsKey(pubkey);
      final dmKind = msg['dm_kind']?.toString();
      if (dmKind == 'legacy_giftwrap') {
        _giftwrapFormats[pubkey] = 'legacy_giftwrap';
        giftwrapChanged = true;
        if (!hasOverride && _dmModes[pubkey] != 'nip59') {
          _dmModes[pubkey] = 'nip59';
          changed = true;
          print(
            '[dm] legacy giftwrap observed; using nip59 for ${pubkey.substring(0, 8)}',
          );
        }
        continue;
      }
      if (dmKind == 'nip59') {
        _giftwrapFormats[pubkey] = 'nip59';
        giftwrapChanged = true;
        if (!hasOverride && _dmModes[pubkey] != 'nip59') {
          _dmModes[pubkey] = 'nip59';
          changed = true;
          print('[dm] mode set nip59 for ${pubkey.substring(0, 8)}');
        }
        continue;
      }
      final kind = _messageKind(msg);
      if (kind == 4) {
        if (!hasOverride && _dmModes[pubkey] != 'nip04') {
          _dmModes[pubkey] = 'nip04';
          changed = true;
          print('[dm] mode set nip04 for ${pubkey.substring(0, 8)}');
        }
      } else if (kind == 1059 && !_dmModes.containsKey(pubkey)) {
        if (!hasOverride) {
          _dmModes[pubkey] = 'nip59';
          changed = true;
          print('[dm] mode set nip59 for ${pubkey.substring(0, 8)}');
        }
        if (!_giftwrapFormats.containsKey(pubkey)) {
          _giftwrapFormats[pubkey] = 'nip59';
          giftwrapChanged = true;
        }
      }
    }
    if (changed) {
      unawaited(_saveDmModes());
    }
    if (giftwrapChanged) {
      unawaited(_saveGiftwrapFormats());
    }
  }

  String _effectiveDmMode(String pubkey) {
    final override = _dmOverrides[pubkey];
    if (override == 'nip04') return 'nip04';
    if (override == 'giftwrap') {
      final observed = _dmModes[pubkey];
      if (observed == 'legacy_giftwrap' || observed == 'nip59') {
        return 'nip59';
      }
      final format = _giftwrapFormats[pubkey];
      return format == 'legacy_giftwrap' ? 'nip59' : (format ?? 'nip59');
    }
    final observed = _dmModes[pubkey];
    if (observed == 'nip04') return 'nip04';
    if (observed == 'legacy_giftwrap' || observed == 'nip59') {
      return 'nip59';
    }
    final format = _giftwrapFormats[pubkey];
    return format == 'legacy_giftwrap' ? 'nip59' : (format ?? 'nip59');
  }

  Widget? _buildDmBadge(Map<String, dynamic> message) {
    final dmKind = message['dm_kind']?.toString();
    final kind = _messageKind(message);
    final isNip04 = dmKind == 'nip04' || kind == 4;
    final isGiftwrap =
        dmKind == 'nip59' || dmKind == 'legacy_giftwrap' || kind == 1059;
    if (!isNip04 && !isGiftwrap) return null;
    final iconData = isGiftwrap ? Icons.lock : Icons.lock_open;
    final color = isGiftwrap ? _historyAccentGreen : Colors.grey.shade500;
    final label = isGiftwrap ? '17' : '04';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(iconData, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }

  Widget _buildDmModeToggle() {
    final pubkey = selectedContact;
    final target = pubkey ?? '';
    final enabled = target.isNotEmpty;
    final mode = enabled ? _effectiveDmMode(target) : 'nip59';
    final isGiftwrap = mode != 'nip04';
    final iconData = isGiftwrap ? Icons.lock : Icons.lock_open;

    final activeColor = isGiftwrap
        ? const Color(0xFF22C55E)
        : Colors.grey.shade500;
    final color = enabled ? activeColor : Colors.grey.shade600;
    final label = enabled ? (isGiftwrap ? '17' : '04') : '17';
    final tooltip = enabled
        ? (isGiftwrap ? 'Send as NIP-17 giftwrap' : 'Send as NIP-04')
        : 'Select a contact';

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled
            ? () {
                setState(() {
                  if (isGiftwrap) {
                    _dmOverrides[target] = 'nip04';
                  } else {
                    _dmOverrides[target] = 'giftwrap';
                    _giftwrapFormats.putIfAbsent(target, () => 'nip59');
                  }
                });
                unawaited(_saveDmOverrides());
                unawaited(_saveGiftwrapFormats());
              }
            : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconData, size: 18, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkPrefsBackup() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await _storageChannel.invokeMethod<Map>(
        'getPrefsBackupInfo',
      );
      if (info == null || info['exists'] != true || !mounted) return;
      final size = (info['size'] as int?) ?? 0;
      final sizeMb = (size / (1024 * 1024)).toStringAsFixed(1);
      final shouldExport = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Preferences backup created'),
          content: Text(
            'Your preferences file was too large (${sizeMb}MB), so it was reset to prevent a crash. '
            'A backup was saved and you can export it now.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Export backup'),
            ),
          ],
        ),
      );
      if (shouldExport == true) {
        final uri = await _storageChannel.invokeMethod<String>(
          'exportPrefsBackup',
          {'name': 'pushstr_prefs_backup.xml'},
        );
        if (uri != null) {
          _showThemedToast('Backup exported', preferTop: true);
        } else {
          _showThemedToast('Backup export failed', preferTop: true);
        }
      }
      await _storageChannel.invokeMethod<bool>('clearPrefsBackup');
    } catch (e) {
      debugPrint('Prefs backup check failed: $e');
    }
  }

  Future<bool> _ensureCameraPermission() async {
    var camStatus = await Permission.camera.status;
    if (!camStatus.isGranted) {
      camStatus = await Permission.camera.request();
    }

    // Also request Photos so the app shows up under Settings > Privacy > Photos.
    var photoStatus = await Permission.photos.status;
    if (!photoStatus.isGranted && !photoStatus.isLimited) {
      photoStatus = await Permission.photos.request();
    }

    if (camStatus.isGranted) return true;

    // If the user has previously denied, nudge them to Settings.
    if (camStatus.isPermanentlyDenied || camStatus.isRestricted) {
      await openAppSettings();
    }
    return false;
  }

  Future<void> _fetchMessages() async {
    try {
      await _ensureRustInitialized();
      final existingLen = messages.length;
      final prefs = await SharedPreferences.getInstance();
      final lastSeen = (nsec != null && nsec!.isNotEmpty)
          ? (prefs.getInt(_lastSeenKeyFor(nsec!)) ?? 0)
          : 0;
      final dmsJson = await RustSyncWorker.fetchRecentDms(
        nsec: nsec ?? '',
        limit: 100,
        sinceTimestamp: lastSeen,
      );
      List<Map<String, dynamic>> fetchedMessages = [];
      if (dmsJson == null || dmsJson.isEmpty) {
        debugPrint('[dm] Fetch received 0 messages');
      } else {
        final List<dynamic> dmsList = jsonDecode(dmsJson);
        fetchedMessages = dmsList.cast<Map<String, dynamic>>();
        fetchedMessages = await _decodeMessages(fetchedMessages);
        debugPrint('[dm] Fetch received ${fetchedMessages.length} messages');
        _updateDmModesFromMessages(fetchedMessages);
      }

      // Merge any pending background-cached messages
      try {
        final pendingKey = nsec != null
            ? _pendingDmsKeyFor(nsec!)
            : 'pending_dms';
        final pendingJson = prefs.getString(pendingKey);
        if (pendingJson != null && pendingJson.isNotEmpty) {
          final pendingList = (jsonDecode(pendingJson) as List<dynamic>)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .map(_normalizeIncomingMessage)
              .toList();
          final decodedPending = await _decodeMessages(pendingList);
          _updateDmModesFromMessages(decodedPending);
          fetchedMessages = _mergeMessages([
            ...fetchedMessages,
            ...decodedPending,
          ]);
          await prefs.remove(pendingKey);
        }
      } catch (_) {
        // ignore pending errors
      }

      // Auto-add contacts from incoming messages
      final incomingPubkeys = fetchedMessages
          .where((m) => m['direction'] == 'in')
          .map((m) => m['from'] as String?)
          .where((pk) => pk != null && pk.isNotEmpty)
          .toSet();

      for (final pubkey in incomingPubkeys) {
        if (!contacts.any((c) => c['pubkey'] == pubkey)) {
          final newContact = {'pubkey': pubkey!, 'nickname': ''};
          contacts.add(newContact);
        }
      }

      // Merge fetched messages with local messages (keep local messages that aren't in fetched)
      final fetchedIds = fetchedMessages
          .map((m) => m['id'] as String?)
          .where((id) => id != null)
          .toSet();
      final localOnly = messages.where((m) {
        final id = m['id'] as String?;
        return id != null &&
            id.startsWith('local_') &&
            !fetchedIds.contains(id);
      }).toList();

      final merged = _mergeMessages([...fetchedMessages, ...localOnly]);
      _applyPendingReceiptsToList(merged);
      final added = merged.length > existingLen;
      setState(() {
        messages = merged;
        lastError = null;
        contacts = _dedupeContacts(contacts);
        _sortContactsByActivity();
      });
      _ensureSelectedContact();

      // Save messages to persist them
      await _saveMessages();
      await _saveContacts();
      if (nsec != null && nsec!.isNotEmpty) {
        final maxSeen = messages.fold<int>(0, (acc, m) {
          final raw = m['created_at'];
          if (raw is int && raw > acc) return raw;
          if (raw is double && raw > acc) return raw.round();
          if (raw is String) {
            final parsed = int.tryParse(raw);
            if (parsed != null && parsed > acc) return parsed;
          }
          return acc;
        });
        await prefs.setInt(_lastSeenKeyFor(nsec!), maxSeen);
        await prefs.setInt('last_notified_ts_${nsec!}', maxSeen);
      }
      if (added) {
        if (_isNearBottom()) {
          _scrollToBottom();
        } else {
          _flagNewMessageWhileScrolledBack();
        }
      }
    } catch (e) {
      setState(() {
        lastError = 'Fetch failed: $e';
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = messageCtrl.text.trim();
    print(
      '[dm] _sendMessage called textLen=${text.length} pending=${_pendingAttachment != null}',
    );
    if ((text.isEmpty && _pendingAttachment == null) || selectedContact == null)
      return;
    if (nsec == null || nsec!.isEmpty) {
      setState(() {
        lastError = 'Missing profile key; please re-import or pick a profile.';
      });
      return;
    }

    try {
      final attachment = _pendingAttachment;
      String payload = text;
      Map<String, dynamic>? localMedia;
      String localText = text;

      if (attachment != null) {
        final isEncrypted = _encryptPendingAttachment;
        final desc = isEncrypted
            ? api.encryptMedia(
                bytes: attachment.bytes,
                recipient: selectedContact!,
                mime: attachment.mime,
                filename: attachment.name,
              )
            : api.uploadMediaUnencrypted(
                bytes: attachment.bytes,
                mime: attachment.mime,
                filename: attachment.name,
              );
        final descriptor = {
          'url': desc.url,
          'iv': desc.iv,
          'sha256': desc.sha256,
          'cipher_sha256': desc.cipherSha256,
          'mime': desc.mime,
          'size': desc.size.toInt(),
          'encryption': desc.encryption,
          'filename': desc.filename,
        };
        final descriptorJson = jsonEncode({'media': descriptor});
        final url = descriptor['url']?.toString() ?? '';
        final filename = descriptor['filename']?.toString() ?? 'attachment';
        final sizeLabel = descriptor['size'] is int
            ? _formatBytes(descriptor['size'] as int)
            : null;
        final attachmentLine = sizeLabel != null
            ? 'Attachment: $filename ($sizeLabel)'
            : 'Attachment: $filename';
        final lines = <String>[
          if (text.isNotEmpty) text,
          attachmentLine,
          if (url.isNotEmpty) url,
          '',
          _pushstrMediaStart,
          descriptorJson,
          _pushstrMediaEnd,
        ];
        payload = lines.join('\n');
        // Use the original picked bytes for local preview (matches browser extension behavior).
        localMedia = {
          'bytes': attachment.bytes,
          'mime': attachment.mime,
          'size': attachment.bytes.length,
          'filename': attachment.name,
          'descriptor': descriptor,
          'senderPubkey': npub ?? '',
          'cacheKey': desc.cipherSha256.isNotEmpty
              ? desc.cipherSha256
              : desc.url,
          'url': desc.url,
          'nonEncrypted': !isEncrypted,
        };
        localText = text.isNotEmpty ? text : '(attachment)';
      }

      payload = _withPushstrClientTag(payload);
      final dmMode = _effectiveDmMode(selectedContact!);
      final useLegacyDm = dmMode == 'nip04';
      final modeLabel = useLegacyDm ? 'nip04' : 'nip59';
      print(
        '[dm] send mode=$modeLabel to=${selectedContact!.substring(0, 8)} textLen=${text.length}',
      );

      // Add to local messages immediately before the send call to avoid UI delays.
      final localId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      _sessionMessages.add(localId); // Mark as session message
      final displayContent = localMedia != null
          ? {'text': localText, 'media': localMedia}
          : await _decodeContent(payload, npub ?? '', localId);
      setState(() {
        messages.add(<String, dynamic>{
          'id': localId,
          'from': npub ?? '',
          'to': selectedContact!,
          'content': displayContent['text'],
          'media': displayContent['media'],
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'direction': 'out',
          'kind': useLegacyDm ? 4 : 1059,
          'dm_kind': useLegacyDm ? 'nip04' : 'nip59',
        });
        messageCtrl.clear();
        _pendingAttachment = null;
        lastError = null;
      });

      _scrollToBottom(force: true);

      // Persist and fire off the send in the background; we optimistically assume success.
      unawaited(_saveMessages());
      unawaited(
        Future(() async {
          try {
            String? eventId;
            if (useLegacyDm) {
              eventId = await RustSyncWorker.sendLegacyDm(
                recipient: selectedContact!,
                message: payload,
                nsec: nsec!,
              );
            } else {
              eventId = await RustSyncWorker.sendGiftDm(
                recipient: selectedContact!,
                content: payload,
                nsec: nsec!,
                useNip44: true,
              );
            }
            if (eventId != null) {
              _replaceLocalMessageId(localId, eventId);
            }
          } catch (e) {
            if (!mounted) return;
            setState(() {
              lastError = 'Send failed: $e';
            });
          }
        }),
      );
    } catch (e) {
      setState(() {
        lastError = 'Send failed: $e';
      });
    }
  }

  Map<String, dynamic> _buildResendPayload(Map<String, dynamic> message) {
    final text = (message['content'] ?? '').toString();
    final media = message['media'];
    String payload = text;
    String localText = text;
    Map<String, dynamic>? localMedia;

    if (media is Map<String, dynamic>) {
      localMedia = media;
      if (localText.isEmpty || localText == '(attachment)') {
        localText = '(attachment)';
      }
      Map<String, dynamic>? descriptor;
      final rawDescriptor = media['descriptor'];
      if (rawDescriptor is Map) {
        descriptor = Map<String, dynamic>.from(rawDescriptor);
      } else if (rawDescriptor is String) {
        try {
          final parsed = jsonDecode(rawDescriptor);
          if (parsed is Map) descriptor = Map<String, dynamic>.from(parsed);
        } catch (_) {
          descriptor = null;
        }
      }
      descriptor ??= {
        'url': media['url'],
        'iv': media['iv'],
        'sha256': media['sha256'],
        'cipher_sha256': media['cipher_sha256'],
        'mime': media['mime'],
        'size': media['size'],
        'encryption': media['encryption'],
        'filename': media['filename'],
      };

      if (descriptor['url'] != null) {
        final descriptorJson = jsonEncode({'media': descriptor});
        final url = descriptor['url']?.toString() ?? '';
        final filename = descriptor['filename']?.toString() ?? 'attachment';
        final sizeValue = descriptor['size'] is int
            ? descriptor['size'] as int
            : int.tryParse(descriptor['size']?.toString() ?? '');
        final sizeLabel = sizeValue != null ? _formatBytes(sizeValue) : null;
        final attachmentLine = sizeLabel != null
            ? 'Attachment: $filename ($sizeLabel)'
            : 'Attachment: $filename';
        final lines = <String>[
          if (text.isNotEmpty && text != '(attachment)') text,
          attachmentLine,
          if (url.isNotEmpty) url,
          '',
          _pushstrMediaStart,
          descriptorJson,
          _pushstrMediaEnd,
        ];
        payload = lines.join('\n');
      }
    }

    payload = _withPushstrClientTag(payload);
    return {'payload': payload, 'text': localText, 'media': localMedia};
  }

  Future<void> _resendMessage(Map<String, dynamic> message) async {
    if (nsec == null || nsec!.isEmpty) {
      setState(() {
        lastError = 'Missing profile key; please re-import or pick a profile.';
      });
      return;
    }
    final recipient = message['to']?.toString() ?? selectedContact;
    if (recipient == null || recipient.isEmpty) {
      setState(() {
        lastError = 'Missing recipient; select a contact.';
      });
      return;
    }

    try {
      final built = _buildResendPayload(message);
      final payload = built['payload'] as String;
      final localMedia = built['media'] as Map<String, dynamic>?;
      final localText = built['text'] as String;
      final dmKind = (message['dm_kind'] ?? 'nip59').toString();
      final useLegacyDm = dmKind == 'nip04';

      final localId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      _sessionMessages.add(localId);
      final displayContent = localMedia != null
          ? {'text': localText, 'media': localMedia}
          : await _decodeContent(payload, npub ?? '', localId);
      setState(() {
        messages.add(<String, dynamic>{
          'id': localId,
          'from': npub ?? '',
          'to': recipient,
          'content': displayContent['text'],
          'media': displayContent['media'],
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'direction': 'out',
          'kind': useLegacyDm ? 4 : 1059,
          'dm_kind': useLegacyDm ? 'nip04' : 'nip59',
        });
        lastError = null;
      });

      _scrollToBottom(force: true);
      unawaited(_saveMessages());

      if (useLegacyDm) {
        final eventId = await RustSyncWorker.sendLegacyDm(
          recipient: recipient,
          message: payload,
          nsec: nsec!,
        );
        if (eventId != null) {
          _replaceLocalMessageId(localId, eventId);
        }
      } else {
        final eventId = await RustSyncWorker.sendGiftDm(
          recipient: recipient,
          content: payload,
          nsec: nsec!,
          useNip44: true,
        );
        if (eventId != null) {
          _replaceLocalMessageId(localId, eventId);
        }
      }
      if (!mounted) return;
      _showThemedToast('Resent', preferTop: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        lastError = 'Resend failed: $e';
      });
    }
  }

  String _normalizeContactInput(String input) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Missing pubkey');
    }
    if (trimmed.startsWith('nostr://')) {
      trimmed = trimmed.substring(8);
    } else if (trimmed.startsWith('nostr:')) {
      trimmed = trimmed.substring(6);
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('npub') || lower.startsWith('nprofile')) {
      return api.npubToHex(npub: trimmed);
    }
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(trimmed)) {
      return trimmed.toLowerCase();
    }
    throw const FormatException('Enter a valid npub, nprofile, or hex pubkey');
  }

  String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = 1024 * kb;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Map<String, String?> _extractPushstrMedia(String raw) {
    final start = raw.indexOf(_pushstrMediaStart);
    if (start == -1) {
      return {'text': raw, 'media': null};
    }
    final startContent = start + _pushstrMediaStart.length;
    final end = raw.indexOf(_pushstrMediaEnd, startContent);
    final mediaBlock = (end == -1)
        ? raw.substring(startContent)
        : raw.substring(startContent, end);
    final before = raw.substring(0, start);
    final after = end == -1 ? '' : raw.substring(end + _pushstrMediaEnd.length);
    final cleaned = (before + after).trim();
    final mediaJson = mediaBlock.trim();
    return {'text': cleaned, 'media': mediaJson.isEmpty ? null : mediaJson};
  }

  Future<void> _addContact(BuildContext context) async {
    final nicknameCtrl = TextEditingController();
    final pubkeyCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nicknameCtrl,
              decoration: const InputDecoration(labelText: 'Nickname'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pubkeyCtrl,
              decoration: const InputDecoration(
                labelText: 'npub, nprofile, or hex pubkey',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final scanned = await _scanQrRaw();
              if (scanned != null && scanned.isNotEmpty) {
                pubkeyCtrl.text = scanned;
              }
            },
            child: const Text('Scan QR'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final pubkeyRaw = pubkeyCtrl.text.trim();
              final nickname = nicknameCtrl.text.trim();

              if (pubkeyRaw.isEmpty) {
                Navigator.pop(context);
                return;
              }

              String pubkey;
              try {
                pubkey = _normalizeContactInput(pubkeyRaw);
              } catch (e) {
                setState(() => lastError = 'Invalid pubkey: $e');
                Navigator.pop(context);
                return;
              }

              setState(() {
                contacts.add(<String, dynamic>{
                  'nickname': nickname,
                  'pubkey': pubkey,
                });
                contacts = _dedupeContacts(contacts);
                _sortContactsByActivity();
                selectedContact = pubkey;
              });
              _persistVisibleState();

              await _saveContacts();
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _editContact(
    BuildContext context,
    Map<String, dynamic> contact,
  ) async {
    final nicknameCtrl = TextEditingController(
      text: contact['nickname']?.toString() ?? _short(contact['pubkey'] ?? ''),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit nickname'),
        content: TextField(
          controller: nicknameCtrl,
          decoration: const InputDecoration(labelText: 'Nickname'),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final pubkey = contact['pubkey']?.toString() ?? '';
              if (pubkey.isEmpty) return;
              String npub = pubkey;
              try {
                npub = api.hexToNpub(hex: pubkey);
              } catch (_) {}
              await Clipboard.setData(ClipboardData(text: npub));
              if (mounted) {
                _showThemedToast('Copied npub', preferTop: true);
              }
            },
            child: const Text('Copy npub'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updatedNick = nicknameCtrl.text.trim();
    setState(() {
      for (final c in contacts) {
        if (c['pubkey'] == contact['pubkey']) {
          c['nickname'] = updatedNick.isEmpty
              ? _short(c['pubkey'] ?? '')
              : updatedNick;
          break;
        }
      }
    });
    await _saveContacts();
  }

  Future<void> _scanContactQr() async {
    final scanned = await _scanQrRaw();
    if (scanned == null || scanned.trim().isEmpty) return;
    final inputRaw = scanned.trim();
    String input;
    String? displayNpub;
    try {
      input = _normalizeContactInput(inputRaw);
      displayNpub = api.hexToNpub(hex: input);
    } catch (e) {
      if (mounted) {
        _showThemedToast('Invalid contact QR: $e', preferTop: true);
      }
      return;
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(input)) {
      if (mounted) {
        _showThemedToast('QR did not contain a valid pubkey', preferTop: true);
      }
      return;
    }
    if (contacts.any((c) => c['pubkey'] == input)) {
      if (mounted) {
        _showThemedToast('Contact already exists', preferTop: true);
      }
      return;
    }

    final nicknameCtrl = TextEditingController(text: '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pubkey'),
            const SizedBox(height: 4),
            SelectableText(
              displayNpub ?? input,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nicknameCtrl,
              decoration: const InputDecoration(labelText: 'Nickname'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final nickname = nicknameCtrl.text.trim();
    setState(() {
      contacts.add(<String, dynamic>{'nickname': nickname, 'pubkey': input});
      contacts = _dedupeContacts(contacts);
      _sortContactsByActivity();
      selectedContact = input;
    });
    _persistVisibleState();
    await _saveContacts();
    if (mounted) {
      _showThemedToast('Contact added', preferTop: true);
    }
  }

  Future<String?> _scanQrRaw() async {
    final granted = await _ensureCameraPermission();
    if (!granted) {
      if (mounted) {
        _showThemedToast(
          'Camera permission required to scan QR',
          preferTop: true,
        );
      }
      return null;
    }

    final scanned = await Navigator.push<String>(
      Navigator.of(context, rootNavigator: true).context,
      MaterialPageRoute(builder: (_) => const _QrScanPage()),
    );
    return scanned?.trim();
  }

  Future<void> _startDmListener() async {
    if (_listening) return;
    _listening = true;
    while (mounted) {
      try {
        final result = await RustSyncWorker.waitForNewDms(
          nsec: nsec ?? '',
          wait: const Duration(seconds: 3),
        );
        // If the call short-circuited (mutex busy, init failure, or no data), avoid a tight loop.
        if (result == null || result.isEmpty || result == '[]') {
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }
        final List<dynamic> list = jsonDecode(result);
        var newMessages = list.cast<Map<String, dynamic>>();
        newMessages = await _decodeMessages(newMessages);
        debugPrint('[dm] Listener received ${newMessages.length} messages');
        _updateDmModesFromMessages(newMessages);
        if (newMessages.isNotEmpty && mounted) {
          // Mark new messages as session messages
          for (final msg in newMessages) {
            final id = msg['id'] as String?;
            if (id != null) _sessionMessages.add(id);
          }

          // Auto-add contacts from incoming messages
          final incomingPubkeys = newMessages
              .where((m) => m['direction'] == 'in')
              .map((m) => m['from'] as String?)
              .where((pk) => pk != null && pk.isNotEmpty)
              .toSet();

          for (final pubkey in incomingPubkeys) {
            if (!contacts.any((c) => c['pubkey'] == pubkey)) {
              final newContact = {'pubkey': pubkey!, 'nickname': ''};
              contacts.add(newContact);
            }
          }

          setState(() {
            final merged = _mergeMessages([...messages, ...newMessages]);
            _applyPendingReceiptsToList(merged);
            messages = merged;
            lastError = null;
            contacts = _dedupeContacts(contacts);
            _sortContactsByActivity();
          });
          _ensureSelectedContact();
          await _saveMessages();
          await _saveContacts();
          try {
            if (nsec != null && nsec!.isNotEmpty) {
              final prefs = await SharedPreferences.getInstance();
              final maxSeen = messages.fold<int>(0, (acc, m) {
                final raw = m['created_at'];
                if (raw is int && raw > acc) return raw;
                if (raw is double && raw > acc) return raw.round();
                if (raw is String) {
                  final parsed = int.tryParse(raw);
                  if (parsed != null && parsed > acc) return parsed;
                }
                return acc;
              });
              await prefs.setInt(_lastSeenKeyFor(nsec!), maxSeen);
              await prefs.setInt('last_notified_ts_${nsec!}', maxSeen);
            }
          } catch (_) {}
          if (_isNearBottom()) {
            _scrollToBottom();
          } else {
            _flagNewMessageWhileScrolledBack();
          }
        }
      } catch (e) {
        if (!mounted) break;
        setState(() => lastError ??= 'Listen failed: $e');
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    _listening = false;
  }

  void _ensureSelectedContact() {
    if (selectedContact != null &&
        contacts.any((c) => c['pubkey'] == selectedContact)) {
      return;
    }
    String? best;
    int bestTs = -1;
    for (final m in messages) {
      final contact = m['direction'] == 'out'
          ? (m['to'] as String?)
          : (m['from'] as String?);
      if (contact == null || contact.isEmpty) continue;
      if (!contacts.any((c) => c['pubkey'] == contact)) continue;
      final ts = m['created_at'] is int ? m['created_at'] as int : 0;
      if (ts > bestTs) {
        bestTs = ts;
        best = contact;
      }
    }
    best ??= contacts.isNotEmpty ? contacts.first['pubkey'] : null;
    if (best != null && mounted) {
      setState(() {
        selectedContact = best;
      });
      _persistVisibleState();
    }
  }

  int _lastActivityFor(String? pubkey) {
    if (pubkey == null || pubkey.isEmpty) return -1;
    var ts = -1;
    for (final m in messages) {
      final contact = m['direction'] == 'out'
          ? (m['to'] as String?)
          : (m['from'] as String?);
      if (contact != pubkey) continue;
      final created = m['created_at'];
      if (created is int && created > ts) {
        ts = created;
      }
    }
    return ts;
  }

  void _sortContactsByActivity() {
    contacts.sort((a, b) {
      final tsA = _lastActivityFor(a['pubkey'] as String?);
      final tsB = _lastActivityFor(b['pubkey'] as String?);
      return tsB.compareTo(tsA);
    });
  }

  List<Map<String, dynamic>> _dedupeContacts(List<Map<String, dynamic>> list) {
    final seen = <String, Map<String, dynamic>>{};
    for (final c in list.reversed) {
      final pubkey = (c['pubkey'] ?? '').toString();
      if (pubkey.isEmpty) continue;
      seen[pubkey] = c;
    }
    final deduped = seen.values.toList().reversed.toList();
    return deduped;
  }

  Future<void> _loadLocalProfileData({
    required int profileIndex,
    bool overrideLoaded = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final profileList = prefs.getStringList('profiles') ?? [];
    String? profileNsec;
    if (profileIndex >= 0 && profileIndex < profileList.length) {
      final parts = profileList[profileIndex].split('|');
      profileNsec = parts.isNotEmpty ? parts[0] : null;
    } else {
      profileNsec = nsec;
    }
    final contactsKey = profileNsec != null && profileNsec.isNotEmpty
        ? _contactsKeyFor(profileNsec)
        : 'contacts';
    final messagesKey = profileNsec != null && profileNsec.isNotEmpty
        ? _messagesKeyFor(profileNsec)
        : 'messages';
    final pendingKey = profileNsec != null && profileNsec.isNotEmpty
        ? _pendingDmsKeyFor(profileNsec)
        : 'pending_dms';
    final dmModesKey = profileNsec != null && profileNsec.isNotEmpty
        ? _dmModesKeyFor(profileNsec)
        : 'dm_modes';
    final dmOverridesKey = profileNsec != null && profileNsec.isNotEmpty
        ? _dmOverridesKeyFor(profileNsec)
        : 'dm_overrides';
    final dmGiftwrapKey = profileNsec != null && profileNsec.isNotEmpty
        ? _dmGiftwrapKeyFor(profileNsec)
        : 'dm_giftwrap_formats';

    final savedContacts = prefs.getStringList(contactsKey) ?? [];
    final savedMessages = prefs.getString(messagesKey);
    final pendingMessagesJson = prefs.getString(pendingKey);
    final dmModesJson = prefs.getString(dmModesKey);
    final dmOverridesJson = prefs.getString(dmOverridesKey);
    final dmGiftwrapJson = prefs.getString(dmGiftwrapKey);
    List<Map<String, dynamic>> loadedMessages = [];
    List<Map<String, dynamic>> pendingMessages = [];
    if (savedMessages != null && savedMessages.isNotEmpty) {
      try {
        final List<dynamic> msgsList = jsonDecode(savedMessages);
        loadedMessages = msgsList.cast<Map<String, dynamic>>();
      } catch (e) {
        print('Failed to load saved messages for profile: $e');
      }
    }
    if (pendingMessagesJson != null && pendingMessagesJson.isNotEmpty) {
      try {
        final List<dynamic> msgsList = jsonDecode(pendingMessagesJson);
        pendingMessages = msgsList
            .map((e) => Map<String, dynamic>.from(e as Map))
            .map(_normalizeIncomingMessage)
            .toList();
      } catch (_) {
        // ignore pending parse errors
      }
    }
    _dmModes.clear();
    if (dmModesJson != null && dmModesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(dmModesJson);
        if (decoded is Map) {
          _dmModes.addAll(
            decoded.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          );
        }
      } catch (_) {
        // ignore dm mode parse errors
      }
    }
    _dmOverrides.clear();
    if (dmOverridesJson != null && dmOverridesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(dmOverridesJson);
        if (decoded is Map) {
          _dmOverrides.addAll(
            decoded.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          );
        }
      } catch (_) {
        // ignore dm override parse errors
      }
    }
    _giftwrapFormats.clear();
    if (dmGiftwrapJson != null && dmGiftwrapJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(dmGiftwrapJson);
        if (decoded is Map) {
          _giftwrapFormats.addAll(
            decoded.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          );
        }
      } catch (_) {
        // ignore giftwrap format parse errors
      }
    }

    final loadedContacts = savedContacts
        .map((c) {
          final parts = c.split('|');
          return <String, dynamic>{
            'nickname': parts[0],
            'pubkey': parts.length > 1 ? parts[1] : '',
          };
        })
        .where((c) => c['pubkey']!.isNotEmpty)
        .toList();

    if (!mounted) return;
    setState(() {
      if (overrideLoaded || contacts.isEmpty) {
        contacts = _dedupeContacts(loadedContacts);
      }
      if (overrideLoaded || messages.isEmpty) {
        final merged = _mergeMessages([...loadedMessages, ...pendingMessages]);
        _applyPendingReceiptsToList(merged);
        messages = merged;
      }
      _sortContactsByActivity();
    });
    _updateDmModesFromMessages(messages);
    _ensureSelectedContact();
    await prefs.remove(pendingKey);
  }

  List<Map<String, dynamic>> _mergeMessages(
    List<Map<String, dynamic>> incoming,
  ) {
    final existingIds = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final m in messages) {
      final id = m['id'] as String?;
      if (id != null) {
        existingIds.add(id);
      }
      merged.add(m);
    }
    for (final m in incoming) {
      final id = m['id'] as String?;
      if (id != null) {
        if (existingIds.contains(id)) continue;
        existingIds.add(id);
      }
      merged.add(m);
    }
    merged.sort(
      (a, b) => (a['created_at'] ?? 0).compareTo(b['created_at'] ?? 0),
    );
    return merged;
  }

  Future<List<Map<String, dynamic>>> _decodeMessages(
    List<Map<String, dynamic>> msgs,
  ) async {
    final decoded = <Map<String, dynamic>>[];
    for (final m in msgs) {
      final receiptId = m['receipt_for']?.toString();
      if (receiptId != null && receiptId.isNotEmpty) {
        _handleIncomingReceipt(receiptId);
        continue;
      }
      final isPushstrClient = m['pushstr_client'] == true;
      final content = m['content']?.toString() ?? '';
      final senderPubkey = m['from']?.toString() ?? npub ?? '';
      final messageId = m['id'] as String?;
      final processed = await _decodeContent(content, senderPubkey, messageId);
      final normalized = {
        ...m,
        'content': processed['text'],
        'media': processed['media'],
      };
      decoded.add(normalized);
      if (isPushstrClient) {
        unawaited(_maybeSendReadReceipt(normalized));
      }
    }
    return decoded;
  }

  void _handleIncomingReceipt(String receiptId) {
    if (_applyReceiptToMessages(receiptId)) return;
    _pendingReceipts.add(receiptId);
  }

  bool _applyReceiptToMessages(String receiptId) {
    bool updated = false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final message in messages) {
      if (message['id'] != receiptId) continue;
      if (message['direction'] != 'out') continue;
      if (message['read_at'] == null) {
        message['read_at'] = now;
        message['read'] = true;
        updated = true;
      }
    }
    if (updated && mounted) {
      setState(() {});
    }
    if (updated) {
      unawaited(_saveMessages());
    }
    return updated;
  }

  void _applyPendingReceiptsToList(List<Map<String, dynamic>> list) {
    if (_pendingReceipts.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = <String>{..._pendingReceipts};
    for (final message in list) {
      final id = message['id'] as String?;
      if (id == null || !remaining.contains(id)) continue;
      if (message['direction'] != 'out') continue;
      if (message['read_at'] == null) {
        message['read_at'] = now;
        message['read'] = true;
      }
      remaining.remove(id);
    }
    _pendingReceipts
      ..clear()
      ..addAll(remaining);
  }

  void _replaceLocalMessageId(String localId, String eventId) {
    bool updated = false;
    for (final message in messages) {
      if (message['id'] == localId) {
        message['id'] = eventId;
        updated = true;
      }
    }
    if (_sessionMessages.remove(localId)) {
      _sessionMessages.add(eventId);
    }
    if (updated) {
      _applyPendingReceiptsToList(messages);
      if (mounted) {
        setState(() {});
      }
      unawaited(_saveMessages());
    }
  }

  Future<void> _maybeSendReadReceipt(Map<String, dynamic> message) async {
    if (message['direction'] != 'in') return;
    final sender = message['from']?.toString() ?? '';
    final messageId = message['id']?.toString() ?? '';
    if (sender.isEmpty || messageId.isEmpty) return;
    if (_sentReceipts.contains(messageId)) return;
    _sentReceipts.add(messageId);
    final dmKind = message['dm_kind']?.toString();
    final kind = _messageKind(message);
    final useLegacyDm = dmKind == 'nip04' || kind == 4;
    final payload = _buildReadReceiptPayload(messageId);
    unawaited(
      Future(() async {
        if (nsec == null || nsec!.isEmpty) return;
        try {
          if (useLegacyDm) {
            await RustSyncWorker.sendLegacyDm(
              recipient: sender,
              message: payload,
              nsec: nsec!,
            );
          } else {
            await RustSyncWorker.sendGiftDm(
              recipient: sender,
              content: payload,
              nsec: nsec!,
              useNip44: true,
            );
          }
        } catch (_) {
          // ignore receipt send failures
        }
      }),
    );
  }

  Future<Map<String, dynamic>> _decodeContent(
    String raw,
    String senderPubkey,
    String? messageId,
  ) async {
    raw = _stripPushstrClientTag(raw);
    final extracted = _extractPushstrMedia(raw);
    final cleanedText = (extracted['text'] ?? '').trim();
    final mediaJson = extracted['media'];
    final candidateJson =
        mediaJson ?? (raw.trim().startsWith('{') ? raw : null);
    if (candidateJson == null) {
      // Plain text message, not a media descriptor
      return {'text': cleanedText.isEmpty ? raw : cleanedText, 'media': null};
    }
    final textForAttachment = cleanedText.isNotEmpty
        ? cleanedText
        : '(attachment)';

    try {
      final parsed = jsonDecode(candidateJson);
      if (parsed is Map && parsed['media'] != null) {
        final media = Map<String, dynamic>.from(parsed['media'] as Map);
        final cacheKey =
            (media['cipher_sha256'] as String?) ??
            (media['url'] as String?) ??
            '';

        final isEncrypted =
            (media['encryption'] == 'aes-gcm' &&
            (media['iv'] ?? '').toString().isNotEmpty);

        // Non-encrypted link/media descriptor: show as downloadable attachment without decrypting
        if (!isEncrypted) {
          final mime = (media['mime'] as String?) ?? 'application/octet-stream';
          final filename = (media['filename'] as String?) ?? 'attachment';
          final url = (media['url'] as String?) ?? '';
          return {
            'text': textForAttachment,
            'media': {
              'bytes': null,
              'mime': mime,
              'size': media['size'] as int?,
              'sha256': media['sha256'] as String?,
              'filename': filename,
              'url': url,
              'nonEncrypted': true,
            },
          };
        }

        // Check cache first
        if (_decryptedMediaCache.containsKey(cacheKey)) {
          final cachedBytes = _decryptedMediaCache[cacheKey]!;
          final mime = (media['mime'] as String?) ?? 'application/octet-stream';
          final filename = (media['filename'] as String?) ?? 'attachment';
          return {
            'text': textForAttachment,
            'media': {
              'bytes': cachedBytes,
              'mime': mime,
              'size': media['size'] as int?,
              'sha256': media['sha256'] as String?,
              'filename': filename,
              'cached': true,
            },
          };
        }

        // Check if this is an old message (not from current session)
        final isOldMessage =
            messageId != null && !_sessionMessages.contains(messageId);

        if (isOldMessage) {
          // Return placeholder for old messages - will show decrypt button
          final mime = (media['mime'] as String?) ?? 'application/octet-stream';
          final filename = (media['filename'] as String?) ?? 'attachment';
          return {
            'text': textForAttachment,
            'media': {
              'bytes': null, // null indicates needs decryption
              'mime': mime,
              'size': media['size'] as int?,
              'sha256': media['sha256'] as String?,
              'filename': filename,
              'needsDecryption': true,
              'descriptor': media,
              'senderPubkey': senderPubkey,
              'cacheKey': cacheKey,
            },
          };
        }

        // Auto-decrypt for new messages
        final descriptorJson = jsonEncode(media);
        final bytes = Uint8List.fromList(
          api.decryptMedia(
            descriptorJson: descriptorJson,
            senderPubkey: senderPubkey,
            myNsec: nsec,
          ),
        );

        // Cache the decrypted bytes
        _decryptedMediaCache[cacheKey] = bytes;

        final mime = (media['mime'] as String?) ?? 'application/octet-stream';
        final filename = (media['filename'] as String?) ?? 'attachment';
        return {
          'text': textForAttachment,
          'media': {
            'bytes': bytes,
            'mime': mime,
            'size': media['size'] as int?,
            'sha256': media['sha256'] as String?,
            'filename': filename,
          },
        };
      }
    } catch (e) {
      print('Failed to decode media: $e');
      // Not a media descriptor or decryption failed, fall back to raw.
    }
    return {'text': cleanedText.isEmpty ? raw : cleanedText, 'media': null};
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (!force && !_isNearBottom()) return;
      final max = _scrollController.position.maxScrollExtent;
      if (force) {
        _scrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }
      _scrollController.jumpTo(max);
    });
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final max = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;
    return (max - offset) < 200;
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || !mounted) return;
    final nearBottom = _isNearBottom();
    if (nearBottom) {
      if (_showScrollToBottom || _hasNewMessages) {
        setState(() {
          _showScrollToBottom = false;
          _hasNewMessages = false;
        });
      }
      return;
    }
    if (!_showScrollToBottom) {
      setState(() {
        _showScrollToBottom = true;
      });
    }
  }

  void _flagNewMessageWhileScrolledBack() {
    if (!_scrollController.hasClients || !mounted) return;
    if (_isNearBottom()) return;
    setState(() {
      _showScrollToBottom = true;
      _hasNewMessages = true;
    });
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _showThemedToast('Could not open link', preferTop: true);
    }
  }

  Future<void> _attachFile() async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (!await _confirmLargeAttachment(file.size)) return;
      final bytes = file.bytes;
      if (bytes == null) return;
      final name = file.name;
      final mime =
          lookupMimeType(name, headerBytes: bytes) ??
          'application/octet-stream';
      await _setPendingAttachment(
        bytes: bytes,
        name: name,
        mime: mime,
        confirm: false,
      );
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
  }

  Future<void> _setPendingAttachment({
    required Uint8List bytes,
    required String name,
    required String mime,
    bool confirm = true,
  }) async {
    if (confirm && !await _confirmLargeAttachment(bytes.length)) return;
    setState(() {
      _pendingAttachment = _PendingAttachment(
        bytes: bytes,
        mime: mime,
        name: name,
      );
      _encryptPendingAttachment = true;
    });
    _scrollToBottom(force: true);
  }

  Future<void> _attachImage() async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 88,
      );
      if (picked == null) return;
      final size = await picked.length();
      if (!await _confirmLargeAttachment(size)) return;
      final bytes = await picked.readAsBytes();
      final name = picked.name;
      final mime = lookupMimeType(name, headerBytes: bytes) ?? 'image/*';
      await _setPendingAttachment(
        bytes: bytes,
        name: name,
        mime: mime,
        confirm: false,
      );
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
  }

  Future<void> _attachImageFromCamera() async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 88,
      );
      if (picked == null) return;
      final size = await picked.length();
      if (!await _confirmLargeAttachment(size)) return;
      final bytes = await picked.readAsBytes();
      final name = picked.name;
      final mime = lookupMimeType(name, headerBytes: bytes) ?? 'image/*';
      await _setPendingAttachment(
        bytes: bytes,
        name: name,
        mime: mime,
        confirm: false,
      );
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
  }

  Future<void> _attachVideo(ImageSource source) async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    try {
      final picked = await _imagePicker.pickVideo(source: source);
      if (picked == null) return;
      final size = await picked.length();
      if (!await _confirmLargeAttachment(size)) return;
      final bytes = await picked.readAsBytes();
      final name = picked.name;
      final mime = lookupMimeType(name, headerBytes: bytes) ?? 'video/*';
      await _setPendingAttachment(
        bytes: bytes,
        name: name,
        mime: mime,
        confirm: false,
      );
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
  }

  Future<void> _attachAudio() async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.audio,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (!await _confirmLargeAttachment(file.size)) return;
      final bytes = file.bytes;
      if (bytes == null) return;
      final name = file.name;
      final mime = lookupMimeType(name, headerBytes: bytes) ?? 'audio/*';
      await _setPendingAttachment(
        bytes: bytes,
        name: name,
        mime: mime,
        confirm: false,
      );
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
  }

  Future<void> _showRecordAudioSheet() async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> startRecording() async {
            final permitted = await _recorder.hasPermission();
            if (!permitted) {
              _showThemedToast('Microphone permission denied', preferTop: true);
              return;
            }
            final dir = await getTemporaryDirectory();
            final filename =
                'pushstr_recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
            final path = '${dir.path}/$filename';
            await _recorder.start(
              const RecordConfig(
                encoder: AudioEncoder.aacLc,
                bitRate: 128000,
                sampleRate: 44100,
              ),
              path: path,
            );
            _isRecordingAudio = true;
            _recordingElapsed = 0;
            _recordingTimer?.cancel();
            _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
              _recordingElapsed += 1;
              setModalState(() {});
            });
            setModalState(() {});
          }

          Future<void> stopRecording({required bool attach}) async {
            final path = await _recorder.stop();
            _recordingTimer?.cancel();
            _isRecordingAudio = false;
            _recordingElapsed = 0;
            setModalState(() {});
            if (path == null) return;
            if (!attach) {
              try {
                final file = File(path);
                if (await file.exists()) await file.delete();
              } catch (_) {}
              return;
            }
            final file = File(path);
            if (!await file.exists()) return;
            final bytes = await file.readAsBytes();
            final name = file.path.split(Platform.pathSeparator).last;
            final mime =
                lookupMimeType(name, headerBytes: bytes) ?? 'audio/mp4';
            await _setPendingAttachment(bytes: bytes, name: name, mime: mime);
            try {
              await file.delete();
            } catch (_) {}
          }

          final recording = _isRecordingAudio;
          final minutes = _recordingElapsed ~/ 60;
          final seconds = _recordingElapsed % 60;
          final timeLabel =
              '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    recording ? 'Recording…' : 'Record audio',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    timeLabel,
                    style: TextStyle(
                      fontSize: 20,
                      color: recording ? Colors.redAccent : Colors.white70,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () async {
                      if (recording) {
                        await stopRecording(attach: true);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } else {
                        await startRecording();
                      }
                    },
                    icon: Icon(recording ? Icons.stop : Icons.mic),
                    label: Text(recording ? 'Stop & Attach' : 'Start'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: recording
                          ? Colors.redAccent
                          : Colors.greenAccent,
                      foregroundColor: Colors.black,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (recording) {
                        await stopRecording(attach: false);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (_isRecordingAudio) {
      await _recorder.stop();
      _recordingTimer?.cancel();
      _isRecordingAudio = false;
      _recordingElapsed = 0;
    }
  }

  Widget _buildAttachOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color ?? Colors.white70, size: 26),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAttachChooser() async {
    if (selectedContact == null) {
      _showThemedToast('Select a contact first', preferTop: true);
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.05,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildAttachOption(
                icon: Icons.photo_camera,
                label: 'Camera',
                color: Colors.redAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _attachImageFromCamera();
                },
              ),
              _buildAttachOption(
                icon: Icons.videocam,
                label: 'Video Cam',
                color: Colors.redAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _attachVideo(ImageSource.camera);
                },
              ),
              _buildAttachOption(
                icon: Icons.mic,
                label: 'Record',
                onTap: () {
                  Navigator.pop(ctx);
                  _showRecordAudioSheet();
                },
                color: Colors.redAccent,
              ),
              _buildAttachOption(
                icon: Icons.photo_library,
                label: 'Gallery',
                color: Colors.lightBlueAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _attachImage();
                },
              ),
              _buildAttachOption(
                icon: Icons.video_library,
                label: 'Video',
                color: Colors.lightBlueAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _attachVideo(ImageSource.gallery);
                },
              ),
              _buildAttachOption(
                icon: Icons.audio_file,
                label: 'Audio',
                color: Colors.lightBlueAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _attachAudio();
                },
              ),
              _buildAttachOption(
                icon: Icons.insert_drive_file,
                label: 'File',
                color: Colors.lightBlueAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _attachFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _persistVisibleState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_visible', _appVisible);
      await prefs.setInt(
        'app_visible_ts',
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      if (selectedContact != null && selectedContact!.isNotEmpty) {
        await prefs.setString('visible_contact', selectedContact!);
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _ensureRustInitialized() async {
    if (_didInitRust) return;
    try {
      await RustLib.init();
      _didInitRust = true;
    } catch (e) {
      // flutter_rust_bridge throws on double-init; if that's the case, continue.
      if (!e.toString().contains(
        'Should not initialize flutter_rust_bridge twice',
      )) {
        rethrow;
      }
      _didInitRust = true;
    }
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'pushstr_fg',
        channelName: 'Pushstr background',
        channelDescription: 'Keeps Pushstr connected for catch-up sync',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 60 * 1000,
        isOnceEvent: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<bool> _startForegroundService() async {
    if (!Platform.isAndroid) return false;
    if (_startingForeground) return true;
    _startingForeground = true;
    final notifStatus = await Permission.notification.request();
    if (!notifStatus.isGranted) {
      _startingForeground = false;
      _showThemedToast(
        'Notification permission is required to stay connected',
        preferTop: true,
      );
      return false;
    }
    _initForegroundTask();
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      _startingForeground = false;
      return true;
    }
    try {
      final started = await FlutterForegroundTask.startService(
        notificationTitle: 'Pushstr running',
        notificationText: 'Staying connected for incoming messages',
        callback: foregroundStartCallback,
      ).timeout(const Duration(seconds: 5), onTimeout: () => false);
      return started;
    } catch (_) {
      return false;
    } finally {
      _startingForeground = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 74,
        leading: Builder(
          builder: (context) => Transform.translate(
            offset: const Offset(0, -2),
            child: IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Open menu',
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(child: _buildSendToDropdown(inAppBar: true)),
            const SizedBox(width: 8),
            _buildDmModeToggle(),
          ],
        ),
        actions: const [],
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.1),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Pushstr',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (npub != null)
                            Text(
                              _short(npub!),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.qr_code_2, size: 32),
                      tooltip: 'Show my npub QR',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 52,
                        height: 52,
                      ),
                      onPressed: _showMyNpubQr,
                    ),
                  ],
                ),
              ),
            ),
            for (final contact in contacts)
              ListTile(
                key: ValueKey(contact['pubkey'] ?? ''),
                title: Text(() {
                  final nickname = (contact['nickname'] ?? '')
                      .toString()
                      .trim();
                  return nickname.isNotEmpty
                      ? nickname
                      : _short(contact['pubkey'] ?? '');
                }()),
                subtitle: Text(
                  _short(contact['pubkey'] ?? ''),
                  style: const TextStyle(fontSize: 11),
                ),
                selected: selectedContact == contact['pubkey'],
                onTap: () {
                  setState(() => selectedContact = contact['pubkey']);
                  _persistVisibleState();
                  Navigator.pop(context);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Edit nickname',
                      onPressed: () => _editContact(context, contact),
                    ),
                    _HoldDeleteIcon(
                      active:
                          _holdActiveHome['delete_contact_${contact['pubkey']}'] ??
                          false,
                      progress: _holdProgressHomeFor(
                        'delete_contact_${contact['pubkey']}',
                      ),
                      onTap: () =>
                          _showHoldWarningHome('Hold 5s to delete contact'),
                      onHoldStart: () {
                        _startHoldActionHome(
                          'delete_contact_${contact['pubkey']}',
                          () async {
                            setState(() {
                              contacts.removeWhere(
                                (c) => c['pubkey'] == contact['pubkey'],
                              );
                              if (selectedContact == contact['pubkey']) {
                                selectedContact = contacts.isNotEmpty
                                    ? contacts.first['pubkey']
                                    : null;
                              }
                            });
                            _persistVisibleState();
                            await _saveContacts();
                            _cancelHoldActionHome(
                              'delete_contact_${contact['pubkey']}',
                            );
                          },
                          countdownLabel: 'delete contact',
                        );
                      },
                      onHoldEnd: () => _cancelHoldActionHome(
                        'delete_contact_${contact['pubkey']}',
                      ),
                    ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add contact'),
              onTap: () {
                Navigator.pop(context);
                _addContact(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan QR'),
              onTap: () {
                Navigator.pop(context);
                _scanContactQr();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                _showSettings(context);
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (lastError != null)
            Container(
              color: Colors.red.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Icon(Icons.error, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      lastError!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _buildHistory()),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    if (selectedContact == null) {
      return const Center(child: Text('Select a contact to start messaging'));
    }

    final convo =
        messages
            .where(
              (m) =>
                  (m['direction'] == 'out' && m['to'] == selectedContact) ||
                  (m['direction'] == 'in' && m['from'] == selectedContact),
            )
            .toList()
          ..sort((a, b) {
            final aTime = a['created_at'] ?? 0;
            final bTime = b['created_at'] ?? 0;
            final timeCmp = aTime.compareTo(bTime);
            if (timeCmp != 0) return timeCmp;
            final aSeq = _messageSeq(a);
            final bSeq = _messageSeq(b);
            if (aSeq != null && bSeq != null) {
              return aSeq.compareTo(bSeq);
            }
            return 0;
          });

    final display = <Map<String, dynamic>>[];
    int? lastIncomingSeq;
    for (final m in convo) {
      if (m['direction'] == 'in' && m['from'] == selectedContact) {
        final seq = _messageSeq(m);
        if (seq != null && lastIncomingSeq != null && seq > lastIncomingSeq + 1) {
          display.add({
            'direction': 'gap',
            'missing_from': lastIncomingSeq + 1,
            'missing_to': seq - 1,
          });
          _requestMissingMessages(selectedContact!);
        }
        if (seq != null) {
          lastIncomingSeq = seq;
        }
      }
      display.add(m);
    }

    final listView = ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: display.length,
      itemBuilder: (context, idx) {
        final m = display[idx];
        if (m['direction'] == 'gap') {
          final from = m['missing_from'];
          final to = m['missing_to'];
          final label = from == to
              ? 'Missing message (seq $from)'
              : 'Missing messages (seq $from-$to)';
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
            ),
          );
        }
        final align = m['direction'] == 'out'
            ? Alignment.centerRight
            : Alignment.centerLeft;
        final isOut = m['direction'] == 'out';
        final bubbleColor = isOut
            ? const Color(0xFF223E63)
            : const Color(0xFF282830);
        final textColor = isOut
            ? const Color.fromARGB(255, 238, 238, 238)
            : Colors.white;
        final fontWeight = FontWeight.w400;
        final blossomUrl = _extractBlossomUrl(m['content']);
        final dmBadge = _buildDmBadge(m);
        final attachmentBadge = _buildAttachmentBadge(m);
        final readReceiptBadge = _buildReadReceiptBadge(m);
        final resendBtn = isOut
            ? IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Resend',
                visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                onPressed: () => _resendMessage(m),
              )
            : null;
        final actions = !isOut
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      _copiedMessages[_messageCopyKey(m)] == true
                          ? Icons.check_circle
                          : Icons.copy,
                      size: 18,
                      color: _copiedMessages[_messageCopyKey(m)] == true
                          ? Colors.greenAccent
                          : null,
                    ),
                    tooltip: 'Copy message',
                    onPressed: () {
                      final text = (m['content'] ?? '').toString();
                      Clipboard.setData(ClipboardData(text: text));
                      _markMessageCopied(_messageCopyKey(m));
                    },
                  ),
                  if (blossomUrl != null)
                    IconButton(
                      icon: const Icon(Icons.download, size: 18),
                      tooltip: 'Download',
                      onPressed: () {
                        _launchUrl(blossomUrl);
                      },
                    ),
                ],
              )
            : null;

        return Column(
          crossAxisAlignment: isOut
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Align(
              alignment: align,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: EdgeInsets.only(bottom: isOut ? 2 : 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.7,
                    ),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.circular(12),
                      border: isOut
                          ? null
                          : Border.all(
                              color: Colors.black.withValues(alpha: 0.25),
                            ),
                      boxShadow: isOut
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.22),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        color: textColor,
                        fontWeight: fontWeight,
                      ),
                      child: _buildMessageContent(m, isOut: isOut),
                    ),
                  ),
                  if (actions != null) ...[const SizedBox(width: 6), actions],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                left: 4,
                right: 4,
                bottom: isOut ? 7 : 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _friendlyTime(m['created_at']),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                  if (dmBadge != null) ...[const SizedBox(width: 6), dmBadge],
                  if (attachmentBadge != null) ...[
                    const SizedBox(width: 6),
                    attachmentBadge,
                  ],
                  if (readReceiptBadge != null) ...[
                    const SizedBox(width: 6),
                    readReceiptBadge,
                  ],
                  if (resendBtn != null) ...[
                    const SizedBox(width: 4),
                    resendBtn,
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
    final canScroll =
        _scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 8;
    return Stack(
      children: [
        listView,
        if (_showScrollToBottom && canScroll)
          Positioned(
            right: 12,
            bottom: 12,
            child: _buildScrollToBottomButton(),
          ),
      ],
    );
  }

  Widget _buildScrollToBottomButton() {
    final iconColor = _hasNewMessages ? _historyAccentGreen : Colors.grey;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          _scrollToBottom(force: true);
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(Icons.arrow_downward_rounded, size: 18, color: iconColor),
        ),
      ),
    );
  }

  Widget? _buildReadReceiptBadge(Map<String, dynamic> message) {
    if (message['direction'] != 'out') return null;
    final hasRead = message['read_at'] != null || message['read'] == true;
    final id = message['id']?.toString() ?? '';
    final isLocal = id.startsWith('local_');
    final color = hasRead ? _historyAccentGreen : Colors.grey.shade500;
    final tooltip = hasRead
        ? 'Read'
        : (isLocal ? 'Sending' : 'Sent');
    return Tooltip(
      message: tooltip,
      child: Icon(
        hasRead
            ? Icons.visibility
            : (isLocal ? Icons.visibility_outlined : Icons.visibility),
        size: 12,
        color: color,
      ),
    );
  }

  Widget? _buildAttachmentBadge(Map<String, dynamic> message) {
    final media = message['media'];
    if (media is! Map) return null;
    final nonEncrypted =
        media['nonEncrypted'] == true ||
        (media['encryption']?.toString() == 'none');
    if (!nonEncrypted) return null;
    return Tooltip(
      message: 'Unencrypted attachment',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 3),
        // decoration: BoxDecoration(
        //   color: Colors.orange.withValues(alpha: 0.2),
        //   borderRadius: BorderRadius.circular(10),
        //   border: Border.all(color: Colors.orange.withValues(alpha: 0.6)),
        // ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.lock_open, size: 14, color: Colors.orange),
          ],
        ),
      ),
    );
  }

  Widget _buildSendToDropdown({bool inAppBar = false}) {
    final showDetails = !inAppBar;
    final contactItems = contacts.map((c) {
      final nickname = c['nickname'] ?? '';
      final pubkey = c['pubkey'] ?? '';
      final primary = _short(pubkey);
      final label = nickname.trim().isNotEmpty
          ? '$nickname · $primary'
          : primary;

      return DropdownMenuItem<String>(
        value: pubkey,
        child: Text(label, overflow: TextOverflow.ellipsis),
      );
    }).toList();
    final selectedValue = contacts.any((c) => c['pubkey'] == selectedContact)
        ? selectedContact
        : null;

    final dropdown = DropdownButtonFormField<String>(
      value: selectedValue,
      isExpanded: true,
      isDense: inAppBar,
      itemHeight: showDetails ? kMinInteractiveDimension : null,
      decoration: inAppBar
          ? InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.white, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.white, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.white.withOpacity(0.9),
                  width: 1.2,
                ),
              ),
            )
          : const InputDecoration(
              labelText: 'Send to',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
      selectedItemBuilder: (_) => contacts.map((c) {
        final pubkey = c['pubkey'] ?? '';
        final nickname = (c['nickname'] ?? '').toString().trim();
        final label = nickname.isNotEmpty ? nickname : _short(pubkey);
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(label, overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      hint: const Text('Select a contact'),
      items: contactItems,
      onChanged: contactItems.isEmpty
          ? null
          : (value) {
              if (value == null) return;
              setState(() => selectedContact = value);
              _persistVisibleState();
              _scrollToBottom(force: true);
            },
    );

    if (inAppBar) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(height: 46, child: dropdown),
        ),
      );
    }
    return dropdown;
  }

  Widget _buildComposer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pendingAttachment != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: _PendingPreview(
              attachment: _pendingAttachment!,
              onRemove: () => setState(() => _pendingAttachment = null),
              encrypted: _encryptPendingAttachment,
              onToggleEncryption: () {
                setState(() {
                  _encryptPendingAttachment = !_encryptPendingAttachment;
                });
              },
            ),
          ),
        Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.3),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: messageCtrl,
                builder: (context, value, _) {
                  final hasContent =
                      value.text.trim().isNotEmpty ||
                      _pendingAttachment != null;
                  final noContacts = contacts.isEmpty;
                  final canSend = selectedContact != null && !noContacts;
                  return Row(
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: TextField(
                            controller: messageCtrl,
                            focusNode: _messageFocus,
                            keyboardType: TextInputType.multiline,
                            minLines: 1,
                            maxLines: null, // allow scrolling inside the field
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              filled: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          noContacts
                              ? Icons.person_add_alt
                              : (hasContent ? Icons.send : Icons.attach_file),
                        ),
                        onPressed: noContacts
                            ? () => _addContact(context)
                            : (canSend
                                  ? () => hasContent
                                        ? _sendMessage()
                                        : _showAttachChooser()
                                  : null),
                        style: IconButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        if (Platform.isAndroid) const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final previousNsec = nsec ?? '';
    final previousProfileIndex = prefs.getInt('selected_profile_index') ?? 0;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );

    final updatedPrefs = await SharedPreferences.getInstance();
    final currentNsec = updatedPrefs.getString('nostr_nsec') ?? '';
    final currentProfileIndex =
        updatedPrefs.getInt('selected_profile_index') ?? 0;
    final cachedNpubs = updatedPrefs.getStringList('profile_npubs_cache') ?? [];
    final cachedNpub = (currentProfileIndex < cachedNpubs.length)
        ? cachedNpubs[currentProfileIndex]
        : '';
    final didProfileChange =
        currentNsec != previousNsec ||
        currentProfileIndex != previousProfileIndex;

    if (!didProfileChange && cachedNpub.isEmpty) {
      // No profile change and nothing to refresh
      return;
    }

    if (mounted && didProfileChange) {
      setState(() {
        isConnected = false;
        lastError = null;
      });
    }

    var newNpub = cachedNpub;
    if (newNpub.isEmpty && currentNsec.isNotEmpty) {
      try {
        newNpub = api.initNostr(nsec: currentNsec);
      } catch (_) {
        newNpub = '';
      }
    }

    if (newNpub.isEmpty) {
      try {
        newNpub = api.getNpub();
      } catch (_) {
        // ignore
      }
    }

    if (!mounted) return;

    setState(() {
      nsec = currentNsec;
      if (newNpub.isNotEmpty) {
        npub = newNpub;
      }
      if (didProfileChange) {
        isConnected = true;
      }
    });

    if (didProfileChange) {
      await _loadLocalProfileData(
        profileIndex: currentProfileIndex,
        overrideLoaded: true,
      );
      // Restart listener and fetch messages
      _startDmListener();
      _fetchMessages();
    }
  }

  Future<void> _showMyNpubQr() async {
    try {
      final npubValue = (npub != null && npub!.isNotEmpty)
          ? npub!
          : api.getNpub();
      if (!mounted) return;
      if (npubValue.isEmpty) {
        _showThemedToast('No npub available', preferTop: true);
        return;
      }
      await showDialog(
        context: context,
        builder: (ctx) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'My npub',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrImageView(
                    data: npubValue,
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  npubValue,
                  style: const TextStyle(fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        _showThemedToast('Unable to show QR: $e', preferTop: true);
      }
    }
  }

  String _short(String text) {
    var value = text.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('npub')) {
      try {
        value = api.hexToNpub(hex: value);
      } catch (_) {
        // fall back to raw text if conversion fails
      }
    }
    if (value.length <= 12) return value;
    return '${value.substring(0, 8)}...${value.substring(value.length - 4)}';
  }

  String _messageCopyKey(Map<String, dynamic> message) {
    final id = message['id']?.toString();
    if (id != null && id.isNotEmpty) return id;
    final created = message['created_at']?.toString() ?? '';
    final content = message['content']?.toString() ?? '';
    return '$created|$content';
  }

  void _markMessageCopied(String key) {
    _copiedMessageTimers[key]?.cancel();
    setState(() {
      _copiedMessages[key] = true;
    });
    _copiedMessageTimers[key] = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _copiedMessages.remove(key);
      });
      _copiedMessageTimers.remove(key);
    });
  }

  String _stripNip18(String text) {
    // Remove NIP-18 prefix: [//]: # (nip18)
    return text
        .replaceFirst(
          RegExp(r'^\[\/\/\]:\s*#\s*\(nip18\)\s*', caseSensitive: false),
          '',
        )
        .trim();
  }

  Widget _buildMessageContent(
    Map<String, dynamic> message, {
    required bool isOut,
  }) {
    final content = message['content']?.toString() ?? '';
    final media = message['media'] as Map<String, dynamic>?;
    final cleaned = _stripNip18(content);

    // Media attachment that needs decryption
    if (media != null && media['needsDecryption'] == true) {
      final mime = media['mime']?.toString() ?? 'application/octet-stream';
      final filename = media['filename']?.toString() ?? 'Attachment';
      final isImage = mime.startsWith('image/');

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade800,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(isImage ? Icons.image : Icons.attach_file, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        filename,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.lock_open, size: 16),
                  label: Text('Decrypt: $filename'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onPressed: () => _decryptMedia(message),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Media attachment with decrypted bytes
    if (media != null && media['bytes'] != null) {
      final bytes = _asUint8List(media['bytes']);
      if (bytes == null) {
        return const Text('(attachment unavailable)');
      }
      final mime = media['mime']?.toString() ?? 'application/octet-stream';
      final isImage = mime.startsWith('image/');
      final isVideo = mime.startsWith('video/');
      final isAudio = mime.startsWith('audio/');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImage)
            GestureDetector(
              onTap: () => _openImageViewer(
                bytes: bytes,
                title: media['filename']?.toString(),
              ),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => Text(
                  'Failed to load image',
                  style: TextStyle(color: Colors.grey.shade400),
                ),
              ),
            ),
          if (!isImage)
            InkWell(
              onTap: () {
                if (isVideo) {
                  _openVideoPlayer(
                    bytes: bytes,
                    title: media['filename']?.toString(),
                    mime: mime,
                  );
                } else if (isAudio) {
                  _openAudioPlayer(
                    bytes: bytes,
                    title: media['filename']?.toString(),
                    mime: mime,
                  );
                }
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isVideo
                        ? Icons.play_circle_outline
                        : (isAudio ? Icons.volume_up : Icons.attach_file),
                    size: 20,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      media['filename']?.toString() ?? 'Attachment',
                      style: const TextStyle(
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.download, size: 20),
                color: Colors.white,
                onPressed: () => _saveMedia(bytes, mime),
              ),
              if (!isImage)
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  color: Colors.white,
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: 'Attachment (${mime})'),
                    );
                    _showThemedToast('Attachment copied', preferTop: true);
                  },
                ),
            ],
          ),
        ],
      );
    }

    // Media link (non-encrypted) with URL only
    if (media != null && media['url'] != null) {
      final url = media['url'].toString();
      final filename = media['filename']?.toString() ?? 'Attachment';
      final mime = media['mime']?.toString() ?? 'application/octet-stream';
      final isBlossom = _isBlossomLink(url, media);
      final isImage =
          mime.startsWith('image/') ||
          RegExp(
            r'\.(png|jpe?g|gif|webp)$',
            caseSensitive: false,
          ).hasMatch(url);
      final isVideo =
          mime.startsWith('video/') ||
          RegExp(r'\.(mp4|mov|webm|mkv)$', caseSensitive: false).hasMatch(url);
      final isAudio =
          mime.startsWith('audio/') ||
          RegExp(r'\.(mp3|m4a|wav|ogg)$', caseSensitive: false).hasMatch(url);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(filename, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          if (isImage)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: GestureDetector(
                onTap: () => _openImageViewer(url: url, title: filename),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Text(
                    'Image preview failed',
                    style: TextStyle(color: Colors.grey.shade400),
                  ),
                ),
              ),
            ),
          if (!isImage && (isVideo || isAudio))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () {
                  if (isVideo) {
                    _openVideoPlayer(url: url, title: filename, mime: mime);
                  } else if (isAudio) {
                    _openAudioPlayer(url: url, title: filename, mime: mime);
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isVideo ? Icons.play_circle_outline : Icons.volume_up,
                      size: 20,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        isVideo ? 'Play video' : 'Play audio',
                        style: const TextStyle(
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: Icon(
                  isBlossom ? Icons.download : Icons.open_in_new,
                  size: 18,
                ),
                label: Text(isBlossom ? 'Download' : 'Open link'),
                onPressed: () => _launchUrl(url),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                color: Colors.white,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  _showThemedToast('Link copied', preferTop: true);
                },
              ),
            ],
          ),
        ],
      );
    }

    // Inline data URI image
    if (cleaned.startsWith('data:') && cleaned.contains('base64,')) {
      try {
        final base64Part = cleaned.split('base64,').last;
        final bytes = base64Decode(base64Part);
        return Image.memory(bytes, fit: BoxFit.contain);
      } catch (_) {
        // fallback to normal handling
      }
    }

    // Regular text message
    final url = _firstUrl(cleaned);
    if (url != null) {
      final isImage = RegExp(
        r'\.(png|jpe?g|gif|webp)$',
        caseSensitive: false,
      ).hasMatch(url);
      final textPart = cleaned.replaceFirst(url, '').trim();
      final isBlossom = _isBlossomLink(url);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (textPart.isNotEmpty)
            Text(textPart, style: const TextStyle(fontSize: 15)),
          TextButton(
            onPressed: () => _launchUrl(url),
            child: Text(
              url,
              style: const TextStyle(
                decoration: TextDecoration.underline,
                color: Colors.lightBlueAccent,
              ),
            ),
          ),
          if (isImage)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => Text(
                  'Image preview failed',
                  style: TextStyle(color: Colors.grey.shade400),
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: Icon(
                  isBlossom ? Icons.download : Icons.open_in_new,
                  size: 18,
                ),
                label: Text(isBlossom ? 'Download' : 'Open link'),
                onPressed: () => _launchUrl(url),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                color: Colors.white,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  _showThemedToast('Link copied', preferTop: true);
                },
              ),
            ],
          ),
        ],
      );
    }

    return Text(cleaned, style: const TextStyle(fontSize: 15));
  }

  Future<void> _decryptMedia(Map<String, dynamic> message) async {
    final media = message['media'] as Map<String, dynamic>?;
    if (media == null || media['descriptor'] == null) return;

    try {
      final descriptor = media['descriptor'] as Map<String, dynamic>;
      final senderPubkey = media['senderPubkey'] as String;
      final cacheKey = media['cacheKey'] as String;
      final descriptorJson = jsonEncode(descriptor);

      // Show loading state
      setState(() {
        lastError = 'Decrypting...';
      });

      final bytes = Uint8List.fromList(
        api.decryptMedia(
          descriptorJson: descriptorJson,
          senderPubkey: senderPubkey,
          myNsec: nsec,
        ),
      );

      // Cache the decrypted bytes
      _decryptedMediaCache[cacheKey] = bytes;

      // Update the message in place
      setState(() {
        media['bytes'] = bytes;
        media['needsDecryption'] = false;
        lastError = null;
      });

      await _saveMessages();
    } catch (e) {
      setState(() {
        lastError = 'Decrypt failed: $e';
      });
    }
  }

  Future<void> _saveMedia(Uint8List bytes, String mime) async {
    try {
      final ext = extensionFromMime(mime);
      final filename = 'pushstr_${DateTime.now().millisecondsSinceEpoch}.$ext';
      if (Platform.isAndroid) {
        final uri = await _storageChannel.invokeMethod<String>(
          'saveToDownloads',
          {'bytes': bytes, 'mime': mime, 'filename': filename},
        );
        if (!mounted) return;
        if (uri == null) {
          _showThemedToast('Save failed', preferTop: true);
        } else {
          _showThemedToast('Saved to Downloads', preferTop: true);
        }
        return;
      }

      if (Platform.isIOS) {
        final file = await _writeTempMediaFile(bytes, mime);
        final ok = await _storageChannel.invokeMethod<bool>('shareFile', {
          'path': file.path,
          'mime': mime,
          'filename': filename,
        });
        if (!mounted) return;
        if (ok != true) {
          _showThemedToast('Save failed', preferTop: true);
        }
        return;
      }

      final selectedDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose where to save',
      );
      if (selectedDir == null) {
        if (mounted) {
          _showThemedToast(
            'Save cancelled',
            preferTop: true,
            duration: const Duration(milliseconds: 800),
          );
        }
        return;
      }
      final file = File('$selectedDir/$filename');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      _showThemedToast('Saved to $selectedDir', preferTop: true);
    } catch (e) {
      if (!mounted) return;
      _showThemedToast('Save failed: $e', preferTop: true);
    }
  }

  Future<File> _writeTempMediaFile(Uint8List bytes, String mime) async {
    final dir = await getTemporaryDirectory();
    final ext = extensionFromMime(mime);
    final filename = 'pushstr_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _openImageViewer({
    Uint8List? bytes,
    String? url,
    String? title,
  }) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ImageViewerPage(bytes: bytes, url: url, title: title),
      ),
    );
  }

  Future<void> _openVideoPlayer({
    Uint8List? bytes,
    String? url,
    String? title,
    required String mime,
  }) async {
    if (!mounted) return;
    String? filePath;
    if (bytes != null) {
      final file = await _writeTempMediaFile(bytes, mime);
      filePath = file.path;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _VideoPlayerPage(url: url, filePath: filePath, title: title),
      ),
    );
  }

  Future<void> _openAudioPlayer({
    Uint8List? bytes,
    String? url,
    String? title,
    required String mime,
  }) async {
    if (!mounted) return;
    String? filePath;
    if (bytes != null) {
      final file = await _writeTempMediaFile(bytes, mime);
      filePath = file.path;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _AudioPlayerPage(url: url, filePath: filePath, title: title),
      ),
    );
  }

  String extensionFromMime(String mime) {
    switch (mime) {
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'video/mp4':
        return 'mp4';
      case 'video/quicktime':
        return 'mov';
      case 'video/webm':
        return 'webm';
      case 'video/x-matroska':
        return 'mkv';
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/mp4':
        return 'm4a';
      case 'audio/wav':
        return 'wav';
      case 'audio/ogg':
        return 'ogg';
      default:
        return 'bin';
    }
  }

  Uint8List? _asUint8List(dynamic value) {
    if (value == null) return null;
    if (value is Uint8List) return value;
    if (value is List) {
      try {
        return Uint8List.fromList(value.cast<int>());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  String? _firstUrl(String text) {
    final match = RegExp(
      r'https?://\S+',
      caseSensitive: false,
    ).firstMatch(text);
    return match?.group(0);
  }

  bool _isBlossomLink(String url, [Map<String, dynamic>? meta]) {
    final uri = Uri.tryParse(url);
    final hostHasBlossom = uri?.host.contains('blossom') ?? false;
    final frag = uri?.fragment ?? '';
    final fragHasMeta =
        frag.contains('m=') || frag.contains('size=') || frag.contains('x=');
    final hasMeta =
        (meta?['sha256']?.toString().isNotEmpty ?? false) ||
        (meta?['cipher_sha256']?.toString().isNotEmpty ?? false) ||
        (meta?['iv']?.toString().isNotEmpty ?? false) ||
        (meta?['mime']?.toString().isNotEmpty ?? false) ||
        (meta?['size'] != null);
    return hasMeta && (hostHasBlossom || fragHasMeta);
  }

  Future<void> _initShareListener() async {
    try {
      // Handle initial share when app is launched from share sheet
      final initial = await _shareChannel.invokeMethod<dynamic>(
        'getInitialShare',
      );
      await _handleSharedPayload(initial);

      // Listen for subsequent shares while app is alive
      _shareChannel.setMethodCallHandler((call) async {
        if (call.method == 'onShare') {
          await _handleSharedPayload(call.arguments);
        }
      });
    } catch (e) {
      // Swallow share errors to avoid breaking startup
      debugPrint('Share init failed: $e');
    }
  }

  Future<void> _handleSharedPayload(dynamic payload) async {
    if (payload is! Map) return;
    final text = payload['text']?.toString() ?? '';
    final bytes = _asUint8List(payload['bytes']);
    final mime = payload['type']?.toString() ?? '';
    final name = payload['name']?.toString();

    if (bytes != null && bytes.isNotEmpty) {
      if (!await _confirmLargeAttachment(bytes.length)) return;
      final resolvedMime = mime.isNotEmpty
          ? mime
          : (lookupMimeType(name ?? '', headerBytes: bytes) ??
                'application/octet-stream');
      final filename = (name != null && name.isNotEmpty)
          ? name
          : 'shared.${extensionFromMime(resolvedMime)}';
      setState(() {
        _pendingAttachment = _PendingAttachment(
          bytes: bytes,
          mime: resolvedMime,
          name: filename,
        );
        _encryptPendingAttachment = true;
        if (text.isNotEmpty) {
          messageCtrl.text = text;
        }
      });
      _messageFocus.requestFocus();
      _scrollToBottom(force: true);
      return;
    }

    if (text.isNotEmpty) {
      setState(() {
        messageCtrl.text = text;
      });
      // Focus composer so the user can just hit send
      _messageFocus.requestFocus();
    }
  }

  String _friendlyTime(int? timestamp) {
    if (timestamp == null) return '';

    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Just now';

    // Helper to get midnight of a date
    DateTime midnight(DateTime d) => DateTime(d.year, d.month, d.day);

    final todayStart = midnight(now);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final dateStart = midnight(date);

    // Format time part (e.g., "6:30 PM")
    final hour = date.hour > 12
        ? date.hour - 12
        : (date.hour == 0 ? 12 : date.hour);
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';
    final timePart = '$hour:$minute $period';

    if (dateStart == todayStart) {
      return 'Today at $timePart';
    }

    if (dateStart == yesterdayStart) {
      return 'Yesterday at $timePart';
    }

    // For older dates, show full date
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    final weekday = weekdays[date.weekday - 1];
    final month = months[date.month - 1];
    final day = date.day;

    return '$weekday, $month $day at $timePart';
  }

  String? _extractBlossomUrl(dynamic content) {
    try {
      final cleaned = _stripNip18(content?.toString() ?? '');
      final parsed = jsonDecode(cleaned);
      if (parsed is Map) {
        final map = Map<String, dynamic>.from(parsed);
        final topUrl = map['url'];
        if (topUrl is String && _isBlossomLink(topUrl, map)) {
          return topUrl;
        }
        if (map['media'] is Map) {
          final media = Map<String, dynamic>.from(map['media'] as Map);
          final url = media['url'];
          if (url is String && _isBlossomLink(url, media)) return url;
        }
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

  void _showThemedToast(
    String message, {
    bool preferTop = false,
    Duration? duration,
  }) {
    _toastEntry?.remove();
    _toastTimer?.cancel();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final theme = Theme.of(context);
    final padding = MediaQuery.of(context).viewPadding;

    _toastEntry = OverlayEntry(
      builder: (_) => Positioned(
        top: preferTop ? padding.top + 16 : null,
        bottom: preferTop ? null : padding.bottom + 16,
        left: 0,
        right: 0,
        child: Align(
          alignment: preferTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              child: IntrinsicWidth(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.8),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.45),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_toastEntry!);
    _toastTimer = Timer(duration ?? const Duration(milliseconds: 1600), () {
      _toastEntry?.remove();
      _toastEntry = null;
    });
  }

  // Home screen hold helpers
  void _startHoldActionHome(
    String key,
    VoidCallback onComplete, {
    String? countdownLabel,
  }) {
    _holdTimersHome[key]?.cancel();
    final start = DateTime.now();
    final totalSeconds = (_holdMillis / 1000).ceil();
    _holdLastSecondHome[key] = totalSeconds;
    setState(() {
      _holdActiveHome[key] = true;
      _holdProgressHome[key] = 0;
    });
    if (countdownLabel != null) {
      _showHoldWarningHome('Hold ${totalSeconds}s to $countdownLabel');
    }
    _holdTimersHome[key] = Timer.periodic(const Duration(milliseconds: 120), (
      t,
    ) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final progress = (elapsed / _holdMillis).clamp(0.0, 1.0);
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _holdProgressHome[key] = progress;
      });
      final remainingSeconds =
          ((_holdMillis - elapsed).clamp(0, _holdMillis) / 1000).ceil();
      if (countdownLabel != null &&
          remainingSeconds != _holdLastSecondHome[key]) {
        _holdLastSecondHome[key] = remainingSeconds;
        _showHoldWarningHome('Hold ${remainingSeconds}s to $countdownLabel');
      }
      if (progress >= 1) {
        t.cancel();
        _holdTimersHome.remove(key);
        _holdLastSecondHome.remove(key);
        setState(() {
          _holdActiveHome[key] = false;
        });
        onComplete();
      }
    });
  }

  void _cancelHoldActionHome(String key) {
    _holdTimersHome[key]?.cancel();
    _holdTimersHome.remove(key);
    _holdLastSecondHome.remove(key);
    if (!mounted) return;
    setState(() {
      _holdActiveHome[key] = false;
      _holdProgressHome[key] = 0;
    });
  }

  double _holdProgressHomeFor(String key) => _holdProgressHome[key] ?? 0;

  void _showHoldWarningHome(String message) {
    if (!mounted) return;
    _showThemedToast(message, preferTop: true);
  }
}

class _PendingAttachment {
  _PendingAttachment({
    required this.bytes,
    required this.mime,
    required this.name,
  });
  final Uint8List bytes;
  final String mime;
  final String name;
}

class _PendingPreview extends StatelessWidget {
  const _PendingPreview({
    required this.attachment,
    required this.onRemove,
    required this.encrypted,
    required this.onToggleEncryption,
  });

  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  final bool encrypted;
  final VoidCallback onToggleEncryption;

  @override
  Widget build(BuildContext context) {
    final isImage = attachment.mime.startsWith('image/');
    Widget preview;
    if (isImage) {
      preview = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(attachment.bytes, height: 120, fit: BoxFit.cover),
      );
    } else {
      preview = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Flexible(fit: FlexFit.loose, child: preview),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              encrypted ? Icons.lock : Icons.lock_open,
              color: encrypted ? Colors.greenAccent : Colors.orangeAccent,
            ),
            onPressed: onToggleEncryption,
            tooltip: encrypted
                ? 'Encrypted attachment (tap to send unencrypted)'
                : 'Unencrypted attachment (tap to encrypt)',
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onRemove,
            tooltip: 'Remove attachment',
          ),
        ],
      ),
    );
  }
}

class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan contact QR')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_handled) return;
          final code = capture.barcodes.isNotEmpty
              ? capture.barcodes.first.rawValue
              : null;
          if (code == null || code.isEmpty) return;
          _handled = true;
          Navigator.of(context).pop(code);
        },
      ),
    );
  }
}

class _ImageViewerPage extends StatelessWidget {
  const _ImageViewerPage({this.bytes, this.url, this.title});

  final Uint8List? bytes;
  final String? url;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final image = bytes != null
        ? Image.memory(bytes!, fit: BoxFit.contain)
        : Image.network(url ?? '', fit: BoxFit.contain);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title ?? 'Image'),
        backgroundColor: Colors.black,
      ),
      body: Center(child: InteractiveViewer(child: image)),
    );
  }
}

class _VideoPlayerPage extends StatefulWidget {
  const _VideoPlayerPage({this.url, this.filePath, this.title});

  final String? url;
  final String? filePath;
  final String? title;

  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
  VideoPlayerController? _controller;
  Future<void>? _initFuture;
  bool _showControls = true;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    if (widget.filePath != null) {
      _controller = VideoPlayerController.file(File(widget.filePath!));
    } else {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url ?? ''),
      );
    }
    _initFuture = _controller!.initialize();
    _controller!.setLooping(true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _hideControlsTimer?.cancel();
    super.dispose();
  }

  void _toggleControls() {
    if (!mounted) return;
    setState(() => _showControls = !_showControls);
    if (_showControls && _controller?.value.isPlaying == true) {
      _startHideTimer();
    }
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_controller?.value.isPlaying == true) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title ?? 'Video'),
        backgroundColor: Colors.black,
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final controller = _controller!;
          return AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              final position = controller.value.position;
              final duration = controller.value.duration;
              final progress = duration.inMilliseconds == 0
                  ? 0.0
                  : (position.inMilliseconds / duration.inMilliseconds).clamp(
                      0.0,
                      1.0,
                    );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                      if (_showControls)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            color: Colors.black.withOpacity(0.35),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.replay_10,
                                        color: Colors.white,
                                      ),
                                      onPressed: () {
                                        final newPos =
                                            position -
                                            const Duration(seconds: 10);
                                        controller.seekTo(
                                          newPos < Duration.zero
                                              ? Duration.zero
                                              : newPos,
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(
                                        controller.value.isPlaying
                                            ? Icons.pause_circle
                                            : Icons.play_circle,
                                        color: Colors.white,
                                        size: 48,
                                      ),
                                      onPressed: () {
                                        if (controller.value.isPlaying) {
                                          controller.pause();
                                        } else {
                                          controller.play();
                                          _startHideTimer();
                                        }
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.forward_10,
                                        color: Colors.white,
                                      ),
                                      onPressed: () {
                                        final newPos =
                                            position +
                                            const Duration(seconds: 10);
                                        controller.seekTo(
                                          newPos > duration ? duration : newPos,
                                        );
                                      },
                                    ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    Text(
                                      _formatDuration(position),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Expanded(
                                      child: Slider(
                                        value: progress,
                                        onChanged: (value) {
                                          if (duration.inMilliseconds == 0)
                                            return;
                                          final target = Duration(
                                            milliseconds:
                                                (duration.inMilliseconds *
                                                        value)
                                                    .round(),
                                          );
                                          controller.seekTo(target);
                                        },
                                      ),
                                    ),
                                    Text(
                                      _formatDuration(duration),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _AudioPlayerPage extends StatefulWidget {
  const _AudioPlayerPage({this.url, this.filePath, this.title});

  final String? url;
  final String? filePath;
  final String? title;

  @override
  State<_AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends State<_AudioPlayerPage> {
  final AudioPlayer _player = AudioPlayer();
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      if (widget.filePath != null) {
        await _player.setFilePath(widget.filePath!);
      } else if (widget.url != null && widget.url!.isNotEmpty) {
        await _player.setUrl(widget.url!);
      }
      _duration = _player.duration ?? Duration.zero;
      setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${value.inHours > 0 ? '${value.inHours}:' : ''}$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? 'Audio')),
      body: Center(
        child: StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, snapshot) {
            final position = snapshot.data ?? Duration.zero;
            final max = _duration.inMilliseconds > 0
                ? _duration
                : Duration.zero;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.audiotrack, size: 64, color: Colors.white70),
                const SizedBox(height: 12),
                Text(
                  '${_formatDuration(position)} / ${_formatDuration(max)}',
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
                Slider(
                  value: max.inMilliseconds == 0
                      ? 0
                      : position.inMilliseconds.clamp(0, max.inMilliseconds) /
                            max.inMilliseconds,
                  onChanged: max.inMilliseconds == 0
                      ? null
                      : (value) async {
                          final targetMs = (value * max.inMilliseconds).round();
                          await _player.seek(Duration(milliseconds: targetMs));
                        },
                ),
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, stateSnapshot) {
                    final playing = stateSnapshot.data?.playing ?? false;
                    return ElevatedButton.icon(
                      onPressed: () {
                        if (playing) {
                          _player.pause();
                        } else {
                          _player.play();
                        }
                        setState(() {});
                      },
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      label: Text(playing ? 'Pause' : 'Play'),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// Settings Screen with Profile Management and Relays
enum RelayStatus { loading, ok, warn }

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _appVersion = '0.0.3';
  static const MethodChannel _storageChannel = MethodChannel(
    'com.pushstr.storage',
  );
  static const List<String> _defaultRelays = [
    'wss://relay.damus.io',
    'wss://relay.primal.net',
    'wss://nos.lol',
    'wss://nostr.mom',
    'wss://relay.nostr.band',
    'wss://relay.snort.social',
    'wss://relay.nostr.bg',
    'wss://eden.nostr.land',
    'wss://relay.nostr.wine',
    'wss://relay.plebstr.com',
  ];
  List<Map<String, String>> profiles = [];
  List<String> profileNpubs = [];
  int selectedProfileIndex = 0;
  String profileNickname = '';
  List<String> relays = [];
  final Map<String, RelayStatus> relayStatuses = {};
  final Map<String, DateTime> relayStatusCheckedAt = {};
  final TextEditingController relayInputCtrl = TextEditingController();
  String relayError = '';
  String currentNpub = '';
  final TextEditingController nicknameCtrl = TextEditingController();
  bool _isSaving = false;
  bool _hasPendingChanges = false;
  bool _relayInputValid = false;
  bool _nsecCopied = false;
  bool _npubCopied = false;
  Timer? _copyResetTimer;
  Timer? _autoSaveTimer;
  final Map<String, Timer> _holdTimers = {};
  final Map<String, double> _holdProgress = {};
  final Map<String, bool> _holdActive = {};
  final Map<String, int> _holdLastSecond = {};
  static const int _holdMillis = 5000;
  bool _startingForeground = false;
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;
  bool _foregroundEnabled = false;

  @override
  void initState() {
    super.initState();
    relayInputCtrl.addListener(_updateRelayValidity);
    _loadSettings();
  }

  @override
  void dispose() {
    relayInputCtrl.dispose();
    nicknameCtrl.dispose();
    _copyResetTimer?.cancel();
    _autoSaveTimer?.cancel();
    for (final t in _holdTimers.values) {
      t.cancel();
    }
    _toastTimer?.cancel();
    _toastEntry?.remove();
    super.dispose();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'pushstr_fg',
        channelName: 'Pushstr background',
        channelDescription: 'Keeps Pushstr connected for catch-up sync',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 60 * 1000,
        isOnceEvent: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<bool> _startForegroundService() async {
    if (!Platform.isAndroid) return false;
    if (_startingForeground) return true;
    _startingForeground = true;
    final notifStatus = await Permission.notification.request();
    if (!notifStatus.isGranted) {
      _startingForeground = false;
      return false;
    }
    _initForegroundTask();
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      _startingForeground = false;
      return true;
    }
    try {
      final started = await FlutterForegroundTask.startService(
        notificationTitle: 'Pushstr running',
        notificationText: 'Staying connected for incoming messages',
        callback: foregroundStartCallback,
      ).timeout(const Duration(seconds: 5), onTimeout: () => false);
      return started;
    } catch (_) {
      return false;
    } finally {
      _startingForeground = false;
    }
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      return;
    }
    await FlutterForegroundTask.stopService();
  }

  Future<void> _loadSettings() async {
    if (mounted) {
      setState(() {
        _isSaving = true;
      });
    }
    final prefs = await SharedPreferences.getInstance();

    // Load profiles
    final profilesList = prefs.getStringList('profiles') ?? [];
    final loadedProfiles = profilesList.map((p) {
      final parts = p.split('|');
      return {'nsec': parts[0], 'nickname': parts.length > 1 ? parts[1] : ''};
    }).toList();

    // If no profiles, add current key
    if (loadedProfiles.isEmpty) {
      final currentNsec = prefs.getString('nostr_nsec') ?? '';
      if (currentNsec.isNotEmpty) {
        loadedProfiles.add({'nsec': currentNsec, 'nickname': ''});
      }
    }

    final selectedIndex = prefs.getInt('selected_profile_index') ?? 0;
    final currentNickname =
        loadedProfiles.isNotEmpty && selectedIndex < loadedProfiles.length
        ? loadedProfiles[selectedIndex]['nickname'] ?? ''
        : '';

    // Load relays
    final storedRelays = prefs.getStringList('relays');
    final loadedRelays = _mergeDefaultRelays(storedRelays);
    if (storedRelays == null || storedRelays.length < _defaultRelays.length) {
      await prefs.setStringList('relays', loadedRelays);
    }

    var npub = '';
    try {
      npub = api.getNpub();
    } catch (_) {
      npub = '';
    }
    _foregroundEnabled = prefs.getBool('foreground_service_enabled') ?? false;

    // Load cached npubs to avoid recomputing on every load
    final cachedNpubs = prefs.getStringList('profile_npubs_cache') ?? [];

    setState(() {
      profiles = loadedProfiles;
      selectedProfileIndex = selectedIndex;
      profileNickname = currentNickname;
      relays = loadedRelays;
      nicknameCtrl.text = currentNickname;
      currentNpub = npub;
      profileNpubs = cachedNpubs.length == loadedProfiles.length
          ? cachedNpubs
          : [];
      _foregroundEnabled = prefs.getBool('foreground_service_enabled') ?? false;
    });

    // Only refresh npubs if cache is missing or invalid
    if (profileNpubs.isEmpty && profiles.isNotEmpty) {
      await _refreshProfileNpubs();
    }

    if (mounted) {
      setState(() {
        _hasPendingChanges = false;
        _isSaving = false;
        _relayInputValid = _isRelayInputValid(relayInputCtrl.text);
      });
    }
    _probeAllRelays(loadedRelays);
  }

  List<String> _mergeDefaultRelays(List<String>? existing) {
    if (existing == null || existing.isEmpty) {
      return List<String>.from(_defaultRelays);
    }
    if (existing.length >= _defaultRelays.length) {
      return List<String>.from(existing);
    }
    final merged = List<String>.from(existing);
    for (final relay in _defaultRelays) {
      if (!merged.contains(relay)) {
        merged.add(relay);
        if (merged.length >= _defaultRelays.length) break;
      }
    }
    return merged;
  }

  void _markDirty({bool schedule = true}) {
    if (!mounted) return;
    setState(() {
      _hasPendingChanges = true;
    });
    if (schedule) {
      _scheduleAutoSave();
    }
  }

  bool _isRelayInputValid(String relay) {
    final trimmed = relay.trim();
    return trimmed.isNotEmpty &&
        (trimmed.startsWith('ws://') || trimmed.startsWith('wss://'));
  }

  void _updateRelayValidity() {
    final valid = _isRelayInputValid(relayInputCtrl.text);
    if (_relayInputValid != valid && mounted) {
      setState(() {
        _relayInputValid = valid;
      });
    }
  }

  Future<void> _saveSettings() async {
    if (!mounted) return;
    setState(() {
      _isSaving = true;
    });
    _showThemedToast('Saving...', preferTop: true);
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setStringList(
        'profiles',
        profiles.map((p) => '${p['nsec']}|${p['nickname'] ?? ''}').toList(),
      );
      await prefs.setInt('selected_profile_index', selectedProfileIndex);

      if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) {
        final selectedNsec = profiles[selectedProfileIndex]['nsec']!;
        await prefs.setString('nostr_nsec', selectedNsec);
        profiles[selectedProfileIndex]['nickname'] = nicknameCtrl.text.trim();

        if (selectedProfileIndex < profileNpubs.length) {
          setState(() => currentNpub = profileNpubs[selectedProfileIndex]);
        }
      }

      await prefs.setStringList('relays', relays);
      await prefs.setBool('foreground_service_enabled', _foregroundEnabled);

      // No need to refresh npubs on every save - they're cached
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _hasPendingChanges = false;
        profileNickname = nicknameCtrl.text.trim();
      });
      _showThemedToast(
        'Saved',
        preferTop: true,
        duration: const Duration(milliseconds: 500),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });
      _showThemedToast('Save failed: $e', preferTop: true);
    }
  }

  Future<void> _addProfile() async {
    final ctrl = TextEditingController();
    final nicknameDialogCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'nsec',
                hintText: 'nsec1...',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nicknameDialogCtrl,
              decoration: const InputDecoration(
                labelText: 'Nickname (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final nsec = ctrl.text.trim();
              final nickname = nicknameDialogCtrl.text.trim();
              if (nsec.isNotEmpty) {
                setState(() {
                  profiles.add({'nsec': nsec, 'nickname': nickname});
                  selectedProfileIndex = profiles.length - 1;
                  profileNickname = nickname;
                  nicknameCtrl.text = nickname;
                });
                _markDirty();
                await _saveSettings();
                await _refreshProfileNpubs();
                unawaited(_primeProfileData(nsec));
              }
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _generateProfile() async {
    final nicknameDialogCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generate New Profile'),
        content: TextField(
          controller: nicknameDialogCtrl,
          decoration: const InputDecoration(labelText: 'Nickname (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final nsec = api.generateNewKey();
              final nickname = nicknameDialogCtrl.text.trim();
              setState(() {
                profiles.add({'nsec': nsec, 'nickname': nickname});
                selectedProfileIndex = profiles.length - 1;
                profileNickname = nickname;
                nicknameCtrl.text = nickname;
              });
              _markDirty();
              await _saveSettings();
              await _refreshProfileNpubs();
              unawaited(_primeProfileData(nsec));
              Navigator.pop(ctx);
            },
            child: const Text('Generate'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCurrentKey() async {
    if (profiles.isEmpty || selectedProfileIndex >= profiles.length) return;

    final nsec = profiles[selectedProfileIndex]['nsec']!;
    await Clipboard.setData(ClipboardData(text: nsec));
    if (mounted) {
      _showThemedToast('Copied profile secret (nSec)', preferTop: true);
    }
  }

  Future<File> _writeTempBackupFile(Uint8List bytes, String filename) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _backupCurrentProfile() async {
    if (profiles.isEmpty || selectedProfileIndex >= profiles.length) {
      _showThemedToast('No profile selected', preferTop: true);
      return;
    }
    final nsec = profiles[selectedProfileIndex]['nsec'] ?? '';
    if (nsec.isEmpty) {
      _showThemedToast('Missing profile secret', preferTop: true);
      return;
    }
    final nickname = profiles[selectedProfileIndex]['nickname'] ?? '';
    final npub = (selectedProfileIndex < profileNpubs.length)
        ? profileNpubs[selectedProfileIndex]
        : currentNpub;
    final prefs = await SharedPreferences.getInstance();
    final contactsKey = nsec.isNotEmpty ? _contactsKeyFor(nsec) : 'contacts';
    final savedContacts = prefs.getStringList(contactsKey) ?? [];
    final contacts = savedContacts
        .map((entry) {
          final parts = entry.split('|');
          return {
            'nickname': parts.isNotEmpty ? parts[0] : '',
            'pubkey': parts.length > 1 ? parts[1] : '',
          };
        })
        .where((c) => (c['pubkey'] ?? '').toString().isNotEmpty)
        .toList();
    final payload = {
      'type': 'pushstr_profile_backup',
      'version': 1,
      'created_at': DateTime.now().toIso8601String(),
      'profile': {'nsec': nsec, 'npub': npub, 'nickname': nickname},
      'contacts': contacts,
    };
    final json = jsonEncode(payload);
    final bytes = Uint8List.fromList(utf8.encode(json));
    final filename =
        'pushstr_profile_backup_${DateTime.now().millisecondsSinceEpoch}.json';

    if (Platform.isAndroid) {
      final uri = await _storageChannel.invokeMethod<String>(
        'saveToDownloads',
        {'bytes': bytes, 'mime': 'application/json', 'filename': filename},
      );
      if (!mounted) return;
      if (uri == null) {
        _showThemedToast('Backup failed', preferTop: true);
      } else {
        _showThemedToast('Backup saved to Downloads', preferTop: true);
      }
      return;
    }

    if (Platform.isIOS) {
      final file = await _writeTempBackupFile(bytes, filename);
      final ok = await _storageChannel.invokeMethod<bool>('shareFile', {
        'path': file.path,
        'mime': 'application/json',
        'filename': filename,
      });
      if (!mounted) return;
      if (ok != true) {
        _showThemedToast('Backup failed', preferTop: true);
      }
      return;
    }

    final selectedDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where to save backup',
    );
    if (selectedDir == null) {
      if (mounted) {
        _showThemedToast('Backup cancelled', preferTop: true);
      }
      return;
    }
    final file = File('$selectedDir/$filename');
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    _showThemedToast('Backup saved to $selectedDir', preferTop: true);
  }

  Future<void> _copyNpub() async {
    // Use cached currentNpub which reflects the selected profile
    final npubToCopy = currentNpub.isNotEmpty
        ? currentNpub
        : (selectedProfileIndex < profileNpubs.length
              ? profileNpubs[selectedProfileIndex]
              : '');

    if (npubToCopy.isEmpty) {
      if (mounted) {
        _showThemedToast('No npub available', preferTop: true);
      }
      return;
    }

    await Clipboard.setData(ClipboardData(text: npubToCopy));
    _setCopyState(npub: true);
  }

  void _setCopyState({bool npub = false, bool nsec = false}) {
    _copyResetTimer?.cancel();
    setState(() {
      if (npub) _npubCopied = true;
      if (nsec) _nsecCopied = true;
    });
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _npubCopied = false;
        _nsecCopied = false;
      });
    });
  }

  void _showThemedToast(
    String message, {
    bool preferTop = false,
    Duration? duration,
  }) {
    _toastEntry?.remove();
    _toastTimer?.cancel();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final theme = Theme.of(context);
    final padding = MediaQuery.of(context).viewPadding;

    _toastEntry = OverlayEntry(
      builder: (_) => Positioned(
        top: preferTop ? padding.top + 16 : null,
        bottom: preferTop ? null : padding.bottom + 16,
        left: 0,
        right: 0,
        child: Align(
          alignment: preferTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              child: IntrinsicWidth(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.8),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.45),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_toastEntry!);
    _toastTimer = Timer(duration ?? const Duration(milliseconds: 1600), () {
      _toastEntry?.remove();
      _toastEntry = null;
    });
  }

  void _startHoldAction(
    String key,
    VoidCallback onComplete, {
    String? countdownLabel,
  }) {
    _holdTimers[key]?.cancel();
    final start = DateTime.now();
    final totalSeconds = (_holdMillis / 1000).ceil();
    _holdLastSecond[key] = totalSeconds;
    setState(() {
      _holdActive[key] = true;
      _holdProgress[key] = 0;
    });
    if (countdownLabel != null) {
      _showHoldWarning('Hold ${totalSeconds}s to $countdownLabel');
    }
    _holdTimers[key] = Timer.periodic(const Duration(milliseconds: 120), (t) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final progress = (elapsed / _holdMillis).clamp(0.0, 1.0);
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _holdProgress[key] = progress;
      });
      final remainingSeconds =
          ((_holdMillis - elapsed).clamp(0, _holdMillis) / 1000).ceil();
      if (countdownLabel != null && remainingSeconds != _holdLastSecond[key]) {
        _holdLastSecond[key] = remainingSeconds;
        _showHoldWarning('Hold ${remainingSeconds}s to $countdownLabel');
      }
      if (progress >= 1) {
        t.cancel();
        _holdTimers.remove(key);
        _holdLastSecond.remove(key);
        setState(() {
          _holdActive[key] = false;
        });
        onComplete();
      }
    });
  }

  void _cancelHoldAction(String key) {
    _holdTimers[key]?.cancel();
    _holdTimers.remove(key);
    _holdLastSecond.remove(key);
    if (!mounted) return;
    setState(() {
      _holdActive[key] = false;
      _holdProgress[key] = 0;
    });
  }

  double _holdProgressFor(String key) => _holdProgress[key] ?? 0;

  void _showHoldWarning(String message) {
    if (!mounted) return;
    _showThemedToast(message, preferTop: true);
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 900), () {
      if (_hasPendingChanges && !_isSaving) {
        _saveSettings();
      }
    });
  }

  Future<void> _showNpubQr() async {
    // Use cached currentNpub which reflects the selected profile
    final npubToShow = currentNpub.isNotEmpty
        ? currentNpub
        : (selectedProfileIndex < profileNpubs.length
              ? profileNpubs[selectedProfileIndex]
              : '');

    if (npubToShow.isEmpty) {
      if (mounted) {
        _showThemedToast('No npub available', preferTop: true);
      }
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'My npub',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrImageView(
                    data: npubToShow,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  npubToShow,
                  style: const TextStyle(fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshProfileNpubs() async {
    if (profiles.isEmpty) return;
    final nsecs = profiles
        .map((profile) => profile['nsec'] ?? '')
        .toList(growable: false);
    List<String> npubs = [];
    try {
      npubs = api.deriveNpubs(nsecs: nsecs);
    } catch (e) {
      print('Failed to derive npubs: $e');
      npubs = List.filled(nsecs.length, '');
    }

    // Cache the computed npubs
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('profile_npubs_cache', npubs);
    } catch (e) {
      print('Failed to cache npubs: $e');
    }

    if (mounted) {
      setState(() {
        profileNpubs = npubs;
        if (selectedProfileIndex < profileNpubs.length) {
          currentNpub = profileNpubs[selectedProfileIndex];
        }
      });
    }
  }

  String _shortNpub(String value) {
    final text = value.trim();
    if (text.length <= 12) return text;
    return '${text.substring(0, 8)}...${text.substring(text.length - 4)}';
  }

  String _contactsKeyFor(String profileNsec) => 'contacts_$profileNsec';
  String _messagesKeyFor(String profileNsec) => 'messages_$profileNsec';
  String _lastSeenKeyFor(String profileNsec) => 'last_seen_ts_$profileNsec';

  String _normalizeBackupPubkey(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('npub') || trimmed.startsWith('nprofile')) {
      try {
        return api.npubToHex(npub: trimmed);
      } catch (_) {
        return trimmed;
      }
    }
    return trimmed;
  }

  Future<void> _importProfileBackup() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    try {
      final file = result.files.first;
      final bytes =
          file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        _showThemedToast('Import failed: file unreadable', preferTop: true);
        return;
      }
      final jsonText = utf8.decode(bytes);
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) {
        _showThemedToast('Import failed: invalid JSON', preferTop: true);
        return;
      }
      final profile = decoded['profile'];
      if (profile is! Map || profile['nsec'] is! String) {
        _showThemedToast('Import failed: missing nsec', preferTop: true);
        return;
      }
      final nsec = (profile['nsec'] as String).trim();
      if (nsec.isEmpty) {
        _showThemedToast('Import failed: empty nsec', preferTop: true);
        return;
      }
      final nickname = (profile['nickname'] ?? '').toString().trim();

      final prefs = await SharedPreferences.getInstance();
      final contactsKey = _contactsKeyFor(nsec);
      final contactsJson = decoded['contacts'];
      if (contactsJson is List) {
        final entries = <String>[];
        final seen = <String>{};
        for (final entry in contactsJson) {
          if (entry is! Map) continue;
          final rawPubkey = entry['pubkey']?.toString() ?? '';
          final pubkey = _normalizeBackupPubkey(rawPubkey);
          if (pubkey.isEmpty || seen.contains(pubkey)) continue;
          seen.add(pubkey);
          final nick = entry['nickname']?.toString() ?? '';
          entries.add('$nick|$pubkey');
        }
        if (entries.isNotEmpty) {
          await prefs.setStringList(contactsKey, entries);
        }
      }

      setState(() {
        profiles.add({'nsec': nsec, 'nickname': nickname});
        selectedProfileIndex = profiles.length - 1;
        profileNickname = nickname;
        nicknameCtrl.text = nickname;
      });
      _markDirty();
      await _saveSettings();
      await _refreshProfileNpubs();
      _showThemedToast('Profile imported', preferTop: true);
    } catch (e) {
      _showThemedToast('Import failed: $e', preferTop: true);
    }
  }

  Future<void> _primeProfileData(String nsec) async {
    if (nsec.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final dmsJson = await RustSyncWorker.fetchRecentDms(
        nsec: nsec,
        limit: 100,
        sinceTimestamp: 0,
      );
      if (dmsJson == null || dmsJson.isEmpty) return;
      await prefs.setString(_messagesKeyFor(nsec), dmsJson);
      final List<dynamic> dmsList = jsonDecode(dmsJson);
      final messages = dmsList.cast<Map<String, dynamic>>();
      final maxSeen = messages.fold<int>(0, (acc, m) {
        final raw = m['created_at'];
        if (raw is int && raw > acc) return raw;
        if (raw is double && raw > acc) return raw.round();
        if (raw is String) {
          final parsed = int.tryParse(raw);
          if (parsed != null && parsed > acc) return parsed;
        }
        return acc;
      });
      if (maxSeen > 0) {
        await prefs.setInt(_lastSeenKeyFor(nsec), maxSeen);
      }
      final contactSet = <String>{};
      final contactsList = <String>[];
      for (final message in messages) {
        final direction = message['direction']?.toString();
        final pubkey =
            (direction == 'out')
            ? message['to']?.toString()
            : message['from']?.toString();
        if (pubkey == null || pubkey.isEmpty) continue;
        if (contactSet.add(pubkey)) {
          contactsList.add('|$pubkey');
        }
      }
      if (contactsList.isNotEmpty) {
        await prefs.setStringList(_contactsKeyFor(nsec), contactsList);
      }
    } catch (e) {
      print('Failed to prime profile data: $e');
    }
  }

  Future<void> _addRelay() async {
    final relay = relayInputCtrl.text.trim();
    setState(() => relayError = '');
    if (relay.isEmpty ||
        !(relay.startsWith('ws://') || relay.startsWith('wss://'))) {
      setState(() => relayError = 'Enter a valid ws:// or wss:// URL');
      return;
    }
    if (relays.contains(relay)) {
      setState(() => relayError = 'Relay already added');
      return;
    }
    setState(() {
      relays.add(relay);
      relayInputCtrl.clear();
    });
    _markDirty();
    await _saveSettings();
    _probeRelay(relay);
  }

  void _probeAllRelays(List<String> list) {
    for (final relay in list) {
      _probeRelay(relay);
    }
  }

  void _probeRelay(String relay) {
    final now = DateTime.now();
    final last = relayStatusCheckedAt[relay];
    if (last != null && now.difference(last).inSeconds < 10) return;
    relayStatusCheckedAt[relay] = now;
    setState(() {
      relayStatuses[relay] = RelayStatus.loading;
    });
    WebSocket.connect(relay)
        .timeout(const Duration(seconds: 4))
        .then((ws) {
          relayStatuses[relay] = RelayStatus.ok;
          relayStatusCheckedAt[relay] = DateTime.now();
          ws.close();
          if (mounted) setState(() {});
        })
        .catchError((_) {
          relayStatuses[relay] = RelayStatus.warn;
          relayStatusCheckedAt[relay] = DateTime.now();
          if (mounted) setState(() {});
        });
  }

  @override
  Widget build(BuildContext context) {
    final sectionDecoration = BoxDecoration(
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.greenAccent.withOpacity(0.2)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.25),
          blurRadius: 8,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: Colors.greenAccent.withOpacity(0.04),
          blurRadius: 8,
          spreadRadius: 0.5,
        ),
      ],
    );

    final textButtonStyle = ElevatedButton.styleFrom(
      minimumSize: const Size(150, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );

    Widget actionGroup(String label, List<Widget> buttons) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 13,
              letterSpacing: 0.4,
              color: Colors.white70,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
        ],
      );
    }

    Color _relayColor(String relay) {
      final status = relayStatuses[relay];
      switch (status) {
        case RelayStatus.ok:
          return Colors.greenAccent;
        case RelayStatus.warn:
          return Colors.orangeAccent;
        case RelayStatus.loading:
        default:
          return Colors.grey.shade500;
      }
    }

    Color _relayShadow(String relay) {
      final status = relayStatuses[relay];
      switch (status) {
        case RelayStatus.ok:
          return Colors.greenAccent.withOpacity(0.18);
        case RelayStatus.warn:
          return Colors.orangeAccent.withOpacity(0.18);
        default:
          return Colors.transparent;
      }
    }

    String _relayStatusLabel(String relay) {
      final status = relayStatuses[relay];
      switch (status) {
        case RelayStatus.ok:
          return 'Good';
        case RelayStatus.warn:
          return 'Offline';
        case RelayStatus.loading:
        default:
          return 'Checking';
      }
    }

    Widget relayRow(String relay) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.greenAccent.withOpacity(0.22)),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _relayColor(relay),
                boxShadow: [
                  BoxShadow(
                    color: _relayShadow(relay),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _relayStatusLabel(relay),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                relay,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _HoldDeleteIcon(
              active: _holdActive['relay_$relay'] ?? false,
              progress: _holdProgressFor('relay_$relay'),
              onTap: () => _showHoldWarning('Hold 5s to remove relay'),
              onHoldStart: () {
                _startHoldAction('relay_$relay', () async {
                  setState(() {
                    relays.remove(relay);
                    relayStatuses.remove(relay);
                    relayStatusCheckedAt.remove(relay);
                  });
                  _markDirty();
                  await _saveSettings();
                  _cancelHoldAction('relay_$relay');
                }, countdownLabel: 'remove relay');
              },
              onHoldEnd: () => _cancelHoldAction('relay_$relay'),
            ),
          ],
        ),
      );
    }

    final nicknameDirty = nicknameCtrl.text.trim() != profileNickname;
    final showProfileSave = !_isSaving && (_hasPendingChanges || nicknameDirty);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: const []),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: sectionDecoration,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Profile',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (profiles.isNotEmpty &&
                    selectedProfileIndex < profiles.length) ...[
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Active profile',
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 3,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.greenAccent.shade200,
                        ),
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: selectedProfileIndex,
                        isExpanded: true,
                        items: profiles.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final profile = entry.value;
                          final fullNpub =
                              (idx < profileNpubs.length &&
                                  profileNpubs[idx].isNotEmpty)
                              ? profileNpubs[idx]
                              : '';
                          final shortNpub = fullNpub.isNotEmpty
                              ? _shortNpub(fullNpub)
                              : 'Profile ${idx + 1}';
                          final nickname = (profile['nickname'] ?? '').trim();
                          final label = nickname.isNotEmpty
                              ? '$shortNpub - $nickname'
                              : shortNpub;

                          return DropdownMenuItem(
                            value: idx,
                            child: Text(label),
                          );
                        }).toList(),
                        selectedItemBuilder: (ctx) {
                          return profiles.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final fullNpub =
                                (idx < profileNpubs.length &&
                                    profileNpubs[idx].isNotEmpty)
                                ? profileNpubs[idx]
                                : '';
                            final shortNpub = fullNpub.isNotEmpty
                                ? _shortNpub(fullNpub)
                                : 'Profile ${idx + 1}';
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Text(shortNpub),
                            );
                          }).toList();
                        },
                        onChanged: (idx) async {
                          if (idx != null &&
                              idx < profiles.length &&
                              idx != selectedProfileIndex) {
                            setState(() {
                              selectedProfileIndex = idx;
                              profileNickname = profiles[idx]['nickname'] ?? '';
                              nicknameCtrl.text = profileNickname;
                              if (idx < profileNpubs.length) {
                                currentNpub = profileNpubs[idx];
                              }
                            });
                            _markDirty();
                            await _saveSettings();
                            final nsec = profiles[idx]['nsec'] ?? '';
                            unawaited(_primeProfileData(nsec));
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nicknameCtrl,
                          decoration: InputDecoration(
                            labelText: 'Profile nickname (optional)',
                            filled: true,
                            fillColor: Colors.black.withOpacity(0.35),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: Colors.greenAccent.shade200,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          onChanged: (value) {
                            if (profiles.isNotEmpty &&
                                selectedProfileIndex < profiles.length) {
                              profiles[selectedProfileIndex]['nickname'] =
                                  value;
                              _markDirty(schedule: false);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: showProfileSave
                            ? IconButton.filled(
                                key: const ValueKey('save_profile'),
                                onPressed: _saveSettings,
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.greenAccent.shade400,
                                  foregroundColor: Colors.black,
                                  shape: const CircleBorder(),
                                  padding: const EdgeInsets.all(10),
                                ),
                                icon: const Icon(Icons.check, size: 22),
                                tooltip: 'Save profile',
                              )
                            : _HoldDeleteIcon(
                                active: _holdActive['delete_profile'] ?? false,
                                progress: _holdProgressFor('delete_profile'),
                                onTap: () => _showHoldWarning(
                                  'Hold 5s to delete profile',
                                ),
                                onHoldStart: () {
                                  if (_isSaving || profiles.length <= 1) return;
                                  _startHoldAction(
                                    'delete_profile',
                                    () async {
                                      final removing = selectedProfileIndex;
                                      setState(() {
                                        profiles.removeAt(removing);
                                        if (removing < profileNpubs.length) {
                                          profileNpubs.removeAt(removing);
                                        }
                                        if (selectedProfileIndex >=
                                            profiles.length) {
                                          selectedProfileIndex =
                                              profiles.isEmpty
                                              ? 0
                                              : profiles.length - 1;
                                        }
                                        profileNickname = profiles.isNotEmpty
                                            ? (profiles[selectedProfileIndex]['nickname'] ??
                                                  '')
                                            : '';
                                        nicknameCtrl.text = profileNickname;
                                      });
                                      _hasPendingChanges = false;
                                      await _saveSettings();
                                      await _refreshProfileNpubs();
                                      _cancelHoldAction('delete_profile');
                                    },
                                    countdownLabel: 'delete profile',
                                  );
                                },
                                onHoldEnd: () =>
                                    _cancelHoldAction('delete_profile'),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                actionGroup('Management', [
                  ElevatedButton.icon(
                    style: textButtonStyle,
                    onPressed: _generateProfile,
                    icon: const Icon(Icons.add, size: 22),
                    label: const Text('New Profile'),
                  ),
                  ElevatedButton.icon(
                    style: textButtonStyle,
                    onPressed: _addProfile,
                    icon: const Icon(Icons.input_outlined, size: 20),
                    label: const Text('Import Profile (nSec)'),
                  ),
                ]),
                const SizedBox(height: 8),
                actionGroup('Utilities', [
                  Builder(
                    builder: (context) {
                      final holdActive = _holdActive['copy_nsec'] ?? false;
                      final progress = _holdProgress['copy_nsec'] ?? 0.0;
                      final remainingMs = (_holdMillis * (1 - progress)).clamp(
                        0.0,
                        _holdMillis.toDouble(),
                      );
                      final remainingSeconds = (remainingMs / 1000).ceil();
                      final label = _nsecCopied
                          ? 'Copied'
                          : holdActive
                          ? 'Hold ${remainingSeconds}s to copy profile secret (nSec)'
                          : 'Hold 5s to copy profile secret (nSec)';
                      return GestureDetector(
                        onLongPressStart: (_) => _startHoldAction(
                          'copy_nsec',
                          () async {
                            await _exportCurrentKey();
                            _setCopyState(nsec: true);
                            _cancelHoldAction('copy_nsec');
                          },
                          countdownLabel: 'copy profile secret (nSec)',
                        ),
                        onLongPressEnd: (_) => _cancelHoldAction('copy_nsec'),
                        onTap: () {},
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          opacity: 1.0,
                          child: ElevatedButton.icon(
                            style: textButtonStyle,
                            onPressed: null,
                            icon: const Icon(Icons.vpn_key_outlined, size: 20),
                            label: Text(label),
                          ),
                        ),
                      );
                    },
                  ),
                  ElevatedButton.icon(
                    style: textButtonStyle,
                    onPressed: () async {
                      await _copyNpub();
                      _setCopyState(npub: true);
                    },
                    icon: const Icon(Icons.mail_outline, size: 22),
                    label: Text(_npubCopied ? 'Copied' : 'Copy nPub'),
                  ),
                  ElevatedButton.icon(
                    style: textButtonStyle,
                    onPressed: _showNpubQr,
                    icon: const Icon(Icons.qr_code_2, size: 20),
                    label: const Text('Show QR'),
                  ),
                  ElevatedButton.icon(
                    style: textButtonStyle,
                    onPressed: _backupCurrentProfile,
                    icon: const Icon(Icons.save_alt, size: 20),
                    label: const Text('Backup Profile (JSON)'),
                  ),
                  ElevatedButton.icon(
                    style: textButtonStyle,
                    onPressed: _importProfileBackup,
                    icon: const Icon(Icons.upload_file, size: 20),
                    label: const Text('Import Profile (JSON)'),
                  ),
                ]),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Stay connected (foreground)'),
                  subtitle: const Text(
                    'Runs an opt-in foreground service for quicker catch-up',
                  ),
                  value: _foregroundEnabled,
                  onChanged: (val) async {
                    setState(() => _foregroundEnabled = val);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('foreground_service_enabled', val);
                    if (val) {
                      _showThemedToast(
                        'Enabling background connection...',
                        preferTop: true,
                      );
                      final ok = await _startForegroundService();
                      if (!ok) {
                        setState(() => _foregroundEnabled = false);
                        await prefs.setBool(
                          'foreground_service_enabled',
                          false,
                        );
                        _showThemedToast(
                          'Foreground service blocked (notification permission?)',
                          preferTop: true,
                        );
                        return;
                      }
                      unawaited(
                        SyncController.performSyncTick(
                          trigger: SyncTrigger.foregroundService,
                          budget: const Duration(seconds: 10),
                        ),
                      );
                      _showThemedToast(
                        'Foreground service running',
                        preferTop: true,
                      );
                    } else {
                      await _stopForegroundService();
                      _showThemedToast(
                        'Foreground service stopped',
                        preferTop: true,
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Container(
            decoration: sectionDecoration,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Relays',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: relayInputCtrl,
                        decoration: InputDecoration(
                          labelText: 'Relay URL',
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.35),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.greenAccent.shade200,
                            ),
                          ),
                          errorText: relayError.isEmpty ? null : relayError,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (_) {
                          if (relayError.isNotEmpty) {
                            setState(() => relayError = '');
                          }
                          _updateRelayValidity();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _relayInputValid ? _addRelay : null,
                      icon: const Icon(Icons.add_rounded, size: 22),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.greenAccent.shade400,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: Colors.greenAccent.shade200
                            .withOpacity(0.4),
                        disabledForegroundColor: Colors.black.withOpacity(0.4),
                        padding: const EdgeInsets.all(12),
                        shape: const CircleBorder(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...relays.map(relayRow),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Version $_appVersion',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}
