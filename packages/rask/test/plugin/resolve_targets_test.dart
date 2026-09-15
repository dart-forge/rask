import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/plugin/plugin.dart';
import 'package:rask/src/plugin/resolve_targets.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

class _Named implements RaskPlugin {
  _Named(this.serves, this.targetName);
  final Set<String> serves;
  final String targetName;

  @override
  Target? targetFor(Package pkg) => serves.contains(pkg.name)
      ? Target(
          targetName,
          command: (ctx) => Command('dart', const ['run']),
          build: (ctx) async {},
        )
      : null;
}

class _Counting implements RaskPlugin {
  var calls = 0;

  @override
  Target? targetFor(Package pkg) {
    calls++;
    return null;
  }
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
    root = Directory.systemTemp.createTempSync('rask_targets_');
    write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
    write('packages/app/pubspec.yaml', 'name: app\n');
    write('packages/edge/pubspec.yaml', 'name: edge\n');
    write('packages/lib/pubspec.yaml', 'name: lib\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('no plugins yields nothing', () {
    expect(resolveTargets(defineConfig(), ws), isEmpty);
  });

  test('one entry per served package', () {
    final resolved = resolveTargets(
      defineConfig(
        plugins: [
          _Named({'app'}, 'server'),
        ],
      ),
      ws,
    );
    expect(resolved.keys, ['app']);
    expect(resolved['app']!.target.name, 'server');
    expect(resolved['app']!.package.name, 'app');
  });

  test('two plugins may serve different packages', () {
    final resolved = resolveTargets(
      defineConfig(
        plugins: [
          _Named({'app'}, 'server'),
          _Named({'edge'}, 'edge'),
        ],
      ),
      ws,
    );
    expect(resolved.keys, unorderedEquals(['app', 'edge']));
    expect(resolved['edge']!.target.name, 'edge');
  });

  test('two plugins serving the same package is a ConfigError', () {
    expect(
      () => resolveTargets(
        defineConfig(
          plugins: [
            _Named({'app'}, 'server'),
            _Named({'app'}, 'edge'),
          ],
        ),
        ws,
      ),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          allOf(contains('app'), contains('server'), contains('edge')),
        ),
      ),
    );
  });

  test('each plugin is asked once per package', () {
    final counting = _Counting();
    resolveTargets(defineConfig(plugins: [counting]), ws);
    expect(counting.calls, ws.packages.length);
  });
}
