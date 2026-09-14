## Unreleased

- rask.dart at the workspace root is loaded: compiled once with dart compile
  exe (cached by content), then exec'd. Requires rask in the root
  dev_dependencies. rask pub bypasses it.
- package:rask/rask.dart now exports only what a rask.dart needs; the
  machinery moved to package:rask/engine.dart.
- The per-package header line is now `rask: <pkg> — <task>` (it used to be
  `rask: <pkg> — dart <verb> <args>`).
- A package a task does not apply to now prints nothing for it (it used to
  print a `skip (no *_test.dart …)` line).
- Cache keys moved to v2. The first run after upgrading re-runs everything;
  old entries under `.dart_tool/rask/cache` are not cleaned up and can be
  deleted at any time.
- `test` and `analyze` no longer wait for dependency packages — all selected
  packages run as one parallel stage (first failure still stops new starts).
  `-F` selects exactly the named packages.

## 1.0.0

- Initial version.
