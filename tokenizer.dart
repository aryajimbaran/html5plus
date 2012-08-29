#library('tokenizer');

#import('dart:math');
#import('lib/constants.dart');
#import('lib/inputstream.dart');
#import('lib/token.dart');
#import('lib/utils.dart');
#import('html5parser.dart', prefix: 'html5parser');

// Group entities by their first character, for faster lookups

// TODO(jmesserly): we could use a better data structure here like a trie, if
// we had it implemented in Dart.
Map<String, List<String>> _entitiesByFirstChar;
Map<String, List<String>> get entitiesByFirstChar {
  if (_entitiesByFirstChar == null) {
    _entitiesByFirstChar = {};
    for (var k in entities.getKeys()) {
      _entitiesByFirstChar.putIfAbsent(k[0], () => []).add(k);
    }
  }
  return _entitiesByFirstChar;
}

// TODO(jmesserly): lots of ways to make this faster:
// - use char codes everywhere instead of 1-char strings
// - use switch instead of inStr
// - use switch instead of the sequential if tests
// - use an Token class instead of a map for tokens
// - avoid tokenTypes lookup
// - avoid string concat

/**
 * This class takes care of tokenizing HTML.
 */
class HTMLTokenizer implements Iterator<Token> {
  // TODO(jmesserly): a lot of these could be made private

  final HTMLInputStream stream;

  final bool lowercaseElementName;

  final bool lowercaseAttrName;

  html5parser.HTMLParser parser;

  final Queue<Token> tokenQueue;

  /** Holds the token that is currently being processed. */
  Token currentToken;

  /**
   * Holds a reference to the method to be invoked for the next parser state.
   */
  Predicate state;

  String temporaryBuffer;

  HTMLTokenizer(stream,
      [String encoding, bool parseMeta = true,
      this.lowercaseElementName = true, this.lowercaseAttrName = true,
      this.parser])
      : stream = new HTMLInputStream(stream, encoding, parseMeta),
        tokenQueue = new Queue() {
    state = dataState;
  }

  get lastData => currentToken.data.last();

  TagToken get currentTagToken => currentToken;
  DoctypeToken get currentDoctypeToken => currentToken;

  bool hasNext() {
    if (stream.errors.length > 0) return true;
    if (tokenQueue.length > 0) return true;
    // Start processing. When EOF is reached state will return false;
    // instead of true and the loop will terminate.
    do {
      if (!state()) return false;
    } while (stream.errors.length == 0 && tokenQueue.length == 0);
    return true;
  }

  /**
   * This is where the magic happens.
   *
   * We do our usually processing through the states and when we have a token
   * to return we yield the token which pauses processing until the next token
   * is requested.
   */
   Token next() {
    if (hasNext()) {
      if (stream.errors.length > 0) {
        return new ParseErrorToken(removeAt(stream.errors, 0));
      }
      return tokenQueue.removeFirst();
    } else {
      throw const NoMoreElementsException();
    }
  }

  /**
   * This function returns either U+FFFD or the character based on the
   * decimal or hexadecimal representation. It also discards ";" if present.
   * If not present tokenQueue.addLast({"type": TokenKind.parseError});
   * is invoked.
   */
  String consumeNumberEntity(bool isHex) {
    var allowed = isDigit;
    var radix = 10;
    if (isHex) {
      allowed = isHexDigit;
      radix = 16;
    }

    var charStack = [];

    // Consume all the characters that are in range while making sure we
    // don't hit an EOF.
    var c = stream.char();
    while (allowed(c) && c !== EOF) {
      charStack.add(c);
      c = stream.char();
    }

    // Convert the set of characters consumed to an int.
    var charAsInt = parseIntRadix(joinStr(charStack), radix);

    // Certain characters get replaced with others
    var char = replacementCharacters[charAsInt];
    if (char != null) {
      tokenQueue.addLast(new ParseErrorToken(
          "illegal-codepoint-for-numeric-entity",
          datavars: {"charAsInt": charAsInt}));
    } else if ((0xD800 <= charAsInt && charAsInt <= 0xDFFF)
        || (charAsInt > 0x10FFFF)) {
      char = "\uFFFD";
      tokenQueue.addLast(new ParseErrorToken(
          "illegal-codepoint-for-numeric-entity",
          datavars: {"charAsInt": charAsInt}));
    } else {
      // Should speed up this check somehow (e.g. move the set to a constant)
      if ((0x0001 <= charAsInt && charAsInt <= 0x0008) ||
          (0x000E <= charAsInt && charAsInt <= 0x001F) ||
          (0x007F <= charAsInt && charAsInt <= 0x009F) ||
          (0xFDD0 <= charAsInt && charAsInt <= 0xFDEF) ||
          const [0x000B, 0xFFFE, 0xFFFF, 0x1FFFE,
                0x1FFFF, 0x2FFFE, 0x2FFFF, 0x3FFFE,
                0x3FFFF, 0x4FFFE, 0x4FFFF, 0x5FFFE,
                0x5FFFF, 0x6FFFE, 0x6FFFF, 0x7FFFE,
                0x7FFFF, 0x8FFFE, 0x8FFFF, 0x9FFFE,
                0x9FFFF, 0xAFFFE, 0xAFFFF, 0xBFFFE,
                0xBFFFF, 0xCFFFE, 0xCFFFF, 0xDFFFE,
                0xDFFFF, 0xEFFFE, 0xEFFFF, 0xFFFFE,
                0xFFFFF, 0x10FFFE, 0x10FFFF].indexOf(charAsInt) >= 0) {
        tokenQueue.addLast(new ParseErrorToken(
                            "illegal-codepoint-for-numeric-entity",
                            datavars: {"charAsInt": charAsInt}));
      }
      char = new String.fromCharCodes([charAsInt]);
    }

    // Discard the ; if present. Otherwise, put it back on the queue and
    // invoke parseError on parser.
    if (c != ";") {
      tokenQueue.addLast(new ParseErrorToken(
          "numeric-entity-without-semicolon"));
      stream.unget(c);
    }
    return char;
  }

  void consumeEntity([String allowedChar, bool fromAttribute = false]) {
    // Initialise to the default output for when no entity is matched
    var output = "&";

    var charStack = [stream.char()];
    if (isWhitespace(charStack[0]) || charStack[0] == '<' || charStack[0] == '&'
        || charStack[0] == EOF || allowedChar == charStack[0]) {
      stream.unget(charStack[0]);
    } else if (charStack[0] == "#") {
      // Read the next character to see if it's hex or decimal
      bool hex = false;
      charStack.add(stream.char());
      if (charStack.last() == 'x' || charStack.last() == 'X') {
        hex = true;
        charStack.add(stream.char());
      }

      // charStack.last() should be the first digit
      if (hex && isHexDigit(charStack.last()) ||
          (!hex && isDigit(charStack.last()))) {
        // At least one digit found, so consume the whole number
        stream.unget(charStack.last());
        output = consumeNumberEntity(hex);
      } else {
        // No digits found
        tokenQueue.addLast(new ParseErrorToken("expected-numeric-entity"));
        stream.unget(charStack.removeLast());
        output = "&${joinStr(charStack)}";
      }
    } else {
      // At this point in the process might have named entity. Entities
      // are stored in the global variable "entities".
      //
      // Consume characters and compare to these to a substring of the
      // entity names in the list until the substring no longer matches.
      var filteredEntityList = entitiesByFirstChar[charStack[0]];
      if (filteredEntityList == null) filteredEntityList = const [];

      while (charStack.last() !== EOF) {
        var name = joinStr(charStack);
        filteredEntityList = filteredEntityList.filter(
            (e) => e.startsWith(name));

        if (filteredEntityList.length == 0) {
          break;
        }
        charStack.add(stream.char());
      }

      // At this point we have a string that starts with some characters
      // that may match an entity
      String entityName = null;

      // Try to find the longest entity the string will match to take care
      // of &noti for instance.

      int entityLen;
      for (entityLen = charStack.length - 1; entityLen > 1; entityLen--) {
        var possibleEntityName = joinStr(charStack.getRange(0, entityLen));
        if (entities.containsKey(possibleEntityName)) {
          entityName = possibleEntityName;
          break;
        }
      }

      if (entityName !== null) {
        var lastChar = entityName[entityName.length - 1];
        if (lastChar != ";") {
          tokenQueue.addLast(new ParseErrorToken(
              "named-entity-without-semicolon"));
        }
        if (lastChar != ";" && fromAttribute &&
            (isLetterOrDigit(charStack[entityLen]) ||
             charStack[entityLen] == '=')) {
          stream.unget(charStack.removeLast());
          output = "&${joinStr(charStack)}";
        } else {
          output = entities[entityName];
          stream.unget(charStack.removeLast());
          output = '${output}${joinStr(slice(charStack, entityLen))}';
        }
      } else {
        tokenQueue.addLast(new ParseErrorToken("expected-named-entity"));
        stream.unget(charStack.removeLast());
        output = "&${joinStr(charStack)}";
      }
    }
    if (fromAttribute) {
      lastData[1] = '${lastData[1]}${output}';
    } else {
      var token;
      if (isWhitespace(output)) {
        token = new SpaceCharactersToken(output);
      } else {
        token = new CharactersToken(output);
      }
      tokenQueue.addLast(token);
    }
  }

  /** This method replaces the need for "entityInAttributeValueState". */
  void processEntityInAttribute(String allowedChar) {
    consumeEntity(allowedChar: allowedChar, fromAttribute: true);
  }

  /**
   * This method is a generic handler for emitting the tags. It also sets
   * the state to "data" because that's what's needed after a token has been
   * emitted.
   */
  void emitCurrentToken() {
    var token = currentToken;
    // Add token to the queue to be yielded
    if (token is TagToken) {
      if (lowercaseElementName) {
        token.name = asciiUpper2Lower(token.name);
      }
      if (token is EndTagToken) {
        if (token.data.length > 0) {
          tokenQueue.addLast(new ParseErrorToken("attributes-in-end-tag"));
        }
        if (token.selfClosing) {
          tokenQueue.addLast(new ParseErrorToken(
              "this-closing-flag-on-end-tag"));
        }
      }
    }
    tokenQueue.addLast(token);
    state = dataState;
  }


  // Below are the various tokenizer states worked out.

  bool dataState() {
    var data = stream.char();
    if (data == "&") {
      state = entityDataState;
    } else if (data == "<") {
      state = tagOpenState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\u0000"));
    } else if (data === EOF) {
      // Tokenization ends.
      return false;
    } else if (isWhitespace(data)) {
      // Directly after emitting a token you switch back to the "data
      // state". At that point spaceCharacters are important so they are
      // emitted separately.
      tokenQueue.addLast(new SpaceCharactersToken(
          '${data}${stream.charsUntil(spaceCharacters, true)}'));
      // No need to update lastFourChars here, since the first space will
      // have already been appended to lastFourChars and will have broken
      // any <!-- or --> sequences
    } else {
      var chars = stream.charsUntil("&<\u0000");
      tokenQueue.addLast(new CharactersToken('${data}${chars}'));
    }
    return true;
  }

  bool entityDataState() {
    consumeEntity();
    state = dataState;
    return true;
  }

  bool rcdataState() {
    var data = stream.char();
    if (data == "&") {
      state = characterReferenceInRcdata;
    } else if (data == "<") {
      state = rcdataLessThanSignState;
    } else if (data == EOF) {
      // Tokenization ends.
      return false;
    } else if (data == "\u0000") {
        tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
        tokenQueue.addLast(new CharactersToken("\uFFFD"));
    } else if (isWhitespace(data)) {
      // Directly after emitting a token you switch back to the "data
      // state". At that point spaceCharacters are important so they are
      // emitted separately.
      tokenQueue.addLast(new SpaceCharactersToken(
          '${data}${stream.charsUntil(spaceCharacters, true)}'));
    } else {
      var chars = stream.charsUntil("&<");
      tokenQueue.addLast(new CharactersToken('${data}${chars}'));
    }
    return true;
  }

  bool characterReferenceInRcdata() {
    consumeEntity();
    state = rcdataState;
    return true;
  }

  bool rawtextState() {
    var data = stream.char();
    if (data == "<") {
      state = rawtextLessThanSignState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
    } else if (data == EOF) {
      // Tokenization ends.
      return false;
    } else {
      var chars = stream.charsUntil("<\u0000");
      tokenQueue.addLast(new CharactersToken("${data}${chars}"));
    }
    return true;
  }

  bool scriptDataState() {
    var data = stream.char();
    if (data == "<") {
      state = scriptDataLessThanSignState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
    } else if (data == EOF) {
      // Tokenization ends.
      return false;
    } else {
      var chars = stream.charsUntil("<\u0000");
      tokenQueue.addLast(new CharactersToken("${data}${chars}"));
    }
    return true;
  }

  bool plaintextState() {
    var data = stream.char();
    if (data == EOF) {
      // Tokenization ends.
      return false;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
    } else {
      tokenQueue.addLast(new CharactersToken(
          '${data}${stream.charsUntil("\u0000")}'));
    }
    return true;
  }

  bool tagOpenState() {
    var data = stream.char();
    if (data == "!") {
      state = markupDeclarationOpenState;
    } else if (data == "/") {
      state = closeTagOpenState;
    } else if (isLetter(data)) {
      currentToken = new StartTagToken(data);
      state = tagNameState;
    } else if (data == ">") {
      // XXX In theory it could be something besides a tag name. But
      // do we really care?
      tokenQueue.addLast(new ParseErrorToken(
          "expected-tag-name-but-got-right-bracket"));
      tokenQueue.addLast(new CharactersToken("<>"));
      state = dataState;
    } else if (data == "?") {
      // XXX In theory it could be something besides a tag name. But
      // do we really care?
      tokenQueue.addLast(new ParseErrorToken(
          "expected-tag-name-but-got-question-mark"));
      stream.unget(data);
      state = bogusCommentState;
    } else {
      // XXX
      tokenQueue.addLast(new ParseErrorToken("expected-tag-name"));
      tokenQueue.addLast(new CharactersToken("<"));
      stream.unget(data);
      state = dataState;
    }
    return true;
  }

  bool closeTagOpenState() {
    var data = stream.char();
    if (isLetter(data)) {
      currentToken = new EndTagToken(data);
      state = tagNameState;
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-closing-tag-but-got-right-bracket"));
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-closing-tag-but-got-eof"));
      tokenQueue.addLast(new CharactersToken("</"));
      state = dataState;
    } else {
      // XXX data can be _'_...
      tokenQueue.addLast(new ParseErrorToken(
          "expected-closing-tag-but-got-char", datavars: {"data": data}));
      stream.unget(data);
      state = bogusCommentState;
    }
    return true;
  }

  bool tagNameState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = beforeAttributeNameState;
    } else if (data == ">") {
      emitCurrentToken();
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-tag-name"));
      state = dataState;
    } else if (data == "/") {
      state = selfClosingStartTagState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentTagToken.name = '${currentTagToken.name}\uFFFD';
    } else {
      currentTagToken.name = '${currentTagToken.name}${data}';
      // (Don't use charsUntil here, because tag names are
      // very short and it's faster to not do anything fancy)
    }
    return true;
  }

  bool rcdataLessThanSignState() {
    var data = stream.char();
    if (data == "/") {
      temporaryBuffer = "";
      state = rcdataEndTagOpenState;
    } else {
      tokenQueue.addLast(new CharactersToken("<"));
      stream.unget(data);
      state = rcdataState;
    }
    return true;
  }

  bool rcdataEndTagOpenState() {
    var data = stream.char();
    if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
      state = rcdataEndTagNameState;
    } else {
      tokenQueue.addLast(new CharactersToken("</"));
      stream.unget(data);
      state = rcdataState;
    }
    return true;
  }

  bool _tokenIsAppropriate() {
    return currentToken is TagToken &&
        currentTagToken.name.toLowerCase() == temporaryBuffer.toLowerCase();
  }

  bool rcdataEndTagNameState() {
    var appropriate = _tokenIsAppropriate();
    var data = stream.char();
    if (isWhitespace(data) && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = beforeAttributeNameState;
    } else if (data == "/" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = selfClosingStartTagState;
    } else if (data == ">" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      emitCurrentToken();
      state = dataState;
    } else if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
    } else {
      tokenQueue.addLast(new CharactersToken("</$temporaryBuffer"));
      stream.unget(data);
      state = rcdataState;
    }
    return true;
  }

  bool rawtextLessThanSignState() {
    var data = stream.char();
    if (data == "/") {
      temporaryBuffer = "";
      state = rawtextEndTagOpenState;
    } else {
      tokenQueue.addLast(new CharactersToken("<"));
      stream.unget(data);
      state = rawtextState;
    }
    return true;
  }

  bool rawtextEndTagOpenState() {
    var data = stream.char();
    if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
      state = rawtextEndTagNameState;
    } else {
      tokenQueue.addLast(new CharactersToken("</"));
      stream.unget(data);
      state = rawtextState;
    }
    return true;
  }

  bool rawtextEndTagNameState() {
    var appropriate = _tokenIsAppropriate();
    var data = stream.char();
    if (isWhitespace(data) && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = beforeAttributeNameState;
    } else if (data == "/" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = selfClosingStartTagState;
    } else if (data == ">" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      emitCurrentToken();
      state = dataState;
    } else if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
    } else {
      tokenQueue.addLast(new CharactersToken("</$temporaryBuffer"));
      stream.unget(data);
      state = rawtextState;
    }
    return true;
  }

  bool scriptDataLessThanSignState() {
    var data = stream.char();
    if (data == "/") {
      temporaryBuffer = "";
      state = scriptDataEndTagOpenState;
    } else if (data == "!") {
      tokenQueue.addLast(new CharactersToken("<!"));
      state = scriptDataEscapeStartState;
    } else {
      tokenQueue.addLast(new CharactersToken("<"));
      stream.unget(data);
      state = scriptDataState;
    }
    return true;
  }

  bool scriptDataEndTagOpenState() {
    var data = stream.char();
    if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
      state = scriptDataEndTagNameState;
    } else {
      tokenQueue.addLast(new CharactersToken("</"));
      stream.unget(data);
      state = scriptDataState;
    }
    return true;
  }

  bool scriptDataEndTagNameState() {
    var appropriate = _tokenIsAppropriate();
    var data = stream.char();
    if (isWhitespace(data) && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = beforeAttributeNameState;
    } else if (data == "/" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = selfClosingStartTagState;
    } else if (data == ">" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      emitCurrentToken();
      state = dataState;
    } else if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
    } else {
      tokenQueue.addLast(new CharactersToken("</$temporaryBuffer"));
      stream.unget(data);
      state = scriptDataState;
    }
    return true;
  }

  bool scriptDataEscapeStartState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
      state = scriptDataEscapeStartDashState;
    } else {
      stream.unget(data);
      state = scriptDataState;
    }
    return true;
  }

  bool scriptDataEscapeStartDashState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
      state = scriptDataEscapedDashDashState;
    } else {
      stream.unget(data);
      state = scriptDataState;
    }
    return true;
  }

  bool scriptDataEscapedState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
      state = scriptDataEscapedDashState;
    } else if (data == "<") {
      state = scriptDataEscapedLessThanSignState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
    } else if (data == EOF) {
      state = dataState;
    } else {
      var chars = stream.charsUntil("<-\u0000");
      tokenQueue.addLast(new CharactersToken("${data}${chars}"));
    }
    return true;
  }

  bool scriptDataEscapedDashState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
      state = scriptDataEscapedDashDashState;
    } else if (data == "<") {
      state = scriptDataEscapedLessThanSignState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
      state = scriptDataEscapedState;
    } else if (data == EOF) {
      state = dataState;
    } else {
      tokenQueue.addLast(new CharactersToken(data));
      state = scriptDataEscapedState;
    }
    return true;
  }

  bool scriptDataEscapedDashDashState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
    } else if (data == "<") {
      state = scriptDataEscapedLessThanSignState;
    } else if (data == ">") {
      tokenQueue.addLast(new CharactersToken(">"));
      state = scriptDataState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
      state = scriptDataEscapedState;
    } else if (data == EOF) {
      state = dataState;
    } else {
      tokenQueue.addLast(new CharactersToken(data));
      state = scriptDataEscapedState;
    }
    return true;
  }

  bool scriptDataEscapedLessThanSignState() {
    var data = stream.char();
    if (data == "/") {
      temporaryBuffer = "";
      state = scriptDataEscapedEndTagOpenState;
    } else if (isLetter(data)) {
      tokenQueue.addLast(new CharactersToken("<$data"));
      temporaryBuffer = data;
      state = scriptDataDoubleEscapeStartState;
    } else {
      tokenQueue.addLast(new CharactersToken("<"));
      stream.unget(data);
      state = scriptDataEscapedState;
    }
    return true;
  }

  bool scriptDataEscapedEndTagOpenState() {
    var data = stream.char();
    if (isLetter(data)) {
      temporaryBuffer = data;
      state = scriptDataEscapedEndTagNameState;
    } else {
      tokenQueue.addLast(new CharactersToken("</"));
      stream.unget(data);
      state = scriptDataEscapedState;
    }
    return true;
  }

  bool scriptDataEscapedEndTagNameState() {
    var appropriate = _tokenIsAppropriate();
    var data = stream.char();
    if (isWhitespace(data) && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = beforeAttributeNameState;
    } else if (data == "/" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      state = selfClosingStartTagState;
    } else if (data == ">" && appropriate) {
      currentToken = new EndTagToken(temporaryBuffer);
      emitCurrentToken();
      state = dataState;
    } else if (isLetter(data)) {
      temporaryBuffer = '${temporaryBuffer}${data}';
    } else {
      tokenQueue.addLast(new CharactersToken("</$temporaryBuffer"));
      stream.unget(data);
      state = scriptDataEscapedState;
    }
    return true;
  }

  bool scriptDataDoubleEscapeStartState() {
    var data = stream.char();
    if (isWhitespace(data) || data == "/" || data == ">") {
      tokenQueue.addLast(new CharactersToken(data));
      if (temporaryBuffer.toLowerCase() == "script") {
        state = scriptDataDoubleEscapedState;
      } else {
        state = scriptDataEscapedState;
      }
    } else if (isLetter(data)) {
      tokenQueue.addLast(new CharactersToken(data));
      temporaryBuffer = '${temporaryBuffer}${data}';
    } else {
      stream.unget(data);
      state = scriptDataEscapedState;
    }
    return true;
  }

  bool scriptDataDoubleEscapedState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
      state = scriptDataDoubleEscapedDashState;
    } else if (data == "<") {
      tokenQueue.addLast(new CharactersToken("<"));
      state = scriptDataDoubleEscapedLessThanSignState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
    } else if (data == EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-script-in-script"));
      state = dataState;
    } else {
      tokenQueue.addLast(new CharactersToken(data));
    }
    return true;
  }

  bool scriptDataDoubleEscapedDashState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
      state = scriptDataDoubleEscapedDashDashState;
    } else if (data == "<") {
      tokenQueue.addLast(new CharactersToken("<"));
      state = scriptDataDoubleEscapedLessThanSignState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
      state = scriptDataDoubleEscapedState;
    } else if (data == EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-script-in-script"));
      state = dataState;
    } else {
      tokenQueue.addLast(new CharactersToken(data));
      state = scriptDataDoubleEscapedState;
    }
    return true;
  }

  // TODO(jmesserly): report bug in original code
  // (was "Dash" instead of "DashDash")
  bool scriptDataDoubleEscapedDashDashState() {
    var data = stream.char();
    if (data == "-") {
      tokenQueue.addLast(new CharactersToken("-"));
    } else if (data == "<") {
      tokenQueue.addLast(new CharactersToken("<"));
      state = scriptDataDoubleEscapedLessThanSignState;
    } else if (data == ">") {
      tokenQueue.addLast(new CharactersToken(">"));
      state = scriptDataState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      tokenQueue.addLast(new CharactersToken("\uFFFD"));
      state = scriptDataDoubleEscapedState;
    } else if (data == EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-script-in-script"));
      state = dataState;
    } else {
      tokenQueue.addLast(new CharactersToken(data));
      state = scriptDataDoubleEscapedState;
    }
    return true;
  }

  bool scriptDataDoubleEscapedLessThanSignState() {
    var data = stream.char();
    if (data == "/") {
      tokenQueue.addLast(new CharactersToken("/"));
      temporaryBuffer = "";
      state = scriptDataDoubleEscapeEndState;
    } else {
      stream.unget(data);
      state = scriptDataDoubleEscapedState;
    }
    return true;
  }

  bool scriptDataDoubleEscapeEndState() {
    var data = stream.char();
    if (isWhitespace(data) || data == "/" || data == ">") {
      tokenQueue.addLast(new CharactersToken(data));
      if (temporaryBuffer.toLowerCase() == "script") {
        state = scriptDataEscapedState;
      } else {
        state = scriptDataDoubleEscapedState;
      }
    } else if (isLetter(data)) {
      tokenQueue.addLast(new CharactersToken(data));
      temporaryBuffer = '${temporaryBuffer}${data}';
    } else {
      stream.unget(data);
      state = scriptDataDoubleEscapedState;
    }
    return true;
  }

  bool beforeAttributeNameState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      stream.charsUntil(spaceCharacters, true);
    } else if (isLetter(data)) {
      currentToken.data.add([data, ""]);
      state = attributeNameState;
    } else if (data == ">") {
      emitCurrentToken();
    } else if (data == "/") {
      state = selfClosingStartTagState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-attribute-name-but-got-eof"));
      state = dataState;
    } else if ("'\"=<".contains(data)) {
      tokenQueue.addLast(new ParseErrorToken(
          "invalid-character-in-attribute-name"));
      currentToken.data.add([data, ""]);
      state = attributeNameState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data.add(["\uFFFD", ""]);
      state = attributeNameState;
    } else {
      currentToken.data.add([data, ""]);
      state = attributeNameState;
    }
    return true;
  }

  bool attributeNameState() {
    var data = stream.char();
    bool leavingThisState = true;
    bool emitToken = false;
    if (data == "=") {
      state = beforeAttributeValueState;
    } else if (isLetter(data)) {
      lastData[0] = '${lastData[0]}${data}'
          '${stream.charsUntil(asciiLetters, true)}';
      leavingThisState = false;
    } else if (data == ">") {
      // XXX If we emit here the attributes are converted to a dict
      // without being checked and when the code below runs we error
      // because data is a dict not a list
      emitToken = true;
    } else if (isWhitespace(data)) {
      state = afterAttributeNameState;
    } else if (data == "/") {
      state = selfClosingStartTagState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      lastData[0] = '${lastData[0]}\uFFFD';
      leavingThisState = false;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-attribute-name"));
      state = dataState;
    } else if ("'\"<".contains(data)) {
      tokenQueue.addLast(new ParseErrorToken("invalid-character-in-attribute-name"));
      lastData[0] = '${lastData[0]}${data}';
      leavingThisState = false;
    } else {
      lastData[0] = '${lastData[0]}${data}';
      leavingThisState = false;
    }

    if (leavingThisState) {
      // Attributes are not dropped at this stage. That happens when the
      // start tag token is emitted so values can still be safely appended
      // to attributes, but we do want to report the parse error in time.
      if (lowercaseAttrName) {
        lastData[0] = asciiUpper2Lower(lastData[0]);
      }
      for (int i = 0; i < currentToken.data.length - 1; i++) {
        var name = currentToken.data[i][0];
        if (lastData[0] == name) {
          tokenQueue.addLast(new ParseErrorToken("duplicate-attribute"));
          break;
        }
      }
      // XXX Fix for above XXX
      if (emitToken) {
        emitCurrentToken();
      }
    }
    return true;
  }

  bool afterAttributeNameState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      stream.charsUntil(spaceCharacters, true);
    } else if (data == "=") {
      state = beforeAttributeValueState;
    } else if (data == ">") {
      emitCurrentToken();
    } else if (isLetter(data)) {
      currentToken.data.add([data, ""]);
      state = attributeNameState;
    } else if (data == "/") {
      state = selfClosingStartTagState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data.add(["\uFFFD", ""]);
      state = attributeNameState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-end-of-tag-but-got-eof"));
      state = dataState;
    } else if ("'\"<".contains(data)) {
      tokenQueue.addLast(new ParseErrorToken("invalid-character-after-attribute-name"));
      currentToken.data.add([data, ""]);
      state = attributeNameState;
    } else {
      currentToken.data.add([data, ""]);
      state = attributeNameState;
    }
    return true;
  }

  bool beforeAttributeValueState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      stream.charsUntil(spaceCharacters, true);
    } else if (data == "\"") {
      state = attributeValueDoubleQuotedState;
    } else if (data == "&") {
      state = attributeValueUnQuotedState;
      stream.unget(data);
    } else if (data == "'") {
      state = attributeValueSingleQuotedState;
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-attribute-value-but-got-right-bracket"));
      emitCurrentToken();
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      lastData[1] = '${lastData[1]}\uFFFD';
      state = attributeValueUnQuotedState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-attribute-value-but-got-eof"));
      state = dataState;
    } else if ("=<`".contains(data)) {
      tokenQueue.addLast(new ParseErrorToken(
          "equals-in-unquoted-attribute-value"));
      lastData[1] = '${lastData[1]}${data}';
      state = attributeValueUnQuotedState;
    } else {
      lastData[1] = '${lastData[1]}${data}';
      state = attributeValueUnQuotedState;
    }
    return true;
  }

  bool attributeValueDoubleQuotedState() {
    var data = stream.char();
    if (data == "\"") {
      state = afterAttributeValueState;
    } else if (data == "&") {
      processEntityInAttribute('"');
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      lastData[1] = '${lastData[1]}\uFFFD';
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-attribute-value-double-quote"));
      state = dataState;
    } else {
      lastData[1] = '${lastData[1]}${data}'
          '${stream.charsUntil("\"&")}';
    }
    return true;
  }

  bool attributeValueSingleQuotedState() {
    var data = stream.char();
    if (data == "'") {
      state = afterAttributeValueState;
    } else if (data == "&") {
      processEntityInAttribute("'");
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      lastData[1] = '${lastData[1]}\uFFFD';
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "eof-in-attribute-value-single-quote"));
      state = dataState;
    } else {
      lastData[1] = '${lastData[1]}${data}'
          '${stream.charsUntil("\'&")}';
    }
    return true;
  }

  bool attributeValueUnQuotedState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = beforeAttributeNameState;
    } else if (data == "&") {
      processEntityInAttribute(">");
    } else if (data == ">") {
      emitCurrentToken();
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "eof-in-attribute-value-no-quotes"));
      state = dataState;
    } else if ('"\'=<`'.contains(data)) {
      tokenQueue.addLast(new ParseErrorToken("unexpected-character-in-unquoted-attribute-value"));
      lastData[1] = '${lastData[1]}${data}';
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      lastData[1] = '${lastData[1]}\uFFFD';
    } else {
      lastData[1] = '${lastData[1]}${data}'
          '${stream.charsUntil("&>\"\'=<`$spaceCharacters")}';
    }
    return true;
  }

  bool afterAttributeValueState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = beforeAttributeNameState;
    } else if (data == ">") {
      emitCurrentToken();
    } else if (data == "/") {
      state = selfClosingStartTagState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("unexpected-EOF-after-attribute-value"));
      stream.unget(data);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-character-after-attribute-value"));
      stream.unget(data);
      state = beforeAttributeNameState;
    }
    return true;
  }

  bool selfClosingStartTagState() {
    var data = stream.char();
    if (data == ">") {
      currentTagToken.selfClosing = true;
      emitCurrentToken();
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("unexpected-EOF-after-solidus-in-tag"));
      stream.unget(data);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-character-after-soldius-in-tag"));
      stream.unget(data);
      state = beforeAttributeNameState;
    }
    return true;
  }

  bool bogusCommentState() {
    // Make a new comment token and give it as value all the characters
    // until the first > or EOF (charsUntil checks for EOF automatically)
    // and emit it.
    var data = stream.charsUntil(">");
    data = data.replaceAll("\u0000", "\uFFFD");
    tokenQueue.addLast(new CommentToken(data));

    // Eat the character directly after the bogus comment which is either a
    // ">" or an EOF.
    stream.char();
    state = dataState;
    return true;
  }

  bool markupDeclarationOpenState() {
    var charStack = [stream.char()];
    if (charStack.last() == "-") {
      charStack.add(stream.char());
      if (charStack.last() == "-") {
        currentToken = new CommentToken("");
        state = commentStartState;
        return true;
      }
    } else if (charStack.last() == 'd' || charStack.last() == 'D') {
      var matched = true;
      for (var expected in const ['oO', 'cC', 'tT', 'yY', 'pP', 'eE']) {
        var char = stream.char();
        charStack.add(char);
        if (char == EOF || !expected.contains(char)) {
          matched = false;
          break;
        }
      }
      if (matched) {
        currentToken = new DoctypeToken(correct: true);
        state = doctypeState;
        return true;
      }
    } else if (charStack.last() == "[" &&
        parser !== null && parser.tree.openElements.length > 0 &&
        parser.tree.openElements.last().namespace
            != parser.tree.defaultNamespace) {
      var matched = true;
      for (var expected in const ["C", "D", "A", "T", "A", "["]) {
        charStack.add(stream.char());
        if (charStack.last() != expected) {
          matched = false;
          break;
        }
      }
      if (matched) {
        state = cdataSectionState;
        return true;
      }
    }

    tokenQueue.addLast(new ParseErrorToken("expected-dashes-or-doctype"));

    while (charStack.length > 0) {
      stream.unget(charStack.removeLast());
    }
    state = bogusCommentState;
    return true;
  }

  bool commentStartState() {
    var data = stream.char();
    if (data == "-") {
      state = commentStartDashState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data = '${currentToken.data}\uFFFD';
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("incorrect-comment"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-comment"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentToken.data = '${currentToken.data}${data}';
      state = commentState;
    }
    return true;
  }

  bool commentStartDashState() {
    var data = stream.char();
    if (data == "-") {
      state = commentEndState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data = '${currentToken.data}-\uFFFD';
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("incorrect-comment"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-comment"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentToken.data = '${currentToken.data}-${data}';
      state = commentState;
    }
    return true;
  }

  bool commentState() {
    var data = stream.char();
    if (data == "-") {
      state = commentEndDashState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data = '${currentToken.data}\uFFFD';
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-comment"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentToken.data = '${currentToken.data}${data}'
          '${stream.charsUntil("-\u0000")}';
    }
    return true;
  }

  bool commentEndDashState() {
    var data = stream.char();
    if (data == "-") {
      state = commentEndState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data = "${currentToken.data}-\uFFFD";
      state = commentState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-comment-end-dash"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentToken.data = "${currentToken.data}-${data}";
      state = commentState;
    }
    return true;
  }

  bool commentEndState() {
    var data = stream.char();
    if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data = '${currentToken.data}--\uFFFD';
      state = commentState;
    } else if (data == "!") {
      tokenQueue.addLast(new ParseErrorToken(
          "unexpected-bang-after-double-dash-in-comment"));
      state = commentEndBangState;
    } else if (data == "-") {
      tokenQueue.addLast(new ParseErrorToken(
          "unexpected-dash-after-double-dash-in-comment"));
      currentToken.data = '${currentToken.data}${data}';
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-comment-double-dash"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      // XXX
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-comment"));
      currentToken.data = "${currentToken.data}--${data}";
      state = commentState;
    }
    return true;
  }

  bool commentEndBangState() {
    var data = stream.char();
    if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data == "-") {
      currentToken.data = '${currentToken.data}--!';
      state = commentEndDashState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentToken.data = '${currentToken.data}--!\uFFFD';
      state = commentState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-comment-end-bang-state"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentToken.data = "${currentToken.data}--!${data}";
      state = commentState;
    }
    return true;
  }

  bool doctypeState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = beforeDoctypeNameState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-doctype-name-but-got-eof"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("need-space-after-doctype"));
      stream.unget(data);
      state = beforeDoctypeNameState;
    }
    return true;
  }

  bool beforeDoctypeNameState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      return true;
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-doctype-name-but-got-right-bracket"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentDoctypeToken.name = "\uFFFD";
      state = doctypeNameState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken(
          "expected-doctype-name-but-got-eof"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentDoctypeToken.name = data;
      state = doctypeNameState;
    }
    return true;
  }

  bool doctypeNameState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      currentDoctypeToken.name = asciiUpper2Lower(currentDoctypeToken.name);
      state = afterDoctypeNameState;
    } else if (data == ">") {
      currentDoctypeToken.name = asciiUpper2Lower(currentDoctypeToken.name);
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentDoctypeToken.name = "${currentDoctypeToken.name}\uFFFD";
      state = doctypeNameState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype-name"));
      currentDoctypeToken.correct = false;
      currentDoctypeToken.name = asciiUpper2Lower(currentDoctypeToken.name);
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentDoctypeToken.name = '${currentDoctypeToken.name}${data}';
    }
    return true;
  }

  bool afterDoctypeNameState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      return true;
    } else if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      currentDoctypeToken.correct = false;
      stream.unget(data);
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      if (data == "p" || data == "P") {
        // TODO(jmesserly): would be nice to have a helper for this.
        var matched = true;
        for (var expected in const ["uU", "bB", "lL", "iI", "cC"]) {
          data = stream.char();
          if (data == EOF || !expected.contains(data)) {
            matched = false;
            break;
          }
        }
        if (matched) {
          state = afterDoctypePublicKeywordState;
          return true;
        }
      } else if (data == "s" || data == "S") {
        var matched = true;
        for (var expected in const ["yY", "sS", "tT", "eE", "mM"]) {
          data = stream.char();
          if (data == EOF || !expected.contains(data)) {
            matched = false;
            break;
          }
        }
        if (matched) {
          state = afterDoctypeSystemKeywordState;
          return true;
        }
      }

      // All the characters read before the current 'data' will be
      // [a-zA-Z], so they're garbage in the bogus doctype and can be
      // discarded; only the latest character might be '>' or EOF
      // and needs to be ungetted
      stream.unget(data);
      tokenQueue.addLast(new ParseErrorToken(
          "expected-space-or-right-bracket-in-doctype",
          datavars: {"data": data}));
      currentDoctypeToken.correct = false;
      state = bogusDoctypeState;
    }
    return true;
  }

  bool afterDoctypePublicKeywordState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = beforeDoctypePublicIdentifierState;
    } else if (data == "'" || data == '"') {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      stream.unget(data);
      state = beforeDoctypePublicIdentifierState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      stream.unget(data);
      state = beforeDoctypePublicIdentifierState;
    }
    return true;
  }

  bool beforeDoctypePublicIdentifierState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      return true;
    } else if (data == "\"") {
      currentDoctypeToken.publicId = "";
      state = doctypePublicIdentifierDoubleQuotedState;
    } else if (data == "'") {
      currentDoctypeToken.publicId = "";
      state = doctypePublicIdentifierSingleQuotedState;
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-end-of-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.correct = false;
      state = bogusDoctypeState;
    }
    return true;
  }

  bool doctypePublicIdentifierDoubleQuotedState() {
    var data = stream.char();
    if (data == '"') {
      state = afterDoctypePublicIdentifierState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentDoctypeToken.publicId = "${currentDoctypeToken.publicId}\uFFFD";
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-end-of-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentDoctypeToken.publicId = '${currentDoctypeToken.publicId}${data}';
    }
    return true;
  }

  bool doctypePublicIdentifierSingleQuotedState() {
    var data = stream.char();
    if (data == "'") {
      state = afterDoctypePublicIdentifierState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentDoctypeToken.publicId = "${currentDoctypeToken.publicId}\uFFFD";
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-end-of-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentDoctypeToken.publicId = '${currentDoctypeToken.publicId}${data}';
    }
    return true;
  }

  bool afterDoctypePublicIdentifierState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = betweenDoctypePublicAndSystemIdentifiersState;
    } else if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data == '"') {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.systemId = "";
      state = doctypeSystemIdentifierDoubleQuotedState;
    } else if (data == "'") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.systemId = "";
      state = doctypeSystemIdentifierSingleQuotedState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.correct = false;
      state = bogusDoctypeState;
    }
    return true;
  }

  bool betweenDoctypePublicAndSystemIdentifiersState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      return true;
    } else if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data == '"') {
      currentDoctypeToken.systemId = "";
      state = doctypeSystemIdentifierDoubleQuotedState;
    } else if (data == "'") {
      currentDoctypeToken.systemId = "";
      state = doctypeSystemIdentifierSingleQuotedState;
    } else if (data == EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.correct = false;
      state = bogusDoctypeState;
    }
    return true;
  }

  bool afterDoctypeSystemKeywordState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      state = beforeDoctypeSystemIdentifierState;
    } else if (data == "'" || data == '"') {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      stream.unget(data);
      state = beforeDoctypeSystemIdentifierState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      stream.unget(data);
      state = beforeDoctypeSystemIdentifierState;
    }
    return true;
  }

  bool beforeDoctypeSystemIdentifierState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      return true;
    } else if (data == "\"") {
      currentDoctypeToken.systemId = "";
      state = doctypeSystemIdentifierDoubleQuotedState;
    } else if (data == "'") {
      currentDoctypeToken.systemId = "";
      state = doctypeSystemIdentifierSingleQuotedState;
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      currentDoctypeToken.correct = false;
      state = bogusDoctypeState;
    }
    return true;
  }

  bool doctypeSystemIdentifierDoubleQuotedState() {
    var data = stream.char();
    if (data == "\"") {
      state = afterDoctypeSystemIdentifierState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentDoctypeToken.systemId = "${currentDoctypeToken.systemId}\uFFFD";
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-end-of-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentDoctypeToken.systemId = '${currentDoctypeToken.systemId}${data}';
    }
    return true;
  }

  bool doctypeSystemIdentifierSingleQuotedState() {
    var data = stream.char();
    if (data == "'") {
      state = afterDoctypeSystemIdentifierState;
    } else if (data == "\u0000") {
      tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
      currentDoctypeToken.systemId = "${currentDoctypeToken.systemId}\uFFFD";
    } else if (data == ">") {
      tokenQueue.addLast(new ParseErrorToken("unexpected-end-of-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      currentDoctypeToken.systemId = '${currentDoctypeToken.systemId}${data}';
    }
    return true;
  }

  bool afterDoctypeSystemIdentifierState() {
    var data = stream.char();
    if (isWhitespace(data)) {
      return true;
    } else if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      tokenQueue.addLast(new ParseErrorToken("eof-in-doctype"));
      currentDoctypeToken.correct = false;
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else {
      tokenQueue.addLast(new ParseErrorToken("unexpected-char-in-doctype"));
      state = bogusDoctypeState;
    }
    return true;
  }

  bool bogusDoctypeState() {
    var data = stream.char();
    if (data == ">") {
      tokenQueue.addLast(currentToken);
      state = dataState;
    } else if (data === EOF) {
      // XXX EMIT
      stream.unget(data);
      tokenQueue.addLast(currentToken);
      state = dataState;
    }
    return true;
  }

  bool cdataSectionState() {
    var data = [];
    int matchedEnd = 0;
    while (true) {
      var ch = stream.char();
      if (ch == EOF) {
        break;
      }
      // Deal with null here rather than in the parser
      if (ch == "\u0000") {
        tokenQueue.addLast(new ParseErrorToken("invalid-codepoint"));
        ch = "\uFFFD";
      }
      data.add(ch);
      // TODO(jmesserly): it'd be nice if we had an easier way to match the end,
      // perhaps with a "peek" API.
      if (ch == "]" && matchedEnd < 2) {
        matchedEnd++;
      } else if (ch == ">" && matchedEnd == 2) {
        // Remove "]]>" from the end.
        data.removeLast();
        data.removeLast();
        data.removeLast();
        break;
      } else {
        matchedEnd = 0;
      }
    }

    if (data.length > 0) {
      tokenQueue.addLast(new CharactersToken(joinStr(data)));
    }
    state = dataState;
    return true;
  }
}

