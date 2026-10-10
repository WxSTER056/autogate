import 'package:autogate_app/services/trigger_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TriggerSigner', () {
    // Cross-checked against Python:
    //   hmac.new(b"testsecret", b"1700000000:12345", hashlib.sha256).hexdigest()
    // The ESP32 firmware must reproduce exactly the same value via
    // mbedtls_md_hmac, so this vector pins the wire format.
    test('canonical payload is "<ts>:<nonce>"', () {
      expect(TriggerSigner.canonicalPayload(1700000000, 12345),
          '1700000000:12345');
    });

    test('matches the known HMAC-SHA256 vector', () {
      expect(
        TriggerSigner.sign('testsecret', 1700000000, 12345),
        '4ef4c7eea7fb01dc104f0038df070e6a181dcb1df86bebfaa9a5496393ee0183',
      );
    });

    test('produces 64 lowercase hex characters', () {
      final sig = TriggerSigner.sign('any secret', 1, 2);
      expect(sig, hasLength(64));
      expect(sig, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('different secrets produce different signatures', () {
      final a = TriggerSigner.sign('secret-a', 1700000000, 1);
      final b = TriggerSigner.sign('secret-b', 1700000000, 1);
      expect(a, isNot(b));
    });

    test('verify accepts a genuine signature and rejects a tampered one', () {
      final payload = TriggerSigner.buildPayload('s3cret');
      final sig = payload['sig']! as String;
      final ts = payload['ts']! as int;
      final n = payload['n']! as int;

      expect(TriggerSigner.verify('s3cret', sig, ts, n), isTrue);
      expect(TriggerSigner.verify('wrong', sig, ts, n), isFalse);
      expect(TriggerSigner.verify('s3cret', sig, ts, n + 1), isFalse);
      // Flipped character.
      final flipped = sig.replaceRange(0, 1, sig[0] == 'a' ? 'b' : 'a');
      expect(TriggerSigner.verify('s3cret', flipped, ts, n), isFalse);
      // Truncated signature must not throw.
      expect(TriggerSigner.verify('s3cret', sig.substring(0, 10), ts, n), isFalse);
    });

    test('payloads are unique and carry a recent timestamp', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final a = TriggerSigner.buildPayload('s3cret');
      final b = TriggerSigner.buildPayload('s3cret');

      expect(a['sig'], isNot(b['sig']), reason: 'nonce must vary per trigger');
      expect((a['ts']! as int) - now, lessThanOrEqualTo(2));
      expect(a['n'], isA<int>());
    });

    test('replay window is sane', () {
      expect(TriggerSigner.replayWindow.inSeconds, 30);
    });
  });
}
