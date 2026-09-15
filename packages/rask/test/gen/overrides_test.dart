import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/gen/overrides.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  Package pkg(String name) => Package(
    name: name,
    path: '/ws/packages/$name',
    dependencies: const [],
    pubspec: loadYaml('name: $name') as YamlMap,
  );

  GeneratedPackage gen(String name, {String producer = 'app'}) =>
      GeneratedPackage(
        name: name,
        producer: pkg(producer),
        taskName: 'codegen',
        dir: '/ws/.dart_tool/rask/gen/$name',
      );

  Map<String, String> managedOf(String yaml) {
    final doc = loadYaml(yaml) as YamlMap;
    final overrides = doc['dependency_overrides'] as YamlMap;
    return {
      for (final e in overrides.entries)
        e.key.toString(): (e.value as YamlMap)['path'].toString(),
    };
  }

  test('creates the file when there is none', () {
    final text = syncOverrides(null, [gen('app_gen')])!;
    expect(managedOf(text), {'app_gen': '.dart_tool/rask/gen/app_gen'});
    expect(text, contains('rask'));
  });

  test('treats a blank file as no file', () {
    expect(syncOverrides('\n\n', [gen('app_gen')]), isNotNull);
  });

  test('returns null when the managed entries already match', () {
    final text = syncOverrides(null, [gen('app_gen')])!;
    expect(syncOverrides(text, [gen('app_gen')]), isNull);
  });

  test('keeps entries it does not manage', () {
    const current = '''
dependency_overrides:
  rask:
    path: ../rask/packages/rask
''';
    final text = syncOverrides(current, [gen('app_gen')])!;
    expect(managedOf(text), {
      'rask': '../rask/packages/rask',
      'app_gen': '.dart_tool/rask/gen/app_gen',
    });
  });

  test('removes a managed entry that is no longer declared', () {
    const current = '''
dependency_overrides:
  rask:
    path: ../rask/packages/rask
  stale_gen:
    path: .dart_tool/rask/gen/stale_gen
''';
    final text = syncOverrides(current, [gen('app_gen')])!;
    expect(managedOf(text).keys, ['rask', 'app_gen']);
  });

  test('asks for deletion when nothing is left', () {
    const current = '''
dependency_overrides:
  stale_gen:
    path: .dart_tool/rask/gen/stale_gen
''';
    expect(syncOverrides(current, const []), '');
  });

  test('keeps the file when a foreign entry survives the last managed one', () {
    const current = '''
dependency_overrides:
  rask:
    path: ../rask/packages/rask
  stale_gen:
    path: .dart_tool/rask/gen/stale_gen
''';
    final text = syncOverrides(current, const [])!;
    expect(text, isNotEmpty);
    expect(managedOf(text), {'rask': '../rask/packages/rask'});
  });

  test('throws when a foreign entry claims a generated name', () {
    const current = '''
dependency_overrides:
  app_gen:
    path: ../somewhere/app_gen
''';
    expect(
      () => syncOverrides(current, [gen('app_gen')]),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          allOf(contains('app_gen'), contains('../somewhere/app_gen')),
        ),
      ),
    );
  });

  test('adds a dependency_overrides section when the file has none', () {
    const current = 'dependency_overrides:\n';
    final text = syncOverrides(current, [gen('app_gen')])!;
    expect(managedOf(text), {'app_gen': '.dart_tool/rask/gen/app_gen'});
  });

  test('nothing declared and no file at all is no change', () {
    expect(syncOverrides(null, const []), isNull);
  });

  test('a comments-only file gains the section and keeps its comments', () {
    const current = '''
# my local override, commented out for now
# rask:
#   path: ../rask/packages/rask
''';
    final text = syncOverrides(current, [gen('app_gen')])!;
    expect(text, startsWith(current));
    expect(managedOf(text), {'app_gen': '.dart_tool/rask/gen/app_gen'});
  });

  test('a comments-only file with nothing declared is no change', () {
    const current = '''
# my local override, commented out for now
# rask:
#   path: ../rask/packages/rask
''';
    expect(syncOverrides(current, const []), isNull);
  });

  test('a file whose content is a scalar is handled like a non-map file', () {
    const current = 'just a string\n';
    // Must not throw the PathError a scalar document used to cause; the
    // text is kept and the generated section appended, same as for a
    // comments-only file. (The scalar plus a following mapping is not
    // itself valid YAML to load back — that is the developer's file to fix,
    // not something rask can repair without destroying their content.)
    final text = syncOverrides(current, [gen('app_gen')])!;
    expect(text, startsWith(current));
    expect(text, contains('app_gen'));
    expect(text, contains('.dart_tool/rask/gen/app_gen'));

    expect(syncOverrides(current, const []), isNull);
  });
}
