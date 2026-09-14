import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/run/dart_verb.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

class RecordingRunner implements ProcessRunner {
  /// Every invocation, streamed or captured: (executable, args, workingDirectory).
  final calls = <(String, List<String>, String)>[];
  /// Working directories of the invocations that went through [runCaptured].
  final captured = <String>[];
  final Map<String, int> exitCodes;
  RecordingRunner({this.exitCodes = const {}});

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory}) async {
    calls.add((executable, args, workingDirectory));
    return exitCodes[p.basename(workingDirectory)] ?? 0;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory}) async {
    captured.add(workingDirectory);
    final code = await run(executable, args, workingDirectory: workingDirectory);
    return CapturedProcess(code, 'output of ${p.basename(workingDirectory)}\n');
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
      {required String workingDirectory}) async {
    final pkg = p.basename(workingDirectory);
    events.add('start $pkg');
    final code = await gate(pkg).future;
    events.add('end $pkg');
    return code;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory}) async {
    final code = await run(executable, args, workingDirectory: workingDirectory);
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
      {required String workingDirectory}) async {
    final pkg = p.basename(workingDirectory);
    started.add(pkg);
    if (pkg == throwFor) throw ProcessException(executable, args, 'dart not found', 2);
    return 0;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory}) async =>
      CapturedProcess(await run(executable, args, workingDirectory: workingDirectory), '');
}

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_verb_');
    void put(String rel, String yaml, {bool withTests = false}) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
      if (withTests) {
        Directory(p.join(d.path, 'test')).createSync();
        File(p.join(d.path, 'test', 'x_test.dart')).writeAsStringSync('');
      }
    }
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/tmp1', 'name: tmp1\ndependencies:\n  tmp2: any\n', withTests: true);
    put('packages/tmp2', 'name: tmp2\n', withTests: true);
    put('packages/tmp3', 'name: tmp3\n'); // no test/ directory
    put('packages/tmp4', 'name: tmp4\n'); // independent, no test/ directory
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('runs `dart <verb>` in each selected package, dependencies first', () async {
    final runner = RecordingRunner();
    final code = await runDartVerb(
      'analyze',
      workspace: ws, packages: ws.inOrder,
      runner: runner,
      out: StringBuffer(),
    );
    expect(code, 0);
    final visited = runner.calls.map((c) => p.basename(c.$3)).toList();
    expect(visited, unorderedEquals(['tmp1', 'tmp2', 'tmp3', 'tmp4']));
    expect(visited.indexOf('tmp2'), lessThan(visited.indexOf('tmp1')));
    expect(runner.calls.every((c) => c.$1 == 'dart' && c.$2.first == 'analyze'), isTrue);
  });

  test('passes extra arguments through to dart', () async {
    final runner = RecordingRunner();
    await runDartVerb('test', workspace: ws, packages: [ws['tmp2']], runner: runner,
        out: StringBuffer(), extraArgs: ['--reporter', 'expanded']);
    expect(runner.calls.single.$2, ['test', '--reporter', 'expanded']);
  });

  test('`test` skips packages that have no test/ directory', () async {
    final runner = RecordingRunner();
    final out = StringBuffer();
    await runDartVerb('test', workspace: ws, packages: ws.inOrder, runner: runner, out: out);
    expect(runner.calls.map((c) => p.basename(c.$3)), unorderedEquals(['tmp2', 'tmp1']));
    expect(out.toString(), contains('tmp3'));
    expect(out.toString(), contains('skip'));
  });

  test('`test` skips packages whose test/ has no *_test.dart files', () async {
    // an empty test/ makes `dart test` exit 79 ("No tests were found")
    Directory(p.join(ws['tmp3'].path, 'test')).createSync();
    // a nested _test.dart still counts
    Directory(p.join(ws['tmp1'].path, 'test', 'unit')).createSync();
    File(p.join(ws['tmp1'].path, 'test', 'unit', 'a_test.dart')).writeAsStringSync('');
    // helpers that are not tests do not count
    File(p.join(ws['tmp2'].path, 'test', 'x_test.dart')).deleteSync();
    File(p.join(ws['tmp2'].path, 'test', 'helper.dart')).writeAsStringSync('');

    final runner = RecordingRunner();
    await runDartVerb('test', workspace: ws, packages: ws.inOrder, runner: runner, out: StringBuffer());
    expect(runner.calls.map((c) => p.basename(c.$3)), ['tmp1']);
  });

  test('stops at the first failure and returns its exit code', () async {
    final runner = RecordingRunner(exitCodes: {'tmp2': 3});
    final code = await runDartVerb('analyze', workspace: ws, packages: ws.inOrder,
        runner: runner, out: StringBuffer());
    expect(code, 3);
    expect(runner.calls.map((c) => p.basename(c.$3)), ['tmp2']);
  });

  test('announces each package before running it', () async {
    final runner = RecordingRunner();
    final out = StringBuffer();
    await runDartVerb('analyze', workspace: ws, packages: [ws['tmp2']], runner: runner, out: out);
    expect(out.toString(), contains('tmp2'));
    expect(out.toString(), contains('dart analyze'));
  });

  group('with a TaskCache', () {
    late Directory cacheDir;
    setUp(() {
      File(p.join(ws['tmp2'].path, 'lib', 'x.dart')).createSync(recursive: true);
      cacheDir = Directory(p.join(root.path, '.dart_tool', 'rask', 'cache'));
    });

    // one TaskCache instance per simulated rask process
    TaskCache newCache() => TaskCache(workspace: ws, directory: cacheDir, sdkVersion: '3.13.0');

    Future<(int, RecordingRunner, String)> run({Map<String, int> exitCodes = const {}}) async {
      final runner = RecordingRunner(exitCodes: exitCodes);
      final out = StringBuffer();
      final code = await runDartVerb('analyze',
          workspace: ws, packages: [ws['tmp2']], runner: runner, out: out, cache: newCache());
      return (code, runner, out.toString());
    }

    test('a successful run is skipped the second time with the same inputs', () async {
      final first = await run();
      expect(first.$2.calls, hasLength(1));
      final second = await run();
      expect(second.$1, 0);
      expect(second.$2.calls, isEmpty);
      expect(second.$3, contains('tmp2'));
      expect(second.$3, contains('cached'));
    });

    test('a failed run is not cached', () async {
      final failed = await run(exitCodes: {'tmp2': 1});
      expect(failed.$1, 1);
      final again = await run();
      expect(again.$2.calls, hasLength(1));
    });

    test('changing a file in the package runs it again', () async {
      await run();
      File(p.join(ws['tmp2'].path, 'lib', 'x.dart')).writeAsStringSync('// changed');
      final again = await run();
      expect(again.$2.calls, hasLength(1));
    });

    test('changing a dependency runs the dependent again', () async {
      final runner = RecordingRunner();
      Future<int> both() => runDartVerb('analyze',
          workspace: ws, packages: [ws['tmp2'], ws['tmp1']], runner: runner, out: StringBuffer(), cache: newCache());
      await both();
      expect(runner.calls, hasLength(2));
      File(p.join(ws['tmp2'].path, 'lib', 'x.dart')).writeAsStringSync('// changed');
      await both();
      expect(runner.calls, hasLength(4)); // tmp2 changed, tmp1 depends on it
    });
  });

  group('parallel stages', () {
    // fixture graph: tmp1 -> tmp2; tmp3 and tmp4 are independent.
    // stages: [tmp2, tmp3, tmp4] then [tmp1]

    test('independent packages of one stage run at once, up to --jobs', () async {
      final runner = GatedRunner();
      final done = runDartVerb('analyze', workspace: ws, packages: ws.inOrder, runner: runner,
          out: StringBuffer(), jobs: 2);
      await pumpEventQueue();
      expect(runner.events.where((e) => e.startsWith('start')), hasLength(2));
      expect(runner.events, isNot(contains('start tmp1')));
      for (final pkg in ['tmp2', 'tmp3', 'tmp4']) {
        runner.gate(pkg).complete(0);
      }
      await pumpEventQueue(); // stage 1 (tmp1) starts once stage 0 is done
      runner.gate('tmp1').complete(0);
      expect(await done, 0);
    });

    test('a dependent starts only after its whole stage has finished', () async {
      final runner = GatedRunner();
      final done = runDartVerb('analyze', workspace: ws, packages: ws.inOrder, runner: runner,
          out: StringBuffer(), jobs: 4);
      await pumpEventQueue();
      expect(runner.events, unorderedEquals(['start tmp2', 'start tmp3', 'start tmp4']));
      runner.gate('tmp2').complete(0);
      await pumpEventQueue();
      expect(runner.events, isNot(contains('start tmp1'))); // tmp3/tmp4 still running
      runner.gate('tmp3').complete(0);
      runner.gate('tmp4').complete(0);
      await pumpEventQueue();
      expect(runner.events, contains('start tmp1'));
      runner.gate('tmp1').complete(0);
      expect(await done, 0);
    });

    test('after a failure nothing new starts, running packages finish, first failure code is returned', () async {
      final runner = GatedRunner();
      final out = StringBuffer();
      final done = runDartVerb('analyze', workspace: ws, packages: ws.inOrder, runner: runner,
          out: out, jobs: 2);
      await pumpEventQueue();
      final started = runner.events.map((e) => e.substring('start '.length)).toList();
      expect(started, hasLength(2));
      final (first, second) = (started[0], started[1]);
      final third = ['tmp2', 'tmp3', 'tmp4'].where((x) => x != first && x != second).single;

      runner.gate(first).complete(7);
      await pumpEventQueue();
      expect(runner.events, isNot(contains('start $third')));
      expect(runner.events, isNot(contains('start tmp1')));

      runner.gate(second).complete(0);
      expect(await done, 7);
      expect(runner.events, contains('end $second'));
      expect(out.toString(), contains('output of $second'));
      expect(out.toString(), contains('$first — dart analyze failed (exit 7)'));
    });

    test('captured output is printed as one block per package', () async {
      final runner = RecordingRunner();
      final out = StringBuffer();
      await runDartVerb('analyze', workspace: ws, packages: [ws['tmp3'], ws['tmp4']], runner: runner,
          out: out, jobs: 2);
      expect(out.toString(), contains('rask: tmp3 — dart analyze\noutput of tmp3\n'));
      expect(out.toString(), contains('rask: tmp4 — dart analyze\noutput of tmp4\n'));
    });

    test('a stage with a single runner streams instead of capturing', () async {
      final runner = RecordingRunner();
      await runDartVerb('analyze', workspace: ws, packages: [ws['tmp2'], ws['tmp1']], runner: runner,
          out: StringBuffer(), jobs: 4);
      expect(runner.calls, hasLength(2));
      expect(runner.captured, isEmpty);
    });

    test('jobs: 1 always streams', () async {
      final runner = RecordingRunner();
      await runDartVerb('analyze', workspace: ws, packages: ws.inOrder, runner: runner,
          out: StringBuffer(), jobs: 1);
      expect(runner.calls, hasLength(4));
      expect(runner.captured, isEmpty);
    });

    test('a package that succeeds after another failed is still recorded in the cache', () async {
      final runner = GatedRunner();
      final cacheDir = Directory(p.join(root.path, '.dart_tool', 'rask', 'cache'));
      final cache = TaskCache(workspace: ws, directory: cacheDir, sdkVersion: '3.13.0');
      final done = runDartVerb('analyze', workspace: ws, packages: [ws['tmp3'], ws['tmp4']], runner: runner,
          out: StringBuffer(), jobs: 2, cache: cache);
      await pumpEventQueue();
      runner.gate('tmp3').complete(1);
      runner.gate('tmp4').complete(0);
      expect(await done, 1);
      expect(cache.contains(cache.keyFor(ws['tmp4'], 'analyze', const [])), isTrue);
      expect(cache.contains(cache.keyFor(ws['tmp3'], 'analyze', const [])), isFalse);
    });

    test('a runner that throws counts as a failure with exit 70 and stops new work', () async {
      final runner = ThrowingRunner(throwFor: 'tmp2');
      final out = StringBuffer();
      final code = await runDartVerb('analyze', packages: ws.inOrder, workspace: ws,
          runner: runner, out: out, jobs: 1);
      expect(code, 70);
      expect(runner.started, ['tmp2']); // jobs: 1 and tmp2 is first in stage 0
      expect(out.toString(), contains('tmp2 — dart analyze failed ('));
      expect(out.toString(), contains('dart not found'));
    });

    test('jobs below 1 is rejected', () {
      expect(
        () => runDartVerb('analyze', workspace: ws, packages: ws.inOrder, runner: RecordingRunner(),
            out: StringBuffer(), jobs: 0),
        throwsArgumentError,
      );
    });
  });
}
