import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:release_tool/src/config.dart';
import 'package:release_tool/src/http_transport.dart';
import 'package:release_tool/src/store_auth.dart';

/// Exit code for a Release that is submitted (or rejected) and not yet live on
/// every enabled store.
const inFlight = 3;

/// A store call failed or a key is missing. The message never holds a key, a
/// token or the issuer id.
class StatusException implements Exception {
  StatusException(this.message);
  final String message;
}

/// What `release status` needs from the outside world.
class StatusServices {
  StatusServices({
    required this.transport,
    required this.appleTokens,
    required this.playTokens,
    DateTime Function()? now,
    String? home,
  }) : now = now ?? DateTime.now,
       home = home ?? Platform.environment['HOME'];

  final HttpTransport transport;
  final TokenSource appleTokens;
  final TokenSource playTokens;
  final DateTime Function() now;

  /// The home folder a leading `~` in the HUD file path stands for.
  final String? home;
}

/// What a store's raw state means for the Release.
class _Reading {
  const _Reading(
    this.state,
    this.nextStep, {
    this.submitted = true,
    this.live = false,
    this.rejection,
  });

  final String state;
  final String nextStep;

  /// A Submission was made for the Release on this store.
  final bool submitted;
  final bool live;

  /// The headline to call out first when the store rejected the Release.
  final String? rejection;
}

/// One store's side of the Release, as shown in the status file.
class _StoreState {
  _StoreState(
    this.store,
    this.reading, {
    required this.version,
    required this.build,
    this.tracks = const [],
  });

  final String store;
  final _Reading reading;
  final String version;
  final String build;

  /// One line per track, for stores that have tracks.
  final List<String> tracks;
}

const _ascApi = 'https://api.appstoreconnect.apple.com/v1';
const _publisherApi =
    'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
const _hudHeader = 'timestamp,source,metric,value,status,error';

/// Reads each enabled store's release state, rewrites the status file and
/// the app's line in the HUD file, and returns the exit code.
Future<int> status(
  AppConfig config,
  StatusServices services, {
  required StringSink out,
  required StringSink err,
}) async {
  final checked = services.now().toUtc();
  final String? hud;
  List<_StoreState> stores;
  try {
    hud = _hudPath(config, services.home);
    stores = [
      if (config.stores.contains(Store.apple))
        await _appStore(config, services),
      if (config.stores.contains(Store.play))
        await _googlePlay(config, services),
    ];
  } on StatusException catch (e) {
    err.writeln(e.message);
    return 1;
  } on TokenException catch (e) {
    err.writeln(e.message);
    return 1;
  } on IOException catch (e) {
    err.writeln('Could not reach a store API: $e');
    return 1;
  } on TimeoutException {
    err.writeln('A store API did not answer in time.');
    return 1;
  }

  // A rejection is called out first: its store leads the file and the line.
  final rejected = stores.where((s) => s.reading.rejection != null).toList();
  final rejections = [for (final s in rejected) s.reading.rejection!];
  stores = [
    ...rejected,
    ...stores.where((s) => s.reading.rejection == null),
  ];
  final live = stores.every((s) => s.reading.live);
  final releaseInFlight = stores.any((s) => s.reading.submitted) && !live;
  final headline = rejections.isNotEmpty
      ? rejections.join('; ')
      : live
      ? 'Live on every store'
      : releaseInFlight
      ? 'In flight'
      : 'Nothing in flight';
  final summary =
      '$headline '
      '(${stores.map((s) => '${s.store}: ${s.reading.state}').join('; ')})';

  _writeStatusFile(
    config,
    stores,
    title: rejections.isEmpty ? 'Release status' : headline,
    summary: summary,
    checked: checked,
  );
  if (hud != null) {
    _writeHudRow(
      hud,
      metric: '${config.bundleId.split('.').last}_release',
      timestamp: checked,
      value: live ? 1 : 0,
      status: rejections.isNotEmpty
          ? 'error'
          : releaseInFlight
          ? 'stale'
          : 'ok',
      summary: summary,
    );
  }
  out.writeln(summary);
  return releaseInFlight ? inFlight : 0;
}

Future<_StoreState> _appStore(AppConfig config, StatusServices services) async {
  final appId = config.appStoreAppId;
  if (appId == null) {
    throw StatusException(
      'App Store: "app_store_app_id" is not set in the config file.',
    );
  }
  final token = await services.appleTokens.token();
  final versions = await _getJson(
    services.transport,
    'App Store',
    'GET',
    Uri.parse('$_ascApi/apps/$appId/appStoreVersions').replace(
      queryParameters: {'filter[platform]': 'IOS', 'limit': '200'},
    ),
    token,
  );
  final builds = await _getJson(
    services.transport,
    'App Store',
    'GET',
    Uri.parse('$_ascApi/builds').replace(
      queryParameters: {
        'filter[app]': appId,
        'sort': '-uploadedDate',
        'limit': '1',
      },
    ),
    token,
  );

  final version = _newest(_resources(versions));
  final build = _resources(builds).firstOrNull;
  final versionState = switch (version) {
    null => null,
    _ => (version['appVersionState'] ?? version['appStoreState']) as String?,
  };
  final buildState = build?['processingState'] as String?;

  return _StoreState(
    'App Store',
    _appleReading(versionState, buildState),
    version: version?['versionString'] as String? ?? 'none',
    build: build?['version'] as String? ?? 'none',
  );
}

/// Maps the newest App Store version's state and the latest build's
/// processing state to a reading. A rejection wins, then App Review, then
/// live, then a build still processing.
_Reading _appleReading(String? versionState, String? buildState) {
  const rejected = 'REJECTED on the App Store';
  return switch ((versionState, buildState)) {
    ('REJECTED', _) => const _Reading(
      'Rejected',
      'Read the reason in App Store Connect (App Review), fix it and '
          'resubmit.',
      rejection: rejected,
    ),
    ('METADATA_REJECTED', _) => const _Reading(
      'Metadata rejected',
      'Read the reason in App Store Connect (App Review), fix the listing '
          'and resubmit.',
      rejection: rejected,
    ),
    ('INVALID_BINARY', _) => const _Reading(
      'Invalid binary',
      'Read the reason in the email from Apple, upload a fixed build and '
          'resubmit.',
      rejection: rejected,
    ),
    ('WAITING_FOR_REVIEW', _) => const _Reading(
      'Waiting for review',
      'Nothing to do: Apple reviews it, usually within a day or two.',
    ),
    ('IN_REVIEW', _) => const _Reading(
      'In review',
      'Nothing to do: wait for the review result.',
    ),
    ('PENDING_DEVELOPER_RELEASE', _) => const _Reading(
      'Approved, waiting for manual release',
      'Release it in App Store Connect.',
    ),
    ('PROCESSING_FOR_DISTRIBUTION' || 'PROCESSING_FOR_APP_STORE', _) =>
      const _Reading(
        'Approved, processing for distribution',
        'Nothing to do: it goes live on its own.',
      ),
    ('READY_FOR_DISTRIBUTION' || 'READY_FOR_SALE', _) => const _Reading(
      'Live',
      'Nothing to do.',
      live: true,
    ),
    (_, 'PROCESSING') => const _Reading(
      'TestFlight processing',
      'Wait for the build to finish processing, then pick it for the version '
          'and submit for review.',
      submitted: false,
    ),
    ('DEVELOPER_REJECTED', _) => const _Reading(
      'Pulled from review (developer rejected)',
      'Resubmit for review in App Store Connect when ready.',
    ),
    ('PREPARE_FOR_SUBMISSION', _) => const _Reading(
      'Not submitted',
      'Submit the version for review in App Store Connect.',
      submitted: false,
    ),
    (null, _) => const _Reading(
      'No App Store version yet',
      'Create the version in App Store Connect.',
      submitted: false,
    ),
    (final raw, _) => _Reading(
      'App Store state $raw',
      'Check the version in App Store Connect.',
    ),
  };
}

/// The newest release on one Google Play track.
typedef _PlayRelease = ({
  String status,
  String? name,
  List<String> versionCodes,
  double? userFraction,
});

Future<_StoreState> _googlePlay(
  AppConfig config,
  StatusServices services,
) async {
  final package = config.androidPackage;
  final transport = services.transport;
  final token = await services.playTokens.token();
  final edits = '$_publisherApi/$package/edits';

  // Tracks are only readable inside an edit. The edit is never committed,
  // only deleted, so this stays read-only.
  final edit = await _getJson(
    transport,
    'Google Play',
    'POST',
    Uri.parse(edits),
    token,
    body: '{}',
  );
  final editId = switch (edit) {
    {'id': final String id} when id.isNotEmpty => id,
    _ => throw StatusException('Google Play: the new edit has no id.'),
  };
  final Map<String, Object?> tracksJson;
  try {
    tracksJson = await _getJson(
      transport,
      'Google Play',
      'GET',
      Uri.parse('$edits/$editId/tracks'),
      token,
    );
  } finally {
    try {
      await _getJson(
        transport,
        'Google Play',
        'DELETE',
        Uri.parse('$edits/$editId'),
        token,
      );
    } on Exception {
      // An edit left behind expires on its own and is never committed.
    }
  }

  final tracks = [
    if (tracksJson['tracks'] case final List<Object?> list)
      for (final track in list)
        if (track case final Map<String, Object?> t)
          if (t case {'track': final String name})
            (name: name, release: _newestRelease(t)),
  ];
  final production = tracks
      .where((t) => t.name == 'production')
      .firstOrNull
      ?.release;

  // The API says a release is completed before review passes, so live also
  // needs the public store page to answer.
  var pageLive = false;
  if (production?.status == 'completed') {
    final page = await transport.send(
      'GET',
      Uri.https('play.google.com', '/store/apps/details', {'id': package}),
    );
    pageLive = page.status == 200;
  }

  final name = production?.name;
  return _StoreState(
    'Google Play',
    _playReading(production, pageLive: pageLive),
    version: switch (name) {
      null => 'none',
      _ => RegExp(r'\(([^()]+)\)\s*$').firstMatch(name)?.group(1) ?? name,
    },
    build: production == null || production.versionCodes.isEmpty
        ? 'none'
        : production.versionCodes.join(', '),
    tracks: [
      for (final t in tracks)
        switch (t.release) {
          null => '${t.name}: no releases',
          final r =>
            '${t.name}: ${r.status}, version codes '
                '${r.versionCodes.join(', ')}',
        },
    ],
  );
}

/// The release with the highest version code on a track, or null.
_PlayRelease? _newestRelease(Map<String, Object?> track) {
  final releases = <_PlayRelease>[
    if (track['releases'] case final List<Object?> list)
      for (final release in list)
        if (release case final Map<String, Object?> r)
          if (r case {'status': final String status})
            (
              status: status,
              name: r['name'] as String?,
              versionCodes: [
                if (r['versionCodes'] case final List<Object?> codes)
                  for (final code in codes) '$code',
              ],
              userFraction: (r['userFraction'] as num?)?.toDouble(),
            ),
  ];
  int highest(_PlayRelease r) =>
      r.versionCodes.map((c) => int.tryParse(c) ?? 0).fold(0, max);
  return releases.isEmpty
      ? null
      : releases.reduce((a, b) => highest(b) > highest(a) ? b : a);
}

/// Maps the newest production release to a reading. Play does not expose
/// review state, so a completed release counts as live only when its store
/// page answers.
_Reading _playReading(_PlayRelease? release, {required bool pageLive}) =>
    switch (release?.status) {
      null => const _Reading(
        'Not submitted to production',
        'Create a production release in Play Console and send it for review.',
        submitted: false,
      ),
      'draft' => const _Reading(
        'Draft',
        'Send the release for review in Play Console.',
        submitted: false,
      ),
      'inProgress' => _Reading(
        switch (release?.userFraction) {
          final double fraction =>
            'Staged rollout to ${(fraction * 100).round()}% of users',
          null => 'Staged rollout',
        },
        'Raise the rollout to 100% in Play Console when ready.',
      ),
      'halted' => const _Reading(
        'Rollout halted',
        'Resume the rollout or replace the release in Play Console.',
      ),
      'completed' when pageLive => const _Reading(
        'Live',
        'Nothing to do.',
        live: true,
      ),
      'completed' => const _Reading(
        'Submitted, review state not exposed by the API',
        'Nothing to do: Google reviews it, then it goes live. Play Console '
            'shows the review state.',
      ),
      final raw => _Reading(
        'Play release status $raw',
        'Check the release in Play Console.',
      ),
    };

/// The `attributes` of each resource in a JSON:API list response.
List<Map<String, Object?>> _resources(Map<String, Object?> json) => [
  if (json['data'] case final List<Object?> data)
    for (final resource in data)
      if (resource case {'attributes': final Map<String, Object?> attributes})
        attributes,
];

/// The App Store version created last.
Map<String, Object?>? _newest(List<Map<String, Object?>> versions) {
  DateTime created(Map<String, Object?> v) =>
      DateTime.tryParse(v['createdDate'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
  return versions.isEmpty
      ? null
      : versions.reduce((a, b) => created(b).isAfter(created(a)) ? b : a);
}

/// Sends one authorized store API call and decodes its JSON body. A failure
/// names the call, the status code and the API's own message, never the token.
Future<Map<String, Object?>> _getJson(
  HttpTransport transport,
  String store,
  String method,
  Uri url,
  String token, {
  String? body,
}) async {
  final result = await transport.send(
    method,
    url,
    headers: {
      'authorization': 'Bearer $token',
      if (body != null) 'content-type': 'application/json',
    },
    body: body,
  );
  final call = '$store: $method ${url.path}';
  if (result.status < 200 || result.status > 299) {
    throw StatusException(
      '$call failed with ${result.status}${_apiMessage(result.body)}',
    );
  }
  if (result.body.isEmpty) return const {};
  try {
    return jsonDecode(result.body) as Map<String, Object?>;
  } on FormatException {
    throw StatusException('$call answered with a body that is not JSON.');
  }
}

/// The error message in an App Store Connect, Google API or OAuth error body,
/// as ": message", or nothing.
String _apiMessage(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return '';
  }
  final message = switch (json) {
    {'errors': [{'detail': final String detail}, ...]} => detail,
    {'errors': [{'title': final String title}, ...]} => title,
    {'error': {'message': final String message}} => message,
    {'error_description': final String description} => description,
    _ => null,
  };
  return message == null ? '' : ': $message';
}

void _writeStatusFile(
  AppConfig config,
  List<_StoreState> stores, {
  required String title,
  required String summary,
  required DateTime checked,
}) {
  final time =
      '${checked.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} '
      'UTC';
  final text = StringBuffer()
    ..writeln('# $title')
    ..writeln()
    ..writeln(summary);
  for (final store in stores) {
    text
      ..writeln()
      ..writeln('## ${store.store}')
      ..writeln()
      ..writeln('- State: ${store.reading.state}')
      ..writeln('- App version: ${store.version}')
      ..writeln('- Build number: ${store.build}')
      ..writeln('- Last checked: $time')
      ..writeln('- Next step: ${store.reading.nextStep}');
    if (store.tracks.isNotEmpty) {
      text.writeln('- Tracks:');
      for (final track in store.tracks) {
        text.writeln('  - $track');
      }
    }
  }
  File(
    '${config.root}/${config.statusFile ?? 'STATUS.md'}',
  ).writeAsStringSync(text.toString());
}

/// The HUD file path with a leading `~` expanded and a relative path taken
/// from the config folder, or null when the config names none.
String? _hudPath(AppConfig config, String? home) {
  final path = config.hudFile;
  if (path == null || path.isEmpty) return null;
  if (path == '~' || path.startsWith('~/')) {
    if (home == null) {
      throw StatusException('HOME is not set, so "hud_file" cannot expand ~.');
    }
    return '$home${path.substring(1)}';
  }
  return path.startsWith('/') ? path : '${config.root}/$path';
}

/// Replaces the app's row in the HUD's metrics CSV and keeps every other line.
void _writeHudRow(
  String path, {
  required String metric,
  required DateTime timestamp,
  required int value,
  required String status,
  required String summary,
}) {
  final file = File(path);
  final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
  bool ownRow(String line) => switch (line.split(',')) {
    [_, 'checkpoint', final m, ...] => m == metric,
    _ => false,
  };
  final kept = lines.where((line) => !ownRow(line)).toList();
  if (kept.isEmpty) kept.add(_hudHeader);
  final time = '${timestamp.toIso8601String().substring(0, 19)}Z';
  final error = summary.replaceAll(RegExp(r'\s*[,\r\n]+\s*'), '; ');
  kept.add('$time,checkpoint,$metric,$value,$status,$error');
  file
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${kept.join('\n')}\n');
}
