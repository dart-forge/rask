import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Exit code when a task's process could not be started at all (`dart`
/// missing from PATH, ...): `EX_SOFTWARE` (D-035).
const exitCannotRun = 70;

/// Exit code for a task that threw something other than [ProcessFailure].
const exitTaskError = 1;

/// Runs [graph] stage by stage: inside a stage up to [jobs] nodes run at
/// once; a stage starts when the previous one is done. With a [cache], a
/// node whose key is fresh (inputs unchanged and outputs intact) is skipped,
/// and every successful node is recorded. After the first failure no new
/// node starts, running nodes are awaited, and that failure's exit code is
/// returned: the process's code for [ProcessFailure], 70 when a process
/// could not start, 1 for any other exception (D-039).
Future<int> runTaskGraph(
  TaskGraph graph, {
  required Workspace workspace,
  required ProcessRunner runner,
  required StringSink out,
  List<String> args = const [],
  TaskCache? cache,
  String configKey = '',
  int jobs = 1,
}) async {
  if (jobs < 1) throw ArgumentError.value(jobs, 'jobs', 'must be at least 1');
  final keys = <TaskNode, String>{};
  int? failure;

  for (final stage in graph.stages) {
    final pending = <TaskNode>[];
    for (final node in stage) {
      final key = cache?.keyForTask(
        package: node.package,
        task: node.task.name,
        args: args,
        inputs: node.task.inputs,
        outputs: node.task.outputs,
        dependsOnKeys: [for (final d in graph.dependenciesOf(node)) keys[d]!],
        configKey: configKey,
      );
      if (key != null) keys[node] = key;
      if (key != null && cache!.isFresh(key, package: node.package, outputs: node.task.outputs)) {
        out.writeln('rask: ${node.package.name} — ${node.task.name} (cached, skip)');
        continue;
      }
      pending.add(node);
    }

    final stream = jobs == 1 || pending.length == 1;
    final queue = Queue.of(pending);

    Future<void> worker() async {
      while (queue.isNotEmpty && failure == null) {
        final node = queue.removeFirst();
        final buffer = stream ? null : StringBuffer();
        final sink = buffer ?? out;
        if (stream) sink.writeln('rask: ${node.package.name} — ${node.task.name}');
        final ctx = _RunContext(node, workspace, args, runner, sink, capture: !stream);
        int? code;
        try {
          await node.task.run!(ctx);
        } on ProcessFailure catch (e) {
          sink.writeln('rask: ${node.package.name} — ${node.task.name} failed (exit ${e.exitCode})');
          code = e.exitCode;
        } on ProcessException catch (e) {
          sink.writeln('rask: ${node.package.name} — ${node.task.name} failed ($e)');
          code = exitCannotRun;
        } catch (e, st) {
          sink.writeln('rask: ${node.package.name} — ${node.task.name} failed ($e)');
          // Error (StateError, ArgumentError, ...) means a bug in the task's
          // Dart code, not an expected failure: keep the stack trace so it
          // can be found without reproducing the run.
          if (e is Error) sink.writeln(st.toString());
          code = exitTaskError;
        }
        if (buffer != null) {
          out.writeln('rask: ${node.package.name} — ${node.task.name}');
          out.write(buffer.toString());
        }
        cache?.invalidate(node.package); // the run may have written into the package
        if (code != null) {
          failure ??= code;
        } else if (cache != null) {
          cache.storeTask(keys[node]!,
              package: node.package, task: node.task.name, outputs: node.task.outputs);
        }
      }
    }

    await Future.wait(List.generate(min(jobs, pending.length), (_) => worker()));
    if (failure != null) return failure!;
  }
  return 0;
}

/// The [TaskContext] a node runs with. In capture mode process output and
/// `log` lines go to the node's buffer; otherwise straight to the terminal.
class _RunContext implements TaskContext {
  final TaskNode _node;
  @override
  final Workspace workspace;
  @override
  final List<String> args;
  final ProcessRunner _runner;
  final StringSink _sink;
  final bool capture;

  _RunContext(this._node, this.workspace, this.args, this._runner, this._sink,
      {required this.capture});

  @override
  Package get package => _node.package;

  @override
  Future<void> dart(List<String> args) => exec('dart', args);

  @override
  Future<void> exec(String executable, List<String> args, {String? workingDirectory}) async {
    final dir = workingDirectory ?? package.path;
    final int code;
    if (capture) {
      final result = await _runner.runCaptured(executable, args, workingDirectory: dir);
      _sink.write(result.output);
      if (result.output.isNotEmpty && !result.output.endsWith('\n')) _sink.writeln();
      code = result.exitCode;
    } else {
      code = await _runner.run(executable, args, workingDirectory: dir);
    }
    if (code != 0) throw ProcessFailure([executable, ...args].join(' '), code);
  }

  @override
  void log(String message) => _sink.writeln('rask: ${package.name} — $message');
}
