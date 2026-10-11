import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

const String kCommandOpenDoor = 'OPEN_DOOR';
const String kCommandCloseDoor = 'CLOSE_DOOR';

/// Stop at a half-open position: two RF pulses three seconds apart.
const String kCommandHalfOpenDoor = 'HALF_OPEN_DOOR';

/// Normalised transcript plus the gate command it maps to.
class CommandMatch {
  const CommandMatch(this.command, this.phrase);
  final String command;
  final String phrase;
}

/// Coarse lifecycle of the recognizer, surfaced to the UI.
enum VoiceState {
  initializing('正在初始化语音引擎…'),
  unavailable('语音识别不可用，请检查麦克风权限'),
  disabled('语音控制已关闭'),
  starting('正在启动麦克风…'),
  listening('正在聆听…'),
  reconnecting('正在重新连接语音引擎…');

  const VoiceState(this.label);

  final String label;
}

/// Owns the speech recognizer and drives it as a small state machine.
///
/// The recognizer only ever listens for one bounded session at a time
/// (Android kills it after a few seconds of silence), so "always on"
/// behaviour means repeatedly opening a new session. The important part is
/// that exactly **one** restart is ever scheduled at a time — the previous
/// implementation let every `notListening` / `done` / error callback queue
/// its own uncancelled `Future.delayed`, so several `listen()` calls landed
/// on the same native recognizer and the microphone visibly flickered on and
/// off forever.
class SpeechService {
  SpeechService._internal();
  static final SpeechService _instance = SpeechService._internal();
  factory SpeechService() => _instance;

  final stt.SpeechToText _speech = stt.SpeechToText();

  // --- Session tuning -----------------------------------------------------
  /// Hard cap for a single recognition session: the mic stays open for ten
  /// seconds at a time, then closes and is reopened.
  static const Duration _maxSession = Duration(seconds: 10);

  /// End the session early after this much silence.
  static const Duration _pauseAfterSilence = Duration(seconds: 4);

  /// How long to wait for the platform's final result before promoting the
  /// last partial result. Shorter than the plugin default so the restart
  /// below is not delayed by two seconds every cycle.
  static const Duration _finalTimeout = Duration(milliseconds: 1000);

  /// Gap between a finished session and the next one.
  static const Duration _restartGap = Duration(milliseconds: 350);

  /// After a keyword fires the mic is closed immediately; this is how long we
  /// then wait before opening it again. Long enough that the gate motor noise
  /// is not picked up, short enough to stay responsive.
  static const Duration _resumeAfterCommand = Duration(milliseconds: 1500);

  /// Watchdog: if the platform never reports `done` after `notListening`,
  /// restart anyway after this long.
  static const Duration _doneWatchdog = Duration(milliseconds: 1600);

  /// Back-off steps applied when sessions keep ending empty. Keeps the mic
  /// from spinning endlessly while nobody is talking.
  static const List<Duration> _idleBackoff = [
    Duration(milliseconds: 350),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  /// Back-off steps applied after a recognition error.
  static const List<Duration> _errorBackoff = [
    Duration(milliseconds: 600),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  /// Ignore any further command for this long after one fires.
  static const Duration _commandCooldown = Duration(seconds: 3);

  // --- Public notifiers ---------------------------------------------------
  final ValueNotifier<VoiceState> state = ValueNotifier<VoiceState>(VoiceState.initializing);

  /// True whenever the assistant is armed, i.e. it is listening or in the
  /// middle of quietly renewing a session. Deliberately does **not** blink
  /// between sessions so the UI looks steady.
  final ValueNotifier<bool> isListening = ValueNotifier<bool>(false);

  final ValueNotifier<bool> isInitialized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> permissionDenied = ValueNotifier<bool>(false);
  final ValueNotifier<String> wordsSpoken = ValueNotifier<String>("");
  final ValueNotifier<String> recognizedCommand = ValueNotifier<String>("");
  final ValueNotifier<double> soundLevel = ValueNotifier<double>(0.0);
  final ValueNotifier<String> statusMessage = ValueNotifier<String>("");

  /// Called with [kCommandOpenDoor] / [kCommandCloseDoor] when a confirmed
  /// command is recognised.
  void Function(String command)? onDoorCommandDetected;

  // --- Internal state -----------------------------------------------------
  Future<bool>? _initFuture;
  Timer? _restartTimer;

  /// Reopens the mic shortly after a keyword fired, see [_handleResult].
  Timer? _resumeTimer;

  /// Bumped whenever a session ends or is cancelled. Any pending restart
  /// carrying an older token is dropped.
  int _sessionToken = 0;

  /// True from the moment `listen()` is issued until the session reports it
  /// ended. Prevents a second `listen()` from being issued while the first is
  /// still starting up (the plugin only flips `isListening` once the platform
  /// confirms, which leaves a window where two calls both look valid).
  bool _sessionActive = false;

  /// Guards against overlapping `listen()` calls while an await is in flight.
  bool _listenInFlight = false;

  int _consecutiveErrors = 0;
  int _consecutiveEmptySessions = 0;
  DateTime? _lastTriggerTime;

  bool _userEnabled = true;
  bool _inForeground = true;
  bool _disposed = false;

  /// Whether the user wants continuous listening. Kept for compatibility
  /// with the auto-listen switch; prefer [setEnabled].
  bool get continuousListening => _userEnabled;
  set continuousListening(bool value) => setEnabled(value);

  /// True when the assistant is enabled, the app is in the foreground and the
  /// engine is healthy — i.e. the condition under which a session may run.
  bool get _shouldListen =>
      _userEnabled && _inForeground && !_disposed && _speech.isAvailable;

  // --- Public API ---------------------------------------------------------

  Future<bool> initSpeech() {
    return _initFuture ??= _doInit();
  }

  Future<bool> _doInit() async {
    _setState(VoiceState.initializing, "正在初始化语音引擎…");
    try {
      // initialize() is what triggers the RECORD_AUDIO permission prompt.
      final available = await _speech.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
        debugLogging: kDebugMode,
        finalTimeout: _finalTimeout,
      );

      isInitialized.value = available;
      if (!available) {
        permissionDenied.value = !await _speech.hasPermission;
        _setState(VoiceState.unavailable, "语音识别不可用，请检查麦克风权限");
        return false;
      }

      permissionDenied.value = false;
      _detectLocale();
      if (_shouldListen) {
        _beginSession(immediate: true);
      } else {
        _setState(VoiceState.disabled, "语音控制已关闭");
      }
      return true;
    } catch (e) {
      _setState(VoiceState.unavailable, "语音初始化失败: $e");
      debugPrint("Speech init error: $e");
      return false;
    }
  }

  /// Enable or disable continuous listening. Safe to call repeatedly.
  void setEnabled(bool enabled) {
    if (_userEnabled == enabled) return;
    _userEnabled = enabled;

    if (!enabled) {
      _endSession();
      _setState(_speech.isAvailable ? VoiceState.disabled : VoiceState.unavailable,
          "语音控制已关闭");
      return;
    }

    if (!_speech.isAvailable) {
      _initFuture = null;
      initSpeech();
      return;
    }
    if (_inForeground) {
      _beginSession(immediate: true);
    } else {
      _setState(VoiceState.disabled, "等待回到前台");
    }
  }

  /// Ask the platform to start a session and re-enable the assistant.
  /// Normally called for you; exposed for the retry button shown when the
  /// engine is unavailable.
  Future<void> startListening() async {
    _userEnabled = true;
    if (!_speech.isAvailable) {
      _initFuture = null;
      final ok = await initSpeech();
      if (!ok) return;
    }
    _beginSession(immediate: true);
  }

  /// Stop listening until [startListening] / [setEnabled(true)] is called.
  void stopListening() {
    _userEnabled = false;
    _endSession();
    _setState(_speech.isAvailable ? VoiceState.disabled : VoiceState.unavailable,
        "语音控制已关闭");
  }

  /// Forward `AppLifecycleState` changes so we do not fight the platform for
  /// the microphone while the app is in the background.
  void onLifecycleChanged(AppLifecycleState lifecycle) {
    final foreground = lifecycle == AppLifecycleState.resumed;
    if (foreground == _inForeground) return;
    _inForeground = foreground;

    if (foreground) {
      if (_userEnabled) _beginSession(immediate: true);
    } else {
      _endSession();
    }
  }

  void dispose() {
    _disposed = true;
    _userEnabled = false;
    _endSession();
    isListening.dispose();
    isInitialized.dispose();
    permissionDenied.dispose();
    wordsSpoken.dispose();
    recognizedCommand.dispose();
    soundLevel.dispose();
    statusMessage.dispose();
    state.dispose();
  }

  // --- Session lifecycle --------------------------------------------------

  void _beginSession({bool immediate = false}) {
    _cancelRestart();

    if (!_shouldListen) {
      if (_speech.isAvailable && !_inForeground) {
        _setState(VoiceState.disabled, "等待回到前台");
      }
      return;
    }

    // The platform has not reported the previous session as finished yet.
    // Starting now would call listen() twice on one recognizer — the exact
    // cause of the on/off flicker.
    if (_sessionActive || _listenInFlight) return;

    _sessionActive = true;
    final token = ++_sessionToken;

    soundLevel.value = 0;
    if (immediate) wordsSpoken.value = "";

    final Duration delay;
    if (_consecutiveErrors > 0) {
      delay = _pick(_errorBackoff, _consecutiveErrors - 1);
    } else {
      delay = _pick(_idleBackoff, _consecutiveEmptySessions);
    }

    if (delay == Duration.zero) {
      _listen(token);
    } else {
      _setState(VoiceState.reconnecting, "正在重新连接语音引擎…");
      _restartTimer = Timer(delay, () {
        _restartTimer = null;
        _listen(token);
      });
    }
  }

  Future<void> _listen(int token) async {
    if (token != _sessionToken || _disposed) return;
    if (!_shouldListen) return;

    _listenInFlight = true;
    _setState(VoiceState.starting, "正在启动麦克风…");

    var failed = false;
    try {
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.confirmation,
          cancelOnError: false,
          partialResults: true,
          pauseFor: _pauseAfterSilence,
          listenFor: _maxSession,
          localeId: _localeId,
          contextualPhrases: _contextualPhrases,
        ),
        onSoundLevelChange: (level) {
          if (!_sessionActive) return;
          soundLevel.value = level;
        },
      );
    } catch (e) {
      debugPrint("listen() failed: $e");
      _sessionActive = false;
      _consecutiveErrors++;
      failed = true;
    } finally {
      _listenInFlight = false;
    }

    // Restart only after _listenInFlight is cleared, otherwise _beginSession
    // sees the in-flight flag and drops the restart, killing the mic for good.
    if (failed) _scheduleRestart();
  }

  /// Ends the current session and makes sure nothing restarts it.
  void _endSession() {
    _cancelRestart();
    _sessionToken++;
    _sessionActive = false;
    isListening.value = false;
    soundLevel.value = 0;
    if (_speech.isAvailable) {
      // cancel() rather than stop(): stop() keeps a final-result timer alive
      // that would fire a stray "done" status a couple of seconds later.
      unawaited(_speech.cancel());
    }
  }

  void _cancelRestart() {
    _restartTimer?.cancel();
    _restartTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  /// Queue exactly one restart, replacing any previous one.
  void _scheduleRestart() {
    _cancelRestart();
    if (!_shouldListen) return;
    _beginSession();
  }

  void _handleStatus(String status) {
    switch (status) {
      case 'listening':
        // A late "listening" from a session the user already cancelled must
        // not switch the UI back on.
        if (!_shouldListen) return;
        _consecutiveErrors = 0;
        _sessionActive = true;
        _setState(VoiceState.listening, "正在聆听：说“开门”或“关门”");

      case 'notListening':
        // Fired before the final result is delivered, so only arm the
        // watchdog here; 'done' normally arrives first.
        _sessionActive = false;
        if (!_shouldListen) return;
        _cancelRestart();
        _restartTimer = Timer(_doneWatchdog, () {
          _restartTimer = null;
          _beginSession();
        });

      case 'done':
        _sessionActive = false;
        if (!_shouldListen) {
          isListening.value = false;
          return;
        }
        // Every session that produced no words pushes the next one further
        // out, so an idle phone is not burning the microphone.
        _consecutiveEmptySessions = wordsSpoken.value.trim().isEmpty
            ? _consecutiveEmptySessions + 1
            : 0;
        // Stay "armed" across the renewal so the UI does not blink between
        // sessions.
        _setState(VoiceState.reconnecting, "正在重新连接语音引擎…");
        _cancelRestart();
        _restartTimer = Timer(_restartGap, () {
          _restartTimer = null;
          _beginSession();
        });
    }
  }

  void _handleError(SpeechRecognitionError error) {
    debugPrint("Speech error: ${error.errorMsg} (permanent: ${error.permanent})");
    _sessionActive = false;

    if (error.permanent) {
      // Permission revoked, no recognizer installed, etc. Do not spin.
      _cancelRestart();
      isListening.value = false;
      permissionDenied.value = error.errorMsg.contains('permission');
      _setState(VoiceState.unavailable, "语音识别出错: ${error.errorMsg}");
      return;
    }

    _consecutiveErrors++;
    _consecutiveEmptySessions = 0;
    if (!_shouldListen) {
      isListening.value = false;
      return;
    }
    _scheduleRestart();
  }

  void _handleResult(SpeechRecognitionResult result) {
    if (!_sessionActive && !_speech.isListening) return;
    wordsSpoken.value = result.recognizedWords;

    // Only the final result can open the gate. Matching on partials meant a
    // partial like "open" fired the door and the refined "open the door"
    // fired it again.
    if (!result.finalResult) return;

    _consecutiveEmptySessions = 0;
    _consecutiveErrors = 0;

    final match = matchCommand(result.recognizedWords);
    if (match == null) return;

    final last = _lastTriggerTime;
    if (last != null && DateTime.now().difference(last) < _commandCooldown) {
      debugPrint("Command '${match.phrase}' ignored (cooldown)");
      return;
    }

    _lastTriggerTime = DateTime.now();
    recognizedCommand.value = match.phrase;
    debugPrint("Command ${match.command} matched on '${match.phrase}'");

    // Close the mic straight away: the keyword is all we needed, and leaving
    // it open would let the gate motor noise trigger a second command.
    _endSession();
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_resumeAfterCommand, () {
      _resumeTimer = null;
      if (_shouldListen) _beginSession(immediate: true);
    });

    onDoorCommandDetected?.call(match.command);
  }

  void _setState(VoiceState next, String message) {
    if (_disposed) return;
    state.value = next;
    statusMessage.value = message;
    isListening.value = next == VoiceState.listening ||
        next == VoiceState.starting ||
        next == VoiceState.reconnecting;
  }

  static Duration _pick(List<Duration> steps, int index) {
    return steps[index.clamp(0, steps.length - 1)];
  }

  // --- Locale -------------------------------------------------------------

  String? _localeId;

  /// Chinese and English are both supported; default to whichever the device
  /// actually has installed for recognition so results are not garbled.
  Future<void> _detectLocale() async {
    try {
      final locales = await _speech.locales();
      bool has(String code) => locales.any((l) => l.localeId == code);
      if (has('zh_CN')) {
        _localeId = 'zh_CN';
      } else if (has('en_US')) {
        _localeId = 'en_US';
      }
      debugPrint("Speech locale: ${_localeId ?? 'system default'}");
    } catch (e) {
      debugPrint("Locale detection failed: $e");
    }
  }

  /// Biases the recogniser towards the phrases we care about (Android 13+).
  static const List<String> _contextualPhrases = [
    'open the door',
    'close the door',
    'half open the door',
    'open gate',
    'close gate',
    '开门',
    '关门',
    '半开门',
  ];

  // --- Command matching ---------------------------------------------------

  static final RegExp _cleaner = RegExp(r"[^a-z0-9\u4e00-\u9fff]+");

  /// Words that mean the person is talking to another app, not to us.
  static final RegExp _notForUs = RegExp(
    r'\b(app|apps|application|google|chrome|firefox|safari|browser|youtube|whatsapp|'
    r'telegram|wechat|facebook|instagram|tiktok|camera|photo|photos|gallery|'
    r'settings|setting|file|files|folder|tab|window|email|mail|message|messages|'
    r'call|alarm|reminder|note|notes|music|song|video|playlist|tv|light|lights|'
    r'fan|air|plug|socket|timer|schedule|calendar|chat|group|channel|news|'
    r'weather|map|maps|translate|dictionary|calculator|game|password|pin)\b',
  );

  static final List<RegExp> _openEn = [
    RegExp(r'\b(open|unlock|raise|lift)\b'),
  ];
  static final List<RegExp> _closeEn = [
    RegExp(r'\b(close|shut|lower|drop)\b'),
  ];
  static final RegExp _targetEn = RegExp(
    r'\b(door|doors|gate|gates|garage|barrier|shutter|roller)\b',
  );

  /// Half-open must be tested before open/close, because "half open the door"
  /// also satisfies the open rule.
  static final RegExp _halfOpenEn = RegExp(
    r'\bhalf[-\s]?open\b|\bhalf[-\s]?way\b|\bpartly\s+open\b|\bpartially\s+open\b',
  );

  static const List<String> _halfOpenZh = [
    '半开一半', '開一半門', '半开一下', '半開一下', '只开一半', '只開一半',
    '半开门', '半開門', '半开门', '半开', '半開', '开门一半', '開門一半',
    '开一半', '開一半', '开一半门', '開一半門',
  ];

  static const List<String> _openZh = [
    '开门', '開門', '开闸', '開閘', '打开门', '打開門', '打开大门', '门打开',
    '把门打开', '拉开门', '拉開門', '升起闸门', '升闸', '开一下门', '开门一下',
  ];
  static const List<String> _closeZh = [
    '关门', '關門', '关闸', '關閘', '关上', '關上', '拉上门', '拉上門',
    '门关上', '降下闸门', '降闸', '把门关上', '关一下门',
  ];

  /// Maps a transcript to a gate command.
  ///
  /// Requires an action verb *and* a door-like target so that "open the app"
  /// or "close the browser" never operates the gate, and so that background
  /// chatter does not trigger it. Half-open is checked first because its
  /// wording overlaps with open.
  static CommandMatch? matchCommand(String raw) {
    final text = raw.toLowerCase().replaceAll(_cleaner, ' ').trim();
    if (text.isEmpty) return null;
    if (_notForUs.hasMatch(text)) return null;

    // Half-open takes priority over both open and close.
    for (final phrase in _halfOpenZh) {
      if (text.contains(phrase)) return CommandMatch(kCommandHalfOpenDoor, phrase);
    }
    final halfEn = _halfOpenEn.firstMatch(text);
    if (halfEn != null) return CommandMatch(kCommandHalfOpenDoor, halfEn.group(0)!);

    // Chinese has no word boundaries, so match the phrases directly.
    for (final phrase in _closeZh) {
      if (text.contains(phrase)) return CommandMatch(kCommandCloseDoor, phrase);
    }
    for (final phrase in _openZh) {
      if (text.contains(phrase)) return CommandMatch(kCommandOpenDoor, phrase);
    }

    // English: verb + target.
    final hasTarget = _targetEn.hasMatch(text);
    if (!hasTarget) return null;

    for (final verb in _closeEn) {
      final hit = verb.firstMatch(text);
      if (hit != null) return CommandMatch(kCommandCloseDoor, hit.group(0)!);
    }
    for (final verb in _openEn) {
      final hit = verb.firstMatch(text);
      if (hit != null) return CommandMatch(kCommandOpenDoor, hit.group(0)!);
    }
    return null;
  }
}
