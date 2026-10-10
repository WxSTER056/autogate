import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'trigger_signer.dart';

class GateService {
  static final GateService _instance = GateService._internal();
  factory GateService() => _instance;
  GateService._internal();

  // Default configuration based on user's project (Singapore / Southeast Asia)
  String projectId = "wong-autogate";
  String apiKey = "AIzaSyBCv87FCAqupLdMydOxvVm6M-Z_ZfYXMBU";
  String databaseUrl = "https://wong-autogate-default-rtdb.asia-southeast1.firebasedatabase.app";

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
    final payload = TriggerSigner.buildPayload(secret);
    return TriggerSigner.verify(
      secret,
      payload['sig']! as String,
      payload['ts']! as int,
      payload['n']! as int,
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
      addLog("Firebase initialized successfully!");
      return true;
    } catch (e) {
      addLog("Firebase init warning: $e");
      // Still mark initialized so REST fallback or retries can happen
      _isInitialized = true;
      return false;
    }
  }

  /// Sends the trigger signal to open/close the door
  Future<bool> sendTriggerSignal({String source = "Manual Button"}) async {
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    lastTriggerTime.value = timeStr;

    addLog("Trigger requested via $source");

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
          'last_triggered_time': now.toIso8601String(),
        };

        if (signed) {
          final signed2 = TriggerSigner.buildPayload(triggerSecret);
          // Firmware drops anything without a valid signature, so the legacy
          // unsigned boolean is deliberately not written any more.
          payload['trigger_v2'] = signed2;
          payload['trigger'] = false;
          addLog("Signed trigger -> ts=${signed2['ts']} n=${signed2['n']} "
              "sig=${_abbreviate(signed2['sig']! as String)}");
        } else {
          payload['trigger'] = true;
        }

        await _dbRef!.child('door_control').update(payload);
        isTriggerActive.value = true;
        doorStatus.value = "triggering";
        addLog(signed
            ? "Signed trigger written to /door_control/trigger_v2"
            : "Signal sent successfully to /door_control/trigger = true");
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
        final p = TriggerSigner.buildPayload(triggerSecret);
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
