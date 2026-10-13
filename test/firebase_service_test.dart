import 'package:autogate_app/services/firebase_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // GateService is a singleton, so each case resets the fields it touches.
  GateService withCreds(String apiKey, String url) {
    final s = GateService();
    s.apiKey = apiKey;
    s.databaseUrl = url;
    return s;
  }

  group('hasCredentials', () {
    test('accepts a bare host with no path', () {
      // Regression: Uri.parse('https://host') yields an EMPTY path, so
      // hasAbsolutePath is false and the status bar wrongly reported
      // "Cloud: Not configured" even though Firebase worked.
      expect(
        withCreds('AIza', 'https://wong-autogate-default-rtdb.asia-southeast1'
                '.firebasedatabase.app')
            .hasCredentials,
        isTrue,
      );
    });

    test('accepts a URL with a trailing slash or a path', () {
      expect(
        withCreds('AIza',
                'https://wong-autogate-default-rtdb.asia-southeast1.firebasedatabase.app/')
            .hasCredentials,
        isTrue,
      );
      expect(
        withCreds('AIza', 'https://example.com/foo').hasCredentials,
        isTrue,
      );
    });

    test('rejects missing pieces', () {
      expect(withCreds('', 'https://example.com').hasCredentials, isFalse);
      expect(withCreds('AIza', '').hasCredentials, isFalse);
      expect(withCreds('AIza', 'not a url').hasCredentials, isFalse);
      expect(withCreds('AIza', 'example.com').hasCredentials, isFalse,
          reason: 'no scheme');
      expect(withCreds('AIza', 'ftp://example.com').hasCredentials, isFalse,
          reason: 'wrong scheme');
      expect(withCreds('AIza', 'https://').hasCredentials, isFalse,
          reason: 'no host');
    });

    test('the default build ships no credentials', () {
      // Guards against someone hardcoding them again.
      final s = GateService();
      expect(s.apiKey, isNot(contains('AIzaSy')));
    });
  });
}
