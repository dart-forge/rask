// rask.dart — rask's own configuration (dogfood).
import 'package:rask/rask.dart';

final config = defineConfig(
  tasks: [
    // `rask format` fails when any Dart file is not formatted.
    Task(
      'format',
      description: 'Check formatting with dart format --set-exit-if-changed.',
      run: (ctx) =>
          ctx.dart(['format', '--set-exit-if-changed', '--output=none', '.']),
    ),
  ],
);
