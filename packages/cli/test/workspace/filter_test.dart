import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/filter.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_filter_');
    void put(String rel, String yaml) {
      final d = Directory(p.join(root.path, rel))..createSync(recursive: true);
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync(yaml);
    }
    put('.', 'name: _\nworkspace:\n  - packages/*\n');
    put('packages/tmp1', 'name: tmp1\ndependencies:\n  tmp2: any\n  tmp3: any\n');
    put('packages/tmp2', 'name: tmp2\n');
    put('packages/tmp3', 'name: tmp3\ndependencies:\n  tmp4: any\n');
    put('packages/tmp4', 'name: tmp4\n');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> names(Iterable<Package> pkgs) => pkgs.map((x) => x.name).toList();

  test('no filter selects every package in dependency order', () {
    final selected = names(selectPackages(ws, const []));
    expect(selected, hasLength(4));
    expect(selected.indexOf('tmp4'), lessThan(selected.indexOf('tmp3')));
    expect(selected.indexOf('tmp3'), lessThan(selected.indexOf('tmp1')));
  });

  test('a bare name selects only that package', () {
    expect(names(selectPackages(ws, ['tmp3'])), ['tmp3']);
  });

  test('name... selects the package and everything that depends on it', () {
    expect(names(selectPackages(ws, ['tmp4...'])), ['tmp4', 'tmp3', 'tmp1']);
  });

  test('...name selects the package and everything it depends on', () {
    expect(names(selectPackages(ws, ['...tmp3'])), ['tmp4', 'tmp3']);
  });

  test('multiple filters union, still in dependency order', () {
    expect(names(selectPackages(ws, ['tmp2', 'tmp4'])), ['tmp2', 'tmp4']);
  });

  test('unknown package name is an error', () {
    expect(() => selectPackages(ws, ['nope']),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('nope'))));
  });
}
