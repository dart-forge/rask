import 'package:path/path.dart' as p;
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Where rask keeps the packages it generates, relative to the workspace
/// root. Inside `.dart_tool` so it is already ignored by git and already
/// invisible to `dart pub publish`.
const String genRoot = '.dart_tool/rask/gen';

/// Absolute path of the directory that holds every generated package.
String genRootDir(String workspaceRootPath) =>
    p.joinAll([workspaceRootPath, ...genRoot.split('/')]);

/// A package rask owns because a task declares it with `Task.generates`.
///
/// Not a workspace member: it has no tasks of its own and never becomes a
/// node in the task graph. pub sees it through a path override that rask
/// writes into the root `pubspec_overrides.yaml`.
class GeneratedPackage {
  /// The pub package name, as `Task.generates` returned it.
  final String name;

  /// The workspace member whose task generates it.
  final Package producer;

  /// The name of the task that generates it.
  final String taskName;

  /// Absolute path of the generated package's directory.
  final String dir;

  GeneratedPackage({
    required this.name,
    required this.producer,
    required this.taskName,
    required this.dir,
  });

  /// Absolute path of the directory the generator writes into.
  String get libDir => p.join(dir, 'lib');

  /// The path a `pubspec_overrides.yaml` entry uses: posix, relative to the
  /// workspace root.
  String get overridePath => '$genRoot/$name';

  @override
  String toString() => 'GeneratedPackage($name from ${producer.name})';
}

final _packageName = RegExp(r'^[a-z][a-z0-9_]*$');

/// Every generated package [config] declares over [workspace], sorted by
/// name.
///
/// Throws [ConfigError] when a name is not a package name, when two packages
/// claim the same name, or when a name collides with a workspace member:
/// each of those would end in a confusing pub failure later.
List<GeneratedPackage> resolveGeneratedPackages(
  ResolvedConfig config,
  Workspace workspace,
) {
  final byName = <String, GeneratedPackage>{};
  for (final task in config.tasks.values) {
    final generates = task.generates;
    if (generates == null) continue;
    final where = task.where;
    for (final pkg in workspace.packages) {
      if (where != null && !where(pkg)) continue;
      final name = generates(pkg);
      if (!_packageName.hasMatch(name)) {
        throw ConfigError(
          'Task "${task.name}" generates "$name" for package ${pkg.name}, '
          'which is not a package name (lowercase letters, digits and '
          'underscores, starting with a letter).',
        );
      }
      Package? member;
      for (final m in workspace.packages) {
        if (m.name == name) member = m;
      }
      if (member != null) {
        throw ConfigError(
          'Task "${task.name}" generates "$name" for package ${pkg.name}, '
          'but ${p.relative(member.path, from: workspace.root.path)} is '
          'already a workspace member with that name.',
        );
      }
      final clash = byName[name];
      if (clash != null) {
        throw ConfigError(
          'Packages ${clash.producer.name} and ${pkg.name} both generate '
          '"$name". Generated package names must be unique across the '
          'workspace.',
        );
      }
      byName[name] = GeneratedPackage(
        name: name,
        producer: pkg,
        taskName: task.name,
        dir: p.join(genRootDir(workspace.root.path), name),
      );
    }
  }
  final result = byName.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return result;
}
