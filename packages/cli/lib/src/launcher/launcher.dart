import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/cli/rask_command_runner.dart' show exitUsage;
import 'package:rask/src/cli/run_rask.dart';
import 'package:rask/src/launcher/config_key.dart';
import 'package:rask/src/launcher/entrypoint_template.dart';
import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/task/task_runner.dart' show exitCannotRun;
import 'package:rask/src/workspace/workspace.dart';
import 'package:yaml/yaml.dart';

/// The version this launcher was built from. Keep equal to pubspec.yaml's
/// `version:`; `rask bump` rewrites it.
const String raskVersion = '0.0.1';

/// What `dart install`ed rask does before any task runs (D-025, D-048–D-051):
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
    if (args.isNotEmpty && args.first == 'pub') return builtin(args); // D-050

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

    String? key = _currentKey(root, depfile, keyFile, exe);
    if (key == null) {
      err.writeln('rask: compiling rask.dart …');
      final CapturedProcess result;
      try {
        result = await runner.runCaptured(dartExecutable, [
          'compile',
          'exe',
          entrypoint.path,
          '-o',
          exe.path,
          '--depfile',
          depfile.path,
        ], workingDirectory: root.path);
      } on ProcessException catch (e) {
        err.writeln('rask: could not run ${e.executable}: ${e.message}');
        return exitCannotRun;
      }
      if (result.exitCode != 0) {
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
      key = _keyFrom(root, depfile);
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
  String? _currentKey(Directory root, File depfile, File keyFile, File exe) {
    if (!depfile.existsSync() || !keyFile.existsSync() || !exe.existsSync()) {
      return null;
    }
    final key = _keyFrom(root, depfile);
    return keyFile.readAsStringSync() == key ? key : null;
  }

  /// The config key from the depfile's inputs plus [sdkVersion] — computed
  /// after a fresh compile and again to check whether a cached exe is stale.
  String _keyFrom(Directory root, File depfile) => computeConfigKey(
    root: root,
    localInputs: localDepfileInputs(
      depfile.readAsStringSync(),
      root: root.path,
    ),
    sdkVersion: sdkVersion,
  );

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
