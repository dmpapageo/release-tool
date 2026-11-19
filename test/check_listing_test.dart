import 'dart:io';

import 'package:release_tool/release_tool.dart';
import 'package:test/test.dart';

/// A complete, valid app folder: config, pubspec at build 7 and a fastlane
/// Listing for both stores in en-US. Tests override single files from here.
const _validApp = <String, String>{
  'release.yaml': '''
bundle_id: com.example.app
android_package: com.example.app
app_store_app_id: "1234567890"
locales: [en-US]
stores: [apple, play]
keys:
  app_store_connect: ASC_KEY_PATH
  play_service_account: PLAY_KEY_PATH
hud_file: hud.md
status_file: STATUS.md
''',
  'pubspec.yaml': 'name: example\nversion: 1.2.0+7\n',
  'fastlane/metadata/en-US/name.txt': 'Example App\n',
  'fastlane/metadata/en-US/subtitle.txt': 'Does one thing well\n',
  'fastlane/metadata/en-US/keywords.txt': 'example,sample,demo\n',
  'fastlane/metadata/en-US/description.txt': 'A longer description.\n',
  'fastlane/metadata/en-US/privacy_url.txt': 'https://example.com/privacy\n',
  'fastlane/metadata/en-US/support_url.txt': 'https://example.com/support\n',
  'fastlane/metadata/review_information/first_name.txt': 'Ada\n',
  'fastlane/metadata/review_information/last_name.txt': 'Lovelace\n',
  'fastlane/metadata/review_information/phone_number.txt': '+1 555 0100\n',
  'fastlane/metadata/review_information/email_address.txt': 'a@example.com\n',
  'fastlane/metadata/review_information/notes.txt': 'Add the widget.\n',
  'fastlane/metadata/android/en-US/title.txt': 'Example App\n',
  'fastlane/metadata/android/en-US/short_description.txt': 'Does one thing\n',
  'fastlane/metadata/android/en-US/full_description.txt': 'A longer one.\n',
  'fastlane/metadata/android/en-US/changelogs/7.txt': 'First build.\n',
};

class _Run {
  _Run(this.exitCode, this.out, this.err);
  final int exitCode;
  final String out;
  final String err;
}

void main() {
  late Directory app;

  setUp(() => app = Directory.systemTemp.createTempSync('release_tool_'));
  tearDown(() => app.deleteSync(recursive: true));

  /// Writes [_validApp] into the temp folder, with [changes] applied on top:
  /// a string replaces a file's contents, null removes the file.
  void writeApp([Map<String, String?> changes = const {}]) {
    final files = <String, String?>{..._validApp, ...changes};
    for (final MapEntry(:key, :value) in files.entries) {
      if (value == null) continue;
      File('${app.path}/$key')
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
  }

  _Run checkListing() {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = runRelease(
      ['check-listing', '--config', '${app.path}/release.yaml'],
      out: out,
      err: err,
    );
    return _Run(code, out.toString(), err.toString());
  }

  test('a valid Listing passes', () {
    writeApp();

    final run = checkListing();

    expect(run.exitCode, 0);
    expect(run.out, contains('Listing OK'));
    expect(run.err, isEmpty);
  });

  group('each missing required field is reported', () {
    const required = {
      'fastlane/metadata/en-US/name.txt': 'apple en-US name: missing',
      'fastlane/metadata/en-US/keywords.txt': 'apple en-US keywords: missing',
      'fastlane/metadata/en-US/description.txt':
          'apple en-US description: missing',
      'fastlane/metadata/en-US/privacy_url.txt':
          'apple en-US privacy_url: missing',
      'fastlane/metadata/en-US/support_url.txt':
          'apple en-US support_url: missing',
      'fastlane/metadata/review_information/first_name.txt':
          'apple review_information first_name: missing',
      'fastlane/metadata/review_information/last_name.txt':
          'apple review_information last_name: missing',
      'fastlane/metadata/review_information/phone_number.txt':
          'apple review_information phone_number: missing',
      'fastlane/metadata/review_information/email_address.txt':
          'apple review_information email_address: missing',
      'fastlane/metadata/android/en-US/title.txt': 'play en-US title: missing',
      'fastlane/metadata/android/en-US/short_description.txt':
          'play en-US short_description: missing',
      'fastlane/metadata/android/en-US/full_description.txt':
          'play en-US full_description: missing',
    };

    for (final MapEntry(key: file, value: problem) in required.entries) {
      test(file, () {
        writeApp({file: null});

        final run = checkListing();

        expect(run.exitCode, 1);
        expect(run.out, contains(problem));
      });
    }

    test('a file holding only whitespace counts as missing', () {
      writeApp({'fastlane/metadata/en-US/name.txt': '  \n'});

      final run = checkListing();

      expect(run.exitCode, 1);
      expect(run.out, contains('apple en-US name: missing'));
    });
  });

  test('optional fields may be left out', () {
    writeApp({
      'fastlane/metadata/en-US/subtitle.txt': null,
      'fastlane/metadata/review_information/notes.txt': null,
    });

    expect(checkListing().exitCode, 0);
  });

  group('each over-limit field is reported with its length and limit', () {
    // Limits from the spec (issue #8, user story 17).
    const limited = {
      'fastlane/metadata/en-US/name.txt': ('apple en-US name', 30),
      'fastlane/metadata/en-US/subtitle.txt': ('apple en-US subtitle', 30),
      'fastlane/metadata/en-US/keywords.txt': ('apple en-US keywords', 100),
      'fastlane/metadata/en-US/promotional_text.txt': (
        'apple en-US promotional_text',
        170,
      ),
      'fastlane/metadata/en-US/description.txt': (
        'apple en-US description',
        4000,
      ),
      'fastlane/metadata/en-US/release_notes.txt': (
        'apple en-US release_notes',
        4000,
      ),
      'fastlane/metadata/android/en-US/title.txt': ('play en-US title', 30),
      'fastlane/metadata/android/en-US/short_description.txt': (
        'play en-US short_description',
        80,
      ),
      'fastlane/metadata/android/en-US/full_description.txt': (
        'play en-US full_description',
        4000,
      ),
      'fastlane/metadata/android/en-US/changelogs/7.txt': (
        'play en-US changelogs/7',
        500,
      ),
    };

    for (final MapEntry(key: file, value: (field, limit)) in limited.entries) {
      test('$field over $limit', () {
        writeApp({file: '${'x' * (limit + 1)}\n'});

        final run = checkListing();

        expect(run.exitCode, 1);
        expect(
          run.out,
          contains('$field: ${limit + 1} characters, limit $limit'),
        );
      });

      test('$field at exactly $limit passes', () {
        writeApp({file: '${'x' * limit}\n'});

        expect(checkListing().exitCode, 0);
      });
    }
  });

  group('the Play changelog for the current build number', () {
    test('is reported when missing', () {
      writeApp({'fastlane/metadata/android/en-US/changelogs/7.txt': null});

      final run = checkListing();

      expect(run.exitCode, 1);
      expect(run.out, contains('play en-US changelogs/7: missing'));
    });

    test("is not satisfied by an earlier build's changelog", () {
      writeApp({
        'fastlane/metadata/android/en-US/changelogs/7.txt': null,
        'fastlane/metadata/android/en-US/changelogs/6.txt': 'Older build.\n',
      });

      final run = checkListing();

      expect(run.exitCode, 1);
      expect(run.out, contains('play en-US changelogs/7: missing'));
    });

    test('follows the build number in pubspec.yaml', () {
      writeApp({
        'pubspec.yaml': 'name: example\nversion: 1.2.0+8\n',
      });

      final run = checkListing();

      expect(run.exitCode, 1);
      expect(run.out, contains('play en-US changelogs/8: missing'));
    });

    test('is reported as unknowable when pubspec.yaml has no build number', () {
      writeApp({'pubspec.yaml': 'name: example\nversion: 1.2.0\n'});

      final run = checkListing();

      expect(run.exitCode, 1);
      expect(
        run.out,
        contains('pubspec.yaml: no build number in "version"'),
      );
    });
  });

  test('several problems are all reported in one run', () {
    writeApp({
      'fastlane/metadata/en-US/name.txt': '${'x' * 31}\n',
      'fastlane/metadata/review_information/phone_number.txt': null,
      'fastlane/metadata/android/en-US/title.txt': null,
      'fastlane/metadata/android/en-US/short_description.txt': '${'x' * 81}\n',
    });

    final run = checkListing();

    expect(run.exitCode, 1);
    expect(
      run.out,
      allOf(
        contains('apple en-US name: 31 characters, limit 30'),
        contains('apple review_information phone_number: missing'),
        contains('play en-US title: missing'),
        contains('play en-US short_description: 81 characters, limit 80'),
        contains('4 problem(s) in the Listing'),
      ),
    );
  });

  test('every configured locale is checked', () {
    writeApp({
      'release.yaml': _validApp['release.yaml']!.replaceFirst(
        'locales: [en-US]',
        'locales: [en-US, de-DE]',
      ),
    });

    final run = checkListing();

    expect(run.exitCode, 1);
    expect(
      run.out,
      allOf(
        contains('apple de-DE name: missing'),
        contains('play de-DE title: missing'),
        isNot(contains('en-US')),
      ),
    );
  });

  test('a store left out of the config is not checked', () {
    writeApp({
      'release.yaml': _validApp['release.yaml']!.replaceFirst(
        'stores: [apple, play]',
        'stores: [apple]',
      ),
      'fastlane/metadata/android/en-US/title.txt': null,
      'pubspec.yaml': 'name: example\nversion: 1.2.0\n',
    });

    expect(checkListing().exitCode, 0);
  });

  group('a bad command line or config is a usage error', () {
    test('no command', () {
      final err = StringBuffer();

      final code = runRelease([], out: StringBuffer(), err: err);

      expect(code, 64);
      expect(err.toString(), contains('check-listing'));
    });

    test('an unknown command', () {
      final err = StringBuffer();

      final code = runRelease(['ship-it'], out: StringBuffer(), err: err);

      expect(code, 64);
      expect(err.toString(), contains('ship-it'));
    });

    test('a missing config file', () {
      final run = checkListing();

      expect(run.exitCode, 64);
      expect(run.err, contains('release.yaml'));
    });

    test('a config without a required value', () {
      writeApp({
        'release.yaml': _validApp['release.yaml']!.replaceFirst(
          'bundle_id: com.example.app\n',
          '',
        ),
      });

      final run = checkListing();

      expect(run.exitCode, 64);
      expect(run.err, contains('bundle_id'));
    });

    test('a config with an unknown store', () {
      writeApp({
        'release.yaml': _validApp['release.yaml']!.replaceFirst(
          'stores: [apple, play]',
          'stores: [apple, steam]',
        ),
      });

      final run = checkListing();

      expect(run.exitCode, 64);
      expect(run.err, contains('steam'));
    });
  });
}
