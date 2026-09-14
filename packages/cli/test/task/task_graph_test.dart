import 'package:rask/src/task/builtin_tasks.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:test/test.dart';

void main() {
  group('resolveConfig', () {
    Future<void> noop(TaskContext _) async {}

    test('with no user tasks the resolved tasks are the builtins, in order', () {
      final r = resolveConfig(defineConfig());
      expect(r.tasks.keys, ['test', 'analyze']);
      expect(r['test'].run, same(builtinTasks[0].run));
    });

    test('user tasks are appended after the builtins', () {
      final r = resolveConfig(defineConfig(tasks: [Task('codegen', run: noop)]));
      expect(r.tasks.keys, ['test', 'analyze', 'codegen']);
    });

    test('a user task with a builtin name merges: given fields replace, others stay', () {
      final r = resolveConfig(defineConfig(tasks: [
        Task('test', dependsOn: ['^codegen'], outputs: ['coverage/**']),
        Task('codegen', run: noop),
      ]));
      final t = r['test'];
      expect(t.dependsOn, ['^codegen']);
      expect(t.outputs, ['coverage/**']);
      expect(t.run, same(builtinTasks[0].run)); // kept
      expect(t.where, same(builtinTasks[0].where)); // kept
      expect(t.description, builtinTasks[0].description); // kept
    });

    test('a user task with a builtin name may replace run and where', () {
      bool everywhere(_) => true;
      final r = resolveConfig(defineConfig(tasks: [Task('test', run: noop, where: everywhere)]));
      expect(r['test'].run, same(noop));
      expect(r['test'].where, same(everywhere));
    });

    test('rejects two user tasks with the same name', () {
      expect(
        () => resolveConfig(defineConfig(tasks: [Task('a', run: noop), Task('a', run: noop)])),
        throwsA(isA<ConfigError>().having((e) => e.message, 'message', contains('"a"'))),
      );
    });

    test('rejects a task named like a command', () {
      for (final name in ['pub', 'bump', 'publish']) {
        expect(() => resolveConfig(defineConfig(tasks: [Task(name, run: noop)])),
            throwsA(isA<ConfigError>().having((e) => e.message, 'message', contains(name))));
      }
    });

    test('rejects a non-builtin task without run', () {
      expect(() => resolveConfig(defineConfig(tasks: [Task('codegen')])),
          throwsA(isA<ConfigError>().having((e) => e.message, 'message', contains('run'))));
    });

    test('rejects dependsOn on an unknown task, naming both', () {
      expect(
        () => resolveConfig(defineConfig(tasks: [Task('a', run: noop, dependsOn: ['^nope'])])),
        throwsA(isA<ConfigError>()
            .having((e) => e.message, 'message', allOf(contains('nope'), contains('"a"')))),
      );
    });

    test('rejects malformed dependsOn entries', () {
      for (final bad in ['', '^', '^^test']) {
        expect(() => resolveConfig(defineConfig(tasks: [Task('a', run: noop, dependsOn: [bad])])),
            throwsA(isA<ConfigError>()), reason: 'entry: "$bad"');
      }
    });

    test('dependsOn may reference builtins and later-defined user tasks', () {
      final r = resolveConfig(defineConfig(tasks: [
        Task('a', run: noop, dependsOn: ['b', '^test']),
        Task('b', run: noop),
      ]));
      expect(r['a'].dependsOn, ['b', '^test']);
    });
  });
}
