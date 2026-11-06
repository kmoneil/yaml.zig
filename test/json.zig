//! The json check: a case's documents, composed under the core schema,
//! are the JSON documents its `in.json` holds, compared as trees. A null,
//! a boolean, a number (by value: YAML's `12e03` is JSON's `12000`), a
//! string by its tag; a sequence item by item; a mapping key by key, a
//! key as its text, in any order (a JSON object has none, and in.json
//! does not always keep the document's: RR7F). Aliases are followed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const Node = yaml.Composer.Node;
const tag = yaml.schema.tag;

/// What differs between `input`'s documents and `json`'s, or null when
/// nothing does. Composes on an allocator that checks for leaks.
pub fn compare(arena: Allocator, input: []const u8, json: []const u8) !?[]const u8 {
    const want = try parseDocuments(arena, json) orelse return "in.json does not parse as JSON";
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const problem = problem: {
        var composer: yaml.Composer = .init(debug.allocator(), input, .{});
        defer composer.deinit();
        break :problem try compareDocuments(arena, &composer, want);
    };
    if (debug.deinit() == .leak) return "leaked memory (the allocator printed where it was allocated)";
    return problem;
}

fn compareDocuments(arena: Allocator, composer: *yaml.Composer, want: []const std.json.Value) !?[]const u8 {
    var path: std.ArrayList(u8) = .empty;
    for (want, 0..) |value, i| {
        const document = composer.next() catch |err| {
            const d = composer.diagnostic;
            return try std.fmt.allocPrint(arena, "document {d}: {s} at {d}:{d}: {s}", .{ i + 1, @errorName(err), d.mark.line + 1, d.mark.column + 1, d.message });
        } orelse return try std.fmt.allocPrint(arena, "{d} documents, where in.json has {d}", .{ i, want.len });
        path.clearRetainingCapacity();
        try path.print(arena, "document {d}: $", .{i + 1});
        if (try compareNode(arena, document.root, value, &path)) |problem| return problem;
    }
    const extra = composer.next() catch return "an error after the documents in.json has";
    if (extra != null) return try std.fmt.allocPrint(arena, "more documents than the {d} in.json has", .{want.len});
    return null;
}

fn compareNode(arena: Allocator, node: *const Node, want: std.json.Value, path: *std.ArrayList(u8)) Allocator.Error!?[]const u8 {
    const n = node.target();
    return switch (n.data) {
        .scalar => |s| if (scalarMatches(n.tag.?, s.value, want)) null else differ(arena, path, "a scalar `{s}` ({s})", .{ s.value, n.tag.? }, want),
        .sequence => |s| compareItems(arena, s.items, want, path),
        .mapping => |m| comparePairs(arena, m.pairs, want, path),
        .alias => unreachable,
    };
}

fn compareItems(arena: Allocator, items: []const *Node, want: std.json.Value, path: *std.ArrayList(u8)) Allocator.Error!?[]const u8 {
    if (want != .array or want.array.items.len != items.len) return differ(arena, path, "a sequence of {d}", .{items.len}, want);
    const len = path.items.len;
    for (items, want.array.items, 0..) |item, value, i| {
        try path.print(arena, "[{d}]", .{i});
        if (try compareNode(arena, item, value, path)) |problem| return problem;
        path.shrinkRetainingCapacity(len);
    }
    return null;
}

fn comparePairs(arena: Allocator, pairs: []const Node.Pair, want: std.json.Value, path: *std.ArrayList(u8)) Allocator.Error!?[]const u8 {
    if (want != .object or want.object.count() != pairs.len) return differ(arena, path, "a mapping of {d}", .{pairs.len}, want);
    const len = path.items.len;
    for (pairs) |pair| {
        const key = keyText(pair.key);
        try path.print(arena, ".{s}", .{key});
        const value = want.object.get(key) orelse return try std.fmt.allocPrint(arena, "{s}: in.json has no such key", .{path.items});
        if (try compareNode(arena, pair.value, value, path)) |problem| return problem;
        path.shrinkRetainingCapacity(len);
    }
    return null;
}

/// A key as JSON writes it: a scalar's text.
fn keyText(key: *const Node) []const u8 {
    const n = key.target();
    return if (n.data == .scalar) n.data.scalar.value else "(a collection)";
}

fn scalarMatches(scalar_tag: []const u8, value: []const u8, want: std.json.Value) bool {
    if (std.mem.eql(u8, scalar_tag, tag.null)) return want == .null;
    if (std.mem.eql(u8, scalar_tag, tag.bool)) return want == .bool and yaml.schema.parseBool(value) == want.bool;
    if (std.mem.eql(u8, scalar_tag, tag.int)) {
        const n = yaml.schema.parseInt(value) orelse return false;
        return switch (want) {
            .integer => |i| n == i,
            .float => |f| @as(f64, @floatFromInt(n)) == f,
            else => false,
        };
    }
    if (std.mem.eql(u8, scalar_tag, tag.float)) {
        const x = yaml.schema.parseFloat(value) orelse return false;
        return switch (want) {
            .integer => |i| x == @as(f64, @floatFromInt(i)),
            .float => |f| x == f,
            else => false,
        };
    }
    return want == .string and std.mem.eql(u8, want.string, value);
}

fn differ(arena: Allocator, path: *const std.ArrayList(u8), comptime got: []const u8, args: anytype, want: std.json.Value) Allocator.Error!?[]const u8 {
    const json = std.json.Stringify.valueAlloc(arena, want, .{}) catch "(unprintable)";
    const shown = if (json.len > 60) json[0..60] else json;
    const message: []const u8 = try std.fmt.allocPrint(arena, "{s}: got " ++ got ++ ", want {s}", .{path.items} ++ args ++ .{shown});
    return message;
}

/// The JSON documents `text` holds one after another, or null when one
/// does not parse.
pub fn parseDocuments(arena: Allocator, text: []const u8) !?[]const std.json.Value {
    var documents: std.ArrayList(std.json.Value) = .empty;
    var at: usize = 0;
    while (nextDocument(text, &at)) |document| {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, document, .{}) catch return null;
        try documents.append(arena, value);
    }
    return documents.items;
}

/// The next whole JSON value in `text` from `at`, which it moves past.
fn nextDocument(text: []const u8, at: *usize) ?[]const u8 {
    while (at.* < text.len and std.ascii.isWhitespace(text[at.*])) at.* += 1;
    if (at.* == text.len) return null;
    const start = at.*;
    at.* = switch (text[start]) {
        '{', '[' => endOfCollection(text, start),
        '"' => endOfString(text, start),
        else => std.mem.indexOfAnyPos(u8, text, start, " \t\r\n") orelse text.len,
    };
    return text[start..at.*];
}

fn endOfString(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len and text[i] != '"') : (i += 1) {
        if (text[i] == '\\') i += 1;
    }
    return @min(i + 1, text.len);
}

fn endOfCollection(text: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i < text.len) {
        switch (text[i]) {
            '"' => {
                i = endOfString(text, i);
                continue;
            },
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return text.len;
}

const testing = std.testing;

test "parseDocuments: one after another, of each kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const docs = (try parseDocuments(arena.allocator(), "null\n\"a\\\"]\" {\"k\": [1, \"}\"]}\n12\n[]")).?;
    try testing.expectEqual(5, docs.len);
    try testing.expectEqualStrings("a\"]", docs[1].string);
    try testing.expectEqual(12, docs[3].integer);
    try testing.expectEqual(null, try parseDocuments(arena.allocator(), "{oops}"));
}

test "compare: equal trees, numbers by value, and a difference named by its path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try compare(a, "a: [1, 12e03, true, ~, x]\nb: &r {c: d}\ne: *r\n", "{\"a\": [1, 12000, true, null, \"x\"], \"b\": {\"c\": \"d\"}, \"e\": {\"c\": \"d\"}}"));
    try testing.expectEqual(null, try compare(a, "--- 1\n--- 2\n", "1\n2\n"));
    try testing.expectEqualStrings(
        "document 1: $.a[1]: got a scalar `2` (tag:yaml.org,2002:int), want \"2\"",
        (try compare(a, "a: [1, 2]", "{\"a\": [1, \"2\"]}")).?,
    );
    try testing.expectEqualStrings("document 1: $.a: in.json has no such key", (try compare(a, "a: 1", "{\"b\": 1}")).?);
    try testing.expectEqual(null, try compare(a, "a: 1\nb: 2", "{\"b\": 2, \"a\": 1}"));
    try testing.expectEqualStrings("more documents than the 1 in.json has", (try compare(a, "--- 1\n--- 2\n", "1")).?);
}
