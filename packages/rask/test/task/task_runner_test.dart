import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/plugin/resolve_targets.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/task/task_runner.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:rask/testing.dart';
import 'package:test/test.dart';

class _StubPlugin implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => null;
}

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
    write(
      'packages/app/pubspec.yaml',
      'name: app\ndependencies:\n  lib: any\n',
    );
    write('packages/app/lib/a.dart', '');
    write('packages/lib/pubspec.yaml', 'name: lib\n');
    write('packages/lib/lib/l.dart', '');
    write('packages/lone/pubspec.yaml', 'name: lone\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  TaskGraph graph(List<Task> tasks, String task, {List<Package>? targets}) =>
      buildTaskGraph(
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

  Future<(int, RecordingRunner, String)> run(
    TaskGraph g, {
    Map<String, int> exitCodes = const {},
    Set<String> cannotStart = const {},
    TaskCache? c,
    int jobs = 1,
    List<String> args = const [],
  }) async {
    final runner = RecordingRunner(
      exitCodes: exitCodes,
      cannotStart: cannotStart,
    );
    final out = StringBuffer();
    final code = await runTaskGraph(
      g,
      workspace: ws,
      runner: runner,
      out: out,
      cache: c,
      jobs: jobs,
      args: args,
    );
    return (code, runner, out.toString());
  }

  List<String> dirs(RecordingRunner r) =>
      r.calls.map((c) => p.basename(c.$3)).toList();

  test('runs the builtin analyze in every package via ctx.dart, dependencies first', () async {
    final (code, runner, out) = await run(graph([], 'analyze'));
    expect(code, 0);
    expect(dirs(runner), unorderedEquals(['app', 'lib', 'lone']));
    expect(dirs(runner).indexOf('lib'), lessThan(dirs(runner).indexOf('app')));
    // List == is identity: compare the single element, not the list
    expect(
      runner.calls.every((c) => c.$1 == 'dart' && c.$2.single == 'analyze'),
      isTrue,
    );
    expect(out, contains('rask: lib — analyze\n'));
  });

  test('passes args to the task context', () async {
    final (_, runner, _) = await run(
      graph([], 'test', targets: []),
      args: ['-x'],
    );
    expect(runner.calls, isEmpty); // no package has tests
    write('packages/lone/test/a_test.dart', '');
    ws = Workspace.load(root);
    final (_, runner2, _) = await run(
      graph([], 'test', targets: [ws['lone']]),
      args: ['-x'],
    );
    expect(runner2.calls.single.$2, ['test', '-x']);
  });

  test('a user task runs its Dart closure with a working context', () async {
    final seen = <String>[];
    final g = graph(
      [
        Task(
          'hello',
          run: (ctx) async {
            seen.add(ctx.package.name);
            ctx.log('hi from ${ctx.package.name}');
            await ctx.exec('echo', ['x']);
          },
        ),
      ],
      'hello',
      targets: [ws['lone']],
    );
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
    final g = graph(
      [
        Task(
          't',
          run: (ctx) => ctx.exec('npm', ['ci'], workingDirectory: root.path),
        ),
      ],
      't',
      targets: [ws['lone']],
    );
    final (_, runner, _) = await run(g);
    expect(runner.calls.single.$3, root.path);
  });

  test('dependsOn order: codegen in lib and app before test in app', () async {
    write('packages/app/test/a_test.dart', '');
    ws = Workspace.load(root);
    final g = graph(
      [
        Task(
          'codegen',
          run: (ctx) => ctx.dart(['run', 'build_runner', 'build']),
        ),
        Task('test', dependsOn: ['^codegen', 'codegen']),
      ],
      'test',
      targets: [ws['app']],
    );
    final (_, runner, _) = await run(g);
    final calls = runner.calls
        .map((c) => '${c.$2.first}@${p.basename(c.$3)}')
        .toList();
    expect(calls, hasLength(3));
    expect(calls.last, 'test@app');
    expect(calls.take(2), unorderedEquals(['run@lib', 'run@app']));
  });

  test('a task that both generates and reads generated code (dependsOn '
      "['^codegen']) runs lib's node before app's", () async {
    // Unlike the transitive tests above (which use a different task,
    // analyze, always landing in its own stage), this is the same task
    // in both roles: app both generates its own package and, via
    // dependsOn: ['^codegen'], reads what lib's codegen produced. Without
    // that self-referential dependsOn, lib and app would land in the
    // same stage and app's key could be taken against lib's generated
    // tree mid-rewrite.
    final order = <String>[];
    final g = graph(
      [
        Task(
          'codegen',
          generates: (pkg) => '${pkg.name}_gen',
          dependsOn: ['^codegen'],
          run: (ctx) async => order.add(ctx.package.name),
        ),
      ],
      'codegen',
      targets: [ws['app'], ws['lib']],
    );
    final (code, _, _) = await run(g);
    expect(code, 0);
    expect(order.indexOf('lib'), lessThan(order.indexOf('app')));
  });

  test(
    'a ProcessFailure stops the run and returns the process exit code',
    () async {
      final (code, runner, out) = await run(
        graph([], 'analyze'),
        exitCodes: {'lib': 3},
      );
      expect(code, 3);
      expect(dirs(runner), isNot(contains('app'))); // app depends on lib
      expect(out, contains('rask: lib — analyze failed (exit 3)'));
    },
  );

  test('a process that cannot start is exit 70', () async {
    final (code, _, out) = await run(
      graph([], 'analyze', targets: [ws['lone']]),
      cannotStart: {'lone'},
    );
    expect(code, 70);
    expect(out, contains('failed'));
    expect(out, contains('not found')); // the ProcessException's own text (F2)
  });

  test('any other exception from run is exit 1 with the message', () async {
    final g = graph(
      [Task('boom', run: (_) async => throw StateError('kaboom'))],
      'boom',
      targets: [ws['lone']],
    );
    final (code, _, out) = await run(g);
    expect(code, 1);
    expect(out, contains('kaboom'));
  });

  test('an Error from run also gets its stack trace written after the failed line (F3)', () async {
    final g = graph(
      [Task('boom', run: (_) async => throw StateError('kaboom'))],
      'boom',
      targets: [ws['lone']],
    );
    final (code, _, out) = await run(g);
    expect(code, 1);
    expect(out, contains('kaboom'));
    // the stack trace of the throw above, in this very file
    expect(out, contains('task_runner_test.dart'));
  });

  test(
    'jobs > 1 captures output per package and prints it as a block',
    () async {
      final (code, runner, out) = await run(
        graph([], 'analyze', targets: [ws['lib'], ws['lone']]),
        jobs: 4,
      );
      expect(code, 0);
      expect(runner.calls, hasLength(2));
      expect(out, contains('rask: lib — analyze\nout of lib\n'));
      expect(out, contains('rask: lone — analyze\nout of lone\n'));
    },
  );

  test('jobs must be at least 1', () {
    expect(() => run(graph([], 'analyze'), jobs: 0), throwsArgumentError);
  });

  group('concurrency and fail-fast (F2, ported from 218f12b:test/run/dart_verb_test.dart)', () {
    // app -> lib ; lone and extra are independent.
    // The builtin `analyze` has no dependsOn of its own, so its nodes would
    // all land in a single stage regardless of package dependencies. Merge
    // in dependsOn: ['^analyze'] (same pattern as the transitive-dependency
    // tests above) so app@analyze genuinely waits on lib@analyze's stage:
    // stage 0: [lib, lone, extra] (3 independent nodes) ; stage 1: [app]
    setUp(() {
      write('packages/extra/pubspec.yaml', 'name: extra\n');
      ws = Workspace.load(root);
    });

    TaskGraph analyzeGraph({List<Package>? targets}) => graph(
      [
        Task('analyze', dependsOn: ['^analyze']),
      ],
      'analyze',
      targets: targets,
    );

    test('a stage runs at most --jobs packages at once', () async {
      final runner = GatedRunner();
      final done = runTaskGraph(
        analyzeGraph(),
        workspace: ws,
        runner: runner,
        out: StringBuffer(),
        jobs: 2,
      );
      await pumpEventQueue();
      expect(runner.events.where((e) => e.startsWith('start')), hasLength(2));
      expect(runner.events, isNot(contains('start app'))); // depends on lib
      for (final pkg in ['lib', 'lone', 'extra']) {
        runner.gate(pkg).complete(0);
      }
      await pumpEventQueue(); // stage 1 (app) starts once stage 0 is done
      runner.gate('app').complete(0);
      expect(await done, 0);
    });

    test('a dependent waits for the whole stage', () async {
      final runner = GatedRunner();
      final done = runTaskGraph(
        analyzeGraph(),
        workspace: ws,
        runner: runner,
        out: StringBuffer(),
        jobs: 4,
      );
      await pumpEventQueue();
      expect(
        runner.events,
        unorderedEquals(['start lib', 'start lone', 'start extra']),
      );
      runner.gate('lib').complete(0);
      await pumpEventQueue();
      expect(
        runner.events,
        isNot(contains('start app')),
      ); // lone/extra still running
      runner.gate('lone').complete(0);
      runner.gate('extra').complete(0);
      await pumpEventQueue();
      expect(runner.events, contains('start app'));
      runner.gate('app').complete(0);
      expect(await done, 0);
    });

    test('after a failure nothing new starts, running nodes finish, '
        "and the first failure's exit code is returned", () async {
      final runner = GatedRunner();
      final out = StringBuffer();
      final done = runTaskGraph(
        analyzeGraph(),
        workspace: ws,
        runner: runner,
        out: out,
        jobs: 2,
      );
      await pumpEventQueue();
      final started = runner.events
          .map((e) => e.substring('start '.length))
          .toList();
      expect(started, hasLength(2));
      final (first, second) = (started[0], started[1]);
      final third = [
        'lib',
        'lone',
        'extra',
      ].where((x) => x != first && x != second).single;

      runner.gate(first).complete(7);
      await pumpEventQueue();
      expect(runner.events, isNot(contains('start $third')));
      expect(runner.events, isNot(contains('start app')));

      runner.gate(second).complete(0);
      expect(await done, 7);
      expect(runner.events, contains('end $second'));
      expect(out.toString(), contains('output of $second'));
      expect(out.toString(), contains('$first — analyze failed (exit 7)'));
    });

    test('a success that finishes after another node failed is still recorded in the cache', () async {
      final runner = GatedRunner();
      final c = cache();
      final done = runTaskGraph(
        analyzeGraph(targets: [ws['lone'], ws['extra']]),
        workspace: ws,
        runner: runner,
        out: StringBuffer(),
        jobs: 2,
        cache: c,
      );
      await pumpEventQueue();
      runner.gate('lone').complete(1);
      runner.gate('extra').complete(0);
      expect(await done, 1);

      final again = await run(
        graph([], 'analyze', targets: [ws['lone'], ws['extra']]),
        c: c,
      );
      expect(dirs(again.$2), [
        'lone',
      ]); // extra's success was recorded; lone (failed) reruns
      expect(again.$3, contains('rask: extra — analyze (cached, skip)'));
    });

    test('an exception from the runner (process cannot start) is reported with its text, exit 70', () async {
      final runner = ThrowingRunner(throwFor: 'lone');
      final out = StringBuffer();
      final code = await runTaskGraph(
        analyzeGraph(targets: [ws['lone']]),
        workspace: ws,
        runner: runner,
        out: out,
        jobs: 1,
      );
      expect(code, 70);
      expect(runner.started, ['lone']);
      expect(out.toString(), contains('lone — analyze failed ('));
      expect(out.toString(), contains('dart not found'));
    });
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

    test(
      'a change in a dependsOn node\'s inputs reruns the dependent node',
      () async {
        write('packages/lone/schema.dart', 'v1');
        final c = cache();
        final g = graph(
          [
            Task(
              'codegen',
              run: (ctx) => ctx.dart(['run', 'gen']),
              inputs: ['schema.dart'],
              outputs: ['lib/**.g.dart'],
            ),
            Task(
              'check',
              run: (ctx) => ctx.dart(['analyze']),
              inputs: ['lib/**'],
              dependsOn: ['codegen'],
            ),
          ],
          'check',
          targets: [ws['lone']],
        );
        await run(g, c: c);
        write(
          'packages/lone/schema.dart',
          'v2',
        ); // not in check's inputs, but codegen's key changes
        final again = await run(g, c: c);
        expect(again.$2.calls.map((c) => c.$2.first), ['run', 'analyze']);
      },
    );

    test('a hit whose outputs are missing is not a hit', () async {
      final c = cache();
      final g = graph(
        [
          Task(
            'codegen',
            outputs: ['lib/**.g.dart'],
            run: (ctx) async {
              write('packages/lone/lib/x.g.dart', '// generated');
            },
          ),
        ],
        'codegen',
        targets: [ws['lone']],
      );
      await run(g, c: c);
      final hit = await run(g, c: c);
      expect(hit.$3, contains('cached, skip'));
      File(p.join(root.path, 'packages/lone/lib/x.g.dart')).deleteSync();
      final miss = await run(g, c: c);
      expect(miss.$3, isNot(contains('cached, skip')));
      expect(
        File(p.join(root.path, 'packages/lone/lib/x.g.dart')).existsSync(),
        isTrue,
      );
    });

    test('a downstream node\'s key sees files an upstream node generated in the same run', () async {
      // codegen writes lib/x.g.dart; check has inputs lib/** so the generated
      // file is part of its key. With a stale memoized tree, run 2 would
      // recompute a different key and rerun check once more.
      final c = cache();
      var checks = 0;
      final g = graph(
        [
          Task(
            'codegen',
            outputs: ['lib/**.g.dart'],
            run: (ctx) async {
              write('packages/lone/lib/x.g.dart', '// generated');
            },
          ),
          Task(
            'check',
            inputs: ['lib/**'],
            dependsOn: ['codegen'],
            run: (ctx) async {
              checks++;
            },
          ),
        ],
        'check',
        targets: [ws['lone']],
      );
      await run(g, c: c);
      expect(checks, 1);
      await run(g, c: cache()); // fresh instance, fresh trees: must be a hit
      expect(checks, 1);
    });

    test('deleting a build/ output makes a cached node run again', () async {
      final c = cache();
      var runs = 0;
      final g = graph(
        [
          Task(
            'build',
            outputs: ['build/**'],
            run: (ctx) async {
              runs++;
              write('packages/lone/build/out.txt', 'built $runs');
            },
          ),
        ],
        'build',
        targets: [ws['lone']],
      );
      await run(g, c: c);
      expect(runs, 1);
      final hit = await run(g, c: c);
      expect(hit.$3, contains('cached, skip'));
      expect(runs, 1);

      Directory(p.join(root.path, 'packages/lone/build'))
          .deleteSync(recursive: true);
      final miss = await run(g, c: c);
      expect(miss.$3, isNot(contains('cached, skip')));
      expect(runs, 2);
      expect(
        File(p.join(root.path, 'packages/lone/build/out.txt')).existsSync(),
        isTrue,
      );
    });

    test('a node\'s own outputs do not invalidate it (stable key)', () async {
      final c = cache();
      var runs = 0;
      final g = graph(
        [
          Task(
            'codegen',
            outputs: ['lib/**.g.dart'],
            run: (ctx) async {
              runs++;
              write('packages/lone/lib/x.g.dart', '// generated $runs');
            },
          ),
        ],
        'codegen',
        targets: [ws['lone']],
      );
      await run(g, c: c);
      await run(g, c: c);
      expect(runs, 1);
    });
  });

  group('build task per-package cache declarations (targets)', () {
    late List<String> built;

    Map<String, ResolvedTarget> targetsWith({
      required List<String> serverOutputs,
      required List<String> webOutputs,
    }) => {
      'server': ResolvedTarget(
        package: ws['server'],
        plugin: _StubPlugin(),
        target: Target(
          'server',
          command: (ctx) => Command('dart', const ['run']),
          build: (ctx) async {
            built.add('server');
            write('packages/server/out/server/built.txt', 'built');
          },
          buildOutputs: serverOutputs,
        ),
      ),
      'web': ResolvedTarget(
        package: ws['web'],
        plugin: _StubPlugin(),
        target: Target(
          'web',
          command: (ctx) => Command('dart', const ['run']),
          build: (ctx) async {
            built.add('web');
            write('packages/web/out/web/built.txt', 'built');
          },
          buildOutputs: webOutputs,
        ),
      ),
    };

    setUp(() {
      built = [];
      write('packages/server/pubspec.yaml', 'name: server\n');
      write('packages/web/pubspec.yaml', 'name: web\n');
      ws = Workspace.load(root);
    });

    TaskGraph buildGraph(Map<String, ResolvedTarget> targets) => buildTaskGraph(
      config: resolveConfig(defineConfig(), targets: targets),
      task: 'build',
      targets: [ws['server'], ws['web']],
      workspace: ws,
    );

    test("each package's own build output is verified on a hit, independently "
        "of the other target's outputs (no union)", () async {
      final targets = targetsWith(
        serverOutputs: ['out/server/**'],
        webOutputs: ['out/web/**'],
      );
      final c = cache();
      final g = buildGraph(targets);
      await run(g, c: c);
      expect(built, unorderedEquals(['server', 'web']));

      built.clear();
      final hit = await run(g, c: c);
      expect(built, isEmpty); // both cached
      expect(hit.$3, contains('server — build (cached, skip)'));
      expect(hit.$3, contains('web — build (cached, skip)'));

      // Deleting only server's own output invalidates only server: web's
      // hit does not depend on server's globs, unlike the unioned outputs
      // a merged task would have carried.
      File(p.join(root.path, 'packages/server/out/server/built.txt'))
          .deleteSync();
      built.clear();
      await run(g, c: c);
      expect(built, ['server']);
    });

    test("a file matching another target's output glob still counts toward "
        "this package's own cache key", () async {
      final targets = targetsWith(
        serverOutputs: ['out/server/**'],
        webOutputs: ['out/web/**'],
      );
      // Not a build artifact of server's own target — just a file that
      // happens to live under the path web's target declares as its
      // output. A merged/unioned outputs list would exclude it from
      // server's own key (a wrong skip); server's own outputsFor is only
      // 'out/server/**', so it must not.
      write('packages/server/out/web/leftover.txt', 'v1');
      final c = cache();
      final g = buildGraph(targets);
      await run(g, c: c);

      built.clear();
      write('packages/server/out/web/leftover.txt', 'v2');
      await run(g, c: c);
      expect(built, contains('server'));
    });
  });

  group('generated packages', () {
    GeneratedPackage genFor(String pkg, String name) => GeneratedPackage(
      name: name,
      producer: ws[pkg],
      taskName: 'codegen',
      dir: p.join(root.path, '.dart_tool', 'rask', 'gen', name),
    );

    test(
      'ctx.gen is the generated lib directory, emptied before the run',
      () async {
        final gen = genFor('app', 'app_gen');
        final stale = File(p.join(gen.libDir, 'stale.dart'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('int stale = 1;');

        String? seen;
        final task = Task(
          'codegen',
          where: (pkg) => pkg.name == 'app',
          generates: (pkg) => 'app_gen',
          run: (ctx) async {
            seen = ctx.gen;
            File(p.join(ctx.gen!, 'fresh.dart'))
                .writeAsStringSync('int fresh = 1;');
          },
        );
        final code = await runTaskGraph(
          graph([task], 'codegen'),
          workspace: ws,
          runner: RecordingRunner(),
          out: StringBuffer(),
          generated: [gen],
        );
        expect(code, 0);
        expect(seen, gen.libDir);
        expect(stale.existsSync(), isFalse);
        expect(File(p.join(gen.libDir, 'fresh.dart')).existsSync(), isTrue);
      },
    );

    test('ctx.gen is null for a task that generates nothing', () async {
      String? seen = 'not null';
      final task = Task(
        'plain',
        where: (pkg) => pkg.name == 'app',
        run: (ctx) async => seen = ctx.gen,
      );
      await runTaskGraph(
        graph([task], 'plain'),
        workspace: ws,
        runner: RecordingRunner(),
        out: StringBuffer(),
      );
      expect(seen, isNull);
    });

    test('a cache hit leaves the generated directory alone', () async {
      final gen = genFor('app', 'app_gen');
      var runs = 0;
      final task = Task(
        'codegen',
        where: (pkg) => pkg.name == 'app',
        generates: (pkg) => 'app_gen',
        run: (ctx) async {
          runs++;
          File(p.join(ctx.gen!, 'out.dart'))
              .writeAsStringSync('int out = $runs;');
        },
      );
      for (var i = 0; i < 2; i++) {
        await runTaskGraph(
          graph([task], 'codegen'),
          workspace: ws,
          runner: RecordingRunner(),
          out: StringBuffer(),
          // A fresh TaskCache each round: one instance memoizes package trees.
          cache: cache(),
          generated: [gen],
        );
      }
      expect(runs, 1);
      expect(
        File(p.join(gen.libDir, 'out.dart')).readAsStringSync(),
        'int out = 1;',
      );
    });

    test(
      'the dependents of a generating package see its output in their key',
      () async {
        final gen = genFor('lib', 'lib_gen');
        Directory(gen.libDir).createSync(recursive: true);
        File(p.join(gen.libDir, 'g.dart')).writeAsStringSync('int g = 1;');
        final task = Task(
          'codegen',
          where: (pkg) => pkg.name == 'lib',
          generates: (pkg) => 'lib_gen',
          run: (ctx) async {},
        );

        Future<String> analyzeRun() async {
          final runner = RecordingRunner();
          await runTaskGraph(
            graph([task], 'analyze'),
            workspace: ws,
            runner: runner,
            out: StringBuffer(),
            cache: cache(),
            generated: [gen],
          );
          return runner.calls.map((c) => p.basename(c.$3)).join(',');
        }

        // First run populates the cache; the second is fully cached.
        expect(await analyzeRun(), isNotEmpty);
        expect(await analyzeRun(), isEmpty);
        // Regenerating lib_gen must make app's analyze run again.
        File(p.join(gen.libDir, 'g.dart')).writeAsStringSync('int g = 2;');
        expect(await analyzeRun(), contains('app'));
      },
    );
  });
}
