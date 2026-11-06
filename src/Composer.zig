//! The composer: events to a graph of nodes, a document at a time, the
//! third stage of YAML 1.2.2's pipeline.
//!
//! A node is a scalar, a sequence, a mapping, or an alias, which points
//! at the node its anchor named. An anchor is the most recent of its name
//! in the document, and is known from its node's start, so an alias
//! inside the node it names makes a cycle: YAML allows that, and the
//! graph holds it; it is typed construction that refuses one. A mapping
//! may not have two equal keys (YAML 1.2.2, 3.2.1.3).
//!
//! Composition is a loop over a stack of open collections, not
//! recursion, so a deep document cannot overflow the call stack. The
//! anchors and the keys of a mapping are kept in hash maps seeded from a
//! hash of the input, since both come from the input: keys made to
//! collide under a fixed seed cannot be found for a seed nobody knows
//! before the input exists.
//!
//! A document may also be read a node at a time (`beginDocument`, `step`,
//! `endDocument`): a collection with no anchor is begun and its entries
//! read one by one, and only what must be is composed whole, a node an
//! alias may name and a mapping's key, so a reader building as it reads
//! holds a fraction of the graph (t47).
//!
//! The events come from the reader (Reader.zig), which reads most YAML in
//! one pass, and past what it does not read from the parser, which reads
//! the stream again from its start and goes on where the reader stopped
//! (t56).
//!
//! Nodes live as long as the composer. Not threadsafe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Reader = @import("Reader.zig");
const schema = @import("schema.zig");

const Composer = @This();

/// A place in the input (`Scanner.Mark`).
pub const Mark = Parser.Mark;
/// How a scalar was written (`Scanner.ScalarStyle`).
pub const ScalarStyle = Parser.ScalarStyle;
/// What the parser gives (`Parser.Event`).
pub const Event = Parser.Event;
/// Where and why composing failed (`Scanner.Diagnostic`).
pub const Diagnostic = Parser.Diagnostic;

/// Composing's errors: the parser's, and composition's own three.
pub const Error = Parser.Error || error{
    /// An alias names no anchor before it in its document.
    UndefinedAlias,
    /// A mapping has two equal keys.
    DuplicateKey,
    /// A plain scalar the schema has no tag for (the JSON schema reads
    /// only null, booleans and numbers).
    NotInSchema,
};

/// A node of a document's graph.
pub const Node = struct {
    start: Mark,
    end: Mark,
    /// The node's tag: the one written, resolved against its document's
    /// directives, or for a node with none or the non-specific `!`, the
    /// one the schema gives it (`schema.tag`). Null for an alias.
    tag: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    data: Data,

    pub const Data = union(enum) {
        scalar: Scalar,
        sequence: Sequence,
        mapping: Mapping,
        /// The node an alias names. Its own tag and anchor are null.
        alias: *Node,
    };

    pub const Scalar = struct { value: []const u8, style: ScalarStyle };
    pub const Sequence = struct { items: []*Node = &.{}, flow: bool };
    pub const Mapping = struct { pairs: []Pair = &.{}, flow: bool };
    pub const Pair = struct { key: *Node, value: *Node };

    /// The node an alias leads to, through any number of aliases; the
    /// node itself if it is none.
    pub fn target(node: *const Node) *const Node {
        var n = node;
        while (n.data == .alias) n = n.data.alias;
        return n;
    }
};

/// One document of the stream: its root node and how it was written.
pub const Document = struct {
    root: *Node,
    start: Mark,
    end: Mark,
    /// Begun with `---`.
    explicit_start: bool,
    /// Ended with `...`.
    explicit_end: bool,
    version: ?Parser.Token.Version,
    tag_directives: []const Parser.Token.TagDirective,
};

/// How composition goes.
pub const Options = struct {
    /// What to do with a mapping's second key equal to an earlier one.
    duplicate_keys: enum { refuse, keep } = .refuse,
    /// How nodes with no specific tag get one.
    schema: schema.Schema = .core,
    /// The most collections open at once (`Scanner.max_depth`).
    max_depth: usize = 10_000,
    /// The most %TAG directives a document may have
    /// (`Parser.max_tag_directives`).
    max_tag_directives: usize = 64,
};

/// How much of two nodes equality and hashing look at before giving up:
/// enough for any key a person writes, little enough that keys built to
/// be costly to compare, or cycles, cost no more.
const node_budget = 256;

parser: Parser,
/// The fast path: events from it until it hands the stream over.
reader: Reader,
/// Where the events come from now.
source: enum { reader, parser } = .reader,
/// Events the reader has given: the parser, taking over, skips as many.
given: usize = 0,
/// The parser's last event, kept where `nextEvent` can point at it.
parsed: Event = undefined,
options: Options,
/// Nodes and their lists.
arena: std.heap.ArenaAllocator,
/// The open collections, innermost last.
frames: std.ArrayList(Frame) = .empty,
/// The open collections' items, innermost last: one stack on the gpa, so
/// a collection's grow in no list of its own, each growth leaving the
/// old buffer in the arena; closing one copies its items there once, at
/// their length (t46).
items: std.ArrayList(*Node) = .empty,
/// The collections `step` has begun and not ended, innermost last.
streams: std.ArrayList(Stream) = .empty,
/// Copies of the keys `step` gave of the mappings it has begun, kept to
/// find a duplicate until each mapping ends.
kept: NodeStack = .{},
/// Key sets of closed mappings, emptied, for the next large mapping: one
/// made and freed a mapping was two allocations each (t46).
spare_key_sets: std.ArrayList(KeySet) = .empty,
/// How many key sets there are, kept or in use: `spare_key_sets` has room
/// for each, made when the set is, so keeping one never allocates.
key_sets: usize = 0,
anchors: std.HashMapUnmanaged([]const u8, *Node, SeededStrings, std.hash_map.default_max_load_percentage) = .empty,
/// The seed of every hash map, once `hashSeed` has hashed the input.
seed: ?u64 = null,
/// The error `next` failed with, which every later call gives again.
failed: ?Error = null,
diagnostic: Diagnostic = .{},

const Frame = struct {
    node: *Node,
    /// Where its items begin in `items`: a sequence's items, or a
    /// mapping's keys and values in turn.
    start: usize,
    /// A large mapping's keys, for finding a duplicate.
    keys: KeySet = .empty,
};

/// A composer over `input`, UTF-8 (`encoding.toUtf8` for others). It
/// allocates nothing until `next`.
pub fn init(gpa: Allocator, input: []const u8, options: Options) Composer {
    var parser: Parser = .init(gpa, input);
    parser.scanner.max_depth = options.max_depth;
    parser.max_tag_directives = options.max_tag_directives;
    var reader: Reader = .init(gpa, input);
    reader.setMaxDepth(options.max_depth);
    return .{
        .parser = parser,
        .reader = reader,
        .options = options,
        .arena = .init(gpa),
    };
}

/// The seed of every hash map keyed by the input's text (anchors, a large
/// mapping's keys, a map construction builds): a hash of the whole input,
/// so keys built to collide under a seed known before the input exists
/// cannot be (kb/t7). Hashed the first time a map needs it: a document
/// with no anchor and no mapping past `linear_keys` keys never pays for
/// it (t48).
pub fn hashSeed(c: *Composer) u64 {
    if (c.seed) |s| return s;
    var digest: [8]u8 = undefined;
    std.crypto.hash.Blake3.hash(c.parser.scanner.input, &digest, .{});
    const s = std.mem.readInt(u64, &digest, .little);
    c.seed = s;
    return s;
}

/// Frees every node and string the composer gave.
pub fn deinit(c: *Composer) void {
    const gpa = c.parser.scanner.gpa;
    for (c.frames.items) |*frame| frame.keys.deinit(gpa);
    c.frames.deinit(gpa);
    c.items.deinit(gpa);
    for (c.streams.items) |*stream| stream.keys.deinit(gpa);
    c.streams.deinit(gpa);
    c.kept.deinit(gpa);
    for (c.spare_key_sets.items) |*keys| keys.deinit(gpa);
    c.spare_key_sets.deinit(gpa);
    c.anchors.deinit(gpa);
    c.arena.deinit();
    c.parser.deinit();
    c.reader.deinit();
    c.* = undefined;
}

/// The stream's next document, or null after its last. On an error,
/// `diagnostic` says what and where, and the composer cannot go on:
/// each later call gives the same error.
pub fn next(c: *Composer) Error!?Document {
    if (c.failed) |err| return err;
    return c.nextDocument() catch |err| {
        c.failed = err;
        return err;
    };
}

/// `next`, which expects the parser between documents: after an error
/// it is not, and this must not be called again.
fn nextDocument(c: *Composer) Error!?Document {
    var start: Event.DocumentStart = undefined;
    var start_mark: Mark = undefined;
    while (true) {
        const event = try c.nextEvent();
        switch (event.data) {
            .stream_start => {},
            .stream_end => return null,
            .document_start => |d| {
                start = d;
                start_mark = event.start;
                break;
            },
            else => unreachable,
        }
    }
    c.anchors.clearRetainingCapacity();
    const root = try c.composeNode();
    const end = try c.nextEvent();
    return .{
        .root = root,
        .start = start_mark,
        .end = end.end,
        .explicit_start = start.explicit,
        .explicit_end = end.data.document_end.explicit,
        .version = start.version,
        .tag_directives = start.tag_directives,
    };
}

/// One step of a document read a node at a time (`step`).
pub const Step = union(enum) {
    /// A scalar or an alias, the node by value: it points into nothing
    /// of the composer's but an alias's target.
    scalar: Node,
    /// A node composed whole, living as long as the composer: one with an
    /// anchor, which an alias may name later, or a mapping's key that is a
    /// collection, compared whole with the mapping's other keys.
    node: *Node,
    /// A collection with no anchor, begun: the node by value, its tag and
    /// start known and no entries. Its entries are the steps after it, a
    /// mapping's keys and values in turn, to its `end`.
    begin: Node,
    /// The end of the innermost collection begun.
    end: Mark,
};

/// What `stepInto` read: a node by value, written in the caller's slot
/// (a scalar or an alias, or a collection begun), as `Step` says of its
/// own; a node composed whole; or the end of the innermost collection
/// begun.
pub const StepInto = union(enum) {
    scalar,
    node: *Node,
    begin,
    end: Mark,
};

/// A collection `step` has begun and not ended.
const Stream = struct {
    mapping: bool,
    /// A mapping's next entry is a key.
    at_key: bool = true,
    /// Where its keys begin in `items` and their copies in `kept`, held to
    /// find a duplicate until it ends.
    start: usize,
    kept_len: usize,
    keys: KeySet = .empty,
};

/// Begins reading the stream's next document a node at a time; null
/// after the last, else where the document begins. `step` then gives its
/// root, and once that is read `endDocument` ends it. `next` composes a
/// document whole: a document is read one way or the other, not both.
pub fn beginDocument(c: *Composer) Error!?Mark {
    if (c.failed) |err| return err;
    return c.documentStart() catch |err| {
        c.failed = err;
        return err;
    };
}

fn documentStart(c: *Composer) Error!?Mark {
    while (true) {
        const event = try c.nextEvent();
        switch (event.data) {
            .stream_start => {},
            .stream_end => return null,
            .document_start => {
                c.anchors.clearRetainingCapacity();
                return event.start;
            },
            else => unreachable,
        }
    }
}

/// The next step of the document `beginDocument` began: its root first,
/// then a begun collection's entries to its end. Called again after the
/// root is read is a misuse; `endDocument` comes then. A mapping's key
/// with an equal key before it in its mapping is `error.DuplicateKey`.
pub fn step(c: *Composer) Error!Step {
    var slot: Node = undefined;
    return switch (try c.stepInto(&slot)) {
        .scalar => .{ .scalar = slot },
        .begin => .{ .begin = slot },
        .node => |n| .{ .node = n },
        .end => |mark| .{ .end = mark },
    };
}

/// `step`, a node by value written in `slot` rather than returned: what
/// construction reads, so a node is written once where it is read, not
/// copied through each return on its way (t49).
pub fn stepInto(c: *Composer, slot: *Node) Error!StepInto {
    if (c.failed) |err| return err;
    return c.nextStep(slot) catch |err| {
        c.failed = err;
        return err;
    };
}

fn nextStep(c: *Composer, slot: *Node) Error!StepInto {
    const event = try c.nextEvent();
    if (event.data == .sequence_end or event.data == .mapping_end) {
        c.endStream();
        return .{ .end = event.end };
    }
    const stream: ?*Stream = if (c.streams.items.len > 0) &c.streams.items[c.streams.items.len - 1] else null;
    const is_key = if (stream) |s| s.mapping and s.at_key else false;
    if (stream) |s| s.at_key = s.mapping and !s.at_key;
    const result = try c.stepOf(event, is_key, slot);
    if (is_key and c.options.duplicate_keys == .refuse) try c.checkStreamKey(stream.?, result, slot);
    return result;
}

/// The step `event` begins: whole, or a collection begun, a node by
/// value written in `slot`.
fn stepOf(c: *Composer, event: *const Event, is_key: bool, slot: *Node) Error!StepInto {
    switch (event.data) {
        .scalar => |*s| {
            const data: Node.Data = .{ .scalar = .{ .value = s.value, .style = s.style } };
            if (s.properties.anchor != null) return .{ .node = try c.newNode(event, &s.properties, data) };
            slot.* = .{ .start = event.start, .end = event.end, .tag = try c.resolveTag(event.start, s.properties.tag, data), .data = data };
            return .scalar;
        },
        .alias => |name| {
            slot.* = .{ .start = event.start, .end = event.end, .data = .{ .alias = try c.anchorNamed(event, name) } };
            return .scalar;
        },
        .sequence_start, .mapping_start => |*collection| {
            if (collection.properties.anchor != null or is_key) return .{ .node = try c.composeFrom(event) };
            const data: Node.Data = if (event.data == .sequence_start) .{ .sequence = .{ .flow = collection.flow } } else .{ .mapping = .{ .flow = collection.flow } };
            const tag = try c.resolveTag(event.start, collection.properties.tag, data);
            try c.streams.append(c.parser.scanner.gpa, .{ .mapping = event.data == .mapping_start, .start = c.items.items.len, .kept_len = c.kept.len });
            slot.* = .{ .start = event.start, .end = event.end, .tag = tag, .data = data };
            return .begin;
        },
        else => unreachable,
    }
}

/// Checks a key `step` read against its mapping's others, keeping it,
/// or a copy of it, until the mapping ends.
fn checkStreamKey(c: *Composer, stream: *Stream, key: StepInto, slot: *const Node) Error!void {
    const gpa = c.parser.scanner.gpa;
    const node = switch (key) {
        .scalar => try c.kept.push(gpa, slot.*),
        .node => |n| n,
        .begin, .end => unreachable,
    };
    try c.checkKeyAmong(c.items.items[stream.start..], 1, &stream.keys, node);
    try c.items.append(gpa, node);
}

fn endStream(c: *Composer) void {
    var stream = c.streams.pop().?;
    c.items.shrinkRetainingCapacity(stream.start);
    c.kept.len = stream.kept_len;
    c.recycle(&stream.keys);
}

/// Composes whole the collection the last `step` began, none of its
/// entries read yet: a node living as long as the composer, for a reader
/// that needs one whole after all (a type's yamlParse hook).
pub fn finish(c: *Composer, head: Node) Error!*Node {
    if (c.failed) |err| return err;
    return c.finishStream(head) catch |err| {
        c.failed = err;
        return err;
    };
}

fn finishStream(c: *Composer, head: Node) Error!*Node {
    var stream = c.streams.pop().?;
    c.recycle(&stream.keys);
    const node = try c.arena.allocator().create(Node);
    node.* = head;
    try c.frames.append(c.parser.scanner.gpa, .{ .node = node, .start = c.items.items.len });
    return c.composeFrom(try c.nextEvent());
}

/// Ends the document `beginDocument` began, its root read.
pub fn endDocument(c: *Composer) Error!void {
    if (c.failed) |err| return err;
    _ = c.nextEvent() catch |err| {
        c.failed = err;
        return err;
    };
}

/// The next event, where it is kept: valid until the next call. The
/// reader's is read in place, not copied (t56).
fn nextEvent(c: *Composer) Error!*const Event {
    if (c.source == .reader) {
        if (c.reader.next()) |event| {
            c.given += 1;
            return event;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => try c.handOver(),
        }
    }
    c.parsed = try c.parserEvent();
    return &c.parsed;
}

/// Where the reader stops, the parser reads the stream from its start,
/// past the events the reader gave: they are its own (the suite's
/// `reader` check and the reader fuzz target hold the reader to that).
/// So an error and its diagnostic are the parser's. The reader stays: a
/// value it built may be a node's.
fn handOver(c: *Composer) Error!void {
    c.source = .parser;
    for (0..c.given) |_| _ = try c.parserEvent();
}

fn parserEvent(c: *Composer) Error!Event {
    return c.parser.next() catch |err| {
        if (err != error.OutOfMemory) c.diagnostic = c.parser.diagnostic;
        return err;
    };
}

/// Composes the node whose first event is next, and all inside it.
fn composeNode(c: *Composer) Error!*Node {
    return c.composeFrom(try c.nextEvent());
}

/// Composes the node whose first event is `first`, and all inside it.
fn composeFrom(c: *Composer, first: *const Event) Error!*Node {
    var event = first;
    while (true) : (event = try c.nextEvent()) {
        const done = switch (event.data) {
            // The event read where it is, not copied to each call (t49).
            .scalar => |*s| try c.newNode(event, &s.properties, .{ .scalar = .{ .value = s.value, .style = s.style } }),
            .alias => |name| try c.aliasNode(event, name),
            .sequence_start => |*s| try c.open(event, &s.properties, .{ .sequence = .{ .flow = s.flow } }),
            .mapping_start => |*s| try c.open(event, &s.properties, .{ .mapping = .{ .flow = s.flow } }),
            .sequence_end, .mapping_end => try c.close(event.end),
            else => unreachable,
        };
        // A node done with no collection open is the one asked for.
        const node = done orelse continue;
        if (c.frames.items.len == 0) return node;
        try c.attach(node);
    }
}

/// A node for `event`, its tag resolved and its anchor recorded.
fn newNode(c: *Composer, event: *const Event, properties: *const Event.Properties, data: Node.Data) Error!*Node {
    const node = try c.arena.allocator().create(Node);
    const tag = if (data == .alias) null else try c.resolveTag(event.start, properties.tag, data);
    node.* = .{ .start = event.start, .end = event.end, .tag = tag, .anchor = properties.anchor, .data = data };
    if (properties.anchor) |name| {
        try c.anchors.putContext(c.parser.scanner.gpa, name, node, .{ .seed = c.hashSeed() });
    }
    return node;
}

/// A node's tag: the one written if it is specific, or else the one its
/// kind, its style and the schema give it.
fn resolveTag(c: *Composer, mark: Mark, written: ?[]const u8, data: Node.Data) Error![]const u8 {
    if (written) |tag| {
        // A core tag written out, `!!int`, is given as the schema's own
        // text, so `schema.core` finds it by its pointer.
        if (!std.mem.eql(u8, tag, "!")) return if (schema.core(tag)) |which| schema.tagOf(which) else tag;
    }
    return switch (data) {
        .sequence => schema.tag.seq,
        .mapping => schema.tag.map,
        .scalar => |s| if (written != null or s.style != .plain)
            schema.tag.str
        else
            schema.resolvePlain(c.options.schema, s.value) orelse {
                c.diagnostic = .{ .mark = mark, .message = "the JSON schema reads a plain scalar only as null, true, false or a number" };
                return error.NotInSchema;
            },
        .alias => unreachable,
    };
}

fn aliasNode(c: *Composer, event: *const Event, name: []const u8) Error!*Node {
    return c.newNode(event, &.{}, .{ .alias = try c.anchorNamed(event, name) });
}

/// The node the anchor `name` names, for the alias `event`.
fn anchorNamed(c: *Composer, event: *const Event, name: []const u8) Error!*Node {
    return c.anchors.getContext(name, .{ .seed = c.hashSeed() }) orelse {
        c.diagnostic = .{ .mark = event.start, .message = "an alias names no anchor before it in its document" };
        return error.UndefinedAlias;
    };
}

/// Opens a collection; returns null, as it is not done yet.
fn open(c: *Composer, event: *const Event, properties: *const Event.Properties, data: Node.Data) Error!?*Node {
    const node = try c.newNode(event, properties, data);
    try c.frames.append(c.parser.scanner.gpa, .{ .node = node, .start = c.items.items.len });
    return null;
}

/// Closes the innermost collection and returns it.
fn close(c: *Composer, end: Mark) Error!*Node {
    var frame = c.frames.pop().?;
    defer c.recycle(&frame.keys);
    const node = frame.node;
    node.end = end;
    const items = c.items.items[frame.start..];
    switch (node.data) {
        .sequence => |*s| s.items = try c.arena.allocator().dupe(*Node, items),
        .mapping => |*m| m.pairs = try pairsOf(c.arena.allocator(), items),
        else => unreachable,
    }
    c.items.shrinkRetainingCapacity(frame.start);
    return node;
}

fn pairsOf(arena: Allocator, items: []const *Node) Allocator.Error![]Node.Pair {
    const pairs = try arena.alloc(Node.Pair, items.len / 2);
    for (pairs, 0..) |*pair, i| pair.* = .{ .key = items[2 * i], .value = items[2 * i + 1] };
    return pairs;
}

/// Adds a done node to the innermost collection, as an item, a key or a
/// value; a key is checked against the mapping's others.
fn attach(c: *Composer, node: *Node) Error!void {
    const frame = &c.frames.items[c.frames.items.len - 1];
    const is_key = frame.node.data == .mapping and (c.items.items.len - frame.start) % 2 == 0;
    if (is_key and c.options.duplicate_keys == .refuse) try c.checkKey(frame, node);
    try c.items.append(c.parser.scanner.gpa, node);
}

/// A mapping with this many keys or fewer is searched key by key; past
/// it, its keys go in a hash set. A config record often has more than 8
/// keys: at 16 one builds no set and the input is never hashed for a
/// seed, a tenth of composing 4.9 MB of 9-key records (t48). A search
/// compares each key with at most 15 others, so its cost stays within a
/// small multiple of the input's length.
const linear_keys = 16;

fn checkKey(c: *Composer, frame: *Frame, key: *Node) Error!void {
    return c.checkKeyAmong(c.items.items[frame.start..], 2, &frame.keys, key);
}

/// Checks `key` against a mapping's keys so far, every `stride`th of
/// `items` from the first: key by key up to linear_keys, past it in
/// `set`.
fn checkKeyAmong(c: *Composer, items: []const *Node, stride: usize, set: *KeySet, key: *Node) Error!void {
    if (items.len / stride < linear_keys) {
        var i: usize = 0;
        while (i < items.len) : (i += stride) {
            if (equal(items[i], key)) return c.duplicate(key);
        }
        return;
    }
    if (set.count() == 0) try c.fillKeySet(items, stride, set);
    const entry = try set.getOrPutContext(c.parser.scanner.gpa, key, .{ .seed = c.hashSeed() });
    if (entry.found_existing) return c.duplicate(key);
}

/// Puts a mapping's keys so far, every `stride`th of `items`, in `set`,
/// a spare one if one is kept.
fn fillKeySet(c: *Composer, items: []const *Node, stride: usize, set: *KeySet) Error!void {
    const gpa = c.parser.scanner.gpa;
    if (set.capacity() == 0) {
        if (c.spare_key_sets.pop()) |spare| {
            set.* = spare;
        } else {
            // Room to keep it once its mapping ends, made while an error
            // can still be returned.
            try c.spare_key_sets.ensureTotalCapacity(gpa, c.key_sets + 1);
            c.key_sets += 1;
        }
    }
    var i: usize = 0;
    const ctx: KeyContext = .{ .seed = c.hashSeed() };
    while (i < items.len) : (i += stride) try set.putContext(gpa, items[i], {}, ctx);
}

/// Nodes that live until the collection keeping them ends: the keys
/// `step` gave of a mapping, kept to find a duplicate. In chunks of a
/// fixed size, so a node does not move while it lives; freed from the
/// top.
const NodeStack = struct {
    chunks: std.ArrayList(*[chunk_len]Node) = .empty,
    len: usize = 0,

    const chunk_len = 64;

    fn push(s: *NodeStack, gpa: Allocator, node: Node) Allocator.Error!*Node {
        if (s.len == s.chunks.items.len * chunk_len) {
            const chunk = try gpa.create([chunk_len]Node);
            errdefer gpa.destroy(chunk);
            try s.chunks.append(gpa, chunk);
        }
        const slot = &s.chunks.items[s.len / chunk_len][s.len % chunk_len];
        slot.* = node;
        s.len += 1;
        return slot;
    }

    fn deinit(s: *NodeStack, gpa: Allocator) void {
        for (s.chunks.items) |chunk| gpa.destroy(chunk);
        s.chunks.deinit(gpa);
    }
};

/// Keeps a closed mapping's key set, emptied, for the next large one, in
/// the room made for it when it was made.
fn recycle(c: *Composer, keys: *KeySet) void {
    if (keys.capacity() == 0) return;
    keys.clearRetainingCapacity();
    c.spare_key_sets.appendAssumeCapacity(keys.*);
}

fn duplicate(c: *Composer, key: *const Node) Error {
    c.diagnostic = .{ .mark = key.start, .message = "a mapping cannot have two equal keys" };
    return error.DuplicateKey;
}

// Equality and hashing

/// Whether two nodes are equal as keys: the same kind and tag, and the
/// same content, a scalar's by value (`schema.equalValues`: `1` and `0x1`
/// are equal integers), through aliases. Gives up, as not equal, past
/// `node_budget` nodes.
pub fn equal(a: *const Node, b: *const Node) bool {
    // Keys a person writes are plain strings far more often than not: two
    // of them are compared by their text at once (t48), as equalValues
    // would after the walk below.
    if (isString(a) and isString(b)) return std.mem.eql(u8, a.data.scalar.value, b.data.scalar.value);
    var budget: usize = node_budget;
    return equalWithin(a, b, &budget);
}

fn equalWithin(a_node: *const Node, b_node: *const Node, budget: *usize) bool {
    const a = a_node.target();
    const b = b_node.target();
    if (a == b) return true;
    if (budget.* == 0) return false;
    budget.* -= 1;
    if (!std.mem.eql(u8, a.tag.?, b.tag.?)) return false;
    return switch (a.data) {
        .scalar => |s| b.data == .scalar and schema.equalValues(a.tag.?, s.value, b.data.scalar.value),
        .sequence => |s| b.data == .sequence and equalItems(s.items, b.data.sequence.items, budget),
        .mapping => |m| b.data == .mapping and equalPairs(m.pairs, b.data.mapping.pairs, budget),
        .alias => unreachable,
    };
}

/// Whether `node` is a scalar the composer tagged a string, by the tag's
/// pointer (`schema.core`).
fn isString(node: *const Node) bool {
    const tag = node.tag orelse return false;
    return node.data == .scalar and tag.ptr == schema.tag.str.ptr and tag.len == schema.tag.str.len;
}

fn equalItems(a: []const *Node, b: []const *Node, budget: *usize) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!equalWithin(x, y, budget)) return false;
    }
    return true;
}

/// Mappings are equal when each key of one is in the other with an equal
/// value; keys being unique, the same count makes that both ways.
fn equalPairs(a: []const Node.Pair, b: []const Node.Pair, budget: *usize) bool {
    if (a.len != b.len) return false;
    outer: for (a) |pa| {
        for (b) |pb| {
            if (equalWithin(pa.key, pb.key, budget)) {
                if (!equalWithin(pa.value, pb.value, budget)) return false;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

/// A hash agreeing with `equal`: equal nodes hash the same.
fn hashNode(node: *const Node, seed: u64) u64 {
    var hasher: std.hash.Wyhash = .init(seed);
    var budget: usize = node_budget;
    hashWithin(&hasher, node, &budget);
    return hasher.final();
}

fn hashWithin(hasher: *std.hash.Wyhash, node: *const Node, budget: *usize) void {
    const n = node.target();
    if (budget.* == 0) return;
    budget.* -= 1;
    hasher.update(n.tag.?);
    hasher.update(&.{@backingInt(std.meta.activeTag(n.data))});
    switch (n.data) {
        .scalar => |s| schema.hashValue(hasher, n.tag.?, s.value),
        .sequence => |s| for (s.items) |item| hashWithin(hasher, item, budget),
        // Pairs may be in any order: their count only.
        .mapping => |m| hasher.update(std.mem.asBytes(&m.pairs.len)),
        .alias => unreachable,
    }
}

const KeyContext = struct {
    seed: u64,
    pub fn hash(ctx: KeyContext, key: *Node) u64 {
        return hashNode(key, ctx.seed);
    }
    pub fn eql(_: KeyContext, a: *Node, b: *Node) bool {
        return equal(a, b);
    }
};

const KeySet = std.HashMapUnmanaged(*Node, void, KeyContext, std.hash_map.default_max_load_percentage);

const SeededStrings = struct {
    seed: u64,
    pub fn hash(ctx: SeededStrings, key: []const u8) u64 {
        return std.hash.Wyhash.hash(ctx.seed, key);
    }
    pub fn eql(_: SeededStrings, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

// A test of the hashes themselves, here rather than in Composer_test.zig
// as they are private.

const bits = 10;
const mask = (@as(u64, 1) << bits) - 1;

/// `count` names that all fall in one of 1,024 buckets under a fixed
/// seed, as an attacker who knew the seed would choose them: by std's
/// string hash (Wyhash, seed 0) for anchor names, or by the key hash at
/// seed 0 for keys.
fn collidingNames(gpa: Allocator, count: usize, comptime as_keys: bool) ![][]const u8 {
    const names = try gpa.alloc([]const u8, count);
    var found: usize = 0;
    var i: usize = 0;
    while (found < count) : (i += 1) {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        const key: Node = .{ .start = .{}, .end = .{}, .tag = schema.tag.str, .data = .{ .scalar = .{ .value = name, .style = .plain } } };
        const hash = if (as_keys) hashNode(&key, 0) else std.hash.Wyhash.hash(0, name);
        if (hash & mask != 0) continue;
        names[found] = try gpa.dupe(u8, name);
        found += 1;
    }
    return names;
}

/// How many of the 1,024 buckets `hashes` fall in.
fn buckets(gpa: Allocator, hashes: []const u64) !usize {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (hashes) |h| try seen.put(gpa, h & mask, {});
    return seen.count();
}

test "keys and anchors built to collide under a fixed seed spread under the composer's" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try collidingNames(a, 400, true);
    const anchors = try collidingNames(a, 400, false);
    var input: std.ArrayList(u8) = .empty;
    for (keys, anchors) |key, anchor| try input.print(a, "{s}: &{s} v\n", .{ key, anchor });
    var c: Composer = .init(testing.allocator, input.items, .{});
    defer c.deinit();
    const root = (try c.next()).?.root;
    var key_hashes: [400]u64 = undefined;
    var anchor_hashes: [400]u64 = undefined;
    for (root.data.mapping.pairs, anchors, 0..) |pair, anchor, i| {
        try testing.expectEqual(0, hashNode(pair.key, 0) & mask);
        key_hashes[i] = hashNode(pair.key, c.hashSeed());
        anchor_hashes[i] = SeededStrings.hash(.{ .seed = c.hashSeed() }, anchor);
    }
    // 400 random hashes fill about 330 of 1,024 buckets; one is what the
    // fixed seed gives. Allow a wide margin either side of random.
    try testing.expect(try buckets(a, &key_hashes) > 250);
    try testing.expect(try buckets(a, &anchor_hashes) > 250);
}
