//! The inputs the fuzz targets draw (kb/t2), three ways: raw bytes, a
//! corpus entry with a few edits, and YAML built a line at a time from
//! pieces, its indentation drawn at the edges a block's rules turn on.
//! Shared by src/fuzz_test.zig and src/differential_test.zig (t68).

const std = @import("std");
const Draw = @import("fuzzing.zig").Draw;

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
pub fn draw(d: *Draw, arena: std.mem.Allocator) ![]const u8 {
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
