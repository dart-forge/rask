import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Directory names rask never watches. Generated code lives under
/// `.dart_tool`, and watching it would make the dev loop feed itself:
/// a change runs codegen, codegen writes there, that is a change.
const _never = '.dart_tool';

/// The directories to watch for [globs]: the literal part before the first
/// glob character, with nested and duplicate roots collapsed.
///
/// Kept in the order each root first appears, so callers that print or
/// compare the result see the globs' own order rather than an alphabetical
/// one.
List<String> watchRoots(List<String> globs) {
  final kept = <String>[];
  for (final glob in globs) {
    if (glob.startsWith('$_never/') || glob == _never) continue;
    final parts = p.posix.split(glob);
    final literal = <String>[];
    for (final part in parts) {
      if (part.contains('*') ||
          part.contains('?') ||
          part.contains('{') ||
          part.contains('[')) {
        break;
      }
      literal.add(part);
    }
    if (literal.isEmpty) continue;
    final root = p.posix.joinAll(literal);
    // Already covered by a root kept earlier: skip.
    if (kept.any((k) => root == k || p.posix.isWithin(k, root))) continue;
    // This root is broader than some roots kept earlier: they are redundant.
    kept.removeWhere((k) => p.posix.isWithin(root, k));
    kept.add(root);
  }
  return kept;
}

/// Whether a package-relative posix [path] is watched by [globs].
bool matchesWatch(String path, List<String> globs) {
  if (path == _never || p.posix.isWithin(_never, path)) return false;
  return globs.any((g) => Glob(g).matches(path));
}
