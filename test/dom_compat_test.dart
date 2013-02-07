library dom_compat_test;

import 'dart:async';
import 'dart:io';
import 'package:unittest/unittest.dart';
import 'package:unittest/compact_vm_config.dart';
import 'package:html5plus/dom.dart';

part 'dom_compat_test_definitions.dart';

main() {
  useCompactVMConfiguration();

  registerDomCompatTests();

  test('DumpRenderTree', () {
    _runDrt('test/browser/browser_tests.html');
  });
}

void _runDrt(String htmlFile) {
  final allPassedRegExp = new RegExp('All \\d+ tests passed');

  final future = Process.run('DumpRenderTree', [htmlFile])
    .then((ProcessResult pr) {
      expect(pr.exitCode, 0);
      expect(pr.stdout, matches(allPassedRegExp), reason: pr.stdout);
    });

  expect(future, completion(isNull));
}
