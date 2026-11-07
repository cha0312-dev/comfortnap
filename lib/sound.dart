import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:google_fonts/google_fonts.dart';

// =====================================================================
// DESIGN TOKENS (match the Session History screen)
// =====================================================================
const Color _bg = Color(0xFF07031F);
const Color _surface = Color(0xFF151040);
const Color _violet = Color(0xFF6B5BFF);
const Color _cyan = Color(0xFF24E0FF);
const Color _magenta = Color(0xFFB04BFF);

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

// =====================================================================
// SOUND CATALOG (shared with the home screen)
// =====================================================================
/// One sleep sound: its file, look (icon + colours) and short description.
class SleepSoundInfo {
  final String label;
  final String subtitle;
  final String file;
  final IconData icon;
  final List<Color> colors;

  const SleepSoundInfo({
    required this.label,
    required this.subtitle,
    required this.file,
    required this.icon,
    required this.colors,
  });

  LinearGradient get gradient => LinearGradient(
    colors: colors,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

const List<SleepSoundInfo> sleepSoundCatalog = [
  SleepSoundInfo(
    label: "Rain",
    subtitle: "Gentle rainfall",
    file: "calming-rain-257596.mp3",
    icon: Icons.water_drop_rounded,
    colors: [Color(0xFF4F7CFF), Color(0xFF24E0FF)],
  ),
  SleepSoundInfo(
    label: "Snow",
    subtitle: "Soft winter hush",
    file: "sledding-on-snow-sliding-on-snow-snow-and-sledding-16590.mp3",
    icon: Icons.ac_unit_rounded,
    colors: [Color(0xFF5B8CFF), Color(0xFFA5D8FF)],
  ),
  SleepSoundInfo(
    label: "Owl",
    subtitle: "Forest at night",
    file: "scops-owl-57475.mp3",
    icon: Icons.forest_rounded,
    colors: [Color(0xFF7B5BFF), Color(0xFFB04BFF)],
  ),
  SleepSoundInfo(
    label: "Bird",
    subtitle: "Dawn chorus",
    file: "bird-chipping-426107.mp3",
    icon: Icons.wb_twilight_rounded,
    colors: [Color(0xFFFF9F43), Color(0xFFFFD36B)],
  ),
  SleepSoundInfo(
    label: "Fire",
    subtitle: "Crackling campfire",
    file: "crackle-fireplace-campfire-402289.mp3",
    icon: Icons.local_fire_department_rounded,
    colors: [Color(0xFFFF5E3A), Color(0xFFFFB547)],
  ),
  SleepSoundInfo(
    label: "Night",
    subtitle: "Calm night ambience",
    file: "night-ambience-17064.mp3",
    icon: Icons.nightlight_round,
    colors: [Color(0xFF3D2BB5), Color(0xFF6B5BFF)],
  ),
  SleepSoundInfo(
    label: "Ocean",
    subtitle: "Rolling shoreline",
    file: "ocean-waves-crashing-the-shoreline-423649.mp3",
    icon: Icons.waves_rounded,
    colors: [Color(0xFF0FA3B1), Color(0xFF24E0FF)],
  ),
  SleepSoundInfo(
    label: "Wind",
    subtitle: "Breezy evening",
    file: "wind-blowing-sfx-01-423673.mp3",
    icon: Icons.air_rounded,
    colors: [Color(0xFF34D399), Color(0xFF24E0FF)],
  ),
  SleepSoundInfo(
    label: "Swing",
    subtitle: "Slow porch swing",
    file: "swing-squeak-73201.mp3",
    icon: Icons.chair_rounded,
    colors: [Color(0xFFFF6FA5), Color(0xFFB04BFF)],
  ),
];

/// Looks up a sound by its file name (what "Use this sound" returns).
SleepSoundInfo? sleepSoundByFile(String? file) {
  if (file == null) return null;
  for (final s in sleepSoundCatalog) {
    if (s.file == file) return s;
  }
  return null;
}

class SoundScreen extends StatefulWidget {
  /// File of the sound currently used on the home screen (shows "In use").
  final String? currentFile;

  const SoundScreen({super.key, this.currentFile});

  @override
  State<SoundScreen> createState() => _SoundScreenState();
}

class _SoundScreenState extends State<SoundScreen>
    with TickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isDisposed = false; // Track if widget is disposed
  String? selectedSound;
  String? selectedFile;
  bool isPlaying = false;
  double _volume = 1.0;

  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  final List<Map<String, dynamic>> sounds = [
    for (final s in sleepSoundCatalog)
      {
        "icon": s.icon,
        "label": s.label,
        "subtitle": s.subtitle,
        "colors": s.colors,
        "file": s.file,
      },
  ];

  @override
  void initState() {
    super.initState();
    // Sleep sounds loop until you pause or leave the page.
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
    // Keep the play/pause button honest when a track finishes on its own.
    _audioPlayer.onPlayerComplete.listen((_) {
      if (!_isDisposed && mounted) setState(() => isPlaying = false);
    });
  }

  Future<void> playSound(String fileName) async {
    try {
      // Stop any currently playing sound
      await _audioPlayer.stop();

      // If widget disposed in the meantime, exit
      if (_isDisposed) return;

      // Play new sound
      await _audioPlayer.play(AssetSource('sounds/$fileName'), volume: _volume);
    } catch (e) {
      debugPrint("⚠️ Error playing sound: $e");
    }
  }

  Future<void> _togglePlay() async {
    HapticFeedback.selectionClick();
    if (isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.resume();
    }
    if (!mounted) return;
    setState(() => isPlaying = !isPlaying);
  }

  Future<void> _onSoundTap(Map<String, dynamic> sound) async {
    // Tapping the current sound toggles play / pause.
    if (selectedFile == sound['file']) {
      await _togglePlay();
      return;
    }

    HapticFeedback.lightImpact();

    // Stop previous sound and play new one safely
    await playSound(sound['file']);
    if (!mounted) return;

    setState(() {
      selectedSound = sound['label'];
      selectedFile = sound['file'];
      isPlaying = true;
    });
  }

  Map<String, dynamic>? get _selected {
    for (final s in sounds) {
      if (s['file'] == selectedFile) return s;
    }
    return null;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _ambient.dispose();
    _beat.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  // ===================================================================
  // BUILD
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final accent = selected == null
        ? const [_violet, _cyan]
        : (selected['colors'] as List<Color>);

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Glow follows the colour of the selected sound.
          Positioned.fill(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: accent.first),
              duration: const Duration(milliseconds: 700),
              builder: (context, c1, _) => TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: accent.last),
                duration: const Duration(milliseconds: 700),
                builder: (context, c2, _) => _Aurora(
                  animation: _ambient,
                  primary: c1 ?? _violet,
                  secondary: c2 ?? _cyan,
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _header()),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    8,
                    20,
                    selected == null ? 32 : 260,
                  ),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          childAspectRatio: 1.02,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _Entrance(
                        index: index,
                        child: _soundCard(sounds[index]),
                      ),
                      childCount: sounds.length,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---------- Now playing dock ----------
          if (selected != null)
            Positioned(
              left: 14,
              right: 14,
              bottom: 0,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 14),
                child: _Entrance(index: 0, child: _nowPlaying(selected)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _glassButton(
                Icons.arrow_back_ios_new_rounded,
                () => Navigator.pop(context),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: _glass(radius: 20),
                child: Row(
                  children: [
                    Icon(Icons.headphones_rounded, color: _cyan, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      "${sounds.length} sounds",
                      style: TextStyle(
                        color: _white(.8),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            "SOUNDSCAPES",
            style: _eyebrow(color: _cyan.withValues(alpha: .85)),
          ),
          const SizedBox(height: 8),
          Text("Sleep Sounds", style: _display(38, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            "Pick a sound to drift off to. Tap it again to pause.",
            style: TextStyle(color: _white(.6), fontSize: 14),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // SOUND CARD
  // ===================================================================
  Widget _soundCard(Map<String, dynamic> sound) {
    final colors = sound['colors'] as List<Color>;
    final gradient = LinearGradient(
      colors: colors,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final isSelected = selectedFile == sound['file'];
    final playingHere = isSelected && isPlaying;

    return AnimatedScale(
      scale: isSelected ? 1.0 : .97,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      child: GestureDetector(
        onTap: () => _onSoundTap(sound),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: isSelected
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.first.withValues(alpha: .55),
                      colors.last.withValues(alpha: .22),
                    ],
                  )
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_white(.08), _white(.025)],
                  ),
            border: Border.all(
              color: isSelected
                  ? colors.last.withValues(alpha: .8)
                  : _white(.08),
              width: isSelected ? 1.5 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: colors.first.withValues(alpha: .45),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ]
                : const [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(17),
                      boxShadow: [
                        BoxShadow(
                          color: colors.first.withValues(alpha: .5),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(sound['icon'], color: Colors.white, size: 25),
                  ),
                  const Spacer(),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: playingHere
                        ? _Equalizer(
                            key: const ValueKey("eq"),
                            animation: _beat,
                            color: Colors.white,
                          )
                        : Container(
                            key: ValueKey(isSelected ? "paused" : "idle"),
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _white(isSelected ? .2 : .08),
                            ),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: _white(.9),
                              size: 18,
                            ),
                          ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      sound['label'],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _display(20),
                    ),
                  ),
                  if (sound['file'] == widget.currentFile) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _white(.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        "IN USE",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          letterSpacing: .8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                sound['subtitle'],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _white(isSelected ? .75 : .5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===================================================================
  // NOW PLAYING DOCK
  // ===================================================================
  Widget _nowPlaying(Map<String, dynamic> sound) {
    final colors = sound['colors'] as List<Color>;
    final gradient = LinearGradient(
      colors: colors,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: _surface.withValues(alpha: .72),
            border: Border.all(color: _white(.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // Artwork with a breathing ring while playing
                  AnimatedBuilder(
                    animation: _beat,
                    builder: (context, child) {
                      final t = isPlaying
                          ? (0.5 + 0.5 * math.sin(_beat.value * 2 * math.pi))
                          : 0.0;
                      return Container(
                        padding: EdgeInsets.all(3 + 3 * t),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.last.withValues(alpha: .18 * t),
                        ),
                        child: child,
                      );
                    },
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: gradient,
                        boxShadow: [
                          BoxShadow(
                            color: colors.first.withValues(alpha: .55),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                      child: Icon(sound['icon'], color: Colors.white, size: 26),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isPlaying ? "NOW PLAYING" : "PAUSED",
                          style: _eyebrow(
                            color: isPlaying ? colors.last : _white(.45),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(selectedSound!, style: _display(19)),
                        Text(
                          sound['subtitle'],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _white(.55), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (isPlaying) ...[
                    _Equalizer(animation: _beat, color: colors.last, bars: 5),
                    const SizedBox(width: 12),
                  ],
                  // Play / pause
                  GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: colors.first.withValues(alpha: .5),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (c, a) =>
                            ScaleTransition(scale: a, child: c),
                        child: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(isPlaying),
                          color: _bg,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Volume
              Row(
                children: [
                  Icon(Icons.volume_down_rounded, color: _white(.5), size: 20),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        activeTrackColor: colors.last,
                        inactiveTrackColor: _white(.12),
                        thumbColor: Colors.white,
                        overlayColor: colors.last.withValues(alpha: .2),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        value: _volume,
                        onChanged: (v) {
                          setState(() => _volume = v);
                          _audioPlayer.setVolume(v);
                        },
                      ),
                    ),
                  ),
                  Icon(Icons.volume_up_rounded, color: _white(.5), size: 20),
                ],
              ),
              const SizedBox(height: 6),

              // Use this sound
              SizedBox(
                width: double.infinity,
                height: 52,
                child: Material(
                  color: Colors.transparent,
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: colors.first.withValues(alpha: .45),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        Navigator.pop(context, {
                          'label': selectedSound,
                          'file': selectedFile,
                        });
                      },
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Text(
                            "Use this sound",
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===================================================================
  // HELPERS
  // ===================================================================
  BoxDecoration _glass({double radius = 24}) => BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [_white(.085), _white(.025)],
    ),
    border: Border.all(color: _white(.09)),
  );

  Widget _glassButton(IconData icon, VoidCallback onTap) {
    return Material(
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
    );
  }
}

// =====================================================================
// SMALL WIDGETS
// =====================================================================

/// Animated audio bars.
class _Equalizer extends StatelessWidget {
  final Animation<double> animation;
  final Color color;
  final int bars;
  const _Equalizer({
    super.key,
    required this.animation,
    required this.color,
    this.bars = 4,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value * 2 * math.pi;
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < bars; i++)
                Container(
                  width: 3.5,
                  height:
                      6 +
                      18 *
                          (0.5 + 0.5 * math.sin(t * (1 + i * .35) + i * 1.3))
                              .abs(),
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Slowly drifting glow, tinted by the selected sound.
class _Aurora extends StatelessWidget {
  final Animation<double> animation;
  final Color primary;
  final Color secondary;
  const _Aurora({
    required this.animation,
    required this.primary,
    required this.secondary,
  });

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
                  primary.withValues(alpha: .36),
                ),
                _blob(
                  Alignment(1.1 + .2 * math.cos(t), -0.2 + .2 * math.sin(t)),
                  380,
                  secondary.withValues(alpha: .18),
                ),
                _blob(
                  Alignment(-0.6 + .25 * math.cos(t), 1.0 + .1 * math.sin(t)),
                  440,
                  _magenta.withValues(alpha: .16),
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
