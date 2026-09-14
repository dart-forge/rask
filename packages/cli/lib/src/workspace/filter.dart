import 'package:rask/src/workspace/workspace.dart';

/// Selects workspace members from `--filter` values.
///
/// - `name` selects that package.
/// - `name...` selects the package and everything that depends on it.
/// - `...name` selects the package and everything it depends on.
///
/// Multiple filters are unioned. With no filters every member is selected.
/// The result is always in dependency order.
List<Package> selectPackages(Workspace ws, List<String> filters) {
  if (filters.isEmpty) return ws.inOrder;

  final selected = <String>{};
  for (final filter in filters) {
    final withDependents = filter.endsWith('...');
    final withDependencies = filter.startsWith('...');
    final name = filter
        .replaceFirst(RegExp(r'\.\.\.$'), '')
        .replaceFirst(RegExp(r'^\.\.\.'), '');

    if (!ws.packages.any((pkg) => pkg.name == name)) {
      throw ArgumentError(
        '"$name" is not a package in this workspace '
        '(members: ${ws.packages.map((pkg) => pkg.name).join(', ')})',
      );
    }
    selected.add(name);
    if (withDependents) {
      selected.addAll(ws.dependentsOf(name).map((pkg) => pkg.name));
    }
    if (withDependencies) {
      selected.addAll(ws.dependenciesOf(name).map((pkg) => pkg.name));
    }
  }

  return ws.inOrder.where((pkg) => selected.contains(pkg.name)).toList();
}
