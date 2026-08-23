import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:record/record.dart';

import 'command_router.dart';
import 'gemini_live_service.dart';

/// Notification channel + id for the persistent foreground notification.
const String kJarvisNotificationChannelId = 'jarvis_core_channel';
const int kJarvisForegroundNotificationId = 1001;

/// Entry point of the Jarvis Background Core.
///
/// Runs in its own isolate as an Android foreground service with a persistent
/// "Jarvis Background Core Active" notification so the OS never kills it.
@pragma('vm:entry-point')
Future<void> jarvisBackgroundEntryPoint(ServiceInstance service) async {
  // Register all Flutter plugins inside this background isolate.
  DartPluginRegistrant.ensureInitialized();

  final gemini = GeminiLiveService.instance;
  final recorder = AudioRecorder();
  final player = AudioPlayer(playerId: 'jarvis_voice_player');
  final router = CommandRouter(
    // Torch / dialer / camera need the main-isolate platform channel.
    onNativeCommand: (command) =>
        service.invoke('native_command', {'command': command}),
  );

  bool sessionActive = false;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<Uint8List>? _voiceSub;
  StreamSubscription<String>? _inputSub;
  StreamSubscription<String>? _modelSub;

  /// Sequential playback queue so overlapping voice chunks play seamlessly.
  Future<void> _playbackQueue = Future<void>.value();

  void emitState(
    String state, {
    String? userText,
    String? aiText,
  }) {
    service.invoke('core_state', <String, dynamic>{
      'state': state,
      if (userText != null) 'userText': userText,
      if (aiText != null) 'aiText': aiText,
    });
  }

  Future<void> teardownSession() async {
    sessionActive = false;
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await recorder.isRecording()) await recorder.stop();
    } catch (_) {}
    await gemini.disconnect();
    emitState('idle');
  }

  // --- Service lifecycle -----------------------------------------------------

  service.on('stop').listen((_) async {
    await teardownSession();
    await player.stop();
    await player.release();
    await service.stopSelf();
  });

  // --- Start a live listening session ----------------------------------------

  service.on('start_session').listen((_) async {
    if (sessionActive) return;
    sessionActive = true;

    emitState('connecting');

    // 1. Connect to Gemini Live and send the setup frame.
    await gemini.connect();

    // 2. Play every voice chunk Jarvis sends back (PCM -> WAV -> queue).
    _voiceSub = gemini.audioOutput.listen((pcmChunk) {
      _playbackQueue = _playbackQueue.then(
        (_) => _playPcmChunk(player, pcmChunk),
      );
    });

    // 3. Terminal subtitles from model output.
    _modelSub = gemini.modelText.listen((text) {
      emitState('speaking', aiText: text);
    });

    // 4. Route user speech: local commands first, Gemini otherwise.
    _inputSub = gemini.inputText.listen((text) {
      final result = router.route(text);
      if (result != null && result.handled) {
        emitState('listening', userText: text, aiText: result.feedback);
      } else {
        emitState('listening', userText: text);
        // Audio is already being streamed to Gemini continuously.
      }
    });

    // 5. Start raw 16 kHz mono 16-bit PCM capture (works in background).
    try {
      final micStream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.mic,
          ),
        ),
      );
      _micSub = micStream.listen(gemini.sendAudioChunk);
      emitState('listening');
    } catch (_) {
      emitState('idle', aiText: 'error: microphone stream failed._');
      await teardownSession();
    }
  });

  // --- Stop the live listening session ---------------------------------------

  service.on('stop_session').listen((_) async {
    await teardownSession();
  });
}

// -----------------------------------------------------------------------------
// AUDIO PLAYBACK HELPERS
// -----------------------------------------------------------------------------

/// Plays one chunk of model PCM by wrapping it in a minimal WAV header
/// (Gemini Live outputs 24 kHz mono 16-bit PCM).
Future<void> _playPcmChunk(AudioPlayer player, Uint8List pcm) async {
  try {
    final wav = wrapPcmAsWav(pcm, sampleRate: 24000);
    await player.stop();
    await player.play(BytesSource(wav));

    // Wait for this chunk to finish before the next one starts.
    final completer = Completer<void>();
    late final StreamSubscription<void> sub;
    sub = player.onPlayerComplete.listen((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => sub.cancel(),
    );
  } catch (_) {
    // Playback hiccup; drop the chunk and continue the queue.
  }
}

/// Prepends a canonical RIFF/WAVE header to raw little-endian PCM bytes.
Uint8List wrapPcmAsWav(
  Uint8List pcm, {
  required int sampleRate,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final dataSize = pcm.length;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;

  final header = BytesBuilder(copy: false)
    ..add(asciiBytes('RIFF'))
    ..add(_le32(36 + dataSize))
    ..add(asciiBytes('WAVE'))
    ..add(asciiBytes('fmt '))
    ..add(_le32(16)) // fmt chunk size
    ..add(_le16(1)) // PCM format
    ..add(_le16(channels))
    ..add(_le32(sampleRate))
    ..add(_le32(byteRate))
    ..add(_le16(blockAlign))
    ..add(_le16(bitsPerSample))
    ..add(asciiBytes('data'))
    ..add(_le32(dataSize));

  return Uint8List.fromList([...header.takeBytes(), ...pcm]);
}

Uint8List asciiBytes(String s) => Uint8List.fromList(s.codeUnits);

Uint8List _le32(int value) => Uint8List.fromList([
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);

Uint8List _le16(int value) =>
    Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);