import 'dart:convert';
import 'dart:io';

import 'package:rask/src/run/process_runner.dart';
import 'package:rask/src/workspace/workspace.dart';

/// Answers "is this version of this package already on the registry?".
abstract class PackageRegistry {
  Future<bool> hasVersion({
    required String host,
    required String name,
    required String version,
  });
}

/// Queries a pub-compatible registry over HTTP (`<host>/api/packages/<name>`).
class HttpPackageRegistry implements PackageRegistry {
  const HttpPackageRegistry();

  @override
  Future<bool> hasVersion({
    required String host,
    required String name,
    required String version,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$host/api/packages/$name');
      final response = await client.getUrl(uri).then((r) => r.close());
      if (response.statusCode == HttpStatus.notFound) return false;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final body = jsonDecode(await response.transform(utf8.decoder).join());
      final versions = (body as Map<String, dynamic>)['versions'] as List<dynamic>;
      return versions.any((v) => (v as Map<String, dynamic>)['version'] == version);
    } finally {
      client.close(force: true);
    }
  }
}

/// Exit code when the registry could not be consulted.
const exitRegistryUnavailable = 69; // EX_UNAVAILABLE

/// Publishes the publishable members of [packages], in the given order,
/// with `dart pub publish`. Members without a version or with
/// `publish_to: none` are reported and skipped, as are versions the registry
/// already has. Stops at the first failure and returns its exit code.
///
/// With [dryRun], `dart pub publish --dry-run` is used and nothing is skipped
/// for being already published (the registry is still consulted so the
/// output shows what a real run would do).
Future<int> publishPackages(
  List<Package> packages, {
  required ProcessRunner runner,
  required PackageRegistry registry,
  required StringSink out,
  bool dryRun = false,
}) async {
  for (final pkg in packages) {
    if (!pkg.isPublishable) {
      final why = pkg.version == null ? 'no version' : 'publish_to: none';
      out.writeln('rask: ${pkg.name} — skip ($why)');
      continue;
    }

    final bool published;
    try {
      published = await registry.hasVersion(
          host: pkg.publishHost, name: pkg.name, version: pkg.version!);
    } catch (e) {
      out.writeln('rask: ${pkg.name} — could not reach ${pkg.publishHost}: $e');
      return exitRegistryUnavailable;
    }
    if (published) {
      out.writeln('rask: ${pkg.name} ${pkg.version} — already published'
          '${dryRun ? ' (dry run continues)' : ', skip'}');
      if (!dryRun) continue;
    }

    final args = ['pub', 'publish', if (dryRun) '--dry-run' else '--force'];
    out.writeln('rask: ${pkg.name} ${pkg.version} — dart ${args.join(' ')}');
    final code = await runner.run('dart', args, workingDirectory: pkg.path);
    if (code != 0) {
      out.writeln('rask: ${pkg.name} — publish failed (exit $code)');
      return code;
    }
  }
  return 0;
}
