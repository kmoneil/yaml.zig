//! The README's suite table: written from the harness's tally, between
//! the lines `<!-- suite -->` and `<!-- /suite -->`, so the counts it
//! shows are never typed by hand. `zig build test` fails when the table
//! is not what the tally makes, and `zig build suite -- readme` writes
//! it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const check = @import("check.zig");

/// The suite's data, as build.zig.zon pins it.
pub const suite_version = "data-2022-01-17";

const open = "<!-- suite -->\n";
const close = "<!-- /suite -->";

fn describe(c: check.Check) []const u8 {
    return switch (c) {
        .events => "the events each valid input parses to",
        .@"error" => "each invalid input refused",
        .json => "each valid input's documents against its in.json",
        .roundtrip => "each valid input emitted and read back the same",
        .reader => "the reader's events are the parser's, as far as it reads",
        .whole => "each valid input the reader reads to its end",
    };
}

/// The table the tally makes, with its closing line.
pub fn table(arena: Allocator, tally: check.Tally) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("| check | cases | passing |\n| --- | ---: | ---: |\n");
    for (std.enums.values(check.Check)) |c| {
        try w.print("| {s}: {s} | {d} | {d} |\n", .{ @tagName(c), describe(c), tally.applied.get(c), tally.passed.get(c) });
    }
    try w.print("\n(yaml-test-suite {s}; written by `zig build suite -- readme`.)\n", .{suite_version});
    return out.written();
}

/// Where the table's text lies in `readme`, between its marker lines.
fn span(readme: []const u8) ?struct { start: usize, end: usize } {
    const start = (std.mem.find(u8, readme, open) orelse return null) + open.len;
    const end = std.mem.findPos(u8, readme, start, close) orelse return null;
    return .{ .start = start, .end = end };
}

/// Null when `readme`'s table is the one `want` is; else what is wrong.
pub fn problem(readme: []const u8, want: []const u8) ?[]const u8 {
    const s = span(readme) orelse return "README.md has no `<!-- suite -->` ... `<!-- /suite -->` block";
    if (std.mem.eql(u8, readme[s.start..s.end], want)) return null;
    return "README.md's suite table is not what the suite gives now: `zig build suite -- readme` writes it";
}

/// `readme` with its table replaced by `want`.
pub fn rewrite(arena: Allocator, readme: []const u8, want: []const u8) ![]const u8 {
    const s = span(readme) orelse return error.NoSuiteBlock;
    return std.mem.concat(arena, u8, &.{ readme[0..s.start], want, readme[s.end..] });
}

const testing = std.testing;

test "a table is checked and rewritten between its markers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = "Intro.\n<!-- suite -->\nold\n<!-- /suite -->\nAfter.\n";
    try testing.expect(problem(doc, "new\n") != null);
    try testing.expectEqual(null, problem(doc, "old\n"));
    const fixed = try rewrite(arena.allocator(), doc, "new\n");
    try testing.expectEqualStrings("Intro.\n<!-- suite -->\nnew\n<!-- /suite -->\nAfter.\n", fixed);
    try testing.expect(problem("no block", "x") != null);
}
