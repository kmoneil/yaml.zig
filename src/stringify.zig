//! Stringify: Zig values to YAML text, through the emitter.
//!
//! A struct is a mapping of its fields in order, a slice, array or tuple
//! a sequence, a tagged union a mapping of one key (or, for a field with
//! no value, the field's name), an optional's null `null`, a pointer the
//! value it points at, a struct with pub `keys`, `values` and `count`
//! (std's array hash maps, yaml.ArrayHashMap) a mapping of its keys to
//! its values, and a `Value` what it holds. A string or an
//! enum's name is plain when a reader would read the plain text back as
//! a string, and quoted when not (`"true"`, `"123"`, `""`); a value of a
//! non-exhaustive enum with no name is its number; a float
//! always has a point or an exponent, so `1.0` does not read back as an
//! integer, and its infinities and NaN are `.inf`, `-.inf` and `.nan`.
//!
//! So `parseFromSlice` of what `stringify` writes gives the value back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("Emitter.zig");
const Parser = @import("Parser.zig");
const schema = @import("schema.zig");
const Value = @import("construct.zig").Value;
const Event = Parser.Event;

/// How `stringify` writes.
pub const StringifyOptions = struct {
    /// Block collections, one entry a line, or flow, `[a, b]` and `{k: v}`.
    style: enum { block, flow } = .block,
    /// Columns a level of block indentation takes, 2 to 8.
    indent: u8 = 2,
    /// Past this column, long text and flow collections break lines.
    width: usize = 80,
    /// Write a struct's optional field that is null, as `field: null`;
    /// when false, leave it out (reading back gives its default).
    emit_null_optional_fields: bool = true,
};

/// What writing can fail with: the writer's errors, memory, and a string
/// that is not UTF-8, which YAML cannot hold.
pub const StringifyError = std.Io.Writer.Error || Allocator.Error || error{InvalidUtf8};

/// Writes `value` as one YAML document to `writer`.
pub fn stringify(gpa: Allocator, value: anytype, options: StringifyOptions, writer: *std.Io.Writer) StringifyError!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s: Stringifier = .{
        .emitter = .init(gpa, writer, .{ .indent = options.indent, .width = options.width }),
        .arena = arena.allocator(),
        .options = options,
    };
    defer s.emitter.deinit();
    try s.emit(.stream_start);
    try s.emit(.{ .document_start = .{ .explicit = false } });
    try s.write(value);
    try s.emit(.{ .document_end = .{ .explicit = false } });
    try s.emit(.stream_end);
}

/// `stringify` into a new slice the caller frees. Its writer fails only
/// for want of memory, so its errors are StringifyError's but that.
pub fn stringifyAlloc(gpa: Allocator, value: anytype, options: StringifyOptions) (Allocator.Error || error{InvalidUtf8})![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    stringify(gpa, value, options, &out.writer) catch |err| return switch (err) {
        // An allocating writer fails only for want of memory (kb/t1).
        error.WriteFailed => error.OutOfMemory,
        else => |e| e,
    };
    return out.toOwnedSlice();
}

const Stringifier = struct {
    emitter: Emitter,
    /// Text made here (numbers), which must outlive the events naming it.
    arena: Allocator,
    options: StringifyOptions,

    fn emit(s: *Stringifier, data: Event.Data) StringifyError!void {
        s.emitter.emit(.{ .start = .{}, .end = .{}, .data = data }) catch |err| return switch (err) {
            // Its events come in a stream's order, collections balanced
            // as the value nests, and name no anchor and no tag.
            error.UnexpectedEvent, error.InvalidName => unreachable,
            else => |e| e,
        };
    }

    /// Whether `T` is written as a map: std's array hash maps and
    /// yaml.ArrayHashMap have these, and a struct of a caller's that has
    /// all three is taken for one.
    fn flow(s: *const Stringifier) bool {
        return s.options.style == .flow;
    }

    fn scalar(s: *Stringifier, value: []const u8, style: Parser.ScalarStyle) StringifyError!void {
        try s.emit(.{ .scalar = .{ .value = value, .style = style } });
    }

    /// Text that must read back as a string: plain unless a reader would
    /// read the plain text as something else.
    fn string(s: *Stringifier, text: []const u8) StringifyError!void {
        const as_plain = schema.resolvePlain(.core, text) orelse schema.tag.str;
        const style: Parser.ScalarStyle = if (std.mem.eql(u8, as_plain, schema.tag.str)) .plain else .single_quoted;
        try s.scalar(text, style);
    }

    fn format(s: *Stringifier, comptime fmt: []const u8, args: anytype) StringifyError!void {
        try s.scalar(try s.arena.print(fmt, args), .plain);
    }

    fn write(s: *Stringifier, value: anytype) StringifyError!void {
        const T = @TypeOf(value);
        if (T == Value) return s.writeValue(value);
        switch (@typeInfo(T)) {
            .bool => try s.scalar(if (value) "true" else "false", .plain),
            .int, .comptime_int => try s.format("{d}", .{value}),
            .float, .comptime_float => try s.writeFloat(@as(f64, value)),
            .null => try s.scalar("null", .plain),
            .optional => if (value) |v| try s.write(v) else try s.scalar("null", .plain),
            // @tagName of a value with no name is a panic, or undefined.
            .@"enum" => if (std.enums.tagName(T, value)) |name| try s.string(name) else try s.format("{d}", .{@backingInt(value)}),
            .enum_literal => try s.string(@tagName(value)),
            .@"struct" => try s.writeStruct(value),
            .@"union" => try s.writeUnion(value),
            .array => try s.writeSlice(&value),
            .pointer => try s.writePointer(value),
            else => @compileError("yaml cannot stringify a " ++ @typeName(T)),
        }
    }

    fn writeFloat(s: *Stringifier, x: f64) StringifyError!void {
        if (std.math.isNan(x)) return s.scalar(".nan", .plain);
        if (std.math.isInf(x)) return s.scalar(if (x > 0) ".inf" else "-.inf", .plain);
        const text = try s.arena.print("{d}", .{x});
        // `1` would read back as an integer.
        const whole = std.mem.findAny(u8, text, ".e") == null;
        try s.scalar(if (whole) try std.mem.concat(s.arena, u8, &.{ text, ".0" }) else text, .plain);
    }

    fn writePointer(s: *Stringifier, value: anytype) StringifyError!void {
        const info = @typeInfo(@TypeOf(value)).pointer;
        switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                // A pointer to an array is the array: a string literal too.
                .array => |a| if (a.child == u8) try s.string(value) else try s.writeSlice(value),
                else => try s.write(value.*),
            },
            .slice => if (info.child == u8) try s.string(value) else try s.writeSlice(value),
            else => @compileError("yaml cannot stringify a " ++ @typeName(@TypeOf(value))),
        }
    }

    fn writeSlice(s: *Stringifier, items: anytype) StringifyError!void {
        try s.emit(.{ .sequence_start = .{ .flow = s.flow() } });
        for (items) |item| try s.write(item);
        try s.emit(.sequence_end);
    }

    fn writeStruct(s: *Stringifier, value: anytype) StringifyError!void {
        const T = @TypeOf(value);
        const info = @typeInfo(T).@"struct";
        if (info.is_tuple) {
            try s.emit(.{ .sequence_start = .{ .flow = s.flow() } });
            inline for (0..info.field_types.len) |i| try s.write(value[i]);
            return s.emit(.sequence_end);
        }
        if (comptime isMapType(T)) return s.writeMap(value);
        try s.emit(.{ .mapping_start = .{ .flow = s.flow() } });
        inline for (info.field_names, info.field_types) |name, Field| {
            const field = @field(value, name);
            const skip = @typeInfo(Field) == .optional and field == null and !s.options.emit_null_optional_fields;
            if (!skip) {
                try s.string(name);
                try s.write(field);
            }
        }
        try s.emit(.mapping_end);
    }

    fn isMapType(comptime T: type) bool {
        return @hasDecl(T, "keys") and @hasDecl(T, "values") and @hasDecl(T, "count");
    }

    fn writeMap(s: *Stringifier, map: anytype) StringifyError!void {
        try s.emit(.{ .mapping_start = .{ .flow = s.flow() } });
        for (map.keys(), map.values()) |key, value| {
            try s.write(key);
            try s.write(value);
        }
        try s.emit(.mapping_end);
    }

    fn writeUnion(s: *Stringifier, value: anytype) StringifyError!void {
        const T = @TypeOf(value);
        if (@typeInfo(T).@"union".tag_type == null) @compileError("yaml cannot stringify the untagged union " ++ @typeName(T));
        switch (value) {
            inline else => |payload, tag| {
                if (@TypeOf(payload) == void) return s.string(@tagName(tag));
                try s.emit(.{ .mapping_start = .{ .flow = s.flow() } });
                try s.string(@tagName(tag));
                try s.write(payload);
                try s.emit(.mapping_end);
            },
        }
    }

    fn writeValue(s: *Stringifier, value: Value) StringifyError!void {
        switch (value) {
            .null => try s.scalar("null", .plain),
            .bool => |b| try s.write(b),
            .integer => |i| try s.write(i),
            .float => |x| try s.writeFloat(x),
            .number_string => |text| try s.scalar(text, .plain),
            .string => |text| try s.string(text),
            .sequence => |items| try s.writeSlice(items),
            .mapping => |pairs| {
                try s.emit(.{ .mapping_start = .{ .flow = s.flow() } });
                for (pairs) |pair| {
                    try s.writeValue(pair.key);
                    try s.writeValue(pair.value);
                }
                try s.emit(.mapping_end);
            },
        }
    }
};
