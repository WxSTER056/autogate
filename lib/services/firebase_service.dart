import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'gate_command.dart';
import 'trigger_signer.dart';

class GateService {
  static final GateService _instance = GateService._internal();
  factory GateService() => _instance;
  GateService._internal();

  // Firebase settings are injected at build time so they are not committed:
  //
  //   flutter build apk --release \
  //     --dart-define=FIREBASE_PROJECT_ID=... \
  //     --dart-define=FIREBASE_API_KEY=... \
  //     --dart-define=FIREBASE_DATABASE_URL=...
  //
  // When left empty they can still be filled in from the in-app settings
  // dialog, which is the fallback for anyone building from a clean checkout.
  String projectId = const String.fromEnvironment('FIREBASE_PROJECT_ID');
  String apiKey = const String.fromEnvironment('FIREBASE_API_KEY');
  String databaseUrl = const String.fromEnvironment('FIREBASE_DATABASE_URL');

  /// True once we have enough to talk to the database. False means the app was
  /// built without `--dart-define` and the user has to fill in Settings.
  bool get hasCredentials =>
      apiKey.isNotEmpty &&
      databaseUrl.isNotEmpty &&
      Uri.tryParse(databaseUrl)?.hasAbsolutePath == true;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Shared secret used to sign triggers. Must match `GATE_TRIGGER_SECRET` in
  /// the ESP32 `secrets.h`.
  String triggerSecret = "";

  /// When true the app writes a signed payload to `/door_control/trigger_v2`
  /// and stops writing the legacy unsigned boolean.
  ///
  /// Off by default so the app keeps working with firmware that predates the
  /// signature check. Turn it on only once the ESP32 has been reflashed.
  bool secureTriggerMode = false;

  /// Self-test for [triggerSecret], surfaced in the settings dialog.
  bool verifySecret(String secret) {
    if (secret.isEmpty) return false;
    final payload = TriggerSigner.buildPayload(secret, GateAction.toggle);
    return TriggerSigner.verify(
      secret,
      payload['sig']! as String,
      payload['ts']! as int,
      payload['n']! as int,
      GateAction.toggle,
    );
  }

  DatabaseReference? _dbRef;
  StreamSubscription<DatabaseEvent>? _triggerSubscription;
  StreamSubscription<DatabaseEvent>? _signedTriggerSubscription;
  StreamSubscription<DatabaseEvent>? _statusSubscription;
  StreamSubscription<DatabaseEvent>? _connectedSubscription;

  // Reactive notifiers for UI
  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isTriggerActive = ValueNotifier<bool>(false);
  final ValueNotifier<String> doorStatus = ValueNotifier<String>("ready");
  final ValueNotifier<String?> lastTriggerTime = ValueNotifier<String?>(null);
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  /// False until we know we have working Firebase settings.
  final ValueNotifier<bool> isConfigured = ValueNotifier<bool>(false);

  void _setConfigured(bool value) {
    isConfigured.value = value;
  }

  void addLog(String message) {
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    final logEntry = "[$timeStr] $message";
    logs.value = [logEntry, ...logs.value.take(49)];
    debugPrint(logEntry);
  }

  /// Initialize Firebase with custom or default credentials
  Future<bool> initialize({String? customApiKey, String? customDbUrl, String? customProjectId}) async {
    if (customApiKey != null && customApiKey.isNotEmpty) apiKey = customApiKey;
    if (customDbUrl != null && customDbUrl.isNotEmpty) {
      // Normalize URL (strip trailing slashes)
      databaseUrl = customDbUrl.replaceAll(RegExp(r'/+$'), '');
    }
    if (customProjectId != null && customProjectId.isNotEmpty) projectId = customProjectId;

    if (!hasCredentials) {
      addLog("Firebase 未设定：请在右上角设置中填写 API Key 与数据库网址，"
          "或使用 --dart-define 在编译时注入。语音功能不受影响。");
      _setConfigured(false);
      return false;
    }

    try {
      addLog("Initializing Firebase for project: $projectId...");

      FirebaseOptions options = FirebaseOptions(
        apiKey: apiKey.isNotEmpty ? apiKey : "dummy_api_key",
        appId: "1:100000000000:android:autogateapp",
        messagingSenderId: "100000000000",
        projectId: projectId,
        databaseURL: databaseUrl,
      );

      // Check if already initialized
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: options);
      }

      final app = Firebase.app();
      final database = FirebaseDatabase.instanceFor(
        app: app,
        databaseURL: databaseUrl,
      );

      _dbRef = database.ref();

      // Cancel previous subscriptions if any
      await _triggerSubscription?.cancel();
      await _signedTriggerSubscription?.cancel();
      await _statusSubscription?.cancel();
      await _connectedSubscription?.cancel();

      // Listen to connection state
      _connectedSubscription = database.ref('.info/connected').onValue.listen((event) {
        final connected = (event.snapshot.value as bool?) ?? false;
        isConnected.value = connected;
        addLog(connected ? "Connected to Firebase Cloud" : "Firebase Disconnected / Reconnecting...");
      }, onError: (err) {
        addLog("Connection stream error: $err");
      });

      // Listen to /door_control/trigger
      _triggerSubscription = _dbRef!.child('door_control/trigger').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is bool) {
          isTriggerActive.value = val;
          if (val) {
            addLog("Trigger active: ESP32 signal requested");
          }
        }
      }, onError: (err) {
        addLog("Trigger listener error: $err");
      });

      // Listen to /door_control/trigger_v2 (signed, secure mode)
      _signedTriggerSubscription =
          _dbRef!.child('door_control/trigger_v2').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          isTriggerActive.value = true;
          final sig = val['sig']?.toString() ?? '';
          addLog("Signed trigger present: ts=${val['ts']} n=${val['n']} "
              "sig=${_abbreviate(sig)}");
        }
      }, onError: (err) {
        addLog("Signed trigger listener error: $err");
      });

      // Listen to /door_control/status
      _statusSubscription = _dbRef!.child('door_control/status').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val != null) {
          final statusStr = val.toString();
          doorStatus.value = statusStr;
          addLog("ESP32 Status updated: $statusStr");
        }
      }, onError: (err) {
        addLog("Status listener error: $err");
      });

      _isInitialized = true;
      _setConfigured(true);
      addLog("Firebase initialized successfully!");
      return true;
    } catch (e) {
      addLog("Firebase init warning: $e");
      // Still mark initialized so REST fallback or retries can happen
      _isInitialized = true;
      return false;
    }
  }

  /// Sends the trigger signal to open/close the door.
  ///
  /// [action] tells the firmware how many RF pulses to emit: one for
  /// [GateAction.toggle], two three seconds apart for [GateAction.halfOpen].
  Future<bool> sendTriggerSignal({
    String source = "Manual Button",
    GateAction action = GateAction.toggle,
  }) async {
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    lastTriggerTime.value = timeStr;

    addLog("Trigger requested via $source (${action.wire})");

    // 半开门和一键开关门完全一样，只是发完第一次后再等 5 秒补发一次。
    for (var i = 1; i <= action.pulseCount; i++) {
      if (i > 1) {
        addLog("半开门：等待 ${GateAction.pulseGap.inSeconds} 秒后补发第 $i 次讯号…");
        await Future<void>.delayed(GateAction.pulseGap);
      }
      final ok = await _sendOnce(source);
      if (!ok) {
        addLog("第 $i 次讯号发送失败，半开门中止。");
        return false;
      }
    }

    if (action.pulseCount > 1) {
      addLog("半开门完成：已发送 ${action.pulseCount} 次讯号。");
    }
    return true;
  }

  /// Writes a single trigger. Always a plain toggle, so every pulse maps to
  /// exactly one RF transmission regardless of the firmware version.
  Future<bool> _sendOnce(String source) async {
    final signed = secureTriggerMode && triggerSecret.isNotEmpty;
    if (secureTriggerMode && triggerSecret.isEmpty) {
      addLog("Secure mode is on but no secret is set - falling back to "
          "the unsigned trigger. Set the secret in Settings!");
    }

    try {
      if (_dbRef != null) {
        final payload = <String, Object?>{
          'status': 'triggering',
          'last_triggered_by': source,
          'last_triggered_time': DateTime.now().toIso8601String(),
        };

        if (signed) {
          final signedPayload =
              TriggerSigner.buildPayload(triggerSecret, GateAction.toggle,
                  source: source);
          // Firmware drops anything without a valid signature, so the legacy
          // unsigned boolean is deliberately not written any more.
          payload['trigger_v2'] = signedPayload;
          payload['trigger'] = false;
          addLog("Signed trigger -> ts=${signedPayload['ts']} "
              "n=${signedPayload['n']} "
              "sig=${_abbreviate(signedPayload['sig']! as String)}");
        } else {
          payload['trigger'] = true;
        }

        await _dbRef!.child('door_control').update(payload);
        isTriggerActive.value = true;
        doorStatus.value = "triggering";
        addLog(signed
            ? "Signed trigger written to /door_control/trigger_v2"
            : "Signal sent to /door_control/trigger = true");
        return true;
      } else {
        addLog("Database reference not ready. Trying HTTP REST fallback...");
        return await _sendTriggerViaRest(source);
      }
    } catch (e) {
      addLog("Error sending trigger via SDK: $e. Falling back to HTTP REST...");
      return await _sendTriggerViaRest(source);
    }
  }

  static String _abbreviate(String value) =>
      value.length <= 12 ? value : '${value.substring(0, 12)}...';

  /// Fallback using Firebase Realtime Database REST API
  Future<bool> _sendTriggerViaRest(String source) async {
    try {
      final url = Uri.parse("$databaseUrl/door_control.json");
      final signed = secureTriggerMode && triggerSecret.isNotEmpty;
      final body = <String, Object?>{
        "status": "triggering",
        "last_triggered_by": source,
        "last_triggered_time": DateTime.now().toIso8601String(),
      };
      if (signed) {
        final p =
            TriggerSigner.buildPayload(triggerSecret, GateAction.toggle, source: source);
        body["trigger_v2"] = p;
        body["trigger"] = false;
      } else {
        body["trigger"] = true;
      }

      final client = HttpClient();
      final request = await client.patchUrl(url);
      request.headers.set('content-type', 'application/json');
      request.write(jsonEncode(body));
      final response = await request.close();
      client.close();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        addLog("Signal sent via REST API successfully!");
        isTriggerActive.value = true;
        doorStatus.value = "triggering";
        return true;
      } else {
        addLog("REST API returned code: ${response.statusCode}");
        return false;
      }
    } catch (e) {
      addLog("REST API error: $e");
      return false;
    }
  }

  void dispose() {
    _triggerSubscription?.cancel();
    _signedTriggerSubscription?.cancel();
    _statusSubscription?.cancel();
    _connectedSubscription?.cancel();
  }
}
