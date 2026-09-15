@Tags(['integration'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:rask/src/plugin/dev_loop.dart';
import 'package:rask/src/plugin/watch_globs.dart';
import 'package:test/test.dart';

/// The one test that starts a real process and watches real files.
void main() {
  late Directory root;

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel))..parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_dev_it_');
    write('pubspec.yaml', '''
name: it_root
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - packages/app
''');
    write('packages/app/pubspec.yaml', '''
name: app
publish_to: none
resolution: workspace
environment:
  sdk: ^3.13.0
''');
    // A server that appends a line and never exits.
    write('packages/app/bin/server.dart', '''
import 'dart:async';
import 'dart:io';
void main() {
  File('started.log').writeAsStringSync('up\\n', mode: FileMode.append);
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''');
    write('packages/app/lib/app.dart', 'const version = 1;');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('starts, restarts on a change, and stops', () async {
    final ws = Workspace.load(root);
    final log = File(p.join(ws['app'].path, 'started.log'));
    final resolved = ResolvedTarget(
      package: ws['app'],
      plugin: _Toy(),
      target: _Toy().targetFor(ws['app'])!,
    );
    final out = StringBuffer();
    final roots = watchRoots(resolved.target.watch);
    final loop = DevLoop(
      resolved: resolved,
      workspace: ws,
      launcher: const SystemProcessLauncher(),
      runner: const SystemProcessRunner(),
      out: out,
      changes: watchChanges(ws['app'].path, roots, resolved.target.watch),
      runDependsOn: () async => 0,
      debounce: const Duration(milliseconds: 100),
    );
    final done = loop.run();

    await _waitFor(
      () => log.existsSync() && log.readAsLinesSync().length == 1,
      reason: () => out.toString(),
    );
    File(p.join(ws['app'].path, 'lib', 'app.dart'))
        .writeAsStringSync('const version = 2;');
    await _waitFor(
      () => log.readAsLinesSync().length == 2,
      timeout: 30,
      reason: () => out.toString(),
    );

    await loop.stop();
    expect(await done, 0, reason: out.toString());
  }, timeout: const Timeout(Duration(minutes: 3)));
}

class _Toy implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => pkg.name == 'app'
      ? Target(
          'toy',
          watch: const ['lib/**'],
          command: (ctx) => Command('dart', const ['run', 'bin/server.dart']),
          build: (ctx) => ctx.dart(['compile', 'exe', 'bin/server.dart']),
        )
      : null;
}

/// Polls [done] until it is true, or fails with [reason] (evaluated lazily,
/// so it can carry whatever the loop has printed by then) once [timeout]
/// seconds have passed.
Future<void> _waitFor(
  bool Function() done, {
  int timeout = 15,
  String Function()? reason,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  while (DateTime.now().isBefore(deadline)) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
    'timed out waiting for the condition'
    '${reason == null ? '' : ' (rask output so far:\n${reason()})'}',
  );
}
