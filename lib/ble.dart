import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:esp32_ble_app/ble_man.dart';
import 'package:google_fonts/google_fonts.dart';

// NOTE: This file used to have its own main()/MyApp here, but main.dart
// already defines MyApp and is the app's real entry point. Having two
// classes named MyApp in the same package fails to compile, so this
// screen now only exposes BleHomePage for main.dart to push onto the nav stack.

class BleHomePage extends StatefulWidget {
  const BleHomePage({super.key});

  @override
  State<BleHomePage> createState() => _BleHomePageState();
}

class _BleHomePageState extends State<BleHomePage>
    with TickerProviderStateMixin {
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  late final AnimationController _radar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  final List<ScanResult> _scanResults = [];
  final List<String> _log = [];

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  bool _scanning = false;
  bool _connecting = false;
  bool _disposed = false;

  /// Device being connected right now (only its button spins).
  String? _connectingId;

  /// When the current scan started (drives the countdown ring).
  DateTime? _scanStartedAt;
  static const _scanSeconds = 6;

  /// Hide devices with no name (most are phones, watches, TVs…).
  bool _showUnnamed = false;

  /// "Can't find your pillow?" help is open.
  bool _helpOpen = false;

  /// Activity log is expanded.
  bool _logOpen = false;

  /// Phone Bluetooth on/off.
  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  @override
  void initState() {
    super.initState();
    _adapterSub = FlutterBluePlus.adapterState.listen((st) {
      if (!mounted || _disposed) return;
      final wasOff = _adapter == BluetoothAdapterState.off;
      setState(() => _adapter = st);
      if (wasOff && st == BluetoothAdapterState.on) {
        _addLog("Bluetooth turned on · tap Scan to look for your pillow");
      }
    });
    // Scanning is manual: it only starts when you tap "Scan for devices".
  }

  bool get _bluetoothOff => _adapter == BluetoothAdapterState.off;

  /// Looks like a ComfortNap pillow (ESP32 board).
  static bool _isPillow(ScanResult r) {
    final n = r.device.name.toLowerCase();
    return n.contains("comfort") ||
        n.contains("nap") ||
        n.contains("pillow") ||
        n.contains("esp32");
  }

  /// Pillows first, then strongest signal.
  List<ScanResult> get _sorted {
    final list = [..._scanResults]
      ..sort((a, b) {
        final pa = _isPillow(a) ? 0 : 1, pb = _isPillow(b) ? 0 : 1;
        if (pa != pb) return pa - pb;
        return b.rssi.compareTo(a.rssi);
      });
    return list;
  }

  // ================= PERMISSIONS =================
  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;

    await Permission.locationWhenInUse.request();

    try {
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
    } catch (_) {}
  }

  // ================= SCAN =================
  Future<void> _startScan() async {
    if (!mounted || _disposed) return;

    await _scanSub?.cancel();
    _scanSub = null;
    await _scanningSub?.cancel();
    _scanningSub = null;
    if (!mounted || _disposed) return;

    setState(() {
      _scanResults.clear();
      _scanning = true;
      _scanStartedAt = DateTime.now();
    });
    _addLog("Scanning…");

    await _ensurePermissions();
    if (!mounted || _disposed) return;

    await FlutterBluePlus.stopScan();
    if (!mounted || _disposed) return;

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted || _disposed) return;
      setState(() {
        _scanResults
          ..clear()
          ..addAll(results);
      });
    });

    _scanningSub = FlutterBluePlus.isScanning.listen((s) {
      if (!mounted || _disposed) return;
      setState(() => _scanning = s);
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: _scanSeconds),
      );
    } catch (e) {
      _addLog("Scan failed ❌ $e");
      if (mounted) setState(() => _scanning = false);
    }
  }

  // ================= CONNECT =================
  Future<void> _connect(ScanResult r) async {
    if (_connecting) return;
    HapticFeedback.mediumImpact();
    await FlutterBluePlus.stopScan();
    setState(() {
      _connecting = true;
      _connectingId = r.device.id.toString();
    });
    _addLog("Connecting → ${r.device.name}");
    try {
      await BLEManager.instance.connect(r.device);
      if (!mounted) return;
      _addLog("Connected ✔ ${r.device.name}");

      // Report the connected device back to whoever pushed this screen
      // (main.dart awaits this to know when to update ble_status).
      Navigator.pop(context, r.device);
    } catch (e) {
      _addLog("Failed ❌ $e");
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectingId = null;
        });
      }
    }
  }

  void _addLog(String msg) {
    if (!mounted) return;
    final now = DateTime.now();
    final t =
        "${now.hour.toString().padLeft(2, '0')}:"
        "${now.minute.toString().padLeft(2, '0')}:"
        "${now.second.toString().padLeft(2, '0')}";
    setState(() => _log.insert(0, "$t  $msg"));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_scanSub?.cancel());
    unawaited(_scanningSub?.cancel());
    unawaited(_adapterSub?.cancel());
    unawaited(FlutterBluePlus.stopScan());
    _ambient.dispose();
    _radar.dispose();
    super.dispose();
  }

  // ================= UI ACTIONS =================
  void _toggleScan() {
    HapticFeedback.selectionClick();
    if (_bluetoothOff) {
      _turnOnBluetooth();
      return;
    }
    if (_scanning) {
      FlutterBluePlus.stopScan();
      _addLog("Scan stopped");
    } else {
      _startScan();
    }
  }

  Future<void> _turnOnBluetooth() async {
    try {
      if (Platform.isAndroid) await FlutterBluePlus.turnOn();
    } catch (e) {
      _addLog("Couldn't turn on Bluetooth: $e");
    }
  }

  // ================= HELPERS =================
  ({String label, Color color, int level}) _signal(int rssi) {
    if (rssi >= -60) return (label: "Excellent", color: _green, level: 4);
    if (rssi >= -70) return (label: "Good", color: _green, level: 3);
    if (rssi >= -80) return (label: "Fair", color: _amber, level: 2);
    return (label: "Weak", color: _rose, level: 1);
  }

  // ================= DEVICE CARD =================
  Widget _deviceCard(ScanResult r, {bool featured = false}) {
    final named = r.device.name.isNotEmpty;
    final name = named ? r.device.name : "Unknown device";
    final pillow = _isPillow(r);
    final sig = _signal(r.rssi);
    final busy = _connectingId == r.device.id.toString();
    final tint = pillow ? _violet : Colors.white;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _Press3D(
        onTap: _connecting ? () {} : () => _connect(r),
        child: Container(
          padding: EdgeInsets.all(featured ? 14 : 12),
          decoration: pillow
              ? _panel3D(_violet, radius: 22, strength: 1.3)
              : _glass(radius: 20),
          foregroundDecoration: _shine3D(radius: featured ? 22 : 20, a: .06),
          child: Column(
            children: [
              Row(
                children: [
                  // Glossy device key
                  Container(
                    width: featured ? 52 : 44,
                    height: featured ? 52 : 44,
                    decoration: pillow
                        ? _gloss3D(_violet, radius: 16, gradient: _mainGradient)
                        : _sunk3D(radius: 14),
                    foregroundDecoration: pillow
                        ? _shine3D(radius: 16)
                        : null,
                    child: Icon(
                      pillow ? Icons.bed_rounded : Icons.bluetooth_rounded,
                      color: pillow ? Colors.white : _white(named ? .7 : .4),
                      size: featured ? 26 : 21,
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
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _display(
                                  featured ? 17 : 14.5,
                                  weight: FontWeight.w700,
                                  color: named ? Colors.white : _white(.55),
                                ),
                              ),
                            ),
                            if (pillow && !featured) ...[
                              const SizedBox(width: 6),
                              _badge("PILLOW", _cyan),
                            ],
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            _SignalBars(level: sig.level, color: sig.color),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                "${sig.label} · ${r.rssi} dBm",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                style: TextStyle(
                                  color: sig.color.withValues(alpha: .9),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Connect key
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _connecting && !busy ? .4 : 1,
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: pillow || busy
                          ? _gloss3D(_violet, radius: 13, gradient: _mainGradient)
                          : _key3D(Colors.white, radius: 13),
                      foregroundDecoration: pillow || busy
                          ? _shine3D(radius: 13)
                          : null,
                      child: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              "Connect",
                              style: TextStyle(
                                color: pillow ? Colors.white : _white(.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
              if (featured) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: _sunk3D(radius: 12),
                  child: Row(
                    children: [
                      _badge("PILLOW", _cyan),
                      const SizedBox(width: 8),
                      Icon(Icons.memory_rounded, size: 14, color: _white(.45)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          r.device.id.toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10.5,
                            color: _white(.5),
                          ),
                        ),
                      ),
                      Icon(
                        sig.level <= 1
                            ? Icons.social_distance_rounded
                            : Icons.touch_app_rounded,
                        size: 14,
                        color: sig.level <= 1 ? _amber : _cyan,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        sig.level <= 1 ? "Move closer" : "Tap to pair",
                        style: TextStyle(
                          color: (sig.level <= 1 ? _amber : _cyan).withValues(
                            alpha: .9,
                          ),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: _panel3D(c, radius: 6, strength: 1.4),
    child: Text(
      text,
      style: TextStyle(
        color: c,
        fontSize: 8.5,
        letterSpacing: .9,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  // ================= EMPTY STATE =================
  Widget _emptyState({int hidden = 0}) {
    final IconData icon;
    final String title, sub;
    if (_bluetoothOff) {
      icon = Icons.bluetooth_disabled_rounded;
      title = "Bluetooth is off";
      sub = "Turn it on to find your pillow";
    } else if (_scanning) {
      icon = Icons.radar_rounded;
      title = "Looking around…";
      sub = "Keep the pillow powered on and close by";
    } else if (hidden > 0) {
      icon = Icons.visibility_off_rounded;
      title = "No named devices";
      sub = "$hidden unnamed ${hidden == 1 ? 'device is' : 'devices are'} hidden";
    } else {
      icon = Icons.bluetooth_searching_rounded;
      title = "No devices found";
      sub = "Tap Scan to look again";
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: _glass(radius: 22),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: _sunk3D(radius: 26),
            child: Icon(icon, size: 24, color: _white(.45)),
          ),
          const SizedBox(height: 12),
          Text(title, style: _display(15.5, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: TextStyle(color: _white(.5), fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  // ================= BLUETOOTH OFF BANNER =================
  Widget _bluetoothBanner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: _panel3D(_rose, radius: 20, strength: 1.2),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: _gloss3D(_rose, radius: 12),
            foregroundDecoration: _shine3D(radius: 12),
            child: const Icon(
              Icons.bluetooth_disabled_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Bluetooth is off", style: _display(15, weight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  "The pillow connects over Bluetooth",
                  style: TextStyle(color: _white(.6), fontSize: 12),
                ),
              ],
            ),
          ),
          if (Platform.isAndroid)
            _Press3D(
              onTap: _turnOnBluetooth,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: _gloss3D(_rose, radius: 12),
                foregroundDecoration: _shine3D(radius: 12),
                child: const Text(
                  "Turn on",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ================= HELP =================
  Widget _helpCard() {
    const tips = [
      (Icons.power_settings_new_rounded, "Turn the pillow on", "Its board needs USB or battery power."),
      (Icons.social_distance_rounded, "Bring the phone close", "Within about 2 metres works best."),
      (Icons.link_off_rounded, "Disconnect other phones", "The pillow pairs with one phone at a time."),
      (Icons.location_on_rounded, "Allow Location & Nearby devices", "Android needs these to scan."),
      (Icons.restart_alt_rounded, "Restart the pillow", "Unplug it for 5 seconds, then scan again."),
    ];
    return Container(
      decoration: _glass(radius: 20),
      child: Column(
        children: [
          _Press3D(
            onTap: () => setState(() => _helpOpen = !_helpOpen),
            travel: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: _gloss3D(_amber, radius: 10),
                    foregroundDecoration: _shine3D(radius: 10),
                    child: const Icon(Icons.lightbulb_rounded, color: Colors.white, size: 17),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Can't find your pillow?",
                      style: _display(15, weight: FontWeight.w600),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _helpOpen ? .5 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: Icon(Icons.expand_more_rounded, color: _white(.6)),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: !_helpOpen
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Column(
                      children: [
                        for (int i = 0; i < tips.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  alignment: Alignment.center,
                                  decoration: _sunk3D(radius: 9),
                                  child: Text(
                                    "${i + 1}",
                                    style: _display(12, weight: FontWeight.w700, color: _amber),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(tips[i].$1, size: 14, color: _white(.75)),
                                          const SizedBox(width: 5),
                                          Text(
                                            tips[i].$2,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        tips[i].$3,
                                        style: TextStyle(color: _white(.5), fontSize: 11.5),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
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

  // ================= LOG PANEL =================
  Widget _logPanel() {
    return Container(
      decoration: _glass(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Press3D(
            onTap: () => setState(() => _logOpen = !_logOpen),
            travel: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: _gloss3D(_cyan.withValues(alpha: 1), radius: 10,
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF6EE7F9), Color(0xFF1597B5)],
                        )),
                    foregroundDecoration: _shine3D(radius: 10),
                    child: const Icon(Icons.terminal_rounded, color: Colors.white, size: 16),
                  ),
                  const SizedBox(width: 10),
                  Text("Activity", style: _display(15)),
                  const SizedBox(width: 8),
                  if (_log.isNotEmpty) _badge("${_log.length}", _cyan),
                  const Spacer(),
                  if (_logOpen && _log.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(_log.clear),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          "Clear",
                          style: TextStyle(color: _white(.55), fontSize: 12),
                        ),
                      ),
                    ),
                  AnimatedRotation(
                    turns: _logOpen ? .5 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: Icon(Icons.expand_more_rounded, color: _white(.6)),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: !_logOpen
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Container(
                      height: 120,
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: _sunk3D(radius: 12),
                      child: _log.isEmpty
                          ? Center(
                              child: Text(
                                "No activity yet",
                                style: TextStyle(color: _white(.35), fontSize: 12),
                              ),
                            )
                          : ListView.builder(
                              padding: EdgeInsets.zero,
                              itemCount: _log.length,
                              itemBuilder: (_, i) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  "› ${_log[i]}",
                                  style: GoogleFonts.jetBrainsMono(
                                    color: i == 0 ? _cyan : _white(.5),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ================= RADAR HERO =================
  Widget _radarHero() {
    final pillows = _scanResults.where(_isPillow).length;
    final count = _scanResults.length;
    final title = _bluetoothOff
        ? "Bluetooth is off"
        : _connecting
        ? "Connecting…"
        : pillows > 0
        ? "Pillow found"
        : _scanning
        ? "Scanning…"
        : count > 0
        ? "$count ${count == 1 ? 'device' : 'devices'} nearby"
        : "Ready to scan";
    final subtitle = _bluetoothOff
        ? "Turn on Bluetooth to look for your pillow"
        : _connecting
        ? "Hold on while we pair with your pillow"
        : pillows > 0
        ? "Tap it below to connect"
        : _scanning
        ? "Looking for your ComfortNap pillow"
        : "Make sure your pillow is on and nearby";
    final accent = _bluetoothOff
        ? _rose
        : pillows > 0 && !_scanning
        ? _green
        : _violet;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: _panel3D(accent, radius: 30, strength: 1.5),
      foregroundDecoration: _shine3D(radius: 30, a: .07),
      child: Column(
        children: [
          // Status chip
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: _panel3D(accent, radius: 20, strength: 1.4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _scanning || _connecting ? _cyan : accent,
                      border: Border.all(color: _white(.4), width: .8),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _bluetoothOff
                        ? "BT OFF"
                        : _connecting
                        ? "PAIRING"
                        : _scanning
                        ? "LIVE"
                        : "IDLE",
                    style: TextStyle(
                      color: _white(.85),
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 180,
            height: 180,
            child: AnimatedBuilder(
              animation: _radar,
              builder: (context, _) {
                final started = _scanStartedAt;
                final countdown = _scanning && started != null
                    ? (DateTime.now().difference(started).inMilliseconds /
                              (_scanSeconds * 1000))
                          .clamp(0.0, 1.0)
                    : null;
                return CustomPaint(
                  painter: _RadarPainter(
                    progress: _radar.value,
                    active: _scanning || _connecting,
                    countdown: countdown,
                    blips: [
                      for (final (i, r) in _sorted.take(12).indexed)
                        (
                          // Golden-angle spread so dots never stack up;
                          // distance from the centre = weaker signal.
                          (i * 0.381966 + .12) % 1.0,
                          (.52 + ((-r.rssi - 45) / 50).clamp(0.0, 1.0) * .4)
                              .toDouble(),
                          _isPillow(r),
                        ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: _gloss3D(
                        accent,
                        circle: true,
                        gradient: _bluetoothOff
                            ? null
                            : pillows > 0 && !_scanning
                            ? const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xFF6EE7B7), Color(0xFF10B981)],
                              )
                            : _mainGradient,
                      ),
                      foregroundDecoration: _shine3D(circle: true, a: .3),
                      child: Icon(
                        _bluetoothOff
                            ? Icons.bluetooth_disabled_rounded
                            : pillows > 0 && !_scanning
                            ? Icons.bed_rounded
                            : _scanning
                            ? Icons.bluetooth_searching_rounded
                            : Icons.bluetooth_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              title,
              key: ValueKey(title),
              style: _display(22, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: _white(.6), fontSize: 12.5),
          ),
          const SizedBox(height: 18),
          _Press3D(
            onTap: _connecting ? () {} : _toggleScan,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              height: 52,
              decoration: _scanning
                  ? _key3D(Colors.white, radius: 18)
                  : _gloss3D(
                      _bluetoothOff ? _rose : _violet,
                      radius: 18,
                      gradient: _bluetoothOff ? null : _mainGradient,
                    ),
              foregroundDecoration: _scanning ? null : _shine3D(radius: 18, a: .22),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _bluetoothOff
                        ? Icons.bluetooth_rounded
                        : _scanning
                        ? Icons.stop_rounded
                        : _scanResults.isEmpty
                        ? Icons.search_rounded
                        : Icons.refresh_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _bluetoothOff
                        ? "Turn on Bluetooth"
                        : _scanning
                        ? "Stop scanning"
                        : _scanResults.isEmpty
                        ? "Scan for devices"
                        : "Scan again",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
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

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    final sorted = _sorted;
    final pillows = [for (final r in sorted) if (_isPillow(r)) r];
    final others = [
      for (final r in sorted)
        if (!_isPillow(r) && (_showUnnamed || r.device.name.isNotEmpty)) r,
    ];
    final hidden = sorted
        .where((r) => !_isPillow(r) && r.device.name.isEmpty)
        .length;

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(child: _Aurora(animation: _ambient)),
          SafeArea(
            bottom: false,
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
              children: [
                // Header
                Row(
                  children: [
                    _Press3D(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: _glass(radius: 16),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  "PAIR YOUR PILLOW",
                  style: _eyebrow(color: _cyan.withValues(alpha: .85)),
                ),
                const SizedBox(height: 8),
                Text(
                  "Connect your pillow",
                  style: _display(32, weight: FontWeight.w700),
                ),
                const SizedBox(height: 20),

                if (_bluetoothOff) ...[
                  _bluetoothBanner(),
                  const SizedBox(height: 14),
                ],

                _radarHero(),

                if (pillows.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  _sectionTitle("Your pillow", pillows.length, _green),
                  const SizedBox(height: 12),
                  for (final r in pillows) _deviceCard(r, featured: true),
                ],

                const SizedBox(height: 26),
                Row(
                  children: [
                    Expanded(
                      child: _sectionTitle(
                        pillows.isEmpty ? "Nearby devices" : "Other devices",
                        others.length,
                        _violet,
                      ),
                    ),
                    if (hidden > 0 || _showUnnamed)
                      _Press3D(
                        onTap: () => setState(() => _showUnnamed = !_showUnnamed),
                        travel: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: _key3D(Colors.white, radius: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _showUnnamed
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded,
                                size: 14,
                                color: _white(.7),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _showUnnamed ? "Hide unnamed" : "Show $hidden unnamed",
                                style: TextStyle(
                                  color: _white(.75),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                if (others.isEmpty && pillows.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: _sunk3D(radius: 16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 16,
                          color: _white(.45),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            hidden > 0 && !_showUnnamed
                                ? "Only unnamed devices nearby"
                                : "No other devices nearby",
                            style: TextStyle(color: _white(.5), fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (others.isEmpty)
                  _emptyState(hidden: _showUnnamed ? 0 : hidden)
                else
                  for (final r in others) _deviceCard(r),

                const SizedBox(height: 16),
                _helpCard(),
                const SizedBox(height: 12),
                _logPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, int count, Color c) {
    return Row(
      children: [
        Text(text, style: _display(20)),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: _key3D(c, radius: 10),
          child: Text(
            "$count",
            style: TextStyle(
              color: _white(.85),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// DESIGN TOKENS (match the other redesigned screens)
// =====================================================================
const Color _bg = Color(0xFF07031F);
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);
const Color _green = Color(0xFF34D399);
const Color _amber = Color(0xFFFFB547);
const Color _rose = Color(0xFFFF6F91);

// Lit from the top so fills read as glossy 3D surfaces.
const LinearGradient _mainGradient = LinearGradient(
  colors: [Color(0xFF8C7DFF), Color(0xFF2FB8E6)],
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

// ---------- No-shadow 3D helpers ----------
/// Raised glass: lit top, darker base, bright rim.
BoxDecoration _glass({double radius = 24}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [_white(.12), _white(.03)],
  ),
  border: Border.all(color: _white(.14)),
);

/// Raised tinted panel.
BoxDecoration _panel3D(Color c, {double radius = 20, double strength = 1}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(c, Colors.white, .1)!.withValues(alpha: .26 * strength),
          c.withValues(alpha: .07 * strength),
        ],
      ),
      border: Border.all(color: c.withValues(alpha: .4)),
    );

/// Raised key / chip.
BoxDecoration _key3D(Color c, {double radius = 12}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.lerp(c, Colors.white, .14)!.withValues(alpha: .26),
      c.withValues(alpha: .07),
    ],
  ),
  border: Border.all(color: _white(.16)),
);

/// Glossy solid key: lit top, deeper base, bright rim.
BoxDecoration _gloss3D(
  Color c, {
  double radius = 12,
  bool circle = false,
  Gradient? gradient,
}) => BoxDecoration(
  shape: circle ? BoxShape.circle : BoxShape.rectangle,
  borderRadius: circle ? null : BorderRadius.circular(radius),
  gradient:
      gradient ??
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(c, Colors.white, .28)!, Color.lerp(c, Colors.black, .2)!],
      ),
  border: Border.all(color: _white(.3)),
);

/// Top-half shine painted over a face.
BoxDecoration _shine3D({double radius = 12, bool circle = false, double a = .24}) =>
    BoxDecoration(
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_white(a), _white(0)],
        stops: const [0, .5],
      ),
    );

/// Recessed well.
BoxDecoration _sunk3D({double radius = 10}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.black.withValues(alpha: .42), _white(.05)],
  ),
  border: Border.all(color: _white(.08)),
);

// =====================================================================
// SMALL WIDGETS
// =====================================================================

/// Any 3D key that sinks a little while pressed.
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
      child: AnimatedScale(
        scale: _down ? .98 : 1,
        duration: const Duration(milliseconds: 110),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _down ? widget.travel : 0),
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          builder: (context, dy, child) =>
              Transform.translate(offset: Offset(0, dy), child: child),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 4-bar signal strength (3D capsules, no glow).
class _SignalBars extends StatelessWidget {
  final int level; // 1..4
  final Color color;
  const _SignalBars({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (int i = 0; i < 4; i++)
          Container(
            width: 4,
            height: 5.0 + i * 3,
            margin: const EdgeInsets.only(right: 2),
            decoration: i < level
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(1.5),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color.lerp(color, Colors.white, .35)!, color],
                    ),
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(1.5),
                    color: Colors.black.withValues(alpha: .35),
                    border: Border.all(color: _white(.1), width: .6),
                  ),
          ),
      ],
    );
  }
}

/// Radar dish: recessed rings, sweeping beam, expanding pulses, device
/// blips (pillows in green) and a scan countdown ring. No blur / glow.
class _RadarPainter extends CustomPainter {
  final double progress;
  final bool active;
  final double? countdown; // 0..1 while a scan runs
  final List<(double, double, bool)> blips; // (angle 0..1, distance 0..1, pillow)
  _RadarPainter({
    required this.progress,
    required this.active,
    this.countdown,
    this.blips = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.shortestSide / 2 - 6;

    // Recessed dish: dark at the top, lighter at the bottom lip.
    final dish = Rect.fromCircle(center: center, radius: maxR);
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: .38), _white(.04)],
        ).createShader(dish),
    );
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _white(.12),
    );

    // Guide rings + cross hairs
    for (final f in const [.45, .7]) {
      canvas.drawCircle(
        center,
        maxR * f,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _white(.08),
      );
    }
    final hair = Paint()
      ..color = _white(.06)
      ..strokeWidth = 1;
    canvas.drawLine(center.translate(-maxR, 0), center.translate(maxR, 0), hair);
    canvas.drawLine(center.translate(0, -maxR), center.translate(0, maxR), hair);

    if (active) {
      // Sweeping beam
      final angle = progress * 2 * math.pi;
      canvas.drawArc(
        dish,
        angle - 1.0,
        1.0,
        true,
        Paint()
          ..shader = SweepGradient(
            startAngle: angle - 1.0,
            endAngle: angle,
            colors: [_cyan.withValues(alpha: 0), _cyan.withValues(alpha: .3)],
          ).createShader(dish),
      );
      canvas.drawLine(
        center,
        center + Offset(math.cos(angle), math.sin(angle)) * maxR,
        Paint()
          ..color = _cyan.withValues(alpha: .7)
          ..strokeWidth = 1.5,
      );

      // Expanding pulses
      for (int i = 0; i < 3; i++) {
        final t = (progress + i / 3) % 1.0;
        canvas.drawCircle(
          center,
          maxR * (.4 + .6 * t),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = _cyan.withValues(alpha: (1 - t) * .45),
        );
      }
    }

    // Device blips: glossy beads
    for (final b in blips) {
      final a = b.$1 * 2 * math.pi;
      final p = center + Offset(math.cos(a), math.sin(a)) * (maxR * b.$2);
      final c = b.$3 ? _green : _white(.75);
      final r = b.$3 ? 5.5 : 3.5;
      canvas.drawCircle(p, r + 1.2, Paint()..color = _bg.withValues(alpha: .7));
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.4, -.4),
            colors: [Colors.white, c],
          ).createShader(Rect.fromCircle(center: p, radius: r)),
      );
    }

    // Scan countdown ring around the dish
    if (countdown != null) {
      final ring = Rect.fromCircle(center: center, radius: maxR + 4);
      canvas.drawArc(
        ring,
        -math.pi / 2,
        2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.black.withValues(alpha: .3),
      );
      canvas.drawArc(
        ring,
        -math.pi / 2,
        2 * math.pi * (1 - countdown!),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = _cyan,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
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
