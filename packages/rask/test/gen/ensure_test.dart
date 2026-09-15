import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/gen/ensure.dart';
import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:rask/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Workspace ws;
  late RecordingRunner runner;
  late StringBuffer out;

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();
  bool exists(String rel) =>
      File(p.join(root.path, rel)).existsSync() ||
      Directory(p.join(root.path, rel)).existsSync();

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_ensure_');
    write(
      'pubspec.yaml',
      'name: _\nenvironment:\n  sdk: ^3.13.0\nworkspace:\n  - packages/*\n',
    );
    write('packages/app/pubspec.yaml', 'name: app\n');
    ws = Workspace.load(root);
    runner = RecordingRunner();
    out = StringBuffer();
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<GeneratedPackage> declared([List<String> names = const ['app_gen']]) => [
    for (final name in names)
      GeneratedPackage(
        name: name,
        producer: ws['app'],
        taskName: 'codegen',
        dir: p.join(root.path, '.dart_tool', 'rask', 'gen', name),
      ),
  ];

  Future<EnsureResult> ensure(List<GeneratedPackage> generated) =>
      ensureGeneratedPackages(
        workspace: ws,
        generated: generated,
        runner: runner,
        out: out,
      );

  test('nothing declared touches nothing and runs no pub get', () async {
    final result = await ensure(const []);
    expect(result.changed, isFalse);
    expect(runner.calls, isEmpty);
    expect(exists('pubspec_overrides.yaml'), isFalse);
    expect(exists('.gitignore'), isFalse);
  });

  test(
    'writes the stub, the override, the gitignore line, then pub get',
    () async {
      final result = await ensure(declared());
      expect(result.changed, isTrue);
      expect(result.created, ['app_gen']);
      expect(result.pubGetExitCode, 0);

      final stub = read('.dart_tool/rask/gen/app_gen/pubspec.yaml');
      expect(stub, contains('name: app_gen'));
      expect(stub, contains('publish_to: none'));
      expect(stub, contains('sdk: ^3.13.0'));
      expect(stub, isNot(contains('resolution: workspace')));
      expect(stub, isNot(contains('dependencies:')));
      expect(exists('.dart_tool/rask/gen/app_gen/lib'), isTrue);

      expect(
        read('pubspec_overrides.yaml'),
        contains('.dart_tool/rask/gen/app_gen'),
      );
      expect(read('.gitignore'), contains('pubspec_overrides.yaml'));

      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.$1, 'dart');
      expect(runner.calls.single.$2, ['pub', 'get']);
      expect(runner.calls.single.$3, root.path);
    },
  );

  test('a second call with the same declaration changes nothing', () async {
    await ensure(declared());
    runner.calls.clear();
    final result = await ensure(declared());
    expect(result.changed, isFalse);
    expect(result.created, isEmpty);
    expect(runner.calls, isEmpty);
  });

  test(
    'removes the directory and the override of a package no longer declared',
    () async {
      await ensure(declared(['app_gen', 'old_gen']));
      runner.calls.clear();
      final result = await ensure(declared(['app_gen']));
      expect(result.changed, isTrue);
      expect(exists('.dart_tool/rask/gen/old_gen'), isFalse);
      expect(read('pubspec_overrides.yaml'), isNot(contains('old_gen')));
      expect(runner.calls, hasLength(1));
    },
  );

  test('reports the pub get exit code', () async {
    // RecordingRunner looks exit codes up by the working directory's basename.
    final failing = RecordingRunner(exitCodes: {p.basename(root.path): 69});
    final result = await ensureGeneratedPackages(
      workspace: ws,
      generated: declared(),
      runner: failing,
      out: out,
    );
    expect(result.pubGetExitCode, 69);
  });

  test('keeps an existing gitignore and does not double-add', () async {
    write('.gitignore', '.dart_tool/\nbuild/\n');
    await ensure(declared());
    final first = read('.gitignore');
    expect(first, startsWith('.dart_tool/\nbuild/\n'));
    expect(first, contains('pubspec_overrides.yaml'));

    await ensure(declared());
    expect(read('.gitignore'), first);
  });

  test('recognises an existing ignore pattern', () async {
    write('.gitignore', 'pubspec_overrides.*\n');
    await ensure(declared());
    expect(read('.gitignore'), 'pubspec_overrides.*\n');
  });

  test(
    'falls back to the running SDK when the root declares no constraint',
    () async {
      write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
      ws = Workspace.load(root);
      await ensure(declared());
      expect(
        read('.dart_tool/rask/gen/app_gen/pubspec.yaml'),
        contains(RegExp(r'sdk: \^\d+\.\d+\.\d+')),
      );
    },
  );

  test('a foreign override of a generated name is a ConfigError', () async {
    write(
      'pubspec_overrides.yaml',
      'dependency_overrides:\n  app_gen:\n    path: ../elsewhere\n',
    );
    await expectLater(ensure(declared()), throwsA(isA<ConfigError>()));
    expect(runner.calls, isEmpty);
  });

  test(
    'a foreign override collision leaves no generated directory behind',
    () async {
      write(
        'pubspec_overrides.yaml',
        'dependency_overrides:\n  app_gen:\n    path: ../elsewhere\n',
      );
      await expectLater(ensure(declared()), throwsA(isA<ConfigError>()));
      expect(exists('.dart_tool/rask/gen/app_gen'), isFalse);
      expect(runner.calls, isEmpty);
    },
  );
}
