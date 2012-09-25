/** Additional feature tests that aren't based on test data. */
library dom_test;

import 'dart:io';
import 'package:unittest/unittest.dart';
import 'package:unittest/vm_config.dart';
import 'package:html5lib/html5parser.dart';
import 'package:html5lib/dom.dart';

main() {
  useVmConfiguration();

  group('Node.query type selectors', () {
    test('x-foo', () {
      expect(parse('<x-foo>').body.query('x-foo'), isNotNull);
    });

    test('-x-foo', () {
      var doc = parse('<body><-x-foo>');
      expect(doc.body.outerHTML, equals('<body>&lt;-x-foo&gt;</body>'));
      expect(doc.body.query('-x-foo'), isNull);
    });

    test('foo123', () {
      expect(parse('<foo123>').body.query('foo123'), isNotNull);
    });

    test('123 - invalid', () {
      var doc = parse('<123>');
      expect(() => doc.body.query('123'), throwsNotImplementedException);
    });

    test('x\\ny - not implemented', () {
      var doc = parse('<x\\ny>');
      expect(() => doc.body.query('x\\ny'), throwsNotImplementedException);
    });
  });
}
