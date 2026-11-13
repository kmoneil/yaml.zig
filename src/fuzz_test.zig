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
//! - typed: building a struct with a field of each kind of type, from
//!   mappings of its field names to values at the edges of those types,
//!   fails only as documented, with no leak, and what it builds is
//!   written by stringify and read back the same.
//! - emit: what parses, emitted, reads back to the same documents.
//! - reader: the reader's events are the parser's, marks and all, as far
//!   as it reads, and where the parser fails the reader has handed over.
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

test "fuzz: typed: a struct of every kind of field built, stringified and read back the same" {
    try fuzzing.run({}, fuzzTyped, 400);
}

test "fuzz: emit: what parses, emitted, reads back the same" {
    try fuzzing.run({}, fuzzEmit, 300);
}

test "fuzz: reader: its events are the parser's, as far as it reads" {
    try fuzzing.run({}, fuzzReader, 400);
}

fn fuzzReader(_: void, d: *Draw) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try drawInput(d, arena);
    const result = try yaml.Reader.compare(testing.allocator, arena, input);
    if (result.problem) |problem| {
        std.debug.print("input:\n{s}\n{s}\n", .{ input, problem });
        return error.ReaderDiffers;
    }
}

// Inputs

/// Entries edits start from: each a feature, or a tricky spot.
const corpus = [_][]const u8{
    "a: 1\nb:\n  - x\n  - y: z\n",
    "- [a, {b: c}, \"d\", 'e']\n- ? k\n  : v\n",
    "%YAML 1.2\n%TAG !e! tag:e.com,2000:\n--- !e!x &a\nk: *a\n...\n",
    "%TAG !e! %5Bt%20%C3%A9:\n--- !e!x [!e!y a]\n",
    "--- |\x00\n  b\n...\n",
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
    "[a: b, ? c : d, : e, [f]: g, &h i: j, *h : l, \"m\":n]\n",
    "{? a, [b]: c, &d e: f, !!str : g, *d : i, {j: k}: l}\n",
    "a: &a {x: 1, <<: {y: 2}}\nb:\n  <<: [*a, &c {z: 3}]\n  x: 4\nc: {<<: *c, \"<<\": 5}\n",
    "&a\n!!str\nx\n---\nk: &b\n !!map\n  c: d\n",
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
    // The state machine alone: the parser's events, from its reader and
    // past the hand-over, and its errors are its own (t76).
    var alone: yaml.Parser = .init(testing.allocator, input);
    alone.use_reader = false;
    defer alone.deinit();
    // Text valid until the next event, its memory reused: each event, as
    // it comes, the same, so no text was reused that was still the
    // caller's (t53).
    var streaming: yaml.Parser = .init(testing.allocator, input);
    streaming.text_lifetime = .next_event;
    defer streaming.deinit();
    var depth: usize = 0;
    var count: usize = 0;
    while (count < 8 * input.len + 64) : (count += 1) {
        const want = alone.next();
        const streamed = streaming.next();
        const event = parser.next() catch |err| switch (err) {
            error.SyntaxError, error.DepthLimit, error.TagDirectiveLimit => {
                try testing.expectError(err, want);
                try testing.expectError(err, streamed);
                try testing.expectEqual(alone.diagnostic.mark, parser.diagnostic.mark);
                try testing.expectEqualStrings(alone.diagnostic.message, parser.diagnostic.message);
                try testing.expect(parser.diagnostic.mark.offset <= input.len);
                try testing.expect(parser.diagnostic.message.len > 0);
                return;
            },
            error.OutOfMemory => return err,
        };
        try testing.expect(yaml.Reader.same(try want, event));
        try testing.expect(yaml.Reader.same(event, try streamed));
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
    // With merge keys or without: a merged Value is a Value as any other,
    // so it too reads back the same.
    const options: yaml.ParseOptions = .{ .max_alias_nodes = 2_000, .max_depth = 64, .duplicate_keys = if (d.boolean()) .refuse else .keep, .merge_keys = d.boolean() };
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

const Level = enum(u8) { a, b, c };
const Open = enum(u8) { a, b, _ };

/// A field of each kind of type construction builds.
const Typed = struct {
    small: i8 = 0,
    byte: u8 = 0,
    long: i64 = 0,
    ulong: u64 = 0,
    huge: i128 = 0,
    uhuge: u128 = 0,
    wide: u256 = 0,
    half: f16 = 0,
    single: f32 = 0,
    double: f64 = 0,
    flag: bool = false,
    level: Level = .a,
    open: Open = .a,
    mode: union(enum) { off, every: u32, name: []const u8 } = .off,
    name: ?[]const u8 = null,
    pair: [2]u8 = .{ 0, 0 },
    tuple: struct { u8, []const u8 } = .{ 0, "" },
    text: [:0]const u8 = "",
    ptr: ?*const u8 = null,
    items: []const i16 = &.{},
    map: yaml.ArrayHashMap(u16) = .{},
    child: ?*const Typed = null,
};

/// Values a field of `Typed` is given: integers at each width's ends and
/// one past, floats that round to those ends, the edges of f16 and f32,
/// and the shapes the other fields take.
const typed_values = [_][]const u8{
    "0",                     "-1",                                      "127",
    "128",                   "-128",                                    "-129",
    "255",                   "256",                                     "0x7F",
    "0o777",                 "1.0",                                     "1.5",
    "-0.0",                  "65504",                                   "65520",
    "3.4e38",                "3.5e38",                                  "1e300",
    ".inf",                  "-.inf",                                   ".nan",
    "9223372036854775807",   "9223372036854775808",                     "-9223372036854775808",
    "-9223372036854775809",  "18446744073709551615",                    "18446744073709551616",
    "9223372036854774784.0", "9223372036854775808.0",                   "-9223372036854777856.0",
    "1.8446744073709552e19", "170141183460469231731687303715884105727", "170141183460469231731687303715884105728",
    "1.7014118346046923e38", "3.402823669209385e38",                    "true",
    "~",                     "",                                        "a",
    "b",                     "z",                                       "off",
    "every",                 "{every: 7}",                              "{name: x}",
    "{off: }",               "[1, 2]",                                  "[1, 2, 3]",
    "[3, x]",                "[]",                                      "{k: 1, j: 65536}",
    "{}",                    "x y",                                     "'7'",
    "!!int foo",             "!!float 2",                               "{byte: 1, child: {long: 2}}",
    "*a",                    "&a 5",                                    "7",
};

/// Whole pairs at the edges a field's type turns on: drawn as a field
/// and a value apart, each would be rare, as one bad pair before it
/// stops the build.
const typed_edges = [_][]const u8{
    "long: 9223372036854775808.0",  "long: 9223372036854774784.0", "long: -9223372036854777856.0",
    "ulong: 1.8446744073709552e19", "ulong: 18446744073709551615", "ulong: -1.0",
    "huge: 1.7014118346046923e38",  "uhuge: 3.402823669209385e38", "byte: 256.0",
    "small: -129.0",                "small: -128.0",               "half: 65520",
    "single: 3.5e38",               "open: 7",                     "open: 255",
    "level: 2",                     "level: 3",                    "items: [32768]",
    "wide: 1.157920892373162e77",   "wide: 9.9e76",                "wide: 115792089237316195423570985008687907853269984665640564039457584007913129639935",
};

/// A mapping of `Typed`'s field names to `typed_values`, or a time in
/// four a pair from `typed_edges`, block or flow; or, a time in four, any
/// input.
fn drawTyped(d: *Draw, arena: std.mem.Allocator) ![]const u8 {
    if (d.index(4) == 0) return drawInput(d, arena);
    const names = @typeInfo(Typed).@"struct".field_names;
    var text: std.ArrayList(u8) = .empty;
    const flow = d.boolean();
    if (flow) try text.append(arena, '{');
    const count: usize = d.atMost(u8, 1, 8);
    for (0..count) |i| {
        if (flow and i > 0) try text.appendSlice(arena, ", ");
        if (d.index(4) == 0) {
            try text.appendSlice(arena, d.pick([]const u8, &typed_edges));
        } else {
            try text.appendSlice(arena, names[d.index(names.len)]);
            try text.appendSlice(arena, ": ");
            try text.appendSlice(arena, d.pick([]const u8, &typed_values));
        }
        if (!flow) try text.append(arena, '\n');
    }
    if (flow) try text.append(arena, '}');
    return text.items;
}

fn fuzzTyped(_: void, d: *Draw) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const input = try drawTyped(d, arena_state.allocator());
    const options: yaml.ParseOptions = .{
        .ignore_unknown_fields = d.boolean(),
        .duplicate_keys = if (d.boolean()) .refuse else .keep,
        .max_alias_nodes = 2_000,
    };
    const parsed = yaml.parseFromSlice(Typed, testing.allocator, input, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // Each a refusal it documents.
        else => return,
    };
    defer parsed.deinit();
    const text = try yaml.stringifyAlloc(testing.allocator, parsed.value, .{ .style = if (d.boolean()) .block else .flow });
    defer testing.allocator.free(text);
    errdefer std.debug.print("input:\n{s}\nstringified:\n{s}\n", .{ input, text });
    const again = try yaml.parseFromSlice(Typed, testing.allocator, text, .{});
    defer again.deinit();
    try expectSameTyped(parsed.value, again.value);
}

/// `expectEqualDeep` but for NaN, equal to itself here, and the map,
/// compared by its keys and values.
fn expectSameTyped(a: Typed, b: Typed) anyerror!void {
    inline for (@typeInfo(Typed).@"struct".field_names) |name| {
        const x = @field(a, name);
        const y = @field(b, name);
        const T = @TypeOf(x);
        if (comptime std.mem.eql(u8, name, "map")) {
            try testing.expectEqualDeep(x.keys(), y.keys());
            try testing.expectEqualDeep(x.values(), y.values());
        } else if (comptime std.mem.eql(u8, name, "child")) {
            if (x == null or y == null) {
                try testing.expect(x == null and y == null);
            } else try expectSameTyped(x.?.*, y.?.*);
        } else if (comptime @typeInfo(T) == .float) {
            if (std.math.isNan(x)) try testing.expect(std.math.isNan(y)) else try testing.expectEqual(x, y);
        } else {
            try testing.expectEqualDeep(x, y);
        }
    }
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
