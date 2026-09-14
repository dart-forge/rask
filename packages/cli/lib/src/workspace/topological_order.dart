/// Thrown when [topologicalOrder] finds a dependency cycle.
class CyclicDependencyException implements Exception {
  /// The packages that form the cycle, in the order they were visited.
  final List<String> cycle;

  CyclicDependencyException(this.cycle);

  @override
  String toString() =>
      'Cyclic dependency: ${[...cycle, cycle.first].join(' -> ')}';
}

/// Orders the nodes of [graph] so that every node comes after the nodes it
/// depends on.
///
/// [graph] maps a node to the nodes it depends on. Edges to nodes that are
/// not keys of [graph] are ignored, so a workspace graph can carry hosted
/// dependencies without filtering them first.
///
/// The result is deterministic: nodes are visited in the iteration order of
/// [graph], and dependencies in the iteration order of their set.
List<String> topologicalOrder(Map<String, Set<String>> graph) {
  final sorted = <String>[];
  final done = <String>{};
  final path = <String>[];

  void visit(String node) {
    if (done.contains(node)) return;
    final cycleStart = path.indexOf(node);
    if (cycleStart != -1) {
      throw CyclicDependencyException(path.sublist(cycleStart));
    }
    path.add(node);
    for (final dep in graph[node] ?? const <String>{}) {
      if (graph.containsKey(dep)) visit(dep);
    }
    path.removeLast();
    done.add(node);
    sorted.add(node);
  }

  for (final node in graph.keys) {
    visit(node);
  }
  return sorted;
}
