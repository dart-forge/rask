import 'package:rask/src/task/builtin_tasks.dart';
import 'package:rask/src/task/task.dart';
import 'package:rask/src/workspace/topological_order.dart';
import 'package:rask/src/workspace/workspace.dart';

/// The tasks a run can use: builtins merged with what `rask.dart` declares,
/// validated. Iteration order is builtins first, then user tasks in the
/// order written.
class ResolvedConfig {
  final Map<String, Task> tasks;
  ResolvedConfig(this.tasks);

  Task operator [](String name) {
    final task = tasks[name];
    if (task == null) throw ArgumentError.value(name, 'name', 'not a task');
    return task;
  }
}

/// Merges [config] over [builtins] (default [builtinTasks]) and validates.
///
/// A user task with a builtin's name keeps the builtin's fields except the
/// ones the user gave (`where` / `run` / `inputs` / `description` when
/// non-null, `dependsOn` / `outputs` when non-empty).
ResolvedConfig resolveConfig(RaskConfig config, {List<Task>? builtins}) {
  final tasks = <String, Task>{
    for (final t in builtins ?? builtinTasks) t.name: t,
  };
  final seen = <String>{};

  for (final user in config.tasks) {
    if (commandNames.contains(user.name)) {
      throw ConfigError(
        '"${user.name}" is a rask command and cannot be a task name.',
      );
    }
    if (!seen.add(user.name)) {
      throw ConfigError('Task "${user.name}" is defined twice in rask.dart.');
    }
    final base = tasks[user.name];
    if (base == null) {
      if (user.run == null) {
        throw ConfigError(
          'Task "${user.name}" has no run. Only built-in tasks may omit it.',
        );
      }
      tasks[user.name] = user;
    } else {
      tasks[user.name] = Task(
        user.name,
        where: user.where ?? base.where,
        run: user.run ?? base.run,
        dependsOn: user.dependsOn.isNotEmpty ? user.dependsOn : base.dependsOn,
        inputs: user.inputs ?? base.inputs,
        outputs: user.outputs.isNotEmpty ? user.outputs : base.outputs,
        description: user.description ?? base.description,
      );
    }
  }

  for (final task in tasks.values) {
    if (task.inputs != null && task.inputs!.isEmpty) {
      throw ConfigError(
        'Task "${task.name}": inputs must be null (everything) or a non-empty list.',
      );
    }
    for (final glob in task.inputs ?? const []) {
      final segment = glob.split('/').first;
      if (segment == '.dart_tool' || segment == 'build' || segment == '.git') {
        throw ConfigError(
          'Task "${task.name}": inputs entry "$glob" is under a directory '
          'rask never reads (.dart_tool/, build/, .git/).',
        );
      }
    }
    for (final dep in task.dependsOn) {
      final target = dep.startsWith('^') ? dep.substring(1) : dep;
      if (target.isEmpty || target.startsWith('^')) {
        throw ConfigError(
          'Task "${task.name}": dependsOn entry "$dep" is malformed. '
          'Use "name" or "^name".',
        );
      }
      if (!tasks.containsKey(target)) {
        throw ConfigError(
          'Task "${task.name}" depends on unknown task "$target" '
          '(known: ${tasks.keys.join(', ')}).',
        );
      }
    }
  }
  return ResolvedConfig(tasks);
}

/// One unit of work: [task] in [package].
class TaskNode {
  final Task task;
  final Package package;
  TaskNode(this.task, this.package);

  String get id => '${task.name}@${package.name}';

  @override
  bool operator ==(Object other) => other is TaskNode && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => id;
}

/// The nodes a run must execute and the order constraints between them.
class TaskGraph {
  /// Every node, dependencies before dependents.
  final List<TaskNode> nodes;
  final Map<TaskNode, List<TaskNode>> _deps;
  TaskGraph._(this.nodes, this._deps);

  /// Nodes that must finish before [node] starts.
  List<TaskNode> dependenciesOf(TaskNode node) => _deps[node] ?? const [];

  /// [nodes] cut into stages: a node's stage is one more than the highest
  /// stage among its dependencies. Nodes in one stage are independent.
  List<List<TaskNode>> get stages {
    final stageOf = <TaskNode, int>{};
    final stages = <List<TaskNode>>[];
    for (final node in nodes) {
      var stage = 0;
      for (final dep in dependenciesOf(node)) {
        final s = stageOf[dep]! + 1;
        if (s > stage) stage = s;
      }
      stageOf[node] = stage;
      while (stages.length <= stage) {
        stages.add([]);
      }
      stages[stage].add(node);
    }
    return stages;
  }
}

/// Builds the graph for running [task] in [targets].
///
/// Nodes come from [targets] filtered by the task's `where`, then from
/// `dependsOn`: `'x'` adds `x` in the same package, `'^x'` adds `x` in every
/// **transitive** workspace dependency (D-037). Packages where the depended-on
/// task does not apply contribute no node and no edge. Nodes pulled in this
/// way are expanded the same way, whether or not they are in [targets].
/// Throws [CyclicDependencyException] on a cycle.
TaskGraph buildTaskGraph({
  required ResolvedConfig config,
  required String task,
  required List<Package> targets,
  required Workspace workspace,
}) {
  final byId = <String, TaskNode>{};
  final deps = <String, Set<String>>{};

  bool applies(Task t, Package pkg) => t.where == null || t.where!(pkg);

  TaskNode? node(Task t, Package pkg) {
    if (!applies(t, pkg)) return null;
    final id = '${t.name}@${pkg.name}';
    if (byId.containsKey(id)) return byId[id];
    final n = TaskNode(t, pkg);
    byId[id] = n;
    final edges = deps[id] = <String>{};
    for (final dep in t.dependsOn) {
      final caret = dep.startsWith('^');
      final target = config[caret ? dep.substring(1) : dep];
      final packages = caret ? workspace.dependenciesOf(pkg.name) : [pkg];
      for (final p in packages) {
        final d = node(target, p);
        if (d != null) edges.add(d.id);
      }
    }
    return n;
  }

  final root = config[task];
  for (final pkg in targets) {
    node(root, pkg);
  }

  final order = topologicalOrder(deps); // throws CyclicDependencyException
  final nodes = [for (final id in order) byId[id]!];
  final resolved = {
    for (final n in nodes) n: [for (final id in deps[n.id]!) byId[id]!],
  };
  return TaskGraph._(nodes, resolved);
}
