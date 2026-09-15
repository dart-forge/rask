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
    put('packages/app', 'name: app\n');
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
