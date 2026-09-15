import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_graph.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Workspace ws;

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_gen_');
    write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
    write(
      'packages/app/pubspec.yaml',
      'name: app\ndependencies:\n  my_orm: any\n',
    );
    write('packages/plain/pubspec.yaml', 'name: plain\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  ResolvedConfig configWith(Task task) =>
      resolveConfig(defineConfig(tasks: [task]));

  Task codegen({
    String Function(Package pkg)? generates,
    bool Function(Package pkg)? where,
  }) => Task(
    'codegen',
    where: where,
    run: (_) async {},
    generates: generates ?? ((pkg) => '${pkg.name}_gen'),
  );

  test('no task with generates yields nothing', () {
    final resolved = resolveConfig(
      defineConfig(tasks: [Task('x', run: (_) async {})]),
    );
    expect(resolveGeneratedPackages(resolved, ws), isEmpty);
  });

  test('one entry per package the task applies to, sorted by name', () {
    final generated = resolveGeneratedPackages(configWith(codegen()), ws);
    expect(generated.map((g) => g.name), ['app_gen', 'plain_gen']);
    expect(generated.first.producer.name, 'app');
    expect(generated.first.taskName, 'codegen');
    expect(
      generated.first.dir,
      p.join(root.path, '.dart_tool', 'rask', 'gen', 'app_gen'),
    );
    expect(generated.first.libDir, p.join(generated.first.dir, 'lib'));
    expect(generated.first.overridePath, '.dart_tool/rask/gen/app_gen');
  });

  test('where narrows which packages produce a generated package', () {
    final generated = resolveGeneratedPackages(
      configWith(codegen(where: (pkg) => pkg.dependsOn('my_orm'))),
      ws,
    );
    expect(generated.map((g) => g.name), ['app_gen']);
  });

  test('rejects a name that is not a package name', () {
    expect(
      () => resolveGeneratedPackages(
        configWith(codegen(generates: (pkg) => '${pkg.name}-gen')),
        ws,
      ),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          allOf(contains('app-gen'), contains('codegen')),
        ),
      ),
    );
  });

  test('rejects two packages generating the same name', () {
    expect(
      () => resolveGeneratedPackages(
        configWith(codegen(generates: (pkg) => 'shared_gen')),
        ws,
      ),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          allOf(contains('shared_gen'), contains('app'), contains('plain')),
        ),
      ),
    );
  });

  test('rejects a name that collides with a workspace member', () {
    expect(
      () => resolveGeneratedPackages(
        configWith(codegen(generates: (pkg) => 'plain')),
        ws,
      ),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          contains('plain'),
        ),
      ),
    );
  });
}
