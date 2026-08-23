import 'dart:async';

import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import 'services/gemini_live_service.dart';
import 'services/jarvis_background_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const JarvisApp());
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JARVIS AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF050508),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF39FF14),
          surface: Color(0xFF0A0A12),
        ),
        fontFamily: 'monospace',
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  // ---------------------------------------------------------------------------
  // STATE
  // ---------------------------------------------------------------------------

  /// Whether microphone permission has been granted.
  bool _micGranted = false;

  /// Live state of the Jarvis Background Core.
  JarvisCoreState _coreState = JarvisCoreState.idle;

  // --- HUD state ---
  int _batteryLevel = 100;
  BatteryState _batteryState = BatteryState.unknown;
  DateTime _now = DateTime.now();

  // --- Terminal subtitle placeholders ---
  String _userText = '> awaiting voice input...';
  String _aiText = 'J.A.R.V.I.S online. All systems nominal._';

  final Battery _battery = Battery();
  final FlutterBackgroundService _bgService = FlutterBackgroundService();
  static const MethodChannel _nativeChannel =
      MethodChannel('com.sejan.jarvis_ai/native');

  late final AnimationController _orbController;
  Timer? _clockTimer;
  Timer? _batteryTimer;
  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<Map<String, dynamic>?>? _coreStateSub;
  StreamSubscription<Map<String, dynamic>?>? _nativeCmdSub;

  @override
  void initState() {
    super.initState();

    // Constantly-running breathing animation for the orb. Amplitude/color are
    // driven by [_coreState] inside the builder.
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    // Real-time clock for the tactical HUD.
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });

    // Real-time battery readout for the tactical HUD.
    _refreshBattery();
    _batteryTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshBattery(),
    );
    _batteryStateSub = _battery.onBatteryStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _batteryState = state);
      _refreshBattery();
    });

    _initBackgroundCore();
    _checkMicrophonePermission();
  }

  @override
  void dispose() {
    _orbController.dispose();
    _clockTimer?.cancel();
    _batteryTimer?.cancel();
    _batteryStateSub?.cancel();
    _coreStateSub?.cancel();
    _nativeCmdSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // BACKGROUND CORE (foreground service)
  // ---------------------------------------------------------------------------

  Future<void> _initBackgroundCore() async {
    await _bgService.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: jarvisBackgroundEntryPoint,
        isForegroundMode: true,
        autoStart: false,
        notificationChannelId: kJarvisNotificationChannelId,
        initialNotificationTitle: 'Jarvis Background Core Active',
        initialNotificationContent:
            'Voice core standing by. Tap to open the interface.',
        foregroundServiceNotificationId: kJarvisForegroundNotificationId,
        foregroundServiceTypes: [AndroidForegroundType.microphone],
      ),
      iosConfiguration: IosConfiguration(),
    );

    // React to core state changes coming from the background isolate.
    _coreStateSub = _bgService.on('core_state').listen((data) {
      if (!mounted || data == null) return;
      setState(() {
        final stateStr = data['state'] as String?;
        switch (stateStr) {
          case 'connecting':
            _coreState = JarvisCoreState.connecting;
            break;
          case 'listening':
            _coreState = JarvisCoreState.listening;
            break;
          case 'processing':
            _coreState = JarvisCoreState.processing;
            break;
          case 'speaking':
            _coreState = JarvisCoreState.speaking;
            break;
          default:
            _coreState = JarvisCoreState.idle;
        }
        if (data['userText'] is String) {
          _userText = data['userText'] as String;
        }
        if (data['aiText'] is String) {
          _aiText = data['aiText'] as String;
        }
      });
      _haptic(durationMs: 20);
    });

    // Execute native commands forwarded from the background core.
    _nativeCmdSub = _bgService.on('native_command').listen((data) {
      final command = data?['command'];
      if (command is String) _executeNativeCommand(command);
    });
  }

  Future<void> _executeNativeCommand(String command) async {
    try {
      switch (command) {
        case 'torch_toggle':
          await _nativeChannel.invokeMethod('torch_toggle');
          break;
        case 'open_camera':
          await _nativeChannel.invokeMethod('open_camera');
          break;
        case 'open_dialer':
          await _nativeChannel.invokeMethod('open_dialer');
          break;
      }
    } catch (_) {
      // Native command unavailable; ignore silently.
    }
  }

  // ---------------------------------------------------------------------------
  // HUD DATA
  // ---------------------------------------------------------------------------

  Future<void> _refreshBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (!mounted) return;
      setState(() => _batteryLevel = level);
    } catch (_) {
      // Battery info unavailable; keep last known value.
    }
  }

  String get _timeString {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    final s = _now.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  IconData get _batteryIcon {
    switch (_batteryState) {
      case BatteryState.charging:
        return Icons.bolt_rounded;
      case BatteryState.full:
        return Icons.battery_full_rounded;
      default:
        if (_batteryLevel <= 15) return Icons.battery_alert_rounded;
        if (_batteryLevel <= 50) return Icons.battery_3_bar_rounded;
        return Icons.battery_full_rounded;
    }
  }

  Color get _batteryColor {
    if (_batteryState == BatteryState.charging ||
        _batteryState == BatteryState.full) {
      return const Color(0xFF39FF14); // neon green while charging
    }
    if (_batteryLevel <= 15) return const Color(0xFFFF3131); // alert red
    return const Color(0xFF00E5FF);
  }

  // ---------------------------------------------------------------------------
  // HAPTIC FEEDBACK
  // ---------------------------------------------------------------------------

  Future<void> _haptic({int durationMs = 40}) async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        await Vibration.vibrate(duration: durationMs);
      }
    } catch (_) {
      // Haptics unsupported on this device; ignore silently.
    }
  }

  // ---------------------------------------------------------------------------
  // PERMISSIONS
  // ---------------------------------------------------------------------------

  Future<void> _checkMicrophonePermission() async {
    final status = await Permission.microphone.status;
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _micGranted = true);
    } else if (status.isDenied || status.isRestricted) {
      final result = await Permission.microphone.request();
      if (!mounted) return;
      setState(() {
        _micGranted = result.isGranted;
        if (!_micGranted) {
          _aiText = 'warning: microphone access denied._';
        }
      });
    } else if (status.isPermanentlyDenied) {
      setState(() {
        _micGranted = false;
        _aiText = 'error: enable microphone in system settings._';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // SESSION TOGGLE (UI -> Background Core)
  // ---------------------------------------------------------------------------

  Future<void> _toggleListening() async {
    if (!_micGranted) {
      await _checkMicrophonePermission();
      if (!_micGranted) {
        if (await Permission.microphone.isPermanentlyDenied) {
          openAppSettings();
        }
        return;
      }
    }

    // Android 13+ needs the notification permission to show the persistent
    // foreground-service notification.
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    final active = _coreState != JarvisCoreState.idle &&
        _coreState != JarvisCoreState.connecting;

    if (active) {
      _bgService.invoke('stop_session');
      setState(() {
        _coreState = JarvisCoreState.idle;
        _aiText = 'session closed. standing by._';
      });
    } else {
      setState(() {
        _coreState = JarvisCoreState.connecting;
        _userText = '> capturing audio stream...';
        _aiText = 'establishing neural link..._';
      });
      _bgService.invoke('start_session');
    }

    // Haptic feedback on state change.
    await _haptic(durationMs: active ? 30 : 60);
  }

  // ---------------------------------------------------------------------------
  // UI HELPERS
  // ---------------------------------------------------------------------------

  Color get _stateColor {
    switch (_coreState) {
      case JarvisCoreState.speaking:
        return const Color(0xFF39FF14); // neon green while speaking
      case JarvisCoreState.processing:
        return const Color(0xFFFFD600); // amber while processing
      case JarvisCoreState.connecting:
        return Colors.white70;
      default:
        return const Color(0xFF00E5FF); // cyan idle / listening
    }
  }

  String get _statusText {
    switch (_coreState) {
      case JarvisCoreState.connecting:
        return 'ESTABLISHING LINK...';
      case JarvisCoreState.listening:
        return 'LISTENING...';
      case JarvisCoreState.processing:
        return 'PROCESSING...';
      case JarvisCoreState.speaking:
        return 'JARVIS SPEAKING';
      default:
        return 'TAP TO SPEAK';
    }
  }

  bool get _isActive =>
      _coreState != JarvisCoreState.idle &&
      _coreState != JarvisCoreState.connecting;

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.0, -0.4),
            radius: 1.2,
            colors: [
              Color(0xFF0D1526),
              Color(0xFF050508),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 28),

              // ---------------- Greeting ----------------
              Text(
                'Welcome, Sejan ( Supreme)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2.5,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      blurRadius: 18,
                      color: const Color(0xFF00E5FF).withOpacity(0.9),
                    ),
                    Shadow(
                      blurRadius: 40,
                      color: const Color(0xFF00E5FF).withOpacity(0.5),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ---------------- Tactical HUD Bar ----------------
              _buildHudBar(),

              const Spacer(),

              // ---------------- Pulsating Mic Orb ----------------
              _buildMicOrb(),

              const SizedBox(height: 20),

              // ---------------- Status ----------------
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _statusText,
                  key: ValueKey<String>(_statusText),
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w600,
                    color: _isActive ? _stateColor : Colors.white54,
                  ),
                ),
              ),

              const Spacer(),

              // ---------------- Live Terminal Subtitles ----------------
              _buildTerminal(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- Tactical HUD Bar ----------------

  Widget _buildHudBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.45),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: const Color(0xFF00E5FF).withOpacity(0.35),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00E5FF).withOpacity(0.08),
              blurRadius: 12,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Clock module
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 15,
                  color: const Color(0xFF00E5FF).withOpacity(0.85),
                ),
                const SizedBox(width: 6),
                Text(
                  _timeString,
                  style: const TextStyle(
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF00E5FF),
                  ),
                ),
              ],
            ),

            // Divider ticks
            Text(
              '//',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: const Color(0xFF39FF14).withOpacity(0.5),
              ),
            ),

            // Core status module
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stateColor,
                    boxShadow: [
                      BoxShadow(blurRadius: 8, color: _stateColor),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _coreState.name.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                    color: _stateColor,
                  ),
                ),
              ],
            ),

            // Divider ticks
            Text(
              '//',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: const Color(0xFF39FF14).withOpacity(0.5),
              ),
            ),

            // Battery module
            Row(
              children: [
                Icon(_batteryIcon, size: 16, color: _batteryColor),
                const SizedBox(width: 6),
                Text(
                  '$_batteryLevel%',
                  style: TextStyle(
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                    color: _batteryColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Pulsating Mic Orb ----------------

  Widget _buildMicOrb() {
    return GestureDetector(
      onTap: _toggleListening,
      child: AnimatedBuilder(
        animation: _orbController,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(_orbController.value);
          final color = _stateColor;

          // Pulse amplitude depends on the current core state.
          final double scale = switch (_coreState) {
            JarvisCoreState.listening => 1.0 + 0.18 * t,
            JarvisCoreState.speaking => 1.0 + 0.14 * t,
            JarvisCoreState.processing => 1.0 + 0.10 * t,
            JarvisCoreState.connecting => 1.0 + 0.06 * t,
            JarvisCoreState.idle => 1.0 + 0.04 * t,
          };
          final double glowOpacity = switch (_coreState) {
            JarvisCoreState.listening => 0.35 + 0.45 * t,
            JarvisCoreState.speaking => 0.30 + 0.40 * t,
            JarvisCoreState.processing => 0.25 + 0.25 * t,
            _ => 0.22 + 0.15 * t,
          };
          final double glowRadius = switch (_coreState) {
            JarvisCoreState.listening => 40 + 50 * t,
            JarvisCoreState.speaking => 36 + 44 * t,
            _ => 26 + 16 * t,
          };

          return Transform.scale(
            scale: scale,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    color.withOpacity(0.35),
                    color.withOpacity(0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.7, 1.0],
                ),
                border: Border.all(
                  color: color.withOpacity(_isActive ? 1.0 : 0.55),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(glowOpacity),
                    blurRadius: glowRadius,
                    spreadRadius: _isActive ? 6 + 10 * t : 2,
                  ),
                  BoxShadow(
                    color: const Color(0xFF39FF14)
                        .withOpacity(glowOpacity * 0.3),
                    blurRadius: glowRadius * 1.6,
                    spreadRadius: _isActive ? 10 * t : 0,
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  _coreState == JarvisCoreState.speaking
                      ? Icons.graphic_eq_rounded
                      : Icons.mic_none_rounded,
                  size: 68,
                  color: _isActive ? Colors.white : color,
                  shadows: [Shadow(blurRadius: 25, color: color)],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------- Live Terminal Subtitles ----------------

  Widget _buildTerminal() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Container(
        height: 190,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.65),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFF39FF14).withOpacity(0.35),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF39FF14).withOpacity(0.07),
              blurRadius: 14,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Terminal title bar
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF39FF14).withOpacity(0.08),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _stateColor,
                      boxShadow: [
                        BoxShadow(blurRadius: 8, color: _stateColor),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'JARVIS://LIVE-TRANSCRIPT',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF39FF14).withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),

            // Transcript body
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // User line (cyan)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'YOU > ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF00E5FF).withOpacity(0.9),
                          ),
                        ),
                        Expanded(
                          child: AnimatedTextKit(
                            key: ValueKey<String>('user_$_userText'),
                            isRepeatingAnimation: false,
                            displayFullTextOnTap: true,
                            animatedTexts: [
                              TypewriterAnimatedText(
                                _userText.replaceFirst('> ', ''),
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Color(0xFF00E5FF),
                                ),
                                speed: const Duration(milliseconds: 35),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // AI line (neon green)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI  > ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF39FF14).withOpacity(0.9),
                          ),
                        ),
                        Expanded(
                          child: AnimatedTextKit(
                            key: ValueKey<String>('ai_$_aiText'),
                            isRepeatingAnimation: false,
                            displayFullTextOnTap: true,
                            animatedTexts: [
                              TypewriterAnimatedText(
                                _aiText.replaceFirst('J.A.R.V.I.S ', ''),
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Color(0xFF39FF14),
                                ),
                                speed: const Duration(milliseconds: 35),
                              ),
                            ],
                          ),
                        ),
                      ],
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
}