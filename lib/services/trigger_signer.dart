import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'gate_command.dart';

/// Builds the signed payload that the ESP32 firmware will accept before it
/// transmits any RF.
///
/// ## Why
///
/// The firmware used to fire its transmitter whenever the database simply
/// contained `"trigger": true`. The Realtime Database is publicly writable,
/// so *anyone* could open the gate by sending a single unauthenticated
/// request. Locking the database rules down is not an option on its own,
/// because the ESP32 connects anonymously and would then lose the ability to
/// read anything at all.
///
/// So the check moves to the only component that can actually actuate the
/// gate: the firmware. A trigger now carries an HMAC-SHA256 signature over a
/// timestamp and a nonce, and a trigger without a valid signature — or one
/// older than the replay window — is logged and dropped.
///
/// ## Honest limitation
///
/// The shared secret has to exist in both the app and the firmware, so a
/// determined attacker who unpacks the APK can recover it and forge triggers.
/// This stops drive-by and internet-scanner attacks, which is the realistic
/// threat here. The airtight version is Firebase Auth on the app plus the
/// Admin SDK on the ESP32 with server-side rules; that is a separate
/// migration and needs console access.
class TriggerSigner {
  const TriggerSigner._();

  /// How far a trigger's timestamp may drift before the firmware rejects it.
  /// Guards against a captured payload being replayed later.
  static const Duration replayWindow = Duration(seconds: 30);

  static final Random _random = Random.secure();

  /// The exact string both sides sign. Order and separator are part of the
  /// protocol — `ts:n:action`, no spaces. The action is inside the signature
  /// so a captured open cannot be replayed as a half-open.
  static String canonicalPayload(int timestamp, int nonce, GateAction action) =>
      '$timestamp:$nonce:${action.wire}';

  /// Lowercase hex HMAC-SHA256 of [canonicalPayload] under [secret].
  static String sign(
    String secret,
    int timestamp,
    int nonce,
    GateAction action,
  ) {
    final key = utf8.encode(secret);
    final message = utf8.encode(canonicalPayload(timestamp, nonce, action));
    return Hmac(sha256, key).convert(message).toString();
  }

  /// A signed trigger ready to be written to `/door_control/trigger_v2`.
  static Map<String, Object> buildPayload(
    String secret,
    GateAction action, {
    String? source,
  }) {
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    // Keeps the nonce unique even when two triggers land in the same second.
    final nonce = _random.nextInt(0x7fffffff);
    return <String, Object>{
      'sig': sign(secret, timestamp, nonce, action),
      'ts': timestamp,
      'n': nonce,
      'action': action.wire,
      if (source != null) 'by': source,
    };
  }

  /// Verification, mirroring the firmware. Used by the app's self-test so the
  /// secret can be confirmed before flashing.
  static bool verify(
    String secret,
    String signature,
    int timestamp,
    int nonce,
    GateAction action,
  ) {
    final expected = sign(secret, timestamp, nonce, action);
    return _constantTimeEquals(expected, signature);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a.toLowerCase());
    final y = utf8.encode(b.toLowerCase());
    if (x.length != y.length) return false;
    var diff = 0;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }
}
