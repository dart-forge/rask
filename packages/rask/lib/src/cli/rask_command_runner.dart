import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/gen/ensure.dart';
import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/plugin/resolve_targets.dart';
import 'package:rask/src/release/bump.dart';
import 'package:rask/src/release/publish.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/task/task_runner.dart';
import 'package:rask/src/workspace/filter.dart';
import 'package:rask/src/workspace/topological_order.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Exit code for usage errors (wrong arguments, not in a workspace).
const exitUsage = 64;

/// The `rask` command line. Everything it needs from the outside world
/// ([cwd], [processRunner], [out]) is injected so it can be tested without
/// touching the real workspace or spawning processes.
class RaskCommandRunner {
  final Directory cwd;
  final ProcessRunner processRunner;
  final PackageRegistry registry;
  final StringSink out;
  final RaskConfig config;

  /// Identifies the `rask.dart` in effect; part of every cache key.
  final String configKey;

  RaskCommandRunner({
    required this.cwd,
    this.processRunner = const SystemProcessRunner(),
    this.registry = const HttpPackageRegistry(),
    StringSink? out,
    this.config = const RaskConfig(),
    this.configKey = '',
  }) : out = out ?? stdout;

  /// Runs [args] and returns the process exit code.
  Future<int> run(List<String> args) async {
    var targets = const <String, ResolvedTarget>{};
    final ResolvedConfig resolved;
    try {
      // A plugin's targets decide whether there is a `build` task at all,
      // and that has to be known before the commands are built. Finding the
      // workspace can fail (rask run outside one), and that failure has to
      // stay a usage error with the same message as before.
      if (config.plugins.isNotEmpty) {
        final ws = _loadWorkspace();
        targets = resolveTargets(config, ws);
      }
      resolved = resolveConfig(config, targets: targets);
    } on ConfigError catch (e) {
      out.writeln('rask: $e');
      return exitUsage;
    } on _RaskError catch (e) {
      out.writeln('rask: ${e.message}');
      return exitUsage;
    }

    final runner = CommandRunner<int>(
      'rask',
      'Workspace-aware task runner for Dart. The verbs dart is missing.',
    );
    for (final task in resolved.tasks.values) {
      runner.addCommand(_TaskCommand(task, resolved, this));
    }
    runner
      ..addCommand(_PubCommand(this))
      ..addCommand(_BumpCommand(this))
      ..addCommand(_PublishCommand(this));

    try {
      return await runner.run(args) ?? 0;
    } on UsageException catch (e) {
      out.writeln(e);
      return exitUsage;
    } on _RaskError catch (e) {
      out.writeln('rask: ${e.message}');
      return exitUsage;
    }
  }

  List<Package> _select(Workspace ws, List<String> filters) {
    try {
      return selectPackages(ws, filters);
    } on ArgumentError catch (e) {
      throw _RaskError(e.message.toString());
    }
  }

  Workspace _loadWorkspace() {
    final root = Workspace.findRoot(cwd);
    if (root == null) {
      throw _RaskError(
        'no pubspec.yaml found in ${cwd.path} or any parent '
        'directory. Run rask inside a Dart package or workspace.',
      );
    }
    return Workspace.load(root);
  }
}

class _RaskError implements Exception {
  final String message;
  _RaskError(this.message);
}

/// `rask <task>`: one task fanned out over the workspace.
class _TaskCommand extends Command<int> {
  final Task task;
  final ResolvedConfig resolved;
  final RaskCommandRunner rask;

  _TaskCommand(this.task, this.resolved, this.rask) {
    argParser.addMultiOption(
      'filter',
      abbr: 'F',
      valueHelp: 'package',
      help:
          'Only run in the named package. `pkg...` adds its dependents, '
          '`...pkg` adds its dependencies. Repeatable.',
    );
    argParser.addFlag(
      'cache',
      defaultsTo: true,
      help:
          'Skip packages whose inputs have not changed since their last '
          'successful run. --no-cache runs everything and records nothing.',
    );
    argParser.addOption(
      'jobs',
      abbr: 'j',
      valueHelp: 'N',
      help:
          'Run up to N independent packages at once. Defaults to the number '
          'of CPU cores. Note that `dart test` runs its own suites in parallel '
          'too, so pin a smaller N on CI.',
    );
  }

  @override
  String get name => task.name;

  @override
  String get description =>
      task.description ?? 'Run the "${task.name}" task from rask.dart.';

  @override
  String get invocation =>
      'rask ${task.name} [-F <package>] [-j <N>] [--no-cache] [-- <args>]';

  @override
  Future<int> run() async {
    final ws = rask._loadWorkspace();
    final List<GeneratedPackage> generated;
    try {
      generated = resolveGeneratedPackages(resolved, ws);
    } on ConfigError catch (e) {
      throw _RaskError(e.message);
    }
    if (generated.isNotEmpty) {
      final EnsureResult ensured;
      try {
        ensured = await ensureGeneratedPackages(
          workspace: ws,
          generated: generated,
          runner: rask.processRunner,
          out: rask.out,
        );
      } on ConfigError catch (e) {
        throw _RaskError(e.message);
      } on FileSystemException catch (e) {
        rask.out.writeln(
          'rask: could not write the generated packages: ${e.message} '
          '(${e.path})',
        );
        return exitCannotRun;
      }
      if (ensured.pubGetExitCode != 0) return ensured.pubGetExitCode;
      for (final name in ensured.created) {
        final g = generated.firstWhere((g) => g.name == name);
        final producer = g.producer;
        final declaringTaskName = g.taskName;
        final pubspec = p.join(
          p.relative(producer.path, from: ws.root.path),
          'pubspec.yaml',
        );
        rask.out.writeln(
          'rask: created package $name in $genRoot\n'
          '      ${producer.name} imports it without declaring it, so the '
          'analyzer may hint about an undeclared dependency. Adding '
          '`$name: any` to $pubspec silences the hint, but then no clone '
          'can resolve dependencies until rask has generated $name, and '
          'neither `dart pub get` nor `rask pub get` can bootstrap that '
          '— leaving it undeclared is the safer default. Run '
          '`rask $declaringTaskName` now so $name has something in it to import.',
        );
      }
    }
    final targets = rask._select(ws, argResults!.multiOption('filter'));
    final cache = argResults!.flag('cache')
        ? TaskCache(
            workspace: ws,
            directory: Directory(
              p.join(ws.root.path, '.dart_tool', 'rask', 'cache'),
            ),
          )
        : null;
    final jobsArg = argResults!.option('jobs');
    final jobs = jobsArg == null
        ? Platform.numberOfProcessors
        : int.tryParse(jobsArg);
    if (jobs == null || jobs < 1) {
      throw _RaskError('--jobs must be a positive integer, got "$jobsArg"');
    }

    final TaskGraph graph;
    try {
      graph = buildTaskGraph(
        config: resolved,
        task: task.name,
        targets: targets,
        workspace: ws,
      );
    } on CyclicDependencyException catch (e) {
      throw _RaskError(e.toString());
    }
    return runTaskGraph(
      graph,
      workspace: ws,
      runner: rask.processRunner,
      out: rask.out,
      args: argResults!.rest,
      cache: cache,
      configKey: rask.configKey,
      jobs: jobs,
      taskName: task.name,
      generated: generated,
    );
  }
}

/// `rask pub <args>`: `dart pub <args>` at the workspace root.
class _PubCommand extends Command<int> {
  @override
  final name = 'pub';
  @override
  final description = 'Run `dart pub` at the workspace root.';
  final RaskCommandRunner rask;

  _PubCommand(this.rask);

  /// Everything after `pub` belongs to `dart pub`, options included.
  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  String get invocation => 'rask pub <dart pub args>';

  @override
  Future<int> run() async {
    final ws = rask._loadWorkspace();
    final args = argResults!.rest;
    rask.out.writeln('rask: ${ws.root.path} — dart pub ${args.join(' ')}');
    return rask.processRunner.run('dart', [
      'pub',
      ...args,
    ], workingDirectory: ws.root.path);
  }
}

/// `rask bump <version>`: lockstep version bump across the workspace.
class _BumpCommand extends Command<int> {
  @override
  final name = 'bump';
  @override
  final description =
      'Set every publishable package to <version>, bump constraints between '
      'workspace members to ^<version>, and fold "## Unreleased" in CHANGELOGs.';
  final RaskCommandRunner rask;

  _BumpCommand(this.rask);

  @override
  String get invocation => 'rask bump <version>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      throw UsageException('bump takes exactly one <version>', invocation);
    }
    final version = rest.single;
    if (!isValidVersion(version)) {
      throw _RaskError(
        '"$version" is not a version. Expected x.y.z, '
        'optionally with -pre-release and +build (no "v" prefix).',
      );
    }
    final ws = rask._loadWorkspace();
    final changed = bumpWorkspace(ws, version, rask.out);
    rask.out.writeln('rask: ${changed.length} file(s) updated to $version');
    return 0;
  }
}

/// `rask publish [--dry-run] [-F <package>]`: dependency-ordered publish.
class _PublishCommand extends Command<int> {
  @override
  final name = 'publish';
  @override
  final description =
      'Run `dart pub publish` for every publishable package, dependencies '
      'first, skipping versions the registry already has.';
  final RaskCommandRunner rask;

  _PublishCommand(this.rask) {
    argParser.addMultiOption(
      'filter',
      abbr: 'F',
      valueHelp: 'package',
      help: 'Only publish the named package (`pkg...` / `...pkg` as for test).',
    );
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Pass --dry-run to dart pub publish; never skips already-published versions.',
    );
  }

  @override
  String get invocation => 'rask publish [--dry-run] [-F <package>]';

  @override
  Future<int> run() async {
    final ws = rask._loadWorkspace();
    final packages = rask._select(ws, argResults!.multiOption('filter'));
    return publishPackages(
      packages,
      runner: rask.processRunner,
      registry: rask.registry,
      out: rask.out,
      dryRun: argResults!.flag('dry-run'),
    );
  }
}
