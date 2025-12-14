import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();
bool _notificationsInitialized = false;

const AndroidNotificationChannel dmChannel = AndroidNotificationChannel(
  'pushstr_dms',
  'Direct Messages',
  description: 'Incoming Pushstr DMs',
  importance: Importance.high,
);

Future<void> initLocalNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await localNotifications.initialize(initSettings);
  _notificationsInitialized = true;
  await ensureDmChannel();
}

Future<void> ensureDmChannel() async {
  if (!_notificationsInitialized) {
    await initLocalNotifications();
  }
  final androidPlugin =
      localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(dmChannel);
}

Future<void> showDmNotification({
  required String title,
  required String body,
}) async {
  await ensureDmChannel();
  final sender = Person(name: title);
  final style = MessagingStyleInformation(
    sender,
    groupConversation: true,
    messages: [
      Message(body, DateTime.now(), sender),
    ],
  );
  final androidDetails = AndroidNotificationDetails(
    'pushstr_dms',
    'Direct Messages',
    channelDescription: 'Incoming Pushstr DMs',
    importance: Importance.high,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    category: AndroidNotificationCategory.message,
    groupKey: 'pushstr_dm_group',
    styleInformation: style,
  );
  final details = NotificationDetails(android: androidDetails);
  await localNotifications.show(
    DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    title,
    body,
    details,
  );
}
