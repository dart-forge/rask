## Unreleased

- `Task(generates:)` declares a package rask generates for each package the
  task applies to. rask owns `.dart_tool/rask/gen/<name>/` and the managed
  entries of the root `pubspec_overrides.yaml`, keeps `.gitignore` in step,
  runs `dart pub get` when any of that changes, and hands the output
  directory to the task as `ctx.gen`.
- Generated directories are part of a task's cache key, and of the output
  verification of the task that produces them, so regenerating never leaves
  a stale skip behind.

## 0.1.0

First release. The library a `rask.dart` imports (`package:rask/rask.dart`), the engine behind the `rask` command (`package:rask/engine.dart`), and test doubles for it (`package:rask/testing.dart`).

- Tasks: `Task(name, where:, run:, dependsOn:, inputs:, outputs:)` and `defineConfig`. Built-in `test` and `analyze`.
- Runs across a pub workspace in dependency order, parallel where independent (`--jobs`), with `--filter` (`pkg`, `pkg...`, `...pkg`).
- Content-addressed cache: a package whose inputs (its files, its workspace dependencies' files, `pubspec.lock`, the SDK version, the task and its arguments) have not changed is skipped; declared `outputs` are verified on every hit.
- `bump` (lockstep versions, member constraints, CHANGELOG folding) and `publish` (dependencies first, already-published versions skipped).
