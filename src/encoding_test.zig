//! Encoding's tests: each encoding and byte order, with and without a
//! byte order mark, the errors, and byte order marks in the stream.

const std = @import("std");
const testing = std.testing;
const yaml = @import("root.zig");
const encoding = yaml.encoding;

/// `text` in UTF-16 or UTF-32, either byte order, a BOM first if asked.
fn encode(gpa: std.mem.Allocator, text: []const u8, comptime unit: type, big: bool, bom: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const endian: std.builtin.Endian = if (big) .big else .little;
    if (bom) try appendUnit(gpa, &out, unit, 0xFEFF, endian);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (unit == u16 and cp >= 0x10000) {
            const v = cp - 0x10000;
            try appendUnit(gpa, &out, u16, @intCast(0xD800 + (v >> 10)), endian);
            try appendUnit(gpa, &out, u16, @intCast(0xDC00 + (v & 0x3FF)), endian);
        } else try appendUnit(gpa, &out, unit, @intCast(cp), endian);
    }
    return out.toOwnedSlice(gpa);
}

fn appendUnit(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime unit: type, value: unit, endian: std.builtin.Endian) !void {
    var buf: [@sizeOf(unit)]u8 = undefined;
    std.mem.writeInt(unit, &buf, value, endian);
    try out.appendSlice(gpa, &buf);
}

test "detect: every row of the spec's table" {
    try testing.expectEqual(.utf32be, encoding.detect("\x00\x00\xFE\xFFx"));
    try testing.expectEqual(.utf32be, encoding.detect("\x00\x00\x00a"));
    try testing.expectEqual(.utf32le, encoding.detect("\xFF\xFE\x00\x00"));
    try testing.expectEqual(.utf32le, encoding.detect("a\x00\x00\x00"));
    try testing.expectEqual(.utf16be, encoding.detect("\xFE\xFF"));
    try testing.expectEqual(.utf16be, encoding.detect("\x00a"));
    try testing.expectEqual(.utf16le, encoding.detect("\xFF\xFEa\x00"));
    try testing.expectEqual(.utf16le, encoding.detect("a\x00"));
    try testing.expectEqual(.utf8, encoding.detect("\xEF\xBB\xBFa"));
    try testing.expectEqual(.utf8, encoding.detect("a: b"));
    try testing.expectEqual(.utf8, encoding.detect(""));
}

test "UTF-16 and UTF-32 each way round, with and without a BOM, parse as UTF-8 does" {
    const text = "name: Zoë\nemoji: \u{1F600}\nlist: [1, 2]\n";
    const S = struct { name: []const u8, emoji: []const u8, list: []const u32 };
    inline for (.{ u16, u32 }) |unit| {
        for ([_]bool{ false, true }) |big| {
            for ([_]bool{ false, true }) |bom| {
                const bytes = try encode(testing.allocator, text, unit, big, bom);
                defer testing.allocator.free(bytes);
                const parsed = try yaml.parseFromSlice(S, testing.allocator, bytes, .{});
                defer parsed.deinit();
                try testing.expectEqualStrings("Zoë", parsed.value.name);
                try testing.expectEqualStrings("\u{1F600}", parsed.value.emoji);
            }
        }
    }
}

test "toUtf8: UTF-8 is returned as it is" {
    const text = "a: b";
    try testing.expect((try encoding.toUtf8(testing.allocator, text, null)).ptr == text.ptr);
}

test "invalid input in each encoding, with the offset" {
    const cases = [_]struct { []const u8, usize }{
        .{ "a: \xFF\n", 3 },
        .{ "ab\xC3", 2 },
        .{ "a\x00\x00\xD8b\x00", 2 }, // UTF-16LE: a high surrogate, then no low one
        .{ "\x00a\xDC\x00", 2 }, // UTF-16BE: a lone low surrogate
        .{ "a\x00b", 2 }, // UTF-16LE of odd length
        .{ "a\x00\x00\x00\x00\x00\x11\x00", 4 }, // UTF-32LE past U+10FFFF
        .{ "a\x00\x00\x00\x00\xD8\x00\x00", 4 }, // UTF-32LE surrogate
    };
    for (cases) |case| {
        var diagnostic: yaml.Diagnostic = .{};
        errdefer std.debug.print("input: {any}\n", .{case[0]});
        try testing.expectError(error.InvalidEncoding, encoding.toUtf8(testing.allocator, case[0], &diagnostic));
        try testing.expectEqual(case[1], diagnostic.mark.offset);
        var parse_diagnostic: yaml.Diagnostic = .{};
        try testing.expectError(error.InvalidEncoding, yaml.parseFromSliceLeaky(yaml.Value, testing.allocator, case[0], .{ .diagnostic = &parse_diagnostic }));
    }
}

test "the scanner names an encoding it does not read" {
    var s: yaml.Scanner = .init(testing.allocator, "a\x00:\x00");
    defer s.deinit();
    try testing.expectError(error.SyntaxError, s.next());
    try testing.expect(std.mem.indexOf(u8, s.diagnostic.message, "UTF-16") != null);
}

test "byte order marks: at the stream's start and each document's, nowhere else" {
    const ok = [_][]const u8{
        "\xEF\xBB\xBFa: b\n",
        "\xEF\xBB\xBF# comment only\n",
        "--- a\n...\n\xEF\xBB\xBF--- b\n",
        "a\n...\n\xEF\xBB\xBFb\n",
        "\"quoted \xEF\xBB\xBF is any character\"",
    };
    for (ok) |input| {
        errdefer std.debug.print("input: {s}\n", .{input});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var p: yaml.Parser = .init(arena.allocator(), input);
        while ((try p.next()).data != .stream_end) {}
    }
    const bad = [_][]const u8{
        "a: \xEF\xBB\xBFb\n",
        "a:\n  \xEF\xBB\xBFb: c\n",
        "- |\n  text \xEF\xBB\xBF\n",
        "# a comment \xEF\xBB\xBF\n",
        "[\xEF\xBB\xBFa]",
    };
    for (bad) |input| {
        errdefer std.debug.print("input: {s}\n", .{input});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var p: yaml.Parser = .init(arena.allocator(), input);
        const err = while (true) {
            const e = p.next() catch |err| break err;
            if (e.data == .stream_end) break error.TestUnexpectedResult;
        };
        try testing.expectEqual(error.SyntaxError, err);
    }
}

test "characters YAML does not allow, in plain scalars and comments" {
    const bad = [_][]const u8{ "a: b\x7Fc\n", "a: b\u{9F}c\n", "# x\x01\n", "key: value \u{FFFE}\n", "%FOO \x01\n---\n" };
    for (bad) |input| {
        errdefer std.debug.print("input: {any}\n", .{input});
        try testing.expectError(error.SyntaxError, yaml.parseFromSliceLeaky(yaml.Value, testing.allocator, input, .{}));
    }
    // NEL and the rest of Unicode are fine.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseFromSliceLeaky(yaml.Value, arena.allocator(), "a: b\u{85}c \u{4E2D} \u{1F600}\n", .{});
    try testing.expectEqualStrings("b\u{85}c \u{4E2D} \u{1F600}", v.get("a").?.string);
}
