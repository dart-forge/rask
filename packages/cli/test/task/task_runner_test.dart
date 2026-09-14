import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/task/task_runner.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

import '../helpers/recording_runner.dart';

void main() {
  late Directory root;
  late Workspace ws;

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_runner_');
    write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
    write('pubspec.lock', '');
    // app -> lib ; lone
    write('packages/app/pubspec.yaml', 'name: app\ndependencies:\n  lib: any\n');
    write('packages/app/lib/a.dart', '');
    write('packages/lib/pubspec.yaml', 'name: lib\n');
    write('packages/lib/lib/l.dart', '');
    write('packages/lone/pubspec.yaml', 'name: lone\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  TaskGraph graph(List<Task> tasks, String task, {List<Package>? targets}) => buildTaskGraph(
        config: resolveConfig(defineConfig(tasks: tasks)),
        task: task,
        targets: targets ?? ws.inOrder,
        workspace: ws,
      );

  TaskCache cache() => TaskCache(
        workspace: ws,
        directory: Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')),
        sdkVersion: '3.13.0',
      );

  Future<(int, RecordingRunner, String)> run(TaskGraph g,
      {Map<String, int> exitCodes = const {},
      Set<String> cannotStart = const {},
      TaskCache? c,
      int jobs = 1,
      List<String> args = const []}) async {
    final runner = RecordingRunner(exitCodes: exitCodes, cannotStart: cannotStart);
    final out = StringBuffer();
    final code = await runTaskGraph(g,
        workspace: ws, runner: runner, out: out, cache: c, jobs: jobs, args: args);
    return (code, runner, out.toString());
  }

  List<String> dirs(RecordingRunner r) => r.calls.map((c) => p.basename(c.$3)).toList();

  test('runs the builtin analyze in every package via ctx.dart, dependencies first', () async {
    final (code, runner, out) = await run(graph([], 'analyze'));
    expect(code, 0);
    expect(dirs(runner), unorderedEquals(['app', 'lib', 'lone']));
    expect(dirs(runner).indexOf('lib'), lessThan(dirs(runner).indexOf('app')));
    // List == is identity: compare the single element, not the list
    expect(runner.calls.every((c) => c.$1 == 'dart' && c.$2.single == 'analyze'), isTrue);
    expect(out, contains('rask: lib — analyze\n'));
  });

  test('passes args to the task context', () async {
    final (_, runner, _) = await run(graph([], 'test', targets: []), args: ['-x']);
    expect(runner.calls, isEmpty); // no package has tests
    write('packages/lone/test/a_test.dart', '');
    ws = Workspace.load(root);
    final (_, runner2, _) = await run(graph([], 'test', targets: [ws['lone']]), args: ['-x']);
    expect(runner2.calls.single.$2, ['test', '-x']);
  });

  test('a user task runs its Dart closure with a working context', () async {
    final seen = <String>[];
    final g = graph([
      Task('hello', run: (ctx) async {
        seen.add(ctx.package.name);
        ctx.log('hi from ${ctx.package.name}');
        await ctx.exec('echo', ['x']);
      }),
    ], 'hello', targets: [ws['lone']]);
    final (code, runner, out) = await run(g);
    expect(code, 0);
    expect(seen, ['lone']);
    // records compare fields with ==, and List == is identity: assert per field
    expect(runner.calls.single.$1, 'echo');
    expect(runner.calls.single.$2, ['x']);
    expect(runner.calls.single.$3, ws['lone'].path);
    expect(out, contains('rask: lone — hi from lone'));
  });

  test('exec with a workingDirectory runs there', () async {
    final g = graph([Task('t', run: (ctx) => ctx.exec('npm', ['ci'], workingDirectory: root.path))], 't',
        targets: [ws['lone']]);
    final (_, runner, _) = await run(g);
    expect(runner.calls.single.$3, root.path);
  });

  test('dependsOn order: codegen in lib and app before test in app', () async {
    write('packages/app/test/a_test.dart', '');
    ws = Workspace.load(root);
    final g = graph([
      Task('codegen', run: (ctx) => ctx.dart(['run', 'build_runner', 'build'])),
      Task('test', dependsOn: ['^codegen', 'codegen']),
    ], 'test', targets: [ws['app']]);
    final (_, runner, _) = await run(g);
    final calls = runner.calls.map((c) => '${c.$2.first}@${p.basename(c.$3)}').toList();
    expect(calls, hasLength(3));
    expect(calls.last, 'test@app');
    expect(calls.take(2), unorderedEquals(['run@lib', 'run@app']));
  });

  test('a ProcessFailure stops the run and returns the process exit code', () async {
    final (code, runner, out) = await run(graph([], 'analyze'), exitCodes: {'lib': 3});
    expect(code, 3);
    expect(dirs(runner), isNot(contains('app'))); // app depends on lib
    expect(out, contains('rask: lib — analyze failed (exit 3)'));
  });

  test('a process that cannot start is exit 70', () async {
    final (code, _, out) = await run(graph([], 'analyze', targets: [ws['lone']]), cannotStart: {'lone'});
    expect(code, 70);
    expect(out, contains('failed'));
  });

  test('any other exception from run is exit 1 with the message', () async {
    final g = graph([Task('boom', run: (_) async => throw StateError('kaboom'))], 'boom', targets: [ws['lone']]);
    final (code, _, out) = await run(g);
    expect(code, 1);
    expect(out, contains('kaboom'));
  });

  test('jobs > 1 captures output per package and prints it as a block', () async {
    final (code, runner, out) = await run(graph([], 'analyze', targets: [ws['lib'], ws['lone']]), jobs: 4);
    expect(code, 0);
    expect(runner.calls, hasLength(2));
    expect(out, contains('rask: lib — analyze\nout of lib\n'));
    expect(out, contains('rask: lone — analyze\nout of lone\n'));
  });

  test('jobs must be at least 1', () {
    expect(() => run(graph([], 'analyze'), jobs: 0), throwsArgumentError);
  });

  group('with a cache', () {
    test('a successful node is skipped the second time', () async {
      final c = cache();
      final g = graph([], 'analyze', targets: [ws['lone']]);
      final first = await run(g, c: c);
      expect(first.$2.calls, hasLength(1));
      final second = await run(g, c: c);
      expect(second.$2.calls, isEmpty);
      expect(second.$3, contains('rask: lone — analyze (cached, skip)'));
    });

    test('a failed node is not recorded', () async {
      final c = cache();
      final g = graph([], 'analyze', targets: [ws['lone']]);
      await run(g, c: c, exitCodes: {'lone': 1});
      final again = await run(g, c: c);
      expect(again.$2.calls, hasLength(1));
    });

    test('a change in a dependency package reruns the dependent', () async {
      final c = cache();
      final g = graph([], 'analyze', targets: [ws['lib'], ws['app']]);
      await run(g, c: c);
      write('packages/lib/lib/l.dart', '// changed');
      final again = await run(g, c: c);
      expect(dirs(again.$2), unorderedEquals(['lib', 'app']));
    });

    test('a change in a dependsOn node\'s inputs reruns the dependent node', () async {
      write('packages/lone/schema.dart', 'v1');
      final c = cache();
      final g = graph([
        Task('codegen', run: (ctx) => ctx.dart(['run', 'gen']), inputs: ['schema.dart'], outputs: ['lib/**.g.dart']),
        Task('check', run: (ctx) => ctx.dart(['analyze']), inputs: ['lib/**'], dependsOn: ['codegen']),
      ], 'check', targets: [ws['lone']]);
      await run(g, c: c);
      write('packages/lone/schema.dart', 'v2'); // not in check's inputs, but codegen's key changes
      final again = await run(g, c: c);
      expect(again.$2.calls.map((c) => c.$2.first), ['run', 'analyze']);
    });

    test('a hit whose outputs are missing is not a hit (D-031)', () async {
      final c = cache();
      final g = graph([
        Task('codegen', outputs: ['lib/**.g.dart'], run: (ctx) async {
          write('packages/lone/lib/x.g.dart', '// generated');
        }),
      ], 'codegen', targets: [ws['lone']]);
      await run(g, c: c);
      final hit = await run(g, c: c);
      expect(hit.$3, contains('cached, skip'));
      File(p.join(root.path, 'packages/lone/lib/x.g.dart')).deleteSync();
      final miss = await run(g, c: c);
      expect(miss.$3, isNot(contains('cached, skip')));
      expect(File(p.join(root.path, 'packages/lone/lib/x.g.dart')).existsSync(), isTrue);
    });

    test('a downstream node\'s key sees files an upstream node generated in the same run', () async {
      // codegen writes lib/x.g.dart; check has inputs lib/** so the generated
      // file is part of its key. With a stale memoized tree, run 2 would
      // recompute a different key and rerun check once more.
      final c = cache();
      var checks = 0;
      final g = graph([
        Task('codegen', outputs: ['lib/**.g.dart'], run: (ctx) async {
          write('packages/lone/lib/x.g.dart', '// generated');
        }),
        Task('check', inputs: ['lib/**'], dependsOn: ['codegen'], run: (ctx) async {
          checks++;
        }),
      ], 'check', targets: [ws['lone']]);
      await run(g, c: c);
      expect(checks, 1);
      await run(g, c: cache()); // fresh instance, fresh trees: must be a hit
      expect(checks, 1);
    });

    test('a node\'s own outputs do not invalidate it (stable key)', () async {
      final c = cache();
      var runs = 0;
      final g = graph([
        Task('codegen', outputs: ['lib/**.g.dart'], run: (ctx) async {
          runs++;
          write('packages/lone/lib/x.g.dart', '// generated $runs');
        }),
      ], 'codegen', targets: [ws['lone']]);
      await run(g, c: c);
      await run(g, c: c);
      expect(runs, 1);
    });
  });
}
