import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/run/process_runner.dart';
import 'package:test/test.dart';

void main() {
  // The tests that spawn a process (see plan Global Constraints / D-011):
  // they run a tiny script with the Dart VM that is already running them.
  test('SystemProcessRunner.runCaptured returns the exit code with stdout and stderr captured', () async {
    final dir = Directory.systemTemp.createTempSync('rask_proc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File(p.join(dir.path, 'main.dart'))
      ..writeAsStringSync('''
import 'dart:io';
void main() {
  stdout.writeln('to stdout');
  stderr.writeln('to stderr');
  exit(3);
}
''');
    final result = await const SystemProcessRunner().runCaptured(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: dir.path,
    );
    expect(result.exitCode, 3);
    expect(result.output, contains('to stdout'));
    expect(result.output, contains('to stderr'));
  });

  test('run passes environment through to the child', () async {
    final dir = Directory.systemTemp.createTempSync('rask_env_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File(p.join(dir.path, 'env.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\nvoid main() => exit(Platform.environment['RASK_PROBE'] == 'yes' ? 0 : 3);\n",
      );
    const runner = SystemProcessRunner();
    expect(
      await runner.run(
        'dart',
        [script.path],
        workingDirectory: dir.path,
        environment: {'RASK_PROBE': 'yes'},
      ),
      0,
    );
    expect(
      await runner.run('dart', [script.path], workingDirectory: dir.path),
      3,
    );
  });
}
