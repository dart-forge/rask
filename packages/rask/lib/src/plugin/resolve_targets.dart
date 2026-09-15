import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';

/// A target with the package it belongs to and the plugin that claimed it.
class ResolvedTarget {
  ResolvedTarget({
    required this.target,
    required this.package,
    required this.plugin,
  });

  final Target target;
  final Package package;
  final RaskPlugin plugin;

  @override
  String toString() => 'ResolvedTarget(${target.name} for ${package.name})';
}

/// Every target [config]'s plugins claim over [workspace], by package name.
///
/// Each plugin is asked once per package and the answers are kept, so a
/// plugin's `targetFor` runs once per run however many times rask needs the
/// result.
///
/// Throws [ConfigError] when two plugins claim the same package: rask cannot
/// know which one should start it.
Map<String, ResolvedTarget> resolveTargets(
  RaskConfig config,
  Workspace workspace,
) {
  final resolved = <String, ResolvedTarget>{};
  for (final plugin in config.plugins) {
    for (final pkg in workspace.packages) {
      final target = plugin.targetFor(pkg);
      if (target == null) continue;
      final existing = resolved[pkg.name];
      if (existing != null) {
        throw ConfigError(
          'Two plugins provide a target for ${pkg.name}: '
          '"${existing.target.name}" and "${target.name}". Remove one of '
          'them from rask.dart.',
        );
      }
      resolved[pkg.name] = ResolvedTarget(
        target: target,
        package: pkg,
        plugin: plugin,
      );
    }
  }
  return resolved;
}
