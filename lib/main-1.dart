import 'package:esp32_ble_app/ble.dart';
import 'package:esp32_ble_app/ble_man.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:esp32_ble_app/SetTimerScreen.dart';
import 'package:esp32_ble_app/sound.dart';
import 'package:esp32_ble_app/data.dart';
import 'package:esp32_ble_app/alarm_service.dart';
import 'package:esp32_ble_app/sleep_sound_service.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/services.dart';
// ===== FIREBASE =====
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ====================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Sleep sounds: keep playing with the screen off + lock-screen controls.
  await initSleepSound();

  // Wake-up alarm (rings via Android even if the app is closed).
  try {
    await AlarmService.instance.init();
  } catch (e) {
    print("ALARM INIT ERROR: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ComfortNap',
      theme: ThemeData(
        textTheme: GoogleFonts.poppinsTextTheme(Theme.of(context).textTheme),
      ),
      home: const ComfortNapScreen(),
    );
  }
}

class ComfortNapScreen extends StatefulWidget {
  const ComfortNapScreen({super.key});

  @override
  State<ComfortNapScreen> createState() => _ComfortNapScreenState();
}

class _ComfortNapScreenState extends State<ComfortNapScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  double vibrationLevel = 0.6;
  double heatLevel = 50.0;
  double pillowTemperature = 0.0;
  bool hasPillowTemperature = false;
  double musicVolume = 0.6;

  static const List<double> _heatLevels = [0.0, 25.0, 50.0, 75.0, 100.0];

  double _snapHeatLevel(double value) {
    double closest = _heatLevels.first;

    for (final level in _heatLevels.skip(1)) {
      if ((value - level).abs() < (value - closest).abs()) {
        closest = level;
      }
    }

    return closest;
  }

  bool bleConnected = false;

  // ===== SESSION TIMER =====
  DateTime? sessionStartTime;
  String? sessionDocId;
  String? activeSessionDocId;
  double currentSessionLevel = 0.5;
  bool isSessionRunning = false;
  bool _heaterSafetyFaultActive = false;
  int? selectedSessionDurationSeconds;
  int? _remainingSessionSeconds;
  Timer? sessionCountdownTimer;
  Timer? _extensionResponseTimer;
  bool _isAwaitingExtensionResponse = false;
  bool _isStoppingSession = false;

  // ===== SLEEP TRACKING =====
  // Sleep is only counted after the session ends without an extension
  // (user taps "No" or the 10-second extend prompt times out).
  DateTime? _sleepStartTime;
  Timer? _sleepTicker;

  // ===== WAKE-UP ALARM =====
  // Rings the phone at this time (pillow stays off). Set on the timer page.
  DateTime? _wakeAlarmTime;
  Timer? _alarmTimer; // in-app backup so the Good Morning screen pops up
  bool _alarmRinging = false;
  static const int _snoozeMinutes = 5;
  OverlayEntry? _sessionNoticeEntry;

  // ===== AUDIO =====
  // Sleep sound player lives in a background media service
  // (see sleep_sound_service.dart) so it survives the screen turning off.
  AudioPlayer get _audioPlayer => sleepSound.player;
  StreamSubscription<PlayerState>? _playerStateSub;
  String? selectedSoundLabel;
  String? selectedSoundFile;

  // ===== FIREBASE =====
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref("ble_status");

  @override
  void initState() {
    super.initState();

    // Sleep sounds loop seamlessly until paused, Wake, or the alarm.
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
    // Keep the play/pause button in sync when paused from the lock screen.
    _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((_) {
      if (mounted) setState(() {});
    });

    // ================= BLE STATUS =================
    // ================= WAKE-UP ALARM =================
    AlarmService.instance.tapped.addListener(_onAlarmRing);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await AlarmService.instance.launchedFromAlarm()) {
        _onAlarmRing();
      }
    });

    BLEManager.instance.connectionStream.listen((isConnected) {
      if (mounted) {
        setState(() {
          bleConnected = isConnected;
        });
      }
    });

    // ================= PILLOW TEMP STREAM =================
    BLEManager.instance.temperatureStream.listen((temp) {
      if (mounted) {
        setState(() {
          pillowTemperature = temp;
          hasPillowTemperature = true;
        });
      }
    });

    BLEManager.instance.heaterSafetyStream.listen((fault) {
      if (!mounted) return;

      if (fault == "CLEARED") {
        setState(() {
          _heaterSafetyFaultActive = false;
        });
        _showSessionMessageSnackBar(
          "Heat pad is cool and the temperature sensor is working. Start a new session to use heat.",
        );
        return;
      }

      setState(() {
        _heaterSafetyFaultActive = true;
      });

      final message = switch (fault) {
        "OVER_TEMPERATURE" =>
          "Heat pad overheated. Heating is off until it cools below 45°C.",
        "SENSOR_ERROR" =>
          "Heat pad temperature sensor error. Heating is off until safe readings return.",
        _ => "Heat pad safety fault. Heating is off while the fault is active.",
      };
      _showSessionMessageSnackBar(message);

      if (activeSessionDocId != null) {
        unawaited(_stopSession());
      }
    });

    // ================= SLEEP STREAM =================
    BLEManager.instance.sleepStream.listen((msg) {
      try {
        final data = msg.replaceFirst("SLEEP:", "").split(",");

        final start = int.parse(data[0]);
        final end = int.parse(data[1]);
        final duration = int.parse(data[2]);

        // ✅ CONVERT HERE (THIS IS WHERE YOU PUT IT)
        final startDate = DateTime.fromMillisecondsSinceEpoch(start);
        final endDate = DateTime.fromMillisecondsSinceEpoch(end);

        FirebaseFirestore.instance.collection("vibrator_logs").add({
          "type": "sleep",
          "sleep_start": Timestamp.fromDate(startDate),
          "sleep_end": Timestamp.fromDate(endDate),
          "sleep_duration_minutes": duration,
          "status": "completed",
          "timestamp": FieldValue.serverTimestamp(),
        });

        print("SLEEP SAVED");
      } catch (e) {
        print("SLEEP ERROR: $e");
      }
    });
  }

  Future<void> saveSleepSession({DateTime? endTimeOverride}) async {
    // Sleep starts when the session ended without an extension.
    final sleepStart = _sleepStartTime;
    if (sleepStart == null) return;

    final endTime = endTimeOverride ?? DateTime.now();
    final durationSeconds = endTime.difference(sleepStart).inSeconds;
    final safeDurationSeconds = durationSeconds <= 0 ? 1 : durationSeconds;
    final durationMinutes = ((safeDurationSeconds + 59) ~/ 60);

    await FirebaseFirestore.instance.collection("vibrator_logs").add({
      "type": "sleep",
      "session_doc_id": activeSessionDocId,
      "sleep_start": Timestamp.fromDate(sleepStart),
      "session_start": Timestamp.fromDate(sessionStartTime ?? sleepStart),
      "sleep_end": Timestamp.fromDate(endTime),
      "sleep_duration_seconds": safeDurationSeconds,

      // Must match "sleep_duration_minutes" — that's the field every
      // reader (MonthlySleepScreen, data.dart's buildSleepCard) looks for.
      "sleep_duration_minutes": durationMinutes,
      "timer_duration_seconds": selectedSessionDurationSeconds ?? 0,
      "timer_remaining_seconds_at_wake":
          _remainingSessionSeconds ?? selectedSessionDurationSeconds ?? 0,
      "status": "completed",
      "timestamp": FieldValue.serverTimestamp(),
    });
  }

  Future<void> endCurrentSession() async {
    if (activeSessionDocId == null || sessionStartTime == null) {
      return;
    }

    final endTime = DateTime.now();

    final duration = endTime.difference(sessionStartTime!).inSeconds;

    await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .doc(activeSessionDocId)
        .update({
          "status": "ended",
          "end_time": Timestamp.fromDate(endTime),
          "duration": duration,
          "final_vibration_level": (currentSessionLevel * 100).round(),
          "final_heat_level": heatLevel.round(),
          if (hasPillowTemperature)
            "final_pillow_temperature": pillowTemperature,
        });

    activeSessionDocId = null;
  }

  void _showSessionMessageSnackBar(String message) {
    _showCenterSessionNotice(message: message);
  }

  void _showStopSessionConfirmation() {
    _showCenterSessionNotice(
      message: "Stopping session?",
      onOkay: _stopSession,
      showCancel: true,
    );
  }

  void _showCenterSessionNotice({
    required String message,
    Future<void> Function()? onOkay,
    bool showCancel = false,
    Future<void> Function()? onYes,
    Future<void> Function()? onNo,
  }) {
    _dismissSessionNotice();

    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Material(
        color: Colors.black54,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Center(
            child: Container(
              width: (MediaQuery.sizeOf(context).width - 48)
                  .clamp(0, 360)
                  .toDouble(),
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
              decoration: BoxDecoration(
                color: _surface.withValues(alpha: .96),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: _white(.12)),
                boxShadow: [
                  BoxShadow(
                    color: _violet.withValues(alpha: .3),
                    blurRadius: 40,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: _mainGradient,
                      boxShadow: [
                        BoxShadow(
                          color: _violet.withValues(alpha: .5),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: Icon(
                      showCancel || onYes != null
                          ? Icons.help_outline_rounded
                          : Icons.check_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (onYes != null && onNo != null) ...[
                        Expanded(
                          child: _PillButton(
                            label: "No",
                            height: 46,
                            onTap: () async {
                              _dismissSessionNotice();
                              await onNo();
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PillButton(
                            label: "Yes",
                            gradient: _mainGradient,
                            height: 46,
                            onTap: () async {
                              _dismissSessionNotice();
                              await onYes();
                            },
                          ),
                        ),
                      ] else ...[
                        if (showCancel) ...[
                          Expanded(
                            child: _PillButton(
                              label: "Cancel",
                              height: 46,
                              onTap: _dismissSessionNotice,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: _PillButton(
                            label: "Okay",
                            gradient: _mainGradient,
                            height: 46,
                            onTap: () async {
                              _dismissSessionNotice();
                              await onOkay?.call();
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    _sessionNoticeEntry = entry;
    overlay.insert(entry);
  }

  void _dismissSessionNotice() {
    final entry = _sessionNoticeEntry;
    _sessionNoticeEntry = null;
    if (entry != null) {
      entry.remove();
      entry.dispose();
    }
  }

  Future<void> _stopSession() async {
    if (activeSessionDocId == null ||
        sessionStartTime == null ||
        _isStoppingSession) {
      return;
    }

    _isStoppingSession = true;
    sessionCountdownTimer?.cancel();
    _extensionResponseTimer?.cancel();
    _extensionResponseTimer = null;
    _isAwaitingExtensionResponse = false;
    _dismissSessionNotice();
    try {
      await BLEManager.instance.send("OFF");
      await BLEManager.instance.send("HEAT:0");

      final endTime = DateTime.now();
      final duration = endTime.difference(sessionStartTime!).inSeconds;

      await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .doc(activeSessionDocId)
          .update({
            "status": "ended",
            "end_time": Timestamp.fromDate(endTime),
            "duration": duration,
            "final_vibration_level": (currentSessionLevel * 100).round(),
            "final_heat_level": heatLevel.round(),
            if (hasPillowTemperature)
              "final_pillow_temperature": pillowTemperature,
          });

      activeSessionDocId = null;
      _clearSleepTracking();
      unawaited(_disarmAlarm());

      if (mounted) {
        setState(() {
          isSessionRunning = false;
          _remainingSessionSeconds = selectedSessionDurationSeconds;
        });
      }
    } finally {
      _isStoppingSession = false;
    }
  }

  void _startSessionCountdown() {
    sessionCountdownTimer?.cancel();
    final duration = selectedSessionDurationSeconds;
    _remainingSessionSeconds = duration;
    if (duration == null) return;

    sessionCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !isSessionRunning) {
        timer.cancel();
        return;
      }

      final remaining = _remainingSessionSeconds ?? 0;
      if (remaining <= 1) {
        timer.cancel();
        setState(() {
          _remainingSessionSeconds = 0;
        });
        _askToExtendSession();
        return;
      }

      setState(() {
        _remainingSessionSeconds = remaining - 1;
      });
    });
  }

  void _beginSleepTracking() {
    if (_sleepStartTime != null) return;

    final sleepStart = DateTime.now();
    _sleepStartTime = sleepStart;

    // Refresh the "asleep for" clock on screen every second.
    _sleepTicker?.cancel();
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    final docId = activeSessionDocId;
    if (docId != null) {
      unawaited(
        FirebaseFirestore.instance
            .collection("vibrator_logs")
            .doc(docId)
            .update({
              "sleep_start_time": Timestamp.fromDate(sleepStart),
              "session_end_time": Timestamp.fromDate(sleepStart),
            })
            .catchError((e) {
              print("SLEEP START SAVE ERROR: $e");
            }),
      );
    }
  }

  void _clearSleepTracking() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepStartTime = null;
  }

  Future<void> _stopHardwareWithoutEndingSession() async {
    if (!isSessionRunning) return;

    sessionCountdownTimer?.cancel();
    _extensionResponseTimer?.cancel();
    _extensionResponseTimer = null;
    _isAwaitingExtensionResponse = false;
    _dismissSessionNotice();

    try {
      await BLEManager.instance.send("OFF");
      await BLEManager.instance.send("HEAT:0");
    } catch (_) {}

    _beginSleepTracking();

    if (mounted) {
      setState(() {
        _remainingSessionSeconds = 0;
      });
    }
  }

  void _askToExtendSession() {
    if (_isAwaitingExtensionResponse || !isSessionRunning) return;

    _isAwaitingExtensionResponse = true;
    _showCenterSessionNotice(
      message: "Do you want to extend your session? You have 10 seconds.",
      onYes: () => _respondToExtension(extend: true),
      onNo: () => _respondToExtension(extend: false),
    );
    _extensionResponseTimer?.cancel();
    _extensionResponseTimer = Timer(const Duration(seconds: 10), () async {
      _isAwaitingExtensionResponse = false;
      _extensionResponseTimer = null;
      _dismissSessionNotice();

      if (mounted && isSessionRunning) {
        await _stopHardwareWithoutEndingSession();
        _showSessionMessageSnackBar(
          "Session ended. Heat and vibration are off and sleep tracking has started. Press Wake when you are awake.",
        );
      }
    });
  }

  Future<void> _respondToExtension({required bool extend}) async {
    if (!_isAwaitingExtensionResponse) return;

    _isAwaitingExtensionResponse = false;
    _extensionResponseTimer?.cancel();
    _extensionResponseTimer = null;

    if (extend && isSessionRunning) {
      final duration = selectedSessionDurationSeconds;
      if (duration == null) {
        await _stopHardwareWithoutEndingSession();
        if (mounted) {
          _showSessionMessageSnackBar(
            "Session ended. Heat and vibration are off and sleep tracking has started. Press Wake when you are awake.",
          );
        }
        return;
      }

      setState(() {
        _remainingSessionSeconds = duration;
      });
      _startSessionCountdown();
      _showSessionMessageSnackBar("Session extended");
      return;
    }

    await _stopHardwareWithoutEndingSession();
    if (mounted) {
      _showSessionMessageSnackBar(
        "Session ended. Heat and vibration are off and sleep tracking has started. Press Wake when you are awake.",
      );
    }
  }

  // ===================================================================
  // WAKE-UP ALARM
  // ===================================================================
  String _clockText(DateTime t) => DateFormat('h:mm a').format(t);

  /// Schedules the phone alarm (Android) plus an in-app timer that opens
  /// the Good Morning screen if the app is open when it rings.
  Future<void> _armAlarm() async {
    final when = _wakeAlarmTime;
    _alarmTimer?.cancel();
    if (when == null || !when.isAfter(DateTime.now())) return;

    try {
      await AlarmService.instance.schedule(when);
    } catch (e) {
      print("ALARM SCHEDULE ERROR: $e");
      _showSessionMessageSnackBar(
        "Couldn't set the wake-up alarm. Allow notifications and alarms for ComfortNap in Settings.",
      );
      return;
    }
    _alarmTimer = Timer(when.difference(DateTime.now()), _onAlarmRing);
  }

  Future<void> _disarmAlarm() async {
    _alarmTimer?.cancel();
    _alarmTimer = null;
    await AlarmService.instance.cancel();
    if (mounted) setState(() => _wakeAlarmTime = null);
  }

  /// Alarm time reached (or the user tapped the alarm notification).
  Future<void> _onAlarmRing() async {
    if (_alarmRinging || !mounted) return;
    _alarmRinging = true;
    _alarmTimer?.cancel();

    // Make sure the pillow is off — the alarm only rings the phone.
    if (isSessionRunning && _sleepStartTime == null) {
      await _stopHardwareWithoutEndingSession();
    } else if (BLEManager.instance.connected) {
      try {
        await BLEManager.instance.send("OFF");
        await BLEManager.instance.send("HEAT:0");
      } catch (_) {}
    }
    if (!mounted) return;

    // Stop the sleep sound so it doesn't play over the alarm.
    try {
      await sleepSound.stop();
    } catch (_) {}
    if (mounted) setState(() {});

    _dismissSessionNotice();
    final action = await Navigator.of(context).push<AlarmAction>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const GoodMorningScreen(snoozeMinutes: _snoozeMinutes),
      ),
    );
    _alarmRinging = false;

    // Stop the ringing notification either way.
    await AlarmService.instance.cancel();

    if (action == AlarmAction.snooze) {
      setState(() {
        _wakeAlarmTime = DateTime.now().add(
          const Duration(minutes: _snoozeMinutes),
        );
      });
      await _armAlarm();
      _showSessionMessageSnackBar(
        "Snoozed. The alarm will ring again at ${_clockText(_wakeAlarmTime!)}.",
      );
      return;
    }

    // "I'm awake": complete the session and record sleep, no extra prompt.
    if (mounted) setState(() => _wakeAlarmTime = null);
    if (activeSessionDocId != null && sessionStartTime != null) {
      await _handleWakeSession(skipConfirm: true);
    } else {
      _showSessionMessageSnackBar("Alarm stopped. Good morning!");
    }
  }

  Future<void> _handleWakeSession({bool skipConfirm = false}) async {
    if (activeSessionDocId == null || sessionStartTime == null) {
      _showSessionMessageSnackBar("No active session");
      return;
    }

    final sleepSoFar = _sleepStartTime == null
        ? null
        : DateTime.now().difference(_sleepStartTime!).inSeconds;

    final confirmed = skipConfirm
        ? true
        : await showDialog<bool>(
            context: context,
            barrierColor: Colors.black54,
            builder: (context) => BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                insetPadding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 380),
                  padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
                  decoration: BoxDecoration(
                    color: _surface.withValues(alpha: .97),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: _white(.12)),
                    boxShadow: [
                      BoxShadow(
                        color: _amber.withValues(alpha: .18),
                        blurRadius: 40,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Sunrise icon
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [_amber, Color(0xFFFF7E5F)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _amber.withValues(alpha: .5),
                              blurRadius: 24,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.wb_sunny_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        "Are you already awake?",
                        textAlign: TextAlign.center,
                        style: _display(22, weight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "This will record your actual wake-up time and complete the session.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _white(.6),
                          fontSize: 13.5,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // What will be recorded
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _white(.06),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: _white(.08)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              sleepSoFar == null
                                  ? Icons.info_outline_rounded
                                  : Icons.bedtime_rounded,
                              color: sleepSoFar == null ? _white(.6) : _magenta,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                sleepSoFar == null
                                    ? "Session still running, so no sleep will be recorded."
                                    : "Sleep so far",
                                style: TextStyle(
                                  color: _white(.75),
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                            if (sleepSoFar != null)
                              Text(
                                _formatSessionDuration(sleepSoFar),
                                style: _display(
                                  16,
                                  weight: FontWeight.w700,
                                  color: _magenta,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _PillButton(
                              label: "Not yet",
                              height: 48,
                              onTap: () => Navigator.of(context).pop(false),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: _PillButton(
                              label: "Yes, I'm awake",
                              icon: Icons.wb_sunny_rounded,
                              gradient: const LinearGradient(
                                colors: [_amber, Color(0xFFFF7E5F)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              height: 48,
                              onTap: () {
                                HapticFeedback.mediumImpact();
                                Navigator.of(context).pop(true);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

    if (confirmed != true) {
      return;
    }

    // Awake now, so the wake-up alarm is no longer needed.
    unawaited(_disarmAlarm());

    // ...and the looping sleep sound can stop too.
    unawaited(sleepSound.stop());

    sessionCountdownTimer?.cancel();
    _extensionResponseTimer?.cancel();
    _extensionResponseTimer = null;
    _isAwaitingExtensionResponse = false;

    final wakeTime = DateTime.now();
    // Sleep only counts from when the session ended without an extension.
    // Waking during the session itself means no sleep was recorded.
    final sleepStart = _sleepStartTime;
    final actualSleepSeconds = sleepStart == null
        ? 0
        : wakeTime.difference(sleepStart).inSeconds;
    final safeActualSleepSeconds = sleepStart == null
        ? 0
        : (actualSleepSeconds <= 0 ? 1 : actualSleepSeconds);
    final sessionSeconds = wakeTime.difference(sessionStartTime!).inSeconds;
    final timerDurationSeconds = selectedSessionDurationSeconds ?? 0;
    final remainingAtWakeSeconds =
        _remainingSessionSeconds ?? selectedSessionDurationSeconds ?? 0;

    try {
      await BLEManager.instance.send("OFF");
      await BLEManager.instance.send("HEAT:0");

      await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .doc(activeSessionDocId)
          .update({
            "status": "completed",
            "wake_time": Timestamp.fromDate(wakeTime),
            "end_time": Timestamp.fromDate(wakeTime),
            "duration": sessionSeconds <= 0 ? 1 : sessionSeconds,
            if (sleepStart != null)
              "sleep_start_time": Timestamp.fromDate(sleepStart),
            "actual_sleep_duration_seconds": safeActualSleepSeconds,
            "actual_sleep_duration_minutes":
                ((safeActualSleepSeconds + 59) ~/ 60),
            "actual_sleep_duration_display": _formatSessionDuration(
              safeActualSleepSeconds,
            ),
            "timer_duration_seconds": timerDurationSeconds,
            "timer_remaining_seconds_at_wake": remainingAtWakeSeconds,
            "timer_remaining_duration_display": _formatSessionDuration(
              remainingAtWakeSeconds,
            ),
            "final_vibration_level": (currentSessionLevel * 100).round(),
            "final_heat_level": heatLevel.round(),
            "final_pillow_temperature": hasPillowTemperature
                ? pillowTemperature
                : null,
            "completed_at": FieldValue.serverTimestamp(),
            "completion_reason": skipConfirm ? "alarm_wake" : "manual_wake",
          });

      await saveSleepSession(endTimeOverride: wakeTime);

      final actualSleepFormatted = _formatSessionDuration(
        safeActualSleepSeconds,
      );

      if (mounted) {
        setState(() {
          isSessionRunning = false;
          _remainingSessionSeconds = remainingAtWakeSeconds;
        });
      }

      _showSessionMessageSnackBar(
        sleepStart == null
            ? "Session completed. No sleep was recorded because you woke before the session ended."
            : "Session completed. Actual sleep: $actualSleepFormatted",
      );
    } catch (error) {
      if (mounted) {
        _showSessionMessageSnackBar("Could not complete session: $error");
      }
      return;
    } finally {
      activeSessionDocId = null;
      sessionStartTime = null;
      _clearSleepTracking();
      _isAwaitingExtensionResponse = false;
      _isStoppingSession = false;
    }
  }

  String _formatSessionDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours.toString().padLeft(2, "0");
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, "0");
    final remainingSeconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, "0");
    return hours == "00"
        ? "$minutes:$remainingSeconds"
        : "$hours:$minutes:$remainingSeconds";
  }

  Future<void> _playSelectedSound() async {
    try {
      await _audioPlayer.stop();

      if (selectedSoundFile != null) {
        // Title shown on the lock screen / notification.
        sleepSound.setSound(selectedSoundLabel ?? "Sleep sound");
        await _audioPlayer.play(AssetSource('sounds/$selectedSoundFile'));

        await _audioPlayer.setVolume(musicVolume);
      }
    } catch (e) {
      print("ERROR PLAYING SOUND: $e");
    }
  }

  @override
  void dispose() {
    sessionCountdownTimer?.cancel();
    _extensionResponseTimer?.cancel();
    _dismissSessionNotice();
    _playerStateSub?.cancel(); // player itself is owned by the media service
    _sleepTicker?.cancel();
    _alarmTimer?.cancel();
    AlarmService.instance.tapped.removeListener(_onAlarmRing);
    _ambient.dispose();
    super.dispose();
  }

  // ===================================================================
  // UI ACTIONS — same logic as before, moved out of build() unchanged
  // ===================================================================
  Future<void> _onVibrationChanged(double val) async {
    setState(() {
      vibrationLevel = val;
      currentSessionLevel = val; // 🔥 store latest
    });

    if (BLEManager.instance.connected) {
      await BLEManager.instance.send("VIB:${(val * 100).round()}");
    }
  }

  Future<void> _onHeatChanged(double val) async {
    final selectedHeat = _snapHeatLevel(val);
    if (selectedHeat != heatLevel) HapticFeedback.selectionClick();
    setState(() {
      heatLevel = selectedHeat;
    });

    if (isSessionRunning && BLEManager.instance.connected) {
      await BLEManager.instance.send("HEAT:${selectedHeat.round()}");
    }
  }

  Future<void> _openTimer() async {
    if (isSessionRunning) {
      _showSessionMessageSnackBar(
        "Stop the current session before changing its timer.",
      );
      return;
    }

    final timerSettings = await Navigator.push<SessionTimerSettings>(
      context,
      MaterialPageRoute(
        builder: (context) => SetTimerScreen(
          initialVibrationLevel: currentSessionLevel,
          initialHeatLevel: heatLevel,
          initialDurationSeconds: selectedSessionDurationSeconds,
          initialWakeAlarm: _wakeAlarmTime,
        ),
      ),
    );
    if (timerSettings != null && mounted) {
      setState(() {
        selectedSessionDurationSeconds = timerSettings.durationSeconds;
        _remainingSessionSeconds = timerSettings.durationSeconds;
        currentSessionLevel = timerSettings.vibrationLevel;
        _wakeAlarmTime = timerSettings.wakeAlarm;
        vibrationLevel = timerSettings.vibrationLevel;
        heatLevel = timerSettings.heatLevel;
      });
    }
  }

  Future<void> _onStartSession() async {
    if (isSessionRunning) return;

    if (selectedSessionDurationSeconds == null) {
      _showSessionMessageSnackBar("Select and save a timer before starting.");
      return;
    }

    if (!bleConnected) {
      _showSessionMessageSnackBar(
        "Connect to the device before starting a session.",
      );
      return;
    }

    if (_heaterSafetyFaultActive) {
      _showSessionMessageSnackBar(
        "Heat pad safety lockout. Wait for the pad to cool and the sensor to report safe readings.",
      );
      return;
    }

    HapticFeedback.mediumImpact();

    String? newSessionDocId;
    try {
      final startTime = DateTime.now();
      final docRef = await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .add({
            "type": "session",
            "status": "running",
            "start_time": Timestamp.fromDate(startTime),
            "vibration_level": (currentSessionLevel * 100).round(),
            "heat_level": heatLevel.round(),
            "timestamp": FieldValue.serverTimestamp(),
          });
      newSessionDocId = docRef.id;

      await BLEManager.instance.send(
        "VIB:${(currentSessionLevel * 100).round()}",
      );
      await BLEManager.instance.send("HEAT:${heatLevel.round()}");
      await BLEManager.instance.send("ON");
      if (_heaterSafetyFaultActive) {
        throw StateError("Heat pad safety lockout detected.");
      }

      sessionStartTime = DateTime.now();
      activeSessionDocId = newSessionDocId;
      _clearSleepTracking();

      setState(() {
        isSessionRunning = true;
      });

      _startSessionCountdown();
      await _armAlarm();
      _showSessionMessageSnackBar(
        _wakeAlarmTime != null && _wakeAlarmTime!.isAfter(DateTime.now())
            ? "Session started. Alarm set for ${_clockText(_wakeAlarmTime!)}."
            : "Session started",
      );

      print("ACTIVE SESSION: $activeSessionDocId");
    } catch (error) {
      await BLEManager.instance.send("OFF");
      await BLEManager.instance.send("HEAT:0");

      if (newSessionDocId != null) {
        await FirebaseFirestore.instance
            .collection("vibrator_logs")
            .doc(newSessionDocId)
            .update({"status": "failed"});
      }

      activeSessionDocId = null;
      if (mounted) {
        _showSessionMessageSnackBar("Session could not start: $error");
      }
    }
  }

  Future<void> _onWake() async {
    if (activeSessionDocId == null || sessionStartTime == null) {
      _showSessionMessageSnackBar("No active session");
      return;
    }

    await _handleWakeSession();
  }

  void _onStop() {
    if (activeSessionDocId == null || sessionStartTime == null) {
      _showSessionMessageSnackBar("No active session");
      return;
    }

    _showStopSessionConfirmation();
  }

  Future<void> _openSounds() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SoundScreen(currentFile: selectedSoundFile),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        selectedSoundLabel = result['label'];

        selectedSoundFile = result['file'];
      });

      _playSelectedSound();
    }
  }

  Future<void> _toggleMusic() async {
    if (selectedSoundFile == null) {
      return;
    }

    HapticFeedback.selectionClick();
    if (_audioPlayer.state == PlayerState.playing) {
      await _audioPlayer.pause();
    } else {
      await _playSelectedSound();
    }

    setState(() {});
  }

  Future<void> _onMusicVolume(double val) async {
    setState(() {
      musicVolume = val;
    });

    await _audioPlayer.setVolume(val);
  }

  Future<void> _onBleTap() async {
    HapticFeedback.selectionClick();
    if (bleConnected) {
      await BLEManager.instance.disconnect();

      await _dbRef.set({
        "status": "Disconnected",
        "timestamp": ServerValue.timestamp,
      });
    } else {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BleHomePage()),
      );

      if (result != null) {
        await BLEManager.instance.connect(result);

        await _dbRef.set({
          "status": "Connected",
          "timestamp": ServerValue.timestamp,
        });
      }
    }
  }

  // ===================================================================
  // BUILD
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(child: _Aurora(animation: _ambient)),
          SafeArea(
            bottom: false,
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 36),
              children: [
                _Entrance(index: 0, child: _header()),
                const SizedBox(height: 20),
                _Entrance(index: 1, child: _deviceCard()),
                if (_heaterSafetyFaultActive) ...[
                  const SizedBox(height: 12),
                  _safetyBanner(),
                ],
                const SizedBox(height: 14),
                _Entrance(index: 2, child: _sessionCard()),
                const SizedBox(height: 26),
                _Entrance(
                  index: 3,
                  child: _sectionTitle("Comfort", "Adjust the pillow live"),
                ),
                const SizedBox(height: 12),
                _Entrance(index: 4, child: _vibrationCard()),
                const SizedBox(height: 8),
                _Entrance(index: 5, child: _heatCard()),
                const SizedBox(height: 26),
                _Entrance(
                  index: 6,
                  child: _sectionTitle("Sleep sounds", "Play while you rest"),
                ),
                const SizedBox(height: 12),
                _Entrance(index: 7, child: _soundCard()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // HEADER
  // ===================================================================
  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return "GOOD MORNING";
    if (h < 18) return "GOOD AFTERNOON";
    return "GOOD EVENING";
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greeting,
                style: _eyebrow(color: _cyan.withValues(alpha: .85)),
              ),
              const SizedBox(height: 6),
              Text("ComfortNap", style: _display(36, weight: FontWeight.w700)),
            ],
          ),
        ),
        Tooltip(
          message: "Sleep Record History",
          child: _glassButton(Icons.history_rounded, () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SleepSessionScreen(),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(title, style: _display(20)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _white(.4), fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _glassButton(IconData icon, VoidCallback onTap, {double size = 48}) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: _glass(radius: 16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  // ===================================================================
  // DEVICE CARD
  // ===================================================================
  Widget _deviceCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: _glass(radius: 22),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: bleConnected ? _greenGradient : null,
              color: bleConnected ? null : _white(.07),
              borderRadius: BorderRadius.circular(15),
              boxShadow: bleConnected
                  ? [
                      BoxShadow(
                        color: _green.withValues(alpha: .4),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              bleConnected
                  ? Icons.bluetooth_connected_rounded
                  : Icons.bluetooth_disabled_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "ComfortNap Pillow",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _PulseDot(
                      animation: _ambient,
                      color: bleConnected ? _green : _white(.35),
                      pulsing: bleConnected,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        bleConnected
                            ? (hasPillowTemperature
                                  ? "Connected · ${pillowTemperature.toStringAsFixed(1)}°C"
                                  : "Connected")
                            : "Not connected",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _white(.6), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _PillButton(
            label: bleConnected ? "Disconnect" : "Connect",
            icon: Icons.bluetooth_rounded,
            gradient: bleConnected ? null : _mainGradient,
            textColor: bleConnected ? _red : Colors.white,
            height: 40,
            onTap: _onBleTap,
          ),
        ],
      ),
    );
  }

  Widget _safetyBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: _red.withValues(alpha: .14),
        border: Border.all(color: _red.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: _red, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Heat pad safety lockout. Wait for the pad to cool before starting a session.",
              style: TextStyle(color: _white(.85), fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // SESSION HERO CARD
  // ===================================================================
  Widget _sessionCard() {
    final selected = selectedSessionDurationSeconds;
    final sleeping = isSessionRunning && _sleepStartTime != null;
    final shownSeconds = sleeping
        ? DateTime.now().difference(_sleepStartTime!).inSeconds
        : selected == null
        ? null
        : (isSessionRunning
              ? (_remainingSessionSeconds ?? selected)
              : selected);
    final progress = sleeping
        ? 1.0
        : selected == null || selected == 0
        ? 0.0
        : isSessionRunning
        ? ((_remainingSessionSeconds ?? selected) / selected).clamp(0.0, 1.0)
        : 1.0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _violet.withValues(alpha: .42),
            const Color(0xFF2A1F7A).withValues(alpha: .35),
            _cyan.withValues(alpha: .10),
          ],
        ),
        border: Border.all(color: _white(.12)),
        boxShadow: [
          BoxShadow(
            color: _violet.withValues(alpha: .25),
            blurRadius: 36,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                sleeping
                    ? "SLEEP TRACKING"
                    : isSessionRunning
                    ? "SESSION IN PROGRESS"
                    : "READY TO REST",
                style: _eyebrow(),
              ),
              const Spacer(),
              if (isSessionRunning)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: (sleeping ? _magenta : _green).withValues(
                      alpha: .15,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      _PulseDot(
                        animation: _ambient,
                        color: sleeping ? _magenta : _green,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        sleeping ? "SLEEPING" : "LIVE",
                        style: TextStyle(
                          color: sleeping ? _magenta : _green,
                          fontSize: 10.5,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => SizedBox(
                  width: 124,
                  height: 124,
                  child: CustomPaint(
                    painter: _RingPainter(value),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FittedBox(
                              child: Text(
                                shownSeconds == null
                                    ? "--:--"
                                    : _formatSessionDuration(shownSeconds),
                                style: _display(24, weight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sleeping
                                  ? "asleep"
                                  : isSessionRunning
                                  ? "remaining"
                                  : "timer",
                              style: TextStyle(
                                color: _white(.5),
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    _infoLine(
                      Icons.vibration_rounded,
                      "Vibration",
                      "${(vibrationLevel * 100).round()}%",
                    ),
                    const SizedBox(height: 10),
                    _infoLine(
                      Icons.local_fire_department_rounded,
                      "Heat",
                      "${heatLevel.round()}",
                    ),
                    const SizedBox(height: 10),
                    _infoLine(
                      sleepSoundByFile(selectedSoundFile)?.icon ??
                          Icons.music_note_rounded,
                      "Sound",
                      selectedSoundLabel ?? "None",
                    ),
                    const SizedBox(height: 10),
                    _infoLine(
                      Icons.alarm_rounded,
                      "Alarm",
                      _wakeAlarmTime == null
                          ? "Off"
                          : _clockText(_wakeAlarmTime!),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Timer row
          GestureDetector(
            onTap: _openTimer,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _white(.07),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _white(.08)),
              ),
              child: Row(
                children: [
                  Icon(Icons.timer_outlined, color: _cyan, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    "Set Timer",
                    style: TextStyle(
                      color: _white(.85),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    selected == null
                        ? "No timer"
                        : _formatSessionDuration(selected),
                    style: _display(15, weight: FontWeight.w700, color: _cyan),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    isSessionRunning
                        ? Icons.lock_outline_rounded
                        : Icons.chevron_right_rounded,
                    color: _white(.6),
                    size: isSessionRunning ? 16 : 20,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Actions
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: isSessionRunning
                ? Row(
                    key: const ValueKey("running"),
                    children: [
                      Expanded(
                        child: _PillButton(
                          label: "Wake",
                          icon: Icons.wb_sunny_rounded,
                          gradient: _greenGradient,
                          onTap: _onWake,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _PillButton(
                          label: "Stop",
                          icon: Icons.stop_rounded,
                          gradient: _redGradient,
                          onTap: _onStop,
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    key: const ValueKey("idle"),
                    width: double.infinity,
                    child: _PillButton(
                      label: "Start Session",
                      icon: Icons.play_arrow_rounded,
                      gradient: _mainGradient,
                      height: 54,
                      onTap: _onStartSession,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _infoLine(IconData icon, String label, String value) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _white(.08),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: _cyan, size: 15),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: _white(.55), fontSize: 12)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _display(14, weight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  // ===================================================================
  // COMFORT CONTROLS
  // ===================================================================
  Widget _vibrationCard() {
    return _controlCard(
      icon: Icons.vibration_rounded,
      title: "Vibration",
      caption: vibrationLevel <= 0
          ? "Off"
          : vibrationLevel < .34
          ? "Gentle"
          : vibrationLevel < .67
          ? "Moderate"
          : "Strong",
      value: "${(vibrationLevel * 100).round()}%",
      gradient: _mainGradient,
      child: _GlowSlider(
        value: vibrationLevel,
        gradient: _mainGradient,
        onChanged: _onVibrationChanged,
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final v in const [0.0, .25, .5, .75, 1.0])
            _tick(
              "${(v * 100).round()}%",
              (vibrationLevel - v).abs() < .005,
              () => _onVibrationChanged(v),
            ),
        ],
      ),
    );
  }

  Widget _heatCard() {
    return _controlCard(
      icon: Icons.local_fire_department_rounded,
      title: "Heat",
      caption: hasPillowTemperature
          ? "Pillow ${pillowTemperature.toStringAsFixed(1)}°C"
          : "Pillow --°C",
      captionColor: _amber,
      value: "${heatLevel.round()}",
      gradient: _heatGradient,
      child: _GlowSlider(
        value: heatLevel / 100,
        gradient: _heatGradient,
        steps: 4,
        onChanged: (v) => _onHeatChanged(v * 100),
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final level in _heatLevels)
            _tick(
              "${level.round()}%",
              heatLevel == level,
              () => _onHeatChanged(level),
            ),
        ],
      ),
    );
  }

  Widget _tick(String text, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          text,
          style: TextStyle(
            color: selected ? Colors.white : _white(.4),
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _controlCard({
    required IconData icon,
    required String title,
    required String caption,
    required String value,
    required Gradient gradient,
    required Widget child,
    Color? captionColor,
    Widget? footer,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: _glass(radius: 20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: gradient.colors.first.withValues(alpha: .4),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 17),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: captionColor ?? _white(.45),
                    fontSize: 11.5,
                    fontWeight: captionColor != null
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => gradient.createShader(r),
                child: Text(
                  value,
                  style: _display(20, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
          if (footer != null) footer,
        ],
      ),
    );
  }

  // ===================================================================
  // SOUND CARD
  // ===================================================================
  Widget _soundCard() {
    final hasSound = selectedSoundFile != null;
    final playing = _audioPlayer.state == PlayerState.playing;
    // The chosen sound's own icon + colours (e.g. raindrop / blue for Rain).
    final info = sleepSoundByFile(selectedSoundFile);
    final gradient = info?.gradient ?? _soundGradient;
    final accent = info?.colors.last ?? _pink;
    final glow = info?.colors.first ?? _pink;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: hasSound
              ? [glow.withValues(alpha: .22), accent.withValues(alpha: .06)]
              : [_white(.085), _white(.025)],
        ),
        border: Border.all(
          color: hasSound ? accent.withValues(alpha: .35) : _white(.09),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Sound icon — pulses gently while playing
              AnimatedBuilder(
                animation: _ambient,
                builder: (context, child) {
                  final t = playing
                      ? 0.5 + 0.5 * math.sin(_ambient.value * 2 * math.pi * 16)
                      : 0.0;
                  return Container(
                    padding: EdgeInsets.all(2 + 3 * t),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: accent.withValues(alpha: .18 * t),
                    ),
                    child: child,
                  );
                },
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (c, a) =>
                      ScaleTransition(scale: a, child: c),
                  child: Container(
                    key: ValueKey(selectedSoundFile),
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: glow.withValues(alpha: .45),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Icon(
                      info?.icon ?? Icons.music_note_rounded,
                      color: Colors.white,
                      size: 25,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          hasSound
                              ? (playing ? "NOW PLAYING" : "SELECTED")
                              : "NO SOUND",
                          style: _eyebrow(color: playing ? accent : null),
                        ),
                        if (playing) ...[
                          const SizedBox(width: 6),
                          _MiniEqualizer(animation: _ambient, color: accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selectedSoundLabel ?? "Choose a sound",
                      style: _display(18),
                    ),
                    if (info != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        info.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _white(.55), fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              GestureDetector(
                onTap: _toggleMusic,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: hasSound ? 1 : .35,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: glow.withValues(alpha: .45),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: _bg,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.volume_down_rounded, color: _white(.5), size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: _GlowSlider(
                  value: musicVolume,
                  gradient: gradient,
                  onChanged: _onMusicVolume,
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.volume_up_rounded, color: _white(.5), size: 20),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _openSounds,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: _white(.06),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(Icons.library_music_rounded, color: accent, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    hasSound ? "Change sound" : "Browse sleep sounds",
                    style: TextStyle(
                      color: _white(.85),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: _white(.6),
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// DESIGN TOKENS (match the other redesigned screens)
// =====================================================================
const Color _bg = Color(0xFF07031F);
const Color _surface = Color(0xFF151040);
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);
const Color _amber = Color(0xFFFFB547);
const Color _flame = Color(0xFFFF5E3A);
const Color _green = Color(0xFF34D399);
const Color _red = Color(0xFFFF4D67);
const Color _pink = Color(0xFFFF6FA5);

const LinearGradient _mainGradient = LinearGradient(
  colors: [_violet, _cyan],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _heatGradient = LinearGradient(
  colors: [_amber, _flame],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _greenGradient = LinearGradient(
  colors: [Color(0xFF10B981), Color(0xFF6EE7B7)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _redGradient = LinearGradient(
  colors: [Color(0xFFFF4D67), Color(0xFFFF8A65)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _soundGradient = LinearGradient(
  colors: [_pink, _magenta],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

Color _white(double a) => Colors.white.withValues(alpha: a);

TextStyle _display(
  double size, {
  FontWeight weight = FontWeight.w600,
  Color color = Colors.white,
}) => GoogleFonts.outfit(
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.1,
);

TextStyle _eyebrow({Color? color}) => TextStyle(
  color: color ?? _white(.5),
  fontSize: 11,
  letterSpacing: 1.6,
  fontWeight: FontWeight.w600,
);

BoxDecoration _glass({double radius = 24}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_white(.085), _white(.025)],
  ),
  border: Border.all(color: _white(.09)),
);

// =====================================================================
// SMALL WIDGETS
// =====================================================================

class _PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Gradient? gradient;
  final Color textColor;
  final double height;
  final VoidCallback? onTap;

  const _PillButton({
    required this.label,
    this.icon,
    this.gradient,
    this.textColor = Colors.white,
    this.height = 50,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: gradient != null
            ? BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(height / 2.6),
                boxShadow: [
                  BoxShadow(
                    color: gradient!.colors.first.withValues(alpha: .4),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              )
            : _glass(radius: height / 2.6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(height / 2.6),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: textColor, size: 18),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small status dot that softly pulses.
class _PulseDot extends StatelessWidget {
  final Animation<double> animation;
  final Color color;
  final bool pulsing;
  const _PulseDot({
    required this.animation,
    required this.color,
    this.pulsing = true,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = pulsing
            ? 0.5 + 0.5 * math.sin(animation.value * 2 * math.pi * 14)
            : 0.0;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: pulsing
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: .6 * t),
                      blurRadius: 4 + 6 * t,
                      spreadRadius: 1 + 2 * t,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// Thick gradient slider with a glowing thumb. [value] is 0..1.
class _GlowSlider extends StatelessWidget {
  final double value;
  final Gradient gradient;
  final ValueChanged<double> onChanged;
  final int? steps;

  const _GlowSlider({
    required this.value,
    required this.gradient,
    required this.onChanged,
    this.steps,
  });

  @override
  Widget build(BuildContext context) {
    const thumb = 20.0;
    const track = 6.0;

    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        final usable = width - thumb;
        final v = value.clamp(0.0, 1.0);

        void update(Offset local) {
          onChanged(((local.dx - thumb / 2) / usable).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => update(d.localPosition),
          onHorizontalDragUpdate: (d) => update(d.localPosition),
          child: SizedBox(
            height: 30,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Positioned(
                  left: thumb / 2,
                  right: thumb / 2,
                  child: Container(
                    height: track,
                    decoration: BoxDecoration(
                      color: _white(.09),
                      borderRadius: BorderRadius.circular(track / 2),
                    ),
                  ),
                ),
                if (steps != null)
                  for (int i = 0; i <= steps!; i++)
                    Positioned(
                      left: thumb / 2 + usable * i / steps! - 2,
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _white(.35),
                        ),
                      ),
                    ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  left: thumb / 2,
                  width: math.max(usable * v, 0),
                  child: Container(
                    height: track,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(track / 2),
                      boxShadow: [
                        BoxShadow(
                          color: gradient.colors.last.withValues(alpha: .5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  left: usable * v,
                  child: Container(
                    width: thumb,
                    height: thumb,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(
                        color: gradient.colors.last,
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: gradient.colors.last.withValues(alpha: .6),
                          blurRadius: 12,
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
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  _RingPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2 - 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = _white(.08),
    );

    if (progress <= 0) return;

    final sweep = math.max(2 * math.pi * progress.clamp(0.0, 1.0), 0.04);
    final shader = const SweepGradient(
      colors: [_violet, _cyan, _magenta, _violet],
      transform: GradientRotation(-math.pi / 2),
    ).createShader(rect);

    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = shader
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

/// Slowly drifting glow behind the content.
class _Aurora extends StatelessWidget {
  final Animation<double> animation;
  const _Aurora({required this.animation});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final t = animation.value * 2 * math.pi;
            return Stack(
              children: [
                _blob(
                  Alignment(-1.0 + .3 * math.sin(t), -1.0 + .12 * math.cos(t)),
                  460,
                  _violet.withValues(alpha: .36),
                ),
                _blob(
                  Alignment(1.1 + .2 * math.cos(t), -0.2 + .2 * math.sin(t)),
                  380,
                  _cyan.withValues(alpha: .16),
                ),
                _blob(
                  Alignment(-0.6 + .25 * math.cos(t), 1.0 + .1 * math.sin(t)),
                  440,
                  _magenta.withValues(alpha: .18),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _blob(Alignment alignment, double size, Color color) {
    return Align(
      alignment: alignment,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}

/// Staggered fade + rise entrance.
class _Entrance extends StatelessWidget {
  final int index;
  final Widget child;
  const _Entrance({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final delay = math.min(index, 10) * 55;
    final total = 480 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 22 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Tiny animated sound bars shown next to "NOW PLAYING".
class _MiniEqualizer extends StatelessWidget {
  final Animation<double> animation;
  final Color color;
  const _MiniEqualizer({required this.animation, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 11,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value * 2 * math.pi * 30;
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < 4; i++)
                Container(
                  width: 2.5,
                  height: 3 + 8 * (0.5 + 0.5 * math.sin(t * (1 + i * .3) + i)),
                  margin: const EdgeInsets.only(right: 1.5),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
