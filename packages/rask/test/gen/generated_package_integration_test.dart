@Tags(['integration'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:test/test.dart';

/// The one test that proves the mechanism end to end: a real `dart pub get`
/// picks up the generated package rask declares, and a real `dart analyze`
/// resolves an import of it from the consumer.
void main() {
  late Directory root;

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_gen_it_');
    write('pubspec.yaml', '''
name: it_root
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - packages/app
''');
    write('packages/app/pubspec.yaml', '''
name: app
publish_to: none
resolution: workspace
environment:
  sdk: ^3.13.0
''');
    // The consumer imports the package rask generates for it.
    write('packages/app/lib/app.dart', '''
import 'package:app_gen/app_gen.dart';

const answer = 42;

int callGenerated() => generated();
''');
    // The generator: writes one library into the directory it is given.
    // That library imports the consumer package back — undeclared, since
    // the generated package's stub pubspec has no dependencies — to prove
    // the workspace's single package_config.json resolves it anyway.
    write('tool/toy_gen.dart', '''
import 'dart:io';

void main(List<String> args) {
  final out = args[args.indexOf('--out') + 1];
  File('\$out/app_gen.dart').writeAsStringSync(
    "import 'package:app/app.dart';\\n\\nint generated() => answer;\\n",
  );
}
''');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('pub resolves the generated package and analyze passes', () async {
    final out = StringBuffer();
    final ws = Workspace.load(root);
    final config = resolveConfig(
      defineConfig(
        tasks: [
          Task(
            'codegen',
            generates: (pkg) => '${pkg.name}_gen',
            run: (ctx) => ctx.exec('dart', [
              'run',
              p.join(ctx.workspace.root.path, 'tool', 'toy_gen.dart'),
              '--out',
              ctx.gen!,
            ]),
          ),
        ],
      ),
    );
    final generated = resolveGeneratedPackages(config, ws);
    expect(generated.map((g) => g.name), ['app_gen']);

    const runner = SystemProcessRunner();
    final ensured = await ensureGeneratedPackages(
      workspace: ws,
      generated: generated,
      runner: runner,
      out: out,
    );
    expect(ensured.pubGetExitCode, 0, reason: out.toString());

    // pub knows the generated package now.
    final packageConfig = File(
      p.join(root.path, '.dart_tool', 'package_config.json'),
    ).readAsStringSync();
    expect(packageConfig, contains('app_gen'));

    // .gitignore covers the file rask wrote.
    expect(
      File(p.join(root.path, '.gitignore')).readAsStringSync(),
      contains('pubspec_overrides.yaml'),
    );

    final graph = buildTaskGraph(
      config: config,
      task: 'codegen',
      targets: ws.packages,
      workspace: ws,
    );
    final code = await runTaskGraph(
      graph,
      workspace: ws,
      runner: runner,
      out: out,
      generated: generated,
    );
    expect(code, 0, reason: out.toString());

    // The consumer's import of the generated library resolves.
    final analyze = await Process.run('dart', [
      'analyze',
      '--fatal-infos',
      'packages/app',
    ], workingDirectory: root.path);
    expect(analyze.exitCode, 0, reason: '${analyze.stdout}\n${analyze.stderr}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
