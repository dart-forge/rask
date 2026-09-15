# rask

**The verbs Dart is missing.**

`dart` knows how to test, analyze, compile and publish *one package*. It has no idea what to do with a
workspace of twenty. rask runs those verbs across a whole [pub workspace](https://dart.dev/tools/pub/workspaces) —
in parallel where packages are independent, skipping whatever has not changed, with filters — and lets you
add your own tasks in Dart, not YAML.

```sh
dart install rask_cli

rask test                      # dart test in every package that has tests
rask analyze                   # dart analyze in every package
rask test -F my_pkg...         # my_pkg and everything that depends on it
rask publish --dry-run         # dart pub publish, dependencies first, already-published versions skipped
rask bump 0.3.0                # lockstep version bump: pubspecs, member constraints, CHANGELOG "Unreleased"
```

The second `rask test` on an unchanged tree takes well under a second: every task's inputs are hashed, and a
package whose inputs — its own files, the files of the workspace members it depends on, `pubspec.lock`, the
SDK — have not changed is skipped. Nothing is derived from git state or timestamps. A wrong skip is worse
than a slow run, so when in doubt rask re-runs.

## Tasks in Dart

A `rask.dart` at the workspace root adds tasks or changes the built-in ones. It is ordinary Dart: the analyzer
checks it, and there is nothing to learn beyond one function.

```dart
// rask.dart
import 'package:rask/rask.dart';

final config = defineConfig(tasks: [
  Task(
    'codegen',
    where: (pkg) => pkg.dependsOn('build_runner'),
    run: (ctx) => ctx.dart(['run', 'build_runner', 'build', '--delete-conflicting-outputs']),
    outputs: ['lib/**.g.dart'],
  ),
  Task('test', dependsOn: ['^codegen']),          // built-in test now waits for codegen in dependencies
  Task(
    'format',
    run: (ctx) => ctx.dart(['format', '--set-exit-if-changed', '--output=none', '.']),
  ),
]);
```

Add `rask` under the root `dev_dependencies`, run `rask pub get`, and `rask codegen` / `rask format` exist.
Each task runs once per package it applies to (`where`), in dependency order (`dependsOn`: `'x'` for the same
package's `x`, `'^x'` for `x` in the packages this one depends on), and is cached like the built-ins — with the
declared `outputs` verified on every cache hit, so a deleted build directory means a re-run, never a stale skip.

The first run after editing `rask.dart` compiles it with `dart compile exe` (a few seconds,
`rask: compiling rask.dart …` on stderr). Every later run starts in milliseconds; the compiled program is
cached by the content of every file it depends on.

## Generated code

A task can own a package instead of writing into yours:

```dart
Task('codegen',
    where: (pkg) => pkg.dependsOn('my_orm'),
    generates: (pkg) => '${pkg.name}_gen',
    run: (ctx) => ctx.exec('dart', ['run', 'my_orm:gen', '--out', ctx.gen!]));
```

`rask codegen` then creates `.dart_tool/rask/gen/<name>/`, points the root
`pubspec_overrides.yaml` at it, adds that file to `.gitignore`, runs
`dart pub get`, and empties `ctx.gen` before your generator writes into it.
The analyzer, your IDE, `dart test` and `dart compile` all see
`package:<name>/...` from then on, and nothing generated is committed.

Two things to know. A package whose code comes from a generated package
cannot be published: `dart pub publish` rejects imports that only a
dependency override resolves. And the package that imports `<name>` does
not declare it, so the analyzer may hint about an undeclared dependency;
adding `<name>: any` would silence that hint, but then no clone can resolve
dependencies until rask has generated the package, and neither
`dart pub get` nor `rask pub get` can bootstrap that — so leave it
undeclared.

A task that reads another package's generated code has to say so: `generates`
tells rask who *produces* a package, never who *imports* one, and rask
deliberately knows nothing about imports. Add `dependsOn: ['^codegen']` to the
consuming task (and `'codegen'` too when it also reads its own package's
generated code) so it never runs against a tree the generator is still
rewriting.

A generated directory folds into the cache key of every task in the package
that produces it and every task in a package that depends on that producer —
not every task that happens to import `package:<name>`. A package that
imports it without declaring the dependency still resolves it (the workspace
has one `package_config.json`), but rask cannot see that import, so its tasks
keep whatever key they already had.

The first `rask <task>` after adding `generates` creates the package with an
empty `lib`, so `dart pub get` succeeds but the imports it declares do not
resolve until the generating task has actually run once.

## dev and build

A plugin provides targets: the things `rask dev` starts and `rask build`
produces. rask owns the loop, so every framework behaves the same.

```dart
import 'package:rask/rask.dart';
import 'package:rask_something/rask_something.dart';

final config = defineConfig(plugins: [something()]);
```

`rask build` is a task like any other: cached, `-F`-able, parallel with
`-j`, and able to depend on `codegen`. It runs in every package a plugin
claims.

`rask dev` starts one package. With several to choose from it lists them and
asks for `-F`. `--port` is passed to the target exactly as given; rask
neither assigns a port nor checks that one is free, so it is entirely up to
the target what to do with it. From then on rask watches the target's files,
debounces, runs the target's prerequisite tasks, and then does what the
target asked for on a change: restart the process, rebuild its artifacts,
both, or nothing when the runtime watches its own sources. A failure keeps
the previous process and the previous artifacts and waits for the next
change, and the process exiting on its own does not end `rask dev` either,
because the usual cause is a compile error you are about to fix. The one
failure that does end `rask dev` is the process itself never starting in the
first place — `dart` missing from PATH, for instance — since there is
nothing running yet to fall back to. Ctrl+C stops the process and everything
it started.

The default `watch` is `lib/**` and `bin/**`. A prerequisite task that writes
into one of those — a `codegen` task producing `*.g.dart` in `lib/`, say —
feeds its own output back into the watcher, so narrow `watch` to exclude
whatever that task writes when you add one.

To write a plugin, implement `RaskPlugin.targetFor` and return a `Target`:
what to run (`command`), what to ship (`build`), what to do first
(`prepare`), what to watch, and what a change means (`onChange`).

## Packages

| Package | What it is |
|---|---|
| [`rask_cli`](packages/rask_cli) | The `rask` command. `dart install rask_cli`. |
| [`rask`](packages/rask) | The library a `rask.dart` imports (`package:rask/rask.dart`); the engine behind the command (`package:rask/engine.dart`); test doubles (`package:rask/testing.dart`). |

To develop rask itself, run the command from a checkout instead — `dart install` cannot resolve an
unreleased `rask` library, but activating the package from inside the workspace can:

```sh
git clone https://github.com/dart-forge/rask
dart pub global activate -s path rask/packages/rask_cli      # puts `rask` in ~/.pub-cache/bin
```

Depend on the library from a `rask.dart` with

```yaml
dev_dependencies:
  rask: ^0.1.0
```

## Why not melos, or a shell script

melos was built before pub workspaces existed and had to wire packages together itself. Now that `pub`
resolves a workspace natively, what is left to do is the part `pub` does not: run things across it in the
right order, only when needed. rask does only that part, and it does it the way turborepo does for JS —
content-hashed inputs, staged parallelism, filters — without inheriting any of the JS-specific problems.

rask has no framework-specific knowledge. It works the same for a server framework, a Flutter app and a
collection of plain packages; anything framework-specific belongs in a `rask.dart` or in a plugin.

## Status

Early. Working today: `test`, `analyze`, `pub`, `bump`, `publish`, `--filter`, `--jobs`, the content-addressed
cache with output verification, `rask.dart` with custom tasks, a `Task.generates` API that keeps generated
code out of `lib/`, and `dev`/`build` verbs driven by framework plugins.

Requires Dart 3.13 or later.
