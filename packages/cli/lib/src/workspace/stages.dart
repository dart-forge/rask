import 'package:rask/src/workspace/workspace.dart';

/// Cuts [packages] into stages that can run one after another, with every
/// package inside a stage independent of the others in it.
///
/// [packages] must be in dependency order (dependencies before dependents),
/// as `Workspace.inOrder` and `selectPackages` return them. A package's stage
/// is one more than the highest stage among its dependencies that are also in
/// [packages]; dependencies outside the list were filtered out, will not run,
/// and so impose no ordering. Input order is preserved inside a stage.
List<List<Package>> stagesOf(List<Package> packages) {
  final stageOf = <String, int>{};
  final stages = <List<Package>>[];
  for (final pkg in packages) {
    var stage = 0;
    for (final dep in pkg.dependencies) {
      final depStage = stageOf[dep];
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
