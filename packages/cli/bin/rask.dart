import 'dart:io';

import 'package:rask/src/cli/run_rask.dart';
import 'package:rask/src/task/task.dart';

Future<void> main(List<String> args) async {
  exit(await runRask(args, const RaskConfig()));
}
