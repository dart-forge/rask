import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Contributes targets: the things `rask dev` starts and `rask build`
/// produces.
///
/// rask owns the lifecycle — watching, debouncing, restarting, stopping,
/// what happens when something fails. A plugin only says what to compile
/// and what to run, so that every framework gets the same `rask dev`.
abstract class RaskPlugin {
  /// The target for [pkg], or null when this plugin does not serve it.
  ///
  /// Must be pure and cheap: rask asks once per package per run and never
  /// expects a process to start here. How a plugin decides is its own
  /// business — a key in the package's pubspec, the presence of a file,
  /// anything.
  Target? targetFor(Package pkg);
}

/// One thing that can be developed and built. A value, like [Task].
class Target {
  Target(
    this.name, {
    required this.command,
    required this.build,
    this.prepare,
    this.watch = const ['lib/**', 'bin/**'],
    this.dependsOn = const [],
    this.onChange = OnChange.restart,
    this.buildInputs,
    this.buildOutputs = const [],
  });

  /// What this target is, for messages: 'server', 'edge', 'web'.
  final String name;

  /// The process `rask dev` starts. rask owns it from there: it streams its
  /// output, restarts it, and stops it with the rest of its process tree.
  final Command Function(TargetContext ctx) command;

  /// Produces the shippable artifact. Runs as the `build` task, so it is
  /// cached and fans out over the workspace.
  final Future<void> Function(TargetContext ctx) build;

  /// What `rask dev` needs before the process can start, if anything. Run
  /// again on a change when [onChange] rebuilds.
  final Future<void> Function(TargetContext ctx)? prepare;

  /// Globs, relative to the package, whose changes drive the dev loop.
  ///
  /// rask watches the literal part of each glob and never watches
  /// `.dart_tool`: generated code lives there, and watching it would make
  /// the loop feed itself.
  final List<String> watch;

  /// Tasks that must succeed before the process starts, and again before a
  /// restart or a rebuild: `'codegen'`, `'^codegen'`.
  final List<String> dependsOn;

  /// What a change to a watched file does.
  final OnChange onChange;

  /// Globs that decide the `build` task's cache key. null means every file
  /// in the package.
  final List<String>? buildInputs;

  /// Globs the `build` task produces, verified on a cache hit.
  final List<String> buildOutputs;

  @override
  String toString() => 'Target($name)';
}

/// What a change to a watched file does in `rask dev`.
enum OnChange {
  /// Nothing: the process watches its own sources (Flutter, vite, ...).
  nothing,

  /// Run `prepare` again and leave the process alone: the runtime picks the
  /// new artifacts up by itself.
  rebuild,

  /// Restart the process.
  restart,

  /// Run `prepare` again, then restart.
  rebuildAndRestart,
}

/// A process for rask to start.
class Command {
  Command(this.executable, this.args, {this.environment});

  final String executable;
  final List<String> args;

  /// Added to the parent's environment when given.
  final Map<String, String>? environment;

  @override
  String toString() => '$executable ${args.join(' ')}';
}

/// What a target's hooks see: a [TaskContext] plus the port the user asked
/// for.
abstract class TargetContext implements TaskContext {
  /// `--port` as given, or null. rask neither assigns nor probes ports; the
  /// target decides what to do with this.
  int? get port;
}
