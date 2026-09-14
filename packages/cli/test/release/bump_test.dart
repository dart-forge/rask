import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/release/bump.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  group('isValidVersion', () {
    test('accepts semver with optional pre-release and build', () {
      expect(isValidVersion('0.2.0'), isTrue);
      expect(isValidVersion('1.0.0-beta.1'), isTrue);
      expect(isValidVersion('1.0.0+3'), isTrue);
    });
    test('rejects everything else', () {
      expect(isValidVersion('v0.2.0'), isFalse);
      expect(isValidVersion('0.2'), isFalse);
      expect(isValidVersion(''), isFalse);
    });
  });

  group('setVersion', () {
    test('rewrites version: and keeps everything else, comments included', () {
      const src = '''
name: aim_core
# keep me
version: 0.1.1   # trailing
environment:
  sdk: ^3.13.0
''';
      expect(setVersion(src, '0.2.0'), '''
name: aim_core
# keep me
version: 0.2.0   # trailing
environment:
  sdk: ^3.13.0
''');
    });
  });

  group('bumpInternalConstraints', () {
    const members = {'aim_core', 'aim_server', 'aim_orm'};
    const src = '''
name: aim_server
version: 0.1.1
dependencies:
  aim_core: ^0.1.1
  args: ^2.7.0
  aim_orm:
    path: ../aim_orm
dev_dependencies:
  aim_server_testing: ^0.1.1
  test: ^1.25.6
''';

    test('rewrites string constraints of workspace members to ^version', () {
      final out = bumpInternalConstraints(src, members, '0.2.0');
      expect(out, contains('  aim_core: ^0.2.0\n'));
    });

    test('leaves hosted non-members, path-valued members and unknown names alone', () {
      final out = bumpInternalConstraints(src, members, '0.2.0');
      expect(out, contains('  args: ^2.7.0\n'));
      expect(out, contains('  aim_orm:\n    path: ../aim_orm\n'));
      expect(out, contains('  aim_server_testing: ^0.1.1\n')); // not in members
      expect(out, contains('version: 0.1.1\n')); // untouched here
    });

    test('also rewrites dev_dependencies', () {
      final out = bumpInternalConstraints(src, {...members, 'aim_server_testing'}, '0.2.0');
      expect(out, contains('  aim_server_testing: ^0.2.0\n'));
    });

    test('returns the input unchanged when there is nothing to do', () {
      const plain = 'name: x\ndependencies:\n  args: ^2.7.0\n';
      expect(bumpInternalConstraints(plain, members, '0.2.0'), plain);
    });
  });

  group('foldChangelog', () {
    test('renames ## Unreleased to the version, keeping its entries', () {
      const src = '# Changelog\n\n## Unreleased\n\n- Added X.\n\n## 0.1.0\n\n- First.\n';
      expect(foldChangelog(src, '0.2.0'),
          '# Changelog\n\n## 0.2.0\n\n- Added X.\n\n## 0.1.0\n\n- First.\n');
    });

    test('matches Unreleased case-insensitively and with trailing spaces', () {
      expect(foldChangelog('## unreleased  \n- a\n', '0.2.0'), '## 0.2.0\n- a\n');
    });

    test('leaves the file alone when the version heading already exists', () {
      const src = '# Changelog\n\n## 0.2.0\n\n- Done.\n';
      expect(foldChangelog(src, '0.2.0'), src);
    });

    test('inserts a heading after the title when there is no Unreleased section', () {
      const src = '# Changelog\n\n## 0.1.0\n\n- First.\n';
      expect(foldChangelog(src, '0.2.0'), '# Changelog\n\n## 0.2.0\n\n## 0.1.0\n\n- First.\n');
    });

    test('inserts at the top when there is no title', () {
      expect(foldChangelog('## 0.1.0\n', '0.2.0'), '## 0.2.0\n\n## 0.1.0\n');
    });
  });

  group('bumpWorkspace', () {
    late Directory root;
    void write(String rel, String content) {
      final f = File(p.join(root.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }
    String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();

    setUp(() {
      root = Directory.systemTemp.createTempSync('rask_bump_');
      write('pubspec.yaml', 'name: _\npublish_to: none\nworkspace:\n  - packages/*\n  - examples/*\n');
      write('packages/core/pubspec.yaml', 'name: core\nversion: 0.1.1\n');
      write('packages/core/CHANGELOG.md', '# Changelog\n\n## Unreleased\n\n- New.\n');
      write('packages/server/pubspec.yaml',
          'name: server\nversion: 0.1.1\ndependencies:\n  core: ^0.1.1\n');
      write('packages/server/CHANGELOG.md', '# Changelog\n\n## 0.1.1\n\n- Old.\n');
      write('examples/demo/pubspec.yaml',
          'name: demo\npublish_to: none\ndependencies:\n  server: ^0.1.1\n  core:\n    path: ../../packages/core\n');
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('sets the version of every publishable member', () {
      bumpWorkspace(Workspace.load(root), '0.2.0', StringBuffer());
      expect(read('packages/core/pubspec.yaml'), contains('version: 0.2.0'));
      expect(read('packages/server/pubspec.yaml'), contains('version: 0.2.0'));
    });

    test('does not add a version to non-publishable members, but bumps their constraints', () {
      bumpWorkspace(Workspace.load(root), '0.2.0', StringBuffer());
      final demo = read('examples/demo/pubspec.yaml');
      expect(demo, isNot(contains('version:')));
      expect(demo, contains('  server: ^0.2.0\n'));
      expect(demo, contains('    path: ../../packages/core\n'));
    });

    test('bumps constraints between publishable members', () {
      bumpWorkspace(Workspace.load(root), '0.2.0', StringBuffer());
      expect(read('packages/server/pubspec.yaml'), contains('  core: ^0.2.0\n'));
    });

    test('folds each publishable member\'s CHANGELOG', () {
      bumpWorkspace(Workspace.load(root), '0.2.0', StringBuffer());
      expect(read('packages/core/CHANGELOG.md'), contains('## 0.2.0\n\n- New.'));
      expect(read('packages/server/CHANGELOG.md'), startsWith('# Changelog\n\n## 0.2.0\n\n## 0.1.1'));
    });

    test('does not create a CHANGELOG where there is none', () {
      File(p.join(root.path, 'packages/core/CHANGELOG.md')).deleteSync();
      bumpWorkspace(Workspace.load(root), '0.2.0', StringBuffer());
      expect(File(p.join(root.path, 'packages/core/CHANGELOG.md')).existsSync(), isFalse);
    });

    test('reports what it changed and returns the changed files', () {
      final out = StringBuffer();
      final changed = bumpWorkspace(Workspace.load(root), '0.2.0', out);
      expect(changed.map((f) => p.relative(f, from: root.path)),
          unorderedEquals([
            'packages/core/pubspec.yaml',
            'packages/core/CHANGELOG.md',
            'packages/server/pubspec.yaml',
            'packages/server/CHANGELOG.md',
            'examples/demo/pubspec.yaml',
          ]));
      expect(out.toString(), contains('core: 0.1.1 → 0.2.0'));
      expect(out.toString(), contains('server: 0.1.1 → 0.2.0'));
    });
  });
}
