import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:rask/src/launcher/entrypoint_template.dart';

/// The inputs a `dart compile --depfile` listed that live under [root],
/// as root-relative posix paths, sorted and unique. SDK and pub-cache
/// files (outside [root]) are dropped: they are covered by the SDK version
/// and `pubspec.lock` instead.
List<String> localDepfileInputs(String depfileContent, {required String root}) {
  final normalizedRoot = p.normalize(p.absolute(root));
  final body = depfileContent.replaceAll('\\\n', ' ');
  final colon = body.indexOf(':');
  final deps = (colon == -1 ? body : body.substring(colon + 1)).split(RegExp(r'\s+'));
  final result = <String>{};
  for (final dep in deps) {
    if (dep.isEmpty) continue;
    final abs = p.normalize(p.absolute(dep));
    if (!p.isWithin(normalizedRoot, abs)) continue;
    result.add(p.posix.joinAll(p.split(p.relative(abs, from: normalizedRoot))));
  }
  return result.toList()..sort();
}

/// Hash of everything the compiled entrypoint depends on: the local files
/// the depfile listed, the root `pubspec.lock`, the SDK version and the
/// entrypoint template version (D-051). Doubles as `RASK_CONFIG_KEY`.
String computeConfigKey({
  required Directory root,
  required List<String> localInputs,
  required String sdkVersion,
  int templateVersion = entrypointTemplateVersion,
}) {
  final manifest = StringBuffer()
    ..writeln('rask-config-v1')
    ..writeln('sdk\t$sdkVersion')
    ..writeln('template\t$templateVersion')
    ..writeln('file\tpubspec.lock\t${_hashFile(p.join(root.path, 'pubspec.lock'))}');
  for (final rel in [...localInputs]..sort()) {
    manifest.writeln('file\t$rel\t${_hashFile(p.join(root.path, rel))}');
  }
  return sha256.convert(utf8.encode(manifest.toString())).toString();
}

String _hashFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return '-';
  return sha256.convert(file.readAsBytesSync()).toString();
}
