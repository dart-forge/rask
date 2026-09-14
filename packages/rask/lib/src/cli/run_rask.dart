import 'dart:io';

import 'package:rask/src/cli/rask_command_runner.dart';
import 'package:rask/src/task/task.dart';

/// Runs the rask command line with [config] in effect and returns the exit
/// code. This is what the generated `.dart_tool/rask/entrypoint.dart` calls
/// with the `config` from `rask.dart`; the launcher calls it with the
/// default config when there is no `rask.dart`.
Future<int> runRask(
  List<String> args,
  RaskConfig config, {
  String configKey = '',
}) => RaskCommandRunner(
  cwd: Directory.current,
  config: config,
  configKey: configKey,
).run(args);
