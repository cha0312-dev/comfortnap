import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
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

  /// Total actual sleep in the previous week (for the comparison badge).
  int lastWeekSleep = 0;

  /// Session records (type "session") started this week, for comfort insights.
  List<Map<String, dynamic>> weekSessions = [];

  /// When the main sleep of each day (Sun..Sat) started, or null.
  List<DateTime?> bedtimes = List.filled(7, null);

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
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _goalGradient,
                    boxShadow: [
                      BoxShadow(
                        color: _green.withValues(alpha: .45),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.flag_rounded,
                    color: Colors.white,
                    size: 26,
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
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final option in _goalOptions)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          _saveGoal(option);
                        },
                        child: Container(
                          width: 76,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: option == goalSeconds
                              ? BoxDecoration(
                                  gradient: _goalGradient,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _green.withValues(alpha: .4),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                )
                              : _glass(radius: 14),
                          child: Text(
                            _goalLabel(option),
                            style: _display(15, weight: FontWeight.w700),
                          ),
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
    final sessionsFuture = _sessionsFor(start);
    final results = await Future.wait([
      _sleepPerDay(start, bedtimesOut: weekBedtimes),
      _sleepPerDay(previousStart),
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
      bedtimes = weekBedtimes;
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
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: isLoading
                      ? _loading()
                      : Column(
                          key: ValueKey(weekStart),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Entrance(index: 2, child: _summaryCard()),
                            const SizedBox(height: 16),
                            _Entrance(index: 3, child: _bedtimeCard()),
                            const SizedBox(height: 16),
                            _Entrance(index: 3, child: _comfortCard()),
                            const SizedBox(height: 16),
                            _Entrance(index: 3, child: buildBarChart()),
                            const SizedBox(height: 26),
                            _Entrance(
                              index: 4,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text("Daily breakdown", style: _display(20)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      "Tap a day to see its sessions",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _white(.4),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (int i = 0; i < 7; i++)
                              _Entrance(index: 5 + i, child: buildSleepCard(i)),
                          ],
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

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: _glass(radius: 20),
      child: Row(
        children: [
          _roundButton(Icons.chevron_left_rounded, () => _changeWeek(-1)),
          Expanded(
            child: Column(
              children: [
                Text(
                  "${DateFormat('MMM d').format(weekStart)} – "
                  "${DateFormat('MMM d, y').format(weekEnd)}",
                  style: _display(15),
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
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: _glass(radius: radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================
  Widget _summaryCard() {
    final loggedDays = dailySleep.where((s) => s > 0).length;
    final avg = loggedDays == 0 ? 0 : totalSleep ~/ loggedDays;
    int best = 0;
    for (int i = 1; i < 7; i++) {
      if (dailySleep[i] > dailySleep[best]) best = i;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _violet.withValues(alpha: .40),
            const Color(0xFF2A1F7A).withValues(alpha: .35),
            _cyan.withValues(alpha: .10),
          ],
        ),
        border: Border.all(color: _white(.12)),
        boxShadow: [
          BoxShadow(
            color: _violet.withValues(alpha: .22),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("TOTAL SLEEP", style: _eyebrow()),
          const SizedBox(height: 6),
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (r) => _mainGradient.createShader(r),
            child: Text(
              totalSleep == 0 ? "—" : formatDuration(totalSleep),
              style: _display(38, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          _comparisonBadge(),
          const SizedBox(height: 14),
          _goalRow(),
          const SizedBox(height: 10),
          Row(
            children: [
              _miniStat(
                Icons.event_available_rounded,
                "$loggedDays/7",
                "Days logged",
              ),
              const SizedBox(width: 8),
              _miniStat(
                Icons.av_timer_rounded,
                loggedDays == 0 ? "-" : formatDuration(avg),
                "Avg / day",
              ),
              const SizedBox(width: 8),
              _miniStat(
                Icons.emoji_events_rounded,
                loggedDays == 0 ? "-" : days[best],
                "Best day",
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _goalRow() {
    final met = _goalDaysMet;
    return GestureDetector(
      onTap: _editGoal,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: _white(.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _white(.08)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.flag_rounded, color: _green, size: 17),
                const SizedBox(width: 8),
                Text(
                  "Goal ${_goalLabel(goalSeconds)} / day",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  "$met/7 days met",
                  style: _display(14, weight: FontWeight.w700, color: _green),
                ),
                const SizedBox(width: 6),
                Icon(Icons.edit_rounded, color: _white(.5), size: 14),
              ],
            ),
            const SizedBox(height: 10),
            // 7 small segments, one per day
            Row(
              children: [
                for (int i = 0; i < 7; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        gradient: _metGoal(dailySleep[i])
                            ? _goalGradient
                            : null,
                        color: _metGoal(dailySleep[i])
                            ? null
                            : dailySleep[i] > 0
                            ? _white(.22)
                            : _white(.08),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ],
            ),
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
      text = "No sleep logged this week or last week";
    } else if (lastWeekSleep == 0) {
      icon = Icons.auto_awesome_rounded;
      color = _cyan;
      text = "No sleep logged last week to compare";
    } else if (diff.abs() < 60) {
      icon = Icons.drag_handle_rounded;
      color = _white(.7);
      text = "About the same as last week";
    } else {
      final up = diff > 0;
      final pct = (diff.abs() / lastWeekSleep * 100).round();
      icon = up ? Icons.trending_up_rounded : Icons.trending_down_rounded;
      color = up ? _green : _rose;
      text =
          "${formatDuration(diff.abs())} ${up ? 'more' : 'less'} than last week"
          "${pct > 0 ? ' (${up ? '+' : '−'}$pct%)' : ''}";
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: _white(.07),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: _cyan, size: 16),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: _display(15, weight: FontWeight.w700)),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _white(.5), fontSize: 10.5),
            ),
          ],
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
  ({int mean, int spread, int days})? _bedtimeStats() {
    final mins = [
      for (final b in bedtimes)
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
      topHeat = counts.entries
          .reduce((a, b) => b.value > a.value ? b : a)
          .key;
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
                  gradient: _comfortGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _amber.withValues(alpha: .4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
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
                icon: Icons.vibration_rounded,
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
            decoration: BoxDecoration(
              gradient: insight == null
                  ? null
                  : LinearGradient(
                      colors: [
                        _amber.withValues(alpha: .14),
                        _magenta.withValues(alpha: .08),
                      ],
                    ),
              color: insight == null ? _white(.05) : null,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: insight == null
                    ? Colors.transparent
                    : _amber.withValues(alpha: .25),
              ),
            ),
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
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _white(.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _white(.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: gradient.colors.last, size: 16),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: _display(16, weight: FontWeight.w700)),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _white(.5), fontSize: 10),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: _white(.08))),
                    if (level != null)
                      FractionallySizedBox(
                        widthFactor: level.clamp(0.0, 1.0),
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(gradient: gradient),
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
                BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: maxY,
                    minY: 0,
                    barTouchData: BarTouchData(
                      enabled: true,
                      // Tap a bar to open that day in History.
                      touchCallback: (event, response) {
                        if (event is! FlTapUpEvent) return;
                        final index = response?.spot?.touchedBarGroupIndex;
                        if (index == null) return;
                        _openDay(_dayAt(index));
                      },
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => _surface,
                        tooltipRoundedRadius: 10,
                        tooltipPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final i = group.x;
                          return BarTooltipItem(
                            "${days[i]}\n",
                            TextStyle(color: _white(.6), fontSize: 11),
                            children: [
                              TextSpan(
                                text: formatDuration(dailySleep[i]),
                                style: _display(14, weight: FontWeight.w700),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 34,
                          interval: interval,
                          getTitlesWidget: (value, meta) {
                            if (value == meta.max || value == 0) {
                              return const SizedBox.shrink();
                            }
                            final label = value % 1 == 0
                                ? value.toInt().toString()
                                : value.toStringAsFixed(1);
                            return Text(
                              "$label$unit",
                              style: TextStyle(color: _white(.4), fontSize: 10),
                            );
                          },
                        ),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          getTitlesWidget: (value, meta) {
                            final i = value.toInt();
                            final isSel = _dayAt(i) == selected;
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                days[i][0],
                                style: TextStyle(
                                  color: isSel ? Colors.white : _white(.45),
                                  fontSize: 12,
                                  fontWeight: isSel
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: interval,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: _white(.06),
                        strokeWidth: 1,
                        dashArray: [4, 4],
                      ),
                    ),
                    rangeAnnotations: RangeAnnotations(
                      horizontalRangeAnnotations: [
                        if (showHealthyBand)
                          HorizontalRangeAnnotation(
                            y1: _healthyMinSeconds / divisor,
                            y2: _healthyMaxSeconds / divisor,
                            color: _green.withValues(alpha: .10),
                          ),
                      ],
                    ),
                    extraLinesData: ExtraLinesData(
                      horizontalLines: [
                        HorizontalLine(
                          y: goalSeconds / divisor,
                          color: _green.withValues(alpha: .85),
                          strokeWidth: 1.5,
                          dashArray: [3, 3],
                        ),
                        if (avgY > 0)
                          HorizontalLine(
                            y: avgY,
                            color: _white(.55),
                            strokeWidth: 1.5,
                            dashArray: [6, 4],
                          ),
                      ],
                    ),
                    barGroups: List.generate(7, (i) {
                      final isSel = _dayAt(i) == selected;
                      final value = dailySleep[i] / divisor;
                      return BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: value,
                            width: 22,
                            borderRadius: BorderRadius.circular(7),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: _metGoal(dailySleep[i])
                                  ? [
                                      const Color(
                                        0xFF10B981,
                                      ).withValues(alpha: isSel ? 1 : .75),
                                      _green.withValues(alpha: isSel ? 1 : .75),
                                    ]
                                  : isSel
                                  ? const [_violet, _cyan]
                                  : [
                                      _violet.withValues(alpha: .65),
                                      _cyan.withValues(alpha: .65),
                                    ],
                            ),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: maxY,
                              color: _white(isSel ? .07 : .035),
                            ),
                          ),
                        ],
                      );
                    }),
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
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        decoration: isSel
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  colors: [
                    _violet.withValues(alpha: .30),
                    _cyan.withValues(alpha: .08),
                  ],
                ),
                border: Border.all(color: _cyan.withValues(alpha: .35)),
              )
            : _glass(radius: 18),
        child: Row(
          children: [
            // Date badge
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: secs > 0 ? _mainGradient : null,
                color: secs > 0 ? null : _white(.05),
                borderRadius: BorderRadius.circular(13),
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
                          decoration: BoxDecoration(
                            color: _green.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(8),
                          ),
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
                          decoration: BoxDecoration(
                            color: _cyan.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(8),
                          ),
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 5,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(color: _white(.07)),
                          ),
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: fraction),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeOutCubic,
                            builder: (context, v, _) => FractionallySizedBox(
                              widthFactor: v,
                              heightFactor: 1,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: _mainGradient,
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
                      15,
                      weight: FontWeight.w700,
                      color: secs > 0 ? Colors.white : _white(.35),
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
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: _white(.35), size: 18),
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

  const _BedtimeTrack({
    required this.bedtimes,
    required this.days,
    required this.meanMinutes,
    required this.spreadMinutes,
  });

  /// 0..1 position on a noon→noon axis.
  static double _pos(int minutesOfDay) => ((minutesOfDay - 720) % 1440) / 1440;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        const dot = 22.0;

        return Column(
          children: [
            SizedBox(
              height: 46,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Track
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 20,
                    height: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: LinearGradient(
                          colors: [
                            _amber.withValues(alpha: .25),
                            _violet.withValues(alpha: .35),
                            _magenta.withValues(alpha: .35),
                            _amber.withValues(alpha: .25),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // ± spread band around the average
                  if (meanMinutes != null && spreadMinutes != null)
                    Builder(
                      builder: (context) {
                        final c = _pos(meanMinutes!);
                        final half = spreadMinutes! / 1440;
                        final l = (c - half).clamp(0.0, 1.0);
                        final r = (c + half).clamp(0.0, 1.0);
                        return Positioned(
                          left: w * l,
                          width: math.max(w * (r - l), 4),
                          top: 10,
                          height: 26,
                          child: Container(
                            decoration: BoxDecoration(
                              color: _magenta.withValues(alpha: .16),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _magenta.withValues(alpha: .35),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  // Average line
                  if (meanMinutes != null)
                    Positioned(
                      left: w * _pos(meanMinutes!) - 1,
                      top: 4,
                      height: 38,
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(1),
                          boxShadow: const [
                            BoxShadow(color: Colors.white, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  // One dot per day
                  for (int i = 0; i < 7; i++)
                    if (bedtimes[i] != null)
                      Positioned(
                        left:
                            (w *
                                        _pos(
                                          bedtimes[i]!.hour * 60 +
                                              bedtimes[i]!.minute,
                                        ) -
                                    dot / 2)
                                .clamp(-dot / 2, w - dot / 2),
                        top: 12,
                        child: Container(
                          width: dot,
                          height: dot,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: _bedtimeGradient,
                            border: Border.all(color: _bg, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: _magenta.withValues(alpha: .5),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Text(
                            days[i][0],
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final label in const [
                  "12 PM",
                  "6 PM",
                  "12 AM",
                  "6 AM",
                  "12 PM",
                ])
                  Text(
                    label,
                    style: TextStyle(
                      color: label == "12 AM" ? _white(.7) : _white(.4),
                      fontSize: 10,
                      fontWeight: label == "12 AM"
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
