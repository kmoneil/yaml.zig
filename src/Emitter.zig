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
//!
//! Not threadsafe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Scanner = @import("Scanner.zig");
const chars = @import("chars.zig");
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

/// Emitting's errors: the writer's, memory, and three of its own.
pub const Error = std.Io.Writer.Error || Allocator.Error || error{
    /// An event came where the stream's grammar has no place for it.
    UnexpectedEvent,
    /// A scalar, anchor or tag is not valid UTF-8, which YAML cannot hold.
    InvalidUtf8,
    /// An anchor, alias, tag or %TAG directive YAML cannot write: an
    /// empty one, or an anchor with a character its name cannot hold.
    InvalidName,
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
/// The scalar being written is ASCII, so its columns are its bytes.
text_ascii: bool = false,

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

/// Writes `event`, or holds it until the events after it show how. An
/// event naming what YAML cannot write is refused before it is held.
pub fn emit(e: *Emitter, event: Event) Error!void {
    try checkNames(event);
    // An event that waits for none after it, with none waiting before
    // it, as most scalars come, is written as it comes: not copied into
    // the queue and looked past (t75).
    if (e.head == e.events.items.len and !waitsForMore(event)) return e.step(event);
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

/// Refuses an event whose names YAML cannot write, which would read back
/// as other names or not at all: an anchor or alias that is empty or
/// holds a blank, a line break, a flow indicator or a character YAML
/// does not allow (ns-anchor-char, YAML 1.2.2, 6.9.2); an empty tag; a
/// %TAG handle that is not `!`, `!!` or `!word!`, or an empty prefix
/// (6.8.2.2).
fn checkNames(event: Event) Error!void {
    switch (event.data) {
        .alias => |name| try checkAnchor(name),
        .scalar => |s| try checkProperties(s.properties),
        .sequence_start, .mapping_start => |c| try checkProperties(c.properties),
        .document_start => |d| for (d.tag_directives) |t| {
            if (!isTagHandle(t.handle) or t.prefix.len == 0) return error.InvalidName;
        },
        else => {},
    }
}

fn checkProperties(p: Event.Properties) Error!void {
    if (p.anchor) |anchor| try checkAnchor(anchor);
    if (p.tag) |tag| if (tag.len == 0) return error.InvalidName;
}

fn checkAnchor(name: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    if (name.len == 0) return error.InvalidName;
    var i: usize = 0;
    while (i < name.len) : (i += std.unicode.utf8ByteSequenceLength(name[i]) catch 1) {
        if (isBlankOrBreak(name[i]) or isFlowIndicator(name[i]) or !chars.isPrintable(name, i)) return error.InvalidName;
    }
}

/// `!`, `!!`, or `!`, a word of letters, digits and `-`, and `!`.
fn isTagHandle(handle: []const u8) bool {
    if (handle.len == 0 or handle[0] != '!' or handle[handle.len - 1] != '!') return false;
    if (handle.len <= 2) return true;
    for (handle[1 .. handle.len - 1]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// Whether the event at the head waits for others: a document start for
/// one more, a sequence's start for two, a mapping's for three, unless
/// the node they begin ends sooner.
fn needMoreEvents(e: *const Emitter) bool {
    const queued = e.events.items[e.head..];
    if (queued.len == 0) return true;
    const wanted = eventsWanted(queued[0]);
    if (wanted == 0) return false;
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

/// How many events after `event` it waits for, at most: a document
/// start to see whether its document is empty, a collection's start
/// whether it is, or a key's whether it fits on a line.
fn eventsWanted(event: Event) usize {
    return switch (event.data) {
        .document_start => 1,
        .sequence_start => 2,
        .mapping_start => 3,
        else => 0,
    };
}

fn waitsForMore(event: Event) bool {
    return eventsWanted(event) > 0;
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
        try e.writeIndicator("---", .{ .space_before = true });
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
        try e.writeIndicator("...", .{ .space_before = true });
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
    try e.writeIndicator("*", .{ .space_before = true });
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
        try e.writeIndicator("&", .{ .space_before = true });
        try e.writeText(anchor);
    }
    if (properties.tag) |tag| try e.writeTag(tag);
}

/// Whether the node at the head can be a key on one line, `key: value`:
/// an alias, a scalar of one short line, or an empty collection.
/// (`event`, the key, is the queue's head when it is a collection's
/// start, which waits there for the events after it.)
fn checkSimpleKey(e: *const Emitter, event: Event) bool {
    const length: usize = switch (event.data) {
        .alias => |name| name.len,
        .scalar => |s| if (chars.findAnyOf(s.value, 0, "\r\n") < s.value.len) return false else propertiesLength(s.properties) + s.value.len,
        .sequence_start => |c| if (!e.nextEnds(.sequence_end)) return false else propertiesLength(c.properties),
        .mapping_start => |c| if (!e.nextEnds(.mapping_end)) return false else propertiesLength(c.properties),
        else => return false,
    };
    // libyaml's bound, under YAML's 1,024 for an implicit key (7.4.2):
    // past it a key reads better on a line of its own after `?`.
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
        try e.writeIndicator("[", .{ .space_before = true, .is_whitespace = true });
        try e.increaseIndent(true, false);
        e.flow_level += 1;
    }
    if (event.data == .sequence_end) {
        e.flow_level -= 1;
        e.popIndent();
        try e.writeIndicator("]", .{});
        return e.pop();
    }
    if (!first) try e.writeIndicator(",", .{});
    if (e.column > e.options.width) try e.writeIndent();
    try e.push(.flow_sequence_item);
    return e.emitNode(event, .{ .sequence = true, .flow_item = true });
}

fn emitFlowMappingKey(e: *Emitter, event: Event, first: bool) Error!void {
    if (first) {
        try e.writeIndicator("{", .{ .space_before = true, .is_whitespace = true });
        try e.increaseIndent(true, false);
        e.flow_level += 1;
    }
    if (event.data == .mapping_end) {
        e.flow_level -= 1;
        e.popIndent();
        try e.writeIndicator("}", .{});
        return e.pop();
    }
    if (!first) try e.writeIndicator(",", .{});
    if (e.column > e.options.width) try e.writeIndent();
    if (e.checkSimpleKey(event)) {
        try e.push(.flow_mapping_simple_value);
        return e.emitNode(event, .{ .mapping = true, .simple_key = true });
    }
    try e.writeIndicator("?", .{ .space_before = true });
    try e.push(.flow_mapping_value);
    return e.emitNode(event, .{ .mapping = true });
}

fn emitFlowMappingValue(e: *Emitter, event: Event, simple: bool) Error!void {
    if (!simple and e.column > e.options.width) try e.writeIndent();
    try e.writeIndicator(":", .{ .space_before = !simple });
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
    try e.writeIndicator("-", .{ .space_before = true, .is_indention = true });
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
    if (e.checkSimpleKey(event)) {
        try e.push(.block_mapping_simple_value);
        return e.emitNode(event, .{ .mapping = true, .simple_key = true });
    }
    try e.writeIndicator("?", .{ .space_before = true, .is_indention = true });
    try e.push(.block_mapping_value);
    return e.emitNode(event, .{ .mapping = true });
}

fn emitBlockMappingValue(e: *Emitter, event: Event, simple: bool) Error!void {
    if (simple) {
        try e.writeIndicator(":", .{});
    } else {
        try e.writeIndent();
        try e.writeIndicator(":", .{ .space_before = true, .is_indention = true });
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
    // Validated just above.
    e.column += std.unicode.utf8CountCodepoints(text) catch unreachable;
}

/// Writes `bytes` into the writer's buffer when they fit, as nearly all
/// do, with no call. Through the writer, each write of a few bytes (an
/// indicator, a word) was a call and a memcpy call (t75).
inline fn put(e: *Emitter, bytes: []const u8) Error!void {
    const free = e.writer.unusedCapacitySlice();
    if (bytes.len > free.len) return e.putPast(bytes, null);
    @memcpy(free[0..bytes.len], bytes);
    e.writer.advance(bytes.len);
}

/// Writes `count` spaces, as `put` writes.
fn putSpaces(e: *Emitter, count: usize) Error!void {
    const free = e.writer.unusedCapacitySlice();
    if (count > free.len) return e.putPast(&.{}, count);
    @memset(free[0..count], ' ');
    e.writer.advance(count);
}

/// Writes `bytes`, or `spaces` spaces, past the buffer's end: the buffer
/// filled, then a byte through the writer, which drains it, and again.
/// A writer that grows its buffer for room (Io.Writer.Allocating) grows
/// it the least, as it did when the emitter wrote a byte at a time;
/// asked for room for the whole rest, it grew by that more each time,
/// and held 2 to 5% more at the end (t75).
noinline fn putPast(e: *Emitter, bytes: []const u8, spaces: ?usize) Error!void {
    var left = spaces orelse bytes.len;
    while (left > 0) {
        const free = e.writer.unusedCapacitySlice();
        const n = @min(left, free.len);
        const done = (spaces orelse bytes.len) - left;
        if (spaces == null) @memcpy(free[0..n], bytes[done..][0..n]) else @memset(free[0..n], ' ');
        e.writer.advance(n);
        left -= n;
        if (left == 0) return;
        try e.writer.writeByte(if (spaces == null) bytes[done + n] else ' ');
        left -= 1;
    }
}

/// Writes ASCII with no line break, as every indicator is.
fn writeAscii(e: *Emitter, text: []const u8) Error!void {
    try e.put(text);
    e.column += text.len;
}

/// Writes a run of a scalar's text with no line break in one write, its
/// UTF-8 checked already. A character at a time, each a write and a
/// memcpy call, was about a fifth of stringify's time (t75).
fn writeRun(e: *Emitter, run: []const u8) Error!void {
    try e.put(run);
    e.column += if (e.text_ascii) run.len else chars.pointCount(run);
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

const isBlank = chars.isBlank;
const isBlankOrBreak = chars.isBlankOrBreak;
const isFlowIndicator = chars.isFlowIndicator;

/// Starts a line at the current indentation, unless the line is at it.
fn writeIndent(e: *Emitter) Error!void {
    const indent: usize = @intCast(@max(e.indent, 0));
    if (!e.indention or e.column > indent or (e.column == indent and !e.whitespace)) try e.writeBreak();
    if (e.column < indent) {
        try e.putSpaces(indent - e.column);
        e.column = indent;
    }
    e.whitespace = true;
    e.indention = true;
}

/// How an indicator sits in its line.
const Spacing = struct {
    /// A space goes before it, unless whitespace is there already.
    space_before: bool = false,
    /// It counts as whitespace for what comes after it, as `[` and `{` do.
    is_whitespace: bool = false,
    /// It counts as indentation, as a block's `-`, `?` and `:` do.
    is_indention: bool = false,
};

/// Writes an indicator: ASCII, as each is, a tag's handle included
/// (checkNames holds a %TAG handle to `!`, letters, digits and `-`).
fn writeIndicator(e: *Emitter, indicator: []const u8, spacing: Spacing) Error!void {
    if (spacing.space_before and !e.whitespace) try e.writeByte(' ');
    try e.writeAscii(indicator);
    e.whitespace = spacing.is_whitespace;
    e.indention = e.indention and spacing.is_indention;
}

// Scalars

fn emitScalar(e: *Emitter, s: Event.Scalar) Error!void {
    const analysis = try analyze(s.value);
    e.text_ascii = analysis.ascii;
    const style = e.chooseStyle(s, analysis);
    var properties = s.properties;
    // A reader resolves an untagged plain scalar by its text, and a
    // quoted one as a string: one that cannot stay plain keeps its tag.
    if (properties.tag == null and s.style == .plain and style != .plain) {
        const resolved = schema.resolvePlain(.core, s.value) orelse schema.tag.str;
        if (resolved.ptr != schema.tag.str.ptr) properties.tag = resolved;
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
    /// Not a style: the text is ASCII.
    ascii: bool = true,
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
    non_ascii: bool = false,
};

/// Which styles can write `value`, refusing text that is not UTF-8.
fn analyze(value: []const u8) Error!Analysis {
    if (isQuiet(value)) return .{};
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    return analyzeLoud(value);
}

/// Whether `value` is text in which `analyzeEach` notes nothing, so that
/// any style can write it: its first byte `quiet_first`, its last no
/// space, every other `quiet_inside`. Most scalars are such words and
/// numbers, read here 16 bytes at a time past the first, with no notes
/// taken and no UTF-8 to check: it is ASCII (t75).
fn isQuiet(value: []const u8) bool {
    if (value.len == 0) return true;
    if (!quiet_first[value[0]] or value[value.len - 1] == ' ') return false;
    var i: usize = 1;
    while (i + 16 <= value.len) : (i += 16) {
        const block: chars.Block = value[i..][0..16].*;
        if (@reduce(.Or, isLoudBlock(block))) return false;
    }
    while (i < value.len) : (i += 1) {
        if (!quiet_inside[value[i]]) return false;
    }
    return true;
}

/// `quiet_inside`'s opposite, 16 bytes at once: `[` and `{`, `]` and
/// `}` each found in one compare, their bytes but the one bit apart.
fn isLoudBlock(block: chars.Block) @Vector(16, bool) {
    const V = chars.Block;
    const folded = block | @as(V, @splat(0x20));
    return (block < @as(V, @splat(' '))) | (block > @as(V, @splat('~'))) |
        (block == @as(V, @splat(','))) | (block == @as(V, @splat('?'))) |
        (block == @as(V, @splat(':'))) | (block == @as(V, @splat('#'))) |
        (folded == @as(V, @splat('{'))) | (folded == @as(V, @splat('}')));
}

/// The bytes that change nothing `analyzeEach` notes inside a scalar's
/// text: printable ASCII and the space, but the flow indicators, `?`,
/// `:` and `#`, which make an indicator or a comment where they sit. A
/// space inside is noted only beside a break, which is not here.
const quiet_inside: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for (' '..'~' + 1) |c| t[c] = true;
    for (",?[]{}:#") |c| t[c] = false;
    break :blk t;
};

/// The same, for a scalar's first byte: no blank, none of the
/// indicators a plain scalar cannot begin with, and no `-` or `.`, which
/// begin a document marker.
const quiet_first: [256]bool = blk: {
    var t = quiet_inside;
    for (" &*!|>'\"%@`-.") |c| t[c] = false;
    break :blk t;
};

/// Notes `value` a character at a time, as libyaml's analysis does.
/// What `analyze` is held to: every character noted.
fn analyzeEach(value: []const u8) Analysis {
    var n: Notes = .{};
    noteMarker(&n, value);
    var preceded_by_whitespace = true;
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        i = noteCharacter(&n, value, i, preceded_by_whitespace);
        preceded_by_whitespace = isBlankOrBreak(c);
    }
    return allowed(n);
}

/// What `analyzeEach` gives, valid UTF-8 `value` read a character at a
/// time only at the bytes `quiet_inside` leaves out, found 16 at once,
/// and at its first character. A space among the bytes passed counts
/// only beside a break, noted at the break, or last (t75).
fn analyzeLoud(value: []const u8) Analysis {
    if (value.len == 0) return .{};
    var n: Notes = .{};
    noteMarker(&n, value);
    var i = noteCharacter(&n, value, 0, true);
    noteSpaceAfter(&n, value, 0, i);
    while (true) {
        i = chars.findOutsideAscii(value, i, ",?[]{}:#");
        if (i >= value.len) break;
        i = noteInside(&n, value, i);
    }
    // A last space after the first character.
    if (value.len > 1 and value[value.len - 1] == ' ') n.trailing_space = true;
    return allowed(n);
}

/// Notes the character at `value[i]`, past the first, the search having
/// passed the ones before it: what they leave noted is read from the
/// byte before, and a space after a break from the byte after.
fn noteInside(n: *Notes, value: []const u8, i: usize) usize {
    const before = value[i - 1];
    n.previous_space = isBlank(before);
    n.previous_break = before == '\n';
    const end = noteCharacter(n, value, i, isBlankOrBreak(before));
    noteSpaceAfter(n, value, i, end);
    return end;
}

/// Notes a space after the character at `value[i]`, ending at `end`, if
/// it is a break: the search passes the space.
fn noteSpaceAfter(n: *Notes, value: []const u8, i: usize, end: usize) void {
    if (value[i] == '\n' and end < value.len and value[end] == ' ') n.break_space = true;
}

fn noteMarker(n: *Notes, value: []const u8) void {
    if (!startsWithMarker(value)) return;
    n.flow_indicators = true;
    n.block_indicators = true;
}

/// Notes the character at `value[i]`, as libyaml's analysis does, and
/// returns where the next begins.
fn noteCharacter(n: *Notes, value: []const u8, i: usize, preceded_by_whitespace: bool) usize {
    const c = value[i];
    const end = i + (std.unicode.utf8ByteSequenceLength(c) catch 1);
    const followed_by_whitespace = end >= value.len or isBlankOrBreak(value[end]);
    noteIndicator(n, c, i == 0, preceded_by_whitespace, followed_by_whitespace);
    if (c == '\r' or !chars.isPrintable(value, i)) n.special = true;
    if (c >= 0x80) n.non_ascii = true;
    noteSpacing(n, c, i == 0, end >= value.len);
    return end;
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
    a.ascii = !n.non_ascii;
    return a;
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

fn writePlain(e: *Emitter, value: []const u8, allow_breaks: bool) Error!void {
    if (!e.whitespace and (value.len > 0 or e.flow_level > 0)) try e.writeByte(' ');
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == ' ') {
            const fold = allow_breaks and e.foldsAt(value, i);
            if (fold) try e.writeIndent() else try e.writeByte(' ');
            i += 1;
        } else {
            // A space is the only place a plain scalar's line breaks.
            const end = std.mem.findScalarPos(u8, value, i, ' ') orelse value.len;
            try e.writeRun(value[i..end]);
            i = end;
            // No indicator comes before a plain scalar to end the
            // indentation, so its first character does: else folding at
            // a space would take the line for indentation and pad it to
            // the indent, not break it (t55). libyaml's write_plain does
            // the same.
            e.indention = false;
        }
    }
    e.whitespace = false;
    e.indention = false;
}

fn writeSingleQuoted(e: *Emitter, value: []const u8, allow_breaks: bool) Error!void {
    try e.writeIndicator("'", .{ .space_before = true });
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
            if (breaks) try e.writeIndent();
            i = try e.writeSingleQuotedText(value, i);
        }
        breaks = c == '\n';
    }
    if (breaks) try e.writeIndent();
    try e.writeIndicator("'", .{});
    e.whitespace = false;
    e.indention = false;
}

/// Writes the text of a single-quoted scalar from `value[i]`, which is
/// no space or break, and returns where it stopped: a quote doubled, any
/// other run up to a space, a break or a quote in one write.
fn writeSingleQuotedText(e: *Emitter, value: []const u8, i: usize) Error!usize {
    e.indention = false;
    if (value[i] == '\'') {
        try e.writeAscii("''");
        return i + 1;
    }
    const end = chars.findAnyOf(value, i, " \n'");
    try e.writeRun(value[i..end]);
    return end;
}

/// Writes a line feed of a single-quoted scalar: one line break reads
/// back as a space, so the first of a run takes two.
fn writeQuotedBreak(e: *Emitter, after_break: bool) Error!void {
    if (!after_break) try e.writeBreak();
    try e.writeBreak();
    e.indention = true;
}

fn writeDoubleQuoted(e: *Emitter, value: []const u8) Error!void {
    try e.writeIndicator("\"", .{ .space_before = true });
    var i: usize = 0;
    while (i < value.len) {
        // A run of printable ASCII but `"` and `\` is written as it is.
        const end = chars.findOutsideAscii(value, i, "\"\\");
        if (end > i) {
            try e.writeAscii(value[i..end]);
            i = end;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        // emitScalar validated the value as UTF-8.
        const point = std.unicode.utf8Decode(value[i..][0..len]) catch unreachable;
        if (escapeOf(point)) |escape| {
            try e.writeAscii(escape);
        } else if (!chars.isPrintable(value, i)) {
            var buf: [10]u8 = undefined;
            try e.writeAscii(hexEscape(&buf, point));
        } else {
            _ = try e.writeCharacter(value, i);
        }
        i += len;
    }
    try e.writeIndicator("\"", .{});
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

/// `\x`, `\u` or `\U` and the hex digits of `point`; the longest, `\U`
/// and eight, fills `buf`.
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
    try e.writeIndicator("|", .{ .space_before = true });
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
            // The line's text, in one write.
            const end = std.mem.findScalarPos(u8, value, i, '\n') orelse value.len;
            try e.writeRun(value[i..end]);
            i = end;
            e.indention = false;
            breaks = false;
        }
    }
}

fn writeFolded(e: *Emitter, value: []const u8, parent: isize) Error!void {
    try e.writeIndicator(">", .{ .space_before = true });
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
            leading_spaces = isBlank(value[i]);
        }
        // A more-indented line is not folded when read: it is not broken.
        i = try e.writeFoldedText(value, i, !breaks and !leading_spaces);
        e.indention = false;
        breaks = false;
    }
}

/// Writes the text of a folded scalar from `value[i]`, which is no
/// break, and returns where it stopped: a space, where the line breaks
/// past the width if it `may_fold`, or a run up to a space or a break in
/// one write.
fn writeFoldedText(e: *Emitter, value: []const u8, i: usize, may_fold: bool) Error!usize {
    if (value[i] == ' ') {
        if (may_fold and e.foldsAt(value, i)) try e.writeIndent() else try e.writeByte(' ');
        return i + 1;
    }
    const end = chars.findAnyOf(value, i, " \n");
    try e.writeRun(value[i..end]);
    return end;
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
    if (std.mem.eql(u8, tag, "!")) return e.writeIndicator("!", .{ .space_before = true });
    if (e.shorthand(tag)) |s| {
        try e.writeIndicator(s.handle, .{ .space_before = true });
        return e.writeUri(tag[s.prefix_len..], .tag_suffix);
    }
    try e.writeIndicator("!<", .{ .space_before = true });
    try e.writeUri(tag, .uri);
    try e.writeIndicator(">", .{});
}

const Shorthand = struct { handle: []const u8, prefix_len: usize };

/// The handle whose prefix starts `tag` the longest way, from the
/// document's %TAG directives and the defaults they do not replace.
fn shorthand(e: *const Emitter, tag: []const u8) ?Shorthand {
    var best: ?Shorthand = null;
    for (e.tag_directives) |d| consider(&best, tag, d.handle, d.prefix);
    if (!e.redefines("!!")) consider(&best, tag, "!!", schema.core_prefix);
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
        const plain_ok = std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "-#;/?:@&=+$_.~*'()", c) != null;
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

/// Holds `analyze`'s two fast paths to `analyzeEach` for `text`: what
/// `isQuiet` passes is UTF-8 in which every style is open, and
/// `analyzeLoud` notes what it does.
fn expectAnalyzedAlike(text: []const u8) !void {
    errdefer std.debug.print("text: {any}\n", .{text});
    if (!std.unicode.utf8ValidateSlice(text)) return std.testing.expect(!isQuiet(text));
    const each = analyzeEach(text);
    if (isQuiet(text)) try std.testing.expectEqual(Analysis{}, each);
    try std.testing.expectEqual(each, analyzeLoud(text));
}

test "analyze: its fast paths note what analyzeEach does" {
    // Every text of one and two bytes.
    var buf: [48]u8 = undefined;
    for (0..256) |a| {
        buf[0] = @intCast(a);
        try expectAnalyzedAlike(buf[0..1]);
        for (0..256) |b| {
            buf[1] = @intCast(b);
            try expectAnalyzedAlike(buf[0..2]);
        }
    }
    // Every text of three of the bytes that turn the notes, and some
    // that do not.
    const turns = " \t\n\r-.:#,?[]{}!&*|>'\"%@`~a0\x00\x7F\xC3\xA9";
    for (turns) |a| for (turns) |b| for (turns) |c| {
        try expectAnalyzedAlike(&.{ a, b, c });
    };
    // Longer ones, past the 16 bytes a block reads: mostly letters, with
    // those bytes and whole characters past ASCII among them.
    var prng: std.Random.DefaultPrng = .init(0x75);
    const r = prng.random();
    const wide = [_][]const u8{ "é", "€", "😀", "\u{85}", "\u{2028}", "\u{FEFF}", "\u{9F}" };
    var quiet: usize = 0;
    for (0..300_000) |_| {
        const len = r.uintLessThan(usize, buf.len - 4);
        var i: usize = 0;
        while (i < len) {
            switch (r.uintLessThan(u8, 24)) {
                0 => {
                    const w = wide[r.uintLessThan(usize, wide.len)];
                    @memcpy(buf[i..][0..w.len], w);
                    i += w.len;
                },
                1, 2 => {
                    buf[i] = turns[r.uintLessThan(usize, turns.len - 2)];
                    i += 1;
                },
                3, 4 => {
                    buf[i] = ' ';
                    i += 1;
                },
                else => {
                    buf[i] = 'a' + r.uintLessThan(u8, 26);
                    i += 1;
                },
            }
        }
        const text = buf[0..i];
        if (isQuiet(text)) quiet += 1;
        try expectAnalyzedAlike(text);
    }
    try std.testing.expect(quiet > 10_000);
}
