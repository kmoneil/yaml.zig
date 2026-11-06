//! The reader: YAML text to the parser's events in one pass, for the YAML
//! most documents are (t56). The parser takes the scanner's tokens, a
//! queue of them held until a `:` shows which scalar was a key; the
//! reader reads the text where it is, a block's lines by their
//! indentation, and knows a key by looking ahead on its line, which an
//! implicit key cannot leave. So there are no tokens and no queue, and
//! each event is given where the reader keeps it.
//!
//! A fast path, not a second parser. On what it does not read
//! (`Error.Unsupported`) it stops, and its caller reads the stream again
//! with the parser, past the events the reader gave: those are the
//! parser's, marks and all, which the suite's `reader` check and the
//! reader fuzz target hold it to. So every error, its message and its
//! mark, is the parser's.
//!
//! It reads with the scanner's character-level scanners (its cursor, its
//! plain line, quoted and block scalars), so a scalar's value is the
//! scanner's own. Not threadsafe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("Scanner.zig");
const Parser = @import("Parser.zig");
const chars = @import("chars.zig");
const encoding = @import("encoding.zig");

const Reader = @This();

/// What the reader gives (`Parser.Event`).
pub const Event = Parser.Event;
/// A place in the input (`Scanner.Mark`).
pub const Mark = Scanner.Mark;

pub const Error = error{
    /// What comes next is outside what the reader reads, or is not YAML:
    /// the parser must read the stream. For now that is a directive or a
    /// document marker, a second document, an anchor, an alias or a tag,
    /// an explicit key (`?`), a plain scalar of more than one line, a
    /// flow collection of more than one line or as a key, a pair in a
    /// flow sequence, a tab in indentation or between tokens, a byte
    /// order mark, an input not UTF-8 or past `Scanner.max_input`,
    /// collections deeper than `max_depth`, and every error.
    Unsupported,
    OutOfMemory,
};

const State = enum {
    stream_start,
    document_start,
    document_end,
    block_sequence_entry,
    /// A sequence at its mapping key's column, which no indentation ends:
    /// it ends at the first token that is not a `-`.
    indentless_sequence_entry,
    block_mapping_key,
    /// The cursor at the `:` after a key.
    block_mapping_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_mapping_first_key,
    flow_mapping_key,
    /// The cursor at the token after a key: its `:`, or else the value is
    /// empty.
    flow_mapping_value,
    /// After a key with no `:`, as `a` in `{a, b: c}`: the value is empty.
    flow_mapping_empty_value,
    /// After the stream's end.
    end,
};

/// Where a block node is: what may begin there.
const Place = enum {
    /// A document's root, or a sequence's entry: any node.
    entry,
    /// A mapping's value on the lines after its key: any node, and a
    /// sequence at the key's column too.
    value_below,
    /// A mapping's value on its key's line: no block collection begins
    /// there.
    value_inline,
};

/// The cursor, the input, the arena of values built (a quoted scalar's
/// with escapes, a block scalar's), and the scanners. Its `indent` and
/// `flow_level` are kept as the scanner's would be, for its scanners.
s: Scanner,
/// Events made and not yet given, from `head`.
events: std.ArrayList(Event) = .empty,
head: usize = 0,
state: State = .stream_start,
/// The states to return to as nodes end.
states: std.ArrayList(State) = .empty,
/// The columns of the block collections open, innermost last.
blocks: std.ArrayList(isize) = .empty,
/// Documents read: the reader reads one.
documents: usize = 0,

/// A reader over `input`, UTF-8. It allocates nothing until `next`.
pub fn init(gpa: Allocator, input: []const u8) Reader {
    return .{ .s = .init(gpa, input) };
}

/// Frees the reader and the values it built.
pub fn deinit(r: *Reader) void {
    const gpa = r.s.gpa;
    r.events.deinit(gpa);
    r.states.deinit(gpa);
    r.blocks.deinit(gpa);
    r.s.deinit();
    r.* = undefined;
}

/// The most collections open at once (`Scanner.max_depth`): past it the
/// reader stops, and the parser gives the error.
pub fn setMaxDepth(r: *Reader, depth: usize) void {
    r.s.max_depth = depth;
}

/// The next event, where the reader keeps it: valid until the next call.
/// After `stream_end`, `stream_end` again. `error.Unsupported` once is
/// the reader's last word: it must not be called again.
pub fn next(r: *Reader) Error!*const Event {
    if (r.head == r.events.items.len) {
        r.events.clearRetainingCapacity();
        r.head = 0;
        while (r.events.items.len == 0) try r.step();
    }
    r.head += 1;
    return &r.events.items[r.head - 1];
}

fn step(r: *Reader) Error!void {
    switch (r.state) {
        .stream_start => try r.streamStart(),
        .document_start => try r.documentStart(),
        .document_end => try r.documentEnd(),
        .block_sequence_entry => try r.blockSequenceEntry(),
        .indentless_sequence_entry => try r.indentlessSequenceEntry(),
        .block_mapping_key => try r.blockMappingKey(),
        .block_mapping_value => try r.blockMappingValue(),
        .flow_sequence_first_entry => try r.flowSequenceEntry(true),
        .flow_sequence_entry => try r.flowSequenceEntry(false),
        .flow_mapping_first_key => try r.flowMappingKey(true),
        .flow_mapping_key => try r.flowMappingKey(false),
        .flow_mapping_value => try r.flowMappingValue(false),
        .flow_mapping_empty_value => try r.flowMappingValue(true),
        .end => {
            const m = r.endMark();
            try r.emit(m, m, .stream_end);
        },
    }
}

// Events and states

/// Puts an event at the end of the queue: inlined to a check and a store,
/// the queue grown in a call apart (as the scanner's tokens, t49).
inline fn emit(r: *Reader, start: Mark, end: Mark, data: Event.Data) Error!void {
    if (r.events.items.len == r.events.capacity) try r.growEvents();
    r.events.appendAssumeCapacity(.{ .start = start, .end = end, .data = data });
}

noinline fn growEvents(r: *Reader) Error!void {
    try r.events.ensureUnusedCapacity(r.s.gpa, 1);
}

/// A scalar token's event.
fn emitScalar(r: *Reader, token: Scanner.Token) Error!void {
    const scalar = token.data.scalar;
    try r.emit(token.start, token.end, .{ .scalar = .{ .value = scalar.value, .style = scalar.style } });
}

/// An empty plain scalar at `mark`, as a node with no content is.
fn emitEmpty(r: *Reader, mark: Mark) Error!void {
    try r.emit(mark, mark, .{ .scalar = .{ .value = "", .style = .plain } });
}

fn push(r: *Reader, state: State) Error!void {
    try r.states.append(r.s.gpa, state);
}

/// Returns to the state saved when the node now ending began.
fn pop(r: *Reader) void {
    r.state = r.states.pop() orelse .end;
}

// Stream and document

fn streamStart(r: *Reader) Error!void {
    const input = r.s.input;
    if (input.len > Scanner.max_input or encoding.detect(input) != .utf8) return error.Unsupported;
    if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) return error.Unsupported;
    try r.emit(r.s.mark, r.s.mark, .stream_start);
    r.state = .document_start;
}

fn documentStart(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atEnd()) {
        const m = r.endMark();
        try r.emit(m, m, .stream_end);
        r.state = .end;
        return;
    }
    if (r.documents > 0 or r.s.mark.column == 0 and (r.s.ch(0) == '%' or r.s.atDocumentMarkerLine())) return error.Unsupported;
    try r.emit(r.s.mark, r.s.mark, .{ .document_start = .{ .explicit = false } });
    try r.push(.document_end);
    try r.blockNode(.entry);
}

fn documentEnd(r: *Reader) Error!void {
    try r.skipToToken();
    if (!r.atEnd()) return error.Unsupported;
    const m = r.endMark();
    try r.emit(m, m, .{ .document_end = .{ .explicit = false } });
    r.documents += 1;
    r.state = .document_start;
}

/// Where the stream ends, as the scanner marks it: a last line with no
/// line break is ended.
fn endMark(r: *const Reader) Mark {
    var m = r.s.mark;
    if (m.column != 0) {
        m.column = 0;
        m.line += 1;
    }
    return m;
}

// Block collections

/// The column of the innermost block collection, -1 with none.
fn indent(r: *const Reader) isize {
    const blocks = r.blocks.items;
    return if (blocks.len > 0) blocks[blocks.len - 1] else -1;
}

fn column(r: *const Reader) isize {
    return @intCast(r.s.mark.column);
}

/// Opens a block collection at `col`.
fn openBlock(r: *Reader, col: isize) Error!void {
    if (r.blocks.items.len + r.s.flow_level >= r.s.max_depth) return error.Unsupported;
    try r.blocks.append(r.s.gpa, col);
    r.s.indent = col;
}

/// Ends the innermost block collection, its end at `mark`.
fn closeBlock(r: *Reader, data: Event.Data, mark: Mark) Error!void {
    try r.emit(mark, mark, data);
    _ = r.blocks.pop();
    r.s.indent = r.indent();
    r.pop();
}

/// Where the next token ends a block collection: at its start, or at the
/// stream's end. There the scanner ends the blocks past the last line's
/// column where it stands, and then the rest where the stream ends, a
/// line further on if the last has no line break.
fn blockEndMark(r: *const Reader) Mark {
    if (!r.atEnd() or r.indent() > r.column()) return r.s.mark;
    return r.endMark();
}

/// A block node at the cursor, `place` saying what may begin there. The
/// state to return to when it ends is pushed.
fn blockNode(r: *Reader, place: Place) Error!void {
    const start = r.s.mark;
    const col = r.column();
    const ind = r.indent();
    if (r.s.ch(0) == '-' and r.s.indicatorEnds()) {
        if (place == .value_inline) return error.Unsupported;
        if (place == .value_below and col == ind) {
            try r.emit(start, start, .{ .sequence_start = .{ .flow = false } });
            r.state = .indentless_sequence_entry;
            return;
        }
        if (col <= ind) return error.Unsupported;
        try r.openBlock(col);
        try r.emit(start, start, .{ .sequence_start = .{ .flow = false } });
        r.state = .block_sequence_entry;
        return;
    }
    switch (r.s.ch(0)) {
        '|', '>' => return r.blockScalar(),
        '[', '{' => return r.flowStart(),
        '"', '\'' => return r.blockQuoted(place, start, col),
        else => return r.blockPlain(place, start, col),
    }
}

/// A plain scalar in a block, or the first key of a block mapping.
fn blockPlain(r: *Reader, place: Place, start: Mark, col: isize) Error!void {
    if (!r.atPlainStart()) return error.Unsupported;
    var end: Mark = undefined;
    r.s.scanPlainLine(&end) catch return error.Unsupported;
    const value = r.s.input[start.offset..end.offset];
    const token: Scanner.Token = .{ .start = start, .end = end, .data = .{ .scalar = .{ .value = value, .style = .plain } } };
    if (r.atValue()) return r.firstKey(place, start, col, token);
    if (r.s.ch(0) != '#' and r.plainContinues()) return error.Unsupported;
    try r.emitScalar(token);
    r.pop();
}

/// A quoted scalar in a block, or the first key of a block mapping.
fn blockQuoted(r: *Reader, place: Place, start: Mark, col: isize) Error!void {
    const token = r.s.scanQuotedScalar(if (r.s.ch(0) == '\'') .single_quoted else .double_quoted) catch |err| return unsupported(err);
    r.skipBlanks();
    if (r.atValue()) {
        if (token.end.line != start.line) return error.Unsupported;
        return r.firstKey(place, start, col, token);
    }
    if (!r.atBlockNodeEnd()) return error.Unsupported;
    try r.emitScalar(token);
    r.pop();
}

/// Opens a block mapping at `col` with `key` its first key, the cursor
/// at the key's `:`.
fn firstKey(r: *Reader, place: Place, start: Mark, col: isize, key: Scanner.Token) Error!void {
    if (place == .value_inline or col <= r.indent() or !r.keyFits(start)) return error.Unsupported;
    try r.openBlock(col);
    try r.emit(start, start, .{ .mapping_start = .{ .flow = false } });
    try r.emitScalar(key);
    r.state = .block_mapping_value;
}

fn blockScalar(r: *Reader) Error!void {
    const token = r.s.scanBlockScalar(if (r.s.ch(0) == '|') .literal else .folded) catch |err| return unsupported(err);
    try r.emitScalar(token);
    r.pop();
}

fn blockSequenceEntry(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atEnd() or r.column() < r.indent()) return r.closeBlock(.sequence_end, r.blockEndMark());
    if (r.column() > r.indent() or !r.atIndicator('-') or r.s.atDocumentMarkerLine()) return error.Unsupported;
    const line = r.s.mark.line;
    r.s.skip();
    const dash_end = r.s.mark;
    try r.skipToToken();
    if (r.atEnd() or r.s.mark.line != line and r.column() <= r.indent()) {
        if (!r.atEnd() and r.column() == r.indent() and !r.atIndicator('-')) return error.Unsupported;
        return r.emitEmpty(dash_end);
    }
    try r.push(.block_sequence_entry);
    try r.blockNode(.entry);
}

fn indentlessSequenceEntry(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atEnd() or r.column() < r.indent()) return r.endIndentless();
    if (r.column() > r.indent()) return error.Unsupported;
    if (!r.atIndicator('-')) {
        // The sequence ends at its mapping's next key, or a `:`: the
        // parser ends it on a token it could read, so nothing else.
        if (!r.atIndicator(':') and !try r.keyAhead()) return error.Unsupported;
        return r.endIndentless();
    }
    const line = r.s.mark.line;
    r.s.skip();
    const dash_end = r.s.mark;
    try r.skipToToken();
    if (r.atEnd() or r.s.mark.line != line and r.column() <= r.indent()) {
        if (!r.atEnd() and r.column() == r.indent() and !r.atIndicator('-') and !r.atIndicator(':') and !try r.keyAhead()) return error.Unsupported;
        return r.emitEmpty(dash_end);
    }
    try r.push(.indentless_sequence_entry);
    try r.blockNode(.entry);
}

fn endIndentless(r: *Reader) Error!void {
    const m = r.blockEndMark();
    try r.emit(m, m, .sequence_end);
    r.pop();
}

fn blockMappingKey(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atEnd() or r.column() < r.indent()) return r.closeBlock(.mapping_end, r.blockEndMark());
    if (r.column() > r.indent() or r.s.atDocumentMarkerLine()) return error.Unsupported;
    if (r.atIndicator(':')) {
        // A value with no key: the key is empty.
        try r.emitEmpty(r.s.mark);
        r.state = .block_mapping_value;
        return;
    }
    const key = try r.scanKey() orelse return error.Unsupported;
    try r.emitScalar(key);
    r.state = .block_mapping_value;
}

fn blockMappingValue(r: *Reader) Error!void {
    const line = r.s.mark.line;
    r.s.skip();
    const colon_end = r.s.mark;
    try r.skipToToken();
    r.state = .block_mapping_key;
    if (r.atEnd()) return r.emitEmpty(colon_end);
    if (r.s.mark.line == line) {
        try r.push(.block_mapping_key);
        return r.blockNode(.value_inline);
    }
    if (r.s.atDocumentMarkerLine()) return error.Unsupported;
    if (r.column() < r.indent()) return r.emitEmpty(colon_end);
    if (r.column() == r.indent() and !r.atIndicator('-')) {
        // The next key, or the `:` of an empty one.
        if (!r.atIndicator(':') and !try r.keyAhead()) return error.Unsupported;
        return r.emitEmpty(colon_end);
    }
    try r.push(.block_mapping_key);
    try r.blockNode(.value_below);
}

/// The key at the cursor, plain or quoted, the cursor left at its `:`;
/// null when what is there is not a key on this line.
fn scanKey(r: *Reader) Error!?Scanner.Token {
    const start = r.s.mark;
    const c = r.s.ch(0);
    const token: Scanner.Token = if (c == '"' or c == '\'') quoted: {
        const t = r.s.scanQuotedScalar(if (c == '\'') .single_quoted else .double_quoted) catch |err| return unsupported(err);
        r.skipBlanks();
        break :quoted t;
    } else plain: {
        if (!r.atPlainStart()) return null;
        var end: Mark = undefined;
        r.s.scanPlainLine(&end) catch return error.Unsupported;
        break :plain .{ .start = start, .end = end, .data = .{ .scalar = .{ .value = r.s.input[start.offset..end.offset], .style = .plain } } };
    };
    if (!r.atValue() or token.end.line != start.line or !r.keyFits(start)) return null;
    return token;
}

/// Whether a key is at the cursor, which is left where it is. Only the
/// cursor is put back: a value the look built stays in the arena.
fn keyAhead(r: *Reader) Error!bool {
    const mark = r.s.mark;
    const line_start = r.s.line_start;
    const line_has_token = r.s.line_has_token;
    defer {
        r.s.mark = mark;
        r.s.line_start = line_start;
        r.s.line_has_token = line_has_token;
    }
    return try r.scanKey() != null;
}

/// Whether the `:` at the cursor is near enough its key's `start` for the
/// key to be an implicit one: 1024 characters (YAML 1.2.2, 7.4.2).
fn keyFits(r: *const Reader, start: Mark) bool {
    return r.s.mark.column - start.column <= 1024;
}

/// Whether a plain scalar may begin at the cursor: not at an indicator,
/// but `-`, `?` and `:` with more of the scalar after them.
fn atPlainStart(r: *const Reader) bool {
    const c = r.s.ch(0);
    if (r.atEnd() or chars.isBlankOrBreak(c)) return false;
    return switch (c) {
        '-', '?', ':' => !r.s.indicatorEnds(),
        ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => false,
        else => c >= 0x20,
    };
}

/// Whether the plain scalar just read, its line ended, goes on to the
/// next lines: one past the block's column that is not a comment or a
/// document marker (the scanner's `plainContinues`). A tab in the way is
/// taken to mean yes.
fn plainContinues(r: *const Reader) bool {
    const input = r.s.input;
    var i: usize = r.s.mark.offset;
    while (i < input.len) {
        if (!chars.isBreak(input[i])) return true;
        i += breakLength(input, i);
        const line_start = i;
        while (i < input.len and input[i] == ' ') i += 1;
        if (i < input.len and chars.isBreak(input[i])) continue;
        return lineContinuesPlain(input, line_start, i, r.indent());
    }
    return false;
}

/// Whether the line at `line_start`, not empty, its indentation ending at
/// `i`, goes on with a plain scalar in a block at `indent`: past its
/// column, and no comment or document marker.
fn lineContinuesPlain(input: []const u8, line_start: usize, i: usize, indent_col: isize) bool {
    if (i >= input.len) return false;
    if (input[i] == '\t') return true;
    if (input[i] == '#') return false;
    if (i == line_start and (std.mem.startsWith(u8, input[i..], "---") or std.mem.startsWith(u8, input[i..], "..."))) return true;
    return @as(isize, @intCast(i - line_start)) > indent_col;
}

/// How many bytes the line break at `i` takes: `\r\n` two.
fn breakLength(input: []const u8, i: usize) usize {
    return if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') 2 else 1;
}

// Flow collections

/// Opens a flow collection at the cursor. One the reader cannot read to
/// its end on this line, or that is followed by a `:` (a key), is
/// unsupported.
fn flowStart(r: *Reader) Error!void {
    const close = r.flowCloseOnLine() orelse return error.Unsupported;
    if (!r.flowEndsNode(close + 1)) return error.Unsupported;
    if (r.blocks.items.len + r.s.flow_level >= r.s.max_depth) return error.Unsupported;
    const mapping = r.s.ch(0) == '{';
    const start = r.s.mark;
    r.s.skip();
    r.s.flow_level += 1;
    try r.emit(start, r.s.mark, if (mapping) .{ .mapping_start = .{ .flow = true } } else .{ .sequence_start = .{ .flow = true } });
    r.state = if (mapping) .flow_mapping_first_key else .flow_sequence_first_entry;
}

/// Whether what follows a flow collection ending before `at` can follow
/// a node there: in a flow collection a `,` or a closing bracket, in a
/// block the line's end or a comment. Anything else, a `:` above all
/// (the collection is a key), is the parser's to read.
fn flowEndsNode(r: *const Reader, at: usize) bool {
    const input = r.s.input;
    var i = at;
    while (i < input.len and chars.isBlank(input[i])) i += 1;
    if (i >= input.len) return r.s.flow_level == 0;
    const c = input[i];
    if (r.s.flow_level > 0) return c == ',' or c == ']' or c == '}';
    return chars.isBreak(c) or (c == '#' and i > at);
}

/// Where the flow collection opening at the cursor closes, if it does on
/// this line: its quoted scalars skipped, and a comment taken as the
/// line's end.
fn flowCloseOnLine(r: *const Reader) ?usize {
    const input = r.s.input;
    var depth: usize = 0;
    var i: usize = r.s.mark.offset;
    // The last character not a blank: a quote after it opens a quoted
    // scalar only where a node may begin.
    var last: u8 = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (c) {
            '[', '{' => depth += 1,
            ']', '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '\r', '\n' => return null,
            '#' => if (chars.isBlank(input[i - 1])) return null,
            '"', '\'' => {
                if (!opensQuoted(last, input[i - 1])) return null;
                i = quotedCloseOnLine(input, i) orelse return null;
            },
            else => {},
        }
        if (!chars.isBlank(c)) last = c;
    }
    return null;
}

/// Whether a quote opens a quoted scalar in a flow collection, `last` the
/// last character before it not a blank and `before` the one just before
/// it: after `[`, `{` or `,`, or a `:` and a blank. After anything else
/// the quote is in a plain scalar, or the line is the parser's to read.
fn opensQuoted(last: u8, before: u8) bool {
    return switch (last) {
        '[', '{', ',' => true,
        ':' => chars.isBlank(before),
        else => false,
    };
}

/// Where the quoted scalar opening at `open` closes, if it does on this
/// line: a `''` in a single-quoted one is a quote, an escape in a
/// double-quoted one is skipped.
fn quotedCloseOnLine(input: []const u8, open: usize) ?usize {
    const quote = input[open];
    var i = open + 1;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (chars.isBreak(c)) return null;
        if (quote == '"' and c == '\\') {
            if (i + 1 < input.len and chars.isBreak(input[i + 1])) return null;
            i += 1;
        } else if (c == quote) {
            if (quote == '"' or i + 1 >= input.len or input[i + 1] != '\'') return i;
            i += 1;
        }
    }
    return null;
}

/// Ends the flow collection at the cursor's `]` or `}`.
fn flowEnd(r: *Reader, data: Event.Data) Error!void {
    const start = r.s.mark;
    r.s.skip();
    r.s.flow_level -= 1;
    try r.emit(start, r.s.mark, data);
    r.pop();
}

fn flowSequenceEntry(r: *Reader, first: bool) Error!void {
    try r.skipFlowSpace();
    if (r.s.ch(0) != ']' and !first) {
        if (r.s.ch(0) != ',') return error.Unsupported;
        r.s.skip();
        try r.skipFlowSpace();
    }
    if (r.s.ch(0) == ']') return r.flowEnd(.sequence_end);
    try r.push(.flow_sequence_entry);
    try r.flowNode();
}

fn flowMappingKey(r: *Reader, first: bool) Error!void {
    try r.skipFlowSpace();
    if (r.s.ch(0) != '}' and !first) {
        if (r.s.ch(0) != ',') return error.Unsupported;
        r.s.skip();
        try r.skipFlowSpace();
    }
    switch (r.s.ch(0)) {
        '}' => return r.flowEnd(.mapping_end),
        '?', '[', '{' => return error.Unsupported,
        else => {},
    }
    if (r.s.ch(0) == ':' and r.s.indicatorEnds()) {
        // A value with no key: the key is empty.
        try r.emitEmpty(r.s.mark);
        r.state = .flow_mapping_value;
        return;
    }
    const token = try r.flowScalar();
    try r.skipFlowSpace();
    const value = r.s.ch(0) == ':';
    if (!value and !r.atFlowNodeEnd()) return error.Unsupported;
    try r.emitScalar(token);
    r.state = if (value) .flow_mapping_value else .flow_mapping_empty_value;
}

fn flowMappingValue(r: *Reader, empty: bool) Error!void {
    try r.skipFlowSpace();
    r.state = .flow_mapping_key;
    if (empty or r.s.ch(0) != ':') return r.emitEmpty(r.s.mark);
    r.s.skip();
    try r.skipFlowSpace();
    if (r.s.ch(0) == ',' or r.s.ch(0) == '}') return r.emitEmpty(r.s.mark);
    try r.push(.flow_mapping_key);
    try r.flowNode();
}

/// A node in a flow collection: a scalar, or a collection opened. One a
/// `:` follows, a key where none may be, is unsupported.
fn flowNode(r: *Reader) Error!void {
    switch (r.s.ch(0)) {
        '[', '{' => return r.flowStart(),
        else => {},
    }
    const token = try r.flowScalar();
    try r.skipFlowSpace();
    if (!r.atFlowNodeEnd()) return error.Unsupported;
    try r.emitScalar(token);
    r.pop();
}

/// A plain or quoted scalar of one line in a flow collection.
fn flowScalar(r: *Reader) Error!Scanner.Token {
    const start = r.s.mark;
    const c = r.s.ch(0);
    if (c == '"' or c == '\'') {
        const token = r.s.scanQuotedScalar(if (c == '\'') .single_quoted else .double_quoted) catch |err| return unsupported(err);
        if (token.end.line != start.line) return error.Unsupported;
        return token;
    }
    if (!r.atPlainStart()) return error.Unsupported;
    var end: Mark = undefined;
    r.s.scanPlainLine(&end) catch return error.Unsupported;
    if (r.s.ch(0) == '#' or r.atBreakOrEnd()) return error.Unsupported;
    return .{ .start = start, .end = end, .data = .{ .scalar = .{ .value = r.s.input[start.offset..end.offset], .style = .plain } } };
}

// Whitespace and comments

/// Moves past the blanks, comments and line breaks before the next token.
/// A tab is unsupported, and a comment must follow whitespace.
fn skipToToken(r: *Reader) Error!void {
    while (true) {
        r.skipSpaces();
        const c = r.s.ch(0);
        if (r.atEnd()) return;
        if (c == '\t') return error.Unsupported;
        if (c == '#') {
            r.s.skipComment() catch return error.Unsupported;
            continue;
        }
        if (!chars.isBreak(c)) return;
        r.s.skipBreak();
    }
}

/// Moves past the blanks and a comment between flow tokens, on one line.
fn skipFlowSpace(r: *Reader) Error!void {
    while (chars.isBlank(r.s.ch(0))) r.s.skip();
    if (r.s.ch(0) == '#' or r.atBreakOrEnd()) return error.Unsupported;
}

fn skipSpaces(r: *Reader) void {
    const input = r.s.input;
    var i: usize = r.s.mark.offset;
    while (i < input.len and input[i] == ' ') i += 1;
    r.advanceAscii(i);
}

/// Moves past the blanks after a token on its line.
fn skipBlanks(r: *Reader) void {
    const input = r.s.input;
    var i: usize = r.s.mark.offset;
    while (i < input.len and chars.isBlank(input[i])) i += 1;
    r.advanceAscii(i);
}

/// Moves to `offset`, past ASCII on the line: a character a byte.
fn advanceAscii(r: *Reader, offset: usize) void {
    const n: u32 = @intCast(offset - r.s.mark.offset);
    r.s.mark.offset += n;
    r.s.mark.column += n;
}

// Reading

fn atEnd(r: *const Reader) bool {
    return r.s.mark.offset >= r.s.input.len;
}

fn atBreakOrEnd(r: *const Reader) bool {
    return r.atEnd() or chars.isBreak(r.s.ch(0));
}

/// Whether `c` is at the cursor as an indicator: a blank, a line break or
/// the end after it (or in a flow collection a flow indicator).
fn atIndicator(r: *const Reader, c: u8) bool {
    return r.s.ch(0) == c and r.s.indicatorEnds();
}

/// Whether what is at the cursor, past a node's blanks, may follow a node
/// in a block: the line's end, or a comment after a blank.
fn atBlockNodeEnd(r: *const Reader) bool {
    if (r.atBreakOrEnd()) return true;
    const at = r.s.mark.offset;
    return r.s.ch(0) == '#' and at > 0 and chars.isBlank(r.s.input[at - 1]);
}

/// Whether what is at the cursor, past a node's blanks, may follow a node
/// in a flow collection: a `,` or a closing bracket.
fn atFlowNodeEnd(r: *const Reader) bool {
    const c = r.s.ch(0);
    return c == ',' or c == ']' or c == '}';
}

/// Whether a key's `:` is at the cursor: a value indicator.
fn atValue(r: *const Reader) bool {
    return r.atIndicator(':');
}

/// The scanner's errors, which the parser must give, as the reader's.
fn unsupported(err: Scanner.Error) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
}

// Held to the parser

/// How the reader read an input, against the parser.
pub const Comparison = struct {
    /// It read the stream to its end, handing nothing over.
    whole: bool,
    /// Where its events first differ from the parser's, or where it gave
    /// an event and the parser an error: null when they do not.
    problem: ?[]const u8,
};

/// Reads `input` with a reader and a parser side by side, event by event,
/// to the end or to where the reader hands over (the suite's `reader`
/// and `whole` checks, and the reader fuzz target).
pub fn compare(gpa: Allocator, arena: Allocator, input: []const u8) Allocator.Error!Comparison {
    var reader: Reader = .init(gpa, input);
    defer reader.deinit();
    var parser: Parser = .init(gpa, input);
    defer parser.deinit();
    // Each event takes at least a byte, but for a few around each node.
    const most = 8 * input.len + 64;
    for (0..most) |index| {
        const got = reader.next() catch |err| switch (err) {
            error.Unsupported => return .{ .whole = false, .problem = null },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const want = parser.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .whole = false, .problem = try arena.print("event {d}: the reader gave {f} where the parser fails: {s}", .{ index, shown(got.*), parser.diagnostic.message }) },
        };
        if (!same(got.*, want)) return .{ .whole = false, .problem = try arena.print("event {d}: the reader gave {f}, the parser {f}", .{ index, shown(got.*), shown(want) }) };
        if (want.data == .stream_end) return .{ .whole = true, .problem = null };
    }
    return .{ .whole = false, .problem = "the reader gave more events than the input can hold" };
}

/// Whether two events are the same, marks and all.
pub fn same(a: Event, b: Event) bool {
    if (!std.meta.eql(a.start, b.start) or !std.meta.eql(a.end, b.end)) return false;
    if (std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
    return switch (a.data) {
        .stream_start, .stream_end, .sequence_end, .mapping_end => true,
        .document_start => |d| sameDocumentStart(d, b.data.document_start),
        .document_end => |d| d.explicit == b.data.document_end.explicit,
        .alias => |name| std.mem.eql(u8, name, b.data.alias),
        .scalar => |s| sameProperties(s.properties, b.data.scalar.properties) and
            std.mem.eql(u8, s.value, b.data.scalar.value) and s.style == b.data.scalar.style,
        .sequence_start => |c| sameProperties(c.properties, b.data.sequence_start.properties) and c.flow == b.data.sequence_start.flow,
        .mapping_start => |c| sameProperties(c.properties, b.data.mapping_start.properties) and c.flow == b.data.mapping_start.flow,
    };
}

fn sameDocumentStart(a: Event.DocumentStart, b: Event.DocumentStart) bool {
    if (a.explicit != b.explicit or !std.meta.eql(a.version, b.version)) return false;
    if (a.tag_directives.len != b.tag_directives.len) return false;
    for (a.tag_directives, b.tag_directives) |x, y| {
        if (!std.mem.eql(u8, x.handle, y.handle) or !std.mem.eql(u8, x.prefix, y.prefix)) return false;
    }
    return true;
}

fn sameProperties(a: Event.Properties, b: Event.Properties) bool {
    return sameText(a.anchor, b.anchor) and sameText(a.tag, b.tag);
}

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// An event in the suite's notation, its marks after it, for a message.
fn shown(e: Event) Shown {
    return .{ .event = e };
}

const Shown = struct {
    event: Event,

    pub fn format(s: Shown, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var line: [256]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&line);
        Parser.writeTestEvent(&fixed, s.event) catch {};
        const text = std.mem.trimEnd(u8, fixed.buffered(), "\n");
        const a = s.event.start;
        const b = s.event.end;
        try w.print("`{s}` {d}:{d}-{d}:{d}", .{ text, a.line + 1, a.column + 1, b.line + 1, b.column + 1 });
    }
};
