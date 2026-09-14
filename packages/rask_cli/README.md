# rask_cli

The `rask` command. Install it with

    dart install rask_cli

and run `rask test`, `rask analyze`, `rask pub get`, `rask bump`, `rask publish`, or any task a `rask.dart`
at your workspace root defines. The library that `rask.dart` imports is `package:rask` — add it under the
root `dev_dependencies`.

To run the command from a checkout of this repository (when developing rask itself), activate it from inside the workspace:

    dart pub global activate -s path packages/rask_cli

which puts `rask` in `~/.pub-cache/bin`. (`dart install rask_cli@{path: …}` resolves `rask_cli` outside the
workspace, so it only works once the `rask` version it depends on is on pub.dev.)

When a `rask.dart` exists, the first run compiles it (`rask: compiling rask.dart …`, a few seconds);
later runs start in milliseconds. See the `rask` package README for tasks, caching and releasing.
