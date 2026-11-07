//! The reader's tests: inputs it reads to their end, its events the
//! parser's, and inputs it hands over.

const std = @import("std");
const testing = std.testing;
const Reader = @import("Reader.zig");

/// The reader reads `input` to its end, its events the parser's.
fn expectWhole(input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try Reader.compare(testing.allocator, arena.allocator(), input);
    if (result.problem) |problem| {
        std.debug.print("{s}\n", .{problem});
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.whole);
}

/// The reader hands `input` over, its events up to then the parser's.
fn expectHandedOver(input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try Reader.compare(testing.allocator, arena.allocator(), input);
    if (result.problem) |problem| {
        std.debug.print("{s}\n", .{problem});
        return error.TestUnexpectedResult;
    }
    try testing.expect(!result.whole);
}

test "block collections, nested and compact, a sequence at its key's column" {
    try expectWhole("a: 1\nb:\n  - x\n  - y: z\n    w: v\nc:\n- p\n- q\nd: e\n");
    try expectWhole("- - a\n  - b\n- c: d\n  e: f\n-\n- g\n");
    try expectWhole("a:\nb: c\n: d\n");
}

test "scalars: plain, quoted, block, empty; comments" {
    try expectWhole("# head\na: 'x y'   # tail\nb: \"q\\tr\"\nc: |\n  lit\n  eral\nd: >-\n  fol\n  ded\n\ne:\n");
    try expectWhole("just a scalar");
    try expectWhole("");
    try expectWhole("# only a comment\n");
    // Found by the reader fuzz target: a last line of a comment and no
    // line break ends the blocks past its column there.
    try expectWhole("a: 1\nb:\n  - - y: z\n#");
}

test "found by the reader fuzz target" {
    // A sequence at its key's column ends only at a token the parser
    // could read: here a plain scalar with a byte that is not UTF-8.
    try expectHandedOver("a: 1\nb:\n-  - x\n  -\xC2 y: z\n\n");
    // A quote in a plain scalar opens no quoted one: the `}` closes the
    // flow collection, and the `: ` after it makes it a key.
    try expectHandedOver("- [a, {b: c}, \"d\", null'key}: e']\n- ?: k\n  : v\n\n");
    // A blank in a plain scalar does not end it: the quote after it is
    // in the scalar too.
    try expectHandedOver("- [a, {b: c}, \"d\",:y '}: e']\n-k\n  : v\n\n");
}

test "documents: markers, several, empty, ended" {
    try expectWhole("--- a\n");
    try expectWhole("a: 1\n---\nb: 2\n...\n--- |\n  lit\n---\n...\n");
    try expectWhole("...\n# no document yet\nx\n...\ny: z\n");
    try expectWhole("- a\n- b: c\n...  # done\n");
    try expectWhole("key:\n- a\n---\n");
}

test "anchors, aliases and tags" {
    try expectWhole("base: &b {x: 1}\nother: *b\nlist:\n- &i item\n- *i\n");
    try expectWhole("a: !!str 1\nb: !local x\nc: !<tag:e.com,2000:t> y\nd: ! z\n");
    try expectWhole("m: &m\n  k: v\ns: !!seq\n- a\ne: &e\nf: &f !!null\n");
    try expectWhole("- &a\n- !!map\n  k: v\n- [&x 1, *x, !!str 2, &y ]\n");
    try expectWhole("&root\nk: v\n");
}

test "plain scalars of more lines" {
    try expectWhole("a: one\n  two\n\n  three\nb: x\n");
    try expectWhole("- first\n  second # c\n- third\n");
    try expectWhole("just\na scalar\n");
    try expectWhole("k: &a !!str v\n  w\n");
}

test "flow collections over lines, as JSON is printed" {
    try expectWhole("{\n  \"a\": 1,\n  \"b\": [\n    true,\n    \"x\"\n  ],\n  \"c\": {}\n}\n");
    try expectWhole("k: [a, # first\n    b,\n    'c\n    d']\nn: {x: 1,\n  y: 2}\n");
    try expectWhole("[one\n two, {a\n : b}]\n");
    // `:b` does not end a plain scalar: the key is `a :b`, its value
    // empty.
    try expectWhole("{a\n:b}\n");
}

test "tabs between tokens" {
    try expectWhole("a:\tb\nc: d\t# tail\n");
    try expectWhole("- \tx\n");
    try expectWhole("k:\n  \tv\n\t# a comment\n");
    try expectWhole("- a\t\n-\tb\n");
}

test "flow collections on one line" {
    try expectWhole("tags: [alpha, beta, \"gamma 0\"]\nenv: {A: \"x\", B: 'y'}\nn: [[1, 2], {}, []]\nk: {a, b: , : c}\n");
}

test "explicit keys, and values with no key" {
    try expectWhole("? a\n: b\n");
    try expectWhole("? explicit # empty value\n? |\n  block key\n: - one\n  - two\n");
    try expectWhole("a: 1\n? b\n: 2\nc: 3\n");
    try expectWhole("?\n- a\n- b\n:\n- c\n");
    try expectWhole("- ? : x\n- ? k\n  : v\n");
    try expectWhole("? a: b\n  c: d\n: e\n? x\n");
    try expectWhole(": a\n: - b\n  - c\n");
    try expectWhole("&m\n? &k k\n: &v\n");
    try expectWhole("?\n");
}

test "keys with properties, and aliases as keys" {
    try expectWhole("&a key: v\n");
    try expectWhole("*a : v\n");
    try expectWhole("- &a !!str k: v\n  *a : w\n  !t 'q': x\n");
    try expectWhole("&m\n&k key: v\n!!str k2: *k\n");
    try expectWhole("&m\n*a : v\n");
    try expectWhole("top:\n  &x a: 1\n  b: &y 2\n");
}

test "directives, and tags resolved against them" {
    try expectWhole("%YAML 1.2\n---\na\n");
    try expectWhole("%TAG !e! tag:e.com,2000:\n%TAG ! !local-\n--- !e!x\n- !y 1\n- !!str 2\n");
    try expectWhole("%TAG !! tag:other:\n--- !!str a\n...\n--- !!str b\n");
    try expectWhole("%FUTURE reserved # skipped\n%YAML 1.1\n---\n...\n%TAG !e! %5Bt%20%C3%A9:\n--- !e!x [!e!y a]\n");
    try expectWhole("# c\n%YAML 1.2 # c\n\n---\n");
}

test "the bench's records" {
    try expectWhole(
        \\- name: service-0
        \\  id: 0
        \\  ratio: 0.0
        \\  enabled: true
        \\  tags: [alpha, beta, "gamma 0"]
        \\  owner: ~
        \\  description: >
        \\    A folded description of service 0
        \\    across two lines.
        \\  ports:
        \\    - 80
        \\    - 443
        \\  env: {A: "x", B: 'y'}
        \\
    );
}

test "what it hands over: forms it does not read yet, and errors" {
    try expectHandedOver("a: !e!x 1\n");
    // Directives the parser refuses, and one after a document with no
    // `...` before it.
    try expectHandedOver("%YAML 1.2\n%YAML 1.2\n---\na\n");
    try expectHandedOver("%YAML 2.0\n---\na\n");
    try expectHandedOver("%TAG !e! a:\n%TAG !e! b:\n---\na\n");
    try expectHandedOver("%TAG !e! a:\na\n");
    try expectHandedOver("a\n---\nb: c\n%YAML 1.2\n---\nc\n");
    try expectHandedOver("a: &x &y 1\n");
    try expectHandedOver("{&a k: v}\n");
    // Properties before a `:` with no key, and properties on two lines
    // of a node that is no mapping.
    try expectHandedOver("&a : b\n");
    try expectHandedOver("&a\n!t x\n");
    try expectHandedOver("a b\nc: d\n");
    try expectHandedOver("[a]: b\n");
    // A line of a flow collection in a block must be indented past it.
    try expectHandedOver("k: [\n  a\n]\n");

    try expectHandedOver("-\ta: b\n");
    try expectHandedOver("a:\n\tb: c\n");
    try expectHandedOver("\xEF\xBB\xBFa: b\n");
    // Errors.
    try expectHandedOver("a: b: c\n");
    try expectHandedOver("a: [b\n");
    try expectHandedOver("- a\nb: c\n");
    try expectHandedOver("a: 'b\n");
    try expectHandedOver("--- a: b\n");
    try expectHandedOver("--- - a\n");
    try expectHandedOver("... a\n");
    try expectHandedOver("a\n... b\n");
    // Found by the reader fuzz target: the parser ends a document at
    // `...` only once it has read the token after, here a comment with a
    // byte that is not UTF-8.
    try expectHandedOver("--- a\n--- |\n b\n...\n# \xBB\n");
    // `---` and a NUL byte is a marker to the scanner, which reads a NUL
    // as it does the end.
    try expectHandedOver("\n---\x00 |\n  b\n...\n'# c\n\n");
}
