import 'package:url_launcher/url_launcher.dart';

/// Result of a routed command.
class CommandResult {
  final bool handled;
  final String feedback;

  const CommandResult(this.handled, this.feedback);
}

/// Lightweight intent router running inside the Jarvis Background Core.
///
/// When the user's speech matches a known local command (flashlight, open
/// YouTube, etc.), the action is executed natively and the audio is NOT
/// forwarded to Gemini. Everything else is left for the Gemini brain.
class CommandRouter {
  /// Commands that must run on the main isolate (e.g. torch via a platform
  /// channel) are forwarded through this callback.
  final void Function(String command)? onNativeCommand;

  CommandRouter({this.onNativeCommand});

  // ---------------------------------------------------------------------------
  // KEYWORD TABLE (English + Bengali)
  // ---------------------------------------------------------------------------

  static const List<String> _torchKeywords = [
    'turn on flashlight',
    'turn off flashlight',
    'toggle flashlight',
    'flashlight',
    'torch',
    'টর্চ',
    'ফ্ল্যাশলাইট',
    'আলো জ্বালাও',
    'লাইট জ্বালাও',
  ];

  static const List<String> _youtubeKeywords = [
    'open youtube',
    'launch youtube',
    'ইউটিউব খোলো',
    'ইউটিউব',
  ];

  static const List<String> _googleKeywords = [
    'open google',
    'google kholo',
    'গুগল খোলো',
  ];

  static const List<String> _whatsappKeywords = [
    'open whatsapp',
    'হোয়াটসঅ্যাপ খোলো',
  ];

  static const List<String> _cameraKeywords = [
    'open camera',
    'ক্যামেরা খোলো',
  ];

  static const List<String> _phoneKeywords = [
    'open dialer',
    'open phone',
    'ডialer', // kept simple; Bengali handled below
    'ফোন খোলো',
  ];

  // ---------------------------------------------------------------------------
  // ROUTING
  // ---------------------------------------------------------------------------

  /// Returns null when the text is NOT a local command (-> route to Gemini).
  CommandResult? route(String rawText) {
    final text = rawText.toLowerCase().trim();
    if (text.isEmpty) return null;

    if (_matches(text, _torchKeywords)) {
      onNativeCommand?.call('torch_toggle');
      return const CommandResult(true, 'টর্চ টগল করা হচ্ছে... [TORCH TOGGLED]');
    }

    if (_matches(text, _youtubeKeywords)) {
      _launch('https://www.youtube.com');
      return const CommandResult(true, 'ইউটিউব খোলা হচ্ছে... [OPENING YOUTUBE]');
    }

    if (_matches(text, _googleKeywords)) {
      _launch('https://www.google.com');
      return const CommandResult(true, 'গুগল খোলা হচ্ছে... [OPENING GOOGLE]');
    }

    if (_matches(text, _whatsappKeywords)) {
      _launch('https://wa.me/');
      return const CommandResult(
          true, 'হোয়াটসঅ্যাপ খোলা হচ্ছে... [OPENING WHATSAPP]');
    }

    if (_matches(text, _cameraKeywords)) {
      onNativeCommand?.call('open_camera');
      return const CommandResult(true, 'ক্যামেরা খোলা হচ্ছে... [OPENING CAMERA]');
    }

    if (_matches(text, _phoneKeywords) || text.contains('dialer')) {
      onNativeCommand?.call('open_dialer');
      return const CommandResult(true, 'ডায়ালার খোলা হচ্ছে... [OPENING DIALER]');
    }

    // Not a local command -> let Gemini handle it.
    return null;
  }

  bool _matches(String text, List<String> keywords) {
    for (final keyword in keywords) {
      if (text.contains(keyword.toLowerCase())) return true;
    }
    return false;
  }

  Future<void> _launch(String uriString) async {
    try {
      final uri = Uri.parse(uriString);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(uri);
      }
    } catch (_) {
      // Launch failed; ignore silently in the background core.
    }
  }
}