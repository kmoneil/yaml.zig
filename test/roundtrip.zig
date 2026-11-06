//! The round-trip check: a case's events, emitted, read back to the same
//! documents. Both texts are composed (duplicate keys kept, as some
//! valid cases have them) and compared node by node: kind, tag, anchor,
//! a scalar's value exactly, a collection's entries in order, and an
//! alias by the anchor it names. Styles may differ: the emitter quotes
//! what it cannot write plain.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const Node = yaml.Composer.Node;

/// The text the emitter writes for `input`'s events, or the parser's
/// error if it fails.
pub fn emit(arena: Allocator, input: []const u8) ![]const u8 {
    var parser: yaml.Parser = .init(arena, input);
    var out: std.Io.Writer.Allocating = .init(arena);
    var emitter: yaml.Emitter = .init(arena, &out.writer, .{});
    while (true) {
        const event = try parser.next();
        try emitter.emit(event);
        if (event.data == .stream_end) break;
    }
    return out.written();
}

/// What differs between `input`'s documents and those of the text the
/// emitter writes for them, or null when nothing does.
pub fn compare(arena: Allocator, input: []const u8) !?[]const u8 {
    const text = emit(arena, input) catch |err| return try arena.print("emitting failed: {s}", .{@errorName(err)});
    var original: yaml.Composer = .init(arena, input, .{ .duplicate_keys = .keep });
    var again: yaml.Composer = .init(arena, text, .{ .duplicate_keys = .keep });
    var path: std.ArrayList(u8) = .empty;
    var document: usize = 1;
    while (true) : (document += 1) {
        const a = original.next() catch |err| return try arena.print("the input does not compose: {s}", .{@errorName(err)});
        const b = again.next() catch |err| {
            const d = again.diagnostic;
            return try arena.print("the emitted text does not read back: {s} at {d}:{d}: {s}", .{ @errorName(err), d.mark.line + 1, d.mark.column + 1, d.message });
        };
        if (a == null and b == null) return null;
        if (a == null or b == null) return try arena.print("document {d}: one text has it and the other not", .{document});
        path.clearRetainingCapacity();
        try path.print(arena, "document {d}: $", .{document});
        if (try compareNodes(arena, a.?.root, b.?.root, &path)) |problem| return problem;
    }
}

fn compareNodes(arena: Allocator, a: *const Node, b: *const Node, path: *std.ArrayList(u8)) Allocator.Error!?[]const u8 {
    if (std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return differ(arena, path, "kinds");
    if (!optionalEql(a.tag, b.tag)) return differ(arena, path, "tags");
    if (!optionalEql(a.anchor, b.anchor)) return differ(arena, path, "anchors");
    switch (a.data) {
        .scalar => |s| if (!std.mem.eql(u8, s.value, b.data.scalar.value)) return differ(arena, path, "values"),
        .alias => |target| if (!optionalEql(target.anchor, b.data.alias.anchor)) return differ(arena, path, "aliases"),
        .sequence => |s| {
            const other = b.data.sequence.items;
            if (s.items.len != other.len) return differ(arena, path, "lengths");
            for (s.items, other, 0..) |x, y, i| {
                const len = path.items.len;
                try path.print(arena, "[{d}]", .{i});
                if (try compareNodes(arena, x, y, path)) |problem| return problem;
                path.shrinkRetainingCapacity(len);
            }
        },
        .mapping => |m| {
            const other = b.data.mapping.pairs;
            if (m.pairs.len != other.len) return differ(arena, path, "lengths");
            for (m.pairs, other, 0..) |x, y, i| {
                const len = path.items.len;
                try path.print(arena, ".{d}", .{i});
                if (try compareNodes(arena, x.key, y.key, path)) |problem| return problem;
                if (try compareNodes(arena, x.value, y.value, path)) |problem| return problem;
                path.shrinkRetainingCapacity(len);
            }
        },
    }
    return null;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn differ(arena: Allocator, path: *const std.ArrayList(u8), what: []const u8) Allocator.Error!?[]const u8 {
    const message: []const u8 = try arena.print("{s}: the {s} differ", .{ path.items, what });
    return message;
}
