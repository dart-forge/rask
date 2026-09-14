## Unreleased

- The per-package header line is now `rask: <pkg> — <task>` (it used to be
  `rask: <pkg> — dart <verb> <args>`).
- A package a task does not apply to now prints nothing for it (it used to
  print a `skip (no *_test.dart …)` line).
- Cache keys moved to v2. The first run after upgrading re-runs everything;
  old entries under `.dart_tool/rask/cache` are not cleaned up and can be
  deleted at any time.
- builtin `test`/`analyze` declare `dependsOn: ['^test']` / `['^analyze']`,
  keeping dependency-first ordering; override in `rask.dart` if you want
  more parallelism.

## 1.0.0

- Initial version.
