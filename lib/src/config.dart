import 'dart:io';

import 'package:yaml/yaml.dart';

/// The config file is missing, unreadable or lacks a required key.
class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
}

/// Everything app specific, read from the per-app config file. Key paths are
/// environment variable names, never the key values themselves.
class AppConfig {
  AppConfig._({
    required this.root,
    required this.bundleId,
    required this.androidPackage,
    required this.appStoreAppId,
    required this.locales,
    required this.stores,
    required this.keyPathVariables,
    required this.hudFile,
    required this.statusFile,
  });

  factory AppConfig.load(String path) {
    final file = File(path);
    if (!file.existsSync()) throw ConfigException('No config file at $path');
    final Object? parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw ConfigException('$path: ${e.message}');
    }
    final yaml = parsed is YamlMap
        ? parsed
        : throw ConfigException('$path: expected a map');

    String string(String key) => switch (yaml[key]) {
      final String value when value.isNotEmpty => value,
      _ => throw ConfigException('$path: "$key" must be a non-empty string'),
    };
    String? optionalString(String key) => switch (yaml[key]) {
      null => null,
      final String value => value,
      _ => throw ConfigException('$path: "$key" must be a string'),
    };
    List<String> strings(String key) => switch (yaml[key]) {
      final YamlList list
          when list.isNotEmpty && list.every((e) => e is String) =>
        list.cast<String>(),
      _ => throw ConfigException('$path: "$key" must be a list of strings'),
    };

    final stores = strings('stores');
    for (final store in stores) {
      if (Store.values.every((s) => s.name != store)) {
        throw ConfigException(
          '$path: unknown store "$store", expected one of '
          '${Store.values.map((s) => s.name).join(', ')}',
        );
      }
    }
    final keys = switch (yaml['keys']) {
      null => const <String, String>{},
      final YamlMap map when map.values.every((v) => v is String) =>
        map.cast<String, String>(),
      _ => throw ConfigException('$path: "keys" must map names to strings'),
    };

    return AppConfig._(
      root: file.parent.path,
      bundleId: string('bundle_id'),
      androidPackage: string('android_package'),
      appStoreAppId: optionalString('app_store_app_id'),
      locales: strings('locales'),
      stores: {for (final s in stores) Store.values.byName(s)},
      keyPathVariables: keys,
      hudFile: optionalString('hud_file'),
      statusFile: optionalString('status_file'),
    );
  }

  /// The app's folder: the one holding the config file.
  final String root;
  final String bundleId;
  final String androidPackage;
  final String? appStoreAppId;
  final List<String> locales;
  final Set<Store> stores;

  /// Key name to the environment variable that holds the key file's path.
  final Map<String, String> keyPathVariables;
  final String? hudFile;
  final String? statusFile;
}

enum Store { apple, play }
