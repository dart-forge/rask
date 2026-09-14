import 'dart:io';

/// Runs external processes. Abstracted so command logic can be tested
/// without spawning anything.
abstract class ProcessRunner {
  Future<int> run(String executable, List<String> args,
      {required String workingDirectory});
}

/// Runs the process with inherited stdio and returns its exit code.
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
}
