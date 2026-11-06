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
//! Nodes live as long as the composer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
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

/// Composing's errors: the parser's, and the two of composition.
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
};

/// How much of two nodes equality and hashing look at before giving up:
/// enough for any key a person writes, little enough that keys built to
/// be costly to compare, or cycles, cost no more.
const node_budget = 256;

parser: Parser,
options: Options,
/// Nodes and their lists.
arena: std.heap.ArenaAllocator,
/// The open collections, innermost last.
frames: std.ArrayList(Frame) = .empty,
anchors: std.HashMapUnmanaged([]const u8, *Node, SeededStrings, std.hash_map.default_max_load_percentage) = .empty,
/// The seed of every hash map, from a hash of the input.
seed: u64,
diagnostic: Diagnostic = .{},

const Frame = struct {
    node: *Node,
    /// A sequence's items, or a mapping's keys and values in turn.
    items: std.ArrayList(*Node) = .empty,
    /// A large mapping's keys, for finding a duplicate.
    keys: KeySet = .empty,
};

/// A composer over `input`, UTF-8 (`encoding.toUtf8` for others). It
/// allocates nothing until `next`.
pub fn init(gpa: Allocator, input: []const u8, options: Options) Composer {
    var digest: [8]u8 = undefined;
    std.crypto.hash.Blake3.hash(input, &digest, .{});
    var parser: Parser = .init(gpa, input);
    parser.scanner.max_depth = options.max_depth;
    return .{
        .parser = parser,
        .options = options,
        .arena = .init(gpa),
        .seed = std.mem.readInt(u64, &digest, .little),
    };
}

/// Frees every node and string the composer gave.
pub fn deinit(c: *Composer) void {
    const gpa = c.parser.scanner.gpa;
    for (c.frames.items) |*frame| frame.keys.deinit(gpa);
    c.frames.deinit(gpa);
    c.anchors.deinit(gpa);
    c.arena.deinit();
    c.parser.deinit();
    c.* = undefined;
}

/// The stream's next document, or null after its last. On an error,
/// `diagnostic` says what and where.
pub fn next(c: *Composer) Error!?Document {
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

fn nextEvent(c: *Composer) Error!Event {
    return c.parser.next() catch |err| {
        if (err != error.OutOfMemory) c.diagnostic = c.parser.diagnostic;
        return err;
    };
}

/// Composes the node whose first event is next, and all inside it.
fn composeNode(c: *Composer) Error!*Node {
    while (true) {
        const event = try c.nextEvent();
        const done = switch (event.data) {
            .scalar => |s| try c.newNode(event, s.properties, .{ .scalar = .{ .value = s.value, .style = s.style } }),
            .alias => |name| try c.aliasNode(event, name),
            .sequence_start => |s| try c.open(event, s.properties, .{ .sequence = .{ .flow = s.flow } }),
            .mapping_start => |s| try c.open(event, s.properties, .{ .mapping = .{ .flow = s.flow } }),
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
fn newNode(c: *Composer, event: Event, properties: Event.Properties, data: Node.Data) Error!*Node {
    const node = try c.arena.allocator().create(Node);
    const tag = if (data == .alias) null else try c.resolveTag(event.start, properties.tag, data);
    node.* = .{ .start = event.start, .end = event.end, .tag = tag, .anchor = properties.anchor, .data = data };
    if (properties.anchor) |name| {
        try c.anchors.putContext(c.parser.scanner.gpa, name, node, .{ .seed = c.seed });
    }
    return node;
}

/// A node's tag: the one written if it is specific, or else the one its
/// kind, its style and the schema give it.
fn resolveTag(c: *Composer, mark: Mark, written: ?[]const u8, data: Node.Data) Error![]const u8 {
    if (written) |tag| {
        if (!std.mem.eql(u8, tag, "!")) return tag;
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

fn aliasNode(c: *Composer, event: Event, name: []const u8) Error!*Node {
    const target = c.anchors.getContext(name, .{ .seed = c.seed }) orelse {
        c.diagnostic = .{ .mark = event.start, .message = "an alias names no anchor before it in its document" };
        return error.UndefinedAlias;
    };
    return c.newNode(event, .{}, .{ .alias = target });
}

/// Opens a collection; returns null, as it is not done yet.
fn open(c: *Composer, event: Event, properties: Event.Properties, data: Node.Data) Error!?*Node {
    const node = try c.newNode(event, properties, data);
    try c.frames.append(c.parser.scanner.gpa, .{ .node = node });
    return null;
}

/// Closes the innermost collection and returns it.
fn close(c: *Composer, end: Mark) Error!*Node {
    var frame = c.frames.pop().?;
    defer frame.keys.deinit(c.parser.scanner.gpa);
    const node = frame.node;
    node.end = end;
    switch (node.data) {
        .sequence => |*s| s.items = frame.items.items,
        .mapping => |*m| m.pairs = try pairsOf(c.arena.allocator(), frame.items.items),
        else => unreachable,
    }
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
    const is_key = frame.node.data == .mapping and frame.items.items.len % 2 == 0;
    if (is_key and c.options.duplicate_keys == .refuse) try c.checkKey(frame, node);
    try frame.items.append(c.arena.allocator(), node);
}

/// A mapping with this many keys or fewer is searched key by key; past
/// it, its keys go in a hash set.
const linear_keys = 8;

fn checkKey(c: *Composer, frame: *Frame, key: *Node) Error!void {
    const items = frame.items.items;
    const count = items.len / 2;
    const gpa = c.parser.scanner.gpa;
    const ctx: KeyContext = .{ .seed = c.seed };
    if (count < linear_keys) {
        var i: usize = 0;
        while (i < items.len) : (i += 2) {
            if (equal(items[i], key)) return c.duplicate(key);
        }
        return;
    }
    if (frame.keys.count() == 0) {
        var i: usize = 0;
        while (i < items.len) : (i += 2) try frame.keys.putContext(gpa, items[i], {}, ctx);
    }
    const entry = try frame.keys.getOrPutContext(gpa, key, ctx);
    if (entry.found_existing) return c.duplicate(key);
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

/// The hash the composer's key sets give `key`: seeded from the input,
/// so keys chosen to collide under another seed spread like any others.
pub fn keyHash(c: *const Composer, key: *const Node) u64 {
    return hashNode(key, c.seed);
}

/// The hash of `key` under `seed`, which the composer's key sets use with
/// a seed from the input. Public so a test can find keys that collide
/// under a seed of its choosing.
pub fn hashKey(key: *const Node, seed: u64) u64 {
    return hashNode(key, seed);
}

/// The hash the composer's anchor table gives `name`.
pub fn anchorHash(c: *const Composer, name: []const u8) u64 {
    return SeededStrings.hash(.{ .seed = c.seed }, name);
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
