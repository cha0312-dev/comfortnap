import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// =====================================================================
// BEDTIME REMINDER — shared notification bits
// =====================================================================
const String bedtimePayload = "bedtime";
const String bedtimeStartAction = "bedtime_start";
const String bedtimeSnoozeAction = "bedtime_snooze";
const int bedtimeSnoozeId = 8999;

/// Look of the bedtime reminder notification (with its two buttons).
NotificationDetails bedtimeNotificationDetails() => const NotificationDetails(
  android: AndroidNotificationDetails(
    'comfortnap_bedtime',
    'Bedtime reminder',
    channelDescription: 'A gentle nudge before your bedtime',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
    actions: <AndroidNotificationAction>[
      AndroidNotificationAction(
        bedtimeStartAction,
        'Start wind-down',
        showsUserInterface: true,
      ),
      AndroidNotificationAction(
        bedtimeSnoozeAction,
        'Snooze 10 min',
        showsUserInterface: false,
      ),
    ],
  ),
);

/// Schedules a one-off notification at [when]. Uses an exact alarm when
/// allowed, otherwise falls back to an inexact one (may be a little late).
Future<void> scheduleExactOrInexact(
  FlutterLocalNotificationsPlugin plugin, {
  required int id,
  required String title,
  required String body,
  required DateTime when,
  required NotificationDetails details,
  required String payload,
}) async {
  final at = tz.TZDateTime.from(when.toUtc(), tz.UTC);
  try {
    await plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  } catch (_) {
    await plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }
}

/// "Snooze 10 min" on the bedtime notification.
Future<void> scheduleBedtimeSnooze(FlutterLocalNotificationsPlugin plugin) =>
    scheduleExactOrInexact(
      plugin,
      id: bedtimeSnoozeId,
      title: '🌙 Bedtime reminder',
      body: 'Snoozed 10 minutes. Time to start winding down.',
      when: DateTime.now().add(const Duration(minutes: 10)),
      details: bedtimeNotificationDetails(),
      payload: bedtimePayload,
    );

/// Runs when a notification button is pressed while the app is closed.
@pragma('vm:entry-point')
Future<void> notificationBackgroundResponse(NotificationResponse r) async {
  if (r.payload != bedtimePayload || r.actionId != bedtimeSnoozeAction) return;
  DartPluginRegistrant.ensureInitialized();
  tzdata.initializeTimeZones();
  await scheduleBedtimeSnooze(FlutterLocalNotificationsPlugin());
}

/// Wake-up alarm handed to Android itself, so it rings at the exact time
/// even if the phone is locked or ComfortNap is closed.
///
/// It only plays the phone's alarm ringtone — it never turns on the
/// pillow's vibration or heat.
class AlarmService {
  AlarmService._();
  static final AlarmService instance = AlarmService._();

  static const int _alarmId = 7001;
  static const String _payload = "wake_alarm";

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Increments every time the user taps the alarm notification while the
  /// app is running. main.dart listens to show the Good Morning screen.
  final ValueNotifier<int> tapped = ValueNotifier<int>(0);

  /// Increments when the bedtime reminder (or its "Start wind-down" button)
  /// is tapped while the app is running.
  final ValueNotifier<int> bedtimeTapped = ValueNotifier<int>(0);

  /// The shared notifications plugin (used by the bedtime reminder too).
  FlutterLocalNotificationsPlugin get plugin => _plugin;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == _payload) {
          tapped.value++;
        } else if (response.payload == bedtimePayload) {
          if (response.actionId == bedtimeSnoozeAction) {
            scheduleBedtimeSnooze(_plugin);
          } else {
            bedtimeTapped.value++;
          }
        }
      },
      onDidReceiveBackgroundNotificationResponse:
          notificationBackgroundResponse,
    );
    _ready = true;
  }

  /// True when the app was opened by tapping the alarm notification.
  Future<bool> launchedFromAlarm() async {
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.didNotificationLaunchApp == true &&
        details?.notificationResponse?.payload == _payload;
  }

  /// True when the app was opened from the bedtime reminder.
  Future<bool> launchedFromBedtime() async {
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    final r = details?.notificationResponse;
    return details?.didNotificationLaunchApp == true &&
        r?.payload == bedtimePayload &&
        r?.actionId != bedtimeSnoozeAction;
  }

  /// Asks for notification + exact-alarm permission (Android 13+ / 12+).
  Future<bool> requestPermissions() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return true;
    final notifications = await android.requestNotificationsPermission();
    final exact = await android.requestExactAlarmsPermission();
    return (notifications ?? true) && (exact ?? true);
  }

  /// Schedules (or reschedules) the wake-up alarm.
  Future<void> schedule(DateTime when) async {
    await init();
    await requestPermissions();
    await cancel();

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'comfortnap_wake_alarm',
        'Wake-up alarm',
        channelDescription: 'Rings when it is time to wake up',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        visibility: NotificationVisibility.public,
        // The phone's own alarm ringtone, played on the alarm volume.
        playSound: true,
        sound: const UriAndroidNotificationSound(
          'content://settings/system/alarm_alert',
        ),
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        // FLAG_INSISTENT: keep ringing until the alarm is stopped.
        additionalFlags: Int32List.fromList(<int>[4]),
        ongoing: true,
        autoCancel: false,
      ),
    );

    await _plugin.zonedSchedule(
      _alarmId,
      '⏰ Time to wake up',
      'Good morning! Tap to stop the alarm.',
      tz.TZDateTime.from(when.toUtc(), tz.UTC),
      details,
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: _payload,
    );
  }

  /// Stops a ringing alarm and/or removes a scheduled one.
  Future<void> cancel() async {
    try {
      await _plugin.cancel(_alarmId);
    } catch (e) {
      debugPrint("ALARM CANCEL ERROR: $e");
    }
  }
}

// =====================================================================
// GOOD MORNING SCREEN
// =====================================================================

/// What the user chose on the Good Morning screen.
enum AlarmAction { awake, snooze }

/// Full-screen sunrise page shown while the alarm rings.
class GoodMorningScreen extends StatefulWidget {
  final int snoozeMinutes;
  const GoodMorningScreen({super.key, this.snoozeMinutes = 5});

  @override
  State<GoodMorningScreen> createState() => _GoodMorningScreenState();
}

class _GoodMorningScreenState extends State<GoodMorningScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  late Timer _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    _glow.dispose();
    super.dispose();
  }

  void _finish(AlarmAction action) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFB547);
    const coral = Color(0xFFFF7E5F);
    const sky = Color(0xFF6B5BFF);

    return PopScope(
      canPop: false, // must choose Awake or Snooze
      child: Scaffold(
        backgroundColor: const Color(0xFF07031F),
        body: Stack(
          children: [
            // Sunrise glow
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _glow,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_glow.value);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, 1.1),
                        radius: 1.2 + .15 * t,
                        colors: [
                          amber.withValues(alpha: .55 + .15 * t),
                          coral.withValues(alpha: .35),
                          sky.withValues(alpha: .25),
                          const Color(0xFF07031F),
                        ],
                        stops: const [0, .35, .65, 1],
                      ),
                    ),
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  children: [
                    const Spacer(),
                    // Pulsing sun
                    AnimatedBuilder(
                      animation: _glow,
                      builder: (context, child) => Transform.scale(
                        scale: 1 + .06 * math.sin(_glow.value * math.pi),
                        child: child,
                      ),
                      child: Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [amber, coral],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: amber.withValues(alpha: .6),
                              blurRadius: 50,
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.wb_sunny_rounded,
                          color: Colors.white,
                          size: 56,
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Text(
                      DateFormat('h:mm').format(_now),
                      style: GoogleFonts.outfit(
                        fontSize: 76,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1,
                      ),
                    ),
                    Text(
                      DateFormat('a · EEEE, MMM d').format(_now),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .7),
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      "Good morning!",
                      style: GoogleFonts.outfit(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Time to wake up. Your pillow is off.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .65),
                        fontSize: 14,
                      ),
                    ),
                    const Spacer(),
                    // I'm awake
                    SizedBox(
                      width: double.infinity,
                      height: 60,
                      child: Material(
                        color: Colors.transparent,
                        child: Ink(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [amber, coral],
                            ),
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: amber.withValues(alpha: .5),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(22),
                            onTap: () => _finish(AlarmAction.awake),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  "I'm awake",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Snooze
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: Material(
                        color: Colors.transparent,
                        child: Ink(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: .18),
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => _finish(AlarmAction.snooze),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.snooze_rounded,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  "Snooze ${widget.snoozeMinutes} min",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
