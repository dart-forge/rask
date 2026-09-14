import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Verbs that are commands, not tasks. A task may not take these names.
///
/// 'help' is not one of ours: args' `CommandRunner` pre-registers a hidden
/// `help` command on construction, so a task named `help` would crash with
/// `ArgumentError: Duplicate command "help"` instead of a clean ConfigError.
const Set<String> commandNames = {'pub', 'bump', 'publish', 'help'};

/// Whether [pkg] has at least one `*_test.dart` under `test/`. `dart test`
/// exits 79 when it finds no tests, which would otherwise fail a run for a
/// package that simply has nothing to test yet.
bool hasTests(Package pkg) {
  final dir = Directory(p.join(pkg.path, 'test'));
  if (!dir.existsSync()) return false;
  return dir
      .listSync(recursive: true, followLinks: false)
      .any((e) => e is File && e.path.endsWith('_test.dart'));
}

/// The tasks every workspace has, with or without a `rask.dart`.
final List<Task> builtinTasks = [
  Task(
    'test',
    description: 'Run `dart test` in every package that has tests.',
    where: hasTests,
    run: (ctx) => ctx.dart(['test', ...ctx.args]),
  ),
  Task(
    'analyze',
    description: 'Run `dart analyze` in every package.',
    run: (ctx) => ctx.dart(['analyze', ...ctx.args]),
  ),
];
