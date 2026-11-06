//! The composer's tests: aliases and anchors, cycles, duplicate keys,
//! documents, and depth.

const std = @import("std");
const testing = std.testing;
const Composer = @import("Composer.zig");
const yaml_schema = @import("schema.zig");
const Node = Composer.Node;

/// Composes `input`'s first document; the composer stays alive with it.
fn first(c: *Composer) !*Node {
    return (try c.next()).?.root;
}

fn scalar(node: *const Node) []const u8 {
    return node.target().data.scalar.value;
}

test "a mapping of a sequence and scalars, with marks" {
    var c: Composer = .init(testing.allocator, "a:\n- 1\n- 2\nb: c\n", .{});
    defer c.deinit();
    const root = try first(&c);
    const pairs = root.data.mapping.pairs;
    try testing.expectEqual(2, pairs.len);
    try testing.expectEqualStrings("a", scalar(pairs[0].key));
    try testing.expectEqual(2, pairs[0].value.data.sequence.items.len);
    try testing.expectEqualStrings("2", scalar(pairs[0].value.data.sequence.items[1]));
    try testing.expectEqualStrings("c", scalar(pairs[1].value));
    try testing.expectEqual(0, root.start.offset);
    try testing.expectEqual(3, pairs[1].value.start.line);
    try testing.expectEqual(null, try c.next());
}

test "aliases lead to the node their anchor named, which may be named again" {
    var c: Composer = .init(testing.allocator, "- &a 1\n- *a\n- &a 2\n- *a\n- &m {k: v}\n- *m\n", .{});
    defer c.deinit();
    const items = (try first(&c)).data.sequence.items;
    try testing.expectEqualStrings("a", items[0].anchor.?);
    try testing.expect(items[1].data.alias == items[0]);
    try testing.expectEqualStrings("2", scalar(items[3]));
    try testing.expect(items[3].data.alias == items[2]);
    try testing.expect(items[5].target() == items[4]);
}

test "an alias inside the node its anchor names is a cycle" {
    var c: Composer = .init(testing.allocator, "&a [x, *a]", .{});
    defer c.deinit();
    const root = try first(&c);
    try testing.expect(root.data.sequence.items[1].data.alias == root);
    var c2: Composer = .init(testing.allocator, "&m {self: *m}", .{});
    defer c2.deinit();
    const map = try first(&c2);
    try testing.expect(map.data.mapping.pairs[0].value.target() == map);
}

test "an alias to no anchor, or one in another document" {
    var c: Composer = .init(testing.allocator, "a: *nope\n", .{});
    defer c.deinit();
    try testing.expectError(error.UndefinedAlias, c.next());
    try testing.expectEqual(3, c.diagnostic.mark.column);
    var c2: Composer = .init(testing.allocator, "--- &a 1\n--- *a\n", .{});
    defer c2.deinit();
    _ = try c2.next();
    try testing.expectError(error.UndefinedAlias, c2.next());
}

test "duplicate keys: scalars, collections, through aliases" {
    const duplicates = [_][]const u8{
        "a: 1\nb: 2\na: 3\n",
        "[1, 2]: a\n[1, 2]: b\n",
        "{x: 1, y: 2}: a\n{y: 2, x: 1}: b\n",
        "&k a: 1\n*k : 2\n",
        "!!str a: 1\n!!str a: 2\n",
        "{a: 1, a: 2}",
        // Under the core schema, keys are equal by value.
        "a: 1\n\"a\": 2\n",
        "1: a\n0x1: b\n",
        "~: a\nnull: b\n",
        "true: a\nTrue: b\n",
        "1.5: a\n15e-1: b\n",
        "0.0: a\n-0.0: b\n",
    };
    for (duplicates) |input| {
        var c: Composer = .init(testing.allocator, input, .{});
        defer c.deinit();
        errdefer std.debug.print("input: {s}\n", .{input});
        try testing.expectError(error.DuplicateKey, c.next());
        try testing.expectEqualStrings("a mapping cannot have two equal keys", c.diagnostic.message);
    }
    // A number and a string differ, and so do other tags or contents.
    const distinct = [_][]const u8{
        "1: a\n\"1\": b\n",
        "[1, 2]: a\n[2, 1]: b\n",
        "!!str a: 1\n!!int a: 2\n",
        "{x: 1}: a\n{x: 2}: b\n",
        "1: a\n1.0: b\n",
        ".nan: a\n.NaN: b\n",
    };
    for (distinct) |input| {
        var c: Composer = .init(testing.allocator, input, .{});
        defer c.deinit();
        errdefer std.debug.print("input: {s}\n", .{input});
        _ = try first(&c);
    }
}

test "duplicate keys in a mapping big enough to use the key set, and keeping them" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    for (0..100) |i| try input.print(testing.allocator, "k{d}: v\n", .{i});
    {
        var c: Composer = .init(testing.allocator, input.items, .{});
        defer c.deinit();
        try testing.expectEqual(100, (try first(&c)).data.mapping.pairs.len);
    }
    try input.appendSlice(testing.allocator, "k42: again\n");
    {
        var c: Composer = .init(testing.allocator, input.items, .{});
        defer c.deinit();
        try testing.expectError(error.DuplicateKey, c.next());
        try testing.expectEqual(100, c.diagnostic.mark.line);
    }
    {
        var c: Composer = .init(testing.allocator, input.items, .{ .duplicate_keys = .keep });
        defer c.deinit();
        try testing.expectEqual(101, (try first(&c)).data.mapping.pairs.len);
    }
}

test "tags: resolved by the schema, or as written" {
    const input = "- 1\n- '1'\n- !foo 1\n- ! 1\n- [a]\n- !!set {a}\n- ~\n";
    var c: Composer = .init(testing.allocator, input, .{});
    defer c.deinit();
    const items = (try first(&c)).data.sequence.items;
    const want = [_][]const u8{
        "tag:yaml.org,2002:int", "tag:yaml.org,2002:str", "!foo",                   "tag:yaml.org,2002:str",
        "tag:yaml.org,2002:seq", "tag:yaml.org,2002:set", "tag:yaml.org,2002:null",
    };
    for (items, want) |item, tag| try testing.expectEqualStrings(tag, item.tag.?);
    var failsafe: Composer = .init(testing.allocator, input, .{ .schema = .failsafe });
    defer failsafe.deinit();
    try testing.expectEqualStrings("tag:yaml.org,2002:str", (try first(&failsafe)).data.sequence.items[0].tag.?);
    var json: Composer = .init(testing.allocator, "[1, true, null, word]", .{ .schema = .json });
    defer json.deinit();
    try testing.expectError(error.NotInSchema, json.next());
    try testing.expectEqual(16, json.diagnostic.mark.column);
}

test "a cyclic key costs no more than the budget" {
    var c: Composer = .init(testing.allocator, "? &a [*a, *a]\n: 1\n? &b [*b, *b]\n: 2\n", .{});
    defer c.deinit();
    const root = try first(&c);
    try testing.expectEqual(2, root.data.mapping.pairs.len);
}

test "documents: each its own root, markers and version" {
    var c: Composer = .init(testing.allocator, "%YAML 1.2\n--- a\n...\nb\n", .{});
    defer c.deinit();
    const one = (try c.next()).?;
    try testing.expect(one.explicit_start and one.explicit_end);
    try testing.expectEqual(2, one.version.?.minor);
    try testing.expectEqualStrings("a", scalar(one.root));
    const two = (try c.next()).?;
    try testing.expect(!two.explicit_start and !two.explicit_end);
    try testing.expectEqualStrings("b", scalar(two.root));
    try testing.expectEqual(null, try c.next());
    try testing.expectEqual(null, try c.next());
}

test "a deep document composes without recursion" {
    const depth = 100_000;
    const input = try testing.allocator.alloc(u8, 2 * depth);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');
    var c: Composer = .init(testing.allocator, input, .{ .max_depth = depth + 1 });
    defer c.deinit();
    var node = try first(&c);
    var levels: usize = 1;
    while (node.data.sequence.items.len > 0) : (levels += 1) node = node.data.sequence.items[0];
    try testing.expectEqual(depth, levels);
}

test "the depth limit comes through with its diagnostic" {
    var c: Composer = .init(testing.allocator, "[[[[1]]]]", .{ .max_depth = 2 });
    defer c.deinit();
    try testing.expectError(error.DepthLimit, c.next());
    try testing.expectEqual(2, c.diagnostic.mark.column);
}

test "syntax errors come through with their diagnostic" {
    var c: Composer = .init(testing.allocator, "a: [b", .{});
    defer c.deinit();
    try testing.expectError(error.SyntaxError, c.next());
    try testing.expect(c.diagnostic.message.len > 0);
}

test "after an error, each next gives it again" {
    const cases = .{
        .{ "{a: 1, a: 2, b: [x, y]}\n", error.DuplicateKey, Composer.Options{} },
        .{ "[*nowhere, [x]]\n", error.UndefinedAlias, Composer.Options{} },
        .{ "[x, [y]]\n", error.NotInSchema, Composer.Options{ .schema = .json } },
        .{ "[a, [b, c\n", error.SyntaxError, Composer.Options{} },
        .{ "[[[[1]]], 2]\n", error.DepthLimit, Composer.Options{ .max_depth = 2 } },
    };
    inline for (cases) |case| {
        var c: Composer = .init(testing.allocator, case[0], case[2]);
        defer c.deinit();
        try testing.expectError(case[1], c.next());
        const diagnostic = c.diagnostic;
        try testing.expectError(case[1], c.next());
        try testing.expectError(case[1], c.next());
        try testing.expectEqual(diagnostic.mark, c.diagnostic.mark);
    }
}
