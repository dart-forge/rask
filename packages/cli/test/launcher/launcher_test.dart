import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/launcher/config_key.dart';
import 'package:rask/src/launcher/entrypoint_template.dart';
import 'package:rask/src/launcher/launcher.dart';
import 'package:test/test.dart';

import '../helpers/recording_runner.dart';

void main() {
  late Directory root;
  late FakeCompiler runner;
  late StringBuffer err;
  final builtinCalls = <List<String>>[];

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    builtinCalls.clear();
    root = Directory.systemTemp.createTempSync('rask_launcher_');
    write(
      'pubspec.yaml',
      'name: _\nworkspace:\n  - packages/*\ndev_dependencies:\n  rask: any\n',
    );
    write('pubspec.lock', 'packages: {}\n');
    write(
      '.dart_tool/package_config.json',
      '{"configVersion":2,"packages":[]}',
    );
    write('packages/app/pubspec.yaml', 'name: app\nresolution: workspace\n');
    write(
      'rask.dart',
      "import 'package:rask/rask.dart';\nfinal config = defineConfig();\n",
    );
    write('rask/tasks.dart', 'const x = 1;');
    runner = FakeCompiler(root: root.path);
    err = StringBuffer();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Launcher launcher({Directory? cwd, FakeCompiler? r}) => Launcher(
    cwd: cwd ?? root,
    runner: r ?? runner,
    err: err,
    environment: {'HOME': '/h'},
    sdkVersion: '3.13.0',
    launcherVersion: '9.9.9',
    builtin: (args) async {
      builtinCalls.add(args);
      return 0;
    },
  );

  String exe() => p.join(root.path, '.dart_tool', 'rask', 'entrypoint.exe');
  File entrypoint() =>
      File(p.join(root.path, '.dart_tool', 'rask', 'entrypoint.dart'));
  File keyFile() =>
      File(p.join(root.path, '.dart_tool', 'rask', 'entrypoint.key'));
  List<String> leftoverTmps() =>
      Directory(p.join(root.path, '.dart_tool', 'rask'))
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.endsWith('.tmp'))
          .toList();

  group('falls back to the builtin config', () {
    test('when there is no rask.dart', () async {
      File(p.join(root.path, 'rask.dart')).deleteSync();
      expect(await launcher().run(['test', '-F', 'app']), 0);
      expect(builtinCalls, [
        ['test', '-F', 'app'],
      ]);
      expect(runner.calls, isEmpty);
    });

    test('when there is no workspace at all', () async {
      final lonely = Directory.systemTemp.createTempSync('rask_lonely_');
      addTearDown(() => lonely.deleteSync(recursive: true));
      await launcher(cwd: lonely).run(['analyze']);
      expect(builtinCalls, [
        ['analyze'],
      ]);
    });

    test('for `pub`, even with a rask.dart (D-050)', () async {
      await launcher().run(['pub', 'get', '--offline']);
      expect(builtinCalls, [
        ['pub', 'get', '--offline'],
      ]);
      expect(runner.compiles, 0);
    });
  });

  group('preconditions', () {
    test(
      'missing package_config.json → 64 and a hint to run rask pub get',
      () async {
        File(p.join(root.path, '.dart_tool', 'package_config.json'))
            .deleteSync();
        expect(await launcher().run(['test']), 64);
        expect(err.toString(), contains('rask pub get'));
        expect(runner.compiles, 0);
      },
    );

    test(
      'root pubspec without a rask dependency → 64 and how to add it',
      () async {
        write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
        expect(await launcher().run(['test']), 64);
        expect(
          err.toString(),
          allOf(
            contains('package:rask'),
            contains('dev_dependencies'),
            contains('9.9.9'),
          ),
        );
        expect(runner.compiles, 0);
      },
    );

    test('a rask dependency under dependencies is accepted too', () async {
      write(
        'pubspec.yaml',
        'name: _\nworkspace:\n  - packages/*\ndependencies:\n  rask: any\n',
      );
      expect(await launcher().run(['test']), 0);
      expect(runner.compiles, 1);
    });
  });

  group('first run', () {
    test('writes the entrypoint from the template, compiles, records the key, execs', () async {
      expect(await launcher().run(['test', '--', '-x']), 0);
      expect(entrypoint().readAsStringSync(), entrypointSource);
      expect(runner.compiles, 1);
      final compile = runner.calls.first;
      expect(compile.$1, 'dart');
      expect(compile.$2.take(2), ['compile', 'exe']);
      final out = compile.$2[compile.$2.indexOf('-o') + 1];
      expect(out, startsWith(exe())); // a temp path beside the exe (F1)
      expect(out, endsWith('.tmp'));
      expect(compile.$2, contains('--depfile'));
      expect(compile.$3, root.path);
      expect(err.toString(), contains('compiling rask.dart'));

      final expectedKey = computeConfigKey(
        root: root,
        localInputs: localDepfileInputs(
          File(p.join(root.path, '.dart_tool', 'rask', 'entrypoint.d'))
              .readAsStringSync(),
          root: root.path,
        ),
        sdkVersion: '3.13.0',
      );
      expect(keyFile().readAsStringSync(), expectedKey);

      final exec = runner.calls.last;
      expect(exec.$1, exe());
      expect(exec.$2, ['test', '--', '-x']);
      expect(exec.$3, root.path); // cwd was root here
      expect(runner.environments.last, {
        'HOME': '/h',
        'RASK_CONFIG_KEY': expectedKey,
        'RASK_LAUNCHER_VERSION': '9.9.9',
      });
    });

    test('execs with the caller\'s cwd, not the root', () async {
      final app = Directory(p.join(root.path, 'packages', 'app'));
      await launcher(cwd: app).run(['analyze']);
      expect(runner.calls.last.$3, app.path);
    });

    test('returns the exe\'s exit code', () async {
      final r = FakeCompiler(root: root.path, exitCodes: {'entrypoint.exe': 5});
      expect(await launcher(r: r).run(['test']), 5);
    });

    test('the compile output goes to a temp path and is renamed into place', () async {
      expect(await launcher().run(['test']), 0);
      final out = runner.calls.first.$2[runner.calls.first.$2.indexOf('-o') + 1];
      expect(out, endsWith('.tmp'));
      expect(out, isNot(exe()));
      expect(File(exe()).existsSync(), isTrue);
      expect(File(out).existsSync(), isFalse);
      expect(leftoverTmps(), isEmpty);
    });

    test('empty args with a rask.dart still compiles and execs', () async {
      expect(await launcher().run([]), 0);
      expect(runner.compiles, 1);
      expect(runner.calls.last.$2, <String>[]);
    });
  });

  group('compile cache', () {
    test('a second run with nothing changed does not compile', () async {
      await launcher().run(['test']);
      final err2 = StringBuffer();
      final r2 = FakeCompiler(root: root.path);
      await Launcher(
        cwd: root,
        runner: r2,
        err: err2,
        sdkVersion: '3.13.0',
        builtin: (_) async => 0,
      ).run(['test']);
      expect(r2.compiles, 0);
      expect(r2.calls.single.$1, exe());
      expect(err2.toString(), isNot(contains('compiling')));
    });

    for (final (what, change) in <(String, void Function())>[
      (
        'rask.dart',
        () => write(
          'rask.dart',
          "import 'package:rask/rask.dart';\nfinal config = defineConfig(tasks: []);\n",
        ),
      ),
      (
        'an imported local file',
        () => write('rask/tasks.dart', 'const x = 2;'),
      ),
      ('pubspec.lock', () => write('pubspec.lock', 'packages:\n  x: {}\n')),
    ]) {
      test('recompiles when $what changes', () async {
        await launcher().run(['test']);
        change();
        final r2 = FakeCompiler(root: root.path);
        await launcher(r: r2).run(['test']);
        expect(r2.compiles, 1);
      });
    }

    test('recompiles when the exe is missing', () async {
      await launcher().run(['test']);
      File(exe()).deleteSync();
      final r2 = FakeCompiler(root: root.path);
      await launcher(r: r2).run(['test']);
      expect(r2.compiles, 1);
    });

    test(
      'recompiles when the depfile is missing but the key file and exe exist',
      () async {
        await launcher().run(['test']);
        File(p.join(root.path, '.dart_tool', 'rask', 'entrypoint.d'))
            .deleteSync();
        final r2 = FakeCompiler(root: root.path);
        await launcher(r: r2).run(['test']);
        expect(r2.compiles, 1);
      },
    );

    test('recompiles when the SDK version changes', () async {
      await launcher().run(['test']);
      final r2 = FakeCompiler(root: root.path);
      await Launcher(
        cwd: root,
        runner: r2,
        err: err,
        sdkVersion: '3.14.0',
        builtin: (_) async => 0,
      ).run(['test']);
      expect(r2.compiles, 1);
    });

    test('rewrites a tampered entrypoint.dart', () async {
      await launcher().run(['test']);
      entrypoint().writeAsStringSync('// tampered');
      await launcher(r: FakeCompiler(root: root.path)).run(['test']);
      expect(entrypoint().readAsStringSync(), entrypointSource);
    });
  });

  group('compile failure', () {
    test('prints the compiler output and exits 64', () async {
      final r = FakeCompiler(
        root: root.path,
        compileExitCode: 254,
        compileOutput: 'rask.dart:2:7: Error: boom\n',
      );
      expect(await launcher(r: r).run(['test']), 64);
      expect(err.toString(), contains('Error: boom'));
      expect(r.calls.where((c) => c.$1 == exe()), isEmpty);
    });

    test('explains the config convention when config is undefined', () async {
      final r = FakeCompiler(
        root: root.path,
        compileExitCode: 254,
        compileOutput:
            "entrypoint.dart:8:10: Error: Undefined name 'config'.\n",
      );
      await launcher(r: r).run(['test']);
      expect(err.toString(), contains('final config = defineConfig('));
    });

    test('does not record a key after a failed compile', () async {
      final r = FakeCompiler(root: root.path, compileExitCode: 1);
      await launcher(r: r).run(['test']);
      expect(keyFile().existsSync(), isFalse);
    });

    test('the exe path is not written until the compile succeeds', () async {
      final r = FakeCompiler(root: root.path, compileExitCode: 1);
      await launcher(r: r).run(['test']);
      expect(File(exe()).existsSync(), isFalse);
      expect(leftoverTmps(), isEmpty);
    });

    test('a stale key is removed before compiling', () async {
      write('.dart_tool/rask/entrypoint.key', 'bogus-key');
      write('.dart_tool/rask/entrypoint.d', 'entrypoint.exe: rask.dart\n');
      write('.dart_tool/rask/entrypoint.exe', '#!stale exe\n');
      final r = FakeCompiler(root: root.path, compileExitCode: 1);
      await launcher(r: r).run(['test']);
      expect(r.compiles, 1);
      expect(keyFile().existsSync(), isFalse);
    });
  });

  group('exec failure', () {
    test('an exe that cannot be started is reported and exits 70', () async {
      final r = FakeCompiler(root: root.path, failExec: true);
      expect(await launcher(r: r).run(['test']), 70);
      expect(
        err.toString(),
        allOf(contains('entrypoint.exe'), contains('Exec format error')),
      );
    });
  });
}
