import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/workspace.dart';

/// Remembers which task runs have already succeeded for a given set of
/// inputs, so an unchanged task can be skipped.
///
/// The key for a task is a content hash of everything that could change its
/// outcome: every file in the package and in the workspace members it depends
/// on (transitively), the root `pubspec.yaml` and `pubspec.lock`, the Dart SDK
/// version, and the verb with its arguments. It is never derived from git
/// state or file timestamps — a wrong skip is worse than a slow run.
///
/// One instance is meant to live for one rask process; see [_manifests].
class TaskCache {
  final Workspace workspace;

  /// Where hits are recorded, one file per key.
  final Directory directory;

  final String sdkVersion;

  TaskCache({
    required this.workspace,
    required this.directory,
    String? sdkVersion,
  }) : sdkVersion = sdkVersion ?? Platform.version;

  /// Directory names that never influence a task's outcome.
  static const _ignoredDirs = {'.dart_tool', 'build', '.git'};

  /// Directory manifests computed so far, by absolute package path.
  ///
  /// One [TaskCache] lives for one rask process, and nothing on disk is
  /// expected to change underneath it, so a dependency's tree is read once
  /// no matter how many dependents include it in their key. A new process
  /// gets a new instance and reads everything again.
  final Map<String, String> _manifests = {};

  /// The cache key for running `dart <verb> <args>` in [package].
  String keyFor(Package package, String verb, List<String> args) {
    final root = workspace.root.path;
    final manifest = StringBuffer()
      ..writeln('rask-cache-v1')
      ..writeln('sdk\t$sdkVersion')
      ..writeln('verb\t$verb')
      ..writeln('args\t${jsonEncode(args)}')
      ..writeln('package\t${package.name}\t${p.relative(package.path, from: root)}')
      ..writeln('root\tpubspec.yaml\t${_hashFile(p.join(root, 'pubspec.yaml'))}')
      ..writeln('root\tpubspec.lock\t${_hashFile(p.join(root, 'pubspec.lock'))}');

    final inputs = [package, ...workspace.dependenciesOf(package.name)]
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final pkg in inputs) {
      manifest.writeln('member\t${p.relative(pkg.path, from: root)}');
      manifest.write(_directoryManifest(pkg.path));
    }

    return sha256.convert(utf8.encode(manifest.toString())).toString();
  }

  bool contains(String key) => _entry(key).existsSync();

  /// Records that the task identified by [key] succeeded.
  void store(String key, {required Package package, required String verb}) {
    directory.createSync(recursive: true);
    _entry(key).writeAsStringSync(jsonEncode({
      'package': package.name,
      'verb': verb,
      'storedAt': DateTime.now().toUtc().toIso8601String(),
    }));
  }

  File _entry(String key) => File(p.join(directory.path, key));

  /// The `file\t<relative path>\t<sha256>` lines for every regular file under
  /// [dir], in sorted path order, skipping [_ignoredDirs]. Memoized per
  /// instance (see [_manifests]).
  String _directoryManifest(String dir) => _manifests.putIfAbsent(dir, () {
        final manifest = StringBuffer();
        _writeDirectoryManifest(dir, manifest);
        return manifest.toString();
      });

  /// Appends one `file\t<relative path>\t<sha256>` line per regular file under
  /// [dir], in sorted path order, skipping [_ignoredDirs].
  static void _writeDirectoryManifest(String dir, StringBuffer manifest) {
    final files = <String>[];
    void walk(Directory d) {
      for (final entity in d.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (!_ignoredDirs.contains(name)) walk(entity);
        } else if (entity is File) {
          files.add(entity.path);
        }
      }
    }
    walk(Directory(dir));
    files.sort();
    for (final file in files) {
      manifest.writeln('file\t${p.relative(file, from: dir)}\t${_hashFile(file)}');
    }
  }

  static String _hashFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return '-';
    return sha256.convert(file.readAsBytesSync()).toString();
  }
}
