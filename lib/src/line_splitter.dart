// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitter;

import 'dart:math' as math;

import 'chunk.dart';
import 'debug.dart' as debug;
import 'line_prefix.dart';
import 'rule.dart';

// TODO(rnystrom): This needs to be updated to take into account how it works
// now.
/// Takes a series of [Chunk]s and determines the best way to split them into
/// lines of output that fit within the page width (if possible).
///
/// Trying all possible combinations is exponential in the number of
/// [SplitParam]s and expression nesting levels both of which can be quite large
/// with things like long method chains containing function literals, lots of
/// named parameters, etc. To tame that, this uses dynamic programming. The
/// basic process is:
///
/// Given a suffix of the entire line, we walk over the tokens keeping track
/// of any splits we find until we fill the page width (or run out of line).
/// If we reached the end of the line without crossing the page width, we're
/// fine and the suffix is good as it is.
///
/// If we went over, at least one of those splits must be applied to keep the
/// suffix in bounds. For each of those splits, we split at that point and
/// apply the same algorithm for the remainder of the line. We get the results
/// of all of those, choose the one with the lowest cost, and
/// that's the best solution.
///
/// The fact that this recurses while only removing a small prefix from the
/// line (the chunks before the first split), means this is exponential.
/// Thankfully, though, the best set of splits for a suffix of the line depends
/// only on:
///
///  -   The starting position of the suffix.
///
///  -   The set of expression nesting levels currently being split up to that
///      point.
///
///      For example, consider the following:
///
///          outer(inner(argument1, argument2, argument3));
///
///      If the suffix we are considering is "argument2, ..." then we need to
///      know if we previously split after "outer(", "inner(", or both. The
///      answer determines how much leading indentation "argument2, ..." will
///      have.
///
/// Thus, whenever we calculate an ideal set of splits for some suffix, we
/// memoize it. When later recursive calls descend to that suffix again, we can
/// reuse it.
class LineSplitter {
  /// The string used for newlines.
  final String _lineEnding;

  /// The number of characters allowed in a single line.
  final int _pageWidth;

  /// The list of chunks being split.
  final List<Chunk> _chunks;

  /// The leading indentation at the beginning of the first line.
  final int _indent;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, SplitSet>{};

  // TODO(rnystrom): Instead of a cache per LineSplitter, we should store a
  // single global cache that uses the parent chunk's identity in the key. That
  // way, we can reuse results across transitive recursive line splitting. For
  // example, say we have code like:
  //
  //     void main() {
  //       function(argument, argument, /* A */ () {
  //         function(argument, argument, /* B */ () {
  //           ;
  //         });
  //       });
  //     }
  //
  // The LineSplitter for the top level may create a few child splitters for
  // each indentation where function A can appear. Each of those will in turn
  // create child splitters for each indentation of B. In many cases, those
  // will be redundant. However, each time one of the line splitters for A is
  // done, it discards all of the cached results for B.
  /// The cache of child blocks of this line that have already been split.
  final _formattedBlocks = <BlockKey, FormattedBlock>{};

  /// The rules that appear in the first `n` chunks of the line where `n` is
  /// the index into the list.
  final _prefixRules = <Set<Rule>>[];

  /// The rules that appear after the first `n` chunks of the line where `n` is
  /// the index into the list.
  final _suffixRules = <Set<Rule>>[];

  /// Creates a new splitter that tries to fit a series of chunks within a
  /// given page width.
  LineSplitter(this._lineEnding, this._pageWidth, this._chunks, this._indent) {
    assert(_chunks.isNotEmpty);
  }

  /// Convert the line to a [String] representation.
  ///
  /// It will determine how best to split it into multiple lines of output and
  /// write the result to [buffer].
  SplitResult apply(StringBuffer buffer) {
    if (debug.traceSplitter) {
      debug.log(debug.green("\nSplitting:"));
      debug.dumpChunks(0, _chunks);
      debug.log();
    }

    // Ignore the trailing rule on the last chunk since it isn't used for
    // anything.
    var ruleChunks = _chunks.take(_chunks.length - 1);

    // Pre-calculate the set of rules appear before and after each length. We
    // use these frequently when creating [LinePrefix]es and they only depend
    // on the length, so we can cache them up front.
    for (var i = 0; i < _chunks.length; i++) {
      _prefixRules.add(ruleChunks.take(i).map((chunk) => chunk.rule).toSet());
      _suffixRules.add(ruleChunks.skip(i).map((chunk) => chunk.rule).toSet());
    }

    var prefix = new LinePrefix(_indent);
    var solution = new RunningSolution(prefix);
    _tryChunkRuleValues(solution, prefix);

    var selectionStart;
    var selectionEnd;

    writeChunk(Chunk chunk) {
      // If this chunk contains one of the selection markers, tell the writer
      // where it ended up in the final output.
      if (chunk.selectionStart != null) {
        selectionStart = buffer.length + chunk.selectionStart;
      }

      if (chunk.selectionEnd != null) {
        selectionEnd = buffer.length + chunk.selectionEnd;
      }

      buffer.write(chunk.text);
    }

    writeChunks(List<Chunk> chunks) {
      for (var chunk in chunks) {
        writeChunk(chunk);

        if (chunk.spaceWhenUnsplit) buffer.write(" ");
        writeChunks(chunk.blockChunks);
      }
    }

    // Write each chunk and the split after it.
    buffer.write(" " * (_indent * spacesPerIndent));
    for (var i = 0; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      writeChunk(chunk);

      if (chunk.blockChunks.isNotEmpty) {
        if (!solution.splits.shouldSplitAt(i)) {
          // This block didn't split (which implies none of the child blocks
          // of that block split either, recursively), so write them all inline.
          writeChunks(chunk.blockChunks);
        } else {
          // Include the formatted block contents.
          var block = _formatBlock(i, solution.splits.getColumn(i));

          // If this block contains one of the selection markers, tell the
          // writer where it ended up in the final output.
          if (block.result.selectionStart != null) {
            selectionStart = buffer.length + block.result.selectionStart;
          }

          if (block.result.selectionEnd != null) {
            selectionEnd = buffer.length + block.result.selectionEnd;
          }

          buffer.write(block.text);
        }
      }

      if (i == _chunks.length - 1) {
        // Don't write trailing whitespace after the last chunk.
      } else if (solution.splits.shouldSplitAt(i)) {
        buffer.write(_lineEnding);
        if (chunk.isDouble) buffer.write(_lineEnding);

        buffer.write(" " * (solution.splits.getColumn(i)));
      } else {
        if (chunk.spaceWhenUnsplit) buffer.write(" ");
      }
    }

    return new SplitResult(solution._lowestCost, selectionStart, selectionEnd);
  }

  /// Finds the best set of splits to apply to the remainder of the chunks
  /// following [prefix].
  ///
  /// This can only be called for a suffix that begins a new line. (In other
  /// words, the last chunk in the prefix cannot be unsplit.)
  SplitSet _findBestSplits(LinePrefix prefix) {
    // Use the memoized result if we have it.
    if (_bestSplits.containsKey(prefix)) {
      if (debug.traceSplitter) {
        debug.log("memoized splits for $prefix = ${_bestSplits[prefix]}");
      }
      return _bestSplits[prefix];
    }

    if (debug.traceSplitter) {
      debug.log("find splits for $prefix");
      debug.indent();
    }

    var solution = new RunningSolution(prefix);
    _tryChunkRuleValues(solution, prefix);

    if (debug.traceSplitter) {
      debug.unindent();
      debug.log("best splits for $prefix = ${solution.splits}");
    }

    return _bestSplits[prefix] = solution.splits;
  }

  /// Updates [solution] with the best rule value selection for the chunk
  /// immediately following [prefix].
  void _tryChunkRuleValues(RunningSolution solution, LinePrefix prefix) {
    // If we made it to the end, this prefix can be solved without splitting
    // any chunks.
    if (prefix.length == _chunks.length - 1) {
      solution.update(this, new SplitSet());
      return;
    }

    var chunk = _chunks[prefix.length];

    // See if we've already selected a value for the rule.
    var value = prefix.ruleValues[chunk.rule];

    if (value == null) {
      // No, so try every possible value for the rule.
      for (value = 0; value < chunk.rule.numValues; value++) {
        _tryRuleValue(solution, prefix, value);
      }
    } else if (value == -1) {
      // A -1 "value" means, "any non-zero value". In other words, the rule has
      // to split somehow, but can split however it chooses.
      for (value = 1; value < chunk.rule.numValues; value++) {
        _tryRuleValue(solution, prefix, value);
      }
    } else {
      // Otherwise, it's constrained to a single value, so use it.
      _tryRuleValue(solution, prefix, value);
    }
  }

  /// Updates [solution] with the best solution that can be found by setting
  /// the chunk after [prefix]'s rule to [value].
  void _tryRuleValue(RunningSolution solution, LinePrefix prefix, int value) {
    var chunk = _chunks[prefix.length];

    if (chunk.rule.isSplit(value, chunk)) {
      // The chunk is splitting in an expression, so try all of the possible
      // nesting combinations.
      var ruleValues = _advancePrefix(prefix, value);
      var longerPrefixes = prefix.split(chunk, ruleValues);
      for (var longerPrefix in longerPrefixes) {
        _tryLongerPrefix(solution, prefix, longerPrefix);
      }
    } else {
      // We didn't split here, so add this chunk and its rule value to the
      // prefix and continue on to the next.
      var extended = prefix.extend(_advancePrefix(prefix, value));
      _tryChunkRuleValues(solution, extended);
    }
  }

  /// Updates [solution] with the solution for [prefix] assuming it uses
  /// [longerPrefix] for the next chunk.
  void _tryLongerPrefix(RunningSolution solution, LinePrefix prefix,
        LinePrefix longerPrefix) {
    var remaining = _findBestSplits(longerPrefix);

    // If it wasn't possible to split the suffix given this nesting stack,
    // skip it.
    if (remaining == null) return;

    solution.update(this, remaining.add(prefix.length, longerPrefix.column));
  }

  /// Determines the set of rule values for a new [LinePrefix] one chunk longer
  /// than [prefix] whose rule on the new last chunk has [value].
  ///
  /// Returns a map of [Rule]s to values for those rules for the values that
  /// span the prefix and suffix of the [LinePrefix].
  Map<Rule, int> _advancePrefix(LinePrefix prefix, int value) {
    // Get the rules that appear in both in and after the new prefix. These are
    // the rules that already have values that the suffix needs to honor.
    var prefixRules = _prefixRules[prefix.length + 1];
    var suffixRules = _suffixRules[prefix.length + 1];

    var nextRule = _chunks[prefix.length].rule;
    var updatedValues = {};

    for (var prefixRule in prefixRules) {
      var ruleValue = prefixRule == nextRule
          ? value
          : prefix.ruleValues[prefixRule];

      if (suffixRules.contains(prefixRule)) {
        // If the same rule appears in both the prefix and suffix, then preserve
        // its exact value.
        updatedValues[prefixRule] = ruleValue;
      }

      // If we haven't specified any value for this rule in the prefix, it
      // doesn't place any constraint on the suffix.
      if (ruleValue == null) continue;

      // Enforce the constraints between rules.
      for (var suffixRule in suffixRules) {
        if (suffixRule == prefixRule) continue;

        // See if the prefix rule's value constrains any values in the suffix.
        var value = prefixRule.constrain(ruleValue, suffixRule);

        // Also consider the backwards case, where a later rule in the suffix
        // constrains a rule in the prefix.
        if (value == null) {
          value = suffixRule.reverseConstrain(ruleValue, prefixRule);
        }

        if (value != null) {
          updatedValues[prefixRule] = ruleValue;
          updatedValues[suffixRule] = value;
        }
      }
    }

    return updatedValues;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of rules.
  int _evaluateCost(LinePrefix prefix, SplitSet splits) {
    assert(splits != null);

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var cost = 0;
    var length = prefix.column;

    var splitRules = new Set();

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _pageWidth) {
        cost += (length - _pageWidth) * Cost.overflowChar;
      }
    }

    // The set of spans that contain chunks that ended up splitting. We store
    // these in a set so a span's cost doesn't get double-counted if more than
    // one split occurs in it.
    var splitSpans = new Set();

    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      length += chunk.text.length;

      if (i < _chunks.length - 1) {
        if (splits.shouldSplitAt(i)) {
          endLine();

          splitSpans.addAll(chunk.spans);

          if (chunk.rule != null && !splitRules.contains(chunk.rule)) {
            // Don't double-count rules if multiple splits share the same
            // rule.
            splitRules.add(chunk.rule);
            cost += chunk.rule.cost;
          }

          // Include the cost of the nested block.
          if (chunk.blockChunks.isNotEmpty) {
            cost += _formatBlock(i, splits.getColumn(i)).result.cost;
          }

          // Start the new line.
          length = splits.getColumn(i);
        } else {
          if (chunk.spaceWhenUnsplit) length++;

          // Include the nested block inline, if any.
          length += chunk.unsplitBlockLength;
        }
      }
    }

    // Add the costs for the spans containing splits.
    for (var span in splitSpans) cost += span.cost;

    // Finish the last line.
    endLine();

    return cost;
  }

  /// Gets the results of formatting the child block of the chunk at
  /// [chunkIndex] with starting [column].
  ///
  /// If that block has already been formatted, reuses the results.
  ///
  /// The column is the column for the delimiters. The contents of the block
  /// are always implicitly one level deeper than that.
  ///
  ///     main() {
  ///       function(() {
  ///         block;
  ///       });
  ///     }
  ///
  /// When we format the anonymous lambda, [column] will be 2, not 4.
  FormattedBlock _formatBlock(int chunkIndex, int column) {
    var key = new BlockKey(chunkIndex, column);

    // Use the cached one if we have it.
    var cached = _formattedBlocks[key];
    if (cached != null) return cached;

    // TODO(rnystrom): Going straight to LineSplitter here skips the line
    // breaking that LineWriter does. This is a huge perf sink on big nested
    // blocks. Reorganize.

    // TODO(rnystrom): Passing in an initial indent here is hacky. The
    // LineWriter ensures all but the first chunk have an indent of 1, and this
    // handles the first chunk. Do something cleaner.
    var splitter = new LineSplitter(_lineEnding, _pageWidth - column,
        _chunks[chunkIndex].blockChunks, _chunks[chunkIndex].flushLeft ? 0 : 1);

    var buffer = new StringBuffer();

    // There is always a newline after the opening delimiter.
    buffer.write(_lineEnding);

    var result = splitter.apply(buffer);

    // TODO(rnystrom): Munging this this way is gross. Instead of passing a raw
    // StringBuffer to apply(), provide something more structured that provides
    // output lines we can indent.
    // Apply the indentation to non-empty lines.
    var lines = buffer.toString().split(_lineEnding);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.trim() != "") lines[i] = "${' ' * column}$line";
    }

    var text = lines.join(_lineEnding);
    return _formattedBlocks[key] = new FormattedBlock(text, result);
  }
}

/// Key type for the formatted block cache.
///
/// To cache formatted blocks, we just need to know which block it is (the
/// index of its parent chunk) and how far it was indented when we formatted it
/// (the starting column).
class BlockKey {
  /// The index of the chunk in the surrounding chunk list that contains this
  /// block.
  final int chunk;

  /// The absolute zero-based column number where the block starts.
  final int column;

  BlockKey(this.chunk, this.column);

  bool operator ==(other) {
    if (other is! BlockKey) return false;
    return chunk == other.chunk && column == other.column;
  }

  int get hashCode => chunk.hashCode ^ column.hashCode;
}

/// The result of formatting a child block of a chunk.
class FormattedBlock {
  /// The resulting formatted text, including newlines and leading whitespace
  /// to reach the proper column.
  final String text;

  /// The result of running the [LineSplitter] on the block.
  final SplitResult result;

  FormattedBlock(this.text, this.result);
}

/// The result of running the [LineSplitter] on a range of chunks.
class SplitResult {
  /// The numeric cost of the chosen solution.
  final int cost;

  /// Where in the resulting buffer the selection starting point should appear
  /// if it was contained within this split list of chunks.
  ///
  /// Otherwise, this is `null`.
  final int selectionStart;

  /// Where in the resulting buffer the selection end point should appear if it
  /// was contained within this split list of chunks.
  ///
  /// Otherwise, this is `null`.
  final int selectionEnd;

  SplitResult(this.cost, this.selectionStart, this.selectionEnd);
}

/// Keeps track of the best set of splits found so far for a suffix of some
/// prefix.
class RunningSolution {
  /// The prefix whose suffix we are finding a solution for.
  final LinePrefix _prefix;

  SplitSet _bestSplits;
  int _lowestCost;

  /// The best set of splits currently found.
  SplitSet get splits => _bestSplits;

  /// Whether a solution that fits within a page has been found yet.
  bool get isAdequate => _lowestCost != null && _lowestCost < Cost.overflowChar;

  RunningSolution(this._prefix);

  /// Compares [splits] to the best solution found so far and keeps it if it's
  /// better.
  void update(LineSplitter splitter, SplitSet splits) {
    var cost = splitter._evaluateCost(_prefix, splits);

    if (_lowestCost == null || cost < _lowestCost) {
      _bestSplits = splits;
      _lowestCost = cost;
    }

    if (debug.traceSplitter) {
      var best = _bestSplits == splits ? " (best)" : "";
      debug.log(debug.gray("$_prefix $splits \$$cost$best"));
      debug.dumpLines(splitter._chunks, _prefix, splits);
      debug.log();
    }
  }
}

/// An immutable, persistent set of enabled split [Chunk]s.
///
/// For each chunk, this tracks if it has been split and, if so, what the
/// chosen column is for the following line.
///
/// Internally, this uses a sparse parallel list where each element corresponds
/// to the column of the chunk at that index in the chunk list, or `null` if
/// there is no active split there. This had about a 10% perf improvement over
/// using a [Set] of splits or a persistent linked list of split index/indent
/// pairs.
class SplitSet {
  List<int> _columns;

  /// Creates a new empty split set.
  SplitSet() : this._(const []);

  SplitSet._(this._columns);

  /// Returns a new [SplitSet] containing the union of this one and the split
  /// at [index] with next line starting at [column].
  SplitSet add(int index, int column) {
    var newIndents = new List(math.max(index + 1, _columns.length));
    newIndents.setAll(0, _columns);
    newIndents[index] = column;

    return new SplitSet._(newIndents);
  }

  /// Returns `true` if the chunk at [splitIndex] should be split.
  bool shouldSplitAt(int index) =>
      index < _columns.length && _columns[index] != null;

  /// Gets the zero-based starting column for the chunk at [index].
  int getColumn(int index) => _columns[index];

  String toString() {
    var result = [];
    for (var i = 0; i < _columns.length; i++) {
      if (_columns[i] != null) {
        result.add("$i:${_columns[i]}");
      }
    }

    return result.join(" ");
  }
}
