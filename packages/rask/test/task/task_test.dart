import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/task/task.dart';
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
}
