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
    try testing.expect(std.mem.indexOf(u8, got, "ERROR") != null);
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
        try testing.expect(std.mem.indexOf(u8, got, case[1] ++ "\n") != null);
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
    };
    inline for (errors) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        try testing.expect(std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ "\n"));
    }
}
