import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/task/builtin_tasks.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

/// Records what a task asked the context to do.
class FakeContext implements TaskContext {
  @override
  final Package package;
  @override
  final Workspace workspace;
  @override
  final List<String> args;
  final calls = <(String, List<String>)>[];
  final logs = <String>[];
  FakeContext(this.package, this.workspace, {this.args = const []});

  @override
  Future<void> dart(List<String> args) async => calls.add(('dart', args));
  @override
  Future<void> exec(String executable, List<String> args, {String? workingDirectory}) async =>
      calls.add((executable, args));
  @override
  void log(String message) => logs.add(message);
}

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_builtin_');
    void put(String rel, String yaml) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
    }
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/with_tests', 'name: with_tests\n');
    Directory(p.join(root.path, 'packages/with_tests/test/unit')).createSync(recursive: true);
    File(p.join(root.path, 'packages/with_tests/test/unit/a_test.dart')).writeAsStringSync('');
    put('packages/empty_test_dir', 'name: empty_test_dir\n');
    Directory(p.join(root.path, 'packages/empty_test_dir/test')).createSync();
    put('packages/helper_only', 'name: helper_only\n');
    Directory(p.join(root.path, 'packages/helper_only/test')).createSync();
    File(p.join(root.path, 'packages/helper_only/test/helper.dart')).writeAsStringSync('');
    put('packages/no_test_dir', 'name: no_test_dir\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  Task builtin(String name) => builtinTasks.singleWhere((t) => t.name == name);

  test('builtinTasks are test and analyze, both with a run', () {
    expect(builtinTasks.map((t) => t.name), ['test', 'analyze']);
    expect(builtinTasks.every((t) => t.run != null), isTrue);
  });

  test('hasTests needs at least one *_test.dart under test/, at any depth', () {
    expect(hasTests(ws['with_tests']), isTrue);
    expect(hasTests(ws['empty_test_dir']), isFalse);
    expect(hasTests(ws['helper_only']), isFalse);
    expect(hasTests(ws['no_test_dir']), isFalse);
  });

  test('test applies only where hasTests; analyze applies everywhere', () {
    expect(builtin('test').where!(ws['with_tests']), isTrue);
    expect(builtin('test').where!(ws['no_test_dir']), isFalse);
    expect(builtin('analyze').where, isNull);
  });

  test('test runs `dart test <args>`; analyze runs `dart analyze <args>`', () async {
    final ctx = FakeContext(ws['with_tests'], ws, args: ['--reporter', 'expanded']);
    await builtin('test').run!(ctx);
    // records compare their fields with ==, and List == is identity, so
    // assert on the fields rather than on whole records
    expect(ctx.calls.single.$1, 'dart');
    expect(ctx.calls.single.$2, ['test', '--reporter', 'expanded']);

    final ctx2 = FakeContext(ws['with_tests'], ws);
    await builtin('analyze').run!(ctx2);
    expect(ctx2.calls.single.$1, 'dart');
    expect(ctx2.calls.single.$2, ['analyze']);
  });

  test('commandNames are the non-task verbs', () {
    // 'help' is CommandRunner's own pre-registered hidden command (F4):
    // a task named 'help' throws ArgumentError: Duplicate command "help".
    expect(commandNames, {'pub', 'bump', 'publish', 'help'});
  });
}
