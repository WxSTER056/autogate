import 'package:autogate_app/services/gate_command.dart';
import 'package:autogate_app/services/trigger_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TriggerSigner', () {
    // Cross-checked against Python:
    //   hmac.new(b"testsecret", b"1700000000:12345:toggle", sha256).hexdigest()
    // The ESP32 firmware must reproduce exactly the same value via
    // mbedtls_md_hmac, so these vectors pin the wire format.
    test('canonical payload is "<ts>:<nonce>:<action>"', () {
      expect(
        TriggerSigner.canonicalPayload(1700000000, 12345, GateAction.toggle),
        '1700000000:12345:toggle',
      );
      expect(
        TriggerSigner.canonicalPayload(1700000000, 12345, GateAction.halfOpen),
        '1700000000:12345:half_open',
      );
    });

    test('matches the known HMAC-SHA256 vectors', () {
      expect(
        TriggerSigner.sign('testsecret', 1700000000, 12345, GateAction.toggle),
        '2d620c4dd49c08405f5e4a7a982d235044f0ca9a57203819bd6129c5cacbbead',
      );
      expect(
        TriggerSigner.sign('testsecret', 1700000000, 12345, GateAction.halfOpen),
        '51e3d5bfa7041fcde74ba295470f9067ab356a44becef5c0499be1250f39a95a',
      );
    });

    test('the action is covered by the signature', () {
      // A captured open must not be replayable as a half-open.
      final open = TriggerSigner.sign('k', 1, 2, GateAction.toggle);
      final half = TriggerSigner.sign('k', 1, 2, GateAction.halfOpen);
      expect(open, isNot(half));
      expect(TriggerSigner.verify('k', open, 1, 2, GateAction.halfOpen), isFalse);
      expect(TriggerSigner.verify('k', open, 1, 2, GateAction.toggle), isTrue);
    });

    test('produces 64 lowercase hex characters', () {
      final sig = TriggerSigner.sign('any secret', 1, 2, GateAction.toggle);
      expect(sig, hasLength(64));
      expect(sig, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('different secrets produce different signatures', () {
      final a = TriggerSigner.sign('secret-a', 1700000000, 1, GateAction.toggle);
      final b = TriggerSigner.sign('secret-b', 1700000000, 1, GateAction.toggle);
      expect(a, isNot(b));
    });

    test('verify accepts a genuine signature and rejects a tampered one', () {
      final payload = TriggerSigner.buildPayload('s3cret', GateAction.halfOpen);
      final sig = payload['sig']! as String;
      final ts = payload['ts']! as int;
      final n = payload['n']! as int;

      expect(TriggerSigner.verify('s3cret', sig, ts, n, GateAction.halfOpen),
          isTrue);
      expect(TriggerSigner.verify('wrong', sig, ts, n, GateAction.halfOpen),
          isFalse);
      expect(TriggerSigner.verify('s3cret', sig, ts, n + 1, GateAction.halfOpen),
          isFalse);
      final flipped = sig.replaceRange(0, 1, sig[0] == 'a' ? 'b' : 'a');
      expect(
          TriggerSigner.verify('s3cret', flipped, ts, n, GateAction.halfOpen),
          isFalse);
      // Truncated signature must not throw.
      expect(
        TriggerSigner.verify('s3cret', sig.substring(0, 10), ts, n,
            GateAction.halfOpen),
        isFalse,
      );
    });

    test('payload carries the action and a recent timestamp', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final a = TriggerSigner.buildPayload('s3cret', GateAction.halfOpen);
      final b = TriggerSigner.buildPayload('s3cret', GateAction.toggle);

      expect(a['action'], 'half_open');
      expect(b['action'], 'toggle');
      expect(a['sig'], isNot(b['sig']));
      expect((a['ts']! as int) - now, lessThanOrEqualTo(2));
    });

    test('replay window is sane', () {
      expect(TriggerSigner.replayWindow.inSeconds, 30);
    });
  });

  group('GateAction', () {
    test('half open sends two triggers five seconds apart', () {
      expect(GateAction.halfOpen.pulseCount, 2);
      expect(GateAction.pulseGap, const Duration(seconds: 5));
    });

    test('toggle sends a single pulse', () {
      expect(GateAction.toggle.pulseCount, 1);
    });

    test('fromWire round-trips and falls back to toggle', () {
      for (final action in GateAction.values) {
        expect(GateAction.fromWire(action.wire), action);
      }
      expect(GateAction.fromWire(null), GateAction.toggle);
      expect(GateAction.fromWire('nonsense'), GateAction.toggle);
    });
  });
}
