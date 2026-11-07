import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

class SessionTimerSettings {
  const SessionTimerSettings({
    required this.durationSeconds,
    required this.vibrationLevel,
    required this.heatLevel,
    this.wakeAlarm,
  });

  final int durationSeconds;
  final double vibrationLevel;
  final double heatLevel;

  /// When the phone should ring to wake you up, or null for no alarm.
  /// The alarm only rings — the pillow's vibration and heat stay off.
  final DateTime? wakeAlarm;
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

/// Ring is "full" at this many seconds (longer timers just show a full ring).
const int _dialMaxSeconds = 2 * 3600;

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

class SetTimerScreen extends StatefulWidget {
  const SetTimerScreen({
    super.key,
    this.initialVibrationLevel = 0.5,
    this.initialHeatLevel = 50.0,
    this.initialDurationSeconds,
    this.initialWakeAlarm,
  });

  final double initialVibrationLevel;
  final double initialHeatLevel;
  final int? initialDurationSeconds;
  final DateTime? initialWakeAlarm;

  @override
  State<SetTimerScreen> createState() => _SetTimerScreenState();
}

class _SetTimerScreenState extends State<SetTimerScreen>
    with SingleTickerProviderStateMixin {
  double selectedLevel = 0.5;
  double heatLevel = 50.0;
  int? selectedDurationSeconds;

  static const List<double> _heatLevels = [0.0, 25.0, 50.0, 75.0, 100.0];

  static const List<({int seconds, String value, String unit})> _presets = [
    (seconds: 60, value: "1", unit: "min"),
    (seconds: 300, value: "5", unit: "min"),
    (seconds: 900, value: "15", unit: "min"),
    (seconds: 1800, value: "30", unit: "min"),
    (seconds: 3600, value: "1", unit: "hour"),
    (seconds: 5400, value: "1.5", unit: "hours"),
  ];

  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  @override
  void initState() {
    super.initState();
    selectedLevel = widget.initialVibrationLevel;
    heatLevel = widget.initialHeatLevel;
    selectedDurationSeconds = widget.initialDurationSeconds;
    final alarm = widget.initialWakeAlarm;
    if (alarm != null && alarm.isAfter(DateTime.now())) {
      _alarmOn = true;
      _wakeAt = TimeOfDay.fromDateTime(alarm);
    }
    _loadBestSettings();
  }

  // ===================================================================
  // BEST SETTINGS (from your recent sessions)
  // ===================================================================
  /// Best heat / vibration found in the last 30 days, or null.
  ({int heat, int vibration, int avgSleepSeconds, int sessions})? _best;
  bool _bestLoaded = false;

  num? _num(dynamic v) => v is num ? v : null;

  Future<void> _loadBestSettings() async {
    try {
      final since = DateTime.now().subtract(const Duration(days: 30));
      final snap = await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .where("timestamp", isGreaterThanOrEqualTo: since)
          .get();

      // Group sessions that led to sleep by heat level and vibration
      // (rounded to 10%); the group with the longest average sleep wins.
      final groups = <String, List<int>>{};
      final settings = <String, (int, int)>{};
      for (final doc in snap.docs) {
        final d = doc.data();
        if (d["type"] != "session") continue;
        final sleep = (_num(d["actual_sleep_duration_seconds"]) ?? 0).toInt();
        final v =
            _num(d["final_vibration_level"]) ?? _num(d["vibration_level"]);
        final h = _num(d["final_heat_level"]) ?? _num(d["heat_level"]);
        if (sleep <= 0 || v == null || h == null) continue;
        final vib10 = ((v / 10).round() * 10).clamp(0, 100).toInt();
        final heat = _snapHeatLevel(h.toDouble()).round();
        final key = "$heat-$vib10";
        groups.putIfAbsent(key, () => []).add(sleep);
        settings[key] = (heat, vib10);
      }

      ({int heat, int vibration, int avgSleepSeconds, int sessions})? best;
      if (groups.isNotEmpty) {
        // Prefer settings used 2+ times so one lucky nap doesn't decide it.
        final hasRepeated = groups.values.any((g) => g.length >= 2);
        double bestAvg = -1;
        groups.forEach((key, sleeps) {
          if (hasRepeated && sleeps.length < 2) return;
          final avg = sleeps.reduce((a, b) => a + b) / sleeps.length;
          if (avg > bestAvg) {
            bestAvg = avg;
            final (heat, vib) = settings[key]!;
            best = (
              heat: heat,
              vibration: vib,
              avgSleepSeconds: avg.round(),
              sessions: sleeps.length,
            );
          }
        });
      }

      if (!mounted) return;
      setState(() {
        _best = best;
        _bestLoaded = true;
      });
    } catch (e) {
      debugPrint("BEST SETTINGS LOAD ERROR: $e");
      if (mounted) setState(() => _bestLoaded = true);
    }
  }

  bool get _bestApplied =>
      _best != null &&
      (selectedLevel * 100).round() == _best!.vibration &&
      heatLevel.round() == _best!.heat;

  void _applyBest() {
    final best = _best;
    if (best == null) return;
    HapticFeedback.mediumImpact();
    setState(() {
      selectedLevel = best.vibration / 100;
      heatLevel = best.heat.toDouble();
    });
  }

  Widget _bestSettingsCard() {
    // Nothing to learn from yet: show a small hint instead.
    if (_best == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: _glass(radius: 18),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_outlined, color: _white(.45), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Press Wake after your sessions and we'll recommend the settings that help you sleep longest.",
                style: TextStyle(
                  color: _white(.55),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final best = _best!;
    final applied = _bestApplied;
    final h = best.avgSleepSeconds ~/ 3600;
    final m = (best.avgSleepSeconds % 3600) ~/ 60;
    final s = best.avgSleepSeconds % 60;
    final avgText = h > 0
        ? "${h}h ${m.toString().padLeft(2, '0')}m"
        : m > 0
        ? "${m}m ${s.toString().padLeft(2, '0')}s"
        : "${s}s";

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _amber.withValues(alpha: .18),
            _amber.withValues(alpha: .18),
          ],
        ),
        border: Border.all(color: _amber.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_amber, _amber],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(13),
              boxShadow: [
                BoxShadow(
                  color: _amber.withValues(alpha: .4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("BEST FOR YOU", style: _eyebrow(color: _amber)),
                const SizedBox(height: 3),
                Text(
                  "Heat ${best.heat} · Vibration ${best.vibration}%",
                  style: _display(15, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  "Avg $avgText sleep · ${best.sessions} "
                  "${best.sessions == 1 ? 'session' : 'sessions'} (30 days)",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _white(.55), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: applied ? null : _applyBest,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: applied
                    ? null
                    : const LinearGradient(colors: [_amber, _amber]),
                color: applied ? _white(.08) : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    applied ? Icons.check_rounded : Icons.bolt_rounded,
                    color: applied ? _amber : Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    applied ? "Applied" : "Apply",
                    style: TextStyle(
                      color: applied ? _amber : Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  double _snapHeatLevel(double value) {
    double closest = _heatLevels.first;

    for (final level in _heatLevels.skip(1)) {
      if ((value - level).abs() < (value - closest).abs()) {
        closest = level;
      }
    }

    return closest;
  }

  bool get _isCustom =>
      selectedDurationSeconds != null &&
      !_presets.any((p) => p.seconds == selectedDurationSeconds);

  String _vibrationLabel(double v) {
    if (v <= 0) return "Off";
    if (v < .34) return "Gentle";
    if (v < .67) return "Moderate";
    return "Strong";
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final remainingSeconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return hours == '00'
        ? '$minutes:$remainingSeconds'
        : '$hours:$minutes:$remainingSeconds';
  }

  String _humanDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final parts = <String>[
      if (h > 0) "${h}h",
      if (m > 0) "${m}m",
      if (s > 0) "${s}s",
    ];
    return parts.isEmpty ? "0s" : parts.join(" ");
  }

  // ===================================================================
  // WAKE-AT MODE
  // ===================================================================
  /// Whether a wake-up alarm is set (separate from the session length).
  bool _alarmOn = false;
  TimeOfDay? _wakeAt;

  /// Seconds from now until the next occurrence of [t] (today or tomorrow).
  int _secondsUntil(TimeOfDay t) {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (!target.isAfter(now)) target = target.add(const Duration(days: 1));
    return target.difference(now).inSeconds;
  }

  String _formatTimeOfDay(TimeOfDay t) =>
      DateFormat('h:mm a').format(DateTime(2000, 1, 1, t.hour, t.minute));

  void _setWakeAt(TimeOfDay t) {
    HapticFeedback.selectionClick();
    setState(() {
      _wakeAt = t;
      _alarmOn = true;
    });
  }

  /// Next occurrence of the chosen wake time, or null if no alarm.
  DateTime? get _alarmDateTime {
    final t = _wakeAt;
    if (!_alarmOn || t == null) return null;
    return DateTime.now().add(Duration(seconds: _secondsUntil(t)));
  }

  /// Wake time [minutes] from now, rounded to the next 5 minutes.
  TimeOfDay _inMinutes(int minutes) {
    final t = DateTime.now().add(Duration(minutes: minutes));
    final rounded = DateTime(
      t.year,
      t.month,
      t.day,
      t.hour,
      ((t.minute + 4) ~/ 5) * 5,
    );
    return TimeOfDay.fromDateTime(rounded);
  }

  void _pickWakeTime() {
    final now = DateTime.now();
    final start = _wakeAt ?? _inMinutes(30);
    // The picker moves in 5-minute steps, so its starting time must be on
    // a 5-minute mark (a saved alarm like 3:18 would crash it otherwise).
    var picked = DateTime(
      now.year,
      now.month,
      now.day,
      start.hour,
      (start.minute ~/ 5) * 5,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final tod = TimeOfDay.fromDateTime(picked);
          final secs = _secondsUntil(tod);
          return ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF1A1250).withValues(alpha: .94),
                      const Color(0xFF1A1250).withValues(alpha: .94),
                    ],
                  ),
                  border: Border(top: BorderSide(color: _white(.14))),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: _white(.25),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text("WAKE ME AT", style: _eyebrow()),
                        const SizedBox(height: 6),
                        ShaderMask(
                          blendMode: BlendMode.srcIn,
                          shaderCallback: (r) => _mainGradient.createShader(r),
                          child: Text(
                            _formatTimeOfDay(tod),
                            style: _display(30, weight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Rings in ${_humanDuration(secs)}",
                          style: TextStyle(color: _white(.6), fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 190,
                          child: CupertinoTheme(
                            data: CupertinoThemeData(
                              brightness: Brightness.dark,
                              textTheme: CupertinoTextThemeData(
                                dateTimePickerTextStyle: _display(22),
                              ),
                            ),
                            child: CupertinoDatePicker(
                              mode: CupertinoDatePickerMode.time,
                              initialDateTime: picked,
                              minuteInterval: 5,
                              onDateTimeChanged: (d) {
                                HapticFeedback.selectionClick();
                                setSheet(() => picked = d);
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _PillButton(
                                label: "Cancel",
                                onTap: () => Navigator.pop(context),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: _PillButton(
                                label: "Set wake time",
                                icon: Icons.alarm_on_rounded,
                                gradient: _mainGradient,
                                onTap: () {
                                  Navigator.pop(context);
                                  _setWakeAt(TimeOfDay.fromDateTime(picked));
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
            ),
          );
        },
      ),
    );
  }

  Widget _alarmHeader() {
    final wake = _wakeAt;
    final on = _alarmOn;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: on
                ? _mainGradient
                : LinearGradient(colors: [_white(.12), _white(.12)]),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: _violet.withValues(alpha: .45),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            on ? Icons.alarm_on_rounded : Icons.alarm_off_rounded,
            color: on ? Colors.white : _white(.6),
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Wake-up alarm", style: _display(20)),
              const SizedBox(height: 3),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  on && wake != null
                      ? "Rings at ${_formatTimeOfDay(wake)} · pillow stays off"
                      : "Your phone rings · the pillow stays off",
                  key: ValueKey("$on${wake?.hour}${wake?.minute}"),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: on ? _cyan.withValues(alpha: .85) : _white(.4),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: _alarmOn,
          activeThumbColor: Colors.white,
          activeTrackColor: _violet,
          inactiveThumbColor: _white(.7),
          inactiveTrackColor: _white(.12),
          onChanged: (on) {
            HapticFeedback.selectionClick();
            setState(() {
              _alarmOn = on;
              // Turning it on with no time yet: suggest one cycle-friendly
              // time after the session (session + 15 min + 90 min).
              if (on && _wakeAt == null) {
                final session = (selectedDurationSeconds ?? 0) ~/ 60;
                _wakeAt = _inMinutes(session + 15 + 90);
              }
            });
          },
        ),
      ],
    );
  }

  /// "1h 29m" / "15m" — short, no seconds.
  String _shortDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h == 0) return "${m}m";
    return m == 0 ? "${h}h" : "${h}h ${m}m";
  }

  Widget _wakeCard() {
    final wake = _wakeAt;
    final secs = wake == null ? null : _secondsUntil(wake);

    // Quick picks: a power nap and whole 90-minute sleep cycles
    // (+15 min to fall asleep), so you wake between cycles.
    final suggestions = <({String label, int minutes, IconData icon})>[
      (label: "Power nap", minutes: 20, icon: Icons.bolt_rounded),
      (label: "1 cycle", minutes: 15 + 90, icon: Icons.nightlight_round),
      (label: "5 cycles", minutes: 15 + 5 * 90, icon: Icons.bedtime_rounded),
      (label: "6 cycles", minutes: 15 + 6 * 90, icon: Icons.hotel_rounded),
    ];

    final ringsBeforeSessionEnds =
        secs != null &&
        selectedDurationSeconds != null &&
        secs < selectedDurationSeconds!;

    // Split "6:25 AM" into the time and the AM/PM part.
    final timeText = wake == null ? null : _formatTimeOfDay(wake);
    final space = timeText?.lastIndexOf(" ") ?? -1;
    final clock = timeText == null
        ? null
        : (space > 0 ? timeText.substring(0, space) : timeText);
    final ampm = timeText != null && space > 0
        ? timeText.substring(space + 1)
        : "";

    final sessionSecs = selectedDurationSeconds ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ringsBeforeSessionEnds) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _amber.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _amber.withValues(alpha: .35)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: _amber,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "The alarm rings before your session ends. Vibration and heat will turn off when it rings.",
                    style: TextStyle(color: _white(.8), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        GestureDetector(
          onTap: _pickWakeTime,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _violet.withValues(alpha: .22),
                  _violet.withValues(alpha: .22),
                  _violet.withValues(alpha: .22),
                ],
              ),
              border: Border.all(color: _violet.withValues(alpha: .35)),
              boxShadow: [
                BoxShadow(
                  color: _violet.withValues(alpha: .15),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        gradient: _mainGradient,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: _violet.withValues(alpha: .5),
                            blurRadius: 16,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.alarm_rounded,
                        color: Colors.white,
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("WAKE UP AT", style: _eyebrow()),
                          const SizedBox(height: 4),
                          if (clock == null)
                            Text(
                              "Pick a time",
                              style: _display(
                                20,
                                weight: FontWeight.w700,
                                color: _white(.6),
                              ),
                            )
                          else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text(
                                  clock,
                                  style: _display(32, weight: FontWeight.w700),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  ampm,
                                  style: _display(
                                    15,
                                    weight: FontWeight.w600,
                                    color: _white(.6),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _white(.08),
                        border: Border.all(color: _white(.1)),
                      ),
                      child: Icon(
                        Icons.edit_rounded,
                        color: _white(.7),
                        size: 16,
                      ),
                    ),
                  ],
                ),
                if (secs != null) ...[
                  const SizedBox(height: 14),
                  // Tonight at a glance: pillow session, then sleep.
                  LayoutBuilder(
                    builder: (context, box) {
                      final total = math.max(secs, 1);
                      final sessionPart = (math.min(sessionSecs, secs) / total)
                          .clamp(0.0, 1.0);
                      return Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              height: 7,
                              child: Row(
                                children: [
                                  if (sessionPart > 0)
                                    Container(
                                      width: box.maxWidth * sessionPart,
                                      decoration: const BoxDecoration(
                                        gradient: _heatGradient,
                                      ),
                                    ),
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            _violet.withValues(alpha: .9),
                                            _violet.withValues(alpha: .9),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              _legendDot(_flame),
                              Text(
                                " Session ${_shortDuration(math.min(sessionSecs, secs))}",
                                style: TextStyle(
                                  color: _white(.6),
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(width: 10),
                              _legendDot(_violet),
                              Text(
                                " Sleep ~${_shortDuration(math.max(secs - sessionSecs, 0))}",
                                style: TextStyle(
                                  color: _white(.6),
                                  fontSize: 11,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _cyan.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: _cyan.withValues(alpha: .35),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.hourglass_bottom_rounded,
                                      color: _cyan,
                                      size: 12,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      "in ${_shortDuration(secs)}",
                                      style: const TextStyle(
                                        color: _cyan,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final (i, sug) in suggestions.indexed) ...[
              Expanded(
                child: Builder(
                  builder: (context) {
                    final t = _inMinutes(sug.minutes);
                    final selected =
                        wake != null &&
                        wake.hour == t.hour &&
                        wake.minute == t.minute;
                    return GestureDetector(
                      onTap: () => _setWakeAt(t),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 10,
                        ),
                        decoration: selected
                            ? BoxDecoration(
                                gradient: _mainGradient,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: _violet.withValues(alpha: .45),
                                    blurRadius: 14,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              )
                            : _glass(radius: 16),
                        child: Column(
                          children: [
                            Icon(
                              sug.icon,
                              size: 16,
                              color: selected ? Colors.white : _cyan,
                            ),
                            const SizedBox(height: 5),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _formatTimeOfDay(t),
                                style: _display(13.5, weight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                sug.label,
                                style: TextStyle(
                                  color: selected ? _white(.9) : _white(.5),
                                  fontSize: 10.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (i < suggestions.length - 1) const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }

  Widget _legendDot(Color c) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(shape: BoxShape.circle, color: c),
  );

  void _selectDuration(int seconds) {
    HapticFeedback.selectionClick();
    setState(() => selectedDurationSeconds = seconds);
  }

  void _save() {
    if (selectedDurationSeconds == null) return;
    HapticFeedback.mediumImpact();
    Navigator.pop(
      context,
      SessionTimerSettings(
        durationSeconds: selectedDurationSeconds!,
        vibrationLevel: selectedLevel,
        heatLevel: heatLevel,
        wakeAlarm: _alarmDateTime,
      ),
    );
  }

  // ================= CUSTOM TIMER =================
  void showCustomTimeDialog() {
    final initial = selectedDurationSeconds ?? 0;
    int selectedHours = initial ~/ 3600 % 24;
    int selectedMinutes = (initial % 3600) ~/ 60;
    int selectedSeconds = initial % 60;

    final hCtrl = FixedExtentScrollController(initialItem: selectedHours);
    final mCtrl = FixedExtentScrollController(initialItem: selectedMinutes);
    final sCtrl = FixedExtentScrollController(initialItem: selectedSeconds);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final totalSeconds =
                (selectedHours * 3600) +
                (selectedMinutes * 60) +
                selectedSeconds;

            Widget wheel(
              FixedExtentScrollController controller,
              int count,
              String unit,
              ValueChanged<int> onChanged,
            ) {
              return Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: CupertinoPicker(
                        scrollController: controller,
                        itemExtent: 46,
                        diameterRatio: 1.3,
                        squeeze: 1.1,
                        selectionOverlay: const SizedBox.shrink(),
                        onSelectedItemChanged: (i) {
                          HapticFeedback.selectionClick();
                          setDialogState(() => onChanged(i));
                        },
                        children: List.generate(
                          count,
                          (i) => Center(
                            child: Text(
                              i.toString().padLeft(2, '0'),
                              style: _display(26),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      unit,
                      style: TextStyle(
                        color: _white(.5),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              );
            }

            return ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(32),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF1A1250).withValues(alpha: .94),
                        const Color(0xFF1A1250).withValues(alpha: .94),
                      ],
                    ),
                    border: Border(top: BorderSide(color: _white(.14))),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 42,
                            height: 4,
                            decoration: BoxDecoration(
                              color: _white(.25),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text("CUSTOM DURATION", style: _eyebrow()),
                          const SizedBox(height: 6),
                          ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (r) =>
                                _mainGradient.createShader(r),
                            child: Text(
                              totalSeconds == 0
                                  ? "Choose a time"
                                  : _humanDuration(totalSeconds),
                              style: _display(30, weight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 190,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Selection highlight
                                Container(
                                  height: 48,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    color: _white(.07),
                                    border: Border.all(color: _white(.1)),
                                  ),
                                ),
                                Row(
                                  children: [
                                    wheel(
                                      hCtrl,
                                      24,
                                      "hr",
                                      (v) => selectedHours = v,
                                    ),
                                    wheel(
                                      mCtrl,
                                      60,
                                      "min",
                                      (v) => selectedMinutes = v,
                                    ),
                                    wheel(
                                      sCtrl,
                                      60,
                                      "sec",
                                      (v) => selectedSeconds = v,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                child: _PillButton(
                                  label: "Cancel",
                                  onTap: () => Navigator.pop(context),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 2,
                                child: _PillButton(
                                  label: "Set duration",
                                  icon: Icons.check_rounded,
                                  gradient: _mainGradient,
                                  onTap: totalSeconds <= 0
                                      ? null
                                      : () {
                                          Navigator.pop(context);
                                          _selectDuration(totalSeconds);
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
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      // Wait for the sheet's close animation before disposing.
      Future.delayed(const Duration(milliseconds: 500), () {
        hCtrl.dispose();
        mCtrl.dispose();
        sCtrl.dispose();
      });
    });
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
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 150),
              children: [
                _Entrance(index: 0, child: _header()),
                const SizedBox(height: 24),
                _Entrance(index: 1, child: _dialCard()),
                const SizedBox(height: 26),
                _Entrance(
                  index: 2,
                  child: _sectionTitle("Comfort", "Set how the pillow feels"),
                ),
                const SizedBox(height: 12),
                if (_bestLoaded) ...[
                  _Entrance(index: 3, child: _bestSettingsCard()),
                  const SizedBox(height: 8),
                ],
                _Entrance(index: 3, child: buildLevelSlider()),
                const SizedBox(height: 8),
                _Entrance(index: 4, child: buildHeatSlider()),
                const SizedBox(height: 26),
                _Entrance(
                  index: 5,
                  child: _sectionTitle(
                    "Session length",
                    "Vibration & heat to help you fall asleep",
                  ),
                ),
                const SizedBox(height: 12),
                _Entrance(index: 6, child: _presetGrid()),
                const SizedBox(height: 26),
                _Entrance(index: 7, child: _alarmHeader()),
                const SizedBox(height: 12),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _alarmOn
                      ? _wakeCard()
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _actionBar()),
        ],
      ),
    );
  }

  // ===================================================================
  // HEADER
  // ===================================================================
  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: Colors.transparent,
          child: Ink(
            decoration: _glass(radius: 16),
            child: InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(16),
              child: const SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 26),
        Text(
          "SESSION TIMER",
          style: _eyebrow(color: _cyan.withValues(alpha: .85)),
        ),
        const SizedBox(height: 8),
        Text("Set Timer", style: _display(38, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          "Choose how long your session runs and how it feels.",
          style: TextStyle(color: _white(.6), fontSize: 14),
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
  // DIAL
  // ===================================================================
  Widget _dialCard() {
    final secs = selectedDurationSeconds;
    final progress = secs == null ? 0.0 : secs / _dialMaxSeconds;
    final endsAt = secs == null
        ? null
        : DateFormat(
            'h:mm a',
          ).format(DateTime.now().add(Duration(seconds: secs)));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _violet.withValues(alpha: .40),
            _violet.withValues(alpha: .40),
            _violet.withValues(alpha: .40),
          ],
        ),
        border: Border.all(color: _white(.12)),
        boxShadow: [
          BoxShadow(
            color: _violet.withValues(alpha: .22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => SizedBox(
              width: 128,
              height: 128,
              child: CustomPaint(
                painter: _DialPainter(value),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: FittedBox(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (c, a) => FadeTransition(
                          opacity: a,
                          child: ScaleTransition(
                            scale: Tween(begin: .9, end: 1.0).animate(a),
                            child: c,
                          ),
                        ),
                        child: Text(
                          secs == null ? "--:--" : _formatDuration(secs),
                          key: ValueKey(secs),
                          style: _display(24, weight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dialInfo(Icons.flag_rounded, endsAt ?? "Not set", "Ends at"),
                const SizedBox(height: 10),
                _dialInfo(
                  Icons.waves_rounded,
                  "${(selectedLevel * 100).round()}%",
                  "Vibration",
                ),
                const SizedBox(height: 10),
                _dialInfo(
                  Icons.local_fire_department_rounded,
                  "${heatLevel.round()}",
                  "Heat",
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dialInfo(IconData icon, String value, String label) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: _white(.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: _cyan, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: _white(.55), fontSize: 12),
          ),
        ),
        Text(value, style: _display(14, weight: FontWeight.w700)),
      ],
    );
  }

  // ===================================================================
  // PRESETS
  // ===================================================================
  Widget _presetGrid() {
    const gap = 8.0;
    return LayoutBuilder(
      builder: (context, box) {
        final unit = (box.maxWidth - gap * 3) / 4;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final p in _presets)
              SizedBox(
                width: unit,
                child: buildButton(p.value, p.seconds, unit: p.unit),
              ),
            SizedBox(width: unit * 2 + gap, child: _customTile()),
          ],
        );
      },
    );
  }

  BoxDecoration _pillDecoration(bool selected) => selected
      ? BoxDecoration(
          gradient: _mainGradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: _violet.withValues(alpha: .45),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        )
      : _glass(radius: 16);

  // ================= PRESET BUTTON =================
  Widget buildButton(String text, int sec, {String unit = ""}) {
    final isSelected = selectedDurationSeconds == sec;
    final shortUnit = unit.startsWith("hour") ? "hr" : unit;
    // Relative length bar (longest preset = full).
    final fill = (sec / _presets.last.seconds).clamp(0.08, 1.0);

    return GestureDetector(
      onTap: () => _selectDuration(sec),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: 54,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        decoration: _pillDecoration(isSelected),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: text,
                      style: _display(17, weight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: " $shortUnit",
                      style: TextStyle(
                        color: isSelected ? _white(.9) : _white(.5),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Container(
                height: 3,
                color: isSelected ? _white(.3) : _white(.08),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fill,
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.white : null,
                      gradient: isSelected
                          ? null
                          : LinearGradient(
                              colors: [
                                _violet.withValues(alpha: .7),
                                _violet.withValues(alpha: .7),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customTile() {
    final active = _isCustom;
    return GestureDetector(
      onTap: showCustomTimeDialog,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: _pillDecoration(active),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _white(.22) : _violet.withValues(alpha: .18),
                border: Border.all(
                  color: active ? _white(.3) : _violet.withValues(alpha: .4),
                ),
              ),
              child: Icon(
                Icons.tune_rounded,
                size: 16,
                color: active ? Colors.white : _cyan,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    active
                        ? _humanDuration(selectedDurationSeconds!)
                        : "Custom",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _display(15, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    active ? "Tap to change" : "Any length you like",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? _white(.85) : _white(.45),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: active ? Colors.white : _white(.4),
            ),
          ],
        ),
      ),
    );
  }

  // ===================================================================
  // SLIDERS
  // ===================================================================
  Widget buildLevelSlider() {
    final pct = (selectedLevel * 100).round();
    return _controlCard(
      icon: Icons.waves_rounded,
      title: "Vibration",
      caption: _vibrationLabel(selectedLevel),
      level: selectedLevel,
      value: "$pct",
      unit: "%",
      gradient: _mainGradient,
      badge: _MiniLevelBars(level: selectedLevel, gradient: _mainGradient),
      child: _ComfortSlider(
        value: selectedLevel,
        gradient: _mainGradient,
        onChanged: (val) {
          setState(() {
            selectedLevel = val;
          });
        },
      ),
      footer: Row(
        children: [
          for (final v in const [0.0, .25, .5, .75, 1.0])
            _tickLabel(
              v == 0 ? "Off" : (v == 1 ? "Max" : "${(v * 100).round()}"),
              gradient: _mainGradient,
              selected: (selectedLevel - v).abs() < .005,
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => selectedLevel = v);
              },
            ),
        ],
      ),
    );
  }

  Widget buildHeatSlider() {
    final h = heatLevel.round();
    return _controlCard(
      icon: Icons.local_fire_department_rounded,
      title: "Heat",
      caption: h <= 0
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
      badge: _MiniLevelBars(level: heatLevel / 100, gradient: _heatGradient),
      child: _ComfortSlider(
        value: heatLevel / 100,
        gradient: _heatGradient,
        steps: 4,
        onChanged: (val) {
          final selectedHeat = _snapHeatLevel(val * 100);
          if (selectedHeat != heatLevel) HapticFeedback.selectionClick();
          setState(() {
            heatLevel = selectedHeat;
          });
        },
      ),
      footer: Row(
        children: [
          for (final level in _heatLevels)
            _tickLabel(
              level == 0 ? "Off" : (level == 100 ? "Max" : "${level.round()}"),
              gradient: _heatGradient,
              selected: heatLevel == level,
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => heatLevel = level);
              },
            ),
        ],
      ),
    );
  }

  /// Small preset chip under the slider (Off · 25 · 50 · 75 · Max).
  Widget _tickLabel(
    String text, {
    required LinearGradient gradient,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: selected ? gradient : null,
            color: selected ? null : _white(.045),
            border: Border.all(
              color: selected ? Colors.transparent : _white(.07),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: gradient.colors.last.withValues(alpha: .4),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            text,
            style: TextStyle(
              color: selected ? Colors.white : _white(.5),
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlCard({
    required IconData icon,
    required String title,
    required String caption,
    required double level,
    required String value,
    required String unit,
    required LinearGradient gradient,
    required Widget child,
    Widget? badge,
    Widget? footer,
  }) {
    final l = level.clamp(0.0, 1.0);
    final on = l > 0;
    final accent = gradient.colors.last;
    final tint = .03 + .1 * l;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            gradient.colors.first.withValues(alpha: tint),
            gradient.colors.first.withValues(alpha: tint),
            gradient.colors.first.withValues(alpha: tint),
          ],
        ),
        border: Border.all(
          color: on ? accent.withValues(alpha: .15 + .25 * l) : _white(.09),
        ),
        boxShadow: on
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: .06 + .1 * l),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: on
                      ? gradient
                      : LinearGradient(colors: [_white(.14), _white(.14)]),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: on
                      ? [
                          BoxShadow(
                            color: gradient.colors.first.withValues(
                              alpha: .3 + .3 * l,
                            ),
                            blurRadius: 8 + 8 * l,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
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
              // Status: glowing dot + label
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? accent : _white(.3),
                  boxShadow: on
                      ? [BoxShadow(color: accent, blurRadius: 5)]
                      : null,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  caption.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: on ? _white(.7) : _white(.4),
                    fontSize: 9.5,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (badge != null) ...[badge, const SizedBox(width: 10)],
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => gradient.createShader(r),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(value, style: _display(20, weight: FontWeight.w700)),
                    Text(unit, style: _display(11, weight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
          if (footer != null) ...[const SizedBox(height: 4), footer],
        ],
      ),
    );
  }

  // ===================================================================
  // BOTTOM ACTION BAR
  // ===================================================================
  Widget _actionBar() {
    final ready = selectedDurationSeconds != null;
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: _surface.withValues(alpha: .7),
            border: Border(top: BorderSide(color: _white(.1))),
          ),
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ready
                              ? _humanDuration(selectedDurationSeconds!)
                              : "No duration",
                          style: _display(18, weight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Vibration ${(selectedLevel * 100).round()}% · "
                          "Heat ${heatLevel.round()}"
                          "${_alarmOn && _wakeAt != null ? ' · ⏰ ${_formatTimeOfDay(_wakeAt!)}' : ''}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _white(.55), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 160,
                    child: _PillButton(
                      label: "Save timer",
                      icon: Icons.check_rounded,
                      gradient: _mainGradient,
                      onTap: ready ? _save : null,
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

// =====================================================================
// SMALL WIDGETS
// =====================================================================

/// Thick gradient slider with a glowing thumb. [value] is 0..1.
class _GlowSlider extends StatelessWidget {
  final double value;
  final Gradient gradient;
  final ValueChanged<double> onChanged;

  /// When set, the track shows this many equal steps as dots.
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
                // Track
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
                // Step dots
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
                // Active fill
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
                          blurRadius: 12,
                        ),
                      ],
                    ),
                  ),
                ),
                // Thumb
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
                          blurRadius: 14,
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

class _PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Gradient? gradient;
  final VoidCallback? onTap;

  const _PillButton({
    required this.label,
    this.icon,
    this.gradient,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1 : .4,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: gradient != null
              ? BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: enabled
                      ? [
                          BoxShadow(
                            color: _violet.withValues(alpha: .45),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ]
                      : null,
                )
              : _glass(radius: 18),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 52,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: Colors.white, size: 20),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
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

/// Circular dial with 60 tick marks and a gradient progress arc.
class _DialPainter extends CustomPainter {
  final double progress;
  _DialPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final stroke = outer * .09;
    final radius = outer * .8;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final p = progress.clamp(0.0, 1.0);

    // Ticks
    for (int i = 0; i < 60; i++) {
      final angle = -math.pi / 2 + 2 * math.pi * i / 60;
      final lit = i / 60 < p;
      final major = i % 5 == 0;
      final r1 = outer * (major ? .9 : .94);
      final r2 = outer - 1;
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * r1,
        center + Offset(math.cos(angle), math.sin(angle)) * r2,
        Paint()
          ..color = lit
              ? _cyan.withValues(alpha: .9)
              : _white(major ? .25 : .12)
          ..strokeWidth = major ? 1.6 : 1
          ..strokeCap = StrokeCap.round,
      );
    }

    // Track
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = _white(.08),
    );

    if (p <= 0) return;

    final sweep = math.max(2 * math.pi * p, 0.05);
    final shader = const SweepGradient(
      colors: [_violet, _violet, _violet, _violet],
      transform: GradientRotation(-math.pi / 2),
    ).createShader(rect);

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = shader;

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
    canvas.drawArc(rect, -math.pi / 2, sweep, false, arcPaint);

    // Knob at the end of the arc
    final endAngle = -math.pi / 2 + sweep;
    final knob =
        center + Offset(math.cos(endAngle), math.sin(endAngle)) * radius;
    canvas.drawCircle(
      knob,
      stroke * .9,
      Paint()
        ..color = _cyan.withValues(alpha: .6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(knob, stroke * .55, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.progress != progress;
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
    final delay = math.min(index, 9) * 60;
    final total = 500 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 26 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Compact comfort slider: segmented track, gradient fill and a glowing
/// two-tone thumb. [value] is 0..1.
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
    const thumb = 22.0;
    const track = 8.0;
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
                      color: Colors.black.withValues(alpha: .25),
                      borderRadius: BorderRadius.circular(track / 2),
                      border: Border.all(color: _white(.07)),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  left: thumb / 2,
                  width: math.max(usable * v, 0),
                  child: Container(
                    height: track,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(track / 2),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: .55),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                  ),
                ),
                for (int i = 1; i < marks; i++)
                  Positioned(
                    left: thumb / 2 + usable * i / marks - 1,
                    child: Container(
                      width: 2,
                      height: steps != null ? 5 : 3.5,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(1),
                        color: i / marks <= v
                            ? Colors.white.withValues(alpha: .55)
                            : _white(.18),
                      ),
                    ),
                  ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  left: usable * v,
                  child: Container(
                    width: thumb,
                    height: thumb,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: .7),
                          blurRadius: 14,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .35),
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Container(
                      width: 8,
                      height: 8,
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

/// Five tiny rising bars that light up with the level.
class _MiniLevelBars extends StatelessWidget {
  final double level;
  final LinearGradient gradient;
  const _MiniLevelBars({required this.level, required this.gradient});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < 5; i++) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 3,
              height: 4.0 + i * 3,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1.5),
                gradient: level > i / 5 ? gradient : null,
                color: level > i / 5 ? null : _white(.14),
              ),
            ),
            if (i < 4) const SizedBox(width: 2.5),
          ],
        ],
      ),
    );
  }
}
