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

  // Control auto-restart for continuous listening
  bool continuousListening = true;
  bool _manualStop = false;
  DateTime? _lastTriggerTime;

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
      // _speech.initialize automatically requests RECORD_AUDIO runtime permission
      bool available = await _speech.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
        debugLogging: false,
      );

      isInitialized.value = available;
      if (available) {
        statusMessage.value = "Ready to listen";
      } else {
        statusMessage.value = "Speech recognition unavailable";
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
      // If continuous listening is enabled and user didn't manually stop, restart listening
      if (continuousListening && !_manualStop) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (!_manualStop && !isListening.value) {
            startListening();
          }
        });
      } else {
        statusMessage.value = "Tap mic to speak";
      }
    }
  }

  void _handleError(SpeechRecognitionError errorNotification) {
    debugPrint("Speech Error: ${errorNotification.errorMsg} - permanent: ${errorNotification.permanent}");
    isListening.value = false;
    statusMessage.value = "Speech error: ${errorNotification.errorMsg}";

    if (continuousListening && !_manualStop && !errorNotification.permanent) {
      Future.delayed(const Duration(seconds: 1), () {
        if (!_manualStop && !isListening.value) {
          startListening();
        }
      });
    }
  }

  Future<void> startListening() async {
    _manualStop = false;

    if (!_speech.isAvailable) {
      bool ok = await initSpeech();
      if (!ok) return;
    }

    if (_speech.isListening) return;

    try {
      await _speech.listen(
        onResult: (result) {
          final text = result.recognizedWords.toLowerCase().trim();
          wordsSpoken.value = result.recognizedWords;
          _checkVoiceCommands(text);
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.confirmation,
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
    _speech.stop();
    isListening.value = false;
    statusMessage.value = "Voice listening stopped";
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
    _speech.stop();
  }
}
