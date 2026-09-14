/// rask — what a `rask.dart` needs.
///
/// ```dart
/// import 'package:rask/rask.dart';
///
/// final config = defineConfig(tasks: [
///   Task('codegen',
///       where: (pkg) => pkg.dependsOn('build_runner'),
///       run: (ctx) => ctx.dart(['run', 'build_runner', 'build'])),
/// ]);
/// ```
///
/// The engine behind it (graph, cache, CLI) is `package:rask/engine.dart`.
library;

export 'src/cli/run_rask.dart';
export 'src/task/builtin_tasks.dart' show hasTests;
export 'src/task/task.dart';
export 'src/workspace/workspace.dart';
