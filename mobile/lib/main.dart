import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
// TODO: Re-enable when API is stable
// import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'bridge_generated.dart/api.dart' as api;
import 'bridge_generated.dart/frb_generated.dart';

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
  runApp(const PushstrApp());
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
  final ImagePicker _picker = ImagePicker();
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
  // StreamSubscription? _intentDataStreamSubscription;

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
    _scrollController.dispose();
    _messageFocus.dispose();
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
        _scrollToBottom();
      }
    }
    super.didChangeMetrics();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedNsec = prefs.getString('nostr_nsec') ?? '';

    // Handle shared content from Android intents
    _initShareListener();

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
      contacts = savedContacts
          .map((c) {
            final parts = c.split('|');
            return <String, dynamic>{'nickname': parts[0], 'pubkey': parts.length > 1 ? parts[1] : ''};
          })
          .where((c) => c['pubkey']!.isNotEmpty)
          .toList();
    });

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

  Future<void> _saveMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('messages', jsonEncode(messages));
    } catch (e) {
      print('Failed to save messages: $e');
    }
  }

  Future<void> _deleteConversation() async {
    if (selectedContact == null) return;
    final label = contacts.firstWhere(
      (c) => c['pubkey'] == selectedContact,
      orElse: () => <String, dynamic>{},
    )['nickname'] as String? ??
        _short(selectedContact!);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text('Remove local history with $label?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      messages.removeWhere((m) =>
          (m['direction'] == 'out' && m['to'] == selectedContact) ||
          (m['direction'] == 'in' && m['from'] == selectedContact));
    });
    await _saveMessages();
  }

  Future<void> _deleteConversationFor(String? pubkey) async {
    if (pubkey == null || pubkey.isEmpty) return;
    final label = contacts.firstWhere(
      (c) => c['pubkey'] == pubkey,
      orElse: () => <String, dynamic>{},
    )['nickname'] as String? ??
        _short(pubkey);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text('Remove local history with $label?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      messages.removeWhere((m) =>
          (m['direction'] == 'out' && m['to'] == pubkey) ||
          (m['direction'] == 'in' && m['from'] == pubkey));
    });
    await _saveMessages();
    if (selectedContact == pubkey) {
      setState(() {
        selectedContact = contacts.isNotEmpty ? contacts.first['pubkey'] : null;
      });
    }
  }

  Future<void> _saveContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'contacts',
        contacts.map((c) => '${c['nickname'] ?? ''}|${c['pubkey'] ?? ''}').toList(),
      );
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
      final dmsJson = api.fetchRecentDms(limit: BigInt.from(100));
      final List<dynamic> dmsList = jsonDecode(dmsJson);
      var fetchedMessages = dmsList.cast<Map<String, dynamic>>();
      fetchedMessages = await _decodeMessages(fetchedMessages);

      // Auto-add contacts from incoming messages
      final incomingPubkeys = fetchedMessages
          .where((m) => m['direction'] == 'in')
          .map((m) => m['from'] as String?)
          .where((pk) => pk != null && pk.isNotEmpty)
          .toSet();

      for (final pubkey in incomingPubkeys) {
        if (!contacts.any((c) => c['pubkey'] == pubkey)) {
          final newContact = {'pubkey': pubkey!, 'nickname': pubkey.substring(0, 8)};
          contacts.add(newContact);
        }
      }

      // Merge fetched messages with local messages (keep local messages that aren't in fetched)
      final fetchedIds = fetchedMessages.map((m) => m['id'] as String?).where((id) => id != null).toSet();
      final localOnly = messages.where((m) {
        final id = m['id'] as String?;
        return id != null && id.startsWith('local_') && !fetchedIds.contains(id);
      }).toList();

      final merged = _mergeMessages([...fetchedMessages, ...localOnly]);
      final added = merged.length > existingLen;
      setState(() {
        messages = merged;
        lastError = null;
      });

      // Save messages to persist them
      await _saveMessages();
      if (added && _isNearBottom()) {
        _scrollToBottom();
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

    try {
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

      api.sendGiftDm(recipient: selectedContact!, content: payload, useNip44: true);

      // Add to local messages immediately
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
        });
        messageCtrl.clear();
        _pendingAttachment = null;
        lastError = null;
      });

      // Save messages to persist them
      await _saveMessages();
      _scrollToBottom();
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
              final nickname = nicknameCtrl.text.trim();
              var pubkey = pubkeyCtrl.text.trim();

              if (nickname.isEmpty || pubkey.isEmpty) {
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
    try {
      if (input.startsWith('npub')) {
        input = api.npubToHex(npub: input);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid contact QR: $e')),
        );
      }
      return;
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(input)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('QR did not contain a valid pubkey')),
        );
      }
      return;
    }
    if (contacts.any((c) => c['pubkey'] == input)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contact already exists')),
        );
      }
      return;
    }

    final nicknameCtrl = TextEditingController(text: _short(input));
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
            SelectableText(input, style: const TextStyle(fontSize: 12)),
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

    final nickname = nicknameCtrl.text.trim().isEmpty ? _short(input) : nicknameCtrl.text.trim();
    setState(() {
      contacts.add(<String, dynamic>{'nickname': nickname, 'pubkey': input});
    });
    await _saveContacts();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact added')),
      );
    }
  }

  Future<String?> _scanQrRaw() async {
    final granted = await _ensureCameraPermission();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission required to scan QR')),
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
        final result = await Isolate.run(() async {
          try {
            await RustLib.init();
          } catch (_) {
            // Ignore double-init warning in isolate.
          }
          return api.waitForNewDms(timeoutSecs: BigInt.from(30));
        });
        if (result.isNotEmpty && result != '[]') {
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
                final newContact = {'pubkey': pubkey!, 'nickname': pubkey.substring(0, 8)};
                contacts.add(newContact);
              }
            }

            setState(() {
              messages = _mergeMessages([...messages, ...newMessages]);
              lastError = null;
            });
            await _saveMessages();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  Future<void> _attachImage() async {
    if (selectedContact == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a contact first')),
      );
      return;
    }
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final mime = lookupMimeType(picked.name) ?? 'image/*';
      setState(() {
        _pendingAttachment = _PendingAttachment(
          bytes: bytes,
          mime: mime,
          name: picked.name,
        );
      });
      _scrollToBottom();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attach failed: $e')),
      );
    }
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
        title: const Text('Pushstr'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchMessages,
            tooltip: 'Refresh messages',
          ),
        ],
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
                          const Text('Contacts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
                      icon: const Icon(Icons.qr_code_2),
                      tooltip: 'Show my npub QR',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
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
                  title: Text(contact['nickname'] ?? ''),
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
                        icon: const Icon(Icons.delete_forever),
                        tooltip: 'Delete conversation',
                        onPressed: () => _deleteConversationFor(contact['pubkey']),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit),
                        tooltip: 'Edit nickname',
                        onPressed: () => _editContact(context, contact),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          setState(() {
                            contacts.removeWhere((c) => c['pubkey'] == contact['pubkey']);
                            if (selectedContact == contact['pubkey']) {
                              selectedContact = contacts.isNotEmpty ? contacts.first['pubkey'] : null;
                            }
                          });
                          await _saveContacts();
                        },
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
              title: const Text('Scan contact QR'),
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

    final convo = messages
        .where((m) =>
            (m['direction'] == 'out' && m['to'] == selectedContact) ||
            (m['direction'] == 'in' && m['from'] == selectedContact))
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
        final color = isOut ? const Color(0xFF1E3A5F) : const Color(0xFF2E7D32);
        final blossomUrl = _extractBlossomUrl(m['content']);
        final actions = !isOut
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy message',
                    onPressed: () {
                      final text = (m['content'] ?? '').toString();
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Message copied')),
                      );
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

  Widget _buildComposer() {
    final contactItems = contacts
        .map(
          (c) => DropdownMenuItem<String>(
            value: c['pubkey'] ?? '',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c['nickname'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(_short(c['pubkey'] ?? ''), style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
        )
        .toList();
    final selectedValue =
        contacts.any((c) => c['pubkey'] == selectedContact) ? selectedContact : null;

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
        Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.3),
            border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: selectedValue,
                      isExpanded: true,
                      isDense: false,
                      decoration: const InputDecoration(
                        labelText: 'Send to',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                      hint: const Text('Select a contact'),
                      items: contactItems,
                      onChanged: contactItems.isEmpty
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => selectedContact = value);
                              _scrollToBottom();
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Add contact',
                    onPressed: () => _addContact(context),
                    icon: const Icon(Icons.person_add_alt),
                  ),
                ],
              ),
              if (contactItems.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Add a contact to start messaging',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: messageCtrl,
                builder: (context, value, _) {
                  final hasContent = value.text.trim().isNotEmpty || _pendingAttachment != null;
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
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              filled: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(hasContent ? Icons.send : Icons.attach_file),
                        onPressed: selectedContact == null
                            ? null
                            : () => hasContent ? _sendMessage() : _attachImage(),
                        style: IconButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
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
      ],
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
    // Reload after returning from settings
    await _init();
  }

  Future<void> _showMyNpubQr() async {
    try {
      final npubValue = (npub != null && npub!.isNotEmpty) ? npub! : api.getNpub();
      if (!mounted) return;
      if (npubValue.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No npub available')),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to show QR: $e')),
        );
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Attachment copied')),
                    );
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
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
  const _QrScanPage({super.key});

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
  String _saveStatus = 'Saved';
  Color _saveStatusColor = Colors.greenAccent.shade200;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    relayInputCtrl.dispose();
    nicknameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
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

    setState(() {
      profiles = loadedProfiles;
      selectedProfileIndex = selectedIndex;
      profileNickname = currentNickname;
      relays = loadedRelays;
      nicknameCtrl.text = currentNickname;
      currentNpub = npub;
    });

    await _refreshProfileNpubs();
    if (mounted) {
      setState(() {
        _hasPendingChanges = false;
        _isSaving = false;
        _saveStatus = 'Saved';
        _saveStatusColor = Colors.greenAccent.shade200;
      });
    }
    _probeAllRelays(loadedRelays);
  }

  void _markDirty() {
    if (!mounted) return;
    setState(() {
      _hasPendingChanges = true;
      _saveStatus = 'Unsaved changes';
      _saveStatusColor = Colors.amber.shade300;
    });
  }

  Future<void> _handleSaveAction() async {
    if (_isSaving) return;
    if (!_hasPendingChanges) {
      if (mounted) {
        setState(() {
          _saveStatus = 'No changes';
          _saveStatusColor = Colors.blueGrey.shade200;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No changes to save'),
            duration: Duration(milliseconds: 1200),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    await _saveSettings();
  }

  Future<void> _saveSettings() async {
    if (!mounted) return;
    setState(() {
      _isSaving = true;
      _saveStatus = 'Saving...';
      _saveStatusColor = Colors.amber.shade300;
    });
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setStringList(
        'profiles',
        profiles.map((p) => '${p['nsec']}|${p['nickname'] ?? ''}').toList(),
      );
      await prefs.setInt('selected_profile_index', selectedProfileIndex);

      if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) {
        await prefs.setString('nostr_nsec', profiles[selectedProfileIndex]['nsec']!);
        profiles[selectedProfileIndex]['nickname'] = nicknameCtrl.text.trim();
      }

      await prefs.setStringList('relays', relays);

      try {
        final npub = api.getNpub();
        setState(() => currentNpub = npub);
      } catch (_) {
        // ignore
      }

      await _refreshProfileNpubs();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _hasPendingChanges = false;
        _saveStatus = 'Saved';
        _saveStatusColor = Colors.greenAccent.shade200;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          duration: Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveStatus = 'Save failed';
        _saveStatusColor = Colors.amber.shade300;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save failed: $e'),
          duration: const Duration(milliseconds: 1600),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('nsec copied to clipboard')),
      );
    }
  }

  Future<void> _copyNpub() async {
    try {
      final npub = api.getNpub();
      await Clipboard.setData(ClipboardData(text: npub));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('npub copied to clipboard')),
        );
        setState(() => currentNpub = npub);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _showNpubQr() async {
    try {
      final npub = api.getNpub();
      if (!mounted) return;
      setState(() => currentNpub = npub);
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
                      data: npub,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    npub,
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to show QR: $e')),
        );
      }
    }
  }

  Future<void> _refreshProfileNpubs() async {
    if (profiles.isEmpty) return;
    final current = (selectedProfileIndex < profiles.length && selectedProfileIndex >= 0)
        ? profiles[selectedProfileIndex]['nsec'] ?? ''
        : '';
    final npubs = <String>[];
    for (final profile in profiles) {
      final nsec = profile['nsec'] ?? '';
      if (nsec.isEmpty) {
        npubs.add('');
        continue;
      }
      try {
        final npub = api.initNostr(nsec: nsec);
        npubs.add(npub);
      } catch (_) {
        npubs.add('');
      }
    }
    if (current.isNotEmpty) {
      try {
        api.initNostr(nsec: current);
      } catch (_) {
        // ignore restore errors
      }
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
      border: Border.all(color: Colors.greenAccent.withOpacity(0.32)),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 8)),
        BoxShadow(color: Colors.greenAccent.withOpacity(0.08), blurRadius: 10, spreadRadius: 1),
      ],
    );

    Widget actionGroup(String label, List<Widget> buttons) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 0.08,
              color: Colors.white70,
              fontWeight: FontWeight.w700,
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

    Widget relayRow(String relay) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
            Expanded(
              child: Text(
                relay,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Remove relay',
              icon: const Icon(Icons.delete_outline, size: 20),
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.08),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Remove relay?'),
                    content: Text('Remove $relay?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (confirmed == true) {
                  setState(() {
                    relays.remove(relay);
                    relayStatuses.remove(relay);
                    relayStatusCheckedAt.remove(relay);
                  });
                  _markDirty();
                  await _saveSettings();
                }
              },
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pushstr Settings'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: (!_hasPendingChanges || _isSaving) ? null : _handleSaveAction,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.greenAccent.shade400,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.greenAccent.shade200.withOpacity(0.4),
                disabledForegroundColor: Colors.black.withOpacity(0.4),
                minimumSize: const Size(94, 40),
              ),
              icon: _isSaving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                      ),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(_isSaving ? 'Saving' : 'Save'),
            ),
          ),
        ],
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
                  'Profile & npub',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) ...[
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Active profile',
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.35),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                          final nickname = profile['nickname'] ?? '';
                          final npubLabel = (idx < profileNpubs.length && profileNpubs[idx].isNotEmpty)
                              ? _shortNpub(profileNpubs[idx])
                              : '';
                          final label = nickname.isNotEmpty
                              ? nickname
                              : (npubLabel.isNotEmpty ? npubLabel : 'Profile ${idx + 1}');

                          return DropdownMenuItem(
                            value: idx,
                            child: Text(label),
                          );
                        }).toList(),
                        onChanged: (idx) async {
                          if (idx != null) {
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
                  const SizedBox(height: 10),
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
                          ),
                          onChanged: (value) {
                            if (profiles.isNotEmpty && selectedProfileIndex < profiles.length) {
                              profiles[selectedProfileIndex]['nickname'] = value;
                              _markDirty();
                              _saveSettings();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: 'Remove profile',
                        onPressed: profiles.length <= 1
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Remove profile?'),
                                    content: const Text('This will remove the selected profile. Continue?'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  final removing = selectedProfileIndex;
                                  setState(() {
                                    profiles.removeAt(removing);
                                    if (removing < profileNpubs.length) {
                                      profileNpubs.removeAt(removing);
                                    }
                                    if (selectedProfileIndex >= profiles.length) {
                                      selectedProfileIndex = profiles.isEmpty ? 0 : profiles.length - 1;
                                    }
                                    profileNickname = profiles.isNotEmpty ? (profiles[selectedProfileIndex]['nickname'] ?? '') : '';
                                    nicknameCtrl.text = profileNickname;
                                  });
                                  _markDirty();
                                  await _saveSettings();
                                  await _refreshProfileNpubs();
                                }
                              },
                        icon: const Icon(Icons.delete_outline),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.06),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: sectionDecoration,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Key Actions',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                actionGroup(
                  'Key management',
                  [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(minimumSize: const Size(140, 44)),
                      onPressed: _generateProfile,
                      icon: const Icon(Icons.bolt_outlined),
                      label: const Text('New Key'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(minimumSize: const Size(140, 44)),
                      onPressed: _addProfile,
                      icon: const Icon(Icons.input_outlined),
                      label: const Text('Import nSec'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                actionGroup(
                  'Utilities',
                  [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(minimumSize: const Size(140, 44)),
                      onPressed: _exportCurrentKey,
                      icon: const Icon(Icons.vpn_key_outlined),
                      label: const Text('Copy nSec'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(minimumSize: const Size(140, 44)),
                      onPressed: _copyNpub,
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Copy nPub'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(minimumSize: const Size(140, 44)),
                      onPressed: _showNpubQr,
                      icon: const Icon(Icons.qr_code_2),
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
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _addRelay,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(90, 44),
                        backgroundColor: Colors.greenAccent.shade400,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...relays.map(relayRow),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
