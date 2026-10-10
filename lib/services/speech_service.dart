import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_error.dart';

class SpeechService {
  static final SpeechService _instance = SpeechService._internal();
  factory SpeechService() => _instance;
  SpeechService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();

  // Stable UI state: Remains TRUE consistently while listening mode is active
  // This completely eliminates the annoying on-off-on-off (开关开关) UI blinking!
  final ValueNotifier<bool> isListening = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isInitialized = ValueNotifier<bool>(false);
  final ValueNotifier<String> wordsSpoken = ValueNotifier<String>("");
  final ValueNotifier<String> recognizedCommand = ValueNotifier<String>("");
  final ValueNotifier<double> soundLevel = ValueNotifier<double>(0.0);
  final ValueNotifier<String> statusMessage = ValueNotifier<String>("Initializing speech...");

  bool continuousListening = true;
  bool _userStopped = false;
  DateTime? _lastTriggerTime;
  Timer? _reconnectTimer;

  // Callback when a valid door command is detected
  Function(String command)? onDoorCommandDetected;

  /// Keywords for opening and closing the door (English & Chinese)
  final List<String> openKeywords = [
    "open the door",
    "open door",
    "open gate",
    "open the gate",
    "open",
    "开门",
    "把门打开",
    "开闸",
    "打开",
  ];

  final List<String> closeKeywords = [
    "close the door",
    "close door",
    "close gate",
    "close the gate",
    "close",
    "关门",
    "把门关上",
    "关闸",
    "关上",
  ];

  Future<bool> initSpeech() async {
    try {
      bool available = await _speech.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
        debugLogging: false,
      );

      isInitialized.value = available;
      if (available) {
        statusMessage.value = "Listening for 'open the door' / 'close the door'...";
      } else {
        statusMessage.value = "Microphone unavailable";
      }
      return available;
    } catch (e) {
      statusMessage.value = "Error initializing speech: $e";
      debugPrint("Speech init error: $e");
      return false;
    }
  }

  void _handleStatus(String status) {
    debugPrint("Speech Status: $status");

    if (status == "listening") {
      isListening.value = true;
      statusMessage.value = "Listening for 'open the door' / 'close the door'...";
    } else if (status == "notListening" || status == "done") {
      // CRITICAL FIX: If continuous listening is enabled and user didn't explicitly pause it,
      // DO NOT set isListening.value to false! Keep the UI stably glowing and active!
      if (continuousListening && !_userStopped) {
        _reconnectTimer?.cancel();
        // Quiet background restart without blinking the UI
        _reconnectTimer = Timer(const Duration(milliseconds: 250), () {
          if (continuousListening && !_userStopped && !_speech.isListening) {
            _startNativeListening();
          }
        });
      } else {
        isListening.value = false;
        statusMessage.value = "Voice paused • Tap mic to listen";
      }
    }
  }

  void _handleError(SpeechRecognitionError errorNotification) {
    debugPrint("Speech Error: ${errorNotification.errorMsg} - permanent: ${errorNotification.permanent}");

    if (continuousListening && !_userStopped && !errorNotification.permanent) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(milliseconds: 500), () {
        if (continuousListening && !_userStopped && !_speech.isListening) {
          _startNativeListening();
        }
      });
    } else {
      isListening.value = false;
      statusMessage.value = "Tap mic to speak";
    }
  }

  Future<void> startListening() async {
    _userStopped = false;
    isListening.value = true; // Immediately lock UI to active state!
    statusMessage.value = "Listening for 'open the door'...";
    _reconnectTimer?.cancel();

    if (!_speech.isAvailable) {
      bool ok = await initSpeech();
      if (!ok) {
        isListening.value = false;
        return;
      }
    }

    _startNativeListening();
  }

  Future<void> _startNativeListening() async {
    if (_speech.isListening || _userStopped) return;

    try {
      await _speech.listen(
        onResult: (result) {
          final text = result.recognizedWords.toLowerCase().trim();
          wordsSpoken.value = result.recognizedWords;
          _checkVoiceCommands(text);
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.confirmation, // Instant partial results
          cancelOnError: false,
          partialResults: true,
        ),
        onSoundLevelChange: (level) {
          soundLevel.value = level;
        },
      );
    } catch (e) {
      debugPrint("Native listen error: $e");
    }
  }

  void stopListening() {
    _userStopped = true;
    _reconnectTimer?.cancel();
    _speech.stop();
    isListening.value = false; // Only turn off when user manually taps to stop!
    statusMessage.value = "Voice paused • Tap mic to resume";
  }

  void _checkVoiceCommands(String spokenText) {
    if (spokenText.isEmpty) return;

    // Cooldown check (prevent repeated triggers within 4 seconds)
    if (_lastTriggerTime != null &&
        DateTime.now().difference(_lastTriggerTime!) < const Duration(seconds: 4)) {
      return;
    }

    String? matchedCommand;

    // Check open commands
    for (final kw in openKeywords) {
      if (spokenText.contains(kw)) {
        matchedCommand = "OPEN_DOOR";
        recognizedCommand.value = "Detected: '$kw'";
        break;
      }
    }

    // Check close commands
    if (matchedCommand == null) {
      for (final kw in closeKeywords) {
        if (spokenText.contains(kw)) {
          matchedCommand = "CLOSE_DOOR";
          recognizedCommand.value = "Detected: '$kw'";
          break;
        }
      }
    }

    if (matchedCommand != null) {
      _lastTriggerTime = DateTime.now();
      debugPrint("Matched Door Command: $matchedCommand from input: '$spokenText'");
      onDoorCommandDetected?.call(matchedCommand);
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _speech.stop();
  }
}
