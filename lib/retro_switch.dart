import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bold "neo-brutalist" toggle: a rounded track with a thick black outline
/// and a hard black drop shadow, plus a white square knob that sits a
/// little above the track. Off = light track, knob left; on = blue track,
/// knob right. Tap or drag; everything animates smoothly.
class RetroSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double width;
  final double height;
  final Color activeColor;
  final Color inactiveColor;

  const RetroSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 58,
    this.height = 30,
    this.activeColor = const Color(0xFF2E8BF0),
    this.inactiveColor = const Color(0xFFF2F2F2),
  });

  @override
  State<RetroSwitch> createState() => _RetroSwitchState();
}

class _RetroSwitchState extends State<RetroSwitch>
    with SingleTickerProviderStateMixin {
  static const _ink = Color(0xFF1C1C1E);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.value ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _c,
    curve: Curves.easeInOutCubic,
  );
  bool _pressed = false;

  @override
  void didUpdateWidget(RetroSwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      widget.value ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onChanged != null;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  void _toggle() {
    if (!_enabled) return;
    HapticFeedback.lightImpact();
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    // Geometry (scales with width/height).
    final knob = widget.height * .74; // square knob
    final trackH = widget.height * .56;
    final shadow = widget.height * .14; // hard shadow offset
    final trackW = widget.width - shadow;
    final trackTop = (widget.height - trackH) / 2 + shadow * .2;
    final knobTop = trackTop - knob * .22; // pokes above the track
    final travel = trackW - knob;

    return Semantics(
      toggled: widget.value,
      button: true,
      enabled: _enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: _toggle,
        onHorizontalDragStart: _enabled ? (_) => _setPressed(true) : null,
        onHorizontalDragUpdate: _enabled
            ? (d) => _c.value = (_c.value + d.delta.dx / travel)
                  .clamp(0.0, 1.0)
                  .toDouble()
            : null,
        onHorizontalDragEnd: _enabled
            ? (_) {
                _setPressed(false);
                final on = _c.value >= .5;
                if (on != widget.value) {
                  HapticFeedback.lightImpact();
                  widget.onChanged!(on);
                } else {
                  on ? _c.forward() : _c.reverse();
                }
              }
            : null,
        child: Opacity(
          opacity: _enabled ? 1 : .5,
          child: AnimatedBuilder(
            animation: _curve,
            builder: (context, _) {
              final t = _curve.value;
              final fill = Color.lerp(
                widget.inactiveColor,
                widget.activeColor,
                t,
              )!;
              // Pressing pushes the switch "into" its shadow.
              final push = _pressed ? shadow * .6 : 0.0;

              return SizedBox(
                width: widget.width,
                height: widget.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // ---------- Hard shadow ----------
                    Positioned(
                      left: shadow,
                      top: trackTop + shadow,
                      width: trackW,
                      height: trackH,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _ink,
                          borderRadius: BorderRadius.circular(trackH * .3),
                        ),
                      ),
                    ),

                    // ---------- Track + knob (move together on press) ----
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 90),
                      curve: Curves.easeOut,
                      left: push,
                      top: push,
                      width: trackW,
                      height: widget.height,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Track
                          Positioned(
                            left: 0,
                            top: trackTop,
                            width: trackW,
                            height: trackH,
                            child: Container(
                              decoration: BoxDecoration(
                                color: fill,
                                borderRadius: BorderRadius.circular(
                                  trackH * .3,
                                ),
                                border: Border.all(color: _ink, width: 2),
                              ),
                            ),
                          ),
                          // Knob
                          Positioned(
                            left: travel * t,
                            top: knobTop,
                            child: Container(
                              width: knob,
                              height: knob,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(
                                  knob * .22,
                                ),
                                border: Border.all(color: _ink, width: 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
