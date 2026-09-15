import 'dart:async';
import 'dart:io';

import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/plugin/resolve_targets.dart';
import 'package:rask/src/run/process_launcher.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/task/run_context.dart';
import 'package:rask/src/task/task_runner.dart'
    show exitCannotRun, exitTaskError;
import 'package:rask/src/workspace/workspace.dart';

/// The `rask dev` loop: rask owns it so that every framework behaves the
/// same. It runs the target's prerequisites, prepares, starts the process,
/// and from then on reacts to changes according to the target's [OnChange].
///
/// Most failures after the process is up never end the loop: the previous
/// process and the previous artifacts stay, the reason is printed, and the
/// next change tries again. The process exiting on its own does not end the
/// loop either — that is usually a compile error the developer is about to
/// fix. The one exception is a restart whose new process cannot even be
/// started (`dart` missing from PATH, ...): the old process is already gone
/// by then, so there is nothing left to preserve, and the loop ends with 70
/// instead of idling with nothing running.
class DevLoop {
  DevLoop({
    required this.resolved,
    required this.workspace,
    required ProcessLauncher launcher,
    required ProcessRunner runner,
    required this.out,
    required Stream<String> changes,
    required Future<int> Function() runDependsOn,
    this.args = const [],
    this.port,
    this.debounce = const Duration(milliseconds: 500),
  }) : _launcher = launcher, // ignore: prefer_initializing_formals
       _runner = runner, // ignore: prefer_initializing_formals
       _changes = changes, // ignore: prefer_initializing_formals
       _runDependsOn = runDependsOn; // ignore: prefer_initializing_formals

  final ResolvedTarget resolved;
  final Workspace workspace;
  final StringSink out;
  final List<String> args;
  final int? port;
  final Duration debounce;

  final ProcessLauncher _launcher;
  final ProcessRunner _runner;
  final Stream<String> _changes;
  final Future<int> Function() _runDependsOn;

  RunningProcess? _process;
  StreamSubscription<String>? _subscription;
  Timer? _timer;
  final _finished = Completer<int>();
  var _handling = false;
  var _pending = false;
  var _stopping = false;
  var _ready = false;

  /// The currently running round of [_handle], if any: [stop] awaits this
  /// before touching [_process], so it never races a restart that is
  /// already underway.
  Future<void>? _inFlight;

  Target get _target => resolved.target;

  TargetContext _context() => RunContext(
    package: resolved.package,
    workspace: workspace,
    args: args,
    runner: _runner,
    sink: out,
    capture: false,
    port: port,
  );

  Command _command() => _target.command(_context());

  /// Runs until [stop]. Returns 0 for a clean stop, or the exit code of a
  /// failure that happened before the process was up.
  Future<int> run() async {
    // Subscribed from the start, before there is anything to react to yet:
    // [_ready] keeps [_onChange] from doing anything until the process is
    // up. Listening this early — rather than only after a successful start —
    // means the subscription always exists, so a caller that never gets a
    // process running can still close its changes stream cleanly.
    _subscription = _changes.listen(_onChange);
    final prerequisites = await _runDependsOn();
    if (prerequisites != 0) return _bail(prerequisites);
    try {
      await _target.prepare?.call(_context());
    } on ProcessException catch (e) {
      out.writeln('rask: ${resolved.package.name} — prepare failed ($e)');
      return _bail(exitCannotRun);
    } catch (e) {
      out.writeln('rask: ${resolved.package.name} — prepare failed ($e)');
      return _bail(exitTaskError);
    }
    try {
      await _start();
    } on ProcessException catch (e) {
      out.writeln(
        'rask: could not start ${_target.name} (${e.message}). '
        'Check that ${_command().executable} is installed and on PATH.',
      );
      return _bail(exitCannotRun);
    }
    // stop() may have run while _start() was awaiting the launcher: _start
    // has already refused to keep the process it just started running, so
    // there is nothing left to do but report the clean stop.
    if (_stopping) return 0;
    _ready = true;
    return _finished.future;
  }

  /// Cancels the subscription taken out at the top of [run] and returns
  /// [code]: used on every path that ends before the process is up.
  Future<int> _bail(int code) async {
    await _subscription?.cancel();
    return code;
  }

  /// Stops the process and ends the loop.
  ///
  /// Final: waits for any round of [_handle] already in flight to finish —
  /// every await point in that round bails out without starting anything
  /// once [_stopping] is set — then terminates whatever is left running.
  /// Nothing started after this returns outlives the loop.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _timer?.cancel();
    await _subscription?.cancel();
    if (_inFlight != null) await _inFlight;
    final process = _process;
    _process = null;
    await process?.terminate();
    if (!_finished.isCompleted) _finished.complete(0);
  }

  /// Ends the loop outright with [code], without touching [_process]: used
  /// when a restart's new process could not even be started, so there is
  /// nothing left running to preserve.
  Future<void> _endWith(int code) async {
    if (_stopping) return;
    _stopping = true;
    _timer?.cancel();
    await _subscription?.cancel();
    if (!_finished.isCompleted) _finished.complete(code);
  }

  /// Starts the target's process and, in the background, watches for it to
  /// exit on its own so the loop notices without anyone awaiting it.
  ///
  /// Bails out — terminating what it just started without ever making it
  /// the loop's current process — if [stop] ran while the process was
  /// coming up.
  Future<void> _start() async {
    final process = await _launcher.start(
      _command(),
      workingDirectory: resolved.package.path,
    );
    if (_stopping) {
      await process.terminate();
      return;
    }
    _process = process;
    unawaited(_watchExit(process));
  }

  /// Notices when [process] ends without anyone here having stopped it
  /// (a crash, a compile error that killed the process, ...). Does nothing
  /// when [process] is no longer the current one: that means a restart or
  /// [stop] already took it down deliberately.
  Future<void> _watchExit(RunningProcess process) async {
    final exitCode = await process.exitCode;
    if (!identical(_process, process)) return;
    _process = null;
    if (_stopping) return;
    out.writeln(
      'rask: ${resolved.package.name} — ${_target.name} exited (exit $exitCode)',
    );
  }

  /// Terminates whatever is running, then starts the target again.
  ///
  /// A [ProcessException] from the new start is not left running (nothing
  /// is, the old process is already gone) and is not left to escape either:
  /// it ends the loop with 70, the same code a start failure at boot uses.
  Future<void> _restart() async {
    final process = _process;
    _process = null;
    await process?.terminate();
    if (_stopping) return;
    try {
      await _start();
    } on ProcessException catch (e) {
      out.writeln(
        'rask: could not restart ${_target.name} (${e.message}). '
        'Check that ${_command().executable} is installed and on PATH.',
      );
      await _endWith(exitCannotRun);
    }
  }

  void _onChange(String _) {
    if (!_ready) return;
    if (_handling) {
      _pending = true;
      return;
    }
    // A timer already waiting covers any change that arrives while it does.
    _timer ??= Timer(debounce, () {
      _timer = null;
      _inFlight = _handle();
    });
  }

  /// Handles one round of changes, then — if more arrived while this round
  /// ran — handles those too, collapsed into a single extra round.
  Future<void> _handle() async {
    do {
      _pending = false;
      _handling = true;
      try {
        await _handleOnce();
      } finally {
        _handling = false;
      }
    } while (_pending);
  }

  /// Runs the dependencies and, depending on [Target.onChange], `prepare`
  /// and a restart. Any failure here is printed and leaves the process (and
  /// the loop) exactly as it was: the next change tries again.
  Future<void> _handleOnce() async {
    final code = await _runDependsOn();
    if (_stopping) return;
    if (code != 0) {
      out.writeln(
        'rask: ${resolved.package.name} — dependencies failed (exit $code)',
      );
      return;
    }
    final onChange = _target.onChange;
    if (onChange == OnChange.rebuild ||
        onChange == OnChange.rebuildAndRestart) {
      try {
        await _target.prepare?.call(_context());
      } catch (e) {
        out.writeln('rask: ${resolved.package.name} — prepare failed ($e)');
        return;
      }
      if (_stopping) return;
    }
    if (onChange == OnChange.restart ||
        onChange == OnChange.rebuildAndRestart) {
      await _restart();
    }
  }
}
