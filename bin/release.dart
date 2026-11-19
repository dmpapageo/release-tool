import 'dart:io';

import 'package:release_tool/release_tool.dart';

Future<void> main(List<String> args) async {
  exitCode = await runReleaseAsync(args, out: stdout, err: stderr);
}
