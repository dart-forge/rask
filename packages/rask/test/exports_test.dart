// Compile-time check of the two public libraries: if a name moves
// out of `rask.dart`, or `engine.dart` stops re-exporting it, this file
// fails to compile.
import 'package:rask/engine.dart' as engine;
import 'package:rask/rask.dart' as config;
import 'package:test/test.dart';

void main() {
  test('rask.dart exposes exactly what a rask.dart author needs', () {
    // referenced so the analyzer proves they are exported
    final Type t1 = config.Task;
    final Type t2 = config.TaskContext;
    final Type t3 = config.RaskConfig;
    final Type t4 = config.ProcessFailure;
    final Type t5 = config.ConfigError;
    final Type t6 = config.Package;
    final Type t7 = config.Workspace;
    // What a plugin author imports: a Target, the RaskPlugin they
    // implement, the Command they return, OnChange, and the TargetContext
    // their hooks run with.
    final Type t8 = config.Target;
    final Type t9 = config.RaskPlugin;
    final Type t10 = config.OnChange;
    final Type t11 = config.Command;
    final Type t12 = config.TargetContext;
    expect([t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12], hasLength(12));
    expect(config.defineConfig(), isA<config.RaskConfig>());
    expect(config.hasTests, isA<Function>());
    expect(config.runRask, isA<Function>());
  });

  test('engine.dart exposes the machinery', () {
    final Type t1 = engine.TaskCache;
    final Type t2 = engine.RaskCommandRunner;
    final Type t3 = engine.TaskGraph;
    final Type t4 = engine.ProcessRunner;
    final Type t5 = engine.PackageRegistry;
    expect([t1, t2, t3, t4, t5], hasLength(5));
    expect(engine.builtinTasks, isNotEmpty);
    expect(engine.commandNames, contains('pub'));
    expect(engine.runTaskGraph, isA<Function>());
    expect(engine.selectPackages, isA<Function>());
    expect(engine.topologicalOrder, isA<Function>());
    expect(engine.bumpWorkspace, isA<Function>());
    expect(engine.publishPackages, isA<Function>());
    final Type t6 = engine.GeneratedPackage;
    expect(t6, isNotNull);
    expect(engine.resolveGeneratedPackages, isA<Function>());
    expect(engine.ensureGeneratedPackages, isA<Function>());
    expect(engine.genRoot, '.dart_tool/rask/gen');
    expect(engine.resolveTargets, isA<Function>());
    final Type t7 = engine.ProcessLauncher;
    final Type t8 = engine.ResolvedTarget;
    expect([t7, t8], hasLength(2));
    // and everything from rask.dart too
    expect(engine.defineConfig(), isA<engine.RaskConfig>());
  });
}
