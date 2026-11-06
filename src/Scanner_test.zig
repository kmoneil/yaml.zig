//! The scanner's tests: token streams for the core of YAML's syntax
//! (block structure, simple keys, documents, comments, plain scalars),
//! the marks tokens carry, and the errors the core reports.
//!
//! `expectTokens` writes a token a line: `+STR` and `-STR` the stream,
//! `+DOC` `---` and `-DOC` `...`, `+SEQ` and `+MAP` a block collection
//! opening and `-BLK` one ending, `[ ] { }` flow collections, `-` a block
//! entry, `,` a flow entry, `?` a key, `:` a value, and `=` a plain
//! scalar followed by its value, with a line feed written `\n` and a
//! tab `\t`.

const std = @import("std");
const testing = std.testing;
const Scanner = @import("Scanner.zig");

fn dump(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var s: Scanner = .init(gpa, input);
    defer s.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    while (true) {
        const token = s.next() catch |err| switch (err) {
            error.SyntaxError => {
                try out.writer.print("ERROR {d}:{d} {s}\n", .{ s.diagnostic.mark.line + 1, s.diagnostic.mark.column + 1, s.diagnostic.message });
                break;
            },
            else => return err,
        };
        try writeToken(&out.writer, token);
        if (token.data == .stream_end) break;
    }
    return out.toOwnedSlice();
}

fn writeToken(w: *std.Io.Writer, token: Scanner.Token) !void {
    switch (token.data) {
        .scalar => |scalar| {
            try w.writeAll(switch (scalar.style) {
                .plain => "=",
                .single_quoted => "'",
                .double_quoted => "\"",
                .literal => "|",
                .folded => ">",
            });
            for (scalar.value) |c| switch (c) {
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            };
        },
        .alias => |name| try w.print("*{s}", .{name}),
        .anchor => |name| try w.print("&{s}", .{name}),
        .tag => |tag| try w.print("!{s}{s}", .{ tag.handle, tag.suffix }),
        .version_directive => |v| try w.print("%YAML {d}.{d}", .{ v.major, v.minor }),
        .tag_directive => |d| try w.print("%TAG {s} {s}", .{ d.handle, d.prefix }),
        else => try w.writeAll(switch (token.data) {
            .stream_start => "+STR",
            .stream_end => "-STR",
            .document_start => "+DOC",
            .document_end => "-DOC",
            .block_sequence_start => "+SEQ",
            .block_mapping_start => "+MAP",
            .block_end => "-BLK",
            .flow_sequence_start => "[",
            .flow_sequence_end => "]",
            .flow_mapping_start => "{",
            .flow_mapping_end => "}",
            .block_entry => "-",
            .flow_entry => ",",
            .key => "?",
            .value => ":",
            else => unreachable,
        }),
    }
    try w.writeByte('\n');
}

fn expectTokens(input: []const u8, comptime expected: []const u8) !void {
    const got = try dump(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected ++ "\n", got);
}

test "empty input: the stream alone" {
    try expectTokens("",
        \\+STR
        \\-STR
    );
    try expectTokens("# only a comment\n\n",
        \\+STR
        \\-STR
    );
}

test "a plain scalar alone" {
    try expectTokens("hello world",
        \\+STR
        \\=hello world
        \\-STR
    );
}

test "a block mapping: the key token put before its scalar" {
    try expectTokens("a: 1\nb: 2\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=1
        \\?
        \\=b
        \\:
        \\=2
        \\-BLK
        \\-STR
    );
}

test "nested block mappings close as the indentation falls" {
    try expectTokens(
        \\a:
        \\  b:
        \\    c: 1
        \\  d: 2
        \\e: 3
    ,
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\+MAP
        \\?
        \\=b
        \\:
        \\+MAP
        \\?
        \\=c
        \\:
        \\=1
        \\-BLK
        \\?
        \\=d
        \\:
        \\=2
        \\-BLK
        \\?
        \\=e
        \\:
        \\=3
        \\-BLK
        \\-STR
    );
}

test "a block sequence, and a sequence as a mapping's value at the same indentation" {
    try expectTokens("- a\n- b\n",
        \\+STR
        \\+SEQ
        \\-
        \\=a
        \\-
        \\=b
        \\-BLK
        \\-STR
    );
    // A sequence may sit at its key's indentation: no `+SEQ`, since the
    // mapping's indentation is not passed.
    try expectTokens("k:\n- a\n",
        \\+STR
        \\+MAP
        \\?
        \\=k
        \\:
        \\-
        \\=a
        \\-BLK
        \\-STR
    );
}

test "compact nested collections" {
    try expectTokens("- - a\n  - b\n- k: v\n  j: w\n",
        \\+STR
        \\+SEQ
        \\-
        \\+SEQ
        \\-
        \\=a
        \\-
        \\=b
        \\-BLK
        \\-
        \\+MAP
        \\?
        \\=k
        \\:
        \\=v
        \\?
        \\=j
        \\:
        \\=w
        \\-BLK
        \\-BLK
        \\-STR
    );
}

test "explicit keys" {
    try expectTokens("? a\n: b\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=b
        \\-BLK
        \\-STR
    );
}

test "documents: markers, and blocks closed at each" {
    try expectTokens("--- a\n...\n---\nb: c\n--- d\n",
        \\+STR
        \\+DOC
        \\=a
        \\-DOC
        \\+DOC
        \\+MAP
        \\?
        \\=b
        \\:
        \\=c
        \\-BLK
        \\+DOC
        \\=d
        \\-STR
    );
    // A marker needs a blank or the end after it.
    try expectTokens("---word\n",
        \\+STR
        \\=---word
        \\-STR
    );
}

test "comments, and # that is part of a scalar" {
    try expectTokens("# top\na: b # end\n# between\nc: d#e\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=b
        \\?
        \\=c
        \\:
        \\=d#e
        \\-BLK
        \\-STR
    );
}

test "plain scalars: indicators inside, and : without a space after" {
    try expectTokens("- -a\n- ?b\n- :c\n- a:b\n- http://x.y/z\n",
        \\+STR
        \\+SEQ
        \\-
        \\=-a
        \\-
        \\=?b
        \\-
        \\=:c
        \\-
        \\=a:b
        \\-
        \\=http://x.y/z
        \\-BLK
        \\-STR
    );
}

test "multi-line plain scalars fold: one break a space, more kept" {
    try expectTokens("a: one\n  two  \n\n  three\n\n\n  four\nb: x\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=one two\nthree\n\nfour
        \\?
        \\=b
        \\:
        \\=x
        \\-BLK
        \\-STR
    );
}

test "line breaks: CRLF and CR read as LF" {
    try expectTokens("a: 1\r\nb:\r\n  two\r\n  lines\rc: 3",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=1
        \\?
        \\=b
        \\:
        \\=two lines
        \\?
        \\=c
        \\:
        \\=3
        \\-BLK
        \\-STR
    );
}

test "a byte order mark opens the stream" {
    try expectTokens("\xEF\xBB\xBFa",
        \\+STR
        \\=a
        \\-STR
    );
}

test "flow collections: tokens, and simple keys inside" {
    try expectTokens("[a, b]: {c: d}\n",
        \\+STR
        \\+MAP
        \\?
        \\[
        \\=a
        \\,
        \\=b
        \\]
        \\:
        \\{
        \\?
        \\=c
        \\:
        \\=d
        \\}
        \\-BLK
        \\-STR
    );
}

test "tabs: separation, not indentation" {
    // After the indentation, and on a line of its own, a tab is fine.
    try expectTokens("a:\t1\nb:\n \tc\n\t\n\t# note\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=1
        \\?
        \\=b
        \\:
        \\=c
        \\-BLK
        \\-STR
    );
    // A flow collection may follow a tab at the start of a line.
    try expectTokens("\t[]",
        \\+STR
        \\[
        \\]
        \\-STR
    );
    try expectTokens("a:\n\tb: c\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\ERROR 2:2 a tab character cannot indent a block
    );
    try expectTokens("a:\n  b: 1\n  \tc: 2\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\+MAP
        \\?
        \\=b
        \\:
        \\ERROR 3:4 a tab character cannot indent a block
    );
}

test "tabs: none before a token that opens a block collection (suite Y79Y, 6BCT)" {
    const opens = [_][]const u8{ "-\t-", "- \t-", "?\t-", "? -\n:\t-", "?\tkey:", "? key:\n:\tkey:", "\tkey: v" };
    for (opens) |input| {
        const got = try dump(testing.allocator, input);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ input, got });
        try testing.expect(std.mem.endsWith(u8, got, "a tab character cannot indent a block collection\n"));
    }
    // A tab before a scalar is separation, and so is one after a key.
    try expectTokens("-\t-1\n- foo:\t bar\n- - baz\n  -\tbaz\n",
        \\+STR
        \\+SEQ
        \\-
        \\=-1
        \\-
        \\+MAP
        \\?
        \\=foo
        \\:
        \\=bar
        \\-BLK
        \\-
        \\+SEQ
        \\-
        \\=baz
        \\-
        \\=baz
        \\-BLK
        \\-BLK
        \\-STR
    );
}

test "errors: a key with no :, a value where none may be, a comment glued on" {
    try expectTokens("a: 1\nb\nc: 2\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=1
        \\ERROR 2:1 could not find the ':' this key needs
    );
    try expectTokens("a: b: c\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\=b
        \\ERROR 1:5 a mapping value is not allowed here
    );
    // `[a]` may still be a key when the error comes, so none of it is out.
    try expectTokens("[a]#c\n",
        \\+STR
        \\ERROR 1:4 a comment must be separated from what comes before it by whitespace
    );
    try expectTokens("a: \x01\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\ERROR 1:4 found a character that is not allowed in YAML
    );
}

test "an implicit key is one line and at most 1024 characters" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, 1025 + 3);
    defer gpa.free(long);
    @memset(long[0..1025], 'k');
    @memcpy(long[1025..], ": v");
    const got = try dump(gpa, long);
    defer gpa.free(got);
    try testing.expect(std.mem.find(u8, got, "ERROR") != null);
    // 1024 is allowed.
    const got_ok = try dump(gpa, long[1..]);
    defer gpa.free(got_ok);
    try testing.expect(std.mem.startsWith(u8, got_ok, "+STR\n+MAP\n?\n"));

    // Two lines are a plain scalar, and no key.
    try expectTokens("a\nb: c\n",
        \\+STR
        \\=a b
        \\ERROR 2:2 a mapping value is not allowed here
    );
}

test "marks: offsets, lines and columns, columns in characters" {
    var s: Scanner = .init(testing.allocator, "é: x\n- y");
    defer s.deinit();
    const want = [_]struct { Scanner.Mark, Scanner.Mark }{
        .{ .{}, .{} }, // +STR
        .{ .{}, .{} }, // +MAP
        .{ .{}, .{} }, // ?
        .{ .{}, .{ .offset = 2, .column = 1 } }, // =é
        .{ .{ .offset = 2, .column = 1 }, .{ .offset = 3, .column = 2 } }, // :
        .{ .{ .offset = 4, .column = 3 }, .{ .offset = 5, .column = 4 } }, // =x
    };
    for (want) |marks| {
        const token = try s.next();
        try testing.expectEqualDeep(marks[0], token.start);
        try testing.expectEqualDeep(marks[1], token.end);
    }
    // `-` at the mapping's own column opens no sequence; the parser
    // reports it.
    const entry = try s.next();
    try testing.expectEqual(.block_entry, std.meta.activeTag(entry.data));
    try testing.expectEqualDeep(Scanner.Mark{ .offset = 6, .line = 1, .column = 0 }, entry.start);
}

test "depth: flow and block collections count toward max_depth" {
    const cases = [_]struct { []const u8, usize }{
        .{ "[[[[x]]]]", 3 },
        .{ "a:\n b:\n  c:\n   d: x\n", 3 },
        // The sequence, `[` and `{` are three: the second `[` is a fourth.
        .{ "- [{a: [x]}]", 7 },
    };
    for (cases) |case| {
        var s: Scanner = .init(testing.allocator, case[0]);
        defer s.deinit();
        s.max_depth = 3;
        const err = while (true) {
            const token = s.next() catch |err| break err;
            if (token.data == .stream_end) break error.TestUnexpectedResult;
        };
        try testing.expectEqual(error.DepthLimit, err);
        try testing.expectEqual(case[1], s.diagnostic.mark.column);
        try testing.expectEqualStrings("collections nest deeper than max_depth", s.diagnostic.message);
    }
    // At the limit, not past it.
    var s: Scanner = .init(testing.allocator, "[[[x]]]");
    defer s.deinit();
    s.max_depth = 3;
    while ((try s.next()).data != .stream_end) {}
}

test "a flow mapping left open ends at the input's end (found by fuzzing)" {
    const inputs = [_][]const u8{ "{[\na#b\n", "{a", "{[", "{\"a\"", "{ a\n b", "[{a", "{{{" };
    for (inputs) |input| {
        var s: Scanner = .init(testing.allocator, input);
        defer s.deinit();
        var count: usize = 0;
        while (count < 100) : (count += 1) {
            const token = s.next() catch break;
            if (token.data == .stream_end) break;
        }
        errdefer std.debug.print("input: {s}\n", .{input});
        try testing.expect(count < 100);
    }
    // The parser reports the collection left open.
    var p: @import("Parser.zig") = .init(testing.allocator, "{[\na#b\n");
    defer p.deinit();
    const err = while (true) {
        const e = p.next() catch |err| break err;
        if (e.data == .stream_end) break error.TestUnexpectedResult;
    };
    try testing.expectEqual(error.SyntaxError, err);
}

test "next after the end gives the end again" {
    var s: Scanner = .init(testing.allocator, "a");
    defer s.deinit();
    while ((try s.next()).data != .stream_end) {}
    try testing.expectEqual(.stream_end, std.meta.activeTag((try s.next()).data));
}

test "single-quoted: '' is a quote, lines fold" {
    try expectTokens("'it''s'",
        \\+STR
        \\'it's
        \\-STR
    );
    try expectTokens("' 1st non-empty\n\n 2nd non-empty \n\t3rd non-empty '",
        \\+STR
        \\' 1st non-empty\n2nd non-empty 3rd non-empty 
        \\-STR
    );
    try expectTokens("'a # not a comment' : 'b'",
        \\+STR
        \\+MAP
        \\?
        \\'a # not a comment
        \\:
        \\'b
        \\-BLK
        \\-STR
    );
}

test "double-quoted: every escape" {
    const got = try dump(testing.allocator, "\"\\0\\a\\b\\t\\\t\\n\\v\\f\\r\\e\\ \\\"\\/\\\\\\N\\_\\L\\P\\x41\\u00e9\\U0001F600\"");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("+STR\n\"\x00\x07\x08\\t\\t\\n\x0B\x0C\r\x1B \"/\\\u{85}\u{A0}\u{2028}\u{2029}A\u{e9}\u{1F600}\n-STR\n", got);
}

test "double-quoted: folding, escaped line breaks, blanks kept before them" {
    try expectTokens("\"folded \nto a space,\t\n \nto a line feed, or \t\\\n \\ \tnon-content\"",
        \\+STR
        \\"folded to a space,\nto a line feed, or \t \tnon-content
        \\-STR
    );
    // An escaped tab stays at the end of a line; a plain one is dropped.
    try expectTokens("\"3 trailing\\\t\n    tab\"",
        \\+STR
        \\"3 trailing\t tab
        \\-STR
    );
    // After an escaped break, an empty line is a line feed.
    try expectTokens("\"a\\\n\n  b\"",
        \\+STR
        \\"a\nb
        \\-STR
    );
}

test "quoted scalars as keys, values and entries; their marks" {
    try expectTokens("\"k\": 'v'\n- x",
        \\+STR
        \\+MAP
        \\?
        \\"k
        \\:
        \\'v
        \\-
        \\=x
        \\-BLK
        \\-STR
    );
    var s: Scanner = .init(testing.allocator, "\"é\\n\"");
    defer s.deinit();
    _ = try s.next();
    const token = try s.next();
    try testing.expectEqualDeep(Scanner.Mark{}, token.start);
    try testing.expectEqualDeep(Scanner.Mark{ .offset = 6, .column = 5 }, token.end);
}

test "quoted scalar errors (suite 55WF, QB6E, 5TRB, RXY3, DK95/01)" {
    try expectTokens("\"\\.\"",
        \\+STR
        \\ERROR 1:2 found an unknown escape in a double-quoted scalar
    );
    try expectTokens("\"\\x4\"",
        \\+STR
        \\ERROR 1:2 an escape needs as many hex digits as its letter says
    );
    try expectTokens("\"\\uD800\"",
        \\+STR
        \\ERROR 1:2 an escape names no Unicode character
    );
    try expectTokens("\"\\U00110000\"",
        \\+STR
        \\ERROR 1:2 an escape names no Unicode character
    );
    try expectTokens("---\nquoted: \"a\nb\nc\"\n",
        \\+STR
        \\+DOC
        \\+MAP
        \\?
        \\=quoted
        \\:
        \\ERROR 3:1 a quoted scalar's lines must be indented past its block's, with spaces
    );
    try expectTokens("foo: \"bar\n\tbaz\"",
        \\+STR
        \\+MAP
        \\?
        \\=foo
        \\:
        \\ERROR 2:2 a quoted scalar's lines must be indented past its block's, with spaces
    );
    try expectTokens("---\n\"\n---\n\"\n",
        \\+STR
        \\+DOC
        \\ERROR 3:1 a document marker cannot be inside a quoted scalar
    );
    try expectTokens("---\n'\n...\n'\n",
        \\+STR
        \\+DOC
        \\ERROR 3:1 a document marker cannot be inside a quoted scalar
    );
    try expectTokens("'unterminated",
        \\+STR
        \\ERROR 1:1 found the end of the input inside a quoted scalar
    );
    try expectTokens("\"a\x01\"",
        \\+STR
        \\ERROR 1:3 found a character that is not allowed in a quoted scalar
    );
    try expectTokens("key: \"value\"# invalid comment",
        \\+STR
        \\+MAP
        \\?
        \\=key
        \\:
        \\"value
        \\ERROR 1:13 a comment must be separated from what comes before it by whitespace
    );
}

test "block scalars: literal keeps lines, folded joins them" {
    try expectTokens("a: |\n  one\n   two\n\n  three\nb: >\n  one\n  two\n\n  three\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\|one\n two\n\nthree\n
        \\?
        \\=b
        \\:
        \\>one two\nthree\n
        \\-BLK
        \\-STR
    );
}

test "block scalars: folded keeps the breaks around more-indented lines" {
    // YAML 1.2.2 example 8.10.
    try expectTokens(">\n\n folded\n line\n\n next\n line\n   * bullet\n\n   * list\n   * lines\n\n last\n line\n\n# Comment\n",
        \\+STR
        \\>\nfolded line\nnext line\n  * bullet\n\n  * list\n  * lines\n\nlast line\n
        \\-STR
    );
}

test "block scalars: each chomping indicator" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "|-\n  text\n\n\n", "|text" },
        .{ "|\n  text\n\n\n", "|text\\n" },
        .{ "|+\n  text\n\n\n", "|text\\n\\n\\n" },
        .{ ">-\n  text\n", ">text" },
        .{ "|-\n\n", "|" },
        .{ "|\n\n", "|" },
        .{ "|+\n\n", "|\\n" },
        // The input's end ends the last line too.
        .{ "|\n  text", "|text\\n" },
        .{ "|-\n  text", "|text" },
        .{ "- |+\n   ", "|\\n" },
    };
    inline for (cases) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        try testing.expect(std.mem.find(u8, got, case[1] ++ "\n") != null);
    }
}

test "block scalars: indentation indicators, either order with chomping" {
    try expectTokens("- |1\n  two spaces\n- >2-\n    folded\n- |+1\n  x\n",
        \\+STR
        \\+SEQ
        \\-
        \\| two spaces\n
        \\-
        \\>  folded
        \\-
        \\| x\n
        \\-BLK
        \\-STR
    );
    // At the top, the block's indentation is -1: content may start at 0.
    try expectTokens("--- >\nline1\nline2\n",
        \\+STR
        \\+DOC
        \\>line1 line2\n
        \\-STR
    );
    try expectTokens("--- |1\n foo\n",
        \\+STR
        \\+DOC
        \\| foo\n
        \\-STR
    );
}

test "block scalars: a less indented comment ends one, a more indented one is content" {
    try expectTokens("a: |\n  text\n  # kept\n # gone\nb: c\n",
        \\+STR
        \\+MAP
        \\?
        \\=a
        \\:
        \\|text\n# kept\n
        \\?
        \\=b
        \\:
        \\=c
        \\-BLK
        \\-STR
    );
}

test "block scalars: tabs after the indentation are content (suite Y79Y/001, 96NN)" {
    try expectTokens("foo: |\n \t\nbar: 1\n",
        \\+STR
        \\+MAP
        \\?
        \\=foo
        \\:
        \\|\t\n
        \\?
        \\=bar
        \\:
        \\=1
        \\-BLK
        \\-STR
    );
    try expectTokens("foo: |-\n \tbar\n",
        \\+STR
        \\+MAP
        \\?
        \\=foo
        \\:
        \\|\tbar
        \\-BLK
        \\-STR
    );
}

test "block scalar errors (suite 2G84, 5LLU, S98Z, W9L4, Y79Y/000)" {
    const errors = [_]struct { []const u8, []const u8 }{
        .{ "--- |10\n", "1:7 a block scalar's indentation indicator cannot be 0" },
        .{ "--- |0\n", "1:6 a block scalar's indentation indicator cannot be 0" },
        .{ "--- |x\n", "1:6 a block scalar's header must end its line, but for a comment" },
        .{ "--- |--\n", "1:7 a block scalar's header must end its line, but for a comment" },
        .{ "--- |#c\n", "1:6 a comment must be separated from what comes before it by whitespace" },
        .{ "block scalar: >\n \n  \n   \n invalid\n", "5:2 a block scalar's leading empty line has more spaces than its first line" },
        .{ "empty block scalar: >\n \n  \n   \n # comment\n", "5:2 a block scalar's leading empty line has more spaces than its first line" },
        .{ "foo: |\n\t\nbar: 1\n", "2:1 a tab character cannot indent a block scalar" },
        .{ "foo: |\n  x\n \t\nbar: 1\n", "3:2 a tab character cannot indent a block scalar" },
        .{ "[ |\n  x ]", "1:3 found a character that cannot start any token" },
        // A NUL byte, read as 0 as the input's end is, once looped
        // forever (t43; the last is the fuzzer's input).
        .{ "--- |\x00", "1:6 a block scalar's header must end its line, but for a comment" },
        .{ "|\n\x00", "2:1 found a character that is not allowed in YAML" },
        .{ ">\n  a\n  \x00", "3:3 found a character that is not allowed in YAML" },
        .{ "-1.5e3-!!str - a\n--- |\x00\n  b\n...\n# c\n", "2:6 a block scalar's header must end its line, but for a comment" },
    };
    inline for (errors) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        try testing.expect(std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ "\n"));
    }
}

test "directives: %YAML and %TAG, a reserved one skipped" {
    try expectTokens("%YAML 1.2\n%TAG !e! tag:example.com,2000:app/\n%TAG ! !foo%21\n%FOO  bar baz # ignored\n--- !e!x a\n",
        \\+STR
        \\%YAML 1.2
        \\%TAG !e! tag:example.com,2000:app/
        \\%TAG ! !foo!
        \\+DOC
        \\!!e!x
        \\=a
        \\-STR
    );
    // Blanks of either kind between the parameters, and a comment after.
    try expectTokens("%YAML \t 1.1  # comment\n---\n",
        \\+STR
        \\%YAML 1.1
        \\+DOC
        \\-STR
    );
    // A near miss is a reserved directive, skipped (suite MUS6/05, MUS6/06).
    try expectTokens("%YAM 1.1\n%YAMLL 1.1\n---\n",
        \\+STR
        \\+DOC
        \\-STR
    );
}

test "directive errors (suite H7TQ, MUS6/00)" {
    const errors = [_]struct { []const u8, []const u8 }{
        .{ "%YAML 1.2 foo\n", "1:11 a directive's line holds more than its parameters and a comment" },
        .{ "%YAML 1.1#...\n", "1:10 a comment must be separated from what comes before it by whitespace" },
        .{ "%YAML 1\n", "1:8 a YAML version needs a '.' between its numbers" },
        .{ "%YAML 1.\n", "1:9 a YAML version needs a number here" },
        .{ "%YAML 99999.1\n", "1:7 a YAML version number is too long" },
        .{ "%YAML\n", "1:6 a directive's parameters must be separated by blanks" },
        .{ "%TAG e! x\n", "1:6 a %TAG directive needs a handle, as ! or !! or !name!" },
        .{ "%TAG !e x\n", "1:6 a %TAG directive needs a handle, as ! or !! or !name!" },
        .{ "%TAG !e! [x\n", "1:10 a %TAG prefix cannot start with a flow indicator" },
        .{ "% x\n", "1:1 a directive needs a name after its %" },
    };
    inline for (errors) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        try testing.expect(std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ "\n"));
    }
}

test "tags: each form, escapes decoded" {
    try expectTokens("- !local a\n- !!str b\n- !e!tag%21 c\n- !<tag:yaml.org,2002:str> d\n- ! e\n- !<!bar> f\n",
        \\+STR
        \\+SEQ
        \\-
        \\!!local
        \\=a
        \\-
        \\!!!str
        \\=b
        \\-
        \\!!e!tag!
        \\=c
        \\-
        \\!tag:yaml.org,2002:str
        \\=d
        \\-
        \\!!
        \\=e
        \\-
        \\!!bar
        \\=f
        \\-BLK
        \\-STR
    );
    // In a flow collection a flow indicator may follow a tag (suite WZ62).
    try expectTokens("{ foo : !!str, !!str : bar }",
        \\+STR
        \\{
        \\?
        \\=foo
        \\:
        \\!!!str
        \\,
        \\?
        \\!!!str
        \\:
        \\=bar
        \\}
        \\-STR
    );
}

test "tag errors (suite U99R, LHL4)" {
    const errors = [_]struct { []const u8, []const u8 }{
        .{ "- !!str, xxx\n", "1:8 an anchor, alias or tag must be followed by whitespace" },
        .{ "---\n!invalid{}tag scalar\n", "2:9 an anchor, alias or tag must be followed by whitespace" },
        .{ "!!\n", "1:1 a tag needs a suffix after its handle" },
        .{ "!e! x\n", "1:1 a tag needs a suffix after its handle" },
        .{ "!<> x\n", "1:1 a verbatim tag needs a URI and a '>' after it" },
        .{ "!<a x\n", "1:1 a verbatim tag needs a URI and a '>' after it" },
        .{ "!a%2 x\n", "1:3 a % in a tag needs two hex digits after it" },
        .{ "!a%ff x\n", "1:6 a tag's % escapes do not spell UTF-8" },
    };
    inline for (errors) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        try testing.expect(std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ "\n"));
    }
}

test "anchors and aliases: names run to a blank or flow indicator (suite 2SXE)" {
    try expectTokens("&a: key: &a value\nfoo:\n  *a:\n",
        \\+STR
        \\+MAP
        \\?
        \\&a:
        \\=key
        \\:
        \\&a
        \\=value
        \\?
        \\=foo
        \\:
        \\*a:
        \\-BLK
        \\-STR
    );
    try expectTokens("[&x a, *x]",
        \\+STR
        \\[
        \\&x
        \\=a
        \\,
        \\*x
        \\]
        \\-STR
    );
    try expectTokens("*a : b\n",
        \\+STR
        \\+MAP
        \\?
        \\*a
        \\:
        \\=b
        \\-BLK
        \\-STR
    );
    try expectTokens("& a\n",
        \\+STR
        \\ERROR 1:1 an anchor or alias needs a name
    );
    try expectTokens("- &a,\n",
        \\+STR
        \\+SEQ
        \\-
        \\ERROR 1:5 an anchor, alias or tag must be followed by whitespace
    );
}

test "flow: a value may adjoin a JSON-like key (suite C2DT, 5T43, 9MMW)" {
    try expectTokens("{\"a\":b, \"c\"::d, [x]:y}",
        \\+STR
        \\{
        \\?
        \\"a
        \\:
        \\=b
        \\,
        \\?
        \\"c
        \\:
        \\=:d
        \\,
        \\?
        \\[
        \\=x
        \\]
        \\:
        \\=y
        \\}
        \\-STR
    );
    // After a plain scalar, `:` with no blank after it is still text.
    try expectTokens("[a:b]",
        \\+STR
        \\[
        \\=a:b
        \\]
        \\-STR
    );
}

test "flow: in a mapping a key's ':' may be on a later line (suite 4MUZ, VJP3/01, K3WX)" {
    try expectTokens("{\"foo\"\n: bar, \"baz\" # c\n :qux}",
        \\+STR
        \\{
        \\?
        \\"foo
        \\:
        \\=bar
        \\,
        \\?
        \\"baz
        \\:
        \\=qux
        \\}
        \\-STR
    );
    // After a plain scalar, `:qux` on the next line is text: here the
    // scalar's next line.
    try expectTokens("{baz\n :qux}",
        \\+STR
        \\{
        \\=baz :qux
        \\}
        \\-STR
    );
    try expectTokens("k: {\n k\n :\n v\n }",
        \\+STR
        \\+MAP
        \\?
        \\=k
        \\:
        \\{
        \\?
        \\=k
        \\:
        \\=v
        \\}
        \\-BLK
        \\-STR
    );
    // In a sequence it may not: no key, and the parser reports the `:`.
    try expectTokens("[ key\n  : value ]",
        \\+STR
        \\[
        \\=key
        \\:
        \\=value
        \\]
        \\-STR
    );
}

test "flow: lines indented past the block, with spaces (suite 9C9N, VJP3/00, Y79Y)" {
    const errors = [_]struct { []const u8, []const u8 }{
        .{ "---\nflow: [a,\nb,\nc]\n", "3:1" },
        .{ "k: {\nk\n:\nv\n}\n", "2:1" },
        .{ "- [\n\tfoo,\n foo\n ]\n", "2:2" },
        .{ "k: [a\nb]\n", "2:1" },
        .{ "k: [\"a\nb\"]\n", "2:1" },
    };
    inline for (errors) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        const message = " a flow collection's lines must be indented past its block's, with spaces\n";
        const quoted = " a quoted scalar's lines must be indented past its block's, with spaces\n";
        try testing.expect(std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ message) or
            std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ quoted));
    }
    // A line holding only a tab, or a comment, is no line of the collection.
    try expectTokens("- [\n\t\n# c\n foo\n ]\n",
        \\+STR
        \\+SEQ
        \\-
        \\[
        \\=foo
        \\]
        \\-BLK
        \\-STR
    );
    // At the top there is no block to be past.
    try expectTokens("[\na,\n\tb\n]",
        \\+STR
        \\[
        \\=a
        \\,
        \\=b
        \\]
        \\-STR
    );
}

test "flow: multi-line plain scalars fold, and end at flow indicators" {
    try expectTokens("- [ one\n   two, three ]",
        \\+STR
        \\+SEQ
        \\-
        \\[
        \\=one two
        \\,
        \\=three
        \\]
        \\-BLK
        \\-STR
    );
}
