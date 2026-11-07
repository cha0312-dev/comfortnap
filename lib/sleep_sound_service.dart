import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';

/// The app-wide sleep sound player. Runs inside an Android media
/// (foreground) service so the sound keeps playing with the screen off,
/// and shows play / pause / stop controls on the lock screen and in the
/// notification shade.
late final SleepSoundHandler sleepSound;

/// Call once from main() before runApp().
Future<void> initSleepSound() async {
  try {
    sleepSound = await AudioService.init(
      builder: () => SleepSoundHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.esp32_ble_app.sleep_sound',
        androidNotificationChannelName: 'Sleep sounds',
        androidNotificationChannelDescription:
            'Playback controls for ComfortNap sleep sounds',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e) {
    // If the media service can't start (e.g. Android setup missing), still
    // play sounds normally — just without lock-screen controls.
    // ignore: avoid_print
    print("SLEEP SOUND SERVICE ERROR (falling back to plain player): $e");
    sleepSound = SleepSoundHandler();
  }
}

class SleepSoundHandler extends BaseAudioHandler {
  /// The underlying player. main.dart uses it directly; every state change
  /// is mirrored to the lock-screen / notification controls.
  final AudioPlayer player = AudioPlayer();

  SleepSoundHandler() {
    // Sleep sounds loop seamlessly until paused or stopped.
    player.setReleaseMode(ReleaseMode.loop);
    player.onPlayerStateChanged.listen(_broadcastState);
  }

  /// Shows [label] (e.g. "Rain") as the title on the lock screen.
  void setSound(String label) {
    mediaItem.add(
      MediaItem(
        id: 'comfortnap_${label.toLowerCase()}',
        title: label,
        artist: 'ComfortNap · Sleep sound',
        album: 'ComfortNap',
      ),
    );
  }

  void _broadcastState(PlayerState state) {
    final playing = state == PlayerState.playing;
    final active = state == PlayerState.playing || state == PlayerState.paused;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1],
        processingState: active
            ? AudioProcessingState.ready
            : AudioProcessingState.idle,
        playing: playing,
      ),
    );
  }

  // ----- Lock-screen / notification / headset button actions -----

  @override
  Future<void> play() => player.resume();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }
}
