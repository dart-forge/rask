import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/task/task.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// The content `pubspec_overrides.yaml` should have for [generated], given
/// its [current] content (null when the file does not exist).
///
/// Returns null when the entries rask manages already match, the empty
/// string when the file should be deleted (nothing but managed entries was
/// in it and nothing is declared any more), and otherwise the text to write.
///
/// rask manages exactly the `dependency_overrides` entries whose `path` is
/// under [genRoot]; everything else in the file is preserved, so a developer
/// can keep their own overrides (pointing rask itself at a local checkout,
/// say) in the same file.
///
/// Throws [ConfigError] when an entry rask does not manage claims the name
/// of a generated package: that would leave two sources of truth.
String? syncOverrides(String? current, List<GeneratedPackage> generated) {
  final desired = {for (final g in generated) g.name: g.overridePath};

  if (current == null || current.trim().isEmpty) {
    if (desired.isEmpty) return null;
    final text = StringBuffer()
      ..writeln(
        '# Written by rask for the packages a rask.dart task generates.',
      )
      ..writeln('# Do not edit and do not commit; rask rewrites it.')
      ..writeln('dependency_overrides:');
    for (final entry in desired.entries) {
      text
        ..writeln('  ${entry.key}:')
        ..writeln('    path: ${entry.value}');
    }
    return text.toString();
  }

  final doc = loadYaml(current);
  if (doc is! YamlMap) {
    // Non-blank text that does not parse to a map: a file holding nothing
    // but comments (null), or a single scalar. Whatever it is, it is not
    // ours to replace — a developer may have parked their own commented-out
    // overrides there — so keep it verbatim and append the managed section,
    // rather than treating it as if there were no file.
    if (desired.isEmpty) return null;
    final text = StringBuffer(current);
    if (!current.endsWith('\n')) text.writeln();
    text.writeln();
    text.writeln('dependency_overrides:');
    for (final entry in desired.entries) {
      text
        ..writeln('  ${entry.key}:')
        ..writeln('    path: ${entry.value}');
    }
    return text.toString();
  }

  final section = doc['dependency_overrides'];

  // Rebuild the whole section in one shot: foreign entries first, in their
  // original order and with their original node (so anything beyond `path`
  // survives), then the generated ones. `yaml_edit` inserts a brand new key
  // at the *front* of a block map when it is added with a single-key
  // `update`, which would put generated entries ahead of the developer's
  // own — replacing the whole map avoids that and lets a plain Dart map
  // control the final order instead.
  final newSection = <String, Object?>{};
  final managed = <String, String>{};
  if (section is YamlMap) {
    for (final entry in section.entries) {
      final name = entry.key.toString();
      final value = entry.value;
      final path = value is YamlMap ? value['path']?.toString() : null;
      if (path != null && path.startsWith('$genRoot/')) {
        managed[name] = path;
        continue;
      }
      if (desired.containsKey(name)) {
        throw ConfigError(
          'pubspec_overrides.yaml already overrides "$name" with '
          '${path ?? value}, but a rask.dart task generates a package of '
          'that name. Remove the override, or change the generated name.',
        );
      }
      newSection[name] = value;
    }
  }
  for (final entry in desired.entries) {
    newSection[entry.key] = {'path': entry.value};
  }

  if (_same(managed, desired)) return null;

  final editor = YamlEditor(current);
  if (newSection.isEmpty) {
    // Nothing rask manages and nothing foreign either: the section, and
    // maybe the whole file, has no reason to exist any more.
    final otherKeys = doc.keys.where(
      (k) => k.toString() != 'dependency_overrides',
    );
    if (otherKeys.isEmpty) return '';
    editor.remove(['dependency_overrides']);
    return editor.toString();
  }

  editor.update(['dependency_overrides'], newSection);
  return editor.toString();
}

bool _same(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
