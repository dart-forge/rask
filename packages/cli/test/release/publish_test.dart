import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rask/src/release/publish.dart';
import 'package:rask/src/workspace/workspace.dart';
import 'package:test/test.dart';

import '../helpers/recording_runner.dart';

class FakeRegistry implements PackageRegistry {
  /// host -> package -> published versions
  final Map<String, Map<String, Set<String>>> published;
  final Set<String> failingHosts;
  final queries = <(String, String)>[];
  FakeRegistry({this.published = const {}, this.failingHosts = const {}});
  @override
  Future<bool> hasVersion({
    required String host,
    required String name,
    required String version,
  }) async {
    queries.add((host, name));
    if (failingHosts.contains(host)) throw const SocketException('offline');
    return published[host]?[name]?.contains(version) ?? false;
  }
}

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rask_publish_');
    void write(String rel, String content) {
      final f = File(p.join(root.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    write(
      'pubspec.yaml',
      'name: _\npublish_to: none\nworkspace:\n  - packages/*\n  - examples/*\n',
    );
    write('packages/core/pubspec.yaml', 'name: core\nversion: 0.2.0\n');
    write(
      'packages/server/pubspec.yaml',
      'name: server\nversion: 0.2.0\ndependencies:\n  core: ^0.2.0\n',
    );
    write(
      'packages/internal/pubspec.yaml',
      'name: internal\nversion: 0.2.0\npublish_to: https://pub.example.com\ndependencies:\n  core: ^0.2.0\n',
    );
    write('packages/unversioned/pubspec.yaml', 'name: unversioned\n');
    write(
      'examples/demo/pubspec.yaml',
      'name: demo\npublish_to: none\nversion: 1.0.0\ndependencies:\n  server: any\n',
    );
    ws = Workspace.load(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(int, RecordingRunner, FakeRegistry, String)> publish({
    List<Package>? packages,
    bool dryRun = false,
    FakeRegistry? registry,
    Map<String, int> exitCodes = const {},
  }) async {
    final runner = RecordingRunner(exitCodes: exitCodes);
    final reg = registry ?? FakeRegistry();
    final out = StringBuffer();
    final code = await publishPackages(
      packages ?? ws.inOrder,
      runner: runner,
      registry: reg,
      out: out,
      dryRun: dryRun,
    );
    return (code, runner, reg, out.toString());
  }

  List<String> dirs(RecordingRunner r) =>
      r.calls.map((c) => p.basename(c.$3)).toList();

  test('publishes only publishable members: skips publish_to: none and versionless', () async {
    final (code, runner, _, out) = await publish();
    expect(code, 0);
    expect(dirs(runner), unorderedEquals(['core', 'server', 'internal']));
    expect(out, contains('demo'));
    expect(out, contains('unversioned'));
  });

  test('publishes dependencies before dependents', () async {
    final (_, runner, _, _) = await publish();
    final d = dirs(runner);
    expect(d.indexOf('core'), lessThan(d.indexOf('server')));
    expect(d.indexOf('core'), lessThan(d.indexOf('internal')));
  });

  test(
    'a real run passes --force; a dry run passes --dry-run and no --force',
    () async {
      final (_, real, _, _) = await publish(packages: [ws['core']]);
      expect(real.calls.single.$2, ['pub', 'publish', '--force']);
      final (_, dry, _, _) = await publish(
        packages: [ws['core']],
        dryRun: true,
      );
      expect(dry.calls.single.$2, ['pub', 'publish', '--dry-run']);
    },
  );

  test('skips a package whose version the registry already has', () async {
    final reg = FakeRegistry(
      published: {
        'https://pub.dev': {
          'core': {'0.2.0'},
        },
      },
    );
    final (code, runner, _, out) = await publish(registry: reg);
    expect(code, 0);
    expect(dirs(runner), unorderedEquals(['server', 'internal']));
    expect(out, contains('core'));
    expect(out, contains('already published'));
  });

  test('asks the publish_to host for privately published packages', () async {
    final (_, _, reg, _) = await publish(
      packages: [ws['internal'], ws['core']],
    );
    expect(
      reg.queries,
      containsAll([
        ('https://pub.example.com', 'internal'),
        ('https://pub.dev', 'core'),
      ]),
    );
  });

  test(
    'a dry run still consults the registry but never skips because of it',
    () async {
      final reg = FakeRegistry(
        published: {
          'https://pub.dev': {
            'core': {'0.2.0'},
          },
        },
      );
      final (_, runner, _, out) = await publish(
        packages: [ws['core']],
        dryRun: true,
        registry: reg,
      );
      expect(dirs(runner), ['core']);
      expect(out, contains('already published'));
    },
  );

  test('a registry failure stops the run instead of skipping', () async {
    final reg = FakeRegistry(failingHosts: {'https://pub.dev'});
    final (code, runner, _, out) = await publish(
      packages: [ws['core']],
      registry: reg,
    );
    expect(code, isNot(0));
    expect(runner.calls, isEmpty);
    expect(out, contains('pub.dev'));
  });

  test('stops at the first failed publish and returns its exit code', () async {
    final (code, runner, _, _) = await publish(exitCodes: {'core': 65});
    expect(code, 65);
    expect(dirs(runner), ['core']);
  });
}
