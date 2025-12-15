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
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:background_fetch/background_fetch.dart' as bg;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/widgets.dart';

import 'bridge_generated.dart/api.dart' as api;
import 'bridge_generated.dart/frb_generated.dart';
import 'notifications.dart';
import 'permissions_gate.dart';
import 'sync/rust_sync_worker.dart';
import 'sync/sync_controller.dart';

bool _rustInitialized = false;
Completer<void>? _rustInitCompleter;
bool _foregroundServiceEnabled = false;
bool _foregroundServiceRunning = false;

Future<void> _ensureRustInit() async {
  if (_rustInitialized) return;
  if (_rustInitCompleter != null) {
    return _rustInitCompleter!.future;
  }
  final completer = Completer<void>();
  _rustInitCompleter = completer;
  try {
    ExternalLibrary? externalLibrary;
    if (Platform.isIOS) {
      externalLibrary = ExternalLibrary.open(
        'Frameworks/pushstr_rust.framework/pushstr_rust',
      );
    }
    await RustLib.init(externalLibrary: externalLibrary);
    _rustInitialized = true;
    completer.complete();
  } catch (e, st) {
    completer.completeError(e, st);
    _rustInitCompleter = null;
    rethrow;
  }
}

@pragma('vm:entry-point')
void backgroundFetchHeadless(bg.HeadlessTask task) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (task.timeout) return;
    await _ensureRustInit();
    await SyncController.performSyncTick(
      trigger: SyncTrigger.backgroundFetch,
      budget: const Duration(seconds: 6),
    );
  } catch (e, st) {
    debugPrint('Headless fetch error: $e\n$st');
  } finally {
    bg.BackgroundFetch.finish(task.taskId);
  }
}

@pragma('vm:entry-point')
void foregroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_PushstrTaskHandler());
}

/// Reset the adaptive interval timer to provide responsive checking
/// Call this when user sends or receives messages
Future<void> _resetAdaptiveInterval() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('fg_service_start_time', DateTime.now().millisecondsSinceEpoch);
  } catch (_) {
    // Ignore if prefs unavailable
  }
}

/// Calculate adaptive sync interval based on elapsed time since service started
/// Starts at 5 seconds, gradually increases to 15 minutes over 3 hours
int _calculateAdaptiveInterval(DateTime serviceStartTime) {
  final elapsed = DateTime.now().difference(serviceStartTime);
  final elapsedSeconds = elapsed.inSeconds;

  // Define the curve: 5s -> 15min over 3 hours (10800 seconds)
  const minInterval = 5;           // 5 seconds
  const maxInterval = 15 * 60;     // 15 minutes
  const rampUpDuration = 3 * 60 * 60; // 3 hours

  if (elapsedSeconds <= 0) return minInterval;
  if (elapsedSeconds >= rampUpDuration) return maxInterval;

  // Use exponential curve for gradual increase
  // Formula: min + (max - min) * (elapsed / duration)^2
  final progress = elapsedSeconds / rampUpDuration;
  final exponentialProgress = progress * progress; // Square for smoother curve
  final interval = minInterval + ((maxInterval - minInterval) * exponentialProgress);

  return interval.round();
}

class _PushstrTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    DartPluginRegistrant.ensureInitialized();
    // Record when the service started
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('fg_service_start_time', timestamp.millisecondsSinceEpoch);
    await prefs.setInt('fg_last_sync_time', 0); // Reset last sync time
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    DartPluginRegistrant.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();

    // Get service start time
    final startTimeMs = prefs.getInt('fg_service_start_time') ?? timestamp.millisecondsSinceEpoch;
    final serviceStartTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);

    // Get last sync time
    final lastSyncMs = prefs.getInt('fg_last_sync_time') ?? 0;
    final lastSyncTime = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);

    // Calculate how much time should pass before next sync
    final desiredInterval = _calculateAdaptiveInterval(serviceStartTime);
    final timeSinceLastSync = timestamp.difference(lastSyncTime).inSeconds;

    // Only sync if enough time has passed
    if (timeSinceLastSync >= desiredInterval) {
      await SyncController.performSyncTick(
        trigger: SyncTrigger.foregroundService,
        budget: const Duration(seconds: 6),
      );
      await prefs.setInt('fg_last_sync_time', timestamp.millisecondsSinceEpoch);
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}

  @override
  void onReceiveData(Object? data) {}
}

Future<void> _setupBackgroundTasks() async {
  try {
    await bg.BackgroundFetch.configure(
      bg.BackgroundFetchConfig(
        minimumFetchInterval: 30,
        stopOnTerminate: false,
        startOnBoot: true,
        enableHeadless: true,
        requiredNetworkType: bg.NetworkType.ANY,
      ),
      (taskId) async {
        final sw = Stopwatch()..start();
        try {
          await SyncController.performSyncTick(
            trigger: SyncTrigger.backgroundFetch,
            budget: const Duration(seconds: 6),
          );
        } catch (e, st) {
          debugPrint('BackgroundFetch($taskId) error: $e\n$st');
        } finally {
          bg.BackgroundFetch.finish(taskId);
          debugPrint('BackgroundFetch($taskId) finished in ${sw.elapsedMilliseconds}ms');
        }
      },
      (taskId) async {
        // Timeout callback: keep it trivial.
        bg.BackgroundFetch.finish(taskId);
      },
    );

    bg.BackgroundFetch.registerHeadlessTask(backgroundFetchHeadless);
  } catch (e, st) {
    // log e/st; best-effort is OK, but keep a breadcrumb.
  }
}


Future<void> _initNotifications() async {
  await initLocalNotifications();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'pushstr_fg',
      channelName: 'Pushstr background service',
      channelDescription: 'Keeps Pushstr connected for notifications',
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
      interval: 15 * 1000, // Base tick; adaptive logic only skips work, never faster than this
      isOnceEvent: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> _startForegroundServiceAtLaunch() async {
  final notifStatus = await Permission.notification.status;
  if (!notifStatus.isGranted) return;
  final running = await FlutterForegroundTask.isRunningService;
  if (running) {
    _foregroundServiceRunning = true;
    return;
  }
  await FlutterForegroundTask.startService(
    notificationTitle: 'Pushstr running',
    notificationText: 'Staying connected for incoming messages',
    callback: foregroundStartCallback,
  );
  _foregroundServiceRunning = true;
}

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
    final color = Color.lerp(Colors.white, Colors.redAccent.shade200, intensity.clamp(0, 1))!;
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
          ),
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PushstrApp());
  // Defer heavy init so first frame is not blocked.
  unawaited(_prewarmApp());
}

Future<void> _prewarmApp() async {
  await _ensureRustInit();
  await _initNotifications();
  await _setupBackgroundTasks();
}

class PushstrApp extends StatelessWidget {
  const PushstrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pushstr Mobile',
      theme: ThemeData.dark(
        useMaterial3: true,
      ).copyWith(
        colorScheme: const ColorScheme.dark(primary: Color(0xFF22C55E)),
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
  bool isConnected = false;
  bool _listening = false;
  bool _didInitRust = false;
  final ImagePicker _imagePicker = ImagePicker();
  // StreamSubscription? _intentDataStreamSubscription;
  final Map<String, bool> _copiedMessages = {};
  final Map<String, Timer> _copiedMessageTimers = {};
  final Map<String, Timer> _holdTimersHome = {};
  final Map<String, double> _holdProgressHome = {};
  final Map<String, bool> _holdActiveHome = {};
  final Map<String, int> _holdLastSecondHome = {};
  static const int _holdMillis = 4000;
  Timer? _pendingPoller;
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;
  bool _sendCooldown = false;
  bool _appVisible = true;

  // Session-based decryption caching
  final Map<String, Uint8List> _decryptedMediaCache = {};
  final Set<String> _sessionMessages = {};

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    _messageFocus.addListener(() {
      if (_messageFocus.hasFocus) {
        _scrollToBottom();
      }
    });
    super.initState();
    // Allow first frame to paint before heavy init.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
      _pendingPoller = Timer.periodic(const Duration(seconds: 5), (_) {
        _loadPendingMessagesIntoUi();
      });
    });
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
    _scrollController.dispose();
    _messageFocus.dispose();
    for (final t in _copiedMessageTimers.values) {
      t.cancel();
    }
    for (final t in _holdTimersHome.values) {
      t.cancel();
    }
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _pendingPoller?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // _intentDataStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Reset adaptive interval when app comes to foreground
    if (state == AppLifecycleState.resumed) {
      _appVisible = true;
      _persistVisibleState();
      _resetAdaptiveInterval();
      _loadPendingMessagesIntoUi();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _appVisible = false;
      _persistVisibleState();
    }
  }

  @override
  void didChangeMetrics() {
    final bottom = WidgetsBinding.instance.window.viewInsets.bottom;
    if (bottom != _lastViewInsets) {
      _lastViewInsets = bottom;
      if (bottom > 0) {
        _scrollToBottom();
      }
    }
    super.didChangeMetrics();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedNsec = prefs.getString('nostr_nsec') ?? '';
    final profileIndex = prefs.getInt('selected_profile_index') ?? 0;

    // Handle shared content from Android intents
    _initShareListener();

    // Run permission gate and restore background service if enabled
    await PermissionsGate.ensureAtLaunch(context, prefs: prefs);
    await _ensurePermissionsAndService();

    try {
      await _ensureRustInitialized();
      final initedNpub = api.initNostr(nsec: savedNsec);
      final savedContacts = prefs.getStringList('contacts') ?? [];
      nsec = savedNsec.isNotEmpty ? savedNsec : api.getNsec();

      // Load saved messages
      final savedMessages = prefs.getString('messages');
      List<Map<String, dynamic>> loadedMessages = [];
      if (savedMessages != null && savedMessages.isNotEmpty) {
        try {
          final List<dynamic> msgsList = jsonDecode(savedMessages);
          loadedMessages = msgsList.cast<Map<String, dynamic>>();
        } catch (e) {
          print('Failed to load saved messages: $e');
        }
      }

    setState(() {
      npub = initedNpub;
      isConnected = true;
      messages = loadedMessages;
      contacts = _dedupeContacts(savedContacts
          .map((c) {
            final parts = c.split('|');
            return <String, dynamic>{'nickname': parts[0], 'pubkey': parts.length > 1 ? parts[1] : ''};
          })
          .where((c) => c['pubkey']!.isNotEmpty)
          .toList());
      _sortContactsByActivity();
    });
      // Load profile-specific stored data if present (fallback to shared above)
      await _loadLocalProfileData(profileIndex: profileIndex, overrideLoaded: true);
      _ensureSelectedContact();

      // Save nsec if it was generated
      if (savedNsec.isEmpty) {
        await prefs.setString('nostr_nsec', nsec!);
      }

      // Fetch recent messages
      _fetchMessages();
      _startDmListener();
    } catch (e) {
      setState(() {
        lastError = 'Init failed: $e';
        isConnected = false;
      });
    }
  }

  /// Ensure all necessary permissions are granted and background service is enabled
  Future<void> _ensurePermissionsAndService() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var foregroundEnabled = prefs.getBool('foreground_service_enabled');
      if (foregroundEnabled == null && Platform.isAndroid) {
          final notifStatus = await Permission.notification.status;
          foregroundEnabled = notifStatus.isGranted;
          await prefs.setBool('foreground_service_enabled', foregroundEnabled);
      }
      if ((foregroundEnabled ?? false) && Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        if (!notifStatus.isGranted) {
          foregroundEnabled = false;
          await prefs.setBool('foreground_service_enabled', false);
        }
      }
      _foregroundServiceEnabled = foregroundEnabled ?? false;
      if (_foregroundServiceEnabled && Platform.isAndroid) {
        final running = await FlutterForegroundTask.isRunningService;
        if (!running) {
          await _startForegroundServiceAtLaunch();
        }
      }
    } catch (e) {
      // Best effort - don't block app startup
    }
  }

  String _contactsKeyFor(String profileNsec) => 'contacts_$profileNsec';
  String _messagesKeyFor(String profileNsec) => 'messages_$profileNsec';
  String _pendingDmsKeyFor(String profileNsec) => 'pending_dms_$profileNsec';

  Future<void> _saveMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null ? _messagesKeyFor(nsec!) : 'messages';
      await prefs.setString(key, jsonEncode(messages));
      if (nsec != null) {
        // Clear legacy shared storage to avoid cross-profile bleed
        await prefs.remove('messages');
      }
    } catch (e) {
      print('Failed to save messages: $e');
    }
  }

  Future<void> _saveContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = nsec != null ? _contactsKeyFor(nsec!) : 'contacts';
      await prefs.setStringList(
        key,
        contacts.map((c) => '${c['nickname'] ?? ''}|${c['pubkey'] ?? ''}').toList(),
      );
      if (nsec != null) {
        await prefs.remove('contacts');
      }
    } catch (e) {
      print('Failed to save contacts: $e');
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
      final existingIds = messages.map((m) => m['id'] as String?).whereType<String>().toSet();
      final dmsJson = api.fetchRecentDms(limit: BigInt.from(100));
      final List<dynamic> dmsList = jsonDecode(dmsJson);
      var fetchedMessages = dmsList.cast<Map<String, dynamic>>();
      fetchedMessages = await _decodeMessages(fetchedMessages);
      // Merge any pending background-cached messages
      try {
        final prefs = await SharedPreferences.getInstance();
        final pendingKey = nsec != null ? _pendingDmsKeyFor(nsec!) : 'pending_dms';
        final pendingJson = prefs.getString(pendingKey);
        if (pendingJson != null && pendingJson.isNotEmpty) {
          final pendingList = (jsonDecode(pendingJson) as List<dynamic>)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .map(_normalizeIncomingMessage)
              .toList();
          final decodedPending = await _decodeMessages(pendingList);
          fetchedMessages = _mergeMessages([...fetchedMessages, ...decodedPending]);
          await prefs.remove(pendingKey);
        }
      } catch (e) {
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
      final fetchedIds = fetchedMessages.map((m) => m['id'] as String?).where((id) => id != null).toSet();
      final localOnly = messages.where((m) {
        final id = m['id'] as String?;
        return id != null && id.startsWith('local_') && !fetchedIds.contains(id);
      }).toList();

      final newIncoming = fetchedMessages.where((m) {
        final id = m['id'] as String?;
        return m['direction'] == 'in' && id != null && !existingIds.contains(id);
      }).toList();

      final merged = _mergeMessages([...fetchedMessages, ...localOnly]);
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
      if (added && _isNearBottom()) {
        _scrollToBottom();
      }

      for (final msg in newIncoming) {
        final from = (msg['from'] as String?) ?? '';
        var body = (msg['content'] as String?) ?? '';
        final media = msg['media'];
        if ((body.isEmpty) && media != null) {
          body = '(attachment)';
        }
        _showIncomingNotification(from, body);
      }
    } catch (e) {
      setState(() {
        lastError = 'Fetch failed: $e';
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = messageCtrl.text.trim();
    if ((text.isEmpty && _pendingAttachment == null) || selectedContact == null) return;
    if (_sendCooldown) return;

    try {
      _sendCooldown = true;
      Future.delayed(const Duration(milliseconds: 600), () {
        _sendCooldown = false;
      });

      String payload = text;
      Map<String, dynamic>? localMedia;
      String localText = text;

      if (_pendingAttachment != null) {
        final desc = api.encryptMedia(
          bytes: _pendingAttachment!.bytes,
          recipient: selectedContact!,
          mime: _pendingAttachment!.mime,
          filename: _pendingAttachment!.name,
        );
        payload = jsonEncode({
          'media': {
            'url': desc.url,
            'iv': desc.iv,
            'sha256': desc.sha256,
            'cipher_sha256': desc.cipherSha256,
            'mime': desc.mime,
            'size': desc.size.toInt(),
            'encryption': desc.encryption,
            'filename': desc.filename,
          }
        });
        // Use the original picked bytes for local preview (matches browser extension behavior).
        localMedia = {
          'bytes': _pendingAttachment!.bytes,
          'mime': _pendingAttachment!.mime,
          'size': _pendingAttachment!.bytes.length,
          'filename': _pendingAttachment!.name,
        };
        localText = '(attachment)';
      }
      // Add to local messages immediately (presume success)
      final localId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      _sessionMessages.add(localId); // Mark as session message
      final displayContent = localMedia != null
          ? {'text': localText, 'media': localMedia}
          : {'text': text, 'media': null};
      setState(() {
        messages.add(<String, dynamic>{
          'id': localId,
          'from': npub ?? '',
          'to': selectedContact!,
          'content': displayContent['text'],
          'media': displayContent['media'],
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'direction': 'out',
        });
        messageCtrl.clear();
        _pendingAttachment = null;
        lastError = null;
      });

      // Save messages to persist them
      await _saveMessages();
      _scrollToBottom();

      // Fire the send in the background
      unawaited(Future.microtask(() async {
        try {
          await api.sendGiftDm(recipient: selectedContact!, content: payload, useNip44: true);
        } catch (e) {
          // best effort; in a real app we might mark failed
        } finally {
          _sessionMessages.remove(localId);
        }
      }));

      // Reset adaptive interval when sending a message
      // This ensures responsive checking for the reply
      await _resetAdaptiveInterval();
    } catch (e) {
      setState(() {
        lastError = 'Send failed: $e';
      });
    }
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
              decoration: const InputDecoration(labelText: 'npub or hex pubkey'),
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
              var pubkey = pubkeyCtrl.text.trim();
              final nickname = nicknameCtrl.text.trim();

              if (pubkey.isEmpty) {
                Navigator.pop(context);
                return;
              }

              // Convert npub to hex if needed
              if (pubkey.toLowerCase().startsWith('npub')) {
                try {
                  pubkey = api.npubToHex(npub: pubkey);
                } catch (e) {
                  setState(() => lastError = 'Invalid npub: $e');
                  Navigator.pop(context);
                  return;
                }
              }

              setState(() {
                contacts.add(<String, dynamic>{'nickname': nickname, 'pubkey': pubkey});
                contacts = _dedupeContacts(contacts);
                _sortContactsByActivity();
                selectedContact = pubkey;
              });

              await _saveContacts();
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _editContact(BuildContext context, Map<String, dynamic> contact) async {
    final nicknameCtrl = TextEditingController(text: contact['nickname']?.toString() ?? _short(contact['pubkey'] ?? ''));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit nickname'),
        content: TextField(
          controller: nicknameCtrl,
          decoration: const InputDecoration(labelText: 'Nickname'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirmed != true) return;
    final updatedNick = nicknameCtrl.text.trim();
    setState(() {
      for (final c in contacts) {
        if (c['pubkey'] == contact['pubkey']) {
          c['nickname'] = updatedNick.isEmpty ? _short(c['pubkey'] ?? '') : updatedNick;
          break;
        }
      }
    });
    await _saveContacts();
  }

  Future<void> _scanContactQr() async {
    final scanned = await _scanQrRaw();
    if (scanned == null || scanned.trim().isEmpty) return;
    var input = scanned.trim();
    String? displayNpub;
    try {
      if (input.startsWith('npub')) {
        input = api.npubToHex(npub: input);
      }
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
            SelectableText(displayNpub ?? input, style: const TextStyle(fontSize: 12)),
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
    await _saveContacts();
    if (mounted) {
      _showThemedToast('Contact added', preferTop: true);
    }
  }

  Future<String?> _scanQrRaw() async {
    final granted = await _ensureCameraPermission();
    if (!granted) {
      if (mounted) {
        _showThemedToast('Camera permission required to scan QR', preferTop: true);
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
          wait: const Duration(seconds: 2),
        );
        if (result != null && result.isNotEmpty && result != '[]') {
          final List<dynamic> list = jsonDecode(result);
          var newMessages = list.cast<Map<String, dynamic>>();
          newMessages = await _decodeMessages(newMessages);
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
              messages = _mergeMessages([...messages, ...newMessages]);
              lastError = null;
              contacts = _dedupeContacts(contacts);
              _sortContactsByActivity();
            });
            _ensureSelectedContact();
            await _saveMessages();
            await _saveContacts();
            if (_isNearBottom()) {
              _scrollToBottom();
            }
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
    if (selectedContact != null && contacts.any((c) => c['pubkey'] == selectedContact)) {
      return;
    }
    String? best;
    int bestTs = -1;
    for (final m in messages) {
      final contact = m['direction'] == 'out' ? (m['to'] as String?) : (m['from'] as String?);
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
    }
  }

  int _lastActivityFor(String? pubkey) {
    if (pubkey == null || pubkey.isEmpty) return -1;
    var ts = -1;
    for (final m in messages) {
      final contact = m['direction'] == 'out' ? (m['to'] as String?) : (m['from'] as String?);
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

  Future<void> _loadLocalProfileData({required int profileIndex, bool overrideLoaded = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final profileList = prefs.getStringList('profiles') ?? [];
    String? profileNsec;
    if (profileIndex >= 0 && profileIndex < profileList.length) {
      final parts = profileList[profileIndex].split('|');
      profileNsec = parts.isNotEmpty ? parts[0] : null;
    } else {
      profileNsec = nsec;
    }
    final contactsKey = profileNsec != null && profileNsec.isNotEmpty ? _contactsKeyFor(profileNsec) : 'contacts';
    final messagesKey = profileNsec != null && profileNsec.isNotEmpty ? _messagesKeyFor(profileNsec) : 'messages';
    final pendingKey = profileNsec != null && profileNsec.isNotEmpty ? _pendingDmsKeyFor(profileNsec) : 'pending_dms';

    final savedContacts = prefs.getStringList(contactsKey) ?? [];
    final savedMessages = prefs.getString(messagesKey);
    final pendingMessagesJson = prefs.getString(pendingKey);
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
        final List<dynamic> pendingList = jsonDecode(pendingMessagesJson);
        pendingMessages = pendingList.cast<Map<String, dynamic>>();
      } catch (e) {
        print('Failed to load pending messages: $e');
      }
    }

    final loadedContacts = savedContacts
        .map((c) {
          final parts = c.split('|');
          return <String, dynamic>{'nickname': parts[0], 'pubkey': parts.length > 1 ? parts[1] : ''};
        })
        .where((c) => c['pubkey']!.isNotEmpty)
        .toList();

    if (!mounted) return;
    setState(() {
      if (overrideLoaded || contacts.isEmpty) {
        contacts = _dedupeContacts(loadedContacts);
      }
      if (overrideLoaded || messages.isEmpty) {
        messages = _mergeMessages([...loadedMessages, ...pendingMessages]);
      }
      _sortContactsByActivity();
    });
    _ensureSelectedContact();
    _persistVisibleState();
  }

  Future<void> _loadPendingMessagesIntoUi() async {
    if (!mounted) return;
    if (nsec == null || nsec!.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingKey = _pendingDmsKeyFor(nsec!);
      final pendingJson = prefs.getString(pendingKey);
      if (pendingJson == null || pendingJson.isEmpty) return;
      final pendingList = (jsonDecode(pendingJson) as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map(_normalizeIncomingMessage)
          .toList();
      final decoded = await _decodeMessages(pendingList);
      if (!mounted) return;
      setState(() {
        messages = _mergeMessages([...messages, ...decoded]);
        contacts = _dedupeContacts(contacts);
        _sortContactsByActivity();
      });
      await _saveMessages();
      _scrollToBottom();
      await prefs.remove(pendingKey);
    } catch (_) {
      // ignore pending load errors
    }
  }

  List<Map<String, dynamic>> _mergeMessages(List<Map<String, dynamic>> incoming) {
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
    merged.sort((a, b) => (a['created_at'] ?? 0).compareTo(b['created_at'] ?? 0));
    return merged;
  }

  Future<List<Map<String, dynamic>>> _decodeMessages(List<Map<String, dynamic>> msgs) async {
    final decoded = <Map<String, dynamic>>[];
    for (final m in msgs) {
      final content = m['content']?.toString() ?? '';
      final senderPubkey = m['from']?.toString() ?? npub ?? '';
      final messageId = m['id'] as String?;
      final processed = await _decodeContent(content, senderPubkey, messageId);
      decoded.add({
        ...m,
        'content': processed['text'],
        'media': processed['media'],
      });
    }
    return decoded;
  }

  Map<String, dynamic> _normalizeIncomingMessage(Map<String, dynamic> msg) {
    final dir = (msg['direction'] ?? msg['dir'] ?? '').toString().toLowerCase();
    if (dir == 'incoming') {
      msg['direction'] = 'in';
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int ts = 0;
    final raw = msg['created_at'];
    if (raw is int) ts = raw;
    else if (raw is double) ts = raw.round();
    else if (raw is String) ts = int.tryParse(raw) ?? 0;
    if (ts <= 0) ts = nowSec;
    if (ts > nowSec + 300) ts = nowSec; // clamp future to now to avoid ordering/regression issues
    msg['created_at'] = ts;
    return msg;
  }

  Future<void> _persistVisibleState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_visible', _appVisible);
      if (selectedContact != null && selectedContact!.isNotEmpty) {
        await prefs.setString('visible_contact', selectedContact!);
      }
    } catch (_) {
      // ignore
    }
  }

  Future<Map<String, dynamic>> _decodeContent(String raw, String senderPubkey, String? messageId) async {
    // Check if content is valid JSON before trying to parse it
    if (!raw.trim().startsWith('{') && !raw.trim().startsWith('[')) {
      // Plain text message, not a media descriptor
      return {'text': raw, 'media': null};
    }

    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map && parsed['media'] != null) {
        final media = Map<String, dynamic>.from(parsed['media'] as Map);
        final cacheKey = (media['cipher_sha256'] as String?) ?? (media['url'] as String?) ?? '';

        final isEncrypted = (media['encryption'] == 'aes-gcm' && (media['iv'] ?? '').toString().isNotEmpty);

        // Non-encrypted link/media descriptor: show as downloadable attachment without decrypting
        if (!isEncrypted) {
          final mime = (media['mime'] as String?) ?? 'application/octet-stream';
          final filename = (media['filename'] as String?) ?? 'attachment';
          final url = (media['url'] as String?) ?? '';
          return {
            'text': '(attachment)',
            'media': {
              'bytes': null,
              'mime': mime,
              'size': media['size'] as int?,
              'sha256': media['sha256'] as String?,
              'filename': filename,
              'url': url,
              'nonEncrypted': true,
            }
          };
        }

        // Check cache first
        if (_decryptedMediaCache.containsKey(cacheKey)) {
          final cachedBytes = _decryptedMediaCache[cacheKey]!;
          final mime = (media['mime'] as String?) ?? 'application/octet-stream';
          final filename = (media['filename'] as String?) ?? 'attachment';
          return {
            'text': '(attachment)',
            'media': {
              'bytes': cachedBytes,
              'mime': mime,
              'size': media['size'] as int?,
              'sha256': media['sha256'] as String?,
              'filename': filename,
              'cached': true,
            }
          };
        }

        // Check if this is an old message (not from current session)
        final isOldMessage = messageId != null && !_sessionMessages.contains(messageId);

        if (isOldMessage) {
          // Return placeholder for old messages - will show decrypt button
          final mime = (media['mime'] as String?) ?? 'application/octet-stream';
          final filename = (media['filename'] as String?) ?? 'attachment';
          return {
            'text': '(attachment)',
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
            }
          };
        }

        // Auto-decrypt for new messages
        final descriptorJson = jsonEncode(media);
        final bytes = Uint8List.fromList(
          api.decryptMedia(
            descriptorJson: descriptorJson,
            senderPubkey: senderPubkey,
            myNsec: nsec,
          )
        );

        // Cache the decrypted bytes
        _decryptedMediaCache[cacheKey] = bytes;

        final mime = (media['mime'] as String?) ?? 'application/octet-stream';
        final filename = (media['filename'] as String?) ?? 'attachment';
        return {
          'text': '(attachment)',
          'media': {
            'bytes': bytes,
            'mime': mime,
            'size': media['size'] as int?,
            'sha256': media['sha256'] as String?,
            'filename': filename,
          }
        };
      }
    } catch (e) {
      print('Failed to decode media: $e');
      // Not a media descriptor or decryption failed, fall back to raw.
    }
    return {'text': raw, 'media': null};
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent + 80;
      if (_isNearBottom()) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final max = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;
    return (max - offset) < 200;
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
      final bytes = file.bytes;
      if (bytes == null) return;
      final name = file.name;
      final mime = lookupMimeType(name, headerBytes: bytes) ?? 'application/octet-stream';
      setState(() {
        _pendingAttachment = _PendingAttachment(
          bytes: bytes,
          mime: mime,
          name: name,
        );
      });
      _scrollToBottom();
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
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
      final bytes = await picked.readAsBytes();
      final name = picked.name;
      final mime = lookupMimeType(name, headerBytes: bytes) ?? 'image/*';
      setState(() {
        _pendingAttachment = _PendingAttachment(
          bytes: bytes,
          mime: mime,
          name: name,
        );
      });
      _scrollToBottom();
    } catch (e) {
      _showThemedToast('Attach failed: $e', preferTop: true);
    }
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Image'),
              onTap: () {
                Navigator.pop(ctx);
                _attachImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('File'),
              onTap: () {
                Navigator.pop(ctx);
                _attachFile();
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Future<void> _ensureRustInitialized() async {
    if (_didInitRust) return;
    try {
      await RustLib.init();
      _didInitRust = true;
    } catch (e) {
      // flutter_rust_bridge throws on double-init; if that's the case, continue.
      if (!e.toString().contains('Should not initialize flutter_rust_bridge twice')) {
        rethrow;
      }
      _didInitRust = true;
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
        title: _buildSendToDropdown(inAppBar: true),
        actions: const [],
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
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
                          const Text('Pushstr', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
                      constraints: const BoxConstraints.tightFor(width: 52, height: 52),
                      onPressed: _showMyNpubQr,
                    ),
                  ],
                ),
              ),
            ),
            for (final contact in contacts)
              Dismissible(
                key: ValueKey(contact['pubkey'] ?? ''),
                background: Container(
                  color: Colors.red.withValues(alpha: 0.4),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                secondaryBackground: Container(
                  color: Colors.red.withValues(alpha: 0.4),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) async {
                  setState(() {
                    contacts.removeWhere((c) => c['pubkey'] == contact['pubkey']);
                    if (selectedContact == contact['pubkey']) {
                      selectedContact = contacts.isNotEmpty ? contacts.first['pubkey'] : null;
                    }
                  });
                  await _saveContacts();
                },
                child: ListTile(
                  title: Text(
                    () {
                      final nickname = (contact['nickname'] ?? '').toString().trim();
                      return nickname.isNotEmpty ? nickname : _short(contact['pubkey'] ?? '');
                    }(),
                  ),
                  subtitle: Text(_short(contact['pubkey'] ?? ''), style: const TextStyle(fontSize: 11)),
                  selected: selectedContact == contact['pubkey'],
                  onTap: () {
                    setState(() => selectedContact = contact['pubkey']);
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
                        active: _holdActiveHome['delete_contact_${contact['pubkey']}'] ?? false,
                        progress: _holdProgressHomeFor('delete_contact_${contact['pubkey']}'),
                        onTap: () => _showHoldWarningHome('Hold 5s to delete contact'),
                        onHoldStart: () {
                          _startHoldActionHome(
                            'delete_contact_${contact['pubkey']}',
                            () async {
                            setState(() {
                              contacts.removeWhere((c) => c['pubkey'] == contact['pubkey']);
                              if (selectedContact == contact['pubkey']) {
                                selectedContact = contacts.isNotEmpty ? contacts.first['pubkey'] : null;
                              }
                            });
                            await _saveContacts();
                            _cancelHoldActionHome('delete_contact_${contact['pubkey']}');
                            },
                            countdownLabel: 'delete contact',
                          );
                        },
                        onHoldEnd: () => _cancelHoldActionHome('delete_contact_${contact['pubkey']}'),
                      ),
                    ],
                  ),
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
          if (!isConnected)
            Container(
              color: Colors.orange.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(8),
              child: const Row(
                children: [
                  Icon(Icons.warning, size: 16),
                  SizedBox(width: 8),
                  Text('Connecting to relays...', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          if (lastError != null)
            Container(
              color: Colors.red.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Icon(Icons.error, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(lastError!, style: const TextStyle(fontSize: 12))),
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
    _persistVisibleState();

    final convo = messages
        .where((m) {
          final dir = (m['direction'] ?? '').toString();
          final from = (m['from'] ?? '').toString();
          final to = (m['to'] ?? '').toString();
          if (dir == 'out') return to == selectedContact;
          if (dir == 'in' || dir == 'incoming') return from == selectedContact;
          // Fallback: include if either side matches selected contact
          return from == selectedContact || to == selectedContact;
        })
        .toList()
      ..sort((a, b) => (a['created_at'] ?? 0).compareTo(b['created_at'] ?? 0));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: convo.length,
      itemBuilder: (context, idx) {
        final m = convo[idx];
        final align = m['direction'] == 'out' ? Alignment.centerRight : Alignment.centerLeft;
        final isOut = m['direction'] == 'out';
        final color = isOut
            ? const Color(0xFF1E3A5F)
            : const Color(0xFF10923A);
        final blossomUrl = _extractBlossomUrl(m['content']);
          final actions = !isOut
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        _copiedMessages[_messageCopyKey(m)] == true ? Icons.check_circle : Icons.copy,
                        size: 16,
                        color: _copiedMessages[_messageCopyKey(m)] == true
                            ? Colors.greenAccent
                            : Colors.grey.shade400,
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
          crossAxisAlignment: isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Align(
              alignment: align,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _buildMessageContent(
                      m,
                      isOut: isOut,
                    ),
                  ),
                  if (actions != null) ...[
                    const SizedBox(width: 6),
                    actions,
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
              child: Text(
                _friendlyTime(m['created_at']),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSendToDropdown({bool inAppBar = false}) {
    final showDetails = !inAppBar;
    final contactItems = contacts
        .map(
          (c) {
            final nickname = c['nickname'] ?? '';
            final pubkey = c['pubkey'] ?? '';
      final primary = _short(pubkey);
      final label = nickname.trim().isNotEmpty
          ? '$primary · $nickname'
          : primary;

            return DropdownMenuItem<String>(
              value: pubkey,
        child: Text(label, overflow: TextOverflow.ellipsis),
            );
          },
        )
        .toList();
    final selectedValue =
        contacts.any((c) => c['pubkey'] == selectedContact) ? selectedContact : null;

    final dropdown = DropdownButtonFormField<String>(
      value: selectedValue,
      isExpanded: true,
      isDense: inAppBar,
      itemHeight: showDetails ? kMinInteractiveDimension : null,
      decoration: inAppBar
          ? InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                borderSide: BorderSide(color: Colors.white.withOpacity(0.9), width: 1.2),
              ),
            )
          : const InputDecoration(
              labelText: 'Send to',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
      selectedItemBuilder: (_) => contacts
          .map((c) {
            final pubkey = c['pubkey'] ?? '';
        final nickname = (c['nickname'] ?? '').toString().trim();
        final primary = nickname.isNotEmpty ? nickname : _short(pubkey);
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(primary, overflow: TextOverflow.ellipsis),
            );
          })
          .toList(),
      hint: const Text('Select a contact'),
      items: contactItems,
      onChanged: contactItems.isEmpty
          ? null
          : (value) {
              if (value == null) return;
              setState(() => selectedContact = value);
              _scrollToBottom();
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
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: messageCtrl,
                builder: (context, value, _) {
                  final hasContent = value.text.trim().isNotEmpty || _pendingAttachment != null;
                  final noContacts = contacts.isEmpty;
                  final canSend = selectedContact != null && !noContacts;
                  return Row(
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: 180,
                          ),
                          child: TextField(
                            controller: messageCtrl,
                            focusNode: _messageFocus,
                            keyboardType: TextInputType.multiline,
                            minLines: 1,
                            maxLines: null, // allow scrolling inside the field
                            decoration: InputDecoration(
                              hintText: 'Message',
                              filled: false,
                              border: const OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.transparent),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.greenAccent.withOpacity(0.35)),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.greenAccent),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        onPressed: noContacts
                            ? () => _addContact(context)
                            : (canSend
                                  ? () => hasContent
                                        ? _sendMessage()
                                        : _showAttachChooser()
                                : null),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: Theme.of(context).colorScheme.primary,
                          highlightColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                          splashFactory: NoSplash.splashFactory,
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
    final currentProfileIndex = updatedPrefs.getInt('selected_profile_index') ?? 0;
    final cachedNpubs = updatedPrefs.getStringList('profile_npubs_cache') ?? [];
    final cachedNpub =
        (currentProfileIndex < cachedNpubs.length) ? cachedNpubs[currentProfileIndex] : '';
    final didProfileChange = currentNsec != previousNsec || currentProfileIndex != previousProfileIndex;

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
      await _loadLocalProfileData(profileIndex: currentProfileIndex, overrideLoaded: true);
      // Restart listener and fetch messages
      _startDmListener();
      _fetchMessages();
    }
  }

  Future<void> _showMyNpubQr() async {
    try {
      final npubValue = (npub != null && npub!.isNotEmpty) ? npub! : api.getNpub();
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
                const Text('My npub', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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

  String _shortHex(String text) {
    final value = text.trim();
    if (value.length <= 12) return value;
    return '${value.substring(0, 8)}...${value.substring(value.length - 4)}';
  }

  String _displayNameFor(String pubkey) {
    final match = contacts.firstWhere(
      (c) => c['pubkey'] == pubkey,
      orElse: () => const <String, dynamic>{},
    );
    final nick = (match['nickname'] ?? '').toString().trim();
    if (nick.isNotEmpty) return nick;
    return _short(pubkey);
  }

  Future<void> _showIncomingNotification(String fromPubkey, String content) async {
    if (fromPubkey.isEmpty) return;
    final title = 'DM from ${_displayNameFor(fromPubkey)}';
    final body = content.isNotEmpty ? content : 'New message';
    await showDmNotification(title: title, body: body);
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
    return text.replaceFirst(RegExp(r'^\[\/\/\]:\s*#\s*\(nip18\)\s*', caseSensitive: false), '').trim();
  }

  Widget _buildMessageContent(Map<String, dynamic> message, {required bool isOut}) {
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
                    Expanded(child: Text(filename, style: const TextStyle(fontSize: 13))),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.lock_open, size: 16),
                  label: Text('Decrypt: $filename'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImage)
            Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  Text('Failed to load image', style: TextStyle(color: Colors.grey.shade400)),
            ),
          if (!isImage)
            Text(
              media['filename']?.toString() ?? 'Attachment',
              style: const TextStyle(decoration: TextDecoration.underline),
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
                    Clipboard.setData(ClipboardData(text: 'Attachment (${mime})'));
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
      final isImage = mime.startsWith('image/') || RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(url);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(filename, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          if (isImage)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) =>
                    Text('Image preview failed', style: TextStyle(color: Colors.grey.shade400)),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: Icon(isBlossom ? Icons.download : Icons.open_in_new, size: 18),
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
      final isImage = RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(url);
      final textPart = cleaned.replaceFirst(url, '').trim();
      final isBlossom = _isBlossomLink(url);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (textPart.isNotEmpty)
            Text(
              textPart,
              style: const TextStyle(fontSize: 15),
            ),
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
                errorBuilder: (context, error, stackTrace) =>
                    Text('Image preview failed', style: TextStyle(color: Colors.grey.shade400)),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: Icon(isBlossom ? Icons.download : Icons.open_in_new, size: 18),
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
        )
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
      final dir = await getTemporaryDirectory();
      final ext = extensionFromMime(mime);
      final file = File('${dir.path}/pushstr_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      _showThemedToast('Saved to ${file.path}', preferTop: true);
    } catch (e) {
      if (!mounted) return;
      _showThemedToast('Save failed: $e', preferTop: true);
    }
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
    final match = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(text);
    return match?.group(0);
  }

  bool _isBlossomLink(String url, [Map<String, dynamic>? meta]) {
    final uri = Uri.tryParse(url);
    final hostHasBlossom = uri?.host.contains('blossom') ?? false;
    final frag = uri?.fragment ?? '';
    final fragHasMeta = frag.contains('m=') || frag.contains('size=') || frag.contains('x=');
    final hasMeta = (meta?['sha256']?.toString().isNotEmpty ?? false) ||
        (meta?['cipher_sha256']?.toString().isNotEmpty ?? false) ||
        (meta?['iv']?.toString().isNotEmpty ?? false) ||
        (meta?['mime']?.toString().isNotEmpty ?? false) ||
        (meta?['size'] != null);
    return hasMeta && (hostHasBlossom || fragHasMeta);
  }

  Future<void> _initShareListener() async {
    try {
      // Handle initial share when app is launched from share sheet
      final initial = await _shareChannel.invokeMethod<dynamic>('getInitialShare');
      _handleSharedPayload(initial);

      // Listen for subsequent shares while app is alive
      _shareChannel.setMethodCallHandler((call) async {
        if (call.method == 'onShare') {
          _handleSharedPayload(call.arguments);
        }
      });
    } catch (e) {
      // Swallow share errors to avoid breaking startup
      debugPrint('Share init failed: $e');
    }
  }

  void _handleSharedPayload(dynamic payload) {
    if (payload is! Map) return;
    final text = payload['text']?.toString() ?? '';
    final bytes = _asUint8List(payload['bytes']);
    final mime = payload['type']?.toString() ?? '';
    final name = payload['name']?.toString();

    if (bytes != null && bytes.isNotEmpty) {
      final resolvedMime = mime.isNotEmpty ? mime : (lookupMimeType(name ?? '', headerBytes: bytes) ?? 'application/octet-stream');
      final filename = (name != null && name.isNotEmpty) ? name : 'shared.${extensionFromMime(resolvedMime)}';
      setState(() {
        _pendingAttachment = _PendingAttachment(
          bytes: bytes,
          mime: resolvedMime,
          name: filename,
        );
        if (text.isNotEmpty) {
          messageCtrl.text = text;
        }
      });
      _messageFocus.requestFocus();
      _scrollToBottom();
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
    final hour = date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour);
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
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final months = ['January', 'February', 'March', 'April', 'May', 'June',
                    'July', 'August', 'September', 'October', 'November', 'December'];

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
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withOpacity(0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.primary.withOpacity(0.8)),
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
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
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
  void _startHoldActionHome(String key, VoidCallback onComplete, {String? countdownLabel}) {
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
    _holdTimersHome[key] = Timer.periodic(const Duration(milliseconds: 120), (t) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final progress = (elapsed / _holdMillis).clamp(0.0, 1.0);
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _holdProgressHome[key] = progress;
      });
      final remainingSeconds = ((_holdMillis - elapsed).clamp(0, _holdMillis) / 1000).ceil();
      if (countdownLabel != null && remainingSeconds != _holdLastSecondHome[key]) {
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
  _PendingAttachment({required this.bytes, required this.mime, required this.name});
  final Uint8List bytes;
  final String mime;
  final String name;
}

class _PendingPreview extends StatelessWidget {
  const _PendingPreview({required this.attachment, required this.onRemove});

  final _PendingAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final isImage = attachment.mime.startsWith('image/');
    Widget preview;
    if (isImage) {
      preview = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          attachment.bytes,
          height: 120,
          fit: BoxFit.cover,
        ),
      );
    } else {
      preview = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file),
          const SizedBox(width: 8),
          Text(attachment.name),
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
          preview,
          const Spacer(),
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
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;
  bool _handled = false;

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void _onQRViewCreated(QRViewController ctrl) {
    controller = ctrl;
    ctrl.scannedDataStream.listen((scanData) {
      if (_handled) return;
      final code = scanData.code;
      if (code == null || code.isEmpty) return;
      _handled = true;
      Navigator.of(context).pop(code);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan contact QR')),
      body: QRView(
        key: qrKey,
        onQRViewCreated: _onQRViewCreated,
        overlay: QrScannerOverlayShape(
          borderColor: Theme.of(context).colorScheme.primary,
          borderWidth: 8,
          borderLength: 24,
          borderRadius: 8,
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
  bool _foregroundEnabled = false;
  Timer? _copyResetTimer;
  Timer? _autoSaveTimer;
  final Map<String, Timer> _holdTimers = {};
  final Map<String, double> _holdProgress = {};
  final Map<String, bool> _holdActive = {};
  final Map<String, int> _holdLastSecond = {};
  static const int _holdMillis = 5000;
  bool _sendCooldown = false;
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

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
    final currentNickname = loadedProfiles.isNotEmpty && selectedIndex < loadedProfiles.length
        ? loadedProfiles[selectedIndex]['nickname'] ?? ''
        : '';

    // Load relays
    final loadedRelays = prefs.getStringList('relays') ?? [
      'wss://relay.damus.io',
      'wss://relay.primal.net',
      'wss://nos.lol',
    ];

    var npub = '';
    try {
      npub = api.getNpub();
    } catch (_) {
      npub = '';
    }

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
        _foregroundServiceEnabled =
            prefs.getBool('foreground_service_enabled') ?? false;
        _foregroundEnabled = _foregroundServiceEnabled;
      });
    }
    if (_foregroundServiceEnabled) {
      await _startForegroundService();
    } else {
      await _stopForegroundService();
    }
    _probeAllRelays(loadedRelays);
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
    return trimmed.isNotEmpty && (trimmed.startsWith('ws://') || trimmed.startsWith('wss://'));
  }

  void _updateRelayValidity() {
    final valid = _isRelayInputValid(relayInputCtrl.text);
    if (_relayInputValid != valid && mounted) {
      setState(() {
        _relayInputValid = valid;
      });
    }
  }

  Future<void> _startForegroundService() async {
    final notifGranted = await PermissionsGate.ensureNotificationPermission(context);
    if (!notifGranted) {
      _showThemedToast('Notification permission is required to stay connected', preferTop: true);
      return;
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      _foregroundServiceRunning = true;
      return;
    }
    await FlutterForegroundTask.startService(
      notificationTitle: 'Pushstr running',
      notificationText: 'Staying connected for incoming messages',
      callback: foregroundStartCallback,
    );
    _foregroundServiceRunning = true;
  }

  Future<void> _stopForegroundService() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      _foregroundServiceRunning = false;
      return;
    }
    await FlutterForegroundTask.stopService();
    _foregroundServiceRunning = false;
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
      await prefs.setBool(
        'foreground_service_enabled',
        _foregroundServiceEnabled,
      );

      if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) {
        final selectedNsec = profiles[selectedProfileIndex]['nsec']!;
        await prefs.setString('nostr_nsec', selectedNsec);
        profiles[selectedProfileIndex]['nickname'] = nicknameCtrl.text.trim();

        // Ensure the selected profile is active in Rust
        try {
          api.initNostr(nsec: selectedNsec);
          if (selectedProfileIndex < profileNpubs.length) {
            setState(() => currentNpub = profileNpubs[selectedProfileIndex]);
          }
        } catch (e) {
          print('Failed to activate profile: $e');
        }
      }

      await prefs.setStringList('relays', relays);

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
      if (_foregroundServiceEnabled) {
        await _startForegroundService();
      } else {
        await _stopForegroundService();
      }
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
                  });
                  _markDirty();
                  await _saveSettings();
                  await _refreshProfileNpubs();
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
          decoration: const InputDecoration(
            labelText: 'Nickname (optional)',
          ),
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
              });
              _markDirty();
              await _saveSettings();
              await _refreshProfileNpubs();
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
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withOpacity(0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.primary.withOpacity(0.8)),
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
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
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

  void _startHoldAction(String key, VoidCallback onComplete, {String? countdownLabel}) {
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
      final remainingSeconds = ((_holdMillis - elapsed).clamp(0, _holdMillis) / 1000).ceil();
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
                const Text('My npub', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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

    final current = (selectedProfileIndex < profiles.length && selectedProfileIndex >= 0)
        ? profiles[selectedProfileIndex]['nsec'] ?? ''
        : '';

    final npubs = <String>[];

    // Compute npubs on main thread to avoid isolate state confusion
    // Crypto operations are fast enough for a few profiles
    for (final profile in profiles) {
      final nsec = profile['nsec'] ?? '';
      if (nsec.isEmpty) {
        npubs.add('');
        continue;
      }
      try {
        final npub = api.initNostr(nsec: nsec);
        npubs.add(npub);
      } catch (e) {
        print('Failed to derive npub: $e');
        npubs.add('');
      }
    }

    // Restore the current nsec
    if (current.isNotEmpty) {
      try {
        api.initNostr(nsec: current);
      } catch (_) {
        // ignore restore errors
      }
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

  Future<void> _addRelay() async {
      final relay = relayInputCtrl.text.trim();
      setState(() => relayError = '');
      if (relay.isEmpty || !(relay.startsWith('ws://') || relay.startsWith('wss://'))) {
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
    WebSocket.connect(relay).timeout(const Duration(seconds: 4)).then((ws) {
      relayStatuses[relay] = RelayStatus.ok;
      relayStatusCheckedAt[relay] = DateTime.now();
      ws.close();
      if (mounted) setState(() {});
    }).catchError((_) {
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
        BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 6)),
        BoxShadow(color: Colors.greenAccent.withOpacity(0.04), blurRadius: 8, spreadRadius: 0.5),
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: buttons,
          ),
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
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [],
      ),
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
                if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) ...[
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Active profile',
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.35),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.greenAccent.shade200),
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
                          if (idx != null && idx < profiles.length && idx != selectedProfileIndex) {
                            final nsec = profiles[idx]['nsec'] ?? '';
                            if (nsec.isNotEmpty) {
                              // Switch the active key in Rust
                              try {
                                api.initNostr(nsec: nsec);
                              } catch (e) {
                                print('Failed to switch profile: $e');
                              }
                            }
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
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.greenAccent.shade200),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                      onChanged: (value) {
                        if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) {
                          profiles[selectedProfileIndex]['nickname'] = value;
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
                            onTap: () => _showHoldWarning('Hold 5s to delete profile'),
                            onHoldStart: () {
                              if (_isSaving || profiles.length <= 1) return;
                              _startHoldAction('delete_profile', () async {
                                final removing = selectedProfileIndex;
                                setState(() {
                                  profiles.removeAt(removing);
                                  if (removing < profileNpubs.length) {
                                    profileNpubs.removeAt(removing);
                                  }
                                  if (selectedProfileIndex >= profiles.length) {
                                    selectedProfileIndex = profiles.isEmpty ? 0 : profiles.length - 1;
                                  }
                                  profileNickname =
                                      profiles.isNotEmpty ? (profiles[selectedProfileIndex]['nickname'] ?? '') : '';
                                  nicknameCtrl.text = profileNickname;
                                });
                                      _hasPendingChanges = false;
                                await _saveSettings();
                                await _refreshProfileNpubs();
                                _cancelHoldAction('delete_profile');
                              }, countdownLabel: 'delete profile');
                            },
                            onHoldEnd: () => _cancelHoldAction('delete_profile'),
                          ),
                  ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                actionGroup(
                  'Management',
                  [
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
                  ],
                ),
                const SizedBox(height: 8),
                actionGroup(
                  'Utilities',
                  [
                  SwitchListTile(
                    title: const Text('Stay connected (foreground service)'),
                    subtitle: const Text(
                      'Keeps Pushstr running with a small notification',
                    ),
                    value: _foregroundEnabled,
                    onChanged: (val) async {
                      _showThemedToast(
                        val
                            ? 'Enabling background service…'
                            : 'Disabling background service…',
                        preferTop: true,
                      );
                      setState(() {
                        _foregroundEnabled = val;
                        _foregroundServiceEnabled = val;
                      });
                      // Ensure notification permission is granted when enabling
                      if (val) {
                        final notifGranted = await PermissionsGate.ensureNotificationPermission(context);
                        if (!notifGranted) {
                          setState(() {
                            _foregroundEnabled = false;
                            _foregroundServiceEnabled = false;
                          });
                          await _saveSettings();
                          return;
                        }
                      }

                      if (val) {
                        await _startForegroundService();
                      } else {
                        await _stopForegroundService();
                      }
                      await _saveSettings();
                    },
                  ),
                    Builder(builder: (context) {
                      final holdActive = _holdActive['copy_nsec'] ?? false;
                      final progress = _holdProgress['copy_nsec'] ?? 0.0;
                      final remainingMs = (_holdMillis * (1 - progress)).clamp(0.0, _holdMillis.toDouble());
                      final remainingSeconds = (remainingMs / 1000).ceil();
                      final label = _nsecCopied
                          ? 'Copied'
                          : holdActive
                          ? 'Hold ${remainingSeconds}s to copy profile secret (nSec)'
                          : 'Hold 5s to copy profile secret (nSec)';
                      return GestureDetector(
                        onLongPressStart: (_) => _startHoldAction('copy_nsec', () async {
                          await _exportCurrentKey();
                          _setCopyState(nsec: true);
                          _cancelHoldAction('copy_nsec');
                        }, countdownLabel: 'copy profile secret (nSec)'),
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
                    }),
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
                  ],
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
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.greenAccent.shade200),
                          ),
                          errorText: relayError.isEmpty ? null : relayError,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                        disabledBackgroundColor: Colors.greenAccent.shade200.withOpacity(0.4),
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
        ],
      ),
    );
  }
}
