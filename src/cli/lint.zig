//! `yaml lint`: warnings for YAML that is valid but reads one way here and
//! another elsewhere, or is legal and almost certainly a mistake (t60).
//! Each warning has a rule, which `--allow` turns off:
//!
//! - yaml11: a plain scalar YAML 1.1 readers (PyYAML) type otherwise than
//!   YAML 1.2 does: `yes`, `on`, `0777`, `1:20`, `2001-12-14`, `1e3`.
//! - tab: a tab in a line's indentation, where YAML allows one (a block
//!   scalar's text, a comment, a flow collection's lines).
//! - trailing-space: blanks at the end of a line.
//! - line-length: a line longer than `--max-line`.
//! - unused-anchor: an anchor no alias names.
//! - key-case: keys of one mapping that differ only in case or trailing
//!   blanks (`Name` and `name`), which some readers take for one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const schema = yaml.schema;
const Node = yaml.Composer.Node;
const Mark = yaml.Composer.Mark;

pub const Rule = enum { yaml11, tab, @"trailing-space", @"line-length", @"unused-anchor", @"key-case" };

pub const rule_names = "yaml11, tab, trailing-space, line-length, unused-anchor or key-case";

pub const Warning = struct { rule: Rule, mark: Mark, message: []const u8 };

pub const Options = struct {
    /// The rules not checked.
    allow: std.EnumSet(Rule) = .empty,
    /// The most characters a line may have; null for any number.
    max_line: ?usize = null,
};

/// The warnings for `text`, whose documents' roots are `roots`, in the
/// order of their marks.
pub fn lint(arena: Allocator, text: []const u8, roots: []const *Node, options: Options) Allocator.Error![]Warning {
    var l: Linter = .{ .arena = arena, .options = options };
    for (roots) |root| try l.document(root);
    try l.lines(text);
    std.mem.sort(Warning, l.warnings.items, {}, before);
    return l.warnings.items;
}

fn before(_: void, a: Warning, b: Warning) bool {
    if (a.mark.offset != b.mark.offset) return a.mark.offset < b.mark.offset;
    return @backingInt(a.rule) < @backingInt(b.rule);
}

const Linter = struct {
    arena: Allocator,
    options: Options,
    warnings: std.ArrayList(Warning) = .empty,

    fn warn(l: *Linter, rule: Rule, mark: Mark, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (l.options.allow.contains(rule)) return;
        try l.warnings.append(l.arena, .{ .rule = rule, .mark = mark, .message = try std.fmt.allocPrint(l.arena, fmt, args) });
    }

    /// One document's nodes, without recursion: each scalar's readings,
    /// each mapping's keys, and its anchors against its aliases.
    fn document(l: *Linter, root: *const Node) Allocator.Error!void {
        var named: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
        var anchored: std.ArrayList(*const Node) = .empty;
        var stack: std.ArrayList(struct { node: *const Node, key: bool }) = .empty;
        try stack.append(l.arena, .{ .node = root, .key = false });
        while (stack.pop()) |item| {
            const node = item.node;
            if (node.anchor != null) try anchored.append(l.arena, node);
            switch (node.data) {
                .alias => |target| try named.put(l.arena, target, {}),
                .scalar => |s| try l.scalar(node, s, item.key),
                .sequence => |s| for (s.items) |child| try stack.append(l.arena, .{ .node = child, .key = false }),
                .mapping => |m| {
                    try l.keys(m.pairs);
                    for (m.pairs) |pair| {
                        try stack.append(l.arena, .{ .node = pair.value, .key = false });
                        try stack.append(l.arena, .{ .node = pair.key, .key = true });
                    }
                },
            }
        }
        for (anchored.items) |node| {
            if (named.contains(node)) continue;
            try l.warn(.@"unused-anchor", node.start, "the anchor &{s} is never used: no alias names it", .{node.anchor.?});
        }
    }

    /// A plain scalar with no tag of its own, read as YAML 1.2 and as 1.1
    /// read it.
    fn scalar(l: *Linter, node: *const Node, s: Node.Scalar, key: bool) Allocator.Error!void {
        if (s.style != .plain or !implicit(node.tag)) return;
        const text = s.value;
        // `<<` as a key is a merge, meant as one.
        if (key and std.mem.eql(u8, text, "<<")) return;
        const now = schema.resolvePlain(.core, text).?;
        const then = schema.resolvePlain(.yaml11, text).?;
        if (now.ptr != then.ptr) {
            if (then.ptr == schema.tag.str.ptr) {
                return l.warn(.yaml11, node.start, "`{s}` is {s} in YAML 1.2 but a string in YAML 1.1 (PyYAML): {s}", .{ text, kindOf(now), fixFor(now) });
            }
            return l.warn(.yaml11, node.start, "`{s}` is {s} in YAML 1.2 but {s} in YAML 1.1 (PyYAML): quote it, '{s}', if it is a string", .{ text, kindOf(now), kindOf(then), text });
        }
        if (now.ptr == schema.tag.int.ptr) return l.integer(node, text);
        if (now.ptr == schema.tag.str.ptr and schema.yaml11Typed(text)) {
            return l.warn(.yaml11, node.start, "`{s}` is a string in YAML 1.2, but some YAML 1.1 readers read it as {s}: quote it, '{s}'", .{ text, looseKind(text), text });
        }
    }

    /// An integer both read, to different values: `0777`.
    fn integer(l: *Linter, node: *const Node, text: []const u8) Allocator.Error!void {
        const now = schema.Schema.core.int(i128, text) orelse return;
        const then = schema.Schema.yaml11.int(i128, text) orelse return;
        if (now == then) return;
        try l.warn(.yaml11, node.start, "`{s}` is {d} in YAML 1.2 but {d} in YAML 1.1 (PyYAML), which reads a leading 0 as octal: write {d} or {d}, as meant", .{ text, now, then, now, then });
    }

    /// Keys of one mapping that differ only in case or trailing blanks.
    fn keys(l: *Linter, pairs: []const Node.Pair) Allocator.Error!void {
        if (pairs.len < 2 or l.options.allow.contains(.@"key-case")) return;
        var seen: std.StringHashMapUnmanaged(*const Node) = .empty;
        for (pairs) |pair| {
            const key = pair.key;
            if (key.data != .scalar or schema.core(key.tag orelse "") != .str) continue;
            const text = key.data.scalar.value;
            const entry = try seen.getOrPut(l.arena, try fold(l.arena, text));
            if (!entry.found_existing) {
                entry.value_ptr.* = key;
                continue;
            }
            const other = entry.value_ptr.*;
            const first = other.data.scalar.value;
            // The same text twice is a duplicate key: check's to report.
            if (std.mem.eql(u8, first, text)) continue;
            const how = if (std.ascii.eqlIgnoreCase(first, text)) "case" else "trailing blanks";
            try l.warn(.@"key-case", key.start, "the key `{s}` differs from `{s}`, on line {d}, only in {s}, which some readers ignore: rename one", .{ text, first, other.start.line + 1, how });
        }
    }

    /// The checks of each line's text: tabs, trailing blanks, length.
    fn lines(l: *Linter, text: []const u8) Allocator.Error!void {
        var offset: usize = 0;
        var number: u32 = 0;
        while (true) : (number += 1) {
            const end = std.mem.findAnyPos(u8, text, offset, "\r\n") orelse text.len;
            try l.line(text[offset..end], offset, number);
            if (end == text.len) return;
            const crlf = text[end] == '\r' and end + 1 < text.len and text[end + 1] == '\n';
            offset = end + @as(usize, if (crlf) 2 else 1);
        }
    }

    fn line(l: *Linter, content: []const u8, offset: usize, number: u32) Allocator.Error!void {
        const indent_end = std.mem.findNone(u8, content, " \t") orelse content.len;
        if (std.mem.findScalar(u8, content[0..indent_end], '\t')) |tab| {
            try l.warn(.tab, at(content, offset, number, tab), "a tab in the indentation: indent with spaces, as YAML's blocks must be", .{});
        }
        const kept = std.mem.trimEnd(u8, content, " \t").len;
        if (kept < content.len) try l.warn(.@"trailing-space", at(content, offset, number, kept), "blanks at the end of the line", .{});
        const max = l.options.max_line orelse return;
        const length = std.unicode.utf8CountCodepoints(content) catch content.len;
        if (length > max) try l.warn(.@"line-length", at(content, offset, number, byteOf(content, max)), "the line is {d} characters long, past --max-line {d}", .{ length, max });
    }
};

/// Whether `tag` is one the composer gave a node that had none: its own
/// constant, not text written in the file.
fn implicit(tag: ?[]const u8) bool {
    const t = tag orelse return false;
    inline for (.{ schema.tag.null, schema.tag.bool, schema.tag.int, schema.tag.float, schema.tag.str, schema.tag.timestamp }) |constant| {
        if (t.ptr == constant.ptr) return true;
    }
    return false;
}

fn kindOf(tag: []const u8) []const u8 {
    if (tag.ptr == schema.tag.timestamp.ptr) return "a timestamp";
    return switch (schema.core(tag) orelse .str) {
        .null => "null",
        .bool => "a boolean",
        .int => "an integer",
        .float => "a float",
        .str, .seq, .map => "a string",
    };
}

/// How to write a number 1.1 reads as a string so both read it alike.
fn fixFor(tag: []const u8) []const u8 {
    if (tag.ptr == schema.tag.float.ptr) return "write it with a point, and a sign on any exponent: 1.0e+3";
    return "write it in decimal";
}

/// What the 1.1 readers that type `text` and PyYAML does not read it as.
fn looseKind(text: []const u8) []const u8 {
    for ([_][]const u8{ "y", "Y", "n", "N" }) |word| {
        if (std.mem.eql(u8, text, word)) return "a boolean";
    }
    if (std.mem.eql(u8, text, "=")) return "a value key";
    return "a number or a date";
}

/// `text` as keys are compared to find near twins: ASCII letters in lower
/// case, trailing blanks dropped.
fn fold(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return std.ascii.allocLowerString(arena, std.mem.trimEnd(u8, text, " \t"));
}

/// The mark of byte `index` of a line's `content`, which starts at
/// `offset` of the text and is line `number`: its column in characters.
fn at(content: []const u8, offset: usize, number: u32, index: usize) Mark {
    const column = std.unicode.utf8CountCodepoints(content[0..index]) catch index;
    return .{ .offset = @intCast(offset + index), .line = number, .column = @intCast(column) };
}

/// The byte where character `n` of `content` starts.
fn byteOf(content: []const u8, n: usize) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < content.len and count < n) : (count += 1) {
        i += std.unicode.utf8ByteSequenceLength(content[i]) catch 1;
    }
    return i;
}
