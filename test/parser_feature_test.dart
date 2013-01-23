/** Additional feature tests that aren't based on test data. */
library parser_test;

import 'dart:io';
import 'package:unittest/unittest.dart';
import 'package:unittest/compact_vm_config.dart';
import 'package:html5plus/dom.dart';
import 'package:html5plus/parser.dart';
import 'package:html5plus/parser_console.dart' as parser_console;
import 'package:html5plus/src/constants.dart';
import 'package:html5plus/src/inputstream.dart' as inputstream;
import 'package:html5plus/src/tokenizer.dart';
import 'package:html5plus/src/treebuilder.dart';
import 'support.dart';

main() {
  useCompactVMConfiguration();

  test('doctype is cloneable', () {
    var doc = parse('<!DOCTYPE HTML>');
    DocumentType doctype = doc.nodes[0];
    expect(doctype.clone().outerHTML, equals('<!DOCTYPE html>'));
  });

  test('line counter', () {
    // http://groups.google.com/group/html5lib-discuss/browse_frm/thread/f4f00e4a2f26d5c0
    var doc = parse("<pre>\nx\n&gt;\n</pre>");
    expect(doc.body.innerHTML, equals("<pre>x\n&gt;\n</pre>"));
  });

  test('namespace html elements on', () {
    var doc = new HtmlParser('', tree: new TreeBuilder(true)).parse();
    expect(doc.nodes[0].namespace, equals(Namespaces.html));
  });

  test('namespace html elements off', () {
    var doc = new HtmlParser('', tree: new TreeBuilder(false)).parse();
    expect(doc.nodes[0].namespace, isNull);
  });

  test('parse error spans - full', () {
    var parser = new HtmlParser('''
<!DOCTYPE html>
<html>
  <body>
  <!DOCTYPE html>
  </body>
</html>
''', generateSpans: true);
    var doc = parser.parse();
    expect(doc.body.outerHTML, equals('<body>\n  \n  \n\n</body>'));
    expect(parser.errors.length, equals(1));
    ParseError error = parser.errors[0];
    expect(error.errorCode, equals('unexpected-doctype'));

    // Note: these values are 0-based, but the printed format is 1-based.
    expect(error.span.line, equals(3));
    expect(error.span.endLine, equals(3));
    expect(error.span.column, equals(2));
    expect(error.span.endColumn, equals(17));
    expect(error.span.sourceText, equals('<!DOCTYPE html>'));

    expect(error.toString(), equals('''
ParseError:4:3: Unexpected DOCTYPE. Ignored.
  <!DOCTYPE html>
  ^^^^^^^^^^^^^^^'''));
  });

  test('parse error spans - minimal', () {
    var parser = new HtmlParser('''
<!DOCTYPE html>
<html>
  <body>
  <!DOCTYPE html>
  </body>
</html>
''');
    var doc = parser.parse();
    expect(doc.body.outerHTML, equals('<body>\n  \n  \n\n</body>'));
    expect(parser.errors.length, equals(1));
    ParseError error = parser.errors[0];
    expect(error.errorCode, equals('unexpected-doctype'));
    expect(error.span.line, equals(3));
    // Note: error position is at the end, not the beginning
    expect(error.span.column, equals(17));
  });

  test('void element innerHTML', () {
    var doc = parse('<div></div>');
    expect(doc.body.innerHTML, '<div></div>');
    doc = parse('<body><script></script></body>');
    expect(doc.body.innerHTML, '<script></script>');
    doc = parse('<br>');
    expect(doc.body.innerHTML, '<br>');
    doc = parse('<br><foo><bar>');
    expect(doc.body.innerHTML, '<br><foo><bar></bar></foo>');
  });

  test('empty document has html, body, and head', () {
    var doc = parse('');
    expect(doc.outerHTML, equals('<html><head></head><body></body></html>'));
    expect(doc.head.outerHTML, equals('<head></head>'));
    expect(doc.body.outerHTML, equals('<body></body>'));
  });

  test('strange table case', () {
    var doc = parseFragment('<table><tbody><foo>');
    expect(doc.outerHTML, equals('<foo></foo><table><tbody></tbody></table>'));
  });

  group('html serialization', () {
    test('attribute order', () {
      // Note: the spec only requires a stable order.
      // However, we preserve the input order via LinkedHashMap
      var doc = parseFragment('<foo d=1 a=2 c=3 b=4>');
      expect(doc.outerHTML, equals('<foo d="1" a="2" c="3" b="4"></foo>'));
      expect(doc.query('foo').attributes.remove('a'), equals('2'));
      expect(doc.outerHTML, equals('<foo d="1" c="3" b="4"></foo>'));
      doc.query('foo').attributes['a'] = '0';
      expect(doc.outerHTML, equals('<foo d="1" c="3" b="4" a="0"></foo>'));
    });

    test('escaping Text node in <script>', () {
      var doc = parseFragment('<script>a && b</script>');
      expect(doc.outerHTML, equals('<script>a && b</script>'));
    });

    test('escaping Text node in <span>', () {
      var doc = parseFragment('<span>a && b</span>');
      expect(doc.outerHTML, equals('<span>a &amp;&amp; b</span>'));
    });

    test('Escaping attributes', () {
      var doc = parseFragment('<div class="a<b>">');
      expect(doc.outerHTML, equals('<div class="a<b>"></div>'));
      doc = parseFragment('<div class=\'a"b\'>');
      expect(doc.outerHTML, equals('<div class="a&quot;b"></div>'));
    });

    test('Escaping non-breaking space', () {
      var text = '<span>foO\u00A0bar</span>';
      expect(text.charCodeAt(text.indexOf('O') + 1), equals(0xA0));
      var doc = parseFragment(text);
      expect(doc.outerHTML, equals('<span>foO&nbsp;bar</span>'));
    });

    test('Newline after <pre>', () {
      var doc = parseFragment('<pre>\n\nsome text</span>');
      expect(doc.query('pre').nodes[0].value, equals('\nsome text'));
      expect(doc.outerHTML, equals('<pre>\n\nsome text</pre>'));

      doc = parseFragment('<pre>\nsome text</span>');
      expect(doc.query('pre').nodes[0].value, equals('some text'));
      expect(doc.outerHTML, equals('<pre>some text</pre>'));
    });

    test('xml namespaces', () {
      // Note: this is a nonsensical example, but it triggers the behavior
      // we're looking for with attribute names in foreign content.
      var doc = parse('''
        <body>
        <svg>
        <desc xlink:type="simple"
              xlink:href="http://example.com/logo.png"
              xlink:show="new"></desc>
      ''');
      var n = doc.query('desc');
      var keys = n.attributes.keys.toList();
      expect(keys[0], new isInstanceOf<AttributeName>());
      expect(keys[0].prefix, equals('xlink'));
      expect(keys[0].namespace, equals('http://www.w3.org/1999/xlink'));
      expect(keys[0].name, equals('type'));

      expect(n.outerHTML, equals('<desc xlink:type="simple" '
        'xlink:href="http://example.com/logo.png" xlink:show="new"></desc>'));
    });
  });

  test('dart:io', () {
    // ensure IO support is unregistered
    expect(inputstream.consoleSupport,
      new isInstanceOf<inputstream.ConsoleSupport>());
    var file = new File('test/data/parser_feature/raw_file.html').openSync();
    expect(() => parse(file), throwsA(new isInstanceOf<ArgumentError>()));
    parser_console.useConsole();
    expect(parse(file).body.innerHTML.trim(), equals('Hello world!'));
  });

  test('error printing without spans', () {
    var parser = new HtmlParser('foo');
    var doc = parser.parse();
    expect(doc.body.innerHTML, equals('foo'));
    expect(parser.errors.length, equals(1));
    expect(parser.errors[0].errorCode,
        equals('expected-doctype-but-got-chars'));
    expect(parser.errors[0].message,
        equals('Unexpected non-space characters. Expected DOCTYPE.'));
    expect(parser.errors[0].toString(),
        equals('ParseError:1:4: Unexpected non-space characters. '
               'Expected DOCTYPE.'));
  });
}
