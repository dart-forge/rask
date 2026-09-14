# rask

Workspace-aware task runner for Dart. The verbs `dart` is missing.

`dart` knows how to test, analyze and publish one package. rask runs those verbs
across a whole pub workspace — in parallel where packages are independent, with
filters — from any directory inside it. No configuration file is needed: the
dependency graph comes from `pubspec.yaml` alone.

## Usage

```sh
rask test                       # dart test in every package (independent packages in parallel)
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

Every verb is a *task*: `test` and `analyze` are built in, and a `rask.dart`
at the workspace root can add more or change theirs (`dependsOn`, `inputs`,
`outputs`). Loading `rask.dart` is not wired up yet; the engine is. Built-in
`test` and `analyze` declare no `dependsOn`, so all selected packages run as
one stage; add `Task('test', dependsOn: ['^test'])` in `rask.dart` to make
them wait for their dependencies.

Packages with no `*_test.dart` under `test/` are skipped by `rask test`.
The first failing package stops the run and its exit code is returned.

Tasks run in parallel, stage by stage: a node (task × package) starts once
every node it `dependsOn` has finished, and nodes without such edges — the
built-in `test` and `analyze` among them — share one stage. The
output of packages that run together is captured and printed per package;
a package that runs alone streams to the terminal. After a failure nothing
new starts, running packages are awaited, and the first failure's exit code
is returned.

`-j` defaults to the number of CPU cores and multiplies with `dart test`'s own
suite-level parallelism, so on CI pin a smaller value (`rask test -j 2`). Whether a
package streams or is captured depends on how many packages in its stage are
uncached, so the same package may print with colours in one run and plain in the
next; the content is the same.

Nested workspaces (a member with its own `workspace:` section) are flattened
into the top-level root, exactly as pub resolves them.

## Caching

A package whose inputs have not changed since its last successful run is
skipped. The key covers the task with its arguments, the task's `inputs`
(default: every file in the package) minus its own `outputs`, every file of
the workspace members it depends on (transitively), the keys of the tasks it
`dependsOn`, the root `pubspec.yaml` and `pubspec.lock`, and the Dart SDK
version. `.dart_tool/` and `build/` are ignored for `inputs`, but not for a
task's own `outputs` — those are read wherever they are declared, including
under `build/` or `.dart_tool/`; `.git/` is always ignored. Nothing is derived
from git state or timestamps: a wrong skip is worse than a slow run.

Even on a key hit, the `outputs` are re-hashed and compared against what they
were when the run was recorded; a mismatch (a deleted or edited output) reruns
the task rather than trusting a stale skip.

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

Early. The task engine (tasks, `dependsOn`, staged parallel runs, cache with
output verification) is in. Loading `rask.dart`, the codegen declaration API
and the `dev`/`build` plugin API are not implemented yet.
