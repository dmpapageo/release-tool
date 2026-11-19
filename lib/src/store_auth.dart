import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:release_tool/src/config.dart';
import 'package:release_tool/src/http_transport.dart';

/// Hands out a bearer token for one store API, so tests never sign anything.
// The seam is an interface with one method on purpose.
// ignore: one_member_abstracts
abstract interface class TokenSource {
  Future<String> token();
}

/// A key setting is missing or a key could not be used. The message names
/// the setting, never a key, a token or the issuer id.
class TokenException implements Exception {
  TokenException(this.message);
  final String message;
}

const _googleTokenUrl = 'https://oauth2.googleapis.com/token';
const _androidPublisherScope =
    'https://www.googleapis.com/auth/androidpublisher';

/// An App Store Connect API token: an ES256 JWT signed with the
/// `AuthKey_<KEYID>.p8` file whose path is in the variable named by
/// `keys.app_store_connect`, issued by the id in the variable named by
/// `keys.app_store_connect_issuer`.
class AppStoreConnectTokens implements TokenSource {
  AppStoreConnectTokens(
    this._config, {
    Map<String, String>? environment,
    DateTime Function()? now,
  }) : _environment = environment ?? Platform.environment,
       _now = now ?? DateTime.now;

  final AppConfig _config;
  final Map<String, String> _environment;
  final DateTime Function() _now;

  @override
  Future<String> token() async {
    final keyPath = _keyFile(
      _config,
      _environment,
      'app_store_connect',
      'App Store',
    );
    final keyId = switch (RegExp(
      r'AuthKey_([A-Za-z0-9]+)\.p8$',
    ).firstMatch(keyPath)) {
      final match? => match.group(1)!,
      null => throw TokenException(
        'App Store: the key file must be named AuthKey_<KEYID>.p8.',
      ),
    };
    final issuer = _setting(
      _config,
      _environment,
      _variableName(_config, 'app_store_connect_issuer', 'App Store'),
      'App Store',
    );
    final issuedAt = _now().millisecondsSinceEpoch ~/ 1000;
    final signingInput = _signingInput(
      {'alg': 'ES256', 'kid': keyId, 'typ': 'JWT'},
      {
        'iss': issuer,
        'iat': issuedAt,
        // Apple refuses tokens that live longer than 20 minutes.
        'exp': issuedAt + 19 * 60,
        'aud': 'appstoreconnect-v1',
      },
    );
    final der = await _openSslSign(signingInput, keyPath, 'App Store');
    return '$signingInput.${_base64Url(_derToRawEcdsa(der))}';
  }
}

/// A Google Play Developer API token: an RS256 JWT assertion signed with the
/// service account in the JSON file whose path is in the variable named by
/// `keys.play_service_account`, exchanged for an access token.
class PlayTokens implements TokenSource {
  PlayTokens(
    this._config,
    this._transport, {
    Map<String, String>? environment,
    DateTime Function()? now,
  }) : _environment = environment ?? Platform.environment,
       _now = now ?? DateTime.now;

  final AppConfig _config;
  final HttpTransport _transport;
  final Map<String, String> _environment;
  final DateTime Function() _now;

  @override
  Future<String> token() async {
    final keyPath = _keyFile(
      _config,
      _environment,
      'play_service_account',
      'Google Play',
    );
    final Object? account;
    try {
      account = jsonDecode(File(keyPath).readAsStringSync());
    } on FormatException {
      // The decoder's message quotes the file, so it is not passed on.
      throw TokenException(
        'Google Play: the service account file is not valid JSON.',
      );
    }
    final (email, privateKey) = switch (account) {
      {
        'client_email': final String email,
        'private_key': final String privateKey,
      } =>
        (email, privateKey),
      _ => throw TokenException(
        'Google Play: the service account file has no client_email or '
        'private_key.',
      ),
    };

    final issuedAt = _now().millisecondsSinceEpoch ~/ 1000;
    final signingInput = _signingInput(
      {'alg': 'RS256', 'typ': 'JWT'},
      {
        'iss': email,
        'scope': _androidPublisherScope,
        'aud': _googleTokenUrl,
        'iat': issuedAt,
        'exp': issuedAt + 3600,
      },
    );

    // openssl reads the key from a file only this user can read, which is
    // removed whatever happens.
    final folder = Directory.systemTemp.createTempSync('release_play_');
    final List<int> signature;
    try {
      final keyFile = File('${folder.path}/key.pem')..createSync();
      final chmod = await Process.run('chmod', ['600', keyFile.path]);
      if (chmod.exitCode != 0) {
        throw TokenException('Google Play: could not protect the key file.');
      }
      keyFile.writeAsStringSync(privateKey, flush: true);
      signature = await _openSslSign(signingInput, keyFile.path, 'Google Play');
    } finally {
      folder.deleteSync(recursive: true);
    }

    final response = await _transport.send(
      'POST',
      Uri.parse(_googleTokenUrl),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: Uri(
        queryParameters: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': '$signingInput.${_base64Url(signature)}',
        },
      ).query,
    );
    Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      // Not JSON: reported below with the status code alone.
    }
    return switch (json) {
      {'access_token': final String token}
          when response.status == 200 && token.isNotEmpty =>
        token,
      {'error_description': final String reason} => throw TokenException(
        'Google Play: the token exchange failed with ${response.status}: '
        '$reason',
      ),
      _ => throw TokenException(
        'Google Play: the token exchange failed with ${response.status}.',
      ),
    };
  }
}

/// The environment variable that `keys.<key>` names in the config file.
String _variableName(AppConfig config, String key, String store) =>
    switch (config.keyPathVariables[key]) {
      final String name when name.isNotEmpty => name,
      _ => throw TokenException(
        '$store: "keys.$key" is not set in the config file.',
      ),
    };

/// The key file path from the variable that `keys.<key>` names, with a
/// leading `~` expanded. The file must exist.
String _keyFile(
  AppConfig config,
  Map<String, String> environment,
  String key,
  String store,
) {
  final variable = _variableName(config, key, store);
  var path = _setting(config, environment, variable, store);
  if (path == '~' || path.startsWith('~/')) {
    final home = environment['HOME'] ?? '';
    path = '$home${path.substring(1)}';
  }
  if (!File(path).existsSync()) {
    throw TokenException('$store: no key file at the path in $variable.');
  }
  return path;
}

/// A variable from the process environment, else from the `.env` file in the
/// app folder. The value is never printed.
String _setting(
  AppConfig config,
  Map<String, String> environment,
  String variable,
  String store,
) {
  final value = environment[variable] ?? _dotEnv(config.root)[variable];
  if (value == null || value.isEmpty) {
    throw TokenException(
      '$store: set $variable in the environment or in .env.',
    );
  }
  return value;
}

/// `KEY=value` lines of the `.env` file in [root], quotes and `export`
/// removed, comments and blank lines skipped.
Map<String, String> _dotEnv(String root) {
  final file = File('$root/.env');
  if (!file.existsSync()) return const {};
  final values = <String, String>{};
  for (var line in file.readAsLinesSync()) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trim();
    final equals = line.indexOf('=');
    if (equals <= 0) continue;
    var value = line.substring(equals + 1).trim();
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    values[line.substring(0, equals).trim()] = value;
  }
  return values;
}

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _signingInput(Map<String, Object> header, Map<String, Object> claims) =>
    '${_base64Url(utf8.encode(jsonEncode(header)))}.'
    '${_base64Url(utf8.encode(jsonEncode(claims)))}';

/// Signs [input] with SHA-256 and the private key at [keyPath] through
/// openssl, and returns the signature bytes.
Future<List<int>> _openSslSign(
  String input,
  String keyPath,
  String store,
) async {
  final Process process;
  try {
    process = await Process.start('openssl', [
      'dgst',
      '-sha256',
      '-sign',
      keyPath,
    ]);
  } on ProcessException {
    throw TokenException('$store: openssl is needed to sign the token.');
  }
  final signature = BytesBuilder(copy: false);
  final output = process.stdout.forEach(signature.add);
  // openssl's messages name files, not key contents, but they are dropped
  // anyway so nothing about the key reaches the terminal.
  final errors = process.stderr.drain<void>();
  process.stdin.add(utf8.encode(input));
  await process.stdin.close();
  final code = await process.exitCode;
  await output;
  await errors;
  if (code != 0 || signature.isEmpty) {
    throw TokenException('$store: openssl could not sign with the key file.');
  }
  return signature.takeBytes();
}

/// Converts an ECDSA signature from DER (`SEQUENCE { INTEGER r, INTEGER s }`)
/// to the 64-byte `r || s` form that ES256 JWTs use.
Uint8List _derToRawEcdsa(List<int> der) {
  var i = 0;
  int next() => i < der.length
      ? der[i++]
      : throw const FormatException('signature too short');
  int length() {
    final first = next();
    if (first < 0x80) return first;
    var value = 0;
    for (var n = first & 0x7f; n > 0; n--) {
      value = (value << 8) | next();
    }
    return value;
  }

  List<int> integer() {
    if (next() != 0x02) throw const FormatException('expected an INTEGER');
    final size = length();
    if (i + size > der.length) throw const FormatException('cut short');
    var bytes = der.sublist(i, i + size);
    i += size;
    while (bytes.length > 32 && bytes.first == 0) {
      bytes = bytes.sublist(1);
    }
    if (bytes.length > 32) throw const FormatException('INTEGER too long');
    return [...List.filled(32 - bytes.length, 0), ...bytes];
  }

  try {
    if (next() != 0x30) throw const FormatException('expected a SEQUENCE');
    length();
    return Uint8List.fromList([...integer(), ...integer()]);
  } on FormatException {
    throw TokenException(
      'App Store: openssl returned a signature that is not ES256. Is the '
      'key file an App Store Connect .p8 key?',
    );
  }
}
