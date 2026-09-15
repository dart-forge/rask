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
    write(
      'packages/tmp1/pubspec.yaml',
      'name: tmp1\ndependencies:\n  tmp3: any\n',
    );
    write('packages/tmp1/lib/a.dart', 'int a = 1;');
    write('packages/tmp2/pubspec.yaml', 'name: tmp2\n');
    write('packages/tmp2/lib/b.dart', 'int b = 2;');
    write(
      'packages/tmp3/pubspec.yaml',
      'name: tmp3\ndependencies:\n  tmp4: any\n',
    );
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

  String key1() =>
      cache().keyForTask(package: ws['tmp1'], task: 'test', args: const []);

  group('keyForTask (general properties)', () {
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
      write(
        'pubspec.yaml',
        'name: _\nworkspace:\n  - packages/*\ndependencies:\n  args: any\n',
      );
      ws = Workspace.load(root);
      expect(key1(), isNot(before));
    });

    test('changes with the Dart SDK version', () {
      expect(
        cache(sdk: '3.14.0')
            .keyForTask(package: ws['tmp1'], task: 'test', args: const []),
        isNot(key1()),
      );
    });

    test('differs between packages with identical contents', () {
      write('packages/tmp2/lib/b.dart', 'int d = 4;');
      File(p.join(root.path, 'packages/tmp2/lib/b.dart'))
          .renameSync(p.join(root.path, 'packages/tmp2/lib/d.dart'));
      write(
        'packages/tmp2/pubspec.yaml',
        'name: tmp4\n',
      ); // now byte-identical to tmp4
      ws = Workspace.load(root);
      // two members named tmp4 is a broken workspace; we only care that the
      // key is not derived from contents alone
      final c = cache();
      final keys = ws.packages
          .where((x) => x.name == 'tmp4')
          .map((x) => c.keyForTask(package: x, task: 'test', args: const []))
          .toSet();
      expect(keys, hasLength(2));
    });
  });

  group('v2: keyForTask / outputsHash / isFresh / storeTask', () {
    String key({
      List<String>? inputs,
      List<String> outputs = const [],
      List<String> dependsOnKeys = const [],
      String configKey = '',
      List<String> args = const [],
      String task = 'codegen',
    }) => cache().keyForTask(
      package: ws['tmp1'],
      task: task,
      args: args,
      inputs: inputs,
      outputs: outputs,
      dependsOnKeys: dependsOnKeys,
      configKey: configKey,
    );

    test('changes with task, args, configKey and dependsOn keys', () {
      final base = key();
      expect(key(task: 'other'), isNot(base));
      expect(key(args: ['-v']), isNot(base));
      expect(key(configKey: 'abc'), isNot(base));
      expect(key(dependsOnKeys: ['k1']), isNot(base));
      expect(
        key(dependsOnKeys: ['k1', 'k2']),
        key(dependsOnKeys: ['k2', 'k1']),
      ); // order-free
    });

    test('inputs narrow the package files that matter', () {
      write('packages/tmp1/README.md', 'a');
      final before = key(inputs: ['lib/**']);
      write('packages/tmp1/README.md', 'b');
      expect(key(inputs: ['lib/**']), before); // README is not an input
      write('packages/tmp1/lib/a.dart', 'int a = 9;');
      expect(key(inputs: ['lib/**']), isNot(before));
    });

    test('inputs do not narrow dependency packages', () {
      final before = key(inputs: ['lib/**']);
      write('packages/tmp4/README.md', 'changed'); // tmp1 -> tmp3 -> tmp4
      expect(key(inputs: ['lib/**']), isNot(before));
    });

    test('the task\'s own outputs are excluded from its inputs', () {
      write('packages/tmp1/lib/a.g.dart', '// gen 1');
      final before = key(outputs: ['lib/**.g.dart']);
      write('packages/tmp1/lib/a.g.dart', '// gen 2');
      expect(key(outputs: ['lib/**.g.dart']), before);
      // but without declaring outputs the generated file counts
      final k1 = key();
      write('packages/tmp1/lib/a.g.dart', '// gen 3');
      expect(key(), isNot(k1));
    });

    test('outputsHash is empty without outputs and tracks matching files', () {
      expect(cache().outputsHash(ws['tmp1'], const []), '');
      final none = cache().outputsHash(ws['tmp1'], ['lib/**.g.dart']);
      write('packages/tmp1/lib/a.g.dart', '// gen');
      final one = cache().outputsHash(ws['tmp1'], ['lib/**.g.dart']);
      expect(one, isNot(none));
      write('packages/tmp1/lib/a.g.dart', '// gen changed');
      expect(cache().outputsHash(ws['tmp1'], ['lib/**.g.dart']), isNot(one));
    });

    test('isFresh is false until stored, true after, and false again when outputs change', () {
      write('packages/tmp1/lib/a.g.dart', '// gen');
      const outputs = ['lib/**.g.dart'];
      final k = key(outputs: outputs);
      expect(
        cache().isFresh(k, package: ws['tmp1'], outputs: outputs),
        isFalse,
      );
      cache().storeTask(
        k,
        package: ws['tmp1'],
        task: 'codegen',
        outputs: outputs,
      );
      expect(cache().isFresh(k, package: ws['tmp1'], outputs: outputs), isTrue);
      File(p.join(root.path, 'packages/tmp1/lib/a.g.dart'))
          .deleteSync(); // fresh clone
      expect(
        cache().isFresh(k, package: ws['tmp1'], outputs: outputs),
        isFalse,
      );
    });

    test('storeTask records task and outputsHash in the entry', () {
      final k = key();
      cache().storeTask(
        k,
        package: ws['tmp1'],
        task: 'codegen',
        outputs: const [],
      );
      final entry = File(p.join(root.path, '.dart_tool', 'rask', 'cache', k))
          .readAsStringSync();
      expect(
        entry,
        allOf(contains('"task":"codegen"'), contains('"outputsHash":""')),
      );
    });

    test('outputsHash sees files under build/ and .dart_tool/', () {
      final beforeBuild = cache().outputsHash(ws['tmp1'], ['build/**']);
      write('packages/tmp1/build/out.js', 'console.log(1);');
      expect(cache().outputsHash(ws['tmp1'], ['build/**']), isNot(beforeBuild));

      final beforeDartTool = cache().outputsHash(ws['tmp1'], ['.dart_tool/**']);
      write('packages/tmp1/.dart_tool/out.g.dart', '// generated');
      expect(
        cache().outputsHash(ws['tmp1'], ['.dart_tool/**']),
        isNot(beforeDartTool),
      );
    });

    test('isFresh goes false once a build/ output is deleted', () {
      write('packages/tmp1/build/out.js', 'console.log(1);');
      const outputs = ['build/**'];
      final k = key(outputs: outputs);
      cache().storeTask(
        k,
        package: ws['tmp1'],
        task: 'build',
        outputs: outputs,
      );
      expect(cache().isFresh(k, package: ws['tmp1'], outputs: outputs), isTrue);
      Directory(p.join(root.path, 'packages/tmp1/build'))
          .deleteSync(recursive: true);
      expect(
        cache().isFresh(k, package: ws['tmp1'], outputs: outputs),
        isFalse,
      );
    });
  });

  group('generated directories', () {
    String genDir(String name) =>
        p.join(root.path, '.dart_tool', 'rask', 'gen', name);

    void writeGen(String name, String rel, String content) {
      final f = File(p.join(genDir(name), rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    test('inputDirs change the key when the generated code changes', () {
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 1;');
      String key() => cache().keyForTask(
        package: ws['tmp1'],
        task: 'test',
        args: const [],
        inputDirs: [genDir('tmp1_gen')],
      );
      final before = key();
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 2;');
      expect(key(), isNot(before));
    });

    test(
      'inputDirs are part of the key, so the same task without them differs',
      () {
        writeGen('tmp1_gen', 'lib/g.dart', 'int g = 1;');
        final withDir = cache().keyForTask(
          package: ws['tmp1'],
          task: 'test',
          args: const [],
          inputDirs: [genDir('tmp1_gen')],
        );
        final without = cache().keyForTask(
          package: ws['tmp1'],
          task: 'test',
          args: const [],
        );
        expect(withDir, isNot(without));
      },
    );

    test('a generating task is not invalidated by its own output', () {
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 1;');
      String key() => cache().keyForTask(
        package: ws['tmp1'],
        task: 'codegen',
        args: const [],
      );
      final before = key();
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 2;');
      expect(key(), before);
    });

    test('outputDirs make a hit stale when the generated tree changes', () {
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 1;');
      final c = cache();
      final key = c.keyForTask(
        package: ws['tmp1'],
        task: 'codegen',
        args: const [],
      );
      c.storeTask(
        key,
        package: ws['tmp1'],
        task: 'codegen',
        outputs: const [],
        outputDirs: [genDir('tmp1_gen')],
      );
      expect(
        c.isFresh(
          key,
          package: ws['tmp1'],
          outputs: const [],
          outputDirs: [genDir('tmp1_gen')],
        ),
        isTrue,
      );
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 2;');
      expect(
        c.isFresh(
          key,
          package: ws['tmp1'],
          outputs: const [],
          outputDirs: [genDir('tmp1_gen')],
        ),
        isFalse,
      );
    });

    test('outputDirs make a hit stale when the generated package is gone', () {
      writeGen('tmp1_gen', 'lib/g.dart', 'int g = 1;');
      final c = cache();
      final key = c.keyForTask(
        package: ws['tmp1'],
        task: 'codegen',
        args: const [],
      );
      c.storeTask(
        key,
        package: ws['tmp1'],
        task: 'codegen',
        outputs: const [],
        outputDirs: [genDir('tmp1_gen')],
      );
      Directory(genDir('tmp1_gen')).deleteSync(recursive: true);
      expect(
        c.isFresh(
          key,
          package: ws['tmp1'],
          outputs: const [],
          outputDirs: [genDir('tmp1_gen')],
        ),
        isFalse,
      );
    });

    test('order of inputDirs does not matter', () {
      writeGen('a_gen', 'lib/a.dart', 'int a = 1;');
      writeGen('b_gen', 'lib/b.dart', 'int b = 1;');
      String key(List<String> dirs) => cache().keyForTask(
        package: ws['tmp1'],
        task: 'test',
        args: const [],
        inputDirs: dirs,
      );
      expect(
        key([genDir('a_gen'), genDir('b_gen')]),
        key([genDir('b_gen'), genDir('a_gen')]),
      );
    });
  });
}
