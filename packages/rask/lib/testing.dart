/// Test doubles for [ProcessRunner] and [PackageRegistry]. Import as
/// package:rask/testing.dart.
library;

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
    if (cannotStart.contains(name)) {
      throw ProcessException('dart', const [], 'not found', 2);
    }
    return exitCodes[name] ?? 0;
  }

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable, args, workingDirectory));
    environments.add(environment);
    return _code(workingDirectory);
  }

  @override
  Future<CapturedProcess> runCaptured(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable, args, workingDirectory));
    environments.add(environment);
    return CapturedProcess(
      _code(workingDirectory),
      'out of ${p.basename(workingDirectory)}\n',
    );
  }
}

/// A runner whose processes finish only when the test completes their gate,
/// so a test can observe what runs concurrently and what waits.
class GatedRunner implements ProcessRunner {
  /// `start <pkg>` and `end <pkg>` in the order they happened.
  final events = <String>[];
  final _gates = <String, Completer<int>>{};

  /// Completing this with an exit code lets the package's fake process finish.
  Completer<int> gate(String pkg) =>
      _gates.putIfAbsent(pkg, Completer<int>.new);

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final pkg = p.basename(workingDirectory);
    events.add('start $pkg');
    final code = await gate(pkg).future;
    events.add('end $pkg');
    return code;
  }

  @override
  Future<CapturedProcess> runCaptured(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final code = await run(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return CapturedProcess(code, 'output of ${p.basename(workingDirectory)}\n');
  }
}

/// A runner whose process for [throwFor] cannot even be started.
class ThrowingRunner implements ProcessRunner {
  final String throwFor;
  final started = <String>[];
  ThrowingRunner({required this.throwFor});

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final pkg = p.basename(workingDirectory);
    started.add(pkg);
    if (pkg == throwFor) {
      throw ProcessException(executable, args, 'dart not found', 2);
    }
    return 0;
  }

  @override
  Future<CapturedProcess> runCaptured(
    String executable,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async => CapturedProcess(
    await run(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    ),
    '',
  );
}

/// A registry that has nothing published.
class NoRegistry implements PackageRegistry {
  @override
  Future<bool> hasVersion({
    required String host,
    required String name,
    required String version,
  }) async => false;
}
