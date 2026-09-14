import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:rask/testing.dart';

/// A [RecordingRunner] that fakes `dart compile exe`: it writes the `-o`
/// file and a depfile listing the workspace's rask.dart and rask/tasks.dart
/// (when they exist) plus one SDK path, then returns [compileExitCode].
class FakeCompiler extends RecordingRunner {
  final String root;
  final int compileExitCode;
  final String compileOutput;

  /// When true, [run] (the exec step) throws instead of returning, as if
  /// the compiled exe could not be started.
  final bool failExec;

  /// Absolute paths appended to the depfile, as a `path:` dependency
  /// outside the workspace root would appear in a real one.
  final List<String> extraDepfileInputs;
  int compiles = 0;
  FakeCompiler({
    required this.root,
    this.compileExitCode = 0,
    this.compileOutput = '',
    this.failExec = false,
    this.extraDepfileInputs = const [],
    super.exitCodes,
  });

  @override
  Future<CapturedProcess> runCaptured(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (executable == 'dart' &&
        args.take(2).toList().join(' ') == 'compile exe') {
      compiles++;
      calls.add((executable, args, workingDirectory));
      environments.add(environment);
      final out = args[args.indexOf('-o') + 1];
      final dep = args[args.indexOf('--depfile') + 1];
      // Written even when the compile fails: a real compile can leave a
      // partial output behind, and the launcher must not leave it lying
      // around (F1).
      File(out)
        ..createSync(recursive: true)
        ..writeAsStringSync('#!fake exe\n');
      if (compileExitCode == 0) {
        final inputs = [
          ...[
            '$root/rask.dart',
            '$root/rask/tasks.dart',
          ].where((f) => File(f).existsSync()),
          ...extraDepfileInputs,
        ].join(' ');
        File(
          dep,
        ).writeAsStringSync('$out: $inputs /opt/dart-sdk/lib/core/core.dart\n');
      }
      return CapturedProcess(compileExitCode, compileOutput);
    }
    return super.runCaptured(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (failExec) {
      throw ProcessException(executable, const [], 'Exec format error', 8);
    }
    calls.add((executable, args, workingDirectory));
    environments.add(environment);
    return exitCodes[p.basename(executable)] ??
        exitCodes[p.basename(workingDirectory)] ??
        0;
  }
}
