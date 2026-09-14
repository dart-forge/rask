import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:rask_cli/src/launcher/config_key.dart';
import 'package:rask_cli/src/launcher/entrypoint_template.dart';
import 'package:yaml/yaml.dart';

/// The version this launcher was built from. Keep equal to pubspec.yaml's
/// `version:`; kept in sync by hand, and
/// `test/launcher/version_sync_test.dart` fails when it drifts.
const String raskVersion = '0.0.1';

/// What `dart install`ed rask does before any task runs:
/// find the workspace root; if it has a `rask.dart`, compile
/// `.dart_tool/rask/entrypoint.dart` (which imports it) to a standalone
/// executable — cached by a content hash of everything the compiler read —
/// and exec that with the original arguments. Without a `rask.dart`, or for
/// `rask pub`, run the built-in configuration in-process.
///
/// The launcher never interprets tasks. Its whole contract with the
/// compiled program is argv plus `RASK_CONFIG_KEY` / `RASK_LAUNCHER_VERSION`.
class Launcher {
  final Directory cwd;
  final ProcessRunner runner;
  final StringSink err;
  final Map<String, String> environment;

  /// Inside a `dart install`ed launcher this is the runtime the launcher was
  /// built with, not the `dart` on PATH; `.dart_tool/package_config.json`'s
  /// `generatorVersion` (in the depfile) catches SDK upgrades after
  /// `rask pub get`.
  final String sdkVersion;
  final String launcherVersion;
  final String dartExecutable;
  final Future<int> Function(List<String> args) builtin;

  Launcher({
    required this.cwd,
    required this.runner,
    required this.err,
    this.environment = const {},
    String? sdkVersion,
    this.launcherVersion = raskVersion,
    this.dartExecutable = 'dart',
    Future<int> Function(List<String> args)? builtin,
  }) : sdkVersion = sdkVersion ?? Platform.version,
       builtin = builtin ?? ((args) => runRask(args, const RaskConfig()));

  Future<int> run(List<String> args) async {
    final root = Workspace.findRoot(cwd);
    if (root == null) return builtin(args);
    final raskDart = File(p.join(root.path, 'rask.dart'));
    if (!raskDart.existsSync()) return builtin(args);
    // pub must not need a compiled rask.dart: it is what makes rask.dart
    // compilable in the first place.
    if (args.isNotEmpty && args.first == 'pub') return builtin(args);

    if (!File(p.join(root.path, '.dart_tool', 'package_config.json'))
        .existsSync()) {
      err.writeln(
        'rask: rask.dart needs resolved dependencies. Run `rask pub get` first.',
      );
      return exitUsage;
    }
    if (!_dependsOnRask(File(p.join(root.path, 'pubspec.yaml')))) {
      err
        ..writeln(
          'rask: rask.dart imports package:rask, but ${p.join(root.path, 'pubspec.yaml')} '
          'does not depend on it. Add',
        )
        ..writeln('  dev_dependencies:')
        ..writeln('    rask: ^$launcherVersion')
        ..writeln('and run `rask pub get`.');
      return exitUsage;
    }

    final dir = Directory(p.join(root.path, '.dart_tool', 'rask'))
      ..createSync(recursive: true);
    final entrypoint = File(p.join(dir.path, 'entrypoint.dart'));
    final exe = File(p.join(dir.path, 'entrypoint.exe'));
    final depfile = File(p.join(dir.path, 'entrypoint.d'));
    final keyFile = File(p.join(dir.path, 'entrypoint.key'));

    if (!entrypoint.existsSync() ||
        entrypoint.readAsStringSync() != entrypointSource) {
      entrypoint.writeAsStringSync(entrypointSource);
    }

    final excludeRoots = _excludedRoots();
    String? key = _currentKey(root, depfile, keyFile, exe, excludeRoots);
    if (key == null) {
      err.writeln('rask: compiling rask.dart …');
      // The cache is valid only when key, depfile and exe agree, so the key
      // goes first: the front end writes the depfile early, and an
      // interrupted compile would otherwise leave a NEW depfile beside an
      // OLD key. Without a key the next run is a miss, never a wrong hit.
      if (keyFile.existsSync()) keyFile.deleteSync();
      // Compile to a temp path and rename it into place. Overwriting the exe
      // where it lies would kill a rask that is executing it (the ad-hoc
      // signature on macOS) or fail with ETXTBSY on Linux; the rename is
      // atomic on the same filesystem, so a process running the old inode
      // keeps working. Two concurrent compiles can still make this process
      // read the other's depfile, but both compiled the same inputs, so the
      // key recorded here is correct for whichever exe the last rename left
      // behind.
      final tmp = File('${exe.path}.$pid.tmp');
      final CapturedProcess result;
      try {
        result = await runner.runCaptured(dartExecutable, [
          'compile',
          'exe',
          entrypoint.path,
          '-o',
          tmp.path,
          '--depfile',
          depfile.path,
        ], workingDirectory: root.path);
      } on ProcessException catch (e) {
        if (tmp.existsSync()) tmp.deleteSync();
        err.writeln('rask: could not run ${e.executable}: ${e.message}');
        return exitCannotRun;
      }
      if (result.exitCode != 0) {
        if (tmp.existsSync()) tmp.deleteSync();
        // The two shapes the front end reports a missing `config` with:
        // `Undefined name 'config'.` and `Getter not found: 'config'.`
        if (RegExp(r"(Undefined name|Getter not found:) 'config'")
            .hasMatch(result.output)) {
          err.writeln(
            'rask: rask.dart must define `final config = defineConfig(...)`.',
          );
        }
        err.write(result.output);
        if (result.output.isNotEmpty && !result.output.endsWith('\n')) {
          err.writeln();
        }
        return exitUsage;
      }
      tmp.renameSync(exe.path);
      key = _keyFrom(root, _localInputs(root, depfile, excludeRoots));
      keyFile.writeAsStringSync(key);
    }

    try {
      return await runner.run(
        exe.path,
        args,
        workingDirectory: cwd.path,
        environment: {
          ...environment,
          'RASK_CONFIG_KEY': key,
          'RASK_LAUNCHER_VERSION': launcherVersion,
        },
      );
    } on ProcessException catch (e) {
      err.writeln('rask: could not run ${e.executable}: ${e.message}');
      return exitCannotRun;
    }
  }

  /// The recorded key when the compiled exe is still valid, else null.
  String? _currentKey(
    Directory root,
    File depfile,
    File keyFile,
    File exe,
    List<String> excludeRoots,
  ) {
    if (!depfile.existsSync() || !keyFile.existsSync() || !exe.existsSync()) {
      return null;
    }
    final inputs = _localInputs(root, depfile, excludeRoots);
    // The entrypoint imports rask.dart, so every depfile lists it. Its
    // absence means this is not the depfile we think it is (unparsable,
    // half-written): a miss costs one compile, a wrong hit runs stale
    // tasks.
    if (!inputs.contains('rask.dart')) return null;
    final key = _keyFrom(root, inputs);
    return keyFile.readAsStringSync() == key ? key : null;
  }

  /// The depfile's inputs, root-relative or absolute (see
  /// [localDepfileInputs]).
  List<String> _localInputs(
    Directory root,
    File depfile,
    List<String> excludeRoots,
  ) => localDepfileInputs(
    depfile.readAsStringSync(),
    root: root.path,
    excludeRoots: excludeRoots,
  );

  /// The config key from the depfile's inputs plus [sdkVersion] — computed
  /// after a fresh compile and again to check whether a cached exe is stale.
  String _keyFrom(Directory root, List<String> localInputs) => computeConfigKey(
    root: root,
    localInputs: localInputs,
    sdkVersion: sdkVersion,
  );

  /// Trees whose files stay out of the config key: the pub cache, which
  /// `pubspec.lock` covers and which would cost thousands of reads to hash.
  /// Everything else the depfile lists is hashed, including `path:`
  /// dependencies outside the workspace. The SDK needs no
  /// entry: `Platform.resolvedExecutable` does not locate it from inside an
  /// AOT launcher, and a real `dart compile exe` depfile lists no SDK source.
  List<String> _excludedRoots() {
    final pubCache = _env('PUB_CACHE');
    if (pubCache != null && pubCache.isNotEmpty) return [pubCache];
    if (Platform.isWindows) {
      final localAppData = _env('LOCALAPPDATA');
      return localAppData == null || localAppData.isEmpty
          ? const []
          : [p.join(localAppData, 'Pub', 'Cache')];
    }
    final home = _env('HOME');
    return home == null || home.isEmpty
        ? const []
        : [p.join(home, '.pub-cache')];
  }

  /// The injected [environment] first — it is what the compiled program will
  /// see — then the launcher's own.
  String? _env(String name) => environment[name] ?? Platform.environment[name];

  static bool _dependsOnRask(File pubspec) {
    if (!pubspec.existsSync()) return false;
    final yaml = loadYaml(pubspec.readAsStringSync());
    if (yaml is! YamlMap) return false;
    for (final section in const ['dependencies', 'dev_dependencies']) {
      final deps = yaml[section];
      if (deps is YamlMap && deps.containsKey('rask')) return true;
    }
    return false;
  }
}
