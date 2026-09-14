import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/workspace.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

final _semver = RegExp(r'^\d+\.\d+\.\d+(-[\w.]+)?(\+[\w.]+)?$');

bool isValidVersion(String version) => _semver.hasMatch(version);

/// Returns [pubspecYaml] with `version:` set to [version]. Everything else,
/// comments included, is left as written.
String setVersion(String pubspecYaml, String version) {
  final editor = YamlEditor(pubspecYaml)..update(['version'], version);
  return editor.toString();
}

/// Returns [pubspecYaml] with every `dependencies` / `dev_dependencies` entry
/// that names one of [members] and has a plain string constraint rewritten to
/// `^version`. Map-valued entries (`path:` and friends) and non-members are
/// left alone.
String bumpInternalConstraints(
  String pubspecYaml,
  Set<String> members,
  String version,
) {
  final doc = loadYaml(pubspecYaml);
  if (doc is! YamlMap) return pubspecYaml;

  final editor = YamlEditor(pubspecYaml);
  var changed = false;
  for (final section in const ['dependencies', 'dev_dependencies']) {
    final deps = doc[section];
    if (deps is! YamlMap) continue;
    for (final entry in deps.entries) {
      final name = entry.key as String;
      if (members.contains(name) && entry.value is String) {
        editor.update([section, name], '^$version');
        changed = true;
      }
    }
  }
  return changed ? editor.toString() : pubspecYaml;
}

final _unreleased = RegExp(r'^## unreleased[ \t]*$', caseSensitive: false);

/// Returns [changelog] with the release [version] applied:
/// `## Unreleased` becomes `## version` (entries kept); an existing
/// `## version` heading leaves the file unchanged; otherwise a bare
/// `## version` heading is inserted after the `# ` title, or at the top.
String foldChangelog(String changelog, String version) {
  final lines = changelog.split('\n');

  final unreleased = lines.indexWhere(_unreleased.hasMatch);
  if (unreleased != -1) {
    lines[unreleased] = '## $version';
    return lines.join('\n');
  }

  if (lines.any((l) => l.trimRight() == '## $version')) return changelog;

  final title = lines.indexWhere((l) => l.startsWith('# '));
  var at = title + 1;
  if (at < lines.length && lines[at].isEmpty) at++;
  lines.insertAll(at, ['## $version', '']);
  return lines.join('\n');
}

/// Applies [version] to the whole workspace, lockstep:
/// - every publishable member gets `version: <version>` and its CHANGELOG
///   folded (when it has one);
/// - every member gets its constraints on other members bumped to `^version`.
///
/// Writes a summary to [out] and returns the paths of the files it rewrote.
List<String> bumpWorkspace(Workspace ws, String version, StringSink out) {
  final members = ws.packages.map((pkg) => pkg.name).toSet();
  final changed = <String>[];

  for (final pkg in ws.inOrder) {
    final pubspecFile = File(p.join(pkg.path, 'pubspec.yaml'));
    final before = pubspecFile.readAsStringSync();
    var after = bumpInternalConstraints(before, members, version);
    if (pkg.isPublishable) {
      after = setVersion(after, version);
      out.writeln('${pkg.name}: ${pkg.version} → $version');
    }
    if (after != before) {
      pubspecFile.writeAsStringSync(after);
      changed.add(pubspecFile.path);
    }

    if (!pkg.isPublishable) continue;
    final changelog = File(p.join(pkg.path, 'CHANGELOG.md'));
    if (!changelog.existsSync()) continue;
    final content = changelog.readAsStringSync();
    final folded = foldChangelog(content, version);
    if (folded != content) {
      changelog.writeAsStringSync(folded);
      changed.add(changelog.path);
      out.writeln('${pkg.name}: CHANGELOG → $version');
    }
  }
  return changed;
}
