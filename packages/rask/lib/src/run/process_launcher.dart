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
      await _terminateDirectly(_process);
      return;
    }
    await terminateProcess(_process);
  }
}

/// Terminates [process]: by default, its whole tree ([killTree], deepest
/// descendant first) — but the process alone, signalled directly, when
/// [killTree] fails for any reason (enumerating or signalling a descendant
/// needs `pgrep` and `kill`, missing on a slim container, say). Either way
/// this never throws: a caller stopping a dev loop cannot be left with a
/// pending stop because the host has no `pgrep`.
///
/// Exposed (rather than kept as a `_SystemProcess` implementation detail)
/// so a test can force the fallback without needing a host that actually
/// lacks `pgrep`: pass a [killTree] that throws.
Future<void> terminateProcess(
  Process process, {
  Future<void> Function(int pid) killTree = _killTree,
}) async {
  try {
    await killTree(process.pid);
  } catch (_) {
    await _terminateDirectly(process);
  }
}

/// Signals [process] itself (not its tree) via Dart's own [Process.kill] —
/// nothing shelled out, so nothing here can fail for a missing executable.
/// SIGTERM, then SIGKILL if it has not gone within five seconds.
Future<void> _terminateDirectly(Process process) async {
  process.kill(ProcessSignal.sigterm);
  await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
}

/// Kills [pid] and its descendants, deepest first so nothing is reparented
/// and left running: `npx` starts `wrangler`, which starts `workerd`, and
/// killing only the one rask started would leave a port bound.
///
/// Sends SIGTERM to the whole tree, waits up to five seconds for it to go,
/// then SIGKILLs whatever is left. Shells out to `pgrep` and `kill`; a
/// failure here (either missing) is the caller's job to fall back on.
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
