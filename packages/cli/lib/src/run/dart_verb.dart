import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/stages.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Runs `dart <verb> <extraArgs>` inside each of [packages], dependencies
/// first, stopping at the first non-zero exit code and returning it.
///
/// [packages] is cut into stages (see [stagesOf]); stages run one after
/// another and, inside a stage, up to [jobs] packages run at once. A package
/// that shares its stage with other runners has its output captured and
/// printed as one block when it finishes; a package that runs alone streams
/// to the terminal. After a failure no further package starts, packages
/// already running are awaited (their output is still printed), and the
/// exit code of the first package to fail is returned.
///
/// With a [cache], a package whose inputs have not changed since its last
/// successful run is skipped, and each successful run is recorded.
///
/// For `test`, packages with no `*_test.dart` under `test/` are skipped:
/// `dart test` exits 79 when it finds no tests, which would otherwise fail
/// the whole run for a package that simply has nothing to test yet.
Future<int> runDartVerb(
  String verb, {
  required List<Package> packages,
  required Workspace workspace,
  required ProcessRunner runner,
  required StringSink out,
  List<String> extraArgs = const [],
  TaskCache? cache,
  int jobs = 1,
}) async {
  if (jobs < 1) throw ArgumentError.value(jobs, 'jobs', 'must be at least 1');
  final command = ['dart', verb, ...extraArgs].join(' ');
  int? failure;

  for (final stage in stagesOf(packages, workspace: workspace)) {
    // Skip decisions are made up front, in input order, so their lines come
    // out before any process output of the stage.
    final runners = <(Package, String?)>[];
    for (final pkg in stage) {
      if (verb == 'test' && !_hasTests(pkg)) {
        out.writeln('rask: ${pkg.name} — skip (no *_test.dart under test/)');
        continue;
      }
      final key = cache?.keyFor(pkg, verb, extraArgs);
      if (key != null && cache!.contains(key)) {
        out.writeln('rask: ${pkg.name} — $command (cached, skip)');
        continue;
      }
      runners.add((pkg, key));
    }

    final stream = jobs == 1 || runners.length == 1;
    final queue = Queue.of(runners);

    Future<void> worker() async {
      while (queue.isNotEmpty && failure == null) {
        final (pkg, key) = queue.removeFirst();
        final int code;
        if (stream) {
          out.writeln('rask: ${pkg.name} — $command');
          code = await runner.run('dart', [verb, ...extraArgs], workingDirectory: pkg.path);
        } else {
          final result = await runner.runCaptured('dart', [verb, ...extraArgs],
              workingDirectory: pkg.path);
          out.writeln('rask: ${pkg.name} — $command');
          out.write(result.output);
          if (result.output.isNotEmpty && !result.output.endsWith('\n')) out.writeln();
          code = result.exitCode;
        }
        if (code != 0) {
          out.writeln('rask: ${pkg.name} — $command failed (exit $code)');
          failure ??= code;
        } else if (key != null) {
          cache!.store(key, package: pkg, verb: verb);
        }
      }
    }

    await Future.wait(List.generate(min(jobs, runners.length), (_) => worker()));
    if (failure != null) return failure!;
  }
  return 0;
}

bool _hasTests(Package pkg) {
  final dir = Directory(p.join(pkg.path, 'test'));
  if (!dir.existsSync()) return false;
  return dir
      .listSync(recursive: true, followLinks: false)
      .any((e) => e is File && e.path.endsWith('_test.dart'));
}
