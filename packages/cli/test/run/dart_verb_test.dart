import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
import 'package:rask/src/run/dart_verb.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

class RecordingRunner implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  final Map<String, int> exitCodes;
  RecordingRunner({this.exitCodes = const {}});

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory}) async {
    calls.add((executable, args, workingDirectory));
    return exitCodes[p.basename(workingDirectory)] ?? 0;
  }
}

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_verb_');
    void put(String rel, String yaml, {bool withTests = false}) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
      if (withTests) {
        Directory(p.join(d.path, 'test')).createSync();
        File(p.join(d.path, 'test', 'x_test.dart')).writeAsStringSync('');
      }
    }
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/tmp1', 'name: tmp1\ndependencies:\n  tmp2: any\n', withTests: true);
    put('packages/tmp2', 'name: tmp2\n', withTests: true);
    put('packages/tmp3', 'name: tmp3\n'); // no test/ directory
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('runs `dart <verb>` in each selected package, dependencies first', () async {
    final runner = RecordingRunner();
    final code = await runDartVerb(
      'analyze',
      packages: ws.inOrder,
      runner: runner,
      out: StringBuffer(),
    );
    expect(code, 0);
    final visited = runner.calls.map((c) => p.basename(c.$3)).toList();
    expect(visited, unorderedEquals(['tmp1', 'tmp2', 'tmp3']));
    expect(visited.indexOf('tmp2'), lessThan(visited.indexOf('tmp1')));
    expect(runner.calls.every((c) => c.$1 == 'dart' && c.$2.first == 'analyze'), isTrue);
  });

  test('passes extra arguments through to dart', () async {
    final runner = RecordingRunner();
    await runDartVerb('test', packages: [ws['tmp2']], runner: runner,
        out: StringBuffer(), extraArgs: ['--reporter', 'expanded']);
    expect(runner.calls.single.$2, ['test', '--reporter', 'expanded']);
  });

  test('`test` skips packages that have no test/ directory', () async {
    final runner = RecordingRunner();
    final out = StringBuffer();
    await runDartVerb('test', packages: ws.inOrder, runner: runner, out: out);
    expect(runner.calls.map((c) => p.basename(c.$3)), unorderedEquals(['tmp2', 'tmp1']));
    expect(out.toString(), contains('tmp3'));
    expect(out.toString(), contains('skip'));
  });

  test('`test` skips packages whose test/ has no *_test.dart files', () async {
    // an empty test/ makes `dart test` exit 79 ("No tests were found")
    Directory(p.join(ws['tmp3'].path, 'test')).createSync();
    // a nested _test.dart still counts
    Directory(p.join(ws['tmp1'].path, 'test', 'unit')).createSync();
    File(p.join(ws['tmp1'].path, 'test', 'unit', 'a_test.dart')).writeAsStringSync('');
    // helpers that are not tests do not count
    File(p.join(ws['tmp2'].path, 'test', 'x_test.dart')).deleteSync();
    File(p.join(ws['tmp2'].path, 'test', 'helper.dart')).writeAsStringSync('');

    final runner = RecordingRunner();
    await runDartVerb('test', packages: ws.inOrder, runner: runner, out: StringBuffer());
    expect(runner.calls.map((c) => p.basename(c.$3)), ['tmp1']);
  });

  test('stops at the first failure and returns its exit code', () async {
    final runner = RecordingRunner(exitCodes: {'tmp2': 3});
    final code = await runDartVerb('analyze', packages: ws.inOrder,
        runner: runner, out: StringBuffer());
    expect(code, 3);
    expect(runner.calls.map((c) => p.basename(c.$3)), ['tmp2']);
  });

  test('announces each package before running it', () async {
    final runner = RecordingRunner();
    final out = StringBuffer();
    await runDartVerb('analyze', packages: [ws['tmp2']], runner: runner, out: out);
    expect(out.toString(), contains('tmp2'));
    expect(out.toString(), contains('dart analyze'));
  });

  group('with a TaskCache', () {
    late TaskCache cache;
    setUp(() {
      File(p.join(ws['tmp2'].path, 'lib', 'x.dart')).createSync(recursive: true);
      cache = TaskCache(
        workspace: ws,
        directory: Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')),
        sdkVersion: '3.13.0',
      );
    });

    Future<(int, RecordingRunner, String)> run({Map<String, int> exitCodes = const {}}) async {
      final runner = RecordingRunner(exitCodes: exitCodes);
      final out = StringBuffer();
      final code = await runDartVerb('analyze',
          packages: [ws['tmp2']], runner: runner, out: out, cache: cache);
      return (code, runner, out.toString());
    }

    test('a successful run is skipped the second time with the same inputs', () async {
      final first = await run();
      expect(first.$2.calls, hasLength(1));
      final second = await run();
      expect(second.$1, 0);
      expect(second.$2.calls, isEmpty);
      expect(second.$3, contains('tmp2'));
      expect(second.$3, contains('cached'));
    });

    test('a failed run is not cached', () async {
      final failed = await run(exitCodes: {'tmp2': 1});
      expect(failed.$1, 1);
      final again = await run();
      expect(again.$2.calls, hasLength(1));
    });

    test('changing a file in the package runs it again', () async {
      await run();
      File(p.join(ws['tmp2'].path, 'lib', 'x.dart')).writeAsStringSync('// changed');
      final again = await run();
      expect(again.$2.calls, hasLength(1));
    });

    test('changing a dependency runs the dependent again', () async {
      final runner = RecordingRunner();
      Future<int> both() => runDartVerb('analyze',
          packages: [ws['tmp2'], ws['tmp1']], runner: runner, out: StringBuffer(), cache: cache);
      await both();
      expect(runner.calls, hasLength(2));
      File(p.join(ws['tmp2'].path, 'lib', 'x.dart')).writeAsStringSync('// changed');
      await both();
      expect(runner.calls, hasLength(4)); // tmp2 changed, tmp1 depends on it
    });
  });
}
