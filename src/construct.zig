//! Typed construction: a document's nodes to Zig values, the last stage
//! of YAML 1.2.2's loading, shaped like std.json.
//!
//! `parseFromSlice` reads one document into a `T` and returns it with the
//! arena that holds what it points at; `parseFromSliceLeaky` builds into
//! an allocator the caller frees as a whole. A `Value` holds a document
//! of any shape.
//!
//! A node fits a type by its resolved tag (the schema's, under
//! `ParseOptions.schema`): a boolean for `bool`, an integer for an
//! integer type (a float with no fraction too), a number for a float
//! type, null for an optional's null, a sequence for an array or a slice,
//! a mapping for a struct (by field name) or a tagged union (one key, the
//! field), a string for an enum (by name) and for a string type, which
//! also takes the text of a number or a boolean. Anything else is
//! `error.UnexpectedType`, and `ParseOptions.diagnostic` says where.
//!
//! An alias builds its node again, so a document can say much more than
//! it is long: nodes built through aliases are counted and held to
//! `max_alias_nodes`. A document whose aliases make a cycle cannot be a
//! Zig value (`error.Cycle`), and construction recurses, so it is held to
//! `max_depth`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Composer = @import("Composer.zig");
const encoding = @import("encoding.zig");
const schema = @import("schema.zig");
const Node = Composer.Node;
const Diagnostic = Composer.Diagnostic;

pub const ParseOptions = struct {
    schema: schema.Schema = .core,
    /// What to do with a mapping's second key equal to an earlier one:
    /// refuse it, or keep it, a struct field then taking the last.
    duplicate_keys: @FieldType(Composer.Options, "duplicate_keys") = .refuse,
    /// Skip a mapping key no field of a struct is named.
    ignore_unknown_fields: bool = false,
    /// The most nodes construction builds through aliases.
    max_alias_nodes: usize = 1_000_000,
    /// The deepest construction goes into a document, and the most
    /// collections the scanner lets be open at once.
    max_depth: usize = 1_000,
    /// Set to where and why parsing or construction failed.
    diagnostic: ?*Diagnostic = null,
};

pub const ParseError = Composer.Error || encoding.Error || error{
    /// The stream holds more than one document.
    MultipleDocuments,
    /// A node does not fit the type asked for.
    UnexpectedType,
    /// A number does not fit the integer type asked for.
    Overflow,
    /// A struct field with no default has no key.
    MissingField,
    /// A mapping key names no field of the struct.
    UnknownField,
    /// The document's aliases make a cycle.
    Cycle,
    /// Building the document would build more than `max_alias_nodes`
    /// nodes through aliases.
    AliasLimit,
    /// The document is deeper than `max_depth`.
    DepthLimit,
};

/// A value and the arena that holds what it points at.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

/// Reads the one document in `input`, UTF-8, UTF-16 or UTF-32, into a
/// `T`. An empty stream is an empty document, which is null. Free the
/// result with `deinit`.
pub fn parseFromSlice(comptime T: type, gpa: Allocator, input: []const u8, options: ParseOptions) ParseError!Parsed(T) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    return .{ .arena = arena, .value = try build(T, arena.allocator(), gpa, input, options) };
}

/// Reads the one document in `input` into a `T` built in `allocator`,
/// which should be an arena: nothing is freed piece by piece.
pub fn parseFromSliceLeaky(comptime T: type, allocator: Allocator, input: []const u8, options: ParseOptions) ParseError!T {
    return build(T, allocator, allocator, input, options);
}

fn build(comptime T: type, result: Allocator, scratch: Allocator, bytes: []const u8, options: ParseOptions) ParseError!T {
    const input = try encoding.toUtf8(scratch, bytes, options.diagnostic);
    defer if (input.ptr != bytes.ptr) scratch.free(input);
    var composer: Composer = .init(scratch, input, .{
        .schema = options.schema,
        .duplicate_keys = options.duplicate_keys,
        .max_depth = options.max_depth,
    });
    defer composer.deinit();
    const document = try composeOne(&composer, options);
    var builder: Builder = .{ .allocator = result, .scratch = scratch, .options = options };
    defer builder.visiting.deinit(scratch);
    const root: *const Node = if (document) |d| d.root else &empty_document;
    return builder.build(T, root, 0);
}

/// An empty stream's node: the empty document's null.
const empty_document: Node = .{ .start = .{}, .end = .{}, .tag = schema.tag.null, .data = .{ .scalar = .{ .value = "", .style = .plain } } };

fn composeOne(composer: *Composer, options: ParseOptions) ParseError!?Composer.Document {
    const document = composer.next() catch |err| return report(options, composer.diagnostic, err);
    if (document == null) return null;
    const another = composer.next() catch |err| return report(options, composer.diagnostic, err);
    if (another) |a| return report(options, .{ .mark = a.start, .message = "a value is read from one document, and this stream has more" }, error.MultipleDocuments);
    return document;
}

fn report(options: ParseOptions, diagnostic: Diagnostic, err: ParseError) ParseError {
    if (options.diagnostic) |d| d.* = diagnostic;
    return err;
}

const Builder = struct {
    allocator: Allocator,
    scratch: Allocator,
    options: ParseOptions,
    /// The collections being built: an alias to one is a cycle.
    visiting: std.AutoHashMapUnmanaged(*const Node, void) = .empty,
    /// How many aliases deep construction is.
    alias_depth: usize = 0,
    /// Nodes built through aliases so far.
    alias_nodes: usize = 0,

    fn fail(b: *const Builder, node: *const Node, err: ParseError, message: []const u8) ParseError {
        return report(b.options, .{ .mark = node.start, .message = message }, err);
    }

    fn build(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        try b.checkLimits(node, depth);
        if (node.data == .alias) return b.buildAlias(T, node, depth);
        if (T == Value) return b.buildValue(node, depth);
        return switch (@typeInfo(T)) {
            .void => b.buildVoid(node),
            .bool => b.buildBool(node),
            .int => b.buildInt(T, node),
            .float => b.buildFloat(T, node),
            .optional => |o| b.buildOptional(o.child, node, depth),
            .@"enum" => b.buildEnum(T, node),
            .@"struct" => b.buildStruct(T, node, depth),
            .@"union" => b.buildUnion(T, node, depth),
            .array => |a| b.buildArray(T, a.child, node, depth),
            .pointer => b.buildPointer(T, node, depth),
            else => @compileError("yaml cannot build a " ++ @typeName(T)),
        };
    }

    /// Counts a node built through an alias, and holds construction to
    /// the options' limits.
    fn checkLimits(b: *Builder, node: *const Node, depth: usize) ParseError!void {
        if (depth > b.options.max_depth) return b.fail(node, error.DepthLimit, "the document is deeper than max_depth");
        if (b.alias_depth == 0) return;
        b.alias_nodes += 1;
        if (b.alias_nodes > b.options.max_alias_nodes) return b.fail(node, error.AliasLimit, "aliases would build more than max_alias_nodes nodes");
    }

    /// A union's field with no value, as in `{off: }`.
    fn buildVoid(b: *const Builder, node: *const Node) ParseError!void {
        if (!isNull(node)) return b.fail(node, error.UnexpectedType, "expected nothing here, as for a union field with no value");
    }

    fn buildOptional(b: *Builder, comptime Child: type, node: *const Node, depth: usize) ParseError!?Child {
        if (isNull(node)) return null;
        return try b.build(Child, node, depth);
    }

    fn buildAlias(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const target = node.target();
        if (b.visiting.contains(target)) return b.fail(node, error.Cycle, "this alias names a node it is inside: a cycle no value can hold");
        b.alias_depth += 1;
        defer b.alias_depth -= 1;
        return b.build(T, target, depth);
    }

    /// Marks a collection as being built until `leave`.
    fn enter(b: *Builder, node: *const Node) ParseError!void {
        try b.visiting.put(b.scratch, node, {});
    }

    fn leave(b: *Builder, node: *const Node) void {
        _ = b.visiting.remove(node);
    }

    fn scalarOf(b: *const Builder, node: *const Node, comptime what: []const u8) ParseError![]const u8 {
        if (node.data != .scalar) return b.fail(node, error.UnexpectedType, "expected " ++ what ++ ", found a collection");
        return node.data.scalar.value;
    }

    fn buildBool(b: *const Builder, node: *const Node) ParseError!bool {
        const text = try b.scalarOf(node, "a boolean");
        if (!hasTag(node, schema.tag.bool)) return b.fail(node, error.UnexpectedType, "expected a boolean");
        return schema.parseBool(text) orelse b.fail(node, error.UnexpectedType, "expected a boolean");
    }

    fn buildInt(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "an integer");
        if (hasTag(node, schema.tag.int)) {
            const n = schema.parseInt(text) orelse return b.fail(node, error.Overflow, "the integer does not fit");
            return std.math.cast(T, n) orelse b.fail(node, error.Overflow, "the integer does not fit the type asked for");
        }
        if (hasTag(node, schema.tag.float)) {
            const x = schema.parseFloat(text) orelse return b.fail(node, error.UnexpectedType, "expected an integer");
            if (@trunc(x) != x or !std.math.isFinite(x)) return b.fail(node, error.UnexpectedType, "expected an integer, found a fraction");
            const max: f64 = @floatFromInt(std.math.maxInt(T));
            const min: f64 = @floatFromInt(std.math.minInt(T));
            if (x > max or x < min) return b.fail(node, error.Overflow, "the integer does not fit the type asked for");
            return @intFromFloat(x);
        }
        return b.fail(node, error.UnexpectedType, "expected an integer");
    }

    fn buildFloat(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "a number");
        if (hasTag(node, schema.tag.float)) {
            const x = schema.parseFloat(text) orelse return b.fail(node, error.UnexpectedType, "expected a number");
            return @floatCast(x);
        }
        if (hasTag(node, schema.tag.int)) {
            const n = schema.parseInt(text) orelse return b.fail(node, error.Overflow, "the integer does not fit");
            return @floatFromInt(n);
        }
        return b.fail(node, error.UnexpectedType, "expected a number");
    }

    fn buildEnum(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "a name");
        if (std.meta.stringToEnum(T, text)) |e| return e;
        if (hasTag(node, schema.tag.int)) {
            const n = schema.parseInt(text) orelse return b.fail(node, error.Overflow, "the integer does not fit");
            const Tag = @typeInfo(T).@"enum".tag_type;
            const raw = std.math.cast(Tag, n) orelse return b.fail(node, error.UnexpectedType, "no value of the enum has this number");
            return std.enums.fromInt(T, raw) orelse b.fail(node, error.UnexpectedType, "no value of the enum has this number");
        }
        return b.fail(node, error.UnexpectedType, "no value of the enum has this name");
    }

    fn buildString(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "a string");
        if (isNull(node)) return b.fail(node, error.UnexpectedType, "expected a string, found null");
        const sentinel = @typeInfo(T).pointer.sentinel();
        if (sentinel) |s| return try b.allocator.dupeSentinel(u8, text, s);
        return try b.allocator.dupe(u8, text);
    }

    fn buildPointer(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const info = @typeInfo(T).pointer;
        switch (info.size) {
            .one => {
                const p = try b.allocator.create(info.child);
                p.* = try b.build(info.child, node, depth + 1);
                return p;
            },
            .slice => {
                if (info.child == u8) return b.buildString(T, node);
                return b.buildSlice(T, info.child, node, depth);
            },
            else => @compileError("yaml cannot build a " ++ @typeName(T)),
        }
    }

    fn itemsOf(b: *const Builder, node: *const Node) ParseError![]const *Node {
        if (node.data != .sequence) return b.fail(node, error.UnexpectedType, "expected a sequence");
        return node.data.sequence.items;
    }

    fn buildSlice(b: *Builder, comptime T: type, comptime Child: type, node: *const Node, depth: usize) ParseError!T {
        const items = try b.itemsOf(node);
        try b.enter(node);
        defer b.leave(node);
        const sentinel = @typeInfo(T).pointer.sentinel();
        const out = if (sentinel) |s| try b.allocator.allocSentinel(Child, items.len, s) else try b.allocator.alloc(Child, items.len);
        for (items, out) |item, *slot| slot.* = try b.build(Child, item, depth + 1);
        return out;
    }

    fn buildArray(b: *Builder, comptime T: type, comptime Child: type, node: *const Node, depth: usize) ParseError!T {
        const items = try b.itemsOf(node);
        if (items.len != @typeInfo(T).array.len) return b.fail(node, error.UnexpectedType, "the sequence's length is not the array's");
        try b.enter(node);
        defer b.leave(node);
        var out: T = undefined;
        for (items, &out) |item, *slot| slot.* = try b.build(Child, item, depth + 1);
        return out;
    }

    fn pairsOf(b: *const Builder, node: *const Node) ParseError![]const Node.Pair {
        if (node.data != .mapping) return b.fail(node, error.UnexpectedType, "expected a mapping");
        return node.data.mapping.pairs;
    }

    fn buildStruct(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"struct";
        if (info.is_tuple) return b.buildTuple(T, node, depth);
        const pairs = try b.pairsOf(node);
        try b.enter(node);
        defer b.leave(node);
        var out: T = undefined;
        var seen: [info.field_names.len]bool = @splat(false);
        for (pairs) |pair| {
            const key = pair.key.target();
            const name = try b.scalarOf(key, "a field name");
            if (!try b.buildField(T, &out, &seen, name, pair.value, depth)) {
                if (!b.options.ignore_unknown_fields) return b.fail(key, error.UnknownField, "no field of the struct has this name");
            }
        }
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
            if (!seen[i]) @field(out, name) = attrs.defaultValue(Field) orelse
                return b.fail(node, error.MissingField, "the mapping has no key for a field with no default");
        }
        return out;
    }

    /// Builds the field `name` of `out` from `value`; false when no field
    /// has that name.
    fn buildField(b: *Builder, comptime T: type, out: *T, seen: []bool, name: []const u8, value: *const Node, depth: usize) ParseError!bool {
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, 0..) |field, Field, i| {
            if (std.mem.eql(u8, field, name)) {
                @field(out, field) = try b.build(Field, value, depth + 1);
                seen[i] = true;
                return true;
            }
        }
        return false;
    }

    fn buildTuple(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"struct";
        const items = try b.itemsOf(node);
        if (items.len != info.field_types.len) return b.fail(node, error.UnexpectedType, "the sequence's length is not the tuple's");
        try b.enter(node);
        defer b.leave(node);
        var out: T = undefined;
        inline for (info.field_types, 0..) |Field, i| out[i] = try b.build(Field, items[i], depth + 1);
        return out;
    }

    /// A tagged union: a mapping of one key, the field, to its value; or
    /// for a field of type void, the field's name alone.
    fn buildUnion(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"union";
        if (info.tag_type == null) @compileError("yaml cannot build the untagged union " ++ @typeName(T));
        if (node.data == .scalar) {
            inline for (info.field_names, info.field_types) |field, Field| {
                if (Field == void and std.mem.eql(u8, field, node.data.scalar.value)) return @unionInit(T, field, {});
            }
            return b.fail(node, error.UnexpectedType, "no field of the union with no value has this name");
        }
        const pairs = try b.pairsOf(node);
        if (pairs.len != 1) return b.fail(node, error.UnexpectedType, "a union is a mapping of one key, the field");
        const name = try b.scalarOf(pairs[0].key.target(), "a field name");
        try b.enter(node);
        defer b.leave(node);
        inline for (info.field_names, info.field_types) |field, Field| {
            if (std.mem.eql(u8, field, name)) return @unionInit(T, field, try b.build(Field, pairs[0].value, depth + 1));
        }
        return b.fail(pairs[0].key, error.UnknownField, "no field of the union has this name");
    }

    fn buildValue(b: *Builder, node: *const Node, depth: usize) ParseError!Value {
        switch (node.data) {
            .scalar => |s| return b.scalarValue(node, s.value),
            .sequence => |s| {
                try b.enter(node);
                defer b.leave(node);
                const out = try b.allocator.alloc(Value, s.items.len);
                for (s.items, out) |item, *slot| slot.* = try b.build(Value, item, depth + 1);
                return .{ .sequence = out };
            },
            .mapping => |m| {
                try b.enter(node);
                defer b.leave(node);
                const out = try b.allocator.alloc(Value.Pair, m.pairs.len);
                for (m.pairs, out) |pair, *slot| slot.* = .{
                    .key = try b.build(Value, pair.key, depth + 1),
                    .value = try b.build(Value, pair.value, depth + 1),
                };
                return .{ .mapping = out };
            },
            .alias => unreachable,
        }
    }

    fn scalarValue(b: *const Builder, node: *const Node, text: []const u8) ParseError!Value {
        if (hasTag(node, schema.tag.null)) return .null;
        if (hasTag(node, schema.tag.bool)) {
            if (schema.parseBool(text)) |v| return .{ .bool = v };
        } else if (hasTag(node, schema.tag.int)) {
            if (schema.parseInt(text)) |n| {
                if (std.math.cast(i64, n)) |i| return .{ .integer = i };
            }
            return .{ .number_string = try b.allocator.dupe(u8, text) };
        } else if (hasTag(node, schema.tag.float)) {
            if (schema.parseFloat(text)) |x| return .{ .float = x };
        }
        return .{ .string = try b.allocator.dupe(u8, text) };
    }
};

fn hasTag(node: *const Node, tag: []const u8) bool {
    return std.mem.eql(u8, node.tag orelse return false, tag);
}

fn isNull(node: *const Node) bool {
    return node.target().data == .scalar and hasTag(node.target(), schema.tag.null);
}

/// A document of any shape. Scalars by their resolved tag: null, a
/// boolean, an integer (`number_string` when it does not fit an i64), a
/// float, and any other scalar as a string. A mapping keeps its pairs in
/// order, and its keys may be any value.
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    /// An integer too large for an i64, as written.
    number_string: []const u8,
    string: []const u8,
    sequence: []Value,
    mapping: []Pair,

    pub const Pair = struct { key: Value, value: Value };

    /// The value of a mapping's key that is the string `key`; null if the
    /// value is no mapping or has no such key.
    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .mapping) return null;
        for (v.mapping) |pair| {
            if (pair.key == .string and std.mem.eql(u8, pair.key.string, key)) return pair.value;
        }
        return null;
    }
};
