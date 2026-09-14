import 'package:rask/src/workspace/workspace.dart';

/// Cuts [packages] into stages that can run one after another, with every
/// package inside a stage independent of the others in it.
///
/// [packages] must be in dependency order (dependencies before dependents),
/// as `Workspace.inOrder` and `selectPackages` return them. A package's stage
/// is one more than the highest stage among its **transitive** workspace
/// dependencies (per [workspace]) that are also in [packages]. Looking at
/// transitive rather than direct dependencies means a package filtered out
/// of [packages] is transparent: `app -> lib_a -> core` with only `app` and
/// `core` selected still runs `core` before `app`. Dependencies outside
/// [packages] impose no wait of their own. Input order is preserved inside a
/// stage.
List<List<Package>> stagesOf(List<Package> packages, {required Workspace workspace}) {
  final stageOf = <String, int>{};
  final stages = <List<Package>>[];
  for (final pkg in packages) {
    var stage = 0;
    for (final dep in workspace.dependenciesOf(pkg.name)) {
      final depStage = stageOf[dep.name];
      if (depStage != null && depStage + 1 > stage) stage = depStage + 1;
    }
    stageOf[pkg.name] = stage;
    while (stages.length <= stage) {
      stages.add([]);
    }
    stages[stage].add(pkg);
  }
  return stages;
}
