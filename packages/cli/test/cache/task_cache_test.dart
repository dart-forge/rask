import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cache/task_cache.dart';
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
    root = Directory.systemTemp.createTempSync('rask_cache_');
    write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
    write('pubspec.lock', 'packages: {}\n');
    write('packages/tmp1/pubspec.yaml', 'name: tmp1\ndependencies:\n  tmp3: any\n');
    write('packages/tmp1/lib/a.dart', 'int a = 1;');
    write('packages/tmp2/pubspec.yaml', 'name: tmp2\n');
    write('packages/tmp2/lib/b.dart', 'int b = 2;');
    write('packages/tmp3/pubspec.yaml', 'name: tmp3\ndependencies:\n  tmp4: any\n');
    write('packages/tmp3/lib/c.dart', 'int c = 3;');
    write('packages/tmp4/pubspec.yaml', 'name: tmp4\n');
    write('packages/tmp4/lib/d.dart', 'int d = 4;');
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  TaskCache cache({String sdk = '3.13.0'}) => TaskCache(
        workspace: ws,
        directory: Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')),
        sdkVersion: sdk,
      );

  String key1() => cache().keyFor(ws['tmp1'], 'test', const []);

  group('keyFor', () {
    test('is stable across calls and instances', () {
      expect(key1(), key1());
      expect(key1(), cache().keyFor(Workspace.load(root)['tmp1'], 'test', const []));
    });

    test('changes when a file in the package changes', () {
      final before = key1();
      write('packages/tmp1/lib/a.dart', 'int a = 2;');
      expect(key1(), isNot(before));
    });

    test('changes when a file in the package is renamed', () {
      final before = key1();
      File(p.join(root.path, 'packages/tmp1/lib/a.dart'))
          .renameSync(p.join(root.path, 'packages/tmp1/lib/a2.dart'));
      expect(key1(), isNot(before));
    });

    test('changes when a file is added to the package', () {
      final before = key1();
      write('packages/tmp1/test/a_test.dart', '');
      expect(key1(), isNot(before));
    });

    test('changes when a transitive workspace dependency changes', () {
      final before = key1();
      write('packages/tmp4/lib/d.dart', 'int d = 40;'); // tmp1 -> tmp3 -> tmp4
      expect(key1(), isNot(before));
    });

    test('does not change when an unrelated package changes', () {
      final before = key1();
      write('packages/tmp2/lib/b.dart', 'int b = 20;');
      expect(key1(), before);
    });

    test('ignores .dart_tool/, build/ and .git/ inside the package', () {
      final before = key1();
      write('packages/tmp1/.dart_tool/x', 'noise');
      write('packages/tmp1/build/x', 'noise');
      write('packages/tmp1/.git/x', 'noise');
      expect(key1(), before);
    });

    test('changes when the root pubspec.lock changes', () {
      final before = key1();
      write('pubspec.lock', 'packages:\n  args: {version: 2.7.0}\n');
      expect(key1(), isNot(before));
    });

    test('changes when the root pubspec.yaml changes', () {
      final before = key1();
      write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\ndependencies:\n  args: any\n');
      ws = Workspace.load(root);
      expect(key1(), isNot(before));
    });

    test('changes with the Dart SDK version', () {
      expect(cache(sdk: '3.14.0').keyFor(ws['tmp1'], 'test', const []), isNot(key1()));
    });

    test('changes with the verb and with the arguments', () {
      final c = cache();
      expect(c.keyFor(ws['tmp1'], 'analyze', const []), isNot(key1()));
      expect(c.keyFor(ws['tmp1'], 'test', ['--reporter', 'expanded']), isNot(key1()));
    });

    test('differs between packages with identical contents', () {
      write('packages/tmp2/lib/b.dart', 'int d = 4;');
      File(p.join(root.path, 'packages/tmp2/lib/b.dart'))
          .renameSync(p.join(root.path, 'packages/tmp2/lib/d.dart'));
      write('packages/tmp2/pubspec.yaml', 'name: tmp4\n'); // now byte-identical to tmp4
      ws = Workspace.load(root);
      // two members named tmp4 is a broken workspace; we only care that the
      // key is not derived from contents alone
      final c = cache();
      final keys = ws.packages.where((x) => x.name == 'tmp4').map((x) => c.keyFor(x, 'test', const [])).toSet();
      expect(keys, hasLength(2));
    });
  });

  group('contains / store', () {
    test('a key is absent until stored, then present, and persists on disk', () {
      final k = key1();
      expect(cache().contains(k), isFalse);
      cache().store(k, package: ws['tmp1'], verb: 'test');
      expect(cache().contains(k), isTrue);
      expect(Directory(p.join(root.path, '.dart_tool', 'rask', 'cache')).listSync(), isNotEmpty);
    });

    test('store creates the cache directory on demand', () {
      final dir = Directory(p.join(root.path, '.dart_tool', 'rask', 'cache'));
      expect(dir.existsSync(), isFalse);
      cache().store(key1(), package: ws['tmp1'], verb: 'test');
      expect(dir.existsSync(), isTrue);
    });
  });
}
