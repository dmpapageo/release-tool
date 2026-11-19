import 'dart:io';

import 'package:release_tool/release_tool.dart';
import 'package:test/test.dart';

const _config = '''
bundle_id: com.example.app
android_package: com.example.app
locales: [en-US]
stores: [apple, play]
''';

const _pubspec = '''
name: example
description: An app.
version: 1.2.0+7

environment:
  sdk: ^3.12.0
''';

const _changelog = 'fastlane/metadata/android/en-US/changelogs';

class _Run {
  _Run(this.exitCode, this.out, this.err);
  final int exitCode;
  final String out;
  final String err;
}

void main() {
  late Directory repo;

  String git(List<String> args) {
    final result = Process.runSync('git', ['-C', repo.path, ...args]);
    expect(result.exitCode, 0, reason: 'git $args: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  void write(String path, String contents) => File('${repo.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  /// A committed fixture repo at 1.2.0+7 with a Play changelog for build 7.
  setUp(() {
    repo = Directory.systemTemp.createTempSync('release_tool_bump_');
    write('release.yaml', _config);
    write('pubspec.yaml', _pubspec);
    write('$_changelog/7.txt', 'Seventh build.\n');
    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.email', 'test@example.com']);
    git(['config', 'user.name', 'Test']);
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'Fixture']);
  });
  tearDown(() => repo.deleteSync(recursive: true));

  _Run run(List<String> args) {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = runRelease(
      ['bump', '--config', '${repo.path}/release.yaml', ...args],
      out: out,
      err: err,
    );
    return _Run(code, out.toString(), err.toString());
  }

  String versionLine() => File(
    '${repo.path}/pubspec.yaml',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));

  test('a build-only bump adds one, commits and tags', () {
    final result = run([]);
    expect(result.exitCode, 0, reason: result.err);
    expect(result.out, contains('Bumped to 1.2.0+8'));
    expect(versionLine(), 'version: 1.2.0+8');
    expect(git(['status', '--porcelain']), isEmpty);
    expect(git(['log', '-1', '--format=%s']), 'Bump to 1.2.0+8');
    expect(git(['tag', '--list']), 'v1.2.0+8');
  });

  test('the rest of the pubspec is untouched', () {
    run([]);
    expect(
      File('${repo.path}/pubspec.yaml').readAsStringSync(),
      _pubspec.replaceFirst('1.2.0+7', '1.2.0+8'),
    );
  });

  test('an App version bump sets the version and the next build', () {
    final result = run(['--version', '1.3.0']);
    expect(result.exitCode, 0, reason: result.err);
    expect(versionLine(), 'version: 1.3.0+8');
    expect(git(['tag', '--list']), 'v1.3.0+8');
  });

  test('an explicit higher build number is used as given', () {
    final result = run(['--build', '20']);
    expect(result.exitCode, 0, reason: result.err);
    expect(versionLine(), 'version: 1.2.0+20');
  });

  test('a non-increasing build number is refused', () {
    for (final build in ['7', '3']) {
      final result = run(['--build', build]);
      expect(result.exitCode, 1);
      expect(result.err, contains('not higher than the current 7'));
    }
    expect(versionLine(), 'version: 1.2.0+7');
    expect(git(['tag', '--list']), isEmpty);
  });

  test('a non-increasing or malformed App version is refused', () {
    for (final version in ['1.2.0', '1.1.9', '1.3']) {
      final result = run(['--version', version]);
      expect(result.exitCode, 1, reason: version);
    }
    expect(versionLine(), 'version: 1.2.0+7');
  });

  test('a dirty working tree is refused before anything changes', () {
    write('notes.txt', 'uncommitted\n');
    final result = run([]);
    expect(result.exitCode, 1);
    expect(result.err, contains('dirty'));
    expect(versionLine(), 'version: 1.2.0+7');
    expect(git(['tag', '--list']), isEmpty);
  });

  test('the tag name is v plus the full version', () {
    run(['--version', '2.0.0', '--build', '100']);
    expect(git(['tag', '--list']), 'v2.0.0+100');
    expect(
      git(['rev-parse', 'v2.0.0+100^{commit}']),
      git(['rev-parse', 'HEAD']),
    );
  });

  test('the Play changelog follows the build number in the same commit', () {
    run([]);
    expect(File('${repo.path}/$_changelog/7.txt').existsSync(), isFalse);
    expect(
      File('${repo.path}/$_changelog/8.txt').readAsStringSync(),
      'Seventh build.\n',
    );
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('a non-numeric --build is a usage error', () {
    final result = run(['--build', 'eight']);
    expect(result.exitCode, 64);
    expect(result.err, contains('--build must be a number'));
  });
}
