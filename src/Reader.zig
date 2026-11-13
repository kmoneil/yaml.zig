//! The reader: YAML text to the parser's events in one pass (t56); every
//! valid input of the yaml-test-suite it reads to its end. The parser
//! takes the scanner's tokens, a queue of them held until a `:` shows
//! which scalar was a key; the reader reads the text where it is, a
//! block's lines by their indentation, and knows a key by looking ahead
//! on its line, which an implicit key cannot leave. So there are no
//! tokens and no queue, and each event is given where the reader keeps
//! it. Only a flow collection read as a key holds its events back, until
//! its `:` is read (`holdForKey`).
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
const schema = @import("schema.zig");

const Reader = @This();

/// What the reader gives (`Parser.Event`).
pub const Event = Parser.Event;
/// A place in the input (`Scanner.Mark`).
pub const Mark = Scanner.Mark;

pub const Error = error{
    /// What comes next is outside what the reader reads, or is not YAML:
    /// the parser must read the stream. That is every error, and a few
    /// valid forms the reader leaves to it: a byte order mark, a reserved
    /// directive after a document with no `...`, a flow collection as a
    /// key or a pair's that holds a quote the look ahead cannot place, an
    /// input past `Scanner.max_input`, and collections deeper than
    /// `max_depth`.
    Unsupported,
    OutOfMemory,
};

const State = enum {
    stream_start,
    document_start,
    /// After `---`: the document's root, on that line or after it, or
    /// none.
    document_content,
    document_end,
    block_sequence_entry,
    /// A sequence at its mapping key's column, which no indentation ends:
    /// it ends at the first token that is not a `-`.
    indentless_sequence_entry,
    block_mapping_key,
    /// The cursor at the `:` after an implicit key.
    block_mapping_value,
    /// After an explicit key (`?`), or at a `:` with no key before it: a
    /// `:` at the block's column, or else the value is empty. After such
    /// a `:` a block collection may begin on its line.
    block_mapping_explicit_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_mapping_first_key,
    flow_mapping_key,
    /// The cursor at the token after a key: its `:`, or else the value is
    /// empty.
    flow_mapping_value,
    /// After `?` in a flow sequence: a pair's key.
    flow_pair_key,
    /// After a pair's key in a flow sequence: its `:`, or else the value
    /// is empty.
    flow_pair_value,
    /// After a pair's value: the end of its mapping.
    flow_pair_end,
    /// After the stream's end.
    end,
};

/// Where a block node is: what may begin there.
const Place = enum {
    /// A document's root, or a sequence's entry: any node.
    entry,
    /// A mapping's value on the lines after its key, or an explicit key
    /// or its value (after `?` or a `:` with no implicit key): any node,
    /// and a sequence at the mapping's column too.
    value_below,
    /// An implicit key's value on its key's line: no block collection
    /// begins there.
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
/// The stream has just begun, or the last document ended with `...`:
/// the next may be bare.
after_end_marker: bool = true,
/// A tab was in the blanks just before the next token, on its line: no
/// block collection may open there (the scanner's `tab_before`).
tab_before: bool = false,
/// While a flow collection read as an implicit key has not shown its
/// `:`, the flow level it opened at: no event is given until the `:` is
/// read (`holdForKey`).
hold: ?usize = null,
/// The current document's %TAG directives, against which its tags are
/// resolved, as the parser's.
tag_directives: std.ArrayList(Scanner.Token.TagDirective) = .empty,
/// The most %TAG directives a document may have
/// (`Parser.max_tag_directives`): past it the reader stops, and the
/// parser gives the error.
max_tag_directives: usize = 64,
/// Whether the text of the events given is reused once all are: true
/// makes each event's text, where it is not the input's, valid only
/// until the next call (`Parser.text_lifetime`, t53).
reuse_text: bool = false,

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
    r.tag_directives.deinit(gpa);
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
/// the reader's last word: it must not be called again. Inlined to an
/// event already read, the queue read again in a call apart.
pub inline fn next(r: *Reader) Error!*const Event {
    if (r.head == r.events.items.len) try r.refill();
    r.head += 1;
    return &r.events.items[r.head - 1];
}

/// How many events `refill` reads at least, its last step's past it,
/// where the stream goes on. A refill, and a return through `step`, for
/// each event or two cost compose 6% of its time (t56); 64 is no faster.
const batch = 16;

/// Reads the next events into the queue, emptied: `batch` or more, held
/// ones until they are let go. A step that fails after others in the
/// batch leaves their events ungiven, and the parser, taking over, gives
/// them, as it does every event past those `next` gave.
noinline fn refill(r: *Reader) Error!void {
    // Every event in the queue has been given, the last of them before
    // this call: their text may go.
    if (r.reuse_text) r.s.reuseText();
    r.events.clearRetainingCapacity();
    r.head = 0;
    while (r.events.items.len == 0 or r.hold != null) try r.step();
    while (r.events.items.len < batch and r.state != .end) {
        try r.step();
        while (r.hold != null) try r.step();
    }
}

fn step(r: *Reader) Error!void {
    switch (r.state) {
        .stream_start => try r.streamStart(),
        .document_start => try r.documentStart(),
        .document_content => try r.documentContent(),
        .document_end => try r.documentEnd(),
        .block_sequence_entry => try r.blockSequenceEntry(),
        .indentless_sequence_entry => try r.indentlessSequenceEntry(),
        .block_mapping_key => try r.blockMappingKey(),
        .block_mapping_value => try r.blockMappingValue(false),
        .block_mapping_explicit_value => try r.blockMappingExplicitValue(),
        .flow_sequence_first_entry => try r.flowSequenceEntry(true),
        .flow_sequence_entry => try r.flowSequenceEntry(false),
        .flow_mapping_first_key => try r.flowMappingKey(true),
        .flow_mapping_key => try r.flowMappingKey(false),
        .flow_mapping_value => try r.flowMappingValue(),
        .flow_pair_key => try r.flowExplicitKey(']', .flow_pair_value),
        .flow_pair_value => try r.flowPairValue(),
        .flow_pair_end => try r.flowPairEnd(),
        .end => {
            if (r.hold != null) return error.Unsupported;
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

/// Makes room for a batch of events at once, as `refill` reads them.
noinline fn growEvents(r: *Reader) Error!void {
    try r.events.ensureUnusedCapacity(r.s.gpa, batch);
}

/// A scalar token's event, with the properties before it, if any.
fn emitScalarWith(r: *Reader, token: Scanner.Token, props: ?Props) Error!void {
    const e = scalarEvent(token, props);
    try r.emit(e.start, e.end, e.data);
}

/// The event of a scalar token and the properties before it, if any.
fn scalarEvent(token: Scanner.Token, props: ?Props) Event {
    const scalar = token.data.scalar;
    return .{ .start = startOf(props, token.start), .end = token.end, .data = .{ .scalar = .{ .properties = propertiesOf(props), .value = scalar.value, .style = scalar.style } } };
}

/// An empty scalar with properties and nothing after them, the node now
/// ending.
fn emitEmptyWith(r: *Reader, props: Props) Error!void {
    const e = emptyEvent(props);
    try r.emit(e.start, e.end, e.data);
    r.pop();
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
    // A `...` with no document before it ends nothing.
    while (r.atMarker("...")) {
        const line = r.s.mark.line;
        r.advanceAscii(r.s.mark.offset + 3);
        r.after_end_marker = true;
        try r.skipToToken();
        if (!r.atEnd() and r.s.mark.line == line) return error.Unsupported;
    }
    if (r.atEnd()) {
        const m = r.endMark();
        try r.emit(m, m, .stream_end);
        r.state = .end;
        return;
    }
    if (r.atDirective() or r.atMarker("---")) return r.explicitDocumentStart();
    // A document after another must begin with `---`, but after `...`.
    if (!r.after_end_marker) return error.Unsupported;
    r.tag_directives.clearRetainingCapacity();
    try r.emit(r.s.mark, r.s.mark, .{ .document_start = .{ .explicit = false } });
    try r.push(.document_end);
    try r.blockNode(.entry);
}

/// A document begun with `---`, and its directives before it, if any:
/// its start is the first directive's, but for one YAML reserves, which
/// the scanner skips as it does a comment.
fn explicitDocumentStart(r: *Reader) Error!void {
    r.tag_directives.clearRetainingCapacity();
    var start: ?Mark = null;
    var version: ?Scanner.Token.Version = null;
    while (r.atDirective()) {
        if (r.s.scanDirective() catch |err| return unsupported(err)) |token| {
            // A directive after a document must follow a `...` that ends
            // it; the parser says so.
            if (!r.after_end_marker) return error.Unsupported;
            if (start == null) start = token.start;
            try r.directive(token, &version);
        }
        try r.skipToToken();
    }
    if (!r.atMarker("---")) return error.Unsupported;
    const marker = r.s.mark;
    r.advanceAscii(marker.offset + 3);
    const tags = if (r.tag_directives.items.len == 0) &.{} else try r.s.arena.allocator().dupe(Scanner.Token.TagDirective, r.tag_directives.items);
    try r.emit(start orelse marker, r.s.mark, .{ .document_start = .{ .explicit = true, .version = version, .tag_directives = tags } });
    try r.push(.document_end);
    r.state = .document_content;
}

/// Takes a `%YAML` or `%TAG` directive into the document's. One the
/// parser refuses (a second %YAML, one not of YAML 1, a second %TAG for
/// a handle, one past `max_tag_directives`) is the parser's to read.
fn directive(r: *Reader, token: Scanner.Token, version: *?Scanner.Token.Version) Error!void {
    switch (token.data) {
        .version_directive => |v| {
            if (version.* != null or v.major != 1) return error.Unsupported;
            version.* = v;
        },
        .tag_directive => |d| {
            if (r.tag_directives.items.len >= r.max_tag_directives or r.tagPrefix(d.handle) != null) return error.Unsupported;
            try r.tag_directives.append(r.s.gpa, d);
        },
        else => unreachable,
    }
}

/// The prefix the current document's %TAG directive gives `handle`.
fn tagPrefix(r: *const Reader, handle: []const u8) ?[]const u8 {
    for (r.tag_directives.items) |d| {
        if (std.mem.eql(u8, d.handle, handle)) return d.prefix;
    }
    return null;
}

/// The root of a document begun with `---`: on that line no block
/// collection may begin. With none, the document is an empty scalar.
fn documentContent(r: *Reader) Error!void {
    const line = r.s.mark.line;
    try r.skipToToken();
    if (r.atDirective()) return error.Unsupported;
    if (r.atEnd() or r.s.atDocumentMarkerLine()) {
        const m = if (r.atEnd()) r.endMark() else r.s.mark;
        r.pop();
        return r.emitEmpty(m);
    }
    try r.blockNode(if (r.s.mark.line == line) .value_inline else .entry);
}

/// A document's end: `...`, after which only a comment may be on its
/// line; or, ended by no marker, the next `---` or the stream's end.
fn documentEnd(r: *Reader) Error!void {
    try r.skipToToken();
    r.state = .document_start;
    if (r.atMarker("...")) {
        const start = r.s.mark;
        r.advanceAscii(start.offset + 3);
        const end = r.s.mark;
        r.skipBlanks();
        if (!r.atBlockNodeEnd()) return error.Unsupported;
        try r.emit(start, end, .{ .document_end = .{ .explicit = true } });
        r.after_end_marker = true;
        // The parser gives `...` only once it has read the token after:
        // read on to it in this step, so a hand-over there drops this
        // event with it, not yet given.
        return r.documentStart();
    }
    if (!r.atEnd() and !r.atMarker("---")) return error.Unsupported;
    const m = if (r.atEnd()) r.endMark() else r.s.mark;
    try r.emit(m, m, .{ .document_end = .{ .explicit = false } });
    r.after_end_marker = false;
}

/// Whether the document marker `marker` begins the line at the cursor:
/// a blank, a line break or the end after it.
fn atMarker(r: *const Reader, comptime marker: []const u8) bool {
    if (r.s.mark.column != 0 or !std.mem.startsWith(u8, r.s.input[r.s.mark.offset..], marker)) return false;
    // As the scanner's: its `ch` gives a NUL byte as 0, as it does the
    // end, so `---` and a NUL is a marker too (found by the reader fuzz
    // target).
    const c = r.s.ch(3);
    return c == 0 or chars.isBlankOrBreak(c);
}

/// Whether a directive (`%`) begins the line at the cursor.
fn atDirective(r: *const Reader) bool {
    return r.s.mark.column == 0 and !r.atEnd() and r.s.ch(0) == '%';
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

/// Whether the next token ends the innermost block collection: the
/// stream's end, a document marker (which ends every one), or a line
/// less indented.
fn atBlockEnd(r: *const Reader) bool {
    return r.atEnd() or r.s.atDocumentMarkerLine() or r.column() < r.indent();
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
    const props = try r.scanProps();
    if (props) |p| {
        if (r.atBlockNodeEnd()) return r.propsBelow(place, p);
    }
    return r.blockContent(place, null, props);
}

/// After properties that end their line: what they belong to is on the
/// lines after, past the block's column, or a sequence at its key's
/// column; else it is an empty scalar. More properties on the node's
/// line are a mapping's first key's, or the node's own with these.
fn propsBelow(r: *Reader, place: Place, props: Props) Error!void {
    try r.skipToToken();
    if (r.atBlockEnd()) return r.emitEmptyWith(props);
    if (r.column() == r.indent()) {
        if (place != .entry and r.atIndicator('-')) {
            try r.emit(props.start, props.end, .{ .sequence_start = .{ .properties = props.properties, .flow = false } });
            r.state = .indentless_sequence_entry;
            return;
        }
        // The block's next entry, key or `:`: the node is empty.
        if (!r.atIndicator('-') and !try r.atKey()) return error.Unsupported;
        return r.emitEmptyWith(props);
    }
    const more = try r.scanProps() orelse return r.blockContent(.entry, props, null);
    if (r.atBlockNodeEnd()) return r.propsBelow(place, (try merge(props, more)).?);
    return r.blockContent(.entry, props, more);
}

/// A block node's content at the cursor. `outer`, the properties on the
/// lines before it, are a mapping's if it begins one, else the node's;
/// `props`, those on its line, are its first key's if it begins a
/// mapping, else the node's too. No block collection begins on its
/// properties' line, but a mapping whose first key they are.
fn blockContent(r: *Reader, place: Place, outer: ?Props, props: ?Props) Error!void {
    if (r.atIndicator('-') or r.atIndicator('?')) {
        if (props != null) return error.Unsupported;
        if (r.s.ch(0) == '-') return r.blockSequenceStart(place, outer);
        return r.blockMappingStart(place, outer, null);
    }
    if (r.atIndicator(':')) return r.blockMappingStart(place, outer, props);
    const start = r.s.mark;
    switch (r.s.ch(0)) {
        '*' => return r.blockAlias(place, outer, props),
        '|', '>' => return r.blockScalar(try merge(outer, props)),
        '[', '{' => return r.blockFlow(place, outer, props),
        '"', '\'' => return r.blockQuoted(place, start, outer, props),
        else => return r.blockPlain(place, start, outer, props),
    }
}

/// A block sequence begun at the cursor's `-`.
fn blockSequenceStart(r: *Reader, place: Place, props: ?Props) Error!void {
    const start = r.s.mark;
    const col = r.column();
    if (place == .value_inline) return error.Unsupported;
    if (place == .value_below and col == r.indent()) {
        try r.emit(start, start, .{ .sequence_start = .{ .flow = false } });
        r.state = .indentless_sequence_entry;
        return;
    }
    if (col <= r.indent() or r.tab_before) return error.Unsupported;
    try r.openBlock(col);
    try r.emit(startOf(props, start), start, .{ .sequence_start = .{ .properties = propertiesOf(props), .flow = false } });
    r.state = .block_sequence_entry;
}

/// A block mapping begun at the cursor by an explicit key's `?`, or by a
/// `:`: with `props` before it on its line, an implicit key that is an
/// empty scalar with them; with none, no key, and the key is empty.
fn blockMappingStart(r: *Reader, place: Place, outer: ?Props, props: ?Props) Error!void {
    if (props) |p| return r.firstKey(place, emptyEvent(p), outer);
    const start = r.s.mark;
    try r.openMapping(place, start, outer);
    if (r.s.ch(0) == '?') return r.explicitKey();
    try r.emitEmpty(start);
    r.state = .block_mapping_explicit_value;
}

/// An alias in a block, or the first key of a block mapping. An alias
/// has no properties: those before it can be only the mapping's.
fn blockAlias(r: *Reader, place: Place, outer: ?Props, props: ?Props) Error!void {
    if (props != null) return error.Unsupported;
    const start = r.s.mark;
    const name = try r.scanName();
    const end = r.s.mark;
    r.skipBlanks();
    const alias: Event = .{ .start = start, .end = end, .data = .{ .alias = name } };
    if (r.atValue()) return r.firstKey(place, alias, outer);
    if (outer != null or !r.atBlockNodeEnd()) return error.Unsupported;
    try r.emit(start, end, alias.data);
    r.pop();
}

/// A plain scalar in a block, or the first key of a block mapping.
fn blockPlain(r: *Reader, place: Place, start: Mark, outer: ?Props, props: ?Props) Error!void {
    if (!r.atPlainStart()) return error.Unsupported;
    var end: Mark = undefined;
    r.s.scanPlainLine(&end) catch return error.Unsupported;
    const value = r.s.input[start.offset..end.offset];
    const token: Scanner.Token = .{ .start = start, .end = end, .data = .{ .scalar = .{ .value = value, .style = .plain } } };
    if (r.atValue()) return r.firstKey(place, scalarEvent(token, props), outer);
    const all = try merge(outer, props);
    if (r.s.ch(0) != '#' and r.plainContinues()) return r.blockPlainLines(start, all);
    try r.emitScalarWith(token, all);
    r.pop();
}

/// A plain scalar of more than one line, read again from its `start` by
/// the scanner, which folds its lines. A `:` after it on its last line
/// would make a key of more than one line: the parser's.
fn blockPlainLines(r: *Reader, start: Mark, props: ?Props) Error!void {
    r.s.mark = start;
    const token = r.s.scanPlainScalar() catch |err| return unsupported(err);
    if (r.atValue() and r.s.mark.line == token.end.line) return error.Unsupported;
    try r.emitScalarWith(token, props);
    r.pop();
}

/// A quoted scalar in a block, or the first key of a block mapping.
fn blockQuoted(r: *Reader, place: Place, start: Mark, outer: ?Props, props: ?Props) Error!void {
    const token = r.s.scanQuotedScalar(if (r.s.ch(0) == '\'') .single_quoted else .double_quoted) catch |err| return unsupported(err);
    r.skipBlanks();
    if (r.atValue()) {
        if (token.end.line != start.line) return error.Unsupported;
        return r.firstKey(place, scalarEvent(token, props), outer);
    }
    if (!r.atBlockNodeEnd()) return error.Unsupported;
    try r.emitScalarWith(token, try merge(outer, props));
    r.pop();
}

/// A flow collection in a block, or one that is the first key of a block
/// mapping: closed on its line, and a `:` after it there. One that goes
/// on past its line is no key, and neither is an implicit key's value on
/// its line, after whose `:` the scanner saves no key: no look ahead for
/// it, the commonest.
fn blockFlow(r: *Reader, place: Place, outer: ?Props, props: ?Props) Error!void {
    if (place == .value_inline) return r.flowStart(try merge(outer, props));
    const start = startOf(props, r.s.mark);
    switch (r.flowLine()) {
        .closes => |close| {
            if (r.flowEndsNode(close + 1)) return r.flowStart(try merge(outer, props));
            if (!r.blockValueAfter(close + 1, start)) return error.Unsupported;
            try r.openMapping(place, start, outer);
            try r.push(.block_mapping_value);
            r.holdForKey();
            return r.flowStart(props);
        },
        .goes_on => return r.flowStart(try merge(outer, props)),
        .unclear => return error.Unsupported,
    }
}

/// Opens a block mapping at the column of its first key, `key`, the
/// cursor at the key's `:`, and gives the key's event.
fn firstKey(r: *Reader, place: Place, key: Event, outer: ?Props) Error!void {
    if (!r.keyFits(key.start)) return error.Unsupported;
    try r.openMapping(place, key.start, outer);
    try r.emit(key.start, key.end, key.data);
    r.state = .block_mapping_value;
}

/// Opens a block mapping whose first key begins at `start`, as the
/// scanner does where it saved the key (at its properties, if any): past
/// the block's column, with no tab before it on its line. `outer`, on the
/// lines before, are the mapping's properties.
fn openMapping(r: *Reader, place: Place, start: Mark, outer: ?Props) Error!void {
    const col: isize = @intCast(start.column);
    if (place == .value_inline or col <= r.indent() or r.tab_before) return error.Unsupported;
    try r.openBlock(col);
    try r.emit(startOf(outer, start), start, .{ .mapping_start = .{ .properties = propertiesOf(outer), .flow = false } });
}

fn blockScalar(r: *Reader, props: ?Props) Error!void {
    const token = r.s.scanBlockScalar(if (r.s.ch(0) == '|') .literal else .folded) catch |err| return unsupported(err);
    try r.emitScalarWith(token, props);
    r.pop();
}

// Properties and aliases

/// A node's properties, read ahead of its content: an anchor and a tag,
/// the tag resolved as the parser does, and where they lie.
const Props = struct {
    properties: Event.Properties = .{},
    start: Mark,
    end: Mark,
};

fn startOf(props: ?Props, start: Mark) Mark {
    return if (props) |p| p.start else start;
}

fn propertiesOf(props: ?Props) Event.Properties {
    return if (props) |p| p.properties else .{};
}

/// The properties of a node written on two lines, `outer` on the lines
/// before and `props` after: an anchor and a tag at most, as the parser
/// takes them. A second of either is the parser's to read.
fn merge(outer: ?Props, props: ?Props) Error!?Props {
    const a = outer orelse return props;
    const b = props orelse return a;
    if (a.properties.anchor != null and b.properties.anchor != null) return error.Unsupported;
    if (a.properties.tag != null and b.properties.tag != null) return error.Unsupported;
    return .{
        .properties = .{ .anchor = a.properties.anchor orelse b.properties.anchor, .tag = a.properties.tag orelse b.properties.tag },
        .start = a.start,
        .end = b.end,
    };
}

/// An empty scalar with properties and nothing after them: its marks are
/// theirs.
fn emptyEvent(props: Props) Event {
    return .{ .start = props.start, .end = props.end, .data = .{ .scalar = .{ .properties = props.properties, .value = "", .style = .plain } } };
}

/// The properties at the cursor, an anchor and a tag in either order, on
/// one line, and the blanks after them; null with none. A second anchor
/// or tag is the parser's. Inlined to its first check: most nodes have
/// none.
inline fn scanProps(r: *Reader) Error!?Props {
    if (r.s.ch(0) != '&' and r.s.ch(0) != '!') return null;
    return try r.scanSomeProps();
}

fn scanSomeProps(r: *Reader) Error!Props {
    var props: Props = .{ .start = r.s.mark, .end = r.s.mark };
    while (true) {
        switch (r.s.ch(0)) {
            '&' => {
                if (props.properties.anchor != null) return error.Unsupported;
                props.properties.anchor = try r.scanName();
            },
            '!' => {
                if (props.properties.tag != null) return error.Unsupported;
                props.properties.tag = try r.scanTag();
            },
            else => return props,
        }
        props.end = r.s.mark;
        r.skipBlanks();
    }
}

/// An anchor's or an alias's name, after its `&` or `*`.
fn scanName(r: *Reader) Error![]const u8 {
    r.s.skip();
    const start = r.s.mark.offset;
    while (r.s.atAnchorCharacter()) r.s.skip();
    const name = r.s.input[start..r.s.mark.offset];
    if (name.len == 0) return error.Unsupported;
    r.s.expectPropertyEnd() catch |err| return unsupported(err);
    return name;
}

/// A tag, resolved as the parser does: against the document's %TAG
/// directives, then the default handles. One whose handle neither gives
/// is the parser's to refuse.
fn scanTag(r: *Reader) Error![]const u8 {
    const tag = (if (r.s.ch(1) == '<') r.s.scanVerbatimTag() else r.s.scanShorthandTag()) catch |err| return unsupported(err);
    r.s.expectPropertyEnd() catch |err| return unsupported(err);
    if (tag.handle.len == 0) return tag.suffix;
    if (tag.suffix.len == 0) return "!";
    const prefix = r.tagPrefix(tag.handle) orelse defaultPrefix(tag.handle) orelse return error.Unsupported;
    return std.mem.concat(r.s.arena.allocator(), u8, &.{ prefix, tag.suffix });
}

/// The prefix of `!` or `!!` with no %TAG directive for it.
fn defaultPrefix(handle: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, handle, "!")) return "!";
    if (std.mem.eql(u8, handle, "!!")) return schema.core_prefix;
    return null;
}

fn blockSequenceEntry(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atBlockEnd()) return r.closeBlock(.sequence_end, r.blockEndMark());
    if (r.column() > r.indent() or !r.atIndicator('-')) return error.Unsupported;
    const line = r.s.mark.line;
    r.s.skip();
    const dash_end = r.s.mark;
    try r.skipToToken();
    if (r.atBlockEnd() or r.s.mark.line != line and r.column() <= r.indent()) {
        if (!r.atBlockEnd() and !r.atIndicator('-')) return error.Unsupported;
        return r.emitEmpty(dash_end);
    }
    try r.push(.block_sequence_entry);
    try r.blockNode(.entry);
}

fn indentlessSequenceEntry(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atBlockEnd()) return r.endIndentless();
    if (r.column() > r.indent()) return error.Unsupported;
    if (!r.atIndicator('-')) {
        // The sequence ends at its mapping's next key, or a `:`: the
        // parser ends it on a token it could read, so nothing else.
        if (!try r.atKey()) return error.Unsupported;
        return r.endIndentless();
    }
    const line = r.s.mark.line;
    r.s.skip();
    const dash_end = r.s.mark;
    try r.skipToToken();
    if (r.atBlockEnd() or r.s.mark.line != line and r.column() <= r.indent()) {
        if (!r.atBlockEnd() and !r.atIndicator('-') and !try r.atKey()) return error.Unsupported;
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
    if (r.atBlockEnd()) return r.closeBlock(.mapping_end, r.blockEndMark());
    if (r.column() > r.indent()) return error.Unsupported;
    if (r.atIndicator('?')) return r.explicitKey();
    if (r.atIndicator(':')) {
        // A value with no key: the key is empty.
        try r.emitEmpty(r.s.mark);
        r.state = .block_mapping_explicit_value;
        return;
    }
    const start = r.s.mark;
    const props = try r.scanProps();
    if (r.s.ch(0) == '[' or r.s.ch(0) == '{') {
        // A flow collection as a key, closed on its line.
        if (!r.flowKeyAhead(start)) return error.Unsupported;
        try r.push(.block_mapping_value);
        r.holdForKey();
        return r.flowStart(props);
    }
    const key = try r.scanKeyAfter(start, props) orelse return error.Unsupported;
    try r.emit(key.start, key.end, key.data);
    // The cursor is at the key's `:`: its value is read on at once, not a
    // step later, a return through `step` saved a key.
    return r.blockMappingValue(false);
}

/// An explicit key at the cursor's `?`, and its node, which may be a
/// block collection begun on its line; with none, the key is empty.
fn explicitKey(r: *Reader) Error!void {
    const line = r.s.mark.line;
    r.s.skip();
    const end = r.s.mark;
    try r.skipToToken();
    r.state = .block_mapping_explicit_value;
    if (r.atBlockEnd()) return r.emitEmpty(end);
    if (r.s.mark.line != line and r.column() <= r.indent() and !r.atIndicator('-')) {
        // The next key, or the `:` of this one's value.
        if (!try r.atKey()) return error.Unsupported;
        return r.emitEmpty(end);
    }
    try r.push(.block_mapping_explicit_value);
    try r.blockNode(.value_below);
}

/// After an explicit key: its `:`, at the block's column, or else an
/// empty value and the next key, or the block's end.
fn blockMappingExplicitValue(r: *Reader) Error!void {
    try r.skipToToken();
    if (r.atBlockEnd()) {
        r.state = .block_mapping_key;
        return r.emitEmpty(r.blockEndMark());
    }
    if (r.column() != r.indent()) return error.Unsupported;
    if (r.atIndicator(':')) return r.blockMappingValue(true);
    if (!try r.atKey()) return error.Unsupported;
    r.state = .block_mapping_key;
    return r.emitEmpty(r.s.mark);
}

/// The value after the `:` at the cursor. `explicit`: the `:` follows no
/// implicit key, so a block collection may begin on its line.
fn blockMappingValue(r: *Reader, explicit: bool) Error!void {
    // After a flow collection as a key, held for it, blanks may come
    // before the `:`.
    if (r.hold) |level| {
        if (level == r.s.flow_level) {
            r.skipBlanks();
            if (!r.atValue()) return error.Unsupported;
            r.hold = null;
        }
    }
    const line = r.s.mark.line;
    r.s.skip();
    const colon_end = r.s.mark;
    try r.skipToToken();
    r.state = .block_mapping_key;
    if (r.atEnd()) return r.emitEmpty(colon_end);
    if (r.s.mark.line == line) {
        try r.push(.block_mapping_key);
        return r.blockNode(if (explicit) .value_below else .value_inline);
    }
    if (r.atBlockEnd()) return r.emitEmpty(colon_end);
    if (r.column() == r.indent() and !r.atIndicator('-')) {
        // The next key, or the `:` of an empty one.
        if (!try r.atKey()) return error.Unsupported;
        return r.emitEmpty(colon_end);
    }
    try r.push(.block_mapping_key);
    try r.blockNode(.value_below);
}

/// The implicit key at the cursor after its properties, `props`, which
/// begin at `start`: its event, an alias, a plain or quoted scalar, or an
/// empty scalar with properties, the cursor left at its `:`; null when
/// what is there is not a key on this line.
fn scanKeyAfter(r: *Reader, start: Mark, props: ?Props) Error!?Event {
    if (r.s.ch(0) == '*') return if (props == null) r.scanAliasKey(start) else null;
    if (props) |p| {
        if (r.atValue()) return if (r.keyFits(start)) emptyEvent(p) else null;
    }
    const scalar_start = r.s.mark;
    const c = r.s.ch(0);
    const token: Scanner.Token = if (c == '"' or c == '\'') quoted: {
        const t = r.s.scanQuotedScalar(if (c == '\'') .single_quoted else .double_quoted) catch |err| return unsupported(err);
        r.skipBlanks();
        break :quoted t;
    } else plain: {
        if (!r.atPlainStart()) return null;
        var end: Mark = undefined;
        r.s.scanPlainLine(&end) catch return error.Unsupported;
        break :plain .{ .start = scalar_start, .end = end, .data = .{ .scalar = .{ .value = r.s.input[scalar_start.offset..end.offset], .style = .plain } } };
    };
    if (!r.atValue() or token.end.line != start.line or !r.keyFits(start)) return null;
    return scalarEvent(token, props);
}

/// The alias at the cursor, `start`, as an implicit key, the cursor left
/// at its `:`; null when it is no key.
fn scanAliasKey(r: *Reader, start: Mark) Error!?Event {
    const name = try r.scanName();
    const end = r.s.mark;
    r.skipBlanks();
    if (!r.atValue() or !r.keyFits(start)) return null;
    return .{ .start = start, .end = end, .data = .{ .alias = name } };
}

/// Whether a block mapping's next key is at the cursor: a `?`, a `:` with
/// no key before it, or an implicit key. The cursor stays where it is.
fn atKey(r: *Reader) Error!bool {
    return r.atIndicator('?') or r.atIndicator(':') or try r.keyAhead();
}

/// Whether an implicit key is at the cursor, which is left where it is.
/// Only the cursor is put back: a value the look built stays in the
/// arena.
fn keyAhead(r: *Reader) Error!bool {
    const mark = r.s.mark;
    const line_start = r.s.line_start;
    const line_has_token = r.s.line_has_token;
    defer {
        r.s.mark = mark;
        r.s.line_start = line_start;
        r.s.line_has_token = line_has_token;
    }
    const props = try r.scanProps();
    if (r.s.ch(0) == '[' or r.s.ch(0) == '{') {
        // An empty node before it is given only once it is read a key.
        if (!r.flowKeyAhead(mark)) return false;
        r.holdForKey();
        return true;
    }
    return try r.scanKeyAfter(mark, props) != null;
}

/// Holds the events from here until the `:` after the flow collection
/// about to be read as an implicit key, if none are held yet. The parser
/// reads it as a key only once its scanner has read the `:`: an error
/// inside it keeps the scanner from that, and the parser then reads the
/// collection as no key, so the reader gives nothing it read on the
/// strength of a look ahead until the `:` is read. The key is on one
/// line, so what is held is a line's.
fn holdForKey(r: *Reader) void {
    if (r.hold == null) r.hold = r.s.flow_level;
}

/// Whether the flow collection at the cursor is a block mapping's key,
/// begun with its properties at `start`: closed on its line, and a `:`
/// after it there (`blockValueAfter`).
fn flowKeyAhead(r: *const Reader, start: Mark) bool {
    return switch (r.flowLine()) {
        .closes => |close| r.blockValueAfter(close + 1, start),
        .goes_on, .unclear => false,
    };
}

/// Whether a block mapping's `:` follows a flow collection ending before
/// `at` (`colonAfter`): in a block one with a blank, a line break or the
/// end after it.
fn blockValueAfter(r: *const Reader, at: usize, start: Mark) bool {
    const input = r.s.input;
    const i = colonAfter(input, at, start) orelse return false;
    // As the scanner's `ch`, the end and a NUL byte are alike.
    const after: u8 = if (i + 1 < input.len) input[i + 1] else 0;
    return after == 0 or chars.isBlankOrBreak(after);
}

/// Where a `:` is at `at`, or past blanks after it on its line, near
/// enough a key begun at `start` for an implicit key: 1024 bytes, which
/// are at least as many characters as the scanner counts. Null with none.
fn colonAfter(input: []const u8, at: usize, start: Mark) ?usize {
    var i = at;
    while (i < input.len and chars.isBlank(input[i])) i += 1;
    if (i >= input.len or input[i] != ':' or i - start.offset > 1024) return null;
    return i;
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
    if (i == line_start and atMarkerText(input, i)) return false;
    return @as(isize, @intCast(i - line_start)) > indent_col;
}

/// Whether a document marker, `---` or `...` and a blank, a line break
/// or the end after it, is at `i` in `input`.
fn atMarkerText(input: []const u8, i: usize) bool {
    const rest = input[i..];
    if (!std.mem.startsWith(u8, rest, "---") and !std.mem.startsWith(u8, rest, "...")) return false;
    return rest.len == 3 or rest[3] == 0 or chars.isBlankOrBreak(rest[3]);
}

/// How many bytes the line break at `i` takes: `\r\n` two.
fn breakLength(input: []const u8, i: usize) usize {
    return if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') 2 else 1;
}

// Flow collections

/// Opens a flow collection at the cursor. Whether it is a key its caller
/// has seen to: in a block `blockFlow`, in a flow sequence
/// `flowEntryCollection`, and in a flow mapping its state after it.
fn flowStart(r: *Reader, props: ?Props) Error!void {
    if (r.blocks.items.len + r.s.flow_level >= r.s.max_depth) return error.Unsupported;
    const mapping = r.s.ch(0) == '{';
    const start = startOf(props, r.s.mark);
    const collection: Event.Collection = .{ .properties = propertiesOf(props), .flow = true };
    r.s.skip();
    r.s.flow_level += 1;
    try r.emit(start, r.s.mark, if (mapping) .{ .mapping_start = collection } else .{ .sequence_start = collection });
    r.state = if (mapping) .flow_mapping_first_key else .flow_sequence_first_entry;
}

/// Whether what follows a flow collection ending before `at` can follow
/// a node there: in a flow collection a `,` or a closing bracket, in a
/// block the line's end or a comment. Anything else, a `:` above all
/// (the collection is a key), is the parser's to read.
fn flowEndsNode(r: *const Reader, at: usize) bool {
    const input = r.s.input;
    if (r.s.flow_level > 0) {
        const c = nextFlowToken(input, at) orelse return false;
        return c == ',' or c == ']' or c == '}';
    }
    var i = at;
    while (i < input.len and chars.isBlank(input[i])) i += 1;
    if (i >= input.len) return true;
    return chars.isBreak(input[i]) or (input[i] == '#' and i > at);
}

/// The first character of the next token in a flow collection from
/// `at`: past blanks, line breaks and comments, which separate tokens
/// there. Null at the end.
fn nextFlowToken(input: []const u8, at: usize) ?u8 {
    var i = at;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (chars.isBlankOrBreak(c)) continue;
        if (c != '#' or i == at or !chars.isBlankOrBreak(input[i - 1])) return c;
        while (i + 1 < input.len and !chars.isBreak(input[i + 1])) i += 1;
    }
    return null;
}

/// How the flow collection opening at the cursor stands on its line.
const FlowLine = union(enum) {
    /// It closes here, at this offset.
    closes: usize,
    /// The line ends, or a comment or a quoted scalar takes it to its
    /// end, with the collection open.
    goes_on,
    /// A quote the look cannot place, or a verbatim tag, whose URI may
    /// hold brackets: the parser's to read.
    unclear,
};

/// Where the flow collection opening at the cursor closes, if it does on
/// this line: its quoted scalars skipped, and a comment taken as the
/// line's end.
fn flowLine(r: *const Reader) FlowLine {
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
                if (depth == 0) return .{ .closes = i };
            },
            '\r', '\n' => return .goes_on,
            '#' => if (chars.isBlank(input[i - 1])) return .goes_on,
            '!' => if (i + 1 < input.len and input[i + 1] == '<') return .unclear,
            '"', '\'' => {
                if (!opensQuoted(last, input[i - 1])) return .unclear;
                i = quotedCloseOnLine(input, i) orelse return .goes_on;
            },
            else => {},
        }
        if (!chars.isBlank(c)) last = c;
    }
    return .goes_on;
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
    if (r.atIndicator('?') or r.atIndicator(':')) return r.flowPairStart();
    try r.flowEntry();
}

/// A flow sequence's entry: a node, or a pair (a mapping of its own,
/// YAML 1.2.2, 7.4.3) whose implicit key is on one line with its `:`: a
/// key in a flow sequence goes stale at its line's end, as in a block.
fn flowEntry(r: *Reader) Error!void {
    const start = r.s.mark;
    const props = try r.scanProps();
    if (props) |p| {
        try r.skipFlowSpace();
        if (r.atFlowNodeEnd()) return r.emitEmptyWith(p);
        if (r.atIndicator(':')) return r.flowPair(start, emptyEvent(p));
    }
    switch (r.s.ch(0)) {
        '*' => return if (props == null) r.flowEntryAlias(start) else error.Unsupported,
        '[', '{' => return r.flowEntryCollection(start, props),
        else => {},
    }
    const token = try r.flowScalar();
    r.skipBlanks();
    if (r.atFlowValue(token.data.scalar.style != .plain)) return r.flowPair(start, scalarEvent(token, props));
    try r.skipFlowSpace();
    if (!r.atFlowNodeEnd()) return error.Unsupported;
    try r.emitScalarWith(token, props);
    r.pop();
}

/// An alias as a flow sequence's entry, or as a pair's key.
fn flowEntryAlias(r: *Reader, start: Mark) Error!void {
    const name = try r.scanName();
    const alias: Event = .{ .start = start, .end = r.s.mark, .data = .{ .alias = name } };
    r.skipBlanks();
    if (r.atIndicator(':')) return r.flowPair(start, alias);
    try r.skipFlowSpace();
    if (!r.atFlowNodeEnd()) return error.Unsupported;
    try r.emit(alias.start, alias.end, alias.data);
    r.pop();
}

/// A flow collection as a flow sequence's entry, or as a pair's key:
/// closed on the line its key began on, and a `:` after it there. As an
/// entry, closed on its line, a `,` or a closing bracket must follow it:
/// the scanner's key at it stays possible past anything else on the line
/// (a tag, a scalar), and a `:` after that makes it a pair's key all the
/// same. One that goes on past its line is no key.
fn flowEntryCollection(r: *Reader, start: Mark, props: ?Props) Error!void {
    switch (r.flowLine()) {
        .closes => |close| if (start.line == r.s.mark.line and r.flowValueAfter(close + 1, start)) {
            r.holdForKey();
            try r.emit(start, start, .{ .mapping_start = .{ .flow = true } });
            try r.push(.flow_pair_value);
        } else if (!r.flowEndsNode(close + 1)) return error.Unsupported,
        .goes_on => {},
        .unclear => return error.Unsupported,
    }
    return r.flowStart(props);
}

/// A pair in a flow sequence whose implicit key, `key`, began at
/// `start`, the cursor at its `:`, which must be on the key's line and
/// near enough it. The pair's mapping begins where the key does.
fn flowPair(r: *Reader, start: Mark, key: Event) Error!void {
    if (r.s.mark.line != start.line or !r.keyFits(start)) return error.Unsupported;
    try r.emit(start, start, .{ .mapping_start = .{ .flow = true } });
    try r.emit(key.start, key.end, key.data);
    r.state = .flow_pair_value;
}

/// A pair in a flow sequence begun by `?`, or by a `:` with no key before
/// it: its mapping begins at the indicator, and with the `:` its key is
/// empty.
fn flowPairStart(r: *Reader) Error!void {
    const start = r.s.mark;
    var end = start;
    end.offset += 1;
    end.column += 1;
    try r.emit(start, end, .{ .mapping_start = .{ .flow = true } });
    if (r.s.ch(0) == ':') {
        try r.emitEmpty(start);
        r.state = .flow_pair_value;
        return;
    }
    r.s.skip();
    r.state = .flow_pair_key;
}

/// An explicit key's node after its `?`, or an empty one before a `:`, a
/// `,` or the collection's `close`; `then`, the state its value is read
/// in.
fn flowExplicitKey(r: *Reader, close: u8, then: State) Error!void {
    try r.skipFlowSpace();
    if (r.atIndicator(':') or r.s.ch(0) == ',' or r.s.ch(0) == close) {
        try r.emitEmpty(r.s.mark);
        r.state = then;
        return;
    }
    try r.push(then);
    try r.flowNode(true);
}

/// After a pair's key: its `:` and value, or else an empty value.
fn flowPairValue(r: *Reader) Error!void {
    if (r.hold) |level| {
        if (level == r.s.flow_level) {
            r.skipBlanks();
            if (r.s.ch(0) != ':') return error.Unsupported;
            r.hold = null;
        }
    }
    try r.skipFlowSpace();
    r.state = .flow_pair_end;
    if (r.s.ch(0) != ':') return r.emitEmptyBefore();
    r.s.skip();
    try r.skipFlowSpace();
    if (r.s.ch(0) == ',' or r.s.ch(0) == ']') return r.emitEmpty(r.s.mark);
    try r.push(.flow_pair_end);
    try r.flowNode(false);
}

/// After a pair's value: its mapping ends where the next token begins,
/// a `,` or a closing bracket (`emitEmptyBefore`).
fn flowPairEnd(r: *Reader) Error!void {
    try r.skipFlowSpace();
    if (!r.atFlowNodeEnd()) return error.Unsupported;
    try r.emit(r.s.mark, r.s.mark, .mapping_end);
    r.pop();
}

/// An empty value where the next token begins, which must be a `,` or a
/// closing bracket: the parser reads that token to give the event, and
/// a character no token begins with (after a collection, which leaves
/// what follows it unread) is its error first.
fn emitEmptyBefore(r: *Reader) Error!void {
    if (!r.atFlowNodeEnd()) return error.Unsupported;
    return r.emitEmpty(r.s.mark);
}

fn flowMappingKey(r: *Reader, first: bool) Error!void {
    try r.skipFlowSpace();
    if (r.s.ch(0) != '}' and !first) {
        if (r.s.ch(0) != ',') return error.Unsupported;
        r.s.skip();
        try r.skipFlowSpace();
    }
    if (r.s.ch(0) == '}') return r.flowEnd(.mapping_end);
    if (r.atIndicator('?')) {
        r.s.skip();
        return r.flowExplicitKey('}', .flow_mapping_value);
    }
    if (r.atIndicator(':')) {
        // A value with no key: the key is empty.
        try r.emitEmpty(r.s.mark);
        r.state = .flow_mapping_value;
        return;
    }
    // A key, with its `:` or alone; in a flow mapping, of any length and
    // over lines.
    try r.push(.flow_mapping_value);
    try r.flowNode(true);
}

/// After a flow mapping's key: its `:` and value, or else an empty value.
/// Any `:` here is the value's: the key's node has seen to it.
fn flowMappingValue(r: *Reader) Error!void {
    try r.skipFlowSpace();
    r.state = .flow_mapping_key;
    if (r.s.ch(0) != ':') return r.emitEmptyBefore();
    r.s.skip();
    try r.skipFlowSpace();
    if (r.s.ch(0) == ',' or r.s.ch(0) == '}') return r.emitEmpty(r.s.mark);
    try r.push(.flow_mapping_key);
    try r.flowNode(false);
}

/// A node in a flow collection: a scalar or an alias, the properties
/// before it, or a collection opened. `key`: a flow mapping's key, or an
/// explicit one's, so the `:` of a value may follow it, as well as a `,`
/// or a closing bracket.
fn flowNode(r: *Reader, key: bool) Error!void {
    const start = r.s.mark;
    const props = try r.scanProps();
    if (props) |p| {
        try r.skipFlowSpace();
        if (r.atFlowNodeEnd() or key and r.atIndicator(':')) return r.emitEmptyWith(p);
    }
    switch (r.s.ch(0)) {
        '*' => return if (props == null) r.flowAlias(start, key) else error.Unsupported,
        '[', '{' => return r.flowStart(props),
        else => {},
    }
    const token = try r.flowScalar();
    try r.skipFlowSpace();
    if (!r.atFlowNodeEnd() and !(key and r.atFlowValue(token.data.scalar.style != .plain))) return error.Unsupported;
    try r.emitScalarWith(token, props);
    r.pop();
}

/// An alias in a flow collection, at `start`.
fn flowAlias(r: *Reader, start: Mark, key: bool) Error!void {
    const name = try r.scanName();
    const end = r.s.mark;
    try r.skipFlowSpace();
    if (!r.atFlowNodeEnd() and !(key and r.atIndicator(':'))) return error.Unsupported;
    try r.emit(start, end, .{ .alias = name });
    r.pop();
}

/// Whether the `:` of a value is at the cursor after a node: after a
/// JSON-like one (a quoted scalar or a flow collection, `json`) any `:`,
/// after another one with a blank, a line break or a flow indicator
/// after it, as the scanner's `after_json_node`.
fn atFlowValue(r: *const Reader, json: bool) bool {
    return r.s.ch(0) == ':' and (json or r.s.indicatorEnds());
}

/// Whether a `:` follows a flow collection in a flow collection, ending
/// before `at`, past blanks on its line, near enough a key begun at
/// `start` (`colonAfter`): after a collection any `:` is a value's.
fn flowValueAfter(r: *const Reader, at: usize, start: Mark) bool {
    return colonAfter(r.s.input, at, start) != null;
}

/// A plain or quoted scalar in a flow collection, of one line or more,
/// by the scanner's scanners, which hold its lines to the block's
/// indentation as for the parser.
fn flowScalar(r: *Reader) Error!Scanner.Token {
    const c = r.s.ch(0);
    if (c == '"' or c == '\'') {
        return r.s.scanQuotedScalar(if (c == '\'') .single_quoted else .double_quoted) catch |err| unsupported(err);
    }
    if (!r.atPlainStart()) return error.Unsupported;
    // Most end on their line, where there is nothing to fold: the
    // scanner's scanPlainScalar, its line read again, only for the rest.
    const start = r.s.mark;
    var end: Mark = undefined;
    r.s.scanPlainLine(&end) catch |err| return unsupported(err);
    if (!chars.isBreak(r.s.ch(0))) return .{ .start = start, .end = end, .data = .{ .scalar = .{ .value = r.s.input[start.offset..end.offset], .style = .plain } } };
    r.s.mark = start;
    return r.s.scanPlainScalar() catch |err| unsupported(err);
}

// Whitespace and comments

/// Moves past the blanks, comments and line breaks before the next token.
/// A tab is unsupported, and a comment must follow whitespace.
fn skipToToken(r: *Reader) Error!void {
    while (true) {
        // The scanner skips a byte order mark where a document may begin.
        if (r.s.mark.column == 0 and r.indent() < 0 and r.s.flow_level == 0 and std.mem.startsWith(u8, r.s.input[r.s.mark.offset..], "\xEF\xBB\xBF")) return error.Unsupported;
        try r.skipSeparation();
        const c = r.s.ch(0);
        if (r.atEnd()) return;
        if (c == '#') {
            r.s.skipComment() catch return error.Unsupported;
            continue;
        }
        if (!chars.isBreak(c)) return;
        r.s.skipBreak();
    }
}

/// Moves past spaces and tabs, as the scanner's skipSeparation: a tab
/// separates tokens anywhere, but where it would indent a block (at a
/// line's start, before the spaces reach past the block's column) only
/// an empty line, a comment or a flow collection may follow it.
fn skipSeparation(r: *Reader) Error!void {
    const line_start = r.s.mark.column == 0;
    r.tab_before = false;
    r.skipSpaces();
    if (r.s.ch(0) != '\t') return;
    const spaces = r.column();
    r.tab_before = true;
    r.skipBlanks();
    if (!line_start or r.s.flow_level > 0 or spaces > r.indent()) return;
    const c = r.s.ch(0);
    if (c == 0 or chars.isBreak(c) or c == '#' or c == '[' or c == '{') return;
    return error.Unsupported;
}

/// Moves past the blanks, comments and line breaks between flow tokens.
/// A line a token begins after a break must be indented past the block
/// around the collection, with spaces; a document marker, or the end,
/// is the parser's. Inlined to the blanks before a token on their line,
/// the most common case, with the rest in a call apart: inlined whole,
/// its registers were saved on every call.
inline fn skipFlowSpace(r: *Reader) Error!void {
    r.skipBlanks();
    const c = r.s.ch(0);
    if (c != '#' and !chars.isBreak(c) and !r.atEnd() and r.s.mark.column > 0) return;
    return r.skipFlowLines();
}

/// skipFlowSpace's comments, line breaks and checks after them.
noinline fn skipFlowLines(r: *Reader) Error!void {
    var new_line = false;
    while (true) {
        r.skipBlanks();
        if (r.atEnd()) return error.Unsupported;
        const c = r.s.ch(0);
        if (c == '#') {
            r.s.skipComment() catch return error.Unsupported;
        } else if (chars.isBreak(c)) {
            r.s.skipBreak();
            new_line = true;
        } else break;
    }
    if (r.s.atDocumentMarkerLine()) return error.Unsupported;
    if (new_line) {
        // The scanner's checkFlowLineIndent.
        const input = r.s.input;
        var i = r.s.line_start;
        while (i < input.len and input[i] == ' ') i += 1;
        if (@as(isize, @intCast(i - r.s.line_start)) <= r.indent()) return error.Unsupported;
    }
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
    parser.use_reader = false;
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
