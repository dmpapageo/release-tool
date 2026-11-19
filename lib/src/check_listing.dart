import 'dart:io';

import 'package:release_tool/src/config.dart';
import 'package:yaml/yaml.dart';

/// Where a field's file sits in fastlane's metadata tree.
enum _Scope {
  /// `metadata/<locale>/`, read by deliver.
  appleLocale,

  /// `metadata/review_information/`, one per app, read by deliver.
  appleReview,

  /// `metadata/android/<locale>/`, read by supply.
  playLocale,
}

/// One Listing field: a single text file in the metadata tree.
class _Field {
  const _Field(this.scope, this.name, {this.required = true, this.limit});

  final _Scope scope;

  /// File name without `.txt`, where `{build}` stands for the current build
  /// number.
  final String name;
  final bool required;

  /// The store's character limit, or null when the store sets none.
  final int? limit;

  Store get store => scope == _Scope.playLocale ? Store.play : Store.apple;
}

/// Every Listing field the checker knows. Adding a field is a row here.
const _fields = [
  _Field(_Scope.appleLocale, 'name', limit: 30),
  _Field(_Scope.appleLocale, 'subtitle', required: false, limit: 30),
  _Field(_Scope.appleLocale, 'keywords', limit: 100),
  _Field(_Scope.appleLocale, 'promotional_text', required: false, limit: 170),
  _Field(_Scope.appleLocale, 'description', limit: 4000),
  // Apple shows no release notes for an app's first version.
  _Field(_Scope.appleLocale, 'release_notes', required: false, limit: 4000),
  _Field(_Scope.appleLocale, 'privacy_url'),
  _Field(_Scope.appleLocale, 'support_url'),
  _Field(_Scope.appleReview, 'first_name'),
  _Field(_Scope.appleReview, 'last_name'),
  _Field(_Scope.appleReview, 'phone_number'),
  _Field(_Scope.appleReview, 'email_address'),
  _Field(_Scope.appleReview, 'notes', required: false),
  _Field(_Scope.playLocale, 'title', limit: 30),
  _Field(_Scope.playLocale, 'short_description', limit: 80),
  _Field(_Scope.playLocale, 'full_description', limit: 4000),
  _Field(_Scope.playLocale, 'changelogs/{build}', limit: 500),
];

/// The build number after the `+` in the pubspec `version`, or null.
String? _buildNumber(String root) {
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) return null;
  final yaml = loadYaml(pubspec.readAsStringSync());
  final version = yaml is YamlMap ? yaml['version'] : null;
  if (version is! String) return null;
  return RegExp(r'\+(\d+)$').firstMatch(version)?.group(1);
}

/// Checks the fastlane Listing of every enabled store and locale, prints every
/// problem found and returns 1 when there is any.
int checkListing(AppConfig config, {required StringSink out}) {
  final metadata = '${config.root}/fastlane/metadata';
  final build = _buildNumber(config.root);
  final problems = <String>[];

  void check(_Field field, String where, String folder) {
    if (field.name.contains('{build}') && build == null) return;
    final name = field.name.replaceAll('{build}', build ?? '');
    final file = File('$folder/$name.txt');
    // fastlane strips surrounding whitespace before upload, so do the same.
    final text = file.existsSync() ? file.readAsStringSync().trim() : '';
    final label = '${field.store.name} $where $name';
    final limit = field.limit;
    // Stores count characters, not UTF-16 code units.
    final length = text.runes.length;
    if (text.isEmpty) {
      if (field.required) problems.add('$label: missing');
    } else if (limit != null && length > limit) {
      problems.add('$label: $length characters, limit $limit');
    }
  }

  final enabled = _fields.where((f) => config.stores.contains(f.store));
  if (build == null && enabled.any((f) => f.name.contains('{build}'))) {
    problems.add('pubspec.yaml: no build number in "version"');
  }

  for (final field in enabled) {
    switch (field.scope) {
      case _Scope.appleReview:
        check(field, 'review_information', '$metadata/review_information');
      case _Scope.appleLocale:
        for (final locale in config.locales) {
          check(field, locale, '$metadata/$locale');
        }
      case _Scope.playLocale:
        for (final locale in config.locales) {
          check(field, locale, '$metadata/android/$locale');
        }
    }
  }

  if (problems.isEmpty) {
    out.writeln('Listing OK');
    return 0;
  }
  problems.forEach(out.writeln);
  out.writeln('${problems.length} problem(s) in the Listing');
  return 1;
}
