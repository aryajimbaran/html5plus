html5plus
=========

This is a fork of [html5lib](https://github.com/dart-lang/html5lib) to support XML better. For a pure HTML5 parser, please use [html5lib](https://github.com/dart-lang/html5lib) instead.

Differences to html5lib
-----------------------

Basically, html5plus is amlost exactly the same as html5lib, except:

* Like XML, self-closing tags, such as &lt;div/>, are handled as the leaf nodes (this is the only reason this fork exists).

For example,

    <div/>
    <div>foo</div>

will be interpreted as follows in html5plus.

    <div></div>
    <div>foo</div>

On the other hand, htm5lib and many browsers will interpret it as follows:

    <div>
      <div>foo</div>
    </div>

* Support processing instructions (a pull request was sent to html5lib).
* HtmlParser has an additional flag called cdataOK. It controls whether CDATA is always accepted, including the `http://www.w3.org/1999/xhtml` namespace.
* Support the line number information (Node.lineNumber).
 * Notice that it is not available in Text node and it broke the compatibility with `dart:html`.

Installation
------------

Add this to your `pubspec.yaml` (or create it):
```yaml
dependencies:
  html5plus: any
```

Usage
-----

Parsing HTML is easy!
```dart
import 'package:html5plus/parser.dart' show parse;
import 'package:html5plus/dom.dart';

main() {
  var document = parse(
      '<body>Hello world! <a href="www.html5rocks.com">HTML5 rocks!');
  print(document.outerHtml);
}
```
