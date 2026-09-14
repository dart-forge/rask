import 'dart:convert';
import 'dart:io';

/// What a finished process left behind when its output was captured.
class CapturedProcess {
  final int exitCode;

  /// stdout and stderr as one string, in the order the chunks arrived,
  /// decoded as UTF-8 (malformed bytes are replaced, never thrown).
  final String output;

  const CapturedProcess(this.exitCode, this.output);
}

/// Runs external processes. Abstracted so command logic can be tested
/// without spawning anything.
abstract class ProcessRunner {
  /// Runs the process with inherited stdio — its output goes straight to the
  /// terminal — and returns its exit code.
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory});

  /// Runs the process with stdout and stderr captured instead of inherited,
  /// so several processes can run at once without interleaving their output.
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory});
}

/// Runs real processes.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory}) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  @override
  Future<CapturedProcess> runCaptured(String executable, List<String> args,
      {required String workingDirectory}) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
    );
    final output = StringBuffer();
    const decoder = Utf8Decoder(allowMalformed: true);
    final drained = Future.wait([
      process.stdout.transform(decoder).forEach(output.write),
      process.stderr.transform(decoder).forEach(output.write),
    ]);
    final exitCode = await process.exitCode;
    await drained;
    return CapturedProcess(exitCode, output.toString());
  }
}
