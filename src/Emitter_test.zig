//! The emitter's tests: the text it writes for representative documents,
//! and that what it writes reads back to the same values, tags and
//! anchors for text chosen to be awkward, in each style and place.

const std = @import("std");
const testing = std.testing;
const Emitter = @import("Emitter.zig");
const Parser = @import("Parser.zig");
const Composer = @import("Composer.zig");
const Event = Parser.Event;

/// The text the emitter writes for the events `input` parses to.
fn reemit(gpa: std.mem.Allocator, input: []const u8, options: Emitter.Options) ![]u8 {
    var parser: Parser = .init(gpa, input);
    defer parser.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var emitter: Emitter = .init(gpa, &out.writer, options);
    defer emitter.deinit();
    while (true) {
        const event = try parser.next();
        try emitter.emit(event);
        if (event.data == .stream_end) break;
    }
    return out.toOwnedSlice();
}

/// `text` `n` times over.
fn repeat(comptime text: []const u8, comptime n: usize) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (0..n) |_| out = out ++ text;
        return out;
    }
}

fn expectEmits(input: []const u8, comptime expected: []const u8) !void {
    const got = try reemit(testing.allocator, input, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "block collections, nested, a sequence at its key's column" {
    try expectEmits("a: 1\nb:\n  - x\n  - y: z\n    w: v\nc: {}\nd: []\n",
        \\a: 1
        \\b:
        \\- x
        \\- y: z
        \\  w: v
        \\c: {}
        \\d: []
        \\
    );
}

test "flow collections stay flow" {
    try expectEmits("k: [a, {b: c}, []]\n",
        \\k: [a, {b: c}, []]
        \\
    );
}

test "scalar styles kept where they can be, quoted where not" {
    try expectEmits("- plain\n- 'single'\n- \"double\"\n- \"two\\nlines\"\n- 'it''s'\n- \"tab\\there\"\n- \" lead\"\n",
        \\- plain
        \\- 'single'
        \\- "double"
        \\- "two\nlines"
        \\- 'it''s'
        \\- "tab\there"
        \\- " lead"
        \\
    );
}

test "block scalars: indicators for a leading space, a missing or extra break" {
    try expectEmits("- |\n  text\n- |-\n  no break\n- |+\n  kept\n\n- |2\n    indented\n- >\n  folded\n  text\n",
        \\- |
        \\  text
        \\- |-
        \\  no break
        \\- |+
        \\  kept
        \\
        \\- |2
        \\    indented
        \\- >
        \\  folded text
        \\
    );
    // At the top, the reader counts indentation from -1: content at
    // column 2 is an indicator of 3.
    const got = try reemit(testing.allocator, "--- |1\n   leading spaces\n", .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("--- |3\n     leading spaces\n", got);
}

test "tags, anchors and aliases" {
    try expectEmits("%TAG !e! tag:example.com,2000:\n--- !!map\n&a !e!x k: !local &b v\n? *a\n: !<v:tag> w\nl: !!str\n",
        \\%TAG !e! tag:example.com,2000:
        \\--- !!map
        \\&a !e!x k: &b !local v
        \\*a : !<v:tag> w
        \\l: !!str
        \\
    );
}

test "empty keys and values, marked or not" {
    try expectEmits(": a\n!!null : b\n&x : c\nd:\n",
        \\: a
        \\!!null : b
        \\&x : c
        \\d:
        \\
    );
    // An empty plain item of a flow sequence cannot be nothing.
    try expectEventsEmit(&.{
        .stream_start,
        .{ .document_start = .{ .explicit = false } },
        .{ .sequence_start = .{ .flow = true } },
        plain("a"),
        plain(""),
        plain("b"),
        .sequence_end,
        .{ .document_end = .{ .explicit = false } },
        .stream_end,
    }, "[a, !!null '', b]\n");
}

fn plain(value: []const u8) Event.Data {
    return .{ .scalar = .{ .value = value, .style = .plain } };
}

fn expectEventsEmit(events: []const Event.Data, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var emitter: Emitter = .init(testing.allocator, &out.writer, .{});
    defer emitter.deinit();
    for (events) |data| try emitter.emit(.{ .start = .{}, .end = .{}, .data = data });
    try testing.expectEqualStrings(expected, out.written());
}

test "documents: markers where needed, '...' before another's directives" {
    try expectEmits("a\n--- b\n...\n%YAML 1.2\n--- c\n",
        \\a
        \\--- b
        \\...
        \\%YAML 1.2
        \\--- c
        \\
    );
    try expectEventsEmit(&.{
        .stream_start,
        .{ .document_start = .{ .explicit = true } },
        .{ .sequence_start = .{ .flow = true } },
        plain("a"),
        .sequence_end,
        .{ .document_end = .{ .explicit = false } },
        .{ .document_start = .{ .explicit = true, .version = .{ .major = 1, .minor = 2 } } },
        plain(""),
        .{ .document_end = .{ .explicit = false } },
        .stream_end,
    }, "--- [a]\n...\n%YAML 1.2\n---\n");
    // An empty document needs its marker to be one.
    try expectEmits("---\n",
        \\---
        \\
    );
}

test "a key that does not fit on a line is explicit" {
    const long = comptime repeat("k", 200);
    const got = try reemit(testing.allocator, long ++ ": v\n[a, b]: c\n", .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("? " ++ long ++ "\n: v\n? [a, b]\n: c\n", got);
}

/// Text chosen to be hard to write: indicators, blanks at the edges,
/// breaks, controls, Unicode, and what a schema would read as no string.
const awkward = [_][]const u8{
    "",                           "plain",            "two words",                " leading",
    "trailing ",                  "a: b",             "a #b",                     "#comment",
    "- item",                     "? key",            ":colon",                   "[flow]",
    "{map}",                      "a, b",             "*alias",                   "&anchor",
    "!tag",                       "|block",           ">folded",                  "'single'",
    "\"double\"",                 "%directive",       "@at",                      "`tick",
    "---",                        "...",              "--- x",                    "line\nbreak",
    "\nleading break",            "trailing break\n", "two\n\nbreaks",            "space \nbreak",
    "break\n space",              "tab\there",        "\ttab first",              "control\x01",
    "bell\x07",                   "esc\x1b",          "nel\u{85}",                "bom\u{feff}",
    "ls\u{2028}",
    "中文",
    "emoji \u{1F600}",            "\\backslash",      "123",                      "1.5",
    "true",                       "null",             "~",                        "0x1F",
    ".inf",                       "cr\rhere",         "a" ++ repeat(" word", 30), repeat("very long line ", 10) ++ repeat("\nand another line ", 10),
    // A long line with a tab beside each space (found by fuzzing).
    repeat("word \tword\t ", 10),
};

fn roundTripValue(value: []const u8, style: Parser.ScalarStyle, comptime place: enum { block, flow, key }) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var emitter: Emitter = .init(testing.allocator, &out.writer, .{ .width = 20 });
    defer emitter.deinit();
    const scalar: Event = .{ .start = .{}, .end = .{}, .data = .{ .scalar = .{ .value = value, .style = style } } };
    const other: Event = .{ .start = .{}, .end = .{}, .data = .{ .scalar = .{ .value = "x", .style = .plain } } };
    const events = [_]Event.Data{
        .stream_start,
        .{ .document_start = .{ .explicit = false } },
        .{ .mapping_start = .{ .flow = place == .flow } },
    };
    for (events) |data| try emitter.emit(.{ .start = .{}, .end = .{}, .data = data });
    if (place == .key) {
        try emitter.emit(scalar);
        try emitter.emit(other);
    } else {
        try emitter.emit(other);
        try emitter.emit(scalar);
    }
    const tail = [_]Event.Data{ .mapping_end, .{ .document_end = .{ .explicit = false } }, .stream_end };
    for (tail) |data| try emitter.emit(.{ .start = .{}, .end = .{}, .data = data });

    // Read back: the value and its tag are what the event's were.
    var c: Composer = .init(testing.allocator, out.written(), .{});
    defer c.deinit();
    errdefer std.debug.print("value {any} as {s} in {s}:\n{s}\n", .{ value, @tagName(style), @tagName(place), out.written() });
    const root = (try c.next()).?.root;
    const pair = root.data.mapping.pairs[0];
    const node = if (place == .key) pair.key else pair.value;
    try testing.expectEqualStrings(value, node.data.scalar.value);
    var want: Composer = .init(testing.allocator, "", .{});
    defer want.deinit();
    const want_tag = if (style == .plain) @import("schema.zig").resolvePlain(.core, value).? else @import("schema.zig").tag.str;
    try testing.expectEqualStrings(want_tag, node.tag.?);
}

test "every awkward text, in every style, in a block, a flow and a key, reads back" {
    for (awkward) |value| {
        for (std.enums.values(Parser.ScalarStyle)) |style| {
            try roundTripValue(value, style, .block);
            try roundTripValue(value, style, .flow);
            try roundTripValue(value, style, .key);
        }
    }
}

test "errors: an event out of place, text that is not UTF-8" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var emitter: Emitter = .init(testing.allocator, &out.writer, .{});
    defer emitter.deinit();
    try testing.expectError(error.UnexpectedEvent, emitter.emit(.{ .start = .{}, .end = .{}, .data = plain("before the stream") }));
    var e2: Emitter = .init(testing.allocator, &out.writer, .{});
    defer e2.deinit();
    for ([_]Event.Data{ .stream_start, .{ .document_start = .{ .explicit = false } } }) |data| try e2.emit(.{ .start = .{}, .end = .{}, .data = data });
    try testing.expectError(error.InvalidUtf8, e2.emit(.{ .start = .{}, .end = .{}, .data = .{ .scalar = .{ .value = "\xff", .style = .plain } } }));
}
