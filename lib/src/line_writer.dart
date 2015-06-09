// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_writer;

import 'chunk.dart';
import 'dart_formatter.dart';
import 'debug.dart' as debug;
import 'nesting_writer.dart';
import 'line_splitter.dart';
import 'rule.dart';
import 'source_code.dart';
import 'whitespace.dart';

/// Takes the incremental serialized output of [SourceVisitor]--the source text
/// along with any comments and preserved whitespace--and produces a coherent
/// tree of [Chunk]s which can then be split into physical lines.
///
/// Keeps track of leading indentation, expression nesting, and all of the hairy
/// code required to seamlessly integrate existing comments into the pure
/// output produced by [SourceVisitor].
class LineWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  final _buffer = new StringBuffer();

  final List<Chunk> _chunks;

  /// The whitespace that should be written to [_chunks] before the next
  ///  non-whitespace token or `null` if no whitespace is pending.
  ///
  /// This ensures that changes to indentation and nesting also apply to the
  /// most recent split, even if the visitor "creates" the split before changing
  /// indentation or nesting.
  Whitespace _pendingWhitespace;

  /// The nested stack of rules that are currently in use.
  ///
  /// New chunks are implicitly split by the innermost rule when the chunk is
  /// ended.
  final _rules = <Rule>[];

  /// The list of rules that are waiting until the next whitespace has been
  /// written before they start.
  final _lazyRules = <Rule>[];

  /// The indexes of the chunks owned by each rule (except for hard splits).
  final _ruleChunks = <Rule, List<int>>{};

  /// The nested stack of spans that are currently being written.
  final _openSpans = <OpenSpan>[];

  /// The current state.
  final _nesting = new NestingWriter();

  /// The index of the "current" chunk being written.
  ///
  /// If the last chunk is still being appended to, this is its index.
  /// Otherwise, it is the index of the next chunk which will be created.
  int get _currentChunkIndex {
    if (_chunks.isEmpty) return 0;
    if (_chunks.last.canAddText) return _chunks.length - 1;
    return _chunks.length;
  }

  /// The offset in [_buffer] where the selection starts in the formatted code.
  ///
  /// This will be `null` if there is no selection or the writer hasn't reached
  /// the beginning of the selection yet.
  int _selectionStart;

  /// The length in [_buffer] of the selection in the formatted code.
  ///
  /// This will be `null` if there is no selection or the writer hasn't reached
  /// the end of the selection yet.
  int _selectionLength;

  /// Whether or not there was a leading comment that was flush left before any
  /// other content was written.
  ///
  /// This is used when writing child blocks to make the parent chunk have the
  /// right flush left value when a comment appears immediately inside the
  /// block.
  bool _firstFlushLeft = false;

  /// Whether there is pending whitespace that depends on the number of
  /// newlines in the source.
  ///
  /// This is used to avoid calculating the newlines between tokens unless
  /// actually needed since doing so is slow when done between every single
  /// token pair.
  bool get needsToPreserveNewlines =>
      _pendingWhitespace == Whitespace.oneOrTwoNewlines ||
      _pendingWhitespace == Whitespace.spaceOrNewline;

  /// The number of characters of code that can fit in a single line.
  int get pageWidth => _formatter.pageWidth;

  /// The current innermost rule.
  Rule get rule => _rules.last;

  /// The current level of expression nesting.
  int get currentNesting => _nesting.currentNesting;

  LineWriter(this._formatter, this._source)
      : _chunks = [] {
    indent(_formatter.indent);
  }

  LineWriter._(this._formatter, this._source, this._chunks);

  /// Writes [string], the text for a single token, to the output.
  ///
  /// By default, this also implicitly adds one level of nesting if we aren't
  /// currently nested at all. We do this here so that if a comment appears
  /// after any token within a statement or top-level form and that comment
  /// leads to splitting, we correctly nest. Even pathological cases like:
  ///
  ///
  ///     import // comment
  ///         "this_gets_nested.dart";
  ///
  /// If we didn't do this here, we'd have to call [nestExpression] after the
  /// first token of practically every grammar production.
  void write(String string) {
    _emitPendingWhitespace();
    _writeText(string);

    _lazyRules.forEach(startRule);
    _lazyRules.clear();

    _nesting.commitNesting();
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;
  }

  /// Write a split owned by the current innermost rule.
  ///
  /// If [nesting] is given, uses that. Otherwise, uses the current nesting
  /// level. If unsplit, it expands to a space if [space] is `true`.
  Chunk split({int nesting, bool space, bool flushLeft}) =>
      _writeSplit(_rules.last,
          nesting: nesting, flushLeft: flushLeft, spaceWhenUnsplit: space);

  /// Outputs the series of [comments] and associated whitespace that appear
  /// before [token] (which is not written by this).
  ///
  /// The list contains each comment as it appeared in the source between the
  /// last token written and the next one that's about to be written.
  ///
  /// [linesBeforeToken] is number of lines between the last comment (or
  /// previous token if there are no comments) and the next token.
  void writeComments(List<SourceComment> comments, int linesBeforeToken,
      String token) {
    // Corner case: if we require a blank line, but there exists one between
    // some of the comments, or after the last one, then we don't need to
    // enforce one before the first comment. Example:
    //
    //     library foo;
    //     // comment
    //
    //     class Bar {}
    //
    // Normally, a blank line is required after `library`, but since there is
    // one after the comment, we don't need one before it. This is mainly so
    // that commented out directives stick with their preceding group.
    if (_pendingWhitespace == Whitespace.twoNewlines &&
        comments.isNotEmpty &&
        comments.first.linesBefore < 2) {
      if (linesBeforeToken > 1) {
        _pendingWhitespace = Whitespace.newline;
      } else {
        for (var i = 1; i < comments.length; i++) {
          if (comments[i].linesBefore > 1) {
            _pendingWhitespace = Whitespace.newline;
            break;
          }
        }
      }
    }

    // Write each comment and the whitespace between them.
    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      preserveNewlines(comment.linesBefore);

      // Don't emit a space because we'll handle it below. If we emit it here,
      // we may get a trailing space if the comment needs a line before it.
      if (_pendingWhitespace == Whitespace.space) _pendingWhitespace = null;
      _emitPendingWhitespace();

      if (comment.linesBefore == 0) {
        // If we're sitting on a split, move the comment before it to adhere it
        // to the preceding text.
        if (_shouldMoveCommentBeforeSplit()) {
          _chunks.last.allowText();
        }

        // The comment follows other text, so we need to decide if it gets a
        // space before it or not.
        if (_needsSpaceBeforeComment(isLineComment: comment.isLineComment)) {
          _writeText(" ");
        }
      } else {
        // The comment starts a line, so make sure it stays on its own line.
        _writeHardSplit(nest: true, flushLeft: comment.isStartOfLine,
            double: comment.linesBefore > 1);
      }

      _writeText(comment.text);

      if (comment.selectionStart != null) {
        startSelectionFromEnd(comment.text.length - comment.selectionStart);
      }

      if (comment.selectionEnd != null) {
        endSelectionFromEnd(comment.text.length - comment.selectionEnd);
      }

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter;
      if (i < comments.length - 1) {
        linesAfter = comments[i + 1].linesBefore;
      } else {
        linesAfter = linesBeforeToken;

        // Always force a newline after multi-line block comments. Prevents
        // mistakes like:
        //
        //     /**
        //      * Some doc comment.
        //      */ someFunction() { ... }
        if (linesAfter == 0 && comments.last.text.contains("\n")) {
          linesAfter = 1;
        }
      }

      if (linesAfter > 0) _writeHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.space;
    }

    preserveNewlines(linesBeforeToken);
  }

  /// If the current pending whitespace allows some source discretion, pins
  /// that down given that the source contains [numLines] newlines at that
  /// point.
  void preserveNewlines(int numLines) {
    // If we didn't know how many newlines the user authored between the last
    // token and this one, now we do.
    switch (_pendingWhitespace) {
      case Whitespace.spaceOrNewline:
        if (numLines > 0) {
          _pendingWhitespace = Whitespace.nestedNewline;
        } else {
          _pendingWhitespace = Whitespace.space;
        }
        break;

      case Whitespace.oneOrTwoNewlines:
        if (numLines > 1) {
          _pendingWhitespace = Whitespace.twoNewlines;
        } else {
          _pendingWhitespace = Whitespace.newline;
        }
        break;
    }
  }

  /// Increases indentation of the next line by [levels].
  void indent([int levels = 1]) {
    _nesting.indent(levels);
  }

  /// Decreases indentation of the next line by [levels].
  void unindent([int levels = 1]) {
    _nesting.unindent(levels);
  }

  /// Starts a new span with [cost].
  ///
  /// Each call to this needs a later matching call to [endSpan].
  void startSpan([int cost = Cost.normal]) {
    _openSpans.add(createSpan(cost));
  }

  /// Creates a "free" span not stored on the span stack.
  ///
  /// By creating this and later passing it to [endSpan], you can create spans
  /// that don't follow the normal strictly nested behavior.
  OpenSpan createSpan([int cost = Cost.normal]) =>
      new OpenSpan(_currentChunkIndex, cost);

  /// Ends the innermost span.
  void endSpan([OpenSpan openSpan]) {
    if (openSpan == null) openSpan = _openSpans.removeLast();

    // A span that just covers a single chunk can't be split anyway.
    var end = _currentChunkIndex;
    if (openSpan.start == end) return;

    // Add the span to every chunk that can split it.
    var span = new Span(openSpan.cost);
    for (var i = openSpan.start; i < end; i++) {
      var chunk = _chunks[i];
      if (!chunk.isHardSplit) chunk.spans.add(span);
    }
  }

  /// Starts a new [Rule].
  ///
  /// If omitted, defaults to a new [SimpleRule].
  void startRule([Rule rule]) {
    //assert(_pendingRule == null);

    if (rule == null) rule = new SimpleRule();

    // See if any of the rules that contain this one care if it splits.
    _rules.forEach((outer) => outer.contain(rule));
    _rules.add(rule);

    // Keep track of the rule's chunk range so we know how to calculate its
    // length for preemption.
    rule.start = _currentChunkIndex;
  }

  /// Starts a new [Rule] that comes into play *after* the next whitespace
  /// (including comments) is written.
  ///
  /// This is used for binary operators who want to start a rule before the
  /// first operand but not get forced to split if a comment appears before the
  /// entire expression.
  ///
  /// If [rule] is omitted, defaults to a new [SimpleRule].
  void startLazyRule([Rule rule]) {
    if (rule == null) rule = new SimpleRule();

    _lazyRules.add(rule);
  }

  /// Ends the innermost rule.
  void endRule() {
    // Keep track of the rule's chunk range so we know how to calculate its
    // length for preemption.
    _rules.removeLast().end = _currentChunkIndex;
  }

  /// Pre-emptively forces all of the current rules to become hard splits.
  ///
  /// This is called by [SourceVisitor] when it can determine that a rule will
  /// will always be split. Turning it (and the surrounding rules) into hard
  /// splits lets the writer break the output into smaller pieces for the line
  /// splitter, which helps performance and avoids failing on very large input.
  ///
  /// In particular, it's easy for the visitor to know that collections with a
  /// large number of items must split. Doing that early avoids crashing the
  /// splitter when it tries to recurse on huge collection literals.
  void forceRules() => _handleHardSplit();

  /// Increases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void nestExpression() {
    _nesting.nest();
  }

  /// Decreases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    _nesting.unnest();
  }

  /// Marks the selection starting point as occurring [fromEnd] characters to
  /// the left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void startSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.startSelectionFromEnd(fromEnd);
  }

  /// Marks the selection ending point as occurring [fromEnd] characters to the
  /// left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void endSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.endSelectionFromEnd(fromEnd);
  }

  /// Starts a new block as a child of the current chunk.
  ///
  /// Nested blocks are handled using their own independent [LineWriter].
  LineWriter startBlock() {
    var writer = new LineWriter._(
        this._formatter, this._source, _chunks.last.blockChunks);

    // A block always starts off indented one level.
    writer.indent();

    return writer;
  }

  /// Ends this [LineWriter], which must have been created by [startBlock()].
  ///
  /// Returns a pair of booleans. The first is `true` if the block will
  /// definitely split because it either contains hard splits or doesn't fit
  /// within a line. Ignores hard newlines coming from [ignoredSplit] if given.
  ///
  /// The second is `true` if the first line of the block should be flush left.
  List<bool> endBlock([HardSplitRule ignoredSplit]) {
    _finishChunks();

    // Determine if there will always be a split in here.
    var length = 0;
    for (var chunk in _chunks) {
      length += chunk.length + chunk.unsplitBlockLength;
      if (length > _formatter.pageWidth) {
        return [true, _firstFlushLeft];
      }

      if (chunk.isHardSplit && chunk.rule != ignoredSplit) {
        return [true, _firstFlushLeft];
      }
    }

    // TODO(rnystrom): Returning a pair like this is ugly. Do something cleaner.
    return [false, _firstFlushLeft];
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode end() {
    _writeHardSplit();
    _finishChunks();
    _splitLines();

    // Be a good citizen, end with a newline.
    if (_source.isCompilationUnit) _buffer.write(_formatter.lineEnding);

    // If we haven't hit the beginning and/or end of the selection yet, they
    // must be at the very end of the code.
    if (_source.selectionStart != null) {
      if (_selectionStart == null) {
        _selectionStart = _buffer.length;
      }

      if (_selectionLength == null) {
        _selectionLength = _buffer.length - _selectionStart;
      }
    }

    return new SourceCode(_buffer.toString(),
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        selectionStart: _selectionStart,
        selectionLength: _selectionLength);
  }

  /// Writes the current pending [Whitespace] to the output, if any.
  ///
  /// This should only be called after source lines have been preserved to turn
  /// any ambiguous whitespace into a concrete choice.
  void _emitPendingWhitespace() {
    if (_pendingWhitespace == null) return;
    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pendingWhitespace) {
      case Whitespace.space:
        _writeText(" ");
        break;

      case Whitespace.newline:
        _writeHardSplit();
        break;

      case Whitespace.nestedNewline:
        _writeHardSplit(nest: true);
        break;

      case Whitespace.newlineFlushLeft:
        _writeHardSplit(flushLeft: true);
        break;

      case Whitespace.twoNewlines:
        _writeHardSplit(double: true);
        break;

      case Whitespace.spaceOrNewline:
      case Whitespace.oneOrTwoNewlines:
        // We should have pinned these down before getting here.
        assert(false);
        break;
    }

    _pendingWhitespace = null;
  }

  /// Returns `true` if the last chunk is a split that should be move after the
  /// comment that is about to be written.
  bool _shouldMoveCommentBeforeSplit() {
    // Not if there is nothing before it.
    if (_chunks.isEmpty) return false;

    // If the text before the split is an open grouping character, we don't
    // want to adhere the comment to that.
    var text = _chunks.last.text;
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output between the end of the current
  /// output and the subsequent comment which is about to be written.
  ///
  /// This is only called if the comment is trailing text in the unformatted
  /// source. In most cases, a space will be output to separate the comment
  /// from what precedes it. This returns false if:
  ///
  /// *   This comment does begin the line in the output even if it didn't in
  ///     the source.
  /// *   The comment is a block comment immediately following a grouping
  ///     character (`(`, `[`, or `{`). This is to allow `foo(/* comment */)`,
  ///     et. al.
  bool _needsSpaceBeforeComment({bool isLineComment}) {
    // Not at the start of the file.
    if (_chunks.isEmpty) return false;

    // Not at the start of a line.
    if (!_chunks.last.canAddText) return false;

    var text = _chunks.last.text;
    if (text.endsWith("\n")) return false;

    // Always put a space before line comments.
    if (isLineComment) return true;

    // Block comments do not get a space if following a grouping character.
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output after the last comment which
  /// was just written and the token that will be written.
  bool _needsSpaceAfterLastComment(List<SourceComment> comments, String token) {
    // Not if there are no comments.
    if (comments.isEmpty) return false;

    // Not at the beginning of a line.
    if (!_chunks.last.canAddText) return false;

    // Otherwise, it gets a space if the following token is not a delimiter or
    // the empty string, for EOF.
    return token != ")" && token != "]" && token != "}" &&
           token != "," && token != ";" && token != "";
  }

  /// Appends a hard split with the current indentation and nesting (the latter
  /// only if [nest] is `true`).
  ///
  /// If [double] is `true`, a double-split (i.e. a blank line) is output.
  ///
  /// If [flushLeft] is `true`, then the split will always cause the next line
  /// to be at column zero. Otherwise, it uses the normal indentation and
  /// nesting behavior.
  void _writeHardSplit({bool nest: false, bool double: false, bool flushLeft}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;
    _writeSplit(new HardSplitRule(),
        nesting: nest ? null : 0, flushLeft: flushLeft, isDouble: double);
  }

  /// Ends the current chunk (if any) with the given split information.
  ///
  /// Returns the chunk.
  Chunk _writeSplit(Rule rule,
      {int nesting, bool flushLeft, bool isDouble, bool spaceWhenUnsplit}) {
    if (_chunks.isEmpty) {
      if (flushLeft != null) _firstFlushLeft = flushLeft;

      return null;
    }

    if (nesting == null) nesting = _nesting.nesting;

    var chunk = _chunks.last;
    chunk.applySplit(rule, _nesting.indentation, nesting,
        flushLeft: flushLeft,
        isDouble: isDouble,
        spaceWhenUnsplit: spaceWhenUnsplit);

    // Keep track of which chunks are owned by the rule.
    if (rule is! HardSplitRule) {
      _ruleChunks.putIfAbsent(rule, () => []).add(_chunks.length - 1);
    }

    if (chunk.isHardSplit) _handleHardSplit();

    return chunk;
  }

  /// Writes [text] to either the current chunk or a new one if the current
  /// chunk is complete.
  void _writeText(String text) {
    if (_chunks.isNotEmpty && _chunks.last.canAddText) {
      _chunks.last.appendText(text);
    } else {
      _chunks.add(new Chunk(text));
    }
  }

  /// Takes all of the chunks and breaks them into sublists that can be line
  /// split individually.
  ///
  /// Since this is linear and line splitting is... worse... it's good to feed
  /// the line splitter smaller lists of chunks when possible. This should only
  /// be called once, after all of the chunks have been written.
  void _splitLines() {
    // Now that we know what hard splits there will be, break the chunks into
    // independently splittable lines.
    var bufferedNewlines = 0;
    var beginningIndent = _formatter.indent;

    var start = 0;
    for (var i = 0; i < _chunks.length; i++) {
      if (!_canSplitAt(i)) continue;

      // Write the newlines required by the previous line.
      for (var i = 0; i < bufferedNewlines; i++) {
        _buffer.write(_formatter.lineEnding);
      }

      _completeLine(beginningIndent, start, i + 1);

      // Get ready for the next line.
      var chunk = _chunks[i];
      bufferedNewlines = chunk.isDouble ? 2 : 1;
      beginningIndent = chunk.absoluteIndent;
      start = i + 1;
    }

    if (start < _chunks.length) {
      _completeLine(beginningIndent, start, _chunks.length);
    }
  }

  /// Returns true if we can divide the chunks at [index] and line split the
  /// ones before and after that separately.
  bool _canSplitAt(int i) {
    var chunk = _chunks[i];
    if (!chunk.isHardSplit) return false;
    if (chunk.nesting > 0) return false;
    if (chunk.blockChunks.isNotEmpty) return false;

    // Make sure we don't split the line in the middle of a rule.
    var chunks = _ruleChunks[chunk.rule];
    if (chunks != null && chunks.any((other) => other > i)) return false;

    return true;
  }

  /// Takes the first [length] of the chunks with leading [indent], removes
  /// them, and runs the [LineSplitter] on them.
  void _completeLine(int indent, int start, int end) {
    var chunks = _chunks.sublist(start, end);

    if (debug.traceFormatter) {
      debug.log(debug.green("\nWriting:"));
      debug.dumpChunks(start, chunks);
      debug.log();
    }

    var splitter = new LineSplitter(
        _formatter.lineEnding, _formatter.pageWidth, chunks, indent);
    var result = splitter.apply(_buffer);

    if (result.selectionStart != null) {
      _selectionStart = result.selectionStart;
    }

    if (result.selectionEnd != null) {
      _selectionLength = result.selectionEnd -_selectionStart;
    }
  }

  /// Pre-processes the chunks after they are done being written by the visitor
  /// but before they are run through the line splitter.
  void _finishChunks() {
    // Need at least two chunks to have any splits.
    if (_chunks.length < 2) return;

    // For each independent set of chunks, see if there are any rules in them
    // that we want to preemptively harden. This is basically to send smaller
    // batches of chunks to LineSplitter in cases where the code is deeply
    // nested or complex.
    var start = 0;
    for (var i = 1; i < _chunks.length; i++) {
      if (_canSplitAt(i)) {
        _preemptRules(start, i);
        start = i;
      }
    }

    if (start < _chunks.length) {
      _preemptRules(start, _chunks.length);
    }
  }

  /// Removes any unused nesting levels from [chunks].
  ///
  /// The line splitter considers every possible combination of mapping
  /// indentation to nesting levels when trying to find the best solution. For
  /// example, it may assign 4 spaces of indentation to level 1, 8 spaces to
  /// level 3, etc.
  ///
  /// It's fairly common for a nesting level to not actually appear at the
  /// boundary of a chunk. The source visitor may enter more than one level of
  /// nesting at a point where a split cannot happen. In that case, there's no
  /// point in trying to assign an indentation level to that nesting level. It
  /// will never be used because no line will begin at that level of
  /// indentation.
  ///
  /// Worse, if the splitter *does* consider these levels, it can dramatically
  /// increase solving time. We can't determine which nesting levels will get
  /// used eagerly since a level may not be used until later. Instead, when we
  /// bounce all the way back to no nesting, this goes through and renumbers
  /// the nesting levels of all of the preceding chunks.
  void _flattenNestingLevels(List<Chunk> chunks) {
    if (chunks.isEmpty) return;

    var nestingLevels = chunks
        .map((chunk) => chunk.nesting)
        .where((nesting) => nesting != null && nesting != 0)
        .toSet()
        .toList();
    nestingLevels.sort();

    var nestingMap = {0: 0};
    for (var i = 0; i < nestingLevels.length; i++) {
      nestingMap[nestingLevels[i]] = i + 1;
    }

    for (var chunk in chunks) {
      chunk.flattenNesting(nestingMap);
    }
  }

  /// Force some rules to become hard splits if it looks like there's no other
  /// option to get a solution in reasonable time.
  ///
  /// In most cases, the formatter can find an ideal solution to a set of rules
  /// in reasonable time. Splitting chunks into short lists, nested blocks, and
  /// the memoization and block caching that [LineSplitter] does all help.
  ///
  /// However, some code isn't helped by any of that. In particular, a very
  /// large, deeply nested expression that contains no collection or function
  /// literals has to be solved all at once by the line splitter. Memoization
  /// helps, but some expressions just have too many permutations.
  ///
  /// In practice, this almost always occurs in machine-generated code where
  /// the output quality doesn't matter as much. To avoid getting stuck there,
  /// this finds rules that surround more than a page of code and forces them
  /// to fully split. It only does this if it thinks it won't find a reasonable
  /// solution otherwise.
  ///
  /// This may discard a more optimal solution in some cases. When a rule is
  /// hardened, it is *fully* hardened. There may have been a solution where
  /// only some of a rule's chunks needed to be split (for example, not fully
  /// breaking an argument list). This won't consider those kinds of solution
  /// To avoid this, pre-emption only kicks in for lines that look like they
  /// will be hard to solve directly.
  void _preemptRules(int start, int end) {
    var chunks = _chunks.sublist(start, end);
    _flattenNestingLevels(chunks);

    var rules = chunks
        .map((chunk) => chunk.rule)
        .where((rule) => rule != null && rule is! HardSplitRule)
        .toSet();

    var values = rules.fold(1, (value, rule) => value * rule.numValues);

    // If the number of possible solutions is reasonable, don't preempt any.
    if (values < 4096) return;

    // Find the rules that contain too much.
    for (var rule in rules) {
      var length = 0;
      for (var i = rule.start + 1; i <= rule.end; i++) {
        length += _chunks[i].length + _chunks[i].unsplitBlockLength;
        if (length > pageWidth) {
          _hardenRule(rule);
          break;
        }
      }
    }
  }

  /// Hardens the active rules when a hard split occurs within them.
  void _handleHardSplit() {
    if (_rules.isEmpty) return;

    // If the current rule doesn't care, it will "eat" the hard split and no
    // others will care either.
    if (!_rules.last.splitsOnInnerRules) return;

    // Start with the innermost rule. This will traverse the other rules it
    // constrains.
    _hardenRule(_rules.last);
  }

  /// Replaces [rule] with a hard split.
  ///
  /// This also applies all of the implications of that change:
  ///
  /// * Existing chunks using that rule are hardened.
  /// * Later chunks using that rule will use a hard split instead.
  /// * Any other rules that are constrained by this one are also hardened.
  void _hardenRule(Rule rule) {
    var hardened = new Set();

    harden(rule) {
      if (hardened.contains(rule)) return;
      hardened.add(rule);

      // Harden every existing chunk that uses this rule.
      if (_ruleChunks.containsKey(rule)) {
        for (var chunk in _ruleChunks[rule]) _chunks[chunk].harden();
      }

      // If the rule is still active, swap it out with a hard split so that
      // later chunks using the rule are hardened too.
      for (var i = 0; i < _rules.length; i++) {
        if (_rules[i] == rule) {
          _rules[i] = new HardSplitRule();
        }
      }

      // Follow this rule's constraints, recursively.
      for (var other in _ruleChunks.keys) {
        if (other == rule) continue;

        if (rule.constrain(rule.fullySplitValue, other) ==
            other.fullySplitValue) {
          harden(other);
        }
      }
    }

    harden(rule);
  }
}
