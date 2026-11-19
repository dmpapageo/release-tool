import 'dart:convert';
import 'dart:io';

import 'package:release_tool/release_tool.dart';
import 'package:test/test.dart';

const _appId = '1234567890';
const _package = 'com.example.app';
const _editId = '17836412093654231235';
const _asc = 'https://api.appstoreconnect.apple.com/v1';
const _publisher =
    'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/'
    '$_package';

const _versions =
    'GET $_asc/apps/$_appId/appStoreVersions?filter[platform]=IOS&limit=200';
const _builds =
    'GET $_asc/builds?filter[app]=$_appId&sort=-uploadedDate&limit=1';
const _insertEdit = 'POST $_publisher/edits';
const _tracks = 'GET $_publisher/edits/$_editId/tracks';
const _deleteEdit = 'DELETE $_publisher/edits/$_editId';
const _storePage =
    'GET https://play.google.com/store/apps/details?id=$_package';

String _config({String stores = '[apple, play]', String hud = 'hud.csv'}) =>
    '''
bundle_id: com.example.app
android_package: $_package
app_store_app_id: "$_appId"
locales: [en-US]
stores: $stores
keys:
  app_store_connect: ASC_KEY_PATH
  app_store_connect_issuer: ASC_ISSUER_ID
  play_service_account: PLAY_KEY_PATH
hud_file: $hud
status_file: STATUS.md
''';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/status/$name').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _attributes(Object? resource) =>
    (resource! as Map<String, Object?>)['attributes']! as Map<String, Object?>;

/// The recorded App Store versions, with the newest one (1.1.0, listed last)
/// set to [state] in both the current and the older state field.
String _appleVersions(String state) {
  final json = _fixture('apple_app_store_versions.json');
  _attributes((json['data']! as List<Object?>).last)
    ..['appVersionState'] = state
    ..['appStoreState'] = state;
  return jsonEncode(json);
}

/// The recorded latest build (8) with its processing state set to [state].
String _appleBuilds(String state) {
  final json = _fixture('apple_builds.json');
  _attributes((json['data']! as List<Object?>).single)['processingState'] =
      state;
  return jsonEncode(json);
}

/// The recorded tracks, with the newest production release (version code 8)
/// set to [status]. Null removes every production release.
String _playTracks(String? status) {
  final json = _fixture('play_tracks.json');
  final production = (json['tracks']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((t) => t['track'] == 'production');
  final releases = production['releases']! as List<Object?>;
  if (status == null) {
    releases.clear();
  } else {
    final newest = releases.cast<Map<String, Object?>>().last;
    newest['status'] = status;
    if (status != 'inProgress') newest.remove('userFraction');
  }
  return jsonEncode(json);
}

/// Every store call answered from the recorded fixtures. The defaults are a
/// Release in flight on both stores.
Map<String, HttpResult> _stores({
  String apple = 'WAITING_FOR_REVIEW',
  String build = 'VALID',
  String? production = 'inProgress',
  int storePage = 404,
}) => {
  _versions: HttpResult(200, _appleVersions(apple)),
  _builds: HttpResult(200, _appleBuilds(build)),
  _insertEdit: HttpResult(200, jsonEncode(_fixture('play_edit.json'))),
  _tracks: HttpResult(200, _playTracks(production)),
  _deleteEdit: const HttpResult(204, ''),
  _storePage: HttpResult(storePage, '<html></html>'),
};

/// Serves recorded responses keyed by method and decoded URL, and records
/// every request. An unexpected request fails the test.
class _FakeTransport implements HttpTransport {
  _FakeTransport(this.responses);

  final Map<String, HttpResult> responses;
  final requests = <String>[];
  final authorization = <String, String?>{};

  @override
  Future<HttpResult> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final key = '$method ${Uri.decodeFull('$url')}';
    requests.add(key);
    authorization[key] = headers['authorization'];
    return responses[key] ?? (throw StateError('Unexpected request: $key'));
  }
}

class _FakeTokens implements TokenSource {
  _FakeTokens(this.value);
  final String value;

  @override
  Future<String> token() async => value;
}

class _Run {
  _Run(this.exitCode, this.out, this.err);
  final int exitCode;
  final String out;
  final String err;
}

void main() {
  late Directory app;
  late _FakeTransport transport;

  setUp(() => app = Directory.systemTemp.createTempSync('release_status_'));
  tearDown(() => app.deleteSync(recursive: true));

  void writeConfig([String? config]) => File('${app.path}/release.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync(config ?? _config());

  Future<_Run> status(
    Map<String, HttpResult> responses, {
    List<String> args = const [],
    TokenSource Function(AppConfig config)? appleTokens,
    TokenSource Function(AppConfig config)? playTokens,
  }) async {
    transport = _FakeTransport(responses);
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runReleaseAsync(
      ['status', '--config', '${app.path}/release.yaml', ...args],
      out: out,
      err: err,
      statusServices: (config) => StatusServices(
        transport: transport,
        appleTokens: appleTokens?.call(config) ?? _FakeTokens('apple-token'),
        playTokens: playTokens?.call(config) ?? _FakeTokens('play-token'),
        now: () => DateTime.utc(2026, 11, 9, 12),
        home: '${app.path}/home',
      ),
    );
    final run = _Run(code, out.toString(), err.toString());
    expect('${run.out}${run.err}', isNot(contains('-token')));
    return run;
  }

  String statusFile() => File('${app.path}/STATUS.md').readAsStringSync();
  String hudRow() => File('${app.path}/hud.csv').readAsLinesSync().singleWhere(
    (line) => line.contains(',checkpoint,app_release,'),
  );

  test('a build still processing in TestFlight is nothing in flight', () async {
    writeConfig(_config(stores: '[apple]'));

    final run = await status(
      _stores(apple: 'PREPARE_FOR_SUBMISSION', build: 'PROCESSING'),
    );

    expect(run.exitCode, 0, reason: run.err);
    expect(statusFile(), contains('## App Store'));
    expect(statusFile(), contains('- State: TestFlight processing'));
    expect(statusFile(), contains('- App version: 1.1.0'));
    expect(statusFile(), contains('- Build number: 8'));
    expect(statusFile(), contains('- Last checked: 2026-11-09 12:00 UTC'));
    expect(statusFile(), contains('- Next step: '));
    expect(statusFile(), isNot(contains('Google Play')));
    expect(
      hudRow(),
      startsWith('2026-11-09T12:00:00Z,checkpoint,app_release,0,ok,'),
    );
    expect(transport.requests, [_versions, _builds]);
    expect(transport.authorization[_versions], 'Bearer apple-token');
  });

  group('App Store, newest version', () {
    setUp(() => writeConfig(_config(stores: '[apple]')));

    for (final (state, label) in [
      ('WAITING_FOR_REVIEW', 'Waiting for review'),
      ('IN_REVIEW', 'In review'),
      ('PENDING_DEVELOPER_RELEASE', 'Approved, waiting for manual release'),
      ('PROCESSING_FOR_DISTRIBUTION', 'Approved, processing for distribution'),
    ]) {
      test('$state is in flight', () async {
        final run = await status(_stores(apple: state));

        expect(run.exitCode, 3, reason: run.err);
        expect(statusFile(), startsWith('# Release status\n'));
        expect(statusFile(), contains('- State: $label\n'));
        expect(statusFile(), contains('- App version: 1.1.0\n'));
        expect(run.out, startsWith('In flight'));
        expect(hudRow(), contains(',app_release,0,stale,In flight'));
      });
    }

    test('PENDING_DEVELOPER_RELEASE asks the owner to release it', () async {
      await status(_stores(apple: 'PENDING_DEVELOPER_RELEASE'));

      expect(
        statusFile(),
        contains('- Next step: Release it in App Store Connect'),
      );
    });

    for (final state in ['READY_FOR_DISTRIBUTION', 'READY_FOR_SALE']) {
      test('$state is live and done', () async {
        final run = await status(_stores(apple: state));

        expect(run.exitCode, 0, reason: run.err);
        expect(statusFile(), contains('- State: Live\n'));
        expect(run.out, startsWith('Live on every store'));
        expect(hudRow(), contains(',app_release,1,ok,Live on every store'));
      });
    }

    for (final (state, label) in [
      ('REJECTED', 'Rejected'),
      ('METADATA_REJECTED', 'Metadata rejected'),
      ('INVALID_BINARY', 'Invalid binary'),
    ]) {
      test('$state is called out first and counts as in flight', () async {
        final run = await status(_stores(apple: state));

        expect(run.exitCode, 3, reason: run.err);
        expect(statusFile(), startsWith('# REJECTED on the App Store\n'));
        expect(statusFile(), contains('- State: $label\n'));
        expect(statusFile(), contains('- Next step: Read the reason'));
        expect(run.out, startsWith('REJECTED on the App Store'));
        expect(hudRow(), contains(',app_release,0,error,REJECTED'));
      });
    }

    test(
      'DEVELOPER_REJECTED was pulled from review and is in flight',
      () async {
        final run = await status(_stores(apple: 'DEVELOPER_REJECTED'));

        expect(run.exitCode, 3, reason: run.err);
        expect(statusFile(), contains('- State: Pulled from review'));
        expect(statusFile(), contains('- Next step: Resubmit'));
      },
    );

    test('PREPARE_FOR_SUBMISSION with a processed build is not submitted, '
        'so nothing is in flight', () async {
      final run = await status(_stores(apple: 'PREPARE_FOR_SUBMISSION'));

      expect(run.exitCode, 0, reason: run.err);
      expect(statusFile(), contains('- State: Not submitted\n'));
      expect(statusFile(), contains('- Next step: Submit'));
      expect(hudRow(), contains(',app_release,0,ok,Nothing in flight'));
    });

    test('a review state wins over a build still processing', () async {
      final run = await status(
        _stores(apple: 'IN_REVIEW', build: 'PROCESSING'),
      );

      expect(run.exitCode, 3, reason: run.err);
      expect(statusFile(), contains('- State: In review\n'));
    });

    test('the older appStoreState field is read when appVersionState is '
        'missing', () async {
      final run = await status({
        ..._stores(),
        _versions: HttpResult(
          200,
          jsonEncode(_fixture('apple_app_store_versions_legacy.json')),
        ),
      });

      expect(run.exitCode, 3, reason: run.err);
      expect(statusFile(), contains('- State: In review\n'));
      expect(statusFile(), contains('- App version: 1.0.0\n'));
    });

    test('an App Store Connect error exits 1 with its message and writes '
        'nothing', () async {
      final run = await status({
        ..._stores(),
        _versions: HttpResult(401, jsonEncode(_fixture('apple_error.json'))),
      });

      expect(run.exitCode, 1);
      expect(run.err, contains('401'));
      expect(run.err, contains('signed bearer token'));
      expect(File('${app.path}/STATUS.md').existsSync(), isFalse);
      expect(File('${app.path}/hud.csv').existsSync(), isFalse);
    });
  });

  group('Google Play, production track', () {
    setUp(() => writeConfig(_config(stores: '[play]')));

    test('a staged rollout is in flight, and the edit is read and deleted '
        'with the Play token', () async {
      final run = await status(_stores());

      expect(run.exitCode, 3, reason: run.err);
      expect(statusFile(), contains('## Google Play'));
      expect(statusFile(), isNot(contains('App Store')));
      expect(
        statusFile(),
        contains('- State: Staged rollout to 20% of users\n'),
      );
      expect(statusFile(), contains('- App version: 1.1.0\n'));
      expect(statusFile(), contains('- Build number: 8\n'));
      expect(statusFile(), contains('- Last checked: 2026-11-09 12:00 UTC'));
      expect(
        statusFile(),
        contains(
          '- Tracks:\n'
          '  - production: inProgress, version codes 8\n'
          '  - beta: no releases\n'
          '  - internal: completed, version codes 9\n',
        ),
      );
      expect(hudRow(), contains(',app_release,0,stale,In flight'));
      expect(transport.requests, [_insertEdit, _tracks, _deleteEdit]);
      for (final request in transport.requests) {
        expect(transport.authorization[request], 'Bearer play-token');
      }
    });

    test('a draft is not submitted, so nothing is in flight', () async {
      final run = await status(_stores(production: 'draft'));

      expect(run.exitCode, 0, reason: run.err);
      expect(statusFile(), contains('- State: Draft\n'));
      expect(
        statusFile(),
        contains('- Next step: Send the release for review'),
      );
      expect(hudRow(), contains(',app_release,0,ok,Nothing in flight'));
      expect(transport.requests, isNot(contains(_storePage)));
    });

    test('a halted rollout is in flight', () async {
      final run = await status(_stores(production: 'halted'));

      expect(run.exitCode, 3, reason: run.err);
      expect(statusFile(), contains('- State: Rollout halted\n'));
    });

    test('a completed release whose store page answers is live', () async {
      final run = await status(
        _stores(production: 'completed', storePage: 200),
      );

      expect(run.exitCode, 0, reason: run.err);
      expect(statusFile(), contains('- State: Live\n'));
      expect(hudRow(), contains(',app_release,1,ok,Live on every store'));
      expect(transport.requests, [
        _insertEdit,
        _tracks,
        _deleteEdit,
        _storePage,
      ]);
      expect(transport.authorization[_storePage], isNull);
    });

    test('a completed release with no store page yet is submitted, and the '
        'review state is not exposed by the API', () async {
      final run = await status(_stores(production: 'completed'));

      expect(run.exitCode, 3, reason: run.err);
      expect(
        statusFile(),
        contains(
          '- State: Submitted, review state not exposed by the API\n',
        ),
      );
      expect(hudRow(), contains(',app_release,0,stale,In flight'));
    });

    test('no production release is not submitted', () async {
      final run = await status(_stores(production: null));

      expect(run.exitCode, 0, reason: run.err);
      expect(statusFile(), contains('- State: Not submitted to production\n'));
      expect(statusFile(), contains('- App version: none\n'));
      expect(statusFile(), contains('  - production: no releases\n'));
    });

    test('the edit is deleted even when reading the tracks fails', () async {
      final run = await status({
        ..._stores(),
        _tracks: HttpResult(500, jsonEncode(_fixture('play_error.json'))),
      });

      expect(run.exitCode, 1);
      expect(run.err, contains('500'));
      expect(run.err, contains('Internal error encountered.'));
      expect(transport.requests, [_insertEdit, _tracks, _deleteEdit]);
      expect(File('${app.path}/STATUS.md').existsSync(), isFalse);
    });
  });

  group('both stores', () {
    setUp(writeConfig);

    test('live on the App Store but not on Google Play is in flight', () async {
      final run = await status(_stores(apple: 'READY_FOR_SALE'));

      expect(run.exitCode, 3, reason: run.err);
      final file = statusFile();
      expect(file, startsWith('# Release status\n'));
      expect(
        file.indexOf('## App Store'),
        lessThan(file.indexOf('## Google Play')),
      );
      expect(file, contains('- State: Live\n'));
      expect(file, contains('- State: Staged rollout to 20% of users\n'));
      expect(run.out, startsWith('In flight'));
      expect(hudRow(), contains(',app_release,0,stale,In flight'));
    });

    test('live on both stores is done', () async {
      final run = await status(
        _stores(
          apple: 'READY_FOR_SALE',
          production: 'completed',
          storePage: 200,
        ),
      );

      expect(run.exitCode, 0, reason: run.err);
      expect(
        run.out.trim(),
        'Live on every store (App Store: Live; Google Play: Live)',
      );
      expect(
        hudRow(),
        '2026-11-09T12:00:00Z,checkpoint,app_release,1,ok,Live on every '
        'store (App Store: Live; Google Play: Live)',
      );
    });

    test(
      'a rejection is called out first even when Google Play is live',
      () async {
        final run = await status(
          _stores(apple: 'REJECTED', production: 'completed', storePage: 200),
        );

        expect(run.exitCode, 3, reason: run.err);
        final file = statusFile();
        expect(file, startsWith('# REJECTED on the App Store\n'));
        expect(
          file.indexOf('## App Store'),
          lessThan(file.indexOf('## Google Play')),
        );
        expect(run.out, startsWith('REJECTED on the App Store'));
        expect(
          hudRow(),
          contains(',app_release,0,error,REJECTED on the App Store'),
        );
      },
    );
  });

  group('HUD file', () {
    test(
      'only the app line is replaced and every other line is kept',
      () async {
        writeConfig();
        const others = [
          'timestamp,source,metric,value,status,error',
          '2026-11-09T10:52:34Z,checkpoint,verse-widget_commit,0,error,dirty',
          '2026-11-09T09:00:00Z,preflight,disk,1,ok,',
          '2026-11-08T08:00:00Z,checkpoint,other_release,1,ok,Live',
        ];
        File('${app.path}/hud.csv').writeAsStringSync(
          [
            ...others.take(3),
            '2026-11-08T08:00:00Z,checkpoint,app_release,0,stale,In flight',
            others.last,
          ].map((line) => '$line\n').join(),
        );

        await status(_stores());

        final lines = File('${app.path}/hud.csv').readAsLinesSync();
        expect(lines.take(4), others);
        expect(lines, hasLength(5));
        expect(
          lines.last,
          startsWith('2026-11-09T12:00:00Z,checkpoint,app_release,'),
        );
      },
    );

    test(
      'a path under ~ is created in the home folder with the header',
      () async {
        writeConfig(_config(stores: '[apple]', hud: '~/metrics/metrics.csv'));

        final run = await status(_stores());

        expect(run.exitCode, 3, reason: run.err);
        final lines = File(
          '${app.path}/home/metrics/metrics.csv',
        ).readAsLinesSync();
        expect(lines.first, 'timestamp,source,metric,value,status,error');
        expect(lines.last, contains(',checkpoint,app_release,0,stale,'));
        expect(lines.last, isNot(contains('Waiting for review,')));
      },
    );
  });

  test('--help lists the exit codes without reading the config', () async {
    final run = await status(const {}, args: ['--help']);

    expect(run.exitCode, 0, reason: run.err);
    expect(run.out, contains('Exit codes:'));
    expect(run.out, contains('0  '));
    expect(run.out, contains('3  '));
    expect(run.out, contains('1  '));
    expect(run.out, contains('64 '));
    expect(transport.requests, isEmpty);
  });

  test('a missing App Store app id exits 1 before any request', () async {
    writeConfig(
      _config(
        stores: '[apple]',
      ).replaceFirst(RegExp('app_store_app_id.*\n'), ''),
    );

    final run = await status(_stores());

    expect(run.exitCode, 1);
    expect(run.err, contains('app_store_app_id'));
    expect(transport.requests, isEmpty);
    expect(File('${app.path}/STATUS.md').existsSync(), isFalse);
  });

  group('store keys', () {
    // Only the checks before signing run here: tests never sign anything.
    File keyFile(String name, String contents) => File('${app.path}/keys/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);

    Future<_Run> apple(Map<String, String> environment) => status(
      _stores(),
      appleTokens: (config) =>
          AppStoreConnectTokens(config, environment: environment),
    );

    Future<_Run> play(Map<String, String> environment) => status(
      _stores(),
      playTokens: (config) =>
          PlayTokens(config, transport, environment: environment),
    );

    test('a missing App Store key path names the variable', () async {
      writeConfig(_config(stores: '[apple]'));

      final run = await apple(const {});

      expect(run.exitCode, 1);
      expect(
        run.err.trim(),
        'App Store: set ASC_KEY_PATH in the environment or in .env.',
      );
      expect(transport.requests, isEmpty);
      expect(File('${app.path}/STATUS.md').existsSync(), isFalse);
    });

    test('a key path that points nowhere is reported', () async {
      writeConfig(_config(stores: '[apple]'));

      final run = await apple({'ASC_KEY_PATH': '${app.path}/AuthKey_X1.p8'});

      expect(run.exitCode, 1);
      expect(run.err, contains('no key file at the path in ASC_KEY_PATH'));
    });

    test('an App Store key file needs the AuthKey_<KEYID>.p8 name', () async {
      writeConfig(_config(stores: '[apple]'));
      final key = keyFile('key.pem', 'NOT-A-KEY');

      final run = await apple({'ASC_KEY_PATH': key.path});

      expect(run.exitCode, 1);
      expect(run.err, contains('AuthKey_<KEYID>.p8'));
      expect(run.err, isNot(contains('NOT-A-KEY')));
    });

    test('a missing issuer id names the variable', () async {
      writeConfig(_config(stores: '[apple]'));
      final key = keyFile('AuthKey_ABC123DEF4.p8', 'NOT-A-KEY');

      final run = await apple({'ASC_KEY_PATH': key.path});

      expect(run.exitCode, 1);
      expect(run.err, contains('set ASC_ISSUER_ID'));
      expect(run.err, isNot(contains('NOT-A-KEY')));
    });

    test('a key name missing from the config file is reported', () async {
      writeConfig(
        _config(
          stores: '[apple]',
        ).replaceFirst('  app_store_connect: ASC_KEY_PATH\n', ''),
      );

      final run = await apple(const {'ASC_KEY_PATH': 'unused'});

      expect(run.exitCode, 1);
      expect(run.err, contains('"keys.app_store_connect" is not set'));
    });

    test('a service account file that is not JSON is reported without its '
        'contents', () async {
      writeConfig(_config(stores: '[play]'));
      final key = keyFile('play.json', 'SECRET-CONTENTS {');

      final run = await play({'PLAY_KEY_PATH': key.path});

      expect(run.exitCode, 1);
      expect(
        run.err,
        contains(
          'Google Play: the service account file is not '
          'valid JSON.',
        ),
      );
      expect(run.err, isNot(contains('SECRET-CONTENTS')));
      expect(transport.requests, isEmpty);
    });

    test('a service account file without a private key is reported', () async {
      writeConfig(_config(stores: '[play]'));
      final key = keyFile('play.json', '{"client_email": "a@b.example"}');

      final run = await play({'PLAY_KEY_PATH': key.path});

      expect(run.exitCode, 1);
      expect(run.err, contains('no client_email or private_key'));
      expect(transport.requests, isEmpty);
    });
  });
}
