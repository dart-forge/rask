import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  void writePubspec(String relDir, String yaml) {
    final dir = Directory(p.join(root.path, relDir))..createSync(recursive: true);
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(yaml);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_ws_');
    writePubspec('.', '''
name: _
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - packages/*
  - tools/release
''');
    writePubspec('packages/tmp1', '''
name: tmp1
resolution: workspace
environment:
  sdk: ^3.13.0
dependencies:
  tmp2: ^0.0.1
  tmp3:
    path: ../tmp3
  args: ^2.7.0
dev_dependencies:
  tmp4: any
''');
    writePubspec('packages/tmp2', 'name: tmp2\nresolution: workspace\n');
    writePubspec('packages/tmp3', '''
name: tmp3
resolution: workspace
dependencies:
  tmp4:
    path: ../tmp4
''');
    writePubspec('packages/tmp4', 'name: tmp4\nresolution: workspace\n');
    writePubspec('tools/release', 'name: release\nresolution: workspace\n');
    // a directory matched by the glob that is not a package
    Directory(p.join(root.path, 'packages', 'notes')).createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('expands workspace globs and lists members by name', () {
    final ws = Workspace.load(root);
    expect(ws.packages.map((pkg) => pkg.name),
        unorderedEquals(['tmp1', 'tmp2', 'tmp3', 'tmp4', 'release']));
  });

  test('skips glob matches that have no pubspec.yaml', () {
    final ws = Workspace.load(root);
    expect(ws.packages.map((pkg) => pkg.name), isNot(contains('notes')));
  });

  test('member paths are absolute and point at the package directory', () {
    final ws = Workspace.load(root);
    expect(ws['tmp3'].path, p.join(root.path, 'packages', 'tmp3'));
    expect(p.isAbsolute(ws['tmp3'].path), isTrue);
  });

  test('internal dependencies include dependencies and dev_dependencies, '
      'regardless of source, and exclude hosted packages', () {
    final ws = Workspace.load(root);
    expect(ws['tmp1'].dependencies, unorderedEquals(['tmp2', 'tmp3', 'tmp4']));
    expect(ws['tmp3'].dependencies, ['tmp4']);
    expect(ws['tmp2'].dependencies, isEmpty);
  });

  test('inOrder lists packages so that dependencies come first', () {
    final names = Workspace.load(root).inOrder.map((pkg) => pkg.name).toList();
    expect(names.indexOf('tmp4'), lessThan(names.indexOf('tmp3')));
    expect(names.indexOf('tmp3'), lessThan(names.indexOf('tmp1')));
    expect(names.indexOf('tmp2'), lessThan(names.indexOf('tmp1')));
  });

  test('dependents lists packages that depend on a package, transitively', () {
    final ws = Workspace.load(root);
    expect(ws.dependentsOf('tmp4').map((pkg) => pkg.name),
        unorderedEquals(['tmp3', 'tmp1']));
    expect(ws.dependentsOf('tmp1'), isEmpty);
  });

  test('findRoot walks up from a member directory to the workspace root', () {
    final found = Workspace.findRoot(Directory(p.join(root.path, 'packages', 'tmp3')));
    expect(found?.path, root.path);
  });

  test('findRoot returns null when no workspace root exists', () {
    final lonely = Directory.systemTemp.createTempSync('rask_lonely_');
    addTearDown(() => lonely.deleteSync(recursive: true));
    expect(Workspace.findRoot(lonely), isNull);
  });

  group('nested workspaces (pub flattens them into the top-level root)', () {
    setUp(() {
      writePubspec('example', '''
name: example_workspace
resolution: workspace
workspace:
  - packages/*
''');
      writePubspec('example/packages/ex1', 'name: ex1\nresolution: workspace\n');
      writePubspec('example/packages/ex2', '''
name: ex2
resolution: workspace
dependencies:
  ex1: any
  tmp4: any
''');
      // add the nested root to the top-level workspace list
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: _
workspace:
  - packages/*
  - tools/release
  - example
''');
    });

    test('members of a nested workspace become members of the top-level one', () {
      final ws = Workspace.load(root);
      expect(ws.packages.map((pkg) => pkg.name),
          containsAll(['example_workspace', 'ex1', 'ex2', 'tmp4']));
    });

    test('dependency edges cross nested boundaries', () {
      final ws = Workspace.load(root);
      expect(ws['ex2'].dependencies, unorderedEquals(['ex1', 'tmp4']));
    });

    test('findRoot from inside a nested workspace returns the top-level root', () {
      final from = Directory(p.join(root.path, 'example', 'packages', 'ex1'));
      expect(Workspace.findRoot(from)?.path, root.path);
    });

    test('findRoot from the nested root itself returns the top-level root', () {
      expect(Workspace.findRoot(Directory(p.join(root.path, 'example')))?.path, root.path);
    });
  });

  group('a top-level root nested under another workspace (e.g. a git worktree)', () {
    // <root>/.claude/worktrees/wt/ is its own workspace root: it has a
    // `workspace:` section but NO `resolution: workspace`, so pub treats it
    // as a top-level root, not as a member of <root>.
    late Directory wt;
    setUp(() {
      wt = Directory(p.join(root.path, '.claude', 'worktrees', 'wt'));
      writePubspec('.claude/worktrees/wt', 'name: _\nworkspace:\n  - packages/*\n');
      writePubspec('.claude/worktrees/wt/packages/tmp1', 'name: tmp1\nresolution: workspace\n');
    });

    test('findRoot from inside the nested top-level root stops there', () {
      final from = Directory(p.join(wt.path, 'packages', 'tmp1'));
      expect(Workspace.findRoot(from)?.path, wt.path);
    });

    test('findRoot from the nested top-level root itself returns it', () {
      expect(Workspace.findRoot(wt)?.path, wt.path);
    });

    test('a genuinely nested workspace (resolution: workspace) still resolves to the outer root', () {
      writePubspec('.claude/worktrees/wt', 'name: _\nresolution: workspace\nworkspace:\n  - packages/*\n');
      final from = Directory(p.join(wt.path, 'packages', 'tmp1'));
      expect(Workspace.findRoot(from)?.path, root.path);
    });
  });

  test('a root without a workspace section is a single-package workspace', () {
    final single = Directory.systemTemp.createTempSync('rask_single_');
    addTearDown(() => single.deleteSync(recursive: true));
    File(p.join(single.path, 'pubspec.yaml'))
        .writeAsStringSync('name: solo\nenvironment:\n  sdk: ^3.13.0\n');
    final ws = Workspace.load(single);
    expect(ws.packages.map((pkg) => pkg.name), ['solo']);
    expect(Workspace.findRoot(single)?.path, single.path);
  });
}
