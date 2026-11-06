//! The emitter: events to YAML text, the pipeline run backwards.
//!
//! Feed it the events of a stream in order with `emit`; it writes YAML
//! 1.2.2 to the writer. Collections are block or flow as their events
//! say, but an empty one is always `[]` or `{}`, and inside a flow
//! collection everything is flow. A scalar keeps the style its event asks
//! for when its text can be written that way, and is quoted when not:
//! plain becomes single-quoted, and single-quoted or a block scalar
//! double-quoted, which can write any text. An untagged plain scalar that
//! must be quoted keeps what a reader resolves it to by gaining its tag
//! (an empty one, null, written as an item of a flow sequence is
//! `!!null ''`). A mapping key that fits on a line is written `key:`,
//! any other `? key`.
//!
//! Reading back what it writes gives the same documents: the same nodes,
//! tags, values and anchors, if not always the same styles.
//!
//! Like libyaml's, it looks a few events ahead before writing one (to
//! see whether a collection is empty, or a key fits on a line), so the
//! text in an event must live until a few more have been emitted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Scanner = @import("Scanner.zig");
const schema = @import("schema.zig");

const Emitter = @This();

/// What the emitter takes (`Parser.Event`).
pub const Event = Parser.Event;
/// How a scalar asks to be written (`Scanner.ScalarStyle`).
pub const ScalarStyle = Parser.ScalarStyle;

/// How the emitter lays text out.
pub const Options = struct {
    /// Columns a level of block indentation takes, 2 to 8 (a block
    /// scalar's indentation indicator at the top is one more, and is a
    /// digit).
    indent: u8 = 2,
    /// Past this column, a plain or single-quoted scalar's line breaks at
    /// its next space, and a flow collection's at its next entry.
    width: usize = 80,
};

/// Emitting's errors: the writer's, memory, and two of its own.
pub const Error = std.Io.Writer.Error || Allocator.Error || error{
    /// An event came where the stream's grammar has no place for it.
    UnexpectedEvent,
    /// A scalar, anchor or tag is not valid UTF-8, which YAML cannot hold.
    InvalidUtf8,
};

const State = enum {
    stream_start,
    first_document_start,
    document_start,
    document_content,
    document_end,
    flow_sequence_first_item,
    flow_sequence_item,
    flow_mapping_first_key,
    flow_mapping_key,
    flow_mapping_simple_value,
    flow_mapping_value,
    block_sequence_first_item,
    block_sequence_item,
    block_mapping_first_key,
    block_mapping_key,
    block_mapping_simple_value,
    block_mapping_value,
    end,
};

/// How a node sits in what holds it.
const Context = struct {
    root: bool = false,
    sequence: bool = false,
    mapping: bool = false,
    simple_key: bool = false,
    /// An item of a flow sequence, where an empty plain scalar cannot be
    /// written as nothing.
    flow_item: bool = false,
};

gpa: Allocator,
writer: *std.Io.Writer,
options: Options,
state: State = .stream_start,
states: std.ArrayList(State) = .empty,
/// Events waiting for the ones after them, from `head`.
events: std.ArrayList(Event) = .empty,
head: usize = 0,
indent: isize = -1,
indents: std.ArrayList(isize) = .empty,
flow_level: usize = 0,
context: Context = .{},
/// The current document's %TAG directives.
tag_directives: []const Scanner.Token.TagDirective = &.{},
/// The column the next character goes in, counting characters.
column: usize = 0,
/// The last character written was whitespace.
whitespace: bool = true,
/// Only indentation is on the line so far.
indention: bool = true,
/// The last document ended without `...`, so one with directives must
/// write it first.
open_ended: bool = false,

/// An emitter writing to `writer`; `gpa` holds its stacks and the events
/// it waits on.
pub fn init(gpa: Allocator, writer: *std.Io.Writer, options: Options) Emitter {
    return .{ .gpa = gpa, .writer = writer, .options = options };
}

/// Frees the emitter's stacks.
pub fn deinit(e: *Emitter) void {
    e.states.deinit(e.gpa);
    e.events.deinit(e.gpa);
    e.indents.deinit(e.gpa);
    e.* = undefined;
}

/// Writes `event`, or holds it until the events after it show how.
pub fn emit(e: *Emitter, event: Event) Error!void {
    try e.events.append(e.gpa, event);
    while (!e.needMoreEvents()) {
        const next_event = e.events.items[e.head];
        try e.step(next_event);
        e.head += 1;
    }
    if (e.head == e.events.items.len) {
        e.events.clearRetainingCapacity();
        e.head = 0;
    }
}

/// Whether the event at the head waits for others: a document start for
/// one more, a sequence's start for two, a mapping's for three, unless
/// the node they begin ends sooner.
fn needMoreEvents(e: *const Emitter) bool {
    const queued = e.events.items[e.head..];
    if (queued.len == 0) return true;
    const wanted: usize = switch (queued[0].data) {
        .document_start => 1,
        .sequence_start => 2,
        .mapping_start => 3,
        else => return false,
    };
    if (queued.len > wanted) return false;
    var level: isize = 0;
    for (queued) |event| {
        switch (event.data) {
            .stream_start, .document_start, .sequence_start, .mapping_start => level += 1,
            .stream_end, .document_end, .sequence_end, .mapping_end => level -= 1,
            else => {},
        }
        if (level == 0) return false;
    }
    return true;
}

fn step(e: *Emitter, event: Event) Error!void {
    return switch (e.state) {
        .stream_start => e.emitStreamStart(event),
        .first_document_start => e.emitDocumentStart(event, true),
        .document_start => e.emitDocumentStart(event, false),
        .document_content => e.emitDocumentContent(event),
        .document_end => e.emitDocumentEnd(event),
        .flow_sequence_first_item => e.emitFlowSequenceItem(event, true),
        .flow_sequence_item => e.emitFlowSequenceItem(event, false),
        .flow_mapping_first_key => e.emitFlowMappingKey(event, true),
        .flow_mapping_key => e.emitFlowMappingKey(event, false),
        .flow_mapping_simple_value => e.emitFlowMappingValue(event, true),
        .flow_mapping_value => e.emitFlowMappingValue(event, false),
        .block_sequence_first_item => e.emitBlockSequenceItem(event, true),
        .block_sequence_item => e.emitBlockSequenceItem(event, false),
        .block_mapping_first_key => e.emitBlockMappingKey(event, true),
        .block_mapping_key => e.emitBlockMappingKey(event, false),
        .block_mapping_simple_value => e.emitBlockMappingValue(event, true),
        .block_mapping_value => e.emitBlockMappingValue(event, false),
        .end => error.UnexpectedEvent,
    };
}

fn push(e: *Emitter, state: State) Error!void {
    try e.states.append(e.gpa, state);
}

fn pop(e: *Emitter) void {
    e.state = e.states.pop() orelse .end;
}

/// The event after the head, if it has come.
fn peekAfter(e: *const Emitter, n: usize) ?Event {
    const i = e.head + n;
    return if (i < e.events.items.len) e.events.items[i] else null;
}

// Stream and documents

fn emitStreamStart(e: *Emitter, event: Event) Error!void {
    if (event.data != .stream_start) return error.UnexpectedEvent;
    if (e.options.indent < 2 or e.options.indent > 8) e.options.indent = 2;
    e.state = .first_document_start;
}

fn emitDocumentStart(e: *Emitter, event: Event, first: bool) Error!void {
    switch (event.data) {
        .stream_end => {
            try e.writer.flush();
            e.state = .end;
            return;
        },
        .document_start => {},
        else => return error.UnexpectedEvent,
    }
    const d = event.data.document_start;
    e.tag_directives = d.tag_directives;
    const has_directives = d.version != null or d.tag_directives.len > 0;
    if (has_directives and e.open_ended) try e.writeLine("...");
    if (d.version) |v| {
        try e.startLine();
        try e.writer.print("%YAML {d}.{d}", .{ v.major, v.minor });
        try e.writeBreak();
    }
    for (d.tag_directives) |t| try e.writeTagDirective(t);
    // An empty document with no marker would be no document at all.
    const empty = if (e.peekAfter(1)) |next| isEmptyPlain(next) else false;
    if (d.explicit or !first or has_directives or empty) {
        try e.writeIndent();
        try e.writeIndicator("---", true, false, false);
    }
    e.open_ended = false;
    e.state = .document_content;
}

fn emitDocumentContent(e: *Emitter, event: Event) Error!void {
    try e.push(.document_end);
    return e.emitNode(event, .{ .root = true });
}

fn emitDocumentEnd(e: *Emitter, event: Event) Error!void {
    if (event.data != .document_end) return error.UnexpectedEvent;
    try e.writeIndent();
    if (event.data.document_end.explicit) {
        try e.writeIndicator("...", true, false, false);
        try e.writeIndent();
    }
    e.open_ended = !event.data.document_end.explicit;
    try e.writer.flush();
    e.state = .document_start;
}

// Nodes

fn emitNode(e: *Emitter, event: Event, context: Context) Error!void {
    e.context = context;
    switch (event.data) {
        .alias => |name| return e.emitAlias(name),
        .scalar => |s| return e.emitScalar(s),
        .sequence_start => |c| return e.emitSequenceStart(c),
        .mapping_start => |c| return e.emitMappingStart(c),
        else => return error.UnexpectedEvent,
    }
}

fn emitAlias(e: *Emitter, name: []const u8) Error!void {
    try e.writeIndicator("*", true, false, false);
    try e.writeText(name);
    // `*a:` would name the anchor `a:`.
    if (e.context.simple_key) try e.writeByte(' ');
    e.pop();
}

fn emitSequenceStart(e: *Emitter, c: Event.Collection) Error!void {
    try e.writeProperties(c.properties);
    const flow = e.flow_level > 0 or c.flow or e.nextEnds(.sequence_end);
    e.state = if (flow) .flow_sequence_first_item else .block_sequence_first_item;
}

fn emitMappingStart(e: *Emitter, c: Event.Collection) Error!void {
    try e.writeProperties(c.properties);
    const flow = e.flow_level > 0 or c.flow or e.nextEnds(.mapping_end);
    e.state = if (flow) .flow_mapping_first_key else .block_mapping_first_key;
}

/// Whether the event after the head is an end of this kind: the
/// collection at the head is empty.
fn nextEnds(e: *const Emitter, comptime kind: std.meta.Tag(Event.Data)) bool {
    const next = e.peekAfter(1) orelse return false;
    return next.data == kind;
}

fn writeProperties(e: *Emitter, properties: Event.Properties) Error!void {
    if (properties.anchor) |anchor| {
        try e.writeIndicator("&", true, false, false);
        try e.writeText(anchor);
    }
    if (properties.tag) |tag| try e.writeTag(tag);
}

/// Whether the node at the head can be a key on one line, `key: value`:
/// an alias, a scalar of one short line, or an empty collection.
fn checkSimpleKey(e: *const Emitter) bool {
    const event = e.events.items[e.head];
    const length: usize = switch (event.data) {
        .alias => |name| name.len,
        .scalar => |s| if (std.mem.indexOfAny(u8, s.value, "\r\n") != null) return false else propertiesLength(s.properties) + s.value.len,
        .sequence_start => |c| if (!e.nextEnds(.sequence_end)) return false else propertiesLength(c.properties),
        .mapping_start => |c| if (!e.nextEnds(.mapping_end)) return false else propertiesLength(c.properties),
        else => return false,
    };
    return length <= 128;
}

fn propertiesLength(p: Event.Properties) usize {
    return (if (p.anchor) |a| a.len else 0) + (if (p.tag) |t| t.len else 0);
}

fn isEmptyPlain(event: Event) bool {
    if (event.data != .scalar) return false;
    const s = event.data.scalar;
    return s.value.len == 0 and s.style == .plain and s.properties.anchor == null and s.properties.tag == null;
}

// Collections

fn increaseIndent(e: *Emitter, flow: bool, indentless: bool) Error!void {
    try e.indents.append(e.gpa, e.indent);
    if (e.indent < 0) {
        e.indent = if (flow) e.options.indent else 0;
    } else if (!indentless) {
        e.indent += e.options.indent;
    }
}

fn popIndent(e: *Emitter) void {
    e.indent = e.indents.pop() orelse -1;
}

fn emitFlowSequenceItem(e: *Emitter, event: Event, first: bool) Error!void {
    if (first) {
        try e.writeIndicator("[", true, true, false);
        try e.increaseIndent(true, false);
        e.flow_level += 1;
    }
    if (event.data == .sequence_end) {
        e.flow_level -= 1;
        e.popIndent();
        try e.writeIndicator("]", false, false, false);
        return e.pop();
    }
    if (!first) try e.writeIndicator(",", false, false, false);
    if (e.column > e.options.width) try e.writeIndent();
    try e.push(.flow_sequence_item);
    return e.emitNode(event, .{ .sequence = true, .flow_item = true });
}

fn emitFlowMappingKey(e: *Emitter, event: Event, first: bool) Error!void {
    if (first) {
        try e.writeIndicator("{", true, true, false);
        try e.increaseIndent(true, false);
        e.flow_level += 1;
    }
    if (event.data == .mapping_end) {
        e.flow_level -= 1;
        e.popIndent();
        try e.writeIndicator("}", false, false, false);
        return e.pop();
    }
    if (!first) try e.writeIndicator(",", false, false, false);
    if (e.column > e.options.width) try e.writeIndent();
    if (e.checkSimpleKey()) {
        try e.push(.flow_mapping_simple_value);
        return e.emitNode(event, .{ .mapping = true, .simple_key = true });
    }
    try e.writeIndicator("?", true, false, false);
    try e.push(.flow_mapping_value);
    return e.emitNode(event, .{ .mapping = true });
}

fn emitFlowMappingValue(e: *Emitter, event: Event, simple: bool) Error!void {
    if (!simple and e.column > e.options.width) try e.writeIndent();
    try e.writeIndicator(":", !simple, false, false);
    try e.push(.flow_mapping_key);
    return e.emitNode(event, .{ .mapping = true });
}

fn emitBlockSequenceItem(e: *Emitter, event: Event, first: bool) Error!void {
    // A sequence that is a mapping's value may sit at the key's column.
    if (first) try e.increaseIndent(false, e.context.mapping and !e.indention);
    if (event.data == .sequence_end) {
        e.popIndent();
        return e.pop();
    }
    try e.writeIndent();
    try e.writeIndicator("-", true, false, true);
    try e.push(.block_sequence_item);
    return e.emitNode(event, .{ .sequence = true });
}

fn emitBlockMappingKey(e: *Emitter, event: Event, first: bool) Error!void {
    if (first) try e.increaseIndent(false, false);
    if (event.data == .mapping_end) {
        e.popIndent();
        return e.pop();
    }
    try e.writeIndent();
    if (e.checkSimpleKey()) {
        try e.push(.block_mapping_simple_value);
        return e.emitNode(event, .{ .mapping = true, .simple_key = true });
    }
    try e.writeIndicator("?", true, false, true);
    try e.push(.block_mapping_value);
    return e.emitNode(event, .{ .mapping = true });
}

fn emitBlockMappingValue(e: *Emitter, event: Event, simple: bool) Error!void {
    if (simple) {
        try e.writeIndicator(":", false, false, false);
    } else {
        try e.writeIndent();
        try e.writeIndicator(":", true, false, true);
    }
    try e.push(.block_mapping_key);
    return e.emitNode(event, .{ .mapping = true });
}

// Writing

fn writeByte(e: *Emitter, c: u8) Error!void {
    try e.writer.writeByte(c);
    if (c < 0x80 or c >= 0xC0) e.column += 1;
}

/// Writes UTF-8 text that holds no line break.
fn writeText(e: *Emitter, text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try e.writer.writeAll(text);
    e.column += std.unicode.utf8CountCodepoints(text) catch unreachable;
}

fn writeBreak(e: *Emitter) Error!void {
    try e.writer.writeByte('\n');
    e.column = 0;
}

/// Writes a line of its own, as a marker is.
fn writeLine(e: *Emitter, text: []const u8) Error!void {
    try e.startLine();
    try e.writeText(text);
    try e.writeBreak();
}

/// Ends the line, unless nothing is on it yet.
fn startLine(e: *Emitter) Error!void {
    if (e.column != 0) try e.writeBreak();
}

/// Writes `%TAG handle prefix` on a line of its own. The prefix is held
/// decoded, as the scanner gives it, so it is escaped again as a tag's
/// text is, and its first character too if it is a flow indicator, which
/// cannot begin one (YAML 1.2.2, 6.8.2.2).
fn writeTagDirective(e: *Emitter, directive: Scanner.Token.TagDirective) Error!void {
    try e.startLine();
    try e.writeText("%TAG ");
    try e.writeText(directive.handle);
    try e.writeByte(' ');
    const prefix = directive.prefix;
    if (prefix.len > 0 and isFlowIndicator(prefix[0])) {
        try e.writeEscapedByte(prefix[0]);
        try e.writeUri(prefix[1..], .uri);
    } else {
        try e.writeUri(prefix, .uri);
    }
    try e.writeBreak();
}

fn isFlowIndicator(c: u8) bool {
    return switch (c) {
        ',', '[', ']', '{', '}' => true,
        else => false,
    };
}

/// Starts a line at the current indentation, unless the line is at it.
fn writeIndent(e: *Emitter) Error!void {
    const indent: usize = @intCast(@max(e.indent, 0));
    if (!e.indention or e.column > indent or (e.column == indent and !e.whitespace)) try e.writeBreak();
    while (e.column < indent) try e.writeByte(' ');
    e.whitespace = true;
    e.indention = true;
}

fn writeIndicator(e: *Emitter, indicator: []const u8, need_whitespace: bool, is_whitespace: bool, is_indention: bool) Error!void {
    if (need_whitespace and !e.whitespace) try e.writeByte(' ');
    try e.writeText(indicator);
    e.whitespace = is_whitespace;
    e.indention = e.indention and is_indention;
}

// Scalars

fn emitScalar(e: *Emitter, s: Event.Scalar) Error!void {
    if (!std.unicode.utf8ValidateSlice(s.value)) return error.InvalidUtf8;
    const analysis = analyze(s.value);
    const style = e.chooseStyle(s, analysis);
    var properties = s.properties;
    // A reader resolves an untagged plain scalar by its text, and a
    // quoted one as a string: one that cannot stay plain keeps its tag.
    if (properties.tag == null and s.style == .plain and style != .plain) {
        const resolved = schema.resolvePlain(.core, s.value) orelse schema.tag.str;
        if (!std.mem.eql(u8, resolved, schema.tag.str)) properties.tag = resolved;
    }
    try e.writeProperties(properties);
    // `&a:` and `!!null:` would take the `:` into the name.
    const marked = properties.anchor != null or properties.tag != null;
    if (s.value.len == 0 and style == .plain and marked and e.context.simple_key) {
        try e.writeByte(' ');
        e.whitespace = true;
    }
    try e.increaseIndent(true, false);
    const parent = e.indents.items[e.indents.items.len - 1];
    const allow_breaks = !e.context.simple_key;
    switch (style) {
        .plain => try e.writePlain(s.value, allow_breaks),
        .single_quoted => try e.writeSingleQuoted(s.value, allow_breaks),
        .double_quoted => try e.writeDoubleQuoted(s.value),
        .literal => try e.writeLiteral(s.value, parent),
        .folded => try e.writeFolded(s.value, parent),
    }
    e.popIndent();
    e.pop();
}

/// The style a scalar is written in: the one its event asks for, or the
/// nearest that can write its text where it is.
fn chooseStyle(e: *const Emitter, s: Event.Scalar, a: Analysis) ScalarStyle {
    var style = s.style;
    if (style == .plain and !e.plainPossible(s, a)) style = .single_quoted;
    if (style == .single_quoted and !a.single_quoted) style = .double_quoted;
    const block = style == .literal or style == .folded;
    if (block and (!a.block or e.flow_level > 0 or e.context.simple_key)) style = .double_quoted;
    return style;
}

fn plainPossible(e: *const Emitter, s: Event.Scalar, a: Analysis) bool {
    if (s.value.len > 0) return if (e.flow_level > 0) a.flow_plain else a.block_plain;
    // Nothing, an empty plain scalar, cannot be a flow sequence's item
    // unless a property marks its place.
    const marked = s.properties.anchor != null or s.properties.tag != null;
    return !e.context.flow_item or marked;
}

/// Which styles can write a scalar's text so it reads back the same.
const Analysis = struct {
    flow_plain: bool = true,
    block_plain: bool = true,
    single_quoted: bool = true,
    /// Literal or folded.
    block: bool = true,
};

/// What `analyze` notes as it reads the text.
const Notes = struct {
    flow_indicators: bool = false,
    block_indicators: bool = false,
    /// A character that must be escaped: not one YAML allows in text, or
    /// a carriage return (read back as a line feed).
    special: bool = false,
    line_breaks: bool = false,
    leading_space: bool = false,
    leading_break: bool = false,
    trailing_space: bool = false,
    trailing_break: bool = false,
    /// A blank right after a line break, which folding would drop.
    break_space: bool = false,
    /// A blank right before a line break, which folding would drop.
    space_break: bool = false,
    previous_space: bool = false,
    previous_break: bool = false,
};

fn analyze(value: []const u8) Analysis {
    var n: Notes = .{};
    if (startsWithMarker(value)) {
        n.flow_indicators = true;
        n.block_indicators = true;
    }
    var preceded_by_whitespace = true;
    var i: usize = 0;
    while (i < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        const end = i + len;
        const followed_by_whitespace = end >= value.len or isBlankOrBreak(value[end]);
        noteIndicator(&n, value[i], i == 0, preceded_by_whitespace, followed_by_whitespace);
        if (value[i] == '\r' or !Scanner.isPrintable(value, i)) n.special = true;
        noteSpacing(&n, value[i], i == 0, end >= value.len);
        preceded_by_whitespace = isBlankOrBreak(value[i]);
        i = end;
    }
    return allowed(n);
}

/// Whether `value` begins as a document marker would.
fn startsWithMarker(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "---") and !std.mem.startsWith(u8, value, "...")) return false;
    return value.len == 3 or isBlankOrBreak(value[3]);
}

fn noteIndicator(n: *Notes, c: u8, first: bool, preceded_by_whitespace: bool, followed_by_whitespace: bool) void {
    if (first) return noteFirstIndicator(n, c, followed_by_whitespace);
    switch (c) {
        ',', '?', '[', ']', '{', '}' => n.flow_indicators = true,
        ':' => {
            n.flow_indicators = true;
            if (followed_by_whitespace) n.block_indicators = true;
        },
        '#' => if (preceded_by_whitespace) {
            n.flow_indicators = true;
            n.block_indicators = true;
        },
        else => {},
    }
}

fn noteFirstIndicator(n: *Notes, c: u8, followed_by_whitespace: bool) void {
    switch (c) {
        '#', ',', '[', ']', '{', '}', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => {
            n.flow_indicators = true;
            n.block_indicators = true;
        },
        '?', ':' => {
            n.flow_indicators = true;
            if (followed_by_whitespace) n.block_indicators = true;
        },
        '-' => if (followed_by_whitespace) {
            n.flow_indicators = true;
            n.block_indicators = true;
        },
        else => {},
    }
}

fn noteSpacing(n: *Notes, c: u8, first: bool, last: bool) void {
    const blank = c == ' ' or c == '\t';
    const line_break = c == '\n';
    if (blank) noteBlank(n, first, last);
    if (line_break) noteBreak(n, first, last);
    n.previous_space = blank;
    n.previous_break = line_break;
}

fn noteBlank(n: *Notes, first: bool, last: bool) void {
    if (first) n.leading_space = true;
    if (last) n.trailing_space = true;
    if (n.previous_break) n.break_space = true;
}

fn noteBreak(n: *Notes, first: bool, last: bool) void {
    n.line_breaks = true;
    if (first) n.leading_break = true;
    if (last) n.trailing_break = true;
    if (n.previous_space) n.space_break = true;
}

fn allowed(n: Notes) Analysis {
    var a: Analysis = .{};
    if (n.leading_space or n.leading_break or n.trailing_space or n.trailing_break or n.line_breaks) {
        a.flow_plain = false;
        a.block_plain = false;
    }
    if (n.trailing_space) a.block = false;
    if (n.break_space) {
        a.flow_plain = false;
        a.block_plain = false;
        a.single_quoted = false;
    }
    if (n.space_break or n.special) a = .{ .flow_plain = false, .block_plain = false, .single_quoted = false, .block = false };
    if (n.flow_indicators) a.flow_plain = false;
    if (n.block_indicators) a.block_plain = false;
    return a;
}

fn isBlankOrBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Writes the character starting at `value[i]` and returns its length.
fn writeCharacter(e: *Emitter, value: []const u8, i: usize) Error!usize {
    const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
    try e.writer.writeAll(value[i..][0..len]);
    e.column += 1;
    return len;
}

/// Whether a long line breaks at the space `value[i]`, which reads back
/// as the space: past the width, with text on both sides. A blank either
/// side would end one line or begin the next, where reading drops it (a
/// tab after a space, found by the emit fuzz target).
fn foldsAt(e: *const Emitter, value: []const u8, i: usize) bool {
    if (e.column <= e.options.width) return false;
    if (i == 0 or isBlank(value[i - 1])) return false;
    return i + 1 < value.len and !isBlank(value[i + 1]);
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn writePlain(e: *Emitter, value: []const u8, allow_breaks: bool) Error!void {
    if (!e.whitespace and (value.len > 0 or e.flow_level > 0)) try e.writeByte(' ');
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == ' ') {
            const fold = allow_breaks and e.foldsAt(value, i);
            if (fold) try e.writeIndent() else try e.writeByte(' ');
            i += 1;
        } else {
            i += try e.writeCharacter(value, i);
        }
    }
    e.whitespace = false;
    e.indention = false;
}

fn writeSingleQuoted(e: *Emitter, value: []const u8, allow_breaks: bool) Error!void {
    try e.writeIndicator("'", true, false, false);
    var breaks = false;
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == ' ') {
            const fold = allow_breaks and e.foldsAt(value, i);
            if (fold) try e.writeIndent() else try e.writeByte(' ');
            i += 1;
        } else if (c == '\n') {
            try e.writeQuotedBreak(breaks);
            i += 1;
        } else {
            i += try e.writeQuotedCharacter(value, i, breaks);
        }
        breaks = c == '\n';
    }
    if (breaks) try e.writeIndent();
    try e.writeIndicator("'", false, false, false);
    e.whitespace = false;
    e.indention = false;
}

/// Writes the character at `value[i]` of a single-quoted scalar, a quote
/// doubled, its line's indentation first if it begins one.
fn writeQuotedCharacter(e: *Emitter, value: []const u8, i: usize, after_break: bool) Error!usize {
    if (after_break) try e.writeIndent();
    if (value[i] == '\'') try e.writeText("'");
    const len = try e.writeCharacter(value, i);
    e.indention = false;
    return len;
}

/// Writes a line feed of a single-quoted scalar: one line break reads
/// back as a space, so the first of a run takes two.
fn writeQuotedBreak(e: *Emitter, after_break: bool) Error!void {
    if (!after_break) try e.writeBreak();
    try e.writeBreak();
    e.indention = true;
}

fn writeDoubleQuoted(e: *Emitter, value: []const u8) Error!void {
    try e.writeIndicator("\"", true, false, false);
    var i: usize = 0;
    while (i < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        const point = std.unicode.utf8Decode(value[i..][0..len]) catch unreachable;
        if (escapeOf(point)) |escape| {
            try e.writeText(escape);
        } else if (!Scanner.isPrintable(value, i)) {
            var buf: [10]u8 = undefined;
            try e.writeText(hexEscape(&buf, point));
        } else {
            _ = try e.writeCharacter(value, i);
        }
        i += len;
    }
    try e.writeIndicator("\"", false, false, false);
    e.whitespace = false;
    e.indention = false;
}

/// The one-letter escape a double-quoted scalar writes `point` as, if it
/// needs one.
fn escapeOf(point: u21) ?[]const u8 {
    return switch (point) {
        0 => "\\0",
        0x07 => "\\a",
        0x08 => "\\b",
        '\t' => "\\t",
        '\n' => "\\n",
        0x0B => "\\v",
        0x0C => "\\f",
        '\r' => "\\r",
        0x1B => "\\e",
        '"' => "\\\"",
        '\\' => "\\\\",
        0x85 => "\\N",
        0x2028 => "\\L",
        0x2029 => "\\P",
        else => null,
    };
}

fn hexEscape(buf: *[10]u8, point: u21) []const u8 {
    if (point <= 0xFF) return std.fmt.bufPrint(buf, "\\x{X:0>2}", .{point}) catch unreachable;
    if (point <= 0xFFFF) return std.fmt.bufPrint(buf, "\\u{X:0>4}", .{point}) catch unreachable;
    return std.fmt.bufPrint(buf, "\\U{X:0>8}", .{point}) catch unreachable;
}

/// Writes a block scalar's indicators after its `|` or `>`: an
/// indentation indicator when its first line begins with a blank or is
/// empty, as the reader cannot then find the indentation itself, counted
/// from `parent`, the block's indentation as the reader sees it; and a
/// chomping indicator for no final line break (`-`) or more than one
/// (`+`).
fn writeBlockHints(e: *Emitter, value: []const u8, parent: isize) Error!void {
    if (value.len > 0 and (value[0] == ' ' or value[0] == '\n')) {
        const hint: u8 = @intCast(e.indent - parent);
        try e.writeByte('0' + hint);
    }
    if (value.len == 0 or value[value.len - 1] != '\n') {
        try e.writeByte('-');
    } else if (value.len == 1 or value[value.len - 2] == '\n') {
        try e.writeByte('+');
    }
}

fn writeLiteral(e: *Emitter, value: []const u8, parent: isize) Error!void {
    try e.writeIndicator("|", true, false, false);
    try e.writeBlockHints(value, parent);
    try e.writeBreak();
    e.indention = true;
    e.whitespace = true;
    var breaks = true;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '\n') {
            try e.writeBreak();
            e.indention = true;
            breaks = true;
            i += 1;
        } else {
            if (breaks) try e.writeIndent();
            i += try e.writeCharacter(value, i);
            e.indention = false;
            breaks = false;
        }
    }
}

fn writeFolded(e: *Emitter, value: []const u8, parent: isize) Error!void {
    try e.writeIndicator(">", true, false, false);
    try e.writeBlockHints(value, parent);
    try e.writeBreak();
    e.indention = true;
    e.whitespace = true;
    var breaks = true;
    var leading_spaces = true;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '\n') {
            if (!breaks and !leading_spaces and needsFoldBreak(value, i)) try e.writeBreak();
            try e.writeBreak();
            e.indention = true;
            breaks = true;
            i += 1;
            continue;
        }
        if (breaks) {
            try e.writeIndent();
            leading_spaces = value[i] == ' ' or value[i] == '\t';
        }
        // A more-indented line is not folded when read: it is not broken.
        const fold = !breaks and !leading_spaces and value[i] == ' ' and e.foldsAt(value, i);
        if (fold) {
            try e.writeIndent();
            i += 1;
        } else {
            i += try e.writeCharacter(value, i);
        }
        e.indention = false;
        breaks = false;
    }
}

/// Whether the line breaks at `value[i]` need one more when written
/// folded: folding reads a single break between two lines of text as a
/// space, so a line feed there takes two.
fn needsFoldBreak(value: []const u8, i: usize) bool {
    var k = i;
    while (k < value.len and value[k] == '\n') k += 1;
    return k < value.len and value[k] != ' ' and value[k] != '\t';
}

// Tags

/// Writes a tag: `!` as itself, one under a handle's prefix as the handle
/// and the rest, any other verbatim, `!<...>`.
fn writeTag(e: *Emitter, tag: []const u8) Error!void {
    if (std.mem.eql(u8, tag, "!")) return e.writeIndicator("!", true, false, false);
    if (e.shorthand(tag)) |s| {
        try e.writeIndicator(s.handle, true, false, false);
        return e.writeUri(tag[s.prefix_len..], .tag_suffix);
    }
    try e.writeIndicator("!<", true, false, false);
    try e.writeUri(tag, .uri);
    try e.writeIndicator(">", false, false, false);
}

const Shorthand = struct { handle: []const u8, prefix_len: usize };

/// The handle whose prefix starts `tag` the longest way, from the
/// document's %TAG directives and the defaults they do not replace.
fn shorthand(e: *const Emitter, tag: []const u8) ?Shorthand {
    var best: ?Shorthand = null;
    for (e.tag_directives) |d| consider(&best, tag, d.handle, d.prefix);
    if (!e.redefines("!!")) consider(&best, tag, "!!", Parser.core_prefix);
    if (!e.redefines("!")) consider(&best, tag, "!", "!");
    return best;
}

fn consider(best: *?Shorthand, tag: []const u8, handle: []const u8, prefix: []const u8) void {
    if (tag.len <= prefix.len or !std.mem.startsWith(u8, tag, prefix)) return;
    if (best.* == null or prefix.len > best.*.?.prefix_len) best.* = .{ .handle = handle, .prefix_len = prefix.len };
}

fn redefines(e: *const Emitter, handle: []const u8) bool {
    for (e.tag_directives) |d| {
        if (std.mem.eql(u8, d.handle, handle)) return true;
    }
    return false;
}

const UriKind = enum { tag_suffix, uri };

/// Writes a tag's text, `%`-escaping each byte a tag cannot hold there.
fn writeUri(e: *Emitter, text: []const u8, kind: UriKind) Error!void {
    for (text) |c| {
        const plain_ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-#;/?:@&=+$_.~*'()", c) != null;
        const suffix_only_bad = c == '!' or c == ',' or c == '[' or c == ']' or c == '{' or c == '}';
        const ok = plain_ok or (kind == .uri and suffix_only_bad);
        if (ok) try e.writeByte(c) else try e.writeEscapedByte(c);
    }
}

/// Writes `c` as a URI's `%` escape: two hex digits.
fn writeEscapedByte(e: *Emitter, c: u8) Error!void {
    try e.writer.print("%{X:0>2}", .{c});
    e.column += 3;
}
