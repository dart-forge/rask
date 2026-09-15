import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/engine.dart';
import 'package:rask/src/plugin/dev_loop.dart';
import 'package:rask/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Workspace ws;
  late FakeProcessLauncher launcher;
  late StreamController<String> changes;
  late StringBuffer out;

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_dev_');
    write('pubspec.yaml', 'name: _\nworkspace:\n  - packages/*\n');
    write('packages/app/pubspec.yaml', 'name: app\n');
    ws = Workspace.load(root);
    launcher = FakeProcessLauncher();
    changes = StreamController<String>();
    out = StringBuffer();
  });
  tearDown(() async {
    await changes.close();
    root.deleteSync(recursive: true);
  });

  ResolvedTarget target({
    OnChange onChange = OnChange.restart,
    Future<void> Function(TargetContext)? prepare,
  }) => ResolvedTarget(
    package: ws['app'],
    plugin: _Stub(),
    target: Target(
      'server',
      command: (ctx) => Command('dart', const ['run', 'bin/server.dart']),
      build: (ctx) async {},
      prepare: prepare,
      onChange: onChange,
    ),
  );

  DevLoop loop(
    ResolvedTarget resolved, {
    Future<int> Function()? runDependsOn,
    Duration debounce = Duration.zero,
  }) => DevLoop(
    resolved: resolved,
    workspace: ws,
    launcher: launcher,
    runner: RecordingRunner(),
    out: out,
    changes: changes.stream,
    runDependsOn: runDependsOn ?? () async => 0,
    debounce: debounce,
  );

  test('starts the target process', () async {
    final l = loop(target());
    final done = l.run();
    await pumpEventQueue();
    expect(launcher.starts, hasLength(1));
    expect(launcher.starts.single.$1.executable, 'dart');
    expect(launcher.starts.single.$2, ws['app'].path);
    await l.stop();
    expect(await done, 0);
  });

  test('a failing prerequisite before the start returns its code', () async {
    final code = await loop(target(), runDependsOn: () async => 3).run();
    expect(code, 3);
    expect(launcher.starts, isEmpty);
  });

  test('prepare runs before the process starts', () async {
    final calls = <String>[];
    final l = loop(target(prepare: (ctx) async => calls.add('prepare')));
    final done = l.run();
    await pumpEventQueue();
    expect(calls, ['prepare']);
    expect(launcher.starts, hasLength(1));
    await l.stop();
    await done;
  });

  test('a throwing prepare before the start stops the loop', () async {
    final code = await loop(
      target(prepare: (ctx) async => throw StateError('no')),
    ).run();
    expect(code, 1);
    expect(launcher.starts, isEmpty);
  });

  test('restart terminates and starts again', () async {
    final l = loop(target());
    final done = l.run();
    await pumpEventQueue();
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(launcher.terminated, 1);
    expect(launcher.starts, hasLength(2));
    await l.stop();
    await done;
  });

  test('rebuild runs prepare and leaves the process alone', () async {
    var prepares = 0;
    final l = loop(
      target(onChange: OnChange.rebuild, prepare: (ctx) async => prepares++),
    );
    final done = l.run();
    await pumpEventQueue();
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(prepares, 2); // once before the start, once for the change
    expect(launcher.terminated, 0);
    expect(launcher.starts, hasLength(1));
    await l.stop();
    await done;
  });

  test('nothing leaves both the process and prepare alone', () async {
    var prepares = 0;
    final l = loop(
      target(onChange: OnChange.nothing, prepare: (ctx) async => prepares++),
    );
    final done = l.run();
    await pumpEventQueue();
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(prepares, 1);
    expect(launcher.starts, hasLength(1));
    await l.stop();
    await done;
  });

  test('rebuildAndRestart does both', () async {
    var prepares = 0;
    final l = loop(
      target(
        onChange: OnChange.rebuildAndRestart,
        prepare: (ctx) async => prepares++,
      ),
    );
    final done = l.run();
    await pumpEventQueue();
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(prepares, 2);
    expect(launcher.starts, hasLength(2));
    await l.stop();
    await done;
  });

  test('a failing prerequisite during the loop keeps the process', () async {
    var fail = false;
    final l = loop(target(), runDependsOn: () async => fail ? 1 : 0);
    final done = l.run();
    await pumpEventQueue();
    fail = true;
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(launcher.terminated, 0);
    expect(launcher.starts, hasLength(1));
    expect(out.toString(), contains('failed'));
    await l.stop();
    await done;
  });

  test('a throwing prepare during the loop keeps the process', () async {
    var fail = false;
    final l = loop(
      target(
        onChange: OnChange.rebuildAndRestart,
        prepare: (ctx) async {
          if (fail) throw StateError('broken');
        },
      ),
    );
    final done = l.run();
    await pumpEventQueue();
    fail = true;
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(launcher.starts, hasLength(1));
    expect(launcher.terminated, 0);
    await l.stop();
    await done;
  });

  test('the loop survives the process exiting on its own', () async {
    final l = loop(target());
    final done = l.run();
    await pumpEventQueue();
    launcher.complete(0, 1); // the server crashed
    await pumpEventQueue();
    expect(done, isA<Future<int>>()); // still running
    changes.add('lib/a.dart');
    await pumpEventQueue();
    expect(launcher.starts, hasLength(2));
    await l.stop();
    expect(await done, 0);
  });

  test('changes arriving while handling are collapsed into one', () async {
    final gate = Completer<int>();
    var calls = 0;
    final l = loop(
      target(),
      runDependsOn: () async {
        calls++;
        if (calls == 2) await gate.future;
        return 0;
      },
    );
    final done = l.run();
    await pumpEventQueue();
    changes.add('lib/a.dart');
    await pumpEventQueue();
    changes
      ..add('lib/b.dart')
      ..add('lib/c.dart');
    await pumpEventQueue();
    gate.complete(0);
    await pumpEventQueue();
    // one start, one restart for the first change, one for the collapsed rest
    expect(launcher.starts, hasLength(3));
    await l.stop();
    await done;
  });

  test('stop terminates the process and returns 0', () async {
    final l = loop(target());
    final done = l.run();
    await pumpEventQueue();
    await l.stop();
    expect(await done, 0);
    expect(launcher.terminated, 1);
  });
}

class _Stub implements RaskPlugin {
  @override
  Target? targetFor(Package pkg) => null;
}
