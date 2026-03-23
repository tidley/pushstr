import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();
bool _notificationsInitialized = false;
Future<void>? _notificationsInitInFlight;

const AndroidNotificationChannel dmChannel = AndroidNotificationChannel(
  'pushstr_dms',
  'Direct Messages',
  description: 'Incoming Pushstr DMs',
  importance: Importance.high,
);

Future<void> initLocalNotifications() async {
  if (_notificationsInitialized) return;
  if (_notificationsInitInFlight != null) {
    await _notificationsInitInFlight;
    return;
  }
  final initFuture = _initLocalNotifications();
  _notificationsInitInFlight = initFuture;
  try {
    await initFuture;
  } finally {
    _notificationsInitInFlight = null;
  }
}

Future<void> _initLocalNotifications() async {
  if (_notificationsInitialized) return;
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const linuxInit = LinuxInitializationSettings(
    defaultActionName: 'Open notification',
  );
  final initSettings = InitializationSettings(
    android: androidInit,
    linux: Platform.isLinux ? linuxInit : null,
  );
  await localNotifications.initialize(initSettings);
  _notificationsInitialized = true;
  await ensureDmChannel();
}

Future<void> ensureDmChannel() async {
  if (!_notificationsInitialized) {
    await initLocalNotifications();
  }
  if (Platform.isLinux) return;
  final androidPlugin =
      localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(dmChannel);
}

Future<void> showDmNotification({
  required String title,
  required String body,
}) async {
  await ensureDmChannel();
  final androidDetails = AndroidNotificationDetails(
    dmChannel.id,
    dmChannel.name,
    channelDescription: dmChannel.description,
    importance: Importance.high,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    category: AndroidNotificationCategory.message,
    groupKey: 'pushstr_dm_group',
    icon: '@mipmap/ic_launcher',
  );
  final linuxDetails = Platform.isLinux
      ? const LinuxNotificationDetails(defaultActionName: 'Open notification')
      : null;
  final details = NotificationDetails(
    android: androidDetails,
    linux: linuxDetails,
  );
  await localNotifications.show(
    DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    title,
    body,
    details,
  );
}
