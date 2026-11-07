import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

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
const Color _amber = Color(0xFFFFB547);
const Color _rose = Color(0xFFFF6F91);
const Color _green = Color(0xFF34D399);

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

class MonthlySleepScreen extends StatefulWidget {
  const MonthlySleepScreen({super.key});

  @override
  State<MonthlySleepScreen> createState() => _MonthlySleepScreenState();
}

class _MonthlySleepScreenState extends State<MonthlySleepScreen>
    with SingleTickerProviderStateMixin {
  DateTime currentMonth = DateTime.now();

  bool isLoading = true;

  int totalSleep = 0;

  /// Sleep (seconds) last month over the comparable period: the same days
  /// so far for the current month, or the whole month for past months.
  int lastMonthSleep = 0;

  int totalSessions = 0;

  int bestSleep = 0;

  int shortestSleep = 999999;

  DateTime? bestDay;

  List<int> dailySleep = [];

  /// Start time of each day's longest (main) sleep, or null.
  List<DateTime?> dailyBedtime = [];

  /// End time (wake-up) of each day's main sleep, or null.
  List<DateTime?> dailyWake = [];

  /// Day tapped in the sleep-window chart (1-based), or null.
  int? _windowDay;

  /// Session records (type "session") this month, for comfort insights.
  List<Map<String, dynamic>> monthSessions = [];

  /// Number of sessions per day of the month.
  List<int> dailyCount = [];

  List<Map<String, dynamic>> sleepRecords = [];

  /// Selected tab: 0 Overview, 1 Trends, 2 Insights, 3 Records.
  int _tab = 0;

  /// Records tab shows only the latest few until "Show all" is tapped.
  static const int _recordsPreview = 5;
  bool _showAllRecords = false;

  /// Day of month tapped in the heat-map (1-based), or null.
  int? _focusedDay;

  /// Sleep calendar mode: false = amount heat-map, true = goal calendar.
  bool _goalView = false;

  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  /// Daily sleep goal in seconds — the same one set on the Weekly page
  /// (Firestore app_settings/sleep_goal). Defaults to 30 minutes.
  int goalSeconds = 30 * 60;

  @override
  void initState() {
    super.initState();

    loadMonthlyData();
    _loadGoal();
  }

  Future<void> _loadGoal() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection("app_settings")
          .doc("sleep_goal")
          .get();
      final value = snap.data()?["seconds"];
      if (value is num && value > 0 && mounted) {
        setState(() => goalSeconds = value.toInt());
      }
    } catch (e) {
      debugPrint("GOAL LOAD ERROR: $e");
    }
  }

  bool _metGoal(int seconds) => seconds > 0 && seconds >= goalSeconds;

  String _goalLabel(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h == 0) return "${m}m";
    if (m == 0) return "${h}h";
    return "${h}h ${m}m";
  }

  /// Days of this month that can count toward the goal (up to today).
  int get _daysSoFar {
    if (dailySleep.isEmpty) return 0;
    final now = DateTime.now();
    if (currentMonth.year == now.year && currentMonth.month == now.month) {
      return now.day;
    }
    final monthStart = DateTime(currentMonth.year, currentMonth.month, 1);
    return monthStart.isAfter(now) ? 0 : dailySleep.length;
  }

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  Future<void> loadMonthlyData() async {
    setState(() {
      isLoading = true;
    });

    final requested = currentMonth;
    DateTime monthStart = DateTime(currentMonth.year, currentMonth.month, 1);

    DateTime monthEnd = DateTime(currentMonth.year, currentMonth.month + 1, 1);

    // Comparison period in the previous month.
    final now = DateTime.now();
    final isCurrent =
        currentMonth.year == now.year && currentMonth.month == now.month;
    final prevStart = DateTime(currentMonth.year, currentMonth.month - 1, 1);
    final prevDays = DateTime(currentMonth.year, currentMonth.month, 0).day;
    final prevEnd = isCurrent
        ? DateTime(
            prevStart.year,
            prevStart.month,
            math.min(now.day, prevDays) + 1,
          )
        : monthStart;
    final lastMonthFuture = _sleepBetween(prevStart, prevEnd);
    final sessionsFuture = _sessionsBetween(monthStart, monthEnd);

    final snapshot = await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .where("sleep_start", isGreaterThanOrEqualTo: monthStart)
        .where("sleep_start", isLessThan: monthEnd)
        .orderBy("sleep_start")
        .get();
    final lastMonthTotal = await lastMonthFuture;
    final sessionDocs = await sessionsFuture;

    // Ignore results if the user already moved to another month.
    if (!mounted || requested != currentMonth) return;

    int total = 0;

    int sessions = 0;

    int longest = 0;

    int shortest = 999999;

    DateTime? longestDay;

    int daysInMonth = DateTime(
      currentMonth.year,
      currentMonth.month + 1,
      0,
    ).day;

    List<int> chart = List.generate(daysInMonth, (_) => 0);
    List<int> counts = List.generate(daysInMonth, (_) => 0);
    final bedtimes = List<DateTime?>.filled(daysInMonth, null);
    final wakes = List<DateTime?>.filled(daysInMonth, null);
    final longestOfDay = List<int>.filled(daysInMonth, -1);

    List<Map<String, dynamic>> records = [];

    for (var doc in snapshot.docs) {
      final data = doc.data();

      // Exact seconds when available; older/device records only have
      // minutes. Everything on this screen is in seconds (same as Weekly).
      final secondsField = data["sleep_duration_seconds"];
      final minutesField = data["sleep_duration_minutes"];
      int duration = secondsField is num
          ? secondsField.toInt()
          : minutesField is num
          ? (minutesField * 60).toInt()
          : 0;
      if (duration < 0) duration = 0;

      final ts = data["sleep_start"];
      if (ts is! Timestamp) continue;

      DateTime date = ts.toDate();

      total += duration;

      sessions++;

      if (duration > longest) {
        longest = duration;

        longestDay = date;
      }

      if (duration < shortest) {
        shortest = duration;
      }

      chart[date.day - 1] += duration;
      counts[date.day - 1]++;
      if (duration > longestOfDay[date.day - 1]) {
        longestOfDay[date.day - 1] = duration;
        bedtimes[date.day - 1] = date;
        final end = data["sleep_end"];
        wakes[date.day - 1] = end is Timestamp
            ? end.toDate()
            : date.add(Duration(seconds: duration));
      }

      records.add({
        "date": date,
        "duration": duration,
        "start": data["sleep_start"],
        "end": data["sleep_end"],
      });
    }

    setState(() {
      totalSleep = total;

      totalSessions = sessions;

      bestSleep = longest;

      shortestSleep = shortest == 999999 ? 0 : shortest;

      bestDay = longestDay;

      dailySleep = chart;

      dailyCount = counts;

      sleepRecords = records;

      _focusedDay = null;

      _showAllRecords = false;

      lastMonthSleep = lastMonthTotal;

      dailyBedtime = bedtimes;

      dailyWake = wakes;

      _windowDay = null;

      monthSessions = sessionDocs;

      isLoading = false;
    });
  }

  /// Session documents (vibration / heat / pillow temperature) in a range.
  Future<List<Map<String, dynamic>>> _sessionsBetween(
    DateTime from,
    DateTime to,
  ) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .where("timestamp", isGreaterThanOrEqualTo: from)
          .where("timestamp", isLessThan: to)
          .get();
      return [
        for (final doc in snap.docs)
          if (doc.data()["type"] == "session") doc.data(),
      ];
    } catch (e) {
      debugPrint("SESSIONS LOAD ERROR: $e");
      return [];
    }
  }

  /// Total sleep (seconds) of sleep records starting in [from, to).
  Future<int> _sleepBetween(DateTime from, DateTime to) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .where("sleep_start", isGreaterThanOrEqualTo: from)
          .where("sleep_start", isLessThan: to)
          .get();
      int total = 0;
      for (final doc in snap.docs) {
        final d = doc.data();
        final sec = d["sleep_duration_seconds"];
        final min = d["sleep_duration_minutes"];
        final v = sec is num
            ? sec.toInt()
            : min is num
            ? (min * 60).toInt()
            : 0;
        if (v > 0) total += v;
      }
      return total;
    } catch (e) {
      debugPrint("LAST MONTH LOAD ERROR: $e");
      return 0;
    }
  }

  /// Formats a duration in seconds: "1h 05m", "6m 18s", "13s".
  String formatDuration(int seconds) {
    if (seconds <= 0) return "0m";
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final sec = seconds % 60;
    if (h > 0) return "${h}h ${m.toString().padLeft(2, '0')}m";
    if (m > 0) return "${m}m ${sec.toString().padLeft(2, '0')}s";
    return "${sec}s";
  }

  String formatTime(Timestamp? ts) {
    if (ts == null) return "-";

    return DateFormat("h:mm a").format(ts.toDate());
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return currentMonth.year == now.year && currentMonth.month == now.month;
  }

  void _changeMonth(int delta) {
    if (delta > 0 && _isCurrentMonth) return;
    HapticFeedback.selectionClick();
    setState(() {
      currentMonth = DateTime(currentMonth.year, currentMonth.month + delta);
    });
    loadMonthlyData();
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
            child: RefreshIndicator(
              color: _cyan,
              backgroundColor: _surface,
              onRefresh: loadMonthlyData,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                    sliver: SliverToBoxAdapter(
                      child: _Entrance(index: 0, child: _header()),
                    ),
                  ),
                  // Month switcher + tabs stay pinned while scrolling.
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _PinnedBar(
                      extent: 146,
                      child: _Entrance(
                        index: 1,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _monthSwitcher(),
                              const SizedBox(height: 10),
                              _tabBar(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    sliver: SliverToBoxAdapter(
                      child: AnimatedSwitcher(
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
                                key: ValueKey(
                                  "${currentMonth.year}-${currentMonth.month}-$_tab",
                                ),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: _tabContent(),
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
    );
  }

  // ===================================================================
  // TABS
  // ===================================================================
  static const List<({String label, IconData icon})> _tabs = [
    (label: "Overview", icon: Icons.dashboard_rounded),
    (label: "Trends", icon: Icons.show_chart_rounded),
    (label: "Insights", icon: Icons.auto_awesome_rounded),
    (label: "Records", icon: Icons.list_alt_rounded),
  ];

  Widget _tabBar() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: _glass(radius: 18),
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
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: _tab == i ? _mainGradient : null,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _tab == i
                        ? [
                            BoxShadow(
                              color: _violet.withValues(alpha: .45),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
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
                      ),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          i == 3
                              ? "${_tabs[i].label} (${sleepRecords.length})"
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

  Widget _showAllButton() {
    final hidden = sleepRecords.length - _recordsPreview;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: _glass(radius: 16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _showAllRecords = !_showAllRecords);
            },
            child: SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _showAllRecords
                        ? "Show less"
                        : "Show all ${sleepRecords.length} records",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!_showAllRecords) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _cyan.withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "+$hidden",
                        style: const TextStyle(
                          color: _cyan,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _showAllRecords
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: _white(.7),
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _tabContent() {
    const gap = SizedBox(height: 16);
    switch (_tab) {
      case 1: // Trends
        return [
          _Entrance(index: 2, child: buildBarChart()),
          gap,
          _Entrance(index: 3, child: _sleepWindowCard()),
          gap,
          _Entrance(index: 4, child: _weeksCard()),
          gap,
          _Entrance(index: 5, child: _weekdayCard()),
        ];
      case 2: // Insights
        return [
          _Entrance(index: 2, child: _bedtimeCard()),
          gap,
          _Entrance(index: 3, child: _wakeCard()),
          gap,
          _Entrance(index: 4, child: _weekdayWeekendCard()),
          gap,
          _Entrance(index: 5, child: _bestWorstCard()),
          gap,
          _Entrance(index: 6, child: _comfortCard()),
        ];
      case 3: // Records
        return [
          _Entrance(
            index: 2,
            child: Row(
              children: [
                Text("Sleep records", style: _display(20)),
                const SizedBox(width: 10),
                _countPill(sleepRecords.length),
                const Spacer(),
                Text(
                  "Tap to view day",
                  style: TextStyle(color: _white(.4), fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (sleepRecords.isEmpty)
            _Entrance(index: 3, child: _emptyRecords())
          else ...[
            for (final (i, record)
                in sleepRecords.reversed
                    .take(
                      _showAllRecords ? sleepRecords.length : _recordsPreview,
                    )
                    .indexed)
              _Entrance(index: 3 + i, child: buildSleepRecord(record)),
            if (sleepRecords.length > _recordsPreview) _showAllButton(),
          ],
        ];
      default: // Overview
        return [
          _Entrance(index: 2, child: _heroCard()),
          gap,
          _Entrance(index: 3, child: _healthyRangeCard()),
          gap,
          _Entrance(index: 4, child: _monthDebtCard()),
          gap,
          _Entrance(index: 5, child: _streakCard()),
          gap,
          _Entrance(index: 6, child: _heatmapCard()),
        ];
    }
  }

  // ===================================================================
  // HEADER + MONTH SWITCHER
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
          "MONTHLY REPORT",
          style: _eyebrow(color: _cyan.withValues(alpha: .85)),
        ),
        const SizedBox(height: 8),
        Text("Monthly Sleep", style: _display(36, weight: FontWeight.w700)),
      ],
    );
  }

  Widget _monthSwitcher() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: _glass(radius: 20),
      child: Row(
        children: [
          _roundButton(Icons.chevron_left_rounded, () => _changeMonth(-1)),
          Expanded(
            child: Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    DateFormat("MMMM yyyy").format(currentMonth),
                    key: ValueKey(currentMonth.month + currentMonth.year * 12),
                    style: _display(17, weight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isCurrentMonth ? "This month" : "Past month",
                  style: TextStyle(color: _white(.5), fontSize: 11.5),
                ),
              ],
            ),
          ),
          Opacity(
            opacity: _isCurrentMonth ? .3 : 1,
            child: _roundButton(
              Icons.chevron_right_rounded,
              () => _changeMonth(1),
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
  // HERO SUMMARY
  // ===================================================================
  Widget _heroCard() {
    final loggedDays = dailySleep.where((m) => m > 0).length;

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => _mainGradient.createShader(r),
                child: Text(
                  totalSessions == 0 ? "—" : formatDuration(totalSleep),
                  style: _display(40, weight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  "across $totalSessions "
                  "${totalSessions == 1 ? 'session' : 'sessions'}",
                  style: TextStyle(color: _white(.55), fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _comparisonBadge(),
          const SizedBox(height: 14),
          _goalRow(),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 2.5,
            children: [
              summaryCard(
                "Avg / session",
                totalSessions == 0
                    ? "-"
                    : formatDuration(totalSleep ~/ totalSessions),
                Icons.av_timer_rounded,
                _cyan,
              ),
              summaryCard(
                "Best sleep",
                bestDay == null
                    ? "-"
                    : "${DateFormat("MMM d").format(bestDay!)} · "
                          "${formatDuration(bestSleep)}",
                Icons.emoji_events_rounded,
                _amber,
              ),
              summaryCard(
                "Shortest",
                totalSessions == 0 ? "-" : formatDuration(shortestSleep),
                Icons.hourglass_bottom_rounded,
                _rose,
              ),
              summaryCard(
                "Days logged",
                "$loggedDays/${dailySleep.length}",
                Icons.event_available_rounded,
                _magenta,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // STREAKS
  // ===================================================================
  /// Longest run of consecutive days with sleep in this month.
  int get _longestStreak {
    int best = 0, run = 0;
    for (final s in dailySleep) {
      if (s > 0) {
        run++;
        best = math.max(best, run);
      } else {
        run = 0;
      }
    }
    return best;
  }

  /// Consecutive days with sleep up to today (or yesterday if nothing is
  /// logged yet today, so the streak isn't "broken" during the day).
  /// Only meaningful for the current month.
  int get _currentStreak {
    if (!_isCurrentMonth || dailySleep.isEmpty) return 0;
    var i = math.min(DateTime.now().day, dailySleep.length) - 1;
    if (dailySleep[i] == 0) i--;
    int run = 0;
    while (i >= 0 && dailySleep[i] > 0) {
      run++;
      i--;
    }
    return run;
  }

  Widget _streakCard() {
    final longest = _longestStreak;
    final current = _currentStreak;
    final todayLogged =
        _isCurrentMonth &&
        dailySleep.isNotEmpty &&
        dailySleep[math.min(DateTime.now().day, dailySleep.length) - 1] > 0;

    String hint;
    if (!_isCurrentMonth) {
      hint = longest == 0
          ? "No sleep logged this month."
          : "Your best run this month was $longest "
                "${longest == 1 ? 'day' : 'days'} in a row.";
    } else if (current == 0) {
      hint = "Log sleep today to start a new streak!";
    } else if (!todayLogged) {
      hint = "Sleep today to keep your $current-day streak going.";
    } else if (current >= longest && current > 1) {
      hint = "You're on your best streak this month. Keep it up!";
    } else {
      hint = "Nice! Keep logging sleep every day to grow your streak.";
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _glass(radius: 24),
      child: Column(
        children: [
          Row(
            children: [
              if (_isCurrentMonth) ...[
                _streakTile(
                  icon: Icons.local_fire_department_rounded,
                  value: current,
                  label: "Current streak",
                  gradient: const LinearGradient(
                    colors: [_amber, Color(0xFFFF5E3A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  active: current > 0,
                ),
                const SizedBox(width: 8),
              ],
              _streakTile(
                icon: Icons.emoji_events_rounded,
                value: longest,
                label: "Longest streak",
                gradient: _mainGradient,
                active: longest > 0,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.lightbulb_rounded, color: _amber, size: 15),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hint,
                  style: TextStyle(color: _white(.7), fontSize: 12.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _streakTile({
    required IconData icon,
    required int value,
    required String label,
    required Gradient gradient,
    required bool active,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _white(.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _white(.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: active ? gradient : null,
                color: active ? null : _white(.06),
                borderRadius: BorderRadius.circular(13),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: gradient.colors.first.withValues(alpha: .45),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                icon,
                color: active ? Colors.white : _white(.35),
                size: 21,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: "$value",
                          style: _display(22, weight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: value == 1 ? " day" : " days",
                          style: TextStyle(color: _white(.55), fontSize: 12),
                        ),
                      ],
                    ),
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
          ],
        ),
      ),
    );
  }

  // ===================================================================
  // WEEKDAY PATTERN
  // ===================================================================
  static const List<String> _weekdayNames = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
  ];

  /// Average sleep (seconds) for each weekday (Sun..Sat) over the days of
  /// this month that have already happened. Days with no sleep count as 0,
  /// so the average reflects your real habit. Null if that weekday hasn't
  /// occurred yet.
  List<int?> _weekdayAverages() {
    final totals = List<int>.filled(7, 0);
    final counts = List<int>.filled(7, 0);
    final today = DateUtils.dateOnly(DateTime.now());
    for (int i = 0; i < dailySleep.length; i++) {
      final date = DateTime(currentMonth.year, currentMonth.month, i + 1);
      if (date.isAfter(today)) break;
      final w = date.weekday % 7;
      totals[w] += dailySleep[i];
      counts[w]++;
    }
    return [
      for (int w = 0; w < 7; w++)
        counts[w] == 0 ? null : totals[w] ~/ counts[w],
    ];
  }

  Widget _weekdayCard() {
    final avgs = _weekdayAverages();
    final known = [
      for (int w = 0; w < 7; w++)
        if (avgs[w] != null) w,
    ];
    final maxAvg = known.isEmpty
        ? 0
        : known.map((w) => avgs[w]!).reduce(math.max);

    int? best, worst;
    if (maxAvg > 0) {
      for (final w in known) {
        if (best == null || avgs[w]! > avgs[best]!) best = w;
        if (worst == null || avgs[w]! < avgs[worst]!) worst = w;
      }
    }

    String message;
    if (best == null) {
      message = "Log sleep on a few different days to see your weekly pattern.";
    } else if (worst == null || best == worst || avgs[best] == avgs[worst]) {
      message = "You sleep most on ${_weekdayNames[best]}s.";
    } else {
      message =
          "You sleep most on ${_weekdayNames[best]}s "
          "(${formatDuration(avgs[best]!)}) and least on "
          "${_weekdayNames[worst!]}s (${formatDuration(avgs[worst]!)}).";
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
                  gradient: _mainGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _violet.withValues(alpha: .4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.view_week_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Weekday pattern", style: _display(17)),
                    const SizedBox(height: 2),
                    Text(
                      "Average sleep for each day of the week",
                      style: TextStyle(color: _white(.5), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int w = 0; w < 7; w++)
                  Expanded(
                    child: _weekdayBar(
                      label: _weekdayNames[w].substring(0, 3),
                      seconds: avgs[w],
                      fraction: maxAvg == 0 || avgs[w] == null
                          ? 0.0
                          : avgs[w]! / maxAvg,
                      highlight: w == best
                          ? _green
                          : (w == worst && best != worst ? _rose : null),
                    ),
                  ),
              ],
            ),
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
                Icon(Icons.insights_rounded, color: _cyan, size: 16),
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

  Widget _weekdayBar({
    required String label,
    required int? seconds,
    required double fraction,
    Color? highlight,
  }) {
    final hasData = seconds != null && seconds > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              hasData ? _shortDuration(seconds!) : "–",
              style: TextStyle(
                color: highlight ?? _white(hasData ? .75 : .3),
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: fraction),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => FractionallySizedBox(
                  heightFactor: math.max(v, .04),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: hasData
                          ? LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: highlight == _green
                                  ? const [Color(0xFF10B981), _green]
                                  : highlight == _rose
                                  ? [_rose.withValues(alpha: .6), _rose]
                                  : [
                                      _violet.withValues(alpha: .7),
                                      _cyan.withValues(alpha: .7),
                                    ],
                            )
                          : null,
                      color: hasData ? null : _white(.06),
                      boxShadow: highlight != null && hasData
                          ? [
                              BoxShadow(
                                color: highlight.withValues(alpha: .4),
                                blurRadius: 10,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: highlight ?? _white(.5),
              fontSize: 11,
              fontWeight: highlight != null ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Compact duration for small labels: "1h5", "12m", "40s".
  String _shortDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return m == 0 ? "${h}h" : "${h}h${m.toString().padLeft(2, '0')}";
    if (m > 0) return "${m}m";
    return "${seconds}s";
  }

  // ===================================================================
  // SHARED SMALL PIECES (new cards)
  // ===================================================================
  LinearGradient _solid(Color c) => LinearGradient(colors: [c, c]);

  Widget _pill(String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 13),
            const SizedBox(width: 4),
          ],
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

  String _hm(int seconds) {
    final s = seconds.abs();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return m == 0 ? "${h}h" : "${h}h ${m}m";
    if (m > 0) return "${m}m";
    return "${s}s";
  }

  // ===================================================================
  // HEALTHY-RANGE BREAKDOWN
  // ===================================================================
  static const List<({String label, int min, int max, Color color})> _ranges = [
    (label: "Under 5h", min: 0, max: 5 * 3600, color: _rose),
    (label: "5–6h", min: 5 * 3600, max: 6 * 3600, color: Color(0xFFFF9A62)),
    (label: "6–7h", min: 6 * 3600, max: 7 * 3600, color: _amber),
    (label: "7–9h healthy", min: 7 * 3600, max: 9 * 3600, color: _green),
    (label: "9h+", min: 9 * 3600, max: 1 << 30, color: _cyan),
  ];

  Widget _healthyRangeCard() {
    final logged = [
      for (final d in dailySleep)
        if (d > 0) d,
    ];
    final counts = [
      for (final r in _ranges)
        logged.where((d) => d >= r.min && d < r.max).length,
    ];
    final healthy = counts[3];
    final pct = logged.isEmpty ? 0 : (healthy / logged.length * 100).round();

    final Color pctColor = logged.isEmpty
        ? _white(.55)
        : pct >= 70
        ? _green
        : pct >= 40
        ? _amber
        : _rose;

    String tip;
    if (logged.isEmpty) {
      tip = "Sleep with ComfortNap to see how many days reach a healthy 7–9h.";
    } else if (pct >= 70) {
      tip = "Most of your days hit the healthy range. Keep it up!";
    } else if (counts[0] + counts[1] > counts[2] + counts[3]) {
      tip =
          "Most days are under 6h. Adults need 7–9h; try moving bedtime "
          "earlier in small 15–30 min steps.";
    } else {
      tip =
          "You're close. A little more sleep on your 6–7h days would move "
          "them into the healthy range.";
    }

    return _insightCard(
      icon: Icons.health_and_safety_rounded,
      gradient: _solid(_green),
      title: "Healthy sleep range",
      subtitle: "How each day's sleep compares with 7–9h",
      badge: _pill(logged.isEmpty ? "No data" : "$pct% healthy", pctColor),
      children: [
        const SizedBox(height: 14),
        if (logged.isNotEmpty) ...[
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: "$healthy of ${logged.length}",
                  style: _display(24, weight: FontWeight.w700, color: pctColor),
                ),
                TextSpan(
                  text: "  days were 7–9h",
                  style: TextStyle(color: _white(.6), fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Stacked bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  for (int k = 0; k < _ranges.length; k++)
                    if (counts[k] > 0)
                      Expanded(
                        flex: counts[k],
                        child: Container(
                          margin: const EdgeInsets.only(right: 2),
                          color: _ranges[k].color,
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        for (int k = 0; k < _ranges.length; k++)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _ranges[k].color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _ranges[k].label,
                  style: TextStyle(
                    color: k == 3 ? Colors.white : _white(.65),
                    fontSize: 12.5,
                    fontWeight: k == 3 ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Container(
                      height: 4,
                      color: _white(.06),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: logged.isEmpty
                            ? 0
                            : counts[k] / logged.length,
                        child: Container(color: _ranges[k].color),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 52,
                  child: Text(
                    "${counts[k]} day${counts[k] == 1 ? '' : 's'}",
                    textAlign: TextAlign.right,
                    style: TextStyle(color: _white(.6), fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        _tipBox(tip),
      ],
    );
  }

  // ===================================================================
  // MONTHLY SLEEP DEBT
  // ===================================================================
  Widget _monthDebtCard() {
    // Running balance over logged days: + means short of the goal.
    final points = <double>[];
    int running = 0;
    for (final d in dailySleep) {
      if (d > 0) {
        running += goalSeconds - d;
        points.add(running.toDouble());
      }
    }
    final logged = points.length;
    final debt = running;
    final short = logged > 0 && debt > 59;
    final color = logged == 0
        ? _white(.55)
        : short
        ? _rose
        : _green;

    // Recent direction: last 3 logged days.
    String? trend;
    Color trendColor = _white(.55);
    if (points.length >= 4) {
      final recent = points.last - points[points.length - 4];
      if (recent < -15 * 60) {
        trend = "Catching up";
        trendColor = _green;
      } else if (recent > 15 * 60) {
        trend = "Growing";
        trendColor = _rose;
      } else {
        trend = "Holding";
        trendColor = _cyan;
      }
    }

    final perNight = short
        ? (((debt / 7 / 60) / 5).round() * 5).clamp(15, 60)
        : 0;

    String tip;
    if (logged == 0) {
      tip = "No sleep logged this month yet.";
    } else if (!short) {
      tip = debt < -59
          ? "You slept ${_hm(debt)} more than your goal this month. Well rested!"
          : "You're right on your goal this month. Nice balance!";
    } else if (debt > 20 * 3600) {
      tip =
          "That's a big debt. Don't try to repay it in one go: add "
          "+${perNight}m a night and keep a steady bedtime.";
    } else {
      tip = "Add about +${perNight}m a night for the next week to catch up.";
    }

    return _insightCard(
      icon: Icons.account_balance_wallet_rounded,
      gradient: _solid(short ? _rose : _green),
      title: "Monthly sleep debt",
      subtitle:
          "Goal ${_goalLabel(goalSeconds)} × $logged logged day${logged == 1 ? '' : 's'}",
      badge: trend == null ? null : _pill(trend, trendColor),
      children: [
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              logged == 0
                  ? "—"
                  : short
                  ? _hm(debt)
                  : debt < -59
                  ? "+${_hm(debt)}"
                  : "None",
              style: _display(30, weight: FontWeight.w700, color: color),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                logged == 0
                    ? ""
                    : short
                    ? "short this month"
                    : debt < -59
                    ? "ahead of goal"
                    : "on goal",
                style: TextStyle(color: _white(.55), fontSize: 12.5),
              ),
            ),
          ],
        ),
        if (points.length >= 2) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 70,
            width: double.infinity,
            child: CustomPaint(
              painter: _DebtLinePainter(points: points, color: color),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                "Start of month",
                style: TextStyle(color: _white(.35), fontSize: 10),
              ),
              const Spacer(),
              Text(
                "Latest",
                style: TextStyle(color: _white(.35), fontSize: 10),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _tipBox(tip),
      ],
    );
  }

  // ===================================================================
  // SLEEP WINDOW CHART (bedtime → wake per day)
  // ===================================================================
  Widget _sleepWindowCard() {
    final days = dailySleep.length;
    final hasAny = dailyBedtime.any((b) => b != null);
    final sel = _windowDay;

    String? detail;
    if (sel != null && dailyBedtime[sel - 1] != null) {
      final b = dailyBedtime[sel - 1]!;
      final w = dailyWake[sel - 1];
      final date = DateTime(currentMonth.year, currentMonth.month, sel);
      detail =
          "${DateFormat('EEE, MMM d').format(date)} · "
          "${DateFormat('h:mm a').format(b)} → "
          "${w == null ? '?' : DateFormat('h:mm a').format(w)} · "
          "${_hm(dailySleep[sel - 1])}";
    }

    return _insightCard(
      icon: Icons.view_timeline_rounded,
      gradient: _solid(_violet),
      title: "Sleep window",
      subtitle: "When you slept each day · tap a bar",
      badge: _pill("Goal met", _green, icon: Icons.circle),
      children: [
        const SizedBox(height: 14),
        if (!hasAny)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                "No sleep logged this month yet.",
                style: TextStyle(color: _white(.5), fontSize: 13),
              ),
            ),
          )
        else ...[
          SizedBox(
            height: 210,
            child: Row(
              children: [
                // Time labels (axis runs 6 PM at top → 6 PM next day)
                SizedBox(
                  width: 40,
                  child: LayoutBuilder(
                    builder: (context, box) => Stack(
                      children: [
                        for (final (i, t) in const [
                          "6 PM",
                          "12 AM",
                          "6 AM",
                          "12 PM",
                          "6 PM",
                        ].indexed)
                          Positioned(
                            top: (box.maxHeight - 14) * i / 4,
                            left: 0,
                            child: Text(
                              t,
                              style: TextStyle(
                                color: t == "12 AM" ? _white(.7) : _white(.38),
                                fontSize: 9.5,
                                fontWeight: t == "12 AM"
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final colW = box.maxWidth / days;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) {
                          final day =
                              (d.localPosition.dx / colW).floor().clamp(
                                0,
                                days - 1,
                              ) +
                              1;
                          HapticFeedback.selectionClick();
                          setState(
                            () => _windowDay =
                                dailyBedtime[day - 1] == null ||
                                    _windowDay == day
                                ? null
                                : day,
                          );
                        },
                        child: CustomPaint(
                          size: Size(box.maxWidth, box.maxHeight),
                          painter: _SleepWindowPainter(
                            bedtimes: dailyBedtime,
                            wakes: dailyWake,
                            sleep: dailySleep,
                            goalSeconds: goalSeconds,
                            selected: sel,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final d in [1, 8, 15, 22, days])
                  Text("$d", style: TextStyle(color: _white(.4), fontSize: 10)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: detail == null
                ? Text(
                    "Green bars met your ${_goalLabel(goalSeconds)} goal. "
                    "Taller bars = longer sleep; higher up = earlier bedtime.",
                    key: const ValueKey("hint"),
                    style: TextStyle(color: _white(.5), fontSize: 11.5),
                  )
                : Container(
                    key: ValueKey(sel),
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _violet.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _violet.withValues(alpha: .35)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            detail,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _openDay(
                            DateTime(
                              currentMonth.year,
                              currentMonth.month,
                              sel!,
                            ),
                          ),
                          child: const Text(
                            "Open",
                            style: TextStyle(
                              color: _cyan,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  // ===================================================================
  // WAKE-UP CONSISTENCY (month)
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

  Widget _wakeCard() {
    final stats = _timeStats(dailyWake);
    final rating = _consistencyRating(stats);
    final around = stats == null ? null : ((stats.mean / 5).round() * 5) % 1440;

    String message;
    if (stats == null) {
      message = "No wake-ups logged this month yet.";
    } else if (stats.days < 2) {
      message = "Log sleep on at least 2 days to see your wake-up pattern.";
    } else if (stats.spread <= 60) {
      message =
          "Across ${stats.days} days you woke within about "
          "${_spreadText(stats.spread)} of the same time. A steady wake-up "
          "time is the strongest anchor for your body clock.";
    } else {
      message =
          "Your wake-up time varied by about ${_spreadText(stats.spread)} "
          "this month. Try getting up at the same time every day, even on "
          "weekends; the wake-up alarm in Set Timer can help.";
    }

    return _insightCard(
      icon: Icons.wb_sunny_rounded,
      gradient: _solid(_amber),
      title: "Wake-up consistency",
      subtitle: "When your main sleep ended each day",
      badge: _pill(rating.label, rating.color),
      children: [
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
        _MonthBedtimeTrack(
          bedtimes: dailyWake,
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
    );
  }

  // ===================================================================
  // WEEKDAYS vs WEEKEND (month)
  // ===================================================================
  int _mins(DateTime t) => t.hour * 60 + t.minute;

  int? _midSleepOf(int i) {
    final b = dailyBedtime[i];
    final w = dailyWake[i];
    if (b == null || w == null || !w.isAfter(b)) return null;
    return _mins(b.add(Duration(seconds: w.difference(b).inSeconds ~/ 2)));
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

  int _clockDiff(int a, int b) {
    var d = (b - a) % 1440;
    if (d > 720) d -= 1440;
    return d;
  }

  Widget _weekdayWeekendCard() {
    // Indexes (day of month − 1) split by weekday / weekend.
    final weekdayIdx = <int>[];
    final weekendIdx = <int>[];
    for (int i = 0; i < dailySleep.length; i++) {
      final wd = DateTime(currentMonth.year, currentMonth.month, i + 1).weekday;
      (wd == DateTime.saturday || wd == DateTime.sunday
              ? weekendIdx
              : weekdayIdx)
          .add(i);
    }

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
            if (dailyBedtime[i] != null) _mins(dailyBedtime[i]!),
        ]),
        wake: _circularMean([
          for (final i in idx)
            if (dailyWake[i] != null) _mins(dailyWake[i]!),
        ]),
        mid: _circularMean([
          for (final i in idx)
            if (_midSleepOf(i) case final m?) m,
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
      message = "Log sleep on weekdays and weekends to compare your schedules.";
    } else {
      final abs = shift.abs();
      final dir = shift >= 0 ? "later" : "earlier";
      if (abs < 60) {
        badge = "Steady";
        badgeColor = _green;
        message =
            "This month your weekend sleep was only ${_spreadText(abs)} $dir "
            "than on weekdays. Your body clock stays in sync all week.";
      } else if (abs < 120) {
        badge = "Small shift";
        badgeColor = _amber;
        message =
            "On weekends you slept ${_spreadText(abs)} $dir this month. "
            "Keeping it under 1h makes Mondays easier.";
      } else {
        badge = "Social jet lag";
        badgeColor = _rose;
        message =
            "On weekends you slept ${_spreadText(abs)} $dir this month, like "
            "flying to another time zone and back each week. Try keeping "
            "weekend bedtime and wake-up within 1h of your weekdays.";
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
            Text(value, style: _display(13.5, weight: FontWeight.w700)),
          ],
        ),
      );

      return Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
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

    return _insightCard(
      icon: Icons.compare_arrows_rounded,
      gradient: _solid(_violet),
      title: "Weekdays vs weekend",
      subtitle: "Mon–Fri compared with Sat–Sun this month",
      badge: _pill(badge, badgeColor),
      children: [
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
              Text(
                shift.abs() < 5
                    ? "None"
                    : "${shift > 0 ? '+' : '−'}${_spreadText(shift.abs())} "
                          "${shift > 0 ? 'later' : 'earlier'}",
                style: _display(15, weight: FontWeight.w700, color: badgeColor),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _tipBox(message),
      ],
    );
  }

  // ===================================================================
  // BEST & WORST NIGHTS
  // ===================================================================
  /// The session that led to day [i]'s sleep (longest one that day).
  Map<String, dynamic>? _sessionForDay(int i) {
    Map<String, dynamic>? best;
    int bestSleep = -1;
    for (final s in monthSessions) {
      final ts = s["sleep_start_time"] ?? s["timestamp"];
      if (ts is! Timestamp) continue;
      final d = ts.toDate();
      if (d.year != currentMonth.year ||
          d.month != currentMonth.month ||
          d.day != i + 1) {
        continue;
      }
      final sl = _sleepOf(s);
      if (sl > bestSleep) {
        bestSleep = sl;
        best = s;
      }
    }
    return best;
  }

  Widget _bestWorstCard() {
    final logged = [
      for (int i = 0; i < dailySleep.length; i++)
        if (dailySleep[i] > 0) i,
    ]..sort((a, b) => dailySleep[b].compareTo(dailySleep[a]));

    final best = logged.take(3).toList();
    final worst = logged.length > 3
        ? logged.reversed.take(math.min(3, logged.length - 3)).toList()
        : <int>[];

    // Insight: compare bedtimes and settings of best vs worst nights.
    String? insight;
    if (best.isNotEmpty && worst.isNotEmpty) {
      final bBed = _circularMean([
        for (final i in best)
          if (dailyBedtime[i] != null) _mins(dailyBedtime[i]!),
      ]);
      final wBed = _circularMean([
        for (final i in worst)
          if (dailyBedtime[i] != null) _mins(dailyBedtime[i]!),
      ]);
      final parts = <String>[];
      if (bBed != null && wBed != null) {
        final diff = _clockDiff(bBed, wBed); // + = worst nights started later
        if (diff >= 30) {
          parts.add(
            "your longest nights started about ${_spreadText(diff)} earlier "
            "(around ${_clock(((bBed / 5).round() * 5) % 1440)})",
          );
        } else if (diff <= -30) {
          parts.add(
            "your longest nights started about ${_spreadText(-diff)} later "
            "(around ${_clock(((bBed / 5).round() * 5) % 1440)})",
          );
        }
      }
      final bHeat = [
        for (final i in best)
          if (_sessionForDay(i) case final s?)
            if (_heatOf(s) case final h?) h,
      ];
      final wHeat = [
        for (final i in worst)
          if (_sessionForDay(i) case final s?)
            if (_heatOf(s) case final h?) h,
      ];
      if (bHeat.isNotEmpty && wHeat.isNotEmpty) {
        final bh = (bHeat.reduce((a, b) => a + b) / bHeat.length).round();
        final wh = (wHeat.reduce((a, b) => a + b) / wHeat.length).round();
        if ((bh - wh).abs() >= 15) {
          parts.add("they used heat around $bh% (vs $wh% on short nights)");
        }
      }
      insight = parts.isEmpty
          ? "No clear pattern yet between your longest and shortest nights. "
                "Keep logging to find what works for you."
          : "This month ${parts.join(', and ')}. Try repeating that routine.";
    }

    Widget row(int i, Color color, int rank) {
      final date = DateTime(currentMonth.year, currentMonth.month, i + 1);
      final b = dailyBedtime[i];
      final w = dailyWake[i];
      final sess = _sessionForDay(i);
      final v = sess == null ? null : _vibrationOf(sess);
      final h = sess == null ? null : _heatOf(sess);
      final settings = [
        if (v != null) "Vib ${v.round()}%",
        if (h != null) "Heat ${h.round()}%",
      ].join(" · ");

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openDay(date),
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: .22)),
          ),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .2),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  "$rank",
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat('EEE, MMM d').format(date),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (b != null)
                          "${DateFormat('h:mm a').format(b)} → "
                              "${w == null ? '?' : DateFormat('h:mm a').format(w)}",
                        if (settings.isNotEmpty) settings,
                      ].join("  ·  "),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _white(.5), fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _hm(dailySleep[i]),
                style: _display(15, weight: FontWeight.w700, color: color),
              ),
            ],
          ),
        ),
      );
    }

    Widget label(IconData icon, Color color, String text) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: .5,
            ),
          ),
        ],
      ),
    );

    return _insightCard(
      icon: Icons.emoji_events_rounded,
      gradient: _solid(_amber),
      title: "Best & worst nights",
      subtitle: "Your longest and shortest sleep · tap to open",
      children: [
        if (logged.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              "No sleep logged this month yet.",
              style: TextStyle(color: _white(.5), fontSize: 13),
            ),
          )
        else ...[
          label(Icons.trending_up_rounded, _green, "LONGEST"),
          for (final (k, i) in best.indexed) row(i, _green, k + 1),
          if (worst.isNotEmpty) ...[
            label(Icons.trending_down_rounded, _rose, "SHORTEST"),
            for (final (k, i) in worst.indexed) row(i, _rose, k + 1),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                "Log 4+ days to compare with your shortest nights.",
                style: TextStyle(color: _white(.45), fontSize: 11.5),
              ),
            ),
          if (insight != null) ...[
            const SizedBox(height: 14),
            _tipBox(insight),
          ],
        ],
      ],
    );
  }

  // ===================================================================
  // WEEK BY WEEK
  // ===================================================================
  /// Calendar weeks (Sun–Sat) of the month, clipped to the month's days.
  List<({int firstDay, int lastDay, int total, bool started})> _monthWeeks() {
    final weeks = <({int firstDay, int lastDay, int total, bool started})>[];
    final days = dailySleep.length;
    if (days == 0) return weeks;
    final today = DateUtils.dateOnly(DateTime.now());

    int day = 1;
    while (day <= days) {
      final date = DateTime(currentMonth.year, currentMonth.month, day);
      final last = math.min(days, day + (6 - date.weekday % 7));
      int total = 0;
      for (int d = day; d <= last; d++) {
        total += dailySleep[d - 1];
      }
      weeks.add((
        firstDay: day,
        lastDay: last,
        total: total,
        started: !date.isAfter(today),
      ));
      day = last + 1;
    }
    return weeks;
  }

  Widget _weeksCard() {
    final weeks = _monthWeeks();
    final started = [
      for (final w in weeks)
        if (w.started) w,
    ];
    final maxTotal = started.isEmpty
        ? 0
        : started.map((w) => w.total).reduce(math.max);
    final bestIndex = maxTotal == 0
        ? -1
        : weeks.indexWhere((w) => w.started && w.total == maxTotal);
    final monthAbbr = DateFormat("MMM").format(currentMonth);

    String message;
    if (maxTotal == 0) {
      message = "No sleep logged yet this month.";
    } else {
      final best = weeks[bestIndex];
      message =
          "Your best week was Week ${bestIndex + 1} "
          "($monthAbbr ${best.firstDay}–${best.lastDay}) with "
          "${formatDuration(best.total)} of sleep.";
      // Trend: compare the two most recent finished-or-current weeks.
      if (started.length >= 2) {
        final last = started[started.length - 1].total;
        final prev = started[started.length - 2].total;
        if (last > prev) {
          message += " You're sleeping more than the week before. 👍";
        } else if (last < prev) {
          message += " So far you're sleeping less than the week before.";
        }
      }
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
                  gradient: const LinearGradient(
                    colors: [_cyan, _violet],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _cyan.withValues(alpha: .35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.stacked_bar_chart_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Week by week", style: _display(17)),
                    const SizedBox(height: 2),
                    Text(
                      "Total sleep in each week of the month",
                      style: TextStyle(color: _white(.5), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (int i = 0; i < weeks.length; i++)
            _weekRow(
              index: i,
              week: weeks[i],
              previous: i == 0 ? null : weeks[i - 1],
              monthAbbr: monthAbbr,
              fraction: maxTotal == 0 ? 0.0 : weeks[i].total / maxTotal,
              isBest: i == bestIndex,
            ),
          const SizedBox(height: 6),
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
                Icon(Icons.insights_rounded, color: _cyan, size: 16),
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

  Widget _weekRow({
    required int index,
    required ({int firstDay, int lastDay, int total, bool started}) week,
    required ({int firstDay, int lastDay, int total, bool started})? previous,
    required String monthAbbr,
    required double fraction,
    required bool isBest,
  }) {
    // Change vs the previous week (only when both have started).
    Widget? change;
    if (week.started && previous != null && previous.started) {
      final diff = week.total - previous.total;
      if (diff.abs() >= 60) {
        final up = diff > 0;
        change = Icon(
          up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          size: 12,
          color: up ? _green : _rose,
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: week.started ? 1 : .4,
        child: Row(
          children: [
            SizedBox(
              width: 66,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Week ${index + 1}",
                    style: TextStyle(
                      color: isBest ? _green : Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    week.firstDay == week.lastDay
                        ? "$monthAbbr ${week.firstDay}"
                        : "$monthAbbr ${week.firstDay}–${week.lastDay}",
                    style: TextStyle(color: _white(.45), fontSize: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 12,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: _white(.06))),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: fraction),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) => FractionallySizedBox(
                          widthFactor: v,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              gradient: isBest
                                  ? _goalGradient
                                  : const LinearGradient(
                                      colors: [_violet, _cyan],
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 72,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (change != null) change,
                  if (change != null) const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      week.started ? formatDuration(week.total) : "Upcoming",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: _display(
                        13,
                        weight: FontWeight.w700,
                        color: week.started && week.total > 0
                            ? Colors.white
                            : _white(.45),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===================================================================
  // BEDTIME CONSISTENCY (month)
  // ===================================================================
  /// Circular mean of bedtimes (so 11:30 PM and 12:30 AM average to
  /// midnight) and the average deviation from it, in minutes.
  ({int mean, int spread, int days})? _bedtimeStats() =>
      _timeStats(dailyBedtime);

  /// Circular mean + average deviation for any list of clock times.
  ({int mean, int spread, int days})? _timeStats(List<DateTime?> times) {
    final mins = [
      for (final b in times)
        if (b != null) b.hour * 60 + b.minute,
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

  Widget _insightCard({
    required IconData icon,
    required Gradient gradient,
    required String title,
    required String subtitle,
    Widget? badge,
    required List<Widget> children,
  }) {
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
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: gradient.colors.first.withValues(alpha: .4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 18),
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
              if (badge != null) badge,
            ],
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _tipBox(String text, {IconData icon = Icons.lightbulb_rounded}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _white(.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _amber, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: _white(.75), fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bedtimeCard() {
    final stats = _bedtimeStats();

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

    final around = stats == null ? null : ((stats.mean / 5).round() * 5) % 1440;

    String message;
    if (stats == null) {
      message = "No sleep logged this month, so there's no bedtime yet.";
    } else if (stats.days < 2) {
      message =
          "Log sleep on at least 2 days to see how consistent your bedtime is.";
    } else if (stats.spread <= 60) {
      message =
          "Across ${stats.days} days your bedtime varied by only about "
          "${_spreadText(stats.spread)}. A steady schedule keeps your body "
          "clock in sync. Great habit!";
    } else {
      message =
          "Across ${stats.days} days your bedtime varied by about "
          "${_spreadText(stats.spread)}. Try to fall asleep within the same "
          "30-minute window each day; regular sleep times improve quality.";
    }

    return _insightCard(
      icon: Icons.bedtime_rounded,
      gradient: const LinearGradient(
        colors: [_violet, _magenta],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      title: "Bedtime consistency",
      subtitle: "When your main sleep started this month",
      badge: Container(
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
      children: [
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
                shaderCallback: (r) => const LinearGradient(
                  colors: [_violet, _magenta],
                ).createShader(r),
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
        _MonthBedtimeTrack(
          bedtimes: dailyBedtime,
          meanMinutes: stats?.mean,
          spreadMinutes: (stats?.days ?? 0) >= 2 ? stats!.spread : null,
        ),
        const SizedBox(height: 14),
        _tipBox(message),
      ],
    );
  }

  // ===================================================================
  // COMFORT INSIGHTS (month)
  // ===================================================================
  num? _num(dynamic v) => v is num ? v : null;

  num? _vibrationOf(Map<String, dynamic> s) =>
      _num(s["final_vibration_level"]) ?? _num(s["vibration_level"]);

  num? _heatOf(Map<String, dynamic> s) =>
      _num(s["final_heat_level"]) ?? _num(s["heat_level"]);

  int _sleepOf(Map<String, dynamic> s) =>
      (_num(s["actual_sleep_duration_seconds"]) ?? 0).toInt();

  Widget _comfortCard() {
    final sessions = monthSessions;

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
    // vibration (rounded to 10%); the group with the longest average sleep
    // wins. Groups need 2+ sessions when possible, so one lucky night
    // doesn't decide it.
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
      final hasRepeated = groups.values.any((g) => g.length >= 2);
      String? bestKey;
      double bestAvg = -1;
      groups.forEach((key, sleeps) {
        if (hasRepeated && sleeps.length < 2) return;
        final avg = sleeps.reduce((a, b) => a + b) / sleeps.length;
        if (avg > bestAvg) {
          bestAvg = avg;
          bestKey = key;
        }
      });
      final (heat, vib) = groupSettings[bestKey]!;
      final n = groups[bestKey]!.length;
      final total = groups.values.fold<int>(0, (a, b) => a + b.length);
      insight = total >= 2
          ? "This month your longest sleeps happened with heat at $heat and "
                "vibration around $vib% (avg ${formatDuration(bestAvg.round())} "
                "over $n ${n == 1 ? 'session' : 'sessions'})."
          : "Your sleep this month followed heat at $heat and vibration around "
                "$vib%. Log more sessions to find your best settings.";
    }

    return _insightCard(
      icon: Icons.tune_rounded,
      gradient: const LinearGradient(
        colors: [_amber, Color(0xFFFF7E5F)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      title: "Comfort insights",
      subtitle: sessions.isEmpty
          ? "Settings used in your sessions"
          : "From ${sessions.length} "
                "${sessions.length == 1 ? 'session' : 'sessions'} this month",
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            _comfortTile(
              icon: Icons.waves_rounded,
              label: "Avg vibration",
              value: avgVib == null ? "-" : "$avgVib%",
              level: avgVib == null ? null : avgVib / 100,
              color: _cyan,
            ),
            const SizedBox(width: 8),
            _comfortTile(
              icon: Icons.local_fire_department_rounded,
              label: "Most-used heat",
              value: topHeat == null ? "-" : "$topHeat",
              level: topHeat == null ? null : topHeat / 100,
              color: _amber,
            ),
            const SizedBox(width: 8),
            _comfortTile(
              icon: Icons.device_thermostat_rounded,
              label: "Avg pillow",
              value: avgTemp == null ? "-" : "${avgTemp.toStringAsFixed(1)}°C",
              color: _magenta,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _tipBox(
          insight ??
              (sessions.isEmpty
                  ? "No sessions this month. Start a session to see which settings help you sleep best."
                  : "Press Wake after your sessions so we can learn which settings give you the longest sleep."),
          icon: insight == null
              ? Icons.info_outline_rounded
              : Icons.auto_awesome_rounded,
        ),
      ],
    );
  }

  Widget _comfortTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
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
            Icon(icon, color: color, size: 16),
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
                        child: ColoredBox(color: color),
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

  Widget _comparisonBadge() {
    final prevMonth = DateTime(currentMonth.year, currentMonth.month - 1, 1);
    final name = DateFormat("MMMM").format(prevMonth);
    final reference = _isCurrentMonth ? "this point in $name" : name;
    final diff = totalSleep - lastMonthSleep;

    late final IconData icon;
    late final Color color;
    late final String text;

    if (totalSleep == 0 && lastMonthSleep == 0) {
      icon = Icons.remove_rounded;
      color = _white(.5);
      text = "No sleep logged this month or in $name";
    } else if (lastMonthSleep == 0) {
      icon = Icons.auto_awesome_rounded;
      color = _cyan;
      text = "No sleep logged by $reference to compare";
    } else if (diff.abs() < 60) {
      icon = Icons.drag_handle_rounded;
      color = _white(.7);
      text = "About the same as $reference";
    } else {
      final up = diff > 0;
      final pct = (diff.abs() / lastMonthSleep * 100).round();
      icon = up ? Icons.trending_up_rounded : Icons.trending_down_rounded;
      color = up ? _green : _rose;
      text =
          "${formatDuration(diff.abs())} ${up ? 'more' : 'less'} than $reference"
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

  Widget _goalRow() {
    final met = dailySleep.where(_metGoal).length;
    final total = _daysSoFar;
    final fraction = total == 0 ? 0.0 : met / total;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
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
              Expanded(
                child: Text(
                  "Goal ${_goalLabel(goalSeconds)} / day",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                "$met/$total days met",
                style: _display(14, weight: FontWeight.w700, color: _green),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 7,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: _white(.08))),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: fraction),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => FractionallySizedBox(
                      widthFactor: v,
                      heightFactor: 1,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(gradient: _goalGradient),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              total == 0
                  ? "Change your goal on the Weekly page"
                  : "${(fraction * 100).round()}% of days so far · change it on the Weekly page",
              style: TextStyle(color: _white(.4), fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget summaryCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _white(.07),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: _display(15, weight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _white(.5), fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // HEAT-MAP CALENDAR
  // ===================================================================
  Color _heat(int minutes, int maxMinutes) {
    if (minutes <= 0 || maxMinutes <= 0) return _white(.04);
    final t = (minutes / maxMinutes).clamp(0.0, 1.0);
    return Color.lerp(
      _violet.withValues(alpha: .30),
      _cyan.withValues(alpha: .75),
      t,
    )!;
  }

  // ---------- Sleep calendar: Amount / Goal views ----------
  Color _goalColor(int seconds) {
    if (seconds <= 0) return _white(.05);
    return _metGoal(seconds)
        ? _green.withValues(alpha: .75)
        : _amber.withValues(alpha: .55);
  }

  Widget _calendarToggle() {
    Widget seg(String label, bool goal) {
      final on = _goalView == goal;
      return GestureDetector(
        onTap: () {
          if (on) return;
          HapticFeedback.selectionClick();
          setState(() => _goalView = goal);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: on ? _violet : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: on ? Colors.white : _white(.55),
              fontSize: 11.5,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _white(.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _white(.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg("Amount", false), seg("Goal", true)],
      ),
    );
  }

  Widget _amountLegend() {
    return Row(
      children: [
        Text(
          "Tap a day for details",
          style: TextStyle(color: _white(.4), fontSize: 10.5),
        ),
        const Spacer(),
        Text("Less", style: TextStyle(color: _white(.4), fontSize: 10.5)),
        const SizedBox(width: 5),
        for (final t in const [0.0, .33, .66, 1.0]) ...[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: t == 0
                  ? _white(.06)
                  : Color.lerp(
                      _violet.withValues(alpha: .30),
                      _cyan.withValues(alpha: .75),
                      t,
                    ),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 3),
        ],
        const SizedBox(width: 2),
        Text("More", style: TextStyle(color: _white(.4), fontSize: 10.5)),
      ],
    );
  }

  Widget _goalLegend() {
    final today = DateUtils.dateOnly(DateTime.now());
    int met = 0, below = 0, none = 0;
    for (int i = 0; i < dailySleep.length; i++) {
      final date = DateTime(currentMonth.year, currentMonth.month, i + 1);
      if (date.isAfter(today)) continue;
      final s = dailySleep[i];
      if (s <= 0) {
        none++;
      } else if (_metGoal(s)) {
        met++;
      } else {
        below++;
      }
    }
    final logged = met + below;
    final rate = logged == 0 ? 0 : (met / logged * 100).round();

    Widget item(Color c, String label, int n) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text("$label $n", style: TextStyle(color: _white(.65), fontSize: 11)),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            item(_green.withValues(alpha: .75), "Met", met),
            item(_amber.withValues(alpha: .55), "Below", below),
            item(_white(.1), "No sleep", none),
          ],
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: logged == 0 ? "—" : "$rate%",
                style: _display(
                  15,
                  weight: FontWeight.w700,
                  color: logged == 0
                      ? _white(.5)
                      : rate >= 70
                      ? _green
                      : rate >= 40
                      ? _amber
                      : _rose,
                ),
              ),
              TextSpan(
                text: logged == 0
                    ? "  no logged days yet"
                    : "  of logged days met your ${_goalLabel(goalSeconds)} goal",
                style: TextStyle(color: _white(.55), fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _heatmapCard() {
    final first = DateTime(currentMonth.year, currentMonth.month, 1);
    final leading = first.weekday % 7; // Sunday-first
    final days = dailySleep.length;
    final maxMinutes = dailySleep.isEmpty ? 0 : dailySleep.reduce(math.max);
    final today = DateUtils.dateOnly(DateTime.now());

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: _glass(radius: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  _goalView ? "Goal calendar" : "Sleep calendar",
                  style: _display(17),
                ),
                const Spacer(),
                _calendarToggle(),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _goalView ? _goalLegend() : _amountLegend(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final d in const ["S", "M", "T", "W", "T", "F", "S"])
                Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: TextStyle(
                        color: _white(.4),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: leading + days,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 5,
              crossAxisSpacing: 5,
            ),
            itemBuilder: (context, index) {
              if (index < leading) return const SizedBox.shrink();
              final day = index - leading + 1;
              final minutes = dailySleep[day - 1];
              final date = DateTime(currentMonth.year, currentMonth.month, day);
              final isToday = date == today;
              final isFuture = date.isAfter(today);
              final isFocused = _focusedDay == day;

              return GestureDetector(
                onTap: isFuture
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        setState(() => _focusedDay = isFocused ? null : day);
                      },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: isFuture
                        ? Colors.transparent
                        : _goalView
                        ? _goalColor(minutes)
                        : _heat(minutes, maxMinutes),
                    borderRadius: BorderRadius.circular(10),
                    border: isFocused
                        ? Border.all(color: Colors.white, width: 1.5)
                        : isToday
                        ? Border.all(color: _cyan, width: 1.2)
                        : !_goalView && _metGoal(minutes)
                        ? Border.all(color: _green, width: 1.4)
                        : null,
                    boxShadow: isFocused
                        ? [
                            BoxShadow(
                              color: _cyan.withValues(alpha: .4),
                              blurRadius: 10,
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Text(
                        "$day",
                        style: GoogleFonts.outfit(
                          fontSize: 12.5,
                          fontWeight: minutes > 0
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isFuture
                              ? _white(.18)
                              : minutes > 0
                              ? Colors.white
                              : _white(.55),
                        ),
                      ),
                      if (!_goalView && _metGoal(minutes))
                        Positioned(
                          top: -4,
                          right: -4,
                          child: Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: _goalGradient,
                              border: Border.all(color: _bg, width: 1.5),
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 8,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _focusedDay == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _dayDetail(_focusedDay!),
                  ),
          ),
        ],
      ),
    );
  }

  /// Go back to the History screen showing [day].
  void _openDay(DateTime day) {
    if (DateUtils.dateOnly(day).isAfter(DateUtils.dateOnly(DateTime.now()))) {
      return;
    }
    HapticFeedback.selectionClick();
    Navigator.pop(context, DateUtils.dateOnly(day));
  }

  Widget _dayDetail(int day) {
    final date = DateTime(currentMonth.year, currentMonth.month, day);
    final minutes = dailySleep[day - 1];
    final count = dailyCount[day - 1];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _white(.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_today_rounded, color: _cyan, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              DateFormat("EEEE, MMM d").format(date),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            count == 0
                ? "No sleep"
                : "${formatDuration(minutes)} · $count "
                      "${count == 1 ? 'session' : 'sessions'}",
            style: TextStyle(color: _white(.7), fontSize: 12.5),
          ),
          if (_metGoal(minutes)) ...[
            const SizedBox(width: 8),
            const Icon(Icons.flag_rounded, color: _green, size: 15),
          ],
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => _openDay(date),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                gradient: _mainGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "View",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white,
                    size: 15,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // TREND CHART
  // ===================================================================
  Widget buildBarChart() {
    if (dailySleep.isEmpty) {
      return const SizedBox();
    }

    // Seconds; include the goal so its line always fits on the chart.
    final maxMin = math.max(dailySleep.reduce(math.max), goalSeconds);
    final useHours = maxMin >= 3600;
    final divisor = useHours ? 3600.0 : 60.0;
    final unit = useHours ? "h" : "m";

    final rawMax = maxMin / divisor;
    final interval = _niceInterval(rawMax == 0 ? 4 : rawMax * 1.2 / 4);
    final maxY = rawMax == 0
        ? interval * 4
        : (rawMax * 1.2 / interval).ceilToDouble() * interval;

    final loggedDays = dailySleep.where((m) => m > 0).length;
    final avgY = loggedDays == 0 ? 0.0 : (totalSleep / loggedDays) / divisor;

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 16, 14, 10),
      decoration: _glass(radius: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                Text("Daily trend", style: _display(17)),
                const Spacer(),
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
            height: 200,
            child: Stack(
              children: [
                BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceBetween,
                    maxY: maxY,
                    minY: 0,
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(
                      enabled: true,
                      // Tap a bar to select that day (shows its details
                      // with a "View" button in the calendar card).
                      touchCallback: (event, response) {
                        if (event is! FlTapUpEvent) return;
                        final index = response?.spot?.touchedBarGroupIndex;
                        if (index == null) return;
                        final date = DateTime(
                          currentMonth.year,
                          currentMonth.month,
                          index + 1,
                        );
                        if (date.isAfter(DateUtils.dateOnly(DateTime.now()))) {
                          return;
                        }
                        HapticFeedback.selectionClick();
                        // Show the day's details (with "View") on Overview.
                        setState(() {
                          _focusedDay = index + 1;
                          _tab = 0;
                        });
                      },
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => _surface,
                        tooltipRoundedRadius: 10,
                        tooltipPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final day = group.x + 1;
                          final date = DateTime(
                            currentMonth.year,
                            currentMonth.month,
                            day,
                          );
                          return BarTooltipItem(
                            "${DateFormat("MMM d").format(date)}\n",
                            TextStyle(color: _white(.6), fontSize: 11),
                            children: [
                              TextSpan(
                                text: formatDuration(dailySleep[group.x]),
                                style: _display(14, weight: FontWeight.w700),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
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
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
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
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 24,
                          interval: 1,
                          getTitlesWidget: (value, meta) {
                            final day = value.toInt() + 1;
                            if (day != 1 && day % 5 != 0) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                "$day",
                                style: TextStyle(
                                  color: _white(.45),
                                  fontSize: 10,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    barGroups: List.generate(dailySleep.length, (i) {
                      final isFocused = _focusedDay == i + 1;
                      return BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: dailySleep[i] / divisor,
                            width: 6,
                            borderRadius: BorderRadius.circular(3),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: _metGoal(dailySleep[i])
                                  ? [
                                      const Color(0xFF10B981).withValues(
                                        alpha: isFocused || _focusedDay == null
                                            ? 1
                                            : .4,
                                      ),
                                      _green.withValues(
                                        alpha: isFocused || _focusedDay == null
                                            ? 1
                                            : .4,
                                      ),
                                    ]
                                  : isFocused || _focusedDay == null
                                  ? const [_violet, _cyan]
                                  : [
                                      _violet.withValues(alpha: .4),
                                      _cyan.withValues(alpha: .4),
                                    ],
                            ),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: maxY,
                              color: _white(isFocused ? .1 : .03),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
                if (totalSessions == 0)
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
                        "No sleep logged this month",
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
  // RECORDS
  // ===================================================================
  Widget _countPill(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: _white(.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _white(.08)),
      ),
      child: Text(
        "$count",
        style: TextStyle(
          color: _white(.8),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _emptyRecords() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      decoration: _glass(radius: 24),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: _mainGradient,
              boxShadow: [
                BoxShadow(
                  color: _violet.withValues(alpha: .45),
                  blurRadius: 22,
                ),
              ],
            ),
            child: const Icon(
              Icons.bedtime_outlined,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(height: 14),
          Text("No sleep records", style: _display(16)),
          const SizedBox(height: 4),
          Text(
            "Sleep you log this month will show up here.",
            textAlign: TextAlign.center,
            style: TextStyle(color: _white(.5), fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget buildSleepRecord(Map<String, dynamic> record) {
    Timestamp? start = record["start"] is Timestamp ? record["start"] : null;
    Timestamp? end = record["end"] is Timestamp ? record["end"] : null;
    final DateTime date = record["date"];
    final int duration = record["duration"];
    final fraction = bestSleep == 0 ? 0.0 : duration / bestSleep;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDay(date),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: _glass(radius: 20),
        child: Row(
          children: [
            // Date badge
            Container(
              width: 48,
              height: 52,
              decoration: BoxDecoration(
                gradient: _mainGradient,
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: _violet.withValues(alpha: .35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    DateFormat("EEE").format(date).toUpperCase(),
                    style: TextStyle(
                      color: _white(.85),
                      fontSize: 9,
                      letterSpacing: .8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    "${date.day}",
                    style: _display(19, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          DateFormat("MMMM d, yyyy").format(date),
                          style: TextStyle(color: _white(.6), fontSize: 12),
                        ),
                      ),
                      ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (r) => _mainGradient.createShader(r),
                        child: Text(
                          formatDuration(duration),
                          style: _display(18, weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.bedtime_rounded, color: _white(.5), size: 14),
                      const SizedBox(width: 5),
                      Text(
                        formatTime(start),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: _white(.3),
                          size: 13,
                        ),
                      ),
                      Icon(Icons.wb_sunny_rounded, color: _white(.5), size: 14),
                      const SizedBox(width: 5),
                      Text(
                        formatTime(end),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 4,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(color: _white(.07)),
                          ),
                          FractionallySizedBox(
                            widthFactor: fraction.clamp(0.0, 1.0),
                            heightFactor: 1,
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: _mainGradient,
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
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: _white(.35), size: 18),
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

/// 24-hour track from noon to noon with a dot for every day's bedtime this
/// month, the average line and a ±spread band.
class _MonthBedtimeTrack extends StatelessWidget {
  final List<DateTime?> bedtimes;
  final int? meanMinutes;
  final int? spreadMinutes;

  /// Minute of the day where the axis starts (noon by default).
  final int axisStart;
  final List<String> labels;
  final String highlightLabel;
  final Color color;

  const _MonthBedtimeTrack({
    required this.bedtimes,
    required this.meanMinutes,
    required this.spreadMinutes,
    this.axisStart = 720,
    this.labels = const ["12 PM", "6 PM", "12 AM", "6 AM", "12 PM"],
    this.highlightLabel = "12 AM",
    this.color = _magenta,
  });

  double _pos(int minutesOfDay) => ((minutesOfDay - axisStart) % 1440) / 1440;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        const dot = 12.0;

        return Column(
          children: [
            SizedBox(
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 17,
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
                  if (meanMinutes != null && spreadMinutes != null)
                    Positioned(
                      left:
                          w *
                          (_pos(meanMinutes!) - spreadMinutes! / 1440).clamp(
                            0.0,
                            1.0,
                          ),
                      width: math.max(
                        w *
                            ((_pos(meanMinutes!) + spreadMinutes! / 1440).clamp(
                                  0.0,
                                  1.0,
                                ) -
                                (_pos(meanMinutes!) - spreadMinutes! / 1440)
                                    .clamp(0.0, 1.0)),
                        4,
                      ),
                      top: 8,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: color.withValues(alpha: .35),
                          ),
                        ),
                      ),
                    ),
                  for (final b in bedtimes)
                    if (b != null)
                      Positioned(
                        left: (w * _pos(b.hour * 60 + b.minute) - dot / 2)
                            .clamp(-dot / 2, w - dot / 2),
                        top: 14,
                        child: Container(
                          width: dot,
                          height: dot,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color.withValues(alpha: .75),
                            border: Border.all(color: _bg, width: 1.5),
                          ),
                        ),
                      ),
                  if (meanMinutes != null)
                    Positioned(
                      left: w * _pos(meanMinutes!) - 1,
                      top: 2,
                      height: 36,
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
                ],
              ),
            ),
            const SizedBox(height: 6),
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
      },
    );
  }
}

/// Pinned header for the month switcher + tabs. Gets a frosted background
/// once content scrolls underneath it.
class _PinnedBar extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double extent;

  _PinnedBar({required this.child, required this.extent});

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final covered = overlapsContent || shrinkOffset > 0;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: covered ? 18 : 0,
          sigmaY: covered ? 18 : 0,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: _bg.withValues(alpha: covered ? .72 : 0),
            border: Border(
              bottom: BorderSide(
                color: covered ? _white(.08) : Colors.transparent,
              ),
            ),
          ),
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedBar oldDelegate) => true;
}

/// Running sleep-debt line (above the zero line = short of goal).
class _DebtLinePainter extends CustomPainter {
  final List<double> points;
  final Color color;
  _DebtLinePainter({required this.points, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final maxV = points.fold<double>(0, (a, b) => math.max(a, b));
    final minV = points.fold<double>(0, (a, b) => math.min(a, b));
    final range = (maxV - minV).abs() < 1 ? 1.0 : maxV - minV;

    double y(double v) => size.height - (v - minV) / range * size.height;
    double x(int i) => size.width * i / (points.length - 1);

    // Zero line (= exactly on goal)
    final zeroY = y(0);
    final dash = Paint()
      ..color = Colors.white.withValues(alpha: .2)
      ..strokeWidth = 1;
    for (double dx = 0; dx < size.width; dx += 8) {
      canvas.drawLine(Offset(dx, zeroY), Offset(dx + 4, zeroY), dash);
    }

    final path = Path()..moveTo(x(0), y(points[0]));
    for (int i = 1; i < points.length; i++) {
      path.lineTo(x(i), y(points[i]));
    }
    final fill = Path.from(path)
      ..lineTo(x(points.length - 1), zeroY)
      ..lineTo(x(0), zeroY)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: .12));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final last = Offset(x(points.length - 1), y(points.last));
    canvas.drawCircle(last, 4.5, Paint()..color = color);
    canvas.drawCircle(last, 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_DebtLinePainter old) =>
      old.points != points || old.color != color;
}

/// Floating bars: one per day from bedtime to wake-up.
/// Vertical axis runs 6 PM (top) → 6 PM next day (bottom).
class _SleepWindowPainter extends CustomPainter {
  final List<DateTime?> bedtimes;
  final List<DateTime?> wakes;
  final List<int> sleep;
  final int goalSeconds;
  final int? selected;

  _SleepWindowPainter({
    required this.bedtimes,
    required this.wakes,
    required this.sleep,
    required this.goalSeconds,
    required this.selected,
  });

  static const int _axisStart = 18 * 60;

  double _pos(DateTime t) =>
      (((t.hour * 60 + t.minute) - _axisStart) % 1440) / 1440;

  @override
  void paint(Canvas canvas, Size size) {
    final days = bedtimes.length;
    if (days == 0) return;
    final colW = size.width / days;

    // Grid lines every 6 hours; midnight brighter.
    for (int k = 0; k <= 4; k++) {
      final gy = size.height * k / 4;
      canvas.drawLine(
        Offset(0, gy),
        Offset(size.width, gy),
        Paint()
          ..color = Colors.white.withValues(alpha: k == 1 ? .16 : .06)
          ..strokeWidth = 1,
      );
    }

    for (int i = 0; i < days; i++) {
      final b = bedtimes[i];
      if (b == null) continue;
      final w = wakes[i] ?? b.add(Duration(seconds: sleep[i]));
      final top = _pos(b) * size.height;
      // Length from the actual duration so bars never wrap around.
      final mins = math.max(w.difference(b).inMinutes, 10);
      final h = math.min(mins / 1440 * size.height, size.height - top);
      final met = sleep[i] >= goalSeconds && goalSeconds > 0;
      final isSel = selected == i + 1;
      final barW = math.max(colW * .62, 3.0);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(colW * i + (colW - barW) / 2, top, barW, math.max(h, 3)),
        Radius.circular(barW / 2),
      );
      final c = met ? const Color(0xFF34D399) : const Color(0xFF6B5BFF);
      canvas.drawRRect(
        rect,
        Paint()
          ..color = selected == null || isSel ? c : c.withValues(alpha: .35),
      );
      if (isSel) {
        canvas.drawRRect(
          rect.inflate(2),
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SleepWindowPainter old) => true;
}
