import 'dart:io';

import 'package:rask/engine.dart';

Future<void> main(List<String> args) async {
  exit(await runRask(args, const RaskConfig()));
}
