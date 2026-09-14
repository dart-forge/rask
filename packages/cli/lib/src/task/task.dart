import 'package:rask/src/workspace/workspace.dart';
import 'package:yaml/yaml.dart';

/// One thing rask can do to a package: `rask <name>`.
///
/// A task is a value; `rask.dart` builds a list of them with [defineConfig].
/// Built-in tasks (`test`, `analyze`) are values too.
class Task {
  final String name;

  /// Which packages the task applies to. `null` means every package.
  final bool Function(Package pkg)? where;

  /// What the task does in one package. `null` only for built-in tasks,
  /// whose run is supplied by rask.
  final Future<void> Function(TaskContext ctx)? run;

  /// Tasks that must have finished first: `'x'` for the same package's `x`,
  /// `'^x'` for `x` in the packages this one depends on.
  final List<String> dependsOn;

  /// Globs (relative to the package) that decide the task's cache key.
  /// `null` means every file in the package.
  final List<String>? inputs;

  /// Globs (relative to the package) the task produces. Excluded from
  /// [inputs] and verified on a cache hit.
  final List<String> outputs;

  final String? description;

  Task(
    this.name, {
    this.where,
    this.run,
    this.dependsOn = const [],
    this.inputs,
    this.outputs = const [],
    this.description,
  });

  @override
  String toString() => 'Task($name)';
}

/// What a [Task.run] sees while running in one package.
abstract class TaskContext {
  Package get package;
  Workspace get workspace;

  /// Arguments after `--` on the command line.
  List<String> get args;

  /// Runs `dart <args>` in the package directory. Throws [ProcessFailure]
  /// on a non-zero exit.
  Future<void> dart(List<String> args);

  /// Runs any executable, in the package directory unless [workingDirectory]
  /// is given. Throws [ProcessFailure] on a non-zero exit.
  Future<void> exec(String executable, List<String> args, {String? workingDirectory});

  /// Writes a `rask: <pkg> — <message>` line.
  void log(String message);
}

/// A process started by [TaskContext.dart] / [TaskContext.exec] exited
/// non-zero.
class ProcessFailure implements Exception {
  final String command;
  final int exitCode;
  ProcessFailure(this.command, this.exitCode);

  @override
  String toString() => '$command failed (exit $exitCode)';
}

/// The configuration is not usable: duplicate task, unknown `dependsOn`,
/// a task named like a command, ...
class ConfigError implements Exception {
  final String message;
  ConfigError(this.message);

  @override
  String toString() => message;
}

/// What `rask.dart` evaluates to. Built with [defineConfig].
class RaskConfig {
  final List<Task> tasks;
  const RaskConfig({this.tasks = const []});
}

/// The one function `rask.dart` calls: `final config = defineConfig(...)`.
RaskConfig defineConfig({List<Task> tasks = const []}) => RaskConfig(tasks: tasks);

extension PackageDependsOn on Package {
  /// Whether [packageName] appears in this package's `dependencies` or
  /// `dev_dependencies`, whatever its source. Not limited to workspace
  /// members — `pkg.dependsOn('build_runner')` is the typical use.
  bool dependsOn(String packageName) {
    for (final section in const ['dependencies', 'dev_dependencies']) {
      final deps = pubspec[section];
      if (deps is YamlMap && deps.containsKey(packageName)) return true;
    }
    return false;
  }
}
