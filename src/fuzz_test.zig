//! Fuzz targets: the parser, composition with typed construction, and
//! the emitter. Each draws its input three ways (kb/t2): raw bytes, a
//! corpus entry with a few edits, and YAML built a line at a time from
//! pieces, its indentation drawn at the edges a block's rules turn on.
//! Each checks more than "no panic":
//!
//! - parse: no leak; the events nest (a stream of documents of balanced
//!   collections); there are no more than the input could hold; and an
//!   error's place is inside the input.
//! - construct: composition and building a Value under tight alias and
//!   depth limits fail only as documented; a Value built is written by
//!   stringify and read back the same.
//! - emit: what parses, emitted, reads back to the same documents.
//!
//! `zig build test` replays a fixed set of draws for each; `zig build
//! fuzz --fuzz` fuzzes them.

const std = @import("std");
const yaml = @import("root.zig");
const fuzzing = @import("testing/fuzzing.zig");
const Draw = fuzzing.Draw;
const testing = std.testing;

test "fuzz: parse: any input, events that nest, no leak" {
    try fuzzing.run({}, fuzzParse, 400);
}

test "fuzz: construct: a Value built is stringified and read back the same" {
    try fuzzing.run({}, fuzzConstruct, 300);
}

test "fuzz: emit: what parses, emitted, reads back the same" {
    try fuzzing.run({}, fuzzEmit, 300);
}

// Inputs

/// Entries edits start from: each a feature, or a tricky spot.
const corpus = [_][]const u8{
    "a: 1\nb:\n  - x\n  - y: z\n",
    "- [a, {b: c}, \"d\", 'e']\n- ? k\n  : v\n",
    "%YAML 1.2\n%TAG !e! tag:e.com,2000:\n--- !e!x &a\nk: *a\n...\n",
    "a: |\n  lit\n   more\nb: >-\n  fold\n  ed\n\nc: |2+\n   x\n\n",
    "\"esc \\t \\u00e9 \\x41\": 'it''s'\n",
    "{\"json\":1, \"adj\":[2]}\n",
    "? - a\n  - b\n: - c\n",
    "&x [*x]\n",
    "- a\n\t# tab comment\n-\tb\n",
    "--- a\n--- |\n  b\n...\n# c\n",
    "key:    value\n  continued\nother: \"multi\n  line\"\n",
    ": empty key\n!!null : tagged\n&e : anchored\n",
    "[a, b]: c\n{d: e}: f\n",
    "- !!str\n- !!int 3\n- ! x\n- !<tag:yaml.org,2002:bool> true\n",
    "a: &a\n  - 1\nb: *a\n",
};

/// Pieces lines are built from, and edits insert.
const pieces = [_][]const u8{
    "- ",  "? ",        ": ",       "key: ",     "k:",   "[",      "]",     "{",    "}",
    ", ",  "&a ",       "*a",       "&b ",       "*b",   "!!str ", "!e!x ", "! ",   "!<v> ",
    "'q'", "'a''b'",    "\"d\\n\"", "\"\\x41\"", "|",    ">-",     "|+2",   "# c",  "---",
    "...", "%YAML 1.2", "true",     "~",         "null", "0x1F",   "1.5e3", ".inf", "plain text",
    "\t",  "",          "\"open",   "a#b",       "a #b", "-1",     "?x",    ":y",
    "é",
};

/// Bytes an edit may put in: the ones YAML's rules turn on.
const edit_bytes = " \t\n\r:-#\"'[]{},!&*|>%\\?\x00\xef\xbb\xbf\xc2";

/// Draws an input: raw bytes, a corpus entry edited, or built lines.
fn drawInput(d: *Draw, arena: std.mem.Allocator) ![]const u8 {
    return switch (d.index(3)) {
        0 => {
            const buf = try arena.alloc(u8, 256);
            return d.bytes(buf);
        },
        1 => drawEdited(d, arena),
        else => drawBuilt(d, arena),
    };
}

fn drawEdited(d: *Draw, arena: std.mem.Allocator) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, corpus[d.index(corpus.len)]);
    const edits: usize = d.atMost(u8, 1, 4);
    for (0..edits) |_| {
        const at = d.index(text.items.len + 1);
        switch (d.index(3)) {
            0 => try text.insertSlice(arena, at, d.pick([]const u8, &pieces)),
            1 => if (at < text.items.len) {
                const len = @min(text.items.len - at, @as(usize, d.atMost(u8, 1, 8)));
                text.replaceRangeAssumeCapacity(at, len, &.{});
            },
            else => try text.insert(arena, at, edit_bytes[d.index(edit_bytes.len)]),
        }
    }
    return text.items;
}

/// Lines of pieces, each indented at an edge of the last: the same, one
/// more or less, two more, none, or a tab.
fn drawBuilt(d: *Draw, arena: std.mem.Allocator) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var indent: usize = 0;
    const lines: usize = d.atMost(u8, 1, 10);
    for (0..lines) |_| {
        indent = switch (d.index(6)) {
            0 => indent,
            1 => indent + 1,
            2 => indent -| 1,
            3 => indent + 2,
            4 => 0,
            else => indent,
        };
        if (d.index(8) == 0) try text.append(arena, '\t');
        try text.appendNTimes(arena, ' ', indent);
        const count: usize = d.atMost(u8, 1, 3);
        for (0..count) |_| try text.appendSlice(arena, d.pick([]const u8, &pieces));
        try text.append(arena, '\n');
    }
    return text.items;
}

// Targets

fn fuzzParse(_: void, d: *Draw) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const input = try drawInput(d, arena_state.allocator());
    var parser: yaml.Parser = .init(testing.allocator, input);
    defer parser.deinit();
    var depth: usize = 0;
    var count: usize = 0;
    while (count < 8 * input.len + 64) : (count += 1) {
        const event = parser.next() catch |err| switch (err) {
            error.SyntaxError, error.DepthLimit, error.TagDirectiveLimit => {
                try testing.expect(parser.diagnostic.mark.offset <= input.len);
                try testing.expect(parser.diagnostic.message.len > 0);
                return;
            },
            error.OutOfMemory => return err,
        };
        try checkNesting(event, &depth, count == 0);
        if (event.data == .stream_end) return testing.expectEqual(0, depth);
    }
    return error.TooManyEvents;
}

/// Checks events open and close in order: a stream holds documents, a
/// document one node, and collections balance.
fn checkNesting(event: yaml.Parser.Event, depth: *usize, first: bool) !void {
    try testing.expectEqual(first, event.data == .stream_start);
    switch (event.data) {
        .stream_start => depth.* += 1,
        .document_start => {
            try testing.expectEqual(1, depth.*);
            depth.* += 1;
        },
        .sequence_start, .mapping_start => {
            try testing.expect(depth.* >= 2);
            depth.* += 1;
        },
        .stream_end, .document_end, .sequence_end, .mapping_end => {
            try testing.expect(depth.* >= 1);
            depth.* -= 1;
        },
        .scalar, .alias => try testing.expect(depth.* >= 2),
    }
}

fn fuzzConstruct(_: void, d: *Draw) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try drawInput(d, arena);
    const options: yaml.ParseOptions = .{ .max_alias_nodes = 2_000, .max_depth = 64, .duplicate_keys = if (d.boolean()) .refuse else .keep };
    const parsed = yaml.parseFromSlice(yaml.Value, testing.allocator, input, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // Each a refusal it documents.
        else => return,
    };
    defer parsed.deinit();
    if (hasNan(parsed.value)) return;
    const text = try yaml.stringifyAlloc(testing.allocator, parsed.value, .{ .style = if (d.boolean()) .block else .flow });
    defer testing.allocator.free(text);
    errdefer std.debug.print("input:\n{s}\nstringified:\n{s}\n", .{ input, text });
    const again = try yaml.parseFromSlice(yaml.Value, testing.allocator, text, .{ .max_depth = 64, .duplicate_keys = .keep, .max_alias_nodes = 2_000 });
    defer again.deinit();
    try testing.expectEqualDeep(parsed.value, again.value);
}

/// NaN equals nothing, itself included, so a value holding one cannot be
/// compared with its copy.
fn hasNan(v: yaml.Value) bool {
    return switch (v) {
        .float => |x| std.math.isNan(x),
        .sequence => |items| for (items) |item| {
            if (hasNan(item)) break true;
        } else false,
        .mapping => |pairs| for (pairs) |pair| {
            if (hasNan(pair.key) or hasNan(pair.value)) break true;
        } else false,
        else => false,
    };
}

fn fuzzEmit(_: void, d: *Draw) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try drawInput(d, arena);
    const text = emitAll(arena, input, .{ .width = d.atMost(u8, 8, 80), .indent = d.atMost(u8, 2, 8) }) catch |err| switch (err) {
        error.SyntaxError, error.DepthLimit, error.TagDirectiveLimit => return,
        else => return err,
    };
    errdefer std.debug.print("input:\n{s}\nemitted:\n{s}\n", .{ input, text });
    // The input may not compose (an alias to no anchor): then skip it.
    var original: yaml.Composer = .init(arena, input, .{ .duplicate_keys = .keep });
    var again: yaml.Composer = .init(arena, text, .{ .duplicate_keys = .keep });
    while (true) {
        const a = (original.next() catch return) orelse break;
        const b = (try again.next()).?;
        try expectSameNodes(a.root, b.root);
    }
    try testing.expectEqual(null, try again.next());
}

fn emitAll(arena: std.mem.Allocator, input: []const u8, options: yaml.Emitter.Options) ![]const u8 {
    var parser: yaml.Parser = .init(arena, input);
    var out: std.Io.Writer.Allocating = .init(arena);
    var emitter: yaml.Emitter = .init(arena, &out.writer, options);
    while (true) {
        const event = try parser.next();
        try emitter.emit(event);
        if (event.data == .stream_end) return out.written();
    }
}

fn expectSameNodes(a: *const yaml.Composer.Node, b: *const yaml.Composer.Node) !void {
    try testing.expectEqual(std.meta.activeTag(a.data), std.meta.activeTag(b.data));
    try expectSameText(a.tag, b.tag);
    try expectSameText(a.anchor, b.anchor);
    switch (a.data) {
        .scalar => |s| try testing.expectEqualStrings(s.value, b.data.scalar.value),
        .alias => |target| try expectSameText(target.anchor, b.data.alias.anchor),
        .sequence => |s| {
            try testing.expectEqual(s.items.len, b.data.sequence.items.len);
            for (s.items, b.data.sequence.items) |x, y| try expectSameNodes(x, y);
        },
        .mapping => |m| {
            try testing.expectEqual(m.pairs.len, b.data.mapping.pairs.len);
            for (m.pairs, b.data.mapping.pairs) |x, y| {
                try expectSameNodes(x.key, y.key);
                try expectSameNodes(x.value, y.value);
            }
        },
    }
}

fn expectSameText(a: ?[]const u8, b: ?[]const u8) !void {
    if (a == null or b == null) return testing.expect(a == null and b == null);
    try testing.expectEqualStrings(a.?, b.?);
}
