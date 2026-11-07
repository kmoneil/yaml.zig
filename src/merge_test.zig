//! Merge keys' tests (merge.zig): yaml.org's examples read as PyYAML reads
//! them, which keys win, what is refused, and the option off.

const std = @import("std");
const testing = std.testing;
const yaml = @import("root.zig");
const Value = yaml.Value;

const merging: yaml.ParseOptions = .{ .merge_keys = true };

/// Expects `v` a mapping of exactly `expected`'s keys to their integers or
/// strings, in any order.
fn expectPairs(v: Value, expected: anytype) !void {
    try testing.expectEqual(expected.len, v.mapping.len);
    inline for (expected) |e| {
        const got = v.get(e[0]) orelse {
            std.debug.print("no key {s}\n", .{e[0]});
            return error.TestExpectedEqual;
        };
        switch (@TypeOf(e[1])) {
            comptime_int => try testing.expectEqual(@as(i64, e[1]), got.integer),
            else => try testing.expectEqualStrings(e[1], got.string),
        }
    }
}

test "merge keys: yaml.org's examples, every map the same" {
    // yaml.org/type/merge.html, as PyYAML reads it.
    const text =
        \\- &CENTER { x: 1, y: 2 }
        \\- &LEFT { x: 0, y: 2 }
        \\- &BIG { r: 10 }
        \\- &SMALL { r: 1 }
        \\- # Explicit keys
        \\  x: 1
        \\  y: 2
        \\  r: 10
        \\  label: center/big
        \\- # Merge one map
        \\  << : *CENTER
        \\  r: 10
        \\  label: center/big
        \\- # Merge multiple maps
        \\  << : [ *CENTER, *BIG ]
        \\  label: center/big
        \\- # Override
        \\  << : [ *BIG, *LEFT, *SMALL ]
        \\  x: 1
        \\  label: center/big
        \\
    ;
    const parsed = try yaml.parseFromSlice(Value, testing.allocator, text, merging);
    defer parsed.deinit();
    for (parsed.value.sequence[4..]) |map| {
        try expectPairs(map, .{ .{ "x", 1 }, .{ "y", 2 }, .{ "r", 10 }, .{ "label", "center/big" } });
    }
}

test "merge keys: into a struct and a map, the mapping's own keys winning wherever they stand" {
    const Point = struct { x: i64, y: i64, r: i64 = 0, label: []const u8 = "" };
    const Doc = struct { base: yaml.ArrayHashMap(i64), point: Point, env: yaml.ArrayHashMap(i64) };
    const text =
        \\base: &b {x: 1, y: 2, r: 3}
        \\point:
        \\  y: 20
        \\  <<: *b
        \\  label: p
        \\env:
        \\  <<: *b
        \\  x: 10
        \\
    ;
    const parsed = try yaml.parseFromSlice(Doc, testing.allocator, text, merging);
    defer parsed.deinit();
    const p = parsed.value.point;
    try testing.expectEqual(1, p.x);
    try testing.expectEqual(20, p.y);
    try testing.expectEqual(3, p.r);
    try testing.expectEqualStrings("p", p.label);
    const env = parsed.value.env;
    try testing.expectEqual(3, env.count());
    try testing.expectEqual(10, env.get("x").?);
    try testing.expectEqual(2, env.get("y").?);
}

test "merge keys: the earlier of a list wins, and a merged mapping's own merges apply under its keys" {
    const text =
        \\a: &a {k: a, from_a: 1}
        \\b: &b {<<: *a, k: b, from_b: 2}
        \\c: &c {k: c, from_c: 3}
        \\list: {<<: [*c, *b]}
        \\chain: {<<: *b}
        \\
    ;
    const parsed = try yaml.parseFromSlice(Value, testing.allocator, text, merging);
    defer parsed.deinit();
    try expectPairs(parsed.value.get("list").?, .{ .{ "k", "c" }, .{ "from_c", 3 }, .{ "from_b", 2 }, .{ "from_a", 1 } });
    try expectPairs(parsed.value.get("chain").?, .{ .{ "k", "b" }, .{ "from_b", 2 }, .{ "from_a", 1 } });
}

test "merge keys: a mapping named many times over is merged once" {
    // Each level merges the one below it twice: merged again each time, the
    // 40th level would read 2^40 pairs.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "l0: &l0 {k0: 0}\n");
    for (1..40) |i| try text.print(testing.allocator, "l{d}: &l{d} {{<<: [*l{d}, *l{d}], k{d}: {d}}}\n", .{ i, i, i - 1, i - 1, i, i });
    const parsed = try yaml.parseFromSlice(Value, testing.allocator, text.items, merging);
    defer parsed.deinit();
    try testing.expectEqual(40, parsed.value.get("l39").?.mapping.len);
}

test "merge keys: past 16 keys, a merged key is found in a set" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "base: &b {");
    for (0..30) |i| try text.print(testing.allocator, "k{d}: 0, ", .{i});
    try text.appendSlice(testing.allocator, "}\nmine: {<<: *b, ");
    for (10..40) |i| try text.print(testing.allocator, "k{d}: 1, ", .{i});
    try text.appendSlice(testing.allocator, "}\n");
    const parsed = try yaml.parseFromSlice(Value, testing.allocator, text.items, merging);
    defer parsed.deinit();
    const mine = parsed.value.get("mine").?;
    try testing.expectEqual(40, mine.mapping.len);
    try testing.expectEqual(0, mine.get("k5").?.integer);
    try testing.expectEqual(1, mine.get("k15").?.integer);
}

test "merge keys: off, a quoted <<, and the tags it takes" {
    const text = "base: &b {x: 1}\nm: {<<: *b, y: 2}\n";
    // Off by default: `<<` is a key as any other.
    const off = try yaml.parseFromSlice(Value, testing.allocator, text, .{});
    defer off.deinit();
    try testing.expectEqual(1, off.value.get("m").?.get("<<").?.get("x").?.integer);
    try testing.expectEqual(null, off.value.get("m").?.get("x"));
    // Quoted, a string.
    const quoted = try yaml.parseFromSlice(Value, testing.allocator, "base: &b {x: 1}\nm: {\"<<\": *b}\n", merging);
    defer quoted.deinit();
    try testing.expect(quoted.value.get("m").?.get("<<") != null);
    // `!!merge`, YAML 1.1's own tag for it, merges.
    const tagged = try yaml.parseFromSlice(Value, testing.allocator, "base: &b {x: 1}\nm: {!!merge <<: *b}\n", merging);
    defer tagged.deinit();
    try testing.expectEqual(1, tagged.value.get("m").?.get("x").?.integer);
}

test "merge keys: what cannot be merged, cycles and depth are refused where they are" {
    const cases = [_]struct { []const u8, anyerror, []const u8 }{
        .{ "m: {<<: 3}\n", error.UnexpectedType, "1:9: m: expected a mapping, or a sequence of mappings, to merge, found the integer 3" },
        .{ "a: &a {x: 1}\nm: {<<: [*a, [1]]}\n", error.UnexpectedType, "2:14: m: expected a mapping, or a sequence of mappings, to merge, found a sequence" },
        .{ "m: &m {<<: *m}\n", error.Cycle, "1:12: m: a merge names a mapping it is merged into: a cycle no value can hold" },
    };
    for (cases) |case| {
        errdefer std.debug.print("input: {s}\n", .{case[0]});
        var diagnostic: yaml.Diagnostic = .{};
        var options = merging;
        options.diagnostic = &diagnostic;
        try testing.expectError(case[1], yaml.parseFromSlice(Value, testing.allocator, case[0], options));
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{f}", .{diagnostic});
        try testing.expectEqualStrings(case[2], w.buffered());
    }
    // A chain of merges deeper than max_depth.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "l0: &l0 {k: 0}\n");
    for (1..8) |i| try text.print(testing.allocator, "l{d}: &l{d} {{<<: *l{d}}}\n", .{ i, i, i - 1 });
    var shallow = merging;
    shallow.max_depth = 4;
    try testing.expectError(error.DepthLimit, yaml.parseFromSlice(Value, testing.allocator, text.items, shallow));
}

test "merge keys: an own key equal to a merged one is no duplicate" {
    const parsed = try yaml.parseFromSlice(Value, testing.allocator, "b: &b {x: 1}\nm: {<<: *b, x: 2}\n", merging);
    defer parsed.deinit();
    try testing.expectEqual(2, parsed.value.get("m").?.get("x").?.integer);
}
