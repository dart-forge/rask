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
  final tokens = _tokenizeDepfile(depfileContent);
  // The first token is the target ("entrypoint.exe:"); drop it. Its own
  // content could itself contain a `\ ` escape, so this only works because
  // tokenization happens before, not via a textual `indexOf(':')` split.
  final deps = tokens.isNotEmpty && tokens.first.endsWith(':') ? tokens.sublist(1) : tokens;
  final result = <String>{};
  for (final dep in deps) {
    final abs = p.normalize(p.absolute(dep));
    if (!p.isWithin(normalizedRoot, abs)) continue;
    result.add(p.posix.joinAll(p.split(p.relative(abs, from: normalizedRoot))));
  }
  return result.toList()..sort();
}

/// Splits Makefile/ninja-style depfile content into whitespace-separated
/// tokens, honoring the escapes `dart compile --depfile` emits: `\ ` and
/// `\#` unescape to a literal space/`#`, `\\` unescapes to a literal `\`,
/// and `\<newline>` is a line continuation (dropped, not a token break).
/// Any other backslash is kept literally. Unescaped space/tab/CR/newline
/// ends the current token.
List<String> _tokenizeDepfile(String content) {
  final tokens = <String>[];
  final buf = StringBuffer();
  var hasToken = false;
  final len = content.length;
  var i = 0;
  while (i < len) {
    final ch = content[i];
    if (ch == '\\' && i + 1 < len) {
      final next = content[i + 1];
      if (next == ' ' || next == '#' || next == '\\') {
        buf.write(next);
        hasToken = true;
        i += 2;
        continue;
      }
      if (next == '\n') {
        i += 2;
        continue;
      }
      buf.write('\\');
      hasToken = true;
      i += 1;
      continue;
    }
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      if (hasToken) {
        tokens.add(buf.toString());
        buf.clear();
        hasToken = false;
      }
      i += 1;
      continue;
    }
    buf.write(ch);
    hasToken = true;
    i += 1;
  }
  if (hasToken) tokens.add(buf.toString());
  return tokens;
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
