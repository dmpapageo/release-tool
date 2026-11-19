import 'dart:io';

import 'package:release_tool/src/config.dart';

/// A bump that must not happen: dirty tree, stale number, missing pubspec.
class BumpException implements Exception {
  BumpException(this.message);
  final String message;
}

/// `major.minor.patch+build`, as the pubspec `version` line spells it.
class AppVersion {
  const AppVersion(this.version, this.build);

  final String version;
  final int build;

  static final _pattern = RegExp(r'^(\d+\.\d+\.\d+)\+(\d+)$');
  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

  static AppVersion? tryParse(String text) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    return AppVersion(match.group(1)!, int.parse(match.group(2)!));
  }

  static bool isVersion(String text) => _versionPattern.hasMatch(text);

  /// Compares `major.minor.patch` numerically, part by part.
  static int compareVersions(String a, String b) {
    final pa = a.split('.').map(int.parse).toList();
    final pb = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return 0;
  }

  String get tag => 'v$this';

  @override
  String toString() => '$version+$build';
}

final _versionLine = RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true);

ProcessResult _git(String root, List<String> args) {
  final result = Process.runSync('git', ['-C', root, ...args]);
  if (result.exitCode != 0) {
    throw BumpException('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result;
}

/// Sets the next build number (or [version] plus build), commits and tags.
/// Returns the new version; throws [BumpException] when the bump is refused.
AppVersion bump(AppConfig config, {String? version, int? build}) {
  final root = config.root;
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) throw BumpException('No pubspec.yaml in $root');
  final source = pubspec.readAsStringSync();
  final match = _versionLine.firstMatch(source);
  final current = match == null ? null : AppVersion.tryParse(match.group(1)!);
  if (current == null) {
    throw BumpException(
      'pubspec.yaml: "version" must look like 1.2.3+4 to be bumped',
    );
  }

  if (version != null) {
    if (!AppVersion.isVersion(version)) {
      throw BumpException('"$version" is not a major.minor.patch version');
    }
    if (AppVersion.compareVersions(version, current.version) <= 0) {
      throw BumpException(
        'Version $version is not higher than the current ${current.version}',
      );
    }
  }
  final nextBuild = build ?? current.build + 1;
  if (nextBuild <= current.build) {
    throw BumpException(
      'Build $nextBuild is not higher than the current ${current.build}',
    );
  }
  final next = AppVersion(version ?? current.version, nextBuild);

  final status = _git(root, ['status', '--porcelain']).stdout as String;
  if (status.trim().isNotEmpty) {
    throw BumpException('The working tree is dirty; commit or stash first');
  }
  final tags = _git(root, ['tag', '--list', next.tag]).stdout as String;
  if (tags.trim().isNotEmpty) throw BumpException('Tag ${next.tag} exists');

  pubspec.writeAsStringSync(
    source.replaceRange(match!.start, match.end, 'version: $next'),
  );
  final staged = ['pubspec.yaml'];
  // The Play changelog is named for the build, so it follows the number.
  const changelogs = 'fastlane/metadata/android';
  for (final locale in config.locales) {
    final stale = '$changelogs/$locale/changelogs/${current.build}.txt';
    final fresh = '$changelogs/$locale/changelogs/${next.build}.txt';
    if (File('$root/$stale').existsSync() &&
        !File('$root/$fresh').existsSync()) {
      File('$root/$stale').renameSync('$root/$fresh');
      staged.addAll([stale, fresh]);
    }
  }
  _git(root, ['add', '-A', '--', ...staged]);
  _git(root, ['commit', '-q', '-m', 'Bump to $next']);
  _git(root, ['tag', next.tag]);
  return next;
}
