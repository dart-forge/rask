import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/release/publish.dart';
import 'package:rask/src/run/process_runner.dart';

/// A [ProcessRunner] that records calls instead of spawning anything.
/// Exit codes are looked up by the working directory's basename.
class RecordingRunner implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  final environments = <Map<String, String>?>[];
  final Map<String, int> exitCodes;
  final Set<String> cannotStart;
  RecordingRunner({this.exitCodes = const {}, this.cannotStart = const {}});

  int _code(String dir) {
    final name = p.basename(dir);
    if (cannotStart.contains(name)) throw ProcessException('dart', const [], 'not found', 2);
    return exitCodes[name] ?? 0;
  }

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    calls.add((executable, args, workingDirectory));
    environments.add(environment);
    return _code(workingDirectory);
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    calls.add((executable, args, workingDirectory));
    environments.add(environment);
    return CapturedProcess(_code(workingDirectory), 'out of ${p.basename(workingDirectory)}\n');
  }
}

/// A runner whose processes finish only when the test completes their gate,
/// so a test can observe what runs concurrently and what waits.
class GatedRunner implements ProcessRunner {
  /// `start <pkg>` and `end <pkg>` in the order they happened.
  final events = <String>[];
  final _gates = <String, Completer<int>>{};

  /// Completing this with an exit code lets the package's fake process finish.
  Completer<int> gate(String pkg) => _gates.putIfAbsent(pkg, Completer<int>.new);

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    final pkg = p.basename(workingDirectory);
    events.add('start $pkg');
    final code = await gate(pkg).future;
    events.add('end $pkg');
    return code;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    final code = await run(executable, args, workingDirectory: workingDirectory, environment: environment);
    return CapturedProcess(code, 'output of ${p.basename(workingDirectory)}\n');
  }
}

/// A runner whose process for [throwFor] cannot even be started.
class ThrowingRunner implements ProcessRunner {
  final String throwFor;
  final started = <String>[];
  ThrowingRunner({required this.throwFor});

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    final pkg = p.basename(workingDirectory);
    started.add(pkg);
    if (pkg == throwFor) throw ProcessException(executable, args, 'dart not found', 2);
    return 0;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async =>
      CapturedProcess(await run(executable, args, workingDirectory: workingDirectory, environment: environment), '');
}

/// A registry that has nothing published.
class NoRegistry implements PackageRegistry {
  @override
  Future<bool> hasVersion({required String host, required String name, required String version}) async =>
      false;
}

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
  int compiles = 0;
  FakeCompiler({
    required this.root,
    this.compileExitCode = 0,
    this.compileOutput = '',
    this.failExec = false,
    super.exitCodes,
  });

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    if (executable == 'dart' && args.take(2).toList().join(' ') == 'compile exe') {
      compiles++;
      calls.add((executable, args, workingDirectory));
      environments.add(environment);
      final out = args[args.indexOf('-o') + 1];
      final dep = args[args.indexOf('--depfile') + 1];
      if (compileExitCode == 0) {
        File(out)
          ..createSync(recursive: true)
          ..writeAsStringSync('#!fake exe\n');
        final inputs = ['$root/rask.dart', '$root/rask/tasks.dart']
            .where((f) => File(f).existsSync())
            .join(' ');
        File(dep).writeAsStringSync('$out: $inputs /opt/dart-sdk/lib/core/core.dart\n');
      }
      return CapturedProcess(compileExitCode, compileOutput);
    }
    return super.runCaptured(executable, args, workingDirectory: workingDirectory, environment: environment);
  }

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    if (failExec) throw ProcessException('entrypoint.exe', const [], 'Exec format error', 8);
    calls.add((executable, args, workingDirectory));
    environments.add(environment);
    return exitCodes[p.basename(executable)] ?? exitCodes[p.basename(workingDirectory)] ?? 0;
  }
}
