//! The parser's tests, events written as the yaml-test-suite writes
//! them (`Parser.writeTestEvent`).

const std = @import("std");
const testing = std.testing;
const Parser = @import("Parser.zig");

fn dump(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var p: Parser = .init(gpa, input);
    defer p.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    while (true) {
        const e = p.next() catch |err| switch (err) {
            error.SyntaxError => {
                try out.writer.print("ERROR {d}:{d} {s}\n", .{ p.diagnostic.mark.line + 1, p.diagnostic.mark.column + 1, p.diagnostic.message });
                break;
            },
            else => return err,
        };
        try Parser.writeTestEvent(&out.writer, e);
        if (e.data == .stream_end) break;
    }
    return out.toOwnedSlice();
}

fn expectEvents(input: []const u8, comptime expected: []const u8) !void {
    const got = try dump(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected ++ "\n", got);
}

test "empty stream" {
    try expectEvents("",
        \\+STR
        \\-STR
    );
}

test "a mapping of a sequence and a scalar" {
    try expectEvents("a:\n- 1\n- 2\nb: c\n",
        \\+STR
        \\+DOC
        \\+MAP
        \\=VAL :a
        \\+SEQ
        \\=VAL :1
        \\=VAL :2
        \\-SEQ
        \\=VAL :b
        \\=VAL :c
        \\-MAP
        \\-DOC
        \\-STR
    );
}

test "empty keys and values" {
    try expectEvents(": a\n: b\nc:\n? d\n",
        \\+STR
        \\+DOC
        \\+MAP
        \\=VAL :
        \\=VAL :a
        \\=VAL :
        \\=VAL :b
        \\=VAL :c
        \\=VAL :
        \\=VAL :d
        \\=VAL :
        \\-MAP
        \\-DOC
        \\-STR
    );
    try expectEvents("- \n-\n",
        \\+STR
        \\+DOC
        \\+SEQ
        \\=VAL :
        \\=VAL :
        \\-SEQ
        \\-DOC
        \\-STR
    );
}

test "flow collections: pairs in sequences, keys alone, empty keys" {
    try expectEvents("[a, b: c, ? d, : e]",
        \\+STR
        \\+DOC
        \\+SEQ []
        \\=VAL :a
        \\+MAP {}
        \\=VAL :b
        \\=VAL :c
        \\-MAP
        \\+MAP {}
        \\=VAL :d
        \\=VAL :
        \\-MAP
        \\+MAP {}
        \\=VAL :
        \\=VAL :e
        \\-MAP
        \\-SEQ
        \\-DOC
        \\-STR
    );
    try expectEvents("{a, b: c, : d, e: }",
        \\+STR
        \\+DOC
        \\+MAP {}
        \\=VAL :a
        \\=VAL :
        \\=VAL :b
        \\=VAL :c
        \\=VAL :
        \\=VAL :d
        \\=VAL :e
        \\=VAL :
        \\-MAP
        \\-DOC
        \\-STR
    );
}

test "properties: anchors, tags resolved, aliases, on empty nodes" {
    try expectEvents("%TAG !e! tag:example.com,2000:\n--- !!map\n&a !e!x k: !local &b v\n? *a\n: !<v:tag>\n",
        \\+STR
        \\+DOC ---
        \\+MAP <tag:yaml.org,2002:map>
        \\=VAL &a <tag:example.com,2000:x> :k
        \\=VAL &b <!local> :v
        \\=ALI *a
        \\=VAL <v:tag> :
        \\-MAP
        \\-DOC
        \\-STR
    );
    try expectEvents("- ! 12\n",
        \\+STR
        \\+DOC
        \\+SEQ
        \\=VAL <!> :12
        \\-SEQ
        \\-DOC
        \\-STR
    );
}

test "documents: bare, explicit, ended, and a stream of them" {
    try expectEvents("Bare\ndocument\n...\n# No document\n...\n|\n%!PS-Adobe-2.0\n",
        \\+STR
        \\+DOC
        \\=VAL :Bare document
        \\-DOC ...
        \\+DOC
        \\=VAL |%!PS-Adobe-2.0\n
        \\-DOC
        \\-STR
    );
    try expectEvents("---\n---\n%YAML 1.2\n---\n",
        \\+STR
        \\+DOC ---
        \\=VAL :
        \\-DOC
        \\+DOC ---
        \\=VAL :
        \\-DOC
        \\ERROR 3:1 a directive after a document must follow a '...' that ends it
    );
}

test "parser errors (suite 9KBC, 3HFZ, SF5V, SR86, ZXT5, 9HCY)" {
    const errors = [_]struct { []const u8, []const u8 }{
        // No simple key may begin on the `---` line: the scanner says so.
        .{ "--- key1: value1\n    key2: value2\n", "1:9 a mapping value is not allowed here" },
        .{ "---\nkey: value\n... invalid\n", "3:5 nothing may follow '...' on its line but a comment" },
        .{ "%YAML 1.2\n%YAML 1.2\n---\n", "2:1 a document may have one %YAML directive" },
        .{ "%YAML 2.0\n---\n", "1:1 this is YAML 1.2: a document of another major version cannot be read" },
        .{ "%TAG ! a\n%TAG ! b\n---\n", "2:1 a document may have one %TAG directive for a handle" },
        .{ "key1: &a value\nkey2: &b *a\n", "2:10 an alias cannot have an anchor or a tag: it is a node already" },
        .{ "[ \"key\"\n  :value ]\n", "2:3 a flow sequence's entries need a ',' between them, and a ']' after" },
        .{ "!foo \"bar\"\n%TAG ! tag:example.com,2000:app/\n---\n", "2:1 a directive after a document must follow a '...' that ends it" },
        .{ "!e!x a\n", "1:1 a tag's handle needs a %TAG directive for it in its document" },
        .{ "%YAML 1.2\nfoo\n", "2:1 directives must be followed by '---'" },
        .{ "--- [a]\nb\n", "2:1 a document after another must begin with '---'" },
    };
    inline for (errors) |case| {
        const got = try dump(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        errdefer std.debug.print("input: {s}\ngot:\n{s}\n", .{ case[0], got });
        try testing.expect(std.mem.endsWith(u8, got, "ERROR " ++ case[1] ++ "\n"));
    }
}
