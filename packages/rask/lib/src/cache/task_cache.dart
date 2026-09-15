import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/workspace.dart';

/// Remembers which task runs have already succeeded for a given set of
/// inputs, so an unchanged task can be skipped.
///
/// A key is a content hash of everything that could change the outcome:
/// the package's files (narrowed by the task's `inputs`, minus its own
/// `outputs`), every file of the workspace members it depends on
/// (transitively), the root `pubspec.yaml` and `pubspec.lock`, the Dart SDK
/// version, the task with its arguments, the keys of the tasks it depends
/// on, and the configuration key. Never git state, never timestamps — a
/// wrong skip is worse than a slow run.
///
/// A hit is only a hit if the task's `outputs` still hash to what they did
/// when the run was recorded: a fresh clone has the same inputs and
/// no outputs.
///
/// One instance is meant to live for one rask process; see [_trees].
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

  /// Package trees read so far: absolute package path -> (relative posix
  /// path -> sha256). One [TaskCache] lives for one rask process, and
  /// nothing on disk is expected to change underneath it, so a dependency's
  /// tree is read once no matter how many dependents include it.
  final Map<String, Map<String, String>> _trees = {};

  /// The cache key for running [task] with [args] in [package].
  ///
  /// [inputs] narrows the package's own files (null = all); files matching
  /// [outputs] are excluded from them. Dependency members always contribute
  /// all their files. [dependsOnKeys] are the keys of the nodes this one
  /// depends on; [configKey] identifies the `rask.dart` in effect.
  ///
  /// [inputDirs] are absolute directories outside the package whose whole
  /// tree belongs to the key — the packages rask generates for this package
  /// and for its dependencies. They are read through `.dart_tool`, which the
  /// package trees skip, and never memoized: a task run rewrites them.
  String keyForTask({
    required Package package,
    required String task,
    required List<String> args,
    List<String>? inputs,
    List<String> outputs = const [],
    List<String> dependsOnKeys = const [],
    String configKey = '',
    List<String> inputDirs = const [],
  }) {
    final root = workspace.root.path;
    final manifest = StringBuffer()
      ..writeln('rask-cache-v2')
      ..writeln('sdk\t$sdkVersion')
      ..writeln('task\t$task')
      ..writeln('args\t${jsonEncode(args)}')
      ..writeln(
        'package\t${package.name}\t${p.relative(package.path, from: root)}',
      )
      ..writeln(
        'root\tpubspec.yaml\t${_hashFile(p.join(root, 'pubspec.yaml'))}',
      )
      ..writeln(
        'root\tpubspec.lock\t${_hashFile(p.join(root, 'pubspec.lock'))}',
      )
      ..writeln('config\t$configKey')
      ..writeln('inputs\t${inputs == null ? '*' : jsonEncode(inputs)}');

    final inputGlobs = inputs?.map(Glob.new).toList();
    final outputGlobs = outputs.map(Glob.new).toList();
    final own = _tree(package.path);
    for (final entry in own.entries) {
      final path = entry.key;
      if (inputGlobs != null && !inputGlobs.any((g) => g.matches(path))) {
        continue;
      }
      if (outputGlobs.any((g) => g.matches(path))) continue;
      manifest.writeln('file\t$path\t${entry.value}');
    }

    final deps = workspace.dependenciesOf(package.name).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final dep in deps) {
      manifest.writeln('dep\t${p.relative(dep.path, from: root)}');
      _writeTree(manifest, _tree(dep.path));
    }

    for (final dir in [...inputDirs]..sort()) {
      manifest.writeln('genDir\t${p.relative(dir, from: root)}');
      _writeTree(manifest, _readTree(dir, ignore: const {'.git'}));
    }

    for (final k in [...dependsOnKeys]..sort()) {
      manifest.writeln('dependsOn\t$k');
    }
    return _sha(manifest.toString());
  }

  /// Hash of the files in [package] matching [outputs] plus the whole tree
  /// of each of [outputDirs]; `''` when both are empty. Not memoized:
  /// outputs change when tasks run.
  ///
  /// Unlike [_tree], this reads through `.dart_tool/` and `build/` (only
  /// `.git/` stays ignored): those are exactly where generated outputs live,
  /// and skipping them made a task with `outputs: ['build/**']` verify
  /// against nothing. [outputDirs] are read the same way, for the packages
  /// rask generates.
  String outputsHash(
    Package package,
    List<String> outputs, {
    List<String> outputDirs = const [],
  }) {
    if (outputs.isEmpty && outputDirs.isEmpty) return '';
    final globs = outputs.map(Glob.new).toList();
    final manifest = StringBuffer();
    for (final entry in _readTree(
      package.path,
      ignore: const {'.git'},
    ).entries) {
      if (globs.any((g) => g.matches(entry.key))) {
        manifest.writeln('file\t${entry.key}\t${entry.value}');
      }
    }
    for (final dir in [...outputDirs]..sort()) {
      manifest.writeln('genDir\t${p.relative(dir, from: workspace.root.path)}');
      _writeTree(manifest, _readTree(dir, ignore: const {'.git'}));
    }
    return _sha(manifest.toString());
  }

  /// Whether [key] was recorded and the package's [outputs] and
  /// [outputDirs] still hash to what they did then.
  bool isFresh(
    String key, {
    required Package package,
    required List<String> outputs,
    List<String> outputDirs = const [],
  }) {
    final entry = _entry(key);
    if (!entry.existsSync()) return false;
    final recorded =
        jsonDecode(entry.readAsStringSync()) as Map<String, dynamic>;
    return recorded['outputsHash'] ==
        outputsHash(package, outputs, outputDirs: outputDirs);
  }

  /// Forgets the memoized tree of [package]. Call after a task ran in it:
  /// the run may have written files that later keys must see.
  void invalidate(Package package) => _trees.remove(package.path);

  /// Records that [task] succeeded in [package] with the current [outputs]
  /// and [outputDirs].
  void storeTask(
    String key, {
    required Package package,
    required String task,
    required List<String> outputs,
    List<String> outputDirs = const [],
  }) {
    directory.createSync(recursive: true);
    _entry(key).writeAsStringSync(
      jsonEncode({
        'package': package.name,
        'task': task,
        'outputsHash': outputsHash(package, outputs, outputDirs: outputDirs),
        'storedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  // ---------------------------------------------------------------- internals

  File _entry(String key) => File(p.join(directory.path, key));

  /// The memoized tree of [dir]; see [_trees].
  Map<String, String> _tree(String dir) =>
      _trees.putIfAbsent(dir, () => _readTree(dir));

  /// Reads every regular file under [dir] (skipping [ignore], not following
  /// links) into relative-posix-path -> sha256, sorted by path. Defaults to
  /// [_ignoredDirs]; [outputsHash] passes a narrower set so it can see into
  /// `.dart_tool/` and `build/`.
  static Map<String, String> _readTree(
    String dir, {
    Set<String> ignore = _ignoredDirs,
  }) {
    final files = <String>[];
    void walk(Directory d) {
      if (!d.existsSync()) return;
      for (final entity in d.listSync(followLinks: false)) {
        if (entity is Directory) {
          if (!ignore.contains(p.basename(entity.path))) walk(entity);
        } else if (entity is File) {
          files.add(entity.path);
        }
      }
    }

    walk(Directory(dir));
    files.sort();
    return {
      for (final file in files)
        p.posix.joinAll(p.split(p.relative(file, from: dir))): _hashFile(file),
    };
  }

  static void _writeTree(StringBuffer manifest, Map<String, String> tree) {
    for (final entry in tree.entries) {
      manifest.writeln('file\t${entry.key}\t${entry.value}');
    }
  }

  static String _hashFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return '-';
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  static String _sha(String s) => sha256.convert(utf8.encode(s)).toString();
}
