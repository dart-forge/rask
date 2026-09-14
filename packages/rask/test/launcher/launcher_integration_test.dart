@Tags(['integration'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/launcher/launcher.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:test/test.dart';

/// The only tests that really run `dart compile exe` (D-033). They share a
/// throwaway workspace whose root depends on this very package by path and
/// holds a rask.dart with a custom task, and drive [Launcher] with the real
/// process runner.
void main() {
  late Directory root;
  final cliDir = Directory.current.path; // packages/rask

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('rask_launcher_it_');
    void write(String rel, String content) {
      final f = File(p.join(root.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    write('pubspec.yaml', '''
name: it_root
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - packages/app
dev_dependencies:
  rask:
    path: $cliDir
''');
    write(
      'packages/app/pubspec.yaml',
      'name: app\nresolution: workspace\nenvironment:\n  sdk: ^3.13.0\n',
    );
    write('packages/app/lib/app.dart', 'int one() => 1;');
    write('rask.dart', '''
import 'dart:io';

import 'package:rask/rask.dart';

final config = defineConfig(tasks: [
  Task('hello', run: (ctx) async {
    File('\${ctx.package.path}/hello.txt').writeAsStringSync('hi from \${ctx.package.name}');
    ctx.log('wrote hello.txt');
  }),
]);
''');
    final get = await Process.run('dart', [
      'pub',
      'get',
    ], workingDirectory: root.path);
    expect(get.exitCode, 0, reason: get.stderr.toString());
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  test('compiles rask.dart once, runs the custom task, then hits the compile cache', () async {
    final err = StringBuffer();
    Launcher launcher() => Launcher(
      cwd: root,
      runner: const SystemProcessRunner(),
      err: err,
      environment: Platform.environment,
    );

    expect(await launcher().run(['hello', '-F', 'app']), 0);
    expect(err.toString(), contains('compiling rask.dart'));
    final hello = File(p.join(root.path, 'packages', 'app', 'hello.txt'));
    expect(hello.existsSync(), isTrue);
    expect(hello.readAsStringSync(), 'hi from app');
    final exe = File(p.join(root.path, '.dart_tool', 'rask', 'entrypoint.exe'));
    expect(exe.existsSync(), isTrue);
    final compiledAt = exe.lastModifiedSync();

    err.clear();
    hello.deleteSync();
    expect(await launcher().run(['hello', '-F', 'app', '--no-cache']), 0);
    expect(err.toString(), isNot(contains('compiling')));
    expect(exe.lastModifiedSync(), compiledAt);
    expect(hello.existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Deliberately mutates the shared root's rask.dart, so it must run after
  // the test above (the default declaration order does that).
  test(
    'a config without `config` fails with the convention hint and exit 64',
    () async {
      File(p.join(root.path, 'rask.dart')).writeAsStringSync(
        "import 'package:rask/rask.dart';\nfinal cfg = defineConfig();\n",
      );
      final err = StringBuffer();
      final code = await Launcher(
        cwd: root,
        runner: const SystemProcessRunner(),
        err: err,
        environment: Platform.environment,
      ).run(['hello']);
      expect(code, 64);
      expect(err.toString(), contains('final config = defineConfig('));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
