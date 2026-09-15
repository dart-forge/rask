import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Workspace ws;

  void put(String rel, String yaml) {
    final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
    File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_packages_for_');
    // app -> lib_a -> core ; lone has no dependencies at all.
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/app', 'name: app\ndependencies:\n  lib_a: any\n');
    put('packages/lib_a', 'name: lib_a\ndependencies:\n  core: any\n');
    put('packages/core', 'name: core\n');
    put('packages/lone', 'name: lone\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a bare name gives exactly the target\'s own package', () {
    expect(packagesForDependsOn('codegen', ws['app'], ws), [same(ws['app'])]);
  });

  test(
    'a ^ name gives the transitive dependencies, not the package itself',
    () {
      expect(
        packagesForDependsOn('^codegen', ws['app'], ws),
        unorderedEquals([same(ws['lib_a']), same(ws['core'])]),
      );
    },
  );

  test('a ^ name in a package with no dependencies gives an empty list', () {
    expect(packagesForDependsOn('^codegen', ws['lone'], ws), isEmpty);
  });
}
