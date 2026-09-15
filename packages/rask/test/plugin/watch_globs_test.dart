import 'package:rask/src/plugin/watch_globs.dart';
import 'package:test/test.dart';

void main() {
  group('watchRoots', () {
    test('takes the literal head of each glob', () {
      expect(watchRoots(['lib/**', 'bin/**']), ['lib', 'bin']);
      expect(watchRoots(['lib/src/**/*.dart']), ['lib/src']);
      expect(watchRoots(['web/index.html']), ['web/index.html']);
    });

    test('drops duplicates and nested roots', () {
      expect(watchRoots(['lib/**', 'lib/src/**']), ['lib']);
    });

    test('never watches .dart_tool', () {
      expect(watchRoots(['.dart_tool/rask/gen/**', 'lib/**']), ['lib']);
    });

    test('an empty glob list watches nothing', () {
      expect(watchRoots(const []), isEmpty);
    });

    test('a character class is a glob character too', () {
      expect(watchRoots(['lib/[ab]/**']), ['lib']);
    });
  });

  group('matchesWatch', () {
    test('matches by glob', () {
      expect(matchesWatch('lib/a.dart', ['lib/**']), isTrue);
      expect(matchesWatch('lib/src/b.dart', ['lib/**']), isTrue);
      expect(matchesWatch('test/a_test.dart', ['lib/**']), isFalse);
    });

    test('never matches anything under .dart_tool', () {
      expect(
        matchesWatch('.dart_tool/rask/gen/app_gen/lib/g.dart', ['**']),
        isFalse,
      );
    });
  });
}
