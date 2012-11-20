library parser_test;

import 'dart:io';
import 'package:unittest/unittest.dart';
import 'package:unittest/vm_config.dart';
import 'package:html5plus/dom.dart';
import 'package:html5plus/parser.dart';
import 'package:html5plus/src/constants.dart';
import 'package:html5plus/src/tokenizer.dart';
import 'package:html5plus/src/utils.dart';
import 'support.dart';

// Run the parse error checks
// TODO(jmesserly): presumably we want this on by default?
final checkParseErrors = false;

String namespaceHtml(String expected) {
  // TODO(jmesserly): this is a workaround for http://dartbug.com/2979
  // We can't do regex replace directly =\
  // final namespaceExpected = new RegExp(@"^(\s*)<(\S+)>", multiLine: true);
  // return expected.replaceAll(namespaceExpected, @"$1<html $2>");
  final namespaceExpected = new RegExp(r"^(\|\s*)<(\S+)>");
  var lines =  expected.split("\n");
  for (int i = 0; i < lines.length; i++) {
    var match = namespaceExpected.firstMatch(lines[i]);
    if (match != null) {
      lines[i] = "${match[1]}<html ${match[2]}>";
    }
  }
  return Strings.join(lines, "\n");
}

void runParserTest(String groupName, String innerHTML, String input,
    String expected, List errors, TreeBuilderFactory treeCtor,
    bool namespaceHTMLElements) {

  // XXX - move this out into the setup function
  // concatenate all consecutive character tokens into a single token
  var builder = treeCtor(namespaceHTMLElements);
  var parser = new HtmlParser(input, tree: builder);

  Node document;
  if (innerHTML != null) {
    document = parser.parseFragment(innerHTML);
  } else {
    document = parser.parse();
  }

  var output = testSerializer(document);

  if (namespaceHTMLElements) {
    expected = namespaceHtml(expected);
  }

  expect(output, equals(expected), reason:
      "\n\nInput:\n$input\n\nExpected:\n$expected\n\nReceived:\n$output");

  if (checkParseErrors) {
    expect(parser.errors.length, equals(errors.length), reason:
        "\n\nInput:\n$input\n\nExpected errors (${errors.length}):\n"
        "${Strings.join(errors, '\n')}\n\n"
        "Actual errors (${parser.errors.length}):\n"
        "${Strings.join(parser.errors.map((e) => '$e'), '\n')}");
  }
}


void main() {
  useVmConfiguration();
  getDataFiles('tree-construction').then((files) {
    for (var path in files) {
      var tests = new TestData(path, "data");
      var testName = new Path.fromNative(path).filename.replaceAll(".dat", "");

      group(testName, () {
        int index = 0;
        for (var testData in tests) {
          var input = testData['data'];
          var errors = testData['errors'];
          var innerHTML = testData['document-fragment'];
          var expected = testData['document'];
          if (errors != null) {
            errors = errors.split("\n");
          }

          for (var treeCtor in treeTypes.values) {
            for (var namespaceHTMLElements in const [false, true]) {
              test(input, () {
                runParserTest(testName, innerHTML, input, expected, errors,
                    treeCtor, namespaceHTMLElements);
              });
            }
          }

          index++;
        }
      });
    }
  });
}
