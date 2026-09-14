import 'dart:io';

import 'package:rask/src/cli/rask_command_runner.dart';

Future<void> main(List<String> args) async {
  exit(await RaskCommandRunner(cwd: Directory.current).run(args));
}
