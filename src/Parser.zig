//! The parser: tokens to events, the second stage of YAML 1.2.2's
//! pipeline. It pulls tokens from a `Scanner` and gives events with
//! `next`: a stream, its documents, and in each the nodes, a collection
//! as its start, its entries and its end.
//!
//! A state machine with a stack, as libyaml's, held to YAML 1.2.2 where
//! the two differ: a key may be empty (`: v`), a bare document may
//! follow `...` and a stream may begin with one, directives need a
//! `...` before them unless the stream has just begun, and nothing may
//! follow `...` on its line. (No block collection may begin on the `---`
//! line either: the scanner sees to that, as no simple key may begin
//! there.)
//!
//! A tag is resolved here against its document's %TAG directives (`!!`
//! is `tag:yaml.org,2002:`, `!` is `!`), so an event carries the whole
//! tag. Event text lives as long as the parser.
//!
//! Its events come first from the reader (Reader.zig), which reads the
//! YAML most documents are in one pass with no tokens, at twice the
//! state machine's speed (t76). Where the reader stops (an error, or a
//! form it leaves to the state machine) the state machine reads the
//! stream again from its start and goes on past the events the reader
//! gave: they are its own, marks and all, which the suite's `reader`
//! check and the reader fuzz target hold the reader to. So every error,
//! and its diagnostic, is the state machine's.
//!
//! Not threadsafe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("Scanner.zig");
const Reader = @import("Reader.zig");
const schema = @import("schema.zig");

const Parser = @This();

/// A place in the input (`Scanner.Mark`).
pub const Mark = Scanner.Mark;
/// What the scanner gives (`Scanner.Token`).
pub const Token = Scanner.Token;
/// How a scalar was written (`Scanner.ScalarStyle`).
pub const ScalarStyle = Scanner.ScalarStyle;
/// Where and why parsing failed (`Scanner.Diagnostic`).
pub const Diagnostic = Scanner.Diagnostic;
/// Parsing's errors: the scanner's, its own syntax errors, and a
/// document with more %TAG directives than `max_tag_directives`.
pub const Error = Scanner.Error || error{TagDirectiveLimit};

/// How long an event's text lives (`text_lifetime`).
pub const TextLifetime = enum { parser, next_event };

/// A step of the stream: a start or end of the stream, a document or a
/// collection, a scalar, or an alias; with the marks of its text.
pub const Event = struct {
    start: Mark,
    end: Mark,
    data: Data,

    pub const Data = union(enum) {
        stream_start,
        stream_end,
        document_start: DocumentStart,
        document_end: DocumentEnd,
        /// The anchor's name.
        alias: []const u8,
        scalar: Scalar,
        sequence_start: Collection,
        sequence_end,
        mapping_start: Collection,
        mapping_end,
    };

    pub const DocumentStart = struct {
        /// Begun with `---`.
        explicit: bool,
        version: ?Token.Version = null,
        tag_directives: []const Token.TagDirective = &.{},
    };

    pub const DocumentEnd = struct {
        /// Ended with `...`.
        explicit: bool,
    };

    /// A node's anchor and its tag, resolved: `!` alone is the
    /// non-specific tag, and null is no tag.
    pub const Properties = struct {
        anchor: ?[]const u8 = null,
        tag: ?[]const u8 = null,
    };

    pub const Scalar = struct {
        properties: Properties = .{},
        value: []const u8,
        style: ScalarStyle,
    };

    pub const Collection = struct {
        properties: Properties = .{},
        flow: bool,
    };
};

const State = enum {
    stream_start,
    document_start,
    document_content,
    document_end,
    block_node,
    block_node_or_indentless_sequence,
    flow_node,
    block_sequence_entry,
    indentless_sequence_entry,
    block_mapping_key,
    block_mapping_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_sequence_entry_mapping_key,
    flow_sequence_entry_mapping_value,
    flow_sequence_entry_mapping_end,
    flow_mapping_first_key,
    flow_mapping_key,
    flow_mapping_value,
    flow_mapping_empty_value,
    end,
};

scanner: Scanner,
state: State = .stream_start,
/// The states to return to as nodes end.
states: std.ArrayList(State) = .empty,
/// The current document's %TAG directives.
tag_directives: std.ArrayList(Token.TagDirective) = .empty,
/// The stream has just begun, or the last document ended with `...`:
/// the next may be bare, or have directives.
after_end_marker: bool = true,
/// The most %TAG directives a document may have. A tag is resolved by
/// looking through them, so with no bound their number would make
/// parsing quadratic: 80,000 of them, 1.3 MB, took 2.6 s.
max_tag_directives: usize = 64,
diagnostic: Diagnostic = .{},
/// How long the text an event points at lives, where it is not the
/// input's own (a scalar's value built from escapes or several lines, a
/// resolved tag, a document start's %TAG directives): `.parser`, as long
/// as the parser; or `.next_event`, until the next call to `next`, its
/// memory then reused, so a stream of any length is read in the memory
/// of a few events, as libyaml's events are until yaml_event_delete
/// (t53). Copy what is kept past the next call. Set before the first
/// `next`.
text_lifetime: TextLifetime = .parser,
/// Whether events come from the reader until it stops. Set false before
/// the first `next` to read with the state machine alone, as the
/// reader's checks do.
use_reader: bool = true,
reader: Reader,
/// Events the reader has given: the state machine, taking over, reads
/// as many again.
given: usize = 0,
/// The state machine's last event, where `nextInPlace` points at it.
parsed: Event = undefined,

/// A parser over `input`, UTF-8 (`encoding.toUtf8` for others). It
/// allocates nothing until `next`.
pub fn init(gpa: Allocator, input: []const u8) Parser {
    return .{ .scanner = .init(gpa, input), .reader = .init(gpa, input) };
}

/// Begins reading at `start` (`init` reads from the input's start): a
/// place a document's text begins, at a line's start, the marks of
/// everything read counted from the input's start. For reading a
/// stream's documents in pieces, side by side (t77). Before the first
/// `next`.
pub fn startAt(p: *Parser, start: Mark) void {
    p.scanner.mark = start;
    p.scanner.line_start = start.offset;
    p.reader.s.mark = start;
    p.reader.s.line_start = start.offset;
}

/// Frees the parser and the text its events point at.
pub fn deinit(p: *Parser) void {
    p.states.deinit(p.scanner.gpa);
    p.tag_directives.deinit(p.scanner.gpa);
    p.scanner.deinit();
    p.reader.deinit();
    p.* = undefined;
}

/// The next event. After `stream_end`, `stream_end` again. On
/// `error.SyntaxError`, `diagnostic` says what and where.
pub fn next(p: *Parser) Error!Event {
    return (try p.nextInPlace()).*;
}

/// `next`'s event where the parser keeps it, not copied: valid until the
/// next call, its text as long as the parser.
pub inline fn nextInPlace(p: *Parser) Error!*const Event {
    if (p.use_reader) {
        // The reader reads on only with its queue empty: its limits are
        // set then, the same test as its own. A flag tested an event
        // cost compose 3% (t76).
        if (p.reader.head == p.reader.events.items.len) p.setReader();
        if (p.reader.next()) |got| {
            p.given += 1;
            return got;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => try p.handOver(),
        }
    }
    p.parsed = try p.parse();
    return &p.parsed;
}

/// The reader's limits, from the parser's (`scanner.max_depth`,
/// `max_tag_directives`), which a caller may set after `init`.
fn setReader(p: *Parser) void {
    p.reader.setMaxDepth(p.scanner.max_depth);
    p.reader.max_tag_directives = p.max_tag_directives;
    p.reader.reuse_text = p.text_lifetime == .next_event;
}

/// Where the reader stops, the state machine reads the stream from its
/// start, past the events the reader gave. The reader stays: the text of
/// the events it gave is its own.
noinline fn handOver(p: *Parser) Error!void {
    p.use_reader = false;
    for (0..p.given) |_| _ = try p.parse();
}

/// The state machine's next event, the text of the last one reused
/// first under `.next_event`.
fn parse(p: *Parser) Error!Event {
    if (p.text_lifetime == .next_event) p.scanner.reuseText();
    return p.parseState();
}

fn parseState(p: *Parser) Error!Event {
    return switch (p.state) {
        .stream_start => p.parseStreamStart(),
        .document_start => p.parseDocumentStart(),
        .document_content => p.parseDocumentContent(),
        .document_end => p.parseDocumentEnd(),
        .block_node => p.parseNode(.{ .block = true }),
        .block_node_or_indentless_sequence => p.parseNode(.{ .block = true, .indentless_sequence = true }),
        .flow_node => p.parseNode(.{ .block = false }),
        .block_sequence_entry => p.parseBlockSequenceEntry(),
        .indentless_sequence_entry => p.parseIndentlessSequenceEntry(),
        .block_mapping_key => p.parseBlockMappingKey(),
        .block_mapping_value => p.parseBlockMappingValue(),
        .flow_sequence_first_entry => p.parseFlowSequenceEntry(true),
        .flow_sequence_entry => p.parseFlowSequenceEntry(false),
        .flow_sequence_entry_mapping_key => p.parseFlowSequenceEntryMappingKey(),
        .flow_sequence_entry_mapping_value => p.parseFlowSequenceEntryMappingValue(),
        .flow_sequence_entry_mapping_end => p.parseFlowSequenceEntryMappingEnd(),
        .flow_mapping_first_key => p.parseFlowMappingKey(true),
        .flow_mapping_key => p.parseFlowMappingKey(false),
        .flow_mapping_value => p.parseFlowMappingValue(false),
        .flow_mapping_empty_value => p.parseFlowMappingValue(true),
        .end => .{ .start = p.scanner.mark, .end = p.scanner.mark, .data = .stream_end },
    };
}

// Tokens

/// The next token, in the scanner's queue: valid until the next `peek`,
/// so a mark wanted after one is taken before it.
fn peek(p: *Parser) Error!*const Token {
    return p.scanner.peekToken() catch |err| {
        if (err != error.OutOfMemory) p.diagnostic = p.scanner.diagnostic;
        return err;
    };
}

/// Moves past the token `peek` gave; it stays readable until the next
/// `peek`.
fn skip(p: *Parser) void {
    p.scanner.skipToken();
}

fn push(p: *Parser, state: State) Error!void {
    try p.states.append(p.scanner.gpa, state);
}

/// Returns to the state saved when the node now ending began.
fn pop(p: *Parser) void {
    p.state = p.states.pop() orelse .end;
}

fn fail(p: *Parser, mark: Mark, message: []const u8) error{SyntaxError} {
    p.diagnostic = .{ .mark = mark, .message = message };
    return error.SyntaxError;
}

fn event(start: Mark, end: Mark, data: Event.Data) Event {
    return .{ .start = start, .end = end, .data = data };
}

/// An empty plain scalar at `mark`, as a node with no content is.
fn emptyScalar(mark: Mark) Event {
    return event(mark, mark, .{ .scalar = .{ .value = "", .style = .plain } });
}

// Stream and documents

fn parseStreamStart(p: *Parser) Error!Event {
    const token = try p.peek();
    p.skip();
    p.state = .document_start;
    return event(token.start, token.end, .stream_start);
}

fn parseDocumentStart(p: *Parser) Error!Event {
    var token = try p.peek();
    // A `...` with no document before it ends nothing.
    while (token.data == .document_end) {
        p.skip();
        p.after_end_marker = true;
        token = try p.peek();
    }
    switch (token.data) {
        .stream_end => {
            p.skip();
            p.state = .end;
            return event(token.start, token.end, .stream_end);
        },
        .version_directive, .tag_directive, .document_start => return p.parseExplicitDocumentStart(),
        else => {},
    }
    if (!p.after_end_marker) return p.fail(token.start, "a document after another must begin with '---'");
    p.tag_directives.clearRetainingCapacity();
    try p.push(.document_end);
    p.state = .block_node;
    return event(token.start, token.start, .{ .document_start = .{ .explicit = false } });
}

fn parseExplicitDocumentStart(p: *Parser) Error!Event {
    const start = (try p.peek()).start;
    p.tag_directives.clearRetainingCapacity();
    const version = try p.parseDirectives();
    const token = try p.peek();
    if (token.data != .document_start) return p.fail(token.start, "directives must be followed by '---'");
    p.skip();
    try p.push(.document_end);
    p.state = .document_content;
    const tags = try p.scanner.arena.allocator().dupe(Token.TagDirective, p.tag_directives.items);
    return event(start, token.end, .{ .document_start = .{ .explicit = true, .version = version, .tag_directives = tags } });
}

/// Reads a document's directives into `tag_directives`, and returns its
/// %YAML version if it has one.
fn parseDirectives(p: *Parser) Error!?Token.Version {
    var version: ?Token.Version = null;
    while (true) {
        const token = try p.peek();
        if (token.data != .version_directive and token.data != .tag_directive) return version;
        if (!p.after_end_marker) return p.fail(token.start, "a directive after a document must follow a '...' that ends it");
        try p.parseDirective(token, &version);
        p.skip();
    }
}

fn parseDirective(p: *Parser, token: *const Token, version: *?Token.Version) Error!void {
    switch (token.data) {
        .version_directive => |v| {
            if (version.* != null) return p.fail(token.start, "a document may have one %YAML directive");
            if (v.major != 1) return p.fail(token.start, "this is YAML 1.2: a document of another major version cannot be read");
            version.* = v;
        },
        .tag_directive => |d| {
            if (p.tag_directives.items.len >= p.max_tag_directives) {
                p.diagnostic = .{ .mark = token.start, .message = "a document has more %TAG directives than max_tag_directives" };
                return error.TagDirectiveLimit;
            }
            if (p.tagPrefix(d.handle) != null) return p.fail(token.start, "a document may have one %TAG directive for a handle");
            try p.tag_directives.append(p.scanner.gpa, d);
        },
        else => unreachable,
    }
}

fn parseDocumentContent(p: *Parser) Error!Event {
    const token = try p.peek();
    switch (token.data) {
        .version_directive, .tag_directive, .document_start, .document_end, .stream_end => {
            p.pop();
            return emptyScalar(token.start);
        },
        else => return p.parseNode(.{ .block = true }),
    }
}

fn parseDocumentEnd(p: *Parser) Error!Event {
    const token = try p.peek();
    const start = token.start;
    const explicit = token.data == .document_end;
    var end = start;
    if (explicit) {
        p.skip();
        end = token.end;
        const after = try p.peek();
        if (after.start.line == start.line and after.data != .stream_end) {
            return p.fail(after.start, "nothing may follow '...' on its line but a comment");
        }
    }
    p.after_end_marker = explicit;
    p.state = .document_start;
    return event(start, end, .{ .document_end = .{ .explicit = explicit } });
}

// Nodes

const NodeContext = struct {
    /// A block collection may be the node.
    block: bool,
    /// A sequence with no indentation past its key's may be the node.
    indentless_sequence: bool = false,
};

fn parseNode(p: *Parser, context: NodeContext) Error!Event {
    const first = try p.peek();
    if (first.data == .alias) {
        p.skip();
        p.pop();
        return event(first.start, first.end, .{ .alias = first.data.alias });
    }
    const first_start = first.start;
    var end = first_start;
    const properties = try p.parseProperties(&end);
    const token = try p.peek();
    if (token.data == .alias) return p.fail(token.start, "an alias cannot have an anchor or a tag: it is a node already");
    const start = if (properties.anchor != null or properties.tag != null) first_start else token.start;
    if (context.indentless_sequence and token.data == .block_entry) {
        p.state = .indentless_sequence_entry;
        return event(start, end, .{ .sequence_start = .{ .properties = properties, .flow = false } });
    }
    if (try p.parseNodeContent(context, token, start, properties)) |content| return content;
    if (properties.anchor != null or properties.tag != null) {
        p.pop();
        return event(start, end, .{ .scalar = .{ .properties = properties, .value = "", .style = .plain } });
    }
    return p.fail(token.start, "did not find the node expected here");
}

/// The event that begins a node's content at `token`, or null if the
/// token holds none.
fn parseNodeContent(p: *Parser, context: NodeContext, token: *const Token, start: Mark, properties: Event.Properties) Error!?Event {
    const collection: Event.Collection = .{ .properties = properties, .flow = true };
    var block = collection;
    block.flow = false;
    switch (token.data) {
        .scalar => |scalar| {
            p.skip();
            p.pop();
            return event(start, token.end, .{ .scalar = .{ .properties = properties, .value = scalar.value, .style = scalar.style } });
        },
        .flow_sequence_start => {
            p.skip();
            p.state = .flow_sequence_first_entry;
            return event(start, token.end, .{ .sequence_start = collection });
        },
        .flow_mapping_start => {
            p.skip();
            p.state = .flow_mapping_first_key;
            return event(start, token.end, .{ .mapping_start = collection });
        },
        .block_sequence_start, .block_mapping_start => if (context.block) {
            p.skip();
            if (token.data == .block_sequence_start) {
                p.state = .block_sequence_entry;
                return event(start, token.end, .{ .sequence_start = block });
            }
            p.state = .block_mapping_key;
            return event(start, token.end, .{ .mapping_start = block });
        },
        else => {},
    }
    return null;
}

/// A node's anchor and tag, in either order, each at most once.
fn parseProperties(p: *Parser, end: *Mark) Error!Event.Properties {
    var properties: Event.Properties = .{};
    while (true) {
        const token = try p.peek();
        switch (token.data) {
            .anchor => |name| {
                if (properties.anchor != null) break;
                properties.anchor = name;
            },
            .tag => |tag| {
                if (properties.tag != null) break;
                properties.tag = try p.resolveTag(tag, token.start);
            },
            else => break,
        }
        end.* = token.end;
        p.skip();
    }
    return properties;
}

/// The whole tag a tag token names: a verbatim tag as written, `!` alone
/// as the non-specific tag, a shorthand's handle replaced by its prefix.
fn resolveTag(p: *Parser, tag: Token.Tag, mark: Mark) Error![]const u8 {
    if (tag.handle.len == 0) return tag.suffix;
    if (tag.suffix.len == 0) return "!";
    const prefix = p.tagPrefix(tag.handle) orelse defaultPrefix(tag.handle) orelse
        return p.fail(mark, "a tag's handle needs a %TAG directive for it in its document");
    return std.mem.concat(p.scanner.arena.allocator(), u8, &.{ prefix, tag.suffix });
}

/// The prefix the current document's %TAG directive gives `handle`.
fn tagPrefix(p: *const Parser, handle: []const u8) ?[]const u8 {
    for (p.tag_directives.items) |d| {
        if (std.mem.eql(u8, d.handle, handle)) return d.prefix;
    }
    return null;
}

fn defaultPrefix(handle: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, handle, "!")) return "!";
    if (std.mem.eql(u8, handle, "!!")) return schema.core_prefix;
    return null;
}

// Block collections

fn parseBlockSequenceEntry(p: *Parser) Error!Event {
    const token = try p.peek();
    switch (token.data) {
        .block_entry => {
            const end = token.end;
            p.skip();
            const after = try p.peek();
            if (after.data == .block_entry or after.data == .block_end) {
                p.state = .block_sequence_entry;
                return emptyScalar(end);
            }
            try p.push(.block_sequence_entry);
            return p.parseNode(.{ .block = true });
        },
        .block_end => {
            p.skip();
            p.pop();
            return event(token.start, token.end, .sequence_end);
        },
        else => return p.fail(token.start, "a block sequence's entries each need a '-' before them"),
    }
}

/// A sequence at its mapping key's indentation, which no `block_end` ends:
/// it ends at the first token that is not a `-`.
fn parseIndentlessSequenceEntry(p: *Parser) Error!Event {
    const token = try p.peek();
    if (token.data != .block_entry) {
        p.pop();
        return event(token.start, token.start, .sequence_end);
    }
    const end = token.end;
    p.skip();
    const after = try p.peek();
    switch (after.data) {
        .block_entry, .key, .value, .block_end => {
            p.state = .indentless_sequence_entry;
            return emptyScalar(end);
        },
        else => {
            try p.push(.indentless_sequence_entry);
            return p.parseNode(.{ .block = true });
        },
    }
}

fn parseBlockMappingKey(p: *Parser) Error!Event {
    const token = try p.peek();
    switch (token.data) {
        .key => {
            const end = token.end;
            p.skip();
            const after = try p.peek();
            if (after.data == .key or after.data == .value or after.data == .block_end) {
                p.state = .block_mapping_value;
                return emptyScalar(end);
            }
            try p.push(.block_mapping_value);
            return p.parseNode(.{ .block = true, .indentless_sequence = true });
        },
        // A value with no key: the key is empty.
        .value => {
            p.state = .block_mapping_value;
            return emptyScalar(token.start);
        },
        .block_end => {
            p.skip();
            p.pop();
            return event(token.start, token.end, .mapping_end);
        },
        else => return p.fail(token.start, "a block mapping's entries each need a key"),
    }
}

fn parseBlockMappingValue(p: *Parser) Error!Event {
    const token = try p.peek();
    if (token.data != .value) {
        p.state = .block_mapping_key;
        return emptyScalar(token.start);
    }
    const end = token.end;
    p.skip();
    const after = try p.peek();
    if (after.data == .key or after.data == .value or after.data == .block_end) {
        p.state = .block_mapping_key;
        return emptyScalar(end);
    }
    try p.push(.block_mapping_key);
    return p.parseNode(.{ .block = true, .indentless_sequence = true });
}

// Flow collections

fn parseFlowSequenceEntry(p: *Parser, first: bool) Error!Event {
    var token = try p.peek();
    if (token.data != .flow_sequence_end and !first) {
        if (token.data != .flow_entry) return p.fail(token.start, "a flow sequence's entries need a ',' between them, and a ']' after");
        p.skip();
        token = try p.peek();
    }
    switch (token.data) {
        .flow_sequence_end => {
            p.skip();
            p.pop();
            return event(token.start, token.end, .sequence_end);
        },
        // A pair in a sequence is a mapping of its own: `[a: b]`. With no
        // key before its `:`, the key is empty.
        .key, .value => {
            if (token.data == .key) p.skip();
            p.state = .flow_sequence_entry_mapping_key;
            return event(token.start, token.end, .{ .mapping_start = .{ .flow = true } });
        },
        else => {
            try p.push(.flow_sequence_entry);
            return p.parseNode(.{ .block = false });
        },
    }
}

fn parseFlowSequenceEntryMappingKey(p: *Parser) Error!Event {
    const token = try p.peek();
    switch (token.data) {
        .value, .flow_entry, .flow_sequence_end => {
            p.state = .flow_sequence_entry_mapping_value;
            return emptyScalar(token.start);
        },
        else => {
            try p.push(.flow_sequence_entry_mapping_value);
            return p.parseNode(.{ .block = false });
        },
    }
}

fn parseFlowSequenceEntryMappingValue(p: *Parser) Error!Event {
    const token = try p.peek();
    if (token.data == .value) {
        p.skip();
        const after = try p.peek();
        if (after.data != .flow_entry and after.data != .flow_sequence_end) {
            try p.push(.flow_sequence_entry_mapping_end);
            return p.parseNode(.{ .block = false });
        }
        p.state = .flow_sequence_entry_mapping_end;
        return emptyScalar(after.start);
    }
    p.state = .flow_sequence_entry_mapping_end;
    return emptyScalar(token.start);
}

fn parseFlowSequenceEntryMappingEnd(p: *Parser) Error!Event {
    const token = try p.peek();
    p.state = .flow_sequence_entry;
    return event(token.start, token.start, .mapping_end);
}

fn parseFlowMappingKey(p: *Parser, first: bool) Error!Event {
    var token = try p.peek();
    if (token.data != .flow_mapping_end and !first) {
        if (token.data != .flow_entry) return p.fail(token.start, "a flow mapping's entries need a ',' between them, and a '}' after");
        p.skip();
        token = try p.peek();
    }
    switch (token.data) {
        .flow_mapping_end => {
            p.skip();
            p.pop();
            return event(token.start, token.end, .mapping_end);
        },
        .key => {
            p.skip();
            const after = try p.peek();
            if (after.data == .value or after.data == .flow_entry or after.data == .flow_mapping_end) {
                p.state = .flow_mapping_value;
                return emptyScalar(after.start);
            }
            try p.push(.flow_mapping_value);
            return p.parseNode(.{ .block = false });
        },
        // A value with no key: the key is empty.
        .value => {
            p.state = .flow_mapping_value;
            return emptyScalar(token.start);
        },
        else => {
            // A key alone: its value is empty.
            try p.push(.flow_mapping_empty_value);
            return p.parseNode(.{ .block = false });
        },
    }
}

fn parseFlowMappingValue(p: *Parser, empty: bool) Error!Event {
    const token = try p.peek();
    p.state = .flow_mapping_key;
    if (empty or token.data != .value) return emptyScalar(token.start);
    p.skip();
    const after = try p.peek();
    if (after.data == .flow_entry or after.data == .flow_mapping_end) return emptyScalar(after.start);
    try p.push(.flow_mapping_key);
    return p.parseNode(.{ .block = false });
}

/// Writes `e` in the notation of the yaml-test-suite's `test.event`
/// files, one event a line: `+STR`, `+DOC ---`, `+MAP {} &a <tag>`,
/// `=VAL :plain`, `=ALI *a`, and so on, a value's `\`, backspace, tab,
/// line feed and carriage return escaped.
pub fn writeTestEvent(w: *std.Io.Writer, e: Event) std.Io.Writer.Error!void {
    switch (e.data) {
        .stream_start => try w.writeAll("+STR"),
        .stream_end => try w.writeAll("-STR"),
        .document_start => |d| try w.writeAll(pick(d.explicit, "+DOC ---", "+DOC")),
        .document_end => |d| try w.writeAll(pick(d.explicit, "-DOC ...", "-DOC")),
        .alias => |name| try w.print("=ALI *{s}", .{name}),
        .sequence_start => |c| try writeTestCollection(w, pick(c.flow, "+SEQ []", "+SEQ"), c),
        .mapping_start => |c| try writeTestCollection(w, pick(c.flow, "+MAP {}", "+MAP"), c),
        .sequence_end => try w.writeAll("-SEQ"),
        .mapping_end => try w.writeAll("-MAP"),
        .scalar => |s| {
            try w.writeAll("=VAL");
            try writeTestProperties(w, s.properties);
            try w.writeAll(styleSigil(s.style));
            for (s.value) |c| try w.writeAll(escapedForTest(&c));
        },
    }
    try w.writeByte('\n');
}

fn pick(which: bool, yes: []const u8, no: []const u8) []const u8 {
    return if (which) yes else no;
}

fn writeTestCollection(w: *std.Io.Writer, head: []const u8, c: Event.Collection) std.Io.Writer.Error!void {
    try w.writeAll(head);
    try writeTestProperties(w, c.properties);
}

fn styleSigil(style: ScalarStyle) []const u8 {
    return switch (style) {
        .plain => " :",
        .single_quoted => " '",
        .double_quoted => " \"",
        .literal => " |",
        .folded => " >",
    };
}

/// The byte at `c` as the suite's notation writes it in a value.
fn escapedForTest(c: *const u8) []const u8 {
    return switch (c.*) {
        '\\' => "\\\\",
        0x08 => "\\b",
        '\t' => "\\t",
        '\n' => "\\n",
        '\r' => "\\r",
        else => c[0..1],
    };
}

fn writeTestProperties(w: *std.Io.Writer, properties: Event.Properties) std.Io.Writer.Error!void {
    if (properties.anchor) |anchor| try w.print(" &{s}", .{anchor});
    if (properties.tag) |tag| try w.print(" <{s}>", .{tag});
}
