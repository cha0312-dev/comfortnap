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
import 'package:esp32_ble_app/bedtime_reminder.dart';
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
  // Pillow temperature log: one sample a minute while a session runs,
  // saved on the session doc as "temp_samples" for the Sleep Log chart.
  Timer? _tempLogTimer;
  String? _tempLogDocId;
  DateTime? _lastTempLogAt;
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

    _tempLogTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _logPillowTemperature(),
    );

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
      } else if (await AlarmService.instance.launchedFromBedtime()) {
        _onBedtimeTapped();
      }
    });

    // ================= BEDTIME REMINDER =================
    AlarmService.instance.bedtimeTapped.addListener(_onBedtimeTapped);
    unawaited(BedtimeReminder.instance.rescheduleFromSaved());

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

      // Safety first: the pillow goes off, but the night isn't thrown away.
      // Sleep tracking starts (or keeps going) so Wake can still record it.
      if (activeSessionDocId != null) {
        if (_sleepStartTime == null) {
          unawaited(_stopHardwareWithoutEndingSession());
        } else {
          unawaited(BLEManager.instance.send("OFF"));
          unawaited(BLEManager.instance.send("HEAT:0"));
        }
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

  Future<void> _showStopSessionConfirmation() async {
    final sleptSeconds = _sleepStartTime == null
        ? null
        : DateTime.now().difference(_sleepStartTime!).inSeconds;
    final sleeping = sleptSeconds != null;

    final choice = await showDialog<String>(
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
                  color: _red.withValues(alpha: .18),
                  blurRadius: 40,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _redGradient,
                    boxShadow: [
                      BoxShadow(
                        color: _red.withValues(alpha: .45),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.delete_sweep_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  sleeping
                      ? "Discard tonight's sleep?"
                      : "Stop without saving?",
                  textAlign: TextAlign.center,
                  style: _display(22, weight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  "Stopping cancels this session. It won't appear in your "
                  "History, Weekly or Monthly stats.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _white(.6),
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: (sleeping ? _amber : _white(1)).withValues(
                      alpha: sleeping ? .1 : .06,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: sleeping
                          ? _amber.withValues(alpha: .35)
                          : _white(.08),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        sleeping
                            ? Icons.lightbulb_rounded
                            : Icons.wb_sunny_outlined,
                        color: sleeping ? _amber : _white(.6),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          sleeping
                              ? "You've slept ${_formatSessionDuration(sleptSeconds)}. "
                                    "Tap Wake & save to keep it."
                              : "Only the Wake button saves a session and your sleep.",
                          style: TextStyle(
                            color: _white(.8),
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                if (sleeping) ...[
                  SizedBox(
                    width: double.infinity,
                    child: _PillButton(
                      label: "Wake & save",
                      icon: Icons.wb_sunny_rounded,
                      gradient: _greenGradient,
                      height: 48,
                      onTap: () => Navigator.of(context).pop("wake"),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    Expanded(
                      child: _PillButton(
                        label: "Keep going",
                        height: 48,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PillButton(
                        label: "Discard",
                        icon: Icons.stop_rounded,
                        gradient: _redGradient,
                        height: 48,
                        onTap: () {
                          HapticFeedback.heavyImpact();
                          Navigator.of(context).pop("discard");
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

    if (!mounted) return;
    if (choice == "discard") {
      await _stopSession();
    } else if (choice == "wake") {
      await _handleWakeSession(skipConfirm: true, reason: "manual_wake");
    }
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
      try {
        await BLEManager.instance.send("OFF");
        await BLEManager.instance.send("HEAT:0");
      } catch (_) {}

      // Stop = cancel. Only Wake records a session and its sleep, so the
      // session document is removed and never shows up in History.
      final docRef = FirebaseFirestore.instance
          .collection("vibrator_logs")
          .doc(activeSessionDocId);
      try {
        await docRef.delete();
      } catch (e) {
        print("DISCARD SESSION ERROR: $e");
      }

      activeSessionDocId = null;
      sessionStartTime = null;
      _clearSleepTracking();
      unawaited(_disarmAlarm());
      unawaited(sleepSound.stop());

      if (mounted) {
        setState(() {
          isSessionRunning = false;
          _remainingSessionSeconds = selectedSessionDurationSeconds;
        });
        _showSessionMessageSnackBar(
          "Session stopped. Nothing was saved to your history.",
        );
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

  Future<void> _handleWakeSession({
    bool skipConfirm = false,
    String? reason,
  }) async {
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
                            colors: [_amber, _amber],
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
                                colors: [_amber, _amber],
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
            "completion_reason":
                reason ?? (skipConfirm ? "alarm_wake" : "manual_wake"),
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

  /// Appends the current pillow temperature to the running session —
  /// right away for a new session, then once a minute.
  Future<void> _logPillowTemperature() async {
    final docId = activeSessionDocId;
    final start = sessionStartTime;
    if (docId == null || start == null) return;
    if (!bleConnected || !hasPillowTemperature) return;

    final now = DateTime.now();
    final isNew = docId != _tempLogDocId;
    if (!isNew &&
        _lastTempLogAt != null &&
        now.difference(_lastTempLogAt!) < const Duration(seconds: 60)) {
      return;
    }
    _tempLogDocId = docId;
    _lastTempLogAt = now;

    try {
      await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .doc(docId)
          .update({
            "temp_samples": FieldValue.arrayUnion([
              {
                "t": now.difference(start).inSeconds, // seconds into session
                "c": double.parse(pillowTemperature.toStringAsFixed(1)),
              },
            ]),
          });
    } catch (e) {
      debugPrint("TEMP LOG ERROR: $e");
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
    _tempLogTimer?.cancel();
    AlarmService.instance.tapped.removeListener(_onAlarmRing);
    AlarmService.instance.bedtimeTapped.removeListener(_onBedtimeTapped);
    _ambient.dispose();
    super.dispose();
  }

  // ===================================================================
  // UI ACTIONS — same logic as before, moved out of build() unchanged
  // ===================================================================
  /// Lowest motor power (%) sent for any level above Off. Small vibration
  /// motors barely spin at low PWM, so the slider is mapped onto
  /// [_minMotorPower]..100 instead of 0..100.
  /// Slider 25% → 70%, 50% → 80%, 75% → 90%, 100% → 100%.
  /// Raise this if low levels still feel weak, lower it if they feel too strong.
  static const int _minMotorPower = 60;

  /// Converts the slider value (0..1) into the power sent to the pillow.
  int _motorPower(double level) {
    final l = level.clamp(0.0, 1.0);
    if (l <= 0) return 0;
    return (_minMotorPower + (100 - _minMotorPower) * l).round();
  }

  Future<void> _onVibrationChanged(double val) async {
    setState(() {
      vibrationLevel = val;
      currentSessionLevel = val; // 🔥 store latest
    });

    if (BLEManager.instance.connected) {
      await BLEManager.instance.send("VIB:${_motorPower(val)}");
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

  /// Bedtime reminder (or its "Start wind-down" button) was tapped.
  void _onBedtimeTapped() {
    if (!mounted || isSessionRunning || _sleepStartTime != null) return;
    HapticFeedback.lightImpact();
    _showCenterSessionNotice(
      message: "🌙 It's almost bedtime. Start your ComfortNap session now?",
      onOkay: _onStartSession,
      showCancel: true,
    );
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
        "VIB:${_motorPower(currentSessionLevel)}",
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
      // Already in bed: skip tonight's bedtime nudge.
      unawaited(BedtimeReminder.instance.cancelUpcoming());
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

    unawaited(_showStopSessionConfirmation());
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
                const SizedBox(height: 26),
                _Entrance(
                  index: 8,
                  child: _sectionTitle("Bedtime", "A gentle nudge before bed"),
                ),
                const SizedBox(height: 12),
                const _Entrance(index: 9, child: BedtimeReminderCard()),
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
          message: "Sleep Log",
          child: _JournalButton(
            animation: _ambient,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SleepSessionScreen(),
                ),
              );
            },
          ),
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

  // ===================================================================
  // DEVICE CARD
  // ===================================================================
  Widget _deviceCard() {
    final on = bleConnected;
    final accent = on ? _green : _violet;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      // 3D slab without shadows: lit top, darker base, bright rim.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(accent, Colors.white, .1)!.withValues(
              alpha: on ? .30 : .26,
            ),
            accent.withValues(alpha: on ? .10 : .07),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: on ? .2 : .14),
        ),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: .07),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, .45],
        ),
      ),
      child: Row(
        children: [
          // ---------- Icon with radar / halo ----------
          SizedBox(
            width: 50,
            height: 50,
            child: AnimatedBuilder(
              animation: _ambient,
              builder: (context, _) {
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    // Expanding rings: "searching" when off, calm pulse when on.
                    for (int k = 0; k < 2; k++)
                      Builder(
                        builder: (context) {
                          final t =
                              ((_ambient.value * (on ? 6 : 12)) + k * .5) % 1.0;
                          return Container(
                            width: 50 + 22 * t,
                            height: 50 + 22 * t,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16 + 8 * t),
                              border: Border.all(
                                color: accent.withValues(
                                  alpha: (1 - t) * (on ? .35 : .45),
                                ),
                                width: 1.4,
                              ),
                            ),
                          );
                        },
                      ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 50,
                      height: 50,
                      // Glossy 3D key (no shadow).
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: on
                              ? [
                                  Color.lerp(_green, Colors.white, .3)!,
                                  const Color(0xFF0F9F72),
                                ]
                              : [
                                  Color.lerp(_violet, Colors.white, .12)!
                                      .withValues(alpha: .8),
                                  Color.lerp(_violet, Colors.black, .35)!
                                      .withValues(alpha: .7),
                                ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .25),
                        ),
                      ),
                      foregroundDecoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: .28),
                            Colors.white.withValues(alpha: 0),
                          ],
                          stops: const [0, .5],
                        ),
                      ),
                      child: Icon(
                        on
                            ? Icons.bluetooth_connected_rounded
                            : Icons.bluetooth_searching_rounded,
                        color: Colors.white,
                        size: 23,
                      ),
                    ),
                    // Status badge
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on ? _green : const Color(0xFF3A3560),
                          border: Border.all(color: _bg, width: 2.5),
                        ),
                        child: Icon(
                          on ? Icons.check_rounded : Icons.close_rounded,
                          color: Colors.white,
                          size: 10,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 14),

          // ---------- Name + status ----------
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        "ComfortNap Pillow",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _display(16, weight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: .4),
                            Colors.white.withValues(alpha: .05),
                          ],
                        ),
                        border: Border.all(color: _white(.1)),
                      ),
                      child: Text(
                        "BLE",
                        style: TextStyle(
                          color: _white(.55),
                          fontSize: 8.5,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: on
                      ? Row(
                          key: const ValueKey("on"),
                          children: [
                            _deviceChip(
                              dot: true,
                              text: "Online",
                              color: _green,
                            ),
                            const SizedBox(width: 6),
                            _deviceChip(
                              icon: Icons.thermostat_rounded,
                              text: hasPillowTemperature
                                  ? "${pillowTemperature.toStringAsFixed(1)}°C"
                                  : "--°C",
                              color: _amber,
                            ),
                          ],
                        )
                      : Row(
                          key: const ValueKey("off"),
                          children: [
                            _PulseDot(
                              animation: _ambient,
                              color: _white(.35),
                              pulsing: false,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                "Not connected · tap Connect",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _white(.55),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // ---------- Action ----------
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: on
                ? Tooltip(
                    key: const ValueKey("disconnect"),
                    message: "Disconnect",
                    child: GestureDetector(
                      onTap: _onBleTap,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color.lerp(_red, Colors.white, .2)!
                                  .withValues(alpha: .32),
                              _red.withValues(alpha: .08),
                            ],
                          ),
                          border: Border.all(
                            color: _red.withValues(alpha: .55),
                          ),
                        ),
                        child: const Icon(
                          Icons.power_settings_new_rounded,
                          color: _red,
                          size: 20,
                        ),
                      ),
                    ),
                  )
                : Stack(
                    key: const ValueKey("connect"),
                    children: [
                      _Glossy3DButton(
                        label: "Connect",
                        icon: Icons.bluetooth_rounded,
                        color: _violet,
                        height: 42,
                        onTap: _onBleTap,
                      ),
                      // Light sweep across the button.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(42 / 2.6),
                            child: AnimatedBuilder(
                              animation: _ambient,
                              builder: (context, _) {
                                final t = (_ambient.value * 8) % 1.0;
                                return FractionalTranslation(
                                  translation: Offset(-1 + 3 * t, 0),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.white.withValues(alpha: 0),
                                          Colors.white.withValues(alpha: 0),
                                          Colors.white.withValues(alpha: 0),
                                        ],
                                        stops: const [.3, .5, .7],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _deviceChip({
    required String text,
    required Color color,
    IconData? icon,
    bool dot = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(color, Colors.white, .15)!.withValues(alpha: .3),
            color.withValues(alpha: .08),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot)
            _PulseDot(animation: _ambient, color: color)
          else if (icon != null)
            Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
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
    final running = isSessionRunning && !sleeping;
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

    // State colours: idle = violet/cyan, live = cyan/green, sleeping = night.
    final List<Color> accent = sleeping
        ? const [_magenta, _violet]
        : running
        ? const [_cyan, _green]
        : const [_violet, _cyan];

    final String eyebrow = sleeping
        ? "SLEEP TRACKING"
        : running
        ? "SESSION IN PROGRESS"
        : "READY TO REST";

    final String subline = sleeping
        ? "Asleep since ${_clockText(_sleepStartTime!)}"
        : running
        ? "Pillow off at ${_clockText(DateTime.now().add(Duration(seconds: _remainingSessionSeconds ?? selected ?? 0)))}"
        : selected == null
        ? "Set a timer to begin"
        : "Then sleep tracking starts";

    final soundInfo = sleepSoundByFile(selectedSoundFile);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      // 3D slab, no shadows: lit top, darker base, bright rim + shine.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(accent.first, Colors.white, .08)!.withValues(alpha: .5),
            accent.first.withValues(alpha: .18),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .16)),
      ),
      foregroundDecoration: _shine3D(radius: 28, a: .08),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _ambient,
                builder: (context, _) {
                  final a = _ambient.value * 2 * math.pi;
                  return Stack(
                    children: [
                      Positioned(
                        top: -70 + 16 * math.sin(a),
                        right: -60 + 16 * math.cos(a),
                        child: _cardGlow(accent.last, 170),
                      ),
                      Positioned(
                        bottom: -80 + 16 * math.cos(a),
                        left: -60 + 20 * math.sin(a),
                        child: _cardGlow(accent.first, 180),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---------- Header ----------
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          eyebrow,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _eyebrow(color: _white(.6)),
                        ),
                      ),
                      _stateChip(sleeping: sleeping, running: running),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // ---------- Ring + info ----------
                  Row(
                    children: [
                      GestureDetector(
                        onTap: isSessionRunning ? null : _openTimer,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: progress),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) => AnimatedBuilder(
                            animation: _ambient,
                            builder: (context, _) => SizedBox(
                              width: 120,
                              height: 120,
                              child: CustomPaint(
                                painter: _HeroRingPainter(
                                  progress: value,
                                  spin: _ambient.value,
                                  colors: accent,
                                  live: isSessionRunning,
                                  empty: selected == null && !sleeping,
                                ),
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 26,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        FittedBox(
                                          child: Text(
                                            shownSeconds == null
                                                ? "--:--"
                                                : _formatSessionDuration(
                                                    shownSeconds,
                                                  ),
                                            style: _display(
                                              22,
                                              weight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          sleeping
                                              ? "ASLEEP"
                                              : running
                                              ? "LEFT"
                                              : selected == null
                                              ? "TAP TO SET"
                                              : "SESSION",
                                          style: TextStyle(
                                            color: _white(.5),
                                            fontSize: 8.5,
                                            letterSpacing: 1.3,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              subline,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: accent.last.withValues(alpha: .9),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _miniInfo(
                              Icons.waves_rounded,
                              "Vibration",
                              "${(vibrationLevel * 100).round()}%",
                              const [_violet, _cyan],
                              level: vibrationLevel,
                            ),
                            _miniInfo(
                              Icons.local_fire_department_rounded,
                              "Heat",
                              "${heatLevel.round()}%",
                              const [_amber, _flame],
                              level: heatLevel / 100,
                            ),
                            _miniInfo(
                              soundInfo?.icon ?? Icons.music_note_rounded,
                              "Sound",
                              selectedSoundLabel ?? "None",
                              soundInfo?.colors ?? const [_pink, _magenta],
                              off: selectedSoundLabel == null,
                            ),
                            _miniInfo(
                              _wakeAlarmTime == null
                                  ? Icons.alarm_off_rounded
                                  : Icons.alarm_on_rounded,
                              "Alarm",
                              _wakeAlarmTime == null
                                  ? "Off"
                                  : _clockText(_wakeAlarmTime!),
                              const [_amber, Color(0xFFFF7E5F)],
                              off: _wakeAlarmTime == null,
                              last: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // ---------- Timer + action in one row ----------
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _openTimer,
                        child: Container(
                          height: 48,
                          constraints: const BoxConstraints(minWidth: 92),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: _raised3D(_cyan, radius: 18),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                isSessionRunning
                                    ? Icons.lock_outline_rounded
                                    : Icons.timer_outlined,
                                color: _cyan,
                                size: 17,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                selected == null
                                    ? "Timer"
                                    : _formatSessionDuration(selected),
                                style: _display(
                                  14,
                                  weight: FontWeight.w700,
                                  color: _cyan,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(width: 2),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          // Stretch whichever child is showing to full width.
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.center,
                            children: [
                              ...previous,
                              if (current != null) current,
                            ],
                          ),
                          child: isSessionRunning
                              ? Row(
                                  key: const ValueKey("running"),
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: _Glossy3DButton(
                                        label: "Wake",
                                        icon: Icons.wb_sunny_rounded,
                                        color: const Color(0xFF10B981),
                                        height: 48,
                                        onTap: _onWake,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 2,
                                      child: _Glossy3DButton(
                                        label: "Stop",
                                        icon: Icons.stop_rounded,
                                        color: const Color(0xFFFF4D67),
                                        height: 48,
                                        onTap: _onStop,
                                      ),
                                    ),
                                  ],
                                )
                              : SizedBox(
                                  key: const ValueKey("idle"),
                                  width: double.infinity,
                                  child: _Glossy3DButton(
                                    label: "Start Session",
                                    icon: Icons.play_arrow_rounded,
                                    color: _violet,
                                    height: 48,
                                    onTap: _onStartSession,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One compact info line: icon, label, value and an optional level bar.
  Widget _miniInfo(
    IconData icon,
    String label,
    String value,
    List<Color> colors, {
    double? level,
    bool off = false,
    bool last = false,
  }) {
    final dim = off || (level != null && level <= 0);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: dim
                ? _sunk3D(radius: 7)
                : _gloss3D(colors.first, radius: 7),
            foregroundDecoration: dim ? null : _shine3D(radius: 7, a: .22),
            child: Icon(icon, color: dim ? _white(.5) : Colors.white, size: 12),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: _white(.55), fontSize: 11.5)),
          const SizedBox(width: 6),
          if (level != null)
            Expanded(
              // Recessed groove with a glossy fill.
              child: Container(
                height: 6,
                decoration: _sunk3D(radius: 3),
                alignment: Alignment.centerLeft,
                child: AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 300),
                  widthFactor: level.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.lerp(colors.first, Colors.white, .4)!,
                          colors.first,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 90),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: _display(
                13,
                weight: FontWeight.w700,
                color: dim ? _white(.6) : Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Flat design: no glow blobs inside cards.
  Widget _cardGlow(Color color, double size) => const SizedBox.shrink();

  Widget _stateChip({required bool sleeping, required bool running}) {
    final Color c = sleeping
        ? _magenta
        : running
        ? _green
        : _cyan;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: _raised3D(c, radius: 20).copyWith(
        border: Border.all(color: c.withValues(alpha: .5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sleeping || running)
            _PulseDot(animation: _ambient, color: c)
          else
            Icon(Icons.nightlight_round, color: c, size: 11),
          const SizedBox(width: 6),
          Text(
            sleeping
                ? "SLEEPING"
                : running
                ? "LIVE"
                : "IDLE",
            style: TextStyle(
              color: c,
              fontSize: 10.5,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // COMFORT CONTROLS
  // ===================================================================
  Widget _vibrationCard() {
    final pct = (vibrationLevel * 100).round();
    return _controlCard(
      icon: Icons.waves_rounded,
      title: "Vibration",
      status: vibrationLevel <= 0
          ? "Off"
          : vibrationLevel < .34
          ? "Gentle"
          : vibrationLevel < .67
          ? "Moderate"
          : "Strong",
      level: vibrationLevel,
      value: "$pct",
      unit: "%",
      gradient: _mainGradient,
      badge: _LevelBars(level: vibrationLevel, gradient: _mainGradient),
      slider: _ComfortSlider(
        value: vibrationLevel,
        gradient: _mainGradient,
        onChanged: _onVibrationChanged,
      ),
      presets: [
        for (final v in const [0.0, .25, .5, .75, 1.0])
          _presetChip(
            v == 0 ? "Off" : (v == 1 ? "Max" : "${(v * 100).round()}"),
            (vibrationLevel - v).abs() < .005,
            _mainGradient,
            () => _onVibrationChanged(v),
          ),
      ],
    );
  }

  Widget _heatCard() {
    final h = heatLevel.round();
    return _controlCard(
      icon: Icons.local_fire_department_rounded,
      title: "Heat",
      status: h <= 0
          ? "Off"
          : h <= 25
          ? "Warm"
          : h <= 50
          ? "Cozy"
          : h <= 75
          ? "Hot"
          : "Max",
      level: heatLevel / 100,
      value: "$h",
      unit: "%",
      gradient: _heatGradient,
      badge: _tempChip(),
      slider: _ComfortSlider(
        value: heatLevel / 100,
        gradient: _heatGradient,
        steps: 4,
        onChanged: (v) => _onHeatChanged(v * 100),
      ),
      presets: [
        for (final level in _heatLevels)
          _presetChip(
            level == 0 ? "Off" : (level == 100 ? "Max" : "${level.round()}"),
            heatLevel == level,
            _heatGradient,
            () => _onHeatChanged(level),
          ),
      ],
    );
  }

  /// Live pillow temperature from the device.
  Widget _tempChip() {
    final known = hasPillowTemperature;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: _raised3D(
        known ? _amber : Colors.white,
        radius: 20,
        strength: known ? 1.0 : .5,
      ).copyWith(
        border: Border.all(
          color: known ? _amber.withValues(alpha: .5) : _white(.14),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.thermostat_rounded,
            size: 14,
            color: known ? _amber : _white(.45),
          ),
          const SizedBox(width: 4),
          Text(
            known ? "${pillowTemperature.toStringAsFixed(1)}°C" : "--°C",
            style: _display(
              12.5,
              weight: FontWeight.w700,
              color: known ? _amber : _white(.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _presetChip(
    String text,
    bool selected,
    LinearGradient gradient,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.center,
          // Selected = glossy key; others = soft raised keys.
          decoration: selected
              ? _gloss3D(gradient.colors.last, radius: 11)
              : _raised3D(Colors.white, radius: 11, strength: .45),
          foregroundDecoration: selected ? _shine3D(radius: 11) : null,
          child: Text(
            text,
            style: _display(
              12.5,
              weight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : _white(.55),
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlCard({
    required IconData icon,
    required String title,
    required String status,
    required double level,
    required String value,
    required String unit,
    required LinearGradient gradient,
    required Widget slider,
    required List<Widget> presets,
    Widget? badge,
  }) {
    final on = level > 0;
    final accent = gradient.colors.last;
    final tint = .04 + .12 * level.clamp(0.0, 1.0);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      // 3D slab, no shadows: lit top fading to a darker base.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(gradient.colors.first, Colors.white, .08)!
                .withValues(alpha: tint + .14),
            gradient.colors.first.withValues(alpha: tint * .5),
          ],
        ),
        border: Border.all(
          color: on
              ? accent.withValues(alpha: .25 + .25 * level)
              : Colors.white.withValues(alpha: .12),
        ),
      ),
      foregroundDecoration: _shine3D(radius: 24, a: .06),
      child: Column(
        children: [
          Row(
            children: [
              // Icon tile with a soft halo that grows with the level.
              AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                width: 44,
                height: 44,
                decoration: on
                    ? _gloss3D(gradient.colors.first, radius: 14)
                    : _raised3D(Colors.white, radius: 14, strength: .6),
                foregroundDecoration: on ? _shine3D(radius: 14) : null,
                child: Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: _display(16.5, weight: FontWeight.w700)),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on ? accent : _white(.3),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: .35),
                              width: .8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status.toUpperCase(),
                          style: TextStyle(
                            color: on ? _white(.8) : _white(.4),
                            fontSize: 10.5,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (badge != null) ...[badge, const SizedBox(width: 12)],
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => gradient.createShader(r),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(value, style: _display(28, weight: FontWeight.w700)),
                    Text(unit, style: _display(14, weight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          slider,
          const SizedBox(height: 10),
          Row(children: presets),
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
      // 3D slab, no shadows: lit top fading to a darker base.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: hasSound
              ? [
                  Color.lerp(glow, Colors.white, .08)!.withValues(alpha: .32),
                  glow.withValues(alpha: .08),
                ]
              : [_white(.12), _white(.03)],
        ),
        border: Border.all(
          color: hasSound
              ? accent.withValues(alpha: .4)
              : Colors.white.withValues(alpha: .13),
        ),
      ),
      foregroundDecoration: _shine3D(radius: 22, a: .06),
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
                    decoration: _gloss3D(glow, radius: 16),
                    foregroundDecoration: _shine3D(radius: 16),
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
                    // Glossy pearl play button (no shadow).
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.white, Color(0xFFCFCBE6)],
                      ),
                      border: Border.all(
                        color: glow.withValues(alpha: .6),
                        width: 1.5,
                      ),
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: _raised3D(glow, radius: 14, strength: .7),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: _gloss3D(glow, radius: 9),
                    foregroundDecoration: _shine3D(radius: 9),
                    child: const Icon(
                      Icons.library_music_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
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

// ---------- No-shadow 3D helpers ----------
/// Glossy key face: lit top, darker base, bright rim.
BoxDecoration _gloss3D(Color c, {double radius = 12, bool circle = false}) =>
    BoxDecoration(
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(c, Colors.white, .28)!,
          Color.lerp(c, Colors.black, .22)!,
        ],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: .28)),
    );

/// Shine painted over a glossy face (top half highlight).
BoxDecoration _shine3D({double radius = 12, bool circle = false, double a = .26}) =>
    BoxDecoration(
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: a),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, .5],
      ),
    );

/// Raised translucent panel / chip.
BoxDecoration _raised3D(Color c, {double radius = 12, double strength = 1}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(c, Colors.white, .14)!.withValues(alpha: .3 * strength),
          c.withValues(alpha: .07 * strength),
        ],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: .14)),
    );

/// Recessed groove (pressed into the surface).
BoxDecoration _sunk3D({double radius = 8}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Colors.black.withValues(alpha: .45),
      Colors.white.withValues(alpha: .05),
    ],
  ),
  border: Border.all(color: Colors.white.withValues(alpha: .07)),
);

const LinearGradient _mainGradient = LinearGradient(
  colors: [_violet, _violet],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _heatGradient = LinearGradient(
  colors: [_amber, _amber],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _greenGradient = LinearGradient(
  colors: [Color(0xFF10B981), Color(0xFF10B981)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _redGradient = LinearGradient(
  colors: [Color(0xFFFF4D67), Color(0xFFFF4D67)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const LinearGradient _soundGradient = LinearGradient(
  colors: [_pink, _pink],
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
    colors: [_white(.085), _white(.085)],
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
    final radius = BorderRadius.circular(height / 2.6);
    // The shadow lives outside the Material so it isn't clipped into a
    // square box behind the rounded button.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: gradient != null
            ? [
                BoxShadow(
                  color: gradient!.colors.first.withValues(alpha: .4),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: gradient != null
              ? BoxDecoration(gradient: gradient, borderRadius: radius)
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
                    decoration: _sunk3D(radius: track / 2),
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
                    decoration: _gloss3D(
                      gradient.colors.last,
                      radius: track / 2,
                    ),
                    foregroundDecoration: _shine3D(radius: track / 2, a: .35),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  left: usable * v,
                  child: Container(
                    width: thumb,
                    height: thumb,
                    // Glossy pearl thumb (no shadow).
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        center: Alignment(-.3, -.4),
                        colors: [Colors.white, Color(0xFFDCD8F0)],
                      ),
                      border: Border.all(
                        color: gradient.colors.last,
                        width: 2.5,
                      ),
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

/// Big session ring: tick dial, glowing progress arc, end knob and a
/// slow orbiting spark.
class _HeroRingPainter extends CustomPainter {
  final double progress;
  final double spin; // 0..1, from the ambient controller
  final List<Color> colors;
  final bool live;
  final bool empty;

  _HeroRingPainter({
    required this.progress,
    required this.spin,
    required this.colors,
    required this.live,
    required this.empty,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    const stroke = 9.0;
    final radius = outer - 17;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final p = progress.clamp(0.0, 1.0);

    // Inner disc
    canvas.drawCircle(
      center,
      radius - stroke / 2 - 4,
      Paint()
        // Domed disc: lit top, darker bottom.
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(colors.first, Colors.white, .12)!.withValues(alpha: .38),
            colors.first.withValues(alpha: .12),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius - stroke / 2 - 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: .16),
    );

    // Tick dial (60 ticks, lit up to the progress)
    for (int i = 0; i < 60; i++) {
      final a = -math.pi / 2 + i / 60 * 2 * math.pi;
      final major = i % 5 == 0;
      final lit = !empty && i / 60 < p;
      final r1 = outer - (major ? 10 : 7.5);
      final r2 = outer - 3.5;
      canvas.drawLine(
        center + Offset(math.cos(a), math.sin(a)) * r1,
        center + Offset(math.cos(a), math.sin(a)) * r2,
        Paint()
          ..strokeWidth = major ? 2 : 1.2
          ..strokeCap = StrokeCap.round
          ..color = lit
              ? Color.lerp(
                  colors.first,
                  colors.last,
                  i / 60,
                )!.withValues(alpha: major ? .9 : .6)
              : Colors.white.withValues(alpha: major ? .18 : .08),
      );
    }

    // Track
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.black.withValues(alpha: .3),
    );

    if (empty) {
      // Dashed hint ring when no timer is set.
      for (int i = 0; i < 36; i += 2) {
        canvas.drawArc(
          rect,
          -math.pi / 2 + i / 36 * 2 * math.pi + spin * 2 * math.pi,
          2 * math.pi / 36 * .8,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = colors.last.withValues(alpha: .35),
        );
      }
      return;
    }

    if (p > 0) {
      final sweep = math.max(2 * math.pi * p, 0.04);
      final shader = SweepGradient(
        colors: [colors.first, colors.first, colors.first],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);

      // Crisp arc + glossy highlight line (no glow).
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
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius + stroke * .2),
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: .4),
      );

      // End knob
      if (p < 1) {
        final ea = -math.pi / 2 + sweep;
        final knob = center + Offset(math.cos(ea), math.sin(ea)) * radius;
        canvas.drawCircle(knob, 7, Paint()..color = Colors.white);
        canvas.drawCircle(knob, 3.5, Paint()..color = colors.last);
      }
    }

    // Orbiting spark while a session or sleep is live.
    if (live) {
      final oa = -math.pi / 2 + spin * 2 * math.pi * 6;
      final spark = center + Offset(math.cos(oa), math.sin(oa)) * (outer - 2);
      canvas.drawCircle(spark, 2.2, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_HeroRingPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.live != live ||
      old.empty != empty ||
      old.colors != colors;
}

/// Slowly drifting glow behind the content.
class _Aurora extends StatelessWidget {
  final Animation<double> animation;
  const _Aurora({required this.animation});

  // Flat background: no glowing colour blobs.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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

/// Thick comfort slider: segmented track, gradient fill and a glowing
/// two-tone thumb. [value] is 0..1 (same contract as _GlowSlider).
class _ComfortSlider extends StatelessWidget {
  final double value;
  final LinearGradient gradient;
  final ValueChanged<double> onChanged;
  final int? steps;

  const _ComfortSlider({
    required this.value,
    required this.gradient,
    required this.onChanged,
    this.steps,
  });

  @override
  Widget build(BuildContext context) {
    const thumb = 26.0;
    const track = 10.0;
    final accent = gradient.colors.last;

    return LayoutBuilder(
      builder: (context, box) {
        final usable = box.maxWidth - thumb;
        final v = value.clamp(0.0, 1.0);

        void update(Offset local) {
          onChanged(((local.dx - thumb / 2) / usable).clamp(0.0, 1.0));
        }

        final marks = steps ?? 10;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => update(d.localPosition),
          onHorizontalDragUpdate: (d) => update(d.localPosition),
          child: SizedBox(
            height: 34,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Track
                Positioned(
                  left: thumb / 2,
                  right: thumb / 2,
                  child: Container(
                    height: track,
                    decoration: _sunk3D(radius: track / 2),
                  ),
                ),
                // Fill
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  left: thumb / 2,
                  width: math.max(usable * v, 0),
                  child: Container(
                    height: track,
                    decoration: _gloss3D(accent, radius: track / 2),
                    foregroundDecoration: _shine3D(radius: track / 2, a: .35),
                  ),
                ),
                // Segment marks
                for (int i = 1; i < marks; i++)
                  Positioned(
                    left: thumb / 2 + usable * i / marks - 1,
                    child: Container(
                      width: 2,
                      height: steps != null ? 6 : 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(1),
                        color: i / marks <= v
                            ? Colors.white.withValues(alpha: .55)
                            : _white(.18),
                      ),
                    ),
                  ),
                // Thumb
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  left: usable * v,
                  child: Container(
                    width: thumb,
                    height: thumb,
                    // Glossy pearl thumb (no shadow).
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        center: Alignment(-.3, -.4),
                        colors: [Colors.white, Color(0xFFDCD8F0)],
                      ),
                      border: Border.all(
                        color: accent.withValues(alpha: .6),
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: gradient,
                      ),
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

/// Five rising bars that light up with the vibration level.
class _LevelBars extends StatelessWidget {
  final double level;
  final LinearGradient gradient;
  const _LevelBars({required this.level, required this.gradient});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < 5; i++) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 4,
              height: 6.0 + i * 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: level > i / 5 ? gradient : null,
                color: level > i / 5 ? null : _white(.14),
              ),
            ),
            if (i < 4) const SizedBox(width: 3),
          ],
        ],
      ),
    );
  }
}

/// Sleep Log button: glossy tile with a slowly rotating gradient rim,
/// a journal icon, a glowing moon badge and a soft press animation.
class _JournalButton extends StatefulWidget {
  final Animation<double> animation;
  final VoidCallback onTap;
  const _JournalButton({required this.animation, required this.onTap});

  @override
  State<_JournalButton> createState() => _JournalButtonState();
}

class _JournalButtonState extends State<_JournalButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    const size = 54.0;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? .9 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: widget.animation,
              builder: (context, _) {
                final glow =
                    .5 +
                    .5 * math.sin(widget.animation.value * 2 * math.pi * 8);
                return SizedBox(
                  width: size + 8,
                  height: size + 8,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      // Rotating gradient rim
                      Container(
                        width: size,
                        height: size,
                        padding: const EdgeInsets.all(1.6),
                        // Bevelled rim: lit on top, darker underneath.
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color.lerp(_violet, Colors.white, .45)!,
                              _violet,
                              Color.lerp(_violet, Colors.black, .35)!,
                            ],
                          ),
                        ),
                        // Glossy inner tile
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16.4),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF4A3BC4), Color(0xFF221A5E)],
                            ),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // top shine
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: 22,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(16.4),
                                    ),
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.white.withValues(alpha: .26),
                                        Colors.white.withValues(alpha: 0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Checklist + clock: your sleep sessions, logged.
                              const CustomPaint(
                                size: Size(30, 30),
                                painter: _SleepLogIconPainter(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Moon badge
                      Positioned(
                        top: -1,
                        right: -1,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            // Glossy bead
                            gradient: RadialGradient(
                              center: const Alignment(-.35, -.4),
                              colors: [
                                Color.lerp(_amber, Colors.white, .55)!,
                                _amber,
                                Color.lerp(_amber, Colors.black, .25)!,
                              ],
                              stops: const [0, .55, 1],
                            ),
                            border: Border.all(color: _bg, width: 2.5),
                          ),
                          child: const Icon(
                            Icons.nightlight_round,
                            color: Colors.white,
                            size: 11,
                          ),
                        ),
                      ),
                      // tiny twinkles
                      Positioned(
                        left: -2,
                        bottom: 6,
                        child: Opacity(
                          opacity: .35 + .65 * glow,
                          child: const Icon(
                            Icons.auto_awesome,
                            color: _cyan,
                            size: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 2),
            Text(
              "Sleep Log",
              style: TextStyle(
                color: _white(.7),
                fontSize: 10.5,
                letterSpacing: .4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Glossy 3D pill button without any shadow: lit top, darker base,
/// bright rim and a shine; sinks a little when pressed.
class _Glossy3DButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final double height;
  final VoidCallback? onTap;
  const _Glossy3DButton({
    required this.label,
    required this.color,
    this.icon,
    this.height = 50,
    this.onTap,
  });

  @override
  State<_Glossy3DButton> createState() => _Glossy3DButtonState();
}

class _Glossy3DButtonState extends State<_Glossy3DButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.height / 2.6);
    final c = widget.color;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap?.call();
      },
      child: AnimatedScale(
        scale: _down ? .95 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _down
                  ? [
                      Color.lerp(c, Colors.black, .1)!,
                      Color.lerp(c, Colors.black, .3)!,
                    ]
                  : [
                      Color.lerp(c, Colors.white, .25)!,
                      Color.lerp(c, Colors.black, .2)!,
                    ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: .3)),
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: _down ? .08 : .22),
                Colors.white.withValues(alpha: 0),
              ],
              stops: const [0, .5],
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, color: Colors.white, size: 18),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sleep Log icon: a checklist with a clock, drawn in the app's colours
/// (white paper, cyan ticks, amber pending box, violet/cyan clock).
class _SleepLogIconPainter extends CustomPainter {
  const _SleepLogIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 30; // design grid: 30 x 30

    // ---------- Paper ----------
    final paper = RRect.fromRectAndRadius(
      Rect.fromLTWH(2 * u, 1.5 * u, 17 * u, 23 * u),
      Radius.circular(3.2 * u),
    );
    canvas.drawRRect(
      paper,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Color(0xFFDCD8F5)],
        ).createShader(paper.outerRect),
    );

    // ---------- Checklist rows ----------
    void box(double y, Color c, {bool checked = true}) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(4.6 * u, y, 4.4 * u, 4.4 * u),
        Radius.circular(1.2 * u),
      );
      if (checked) {
        canvas.drawRRect(r, Paint()..color = c);
        final tick = Path()
          ..moveTo(5.6 * u, y + 2.3 * u)
          ..lineTo(6.6 * u, y + 3.3 * u)
          ..lineTo(8.1 * u, y + 1.3 * u);
        canvas.drawPath(
          tick,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1 * u
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      } else {
        canvas.drawRRect(r, Paint()..color = c);
        canvas.drawRRect(
          r.deflate(1.1 * u),
          Paint()..color = Colors.white.withValues(alpha: .85),
        );
      }
      // the text line next to the box
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(10.6 * u, y + 1.5 * u, 6 * u, 1.5 * u),
          Radius.circular(.75 * u),
        ),
        Paint()..color = const Color(0xFF2B2170).withValues(alpha: .35),
      );
    }

    box(4.2 * u, const Color(0xFF1FB5D6));
    box(10.0 * u, const Color(0xFF1FB5D6));
    box(15.8 * u, _amber, checked: false);

    // ---------- Clock ----------
    final c = Offset(20.5 * u, 20.5 * u);
    final r = 8.2 * u;
    // dark ring separates the clock from the paper
    canvas.drawCircle(c, r + 1.3 * u, Paint()..color = const Color(0xFF2B2170));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6EE7F9), Color(0xFF1FB5D6)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    // face
    canvas.drawCircle(c, r - 1.6 * u, Paint()..color = Colors.white);
    // hour ticks
    for (int i = 0; i < 12; i += 3) {
      final a = i / 12 * 2 * math.pi;
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(
        c + dir * (r - 3.0 * u),
        c + dir * (r - 2.3 * u),
        Paint()
          ..color = const Color(0xFF2B2170).withValues(alpha: .5)
          ..strokeWidth = .9 * u
          ..strokeCap = StrokeCap.round,
      );
    }
    // hands (about 10:10, bedtime)
    final hand = Paint()
      ..color = const Color(0xFF2B2170)
      ..strokeWidth = 1.3 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c, c + Offset(-2.4 * u, -1.9 * u), hand);
    canvas.drawLine(c, c + Offset(2.6 * u, -3.4 * u), hand..color = _violet);
    canvas.drawCircle(c, 1.1 * u, Paint()..color = const Color(0xFF2B2170));
  }

  @override
  bool shouldRepaint(_SleepLogIconPainter oldDelegate) => false;
}
