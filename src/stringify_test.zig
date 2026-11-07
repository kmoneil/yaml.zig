//! Stringify's tests: the text it writes, and that parsing it gives the
//! value back, for every kind of type and for text that reads as other
//! types when plain.

const std = @import("std");
const testing = std.testing;
const yaml = @import("root.zig");

fn expectText(value: anytype, options: yaml.StringifyOptions, expected: []const u8) !void {
    const text = try yaml.stringifyAlloc(testing.allocator, value, options);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

/// Stringifies `value`, parses the text into its type, and checks it is
/// the same value.
fn expectRoundTrip(value: anytype, options: yaml.StringifyOptions) !void {
    const T = @TypeOf(value);
    const text = try yaml.stringifyAlloc(testing.allocator, value, options);
    defer testing.allocator.free(text);
    errdefer std.debug.print("text:\n{s}\n", .{text});
    const parsed = try yaml.parseFromSlice(T, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqualDeep(value, parsed.value);
}

test "the text: block and flow" {
    const S = struct { name: []const u8 = "web", ports: []const u16 = &.{ 80, 443 }, debug: bool = false, ratio: f64 = 1, none: ?u8 = null };
    try expectText(S{}, .{},
        \\name: web
        \\ports:
        \\- 80
        \\- 443
        \\debug: false
        \\ratio: 1.0
        \\none: null
        \\
    );
    try expectText(S{}, .{ .style = .flow, .emit_null_optional_fields = false }, "{name: web, ports: [80, 443], debug: false, ratio: 1.0}\n");
    try expectText("plain", .{}, "plain\n");
    try expectText(@as([]const u8, "true"), .{}, "'true'\n");
}

const Level = enum { debug, info, null, true, @"1" };

const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    ratio: f64,
    level: Level,
    tags: []const []const u8,
    limits: [2]u8,
    owner: ?[]const u8 = null,
    backup: ?*const Config = null,
    pair: struct { u8, []const u8 },
    mode: union(enum) { off, every: u32 },
};

test "round trip: a struct of every kind of field" {
    const spare: Config = .{ .name = "spare", .ratio = 1, .level = .null, .tags = &.{}, .limits = .{ 0, 0 }, .pair = .{ 0, "" }, .mode = .off };
    const config: Config = .{
        .name = "web",
        .ratio = 0.5,
        .level = .true,
        .tags = &.{ "a", "b c", "123", "", "~", "- x", "#y", "multi\nline", " lead" },
        .limits = .{ 1, 2 },
        .owner = "ops",
        .backup = &spare,
        .pair = .{ 7, "seven" },
        .mode = .{ .every = 30 },
    };
    try expectRoundTrip(config, .{});
    try expectRoundTrip(config, .{ .style = .flow });
    try expectRoundTrip(config, .{ .width = 10, .indent = 4 });
    const minimal: Config = .{ .name = "x", .ratio = 2, .level = .@"1", .tags = &.{}, .limits = .{ 0, 0 }, .pair = .{ 0, "" }, .mode = .off };
    try expectRoundTrip(minimal, .{ .emit_null_optional_fields = false });
}

test "round trip: numbers at their edges" {
    try expectRoundTrip([_]i64{ std.math.minInt(i64), -1, 0, std.math.maxInt(i64) }, .{});
    try expectRoundTrip([_]u64{ 0, std.math.maxInt(u64) }, .{});
    // Past an i128 (found by the typed fuzz target, 2^127 into a u128).
    try expectRoundTrip([_]i128{ std.math.minInt(i128), std.math.maxInt(i128) }, .{});
    try expectRoundTrip([_]u128{ 1 << 127, std.math.maxInt(u128) }, .{});
    try expectRoundTrip([_]f64{ 1, -0.5, 1e300, -1e-300, 0.1, std.math.inf(f64), -std.math.inf(f64) }, .{});
    const text = try yaml.stringifyAlloc(testing.allocator, std.math.nan(f64), .{});
    defer testing.allocator.free(text);
    try testing.expect(std.math.isNan(try yaml.parseFromSliceLeaky(f64, testing.allocator, text, .{})));
}

test "a non-exhaustive enum's value with no name is its number" {
    const Open = enum(u8) { a, b, _ };
    try expectText([_]Open{ .b, @fromBackingInt(7) }, .{ .style = .flow }, "[b, 7]\n");
    try expectRoundTrip([_]Open{ .a, @fromBackingInt(7), @fromBackingInt(255) }, .{});
}

/// A command that reads and writes itself: a line for the shell, or a
/// program and its arguments.
const Run = union(enum) {
    shell: []const u8,
    exec: struct { argv: []const []const u8, cwd: ?[]const u8 = null },

    pub fn yamlParse(c: yaml.Construction) yaml.ParseError!Run {
        return switch (c.node.data) {
            .scalar => .{ .shell = try c.build([]const u8, c.node) },
            .mapping => .{ .exec = try c.build(@FieldType(Run, "exec"), c.node) },
            else => c.failExpected(c.node, "a command"),
        };
    }

    pub fn yamlStringify(r: Run, s: *yaml.Stringification) yaml.StringifyError!void {
        switch (r) {
            .shell => |line| try s.write(line),
            .exec => |exec| try s.write(exec),
        }
    }
};

test "a type's own yamlStringify writes it as it is read" {
    const runs = [_]Run{ .{ .shell = "make test" }, .{ .exec = .{ .argv = &.{ "python", "train.py" }, .cwd = "src" } } };
    try expectText(runs, .{ .style = .flow }, "[make test, {argv: [python, train.py], cwd: src}]\n");
    try expectRoundTrip(runs, .{});
    // Through a pointer and an optional, as any value.
    const one: Run = .{ .shell = "true" };
    try expectText(@as(?*const Run, &one), .{}, "'true'\n");
}

test "round trip: strings that read as other things when plain" {
    const texts = [_][]const u8{
        "true",            "False",     "null",        "~",       "",         "123", "-1.5", "0x1F", ".inf",  ".nan",   "1e3",
        "a: b",            "- a",       "? a",         "#a",      "a #b",     "[a]", "{a}",  "&a",   "*a",    "!a",     "|",
        ">",               "'q'",       "\"q\"",       "%a",      "@a",       "`a",  "---",  "...",  " lead", "trail ", "tab\t",
        "line\nbreak",     "\ttab",     "cr\rhere",    "nul\x00", "bell\x07",
        "中文",
        "emoji \u{1F600}", "nel\u{85}", "bom\u{feff}",
    };
    try expectRoundTrip(texts, .{});
    try expectRoundTrip(texts, .{ .style = .flow });
}

test "strings YAML 1.1 reads as other things are quoted, for its readers" {
    // YAML 1.2 reads each as a string plain; PyYAML and other 1.1 readers
    // read them as booleans, numbers, dates and the merge key.
    const typed = [_][]const u8{ "yes", "No", "on", "OFF", "y", "N", "0b101", "1_000", "-1_000.5", "1:20", "190:20:30.15", "2001-12-14", "2001-1-2T10:00:00Z", "2001-12-14 21:59:43", "<<", "=", "-0x1F", "0x_1F" };
    for (typed) |text| {
        const written = try yaml.stringifyAlloc(testing.allocator, text, .{});
        defer testing.allocator.free(written);
        try testing.expectEqual('\'', written[0]);
    }
    try expectRoundTrip(typed, .{});
    // And what neither reads as anything else stays plain.
    const plain = [_][]const u8{ "yesterday", "online", "1:60", "1:2:3:4.5.6", "2001-12", "12001-12-14", "0b102", "a_b", "v1.2.3" };
    for (plain) |text| {
        const written = try yaml.stringifyAlloc(testing.allocator, text, .{});
        defer testing.allocator.free(written);
        try testing.expectEqualStrings(text, written[0 .. written.len - 1]);
    }
}

test "round trip: Value, and std's array hash maps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try yaml.parseFromSliceLeaky(yaml.Value, a, "a: [1, 2.5, true, ~, x, '1']\n? [k]\n: v\nbig: 99999999999999999999\n", .{});
    const text = try yaml.stringifyAlloc(a, value, .{});
    const again = try yaml.parseFromSliceLeaky(yaml.Value, a, text, .{});
    try testing.expectEqualDeep(value, again);

    var map: std.StringArrayHashMapUnmanaged(u32) = .empty;
    try map.put(a, "one", 1);
    try map.put(a, "two", 2);
    const map_text = try yaml.stringifyAlloc(a, map, .{});
    try testing.expectEqualStrings("one: 1\ntwo: 2\n", map_text);
}

test "every allocation may fail, and nothing leaks when one does" {
    const S = struct { a: []const []const u8, b: f64 };
    const run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const text = try yaml.stringifyAlloc(gpa, S{ .a = &.{ "x", "true", "1" }, .b = 1 }, .{});
            gpa.free(text);
            const runs = try yaml.stringifyAlloc(gpa, [_]Run{ .{ .shell = "a b" }, .{ .exec = .{ .argv = &.{"c"} } } }, .{});
            gpa.free(runs);
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{});
}
