import 'package:rask/src/task/builtin_tasks.dart';
import 'package:rask/src/task/task.dart';

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
  final tasks = <String, Task>{for (final t in builtins ?? builtinTasks) t.name: t};
  final seen = <String>{};

  for (final user in config.tasks) {
    if (commandNames.contains(user.name)) {
      throw ConfigError('"${user.name}" is a rask command and cannot be a task name.');
    }
    if (!seen.add(user.name)) {
      throw ConfigError('Task "${user.name}" is defined twice in rask.dart.');
    }
    final base = tasks[user.name];
    if (base == null) {
      if (user.run == null) {
        throw ConfigError('Task "${user.name}" has no run. Only built-in tasks may omit it.');
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
    for (final dep in task.dependsOn) {
      final target = dep.startsWith('^') ? dep.substring(1) : dep;
      if (target.isEmpty || target.startsWith('^')) {
        throw ConfigError('Task "${task.name}": dependsOn entry "$dep" is malformed. '
            'Use "name" or "^name".');
      }
      if (!tasks.containsKey(target)) {
        throw ConfigError('Task "${task.name}" depends on unknown task "$target" '
            '(known: ${tasks.keys.join(', ')}).');
      }
    }
  }
  return ResolvedConfig(tasks);
}
