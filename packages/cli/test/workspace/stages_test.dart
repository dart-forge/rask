import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/stages.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_stages_');
    void put(String rel, String yaml) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
    }
    // app -> {lib_a, lib_b}; lib_a -> core; lib_b -> core; lone has no edges
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/app', 'name: app\ndependencies:\n  lib_a: any\n  lib_b: any\n');
    put('packages/lib_a', 'name: lib_a\ndependencies:\n  core: any\n');
    put('packages/lib_b', 'name: lib_b\ndev_dependencies:\n  core: any\n');
    put('packages/core', 'name: core\n');
    put('packages/lone', 'name: lone\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<List<String>> names(List<List<Package>> stages) =>
      [for (final s in stages) [for (final pkg in s) pkg.name]];

  test('packages without selected dependencies form stage 0, dependents follow one stage later', () {
    final stages = names(stagesOf(ws.inOrder, workspace: ws));
    expect(stages, hasLength(3));
    expect(stages[0], unorderedEquals(['core', 'lone']));
    expect(stages[1], unorderedEquals(['lib_a', 'lib_b']));
    expect(stages[2], ['app']);
  });

  test('every input package appears in exactly one stage', () {
    final all = names(stagesOf(ws.inOrder, workspace: ws)).expand((s) => s).toList();
    expect(all, unorderedEquals(['app', 'lib_a', 'lib_b', 'core', 'lone']));
  });

  test('a dependency that is not in the input is ignored', () {
    // -F lib_a -F app: core is not selected and imposes no wait; app still waits for lib_a
    final stages = names(stagesOf([ws['lib_a'], ws['app']], workspace: ws));
    expect(stages, [['lib_a'], ['app']]);
  });

  test('a de-selected intermediate dependency still orders its endpoints', () {
    // -F core -F app: lib_a and lib_b are not selected, but app still
    // depends on core through them, so app must wait for core.
    final stages = names(stagesOf([ws['core'], ws['app']], workspace: ws));
    expect(stages, [['core'], ['app']]);
  });

  test('preserves input order inside a stage', () {
    final stages = names(stagesOf([ws['lone'], ws['core']], workspace: ws));
    expect(stages, [['lone', 'core']]);
  });

  test('empty input gives no stages', () {
    expect(stagesOf(const [], workspace: ws), isEmpty);
  });
}
