import 'package:rask/rask.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

class _Plugin implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => pkg.name == 'app'
      ? Target(
          'server',
          command: (ctx) => Command('dart', ['run', 'bin/server.dart']),
          build: (ctx) => ctx.dart(['compile', 'exe', 'bin/server.dart']),
        )
      : null;
}

void main() {
  Package pkg(String name) => Package(
    name: name,
    path: '/ws/packages/$name',
    dependencies: const [],
    pubspec: loadYaml('name: $name') as YamlMap,
  );

  test('a target carries its defaults', () {
    final t = _Plugin().targetFor(pkg('app'))!;
    expect(t.name, 'server');
    expect(t.watch, ['lib/**', 'bin/**']);
    expect(t.dependsOn, isEmpty);
    expect(t.onChange, OnChange.restart);
    expect(t.prepare, isNull);
    expect(t.buildInputs, isNull);
    expect(t.buildOutputs, isEmpty);
  });

  test('a plugin can decline a package', () {
    expect(_Plugin().targetFor(pkg('lib')), isNull);
  });

  test('a command carries its environment', () {
    final c = Command('npx', ['wrangler', 'dev'], environment: {'A': '1'});
    expect(c.executable, 'npx');
    expect(c.args, ['wrangler', 'dev']);
    expect(c.environment, {'A': '1'});
  });

  test('every OnChange value is distinct', () {
    expect(OnChange.values, hasLength(4));
  });
}
