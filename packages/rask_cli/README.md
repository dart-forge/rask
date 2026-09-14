# rask_cli

The `rask` command. Install it with

    dart install rask_cli

and run `rask test`, `rask analyze`, `rask pub get`, `rask bump`, `rask publish`, or any task a `rask.dart`
at your workspace root defines. The library that `rask.dart` imports is `package:rask` — add it under the
root `dev_dependencies`.

From a checkout of this repository (before the packages are on pub.dev), install the command with

    dart pub global activate -s path packages/rask_cli

which puts `rask` in `~/.pub-cache/bin`. `dart install rask_cli@{path: …}` does not work here: it resolves
`rask_cli` outside the workspace and cannot find the unpublished `rask` library.

When a `rask.dart` exists, the first run compiles it (`rask: compiling rask.dart …`, a few seconds);
later runs start in milliseconds. See the `rask` package README for tasks, caching and releasing.
