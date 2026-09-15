import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:rask/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late StringBuffer out;
  late FakeProcessLauncher launcher;

  void put(String rel, String yaml) {
    final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
    File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_dev_cli_');
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/app', 'name: app\ndependencies:\n  lib: any\n');
    put('packages/edge', 'name: edge\n');
    put('packages/lib', 'name: lib\n');
    out = StringBuffer();
    launcher = FakeProcessLauncher();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<int> dev(
    List<String> args, {
    RaskConfig config = const RaskConfig(),
  }) => RaskCommandRunner(
    cwd: root,
    processRunner: RecordingRunner(),
    registry: NoRegistry(),
    launcher: launcher,
    out: out,
    config: config,
  ).run(['dev', ...args]);

  test('without a plugin it says there is no target', () async {
    expect(await dev(const []), 64);
    expect(out.toString(), contains('no target'));
  });

  test('two targets without -F lists the candidates', () async {
    expect(await dev(const [], config: defineConfig(plugins: [_Two()])), 64);
    expect(
      out.toString(),
      allOf(contains('app'), contains('edge'), contains('-F')),
    );
  });

  test('-F naming a package without a target says so', () async {
    expect(
      await dev(['-F', 'lib'], config: defineConfig(plugins: [_Two()])),
      64,
    );
    expect(out.toString(), contains('lib has no target'));
  });

  test('two -F values is a usage error', () async {
    expect(
      await dev([
        '-F',
        'app',
        '-F',
        'edge',
      ], config: defineConfig(plugins: [_Two()])),
      64,
    );
    expect(out.toString(), contains('single name'));
  });

  test('a non-numeric --port is a usage error', () async {
    expect(
      await dev([
        '--port',
        'abc',
        '-F',
        'app',
      ], config: defineConfig(plugins: [_Two()])),
      64,
    );
    expect(out.toString(), contains('--port'));
  });

  test('^codegen in dependsOn runs codegen in dependencies, not in the '
      'target\'s own package, and a failure there returns promptly', () async {
    // app depends on lib (set up above); app's target declares
    // `dependsOn: ['^codegen']`, so codegen must run in lib and not in
    // app itself. codegen fails outright, so this never reaches a
    // process start: DevLoop.run bails out on runDependsOn's exit code
    // before touching the launcher.
    final ranIn = <String>[];
    final config = defineConfig(
      plugins: [_WithCodegen()],
      tasks: [
        Task(
          'codegen',
          run: (ctx) async {
            ranIn.add(ctx.package.name);
            throw ProcessFailure('codegen', 7);
          },
        ),
      ],
    );
    expect(await dev(const [], config: config), 7);
    expect(ranIn, ['lib']);
    expect(launcher.starts, isEmpty);
  });
}

class _Two implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => const {'app', 'edge'}.contains(pkg.name)
      ? Target(
          pkg.name,
          command: (ctx) => Command('dart', const ['run']),
          build: (ctx) async {},
        )
      : null;
}

class _WithCodegen implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => pkg.name == 'app'
      ? Target(
          pkg.name,
          command: (ctx) => Command('dart', const ['run']),
          build: (ctx) async {},
          dependsOn: const ['^codegen'],
        )
      : null;
}
