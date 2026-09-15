import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';

/// The context a hook runs with, for both tasks and targets.
///
/// In capture mode process output and [log] lines go to the given sink;
/// otherwise straight to the terminal.
class RunContext implements TargetContext {
  RunContext({
    required this.package,
    required this.workspace,
    required this.args,
    required this.runner,
    required this.sink,
    required this.capture,
    this.gen,
    this.port,
    this.label,
  });

  @override
  final Package package;
  @override
  final Workspace workspace;
  @override
  final List<String> args;
  @override
  final String? gen;
  @override
  final int? port;

  final ProcessRunner runner;
  final StringSink sink;
  final bool capture;

  /// What [log] names after the package: a task's name, or a target's.
  final String? label;

  @override
  Future<void> dart(List<String> args) => exec('dart', args);

  @override
  Future<void> exec(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    final dir = workingDirectory ?? package.path;
    final int code;
    if (capture) {
      final result = await runner.runCaptured(
        executable,
        args,
        workingDirectory: dir,
      );
      sink.write(result.output);
      if (result.output.isNotEmpty && !result.output.endsWith('\n')) {
        sink.writeln();
      }
      code = result.exitCode;
    } else {
      code = await runner.run(executable, args, workingDirectory: dir);
    }
    if (code != 0) throw ProcessFailure([executable, ...args].join(' '), code);
  }

  @override
  void log(String message) => sink.writeln('rask: ${package.name} — $message');
}
