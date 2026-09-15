import 'dart:io';

import 'package:rask/engine.dart';
import 'package:test/test.dart';

void main() {
  test(
    'starts a process, reports its pid, and reports its exit code',
    () async {
      final running = await const SystemProcessLauncher().start(
        Command(Platform.resolvedExecutable, const ['--version']),
        workingDirectory: Directory.current.path,
      );
      expect(running.pid, greaterThan(0));
      expect(await running.exitCode, 0);
    },
  );

  test('terminate stops a process that would otherwise never exit', () async {
    final script =
        File(
          '${Directory.systemTemp.createTempSync('rask_launcher_').path}/loop.dart',
        )..writeAsStringSync('''
import 'dart:async';
void main() {
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''');
    final running = await const SystemProcessLauncher().start(
      Command(Platform.resolvedExecutable, ['run', script.path]),
      workingDirectory: script.parent.path,
    );
    await running.terminate();
    expect(await running.exitCode, isNot(0));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the environment reaches the process', () async {
    final script =
        File(
          '${Directory.systemTemp.createTempSync('rask_launcher_env_').path}/env.dart',
        )..writeAsStringSync('''
import 'dart:io';
void main() {
  exit(Platform.environment['RASK_TEST_VALUE'] == 'yes' ? 0 : 3);
}
''');
    final running = await const SystemProcessLauncher().start(
      Command(
        Platform.resolvedExecutable,
        ['run', script.path],
        environment: const {'RASK_TEST_VALUE': 'yes'},
      ),
      workingDirectory: script.parent.path,
    );
    expect(await running.exitCode, 0);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
