import 'dart:io';

import 'package:rask/engine.dart';
import 'package:rask_cli/rask_cli.dart';

Future<void> main(List<String> args) async {
  exit(
    await Launcher(
      cwd: Directory.current,
      runner: const SystemProcessRunner(),
      err: stderr,
      environment: Platform.environment,
    ).run(args),
  );
}
