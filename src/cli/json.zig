//! The CLI's JSON: a `yaml.Value` written as JSON, and JSON read into one
//! to be written as YAML.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const Value = yaml.Value;

pub const WriteError = std.Io.Writer.Error || Allocator.Error || error{
    /// A float JSON has no number for (`.nan`, `.inf`), or a mapping key
    /// that is a collection.
    NotJson,
};

/// How `write` indents: 0 for all on one line, else 1, 2, 3, 4 or 8
/// spaces a level.
pub fn whitespace(indent: u8) ?@FieldType(std.json.Stringify.Options, "whitespace") {
    return switch (indent) {
        0 => .minified,
        1 => .indent_1,
        2 => .indent_2,
        3 => .indent_3,
        4 => .indent_4,
        8 => .indent_8,
        else => null,
    };
}

/// Writes `value` as JSON. A mapping key that is not a string is written
/// as the text of its value (`1`, `true`, `null`).
pub fn write(arena: Allocator, w: *std.Io.Writer, value: Value, indent: u8) WriteError!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = whitespace(indent).? } };
    try writeValue(arena, &s, value);
}

fn writeValue(arena: Allocator, s: *std.json.Stringify, value: Value) WriteError!void {
    switch (value) {
        .null => try s.write(null),
        .bool => |b| try s.write(b),
        .integer => |i| try s.write(i),
        .float => |x| {
            if (!std.math.isFinite(x)) return error.NotJson;
            try s.write(x);
        },
        // An integer past an i64, as written: JSON's numbers have no
        // bound, so a decimal one is written as it is.
        .number_string => |text| if (isDecimal(text)) try s.print("{s}", .{text}) else try s.write(text),
        .string => |text| try s.write(text),
        .sequence => |items| {
            try s.beginArray();
            for (items) |item| try writeValue(arena, s, item);
            try s.endArray();
        },
        .mapping => |pairs| {
            try s.beginObject();
            for (pairs) |pair| {
                try s.objectField(try keyText(arena, pair.key));
                try writeValue(arena, s, pair.value);
            }
            try s.endObject();
        },
    }
}

fn isDecimal(text: []const u8) bool {
    const digits = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return text[0] != '+';
}

/// A mapping key as JSON's object keys are: a string.
fn keyText(arena: Allocator, key: Value) WriteError![]const u8 {
    return switch (key) {
        .string, .number_string => |text| text,
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |x| if (std.math.isFinite(x)) try std.fmt.allocPrint(arena, "{d}", .{x}) else error.NotJson,
        .sequence, .mapping => error.NotJson,
    };
}

/// A JSON value as a Value, its objects' keys in their order.
pub fn fromJson(arena: Allocator, json: std.json.Value) Allocator.Error!Value {
    return switch (json) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |x| .{ .float = x },
        .number_string => |text| .{ .number_string = text },
        .string => |text| .{ .string = text },
        .array => |array| array: {
            const items = try arena.alloc(Value, array.items.len);
            for (items, array.items) |*v, item| v.* = try fromJson(arena, item);
            break :array .{ .sequence = items };
        },
        .object => |object| object: {
            const pairs = try arena.alloc(Value.Pair, object.count());
            var it = object.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                pairs[i] = .{ .key = .{ .string = entry.key_ptr.* }, .value = try fromJson(arena, entry.value_ptr.*) };
            }
            break :object .{ .mapping = pairs };
        },
    };
}
