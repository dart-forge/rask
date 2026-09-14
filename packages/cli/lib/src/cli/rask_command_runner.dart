import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/release/bump.dart';
import 'package:rask/src/release/publish.dart';
import 'package:rask/src/run/dart_verb.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/filter.dart';
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

  RaskCommandRunner({
    required this.cwd,
    this.processRunner = const SystemProcessRunner(),
    this.registry = const HttpPackageRegistry(),
    StringSink? out,
  }) : out = out ?? stdout;

  /// Runs [args] and returns the process exit code.
  Future<int> run(List<String> args) async {
    final runner = CommandRunner<int>(
      'rask',
      'Workspace-aware task runner for Dart. The verbs dart is missing.',
    )
      ..addCommand(_DartVerbCommand('test', 'Run `dart test` in every package.', this))
      ..addCommand(_DartVerbCommand('analyze', 'Run `dart analyze` in every package.', this))
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
      throw _RaskError('no pubspec.yaml found in ${cwd.path} or any parent '
          'directory. Run rask inside a Dart package or workspace.');
    }
    return Workspace.load(root);
  }
}

class _RaskError implements Exception {
  final String message;
  _RaskError(this.message);
}

/// `rask test` / `rask analyze`: the dart verb, fanned out over the workspace.
class _DartVerbCommand extends Command<int> {
  @override
  final String name;
  @override
  final String description;
  final RaskCommandRunner rask;

  _DartVerbCommand(this.name, this.description, this.rask) {
    argParser.addMultiOption(
      'filter',
      abbr: 'F',
      valueHelp: 'package',
      help: 'Only run in the named package. `pkg...` adds its dependents, '
          '`...pkg` adds its dependencies. Repeatable.',
    );
    argParser.addFlag(
      'cache',
      defaultsTo: true,
      help: 'Skip packages whose inputs have not changed since their last '
          'successful run. --no-cache runs everything and records nothing.',
    );
  }

  @override
  String get invocation => 'rask $name [-F <package>] [--no-cache] [-- <dart $name args>]';

  @override
  Future<int> run() async {
    final ws = rask._loadWorkspace();
    final packages = rask._select(ws, argResults!.multiOption('filter'));
    final cache = argResults!.flag('cache')
        ? TaskCache(
            workspace: ws,
            directory: Directory(p.join(ws.root.path, '.dart_tool', 'rask', 'cache')),
          )
        : null;
    return runDartVerb(
      name,
      packages: packages,
      runner: rask.processRunner,
      out: rask.out,
      extraArgs: argResults!.rest,
      cache: cache,
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
    return rask.processRunner
        .run('dart', ['pub', ...args], workingDirectory: ws.root.path);
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
      throw _RaskError('"$version" is not a version. Expected x.y.z, '
          'optionally with -pre-release and +build (no "v" prefix).');
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
    argParser.addMultiOption('filter', abbr: 'F', valueHelp: 'package',
        help: 'Only publish the named package (`pkg...` / `...pkg` as for test).');
    argParser.addFlag('dry-run', negatable: false,
        help: 'Pass --dry-run to dart pub publish; never skips already-published versions.');
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
