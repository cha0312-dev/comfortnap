import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;

import 'package:esp32_ble_app/alarm_service.dart';

// =====================================================================
// BEDTIME REMINDER
// A daily notification a few minutes before bedtime, with
// "Start wind-down" and "Snooze 10 min" buttons. Works with the app
// closed: the next 14 reminders are handed to Android and topped up
// every time the app opens or the settings are saved.
// =====================================================================

const Color _bg = Color(0xFF07031F);
const Color _surface = Color(0xFF151040);
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);
const Color _amber = Color(0xFFFFB547);

Color _white(double a) => Colors.white.withValues(alpha: a);

TextStyle _display(double size, FontWeight weight, [Color? color]) =>
    GoogleFonts.outfit(
      fontSize: size,
      fontWeight: weight,
      color: color ?? Colors.white,
      height: 1.1,
    );

class BedtimeSettings {
  final bool enabled;
  final int hour;
  final int minute;
  final int leadMinutes;

  /// Weekdays the reminder fires (DateTime.monday = 1 … DateTime.sunday = 7).
  final Set<int> days;

  const BedtimeSettings({
    this.enabled = false,
    this.hour = 22,
    this.minute = 30,
    this.leadMinutes = 5,
    this.days = const {1, 2, 3, 4, 5, 6, 7},
  });

  BedtimeSettings copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    int? leadMinutes,
    Set<int>? days,
  }) => BedtimeSettings(
    enabled: enabled ?? this.enabled,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    leadMinutes: leadMinutes ?? this.leadMinutes,
    days: days ?? this.days,
  );

  factory BedtimeSettings.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const BedtimeSettings();
    final rawDays = m["days"];
    return BedtimeSettings(
      enabled: m["enabled"] == true,
      hour: (m["hour"] as num?)?.toInt() ?? 22,
      minute: (m["minute"] as num?)?.toInt() ?? 30,
      leadMinutes: (m["lead_minutes"] as num?)?.toInt() ?? 5,
      days: rawDays is List
          ? rawDays.map((e) => (e as num).toInt()).toSet()
          : const {1, 2, 3, 4, 5, 6, 7},
    );
  }

  Map<String, dynamic> toMap() => {
    "enabled": enabled,
    "hour": hour,
    "minute": minute,
    "lead_minutes": leadMinutes,
    "days": (days.toList()..sort()),
    "updated_at": FieldValue.serverTimestamp(),
  };

  DateTime bedtimeOn(DateTime day) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  String get bedtimeText =>
      DateFormat("h:mm a").format(DateTime(2000, 1, 1, hour, minute));

  String get reminderText => DateFormat("h:mm a").format(
    DateTime(2000, 1, 1, hour, minute).subtract(Duration(minutes: leadMinutes)),
  );

  String get daysText {
    if (days.length == 7) return "Every day";
    if (days.isEmpty) return "No days";
    if (days.length == 5 && days.containsAll({1, 2, 3, 4, 5})) {
      return "Weeknights";
    }
    if (days.length == 2 && days.containsAll({6, 7})) return "Weekends";
    const names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    return (days.toList()..sort()).map((d) => names[d - 1]).join(", ");
  }
}

class BedtimeReminder {
  BedtimeReminder._();
  static final BedtimeReminder instance = BedtimeReminder._();

  static const int _baseId = 8100;
  static const int _daysAhead = 14;

  final ValueNotifier<BedtimeSettings> settings =
      ValueNotifier<BedtimeSettings>(const BedtimeSettings());

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection("app_settings").doc("bedtime");

  static const List<String> _tips = [
    "Dim the lights and put your phone face-down.",
    "A few slow breaths: in for 4, hold 4, out for 6.",
    "Pick a calming sound and let ComfortNap warm your pillow.",
    "Keep the room cool, dark and quiet tonight.",
    "Skip the scrolling. Your pillow is waiting.",
    "Write down tomorrow's to-dos so your mind can rest.",
    "A glass of water and a stretch, then lights out.",
  ];

  /// Loads the saved settings and tops up the scheduled reminders.
  Future<void> rescheduleFromSaved() async {
    try {
      final snap = await _doc.get();
      settings.value = BedtimeSettings.fromMap(snap.data());
    } catch (_) {
      // Offline: keep whatever is in memory.
    }
    await _schedule(settings.value);
  }

  Future<void> save(BedtimeSettings s) async {
    settings.value = s;
    if (s.enabled) await AlarmService.instance.requestPermissions();
    await _schedule(s);
    try {
      await _doc.set(s.toMap(), SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _cancelAll() async {
    final plugin = AlarmService.instance.plugin;
    for (var i = 0; i < _daysAhead; i++) {
      await plugin.cancel(_baseId + i);
    }
    await plugin.cancel(bedtimeSnoozeId);
  }

  Future<void> _schedule(BedtimeSettings s) async {
    await AlarmService.instance.init();
    await _cancelAll();
    if (!s.enabled || s.days.isEmpty) return;

    final plugin = AlarmService.instance.plugin;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (var i = 0; i < _daysAhead; i++) {
      final day = today.add(Duration(days: i));
      if (!s.days.contains(day.weekday)) continue;
      final remindAt = s
          .bedtimeOn(day)
          .subtract(Duration(minutes: s.leadMinutes));
      if (!remindAt.isAfter(now)) continue;
      final tip = _tips[(day.difference(DateTime(2024)).inDays) % _tips.length];
      try {
        await scheduleExactOrInexact(
          plugin,
          id: _baseId + i,
          title: "🌙 Bedtime in ${s.leadMinutes} min (${s.bedtimeText})",
          body: tip,
          when: remindAt,
          details: bedtimeNotificationDetails(),
          payload: bedtimePayload,
        );
      } catch (e) {
        debugPrint("Bedtime reminder not scheduled: $e");
      }
    }
  }

  /// Skips tonight's reminder (e.g. a session is already running).
  Future<void> cancelUpcoming({
    Duration within = const Duration(hours: 12),
  }) async {
    final s = settings.value;
    final plugin = AlarmService.instance.plugin;
    await plugin.cancel(bedtimeSnoozeId);
    if (!s.enabled) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (var i = 0; i < 2; i++) {
      final day = today.add(Duration(days: i));
      final remindAt = s
          .bedtimeOn(day)
          .subtract(Duration(minutes: s.leadMinutes));
      if (remindAt.isAfter(now) && remindAt.difference(now) <= within) {
        await plugin.cancel(_baseId + i);
      }
    }
  }

  /// Usual bedtime from the last 30 days of sleep records, rounded to
  /// 5 minutes. Null when there are fewer than 3 nights.
  Future<TimeOfDay?> suggestBedtime() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection("vibrator_logs")
          .where("type", isEqualTo: "sleep")
          .get();
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      double sx = 0, sy = 0;
      var n = 0;
      for (final d in snap.docs) {
        final ts = d.data()["sleep_start"];
        if (ts is! Timestamp) continue;
        final t = ts.toDate();
        if (t.isBefore(cutoff)) continue;
        final a = (t.hour * 60 + t.minute) / 1440 * 2 * math.pi;
        sx += math.cos(a);
        sy += math.sin(a);
        n++;
      }
      if (n < 3) return null;
      var mean = math.atan2(sy, sx);
      if (mean < 0) mean += 2 * math.pi;
      final minutes = (mean / (2 * math.pi) * 1440 / 5).round() * 5 % 1440;
      return TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
    } catch (_) {
      return null;
    }
  }
}

// =====================================================================
// HOME CARD
// =====================================================================
class BedtimeReminderCard extends StatelessWidget {
  const BedtimeReminderCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BedtimeSettings>(
      valueListenable: BedtimeReminder.instance.settings,
      builder: (context, s, _) {
        final on = s.enabled;
        return GestureDetector(
          onTap: () => _openEditor(context),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: on
                    ? [
                        _violet.withValues(alpha: 0.28),
                        _violet.withValues(alpha: 0.28),
                      ]
                    : [_white(0.06), _white(0.06)],
              ),
              border: Border.all(
                color: on ? _violet.withValues(alpha: 0.5) : _white(0.1),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: on
                          ? [_violet, _violet]
                          : [_white(0.12), _white(0.12)],
                    ),
                    boxShadow: on
                        ? [
                            BoxShadow(
                              color: _violet.withValues(alpha: 0.5),
                              blurRadius: 16,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    on
                        ? Icons.notifications_active_rounded
                        : Icons.bedtime_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        on ? "Bedtime ${s.bedtimeText}" : "Bedtime reminder",
                        style: _display(16, FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        on
                            ? "Nudge at ${s.reminderText} · ${s.daysText}"
                            : "Get a nudge before bed",
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: _white(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: on,
                  activeThumbColor: Colors.white,
                  activeTrackColor: _violet,
                  inactiveThumbColor: _white(0.7),
                  inactiveTrackColor: _white(0.12),
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    BedtimeReminder.instance.save(s.copyWith(enabled: v));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openEditor(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _BedtimeSheet(),
    );
  }
}

// =====================================================================
// SETTINGS SHEET
// =====================================================================
class _BedtimeSheet extends StatefulWidget {
  const _BedtimeSheet();

  @override
  State<_BedtimeSheet> createState() => _BedtimeSheetState();
}

class _BedtimeSheetState extends State<_BedtimeSheet> {
  late BedtimeSettings _s;
  TimeOfDay? _suggested;
  bool _loadingSuggestion = true;
  int _pickerKey = 0;

  static const _leads = [5, 10, 15, 30];

  @override
  void initState() {
    super.initState();
    final cur = BedtimeReminder.instance.settings.value;
    _s = cur.copyWith(minute: (cur.minute ~/ 5) * 5);
    BedtimeReminder.instance.suggestBedtime().then((t) {
      if (mounted) {
        setState(() {
          _suggested = t;
          _loadingSuggestion = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottom),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: _white(0.12))),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: _white(0.25),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.bedtime_rounded, color: _amber, size: 24),
                const SizedBox(width: 10),
                Text("Bedtime reminder", style: _display(22, FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "We'll nudge you at ${_s.reminderText} so you're in bed by ${_s.bedtimeText}.",
              style: GoogleFonts.poppins(fontSize: 13, color: _white(0.65)),
            ),
            const SizedBox(height: 14),

            // ---- time picker ----
            Container(
              height: 150,
              decoration: BoxDecoration(
                color: _bg.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _white(0.08)),
              ),
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: Brightness.dark,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: _display(22, FontWeight.w600),
                  ),
                ),
                child: CupertinoDatePicker(
                  key: ValueKey(_pickerKey),
                  mode: CupertinoDatePickerMode.time,
                  minuteInterval: 5,
                  initialDateTime: DateTime(2000, 1, 1, _s.hour, _s.minute),
                  onDateTimeChanged: (d) => setState(
                    () => _s = _s.copyWith(hour: d.hour, minute: d.minute),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _suggestionChip(),
            const SizedBox(height: 18),

            _label("REMIND ME"),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final m in _leads) ...[
                  Expanded(
                    child: _chip(
                      "$m min",
                      selected: _s.leadMinutes == m,
                      onTap: () =>
                          setState(() => _s = _s.copyWith(leadMinutes: m)),
                    ),
                  ),
                  if (m != _leads.last) const SizedBox(width: 8),
                ],
              ],
            ),
            const SizedBox(height: 18),

            _label("REPEAT  ·  ${_s.daysText.toUpperCase()}"),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (i, d) in const [
                  (7, "S"),
                  (1, "M"),
                  (2, "T"),
                  (3, "W"),
                  (4, "T"),
                  (5, "F"),
                  (6, "S"),
                ].indexed) ...[
                  Expanded(child: _dayChip(d.$1, d.$2)),
                  if (i != 6) const SizedBox(width: 6),
                ],
              ],
            ),
            const SizedBox(height: 22),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(colors: [_violet, _violet]),
                  boxShadow: [
                    BoxShadow(
                      color: _violet.withValues(alpha: 0.45),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: TextButton(
                  style: TextButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: _s.days.isEmpty ? null : _save,
                  child: Text(
                    _s.days.isEmpty ? "Pick at least one day" : "Save reminder",
                    style: _display(16, FontWeight.w700),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    HapticFeedback.mediumImpact();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await BedtimeReminder.instance.save(_s.copyWith(enabled: true));
    nav.pop();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: _surface,
        behavior: SnackBarBehavior.floating,
        content: Text(
          "🌙 Reminder set for ${_s.reminderText} · ${_s.daysText}",
          style: GoogleFonts.poppins(color: Colors.white),
        ),
      ),
    );
  }

  Widget _suggestionChip() {
    if (_loadingSuggestion) {
      return Text(
        "Looking at your recent nights…",
        style: GoogleFonts.poppins(fontSize: 12, color: _white(0.45)),
      );
    }
    final t = _suggested;
    if (t == null) {
      return Text(
        "Sleep 3+ nights with ComfortNap and we'll suggest your usual bedtime.",
        style: GoogleFonts.poppins(fontSize: 12, color: _white(0.45)),
      );
    }
    final label = DateFormat(
      "h:mm a",
    ).format(DateTime(2000, 1, 1, t.hour, t.minute));
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          _s = _s.copyWith(hour: t.hour, minute: t.minute);
          _pickerKey++;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: _cyan.withValues(alpha: 0.1),
          border: Border.all(color: _cyan.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_rounded, color: _cyan, size: 16),
            const SizedBox(width: 8),
            Text(
              "Use my usual bedtime · $label",
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _cyan,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t) => Text(
    t,
    style: GoogleFonts.poppins(
      fontSize: 11,
      letterSpacing: 1.6,
      fontWeight: FontWeight.w600,
      color: _white(0.5),
    ),
  );

  Widget _chip(
    String text, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: selected
              ? const LinearGradient(colors: [_violet, _violet])
              : null,
          color: selected ? null : _white(0.06),
          border: Border.all(
            color: selected ? Colors.transparent : _white(0.1),
          ),
        ),
        child: Text(
          text,
          style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : _white(0.7),
          ),
        ),
      ),
    );
  }

  Widget _dayChip(int weekday, String letter) {
    final on = _s.days.contains(weekday);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        final next = Set<int>.from(_s.days);
        on ? next.remove(weekday) : next.add(weekday);
        setState(() => _s = _s.copyWith(days: next));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: on
              ? const LinearGradient(colors: [_violet, _violet])
              : null,
          color: on ? null : _white(0.06),
          border: Border.all(color: on ? Colors.transparent : _white(0.12)),
        ),
        child: Text(
          letter,
          style: _display(14, FontWeight.w700, on ? Colors.white : _white(0.6)),
        ),
      ),
    );
  }
}
