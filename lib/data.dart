import 'dart:async';
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
const Color _green = Color(0xFF34D399);

/// Daily sleep goal used by the progress ring. Change to suit your app.

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

// ===================================================================
// 3D HELPERS (same look as the Weekly / Monthly pages)
// ===================================================================
/// Raised 3D slab: solid darker edge, glow, glossy sheen, bright top edge.
Widget _slab3D({
  required Color tint,
  required Widget child,
  double radius = 24,
  EdgeInsets padding = const EdgeInsets.all(14),
  double depth = 6,
}) {
  return Container(
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
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 50,
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

/// Recessed tray (pressed into the card).
BoxDecoration _tray3D({double radius = 14}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Colors.black.withValues(alpha: .34),
      Colors.black.withValues(alpha: .12),
    ],
  ),
  border: Border.all(color: Colors.white.withValues(alpha: .07)),
);

/// Raised 3D key / chip.
BoxDecoration _key3D(Color tint, {double radius = 12, BoxShape? shape}) =>
    BoxDecoration(
      shape: shape ?? BoxShape.rectangle,
      borderRadius: shape == BoxShape.circle
          ? null
          : BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(tint, Colors.white, .14)!.withValues(alpha: .34),
          tint.withValues(alpha: .14),
        ],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: .14)),
    );

/// Glossy 3D icon tile.
BoxDecoration _iconKey3D(Color c, {Gradient? gradient, double radius = 12}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient:
          gradient ??
          LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(c, Colors.white, .28)!, c],
          ),
      border: Border.all(color: Colors.white.withValues(alpha: .22)),
    );

/// Makes any 3D key sink a little while pressed.
class _Press3D extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  final double travel;
  const _Press3D({required this.onTap, required this.child, this.travel = 3});

  @override
  State<_Press3D> createState() => _Press3DState();
}

class _Press3DState extends State<_Press3D> {
  bool _down = false;

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
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _down ? widget.travel : 0),
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        builder: (context, dy, child) =>
            Transform.translate(offset: Offset(0, dy), child: child),
        child: widget.child,
      ),
    );
  }
}

/// "7h", "7h 30m" or "45m" for a goal length in seconds.
String _goalLabel(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return m == 0 ? "${h}h" : "${h}h ${m}m";
  return "${m}m";
}

/// Minutes from starting a session to falling asleep, or null when the
/// pillow didn't detect sleep (or the times look wrong).
int? _fallAsleepSeconds(Map<String, dynamic> data) {
  final start = data["start_time"];
  final asleep = data["sleep_start_time"];
  if (start is! Timestamp || asleep is! Timestamp) return null;
  final secs = asleep.toDate().difference(start.toDate()).inSeconds;
  if (secs < 0 || secs > 4 * 3600) return null;
  return secs;
}

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

  /// Firestore id of the session this bar belongs to (for tap-to-jump).
  final String? id;

  /// True when the session is under 5 min (may be folded in the list).
  final bool isShort;

  const _Segment(
    this.start,
    this.end,
    this.isTimer, {
    this.id,
    this.isShort = false,
  });
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

  /// Short sessions (under 5 min) are folded until this is turned on.
  bool _showShortSessions = false;

  /// Latest build context of each session card, so a timeline tap can
  /// scroll to it. (Plain contexts, not GlobalKeys, so a quick day switch
  /// during the page animation can't cause a duplicate-key error.)
  final Map<String, BuildContext> _cardContexts = {};

  /// Session card briefly highlighted after a timeline tap.
  String? _highlightId;

  void _jumpToSession(_Segment seg) {
    final id = seg.id;
    if (id == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (seg.isShort) _showShortSessions = true;
      _highlightId = id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _cardContexts[id];
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          alignment: .15,
        );
      }
    });
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted && _highlightId == id) setState(() => _highlightId = null);
    });
  }

  /// Session card with a key (for scrolling) and a glow when highlighted.
  Widget _sessionCardFor(QueryDocumentSnapshot doc) {
    final on = _highlightId == doc.id;
    return Builder(
      builder: (ctx) {
        _cardContexts[doc.id] = ctx;
        return _highlightBox(on, buildSessionCard(doc));
      },
    );
  }

  Widget _highlightBox(bool on, Widget child) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: on
            ? [
                BoxShadow(
                  color: _cyan.withValues(alpha: .55),
                  blurRadius: 22,
                  spreadRadius: 1,
                ),
              ]
            : const [],
      ),
      child: child,
    );
  }

  /// +1 when moving forward in time, -1 when moving back (drives slide anim).
  int _direction = 1;

  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  )..repeat();

  // ✅ ADDED ONLY
  final Map<String, Map<String, dynamic>> _deletedCache = {};

  /// Daily sleep goal — the same one you set on the Weekly page
  /// (Firestore app_settings/sleep_goal), kept live.
  int _dailySleepGoalSeconds = 30 * 60;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _goalSub;

  @override
  void initState() {
    super.initState();
    _goalSub = FirebaseFirestore.instance
        .collection("app_settings")
        .doc("sleep_goal")
        .snapshots()
        .listen((snap) {
          final v = snap.data()?["seconds"];
          if (v is num && v > 0 && mounted) {
            setState(() => _dailySleepGoalSeconds = v.toInt());
          }
        }, onError: (e) => debugPrint("GOAL LOAD ERROR: $e"));
  }

  @override
  void dispose() {
    _goalSub?.cancel();
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

    final logs = FirebaseFirestore.instance.collection("vibrator_logs");

    // A night added by hand also has a linked "sleep" record (that's what
    // Weekly / Monthly count) — remove it too, and keep it for UNDO.
    final linked = <String, Map<String, dynamic>>{};
    if (data["manual"] == true) {
      try {
        final q = await logs.where("session_doc_id", isEqualTo: docId).get();
        for (final d in q.docs) {
          linked[d.id] = d.data();
          await d.reference.delete();
        }
      } catch (e) {
        debugPrint("LINKED DELETE ERROR: $e");
      }
    }

    await logs.doc(docId).delete();

    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();

    final controller = messenger.showSnackBar(
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
              for (final e in linked.entries) {
                await logs.doc(e.key).set(e.value);
              }

              _deletedCache.remove(docId);
            }
          },
        ),
      ),
    );

    // Newer Flutter keeps snackbars that have an action (UNDO) on screen
    // until tapped, so close it ourselves after 3 seconds.
    var open = true;
    controller.closed.then((_) => open = false);

    // ⬅️ after 3 seconds, hide the snackbar and remove undo data
    Future.delayed(const Duration(seconds: 3), () {
      _deletedCache.remove(docId);
      if (open) messenger.hideCurrentSnackBar();
    });
  }

  // ================= ADD A MISSED NIGHT =================
  /// Opens the sheet to log a night by hand.
  void _openAddNight() {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => _AddNightSheet(day: DateUtils.dateOnly(selectedDate)),
    ).then((result) {
      if (result is (DateTime, DateTime)) _saveManualNight(result.$1, result.$2);
    });
  }

  /// Saves a hand-entered night as a session (for this page) plus a linked
  /// sleep record (for Weekly / Monthly), so streaks and averages count it.
  Future<void> _saveManualNight(DateTime bed, DateTime wake) async {
    final secs = wake.difference(bed).inSeconds;
    final logs = FirebaseFirestore.instance.collection("vibrator_logs");
    final sessionRef = logs.doc();
    final batch = FirebaseFirestore.instance.batch();
    batch.set(sessionRef, {
      "type": "session",
      "manual": true,
      "start_time": Timestamp.fromDate(bed),
      "end_time": Timestamp.fromDate(wake),
      "wake_time": Timestamp.fromDate(wake),
      "actual_sleep_duration_seconds": secs,
      "duration": secs,
      "completion_reason": "manual_entry",
      "timestamp": Timestamp.fromDate(bed),
    });
    batch.set(logs.doc(), {
      "type": "sleep",
      "manual": true,
      "session_doc_id": sessionRef.id,
      "sleep_start": Timestamp.fromDate(bed),
      "session_start": Timestamp.fromDate(bed),
      "sleep_end": Timestamp.fromDate(wake),
      "sleep_duration_seconds": secs,
      "sleep_duration_minutes": (secs + 59) ~/ 60,
      "status": "completed",
      "timestamp": Timestamp.fromDate(bed),
    });
    try {
      await batch.commit();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      _goToDate(bed);
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: _green, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Night added · ${_formatDuration(secs)}",
                  style: const TextStyle(color: Colors.white),
                ),
              ),
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
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint("ADD NIGHT ERROR: $e");
    }
  }

  /// Raised 3D bar that opens the "add a missed night" sheet.
  Widget _addNightButton() {
    return _Press3D(
      onTap: _openAddNight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: _key3D(_violet, radius: 18),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: _iconKey3D(_violet, gradient: _sleepGradient, radius: 10),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Add a missed night",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Forgot to start a session? Log it by hand",
                    style: TextStyle(color: _white(.5), fontSize: 11.5),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: _white(.6), size: 20),
          ],
        ),
      ),
    );
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
      _showShortSessions = false;
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
    // Sleep per day (for the coloured week-strip dots) and each day's
    // first bedtime (for "earlier / later than usual").
    final daySleep = <DateTime, int>{};
    final dayBedtime = <DateTime, DateTime>{};
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final ts = data["timestamp"];
      final type = data["type"];
      if (ts is Timestamp && type == "session") {
        final day = DateUtils.dateOnly(ts.toDate());
        daySleep[day] = (daySleep[day] ?? 0) + _sessionSeconds(data);
        final bedRaw = data["sleep_start_time"] ?? data["start_time"];
        if (bedRaw is Timestamp) {
          final bed = bedRaw.toDate();
          final prev = dayBedtime[day];
          if (prev == null || bed.isBefore(prev)) dayBedtime[day] = bed;
        }
      }
    }

    final sessionLogs = docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      if (data["type"] != "session") return false;
      if (data["timestamp"] == null) return false;
      return isSameSelectedDay(data["timestamp"]);
    }).toList();

    int totalSleepSeconds = 0;
    int longestSleepSeconds = 0;
    final pillowTemps = <double>[];
    for (final doc in sessionLogs) {
      final data = doc.data() as Map<String, dynamic>;
      final secs = _sessionSeconds(data);
      totalSleepSeconds += secs;
      if (secs > longestSleepSeconds) longestSleepSeconds = secs;
      final t = data["final_pillow_temperature"];
      if (t is num) pillowTemps.add(t.toDouble());
    }
    final avgPillow = pillowTemps.isEmpty
        ? null
        : pillowTemps.reduce((a, b) => a + b) / pillowTemps.length;

    final dayKey = DateUtils.dateOnly(selectedDate);
    final isToday = DateUtils.isSameDay(selectedDate, DateTime.now());
    final summary = _daySummary(
      sleepSeconds: totalSleepSeconds,
      hasSessions: sessionLogs.isNotEmpty,
      day: dayKey,
      dayBedtime: dayBedtime,
    );

    // Main sessions first; tiny ones (under 5 min) fold into one row.
    const shortLimit = 5 * 60;
    final mainSessions = [
      for (final d in sessionLogs)
        if (_sessionSeconds(d.data() as Map<String, dynamic>) >= shortLimit) d,
    ];
    final shortSessions = [
      for (final d in sessionLogs)
        if (_sessionSeconds(d.data() as Map<String, dynamic>) < shortLimit) d,
    ];
    final foldShort = mainSessions.isNotEmpty && shortSessions.length >= 2;

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
            longest: longestSleepSeconds,
            avgPillow: avgPillow,
            segments: _segmentsFor(sessionLogs, const []),
            isToday: isToday,
            summary: summary,
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
        else if (!foldShort)
          for (final doc in sessionLogs)
            _FadeSlideIn(index: i++, child: _sessionCardFor(doc))
        else ...[
          for (final doc in mainSessions)
            _FadeSlideIn(index: i++, child: _sessionCardFor(doc)),
          _FadeSlideIn(index: i++, child: _shortSessionsToggle(shortSessions)),
          if (_showShortSessions)
            for (final doc in shortSessions)
              _FadeSlideIn(index: i++, child: _sessionCardFor(doc)),
        ],
        // Can't log a night that hasn't happened yet.
        if (!dayKey.isAfter(DateUtils.dateOnly(DateTime.now())))
          _FadeSlideIn(index: i++, child: _addNightButton()),
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
          _weekStrip(daySleep),
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
        _slab3D(
          tint: _violet,
          radius: 20,
          depth: 5,
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
          child: Row(
            children: [
              _barButton(Icons.bar_chart_rounded, "Week", _cyan, () async {
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
              _barDivider(),
              _barButton(Icons.insights_rounded, "Month", _violet, () async {
                // Monthly screen returns a date when the user opens a day.
                final picked = await Navigator.push<DateTime>(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const MonthlySleepScreen(),
                  ),
                );
                if (picked != null && mounted) _goToDate(picked);
              }),
              _barDivider(),
              _barButton(
                Icons.calendar_month_rounded,
                "Date",
                _amber,
                _openCalendar,
              ),
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
      child: _Press3D(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: _key3D(_violet, radius: 16),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  /// One action in the top bar: coloured icon tile with a small label.
  Widget _barButton(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    final tooltip = switch (label) {
      "Week" => "Weekly report",
      "Month" => "Monthly report",
      _ => "Pick a date",
    };
    return Tooltip(
      message: tooltip,
      child: _Press3D(
        onTap: onTap,
        travel: 2.5,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Glossy 3D icon key
                Container(
                  width: 34,
                  height: 34,
                  decoration: _iconKey3D(color, radius: 11),
                  child: Icon(icon, color: Colors.white, size: 18),
                ),
                const SizedBox(height: 4),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: _white(.8),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .3,
                  ),
                ),
              ],
            ),
          ),
      ),
    );
  }

  // Engraved groove: dark line + light line.
  Widget _barDivider() => Container(
    width: 2,
    height: 32,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          Colors.black.withValues(alpha: .45),
          Colors.black.withValues(alpha: .45),
          Colors.white.withValues(alpha: .08),
          Colors.white.withValues(alpha: .08),
        ],
        stops: const [0, .5, .5, 1],
      ),
    ),
  );

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
                "SLEEP LOG",
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
              : _Press3D(
                  onTap: () => _goToDate(DateTime.now()),
                  child: _chip("Jump to today", icon: Icons.restore_rounded),
                ),
        ),
      ],
    );
  }

  Widget _chip(String text, {Gradient? gradient, IconData? icon}) {
    return Container(
      padding: EdgeInsets.fromLTRB(icon != null ? 5 : 12, 5, 12, 5),
      decoration: gradient != null
          ? _iconKey3D(_violet, gradient: gradient, radius: 20)
          : _key3D(_violet, radius: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Container(
              width: 24,
              height: 24,
              decoration: _iconKey3D(_cyan, gradient: _sleepGradient, radius: 12),
              child: Icon(icon, size: 14, color: Colors.white),
            ),
            const SizedBox(width: 7),
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
  Widget _weekStrip(Map<DateTime, int> daySleep) {
    final sel = DateUtils.dateOnly(selectedDate);
    final weekStart = DateTime(sel.year, sel.month, sel.day - sel.weekday % 7);
    final weekEnd = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day + 6,
    );

    return _slab3D(
      tint: _violet,
      radius: 26,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
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
              _dotLegend(_green, "Goal"),
              const SizedBox(width: 8),
              _dotLegend(_amber, "Below"),
              const SizedBox(width: 10),
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
          const SizedBox(height: 12),
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
                  child: buildDay(day, index, sleepSeconds: daySleep[day]),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _dotLegend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-.4, -.4),
              colors: [Color.lerp(color, Colors.white, .55)!, color],
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: _white(.5), fontSize: 10.5)),
      ],
    );
  }

  /// One-line verdict for the day: vs goal, and bedtime vs usual.
  List<({IconData icon, String text, Color color})> _daySummary({
    required int sleepSeconds,
    required bool hasSessions,
    required DateTime day,
    required Map<DateTime, DateTime> dayBedtime,
  }) {
    final out = <({IconData icon, String text, Color color})>[];
    if (!hasSessions) return out;

    final goalH = _goalLabel(_dailySleepGoalSeconds);
    final diff = _dailySleepGoalSeconds - sleepSeconds;
    if (diff <= 0) {
      out.add((
        icon: Icons.check_circle_rounded,
        text: diff == 0
            ? "Goal met"
            : "Goal met · ${_formatDuration(-diff)} over $goalH",
        color: _green,
      ));
    } else {
      out.add((
        icon: Icons.flag_rounded,
        text: "${_formatDuration(diff)} below your $goalH goal",
        color: _amber,
      ));
    }

    // Usual bedtime = circular mean of the 14 days before this one.
    final bed = dayBedtime[day];
    if (bed != null) {
      final mins = <int>[];
      for (int k = 1; k <= 14; k++) {
        final b = dayBedtime[DateTime(day.year, day.month, day.day - k)];
        if (b != null) mins.add(b.hour * 60 + b.minute);
      }
      if (mins.length >= 3) {
        double sx = 0, sy = 0;
        for (final m in mins) {
          final a = m / 1440 * 2 * math.pi;
          sx += math.cos(a);
          sy += math.sin(a);
        }
        var angle = math.atan2(sy, sx);
        if (angle < 0) angle += 2 * math.pi;
        final usual = (angle / (2 * math.pi) * 1440).round() % 1440;
        var d = ((bed.hour * 60 + bed.minute) - usual) % 1440;
        if (d > 720) d -= 1440;
        final abs = d.abs();
        final txt = abs >= 60
            ? (abs % 60 == 0 ? "${abs ~/ 60}h" : "${abs ~/ 60}h ${abs % 60}m")
            : "${abs}m";
        if (abs < 20) {
          out.add((
            icon: Icons.schedule_rounded,
            text: "Bedtime right on your usual time",
            color: _cyan,
          ));
        } else {
          out.add((
            icon: Icons.schedule_rounded,
            text: "Bedtime $txt ${d > 0 ? 'later' : 'earlier'} than usual",
            color: d > 0 ? _amber : _cyan,
          ));
        }
      }
    }
    return out;
  }

  Widget _shortSessionsToggle(List<QueryDocumentSnapshot> short) {
    final total = short.fold<int>(
      0,
      (a, d) => a + _sessionSeconds(d.data() as Map<String, dynamic>),
    );
    final open = _showShortSessions;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _showShortSessions = !open);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _white(.04),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _white(.08)),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _violet.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.more_horiz_rounded,
                color: _violet,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                open
                    ? "Hide ${short.length} short sessions"
                    : "+${short.length} short sessions (under 5 min) · "
                          "${_formatDuration(total)}",
                style: TextStyle(
                  color: _white(.75),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AnimatedRotation(
              turns: open ? .5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                color: _white(.6),
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallRoundButton(IconData icon, VoidCallback onTap) {
    return _Press3D(
      onTap: onTap,
      travel: 2,
      child: Container(
        width: 32,
        height: 32,
        decoration: _key3D(_violet, shape: BoxShape.circle),
        child: Icon(icon, color: _white(.9), size: 20),
      ),
    );
  }

  // ================= DAY =================
  Widget buildDay(DateTime day, int index, {int? sleepSeconds}) {
    final hasRecord = sleepSeconds != null;
    final metGoal = (sleepSeconds ?? 0) >= _dailySleepGoalSeconds;
    final isSelected = DateUtils.isSameDay(day, selectedDate);
    final isToday = DateUtils.isSameDay(day, DateTime.now());

    final tint = hasRecord ? (metGoal ? _green : _amber) : _violet;

    // Selected = glossy key popped up; logged = raised tile;
    // empty = pressed into the card.
    final BoxDecoration deco;
    if (isSelected) {
      deco = BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: _sleepGradient,
        border: Border.all(color: Colors.white.withValues(alpha: .3)),
      );
    } else if (hasRecord) {
      deco = BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(tint, Colors.white, .1)!.withValues(alpha: .22),
            tint.withValues(alpha: .06),
          ],
        ),
        border: Border.all(
          color: isToday
              ? _cyan.withValues(alpha: .7)
              : Colors.white.withValues(alpha: .12),
          width: isToday ? 1.4 : 1,
        ),
      );
    } else {
      deco = _tray3D(radius: 18).copyWith(
        border: Border.all(
          color: isToday
              ? _cyan.withValues(alpha: .7)
              : Colors.white.withValues(alpha: .07),
          width: isToday ? 1.4 : 1,
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        _goToDate(day);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        height: 74,
        transform: Matrix4.translationValues(0, isSelected ? -3 : 0, 0),
        decoration: deco,
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
                    ? (metGoal ? _green : _amber)
                    : Colors.transparent,
                border: hasRecord && isSelected
                    ? Border.all(color: Colors.white, width: 1)
                    : null,
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
      bool isTimer, {
      String? id,
    }) {
      DateTime? start = startRaw is Timestamp ? startRaw.toDate() : null;
      DateTime? end = endRaw is Timestamp ? endRaw.toDate() : null;
      if (start == null && end == null && tsRaw is Timestamp) {
        end = tsRaw.toDate();
      }
      start ??= end?.subtract(Duration(seconds: secs));
      end ??= start?.add(Duration(seconds: secs));
      if (start == null || end == null) return;
      out.add(
        _Segment(
          frac(start),
          frac(end),
          isTimer,
          id: id,
          isShort: !isTimer && secs < 5 * 60,
        ),
      );
    }

    for (final doc in sessions) {
      final d = doc.data() as Map<String, dynamic>;
      add(
        d["start_time"],
        d["end_time"],
        d["timestamp"],
        _sessionSeconds(d),
        false,
        id: doc.id,
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
    required int longest,
    required double? avgPillow,
    required List<_Segment> segments,
    required bool isToday,
    List<({IconData icon, String text, Color color})> summary = const [],
  }) {
    final progress = sessions == 0
        ? 0.0
        : sleepSeconds / _dailySleepGoalSeconds;
    final now = DateTime.now();
    final nowFrac = isToday
        ? (now.hour * 3600 + now.minute * 60 + now.second) / 86400.0
        : null;

    return _slab3D(
      tint: _violet,
      radius: 32,
      padding: const EdgeInsets.all(20),
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
                              "of ${_goalLabel(_dailySleepGoalSeconds)} goal",
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
                      _violet,
                      "$sessions",
                      sessions == 1 ? "Session" : "Sessions",
                    ),
                    const SizedBox(height: 12),
                    _heroStat(
                      Icons.emoji_events_rounded,
                      _amber,
                      longest <= 0 ? "-" : _formatDuration(longest),
                      "Longest sleep",
                    ),
                    const SizedBox(height: 12),
                    _heroStat(
                      Icons.device_thermostat_rounded,
                      _pink,
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
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              decoration: _tray3D(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (k, line) in summary.indexed) ...[
                    if (k > 0) const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(line.icon, color: line.color, size: 15),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            line.text,
                            style: TextStyle(
                              color: _white(.85),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Text("24-HOUR TIMELINE", style: _eyebrow()),
              const SizedBox(width: 8),
              if (segments.isNotEmpty)
                Text(
                  "· tap a bar",
                  style: TextStyle(color: _white(.4), fontSize: 10.5),
                ),
              const Spacer(),
              _legendDot(_sleepGradient, "Sleep"),
            ],
          ),
          const SizedBox(height: 12),
          _timeline(segments, nowFrac),
        ],
      ),
    );
  }

  Widget _heroStat(IconData icon, Color color, String value, String label) {
    return Row(
      children: [
        // Glossy 3D icon key
        Container(
          width: 36,
          height: 36,
          decoration: _iconKey3D(color),
          child: Icon(icon, color: Colors.white, size: 18),
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
          width: 14,
          height: 8,
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white.withValues(alpha: .35)),
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
                        borderRadius: BorderRadius.circular(7),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: .45),
                            Colors.white.withValues(alpha: .05),
                          ],
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .07),
                        ),
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
                      // Glossy 3D capsule (no shadow).
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: s.isTimer ? _timerGradient : _sleepGradient,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .35),
                          ),
                        ),
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: .45),
                              Colors.white.withValues(alpha: 0),
                              Colors.black.withValues(alpha: .18),
                            ],
                            stops: const [0, .5, 1],
                          ),
                        ),
                      ),
                    ),
                  // Bigger invisible tap targets on top of each bar.
                  for (final s in segments)
                    if (s.id != null)
                      Positioned(
                        left: math.max(0, math.min(w * s.start, w - 6) - 8),
                        top: -6,
                        height: 36,
                        width: math.max(w * (s.end - s.start), 6) + 16,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _jumpToSession(s),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: _key3D(_violet, radius: 10),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _slab3D(
      tint: _violet,
      radius: 26,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      child: SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: _iconKey3D(
              accent.colors.first,
              gradient: accent,
              radius: 30,
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
      ),
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
    String? note,
    Widget? extra,
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
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: _slab3D(
        tint: _violet,
        radius: 26,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Glossy 3D icon key
                Container(
                  width: 46,
                  height: 46,
                  decoration: _iconKey3D(
                    accent.colors.first,
                    gradient: accent,
                    radius: 15,
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
                      if (note != null) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            const Icon(
                              Icons.hourglass_bottom_rounded,
                              size: 13,
                              color: _cyan,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                note,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _cyan.withValues(alpha: .85),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  durationText,
                  style: _display(24, weight: FontWeight.w700),
                ),
              ],
            ),
            if (stats.isNotEmpty) ...[
              const SizedBox(height: 16),
              // Equal-height tiles so "Pillow" lines up with the others.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < stats.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: _statTile(stats[i], accent)),
                    ],
                  ],
                ),
              ),
            ],
            if (extra != null) ...[const SizedBox(height: 12), extra],
          ],
        ),
      ),
      ),
    );
  }

  Widget _statTile(_Stat stat, Gradient accent) {
    return Container(
      padding: const EdgeInsets.all(12),
      // Raised inner panel (glossy top, bright rim, no shadow).
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(_violet, Colors.white, .12)!.withValues(alpha: .22),
            _violet.withValues(alpha: .06),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .13)),
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

    if (data["manual"] == true) {
      return _recordCard(
        doc: doc,
        data: data,
        icon: Icons.edit_calendar_rounded,
        title: "Added by hand",
        durationText: _formatDuration(_sessionSeconds(data)),
        startTime: startTime,
        endTime: endTime,
        accent: _sleepGradient,
      );
    }

    return _recordCard(
      doc: doc,
      data: data,
      icon: Icons.bedtime_rounded,
      title: "Sleep Session",
      extra: _tempChart(data, startTime),
      note: switch (_fallAsleepSeconds(data)) {
        final s? => "Fell asleep in ${s < 60 ? "${s}s" : "${s ~/ 60}m"}",
        null => null,
      },
      durationText: _formatDuration(_sessionSeconds(data)),
      startTime: startTime,
      endTime: endTime,
      accent: _sleepGradient,
      stats: [
        _Stat(
          Icons.waves_rounded,
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

  /// Pillow temperature through the session (needs 2+ samples).
  Widget? _tempChart(Map<String, dynamic> data, DateTime? start) {
    final raw = data["temp_samples"];
    if (raw is! List) return null;
    final pts = <(double, double)>[];
    for (final e in raw) {
      if (e is Map && e["t"] is num && e["c"] is num) {
        pts.add(((e["t"] as num).toDouble(), (e["c"] as num).toDouble()));
      }
    }
    if (pts.length < 2) return null;
    pts.sort((a, b) => a.$1.compareTo(b.$1));

    final temps = pts.map((p) => p.$2);
    final lo = temps.reduce(math.min);
    final hi = temps.reduce(math.max);
    final first = pts.first.$2;
    final last = pts.last.$2;
    final change = last - first;
    String clockAt(double secs) => start == null
        ? ""
        : DateFormat('h:mm a').format(
            start.add(Duration(seconds: secs.round())),
          );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: _tray3D(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.device_thermostat_rounded, size: 14, color: _amber),
              const SizedBox(width: 6),
              Text(
                "Pillow temperature",
                style: TextStyle(
                  color: _white(.7),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                "${lo.toStringAsFixed(1)}–${hi.toStringAsFixed(1)}°C",
                style: TextStyle(color: _white(.55), fontSize: 11),
              ),
              const SizedBox(width: 8),
              Text(
                change.abs() < .05
                    ? "steady"
                    : "${change > 0 ? '▲' : '▼'} ${change.abs().toStringAsFixed(1)}°",
                style: TextStyle(
                  color: change > .05
                      ? _amber
                      : change < -.05
                      ? _cyan
                      : _white(.55),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            width: double.infinity,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => CustomPaint(
                painter: _TempLinePainter(pts, reveal: v),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                clockAt(pts.first.$1),
                style: TextStyle(color: _white(.4), fontSize: 10),
              ),
              const Spacer(),
              Text(
                clockAt(pts.last.$1),
                style: TextStyle(color: _white(.4), fontSize: 10),
              ),
            ],
          ),
        ],
      ),
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
          Icons.waves_rounded,
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
    // Recessed 3D track with a glossy fill.
    return Container(
      height: 8,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: .45),
            Colors.white.withValues(alpha: .05),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .06)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: level),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => FractionallySizedBox(
            widthFactor: v,
            heightFactor: 1,
            child: Container(
              decoration: BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(4),
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: .45),
                    Colors.white.withValues(alpha: 0),
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

class _RingPainter extends CustomPainter {
  final double progress;
  _RingPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Recessed groove: dark track with a light lower lip.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.black.withValues(alpha: .35),
    );
    canvas.drawCircle(
      center,
      radius + stroke / 2 - .6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: .3),
            Colors.white.withValues(alpha: .14),
          ],
        ).createShader(rect.inflate(stroke)),
    );

    if (progress <= 0) return;

    final sweep = math.max(2 * math.pi * progress.clamp(0.0, 1.0), 0.04);
    final shader = const SweepGradient(
      colors: [_violet, _cyan, _magenta, _violet],
      transform: GradientRotation(-math.pi / 2),
    ).createShader(rect);

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

    // Glossy highlight along the outer side of the tube.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + stroke * .22),
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: .4),
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
                            border: Border.all(
                              color: level == 0
                                  ? _white(.08)
                                  : _cyan.withValues(alpha: .3),
                            ),
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
      _violet.withValues(alpha: .35),
      _cyan.withValues(alpha: .6),
      t,
    )!;
  }

  Widget _dayCell(
    DateTime day, {
    bool isSelected = false,
    bool isToday = false,
    bool isDisabled = false,
  }) {
    final count = isDisabled ? 0 : _countFor(day);
    final hasData = count > 0;
    final weekend =
        day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
    final t = math.min(1.0, count / 4);

    final Color textColor = isDisabled
        ? _white(.16)
        : isSelected || hasData
        ? Colors.white
        : isToday
        ? _cyan
        : weekend
        ? _cyan.withValues(alpha: .55)
        : _white(.6);

    // Fill the whole cell so every day is an even rounded tile.
    return SizedBox.expand(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: isSelected
              ? _sleepGradient
              : hasData
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _heatColor(count),
                    Color.lerp(
                      _violet.withValues(alpha: .2),
                      _cyan.withValues(alpha: .35),
                      t,
                    )!,
                  ],
                )
              : null,
          color: isSelected || hasData
              ? null
              : isDisabled
              ? Colors.transparent
              : _white(.035),
          border: isSelected
              ? Border.all(color: _white(.5), width: 1.2)
              : isToday
              ? Border.all(color: _cyan, width: 1.8)
              : hasData
              ? Border.all(color: _cyan.withValues(alpha: .25 + .35 * t))
              : isDisabled
              ? null
              : Border.all(color: _white(.06)),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _violet.withValues(alpha: .6),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : isToday
              ? [BoxShadow(color: _cyan.withValues(alpha: .3), blurRadius: 12)]
              : hasData
              ? [
                  BoxShadow(
                    color: _cyan.withValues(alpha: .08 + .18 * t),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: hasData ? 6 : 0),
              child: Text(
                "${day.day}",
                style: GoogleFonts.outfit(
                  fontSize: 15.5,
                  fontWeight: isSelected || isToday || hasData
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: textColor,
                ),
              ),
            ),
            // Recordings that day: up to 3 dots, then "3+".
            if (hasData)
              Positioned(
                bottom: 6,
                child: count > 3
                    ? Text(
                        "$count",
                        style: TextStyle(
                          color: isSelected ? Colors.white : _cyan,
                          fontSize: 8.5,
                          height: 1,
                          fontWeight: FontWeight.w800,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (int i = 0; i < count; i++)
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
            // Small "today" marker in the corner.
            if (isToday)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected ? Colors.white : _cyan,
                    boxShadow: [
                      BoxShadow(
                        color: (isSelected ? Colors.white : _cyan).withValues(
                          alpha: .8,
                        ),
                        blurRadius: 4,
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

// =====================================================================
// ADD A MISSED NIGHT — bottom sheet
// =====================================================================
/// Lets the user pick when they went to bed and woke up. Pops with
/// `(bedtime, wakeTime)` when saved.
class _AddNightSheet extends StatefulWidget {
  final DateTime day; // the day selected on the Sleep Log
  const _AddNightSheet({required this.day});

  @override
  State<_AddNightSheet> createState() => _AddNightSheetState();
}

class _AddNightSheetState extends State<_AddNightSheet> {
  /// 0 = went to bed on the selected day, 1 = the evening before.
  int _bedDay = 0;
  TimeOfDay _bed = const TimeOfDay(hour: 22, minute: 30);
  TimeOfDay _wake = const TimeOfDay(hour: 6, minute: 30);

  @override
  void initState() {
    super.initState();
    // Logging today? The night most likely started yesterday evening.
    if (DateUtils.isSameDay(widget.day, DateTime.now())) _bedDay = 1;
  }

  DateTime get _bedDate {
    final d = widget.day.subtract(Duration(days: _bedDay));
    return DateTime(d.year, d.month, d.day, _bed.hour, _bed.minute);
  }

  /// Wake is the first time after bedtime with the chosen clock time.
  DateTime get _wakeDate {
    final b = _bedDate;
    var w = DateTime(b.year, b.month, b.day, _wake.hour, _wake.minute);
    if (!w.isAfter(b)) w = w.add(const Duration(days: 1));
    return w;
  }

  int get _seconds => _wakeDate.difference(_bedDate).inSeconds;

  String? get _problem {
    if (_wakeDate.isAfter(DateTime.now())) {
      return "Wake-up time is in the future";
    }
    if (_seconds < 15 * 60) return "A night needs at least 15 minutes";
    if (_seconds > 16 * 3600) return "That's over 16 hours — check the times";
    return null;
  }

  Future<void> _pick(bool bed) async {
    final picked = await showDialog<TimeOfDay>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (_) => _TimeWheelDialog(
        initial: bed ? _bed : _wake,
        title: bed ? "Went to bed at" : "Woke up at",
        icon: bed ? Icons.bedtime_rounded : Icons.wb_sunny_rounded,
        color: bed ? _violet : _amber,
      ),
    );
    if (picked == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (bed) {
        _bed = picked;
      } else {
        _wake = picked;
      }
    });
  }

  String _clock(TimeOfDay t) =>
      DateFormat('h:mm a').format(DateTime(2000, 1, 1, t.hour, t.minute));

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    final prevDay = widget.day.subtract(const Duration(days: 1));

    Widget dayChip(int value, String label) {
      final on = _bedDay == value;
      return Expanded(
        child: _Press3D(
          onTap: () => setState(() => _bedDay = value),
          travel: 2,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: on
                ? _iconKey3D(_violet, gradient: _sleepGradient, radius: 14)
                : _key3D(Colors.white, radius: 14),
            child: Text(
              label,
              style: TextStyle(
                color: on ? Colors.white : _white(.65),
                fontSize: 12.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    Widget timeTile(bool bed) {
      final color = bed ? _violet : _amber;
      return Expanded(
        child: _Press3D(
          onTap: () => _pick(bed),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: _key3D(color, radius: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: _iconKey3D(color, radius: 9),
                      child: Icon(
                        bed ? Icons.bedtime_rounded : Icons.wb_sunny_rounded,
                        color: Colors.white,
                        size: 15,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      bed ? "Bedtime" : "Woke up",
                      style: TextStyle(color: _white(.6), fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  _clock(bed ? _bed : _wake),
                  style: _display(22, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('EEE, MMM d').format(bed ? _bedDate : _wakeDate),
                  style: TextStyle(color: _white(.45), fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(_surface, Colors.white, .06)!, _bg],
        ),
        border: Border(top: BorderSide(color: _white(.14))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _white(.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            "ADD A MISSED NIGHT",
            style: _eyebrow(color: _cyan.withValues(alpha: .85)),
          ),
          const SizedBox(height: 6),
          Text(
            "When did you sleep?",
            style: _display(24, weight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            "It counts toward your goal, streaks and averages.",
            style: TextStyle(color: _white(.55), fontSize: 12.5),
          ),
          const SizedBox(height: 18),
          Text(
            "Went to bed on",
            style: TextStyle(color: _white(.6), fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              dayChip(1, DateFormat('EEE, MMM d').format(prevDay)),
              const SizedBox(width: 8),
              dayChip(0, DateFormat('EEE, MMM d').format(widget.day)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              timeTile(true),
              const SizedBox(width: 10),
              timeTile(false),
            ],
          ),
          const SizedBox(height: 14),
          // Live result
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: _tray3D(),
            child: Row(
              children: [
                Icon(
                  problem == null
                      ? Icons.nights_stay_rounded
                      : Icons.error_outline_rounded,
                  color: problem == null ? _cyan : _amber,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    problem ?? "${_formatDuration(_seconds)} of sleep",
                    style: TextStyle(
                      color: problem == null ? Colors.white : _amber,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: problem == null ? 1 : .4,
            child: _Press3D(
              onTap: () {
                if (problem != null) return;
                Navigator.pop(context, (_bedDate, _wakeDate));
              },
              child: Container(
                height: 52,
                alignment: Alignment.center,
                decoration: _iconKey3D(
                  _violet,
                  gradient: _sleepGradient,
                  radius: 18,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_rounded, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      "Save night",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
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
}

/// Small line chart of pillow temperature over a session: glossy amber
/// line with a soft fill and end dots (no shadows / glows).
class _TempLinePainter extends CustomPainter {
  final List<(double, double)> pts; // (seconds, °C)
  final double reveal; // 0..1 draw-in animation
  _TempLinePainter(this.pts, {this.reveal = 1});

  @override
  void paint(Canvas canvas, Size size) {
    final t0 = pts.first.$1, t1 = pts.last.$1;
    var lo = pts.map((p) => p.$2).reduce(math.min);
    var hi = pts.map((p) => p.$2).reduce(math.max);
    // Keep at least a 2 °C window so tiny wobbles don't look dramatic.
    if (hi - lo < 2) {
      final mid = (hi + lo) / 2;
      lo = mid - 1;
      hi = mid + 1;
    }
    const pad = 5.0;
    Offset at((double, double) p) => Offset(
      t1 == t0 ? 0 : (p.$1 - t0) / (t1 - t0) * size.width,
      pad + (1 - (p.$2 - lo) / (hi - lo)) * (size.height - pad * 2),
    );

    // Faint guide lines
    final guide = Paint()
      ..color = Colors.white.withValues(alpha: .07)
      ..strokeWidth = 1;
    for (final f in [.25, .5, .75]) {
      canvas.drawLine(
        Offset(0, size.height * f),
        Offset(size.width, size.height * f),
        guide,
      );
    }

    final line = Path()..moveTo(at(pts.first).dx, at(pts.first).dy);
    for (int i = 1; i < pts.length; i++) {
      final a = at(pts[i - 1]), b = at(pts[i]);
      final mx = (a.dx + b.dx) / 2;
      line.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * reveal, size.height));

    // Soft fill under the line
    final fill = Path.from(line)
      ..lineTo(at(pts.last).dx, size.height)
      ..lineTo(at(pts.first).dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _amber.withValues(alpha: .28),
            _amber.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );

    // Glossy line: darker base stroke + bright top stroke
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFE08A1E),
    );
    canvas.drawPath(
      line.shift(const Offset(0, -.6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFD79A),
    );
    canvas.restore();

    // End dots (start = hollow, latest = filled)
    final s0 = at(pts.first);
    canvas.drawCircle(s0, 3.2, Paint()..color = const Color(0xFF1A1440));
    canvas.drawCircle(
      s0,
      3.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _amber,
    );
    if (reveal >= .99) {
      final e = at(pts.last);
      canvas.drawCircle(e, 4, Paint()..color = _amber);
      canvas.drawCircle(e, 1.6, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_TempLinePainter old) =>
      old.reveal != reveal || old.pts != pts;
}

// =====================================================================
// 3D TIME WHEEL PICKER (replaces the stock Material clock)
// =====================================================================
/// Hour / minute / AM-PM wheels sitting in a recessed 3D well, with a
/// glossy selection band. Pops with the chosen [TimeOfDay].
class _TimeWheelDialog extends StatefulWidget {
  final TimeOfDay initial;
  final String title;
  final IconData icon;
  final Color color;
  const _TimeWheelDialog({
    required this.initial,
    required this.title,
    required this.icon,
    required this.color,
  });

  @override
  State<_TimeWheelDialog> createState() => _TimeWheelDialogState();
}

class _TimeWheelDialogState extends State<_TimeWheelDialog> {
  static const double _item = 46;

  late int _hour12 = widget.initial.hourOfPeriod == 0
      ? 12
      : widget.initial.hourOfPeriod; // 1..12
  late int _minute = widget.initial.minute; // 0..59
  late bool _pm = widget.initial.period == DayPeriod.pm;

  // Large starting offsets so the hour / minute wheels can spin both ways.
  late final _hourCtrl = FixedExtentScrollController(
    initialItem: 12 * 50 + (_hour12 - 1),
  );
  late final _minCtrl = FixedExtentScrollController(
    initialItem: 60 * 50 + _minute,
  );
  late final _ampmCtrl = FixedExtentScrollController(initialItem: _pm ? 1 : 0);

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minCtrl.dispose();
    _ampmCtrl.dispose();
    super.dispose();
  }

  TimeOfDay get _value =>
      TimeOfDay(hour: (_hour12 % 12) + (_pm ? 12 : 0), minute: _minute);

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int count,
    required bool loop,
    required String Function(int) label,
    required bool Function(int) isSelected,
    required ValueChanged<int> onChanged,
    double width = 72,
  }) {
    return SizedBox(
      width: width,
      child: ListWheelScrollView.useDelegate(
        controller: controller,
        itemExtent: _item,
        diameterRatio: 1.35,
        perspective: .004,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: (i) {
          HapticFeedback.selectionClick();
          onChanged(i % count);
        },
        childDelegate: loop
            ? ListWheelChildLoopingListDelegate(
                children: [
                  for (int i = 0; i < count; i++)
                    _wheelText(label(i), isSelected(i)),
                ],
              )
            : ListWheelChildListDelegate(
                children: [
                  for (int i = 0; i < count; i++)
                    _wheelText(label(i), isSelected(i)),
                ],
              ),
      ),
    );
  }

  Widget _wheelText(String text, bool selected) {
    return Center(
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 150),
        style: GoogleFonts.outfit(
          fontSize: selected ? 30 : 22,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? Colors.white : _white(.35),
        ),
        child: Text(text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final v = _value;
    final preview = DateFormat(
      'h:mm a',
    ).format(DateTime(2000, 1, 1, v.hour, v.minute));

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        // 3D slab, no shadows: lit top, darker base, bright rim.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(_surface, c, .22)!,
              Color.lerp(_bg, c, .06)!,
            ],
          ),
          border: Border.all(color: _white(.16)),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_white(.06), _white(0)],
            stops: const [0, .35],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---------- Header ----------
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: _iconKey3D(c, radius: 11),
                  child: Icon(widget.icon, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title.toUpperCase(),
                        style: _eyebrow(color: c.withValues(alpha: .9)),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        preview,
                        style: _display(22, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ---------- Wheels in a recessed well ----------
            Container(
              height: _item * 5,
              decoration: _tray3D(radius: 20),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Glossy selection band behind the centre row
                  Positioned(
                    left: 10,
                    right: 10,
                    child: Container(
                      height: _item,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color.lerp(c, Colors.white, .15)!.withValues(
                              alpha: .45,
                            ),
                            c.withValues(alpha: .18),
                          ],
                        ),
                        border: Border.all(color: _white(.22)),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _wheel(
                        controller: _hourCtrl,
                        count: 12,
                        loop: true,
                        label: (i) => "${i + 1}",
                        isSelected: (i) => i + 1 == _hour12,
                        onChanged: (i) => setState(() => _hour12 = i + 1),
                      ),
                      Text(
                        ":",
                        style: _display(28, weight: FontWeight.w700),
                      ),
                      _wheel(
                        controller: _minCtrl,
                        count: 60,
                        loop: true,
                        label: (i) => i.toString().padLeft(2, '0'),
                        isSelected: (i) => i == _minute,
                        onChanged: (i) => setState(() => _minute = i),
                      ),
                      const SizedBox(width: 6),
                      _wheel(
                        controller: _ampmCtrl,
                        count: 2,
                        loop: false,
                        width: 64,
                        label: (i) => i == 0 ? "AM" : "PM",
                        isSelected: (i) => (i == 1) == _pm,
                        onChanged: (i) => setState(() => _pm = i == 1),
                      ),
                    ],
                  ),
                  // Fade the wheel edges into the well
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            _bg.withValues(alpha: .85),
                            _bg.withValues(alpha: 0),
                            _bg.withValues(alpha: 0),
                            _bg.withValues(alpha: .85),
                          ],
                          stops: const [0, .3, .7, 1],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ---------- Actions ----------
            Row(
              children: [
                Expanded(
                  child: _Press3D(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: _key3D(Colors.white, radius: 16),
                      child: Text(
                        "Cancel",
                        style: TextStyle(
                          color: _white(.8),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _Press3D(
                    onTap: () => Navigator.pop(context, _value),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: _iconKey3D(c, radius: 16),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 19,
                          ),
                          SizedBox(width: 6),
                          Text(
                            "Set time",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
