import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Runs `dart <verb> <extraArgs>` inside each of [packages], in the given
/// order, stopping at the first non-zero exit code and returning it.
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
  required ProcessRunner runner,
  required StringSink out,
  List<String> extraArgs = const [],
  TaskCache? cache,
}) async {
  final command = ['dart', verb, ...extraArgs].join(' ');
  for (final pkg in packages) {
    if (verb == 'test' && !_hasTests(pkg)) {
      out.writeln('rask: ${pkg.name} — skip (no *_test.dart under test/)');
      continue;
    }
    final key = cache?.keyFor(pkg, verb, extraArgs);
    if (key != null && cache!.contains(key)) {
      out.writeln('rask: ${pkg.name} — $command (cached, skip)');
      continue;
    }
    out.writeln('rask: ${pkg.name} — $command');
    final code = await runner.run('dart', [verb, ...extraArgs],
        workingDirectory: pkg.path);
    if (code != 0) {
      out.writeln('rask: ${pkg.name} — $command failed (exit $code)');
      return code;
    }
    if (key != null) cache!.store(key, package: pkg, verb: verb);
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
