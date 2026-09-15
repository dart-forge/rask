import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/plugin/resolve_targets.dart';
import 'package:rask/src/task/builtin_tasks.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/workspace/topological_order.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

class _Stub implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => null;
}

class _Ctx implements TargetContext {
  _Ctx(this.package);
  @override
  final Package package;
  @override
  List<String> get args => const [];
  @override
  int? get port => null;
  @override
  String? get gen => null;
  @override
  Workspace get workspace => throw UnimplementedError();
  @override
  Future<void> dart(List<String> args) => throw UnimplementedError();
  @override
  Future<void> exec(String e, List<String> a, {String? workingDirectory}) =>
      throw UnimplementedError();
  @override
  void log(String message) {}
}

void main() {
  group('resolveConfig', () {
    Future<void> noop(TaskContext _) async {}

    test(
      'with no user tasks the resolved tasks are the builtins, in order',
      () {
        final r = resolveConfig(defineConfig());
        expect(r.tasks.keys, ['test', 'analyze']);
        expect(r['test'].run, same(builtinTasks[0].run));
      },
    );

    test('user tasks are appended after the builtins', () {
      final r = resolveConfig(
        defineConfig(tasks: [Task('codegen', run: noop)]),
      );
      expect(r.tasks.keys, ['test', 'analyze', 'codegen']);
    });

    test('a user task with a builtin name merges: given fields replace, others stay', () {
      final r = resolveConfig(
        defineConfig(
          tasks: [
            Task('test', dependsOn: ['^codegen'], outputs: ['coverage/**']),
            Task('codegen', run: noop),
          ],
        ),
      );
      final t = r['test'];
      expect(t.dependsOn, ['^codegen']);
      expect(t.outputs, ['coverage/**']);
      expect(t.run, same(builtinTasks[0].run)); // kept
      expect(t.where, same(builtinTasks[0].where)); // kept
      expect(t.description, builtinTasks[0].description); // kept
    });

    test('a user task with a builtin name may replace run and where', () {
      bool everywhere(_) => true;
      final r = resolveConfig(
        defineConfig(
          tasks: [Task('test', run: noop, where: everywhere)],
        ),
      );
      expect(r['test'].run, same(noop));
      expect(r['test'].where, same(everywhere));
    });

    test('rejects two user tasks with the same name', () {
      expect(
        () => resolveConfig(
          defineConfig(
            tasks: [
              Task('a', run: noop),
              Task('a', run: noop),
            ],
          ),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('"a"'),
          ),
        ),
      );
    });

    test('rejects a task named like a command', () {
      // 'dev' is a command whether or not any plugin provides a target, so
      // a task named 'dev' must be rejected the same clean way 'pub' is —
      // the crash this guards against is a duplicate-command ArgumentError
      // from args' CommandRunner, escaping every catch.
      for (final name in ['pub', 'bump', 'publish', 'help', 'dev']) {
        expect(
          () => resolveConfig(defineConfig(tasks: [Task(name, run: noop)])),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              contains(name),
            ),
          ),
        );
      }
    });

    test('rejects a non-builtin task without run', () {
      expect(
        () => resolveConfig(defineConfig(tasks: [Task('codegen')])),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('run'),
          ),
        ),
      );
    });

    test('rejects dependsOn on an unknown task, naming both', () {
      expect(
        () => resolveConfig(
          defineConfig(
            tasks: [
              Task('a', run: noop, dependsOn: ['^nope']),
            ],
          ),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('nope'), contains('"a"')),
          ),
        ),
      );
    });

    test('rejects malformed dependsOn entries', () {
      for (final bad in ['', '^', '^^test']) {
        expect(
          () => resolveConfig(
            defineConfig(
              tasks: [
                Task('a', run: noop, dependsOn: [bad]),
              ],
            ),
          ),
          throwsA(isA<ConfigError>()),
          reason: 'entry: "$bad"',
        );
      }
    });

    test('rejects an empty inputs list (F4)', () {
      expect(
        () => resolveConfig(
          defineConfig(
            tasks: [Task('a', run: noop, inputs: const [])],
          ),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('inputs must be null (everything) or a non-empty list'),
          ),
        ),
      );
    });

    test('rejects an inputs entry under .dart_tool/, build/ or .git/ (F1)', () {
      for (final dir in ['.dart_tool', 'build', '.git']) {
        expect(
          () => resolveConfig(
            defineConfig(
              tasks: [
                Task('a', run: noop, inputs: ['$dir/**']),
              ],
            ),
          ),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              contains(dir),
            ),
          ),
          reason: 'dir: "$dir"',
        );
      }
    });

    test(
      'outputs under build/ or .dart_tool/ are fine (F1 is about inputs only)',
      () {
        expect(
          () => resolveConfig(
            defineConfig(
              tasks: [
                Task('a', run: noop, outputs: ['build/**', '.dart_tool/**']),
              ],
            ),
          ),
          returnsNormally,
        );
      },
    );

    test('dependsOn may reference builtins and later-defined user tasks', () {
      final r = resolveConfig(
        defineConfig(
          tasks: [
            Task('a', run: noop, dependsOn: ['b', '^test']),
            Task('b', run: noop),
          ],
        ),
      );
      expect(r['a'].dependsOn, ['b', '^test']);
    });
  });

  group('buildTaskGraph', () {
    late Directory root;
    late Workspace ws;
    Future<void> noop(TaskContext _) async {}

    setUp(() {
      root = Directory.systemTemp.createTempSync('rask_graph_');
      void put(String rel, String yaml) {
        final d = Directory(p.join(root.path, rel))
          ..createSync(recursive: true);
        File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
      }

      // app -> lib_a -> core ; app -> lib_b ; lone
      put('.', 'name: _\nworkspace:\n  - packages/*\n');
      put(
        'packages/app',
        'name: app\ndependencies:\n  lib_a: any\n  lib_b: any\n',
      );
      put(
        'packages/lib_a',
        'name: lib_a\ndependencies:\n  core: any\n  build_runner: any\n',
      );
      put('packages/lib_b', 'name: lib_b\n');
      put('packages/core', 'name: core\ndependencies:\n  build_runner: any\n');
      put('packages/lone', 'name: lone\n');
      ws = Workspace.load(root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    ResolvedConfig config(List<Task> tasks) =>
        resolveConfig(defineConfig(tasks: tasks));
    List<String> ids(Iterable<TaskNode> nodes) =>
        nodes.map((n) => n.id).toList();

    // A task literally named 'test' merges with the built-in `test` task
    // (Task 3's resolveConfig), whose `where` is `hasTests` unless the user
    // task overrides it. Give a package a real test file so that merged
    // `where` holds for it, as the tests below that reuse the name 'test'
    // (to mirror the real built-in) require.
    void addTestFile(String rel) {
      final dir = Directory(p.join(root.path, rel, 'test'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'smoke_test.dart')).writeAsStringSync('');
    }

    test('one node per target package the task applies to; where filters', () {
      final g = buildTaskGraph(
        config: config([
          Task(
            'codegen',
            run: noop,
            where: (pkg) => pkg.dependsOn('build_runner'),
          ),
        ]),
        task: 'codegen',
        targets: ws.inOrder,
        workspace: ws,
      );
      expect(ids(g.nodes), unorderedEquals(['codegen@lib_a', 'codegen@core']));
    });

    test(
      'same-package dependsOn adds an edge and the node, even outside targets',
      () {
        final g = buildTaskGraph(
          config: config([
            Task('codegen', run: noop),
            Task('build', run: noop, dependsOn: ['codegen']),
          ]),
          task: 'build',
          targets: [ws['lone']],
          workspace: ws,
        );
        expect(ids(g.nodes), ['codegen@lone', 'build@lone']);
        expect(ids(g.dependenciesOf(g.nodes.last)), ['codegen@lone']);
      },
    );

    test('^task depends on the task in transitive workspace dependencies', () {
      addTestFile('packages/app');
      final g = buildTaskGraph(
        config: config([
          Task(
            'codegen',
            run: noop,
            where: (pkg) => pkg.dependsOn('build_runner'),
          ),
          Task('test', dependsOn: ['^codegen']),
        ]),
        task: 'test',
        targets: [ws['app']],
        workspace: ws,
      );
      final testApp = g.nodes.singleWhere((n) => n.id == 'test@app');
      // lib_b has no codegen (where false) -> no node, no edge; core is transitive
      expect(
        ids(g.dependenciesOf(testApp)),
        unorderedEquals(['codegen@lib_a', 'codegen@core']),
      );
      expect(ids(g.nodes), isNot(contains('codegen@lib_b')));
    });

    test('nodes are in dependency order and stages respect edges', () {
      addTestFile('packages/app');
      addTestFile('packages/lone');
      final g = buildTaskGraph(
        config: config([
          Task('codegen', run: noop, dependsOn: ['^codegen']),
          Task('test', dependsOn: ['^codegen', 'codegen']),
        ]),
        task: 'test',
        targets: ws.inOrder,
        workspace: ws,
      );
      final order = ids(g.nodes);
      expect(
        order.indexOf('codegen@core'),
        lessThan(order.indexOf('codegen@lib_a')),
      );
      expect(
        order.indexOf('codegen@lib_a'),
        lessThan(order.indexOf('test@app')),
      );
      final stageOf = <String, int>{};
      for (var i = 0; i < g.stages.length; i++) {
        for (final n in g.stages[i]) {
          stageOf[n.id] = i;
        }
      }
      expect(stageOf['codegen@core'], lessThan(stageOf['codegen@lib_a']!));
      expect(stageOf['codegen@lib_a'], lessThan(stageOf['test@app']!));
      expect(stageOf['codegen@lone'], 0);
      expect(g.stages.expand((s) => s).length, g.nodes.length);
    });

    test('a task with no dependsOn yields one stage', () {
      final g = buildTaskGraph(
        config: config([]),
        task: 'analyze',
        targets: ws.inOrder,
        workspace: ws,
      );
      expect(g.stages, hasLength(1));
      expect(g.stages.single, hasLength(5));
    });

    test('a dependsOn cycle throws CyclicDependencyException', () {
      expect(
        () => buildTaskGraph(
          config: config([
            Task('a', run: noop, dependsOn: ['b']),
            Task('b', run: noop, dependsOn: ['a']),
          ]),
          task: 'a',
          targets: [ws['lone']],
          workspace: ws,
        ),
        throwsA(isA<CyclicDependencyException>()),
      );
    });

    test('TaskNode identity is task@package', () {
      final n = TaskNode(config([])['analyze'], ws['lone']);
      expect(n.id, 'analyze@lone');
      expect(n, TaskNode(config([])['analyze'], ws['lone']));
      expect(n.hashCode, TaskNode(config([])['analyze'], ws['lone']).hashCode);
    });
  });

  group('build from targets', () {
    Package pkg(String name) => Package(
      name: name,
      path: '/ws/packages/$name',
      dependencies: const [],
      pubspec: loadYaml('name: $name') as YamlMap,
    );

    Map<String, ResolvedTarget> targetsFor(
      String name, {
      List<String> dependsOn = const [],
      List<String>? inputs,
      List<String> outputs = const [],
      Future<void> Function(TargetContext)? build,
    }) {
      final package = pkg(name);
      return {
        name: ResolvedTarget(
          package: package,
          plugin: _Stub(),
          target: Target(
            'server',
            command: (ctx) => Command('dart', const ['run']),
            build: build ?? (ctx) async {},
            dependsOn: dependsOn,
            buildInputs: inputs,
            buildOutputs: outputs,
          ),
        ),
      };
    }

    test('no targets means no build task', () {
      expect(resolveConfig(defineConfig()).tasks.containsKey('build'), isFalse);
    });

    test('a target contributes a build task', () {
      final resolved = resolveConfig(
        defineConfig(),
        targets: targetsFor('app'),
      );
      final build = resolved['build'];
      expect(build.run, isNotNull);
      expect(build.where!(pkg('app')), isTrue);
      expect(build.where!(pkg('lib')), isFalse);
    });

    test("the build task carries the target's cache declarations", () {
      final resolved = resolveConfig(
        defineConfig(tasks: [Task('codegen', run: (ctx) async {})]),
        targets: targetsFor(
          'app',
          dependsOn: ['codegen'],
          inputs: ['lib/**'],
          outputs: ['build/**'],
        ),
      );
      expect(resolved['build'].dependsOn, ['codegen']);
      // Per-package form, not the static one: see the next test for why.
      expect(resolved['build'].inputsFor!(pkg('app')), ['lib/**']);
      expect(resolved['build'].outputsFor!(pkg('app')), ['build/**']);
      expect(resolved['build'].inputs, isNull);
      expect(resolved['build'].outputs, isEmpty);
    });

    test("each package's target contributes only its own inputsFor/outputsFor "
        '— never unioned with another target\'s', () {
      final resolved = resolveConfig(
        defineConfig(),
        targets: {
          ...targetsFor('server', outputs: ['out/server/**']),
          ...targetsFor('web', outputs: ['out/web/**']),
        },
      );
      final build = resolved['build'];
      expect(build.outputsFor!(pkg('server')), ['out/server/**']);
      expect(build.outputsFor!(pkg('web')), ['out/web/**']);
      // Neither package's globs leak into the other's.
      expect(build.outputsFor!(pkg('server')), isNot(contains('out/web/**')));
      expect(build.outputsFor!(pkg('web')), isNot(contains('out/server/**')));
    });

    test("dependsOn stays unioned across targets: a package's build node still "
        "gets a prerequisite another target declared", () {
      final resolved = resolveConfig(
        defineConfig(tasks: [Task('codegen', run: (ctx) async {})]),
        targets: {
          ...targetsFor('server', dependsOn: ['codegen']),
          ...targetsFor('web'),
        },
      );
      expect(resolved['build'].dependsOn, ['codegen']);
    });

    test(
      "a target depending on a task rask.dart never defines is a ConfigError",
      () {
        expect(
          () => resolveConfig(
            defineConfig(),
            targets: targetsFor('app', dependsOn: ['codegen']),
          ),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              contains('codegen'),
            ),
          ),
        );
      },
    );

    test('the build task calls the target of the package it runs in', () async {
      var calls = <String>[];
      final resolved = resolveConfig(
        defineConfig(),
        targets: {...targetsFor('app', build: (ctx) async => calls.add('app'))},
      );
      // The synthesized run looks the package up in the resolved targets.
      await resolved['build'].run!(_Ctx(pkg('app')));
      expect(calls, ['app']);
    });

    test('a user task named build wins', () {
      final resolved = resolveConfig(
        defineConfig(
          tasks: [Task('build', run: (ctx) async {}, description: 'mine')],
        ),
        targets: targetsFor('app'),
      );
      expect(resolved['build'].description, 'mine');
      expect(resolved['build'].where, isNull);
    });

    test(
      "a target's dependsOn is still validated when the user declares their "
      'own build task (there is no synthesized build task to carry the check)',
      () {
        expect(
          () => resolveConfig(
            defineConfig(
              tasks: [Task('build', run: (ctx) async {}, description: 'mine')],
            ),
            targets: targetsFor('app', dependsOn: ['codegen']),
          ),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              contains('codegen'),
            ),
          ),
        );
      },
    );

    test('a target with an empty buildInputs is a ConfigError naming the '
        "target's package", () {
      expect(
        () => resolveConfig(
          defineConfig(),
          targets: targetsFor('app', inputs: []),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('app'), contains('buildInputs')),
          ),
        ),
      );
    });

    test(
      "a target's buildOutputs naming an ignored directory is a ConfigError",
      () {
        expect(
          () => resolveConfig(
            defineConfig(),
            targets: targetsFor('app', outputs: ['.git/hooks/**']),
          ),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              allOf(contains('app'), contains('.git/hooks/**')),
            ),
          ),
        );
      },
    );
  });
}
