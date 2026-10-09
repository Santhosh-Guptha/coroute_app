import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/l10n/strings_core.dart';
import 'package:coroute_app/core/l10n/strings_safety.dart';
import 'package:coroute_app/core/l10n/strings_screens.dart';
import 'package:flutter_test/flutter_test.dart';

/// English words allowed inside Hindi and Telugu strings (plus the weather attribution name).
const allowedWords = ['CoRoute', 'SOS', 'OK', 'km', 'min', '112', 'Open-Meteo.com'];

final placeholder = RegExp(r'\{[A-Za-z0-9_]+\}');
final latin = RegExp(r'[A-Za-z]');
// Em dash, en dash, emoji ranges (symbols and pictographs, emoticons, transport, flags).
final dashes = RegExp(r'[\u2013\u2014]');
final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}]', unicode: true);

void main() {
  setUp(() {
    L10n.systemLanguage = 'en';
    L10n.setLanguage(AppLanguage.system);
  });

  group('AppLanguage', () {
    test('codes, labels, tags, fromCode', () {
      expect(AppLanguage.values.map((l) => l.code), ['system', 'en', 'hi', 'te']);
      expect(AppLanguage.hi.label, 'हिन्दी');
      expect(AppLanguage.te.label, 'తెలుగు');
      expect(AppLanguage.en.label, 'English');
      expect(AppLanguage.system.label, 'System language');
      expect(AppLanguage.system.ttsTag, '');
      expect(AppLanguage.en.ttsTag, 'en-IN');
      expect(AppLanguage.hi.ttsTag, 'hi-IN');
      expect(AppLanguage.te.ttsTag, 'te-IN');
      expect(AppLanguage.fromCode('te'), AppLanguage.te);
      expect(AppLanguage.fromCode('HI '), AppLanguage.hi);
      expect(AppLanguage.fromCode(null), AppLanguage.system);
      expect(AppLanguage.fromCode('fr'), AppLanguage.system);
    });
  });

  group('L10n.current and ttsTag', () {
    test('system language hi/te is used, anything else falls back to English', () {
      L10n.systemLanguage = 'hi';
      expect(L10n.current, 'hi');
      expect(L10n.ttsTag, 'hi-IN');
      L10n.systemLanguage = 'te';
      expect(L10n.current, 'te');
      expect(L10n.ttsTag, 'te-IN');
      L10n.systemLanguage = 'ta';
      expect(L10n.current, 'en');
      expect(L10n.ttsTag, 'en-IN');
      // An explicit choice wins over the phone's language.
      L10n.setLanguage(AppLanguage.te);
      L10n.systemLanguage = 'hi';
      expect(L10n.current, 'te');
      L10n.setLanguage(AppLanguage.en);
      expect(L10n.current, 'en');
    });

    test('changes fires with the language in use', () {
      final seen = <String>[];
      void listen() => seen.add(L10n.changes.value);
      L10n.changes.addListener(listen);
      L10n.setLanguage(AppLanguage.hi);
      L10n.setLanguage(AppLanguage.te);
      L10n.setLanguage(AppLanguage.system);
      L10n.changes.removeListener(listen);
      expect(seen, ['hi', 'te', 'en']);
      expect(L10n.changes.value, 'en');
    });
  });

  group('L10n.t', () {
    test('placeholders, fallback chain and has()', () {
      expect(L10n.t('alert.battery.title', {'name': 'Kiran', 'n': 14}), 'Kiran 14% battery');
      expect(L10n.t('alert.battery.title', {'name': 'Kiran', 'n': 14}, 'hi'), 'Kiran की बैटरी 14%');
      expect(L10n.t('alert.battery.title', {'name': 'Kiran', 'n': 14}, 'te'), 'Kiran బ్యాటరీ 14%');
      // A missing argument leaves the placeholder visible rather than dropping the text.
      expect(L10n.t('alert.battery.title', {'name': 'Kiran'}), 'Kiran {n}% battery');
      // Unknown language: English.
      expect(L10n.t('lang.title', const {}, 'fr'), 'Language');
      // Unknown key: the key itself.
      expect(L10n.t('no.such.key'), 'no.such.key');
      expect(L10n.t('no.such.key', const {}, 'hi'), 'no.such.key');
      expect(L10n.has('lang.title'), isTrue);
      expect(L10n.has('lang.title', 'te'), isTrue);
      expect(L10n.has('no.such.key'), isFalse);
      L10n.setLanguage(AppLanguage.hi);
      expect(L10n.t('lang.title'), 'भाषा');
      expect(L10n.t('lang.title', const {}, 'en'), 'Language');
    });

    test('tables are the three owners in order', () {
      expect(L10n.tables.length, 3);
      expect(identical(L10n.tables[0], coreStrings), isTrue);
      expect(identical(L10n.tables[1], safetyStrings), isTrue);
      expect(identical(L10n.tables[2], screenStrings), isTrue);
      expect(L10n.supported, ['en', 'hi', 'te']);
    });
  });

  group('Translation tables', () {
    final tables = {'core': coreStrings, 'safety': safetyStrings, 'screens': screenStrings};

    test('every table has en, hi and te', () {
      for (final e in tables.entries) {
        expect(e.value.keys.toSet(), {'en', 'hi', 'te'}, reason: e.key);
      }
    });

    test('the contract keys exist in English', () {
      const core = [
        'alert.emergency.title', 'alert.accident.body', 'alert.help.body', 'alert.report.title', 'alert.report.body', 'alert.report.self',
        'alert.automatic', 'alert.stale.title', 'alert.stale.body', 'alert.battery.title', 'alert.battery.body', 'alert.battery.self.title',
        'alert.battery.self.body', 'alert.behind.title', 'alert.behind.body', 'alert.behind.self', 'alert.overspeed.town', 'alert.far.body',
        'alert.hospital', 'speech.emergency', 'speech.help', 'speech.report', 'speech.assist', 'speech.hazard', 'speech.stale', 'speech.behind',
        'speech.battery', 'speech.stopped', 'speech.separated', 'speech.separated.self', 'lang.title', 'lang.hint',
      ];
      for (final k in core) {
        expect(coreStrings['en']!.containsKey(k), isTrue, reason: k);
      }
      for (final prefix in ['notif.', 'prompt.', 'fuel.', 'dark.', 'weather.']) {
        expect(safetyStrings['en']!.keys.any((k) => k.startsWith(prefix)), isTrue, reason: prefix);
      }
      for (final prefix in ['crash.', 'sos.', 'incident.', 'assist.', 'hazard.', 'settings.', 'card.', 'report.']) {
        expect(screenStrings['en']!.keys.any((k) => k.startsWith(prefix)), isTrue, reason: prefix);
      }
    });

    test('key parity: every key in en exists in hi and te and the other way round, no empty values', () {
      for (final e in tables.entries) {
        final en = e.value['en']!;
        for (final lang in ['hi', 'te']) {
          final other = e.value[lang]!;
          expect(other.keys.toSet(), en.keys.toSet(), reason: '${e.key}/$lang keys differ from en');
          for (final k in en.keys) {
            expect(en[k]!.trim(), isNotEmpty, reason: '${e.key}/en/$k');
            expect(other[k]!.trim(), isNotEmpty, reason: '${e.key}/$lang/$k');
          }
        }
      }
    });

    test('placeholders match the English ones exactly', () {
      for (final e in tables.entries) {
        final en = e.value['en']!;
        for (final lang in ['hi', 'te']) {
          for (final k in en.keys) {
            final want = placeholder.allMatches(en[k]!).map((m) => m.group(0)).toSet();
            final have = placeholder.allMatches(e.value[lang]![k] ?? '').map((m) => m.group(0)).toSet();
            expect(have, want, reason: '${e.key}/$lang/$k');
          }
        }
      }
    });

    test('no English letters in hi/te values except the allowed words, no dashes, no emoji anywhere', () {
      for (final e in tables.entries) {
        for (final lang in ['en', 'hi', 'te']) {
          for (final kv in e.value[lang]!.entries) {
            final v = kv.value;
            expect(dashes.hasMatch(v), isFalse, reason: '${e.key}/$lang/${kv.key} has a dash');
            expect(emoji.hasMatch(v), isFalse, reason: '${e.key}/$lang/${kv.key} has an emoji');
            if (lang == 'en') continue;
            var stripped = v.replaceAll(placeholder, '');
            for (final w in allowedWords) {
              stripped = stripped.replaceAll(w, '');
            }
            expect(latin.hasMatch(stripped), isFalse, reason: '${e.key}/$lang/${kv.key} has English words: $v');
          }
        }
      }
    });

    test('keys are not duplicated between tables', () {
      final seen = <String, String>{};
      for (final e in tables.entries) {
        for (final k in e.value['en']!.keys) {
          expect(seen.containsKey(k), isFalse, reason: '$k in both ${seen[k]} and ${e.key}');
          seen[k] = e.key;
        }
      }
    });
  });
}
