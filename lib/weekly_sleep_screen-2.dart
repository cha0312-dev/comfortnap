import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

// =====================================================================
// DESIGN TOKENS (match the other redesigned screens)
// =====================================================================
const Color _bg = Color(0xFF07031F);
const Color _surface = Color(0xFF151040);
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);
const Color _green = Color(0xFF34D399);
const Color _rose = Color(0xFFFF6F91);
const Color _amber = Color(0xFFFFB547);

const LinearGradient _comfortGradient = LinearGradient(
  colors: [_amber, Color(0xFFFF7E5F)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient _bedtimeGradient = LinearGradient(
  colors: [_violet, _magenta],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

/// Adult sleep recommendation (National Sleep Foundation / AASM):
/// 7–9 hours per night.
const int _healthyMinSeconds = 7 * 3600;
const int _healthyMaxSeconds = 9 * 3600;

/// A day with less than this much sleep is treated as naps, not a night.
const int _napMaxSeconds = 3 * 3600;

/// Status of one day's total sleep against the adult guideline.
typedef _SleepStatus = ({String label, Color color, IconData icon});

_SleepStatus? _statusFor(int seconds) {
  if (seconds <= 0) return null;
  if (seconds < _napMaxSeconds) {
    return (label: "Nap", color: _cyan, icon: Icons.bolt_rounded);
  }
  if (seconds < _healthyMinSeconds) {
    return (label: "Short", color: _amber, icon: Icons.south_rounded);
  }
  if (seconds <= _healthyMaxSeconds) {
    return (label: "Healthy", color: _green, icon: Icons.favorite_rounded);
  }
  return (label: "Long", color: _magenta, icon: Icons.north_rounded);
}

const LinearGradient _goalGradient = LinearGradient(
  colors: [Color(0xFF10B981), _green],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient _mainGradient = LinearGradient(
  colors: [_violet, _cyan],
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

class WeeklySleepScreen extends StatefulWidget {
  final DateTime selectedDate;

  const WeeklySleepScreen({super.key, required this.selectedDate});

  @override
  State<WeeklySleepScreen> createState() => _WeeklySleepScreenState();
}

class _WeeklySleepScreenState extends State<WeeklySleepScreen>
    with SingleTickerProviderStateMixin {
  late DateTime weekStart;
  late DateTime weekEnd;

  List<int> dailySleep = List.filled(7, 0);
  int totalSleep = 0;

  /// Selected tab: 0 Overview, 1 Chart, 2 Habits, 3 Days.
  int _tab = 0;

  /// Total actual sleep in the previous week (for the comparison badge).
  int lastWeekSleep = 0;

  /// Total sleep for the 4 weeks ending with this one (oldest first).
  List<int> fourWeekTotals = List.filled(4, 0);

  /// Session records (type "session") started this week, for comfort insights.
  List<Map<String, dynamic>> weekSessions = [];

  /// When the main sleep of each day (Sun..Sat) started, or null.
  List<DateTime?> bedtimes = List.filled(7, null);

  /// When the main sleep of each day ended (wake-up time), or null.
  List<DateTime?> wakeTimes = List.filled(7, null);

  /// Daily sleep goal in seconds (saved in Firestore app_settings/sleep_goal).
  int goalSeconds = 30 * 60;

  static const List<int> _goalOptions = [
    10 * 60,
    15 * 60,
    20 * 60,
    30 * 60,
    45 * 60,
    60 * 60,
    90 * 60,
    2 * 3600,
    4 * 3600,
    6 * 3600,
    7 * 3600,
    8 * 3600,
    9 * 3600,
  ];
  bool isLoading = true;

  final List<String> days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _setWeek(widget.selectedDate);
    loadWeeklyData();
    _loadGoal();
  }

  // ===================================================================
  // SLEEP GOAL
  // ===================================================================
  DocumentReference<Map<String, dynamic>> get _goalDoc =>
      FirebaseFirestore.instance.collection("app_settings").doc("sleep_goal");

  Future<void> _loadGoal() async {
    try {
      final snap = await _goalDoc.get();
      final value = snap.data()?["seconds"];
      if (value is num && value > 0 && mounted) {
        setState(() => goalSeconds = value.toInt());
      }
    } catch (e) {
      debugPrint("GOAL LOAD ERROR: $e");
    }
  }

  Future<void> _saveGoal(int seconds) async {
    HapticFeedback.selectionClick();
    setState(() => goalSeconds = seconds);
    try {
      await _goalDoc.set({
        "seconds": seconds,
        "updated_at": FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("GOAL SAVE ERROR: $e");
    }
  }

  bool _metGoal(int seconds) => seconds > 0 && seconds >= goalSeconds;

  int get _goalDaysMet => dailySleep.where(_metGoal).length;

  void _editGoal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF1A1250).withValues(alpha: .98),
              _bg.withValues(alpha: .99),
            ],
          ),
          border: Border(top: BorderSide(color: _white(.14))),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
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
                // 3D sphere with a highlight and a solid shadow base.
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      center: Alignment(-.35, -.45),
                      radius: 1.0,
                      colors: [Color(0xFF9DF5CF), _green, Color(0xFF0B7F57)],
                      stops: [0, .5, 1],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .25),
                    ),
                    boxShadow: [
                      const BoxShadow(
                        color: Color(0xFF064D35),
                        offset: Offset(0, 4),
                      ),
                      BoxShadow(
                        color: _green.withValues(alpha: .5),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.flag_rounded,
                    color: Colors.white,
                    size: 27,
                    shadows: [
                      Shadow(color: Colors.black38, offset: Offset(0, 2)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text("Daily sleep goal", style: _display(22)),
                const SizedBox(height: 4),
                Text(
                  "Adults need 7–9h a night · power naps work best at 10–20m",
                  style: TextStyle(color: _white(.55), fontSize: 13),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final option in _goalOptions)
                      _GoalKey(
                        label: _goalLabel(option),
                        selected: option == goalSeconds,
                        // 7–9h keys get a faint green rim (healthy range).
                        healthy:
                            option >= _healthyMinSeconds &&
                            option <= _healthyMaxSeconds,
                        onTap: () {
                          Navigator.pop(context);
                          _saveGoal(option);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _goalLabel(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h == 0) return "${m}m";
    if (m == 0) return "${h}h";
    return "${h}h ${m}m";
  }

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  /// Week runs Sunday 00:00 → Saturday 23:59:59.
  void _setWeek(DateTime anyDay) {
    final d = DateUtils.dateOnly(anyDay);
    weekStart = DateTime(d.year, d.month, d.day - d.weekday % 7);
    weekEnd = DateTime(weekStart.year, weekStart.month, weekStart.day + 6);
  }

  DateTime get _nextWeekStart =>
      DateTime(weekStart.year, weekStart.month, weekStart.day + 7);

  bool get _canGoForward => !_nextWeekStart.isAfter(DateTime.now());

  void _changeWeek(int delta) {
    if (delta > 0 && !_canGoForward) return;
    HapticFeedback.selectionClick();
    setState(() {
      _setWeek(
        DateTime(weekStart.year, weekStart.month, weekStart.day + 7 * delta),
      );
    });
    loadWeeklyData();
  }

  /// Sums actual sleep per day (Sun..Sat) for the week starting [from].
  /// Uses the "sleep" records saved at Wake / sent by the device — the same
  /// source as the Monthly screen, so totals match.
  /// When [bedtimesOut] is given it is filled with the start time of the
  /// longest sleep of each day (the day's "main" sleep).
  Future<List<int>> _sleepPerDay(
    DateTime from, {
    List<DateTime?>? bedtimesOut,
    List<DateTime?>? wakeOut,
  }) async {
    final to = DateTime(from.year, from.month, from.day + 7);
    final snapshot = await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .where("sleep_start", isGreaterThanOrEqualTo: from)
        .where("sleep_start", isLessThan: to)
        .orderBy("sleep_start")
        .get();

    final perDay = List<int>.filled(7, 0);
    final longest = List<int>.filled(7, -1);
    for (var doc in snapshot.docs) {
      final data = doc.data();

      final ts = data["sleep_start"];
      if (ts is! Timestamp) continue;
      final index = ts.toDate().weekday % 7;

      // Prefer exact seconds; older/device records only have minutes.
      final seconds = data["sleep_duration_seconds"];
      final minutes = data["sleep_duration_minutes"];
      int duration = seconds is num
          ? seconds.toInt()
          : minutes is num
          ? (minutes * 60).toInt()
          : 0;
      if (duration < 0) duration = 0;

      perDay[index] += duration;

      if (bedtimesOut != null && duration > longest[index]) {
        longest[index] = duration;
        bedtimesOut[index] = ts.toDate();
        if (wakeOut != null) {
          final end = data["sleep_end"];
          wakeOut[index] = end is Timestamp
              ? end.toDate()
              : ts.toDate().add(Duration(seconds: duration));
        }
      }
    }
    return perDay;
  }

  /// Session documents (vibration / heat / pillow temperature) for the week.
  Future<List<Map<String, dynamic>>> _sessionsFor(DateTime from) async {
    final to = DateTime(from.year, from.month, from.day + 7);
    final snapshot = await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .where("timestamp", isGreaterThanOrEqualTo: from)
        .where("timestamp", isLessThan: to)
        .get();
    return [
      for (final doc in snapshot.docs)
        if (doc.data()["type"] == "session") doc.data(),
    ];
  }

  Future<void> loadWeeklyData() async {
    setState(() => isLoading = true);

    final start = weekStart;
    final previousStart = DateTime(start.year, start.month, start.day - 7);

    // Load this week and last week at the same time.
    final weekBedtimes = List<DateTime?>.filled(7, null);
    final weekWakes = List<DateTime?>.filled(7, null);
    final sessionsFuture = _sessionsFor(start);
    final results = await Future.wait([
      _sleepPerDay(start, bedtimesOut: weekBedtimes, wakeOut: weekWakes),
      _sleepPerDay(previousStart),
      _sleepPerDay(DateTime(start.year, start.month, start.day - 14)),
      _sleepPerDay(DateTime(start.year, start.month, start.day - 21)),
    ]);
    final sessions = await sessionsFuture;

    // Ignore results if the user already switched to another week.
    if (!mounted || start != weekStart) return;

    final thisWeek = results[0];
    final previousWeek = results[1];

    setState(() {
      dailySleep = thisWeek;
      totalSleep = thisWeek.fold(0, (a, b) => a + b);
      lastWeekSleep = previousWeek.fold(0, (a, b) => a + b);
      fourWeekTotals = [
        for (final w in results.reversed) w.fold(0, (a, b) => a + b),
      ];
      bedtimes = weekBedtimes;
      wakeTimes = weekWakes;
      weekSessions = sessions;
      isLoading = false;
    });
  }

  String formatDuration(int seconds) {
    if (seconds <= 0) return "0m";
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;

    if (h > 0) return "${h}h ${m.toString().padLeft(2, '0')}m";
    if (m > 0) return "${m}m ${s.toString().padLeft(2, '0')}s";
    return "${s}s";
  }

  DateTime _dayAt(int i) =>
      DateTime(weekStart.year, weekStart.month, weekStart.day + i);

  // ===================================================================
  // SLEEP DEBT
  // ===================================================================
  int get _loggedDays => dailySleep.where((s) => s > 0).length;

  /// Positive = short of the goal, negative = ahead of it.
  int get _sleepDebt => goalSeconds * _loggedDays - totalSleep;

  String _hm(int seconds) {
    final s = seconds.abs();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return m == 0 ? "${h}h" : "${h}h ${m}m";
    if (m > 0) return "${m}m";
    return "${s}s";
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
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
              children: [
                _Entrance(index: 0, child: _header()),
                const SizedBox(height: 20),
                _Entrance(index: 1, child: _weekSwitcher()),
                const SizedBox(height: 16),
                _Entrance(index: 2, child: _tabBar()),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topCenter,
                    children: [...previous, if (current != null) current],
                  ),
                  child: isLoading
                      ? _loading()
                      : Column(
                          key: ValueKey("$weekStart-$_tab"),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _tabContent(),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _tabContent() {
    switch (_tab) {
      case 1:
        return [
          _Entrance(index: 0, child: buildBarChart()),
          const SizedBox(height: 16),
          _Entrance(index: 1, child: _fourWeekCard()),
        ];
      case 2:
        return [
          _Entrance(index: 0, child: _bedtimeCard()),
          const SizedBox(height: 16),
          _Entrance(index: 1, child: _wakeCard()),
          const SizedBox(height: 16),
          _Entrance(index: 2, child: _weekdayWeekendCard()),
          const SizedBox(height: 16),
          _Entrance(index: 3, child: _comfortCard()),
        ];
      case 3:
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text("Daily breakdown", style: _display(20)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Tap a day to see its sessions",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _white(.4), fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < 7; i++)
            _Entrance(index: i, child: buildSleepCard(i)),
        ];
      default:
        return [
          _Entrance(index: 0, child: _summaryCard()),
          const SizedBox(height: 12),
          _Entrance(index: 1, child: _debtCard()),
        ];
    }
  }

  // ===================================================================
  // OVERVIEW: SLEEP DEBT
  // ===================================================================
  Widget _debtCard() {
    final logged = _loggedDays;
    final debt = _sleepDebt;
    final short = logged > 0 && debt > 59;
    final color = logged == 0
        ? _white(.4)
        : short
        ? _rose
        : _green;

    // Gentle catch-up: spread over 4 nights, 15–60 min extra per night.
    final perNight = short
        ? (((debt / 4 / 60) / 5).round() * 5).clamp(15, 60)
        : 0;

    final String value = logged == 0
        ? "—"
        : short
        ? _hm(debt)
        : debt < -59
        ? "+${_hm(debt)}"
        : "None";

    final String note = logged == 0
        ? "No nights logged"
        : short
        ? "short of ${_goalLabel(goalSeconds)} × $logged"
        : debt < -59
        ? "ahead of your goal"
        : "right on your goal";

    // How much of the goal hours were actually slept (for the 3D meter).
    final needed = goalSeconds * logged;
    final fill = needed == 0 ? 0.0 : (totalSleep / needed).clamp(0.0, 1.0);

    return _slab(
      tint: logged == 0 ? _violet : (short ? _rose : _green),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text("SLEEP DEBT", style: _eyebrow()),
              const Spacer(),
              Container(
                width: 28,
                height: 28,
                decoration: _key(color, radius: 9),
                child: Icon(
                  short ? Icons.trending_down_rounded : Icons.verified_rounded,
                  color: color,
                  size: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _text3D(value, 30, Colors.white),
          ),
          const SizedBox(height: 4),
          Text(note, style: TextStyle(color: _white(.55), fontSize: 11.5)),
          if (logged > 0) ...[
            const SizedBox(height: 12),
            // 3D meter: slept vs needed this week.
            Container(
              height: 14,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.black.withValues(alpha: .35),
                border: Border.all(color: Colors.white.withValues(alpha: .08)),
              ),
              child: LayoutBuilder(
                builder: (context, box) => Align(
                  alignment: Alignment.centerLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: fill),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    builder: (context, f, _) => Container(
                      width: math.max(box.maxWidth * f, 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color.lerp(_cyan, Colors.white, .3)!,
                            _violet,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _violet.withValues(alpha: .55),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  "Slept ${_hm(totalSleep)}",
                  style: TextStyle(color: _white(.55), fontSize: 10.5),
                ),
                const Spacer(),
                Text(
                  "Needed ${_hm(needed)}",
                  style: TextStyle(color: _white(.55), fontSize: 10.5),
                ),
              ],
            ),
          ],
          if (short) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_rounded, color: _amber, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    debt > 10 * 3600
                        ? "Too big to repay at once. Aim for +${perNight}m a night."
                        : "Try +${perNight}m a night for 4 nights.",
                    style: TextStyle(
                      color: _white(.8),
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ===================================================================
  // LAST 4 WEEKS TREND
  // ===================================================================
  Widget _fourWeekCard() {
    final totals = fourWeekTotals;
    final maxTotal = totals.fold<int>(0, (a, b) => math.max(a, b));
    final current = totals.last;
    final earlier = totals.sublist(0, 3).where((t) => t > 0).toList();
    final earlierAvg = earlier.isEmpty
        ? null
        : earlier.reduce((a, b) => a + b) ~/ earlier.length;

    String badge;
    Color badgeColor;
    IconData badgeIcon;
    String message;
    if (earlierAvg == null) {
      badge = "New";
      badgeColor = _white(.55);
      badgeIcon = Icons.auto_awesome_rounded;
      message = "Keep logging. Your trend appears once you have earlier weeks.";
    } else {
      final diff = current - earlierAvg;
      final pct = earlierAvg == 0 ? 0 : (diff.abs() / earlierAvg * 100).round();
      if (diff.abs() < 15 * 60 || pct < 5) {
        badge = "Steady";
        badgeColor = _cyan;
        badgeIcon = Icons.trending_flat_rounded;
        message =
            "About the same as your 3-week average of ${_hm(earlierAvg)}.";
      } else if (diff > 0) {
        badge = "+$pct%";
        badgeColor = _green;
        badgeIcon = Icons.trending_up_rounded;
        message =
            "${_hm(diff)} more than your 3-week average. You're improving!";
      } else {
        badge = "−$pct%";
        badgeColor = _rose;
        badgeIcon = Icons.trending_down_rounded;
        message =
            "${_hm(diff)} less than your 3-week average of ${_hm(earlierAvg)}.";
      }
    }

    String labelFor(int k) {
      if (k == 3 && !_canGoForward) return "This wk";
      final st = DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day - 7 * (3 - k),
      );
      return DateFormat('MMM d').format(st);
    }

    return _slab(
      tint: _violet,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color.lerp(_violet, Colors.white, .25)!, _violet],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color.lerp(_violet, Colors.black, .55)!,
                      offset: const Offset(0, 3),
                    ),
                    BoxShadow(
                      color: _violet.withValues(alpha: .45),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.show_chart_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Last 4 weeks", style: _display(17)),
                    const SizedBox(height: 2),
                    Text(
                      "Total sleep per week · tap one to open it",
                      style: TextStyle(color: _white(.5), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: _key(badgeColor, radius: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(badgeIcon, color: badgeColor, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      badge,
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 168,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int k = 0; k < 4; k++) ...[
                  if (k > 0) const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: k == 3 ? null : () => _changeWeek(k - 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              totals[k] == 0 ? "—" : _hm(totals[k]),
                              style: _display(
                                12.5,
                                weight: FontWeight.w700,
                                color: k == 3 ? Colors.white : _white(.7),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          TweenAnimationBuilder<double>(
                            tween: Tween(
                              begin: 0,
                              end: maxTotal == 0 ? 0 : totals[k] / maxTotal,
                            ),
                            duration: Duration(milliseconds: 600 + 120 * k),
                            curve: Curves.easeOutCubic,
                            builder: (context, v, _) => SizedBox(
                              height: math.max(10, 100 * v) + 12,
                              width: double.infinity,
                              child: CustomPaint(
                                painter: _Block3DPainter(
                                  color: totals[k] == 0
                                      ? _white(.25)
                                      : k == 3
                                      ? _violet
                                      : const Color(0xFF4A3FB0),
                                  highlight: k == 3
                                      ? _cyan
                                      : const Color(0xFF6B5BFF),
                                  selected: k == 3,
                                  empty: totals[k] == 0,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            labelFor(k),
                            maxLines: 1,
                            style: TextStyle(
                              color: k == 3 ? _white(.85) : _white(.45),
                              fontSize: 10.5,
                              fontWeight: k == 3
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: .08)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(badgeIcon, color: badgeColor, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: _white(.75),
                      fontSize: 12.5,
                      height: 1.4,
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

  // ===================================================================
  // TABS
  // ===================================================================
  static const List<({String label, IconData icon})> _tabs = [
    (label: "Overview", icon: Icons.dashboard_rounded),
    (label: "Chart", icon: Icons.bar_chart_rounded),
    (label: "Habits", icon: Icons.auto_awesome_rounded),
    (label: "Days", icon: Icons.calendar_view_week_rounded),
  ];

  Widget _tabBar() {
    final logged = dailySleep.where((s) => s > 0).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 5, 5, 8),
      decoration: _tray().copyWith(borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          for (int i = 0; i < _tabs.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_tab == i) return;
                  HapticFeedback.selectionClick();
                  setState(() => _tab = i);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  height: 50,
                  // Selected tab pops up as a glossy 3D key.
                  transform: Matrix4.translationValues(0, _tab == i ? -2 : 0, 0),
                  decoration: BoxDecoration(
                    gradient: _tab == i
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.lerp(_violet, Colors.white, .15)!,
                              _cyan,
                            ],
                          )
                        : null,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _tab == i
                          ? Colors.white.withValues(alpha: .3)
                          : Colors.transparent,
                    ),
                    boxShadow: _tab == i
                        ? [
                            BoxShadow(
                              color: Color.lerp(_violet, Colors.black, .55)!,
                              offset: const Offset(0, 4),
                            ),
                            BoxShadow(
                              color: _cyan.withValues(alpha: .4),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _tabs[i].icon,
                        size: 17,
                        color: _tab == i ? Colors.white : _white(.5),
                        shadows: _tab == i
                            ? const [
                                Shadow(
                                  color: Colors.black38,
                                  offset: Offset(0, 1.5),
                                ),
                              ]
                            : null,
                      ),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          i == 3 && !isLoading
                              ? "${_tabs[i].label} ($logged/7)"
                              : _tabs[i].label,
                          style: TextStyle(
                            color: _tab == i ? Colors.white : _white(.55),
                            fontSize: 11.5,
                            fontWeight: _tab == i
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
        _roundButton(
          Icons.arrow_back_ios_new_rounded,
          () => Navigator.pop(context),
          size: 48,
          radius: 16,
        ),
        const SizedBox(height: 24),
        Text(
          "WEEKLY REPORT",
          style: _eyebrow(color: _cyan.withValues(alpha: .85)),
        ),
        const SizedBox(height: 8),
        Text("Weekly Sleep", style: _display(36, weight: FontWeight.w700)),
      ],
    );
  }

  Widget _weekSwitcher() {
    final now = DateTime.now();
    final isThisWeek = !now.isBefore(weekStart) && now.isBefore(_nextWeekStart);

    return _slab(
      tint: _violet,
      radius: 22,
      depth: 5,
      padding: const EdgeInsets.fromLTRB(7, 7, 7, 10),
      child: Row(
        children: [
          _roundButton(Icons.chevron_left_rounded, () => _changeWeek(-1)),
          Expanded(
            child: Column(
              children: [
                Text(
                  "${DateFormat('MMM d').format(weekStart)} – "
                  "${DateFormat('MMM d, y').format(weekEnd)}",
                  style: _display(15.5, weight: FontWeight.w700).copyWith(
                    shadows: const [
                      Shadow(color: Colors.black54, offset: Offset(0, 2)),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isThisWeek ? "This week" : "Past week",
                  style: TextStyle(color: _white(.5), fontSize: 11.5),
                ),
              ],
            ),
          ),
          Opacity(
            opacity: _canGoForward ? 1 : .3,
            child: _roundButton(
              Icons.chevron_right_rounded,
              () => _changeWeek(1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundButton(
    IconData icon,
    VoidCallback onTap, {
    double size = 40,
    double radius = 14,
  }) {
    return _PressKey(
      onTap: onTap,
      size: size,
      radius: radius,
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }


  // ===================================================================
  // SUMMARY
  // ===================================================================
  // ===================================================================
  // 3D HELPERS
  // ===================================================================
  /// A raised "slab": tinted face, glossy top sheen, a solid darker
  /// edge underneath (thickness) and a soft coloured glow.
  Widget _slab({
    required Color tint,
    required Widget child,
    double radius = 24,
    EdgeInsets padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
    double depth = 6,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: depth),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          // Solid edge = slab thickness.
          BoxShadow(
            color: Color.lerp(tint, Colors.black, .72)!,
            offset: Offset(0, depth),
          ),
          // Soft glow under the slab.
          BoxShadow(
            color: tint.withValues(alpha: .28),
            blurRadius: 26,
            offset: Offset(0, depth + 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(tint, const Color(0xFF151040), .35)!,
                      Color.lerp(tint, const Color(0xFF0B0726), .72)!,
                    ],
                  ),
                ),
              ),
            ),
            // Glossy sheen on the top half.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 60,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: .10),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            // Bright top edge + subtle frame.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: Colors.white.withValues(alpha: .1)),
                ),
              ),
            ),
            Positioned(
              left: radius,
              right: radius,
              top: 0,
              height: 1.2,
              child: ColoredBox(color: Colors.white.withValues(alpha: .35)),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }

  /// Extruded 3D number: stacked darker copies behind the face.
  Widget _text3D(String text, double size, Color color) {
    final edge = Color.lerp(color, Colors.black, .6)!;
    return Text(
      text,
      style: _display(size, weight: FontWeight.w800, color: color).copyWith(
        shadows: [
          for (int k = 1; k <= 4; k++)
            Shadow(color: edge, offset: Offset(0, k.toDouble())),
          Shadow(
            color: color.withValues(alpha: .45),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
    );
  }

  /// Small raised "key" (chip with a solid darker bottom edge).
  BoxDecoration _key(Color tint, {double radius = 12, bool on = true}) =>
      BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: on
              ? [
                  Color.lerp(tint, Colors.white, .12)!.withValues(alpha: .32),
                  tint.withValues(alpha: .16),
                ]
              : [_white(.10), _white(.05)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .45),
            offset: const Offset(0, 3),
          ),
        ],
      );

  /// Glossy 3D icon tile: lit top, solid darker edge, coloured glow.
  BoxDecoration _iconKey(Color c, {Gradient? gradient}) => BoxDecoration(
    borderRadius: BorderRadius.circular(12),
    gradient:
        gradient ??
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(c, Colors.white, .28)!, c],
        ),
    border: Border.all(color: Colors.white.withValues(alpha: .2)),
    boxShadow: [
      BoxShadow(
        color: Color.lerp(c, Colors.black, .55)!,
        offset: const Offset(0, 3),
      ),
      BoxShadow(
        color: c.withValues(alpha: .45),
        blurRadius: 12,
        offset: const Offset(0, 6),
      ),
    ],
  );

  /// Recessed tray (pressed into the card).
  BoxDecoration _tray({Color? tint}) => BoxDecoration(
    borderRadius: BorderRadius.circular(14),
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.black.withValues(alpha: .34),
        (tint ?? Colors.black).withValues(alpha: tint == null ? .16 : .1),
      ],
    ),
    border: Border.all(
      color: (tint ?? Colors.white).withValues(alpha: tint == null ? .07 : .3),
    ),
  );

  /// Raised panel inside a card (thicker than a key).
  BoxDecoration _raisedPanel(Color tint) => BoxDecoration(
    borderRadius: BorderRadius.circular(16),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.lerp(tint, Colors.white, .1)!.withValues(alpha: .24),
        tint.withValues(alpha: .07),
      ],
    ),
    border: Border.all(color: tint.withValues(alpha: .35)),
    boxShadow: [
      BoxShadow(
        color: Color.lerp(tint, Colors.black, .78)!,
        offset: const Offset(0, 4),
      ),
      BoxShadow(
        color: tint.withValues(alpha: .18),
        blurRadius: 14,
        offset: const Offset(0, 8),
      ),
    ],
  );

  // ===================================================================
  // SUMMARY (3D)
  // ===================================================================
  Widget _summaryCard() {
    final loggedDays = dailySleep.where((s) => s > 0).length;
    final avg = loggedDays == 0 ? 0 : totalSleep ~/ loggedDays;
    int best = 0;
    for (int i = 1; i < 7; i++) {
      if (dailySleep[i] > dailySleep[best]) best = i;
    }

    return _slab(
      tint: _violet,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("TOTAL SLEEP", style: _eyebrow()),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: totalSleep.toDouble()),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) => _text3D(
                          totalSleep == 0 ? "—" : formatDuration(v.round()),
                          34,
                          Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _comparisonBadge(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _goalRow(),
          const SizedBox(height: 12),
          Row(
            children: [
              _miniStat(
                Icons.event_available_rounded,
                "$loggedDays/7",
                "days",
                _cyan,
              ),
              const SizedBox(width: 8),
              _miniStat(
                Icons.av_timer_rounded,
                loggedDays == 0 ? "-" : _shortDur(avg),
                "avg",
                _violet,
              ),
              const SizedBox(width: 8),
              _miniStat(
                Icons.emoji_events_rounded,
                loggedDays == 0 ? "-" : days[best],
                "best",
                _amber,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "1h 14m" / "24m" / "45s" — no seconds once there are minutes.
  String _shortDur(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return m == 0 ? "${h}h" : "${h}h ${m}m";
    if (m > 0) return "${m}m";
    return "${seconds}s";
  }

  /// Goal bar: flag · 7 raised 3D segments · met count · edit.
  Widget _goalRow() {
    final met = _goalDaysMet;
    return GestureDetector(
      onTap: _editGoal,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.black.withValues(alpha: .22),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
        ),
        child: Row(
          children: [
            const Icon(Icons.flag_rounded, color: _green, size: 15),
            const SizedBox(width: 5),
            Text(
              "Goal ${_goalLabel(goalSeconds)}",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            for (int i = 0; i < 7; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final hit = _metGoal(dailySleep[i]);
                    final logged = dailySleep[i] > 0;
                    final c = hit ? _green : (logged ? _violet : null);
                    return Container(
                      height: 7,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: c == null
                            ? null
                            : LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color.lerp(c, Colors.white, .35)!,
                                  c,
                                ],
                              ),
                        color: c == null ? _white(.1) : null,
                        boxShadow: [
                          BoxShadow(
                            color: c == null
                                ? Colors.black.withValues(alpha: .4)
                                : Color.lerp(c, Colors.black, .55)!,
                            offset: const Offset(0, 2),
                          ),
                          if (hit)
                            BoxShadow(
                              color: _green.withValues(alpha: .45),
                              blurRadius: 6,
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(width: 10),
            Text(
              "$met/7",
              style: _display(13, weight: FontWeight.w800, color: _green),
            ),
            const SizedBox(width: 4),
            Icon(Icons.edit_rounded, color: _white(.45), size: 13),
          ],
        ),
      ),
    );
  }

  Widget _comparisonBadge() {
    final diff = totalSleep - lastWeekSleep;

    late final IconData icon;
    late final Color color;
    late final String text;

    if (totalSleep == 0 && lastWeekSleep == 0) {
      icon = Icons.remove_rounded;
      color = _white(.5);
      text = "No data";
    } else if (lastWeekSleep == 0) {
      icon = Icons.auto_awesome_rounded;
      color = _cyan;
      text = "First week";
    } else if (diff.abs() < 60) {
      icon = Icons.drag_handle_rounded;
      color = _white(.7);
      text = "Same as last wk";
    } else {
      final up = diff > 0;
      final pct = (diff.abs() / lastWeekSleep * 100).round();
      icon = up ? Icons.trending_up_rounded : Icons.trending_down_rounded;
      color = up ? _green : _rose;
      text =
          "${up ? '+' : '−'}${_shortDur(diff.abs())}"
          "${pct > 0 ? ' · ${up ? '+' : '−'}$pct%' : ''}";
    }

    return Tooltip(
      message: "Compared with last week",
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: _key(color, radius: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Small raised stat key: icon · value · label.
  Widget _miniStat(IconData icon, String value, String label, Color tint) {
    return Expanded(
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: _key(tint),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: tint, size: 15),
              const SizedBox(width: 5),
              Text(value, style: _display(14, weight: FontWeight.w800)),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: _white(.55), fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  // ===================================================================
  // CHART
  // ===================================================================
  // ===================================================================
  // BEDTIME & CONSISTENCY
  // ===================================================================
  int _minutesOfDay(DateTime t) => t.hour * 60 + t.minute;

  /// Average bedtime (minutes after midnight) and average deviation from it.
  /// Uses a circular mean so 11:30 PM and 12:30 AM average to midnight,
  /// not noon.
  ({int mean, int spread, int days})? _bedtimeStats() => _timeStats(bedtimes);

  /// Circular mean + average deviation for any list of clock times.
  ({int mean, int spread, int days})? _timeStats(List<DateTime?> times) {
    final mins = [
      for (final b in times)
        if (b != null) _minutesOfDay(b),
    ];
    if (mins.isEmpty) return null;

    double sx = 0, sy = 0;
    for (final m in mins) {
      final a = m / 1440 * 2 * math.pi;
      sx += math.cos(a);
      sy += math.sin(a);
    }
    var angle = math.atan2(sy, sx);
    if (angle < 0) angle += 2 * math.pi;
    final mean = (angle / (2 * math.pi) * 1440).round() % 1440;

    int total = 0;
    for (final m in mins) {
      var d = (m - mean).abs() % 1440;
      if (d > 720) d = 1440 - d;
      total += d;
    }
    return (mean: mean, spread: total ~/ mins.length, days: mins.length);
  }

  String _clock(int minutesOfDay) =>
      DateFormat('h:mm a').format(DateTime(2000, 1, 1, 0, minutesOfDay));

  String _spreadText(int minutes) {
    if (minutes < 60) return "${minutes}m";
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? "${h}h" : "${h}h ${m}m";
  }

  Widget _bedtimeCard() {
    final stats = _bedtimeStats();

    // Consistency rating
    String rating;
    Color ratingColor;
    if (stats == null || stats.days < 2) {
      rating = "Need 2+ days";
      ratingColor = _white(.55);
    } else if (stats.spread <= 30) {
      rating = "Very consistent";
      ratingColor = _green;
    } else if (stats.spread <= 60) {
      rating = "Consistent";
      ratingColor = _cyan;
    } else if (stats.spread <= 120) {
      rating = "A bit irregular";
      ratingColor = _amber;
    } else {
      rating = "Irregular";
      ratingColor = _rose;
    }

    // Round the headline time to the nearest 5 minutes ("around").
    final around = stats == null ? null : ((stats.mean / 5).round() * 5) % 1440;

    String message;
    if (stats == null) {
      message = "No sleep logged this week, so there's no bedtime to show yet.";
    } else if (stats.days < 2) {
      message =
          "Log sleep on at least 2 days to see how consistent your bedtime is.";
    } else if (stats.spread <= 60) {
      message =
          "Your bedtime only varies by about ${_spreadText(stats.spread)}. "
          "A regular schedule keeps your body clock steady. Nice work!";
    } else {
      message =
          "Your bedtime varies by about ${_spreadText(stats.spread)}. "
          "Try falling asleep within the same 30-minute window each day; "
          "regular sleep times improve sleep quality.";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _glass(radius: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: _bedtimeGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _magenta.withValues(alpha: .4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.bedtime_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Bedtime consistency", style: _display(17)),
                    const SizedBox(height: 2),
                    Text(
                      "When your main sleep started each day",
                      style: TextStyle(color: _white(.5), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: ratingColor.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  rating,
                  style: TextStyle(
                    color: ratingColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (around != null) ...[
            const SizedBox(height: 16),
            Text(
              "You usually fall asleep around",
              style: TextStyle(color: _white(.6), fontSize: 13),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (r) => _bedtimeGradient.createShader(r),
                  child: Text(
                    _clock(around),
                    style: _display(32, weight: FontWeight.w700),
                  ),
                ),
                if (stats!.days >= 2) ...[
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      "± ${_spreadText(stats.spread)}",
                      style: _display(
                        16,
                        weight: FontWeight.w600,
                        color: ratingColor,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 18),
          _BedtimeTrack(
            bedtimes: bedtimes,
            days: days,
            meanMinutes: stats?.mean,
            spreadMinutes: (stats?.days ?? 0) >= 2 ? stats!.spread : null,
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _white(.05),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_rounded, color: _amber, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: _white(.75),
                      fontSize: 12.5,
                      height: 1.4,
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

  // ===================================================================
  // WAKE-UP CONSISTENCY
  // ===================================================================
  ({String label, Color color}) _consistencyRating(
    ({int mean, int spread, int days})? stats,
  ) {
    if (stats == null || stats.days < 2) {
      return (label: "Need 2+ days", color: _white(.55));
    }
    if (stats.spread <= 30) return (label: "Very consistent", color: _green);
    if (stats.spread <= 60) return (label: "Consistent", color: _cyan);
    if (stats.spread <= 120) return (label: "A bit irregular", color: _amber);
    return (label: "Irregular", color: _rose);
  }

  Widget _habitHeader(
    IconData icon,
    Color color,
    String title,
    String subtitle, {
    String? badge,
    Color? badgeColor,
  }) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: _iconKey(color),
          child: Icon(icon, color: Colors.white, size: 19),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _display(17)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(color: _white(.5), fontSize: 11.5),
              ),
            ],
          ),
        ),
        if (badge != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: _key(badgeColor ?? _white(.5), radius: 12),
            child: Text(
              badge,
              style: TextStyle(
                color: badgeColor ?? _white(.6),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  Widget _tipBox(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _tray(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_rounded, color: _amber, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: _white(.75), fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wakeCard() {
    final stats = _timeStats(wakeTimes);
    final rating = _consistencyRating(stats);
    final around = stats == null ? null : ((stats.mean / 5).round() * 5) % 1440;

    String message;
    if (stats == null) {
      message = "No wake-ups logged this week yet.";
    } else if (stats.days < 2) {
      message = "Log sleep on at least 2 days to see your wake-up pattern.";
    } else if (stats.spread <= 60) {
      message =
          "You wake within about ${_spreadText(stats.spread)} of the same time. "
          "A steady wake-up time is the strongest anchor for your body clock.";
    } else {
      message =
          "Your wake-up time varies by about ${_spreadText(stats.spread)}. "
          "Try getting up at the same time every day, even on weekends; "
          "use the wake-up alarm in Set Timer to help.";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _glass(radius: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _habitHeader(
            Icons.wb_sunny_rounded,
            _amber,
            "Wake-up consistency",
            "When your main sleep ended each day",
            badge: rating.label,
            badgeColor: rating.color,
          ),
          if (around != null) ...[
            const SizedBox(height: 16),
            Text(
              "You usually wake up around",
              style: TextStyle(color: _white(.6), fontSize: 13),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _clock(around),
                  style: _display(32, weight: FontWeight.w700, color: _amber),
                ),
                if (stats!.days >= 2) ...[
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      "± ${_spreadText(stats.spread)}",
                      style: _display(16, color: rating.color),
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 18),
          _BedtimeTrack(
            bedtimes: wakeTimes,
            days: days,
            meanMinutes: stats?.mean,
            spreadMinutes: (stats?.days ?? 0) >= 2 ? stats!.spread : null,
            axisStart: 18 * 60,
            labels: const ["6 PM", "12 AM", "6 AM", "12 PM", "6 PM"],
            highlightLabel: "6 AM",
            color: _amber,
          ),
          const SizedBox(height: 14),
          _tipBox(message),
        ],
      ),
    );
  }

  // ===================================================================
  // WEEKDAY vs WEEKEND
  // ===================================================================
  /// Middle of the main sleep, in minutes of the day.
  int? _midSleep(int i) {
    final b = bedtimes[i];
    final w = wakeTimes[i];
    if (b == null || w == null || !w.isAfter(b)) return null;
    return _minutesOfDay(
      b.add(Duration(seconds: w.difference(b).inSeconds ~/ 2)),
    );
  }

  int? _circularMean(List<int> mins) {
    if (mins.isEmpty) return null;
    double sx = 0, sy = 0;
    for (final m in mins) {
      final a = m / 1440 * 2 * math.pi;
      sx += math.cos(a);
      sy += math.sin(a);
    }
    var angle = math.atan2(sy, sx);
    if (angle < 0) angle += 2 * math.pi;
    return (angle / (2 * math.pi) * 1440).round() % 1440;
  }

  /// Signed minutes from a to b on a 24h clock (−720..720).
  int _clockDiff(int a, int b) {
    var d = (b - a) % 1440;
    if (d > 720) d -= 1440;
    return d;
  }

  Widget _weekdayWeekendCard() {
    const weekdayIdx = [1, 2, 3, 4, 5];
    const weekendIdx = [0, 6];

    ({int? avgSleep, int? bed, int? wake, int? mid, int days}) group(
      List<int> idx,
    ) {
      final logged = [
        for (final i in idx)
          if (dailySleep[i] > 0) i,
      ];
      return (
        avgSleep: logged.isEmpty
            ? null
            : logged.map((i) => dailySleep[i]).reduce((a, b) => a + b) ~/
                  logged.length,
        bed: _circularMean([
          for (final i in idx)
            if (bedtimes[i] != null) _minutesOfDay(bedtimes[i]!),
        ]),
        wake: _circularMean([
          for (final i in idx)
            if (wakeTimes[i] != null) _minutesOfDay(wakeTimes[i]!),
        ]),
        mid: _circularMean([
          for (final i in idx)
            if (_midSleep(i) case final m?) m,
        ]),
        days: logged.length,
      );
    }

    final wd = group(weekdayIdx);
    final we = group(weekendIdx);

    // Social jet lag = shift of the middle of your sleep on weekends.
    final shift = wd.mid != null && we.mid != null
        ? _clockDiff(wd.mid!, we.mid!)
        : null;

    String badge;
    Color badgeColor;
    String message;
    if (shift == null) {
      badge = "Need both";
      badgeColor = _white(.55);
      message =
          "Log sleep on a weekday and on the weekend to compare your schedules.";
    } else {
      final abs = shift.abs();
      final dir = shift >= 0 ? "later" : "earlier";
      if (abs < 60) {
        badge = "Steady";
        badgeColor = _green;
        message =
            "Your weekend sleep is only ${_spreadText(abs)} $dir than on weekdays. "
            "Great: your body clock stays in sync all week.";
      } else if (abs < 120) {
        badge = "Small shift";
        badgeColor = _amber;
        message =
            "You sleep ${_spreadText(abs)} $dir on weekends. "
            "Keeping it under 1h makes Mondays easier.";
      } else {
        badge = "Social jet lag";
        badgeColor = _rose;
        message =
            "You sleep ${_spreadText(abs)} $dir on weekends, like flying to "
            "another time zone and back each week. Try to keep weekend "
            "bedtime and wake-up within 1h of your weekdays.";
      }
    }

    Widget column(
      String title,
      Color color,
      ({int? avgSleep, int? bed, int? wake, int? mid, int days}) g,
    ) {
      Widget line(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(icon, color: _white(.45), size: 13),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: _white(.5), fontSize: 11.5)),
            const Spacer(),
            Text(
              value,
              style: _display(13.5, weight: FontWeight.w800).copyWith(
                shadows: const [
                  Shadow(color: Colors.black54, offset: Offset(0, 1.5)),
                ],
              ),
            ),
          ],
        ),
      );

      return Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: _raisedPanel(color),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                  ),
                ),
                const Spacer(),
                Text(
                  "${g.days}d",
                  style: TextStyle(color: _white(.4), fontSize: 10.5),
                ),
              ],
            ),
            line(
              Icons.hotel_rounded,
              "Sleep",
              g.avgSleep == null ? "—" : _hm(g.avgSleep!),
            ),
            line(
              Icons.bedtime_rounded,
              "Bed",
              g.bed == null ? "—" : _clock(g.bed!),
            ),
            line(
              Icons.wb_sunny_rounded,
              "Wake",
              g.wake == null ? "—" : _clock(g.wake!),
            ),
          ],
        ),
      );
    }

    return _slab(
      tint: _violet,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _habitHeader(
            Icons.compare_arrows_rounded,
            _violet,
            "Weekdays vs weekend",
            "Mon–Fri compared with Sat–Sun",
            badge: badge,
            badgeColor: badgeColor,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: column("WEEKDAYS", _cyan, wd)),
              const SizedBox(width: 10),
              Expanded(child: column("WEEKEND", _magenta, we)),
            ],
          ),
          if (shift != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  "Weekend shift",
                  style: TextStyle(color: _white(.6), fontSize: 12.5),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: _key(badgeColor, radius: 10),
                  child: Text(
                    shift.abs() < 5
                        ? "None"
                        : "${shift > 0 ? '+' : '−'}${_spreadText(shift.abs())} "
                              "${shift > 0 ? 'later' : 'earlier'}",
                    style: _display(
                      14,
                      weight: FontWeight.w800,
                      color: badgeColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _tipBox(message),
        ],
      ),
    );
  }

  // ===================================================================
  // COMFORT INSIGHTS
  // ===================================================================
  num? _num(dynamic v) => v is num ? v : null;

  /// Final level if the user changed it mid-session, otherwise the start level.
  num? _vibrationOf(Map<String, dynamic> s) =>
      _num(s["final_vibration_level"]) ?? _num(s["vibration_level"]);

  num? _heatOf(Map<String, dynamic> s) =>
      _num(s["final_heat_level"]) ?? _num(s["heat_level"]);

  int _sleepOf(Map<String, dynamic> s) =>
      (_num(s["actual_sleep_duration_seconds"]) ?? 0).toInt();

  Widget _comfortCard() {
    final sessions = weekSessions;

    // Averages / most-used values
    final vibs = [
      for (final s in sessions)
        if (_vibrationOf(s) case final v?) v,
    ];
    final heats = [
      for (final s in sessions)
        if (_heatOf(s) case final h?) h,
    ];
    final temps = [
      for (final s in sessions)
        if (_num(s["final_pillow_temperature"]) case final t?) t,
    ];

    final avgVib = vibs.isEmpty
        ? null
        : (vibs.fold<num>(0, (a, b) => a + b) / vibs.length).round();

    int? topHeat;
    if (heats.isNotEmpty) {
      final counts = <int, int>{};
      for (final h in heats) {
        counts[h.round()] = (counts[h.round()] ?? 0) + 1;
      }
      topHeat = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    }

    final avgTemp = temps.isEmpty
        ? null
        : temps.fold<num>(0, (a, b) => a + b) / temps.length;

    // Best settings: group sessions that led to sleep by heat level and
    // vibration (rounded to 10%), then pick the group with the longest
    // average sleep.
    final groups = <String, List<int>>{};
    final groupSettings = <String, (int, int)>{};
    for (final s in sessions) {
      final sleep = _sleepOf(s);
      final v = _vibrationOf(s);
      final h = _heatOf(s);
      if (sleep <= 0 || v == null || h == null) continue;
      final vib10 = ((v / 10).round() * 10).clamp(0, 100).toInt();
      final heat = h.round();
      final key = "$heat-$vib10";
      groups.putIfAbsent(key, () => []).add(sleep);
      groupSettings[key] = (heat, vib10);
    }

    String? insight;
    if (groups.isNotEmpty) {
      String? bestKey;
      double bestAvg = -1;
      groups.forEach((key, sleeps) {
        final avg = sleeps.reduce((a, b) => a + b) / sleeps.length;
        if (avg > bestAvg) {
          bestAvg = avg;
          bestKey = key;
        }
      });
      final (heat, vib) = groupSettings[bestKey]!;
      final sleepsWithData = groups.values.fold<int>(0, (a, b) => a + b.length);
      insight = sleepsWithData >= 2
          ? "Your longest sleeps happened with heat at $heat and "
                "vibration around $vib% (avg ${formatDuration(bestAvg.round())})."
          : "Your sleep this week followed heat at $heat and vibration "
                "around $vib%. Log more sessions to find your best settings.";
    }

    return _slab(
      tint: _amber,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: _iconKey(_amber, gradient: _comfortGradient),
                child: const Icon(
                  Icons.tune_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Comfort insights", style: _display(17)),
                    const SizedBox(height: 2),
                    Text(
                      sessions.isEmpty
                          ? "Settings used in your sessions"
                          : "From ${sessions.length} "
                                "${sessions.length == 1 ? 'session' : 'sessions'} this week",
                      style: TextStyle(color: _white(.5), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _comfortTile(
                icon: Icons.waves_rounded,
                label: "Avg vibration",
                value: avgVib == null ? "-" : "$avgVib%",
                level: avgVib == null ? null : avgVib / 100,
                gradient: _mainGradient,
              ),
              const SizedBox(width: 8),
              _comfortTile(
                icon: Icons.local_fire_department_rounded,
                label: "Most-used heat",
                value: topHeat == null ? "-" : "$topHeat",
                level: topHeat == null ? null : topHeat / 100,
                gradient: _comfortGradient,
              ),
              const SizedBox(width: 8),
              _comfortTile(
                icon: Icons.device_thermostat_rounded,
                label: "Avg pillow",
                value: avgTemp == null
                    ? "-"
                    : "${avgTemp.toStringAsFixed(1)}°C",
                gradient: _bedtimeGradient,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: _tray(tint: insight == null ? null : _amber),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  insight == null
                      ? Icons.info_outline_rounded
                      : Icons.auto_awesome_rounded,
                  color: insight == null ? _white(.5) : _amber,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    insight ??
                        (sessions.isEmpty
                            ? "No sessions this week. Start a session to see which settings help you sleep best."
                            : "Press Wake after your sessions so we can learn which settings give you the longest sleep."),
                    style: TextStyle(
                      color: _white(.8),
                      fontSize: 12.5,
                      height: 1.4,
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

  Widget _comfortTile({
    required IconData icon,
    required String label,
    required String value,
    required Gradient gradient,
    double? level,
  }) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(10),
        decoration: _raisedPanel(gradient.colors.last),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: _iconKey(
                gradient.colors.last,
                gradient: gradient,
              ).copyWith(borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: Colors.white, size: 14),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: _display(17, weight: FontWeight.w800).copyWith(
                  shadows: const [
                    Shadow(color: Colors.black54, offset: Offset(0, 2)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _white(.5), fontSize: 10),
            ),
            const SizedBox(height: 8),
            // Recessed 3D meter
            Container(
              height: 7,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: Colors.black.withValues(alpha: .4),
                border: Border.all(color: Colors.white.withValues(alpha: .06)),
              ),
              child: level == null
                  ? null
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: level.clamp(0.0, 1.0),
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: gradient,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: [
                              BoxShadow(
                                color: gradient.colors.last.withValues(
                                  alpha: .55,
                                ),
                                blurRadius: 6,
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
    );
  }

  Widget buildBarChart() {
    final longestDay = dailySleep.reduce(math.max);
    // Show the 7–9h band only when real nights were logged; otherwise
    // short naps would be squashed at the bottom of a 9h-tall chart.
    final showHealthyBand = longestDay >= _napMaxSeconds;
    final maxSec = math.max(
      math.max(longestDay, goalSeconds),
      showHealthyBand ? _healthyMaxSeconds : 0,
    );
    final useHours = maxSec >= 3600;
    final divisor = useHours ? 3600.0 : 60.0;
    final unit = useHours ? "h" : "m";

    final rawMax = maxSec / divisor;
    final interval = _niceInterval(rawMax == 0 ? 4 : rawMax * 1.2 / 4);
    final maxY = rawMax == 0
        ? interval * 4
        : (rawMax * 1.2 / interval).ceilToDouble() * interval;

    final loggedDays = dailySleep.where((s) => s > 0).length;
    final avgY = loggedDays == 0 ? 0.0 : (totalSleep / loggedDays) / divisor;
    final selected = DateUtils.dateOnly(widget.selectedDate);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 16, 10),
      decoration: _glass(radius: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Row(
              children: [
                Text("Sleep trend", style: _display(17)),
                const Spacer(),
                if (showHealthyBand) ...[
                  Container(
                    width: 12,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _green.withValues(alpha: .25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    "7–9h",
                    style: TextStyle(color: _white(.5), fontSize: 11),
                  ),
                  const SizedBox(width: 10),
                ],
                Container(width: 12, height: 1.5, color: _green),
                const SizedBox(width: 5),
                Text("Goal", style: TextStyle(color: _white(.5), fontSize: 11)),
                const SizedBox(width: 10),
                Container(width: 12, height: 1.5, color: _white(.6)),
                const SizedBox(width: 5),
                Text(
                  "Average",
                  style: TextStyle(color: _white(.5), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 210,
            child: Stack(
              children: [
                // 3D bars: grow in on load, tap one to open that day.
                TweenAnimationBuilder<double>(
                  key: ValueKey(weekStart),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 1000),
                  builder: (context, grow, _) => LayoutBuilder(
                    builder: (context, box) {
                      final selIndex = [
                        for (int i = 0; i < 7; i++)
                          if (_dayAt(i) == selected) i,
                      ];
                      final painter = _Week3DChartPainter(
                        values: [for (final v in dailySleep) v / divisor],
                        labels: [
                          for (final v in dailySleep)
                            v <= 0 ? "" : _hm(v),
                        ],
                        days: days,
                        metGoal: [for (final v in dailySleep) _metGoal(v)],
                        maxY: maxY,
                        interval: interval,
                        unit: unit,
                        goalY: goalSeconds / divisor,
                        avgY: avgY,
                        bandLow: showHealthyBand
                            ? _healthyMinSeconds / divisor
                            : null,
                        bandHigh: showHealthyBand
                            ? _healthyMaxSeconds / divisor
                            : null,
                        selected: selIndex.isEmpty ? null : selIndex.first,
                        grow: grow,
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) {
                          final i = painter.indexAt(
                            d.localPosition,
                            Size(box.maxWidth, box.maxHeight),
                          );
                          if (i == null) return;
                          HapticFeedback.selectionClick();
                          _openDay(_dayAt(i));
                        },
                        child: CustomPaint(
                          size: Size(box.maxWidth, box.maxHeight),
                          painter: painter,
                        ),
                      );
                    },
                  ),
                ),
                if (totalSleep == 0)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _surface.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _white(.1)),
                      ),
                      child: Text(
                        "No sleep logged this week",
                        style: TextStyle(color: _white(.7), fontSize: 12.5),
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

  double _niceInterval(double raw) {
    if (raw <= 0) return 1;
    final exp = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final f = raw / exp;
    final double nice = f <= 1
        ? 1
        : f <= 2
        ? 2
        : f <= 5
        ? 5
        : 10;
    return nice * exp;
  }

  // ===================================================================
  // DAILY LIST
  // ===================================================================
  /// Go back to the History screen showing [day].
  void _openDay(DateTime day) {
    if (day.isAfter(DateUtils.dateOnly(DateTime.now()))) return;
    HapticFeedback.selectionClick();
    Navigator.pop(context, day);
  }

  Widget buildSleepCard(int i) {
    final day = _dayAt(i);
    final secs = dailySleep[i];
    final maxSec = dailySleep.reduce(math.max);
    final fraction = maxSec == 0 ? 0.0 : secs / maxSec;
    final isSel = day == DateUtils.dateOnly(widget.selectedDate);
    final isToday = DateUtils.isSameDay(day, DateTime.now());
    final isFuture = day.isAfter(DateUtils.dateOnly(DateTime.now()));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isFuture ? null : () => _openDay(day),
      child: Container(
        // Logged days are raised 3D tiles; empty days sit recessed.
        margin: EdgeInsets.only(bottom: secs > 0 ? 12 : 8),
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        decoration: secs > 0
            ? _raisedPanel(
                isSel ? _cyan : (_metGoal(secs) ? _green : _violet),
              ).copyWith(
                borderRadius: BorderRadius.circular(18),
                border: isSel
                    ? Border.all(color: Colors.white.withValues(alpha: .6))
                    : null,
              )
            : _tray().copyWith(
                borderRadius: BorderRadius.circular(18),
                border: isSel
                    ? Border.all(color: _cyan.withValues(alpha: .5))
                    : null,
              ),
        child: Row(
          children: [
            // Date badge
            Container(
              width: 44,
              height: 44,
              decoration: secs > 0
                  ? _iconKey(
                      _metGoal(secs) ? _green : _violet,
                      gradient: _metGoal(secs) ? _goalGradient : _mainGradient,
                    ).copyWith(borderRadius: BorderRadius.circular(13))
                  : BoxDecoration(
                      color: _white(.05),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: _white(.06)),
                    ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    days[i].toUpperCase(),
                    style: TextStyle(
                      color: secs > 0 ? _white(.85) : _white(.4),
                      fontSize: 9,
                      letterSpacing: .8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    "${day.day}",
                    style: _display(
                      16,
                      weight: FontWeight.w700,
                      color: secs > 0 ? Colors.white : _white(.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          DateFormat('EEEE').format(day),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isFuture ? _white(.4) : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (_metGoal(secs)) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: _key(_green, radius: 8),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_rounded,
                                color: _green,
                                size: 11,
                              ),
                              SizedBox(width: 3),
                              Text(
                                "Goal",
                                style: TextStyle(
                                  color: _green,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (isToday) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: _key(_cyan, radius: 8),
                          child: const Text(
                            "Today",
                            style: TextStyle(
                              color: _cyan,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Relative bar vs. the best day this week
                  // Recessed 3D meter with a glowing fill.
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: Colors.black.withValues(alpha: .4),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .06),
                      ),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: fraction),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) => FractionallySizedBox(
                          widthFactor: v,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: _metGoal(secs)
                                    ? [
                                        Color.lerp(_green, Colors.white, .35)!,
                                        _green,
                                      ]
                                    : [
                                        Color.lerp(_cyan, Colors.white, .25)!,
                                        _violet,
                                      ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (_metGoal(secs) ? _green : _cyan)
                                      .withValues(alpha: .5),
                                  blurRadius: 6,
                                ),
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
            const SizedBox(width: 14),
            SizedBox(
              width: 74,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    isFuture ? "—" : formatDuration(secs),
                    textAlign: TextAlign.right,
                    style: _display(
                      15.5,
                      weight: FontWeight.w800,
                      color: secs > 0 ? Colors.white : _white(.35),
                    ).copyWith(
                      shadows: secs > 0
                          ? const [
                              Shadow(
                                color: Colors.black54,
                                offset: Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                  ),
                  if (_statusFor(secs) case final status?) ...[
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(status.icon, color: status.color, size: 10),
                        const SizedBox(width: 3),
                        Text(
                          status.label,
                          style: TextStyle(
                            color: status.color,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (!isFuture) ...[
              const SizedBox(width: 6),
              Container(
                width: 24,
                height: 24,
                decoration: _key(secs > 0 ? _violet : _white(.5), radius: 8),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: _white(secs > 0 ? .8 : .4),
                  size: 16,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _loading() {
    return SizedBox(
      key: const ValueKey("loading"),
      height: 300,
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: _cyan,
            backgroundColor: _white(.08),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// SMALL WIDGETS
// =====================================================================

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

/// 24-hour track from noon to noon (so night-time sits in the middle),
/// with one dot per day at its bedtime, the average line and a ±spread band.
class _BedtimeTrack extends StatelessWidget {
  final List<DateTime?> bedtimes;
  final List<String> days;
  final int? meanMinutes;
  final int? spreadMinutes;

  /// Minute of the day where the axis starts (noon by default).
  final int axisStart;
  final List<String> labels;
  final String highlightLabel;

  /// Solid colour for dots and the ± band; null keeps the bedtime look.
  final Color? color;

  const _BedtimeTrack({
    required this.bedtimes,
    required this.days,
    required this.meanMinutes,
    required this.spreadMinutes,
    this.axisStart = 720,
    this.labels = const ["12 PM", "6 PM", "12 AM", "6 AM", "12 PM"],
    this.highlightLabel = "12 AM",
    this.color,
  });

  /// 0..1 position on the axis.
  double _pos(int minutesOfDay) => ((minutesOfDay - axisStart) % 1440) / 1440;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? _magenta;
    final points = <({double pos, String letter})>[
      for (int i = 0; i < 7; i++)
        if (bedtimes[i] != null)
          (
            pos: _pos(bedtimes[i]!.hour * 60 + bedtimes[i]!.minute),
            letter: days[i][0],
          ),
    ];

    return Column(
      children: [
        // Spheres drop onto the rail with a bounce whenever data changes.
        TweenAnimationBuilder<double>(
          key: ValueKey(Object.hashAll([...bedtimes, meanMinutes])),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 1100),
          builder: (context, t, _) => SizedBox(
            height: 70,
            width: double.infinity,
            child: CustomPaint(
              painter: _Track3DPainter(
                points: points,
                mean: meanMinutes == null ? null : _pos(meanMinutes!),
                halfSpread: spreadMinutes == null
                    ? null
                    : spreadMinutes! / 1440,
                accent: accent,
                useBedtimeLook: color == null,
                t: t,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final label in labels)
              Text(
                label,
                style: TextStyle(
                  color: label == highlightLabel ? _white(.7) : _white(.4),
                  fontSize: 10,
                  fontWeight: label == highlightLabel
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
          ],
        ),
      ],
    );
  }
}


// =====================================================================
// 3D WEEKLY SLEEP TREND
// Isometric bars (front, side, top faces) on a floor with a back-wall
// grid, the 7–9h healthy band, dashed goal/average lines, value labels
// and a staggered grow-in animation.
// =====================================================================
class _Week3DChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final List<String> days;
  final List<bool> metGoal;
  final double maxY;
  final double interval;
  final String unit;
  final double goalY;
  final double avgY;
  final double? bandLow;
  final double? bandHigh;
  final int? selected;
  final double grow;

  _Week3DChartPainter({
    required this.values,
    required this.labels,
    required this.days,
    required this.metGoal,
    required this.maxY,
    required this.interval,
    required this.unit,
    required this.goalY,
    required this.avgY,
    required this.bandLow,
    required this.bandHigh,
    required this.selected,
    required this.grow,
  });

  static const double _left = 34;
  static const double _bottomPad = 26;

  ({double left, double right, double top, double bottom, double slot,
    double barW, double dx, double dy}) _geo(Size size) {
    const n = 7;
    const right0 = 4.0;
    final slotGuess = (size.width - _left - right0) / n;
    final barW0 = slotGuess * .5;
    final dx = barW0 * .55;
    final dy = barW0 * .42;
    final right = size.width - right0 - dx;
    final slot = (right - _left) / n;
    return (
      left: _left,
      right: right,
      top: 18 + dy, // room for value labels above the tallest bar
      bottom: size.height - _bottomPad,
      slot: slot,
      barW: slot * .5,
      dx: dx,
      dy: dy,
    );
  }

  int? indexAt(Offset p, Size size) {
    final g = _geo(size);
    if (p.dx < g.left - 4 || p.dx > g.right + g.dx) return null;
    final i = ((p.dx - g.left) / g.slot).floor();
    return i < 0 || i > 6 ? null : i;
  }

  double _y(double v, double top, double bottom) =>
      bottom - (v / (maxY <= 0 ? 1 : maxY)).clamp(0.0, 1.0) * (bottom - top);

  void _dashed(Canvas c, Offset a, Offset b, Paint p, double dash, double gap) {
    final len = (b - a).distance;
    if (len == 0) return;
    final dir = (b - a) / len;
    for (double d = 0; d < len; d += dash + gap) {
      c.drawLine(a + dir * d, a + dir * math.min(d + dash, len), p);
    }
  }

  void _text(Canvas c, String text, Offset at, Color color,
      {double size = 10, bool alignRight = false, bool center = false,
      FontWeight weight = FontWeight.w500}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, fontWeight: weight),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    var o = at;
    if (alignRight) o = o.translate(-tp.width, 0);
    if (center) o = o.translate(-tp.width / 2, 0);
    tp.paint(c, o.translate(0, -tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = _geo(size);
    const white = Colors.white;
    const green = Color(0xFF34D399);

    // ---------- Floor ----------
    final floor = Path()
      ..moveTo(g.left, g.bottom)
      ..lineTo(g.right, g.bottom)
      ..lineTo(g.right + g.dx, g.bottom - g.dy)
      ..lineTo(g.left + g.dx, g.bottom - g.dy)
      ..close();
    canvas.drawPath(floor, Paint()..color = white.withValues(alpha: .05));
    canvas.drawLine(
      Offset(g.left, g.bottom),
      Offset(g.right, g.bottom),
      Paint()
        ..color = white.withValues(alpha: .18)
        ..strokeWidth = 1,
    );

    // ---------- Healthy 7–9h band on the back wall ----------
    if (bandLow != null && bandHigh != null) {
      final y1 = _y(bandHigh!, g.top, g.bottom) - g.dy;
      final y2 = _y(bandLow!, g.top, g.bottom) - g.dy;
      canvas.drawRect(
        Rect.fromLTRB(g.left + g.dx, y1, g.right + g.dx, y2),
        Paint()..color = green.withValues(alpha: .09),
      );
    }

    // ---------- Back-wall grid + y labels ----------
    final grid = Paint()
      ..color = white.withValues(alpha: .07)
      ..strokeWidth = 1;
    if (interval > 0) {
      for (double v = interval; v <= maxY + 1e-6; v += interval) {
        final y = _y(v, g.top, g.bottom);
        _dashed(canvas, Offset(g.left + g.dx, y - g.dy),
            Offset(g.right + g.dx, y - g.dy), grid, 4, 4);
        canvas.drawLine(Offset(g.left, y), Offset(g.left + g.dx, y - g.dy), grid);
        if (v < maxY - 1e-6) {
          final t = v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
          _text(canvas, "$t$unit", Offset(g.left - 6, y),
              white.withValues(alpha: .4), alignRight: true);
        }
      }
    }

    // ---------- Bars ----------
    for (int i = 0; i < 7; i++) {
      final local = ((grow * 1.4) - i / 7 * .4).clamp(0.0, 1.0);
      final eased = Curves.easeOutBack.transform(local);
      final v = values[i] * eased;
      final x0 = g.left + g.slot * i + (g.slot - g.barW) / 2;
      final x1 = x0 + g.barW;
      final isSel = selected == i;

      if (values[i] <= 0) {
        final tile = Path()
          ..moveTo(x0, g.bottom)
          ..lineTo(x1, g.bottom)
          ..lineTo(x1 + g.dx, g.bottom - g.dy)
          ..lineTo(x0 + g.dx, g.bottom - g.dy)
          ..close();
        canvas.drawPath(tile, Paint()..color = white.withValues(alpha: .07));
        continue;
      }

      final yTop = _y(v, g.top, g.bottom);
      final base = metGoal[i] ? const Color(0xFF10B981) : const Color(0xFF6B5BFF);
      final hi = metGoal[i] ? const Color(0xFF6EE7B7) : const Color(0xFF24E0FF);
      final a = isSel || selected == null ? 1.0 : .78;

      // Soft glow on the floor under the bar.
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset((x0 + x1) / 2 + g.dx / 2, g.bottom - g.dy / 2),
          width: g.barW * 1.8,
          height: g.dy * 1.4,
        ),
        Paint()
          ..color = hi.withValues(alpha: .22 * eased.clamp(0.0, 1.0))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );

      final front = Rect.fromLTRB(x0, yTop, x1, g.bottom);
      canvas.drawRect(
        front,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [base.withValues(alpha: a), hi.withValues(alpha: a)],
          ).createShader(front),
      );
      final side = Path()
        ..moveTo(x1, g.bottom)
        ..lineTo(x1 + g.dx, g.bottom - g.dy)
        ..lineTo(x1 + g.dx, yTop - g.dy)
        ..lineTo(x1, yTop)
        ..close();
      canvas.drawPath(
        side,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Color.lerp(base, Colors.black, .45)!.withValues(alpha: a),
              Color.lerp(hi, Colors.black, .4)!.withValues(alpha: a),
            ],
          ).createShader(side.getBounds()),
      );
      final top = Path()
        ..moveTo(x0, yTop)
        ..lineTo(x1, yTop)
        ..lineTo(x1 + g.dx, yTop - g.dy)
        ..lineTo(x0 + g.dx, yTop - g.dy)
        ..close();
      canvas.drawPath(
        top,
        Paint()..color = Color.lerp(hi, Colors.white, .35)!.withValues(alpha: a),
      );
      // Thin highlight on the front's left edge.
      canvas.drawLine(
        Offset(x0 + .5, yTop),
        Offset(x0 + .5, g.bottom),
        Paint()
          ..color = Colors.white.withValues(alpha: .25 * a)
          ..strokeWidth = 1,
      );

      if (isSel) {
        final outline = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2;
        canvas.drawRect(front, outline);
        canvas.drawPath(top, outline);
        canvas.drawPath(side, outline);
      }

      // Value label above the bar (fades in at the end of the grow).
      if (labels[i].isNotEmpty && local > .7) {
        _text(
          canvas,
          labels[i],
          Offset((x0 + x1) / 2 + g.dx / 2, yTop - g.dy - 9),
          Colors.white.withValues(alpha: ((local - .7) / .3).clamp(0.0, 1.0)),
          size: 9.5,
          center: true,
          weight: FontWeight.w700,
        );
      }
    }

    // ---------- Goal & average lines ----------
    if (goalY > 0 && goalY <= maxY) {
      final y = _y(goalY, g.top, g.bottom);
      _dashed(canvas, Offset(g.left, y), Offset(g.right + g.dx, y),
          Paint()
            ..color = green.withValues(alpha: .9)
            ..strokeWidth = 1.5,
          3, 3);
    }
    if (avgY > 0 && avgY <= maxY) {
      final y = _y(avgY * grow, g.top, g.bottom);
      _dashed(canvas, Offset(g.left, y), Offset(g.right + g.dx, y),
          Paint()
            ..color = white.withValues(alpha: .6)
            ..strokeWidth = 1.5,
          6, 4);
    }

    // ---------- Day names ----------
    for (int i = 0; i < 7; i++) {
      final cx = g.left + g.slot * i + g.slot / 2;
      _text(
        canvas,
        days[i],
        Offset(cx, size.height - _bottomPad / 2 + 2),
        selected == i ? Colors.white : white.withValues(alpha: .5),
        size: 11,
        center: true,
        weight: selected == i ? FontWeight.w700 : FontWeight.w500,
      );
    }
  }

  @override
  bool shouldRepaint(_Week3DChartPainter old) =>
      old.grow != grow ||
      old.selected != selected ||
      old.values != values ||
      old.maxY != maxY ||
      old.goalY != goalY ||
      old.avgY != avgY;
}


// =====================================================================
// 3D CONSISTENCY TRACK
// A raised glossy rail with a soft floor shadow, a glass slab for the
// ± spread, a glowing pin for the average and one shiny sphere per day
// (with its own shadow) that drops in with a bounce.
// =====================================================================
class _Track3DPainter extends CustomPainter {
  final List<({double pos, String letter})> points;
  final double? mean; // 0..1
  final double? halfSpread; // 0..1
  final Color accent;
  final bool useBedtimeLook;
  final double t; // 0..1 animation

  _Track3DPainter({
    required this.points,
    required this.mean,
    required this.halfSpread,
    required this.accent,
    required this.useBedtimeLook,
    required this.t,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const r = 13.0; // sphere radius
    final w = size.width;
    final railY = size.height * .62; // rail centre
    const railH = 10.0;
    double x(double f) => (w * f).clamp(r, w - r).toDouble();

    // ---------- Floor shadow under the rail ----------
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(4, railY + railH / 2 + 3, w - 8, 6),
        const Radius.circular(3),
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: .45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ---------- Rail: front face (depth) + glossy tube top ----------
    final railRect = Rect.fromLTWH(0, railY - railH / 2, w, railH);
    final front = RRect.fromRectAndRadius(
      railRect.shift(const Offset(0, 3)),
      const Radius.circular(railH / 2),
    );
    canvas.drawRRect(
      front,
      Paint()..color = Color.lerp(accent, Colors.black, .7)!,
    );
    final tube = RRect.fromRectAndRadius(railRect, const Radius.circular(railH / 2));
    canvas.drawRRect(
      tube,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(accent, Colors.white, .25)!.withValues(alpha: .55),
            accent.withValues(alpha: .35),
            Color.lerp(accent, Colors.black, .5)!.withValues(alpha: .6),
          ],
          stops: const [0, .45, 1],
        ).createShader(railRect),
    );
    // Gloss streak along the top of the tube.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(6, railY - railH / 2 + 1.5, w - 12, 2.2),
        const Radius.circular(1.2),
      ),
      Paint()..color = Colors.white.withValues(alpha: .22),
    );
    // Hour ticks every 6h on the rail.
    for (final f in const [.25, .5, .75]) {
      canvas.drawLine(
        Offset(w * f, railY - railH / 2 + 2),
        Offset(w * f, railY + railH / 2 - 1),
        Paint()
          ..color = Colors.white.withValues(alpha: .25)
          ..strokeWidth = 1.2,
      );
    }

    // ---------- Glass slab for the ± spread ----------
    if (mean != null && halfSpread != null) {
      final grow = Curves.easeOutCubic.transform(t.clamp(0.0, 1.0).toDouble());
      final l = (mean! - halfSpread! * grow).clamp(0.0, 1.0).toDouble() * w;
      final rr = (mean! + halfSpread! * grow).clamp(0.0, 1.0).toDouble() * w;
      final slab = Rect.fromLTRB(l, railY - 17, math.max(rr, l + 4), railY + 13);
      // depth (front face)
      canvas.drawRRect(
        RRect.fromRectAndRadius(slab.shift(const Offset(0, 4)), const Radius.circular(9)),
        Paint()..color = accent.withValues(alpha: .18),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(slab, const Radius.circular(9)),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: .16),
              accent.withValues(alpha: .14),
              accent.withValues(alpha: .22),
            ],
          ).createShader(slab),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(slab, const Radius.circular(9)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = accent.withValues(alpha: .55),
      );
      // top edge highlight
      canvas.drawLine(
        Offset(slab.left + 8, slab.top + 1.5),
        Offset(slab.right - 8, slab.top + 1.5),
        Paint()
          ..color = Colors.white.withValues(alpha: .35)
          ..strokeWidth = 1,
      );
    }

    // ---------- Average pin (glowing pillar + cap) ----------
    if (mean != null) {
      final mx = w * mean!;
      final pinTop = railY - 30;
      canvas.drawLine(
        Offset(mx, pinTop),
        Offset(mx, railY + 16),
        Paint()
          ..color = Colors.white.withValues(alpha: .6)
          ..strokeWidth = 5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawLine(
        Offset(mx, pinTop),
        Offset(mx, railY + 16),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(
        Offset(mx, pinTop),
        4,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.4, -.4),
            colors: [Colors.white, accent],
          ).createShader(Rect.fromCircle(center: Offset(mx, pinTop), radius: 4)),
      );
    }

    // ---------- Day spheres ----------
    for (int k = 0; k < points.length; k++) {
      final p = points[k];
      // Staggered drop with a bounce.
      final local = ((t * 1.5) - k / math.max(points.length, 1) * .5)
          .clamp(0.0, 1.0)
          .toDouble();
      final drop = Curves.bounceOut.transform(local);
      final cx = x(p.pos);
      final cy = railY - 2 - (1 - drop) * 40;
      final opacity = (local * 3).clamp(0.0, 1.0).toDouble();

      // Ground shadow on the rail (tighter as the ball lands).
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + 2, railY + railH / 2 + 3),
          width: r * (1.2 + .6 * drop),
          height: 5,
        ),
        Paint()
          ..color = Colors.black.withValues(alpha: .5 * drop)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );

      final c1 = useBedtimeLook ? const Color(0xFFB04BFF) : accent;
      final c0 = Color.lerp(c1, Colors.white, .55)!;
      final c2 = Color.lerp(c1, Colors.black, .55)!;
      final ball = Rect.fromCircle(center: Offset(cx, cy), radius: r);

      // Outer glow
      canvas.drawCircle(
        Offset(cx, cy),
        r + 2,
        Paint()
          ..color = c1.withValues(alpha: .45 * opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
      // Sphere body
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.35, -.45),
            radius: 1.05,
            colors: [
              c0.withValues(alpha: opacity),
              c1.withValues(alpha: opacity),
              c2.withValues(alpha: opacity),
            ],
            stops: const [0, .5, 1],
          ).createShader(ball),
      );
      // Rim
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: .25 * opacity),
      );
      // Specular highlight
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx - r * .35, cy - r * .45),
          width: r * .7,
          height: r * .4,
        ),
        Paint()..color = Colors.white.withValues(alpha: .55 * opacity),
      );
      // Day letter
      final tp = TextPainter(
        text: TextSpan(
          text: p.letter,
          style: TextStyle(
            color: Colors.white.withValues(alpha: opacity),
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 2)],
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2 + 1));
    }
  }

  @override
  bool shouldRepaint(_Track3DPainter old) =>
      old.t != t ||
      old.mean != mean ||
      old.halfSpread != halfSpread ||
      old.points != points ||
      old.accent != accent;
}


// =====================================================================
// 3D BLOCK (Last 4 weeks bars)
// Front face, darker right side, lighter top, plus a floor shadow.
// =====================================================================
class _Block3DPainter extends CustomPainter {
  final Color color;
  final Color highlight;
  final bool selected;
  final bool empty;

  _Block3DPainter({
    required this.color,
    required this.highlight,
    required this.selected,
    required this.empty,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dx = math.min(size.width * .16, 14.0); // depth to the right
    const dy = 10.0; // depth upwards
    final w = size.width - dx;
    final bottom = size.height;
    final top = dy;

    // Floor shadow
    canvas.drawOval(
      Rect.fromLTWH(-2, bottom - 7, w + dx + 6, 12),
      Paint()
        ..color = Colors.black.withValues(alpha: .45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    final front = Rect.fromLTRB(0, top, w, bottom);
    final side = Path()
      ..moveTo(w, bottom)
      ..lineTo(w + dx, bottom - dy)
      ..lineTo(w + dx, top - dy)
      ..lineTo(w, top)
      ..close();
    final cap = Path()
      ..moveTo(0, top)
      ..lineTo(w, top)
      ..lineTo(w + dx, top - dy)
      ..lineTo(dx, top - dy)
      ..close();

    if (empty) {
      canvas.drawRect(front, Paint()..color = color.withValues(alpha: .35));
      canvas.drawPath(side, Paint()..color = color.withValues(alpha: .2));
      canvas.drawPath(cap, Paint()..color = color.withValues(alpha: .5));
      return;
    }

    if (selected) {
      canvas.drawRect(
        front.inflate(4),
        Paint()
          ..color = highlight.withValues(alpha: .35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
    }

    canvas.drawRect(
      front,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [color, Color.lerp(color, highlight, .55)!],
        ).createShader(front),
    );
    canvas.drawPath(
      side,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Color.lerp(color, Colors.black, .55)!,
            Color.lerp(color, Colors.black, .35)!,
          ],
        ).createShader(side.getBounds()),
    );
    canvas.drawPath(
      cap,
      Paint()..color = Color.lerp(highlight, Colors.white, .3)!,
    );
    // Glossy edge on the front's left side.
    canvas.drawLine(
      Offset(1, top),
      Offset(1, bottom),
      Paint()
        ..color = Colors.white.withValues(alpha: .3)
        ..strokeWidth = 1.5,
    );
    if (selected) {
      final o = Paint()
        ..color = Colors.white.withValues(alpha: .85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawRect(front, o);
      canvas.drawPath(cap, o);
      canvas.drawPath(side, o);
    }
  }

  @override
  bool shouldRepaint(_Block3DPainter old) =>
      old.color != color ||
      old.highlight != highlight ||
      old.selected != selected ||
      old.empty != empty;
}


// =====================================================================
// 3D PRESS KEY — raised square button that sinks when pressed.
// =====================================================================
class _PressKey extends StatefulWidget {
  final VoidCallback onTap;
  final double size;
  final double radius;
  final Widget child;

  const _PressKey({
    required this.onTap,
    required this.size,
    required this.radius,
    required this.child,
  });

  @override
  State<_PressKey> createState() => _PressKeyState();
}

class _PressKeyState extends State<_PressKey> {
  bool _down = false;
  static const double _depth = 4;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size + _depth,
        child: Stack(
          children: [
            // Key "base" (the dark side you see below the face).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: widget.size,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF07041A),
                  borderRadius: BorderRadius.circular(widget.radius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .5),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
              ),
            ),
            // Key face — slides down when pressed.
            AnimatedPositioned(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              top: _down ? _depth : 0,
              height: widget.size,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [Color(0xFF2E2570), Color(0xFF1A1448)],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .18),
                  ),
                ),
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// =====================================================================
// 3D GOAL KEY — raised key that sinks when pressed (goal picker).
// =====================================================================
class _GoalKey extends StatefulWidget {
  final String label;
  final bool selected;
  final bool healthy;
  final VoidCallback onTap;

  const _GoalKey({
    required this.label,
    required this.selected,
    required this.healthy,
    required this.onTap,
  });

  @override
  State<_GoalKey> createState() => _GoalKeyState();
}

class _GoalKeyState extends State<_GoalKey> {
  bool _down = false;
  static const double _w = 76, _h = 44, _depth = 5;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final face = sel
        ? const [Color(0xFF5BE8B0), Color(0xFF18B983)]
        : const [Color(0xFF2E2570), Color(0xFF1A1448)];
    final base = sel ? const Color(0xFF0B6B4A) : const Color(0xFF07041A);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        // Let the press animation show before the sheet closes.
        Future.delayed(const Duration(milliseconds: 120), widget.onTap);
      },
      child: SizedBox(
        width: _w,
        height: _h + _depth,
        child: Stack(
          children: [
            // Base (key side)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _h,
              child: Container(
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: sel
                          ? const Color(0xFF34D399).withValues(alpha: .45)
                          : Colors.black.withValues(alpha: .45),
                      blurRadius: sel ? 16 : 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
              ),
            ),
            // Face
            AnimatedPositioned(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              top: _down ? _depth : 0,
              height: _h,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: face,
                  ),
                  border: Border.all(
                    color: sel
                        ? Colors.white.withValues(alpha: .45)
                        : widget.healthy
                        ? const Color(0xFF34D399).withValues(alpha: .4)
                        : Colors.white.withValues(alpha: .14),
                  ),
                ),
                child: Text(
                  widget.label,
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: Colors.black45, offset: Offset(0, 1.5)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
