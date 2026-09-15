import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/gen/generated_package.dart';
import 'package:rask/src/gen/overrides.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:yaml/yaml.dart';

/// What [ensureGeneratedPackages] did.
class EnsureResult {
  /// Whether anything on disk was written, removed, or rewritten.
  final bool changed;

  /// Names of the generated packages that did not exist before this call.
  final List<String> created;

  /// The exit code of the `dart pub get` that followed a change; 0 when no
  /// pub get was needed.
  final int pubGetExitCode;

  const EnsureResult({
    required this.changed,
    required this.created,
    required this.pubGetExitCode,
  });

  static const unchanged = EnsureResult(
    changed: false,
    created: [],
    pubGetExitCode: 0,
  );
}

/// Brings the workspace in line with [generated]: writes each generated
/// package's pubspec, removes the ones no longer declared, rewrites the
/// managed entries of `pubspec_overrides.yaml`, makes sure git ignores that
/// file, and runs `dart pub get` when any of that changed.
///
/// Cheap when nothing changed: it compares file contents and starts no
/// process. Called before every task run, so it must stay that way.
///
/// Throws [ConfigError] (from [syncOverrides]) when the workspace's own
/// overrides collide with a generated name; the process never starts then.
Future<EnsureResult> ensureGeneratedPackages({
  required Workspace workspace,
  required List<GeneratedPackage> generated,
  required ProcessRunner runner,
  required StringSink out,
}) async {
  final root = workspace.root.path;
  var changed = false;
  final created = <String>[];

  final sdk = _sdkConstraint(root);
  for (final g in generated) {
    if (!Directory(g.dir).existsSync()) created.add(g.name);
    Directory(g.libDir).createSync(recursive: true);
    final pubspec = File(p.join(g.dir, 'pubspec.yaml'));
    final text = _stub(g.name, sdk);
    if (!pubspec.existsSync() || pubspec.readAsStringSync() != text) {
      pubspec.writeAsStringSync(text);
      changed = true;
    }
  }

  final genDir = Directory(genRootDir(root));
  if (genDir.existsSync()) {
    final keep = {for (final g in generated) g.name};
    for (final entity in genDir.listSync(followLinks: false)) {
      if (entity is Directory && !keep.contains(p.basename(entity.path))) {
        entity.deleteSync(recursive: true);
        changed = true;
      }
    }
  }

  final overrides = File(p.join(root, 'pubspec_overrides.yaml'));
  final next = syncOverrides(
    overrides.existsSync() ? overrides.readAsStringSync() : null,
    generated,
  );
  if (next != null) {
    if (next.isEmpty) {
      if (overrides.existsSync()) overrides.deleteSync();
    } else {
      overrides.writeAsStringSync(next);
    }
    changed = true;
  }

  if (generated.isNotEmpty && _ignoreOverrides(root, out)) changed = true;

  if (!changed) return EnsureResult.unchanged;
  out.writeln('rask: generated packages changed — dart pub get');
  final code = await runner.run('dart', [
    'pub',
    'get',
  ], workingDirectory: root);
  return EnsureResult(
    changed: true,
    created: created,
    pubGetExitCode: code,
  );
}

String _stub(String name, String sdk) =>
    '''
# Written by rask. Do not edit and do not commit: rask rewrites it.
#
# No dependencies on purpose. A pub workspace has a single
# package_config.json, so the generated code can import anything the
# workspace resolves without declaring it here.
name: $name
publish_to: none
environment:
  sdk: $sdk
''';

/// The root pubspec's SDK constraint, or one for the running SDK.
String _sdkConstraint(String root) {
  final file = File(p.join(root, 'pubspec.yaml'));
  if (file.existsSync()) {
    final doc = loadYaml(file.readAsStringSync());
    if (doc is YamlMap) {
      final environment = doc['environment'];
      if (environment is YamlMap) {
        final sdk = environment['sdk'];
        if (sdk != null) return sdk.toString();
      }
    }
  }
  return '^${Platform.version.split(' ').first}';
}

/// Patterns in `.gitignore` that already cover `pubspec_overrides.yaml`.
const _ignorePatterns = {
  'pubspec_overrides.yaml',
  '/pubspec_overrides.yaml',
  'pubspec_overrides.*',
  '/pubspec_overrides.*',
};

/// Makes sure git ignores `pubspec_overrides.yaml`, returning whether the
/// file was changed.
///
/// This is correctness, not tidiness: committed, the file points at
/// `.dart_tool/rask/gen/...`, which a fresh clone does not have, and a plain
/// `dart pub get` then fails for everyone.
bool _ignoreOverrides(String root, StringSink out) {
  final file = File(p.join(root, '.gitignore'));
  final existing = file.existsSync() ? file.readAsStringSync() : '';
  final covered = existing
      .split('\n')
      .any((line) => _ignorePatterns.contains(line.trim()));
  if (covered) return false;
  final separator = existing.isEmpty
      ? ''
      : (existing.endsWith('\n') ? '\n' : '\n\n');
  file.writeAsStringSync(
    '$existing$separator'
    '# rask writes this for the packages a rask.dart task generates.\n'
    'pubspec_overrides.yaml\n',
  );
  out.writeln('rask: added pubspec_overrides.yaml to .gitignore');
  return true;
}
