//! The CLI's reading of a document's node graph: the node a path names,
//! and what a node holds as a `yaml.Value`, its aliases followed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const Node = yaml.Composer.Node;
const Value = yaml.Value;
const schema = yaml.schema;

/// One step of a path: a mapping's key, by its text, or a sequence's
/// item, by its place from 0.
pub const Segment = union(enum) {
    key: []const u8,
    index: usize,
};

/// Reads a path: `.` alone for the root; else steps in any order, each
/// `.name`, `.["a key"]` or `["a key"]`, or `[n]`. A quoted key may hold
/// `\"` and `\\`.
pub fn parsePath(arena: Allocator, text: []const u8) error{ BadPath, OutOfMemory }![]Segment {
    var path: std.ArrayList(Segment) = .empty;
    if (std.mem.eql(u8, text, ".")) return path.items;
    var i: usize = 0;
    while (i < text.len) try path.append(arena, try step(arena, text, &i));
    if (path.items.len == 0) return error.BadPath;
    return path.items;
}

/// The step of a path at `i.*`, `i.*` left after it.
fn step(arena: Allocator, text: []const u8, i: *usize) error{ BadPath, OutOfMemory }!Segment {
    if (text[i.*] == '.') {
        i.* += 1;
        if (i.* < text.len and text[i.*] == '[') return bracketed(arena, text, i);
        const start = i.*;
        while (i.* < text.len and text[i.*] != '.' and text[i.*] != '[') i.* += 1;
        if (i.* == start) return error.BadPath;
        return .{ .key = text[start..i.*] };
    }
    if (text[i.*] == '[') return bracketed(arena, text, i);
    return error.BadPath;
}

/// `["a key"]` or `[n]` at `i.*`.
fn bracketed(arena: Allocator, text: []const u8, i: *usize) error{ BadPath, OutOfMemory }!Segment {
    i.* += 1;
    const segment: Segment = if (i.* < text.len and text[i.*] == '"') .{ .key = try quotedKey(arena, text, i) } else .{ .index = try index(text, i) };
    if (i.* >= text.len or text[i.*] != ']') return error.BadPath;
    i.* += 1;
    return segment;
}

/// The key quoted at `i.*`, its escapes read; `i.*` left after its
/// closing quote.
fn quotedKey(arena: Allocator, text: []const u8, i: *usize) error{ BadPath, OutOfMemory }![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    i.* += 1;
    while (i.* < text.len and text[i.*] != '"') : (i.* += 1) {
        if (text[i.*] == '\\') {
            i.* += 1;
            if (i.* >= text.len or (text[i.*] != '"' and text[i.*] != '\\')) return error.BadPath;
        }
        try key.append(arena, text[i.*]);
    }
    if (i.* >= text.len) return error.BadPath;
    i.* += 1;
    return key.items;
}

fn index(text: []const u8, i: *usize) error{BadPath}!usize {
    const start = i.*;
    while (i.* < text.len and std.ascii.isDigit(text[i.*])) i.* += 1;
    return std.fmt.parseInt(usize, text[start..i.*], 10) catch error.BadPath;
}

/// What a path found: the node, or the step at which nothing was there.
pub const Found = union(enum) {
    node: *const Node,
    missing: usize,
};

/// The node `path` names in the graph from `root`, aliases followed; a
/// key matched by the text of a scalar key, whatever its tag.
pub fn find(root: *const Node, path: []const Segment) Found {
    var node = root.target();
    for (path, 0..) |segment, at_step| {
        const next: ?*const Node = switch (segment) {
            .key => |key| if (node.data == .mapping) lookup(node.data.mapping.pairs, key) else null,
            .index => |at| if (node.data == .sequence and at < node.data.sequence.items.len) node.data.sequence.items[at] else null,
        };
        node = (next orelse return .{ .missing = at_step }).target();
    }
    return .{ .node = node };
}

fn lookup(pairs: []const Node.Pair, key: []const u8) ?*const Node {
    for (pairs) |pair| {
        const k = pair.key.target();
        if (k.data == .scalar and std.mem.eql(u8, k.data.scalar.value, key)) return pair.value;
    }
    return null;
}

pub const ValueError = error{
    /// An alias leads back into a collection it is in: a Value cannot
    /// hold the cycle.
    Cycle,
    /// Following aliases would build more than `max_values` values.
    TooLarge,
    OutOfMemory,
};

/// The most values `valueOf` builds: aliases can make a small document
/// stand for a huge one.
pub const max_values = 1_000_000;

/// What `node` holds as a Value, aliases followed: a scalar typed by its
/// tag as parseFromSlice types one (a tag the schema has no type for
/// gives the text), a collection's entries in order.
pub fn valueOf(arena: Allocator, node: *const Node) ValueError!Value {
    var b: Builder = .{ .arena = arena };
    return b.build(node);
}

const Builder = struct {
    arena: Allocator,
    /// The collections being built: an alias to one is a cycle.
    open: std.AutoHashMapUnmanaged(*const Node, void) = .empty,
    built: usize = 0,

    fn build(b: *Builder, from: *const Node) ValueError!Value {
        const node = from.target();
        b.built += 1;
        if (b.built > max_values) return error.TooLarge;
        if (node.data == .scalar) return scalarValue(node);
        const entry = try b.open.getOrPut(b.arena, node);
        if (entry.found_existing) return error.Cycle;
        defer _ = b.open.remove(node);
        return switch (node.data) {
            .sequence => |s| .{ .sequence = try b.items(s.items) },
            .mapping => |m| .{ .mapping = try b.pairs(m.pairs) },
            .scalar, .alias => unreachable,
        };
    }

    fn items(b: *Builder, nodes: []const *Node) ValueError![]Value {
        const out = try b.arena.alloc(Value, nodes.len);
        for (out, nodes) |*v, n| v.* = try b.build(n);
        return out;
    }

    fn pairs(b: *Builder, from: []const Node.Pair) ValueError![]Value.Pair {
        const out = try b.arena.alloc(Value.Pair, from.len);
        for (out, from) |*p, pair| p.* = .{ .key = try b.build(pair.key), .value = try b.build(pair.value) };
        return out;
    }
};

fn scalarValue(node: *const Node) Value {
    const text = node.data.scalar.value;
    switch (schema.core(node.tag orelse "") orelse .str) {
        .null => return .null,
        .bool => if (schema.parseBool(text)) |v| return .{ .bool = v },
        .int => if (schema.parseInt(text)) |n| {
            if (std.math.cast(i64, n)) |i| return .{ .integer = i };
            return .{ .number_string = text };
        },
        .float => if (schema.parseFloat(text)) |x| return .{ .float = x },
        .str, .seq, .map => {},
    }
    return .{ .string = text };
}

test "paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(0, (try parsePath(a, ".")).len);
    const p = try parsePath(a, ".servers[1].name.[\"a \\\"b\\\"\"][\"c\"]");
    try std.testing.expectEqualStrings("servers", p[0].key);
    try std.testing.expectEqual(1, p[1].index);
    try std.testing.expectEqualStrings("name", p[2].key);
    try std.testing.expectEqualStrings("a \"b\"", p[3].key);
    try std.testing.expectEqualStrings("c", p[4].key);
    for ([_][]const u8{ "", "name", "..", ".a.", "[x]", "[1", ".[\"a]", "[\"\\n\"]" }) |bad| {
        try std.testing.expectError(error.BadPath, parsePath(a, bad));
    }
}
