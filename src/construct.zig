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
const chars = @import("chars.zig");
const encoding = @import("encoding.zig");
const merge = @import("merge.zig");
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
    /// Apply YAML 1.1's merge key, as most YAML readers do (merge.zig): a
    /// plain `<<: *defaults` merges that mapping's pairs into the one it
    /// is in, the mapping's own keys winning. A struct, a map and a Value
    /// take merged pairs; a type's yamlParse hook sees the mapping as it
    /// is written. Merged nodes count as an alias's toward
    /// `max_alias_nodes`. With it on, a mapping is composed whole before
    /// it is built, as its own keys win wherever they stand.
    merge_keys: bool = false,
    /// The most nodes construction builds through aliases.
    max_alias_nodes: usize = 1_000_000,
    /// The deepest construction goes into a document, and the most
    /// collections the scanner lets be open at once. Construction
    /// recurses a level for each collection and each pointer it follows,
    /// and a level takes about 1.9 KiB of stack in a Debug build and
    /// 0.75 KiB in a release one, more for a struct or array whose own
    /// size is large. The default's deepest documents need under 512 KiB
    /// in Debug (a test holds them to it) and 200 KiB in release, built
    /// with LLVM: Zig's own x86_64 backend, a Debug build's default on
    /// Linux, takes more a level.
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
    var builder: Builder = .{ .allocator = result, .scratch = scratch, .options = options, .composer = &composer };
    defer builder.visiting.deinit(scratch);
    defer builder.path.deinit(scratch);
    defer builder.stack.deinit(scratch);
    defer builder.slots.deinit(scratch);
    // The document read a node at a time as it is built (t47), so only
    // what an alias may name is held whole, not the graph.
    if (try builder.beginDocument() == null) return builder.build(T, .{ .node = &empty_document }, 0);
    var root: Node = undefined;
    const value = try builder.build(T, (try builder.step(&root)).?, 0);
    composer.endDocument() catch |err| return builder.composerFailed(err);
    if (try builder.beginDocument()) |start| {
        return report(options, .{ .mark = start, .message = "a value is read from one document, and this stream has more" }, error.MultipleDocuments);
    }
    return value;
}

/// An empty stream's node: the empty document's null.
const empty_document: Node = .{ .start = .{}, .end = .{}, .tag = schema.tag.null, .data = .{ .scalar = .{ .value = "", .style = .plain } } };

/// What construction builds a value from: a node, whole, or a collection
/// the composer has begun reading, by its node of no entries, the
/// entries the composer's steps still to come (t47).
const Src = union(enum) {
    node: *const Node,
    begun: *const Node,

    /// The node, or the begun collection's: its kind, tag and place.
    fn head(s: Src) *const Node {
        return switch (s) {
            inline else => |n| n,
        };
    }
};

/// A mapping's key, whole, and its value; `merged` when a merge key
/// brought it in (`ParseOptions.merge_keys`).
const KeyValue = struct { key: *const Node, value: Src, merged: bool = false };

/// A collection's entries as construction reads them: a node's, or the
/// composer's steps to the collection's end, one at a time.
const Entries = struct {
    b: *Builder,
    /// A mapping with its merges applied is read through `merged`, held
    /// on the scratch allocator, not in each level's stack frame, which it
    /// would swell past what max_depth's stack allows.
    from: union(enum) { items: []const *Node, pairs: []const Node.Pair, steps, merged: *merge.Pairs },
    index: usize = 0,
    /// The key and value last read from steps, by value, on the builder's
    /// `slots`: they live until the next entry is read.
    slots: *[2]Node = undefined,

    /// Gives back the slots of entries read from steps, or what a
    /// mapping's merges held.
    fn done(e: *Entries) void {
        switch (e.from) {
            .steps => e.b.slots.len -= 1,
            .merged => |m| {
                m.deinit();
                e.b.scratch.destroy(m);
            },
            .items, .pairs => {},
        }
    }

    /// How many entries there are, if known before they are read.
    fn count(e: *const Entries) ?usize {
        return switch (e.from) {
            .items => |items| items.len,
            .pairs => |pairs| pairs.len,
            .steps, .merged => null,
        };
    }

    /// A sequence's next item, or null after its last.
    fn nextItem(e: *Entries) ParseError!?Src {
        switch (e.from) {
            .items => |items| {
                if (e.index == items.len) return null;
                e.index += 1;
                return .{ .node = items[e.index - 1] };
            },
            .pairs, .merged => unreachable,
            .steps => return e.b.step(&e.slots[1]),
        }
    }

    /// A mapping's next pair, or null after its last.
    fn nextPair(e: *Entries) ParseError!?KeyValue {
        switch (e.from) {
            .pairs => |pairs| {
                if (e.index == pairs.len) return null;
                e.index += 1;
                const pair = pairs[e.index - 1];
                return .{ .key = pair.key, .value = .{ .node = pair.value } };
            },
            .items => unreachable,
            .steps => {
                // The composer gives a key whole, and a value after it.
                const key = try e.b.step(&e.slots[0]) orelse return null;
                return .{ .key = key.node, .value = (try e.b.step(&e.slots[1])).? };
            },
            .merged => |m| {
                const pair = m.next() catch |err| return e.b.mergeFailed(err, m.failed_at);
                const p = pair orelse return null;
                return .{ .key = p.key, .value = .{ .node = p.value }, .merged = p.merged };
            },
        }
    }
};

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

    /// Where construction is in the document, from its root.
    path: std.ArrayList(Segment) = .empty,
    /// What reads the document a node at a time.
    composer: *Composer,
    /// Items of the sequences read from steps, whose number is not known
    /// till their ends: one stack on the scratch allocator, a sequence's
    /// at its top while it is read, then copied into the result once, at
    /// its length (`Gathered`).
    stack: std.array_list.Aligned(u8, .@"16") = .empty,
    /// The by-value nodes of the collections read from steps, a key's and a
    /// value's for each open: here, not in each level's stack frame,
    /// which they would swell past what max_depth's stack allows.
    slots: SlotStack = .{},

    /// Gives a composer's error, its diagnostic the caller's.
    fn composerFailed(b: *const Builder, err: Composer.Error) ParseError {
        return report(b.options, b.composer.diagnostic, err);
    }

    fn beginDocument(b: *Builder) ParseError!?Diagnostic.Mark {
        return b.composer.beginDocument() catch |err| b.composerFailed(err);
    }

    /// The composer's next step as a source, null at a collection's end:
    /// a scalar's or a begun collection's node by value in `slot`.
    fn step(b: *Builder, slot: *Node) ParseError!?Src {
        return switch (b.composer.stepInto(slot) catch |err| return b.composerFailed(err)) {
            .end => null,
            .scalar => .{ .node = slot },
            .node => |n| .{ .node = n },
            .begin => .{ .begun = slot },
        };
    }

    /// `src` whole: a begun collection composed whole, for what needs a
    /// node (a type's yamlParse hook).
    fn whole(b: *Builder, src: Src) ParseError!*const Node {
        return switch (src) {
            .node => |n| n,
            .begun => |n| b.composer.finish(n.*) catch |err| b.composerFailed(err),
        };
    }

    /// Reads past a begun collection that is not built, an unknown field's
    /// value skipped: its entries' steps to its end.
    fn skip(b: *Builder, src: Src) ParseError!void {
        if (src != .begun) return;
        var open: usize = 1;
        var slot: Node = undefined;
        while (open > 0) {
            switch (b.composer.stepInto(&slot) catch |err| return b.composerFailed(err)) {
                .begin => open += 1,
                .end => open -= 1,
                .scalar, .node => {},
            }
        }
    }

    /// A collection's entries, `src` a sequence or a mapping as `kind`
    /// says, else the error.
    fn entries(b: *Builder, src: Src, comptime kind: enum { sequence, mapping }) ParseError!Entries {
        const node = src.head();
        switch (kind) {
            .sequence => if (node.data != .sequence) return b.failExpected(node, "a sequence"),
            .mapping => if (node.data != .mapping) return b.failExpected(node, "a mapping"),
        }
        return switch (src) {
            .node => |n| .{ .b = b, .from = if (kind == .sequence) .{ .items = n.data.sequence.items } else .{ .pairs = n.data.mapping.pairs } },
            .begun => .{ .b = b, .from = .steps, .slots = try b.slots.push(b.scratch) },
        };
    }

    /// A struct's, a map's or a Value's mapping: with merge keys on, its
    /// pairs with them applied, the mapping composed whole first, as its
    /// own keys win over merged ones wherever they stand.
    fn mappingEntries(b: *Builder, src: Src) ParseError!Entries {
        if (!b.options.merge_keys) return b.entries(src, .mapping);
        const node = src.head();
        if (node.data != .mapping) return b.failExpected(node, "a mapping");
        const mapping = try b.whole(src);
        const pairs = try b.scratch.create(merge.Pairs);
        errdefer b.scratch.destroy(pairs);
        pairs.* = merge.Pairs.init(b.scratch, mapping, b.composer, b.options.max_depth) catch |err| return b.mergeFailed(err, mapping);
        return .{ .b = b, .from = .{ .merged = pairs } };
    }

    /// Gives merging's error, at the node it failed at.
    fn mergeFailed(b: *const Builder, err: merge.Error, at: ?*const Node) ParseError {
        const node = at orelse return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotMergeable => b.failExpected(node, "a mapping, or a sequence of mappings, to merge"),
            error.Cycle => b.fail(node, error.Cycle, "a merge names a mapping it is merged into: a cycle no value can hold"),
            error.DepthLimit => b.fail(node, error.DepthLimit, "merges go deeper than max_depth"),
        };
    }

    /// Marks `src`, if a node, as being built until `leaveSrc`: a begun
    /// collection has no anchor, so no alias can lead into it.
    fn enterSrc(b: *Builder, src: Src) ParseError!void {
        if (src == .node) try b.enter(src.node);
    }

    fn leaveSrc(b: *Builder, src: Src) void {
        if (src == .node) b.leave(src.node);
    }

    /// Fails at `node`, with the path to it.
    fn fail(b: *const Builder, node: *const Node, err: ParseError, message: []const u8) ParseError {
        _ = b.locate(node, message);
        return err;
    }

    /// Fails at `node`, which is not the `what` expected there, with the
    /// path to it and a detail saying what it is instead.
    fn failExpected(b: *const Builder, node: *const Node, comptime what: []const u8) ParseError {
        // `what` is an argument, not part of the format: a brace in it is
        // text (t45).
        return b.failDetail(node, error.UnexpectedType, "expected " ++ what, "expected {s}, found {f}", .{ what, Found{ .node = node.target() } });
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

    fn build(b: *Builder, comptime T: type, src: Src, depth: usize) ParseError!T {
        const node = src.head();
        try b.checkLimits(node, depth);
        if (node.data == .alias) return b.buildAlias(T, node, depth);
        if (node.data == .scalar) try b.checkScalar(node);
        if (T == Value) return b.buildValue(src, depth);
        if (comptime hasParseHook(T)) return b.buildWithHook(T, try b.whole(src), depth);
        return switch (@typeInfo(T)) {
            .void => b.buildVoid(node),
            .bool => b.buildBool(node),
            .int => b.buildInt(T, node),
            .float => b.buildFloat(T, node),
            .optional => |o| b.buildOptional(o.child, src, depth),
            .@"enum" => b.buildEnum(T, node),
            .@"struct" => b.buildStruct(T, src, depth),
            .@"union" => b.buildUnion(T, src, depth),
            .array => |a| b.buildArray(T, a.child, src, depth),
            .pointer => b.buildPointer(T, src, depth),
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

    fn buildOptional(b: *Builder, comptime Child: type, src: Src, depth: usize) ParseError!?Child {
        if (isNull(src.head())) return null;
        return try b.build(Child, src, depth);
    }

    fn buildAlias(b: *Builder, comptime T: type, node: *const Node, depth: usize) ParseError!T {
        const target = node.target();
        if (b.visiting.contains(target)) return b.fail(node, error.Cycle, "this alias names a node it is inside: a cycle no value can hold");
        b.alias_depth += 1;
        defer b.alias_depth -= 1;
        return b.build(T, .{ .node = target }, depth);
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
        if (b.options.schema.fits(tag, text)) return;
        return b.failDetail(node, error.UnexpectedType, "a scalar's text is not what its tag says", "the scalar \"{f}\" is tagged !!{s} but is not {s}", .{
            Shown{ .text = cutUtf8(text, 40) }, tag[schema.core_prefix.len..], tagSays(tag),
        });
    }

    fn buildBool(b: *const Builder, node: *const Node) ParseError!bool {
        const text = try b.scalarOf(node, "a boolean");
        if (!hasTag(node, .bool)) return b.failExpected(node, "a boolean");
        return b.options.schema.boolean(text) orelse b.failExpected(node, "a boolean");
    }

    fn buildInt(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "an integer");
        // `build` saw that the text is an integer: null here is too big.
        if (hasTag(node, .int)) return b.options.schema.int(T, text) orelse b.tooBig(T, node, text);
        if (hasTag(node, .float)) {
            const x = b.options.schema.float(text) orelse return b.failExpected(node, "an integer");
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
        if (hasTag(node, .float)) {
            const x = b.options.schema.float(text) orelse return b.failExpected(node, "a number");
            return @floatCast(x);
        }
        if (hasTag(node, .int)) {
            const n = b.options.schema.int(i128, text) orelse return b.fail(node, error.Overflow, "the integer does not fit");
            return @floatFromInt(n);
        }
        return b.failExpected(node, "a number");
    }

    fn buildEnum(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "a name");
        if (std.meta.stringToEnum(T, text)) |e| return e;
        if (hasTag(node, .int)) {
            const n = b.options.schema.int(i128, text) orelse return b.fail(node, error.Overflow, "the integer does not fit");
            const Tag = @typeInfo(T).@"enum".tag_type;
            const raw = std.math.cast(Tag, n) orelse return b.fail(node, error.UnexpectedType, "no value of the enum has this number");
            return std.enums.fromInt(T, raw) orelse b.fail(node, error.UnexpectedType, "no value of the enum has this number");
        }
        const names = @typeInfo(T).@"enum".field_names;
        return b.failDetail(node, error.UnexpectedType, "no value of the enum has this name", "no value is named \"{f}\"; expected one of: {s}{f}", .{
            Shown{ .text = text }, comptime joinNames(names), Suggestion{ .name = nearest(names, text) },
        });
    }

    fn buildString(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const text = try b.scalarOf(node, "a string");
        if (isNull(node)) return b.fail(node, error.UnexpectedType, "expected a string, found null");
        const sentinel = @typeInfo(T).pointer.sentinel();
        if (sentinel) |s| return try b.allocator.dupeSentinel(u8, text, s);
        return try b.allocator.dupe(u8, text);
    }

    fn buildPointer(b: *Builder, comptime T: type, src: Src, depth: usize) ParseError!T {
        const info = @typeInfo(T).pointer;
        switch (info.size) {
            .one => {
                const p = try b.allocator.create(info.child);
                p.* = try b.build(info.child, src, depth + 1);
                return p;
            },
            .slice => {
                if (info.child == u8) return b.buildString(T, src.head());
                return b.buildSlice(T, info.child, src, depth);
            },
            else => @compileError("yaml cannot build a " ++ @typeName(T)),
        }
    }

    fn buildSlice(b: *Builder, comptime T: type, comptime Child: type, src: Src, depth: usize) ParseError!T {
        var items = try b.entries(src, .sequence);
        defer items.done();
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        // Each way its own function, so a level's stack frame, which in a
        // Debug build holds every branch's temporaries, holds one way's.
        if (items.count()) |n| return b.sliceOf(T, Child, &items, n, depth);
        return b.sliceGathered(T, Child, &items, depth);
    }

    /// A slice of `n` items, their number known before they are read:
    /// built in place.
    fn sliceOf(b: *Builder, comptime T: type, comptime Child: type, items: *Entries, n: usize, depth: usize) ParseError!T {
        const sentinel = @typeInfo(T).pointer.sentinel();
        const out = if (sentinel) |s| try b.allocator.allocSentinel(Child, n, s) else try b.allocator.alloc(Child, n);
        for (out, 0..) |*slot, i| slot.* = try b.buildItem(Child, (try items.nextItem()).?, i, depth);
        return out;
    }

    /// A slice of items read from steps, their number known at the end.
    fn sliceGathered(b: *Builder, comptime T: type, comptime Child: type, items: *Entries, depth: usize) ParseError!T {
        var gathered: Gathered(Child) = try .begin(b);
        defer gathered.end(b);
        while (try items.nextItem()) |item| try gathered.append(b, try b.buildItem(Child, item, gathered.len, depth));
        return gathered.finish(b, @typeInfo(T).pointer.sentinel());
    }

    /// Builds the item at `index` of a sequence, the index on the path.
    fn buildItem(b: *Builder, comptime T: type, item: Src, index: usize, depth: usize) ParseError!T {
        try b.pushPath(.{ .index = index });
        defer b.popPath();
        return b.build(T, item, depth + 1);
    }

    /// Builds the value at `name` of a mapping, the name on the path.
    fn buildNamed(b: *Builder, comptime T: type, value: Src, name: []const u8, depth: usize) ParseError!T {
        try b.pushPath(.{ .name = name });
        defer b.popPath();
        return b.build(T, value, depth + 1);
    }

    fn buildArray(b: *Builder, comptime T: type, comptime Child: type, src: Src, depth: usize) ParseError!T {
        const len = @typeInfo(T).array.len;
        var items = try b.entries(src, .sequence);
        defer items.done();
        if ((items.count() orelse len) != len) return b.wrongLength(src, "the sequence's length is not the array's");
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        var out: T = undefined;
        for (&out, 0..) |*slot, i| {
            const item = try items.nextItem() orelse return b.wrongLength(src, "the sequence's length is not the array's");
            slot.* = try b.buildItem(Child, item, i, depth);
        }
        if (try items.nextItem() != null) return b.wrongLength(src, "the sequence's length is not the array's");
        return out;
    }

    fn wrongLength(b: *const Builder, src: Src, message: []const u8) ParseError {
        return b.fail(src.head(), error.UnexpectedType, message);
    }

    fn buildStruct(b: *Builder, comptime T: type, src: Src, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"struct";
        if (info.is_tuple) return b.buildTuple(T, src, depth);
        if (comptime @hasDecl(T, "yaml_map_value")) return b.buildMap(T, src, depth);
        var pairs = try b.mappingEntries(src);
        defer pairs.done();
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        var out: T = undefined;
        var seen: [info.field_names.len]bool = @splat(false);
        while (try pairs.nextPair()) |pair| {
            const key = pair.key.target();
            const name = try b.nameOf(key);
            // A merged pair is built again where it is merged, as an
            // alias's node is: it counts toward max_alias_nodes.
            b.alias_depth += @intFromBool(pair.merged);
            defer b.alias_depth -= @intFromBool(pair.merged);
            if (try b.buildField(T, &out, &seen, name, pair.value, depth)) continue;
            if (!b.options.ignore_unknown_fields) return b.unknownField(info.field_names, key, name, "no field of the struct has this name");
            try b.skip(pair.value);
        }
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
            if (!seen[i]) @field(out, name) = attrs.defaultValue(Field) orelse
                return b.failDetail(src.head(), error.MissingField, "the mapping has no key for a field with no default", "missing field \"{s}\"", .{name});
        }
        return out;
    }

    /// Fails at `key`, which no field in `names` has, naming them and the
    /// nearest if one is near.
    fn unknownField(b: *const Builder, comptime names: anytype, key: *const Node, name: []const u8, message: []const u8) ParseError {
        return b.failDetail(key, error.UnknownField, message, "unknown field \"{f}\"; expected one of: {s}{f}", .{
            Shown{ .text = name }, comptime joinNames(names), Suggestion{ .name = nearest(names, name) },
        });
    }

    /// A `map.ArrayHashMap`: each scalar key's text to its value built as
    /// the map's value type, in the document's order. With duplicate keys
    /// kept, a later key's value replaces the earlier's, in its place.
    fn buildMap(b: *Builder, comptime T: type, src: Src, depth: usize) ParseError!T {
        var pairs = try b.mappingEntries(src);
        defer pairs.done();
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        var out: T = .{ .context = .{ .seed = b.composer.hashSeed() } };
        if (pairs.count()) |n| try out.map.ensureTotalCapacityContext(b.allocator, n, out.context);
        while (try pairs.nextPair()) |pair| {
            const key = pair.key.target();
            if (key.data != .scalar) return b.fail(key, error.UnexpectedType, "a map's keys are scalars, and this is a collection");
            try b.checkScalar(key);
            b.alias_depth += @intFromBool(pair.merged);
            defer b.alias_depth -= @intFromBool(pair.merged);
            const value = try b.buildNamed(T.yaml_map_value, pair.value, key.data.scalar.value, depth);
            const entry = try out.map.getOrPutContext(b.allocator, key.data.scalar.value, out.context);
            if (!entry.found_existing) entry.key_ptr.* = try b.allocator.dupe(u8, key.data.scalar.value);
            entry.value_ptr.* = value;
        }
        return out;
    }

    /// Builds the field `name` of `out` from `value`; false when no field
    /// has that name.
    fn buildField(b: *Builder, comptime T: type, out: *T, seen: []bool, name: []const u8, value: Src, depth: usize) ParseError!bool {
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

    fn buildTuple(b: *Builder, comptime T: type, src: Src, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"struct";
        const len = info.field_types.len;
        var items = try b.entries(src, .sequence);
        defer items.done();
        if ((items.count() orelse len) != len) return b.wrongLength(src, "the sequence's length is not the tuple's");
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        var out: T = undefined;
        inline for (info.field_types, 0..) |Field, i| {
            const item = try items.nextItem() orelse return b.wrongLength(src, "the sequence's length is not the tuple's");
            out[i] = try b.buildItem(Field, item, i, depth);
        }
        if (try items.nextItem() != null) return b.wrongLength(src, "the sequence's length is not the tuple's");
        return out;
    }

    /// A tagged union: a mapping of one key, the field, to its value; or
    /// for a field of type void, the field's name alone.
    fn buildUnion(b: *Builder, comptime T: type, src: Src, depth: usize) ParseError!T {
        const info = @typeInfo(T).@"union";
        if (info.tag_type == null) @compileError("yaml cannot build the untagged union " ++ @typeName(T));
        const node = src.head();
        if (node.data == .scalar) return b.unionByName(T, node);
        var pairs = try b.entries(src, .mapping);
        defer pairs.done();
        const one_key = "a union is a mapping of one key, the field";
        if ((pairs.count() orelse 1) != 1) return b.wrongLength(src, one_key);
        const pair = try pairs.nextPair() orelse return b.wrongLength(src, one_key);
        const name = try b.nameOf(pair.key.target());
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        inline for (info.field_names, info.field_types) |field, Field| {
            if (std.mem.eql(u8, field, name)) {
                const value = @unionInit(T, field, try b.buildNamed(Field, pair.value, field, depth));
                if (try pairs.nextPair() != null) return b.wrongLength(src, one_key);
                return value;
            }
        }
        return b.unknownField(info.field_names, pair.key, name, "no field of the union has this name");
    }

    /// A tagged union's field with no value, named by a scalar alone.
    fn unionByName(b: *const Builder, comptime T: type, node: *const Node) ParseError!T {
        const info = @typeInfo(T).@"union";
        inline for (info.field_names, info.field_types) |field, Field| {
            if (Field == void and std.mem.eql(u8, field, node.data.scalar.value)) return @unionInit(T, field, {});
        }
        return b.fail(node, error.UnexpectedType, "no field of the union with no value has this name");
    }

    fn buildValue(b: *Builder, src: Src, depth: usize) ParseError!Value {
        const node = src.head();
        // A dispatch only, so the stack frame of each level a Value nests
        // in holds no more than one kind's (see buildSlice).
        return switch (node.data) {
            .scalar => |s| b.scalarValue(node, s.value),
            .sequence => .{ .sequence = try b.buildSlice([]Value, Value, src, depth) },
            .mapping => .{ .mapping = try b.buildValuePairs(src, depth) },
            .alias => unreachable,
        };
    }

    /// A Value mapping's pairs in their order, a key any Value.
    fn buildValuePairs(b: *Builder, src: Src, depth: usize) ParseError![]Value.Pair {
        var pairs = try b.mappingEntries(src);
        defer pairs.done();
        try b.enterSrc(src);
        defer b.leaveSrc(src);
        var gathered: Gathered(Value.Pair) = try .begin(b);
        defer gathered.end(b);
        while (try pairs.nextPair()) |pair| {
            b.alias_depth += @intFromBool(pair.merged);
            defer b.alias_depth -= @intFromBool(pair.merged);
            try gathered.append(b, .{
                .key = try b.build(Value, .{ .node = pair.key }, depth + 1),
                .value = try b.buildNamed(Value, pair.value, keyName(pair.key), depth),
            });
        }
        return gathered.finish(b, null);
    }

    fn scalarValue(b: *const Builder, node: *const Node, text: []const u8) ParseError!Value {
        switch (schema.core(node.tag orelse "") orelse .str) {
            .null => return .null,
            .bool => if (b.options.schema.boolean(text)) |v| return .{ .bool = v },
            .int => {
                if (b.options.schema.int(i64, text)) |i| return .{ .integer = i };
                return .{ .number_string = try b.allocator.dupe(u8, text) };
            },
            .float => if (b.options.schema.float(text)) |x| return .{ .float = x },
            .str, .seq, .map => {},
        }
        return .{ .string = try b.allocator.dupe(u8, text) };
    }
};

/// The by-value nodes of the collections read from steps, a pair a
/// collection open, innermost last: in chunks of a fixed size, so a pair
/// does not move while it is in use.
const SlotStack = struct {
    chunks: std.ArrayList(*[chunk_len][2]Node) = .empty,
    len: usize = 0,

    const chunk_len = 16;

    fn push(s: *SlotStack, gpa: Allocator) Allocator.Error!*[2]Node {
        if (s.len == s.chunks.items.len * chunk_len) {
            const chunk = try gpa.create([chunk_len][2]Node);
            errdefer gpa.destroy(chunk);
            try s.chunks.append(gpa, chunk);
        }
        s.len += 1;
        return &s.chunks.items[(s.len - 1) / chunk_len][(s.len - 1) % chunk_len];
    }

    fn deinit(s: *SlotStack, gpa: Allocator) void {
        for (s.chunks.items) |chunk| gpa.destroy(chunk);
        s.chunks.deinit(gpa);
    }
};

/// A slice of `Child`s gathered as a sequence or mapping read from steps
/// is built, their number not known till its end: on the builder's stack
/// of bytes, then copied into the result once, at their number, so no
/// slice outgrown is left in the result's arena (t47).
fn Gathered(comptime Child: type) type {
    if (@alignOf(Child) > 16) @compileError("yaml cannot build a slice of " ++ @typeName(Child) ++ ", aligned past 16 bytes");
    return struct {
        const Self = @This();
        /// Where the stack was before, and where these begin on it.
        base: usize,
        start: usize,
        len: usize = 0,

        fn begin(b: *Builder) Allocator.Error!Self {
            const base = b.stack.items.len;
            const start = std.mem.alignForward(usize, base, @alignOf(Child));
            try b.stack.resize(b.scratch, start);
            return .{ .base = base, .start = start };
        }

        /// Adds `value`; what a nested sequence put on the stack is gone
        /// by now, as it was copied out when it ended.
        fn append(g: *Self, b: *Builder, value: Child) Allocator.Error!void {
            try b.stack.appendSlice(b.scratch, std.mem.asBytes(&value));
            g.len += 1;
        }

        /// The gathered `Child`s in the result, `sentinel`-terminated if
        /// one is given.
        fn finish(g: *const Self, b: *Builder, comptime sentinel: ?Child) Allocator.Error!(if (sentinel) |s| [:s]Child else []Child) {
            const out = if (sentinel) |s| try b.allocator.allocSentinel(Child, g.len, s) else try b.allocator.alloc(Child, g.len);
            @memcpy(std.mem.sliceAsBytes(out), b.stack.items[g.start..][0 .. g.len * @sizeOf(Child)]);
            return out;
        }

        fn end(g: *const Self, b: *Builder) void {
            b.stack.shrinkRetainingCapacity(g.base);
        }
    };
}

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
        return c.builder.build(T, .{ .node = node }, c.depth + 1);
    }

    /// Builds `node`, the value of this mapping's key `name`, as a `T`,
    /// with `name` on the path.
    pub fn buildNamed(c: Construction, comptime T: type, name: []const u8, node: *const Node) ParseError!T {
        return c.builder.buildNamed(T, .{ .node = node }, name, c.depth);
    }

    /// Builds `node`, the item at `index` of this sequence, as a `T`,
    /// with the index on the path.
    pub fn buildIndexed(c: Construction, comptime T: type, index: usize, node: *const Node) ParseError!T {
        return c.builder.buildItem(T, .{ .node = node }, index, c.depth);
    }

    /// Fails with `error.UnexpectedType` at `node`, the path to it and
    /// `message` in the diagnostic, as it is written: braces are text.
    pub fn fail(c: Construction, node: *const Node, comptime message: []const u8) ParseError {
        return c.builder.fail(node, error.UnexpectedType, message);
    }

    /// Fails at `node`, which is not the `what` expected there: `expected
    /// a command, found a sequence`. `what` is written as it is: braces
    /// are text.
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
                if (isWord(name)) try w.writeAll(name) else try w.print("\"{f}\"", .{Shown{ .text = name }});
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
        switch (schema.core(tag) orelse return w.print("a scalar tagged {f}", .{Shown{ .text = tag }})) {
            .null => return w.writeAll("null"),
            .bool => return w.print("the boolean {s}", .{text}),
            .int => return w.print("the integer {s}", .{text}),
            .float => return w.print("the float {s}", .{text}),
            .seq, .map => return w.print("a scalar tagged {f}", .{Shown{ .text = tag }}),
            .str => {},
        }
        const shown = cutUtf8(text, 40);
        try w.print("the string \"{f}\"{s}", .{ Shown{ .text = shown }, if (shown.len < text.len) "..." else "" });
    }
};

/// Text from the input as a diagnostic shows it: a printable character
/// as it is, any script's included, and escaped what a terminal or a log
/// would act on, controls, line breaks of any kind and bytes that are not
/// UTF-8, and `"` and `\`, so the input cannot write into the terminal
/// reading the message or forge a line of a log (CWE-117, CWE-150).
const Shown = struct {
    text: []const u8,

    pub fn format(s: Shown, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < s.text.len) {
            const len = std.unicode.utf8ByteSequenceLength(s.text[i]) catch 1;
            if (shownAsIs(s.text, i, len)) {
                try w.writeAll(s.text[i..][0..len]);
                i += len;
                continue;
            }
            switch (s.text[i]) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => |c| try w.print("\\x{X:0>2}", .{c}),
            }
            i += 1;
        }
    }

    /// Whether the character of `len` bytes at `text[i]` is written as
    /// it is: printable, and no line break (NEL, U+2028 and U+2029 are
    /// ones to a terminal or a reader of logs).
    fn shownAsIs(text: []const u8, i: usize, len: usize) bool {
        const c = text[i];
        if (c < 0x20 or c == '"' or c == '\\' or !chars.isPrintable(text, i)) return false;
        if (len == 1) return true;
        const point = std.unicode.utf8Decode(text[i..][0..len]) catch return false;
        return point != 0x85 and point != 0x2028 and point != 0x2029;
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
    return switch (schema.core(tag).?) {
        .null => "null",
        .bool => "a boolean",
        .int => "an integer",
        else => "a float",
    };
}

/// Whether `node`'s tag is the core tag `which`.
fn hasTag(node: *const Node, which: schema.Core) bool {
    return schema.core(node.tag orelse return false) == which;
}

fn isNull(node: *const Node) bool {
    return node.target().data == .scalar and hasTag(node.target(), .null);
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
