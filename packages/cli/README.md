# rask

Workspace-aware task runner for Dart. The verbs `dart` is missing.

`dart` knows how to test, analyze and publish one package. rask runs those verbs
across a whole pub workspace — dependencies first, with filters — from any
directory inside it. No configuration file is needed: the dependency graph comes
from `pubspec.yaml` alone.

## Usage

```sh
rask test                       # dart test in every package, dependencies first
rask analyze                    # dart analyze in every package
rask pub get                    # dart pub get at the workspace root
rask test -F my_pkg             # only my_pkg
rask test -F 'my_pkg...'        # my_pkg and everything that depends on it
rask test -F '...my_pkg'        # my_pkg and everything it depends on
rask test -- --reporter expanded   # arguments after -- go to dart test
rask test --no-cache            # run everything, record nothing
rask test -j 2                  # at most 2 packages at once (default: CPU cores)
rask bump 0.2.0                 # lockstep version bump across the workspace
rask publish --dry-run          # dart pub publish, dependencies first
```

Packages with no `*_test.dart` under `test/` are skipped by `rask test`.
The first failing package stops the run and its exit code is returned.

Packages that do not depend on each other run in parallel, stage by stage:
a package starts once every workspace member it depends on has finished. The
output of packages that run together is captured and printed per package;
a package that runs alone streams to the terminal. After a failure nothing
new starts, running packages are awaited, and the first failure's exit code
is returned.

Nested workspaces (a member with its own `workspace:` section) are flattened
into the top-level root, exactly as pub resolves them.

## Caching

A package whose inputs have not changed since its last successful run is
skipped. The inputs are the contents of every file in the package and in the
workspace members it depends on (transitively), the root `pubspec.yaml` and
`pubspec.lock`, the Dart SDK version, and the verb with its arguments.
`.dart_tool/`, `build/` and `.git/` are ignored. Nothing is derived from git
state or timestamps: a wrong skip is worse than a slow run.

Only successful runs are recorded, under `<root>/.dart_tool/rask/cache/`.
Delete that directory to start over.

## Releasing

`rask bump <version>` sets `version:` on every publishable package (one that
has a version and is not `publish_to: none`), rewrites constraints between
workspace members to `^<version>` — string constraints only; `path:` entries
are left alone — and turns `## Unreleased` into `## <version>` in each
package's CHANGELOG.md. Nothing else is touched; project-specific release
steps stay in your own scripts.

`rask publish` runs `dart pub publish --force` in every publishable package,
dependencies first. Before each one it asks the registry (`publish_to`, or
pub.dev) whether that version already exists and skips it if so, so a run
interrupted halfway can simply be repeated. If the registry cannot be reached
the run stops rather than guessing. `--dry-run` passes `--dry-run` through and
never skips.

## Status

Early. `rask run`, `rask.dart` configuration and the `dev`/`build` plugin API
are not implemented yet.
