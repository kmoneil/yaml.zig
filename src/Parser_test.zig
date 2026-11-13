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

fn parseAll(p: *Parser) Parser.Error!void {
    while ((try p.next()).data != .stream_end) {}
}

test "a document may have max_tag_directives %TAG directives, and no more" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    // Two documents of 64 each: the bound is a document's, not the stream's.
    for (0..2) |_| {
        for (0..64) |i| try text.print(gpa, "%TAG !h{d}! p{d}:\n", .{ i, i });
        try text.appendSlice(gpa, "--- !h63!x a\n...\n");
    }
    var p: Parser = .init(gpa, text.items);
    defer p.deinit();
    try parseAll(&p);

    // The 65th is refused where it is.
    try text.insertSlice(gpa, 0, "%TAG !extra! q:\n");
    var over: Parser = .init(gpa, text.items);
    defer over.deinit();
    try testing.expectError(error.TagDirectiveLimit, parseAll(&over));
    try testing.expectEqual(64, over.diagnostic.mark.line);
    try testing.expectEqual(0, over.diagnostic.mark.column);
}

/// `dump` with the parser set as given: each event written as it comes,
/// which is all `.next_event` promises.
fn dumpWith(gpa: std.mem.Allocator, input: []const u8, lifetime: Parser.TextLifetime, use_reader: bool) ![]u8 {
    var p: Parser = .init(gpa, input);
    defer p.deinit();
    p.text_lifetime = lifetime;
    p.use_reader = use_reader;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    while (true) {
        const e = p.next() catch |err| switch (err) {
            error.SyntaxError => {
                try out.writer.print("ERROR {s}\n", .{p.diagnostic.message});
                break;
            },
            else => return err,
        };
        try Parser.writeTestEvent(&out.writer, e);
        if (e.data == .stream_end) break;
    }
    return out.toOwnedSlice();
}

test "text valid until the next event: the events as ever, the reader's and the state machine's" {
    const folded = "- >\n  folded across\n  two lines\n";
    const escaped = "- \"an \\x41 escape \\u263A\"\n- 'it''s'\n- \"multi\n  line\"\n";
    // A prefix with escapes, decoded: the document's later tags resolve
    // against it after many events' text has gone.
    const tagged = comptime "%TAG !e! tag:ex%41mple.com,2026:\n---\n- !e!one a\n- " ++ repeat("x\n- ", 40) ++ "!e!two b\n...\n%TAG !e! tag:other%2C:\n---\n- !e!three c\n";
    const block = "a: |\n  literal\n   kept\n\nb: >-\n  folded\n\n  para\n";
    const inputs = [_][]const u8{ folded, escaped, tagged, block, "{a: [b, \"c\\td\"], ? e : f}\n", "- \"bad \\q escape\"\n" };
    for (inputs) |input| {
        // With a byte order mark the state machine reads it all.
        for ([_][]const u8{ "", "\xEF\xBB\xBF" }) |bom| for ([_]bool{ true, false }) |use_reader| {
            const text = try std.mem.concat(testing.allocator, u8, &.{ bom, input });
            defer testing.allocator.free(text);
            errdefer std.debug.print("input: {s} (reader {})\n", .{ text, use_reader });
            const want = try dumpWith(testing.allocator, text, .parser, use_reader);
            defer testing.allocator.free(want);
            const got = try dumpWith(testing.allocator, text, .next_event, use_reader);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(want, got);
        };
    }
}

fn repeat(comptime text: []const u8, comptime n: usize) []const u8 {
    var out: []const u8 = "";
    for (0..n) |_| out = out ++ text;
    return out;
}

/// `text` `n` times over, on the testing allocator.
fn repeated(text: []const u8, n: usize) ![]u8 {
    const out = try testing.allocator.alloc(u8, text.len * n);
    for (0..n) |i| @memcpy(out[i * text.len ..][0..text.len], text);
    return out;
}

/// Counts the most bytes held at once through it.
const Peak = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(c: *Peak) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grew(c: *Peak, old: usize, new: usize) void {
        c.live = c.live - old + new;
        c.peak = @max(c.peak, c.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const c: *Peak = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, a, ret) orelse return null;
        c.grew(0, len);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, len: usize, ret: usize) bool {
        const c: *Peak = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(m, a, len, ret)) return false;
        c.grew(m.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const c: *Peak = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(m, a, len, ret) orelse return null;
        c.grew(m.len, len);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ret: usize) void {
        const c: *Peak = @ptrCast(@alignCast(ctx));
        c.grew(m.len, 0);
        c.child.rawFree(m, a, ret);
    }
};

/// The most a parse of `input` holds, set as given.
fn peakOf(input: []const u8, lifetime: Parser.TextLifetime, use_reader: bool) !usize {
    var peak: Peak = .{ .child = testing.allocator };
    var p: Parser = .init(peak.allocator(), input);
    defer p.deinit();
    p.text_lifetime = lifetime;
    p.use_reader = use_reader;
    while ((try p.next()).data != .stream_end) {}
    return peak.peak;
}

test "text valid until the next event: memory that does not grow with the stream" {
    // Scalars whose text is built: a folded one and an escaped one each.
    const item = "- >\n  folded text that the scanner\n  builds from two lines\n- \"an \\t escaped one\"\n";
    for ([_]bool{ true, false }) |use_reader| {
        const small = try repeated(item, 100);
        defer testing.allocator.free(small);
        const large = try repeated(item, 5_000);
        defer testing.allocator.free(large);
        errdefer std.debug.print("reader {}\n", .{use_reader});
        // Kept as long as the parser, the text grows with the stream...
        try testing.expect(try peakOf(large, .parser, use_reader) > 200_000);
        // ...and reused, it does not: the large stream holds what the
        // small one does, to a few kilobytes.
        const small_peak = try peakOf(small, .next_event, use_reader);
        const large_peak = try peakOf(large, .next_event, use_reader);
        try testing.expect(large_peak < small_peak + 8_192);
        try testing.expect(large_peak < 32_768);
    }
}

test "a flow node's properties: whitespace before a collection, a closer at once (t68)" {
    // Found by the differential fuzz target, held to the YAML reference
    // parser: content needs separation after its properties (7.3).
    try expectEvents("[!{a: b}]", "+STR\n+DOC\n+SEQ []\nERROR 1:3 an anchor, alias or tag must be followed by whitespace");
    try expectEvents("[&x{a: b}]", "+STR\n+DOC\n+SEQ []\nERROR 1:4 an anchor, alias or tag must be followed by whitespace");
    try expectEvents("{!!str{a: b}: c}", "+STR\n+DOC\n+MAP {}\nERROR 1:7 an anchor, alias or tag must be followed by whitespace");
    // An empty node ends at once, and whitespace before content is fine.
    try expectEvents("[!a, ! {b: c}]", "+STR\n+DOC\n+SEQ []\n=VAL <!a> :\n+MAP {} <!>\n=VAL :b\n=VAL :c\n-MAP\n-SEQ\n-DOC\n-STR");
    try expectEvents("{&x : y}", "+STR\n+DOC\n+MAP {}\n=VAL &x :\n=VAL :y\n-MAP\n-DOC\n-STR");
}

test "a block scalar is a node of its block only past the block's column (t68)" {
    // Found by the differential fuzz target, held to the YAML reference
    // parser: s-separate(n+1) before it (8.1), which a block sequence's
    // indentless form does not need.
    try expectEvents("k:\n|\n x\n", "+STR\n+DOC\n+MAP\n=VAL :k\nERROR 2:1 a block scalar must be indented past the block it is in");
    try expectEvents("-\n|\n x\n", "+STR\n+DOC\n+SEQ\nERROR 2:1 a block scalar must be indented past the block it is in");
    try expectEvents("k:\n!t |\n x\n", "+STR\n+DOC\n+MAP\n=VAL :k\nERROR 2:4 a block scalar must be indented past the block it is in");
    try expectEvents("k:\n |\n x\n", "+STR\n+DOC\n+MAP\n=VAL :k\n=VAL |x\\n\n-MAP\n-DOC\n-STR");
    try expectEvents("!t\n|\n x\n", "+STR\n+DOC\n=VAL <!t> |x\\n\n-DOC\n-STR");
    try expectEvents("k:\n- |\n x\n", "+STR\n+DOC\n+MAP\n=VAL :k\n+SEQ\n=VAL |x\\n\n-SEQ\n-MAP\n-DOC\n-STR");
}

test "the suite's notation escapes what the reference parser does (t68)" {
    try expectEvents("\"\\0\\a\\b\\t\\n\\v\\f\\r\\e\\N\\_\\L\\P\\\\\"", "+STR\n+DOC\n=VAL \"\\0\\a\\b\\t\\n\\v\\f\\r\\e\\N\\_\\L\\P\\\\\n-DOC\n-STR");
}

test "an empty implicit key's value holds no block collection on its line (t68)" {
    // Found by the differential fuzz target, held to the YAML reference
    // parser: only an explicit key's value may (s-l+block-indented, 8.2.2).
    try expectEvents(": - a\n", "+STR\n+DOC\n+MAP\n=VAL :\nERROR 1:3 a block sequence entry is not allowed here");
    try expectEvents(": ? a\n", "+STR\n+DOC\n+MAP\n=VAL :\nERROR 1:3 a mapping key is not allowed here");
    try expectEvents("? a\n: b\n: ? c\n", "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :\nERROR 3:3 a mapping key is not allowed here");
    try expectEvents("? a\n: - b\n", "+STR\n+DOC\n+MAP\n=VAL :a\n+SEQ\n=VAL :b\n-SEQ\n-MAP\n-DOC\n-STR");
    try expectEvents(":\n  - a\n", "+STR\n+DOC\n+MAP\n=VAL :\n+SEQ\n=VAL :a\n-SEQ\n-MAP\n-DOC\n-STR");
}

test "nothing may follow a '...' on its line, with no document open too (t68)" {
    try expectEvents("... a\n", "+STR\nERROR 1:5 nothing may follow '...' on its line but a comment");
    try expectEvents("...\n... x\n", "+STR\nERROR 2:5 nothing may follow '...' on its line but a comment");
    try expectEvents("... # c\nb\n", "+STR\n+DOC\n=VAL :b\n-DOC\n-STR");
}

test "a flow collection's '?' takes whitespace after it (t68)" {
    try expectEvents("[?]", "+STR\n+DOC\n+SEQ []\nERROR 1:2 a '?' in a flow collection must be followed by whitespace");
    try expectEvents("[?{a: b}]", "+STR\n+DOC\n+SEQ []\nERROR 1:2 a '?' in a flow collection must be followed by whitespace");
    try expectEvents("[? , ?a]", "+STR\n+DOC\n+SEQ []\n+MAP {}\n=VAL :\n=VAL :\n-MAP\n=VAL :?a\n-SEQ\n-DOC\n-STR");
    try expectEvents("{?: a}", "+STR\n+DOC\n+MAP {}\n=VAL :?\n=VAL :a\n-MAP\n-DOC\n-STR");
}

test "a reserved directive is a directive: past a '...' after a document, and a '---' after it (t68)" {
    try expectEvents("%FOO bar\n--- x\n", "+STR\n+DOC ---\n=VAL :x\n-DOC\n-STR");
    try expectEvents("%FOO\n", "+STR\nERROR 2:1 directives must be followed by '---'");
    try expectEvents("%FOO\nx\n", "+STR\nERROR 2:1 directives must be followed by '---'");
    try expectEvents("{a: b}\n%x\n", "+STR\n+DOC\n+MAP {}\n=VAL :a\n=VAL :b\n-MAP\n-DOC\nERROR 2:1 a directive after a document must follow a '...' that ends it");
    // A `%` line inside a plain scalar is its text.
    try expectEvents("a\n%FOO\n--- b\n", "+STR\n+DOC\n=VAL :a %FOO\n-DOC\n+DOC ---\n=VAL :b\n-DOC\n-STR");
}
