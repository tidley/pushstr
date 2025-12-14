import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _permissionsChannel = MethodChannel('com.pushstr.permissions');

class PermissionsGate {
  static const _gateVersion = 2;

  /// Runs once per changed permission state. Only prompts when a required
  /// permission/setting is missing or when the device/OEM requires guidance.
  static Future<void> ensureAtLaunch(
    BuildContext context, {
    SharedPreferences? prefs,
  }) async {
    if (!Platform.isAndroid) return;
    final sharedPrefs = prefs ?? await SharedPreferences.getInstance();
    final state = await _GateState.load();
    final gatePrefs = await _GatePrefs.load(sharedPrefs);

    final needsNotifPrompt = state.needsNotificationPermission &&
        (!gatePrefs.askedPostNotifications || (gatePrefs.cachedNotificationsGranted && !state.notificationGranted));
    final needsBatteryPrompt = state.needsBatteryExemption &&
        (!gatePrefs.askedBatteryOpt || (gatePrefs.cachedBatteryExempt && !state.batteryExempt));
    final needsOemPrompt = state.showOemGuidance && gatePrefs.oemGuidanceShownFor != state.manufacturer;
    final shouldPrompt = needsNotifPrompt || needsBatteryPrompt || needsOemPrompt;

    if (!shouldPrompt || !context.mounted) {
      await gatePrefs.save(sharedPrefs, state: state);
      return;
    }

    gatePrefs
      ..askedPostNotifications = gatePrefs.askedPostNotifications || needsNotifPrompt
      ..askedBatteryOpt = gatePrefs.askedBatteryOpt || needsBatteryPrompt
      ..oemGuidanceShownFor = needsOemPrompt ? state.manufacturer : gatePrefs.oemGuidanceShownFor;
    await gatePrefs.save(sharedPrefs, state: state);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PermissionsSheet(
        initialState: state,
        prefs: gatePrefs,
        sharedPrefs: sharedPrefs,
      ),
    );
  }

  /// Requests notification permission with a short rationale dialog.
  static Future<bool> ensureNotificationPermission(
    BuildContext context, {
    SharedPreferences? prefs,
  }) async {
    if (!Platform.isAndroid) return true;
    final sharedPrefs = prefs ?? await SharedPreferences.getInstance();
    final gatePrefs = await _GatePrefs.load(sharedPrefs);
    gatePrefs.askedPostNotifications = true;
    final status = await Permission.notification.status;
    if (status.isGranted) {
      gatePrefs.cachedNotificationsGranted = true;
      await gatePrefs.save(sharedPrefs);
      return true;
    }

    final proceed = await _confirmDialog(
      context,
      title: 'Allow notifications',
      message: 'Pushstr shows an ongoing status notification for background sync. Allow to keep it visible and reliable.',
      approveLabel: 'Allow',
    );
    if (proceed != true) {
      await gatePrefs.save(sharedPrefs);
      return false;
    }

    final req = await Permission.notification.request();
    gatePrefs.cachedNotificationsGranted = req.isGranted;
    await gatePrefs.save(sharedPrefs);
    if (req.isPermanentlyDenied) {
      await openAppSettings();
    }
    return req.isGranted;
  }

  static Future<bool?> _confirmDialog(
    BuildContext context, {
    required String title,
    required String message,
    String approveLabel = 'OK',
    String cancelLabel = 'Not now',
  }) async {
    if (!context.mounted) return false;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(approveLabel),
          ),
        ],
      ),
    );
  }
}

class _GateState {
  final int sdkInt;
  final bool notificationGranted;
  final bool notificationPermanentlyDenied;
  final bool batteryExempt;
  final String manufacturer;

  const _GateState._({
    required this.sdkInt,
    required this.notificationGranted,
    required this.notificationPermanentlyDenied,
    required this.batteryExempt,
    required this.manufacturer,
  });

  bool get needsNotificationPermission => sdkInt >= 33 && !notificationGranted;

  bool get needsBatteryExemption => sdkInt >= 23 && !batteryExempt;

  bool get showOemGuidance =>
      manufacturer.isNotEmpty &&
      (_oemVendors.contains(manufacturer) ||
          _oemVendors.any((vendor) => manufacturer.contains(vendor)));

  String get oemDisplayName =>
      manufacturer.isEmpty ? 'Device' : '${manufacturer[0].toUpperCase()}${manufacturer.substring(1)}';

  static Future<_GateState> load() async {
    if (!Platform.isAndroid) {
      return const _GateState._(
        sdkInt: 0,
        notificationGranted: true,
        notificationPermanentlyDenied: false,
        batteryExempt: true,
        manufacturer: '',
      );
    }

    final info = await DeviceInfoPlugin().androidInfo;
    final notifStatus = await Permission.notification.status;
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    final manufacturer = (info.manufacturer ?? '').toLowerCase();

    return _GateState._(
      sdkInt: info.version.sdkInt,
      notificationGranted: notifStatus.isGranted,
      notificationPermanentlyDenied: notifStatus.isPermanentlyDenied || notifStatus.isRestricted,
      batteryExempt: batteryStatus.isGranted,
      manufacturer: manufacturer,
    );
  }
}

class _PermissionsSheet extends StatefulWidget {
  final _GateState initialState;
  final _GatePrefs prefs;
  final SharedPreferences sharedPrefs;

  const _PermissionsSheet({
    required this.initialState,
    required this.prefs,
    required this.sharedPrefs,
  });

  @override
  State<_PermissionsSheet> createState() => _PermissionsSheetState();
}

class _PermissionsSheetState extends State<_PermissionsSheet> {
  late bool _notifGranted;
  late bool _batteryExempt;

  @override
  void initState() {
    super.initState();
    _notifGranted = !widget.initialState.needsNotificationPermission;
    _batteryExempt = !widget.initialState.needsBatteryExemption;
  }

  @override
  Widget build(BuildContext context) {
    final needsNotif = widget.initialState.needsNotificationPermission;
    final needsBattery = widget.initialState.needsBatteryExemption;
    final showOem = widget.initialState.showOemGuidance;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Keep Pushstr running',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (needsNotif)
              _PermissionTile(
                title: 'Allow notifications',
                subtitle:
                    'Needed so the foreground service can show its ongoing status icon.',
                actionLabel: _notifGranted ? 'Allowed' : 'Allow',
                done: _notifGranted,
                onTap: _notifGranted
                    ? null
                    : () async {
                        final granted =
                            await PermissionsGate.ensureNotificationPermission(context, prefs: widget.sharedPrefs);
                        if (mounted && granted) {
                          setState(() => _notifGranted = true);
                          widget.prefs.cachedNotificationsGranted = true;
                          await widget.prefs.save(widget.sharedPrefs, state: widget.initialState);
                        }
                      },
              ),
            if (needsBattery)
              _PermissionTile(
                title: 'Battery optimisation',
                subtitle: 'Let Pushstr ignore Doze so Android does not stop background sync.',
                actionLabel: _batteryExempt ? 'Allowed' : 'Allow',
                done: _batteryExempt,
                onTap: _batteryExempt
                    ? null
                    : () async {
                        final granted = await _requestBatteryExemption();
                        if (mounted && granted) {
                          setState(() => _batteryExempt = true);
                          widget.prefs.cachedBatteryExempt = true;
                          await widget.prefs.save(widget.sharedPrefs, state: widget.initialState);
                        }
                      },
              ),
            if (showOem)
              _PermissionTile(
                title: '${widget.initialState.oemDisplayName} auto-start (optional)',
                subtitle:
                    'Enable Auto-start / background run so OEM restrictions do not kill Pushstr.',
                actionLabel: 'Open settings',
                optional: true,
                onTap: () async {
                  await _openAutoStartSettings();
                },
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _requestBatteryExemption() async {
    final currentStatus = await Permission.ignoreBatteryOptimizations.status;
    if (currentStatus.isGranted) return true;

    final proceed = await PermissionsGate._confirmDialog(
      context,
      title: 'Allow background running',
      message: 'Allow Pushstr to ignore battery optimisations to reduce the OS killing background sync.',
      approveLabel: 'Allow',
    );
    if (proceed != true) return false;

    final req = await Permission.ignoreBatteryOptimizations.request();
    if (req.isPermanentlyDenied || req.isRestricted) {
      // Best effort: send the user to app settings where battery usage can be set to Unrestricted.
      await openAppSettings();
    }
    return req.isGranted;
  }

  Future<void> _openAutoStartSettings() async {
    try {
      final ok = await _permissionsChannel.invokeMethod<bool>('openAutoStartSettings');
      if (ok != true) {
        await openAppSettings();
      }
    } catch (_) {
      await openAppSettings();
    }
  }
}

class _GatePrefs {
  bool askedPostNotifications;
  bool cachedNotificationsGranted;
  bool askedBatteryOpt;
  bool cachedBatteryExempt;
  String oemGuidanceShownFor;
  int version;

  _GatePrefs({
    required this.askedPostNotifications,
    required this.cachedNotificationsGranted,
    required this.askedBatteryOpt,
    required this.cachedBatteryExempt,
    required this.oemGuidanceShownFor,
    required this.version,
  });

  static Future<_GatePrefs> load(SharedPreferences prefs) async {
    final storedVersion = prefs.getInt('permissions_gate_version') ?? 0;
    if (storedVersion != PermissionsGate._gateVersion) {
      return _GatePrefs(
        askedPostNotifications: false,
        cachedNotificationsGranted: false,
        askedBatteryOpt: false,
        cachedBatteryExempt: false,
        oemGuidanceShownFor: '',
        version: PermissionsGate._gateVersion,
      );
    }
    return _GatePrefs(
      askedPostNotifications: prefs.getBool('permissions_gate_asked_notif') ?? false,
      cachedNotificationsGranted: prefs.getBool('permissions_gate_cached_notif') ?? false,
      askedBatteryOpt: prefs.getBool('permissions_gate_asked_battery') ?? false,
      cachedBatteryExempt: prefs.getBool('permissions_gate_cached_battery') ?? false,
      oemGuidanceShownFor: prefs.getString('permissions_gate_oem_shown') ?? '',
      version: storedVersion,
    );
  }

  Future<void> save(
    SharedPreferences prefs, {
    _GateState? state,
  }) async {
    if (state != null) {
      cachedNotificationsGranted = state.notificationGranted;
      cachedBatteryExempt = state.batteryExempt;
    }
    await prefs.setInt('permissions_gate_version', PermissionsGate._gateVersion);
    await prefs.setBool('permissions_gate_asked_notif', askedPostNotifications);
    await prefs.setBool('permissions_gate_cached_notif', cachedNotificationsGranted);
    await prefs.setBool('permissions_gate_asked_battery', askedBatteryOpt);
    await prefs.setBool('permissions_gate_cached_battery', cachedBatteryExempt);
    await prefs.setString('permissions_gate_oem_shown', oemGuidanceShownFor);
  }
}

class _PermissionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String actionLabel;
  final bool done;
  final bool optional;
  final VoidCallback? onTap;

  const _PermissionTile({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    this.done = false,
    this.optional = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = Colors.white.withOpacity(0.05);
    final border = Colors.white.withOpacity(0.08);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    if (optional)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Recommended',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    if (done)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            child: Text(done ? 'Done' : actionLabel),
          ),
        ],
      ),
    );
  }
}

const Set<String> _oemVendors = {
  'xiaomi',
  'redmi',
  'poco',
  'oppo',
  'realme',
  'oneplus',
  'vivo',
  'samsung',
  'huawei',
  'honor',
};
