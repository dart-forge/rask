import 'dart:io';

import 'package:rask/engine.dart';

Future<void> main(List<String> args) async {
  exit(await Launcher(
    cwd: Directory.current,
    runner: const SystemProcessRunner(),
    err: stderr,
    environment: Platform.environment,
  ).run(args));
}
