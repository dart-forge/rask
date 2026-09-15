import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cli/rask_command_runner.dart';
import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:rask/testing.dart';
import 'package:test/test.dart';

class _TestPlugin implements RaskPlugin {
  _TestPlugin(this.built);
  final List<String> built;

  @override
  Target? targetFor(Package pkg) => pkg.name == 'tmp1'
      ? Target(
          'server',
          command: (ctx) => Command('dart', const ['run']),
          build: (ctx) async => built.add(ctx.package.name),
        )
      : null;
}

void main() {
  late Directory root;
  late RecordingRunner runner;
  late StringBuffer out;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_cli_');
    void put(String rel, String yaml, {bool withTests = true}) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
      if (withTests) {
        Directory(p.join(d.path, 'test')).createSync();
        File(p.join(d.path, 'test', 'x_test.dart')).writeAsStringSync('');
      }
    }

    put('.', 'name: _\nworkspace:\n  - packages/*\n', withTests: false);
    put('packages/tmp1', 'name: tmp1\ndependencies:\n  tmp3: any\n');
    put('packages/tmp3', 'name: tmp3\ndependencies:\n  tmp4: any\n');
    put('packages/tmp4', 'name: tmp4\n');
    runner = RecordingRunner();
    out = StringBuffer();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<int> rask(
    List<String> args, {
    Directory? cwd,
    RaskConfig config = const RaskConfig(),
  }) => RaskCommandRunner(
    cwd: cwd ?? root,
    processRunner: runner,
    out: out,
    registry: NoRegistry(),
    config: config,
  ).run(args);

  List<String> dirs() => runner.calls.map((c) => p.basename(c.$3)).toList();

  test(
    'analyze runs dart analyze in every package, dependencies first',
    () async {
      expect(await rask(['analyze']), 0);
      expect(dirs(), ['tmp4', 'tmp3', 'tmp1']);
      expect(runner.calls.first.$2, ['analyze']);
    },
  );

  test('--filter narrows the packages', () async {
    await rask(['test', '--filter', 'tmp3...']);
    expect(dirs(), ['tmp3', 'tmp1']);
  });

  test('-F is short for --filter and may repeat', () async {
    await rask(['test', '-F', 'tmp4', '-F', 'tmp1']);
    expect(dirs(), ['tmp4', 'tmp1']);
  });

  test('arguments after the command are passed through to dart', () async {
    await rask(['test', '-F', 'tmp4', '--', '--reporter', 'expanded']);
    expect(runner.calls.single.$2, ['test', '--reporter', 'expanded']);
  });

  test(
    'pub runs dart pub once at the workspace root with its arguments',
    () async {
      expect(await rask(['pub', 'get', '--offline']), 0);
      expect(runner.calls.single.$2, ['pub', 'get', '--offline']);
      expect(runner.calls.single.$3, root.path);
    },
  );

  test('finds the workspace root when run from a member directory', () async {
    await rask([
      'analyze',
    ], cwd: Directory(p.join(root.path, 'packages', 'tmp3')));
    expect(dirs(), ['tmp4', 'tmp3', 'tmp1']);
  });

  test('outside any workspace it fails with exit 64 and says so', () async {
    final lonely = Directory.systemTemp.createTempSync('rask_lonely_');
    addTearDown(() => lonely.deleteSync(recursive: true));
    expect(await rask(['analyze'], cwd: lonely), 64);
    expect(out.toString(), contains('pubspec.yaml'));
    expect(runner.calls, isEmpty);
  });

  test('unknown --filter name fails with exit 64', () async {
    expect(await rask(['analyze', '-F', 'nope']), 64);
    expect(out.toString(), contains('nope'));
  });

  test('a task with nothing to apply to reports so and exits 0 (F4)', () async {
    // remove every package's test/ dir so `test` (hasTests) applies nowhere
    for (final pkg in ['tmp1', 'tmp3', 'tmp4']) {
      Directory(p.join(root.path, 'packages', pkg, 'test'))
          .deleteSync(recursive: true);
    }
    expect(await rask(['test']), 0);
    expect(out.toString(), contains('rask: nothing to do for test'));
    expect(runner.calls, isEmpty);
  });

  group('--jobs', () {
    test('two independent packages run captured when -j allows it', () async {
      Directory(p.join(root.path, 'packages', 'tmp5'))
          .createSync(recursive: true);
      File(p.join(root.path, 'packages', 'tmp5', 'pubspec.yaml'))
          .writeAsStringSync('name: tmp5\n');
      expect(await rask(['analyze', '-j', '2', '-F', 'tmp4', '-F', 'tmp5']), 0);
      expect(dirs(), unorderedEquals(['tmp4', 'tmp5']));
      expect(
        out.toString(),
        allOf(contains('out of tmp4'), contains('out of tmp5')),
      );
    });

    test('--jobs 1 streams every package', () async {
      Directory(p.join(root.path, 'packages', 'tmp5'))
          .createSync(recursive: true);
      File(p.join(root.path, 'packages', 'tmp5', 'pubspec.yaml'))
          .writeAsStringSync('name: tmp5\n');
      expect(
        await rask(['analyze', '--jobs', '1', '-F', 'tmp4', '-F', 'tmp5']),
        0,
      );
      expect(dirs(), unorderedEquals(['tmp4', 'tmp5']));
      expect(out.toString(), isNot(contains('out of')));
    });

    test('a non-positive or non-numeric value fails with exit 64', () async {
      expect(await rask(['analyze', '-j', '0']), 64);
      expect(out.toString(), contains('--jobs'));
      expect(await rask(['analyze', '-j', 'many']), 64);
      expect(runner.calls, isEmpty);
    });
  });

  group('caching', () {
    test('by default a second identical run is skipped', () async {
      await rask(['analyze', '-F', 'tmp4']);
      await rask(['analyze', '-F', 'tmp4']);
      expect(dirs(), ['tmp4']);
      expect(out.toString(), contains('cached'));
    });

    test('cache lives under <root>/.dart_tool/rask/cache', () async {
      await rask(['analyze', '-F', 'tmp4']);
      expect(
        Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')).listSync(),
        hasLength(1),
      );
    });

    test('--no-cache runs every time and records nothing', () async {
      await rask(['analyze', '-F', 'tmp4', '--no-cache']);
      await rask(['analyze', '-F', 'tmp4', '--no-cache']);
      expect(dirs(), ['tmp4', 'tmp4']);
      expect(
        Directory(p.join(root.path, '.dart_tool', 'rask', 'cache'))
            .existsSync(),
        isFalse,
      );
    });
  });

  group('release', () {
    setUp(() {
      // make tmp4 publishable
      File(p.join(root.path, 'packages', 'tmp4', 'pubspec.yaml'))
          .writeAsStringSync('name: tmp4\nversion: 0.1.0\n');
      File(p.join(root.path, 'packages', 'tmp3', 'pubspec.yaml'))
          .writeAsStringSync(
            'name: tmp3\nversion: 0.1.0\ndependencies:\n  tmp4: ^0.1.0\n',
          );
    });

    test('bump rewrites versions and reports them', () async {
      expect(await rask(['bump', '0.2.0']), 0);
      expect(
        File(p.join(root.path, 'packages', 'tmp4', 'pubspec.yaml'))
            .readAsStringSync(),
        contains('version: 0.2.0'),
      );
      expect(
        File(p.join(root.path, 'packages', 'tmp3', 'pubspec.yaml'))
            .readAsStringSync(),
        contains('tmp4: ^0.2.0'),
      );
      expect(out.toString(), contains('tmp4: 0.1.0 → 0.2.0'));
      expect(runner.calls, isEmpty);
    });

    test('bump rejects a malformed version with exit 64', () async {
      expect(await rask(['bump', 'v0.2.0']), 64);
      expect(out.toString(), contains('v0.2.0'));
    });

    test('bump without a version is a usage error', () async {
      expect(await rask(['bump']), 64);
    });

    test('publish runs dart pub publish --force for publishable members, dependencies first', () async {
      expect(await rask(['publish']), 0);
      expect(dirs(), ['tmp4', 'tmp3']);
      expect(runner.calls.first.$2, ['pub', 'publish', '--force']);
    });

    test('publish --dry-run passes --dry-run', () async {
      await rask(['publish', '--dry-run', '-F', 'tmp4']);
      expect(runner.calls.single.$2, ['pub', 'publish', '--dry-run']);
    });
  });

  group('user tasks from a RaskConfig', () {
    Future<void> noop(TaskContext _) async {}

    test('each task becomes a command with -F and -- passthrough', () async {
      final config = defineConfig(
        tasks: [
          Task(
            'codegen',
            run: (ctx) =>
                ctx.dart(['run', 'build_runner', 'build', ...ctx.args]),
          ),
        ],
      );
      expect(
        await rask([
          'codegen',
          '-F',
          'tmp4',
          '--',
          '--verbose',
        ], config: config),
        0,
      );
      expect(runner.calls.single.$2, [
        'run',
        'build_runner',
        'build',
        '--verbose',
      ]);
      expect(p.basename(runner.calls.single.$3), 'tmp4');
    });

    test('dependsOn pulls in nodes outside the filter', () async {
      final config = defineConfig(
        tasks: [
          Task('codegen', run: noop),
          Task('test', dependsOn: ['^codegen']),
        ],
      );
      await rask(['test', '-F', 'tmp1'], config: config);
      // tmp1 -> tmp3 -> tmp4: codegen runs (noop, no process) in tmp3 and tmp4, then dart test in tmp1
      expect(dirs(), ['tmp1']);
      expect(
        out.toString(),
        allOf(
          contains('rask: tmp3 — codegen'),
          contains('rask: tmp4 — codegen'),
        ),
      );
    });

    test('a broken config is exit 64 before any command runs', () async {
      final config = defineConfig(tasks: [Task('pub', run: noop)]);
      expect(await rask(['analyze'], config: config), 64);
      expect(out.toString(), contains('pub'));
      expect(runner.calls, isEmpty);
    });

    test(
      'an unknown task is a usage error listing available commands',
      () async {
        expect(await rask(['nope']), 64);
        expect(out.toString(), contains('analyze'));
      },
    );
  });

  group('generated packages', () {
    Task codegen({String Function(Package pkg)? generates}) => Task(
      'codegen',
      where: (pkg) => pkg.name == 'tmp1',
      generates: generates ?? ((pkg) => 'tmp1_gen'),
      run: (ctx) async {},
    );

    bool exists(String rel) => File(p.join(root.path, rel)).existsSync();

    test('creates them, runs pub get first, and hints once', () async {
      expect(
        await rask(['codegen'], config: defineConfig(tasks: [codegen()])),
        0,
      );
      expect(exists('.dart_tool/rask/gen/tmp1_gen/pubspec.yaml'), isTrue);
      expect(exists('pubspec_overrides.yaml'), isTrue);
      expect(runner.calls.first.$2, ['pub', 'get']);
      expect(
        out.toString(),
        allOf(
          contains('tmp1_gen: any'),
          contains(p.join('packages', 'tmp1', 'pubspec.yaml')),
          contains(
            'no clone can resolve dependencies until rask has generated '
            'tmp1_gen',
          ),
          contains('Run `rask codegen` now'),
        ),
      );

      // Second run: nothing changed, so no pub get and no hint.
      runner.calls.clear();
      out.clear();
      expect(
        await rask(['codegen'], config: defineConfig(tasks: [codegen()])),
        0,
      );
      expect(runner.calls.where((c) => c.$2.contains('get')), isEmpty);
      expect(out.toString(), isNot(contains('tmp1_gen: any')));
    });

    test('hint names the declaring task, not the invoked task', () async {
      expect(
        await rask(
          ['analyze'],
          config: defineConfig(
            tasks: [
              codegen(),
              Task('analyze', run: (ctx) async {}),
            ],
          ),
        ),
        0,
      );
      expect(exists('.dart_tool/rask/gen/tmp1_gen/pubspec.yaml'), isTrue);
      // The hint should tell the user to run `rask codegen`, the declaring task,
      // even though `analyze` was invoked.
      expect(out.toString(), contains('Run `rask codegen` now'));
    });

    test('a failing pub get stops the run with its exit code', () async {
      final failing = RecordingRunner(exitCodes: {p.basename(root.path): 69});
      final code = await RaskCommandRunner(
        cwd: root,
        processRunner: failing,
        out: out,
        registry: NoRegistry(),
        config: defineConfig(
          tasks: [
            Task(
              'codegen',
              where: (pkg) => pkg.name == 'tmp1',
              generates: (pkg) => 'tmp1_gen',
              run: (ctx) async => fail('the task must not run'),
            ),
          ],
        ),
      ).run(['codegen']);
      expect(code, 69);
    });

    test('a bad generated name is a usage error', () async {
      final code = await rask(
        ['codegen'],
        config: defineConfig(tasks: [codegen(generates: (pkg) => 'Bad-Name')]),
      );
      expect(code, 64);
      expect(out.toString(), contains('Bad-Name'));
    });

    test(
      'a task without generates never touches pubspec_overrides.yaml',
      () async {
        expect(
          await rask([
            'plain',
          ], config: defineConfig(tasks: [Task('plain', run: (ctx) async {})])),
          0,
        );
        expect(exists('pubspec_overrides.yaml'), isFalse);
        expect(runner.calls.where((c) => c.$2.contains('get')), isEmpty);
      },
    );
  });

  group('build from a plugin', () {
    test('build runs the target of each served package', () async {
      final built = <String>[];
      final code = await rask([
        'build',
      ], config: defineConfig(plugins: [_TestPlugin(built)]));
      expect(code, 0);
      expect(built, ['tmp1']);
    });

    test('there is no build command without a plugin', () async {
      expect(await rask(['build']), 64);
      expect(
        out.toString(),
        contains('Could not find a command named "build"'),
      );
    });
  });
}
