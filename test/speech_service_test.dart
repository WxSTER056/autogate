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

  group('matchCommand - half open', () {
    test('matches English half-open phrasings', () {
      for (final phrase in [
        'half open the door',
        'half-open the door',
        'half open',
        'open the door halfway',
        'open the door half way',
        'open halfway',
        'partially open the gate',
      ]) {
        expect(
          SpeechService.matchCommand(phrase)?.command,
          kCommandHalfOpenDoor,
          reason: '"$phrase" should be half-open',
        );
      }
    });

    test('matches Chinese half-open phrasings', () {
      for (final phrase in [
        '半开',
        '半開',
        '半开门',
        '開一半',
        '开一半',
        '开门一半',
      ]) {
        expect(
          SpeechService.matchCommand(phrase)?.command,
          kCommandHalfOpenDoor,
          reason: '"$phrase" should be half-open',
        );
      }
    });

    test('half-open wins over the plain open rule', () {
      // "half open the door" also satisfies the open rule (open + door),
      // which used to resolve to a full open.
      final match = SpeechService.matchCommand('half open the door')!;
      expect(match.command, kCommandHalfOpenDoor);
      expect(match.command, isNot(kCommandOpenDoor));
    });

    test('plain open is still a full open', () {
      expect(
          SpeechService.matchCommand('open the door')!.command, kCommandOpenDoor);
      expect(SpeechService.matchCommand('开门')!.command, kCommandOpenDoor);
      // "half" must be a whole word, never the tail of another word.
      expect(SpeechService.matchCommand('open the halfhearted door')?.command,
          kCommandOpenDoor);
    });
  });
}
