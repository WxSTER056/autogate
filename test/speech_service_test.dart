import 'package:autogate_app/services/speech_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchCommand', () {
    test('matches the documented English commands', () {
      for (final phrase in [
        'open the door',
        'Open the door.',
        'please open the gate',
        'close the door',
        'close gate',
        'shut the garage door',
        'raise the shutter',
      ]) {
        expect(
          SpeechService.matchCommand(phrase)?.command,
          isNotNull,
          reason: '"$phrase" should be recognised',
        );
      }

      expect(SpeechService.matchCommand('open the door')!.command, kCommandOpenDoor);
      expect(SpeechService.matchCommand('close the door')!.command, kCommandCloseDoor);
      expect(SpeechService.matchCommand('shut the garage')!.command, kCommandCloseDoor);
    });

    test('matches Chinese commands', () {
      expect(SpeechService.matchCommand('开门')!.command, kCommandOpenDoor);
      expect(SpeechService.matchCommand('把门打开')!.command, kCommandOpenDoor);
      expect(SpeechService.matchCommand('打开大门')!.command, kCommandOpenDoor);
      expect(SpeechService.matchCommand('開門')!.command, kCommandOpenDoor);
      expect(SpeechService.matchCommand('关门')!.command, kCommandCloseDoor);
      expect(SpeechService.matchCommand('把门关上')!.command, kCommandCloseDoor);
      expect(SpeechService.matchCommand('關門')!.command, kCommandCloseDoor);
    });

    test('ignores commands aimed at other apps', () {
      for (final phrase in [
        'open the app',
        'close the browser',
        'open google',
        'close the tab',
        'turn on the camera',
        'play some music',
        'open the app store',
      ]) {
        expect(
          SpeechService.matchCommand(phrase),
          isNull,
          reason: '"$phrase" must not open the gate',
        );
      }
    });

    test('requires a door-like target for English verbs', () {
      // The old implementation matched the bare words "open"/"close", which
      // fired the gate on any unrelated chatter.
      expect(SpeechService.matchCommand('open'), isNull);
      expect(SpeechService.matchCommand('close'), isNull);
      expect(SpeechService.matchCommand('I have to close my eyes'), isNull);
      expect(SpeechService.matchCommand('that is very open'), isNull);
    });

    test('rejects empty and punctuation-only input', () {
      expect(SpeechService.matchCommand(''), isNull);
      expect(SpeechService.matchCommand('   '), isNull);
      expect(SpeechService.matchCommand('...?!'), isNull);
    });

    test('prefers close when both verbs appear', () {
      expect(
        SpeechService.matchCommand('open the door then close the gate')!.command,
        kCommandCloseDoor,
      );
    });
  });
}
