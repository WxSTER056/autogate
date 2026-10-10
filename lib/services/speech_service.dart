import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_error.dart';

class SpeechService {
  static final SpeechService _instance = SpeechService._internal();
  factory SpeechService() => _instance;
  SpeechService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();

  final ValueNotifier<bool> isListening = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isInitialized = ValueNotifier<bool>(false);
  final ValueNotifier<String> wordsSpoken = ValueNotifier<String>("");
  final ValueNotifier<String> recognizedCommand = ValueNotifier<String>("");
  final ValueNotifier<double> soundLevel = ValueNotifier<double>(0.0);
  final ValueNotifier<String> statusMessage = ValueNotifier<String>("Initializing speech...");

  // Control whether to continuously loop after timeout
  // Default to false to avoid frantic start-stop cycling on Android
  bool continuousListening = false;
  bool _manualStop = false;
  DateTime? _lastTriggerTime;
  Timer? _restartDebounceTimer;

  // Callback when a valid door command is detected
  Function(String command)? onDoorCommandDetected;

  /// Keywords for opening and closing the door
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
        statusMessage.value = "Ready to listen";
      } else {
        statusMessage.value = "Microphone or Speech unavailable";
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
      isListening.value = false;

      // Only restart if continuous listening is explicitly enabled and not manually stopped
      if (continuousListening && !_manualStop) {
        _restartDebounceTimer?.cancel();
        // Give Android audio engine at least 2 seconds cooldown to prevent rapid start/stop flashing
        _restartDebounceTimer = Timer(const Duration(milliseconds: 2000), () {
          if (continuousListening && !_manualStop && !_speech.isListening) {
            startListening();
          }
        });
      } else {
        statusMessage.value = "Standby • Tap mic to speak";
      }
    }
  }

  void _handleError(SpeechRecognitionError errorNotification) {
    debugPrint("Speech Error: ${errorNotification.errorMsg} - permanent: ${errorNotification.permanent}");
    isListening.value = false;

    // Handle common Android errors gracefully (e.g., error_no_match, error_busy, error_speech_timeout)
    if (errorNotification.errorMsg.contains("error_no_match") ||
        errorNotification.errorMsg.contains("error_speech_timeout")) {
      statusMessage.value = "Standby • Tap mic to speak";
    } else {
      statusMessage.value = "Speech: ${errorNotification.errorMsg}";
    }

    if (continuousListening && !_manualStop && !errorNotification.permanent) {
      _restartDebounceTimer?.cancel();
      _restartDebounceTimer = Timer(const Duration(milliseconds: 3000), () {
        if (continuousListening && !_manualStop && !_speech.isListening) {
          startListening();
        }
      });
    }
  }

  Future<void> startListening() async {
    _manualStop = false;
    _restartDebounceTimer?.cancel();

    if (!_speech.isAvailable) {
      bool ok = await initSpeech();
      if (!ok) return;
    }

    if (_speech.isListening) return;

    try {
      wordsSpoken.value = "";
      await _speech.listen(
        onResult: (result) {
          final text = result.recognizedWords.toLowerCase().trim();
          wordsSpoken.value = result.recognizedWords;
          _checkVoiceCommands(text);
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation, // Dictation mode allows longer listening without instant cuts
          cancelOnError: false,
          partialResults: true,
        ),
        onSoundLevelChange: (level) {
          soundLevel.value = level;
        },
      );
      isListening.value = true;
    } catch (e) {
      debugPrint("Start listening error: $e");
      isListening.value = false;
    }
  }

  void stopListening() {
    _manualStop = true;
    _restartDebounceTimer?.cancel();
    _speech.stop();
    isListening.value = false;
    statusMessage.value = "Voice listening paused";
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
    _restartDebounceTimer?.cancel();
    _speech.stop();
  }
}
