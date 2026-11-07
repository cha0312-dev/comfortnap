import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'weekly_sleep_screen.dart';
import 'monthly_sleep_screen.dart';
import 'package:table_calendar/table_calendar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SleepSessionScreen(),
    ),
  );
}

// =====================================================================
// DESIGN TOKENS
// =====================================================================
const Color _bg = Color(0xFF07031F);
const Color _surface = Color(0xFF151040);
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);
const Color _amber = Color(0xFFFFB547);
const Color _pink = Color(0xFFFF6FA5);
const Color _danger = Color(0xFFFF4D67);

/// Daily sleep goal used by the progress ring. Change to suit your app.
const int _dailySleepGoalSeconds = 8 * 3600;

const LinearGradient _sleepGradient = LinearGradient(
  colors: [_violet, _cyan],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient _timerGradient = LinearGradient(
  colors: [_amber, _pink],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

Color _white(double alpha) => Colors.white.withValues(alpha: alpha);

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

BoxDecoration _glass({double radius = 24, double strength = 1}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_white(.085 * strength), _white(.025 * strength)],
      ),
      border: Border.all(color: _white(.09)),
    );

String _formatDuration(int totalSeconds) {
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  if (h > 0) return "${h}h ${m.toString().padLeft(2, '0')}m";
  if (m > 0) return "${m}m ${s.toString().padLeft(2, '0')}s";
  return "${s}s";
}

String _formatTime(DateTime? t) =>
    t == null ? "-" : DateFormat('h:mm a').format(t);

class _Stat {
  final IconData icon;
  final String label;
  final String value;

  /// 0..1 — when set, a small level bar is drawn under the value.
  final double? level;
  const _Stat(this.icon, this.label, this.value, {this.level});
}

class _Segment {
  final double start;
  final double end;
  final bool isTimer;
  const _Segment(this.start, this.end, this.isTimer);
}

// =====================================================================
// SCREEN
// =====================================================================
class SleepSessionScreen extends StatefulWidget {
  const SleepSessionScreen({super.key});

  @override
  State<SleepSessionScreen> createState() => _SleepSessionScreenState();
}

class _SleepSessionScreenState extends State<SleepSessionScreen>
    with SingleTickerProviderStateMixin {
  int selectedDayIndex = DateTime.now().weekday % 7;
  DateTime selectedDate = DateTime.now();

  /// +1 when moving forward in time, -1 when moving back (drives slide anim).
  int _direction = 1;

  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  )..repeat();

  // ✅ ADDED ONLY
  final Map<String, Map<String, dynamic>> _deletedCache = {};

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  bool isSameSelectedDay(Timestamp ts) {
    final date = ts.toDate();
    return date.year == selectedDate.year &&
        date.month == selectedDate.month &&
        date.day == selectedDate.day;
  }

  // ✅ ADDED ONLY (DELETE + UNDO LOGIC)
  Future<void> deleteWithUndo(String docId, Map<String, dynamic> data) async {
    _deletedCache[docId] = data;
    HapticFeedback.mediumImpact();

    await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .doc(docId)
        .delete();

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.white, size: 20),
            SizedBox(width: 10),
            Text("Session deleted", style: TextStyle(color: Colors.white)),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: _surface,
        elevation: 0,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _white(.1)),
        ),
        duration: const Duration(seconds: 3), // ⬅️ auto close after 3 sec
        action: SnackBarAction(
          label: "UNDO",
          textColor: _cyan,
          onPressed: () async {
            final restored = _deletedCache[docId];

            if (restored != null) {
              await FirebaseFirestore.instance
                  .collection("vibrator_logs")
                  .doc(docId)
                  .set(restored);

              _deletedCache.remove(docId);
            }
          },
        ),
      ),
    );

    // ⬅️ after 3 seconds, remove undo data (prevents restore after timeout)
    Future.delayed(const Duration(seconds: 3), () {
      _deletedCache.remove(docId);
    });
  }

  int _sessionSeconds(Map<String, dynamic> data) {
    // Sessions where the user woke before the session ended have 0 sleep.
    if (data["actual_sleep_duration_seconds"] is num) {
      final actual = (data["actual_sleep_duration_seconds"] as num).toInt();
      return actual < 0 ? 0 : actual;
    }
    final actualSeconds = (data["duration"] as num?)?.toInt() ?? 0;
    return actualSeconds <= 0 ? 1 : actualSeconds;
  }

  void _goToDate(DateTime date) {
    final target = DateUtils.dateOnly(date);
    final current = DateUtils.dateOnly(selectedDate);
    if (target == current) return;
    HapticFeedback.selectionClick();
    setState(() {
      _direction = target.isAfter(current) ? 1 : -1;
      selectedDate = target;
      selectedDayIndex = target.weekday % 7;
    });
  }

  void _shiftDays(int days) {
    final d = DateUtils.dateOnly(selectedDate);
    _goToDate(DateTime(d.year, d.month, d.day + days));
  }

  void _openCalendar() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (_) =>
          CalendarOverlay(initialDate: selectedDate, onDateSelected: _goToDate),
    );
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
          Positioned.fill(child: _AuroraBackground(animation: _ambient)),
          SafeArea(
            bottom: false,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection("vibrator_logs")
                  .orderBy("timestamp", descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return _loadingSkeleton();
                return _content(snapshot.data!.docs);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(List<QueryDocumentSnapshot> docs) {
    // Days that have any record — shown as dots in the week strip.
    final recordDays = <DateTime>{};
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final ts = data["timestamp"];
      final type = data["type"];
      if (ts is Timestamp && (type == "session" || type == "timer")) {
        recordDays.add(DateUtils.dateOnly(ts.toDate()));
      }
    }

    final sessionLogs = docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      if (data["type"] != "session") return false;
      if (data["timestamp"] == null) return false;
      return isSameSelectedDay(data["timestamp"]);
    }).toList();

    final timerLogs = docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      if (data["type"] != "timer") return false;
      if (data["timestamp"] == null) return false;
      return isSameSelectedDay(data["timestamp"]);
    }).toList();

    int totalSleepSeconds = 0;
    final pillowTemps = <double>[];
    for (final doc in sessionLogs) {
      final data = doc.data() as Map<String, dynamic>;
      totalSleepSeconds += _sessionSeconds(data);
      final t = data["final_pillow_temperature"];
      if (t is num) pillowTemps.add(t.toDouble());
    }
    final avgPillow = pillowTemps.isEmpty
        ? null
        : pillowTemps.reduce((a, b) => a + b) / pillowTemps.length;

    final dayKey = DateUtils.dateOnly(selectedDate);
    final isToday = DateUtils.isSameDay(selectedDate, DateTime.now());

    int i = 0;
    final dayContent = Column(
      key: ValueKey<DateTime>(dayKey),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FadeSlideIn(
          index: i++,
          child: _heroCard(
            sleepSeconds: totalSleepSeconds,
            sessions: sessionLogs.length,
            timers: timerLogs.length,
            avgPillow: avgPillow,
            segments: _segmentsFor(sessionLogs, timerLogs),
            isToday: isToday,
          ),
        ),
        const SizedBox(height: 30),
        _FadeSlideIn(
          index: i++,
          child: _sectionHeader("Sleep sessions", sessionLogs.length),
        ),
        const SizedBox(height: 14),
        if (sessionLogs.isEmpty)
          _FadeSlideIn(
            index: i++,
            child: _emptyState(
              Icons.bedtime_outlined,
              "No sleep sessions",
              "Sessions recorded on this day will appear here.",
              _sleepGradient,
            ),
          )
        else
          for (final doc in sessionLogs)
            _FadeSlideIn(index: i++, child: buildSessionCard(doc)),
        const SizedBox(height: 22),
        _FadeSlideIn(
          index: i++,
          child: _sectionHeader("Timer logs", timerLogs.length),
        ),
        const SizedBox(height: 14),
        if (timerLogs.isEmpty)
          _FadeSlideIn(
            index: i++,
            child: _emptyState(
              Icons.timer_outlined,
              "No timers",
              "Timers you run on this day will appear here.",
              _timerGradient,
            ),
          )
        else
          for (final doc in timerLogs)
            _FadeSlideIn(index: i++, child: buildTimerCard(doc)),
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Swipe left/right anywhere to move between days.
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -350) _shiftDays(1);
        if (v > 350) _shiftDays(-1);
      },
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 48),
        children: [
          _topBar(),
          const SizedBox(height: 26),
          _dateHeader(isToday),
          const SizedBox(height: 22),
          _weekStrip(recordDays),
          const SizedBox(height: 22),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, if (current != null) current],
            ),
            transitionBuilder: (child, anim) {
              final incoming = child.key == ValueKey<DateTime>(dayKey);
              final dx = (incoming ? 1 : -1) * _direction * 0.12;
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(dx, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              );
            },
            child: dayContent,
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // TOP BAR
  // ===================================================================
  Widget _topBar() {
    return Row(
      children: [
        _glassIconButton(
          Icons.arrow_back_ios_new_rounded,
          tooltip: "Back",
          onTap: () => Navigator.pop(context),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: _glass(radius: 18),
          child: Row(
            children: [
              _barButton(Icons.view_week_rounded, "Weekly view", () async {
                // Weekly screen returns a date when the user taps a day.
                final picked = await Navigator.push<DateTime>(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        WeeklySleepScreen(selectedDate: selectedDate),
                  ),
                );
                if (picked != null && mounted) _goToDate(picked);
              }),
              _barButton(Icons.calendar_month_rounded, "Monthly view", () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const MonthlySleepScreen(),
                  ),
                );
              }),
              _barButton(Icons.event_rounded, "Pick a date", _openCalendar),
            ],
          ),
        ),
      ],
    );
  }

  Widget _glassIconButton(
    IconData icon, {
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: _glass(radius: 16),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _barButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 42,
            height: 40,
            child: Icon(icon, color: _white(.9), size: 21),
          ),
        ),
      ),
    );
  }

  // ===================================================================
  // DATE HEADER
  // ===================================================================
  Widget _dateHeader(bool isToday) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "SLEEP JOURNAL",
                style: _eyebrow(color: _cyan.withValues(alpha: .85)),
              ),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  DateFormat('EEEE').format(selectedDate),
                  key: ValueKey(DateFormat('EEEE').format(selectedDate)),
                  style: _display(40, weight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                DateFormat('MMMM d, y').format(selectedDate),
                style: TextStyle(color: _white(.6), fontSize: 15),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: isToday
              ? _chip("Today", gradient: _sleepGradient)
              : GestureDetector(
                  onTap: () => _goToDate(DateTime.now()),
                  child: _chip("Jump to today", icon: Icons.restore_rounded),
                ),
        ),
      ],
    );
  }

  Widget _chip(String text, {Gradient? gradient, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: gradient != null
          ? BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: _violet.withValues(alpha: .45),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            )
          : _glass(radius: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // WEEK STRIP
  // ===================================================================
  Widget _weekStrip(Set<DateTime> recordDays) {
    final sel = DateUtils.dateOnly(selectedDate);
    final weekStart = DateTime(sel.year, sel.month, sel.day - sel.weekday % 7);
    final weekEnd = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day + 6,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: _glass(radius: 26),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 6),
              Text(
                "${DateFormat('MMM d').format(weekStart)} – "
                "${DateFormat('MMM d').format(weekEnd)}",
                style: TextStyle(
                  color: _white(.75),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              _smallRoundButton(
                Icons.chevron_left_rounded,
                () => _shiftDays(-7),
              ),
              const SizedBox(width: 6),
              _smallRoundButton(
                Icons.chevron_right_rounded,
                () => _shiftDays(7),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: List.generate(7, (index) {
              final day = DateTime(
                weekStart.year,
                weekStart.month,
                weekStart.day + index,
              );
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: index == 6 ? 0 : 6),
                  child: buildDay(
                    day,
                    index,
                    hasRecord: recordDays.contains(day),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _smallRoundButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: _white(.06),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, color: _white(.85), size: 20),
        ),
      ),
    );
  }

  // ================= DAY =================
  Widget buildDay(DateTime day, int index, {bool hasRecord = false}) {
    final isSelected = DateUtils.isSameDay(day, selectedDate);
    final isToday = DateUtils.isSameDay(day, DateTime.now());

    return GestureDetector(
      onTap: () => _goToDate(day),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        height: 74,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: isSelected ? _sleepGradient : null,
          color: isSelected ? null : _white(.035),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : isToday
                ? _cyan.withValues(alpha: .55)
                : _white(.06),
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _violet.withValues(alpha: .55),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : const [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FittedBox(
              child: Text(
                DateFormat('EEE').format(day).toUpperCase(),
                style: TextStyle(
                  color: isSelected ? _white(.9) : _white(.45),
                  fontSize: 10.5,
                  letterSpacing: .8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              day.day.toString(),
              style: _display(19, weight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              width: hasRecord ? (isSelected ? 14 : 5) : 5,
              height: 5,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: hasRecord
                    ? (isSelected ? Colors.white : _cyan)
                    : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===================================================================
  // HERO
  // ===================================================================
  List<_Segment> _segmentsFor(
    List<QueryDocumentSnapshot> sessions,
    List<QueryDocumentSnapshot> timers,
  ) {
    final dayStart = DateUtils.dateOnly(selectedDate);
    double frac(DateTime t) =>
        (t.difference(dayStart).inSeconds / 86400.0).clamp(0.0, 1.0);

    final out = <_Segment>[];

    void add(
      dynamic startRaw,
      dynamic endRaw,
      dynamic tsRaw,
      int secs,
      bool isTimer,
    ) {
      DateTime? start = startRaw is Timestamp ? startRaw.toDate() : null;
      DateTime? end = endRaw is Timestamp ? endRaw.toDate() : null;
      if (start == null && end == null && tsRaw is Timestamp) {
        end = tsRaw.toDate();
      }
      start ??= end?.subtract(Duration(seconds: secs));
      end ??= start?.add(Duration(seconds: secs));
      if (start == null || end == null) return;
      out.add(_Segment(frac(start), frac(end), isTimer));
    }

    for (final doc in sessions) {
      final d = doc.data() as Map<String, dynamic>;
      add(
        d["start_time"],
        d["end_time"],
        d["timestamp"],
        _sessionSeconds(d),
        false,
      );
    }
    for (final doc in timers) {
      final d = doc.data() as Map<String, dynamic>;
      add(
        d["set_time"],
        d["end_time"],
        d["timestamp"],
        (d["duration"] as num?)?.toInt() ?? 0,
        true,
      );
    }
    return out;
  }

  Widget _heroCard({
    required int sleepSeconds,
    required int sessions,
    required int timers,
    required double? avgPillow,
    required List<_Segment> segments,
    required bool isToday,
  }) {
    final progress = sessions == 0
        ? 0.0
        : sleepSeconds / _dailySleepGoalSeconds;
    final now = DateTime.now();
    final nowFrac = isToday
        ? (now.hour * 3600 + now.minute * 60 + now.second) / 86400.0
        : null;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
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
            blurRadius: 40,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 1300),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => SizedBox(
                  width: 136,
                  height: 136,
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
                                sessions == 0
                                    ? "0m"
                                    : _formatDuration(sleepSeconds),
                                style: _display(24, weight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              "of ${_dailySleepGoalSeconds ~/ 3600}h goal",
                              style: TextStyle(
                                color: _white(.55),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _heroStat(
                      Icons.bedtime_rounded,
                      "$sessions",
                      sessions == 1 ? "Session" : "Sessions",
                    ),
                    const SizedBox(height: 12),
                    _heroStat(
                      Icons.timer_rounded,
                      "$timers",
                      timers == 1 ? "Timer" : "Timers",
                    ),
                    const SizedBox(height: 12),
                    _heroStat(
                      Icons.device_thermostat_rounded,
                      avgPillow == null
                          ? "-"
                          : "${avgPillow.toStringAsFixed(1)}°C",
                      "Avg pillow",
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Text("24-HOUR TIMELINE", style: _eyebrow()),
              const Spacer(),
              _legendDot(_sleepGradient, "Sleep"),
              const SizedBox(width: 12),
              _legendDot(_timerGradient, "Timer"),
            ],
          ),
          const SizedBox(height: 12),
          _timeline(segments, nowFrac),
        ],
      ),
    );
  }

  Widget _heroStat(IconData icon, String value, String label) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _white(.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: _cyan, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: _display(17)),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _white(.5), fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Gradient gradient, String label) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 6,
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: _white(.55), fontSize: 11)),
      ],
    );
  }

  Widget _timeline(List<_Segment> segments, double? nowFrac) {
    const labels = ["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"];
    return Column(
      children: [
        SizedBox(
          height: 24,
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 5,
                    height: 14,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _white(.07),
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                  for (final f in const [.25, .5, .75])
                    Positioned(
                      left: w * f,
                      top: 5,
                      height: 14,
                      child: Container(width: 1, color: _white(.1)),
                    ),
                  for (final s in segments)
                    Positioned(
                      left: math.min(w * s.start, w - 6),
                      top: 5,
                      height: 14,
                      width: math.max(w * (s.end - s.start), 6),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: s.isTimer ? _timerGradient : _sleepGradient,
                          borderRadius: BorderRadius.circular(7),
                          boxShadow: [
                            BoxShadow(
                              color: (s.isTimer ? _amber : _cyan).withValues(
                                alpha: .55,
                              ),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (nowFrac != null)
                    Positioned(
                      left: w * nowFrac - 1,
                      top: 0,
                      height: 24,
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
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final l in labels)
              Text(l, style: TextStyle(color: _white(.4), fontSize: 10)),
          ],
        ),
      ],
    );
  }

  // ===================================================================
  // SECTION HEADER / EMPTY
  // ===================================================================
  Widget _sectionHeader(String title, int count) {
    return Row(
      children: [
        Text(title, style: _display(20)),
        const SizedBox(width: 10),
        Container(
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
        ),
        const Spacer(),
        if (count > 0)
          Row(
            children: [
              Icon(Icons.swipe_left_rounded, size: 14, color: _white(.35)),
              const SizedBox(width: 4),
              Text(
                "Swipe to delete",
                style: TextStyle(color: _white(.35), fontSize: 11),
              ),
            ],
          ),
      ],
    );
  }

  Widget _emptyState(
    IconData icon,
    String title,
    String subtitle,
    Gradient accent,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: _glass(radius: 26, strength: .7),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: accent,
              boxShadow: [
                BoxShadow(
                  color: accent.colors.first.withValues(alpha: .45),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 14),
          Text(title, style: _display(16)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: _white(.5), fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // RECORD CARD (shared by sessions & timers)
  // ===================================================================
  Widget _recordCard({
    required QueryDocumentSnapshot doc,
    required Map<String, dynamic> data,
    required IconData icon,
    required String title,
    required String durationText,
    required DateTime? startTime,
    required DateTime? endTime,
    required Gradient accent,
    List<_Stat> stats = const [],
  }) {
    final timeRange = startTime == null && endTime == null
        ? "No time recorded"
        : "${_formatTime(startTime)} – ${_formatTime(endTime)}";

    return Dismissible(
      key: Key(doc.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 14),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 26),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_danger.withValues(alpha: .3), _danger],
          ),
          borderRadius: BorderRadius.circular(26),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Delete",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 8),
            Icon(Icons.delete_outline_rounded, color: Colors.white),
          ],
        ),
      ),
      onDismissed: (_) => deleteWithUndo(doc.id, data),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: _glass(radius: 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: accent,
                    borderRadius: BorderRadius.circular(15),
                    boxShadow: [
                      BoxShadow(
                        color: accent.colors.first.withValues(alpha: .45),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: _white(.45),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              timeRange,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _white(.55),
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (rect) => accent.createShader(rect),
                  child: Text(
                    durationText,
                    style: _display(24, weight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            if (stats.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  for (int i = 0; i < stats.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: _statTile(stats[i], accent)),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statTile(_Stat stat, Gradient accent) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _white(.045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _white(.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(stat.icon, color: accent.colors.last, size: 15),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  stat.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _white(.55), fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(stat.value, style: _display(17)),
          ),
          if (stat.level != null) ...[
            const SizedBox(height: 8),
            _LevelBar(level: stat.level!, gradient: accent),
          ],
        ],
      ),
    );
  }

  double? _level(dynamic v) => v is num ? (v / 100).clamp(0.0, 1.0) : null;

  // ================= SESSION CARD =================
  Widget buildSessionCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    final start = data["start_time"];
    final end = data["end_time"];

    DateTime? startTime = start is Timestamp ? start.toDate() : null;
    DateTime? endTime = end is Timestamp ? end.toDate() : null;

    // ================= VIBRATION / HEAT LEVELS =================
    final vibrationStart = data["vibration_level"];
    final vibrationEnd = data["final_vibration_level"];
    final heatSetting = data["heat_level"];
    final pillowTemperature = data["final_pillow_temperature"];

    String vibrationText = vibrationStart == null
        ? "-"
        : vibrationEnd == null || vibrationEnd == vibrationStart
        ? "$vibrationStart%"
        : "$vibrationStart% → $vibrationEnd%";

    final heatSettingText = heatSetting == null ? "-" : "$heatSetting%";
    final pillowTemperatureText = pillowTemperature == null
        ? "-"
        : "${(pillowTemperature as num).toStringAsFixed(1)}°C";

    return _recordCard(
      doc: doc,
      data: data,
      icon: Icons.bedtime_rounded,
      title: "Sleep Session",
      durationText: _formatDuration(_sessionSeconds(data)),
      startTime: startTime,
      endTime: endTime,
      accent: _sleepGradient,
      stats: [
        _Stat(
          Icons.vibration_rounded,
          "Vibration",
          vibrationText,
          level: _level(vibrationEnd ?? vibrationStart),
        ),
        _Stat(
          Icons.local_fire_department_rounded,
          "Heat",
          heatSettingText,
          level: _level(heatSetting),
        ),
        _Stat(Icons.device_thermostat_rounded, "Pillow", pillowTemperatureText),
      ],
    );
  }

  // ================= TIMER CARD =================
  Widget buildTimerCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    final duration = (data["duration"] as num?)?.toInt() ?? 0;
    final start = data["set_time"]; // timer docs store start as "set_time"
    final end = data["end_time"];

    DateTime? startTime = start is Timestamp ? start.toDate() : null;
    DateTime? endTime = end is Timestamp ? end.toDate() : null;

    // Timer levels don't change mid-run (slider is locked while running),
    // so there's just one value each — no start/end pair needed here.
    final vibrationLevel = data["vibration_level"];
    final heatLevel = data["heat_level"];

    final vibrationText = vibrationLevel == null ? "-" : "$vibrationLevel%";
    final heatText = heatLevel == null ? "-" : "$heatLevel°C";

    return _recordCard(
      doc: doc,
      data: data,
      icon: Icons.timer_rounded,
      title: "Timer Session",
      durationText: _formatDuration(duration),
      startTime: startTime,
      endTime: endTime,
      accent: _timerGradient,
      stats: [
        _Stat(
          Icons.vibration_rounded,
          "Vibration",
          vibrationText,
          level: _level(vibrationLevel),
        ),
        _Stat(Icons.local_fire_department_rounded, "Heat", heatText),
      ],
    );
  }

  // ================= SLEEP CARD =================
  Widget buildSleepCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    final start = data["sleep_start"];
    final end = data["sleep_end"];
    final actualSeconds = data["actual_sleep_duration_seconds"] is num
        ? (data["actual_sleep_duration_seconds"] as num).toInt()
        : (((data["sleep_duration_minutes"] as num?) ?? 0) * 60).toInt();

    DateTime? startTime = start is Timestamp ? start.toDate() : null;
    DateTime? endTime = end is Timestamp ? end.toDate() : null;

    return _recordCard(
      doc: doc,
      data: data,
      icon: Icons.nights_stay_rounded,
      title: "Sleep Session",
      durationText: _formatDuration(actualSeconds),
      startTime: startTime,
      endTime: endTime,
      accent: _sleepGradient,
    );
  }

  Widget buildInfoRow(IconData icon, String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: _cyan, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title, style: TextStyle(color: _white(.8))),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // LOADING SKELETON
  // ===================================================================
  Widget _loadingSkeleton() {
    return AnimatedBuilder(
      animation: _ambient,
      builder: (context, _) {
        final pulse =
            .05 + .035 * (0.5 + 0.5 * math.sin(_ambient.value * math.pi * 24));
        Widget box(double h, {double r = 22, double? w}) => Container(
          height: h,
          width: w,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: _white(pulse),
            borderRadius: BorderRadius.circular(r),
          ),
        );
        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          children: [
            Row(
              children: [
                box(48, r: 16, w: 48),
                const Spacer(),
                box(48, r: 18, w: 140),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: box(14, r: 7, w: 110),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: box(40, r: 12, w: 200),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: box(16, r: 8, w: 150),
            ),
            const SizedBox(height: 6),
            box(120, r: 26),
            box(250, r: 32),
            box(130, r: 26),
            box(130, r: 26),
          ],
        );
      },
    );
  }
}

// =====================================================================
// SMALL WIDGETS
// =====================================================================

/// Soft, slowly drifting glow blobs behind the content.
class _AuroraBackground extends StatelessWidget {
  final Animation<double> animation;
  const _AuroraBackground({required this.animation});

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
                  440,
                  _violet.withValues(alpha: .38),
                ),
                _blob(
                  Alignment(1.1 + .2 * math.cos(t), -0.35 + .18 * math.sin(t)),
                  380,
                  _cyan.withValues(alpha: .16),
                ),
                _blob(
                  Alignment(-0.7 + .25 * math.cos(t), 1.0 + .1 * math.sin(t)),
                  420,
                  _magenta.withValues(alpha: .20),
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
class _FadeSlideIn extends StatelessWidget {
  final int index;
  final Widget child;
  const _FadeSlideIn({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final delay = math.min(index, 8) * 70;
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

class _LevelBar extends StatelessWidget {
  final double level;
  final Gradient gradient;
  const _LevelBar({required this.level, required this.gradient});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: _white(.08))),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: level),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => FractionallySizedBox(
                widthFactor: v,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: gradient,
                    borderRadius: BorderRadius.circular(3),
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

class _RingPainter extends CustomPainter {
  final double progress;
  _RingPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
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

    // Glow
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
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // Arc
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

// =====================================================================
// CALENDAR
// =====================================================================
class CalendarOverlay extends StatefulWidget {
  final Function(DateTime) onDateSelected;
  final DateTime? initialDate;

  const CalendarOverlay({
    super.key,
    required this.onDateSelected,
    this.initialDate,
  });

  @override
  State<CalendarOverlay> createState() => _CalendarOverlayState();
}

class _CalendarOverlayState extends State<CalendarOverlay> {
  late DateTime focusedDay = widget.initialDate ?? DateTime.now();
  late DateTime? selectedDay = widget.initialDate;

  PageController? _pageController;

  /// Number of recordings per calendar day.
  Map<DateTime, int> recordCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    loadRecordDates();
  }

  Future<void> loadRecordDates() async {
    final snapshot = await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .get();

    final temp = <DateTime, int>{};

    for (var doc in snapshot.docs) {
      final data = doc.data();

      final Timestamp? ts = data["timestamp"] is Timestamp
          ? data["timestamp"]
          : data["sleep_start"] is Timestamp
          ? data["sleep_start"]
          : null;

      if (ts != null) {
        final cleanDate = DateUtils.dateOnly(ts.toDate());
        temp[cleanDate] = (temp[cleanDate] ?? 0) + 1;
      }
    }

    if (!mounted) return;
    setState(() {
      recordCounts = temp;
      _loading = false;
    });
  }

  void _pick(DateTime day) {
    setState(() => selectedDay = day);
    widget.onDateSelected(day);
    Navigator.pop(context); // close calendar after select
  }

  int _countFor(DateTime day) => recordCounts[DateUtils.dateOnly(day)] ?? 0;

  bool _isFuture(DateTime day) =>
      DateUtils.dateOnly(day).isAfter(DateUtils.dateOnly(DateTime.now()));

  // ---------- Month stats ----------
  ({int days, int records, int streak}) _monthStats() {
    final year = focusedDay.year;
    final month = focusedDay.month;
    final daysInMonth = DateUtils.getDaysInMonth(year, month);
    int days = 0, records = 0, streak = 0, run = 0;
    for (int d = 1; d <= daysInMonth; d++) {
      final c = recordCounts[DateTime(year, month, d)] ?? 0;
      if (c > 0) {
        days++;
        records += c;
        run++;
        streak = math.max(streak, run);
      } else {
        run = 0;
      }
    }
    return (days: days, records: records, streak: streak);
  }

  @override
  Widget build(BuildContext context) {
    final stats = _monthStats();
    final now = DateTime.now();
    final viewingCurrentMonth =
        focusedDay.year == now.year && focusedDay.month == now.month;

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
                const Color(0xFF1A1250).withValues(alpha: .92),
                _bg.withValues(alpha: .96),
              ],
            ),
            border: Border(top: BorderSide(color: _white(.14))),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Grab handle
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _white(.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ---------- Header ----------
                  Row(
                    children: [
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("SELECT A DATE", style: _eyebrow()),
                            const SizedBox(height: 4),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              child: RichText(
                                key: ValueKey(
                                  "${focusedDay.year}-${focusedDay.month}",
                                ),
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: DateFormat(
                                        'MMMM',
                                      ).format(focusedDay),
                                      style: _display(
                                        26,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                    TextSpan(
                                      text: "  ${focusedDay.year}",
                                      style: _display(
                                        26,
                                        weight: FontWeight.w300,
                                        color: _white(.45),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _navButton(Icons.chevron_left_rounded, () {
                        _pageController?.previousPage(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                        );
                      }),
                      const SizedBox(width: 8),
                      _navButton(Icons.chevron_right_rounded, () {
                        _pageController?.nextPage(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                        );
                      }),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ---------- Month stats ----------
                  Row(
                    children: [
                      _monthStat(
                        Icons.event_available_rounded,
                        _loading ? "–" : "${stats.days}",
                        "Days logged",
                      ),
                      const SizedBox(width: 8),
                      _monthStat(
                        Icons.bedtime_rounded,
                        _loading ? "–" : "${stats.records}",
                        "Recordings",
                      ),
                      const SizedBox(width: 8),
                      _monthStat(
                        Icons.local_fire_department_rounded,
                        _loading ? "–" : "${stats.streak}d",
                        "Best streak",
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // ---------- Grid ----------
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                    decoration: _glass(radius: 24, strength: .8),
                    child: TableCalendar<int>(
                      firstDay: DateTime.utc(2020),
                      lastDay: DateTime.utc(2035),
                      focusedDay: focusedDay,
                      headerVisible: false,
                      sixWeekMonthsEnforced: false,
                      rowHeight: 50,
                      daysOfWeekHeight: 26,
                      availableGestures: AvailableGestures.horizontalSwipe,
                      onCalendarCreated: (controller) =>
                          _pageController = controller,
                      selectedDayPredicate: (day) =>
                          isSameDay(selectedDay, day),
                      enabledDayPredicate: (day) => !_isFuture(day),
                      onPageChanged: (focused) =>
                          setState(() => focusedDay = focused),
                      onDaySelected: (selected, focused) {
                        focusedDay = focused;
                        _pick(selected);
                      },
                      calendarStyle: const CalendarStyle(
                        outsideDaysVisible: false,
                        cellMargin: EdgeInsets.all(3),
                      ),
                      calendarBuilders: CalendarBuilders<int>(
                        dowBuilder: (context, day) {
                          final weekend =
                              day.weekday == DateTime.saturday ||
                              day.weekday == DateTime.sunday;
                          return Center(
                            child: Text(
                              DateFormat('EEE').format(day)[0],
                              style: TextStyle(
                                color: weekend
                                    ? _cyan.withValues(alpha: .7)
                                    : _white(.4),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                        defaultBuilder: (context, day, _) => _dayCell(day),
                        todayBuilder: (context, day, _) =>
                            _dayCell(day, isToday: true),
                        selectedBuilder: (context, day, _) => _dayCell(
                          day,
                          isSelected: true,
                          isToday: DateUtils.isSameDay(day, DateTime.now()),
                        ),
                        disabledBuilder: (context, day, _) =>
                            _dayCell(day, isDisabled: true),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ---------- Legend ----------
                  Row(
                    children: [
                      const SizedBox(width: 6),
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: _cyan, width: 1.5),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "Today",
                        style: TextStyle(color: _white(.5), fontSize: 11),
                      ),
                      const Spacer(),
                      Text(
                        "Less",
                        style: TextStyle(color: _white(.45), fontSize: 11),
                      ),
                      const SizedBox(width: 6),
                      for (final level in const [0, 1, 2, 4]) ...[
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _heatColor(level),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      const SizedBox(width: 2),
                      Text(
                        "More",
                        style: TextStyle(color: _white(.45), fontSize: 11),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ---------- Actions ----------
                  Row(
                    children: [
                      Expanded(
                        child: _sheetButton(
                          label: "Close",
                          onTap: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: _sheetButton(
                          label: viewingCurrentMonth
                              ? "Go to today"
                              : "Back to this month",
                          icon: Icons.today_rounded,
                          primary: true,
                          onTap: () => _pick(DateTime.now()),
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
  }

  // ---------- Pieces ----------
  Color _heatColor(int count) {
    if (count <= 0) return _white(.04);
    final t = math.min(1.0, count / 4);
    return Color.lerp(
      _violet.withValues(alpha: .28),
      _cyan.withValues(alpha: .55),
      t,
    )!;
  }

  Widget _dayCell(
    DateTime day, {
    bool isSelected = false,
    bool isToday = false,
    bool isDisabled = false,
  }) {
    final count = _countFor(day);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: isSelected ? _sleepGradient : null,
        color: isSelected
            ? null
            : isDisabled
            ? Colors.transparent
            : _heatColor(count),
        border: isToday && !isSelected
            ? Border.all(color: _cyan, width: 1.5)
            : null,
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: _violet.withValues(alpha: .6),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            "${day.day}",
            style: GoogleFonts.outfit(
              fontSize: 15,
              fontWeight: isSelected || isToday || count > 0
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: isDisabled
                  ? _white(.18)
                  : isSelected
                  ? Colors.white
                  : count > 0
                  ? Colors.white
                  : _white(.7),
            ),
          ),
          if (count > 0 && !isDisabled)
            Positioned(
              bottom: 5,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < math.min(count, 3); i++)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? Colors.white : _cyan,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _navButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: _glass(radius: 14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _monthStat(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: _glass(radius: 16, strength: .8),
        child: Row(
          children: [
            Icon(icon, color: _cyan, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value, style: _display(16, weight: FontWeight.w700)),
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

  Widget _sheetButton({
    required String label,
    required VoidCallback onTap,
    IconData? icon,
    bool primary = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: primary
            ? BoxDecoration(
                gradient: _sleepGradient,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: _violet.withValues(alpha: .45),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              )
            : _glass(radius: 16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
