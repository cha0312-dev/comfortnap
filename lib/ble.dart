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
    });

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

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
  }

  // ================= CONNECT =================
  Future<void> _connect(ScanResult r) async {
    if (_connecting) return;
    setState(() => _connecting = true);
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
        setState(() => _connecting = false);
      }
    }
  }

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_scanSub?.cancel());
    unawaited(_scanningSub?.cancel());
    unawaited(FlutterBluePlus.stopScan());
    _ambient.dispose();
    _radar.dispose();
    super.dispose();
  }

  // ================= UI ACTIONS =================
  void _toggleScan() {
    HapticFeedback.selectionClick();
    if (_scanning) {
      FlutterBluePlus.stopScan();
    } else {
      _startScan();
    }
  }

  // ================= DEVICE CARD =================
  Widget _deviceCard(ScanResult r) {
    final name = r.device.name.isNotEmpty ? r.device.name : "Unknown Device";
    final named = r.device.name.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: _glass(radius: 20),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: named ? _mainGradient : null,
              color: named ? null : _white(.07),
              borderRadius: BorderRadius.circular(15),
              boxShadow: named
                  ? [
                      BoxShadow(
                        color: _violet.withValues(alpha: .4),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              Icons.bluetooth_rounded,
              color: named ? Colors.white : _white(.6),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: named ? Colors.white : _white(.6),
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _SignalBars(rssi: r.rssi),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        r.device.id.toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10.5,
                          color: _white(.45),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          GestureDetector(
            onTap: _connecting ? null : () => _connect(r),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _connecting ? .5 : 1,
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  gradient: _mainGradient,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: _violet.withValues(alpha: .4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: _connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        "Connect",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ================= EMPTY STATE =================
  Widget _emptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      decoration: _glass(radius: 22),
      child: Column(
        children: [
          Icon(
            _scanning ? Icons.radar_rounded : Icons.bluetooth_searching_rounded,
            size: 30,
            color: _white(.35),
          ),
          const SizedBox(height: 10),
          Text(
            _scanning ? "Scanning nearby devices..." : "No BLE devices found",
            style: _display(15),
          ),
          const SizedBox(height: 4),
          Text(
            _scanning
                ? "Keep the pillow powered on and close by"
                : "Tap scan button to start",
            textAlign: TextAlign.center,
            style: TextStyle(color: _white(.5), fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  // ================= LOG PANEL =================
  Widget _logPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: _glass(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal_rounded, color: _cyan, size: 18),
              const SizedBox(width: 8),
              Text("Activity", style: _display(15)),
              const Spacer(),
              if (_log.isNotEmpty)
                Text(
                  "${_log.length} ${_log.length == 1 ? 'event' : 'events'}",
                  style: TextStyle(color: _white(.4), fontSize: 11),
                ),
            ],
          ),

          const SizedBox(height: 10),

          Container(
            height: 96,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .25),
              borderRadius: BorderRadius.circular(12),
            ),
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
        ],
      ),
    );
  }

  // ================= RADAR HERO =================
  Widget _radarHero() {
    final count = _scanResults.length;
    final title = _connecting
        ? "Connecting..."
        : _scanning
        ? "Scanning..."
        : count > 0
        ? "$count ${count == 1 ? 'device' : 'devices'} found"
        : "Ready to scan";
    final subtitle = _connecting
        ? "Hold on while we pair with your pillow"
        : _scanning
        ? "Looking for nearby Bluetooth devices"
        : "Make sure your pillow is on and nearby";

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
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
            blurRadius: 36,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            width: 170,
            height: 170,
            child: AnimatedBuilder(
              animation: _radar,
              builder: (context, _) {
                return CustomPaint(
                  painter: _RadarPainter(
                    progress: _radar.value,
                    active: _scanning || _connecting,
                  ),
                  child: Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: _mainGradient,
                        boxShadow: [
                          BoxShadow(
                            color: _cyan.withValues(
                              alpha: _scanning ? .55 : .3,
                            ),
                            blurRadius: 26,
                          ),
                        ],
                      ),
                      child: Icon(
                        _scanning
                            ? Icons.bluetooth_searching_rounded
                            : Icons.bluetooth_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
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
            style: TextStyle(color: _white(.55), fontSize: 12.5),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: Material(
              color: Colors.transparent,
              child: Ink(
                decoration: _scanning
                    ? BoxDecoration(
                        color: _white(.08),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _white(.15)),
                      )
                    : BoxDecoration(
                        gradient: _mainGradient,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: _violet.withValues(alpha: .45),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                child: InkWell(
                  onTap: _toggleScan,
                  borderRadius: BorderRadius.circular(18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _scanning ? Icons.stop_rounded : Icons.search_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _scanning ? "Stop scanning" : "Scan for devices",
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
            ),
          ),
        ],
      ),
    );
  }

  // ================= UI =================
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
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
              children: [
                // Header
                Row(
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
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  "BLE SCANNER",
                  style: _eyebrow(color: _cyan.withValues(alpha: .85)),
                ),
                const SizedBox(height: 8),
                Text(
                  "Connect your pillow",
                  style: _display(32, weight: FontWeight.w700),
                ),
                const SizedBox(height: 20),

                _radarHero(),

                const SizedBox(height: 26),
                Row(
                  children: [
                    Text("Nearby devices", style: _display(20)),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: _white(.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        "${_scanResults.length}",
                        style: TextStyle(
                          color: _white(.8),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                if (_scanResults.isEmpty)
                  _emptyState()
                else
                  for (final r in _scanResults) _deviceCard(r),

                const SizedBox(height: 16),
                _logPanel(),
              ],
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
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);
const Color _green = Color(0xFF34D399);
const Color _amber = Color(0xFFFFB547);

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

// =====================================================================
// SMALL WIDGETS
// =====================================================================

/// 4-bar signal strength from RSSI.
class _SignalBars extends StatelessWidget {
  final int rssi;
  const _SignalBars({required this.rssi});

  @override
  Widget build(BuildContext context) {
    final level = rssi >= -60
        ? 4
        : rssi >= -70
        ? 3
        : rssi >= -80
        ? 2
        : 1;
    final color = level >= 3 ? _green : (level == 2 ? _amber : _white(.5));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (int i = 0; i < 4; i++)
          Container(
            width: 3,
            height: 4.0 + i * 2.5,
            margin: const EdgeInsets.only(right: 1.5),
            decoration: BoxDecoration(
              color: i < level ? color : _white(.15),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

/// Expanding radar rings around the centre icon.
class _RadarPainter extends CustomPainter {
  final double progress;
  final bool active;
  _RadarPainter({required this.progress, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.shortestSide / 2;

    // Static guide rings
    for (final f in const [.55, .78, 1.0]) {
      canvas.drawCircle(
        center,
        maxR * f - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _white(.08),
      );
    }

    if (!active) return;

    // Sweeping beam
    final sweepRect = Rect.fromCircle(center: center, radius: maxR - 1);
    final angle = progress * 2 * math.pi;
    canvas.drawArc(
      sweepRect,
      angle - .9,
      .9,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: angle - .9,
          endAngle: angle,
          colors: [_cyan.withValues(alpha: 0), _cyan.withValues(alpha: .28)],
        ).createShader(sweepRect),
    );

    // Expanding pulses
    for (int i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final r = maxR * (.38 + .62 * t);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _cyan.withValues(alpha: (1 - t) * .55),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress || old.active != active;
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
