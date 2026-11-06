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
//! `error.UnexpectedType`, and `ParseOptions.diagnostic` says where. So
//! is a scalar whose text is not what its tag says, `!!int foo`, whatever
//! it is read into.
//!
//! A type may build itself, as std.json's `jsonParse` lets one: with a
//! `pub fn yamlParse(c: Construction) ParseError!@This()`, which gets
//! the node and builds its parts as other types (`Construction`).
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

/// How `parseFromSlice` reads a document.
pub const ParseOptions = struct {
    /// How nodes with no specific tag get one.
    schema: schema.Schema = .core,
    /// What to do with a mapping's second key equal to an earlier one:
    /// refuse it, or keep it, a struct field then taking the last.
    duplicate_keys: @FieldType(Composer.Options, "duplicate_keys") = .refuse,
    /// Skip a mapping key no field of a struct is named.
    ignore_unknown_fields: bool = false,
    /// The most nodes construction builds through aliases.
    max_alias_nodes: usize = 1_000_000,
    /// The deepest construction goes into a document, and the most
    /// collections the scanner lets be open at once. Construction
    /// recurses a level for each collection and each pointer it follows,
    /// and a level takes about 1.7 KiB of stack in a Debug build and
    /// 0.35 KiB in a release one, more for a struct or array whose own
    /// size is large. The default's deepest documents need under 512 KiB
    /// in Debug (a test holds them to it) and 128 KiB in release.
    max_depth: usize = 256,
    /// The most %TAG directives a document may have.
    max_tag_directives: usize = 64,
    /// Set to where and why parsing or construction failed.
    diagnostic: ?*Diagnostic = null,
};

/// Reading's errors: decoding's, composing's, and construction's.
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

/// A value and the arena that holds what it points at, which `deinit`
/// frees. Not threadsafe.
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
        .max_tag_directives = options.max_tag_directives,
    });
    defer composer.deinit();
    const document = try composeOne(&composer, options);
    var builder: Builder = .{ .allocator = result, .scratch = scratch, .options = options, .seed = composer.seed };
    defer builder.visiting.deinit(scratch);
    defer builder.path.deinit(scratch);
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
    /// The seed of every map built, from a hash of the input.
    seed: u64 = 0,
    /// Where construction is in the document, from its root.
    path: std.ArrayList(Segment) = .empty,

    /// Fails at `node`, with the path to it.
    fn fail(b: *const Builder, node: *const Node, err: ParseError, message: []const u8) ParseError {
        _ = b.locate(node, message);
        return err;
    }

    /// Fails at `node`, which is not the `what` expected there, with the
    /// path to it and a detail saying what it is instead.
    fn failExpected(b: *const Builder, node: *const Node, comptime what: []const u8) ParseError {
        return b.failDetail(node, error.UnexpectedType, "expected " ++ what, "expected " ++ what ++ ", found {f}", .{Found{ .node = node.target() }});
    }

    /// Fails at `node`, with the path to it and a detail.
    fn failDetail(b: *const Builder, node: *const Node, err: ParseError, message: []const u8, comptime detail: []const u8, args: anytype) ParseError {
        const d = b.locate(node, message) orelse return err;
        d.setDetail(detail, args);
        return err;
    }

    /// Sets the caller's diagnostic to `node`'s place and the path to it;
    /// null when the caller gave none.
    fn locate(b: *const Builder, node: *const Node, message: []const u8) ?*Diagnostic {
        const d = b.options.diagnostic orelse return null;
        d.* = .{ .mark = node.start, .message = message };
        d.setPath("{f}", .{PathText{ .segments = b.path.items }});
        return d;
    }

    fn pushPath(b: *Builder, segment: Segment) ParseError!void {
        try b.path.append(b.scratch, segment);
    }

    fn popPath(b: *Builder) void {
        _ = b.path.pop();
    }

    fn build(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        try b.checkLimits(node, depth);
        if (node.data == .alias) return b.buildAlias(T, node, depth);
        if (node.data == .scalar) try b.checkScalar(node);
        if (T == Value) return b.buildValue(node, depth);
        if (comptime hasParseHook(T)) return b.buildWithHook(T, node, depth);
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

    /// Builds a `T` with its own `yamlParse`, its node, a collection,
    /// marked as being built, so an alias to it inside it is a cycle.
    fn buildWithHook(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        if (node.data != .scalar) try b.enter(node);
        defer if (node.data != .scalar) b.leave(node);
        return T.yamlParse(.{ .node = node, .builder = b, .depth = depth });
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
        if (!isNull(node)) return b.failExpected(node, "nothing here, as for a union field with no value");
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
        if (node.data != .scalar) return b.failExpected(node, what);
        return node.data.scalar.value;
    }

    /// A key's text, to find a field by: a scalar, refused as `build`
    /// refuses one if its text is not what its tag says.
    fn nameOf(b: *const Builder, key: *const Node) ParseError![]const u8 {
        const name = try b.scalarOf(key, "a field name");
        try b.checkScalar(key);
        return name;
    }

    /// Refuses a scalar whose text is not what its tag says, `!!int foo`:
    /// the core tags for null, booleans, integers and floats each take
    /// only their own forms (YAML 1.2.2, 10.3.2).
    fn checkScalar(b: *const Builder, node: *const Node) ParseError!void {
        const tag = node.tag orelse return;
        const text = node.data.scalar.value;
        if (schema.fitsTag(tag, text)) return;
        return b.failDetail(node, error.UnexpectedType, "a scalar's text is not what its tag says", "the scalar \"{f}\" is tagged !!{s} but is not {s}", .{
            std.zig.fmtString(cutUtf8(text, 40)), tag[schema.core_prefix.len..], tagSays(tag),
        });
    }

    fn buildBool(b: *const Builder, node: *const Node) ParseError!bool {
        const text = try b.scalarOf(node, "a boolean");
        if (!hasTag(node, schema.tag.bool)) return b.failExpected(node, "a boolean");
        return schema.parseBool(text) orelse b.failExpected(node, "a boolean");
    }

    fn buildInt(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "an integer");
        // `build` saw that the text is an integer: null here is too big.
        if (hasTag(node, schema.tag.int)) return schema.parseIntAs(T, text) orelse b.tooBig(T, node, text);
        if (hasTag(node, schema.tag.float)) {
            const x = schema.parseFloat(text) orelse return b.failExpected(node, "an integer");
            if (@trunc(x) != x or !std.math.isFinite(x)) return b.fail(node, error.UnexpectedType, "expected an integer, found a fraction");
            if (!wholeFits(T, x)) return b.tooBig(T, node, text);
            return wholeToInt(T, x);
        }
        return b.failExpected(node, "an integer");
    }

    /// Whether the whole number `x` is in `T`'s range. The bounds are
    /// powers of two, which an f64 holds exactly: `maxInt(T)` as an f64
    /// rounds up to 2^bits for a type wider than 53 bits, past the range,
    /// and converting that is a panic, or in ReleaseFast undefined.
    fn wholeFits(comptime T: type, x: f64) bool {
        const info = @typeInfo(T).int;
        const signed = info.signedness == .signed;
        const upper: f64 = comptime std.math.ldexp(@as(f64, 1), info.bits - @intFromBool(signed));
        const lower: f64 = if (signed) -upper else 0;
        return x >= lower and x < upper;
    }

    /// The whole number `x`, which `wholeFits` a `T`, as a `T`. LLVM has
    /// no call converting a float to an integer wider than 128 bits
    /// (aarch64's at least), so such a `T` is built from `x`'s
    /// significand, a 53-bit integer, shifted by its exponent: exact, as
    /// `x` is whole.
    fn wholeToInt(comptime T: type, x: f64) T {
        const info = @typeInfo(T).int;
        if (info.bits <= 128) return @trunc(x);
        if (x == 0) return 0;
        const parts = std.math.frexp(@abs(x));
        const significand: u64 = @trunc(std.math.ldexp(parts.significand, 53));
        const shift = parts.exponent - 53;
        const Magnitude = @Int(.unsigned, info.bits);
        const magnitude: Magnitude = if (shift >= 0) @as(Magnitude, significand) << @intCast(shift) else significand >> @intCast(-shift);
        return @bitCast(if (x < 0) 0 -% magnitude else magnitude);
    }

    fn tooBig(b: *const Builder, comptime T: type, node: *const Node, text: []const u8) ParseError {
        return b.failDetail(node, error.Overflow, "the integer does not fit the type asked for", "the integer {s} does not fit a {s}", .{ text, @typeName(T) });
    }

    fn buildFloat(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "a number");
        if (hasTag(node, schema.tag.float)) {
            const x = schema.parseFloat(text) orelse return b.failExpected(node, "a number");
            return @floatCast(x);
        }
        if (hasTag(node, schema.tag.int)) {
            const n = schema.parseInt(text) orelse return b.fail(node, error.Overflow, "the integer does not fit");
            return @floatFromInt(n);
        }
        return b.failExpected(node, "a number");
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
        const names = @typeInfo(T).@"enum".field_names;
        return b.failDetail(node, error.UnexpectedType, "no value of the enum has this name", "no value is named \"{s}\"; expected one of: {s}{f}", .{
            text, comptime joinNames(names), Suggestion{ .name = nearest(names, text) },
        });
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
        if (node.data != .sequence) return b.failExpected(node, "a sequence");
        return node.data.sequence.items;
    }

    fn buildSlice(b: *Builder, comptime T: type, comptime Child: type, node: *const Node, depth: usize) ParseError!T {
        const items = try b.itemsOf(node);
        try b.enter(node);
        defer b.leave(node);
        const sentinel = @typeInfo(T).pointer.sentinel();
        const out = if (sentinel) |s| try b.allocator.allocSentinel(Child, items.len, s) else try b.allocator.alloc(Child, items.len);
        for (items, out, 0..) |item, *slot, i| slot.* = try b.buildItem(Child, item, i, depth);
        return out;
    }

    /// Builds the item at `index` of a sequence, the index on the path.
    fn buildItem(b: *Builder, comptime T: type, item: *const Node, index: usize, depth: usize) ParseError!T {
        try b.pushPath(.{ .index = index });
        defer b.popPath();
        return b.build(T, item, depth + 1);
    }

    /// Builds the value at `name` of a mapping, the name on the path.
    fn buildNamed(b: *Builder, comptime T: type, value: *const Node, name: []const u8, depth: usize) ParseError!T {
        try b.pushPath(.{ .name = name });
        defer b.popPath();
        return b.build(T, value, depth + 1);
    }

    fn buildArray(b: *Builder, comptime T: type, comptime Child: type, node: *const Node, depth: usize) ParseError!T {
        const items = try b.itemsOf(node);
        if (items.len != @typeInfo(T).array.len) return b.fail(node, error.UnexpectedType, "the sequence's length is not the array's");
        try b.enter(node);
        defer b.leave(node);
        var out: T = undefined;
        for (items, &out, 0..) |item, *slot, i| slot.* = try b.buildItem(Child, item, i, depth);
        return out;
    }

    fn pairsOf(b: *const Builder, node: *const Node) ParseError![]const Node.Pair {
        if (node.data != .mapping) return b.failExpected(node, "a mapping");
        return node.data.mapping.pairs;
    }

    fn buildStruct(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"struct";
        if (info.is_tuple) return b.buildTuple(T, node, depth);
        if (comptime @hasDecl(T, "yaml_map_value")) return b.buildMap(T, node, depth);
        const pairs = try b.pairsOf(node);
        try b.enter(node);
        defer b.leave(node);
        var out: T = undefined;
        var seen: [info.field_names.len]bool = @splat(false);
        for (pairs) |pair| {
            const key = pair.key.target();
            const name = try b.nameOf(key);
            if (!try b.buildField(T, &out, &seen, name, pair.value, depth)) {
                if (!b.options.ignore_unknown_fields) return b.unknownField(info.field_names, key, name, "no field of the struct has this name");
            }
        }
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
            if (!seen[i]) @field(out, name) = attrs.defaultValue(Field) orelse
                return b.failDetail(node, error.MissingField, "the mapping has no key for a field with no default", "missing field \"{s}\"", .{name});
        }
        return out;
    }

    /// Fails at `key`, which no field in `names` has, naming them and the
    /// nearest if one is near.
    fn unknownField(b: *const Builder, comptime names: anytype, key: *const Node, name: []const u8, message: []const u8) ParseError {
        return b.failDetail(key, error.UnknownField, message, "unknown field \"{s}\"; expected one of: {s}{f}", .{
            name, comptime joinNames(names), Suggestion{ .name = nearest(names, name) },
        });
    }

    /// A `map.ArrayHashMap`: each scalar key's text to its value built as
    /// the map's value type, in the document's order. With duplicate keys
    /// kept, a later key's value replaces the earlier's, in its place.
    fn buildMap(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const pairs = try b.pairsOf(node);
        try b.enter(node);
        defer b.leave(node);
        var out: T = .{ .context = .{ .seed = b.seed } };
        try out.map.ensureTotalCapacityContext(b.allocator, pairs.len, out.context);
        for (pairs) |pair| {
            const key = pair.key.target();
            if (key.data != .scalar) return b.fail(key, error.UnexpectedType, "a map's keys are scalars, and this is a collection");
            try b.checkScalar(key);
            const value = try b.buildNamed(T.yaml_map_value, pair.value, key.data.scalar.value, depth);
            const entry = out.map.getOrPutAssumeCapacityContext(key.data.scalar.value, out.context);
            if (!entry.found_existing) entry.key_ptr.* = try b.allocator.dupe(u8, key.data.scalar.value);
            entry.value_ptr.* = value;
        }
        return out;
    }

    /// Builds the field `name` of `out` from `value`; false when no field
    /// has that name.
    fn buildField(b: *Builder, comptime T: type, out: *T, seen: []bool, name: []const u8, value: *const Node, depth: usize) ParseError!bool {
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, 0..) |field, Field, i| {
            if (std.mem.eql(u8, field, name)) {
                @field(out, field) = try b.buildNamed(Field, value, field, depth);
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
        inline for (info.field_types, 0..) |Field, i| out[i] = try b.buildItem(Field, items[i], i, depth);
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
        const name = try b.nameOf(pairs[0].key.target());
        try b.enter(node);
        defer b.leave(node);
        inline for (info.field_names, info.field_types) |field, Field| {
            if (std.mem.eql(u8, field, name)) return @unionInit(T, field, try b.buildNamed(Field, pairs[0].value, field, depth));
        }
        return b.unknownField(info.field_names, pairs[0].key, name, "no field of the union has this name");
    }

    fn buildValue(b: *Builder, node: *const Node, depth: usize) ParseError!Value {
        switch (node.data) {
            .scalar => |s| return b.scalarValue(node, s.value),
            .sequence => |s| {
                try b.enter(node);
                defer b.leave(node);
                const out = try b.allocator.alloc(Value, s.items.len);
                for (s.items, out, 0..) |item, *slot, i| slot.* = try b.buildItem(Value, item, i, depth);
                return .{ .sequence = out };
            },
            .mapping => |m| {
                try b.enter(node);
                defer b.leave(node);
                const out = try b.allocator.alloc(Value.Pair, m.pairs.len);
                for (m.pairs, out) |pair, *slot| slot.* = .{
                    .key = try b.build(Value, pair.key, depth + 1),
                    .value = try b.buildNamed(Value, pair.value, keyName(pair.key), depth),
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

/// What a type's own `yamlParse` is given to build itself: the node,
/// and construction, to build what is in the node as other types with
/// the path, the limits, alias counting and the diagnostic kept. A type
/// declares
///
///     pub fn yamlParse(c: yaml.Construction) yaml.ParseError!@This()
///
/// and construction calls it for each node it builds as that type: an
/// alias's target in place of the alias, a scalar already checked
/// against its tag.
pub const Construction = struct {
    /// The node to build the type from.
    node: *const Node,
    /// Construction's own.
    builder: *Builder,
    depth: usize,

    /// The allocator what is built lives in: the result's arena under
    /// `parseFromSlice`. Nothing in it is freed piece by piece.
    pub fn allocator(c: Construction) Allocator {
        return c.builder.allocator;
    }

    /// Builds `node`, this one or one in it, as a `T`, a level deeper,
    /// the path as it is.
    pub fn build(c: Construction, comptime T: type, node: *const Node) ParseError!T {
        return c.builder.build(T, node, c.depth + 1);
    }

    /// Builds `node`, the value of this mapping's key `name`, as a `T`,
    /// with `name` on the path.
    pub fn buildNamed(c: Construction, comptime T: type, name: []const u8, node: *const Node) ParseError!T {
        return c.builder.buildNamed(T, node, name, c.depth);
    }

    /// Builds `node`, the item at `index` of this sequence, as a `T`,
    /// with the index on the path.
    pub fn buildIndexed(c: Construction, comptime T: type, index: usize, node: *const Node) ParseError!T {
        return c.builder.buildItem(T, node, index, c.depth);
    }

    /// Fails with `error.UnexpectedType` at `node`, the path to it and
    /// `message` in the diagnostic.
    pub fn fail(c: Construction, node: *const Node, comptime message: []const u8) ParseError {
        return c.builder.fail(node, error.UnexpectedType, message);
    }

    /// Fails at `node`, which is not the `what` expected there: `expected
    /// a command, found a sequence`.
    pub fn failExpected(c: Construction, node: *const Node, comptime what: []const u8) ParseError {
        return c.builder.failExpected(node, what);
    }
};

/// Whether `T` builds itself with a `yamlParse` (`Construction`).
fn hasParseHook(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "yamlParse"),
        else => false,
    };
}

/// A step of the path from a document's root: a mapping's key, or a
/// sequence's index.
const Segment = union(enum) { name: []const u8, index: usize };

/// A key as the path names it: a scalar's text, or `?` for a collection.
fn keyName(key: *const Node) []const u8 {
    const k = key.target();
    return if (k.data == .scalar) k.data.scalar.value else "?";
}

/// The path as `Diagnostic.path` writes it: `a.b[2]."c d"`.
const PathText = struct {
    segments: []const Segment,

    pub fn format(p: PathText, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (p.segments, 0..) |segment, i| switch (segment) {
            .index => |n| try w.print("[{d}]", .{n}),
            .name => |name| {
                if (i > 0) try w.writeByte('.');
                if (isWord(name)) try w.writeAll(name) else try w.print("\"{f}\"", .{std.zig.fmtString(name)});
            },
        };
    }
};

/// Whether `text` needs no quotes in a path: letters, digits, `_`, `-`.
fn isWord(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// What a node is, for "found ...": `a mapping`, `null`, `the integer
/// 300`, `the string "web"` (its first 40 bytes).
const Found = struct {
    node: *const Node,

    pub fn format(f: Found, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const n = f.node;
        switch (n.data) {
            .sequence => return w.writeAll("a sequence"),
            .mapping => return w.writeAll("a mapping"),
            .alias => return w.writeAll("an alias"),
            .scalar => |s| return writeScalar(w, n.tag orelse "", s.value),
        }
    }

    fn writeScalar(w: *std.Io.Writer, tag: []const u8, text: []const u8) std.Io.Writer.Error!void {
        if (std.mem.eql(u8, tag, schema.tag.null)) return w.writeAll("null");
        if (std.mem.eql(u8, tag, schema.tag.bool)) return w.print("the boolean {s}", .{text});
        if (std.mem.eql(u8, tag, schema.tag.int)) return w.print("the integer {s}", .{text});
        if (std.mem.eql(u8, tag, schema.tag.float)) return w.print("the float {s}", .{text});
        if (!std.mem.eql(u8, tag, schema.tag.str)) return w.print("a scalar tagged {s}", .{tag});
        const shown = cutUtf8(text, 40);
        try w.print("the string \"{f}\"{s}", .{ std.zig.fmtString(shown), if (shown.len < text.len) "..." else "" });
    }
};

/// The first `max` bytes of `text`, or fewer so as not to cut a
/// character.
fn cutUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// `names` joined with commas, at compile time.
fn joinNames(comptime names: anytype) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (names, 0..) |name, i| out = out ++ (if (i == 0) "" else ", ") ++ name;
        return out;
    }
}

/// ` (did you mean "x"?)` when a name is near, else nothing.
const Suggestion = struct {
    name: ?[]const u8,

    pub fn format(s: Suggestion, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (s.name) |n| try w.print(" (did you mean \"{s}\"?)", .{n});
    }
};

/// The name in `names` nearest `name`, if it is near: at most one edit
/// away for a short name, two for one of four letters or more, letters'
/// case not counting.
fn nearest(comptime names: anytype, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = if (name.len >= 4) 3 else 2;
    inline for (names) |candidate| {
        const d = editDistance(candidate, name);
        if (d < best_distance) {
            best = candidate;
            best_distance = d;
        }
    }
    return best;
}

/// Levenshtein distance, ignoring case; past 32 bytes, too far to tell.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return std.math.maxInt(usize);
    var row: [33]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 0..) |ca, i| {
        var diagonal = row[0];
        row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const above = row[j + 1];
            const cost: usize = @intFromBool(std.ascii.toLower(ca) != std.ascii.toLower(cb));
            row[j + 1] = @min(@min(above + 1, row[j] + 1), diagonal + cost);
            diagonal = above;
        }
    }
    return row[b.len];
}

/// What a scalar with one of the core scalar tags must be, as
/// `checkScalar` says it.
fn tagSays(tag: []const u8) []const u8 {
    if (std.mem.eql(u8, tag, schema.tag.null)) return "null";
    if (std.mem.eql(u8, tag, schema.tag.bool)) return "a boolean";
    if (std.mem.eql(u8, tag, schema.tag.int)) return "an integer";
    return "a float";
}

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
