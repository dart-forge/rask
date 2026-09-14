import 'package:rask/src/workspace/topological_order.dart';
import 'package:test/test.dart';

void main() {
  test('dependencies come before dependents', () {
    final order = topologicalOrder({
      'tmp1': {'tmp2', 'tmp3'},
      'tmp2': {},
      'tmp3': {'tmp4'},
      'tmp4': {},
    });

    expect(order.indexOf('tmp2'), lessThan(order.indexOf('tmp1')));
    expect(order.indexOf('tmp3'), lessThan(order.indexOf('tmp1')));
    expect(order.indexOf('tmp4'), lessThan(order.indexOf('tmp3')));
    expect(order, hasLength(4));
  });

  test('is deterministic: independent nodes keep input order', () {
    final order = topologicalOrder({
      'b': {},
      'a': {},
      'c': {'a'},
    });
    expect(order, ['b', 'a', 'c']);
  });

  test('throws on a cycle naming the packages involved', () {
    expect(
      () => topologicalOrder({
        'a': {'b'},
        'b': {'a'},
      }),
      throwsA(
        isA<CyclicDependencyException>().having(
          (e) => e.cycle,
          'cycle',
          containsAll(['a', 'b']),
        ),
      ),
    );
  });

  test('ignores edges to packages outside the graph', () {
    expect(
      topologicalOrder({
        'a': {'external'},
      }),
      ['a'],
    );
  });
}
