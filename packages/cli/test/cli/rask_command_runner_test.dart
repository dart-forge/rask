import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cli/rask_command_runner.dart';
import 'package:rask/src/release/publish.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:test/test.dart';

class NoRegistry implements PackageRegistry {
  @override
  Future<bool> hasVersion({required String host, required String name, required String version}) async => false;
}

class RecordingRunner implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  /// Working directories of the invocations that went through [runCaptured].
  final captured = <String>[];
  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory}) async {
    calls.add((executable, args, workingDirectory));
    return 0;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory}) async {
    captured.add(workingDirectory);
    return CapturedProcess(await run(executable, args, workingDirectory: workingDirectory), '');
  }
}

void main() {
  late Directory root;
  late RecordingRunner runner;
  late StringBuffer out;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_cli_');
    void put(String rel, String yaml, {bool withTests = true}) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
      if (withTests) {
        Directory(p.join(d.path, 'test')).createSync();
        File(p.join(d.path, 'test', 'x_test.dart')).writeAsStringSync('');
      }
    }
    put('.', 'name: _\nworkspace:\n  - packages/*\n', withTests: false);
    put('packages/tmp1', 'name: tmp1\ndependencies:\n  tmp3: any\n');
    put('packages/tmp3', 'name: tmp3\ndependencies:\n  tmp4: any\n');
    put('packages/tmp4', 'name: tmp4\n');
    runner = RecordingRunner();
    out = StringBuffer();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<int> rask(List<String> args, {Directory? cwd}) =>
      RaskCommandRunner(cwd: cwd ?? root, processRunner: runner, out: out, registry: NoRegistry()).run(args);

  List<String> dirs() => runner.calls.map((c) => p.basename(c.$3)).toList();

  test('analyze runs dart analyze in every package, dependencies first', () async {
    expect(await rask(['analyze']), 0);
    expect(dirs(), ['tmp4', 'tmp3', 'tmp1']);
    expect(runner.calls.first.$2, ['analyze']);
  });

  test('--filter narrows the packages', () async {
    await rask(['test', '--filter', 'tmp3...']);
    expect(dirs(), ['tmp3', 'tmp1']);
  });

  test('-F is short for --filter and may repeat', () async {
    await rask(['test', '-F', 'tmp4', '-F', 'tmp1']);
    expect(dirs(), ['tmp4', 'tmp1']);
  });

  test('arguments after the command are passed through to dart', () async {
    await rask(['test', '-F', 'tmp4', '--', '--reporter', 'expanded']);
    expect(runner.calls.single.$2, ['test', '--reporter', 'expanded']);
  });

  test('pub runs dart pub once at the workspace root with its arguments', () async {
    expect(await rask(['pub', 'get', '--offline']), 0);
    expect(runner.calls.single.$2, ['pub', 'get', '--offline']);
    expect(runner.calls.single.$3, root.path);
  });

  test('finds the workspace root when run from a member directory', () async {
    await rask(['analyze'], cwd: Directory(p.join(root.path, 'packages', 'tmp3')));
    expect(dirs(), ['tmp4', 'tmp3', 'tmp1']);
  });

  test('outside any workspace it fails with exit 64 and says so', () async {
    final lonely = Directory.systemTemp.createTempSync('rask_lonely_');
    addTearDown(() => lonely.deleteSync(recursive: true));
    expect(await rask(['analyze'], cwd: lonely), 64);
    expect(out.toString(), contains('pubspec.yaml'));
    expect(runner.calls, isEmpty);
  });

  test('unknown --filter name fails with exit 64', () async {
    expect(await rask(['analyze', '-F', 'nope']), 64);
    expect(out.toString(), contains('nope'));
  });

  group('caching', () {
    test('by default a second identical run is skipped', () async {
      await rask(['analyze', '-F', 'tmp4']);
      await rask(['analyze', '-F', 'tmp4']);
      expect(dirs(), ['tmp4']);
      expect(out.toString(), contains('cached'));
    });

    test('cache lives under <root>/.dart_tool/rask/cache', () async {
      await rask(['analyze', '-F', 'tmp4']);
      expect(Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')).listSync(), hasLength(1));
    });

    test('--no-cache runs every time and records nothing', () async {
      await rask(['analyze', '-F', 'tmp4', '--no-cache']);
      await rask(['analyze', '-F', 'tmp4', '--no-cache']);
      expect(dirs(), ['tmp4', 'tmp4']);
      expect(Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')).existsSync(), isFalse);
    });
  });

  group('release', () {
    setUp(() {
      // make tmp4 publishable
      File(p.join(root.path, 'packages', 'tmp4', 'pubspec.yaml')).writeAsStringSync('name: tmp4\nversion: 0.1.0\n');
      File(p.join(root.path, 'packages', 'tmp3', 'pubspec.yaml'))
          .writeAsStringSync('name: tmp3\nversion: 0.1.0\ndependencies:\n  tmp4: ^0.1.0\n');
    });

    test('bump rewrites versions and reports them', () async {
      expect(await rask(['bump', '0.2.0']), 0);
      expect(File(p.join(root.path, 'packages', 'tmp4', 'pubspec.yaml')).readAsStringSync(), contains('version: 0.2.0'));
      expect(File(p.join(root.path, 'packages', 'tmp3', 'pubspec.yaml')).readAsStringSync(), contains('tmp4: ^0.2.0'));
      expect(out.toString(), contains('tmp4: 0.1.0 → 0.2.0'));
      expect(runner.calls, isEmpty);
    });

    test('bump rejects a malformed version with exit 64', () async {
      expect(await rask(['bump', 'v0.2.0']), 64);
      expect(out.toString(), contains('v0.2.0'));
    });

    test('bump without a version is a usage error', () async {
      expect(await rask(['bump']), 64);
    });

    test('publish runs dart pub publish --force for publishable members, dependencies first', () async {
      expect(await rask(['publish']), 0);
      expect(dirs(), ['tmp4', 'tmp3']);
      expect(runner.calls.first.$2, ['pub', 'publish', '--force']);
    });

    test('publish --dry-run passes --dry-run', () async {
      await rask(['publish', '--dry-run', '-F', 'tmp4']);
      expect(runner.calls.single.$2, ['pub', 'publish', '--dry-run']);
    });
  });
}
