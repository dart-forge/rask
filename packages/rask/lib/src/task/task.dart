import 'package:rask/src/plugin/plugin.dart';
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

  /// The per-package form of [inputs], for a task whose declarations differ
  /// by package (the synthesized `build` task, one target's globs per
  /// package). A task sets one form or the other, never both; when this is
  /// set, it is used instead of [inputs] for every package the task runs in.
  final List<String>? Function(Package pkg)? inputsFor;

  /// The per-package form of [outputs], for a task whose declarations differ
  /// by package. A task sets one form or the other, never both; when this is
  /// set, it is used instead of [outputs] for every package the task runs
  /// in.
  final List<String> Function(Package pkg)? outputsFor;

  /// The package rask generates for each package this task applies to, by
  /// name: `generates: (pkg) => '${pkg.name}_gen'`.
  ///
  /// rask owns that package (`.dart_tool/rask/gen/<name>/`) and its pubspec,
  /// puts a path override for it in the root `pubspec_overrides.yaml`, and
  /// hands [TaskContext.gen] to [run] as the directory to write into. A task
  /// that declares this must also declare [run]: rask never generates
  /// anything by itself.
  final String Function(Package pkg)? generates;

  final String? description;

  Task(
    this.name, {
    this.where,
    this.run,
    this.dependsOn = const [],
    this.inputs,
    this.outputs = const [],
    this.inputsFor,
    this.outputsFor,
    this.generates,
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

  /// Absolute path of the `lib` directory of the package this task generates,
  /// emptied right before the run. Null when the task has no `generates`.
  String? get gen;

  /// Runs `dart <args>` in the package directory. Throws [ProcessFailure]
  /// on a non-zero exit.
  Future<void> dart(List<String> args);

  /// Runs any executable, in the package directory unless [workingDirectory]
  /// is given. Throws [ProcessFailure] on a non-zero exit.
  Future<void> exec(
    String executable,
    List<String> args, {
    String? workingDirectory,
  });

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

  /// Plugins that contribute targets for `rask dev` and `rask build`.
  final List<RaskPlugin> plugins;

  const RaskConfig({this.tasks = const [], this.plugins = const []});
}

/// The one function `rask.dart` calls: `final config = defineConfig(...)`.
RaskConfig defineConfig({
  List<Task> tasks = const [],
  List<RaskPlugin> plugins = const [],
}) => RaskConfig(tasks: tasks, plugins: plugins);

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
