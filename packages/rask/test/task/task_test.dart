import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  test('defineConfig keeps the tasks it is given, in order', () {
    final a = Task('a');
    final b = Task('b');
    expect(defineConfig(tasks: [a, b]).tasks, [a, b]);
    expect(defineConfig().tasks, isEmpty);
  });

  test('Task defaults: applies everywhere, no run, no dependsOn, whole package as inputs, no outputs', () {
    final t = Task('x');
    expect(t.where, isNull);
    expect(t.run, isNull);
    expect(t.dependsOn, isEmpty);
    expect(t.inputs, isNull);
    expect(t.outputs, isEmpty);
    expect(t.description, isNull);
  });

  test('ProcessFailure carries the command and exit code and prints both', () {
    final f = ProcessFailure('dart test', 3);
    expect(f.exitCode, 3);
    expect(f.toString(), allOf(contains('dart test'), contains('3')));
  });

  group('Package.dependsOn', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('rask_task_');
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: solo
dependencies:
  build_runner: ^2.4.0
  other:
    path: ../other
dev_dependencies:
  test: any
''');
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('is true for hosted, path and dev dependencies, false otherwise', () {
      final pkg = Workspace.load(root)['solo'];
      expect(pkg.dependsOn('build_runner'), isTrue);
      expect(pkg.dependsOn('other'), isTrue);
      expect(pkg.dependsOn('test'), isTrue);
      expect(pkg.dependsOn('freezed'), isFalse);
    });
  });

  group('generates', () {
    test('defaults to null and round-trips the given function', () {
      expect(Task('a', run: (_) async {}).generates, isNull);
      final t = Task(
        'codegen',
        run: (_) async {},
        generates: (pkg) => '${pkg.name}_gen',
      );
      expect(t.generates, isNotNull);
    });

    test('resolveConfig keeps generates on a user task', () {
      final resolved = resolveConfig(
        defineConfig(
          tasks: [
            Task('codegen', run: (_) async {}, generates: (pkg) => 'x_gen'),
          ],
        ),
      );
      expect(resolved['codegen'].generates, isNotNull);
    });

    test('resolveConfig rejects generates without a run in the same task', () {
      expect(
        () => resolveConfig(
          defineConfig(tasks: [Task('codegen', generates: (pkg) => 'x_gen')]),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('codegen'), contains('generates')),
          ),
        ),
      );
    });

    test('resolveConfig rejects generates bolted onto a built-in task', () {
      expect(
        () => resolveConfig(
          defineConfig(tasks: [Task('test', generates: (pkg) => 'x_gen')]),
        ),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('plugins', () {
    test('defineConfig takes plugins and defaults them to empty', () {
      expect(defineConfig().plugins, isEmpty);
      expect(defineConfig(plugins: const []).plugins, isEmpty);
    });
  });
}
