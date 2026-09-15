import 'dart:io';

import 'package:rask/src/plugin/plugin.dart';

/// A process rask started and still holds.
abstract class RunningProcess {
  int get pid;

  /// Completes when the process is gone.
  Future<int> get exitCode;

  /// Stops the process and everything it started, gently first.
  Future<void> terminate();
}

/// Starts long-lived processes. Abstracted so the dev loop can be tested
/// without spawning anything: [ProcessRunner] cannot do this job because it
/// only starts a process and waits for it to finish.
abstract class ProcessLauncher {
  Future<RunningProcess> start(
    Command command, {
    required String workingDirectory,
  });
}

/// Starts real processes.
class SystemProcessLauncher implements ProcessLauncher {
  const SystemProcessLauncher();

  @override
  Future<RunningProcess> start(
    Command command, {
    required String workingDirectory,
  }) async {
    final process = await Process.start(
      command.executable,
      command.args,
      workingDirectory: workingDirectory,
      environment: command.environment,
      mode: ProcessStartMode.inheritStdio,
    );
    return _SystemProcess(process);
  }
}

class _SystemProcess implements RunningProcess {
  _SystemProcess(this._process);
  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> terminate() async {
    if (Platform.isWindows) {
      _process.kill(ProcessSignal.sigterm);
      await _process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      return;
    }
    await _killTree(_process.pid);
  }
}

/// Kills [pid] and its descendants, deepest first so nothing is reparented
/// and left running: `npx` starts `wrangler`, which starts `workerd`, and
/// killing only the one rask started would leave a port bound.
///
/// Sends SIGTERM to the whole tree, waits up to five seconds for it to go,
/// then SIGKILLs whatever is left.
Future<void> _killTree(int pid) async {
  final descendants = await _descendants(pid);
  for (final child in descendants) {
    await Process.run('kill', ['-TERM', '$child']);
  }
  await Process.run('kill', ['-TERM', '$pid']);

  const poll = Duration(milliseconds: 200);
  var waited = Duration.zero;
  while (waited < const Duration(seconds: 5)) {
    if (!await _alive(pid) && (await _descendants(pid)).isEmpty) return;
    await Future<void>.delayed(poll);
    waited += poll;
  }
  for (final child in descendants) {
    if (await _alive(child)) await Process.run('kill', ['-9', '$child']);
  }
  if (await _alive(pid)) await Process.run('kill', ['-9', '$pid']);
}

/// PIDs below [pid], deepest first. Best effort: anything forked while this
/// walks may be missed.
Future<List<int>> _descendants(int pid) async {
  final result = await Process.run('pgrep', ['-P', '$pid']);
  final children = (result.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(int.parse);
  final ordered = <int>[];
  for (final child in children) {
    ordered
      ..addAll(await _descendants(child))
      ..add(child);
  }
  return ordered;
}

Future<bool> _alive(int pid) async =>
    (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
