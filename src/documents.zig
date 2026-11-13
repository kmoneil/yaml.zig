//! Where a stream can be cut between its documents, so the pieces can be
//! read apart, side by side (`parseDocumentsConcurrently`, t77). Not
//! part of the package's API.
//!
//! A line that begins with `---` or `...` and then a blank, a break or
//! the end is a document marker wherever it stands: YAML 1.2.2 lets no
//! scalar or collection hold one (c-forbidden), so no node runs across
//! it, and a reader either ends the document there or fails. The stream
//! is cut before a `---` line when what came since the last cut holds a
//! document, and after a `...` line with nothing but a comment after it;
//! what holds only directives, comments, blank lines and a byte order
//! mark is the next document's prefix and goes with it. Each piece is
//! then a stream of its own that reads as its part of the whole, or
//! fails where the whole does. A cut missed only reads two documents
//! together; a cut made wrong could let pieces read where the whole
//! fails (`... c` and a line after it, found by the documents fuzz
//! target, which holds the pieces to the whole).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mark = @import("Diagnostic.zig").Mark;
const chars = @import("chars.zig");

/// The places `input` can be cut, in order, each at a line's start, 0
/// not among them.
pub fn cuts(gpa: Allocator, input: []const u8) Allocator.Error![]Mark {
    var out: std.ArrayList(Mark) = .empty;
    errdefer out.deinit(gpa);
    // What came since the last cut holds a document: a `---` line, or a
    // line of a node's text.
    var holds_document = false;
    var at: usize = 0;
    var line: u32 = 0;
    while (at < input.len) : (line += 1) {
        const end = chars.findAnyOf(input, at, "\n\r");
        const next = pastBreak(input, end);
        switch (kindOf(input[at..end])) {
            .start => {
                if (holds_document) try out.append(gpa, .{ .offset = @intCast(at), .line = line });
                holds_document = true;
            },
            .end => {
                if (next < input.len) try out.append(gpa, .{ .offset = @intCast(next), .line = line + 1 });
                holds_document = false;
            },
            .prefix => {},
            .content => holds_document = true,
        }
        at = next;
    }
    return out.toOwnedSlice(gpa);
}

/// Where the line whose text ends at `end` is followed: past its break
/// (`\r\n`, `\n` or `\r`), or the end.
fn pastBreak(input: []const u8, end: usize) usize {
    if (end >= input.len) return end;
    if (input[end] == '\r' and end + 1 < input.len and input[end + 1] == '\n') return end + 2;
    return end + 1;
}

const Kind = enum { start, end, prefix, content };

/// What a line is to the cutting: a `---` or `...` marker, what may
/// come before a document (a directive, a comment, a blank line), or
/// anything else, a node's text. A directive or comment inside a
/// document is its text, but changes nothing there.
fn kindOf(text: []const u8) Kind {
    const line = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    if (isMarker(line, "---")) return .start;
    if (isMarker(line, "...")) {
        // Only blanks and a comment may follow it: a document after it
        // on its line, as in `... c`, may run on to the lines below
        // (found by the documents fuzz target).
        const rest = std.mem.trimStart(u8, line[3..], " \t");
        return if (rest.len == 0 or rest[0] == '#') .end else .content;
    }
    if (line.len > 0 and line[0] == '%') return .prefix;
    const rest = std.mem.trimStart(u8, line, " \t");
    if (rest.len == 0 or rest[0] == '#') return .prefix;
    return .content;
}

fn isMarker(line: []const u8, marker: []const u8) bool {
    if (!std.mem.startsWith(u8, line, marker)) return false;
    return line.len == 3 or line[3] == ' ' or line[3] == '\t';
}

/// Where each of about `count` pieces of `input` begins, the first at 0,
/// each at a cut and at least `least` bytes past the last.
pub fn pieces(gpa: Allocator, input: []const u8, count: usize, least: usize) Allocator.Error![]Mark {
    const all = try cuts(gpa, input);
    defer gpa.free(all);
    const size = @max(least, input.len / @max(count, 1));
    var out: std.ArrayList(Mark) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, .{});
    for (all) |cut| {
        if (cut.offset - out.items[out.items.len - 1].offset >= size) try out.append(gpa, cut);
    }
    return out.toOwnedSlice(gpa);
}

fn expectCuts(input: []const u8, comptime want: []const u32) !void {
    const got = try cuts(std.testing.allocator, input);
    defer std.testing.allocator.free(got);
    errdefer std.debug.print("input: {s}\n", .{input});
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |offset, mark| {
        try std.testing.expectEqual(offset, mark.offset);
        try std.testing.expectEqual(0, mark.column);
    }
}

test "cuts: between documents, with their directives, and nowhere else" {
    try expectCuts("a: 1\n", &.{});
    try expectCuts("--- a\n--- b\n", &.{6});
    // A bare document before the first marker is one.
    try expectCuts("a\n--- b\n", &.{2});
    // Directives and comments before a `---` are its document's.
    try expectCuts("%YAML 1.2\n# c\n--- a\n...\n%TAG !e! x\n--- b\n", &.{24});
    try expectCuts("--- a\n...\n--- b\n", &.{10});
    // Markers need a blank, a break or the end after them.
    try expectCuts("--- a\n---x\n...y\n--- b", &.{16});
    // A `...` ends a document only with nothing but a comment after it.
    try expectCuts("--- a\n... # end\nb\n", &.{16});
    try expectCuts("... c\n{d: e}: f\n", &.{});
    // Inside a document a `%` or `#` at a line's start is its text.
    try expectCuts("--- |\n  a\n%b\n#c\n--- d\n", &.{16});
    // Every line break, and a byte order mark before a marker.
    try expectCuts("--- a\r--- b\r\n\xEF\xBB\xBF--- c", &.{ 6, 13 });
    // Their lines.
    const got = try cuts(std.testing.allocator, "a\n\nb\n--- c\n...\nd\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(Mark, &.{ .{ .offset = 5, .line = 3 }, .{ .offset = 15, .line = 5 } }, got);
}

test "pieces: at cuts, at least so far apart" {
    const input = "--- a\n--- b\n--- c\n--- d\n";
    const got = try pieces(std.testing.allocator, input, 2, 10);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqual(0, got[0].offset);
    try std.testing.expectEqual(12, got[1].offset);
}
