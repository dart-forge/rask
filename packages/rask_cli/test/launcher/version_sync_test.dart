import 'dart:io';

import 'package:rask_cli/src/launcher/launcher.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('raskVersion matches pubspec.yaml version (update both on bump)', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(raskVersion, pubspec['version']);
  });
}
