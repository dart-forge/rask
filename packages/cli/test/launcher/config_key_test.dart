import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/launcher/config_key.dart';
import 'package:rask/src/launcher/entrypoint_template.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_key_');
    write('pubspec.lock', 'packages: {}\n');
    write(
      'rask.dart',
      "import 'package:rask/rask.dart';\nfinal config = defineConfig();\n",
    );
    write('rask/tasks.dart', 'const x = 1;');
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('entrypoint template', () {
    test('imports package:rask/rask.dart and ../../rask.dart, forwards RASK_CONFIG_KEY', () {
      expect(entrypointSource, contains("import 'package:rask/rask.dart';"));
      expect(entrypointSource, contains("import '../../rask.dart' as user;"));
      expect(
        entrypointSource,
        contains("Platform.environment['RASK_CONFIG_KEY']"),
      );
      expect(entrypointSource, contains('runRask(args, user.config'));
      expect(entrypointTemplateVersion, 1);
    });
  });

  group('localDepfileInputs', () {
    test('keeps root-relative posix paths of files under root, sorted and unique', () {
      final r = root.path;
      final depfile =
          '$r/.dart_tool/rask/entrypoint.exe: $r/rask/tasks.dart $r/rask.dart '
          '/opt/dart-sdk/lib/core/core.dart /home/me/.pub-cache/hosted/pub.dev/args-2.7.0/lib/args.dart '
          '$r/.dart_tool/package_config.json $r/rask.dart\n';
      expect(
        localDepfileInputs(
          depfile,
          root: r,
          excludeRoots: const ['/opt/dart-sdk', '/home/me/.pub-cache'],
        ),
        ['.dart_tool/package_config.json', 'rask.dart', 'rask/tasks.dart'],
      );
    });

    test('keeps an out-of-root path dependency as an absolute path', () {
      final r = root.path;
      final depfile =
          '$r/out.exe: $r/rask.dart /elsewhere/plugin/lib/plugin.dart\n';
      expect(localDepfileInputs(depfile, root: r), [
        '/elsewhere/plugin/lib/plugin.dart',
        'rask.dart',
      ]);
    });

    test('drops files under an exclude root', () {
      final r = root.path;
      final depfile =
          '$r/out.exe: $r/rask.dart '
          '/home/me/.pub-cache/hosted/pub.dev/args-2.7.0/lib/args.dart\n';
      expect(
        localDepfileInputs(
          depfile,
          root: r,
          excludeRoots: const ['/home/me/.pub-cache'],
        ),
        ['rask.dart'],
      );
    });

    test('handles backslash line continuations', () {
      final r = root.path;
      final depfile =
          '$r/.dart_tool/rask/entrypoint.exe: \\\n  $r/rask.dart \\\n  $r/rask/tasks.dart\n';
      expect(localDepfileInputs(depfile, root: r), [
        'rask.dart',
        'rask/tasks.dart',
      ]);
    });

    test('resolves a relative entry against root, not the process cwd', () {
      expect(localDepfileInputs('out.exe: rask.dart\n', root: root.path), [
        'rask.dart',
      ]);
    });

    test('returns an empty list for an empty depfile', () {
      expect(localDepfileInputs('', root: root.path), isEmpty);
    });

    test('unescapes backslash-space in paths', () {
      final r = root.path;
      final depfile = '$r/out.exe: $r/with\\ space/rask.dart $r/rask.dart\n';
      expect(localDepfileInputs(depfile, root: r), [
        'rask.dart',
        'with space/rask.dart',
      ]);
    });

    test('a root path containing a space', () {
      final spaceRoot = Directory.systemTemp.createTempSync('rask key ');
      addTearDown(() => spaceRoot.deleteSync(recursive: true));
      final rr = spaceRoot.path;
      File(p.join(rr, 'rask.dart')).writeAsStringSync('const x = 1;');
      final escapedRoot = rr.replaceAll(' ', '\\ ');
      final depfile = '$escapedRoot/out.exe: $escapedRoot/rask.dart\n';
      expect(localDepfileInputs(depfile, root: rr), ['rask.dart']);
    });

    test('unescapes backslash-hash and double backslash', () {
      final r = root.path;
      final depfile = 'out: $r/a\\#b.dart $r/c\\\\d.dart\n';
      expect(localDepfileInputs(depfile, root: r), ['a#b.dart', 'c\\d.dart']);
    });
  });

  group('computeConfigKey', () {
    String key({
      List<String>? inputs,
      String sdk = '3.13.0',
      int template = 1,
    }) => computeConfigKey(
      root: root,
      localInputs: inputs ?? ['rask.dart', 'rask/tasks.dart'],
      sdkVersion: sdk,
      templateVersion: template,
    );

    test('is stable', () => expect(key(), key()));
    test('changes when rask.dart changes', () {
      final before = key();
      write(
        'rask.dart',
        "import 'package:rask/rask.dart';\nfinal config = defineConfig(tasks: []);\n",
      );
      expect(key(), isNot(before));
    });
    test('changes when an imported local file changes', () {
      final before = key();
      write('rask/tasks.dart', 'const x = 2;');
      expect(key(), isNot(before));
    });
    test('changes when pubspec.lock changes', () {
      final before = key();
      write('pubspec.lock', 'packages:\n  args: {version: 2.7.0}\n');
      expect(key(), isNot(before));
    });
    test('changes with the SDK version and the template version', () {
      expect(key(sdk: '3.14.0'), isNot(key()));
      expect(key(template: 2), isNot(key()));
    });
    test('changes when a listed file disappears', () {
      final before = key();
      File(p.join(root.path, 'rask/tasks.dart')).deleteSync();
      expect(key(), isNot(before));
    });
    test('changes when an absolute (out-of-root) input changes', () {
      final other = Directory.systemTemp.createTempSync('rask_key_other_');
      addTearDown(() => other.deleteSync(recursive: true));
      final plugin = File(p.join(other.path, 'plugin.dart'))
        ..writeAsStringSync('const p = 1;');
      final inputs = ['rask.dart', p.posix.joinAll(p.split(plugin.path))];
      final before = key(inputs: inputs);
      plugin.writeAsStringSync('const p = 2;');
      expect(key(inputs: inputs), isNot(before));
    });

    test('does not depend on unrelated files', () {
      final before = key();
      write('README.md', 'x');
      expect(key(), before);
    });
  });
}
