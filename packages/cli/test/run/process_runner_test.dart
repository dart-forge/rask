import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/run/process_runner.dart';
import 'package:test/test.dart';

void main() {
  // The one test that spawns a process (see plan Global Constraints / D-011):
  // it runs a tiny script with the Dart VM that is already running this test.
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
    final result = await const SystemProcessRunner()
        .runCaptured(Platform.resolvedExecutable, [script.path], workingDirectory: dir.path);
    expect(result.exitCode, 3);
    expect(result.output, contains('to stdout'));
    expect(result.output, contains('to stderr'));
  });
}
