import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/release/publish.dart';
import 'package:rask/src/run/process_runner.dart';

/// A [ProcessRunner] that records calls instead of spawning anything.
/// Exit codes are looked up by the working directory's basename.
class RecordingRunner implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  final Map<String, int> exitCodes;
  final Set<String> cannotStart;
  RecordingRunner({this.exitCodes = const {}, this.cannotStart = const {}});

  int _code(String dir) {
    final name = p.basename(dir);
    if (cannotStart.contains(name)) throw ProcessException('dart', const [], 'not found', 2);
    return exitCodes[name] ?? 0;
  }

  @override
  Future<int> run(String executable, List<String> args, {required String workingDirectory}) async {
    calls.add((executable, args, workingDirectory));
    return _code(workingDirectory);
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory}) async {
    calls.add((executable, args, workingDirectory));
    return CapturedProcess(_code(workingDirectory), 'out of ${p.basename(workingDirectory)}\n');
  }
}

/// A registry that has nothing published.
class NoRegistry implements PackageRegistry {
  @override
  Future<bool> hasVersion({required String host, required String name, required String version}) async =>
      false;
}
