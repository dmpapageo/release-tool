import 'package:args/args.dart';
import 'package:release_tool/src/bump.dart';
import 'package:release_tool/src/check_listing.dart';
import 'package:release_tool/src/config.dart';
import 'package:release_tool/src/http_transport.dart';
import 'package:release_tool/src/status.dart';
import 'package:release_tool/src/store_auth.dart';

/// Exit code for a bad command line or an unreadable config file.
const usageError = 64;

ArgParser _withConfig(ArgParser parser) => parser
  ..addOption(
    'config',
    defaultsTo: 'release.yaml',
    help: 'Per-app config file. Paths in it are relative to its folder.',
  );

ArgParser _parser() => ArgParser()
  ..addCommand('check-listing', _withConfig(ArgParser()))
  ..addCommand(
    'status',
    _withConfig(ArgParser())
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.'),
  )
  ..addCommand(
    'bump',
    _withConfig(ArgParser())
      ..addOption(
        'version',
        valueHelp: 'major.minor.patch',
        help: 'Also set the App version (default: build number only).',
      )
      ..addOption(
        'build',
        valueHelp: 'number',
        help: 'The build number to set (default: the current one plus one).',
      ),
  );

/// Runs one release subcommand and returns its exit code.
int runRelease(
  List<String> args, {
  required StringSink out,
  required StringSink err,
}) {
  final parser = _parser();
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    err.writeln(e.message);
    return usageError;
  }
  final command = results.command;
  if (command == null) {
    if (results.rest.isNotEmpty) {
      err.writeln('Unknown command "${results.rest.first}".');
    }
    err
      ..writeln('Usage: release <command> [options]')
      ..writeln('Commands: ${parser.commands.keys.join(', ')}');
    return usageError;
  }

  final AppConfig config;
  try {
    config = AppConfig.load(command.option('config')!);
  } on ConfigException catch (e) {
    err.writeln(e.message);
    return usageError;
  }

  return switch (command.name) {
    'check-listing' => checkListing(config, out: out),
    'bump' => _bump(config, command, out: out, err: err),
    'status' => _asyncOnly(command.name!, err),
    _ => usageError,
  };
}

int _bump(
  AppConfig config,
  ArgResults command, {
  required StringSink out,
  required StringSink err,
}) {
  final buildOption = command.option('build');
  final build = buildOption == null ? null : int.tryParse(buildOption);
  if (buildOption != null && build == null) {
    err.writeln('--build must be a number, got "$buildOption".');
    return usageError;
  }
  try {
    final next = bump(config, version: command.option('version'), build: build);
    out.writeln('Bumped to $next, committed and tagged ${next.tag}');
    return 0;
  } on BumpException catch (e) {
    err.writeln(e.message);
    return 1;
  }
}

int _asyncOnly(String command, StringSink err) {
  err.writeln(
    '"$command" talks to the store APIs; run it with runReleaseAsync.',
  );
  return usageError;
}

/// Runs one release subcommand, including the ones that talk to the store
/// APIs, and returns its exit code. [statusServices] replaces the network and
/// token seams for `status`; by default they are the real ones.
Future<int> runReleaseAsync(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  StatusServices Function(AppConfig config)? statusServices,
}) async {
  final ArgResults results;
  try {
    results = _parser().parse(args);
  } on FormatException {
    return runRelease(args, out: out, err: err);
  }
  final command = results.command;
  if (command == null || command.name != 'status') {
    return runRelease(args, out: out, err: err);
  }
  if (command.flag('help')) {
    out
      ..writeln('Usage: release status [options]')
      ..writeln()
      ..writeln(
        'Reads the release state from each enabled store (read-only), '
        'rewrites the status file and the app line in the HUD file.',
      )
      ..writeln()
      ..writeln(_parser().commands['status']!.usage)
      ..writeln()
      ..writeln('Exit codes:')
      ..writeln('  0   done: live on every store, or nothing in flight')
      ..writeln('  3   a Release is in flight (a rejection counts)')
      ..writeln('  1   a store API call, a key or a file failed')
      ..writeln('  64  bad command line or config file');
    return 0;
  }

  final AppConfig config;
  try {
    config = AppConfig.load(command.option('config')!);
  } on ConfigException catch (e) {
    err.writeln(e.message);
    return usageError;
  }
  if (statusServices != null) {
    return status(config, statusServices(config), out: out, err: err);
  }
  final transport = IoHttpTransport();
  try {
    return await status(
      config,
      StatusServices(
        transport: transport,
        appleTokens: AppStoreConnectTokens(config),
        playTokens: PlayTokens(config, transport),
      ),
      out: out,
      err: err,
    );
  } finally {
    transport.close();
  }
}
