import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:rask/src/workspace/topological_order.dart';
import 'package:yaml/yaml.dart';

/// One member of a [Workspace].
class Package {
  final String name;

  /// Absolute path of the package directory.
  final String path;

  /// Names of the workspace members this package depends on, from both
  /// `dependencies` and `dev_dependencies`, regardless of dependency source.
  final List<String> dependencies;

  final YamlMap pubspec;

  Package({
    required this.name,
    required this.path,
    required this.dependencies,
    required this.pubspec,
  });

  /// `version:` from the pubspec, or null when absent.
  String? get version => pubspec['version']?.toString();

  /// Whether `dart pub publish` applies: has a version and is not
  /// `publish_to: none`.
  bool get isPublishable => version != null && pubspec['publish_to'] != 'none';

  /// The registry `dart pub publish` targets: `publish_to` when set to a
  /// host, otherwise pub.dev.
  String get publishHost {
    final target = pubspec['publish_to'];
    return target is String && target != 'none' ? target : 'https://pub.dev';
  }

  @override
  String toString() => 'Package($name)';
}

/// A pub workspace: the root `pubspec.yaml` and every package it lists under
/// `workspace:`. A `pubspec.yaml` without a `workspace:` section is a
/// workspace with a single member.
class Workspace {
  final Directory root;
  final List<Package> packages;
  final Map<String, Package> _byName;

  Workspace._(this.root, this.packages)
      : _byName = {for (final pkg in packages) pkg.name: pkg};

  Package operator [](String name) {
    final pkg = _byName[name];
    if (pkg == null) {
      throw ArgumentError.value(name, 'name', 'not a workspace member');
    }
    return pkg;
  }

  /// Members ordered so that every package comes after its dependencies.
  List<Package> get inOrder => topologicalOrder({
        for (final pkg in packages) pkg.name: pkg.dependencies.toSet(),
      }).map((name) => _byName[name]!).toList();

  /// Members that depend on [name], directly or transitively.
  Iterable<Package> dependentsOf(String name) {
    final result = <String>{};
    var frontier = {name};
    while (frontier.isNotEmpty) {
      final next = <String>{};
      for (final pkg in packages) {
        if (!result.contains(pkg.name) &&
            pkg.dependencies.any(frontier.contains)) {
          result.add(pkg.name);
          next.add(pkg.name);
        }
      }
      frontier = next;
    }
    return result.map((n) => _byName[n]!);
  }

  /// Members that [name] depends on, directly or transitively.
  Iterable<Package> dependenciesOf(String name) {
    final result = <String>{};
    void visit(String n) {
      for (final dep in this[n].dependencies) {
        if (result.add(dep)) visit(dep);
      }
    }
    visit(name);
    return result.map((n) => _byName[n]!);
  }

  /// Reads the workspace rooted at [root].
  ///
  /// Members that have a `workspace:` section of their own are nested
  /// workspaces; pub resolves them together with the top-level root, so their
  /// members (and the nested root itself) become members here too.
  static Workspace load(Directory root) {
    final rootDir = p.normalize(p.absolute(root.path));
    final rootPubspec = _readPubspec(rootDir);

    if (rootPubspec['workspace'] is! YamlList) {
      return Workspace._(root, [
        _readPackage(rootDir, rootPubspec, {rootPubspec['name'] as String}),
      ]);
    }

    final pubspecs = <String, YamlMap>{};
    _collectMembers(rootDir, rootPubspec, pubspecs);

    final names = pubspecs.values.map((y) => y['name'] as String).toSet();
    final packages = [
      for (final entry in pubspecs.entries)
        _readPackage(entry.key, entry.value, names),
    ];
    return Workspace._(root, packages);
  }

  /// Adds every member listed under `workspace:` in [pubspec] (which lives in
  /// [dir]) to [into], recursing into members that are workspaces themselves.
  static void _collectMembers(
      String dir, YamlMap pubspec, Map<String, YamlMap> into) {
    final patterns = pubspec['workspace'];
    if (patterns is! YamlList) return;

    for (final pattern in patterns.cast<String>()) {
      final matches = Glob(pattern)
          .listSync(root: dir)
          .whereType<Directory>()
          .map((d) => p.normalize(p.absolute(d.path)))
          .where((m) => File(p.join(m, 'pubspec.yaml')).existsSync())
          .toList()
        ..sort();
      for (final member in matches) {
        if (into.containsKey(member)) continue;
        final memberPubspec = _readPubspec(member);
        into[member] = memberPubspec;
        _collectMembers(member, memberPubspec, into);
      }
    }
  }

  /// Walks up from [from] to find the workspace root, following pub's rule:
  /// a `pubspec.yaml` with `resolution: workspace` says its root is somewhere
  /// above; one without it is a root itself. So we climb while the pubspecs
  /// we pass are members, and stop at the first `workspace:` root that is not
  /// itself a member (nested workspaces have both keys and are climbed
  /// through). A lone `pubspec.yaml` with neither key is a single-package
  /// workspace. Returns null when there is no `pubspec.yaml` at all.
  static Directory? findRoot(Directory from) {
    Directory? nearestWorkspace;
    Directory? standalone;
    var dir = Directory(p.normalize(p.absolute(from.path)));
    while (true) {
      final file = File(p.join(dir.path, 'pubspec.yaml'));
      if (file.existsSync()) {
        final yaml = loadYaml(file.readAsStringSync());
        if (yaml is YamlMap) {
          final isMember = yaml['resolution'] == 'workspace';
          if (yaml['workspace'] is YamlList) {
            nearestWorkspace = dir;
            if (!isMember) return dir; // a top-level root: stop here
          } else if (!isMember) {
            standalone ??= dir;
          }
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return nearestWorkspace ?? standalone;
      dir = parent;
    }
  }

  static YamlMap _readPubspec(String dir) {
    final file = File(p.join(dir, 'pubspec.yaml'));
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is! YamlMap) {
      throw FormatException('${file.path} is not a YAML map');
    }
    return yaml;
  }

  static Package _readPackage(String dir, YamlMap pubspec, Set<String> members) {
    final deps = <String>[];
    for (final section in const ['dependencies', 'dev_dependencies']) {
      final map = pubspec[section];
      if (map is! YamlMap) continue;
      for (final key in map.keys) {
        final name = key as String;
        if (members.contains(name) && !deps.contains(name)) deps.add(name);
      }
    }
    return Package(
      name: pubspec['name'] as String,
      path: dir,
      dependencies: deps,
      pubspec: pubspec,
    );
  }
}
