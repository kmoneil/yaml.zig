//! pyyaml_zig._yaml: the CPython extension under pyyaml-zig (karte t63).
//!
//! It reads YAML with yaml.zig and builds Python objects straight from
//! the composer's node graph: dict, list, str, int, float, bool and None,
//! as PyYAML's safe_load builds them, for YAML 1.2's core schema or, with
//! the yaml11 schema, YAML 1.1's, timestamps then datetime's. An alias
//! is the same object as its anchor's, as in PyYAML, so an alias inside
//! the collection it names makes a cycle of objects. The documents are
//! composed with the GIL released; only building the objects holds it.
//!
//! Against Python's stable ABI (abi3, 3.9 and later): python.h, translated
//! by build.zig.

const std = @import("std");
const yaml = @import("yaml");
const c = @import("python");
const build_options = @import("build_options");

const Node = yaml.Composer.Node;
const Mark = yaml.Composer.Mark;

// Each call allocates in an arena of its own over the system's pages, freed
// as a whole when it returns: no libc, so on Linux one library serves glibc
// and musl alike, and no state shared between calls, which may run at once
// with the GIL released while they compose.

/// The exception the extension raises for input it cannot load or data it
/// cannot write: args (message, line, column, kind), line and column from
/// 0, or -1 when no place is known, and kind a `Kind`'s name. pyyaml_zig
/// raises PyYAML's error class for the kind.
var error_type: ?*c.PyObject = null;

/// A Python exception is set: the caller returns null to Python.
const Raised = error{Raised};

/// Which of PyYAML's error classes an error is, by what found it: the
/// input's encoding (ReaderError), its syntax (ScannerError and
/// ParserError, which yaml.zig does not tell apart), composing (an
/// undefined alias, a second document), building objects
/// (ConstructorError), or writing (RepresenterError).
const Kind = enum { reader, syntax, composer, constructor, representer };

/// Raises an error building objects, the most common kind.
fn raise(message: []const u8, mark: ?Mark) Raised {
    return raiseAs(.constructor, message, mark);
}

fn raiseAs(kind: Kind, message: []const u8, mark: ?Mark) Raised {
    const line: c.Py_ssize_t = if (mark) |m| @intCast(m.line) else -1;
    const column: c.Py_ssize_t = if (mark) |m| @intCast(m.column) else -1;
    const args = c.Py_BuildValue("(s#nns)", message.ptr, @as(c.Py_ssize_t, @intCast(message.len)), line, column, @tagName(kind).ptr) orelse return error.Raised;
    defer c.Py_DecRef(args);
    c.PyErr_SetObject(error_type, args);
    return error.Raised;
}

/// The kind of a composing error.
fn kindOf(err: yaml.Composer.Error) Kind {
    return switch (err) {
        error.UndefinedAlias => .composer,
        error.DuplicateKey, error.NotInSchema => .constructor,
        else => .syntax,
    };
}

fn noMemory() Raised {
    _ = c.PyErr_NoMemory();
    return error.Raised;
}

// None, True and False through functions, not Python's data symbols: on
// Windows a function is imported through python3.lib alone, data needs
// declaring as imported.

fn none() Raised!*c.PyObject {
    return c.Py_BuildValue("") orelse error.Raised;
}

fn boolean(v: bool) Raised!*c.PyObject {
    return c.PyBool_FromLong(@intFromBool(v)) orelse error.Raised;
}

/// Builds the objects of one document, its anchored nodes' objects kept
/// so each alias is the object its anchor names.
const Builder = struct {
    gpa: std.mem.Allocator,
    composer: *yaml.Composer,
    schema: yaml.schema.Schema,
    merge_keys: bool,
    max_depth: usize,
    /// Each anchored node's object, a borrowed reference: its container,
    /// or the result, holds it while the document is built.
    anchored: std.AutoHashMapUnmanaged(*const Node, *c.PyObject) = .empty,

    fn deinit(b: *Builder) void {
        b.anchored.deinit(b.gpa);
    }

    fn build(b: *Builder, from: *const Node, depth: usize) Raised!*c.PyObject {
        const node = from.target();
        if (b.anchored.get(node)) |obj| {
            c.Py_IncRef(obj);
            return obj;
        }
        if (depth > b.max_depth) return raise("the document is deeper than max_depth", node.start);
        return switch (node.data) {
            .scalar => |s| {
                const obj = try b.scalar(node, s.value, s.style);
                errdefer c.Py_DecRef(obj);
                try b.remember(node, obj);
                return obj;
            },
            .sequence => |s| b.sequence(node, s.items, depth),
            .mapping => b.mapping(node, depth),
            .alias => unreachable,
        };
    }

    /// Keeps an anchored node's object, before a collection's entries are
    /// built, so an alias inside it finds it.
    fn remember(b: *Builder, node: *const Node, obj: *c.PyObject) Raised!void {
        if (node.anchor == null) return;
        b.anchored.put(b.gpa, node, obj) catch return noMemory();
    }

    fn scalar(b: *Builder, node: *const Node, text: []const u8, style: yaml.Composer.ScalarStyle) Raised!*c.PyObject {
        _ = style;
        const tag = node.tag orelse "";
        const core = yaml.schema.core(tag) orelse {
            if (std.mem.eql(u8, tag, yaml.schema.tag.timestamp)) return timestamp(text, node.start);
            if (std.mem.eql(u8, tag, binary_tag)) return binary(text, node.start);
            return b.unknownTag(node);
        };
        const s = b.schema;
        if (!s.fits(tag, text)) return raise("the scalar's text is not what its tag says", node.start);
        return switch (core) {
            .null => none(),
            .bool => boolean(s.boolean(text).?),
            .int => integer(b.gpa, s, text, node.start),
            .float => c.PyFloat_FromDouble(s.float(text) orelse return raise("the float is too long to read", node.start)) orelse error.Raised,
            .str => c.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len)) orelse error.Raised,
            .seq, .map => raise("a scalar cannot be tagged as a collection", node.start),
        };
    }

    /// Refuses a node whose tag safe_load has no constructor for, as
    /// PyYAML's safe loader does: `!!python/...`, a custom tag, and on a
    /// collection any but its own kind's (`!!set` and `!!omap` among them).
    fn unknownTag(b: *Builder, node: *const Node) Raised {
        const message = std.fmt.allocPrint(b.gpa, "could not determine a constructor for the tag '{s}'", .{node.tag orelse ""}) catch return noMemory();
        return raise(message, node.start);
    }

    /// Whether a collection's tag is its kind's, as nearly every one's is:
    /// the composer's own constant, found by its pointer (schema.core).
    fn isPlainKind(node: *const Node, kind: yaml.schema.Core) bool {
        const tag = node.tag orelse return true;
        return yaml.schema.core(tag) == kind;
    }

    fn sequence(b: *Builder, node: *const Node, items: []const *Node, depth: usize) Raised!*c.PyObject {
        if (!isPlainKind(node, .seq)) {
            const tag = node.tag.?;
            if (std.mem.eql(u8, tag, omap_tag) or std.mem.eql(u8, tag, pairs_tag)) return b.pairList(node, items, depth);
            return b.unknownTag(node);
        }
        const list = c.PyList_New(@intCast(items.len)) orelse return error.Raised;
        errdefer c.Py_DecRef(list);
        try b.remember(node, list);
        for (items, 0..) |item, i| {
            const obj = try b.build(item, depth + 1);
            // PyList_SetItem takes the reference.
            _ = c.PyList_SetItem(list, @intCast(i), obj);
        }
        return list;
    }

    /// `!!omap` and `!!pairs`, a sequence of one-pair mappings: a list
    /// of (key, value) tuples, as PyYAML builds both.
    fn pairList(b: *Builder, node: *const Node, items: []const *Node, depth: usize) Raised!*c.PyObject {
        const list = c.PyList_New(0) orelse return error.Raised;
        errdefer c.Py_DecRef(list);
        try b.remember(node, list);
        for (items) |from| {
            const item = from.target();
            if (item.data != .mapping or item.data.mapping.pairs.len != 1) return raise("an ordered map's items are each a mapping of one pair", item.start);
            const pair = item.data.mapping.pairs[0];
            const key = try b.build(pair.key, depth + 2);
            defer c.Py_DecRef(key);
            const value = try b.build(pair.value, depth + 2);
            defer c.Py_DecRef(value);
            const tuple = c.PyTuple_Pack(2, key, value) orelse return error.Raised;
            defer c.Py_DecRef(tuple);
            if (c.PyList_Append(list, tuple) != 0) return error.Raised;
        }
        return list;
    }

    fn mapping(b: *Builder, node: *const Node, depth: usize) Raised!*c.PyObject {
        if (!isPlainKind(node, .map)) {
            if (std.mem.eql(u8, node.tag.?, set_tag)) return b.set(node, depth);
            return b.unknownTag(node);
        }
        const dict = c.PyDict_New() orelse return error.Raised;
        errdefer c.Py_DecRef(dict);
        try b.remember(node, dict);
        try b.fill(dict, node, depth);
        return dict;
    }

    /// `!!set`, a mapping whose keys are the members: a set, as PyYAML
    /// builds one.
    fn set(b: *Builder, node: *const Node, depth: usize) Raised!*c.PyObject {
        const dict = c.PyDict_New() orelse return error.Raised;
        defer c.Py_DecRef(dict);
        try b.fill(dict, node, depth);
        const members = c.PySet_New(dict) orelse return error.Raised;
        errdefer c.Py_DecRef(members);
        try b.remember(node, members);
        return members;
    }

    /// Puts a mapping's pairs in `dict`, its merge keys applied.
    fn fill(b: *Builder, dict: *c.PyObject, node: *const Node, depth: usize) Raised!void {
        if (!b.merge_keys) {
            for (node.data.mapping.pairs) |pair| try b.put(dict, pair.key, pair.value, depth);
            return;
        }
        var pairs = yaml.merge.Pairs.init(b.gpa, node, b.composer, b.max_depth) catch return noMemory();
        defer pairs.deinit();
        while (true) {
            const pair = (pairs.next() catch |err| return mergeFailed(err, pairs.failed_at)) orelse break;
            try b.put(dict, pair.key, pair.value, depth);
        }
    }

    fn put(b: *Builder, dict: *c.PyObject, key_node: *const Node, value_node: *const Node, depth: usize) Raised!void {
        const key = try b.build(key_node, depth + 1);
        defer c.Py_DecRef(key);
        if (c.PyObject_Hash(key) == -1) {
            c.PyErr_Clear();
            return raise("found an unhashable key", key_node.target().start);
        }
        const value = try b.build(value_node, depth + 1);
        defer c.Py_DecRef(value);
        if (c.PyDict_SetItem(dict, key, value) != 0) return error.Raised;
    }
};

fn mergeFailed(err: yaml.merge.Error, at: ?*const Node) Raised {
    const mark = if (at) |n| n.start else null;
    return switch (err) {
        error.OutOfMemory => noMemory(),
        error.NotMergeable => raise("a merge key's value is not a mapping or a sequence of mappings", mark),
        error.Cycle => raise("a merge names a mapping it is merged into", mark),
        error.DepthLimit => raise("merges go deeper than max_depth", mark),
    };
}

/// An int, of any size, from an integer's text as the schema `s` reads
/// it: decimal, `0o` octal or `0x` hexadecimal, with a sign, and under
/// yaml11 binary, `0` octal, `_` among the digits and sexagesimal.
fn integer(gpa: std.mem.Allocator, s: yaml.schema.Schema, text: []const u8, mark: Mark) Raised!*c.PyObject {
    if (s.int(c_longlong, text)) |n| return c.PyLong_FromLongLong(n) orelse error.Raised;
    if (std.mem.findScalar(u8, text, ':') == null) return bigInteger(gpa, s, text);
    // Sexagesimal, which Python does not read: through an i128.
    const n = s.int(i128, text) orelse return raise("the integer is too large", mark);
    const z = std.fmt.allocPrintSentinel(gpa, "{d}", .{n}, 0) catch return noMemory();
    defer gpa.free(z);
    return c.PyLong_FromString(z.ptr, null, 10) orelse error.Raised;
}

/// An integer past 64 bits: Python reads its digits, in the base its
/// form says, with no `_`.
fn bigInteger(gpa: std.mem.Allocator, s: yaml.schema.Schema, text: []const u8) Raised!*c.PyObject {
    const negative = text.len > 0 and text[0] == '-';
    var digits = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    const base = baseOf(s, &digits);
    const z = gpa.allocSentinel(u8, digits.len + 1, 0) catch return noMemory();
    defer gpa.free(z);
    var n: usize = 0;
    if (negative) {
        z[0] = '-';
        n = 1;
    }
    for (digits) |ch| {
        if (ch == '_') continue;
        z[n] = ch;
        n += 1;
    }
    z[n] = 0;
    return c.PyLong_FromString(z.ptr, null, base) orelse error.Raised;
}

/// The base an unsigned integer's prefix gives it, the prefix taken off
/// `digits`: `0x`, `0o` and `0b`, and under yaml11 a leading `0`.
fn baseOf(s: yaml.schema.Schema, digits: *[]const u8) c_int {
    for ([_]struct { []const u8, c_int }{ .{ "0x", 16 }, .{ "0o", 8 }, .{ "0b", 2 } }) |prefix| {
        if (std.mem.startsWith(u8, digits.*, prefix[0])) {
            digits.* = digits.*[2..];
            return prefix[1];
        }
    }
    return if (s == .yaml11 and digits.len > 1 and digits.*[0] == '0') 8 else 10;
}

const set_tag = yaml.schema.core_prefix ++ "set";
const omap_tag = yaml.schema.core_prefix ++ "omap";
const pairs_tag = yaml.schema.core_prefix ++ "pairs";
const binary_tag = yaml.schema.core_prefix ++ "binary";

/// `!!binary`: bytes, from base64 as PyYAML reads it, the text's blanks
/// and line breaks skipped (binascii.a2b_base64).
fn binary(text: []const u8, mark: Mark) Raised!*c.PyObject {
    for (text) |ch| {
        if (ch >= 0x80) return raise("failed to convert base64 data into ascii", mark);
    }
    return c.PyObject_CallFunction(types.a2b_base64, "(y#)", text.ptr, @as(c.Py_ssize_t, @intCast(text.len))) orelse {
        c.PyErr_Clear();
        return raise("failed to decode base64 data", mark);
    };
}

/// A date, or a datetime, as PyYAML builds one: with no zone a naive
/// one, with `Z` or an offset of 0 in UTC.
fn timestamp(text: []const u8, mark: Mark) Raised!*c.PyObject {
    const t = yaml.schema.parseTimestamp(text) orelse return raise("the timestamp is not a real date and time", mark);
    const year: c_int = t.year;
    const month: c_int = t.month;
    const day: c_int = t.day;
    const time = t.time orelse return c.PyObject_CallFunction(types.date, "(iii)", year, month, day) orelse outOfRange(mark);
    const zone = try timezone(time.offset);
    defer c.Py_DecRef(zone);
    const hour: c_int = time.hour;
    const minute: c_int = time.minute;
    const second: c_int = time.second;
    const microsecond: c_int = @intCast(time.nanosecond / 1000);
    return c.PyObject_CallFunction(types.datetime, "(iiiiiiiO)", year, month, day, hour, minute, second, microsecond, zone) orelse outOfRange(mark);
}

/// Python refused a date, as it refuses the year 0.
fn outOfRange(mark: Mark) Raised {
    c.PyErr_Clear();
    return raise("the timestamp is out of Python's range", mark);
}

/// A tzinfo for an offset of `offset` minutes; None for none.
fn timezone(offset: ?i16) Raised!*c.PyObject {
    const minutes = offset orelse return none();
    if (minutes == 0) {
        c.Py_IncRef(types.utc);
        return types.utc;
    }
    const seconds: c_int = @as(c_int, minutes) * 60;
    const delta = c.PyObject_CallFunction(types.timedelta, "(ii)", @as(c_int, 0), seconds) orelse return error.Raised;
    defer c.Py_DecRef(delta);
    return c.PyObject_CallFunction(types.timezone, "(O)", delta) orelse error.Raised;
}

/// What composing gave, read with the GIL released: the documents' roots,
/// or why the stream is not YAML.
const Composed = struct {
    roots: std.ArrayList(*Node) = .empty,
    /// The start of a second document, where one was asked for.
    extra: ?Mark = null,
    failure: ?struct { diagnostic: yaml.Composer.Diagnostic, kind: Kind } = null,
    out_of_memory: bool = false,

    fn failed(out: *Composed, composer: *const yaml.Composer, err: yaml.Composer.Error) void {
        if (err == error.OutOfMemory) {
            out.out_of_memory = true;
        } else {
            out.failure = .{ .diagnostic = composer.diagnostic, .kind = kindOf(err) };
        }
    }
};

fn compose(gpa: std.mem.Allocator, composer: *yaml.Composer, all: bool) Composed {
    var out: Composed = .{};
    while (true) {
        const document = composer.next() catch |err| {
            out.failed(composer, err);
            return out;
        } orelse return out;
        out.roots.append(gpa, document.root) catch {
            out.out_of_memory = true;
            return out;
        };
        if (all) continue;
        // One document asked for: another after it is an error, as in PyYAML.
        const start = composer.beginDocument() catch |err| {
            out.failed(composer, err);
            return out;
        };
        out.extra = start;
        return out;
    }
}

/// How `_load` reads.
const LoadOptions = struct {
    all: bool,
    merge_keys: bool,
    max_depth: usize,
    schema: yaml.schema.Schema,
    /// Keep a mapping's later equal key, as PyYAML does, not refuse it.
    keep_duplicates: bool,
};

/// `_load(text, all, merge_keys, max_depth, schema, keep_duplicates)`:
/// the document of `text` (str or UTF-8, UTF-16 or UTF-32 bytes), None
/// for an empty stream; with `all`, a list of every document. `schema`
/// is a yaml.schema.Schema's name.
fn load(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return loadArgs(args) catch null;
}

fn loadArgs(args: ?*c.PyObject) Raised!*c.PyObject {
    var ptr: [*c]const u8 = undefined;
    var len: c.Py_ssize_t = 0;
    var all: c_int = 0;
    var merge_keys: c_int = 0;
    var max_depth: c.Py_ssize_t = 0;
    var schema_name: [*c]const u8 = undefined;
    var keep_duplicates: c_int = 0;
    if (c.PyArg_ParseTuple(args, "s#ppnsp", &ptr, &len, &all, &merge_keys, &max_depth, &schema_name, &keep_duplicates) == 0) return error.Raised;
    const s = std.meta.stringToEnum(yaml.schema.Schema, std.mem.span(schema_name)) orelse
        return raise("the schema is core, yaml11, json or failsafe", null);
    return loadText(ptr[0..@intCast(len)], .{
        .all = all != 0,
        .merge_keys = merge_keys != 0,
        .max_depth = @intCast(@max(max_depth, 0)),
        .schema = s,
        .keep_duplicates = keep_duplicates != 0,
    });
}

fn loadText(bytes: []const u8, options: LoadOptions) Raised!*c.PyObject {
    const all = options.all;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diagnostic: yaml.Diagnostic = .{};
    const text = yaml.encoding.toUtf8(gpa, bytes, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return noMemory(),
        else => return raiseAs(.reader, diagnostic.message, diagnostic.mark),
    };
    defer if (text.ptr != bytes.ptr) gpa.free(text);

    var composer: yaml.Composer = .init(gpa, text, .{
        .max_depth = options.max_depth,
        .schema = options.schema,
        .duplicate_keys = if (options.keep_duplicates) .keep else .refuse,
    });
    defer composer.deinit();
    const state = c.PyEval_SaveThread();
    var composed = compose(gpa, &composer, all);
    c.PyEval_RestoreThread(state);
    defer composed.roots.deinit(gpa);
    if (composed.out_of_memory) return noMemory();
    if (composed.failure) |f| return raiseAs(f.kind, f.diagnostic.message, f.diagnostic.mark);
    if (composed.extra) |start| return raiseAs(.composer, "expected a single document in the stream, but found another document", start);

    var builder: Builder = .{ .gpa = gpa, .composer = &composer, .schema = options.schema, .merge_keys = options.merge_keys, .max_depth = options.max_depth };
    defer builder.deinit();
    if (!all) {
        if (composed.roots.items.len == 0) return none();
        return builder.build(composed.roots.items[0], 0);
    }
    const list = c.PyList_New(@intCast(composed.roots.items.len)) orelse return error.Raised;
    errdefer c.Py_DecRef(list);
    for (composed.roots.items, 0..) |root, i| {
        // Anchors are a document's own.
        builder.anchored.clearRetainingCapacity();
        _ = c.PyList_SetItem(list, @intCast(i), try builder.build(root, 0));
    }
    return list;
}

/// The types and singletons `_dump` tells objects by, taken from instances
/// when the module loads, and held for its life: Python's type objects are
/// data symbols, which Windows imports only when declared so. With them,
/// datetime's types, which `_load` builds timestamps with.
var types: struct {
    none: *c.PyObject,
    true_: *c.PyObject,
    false_: *c.PyObject,
    int: *c.PyObject,
    float: *c.PyObject,
    str: *c.PyObject,
    dict: *c.PyObject,
    list: *c.PyObject,
    tuple: *c.PyObject,
    date: *c.PyObject,
    datetime: *c.PyObject,
    timedelta: *c.PyObject,
    timezone: *c.PyObject,
    utc: *c.PyObject,
    a2b_base64: *c.PyObject,
} = undefined;

/// The type of `instance`, a new one dropped once it is read.
fn typeOf(instance: ?*c.PyObject) ?*c.PyObject {
    const obj = instance orelse return null;
    defer c.Py_DecRef(obj);
    return c.PyObject_Type(obj);
}

fn initTypes() bool {
    return initBuiltins() and initImported();
}

fn initBuiltins() bool {
    types.none = c.Py_BuildValue("") orelse return false;
    types.true_ = c.PyBool_FromLong(1) orelse return false;
    types.false_ = c.PyBool_FromLong(0) orelse return false;
    types.int = typeOf(c.PyLong_FromLong(0)) orelse return false;
    types.float = typeOf(c.PyFloat_FromDouble(0)) orelse return false;
    types.str = typeOf(c.PyUnicode_FromStringAndSize("", 0)) orelse return false;
    types.dict = typeOf(c.PyDict_New()) orelse return false;
    types.list = typeOf(c.PyList_New(0)) orelse return false;
    types.tuple = typeOf(c.PyTuple_New(0)) orelse return false;
    return true;
}

/// datetime's types and binascii's base64 reader.
fn initImported() bool {
    const datetime = c.PyImport_ImportModule("datetime") orelse return false;
    defer c.Py_DecRef(datetime);
    types.date = c.PyObject_GetAttrString(datetime, "date") orelse return false;
    types.datetime = c.PyObject_GetAttrString(datetime, "datetime") orelse return false;
    types.timedelta = c.PyObject_GetAttrString(datetime, "timedelta") orelse return false;
    types.timezone = c.PyObject_GetAttrString(datetime, "timezone") orelse return false;
    types.utc = c.PyObject_GetAttrString(types.timezone, "utc") orelse return false;
    const binascii = c.PyImport_ImportModule("binascii") orelse return false;
    defer c.Py_DecRef(binascii);
    types.a2b_base64 = c.PyObject_GetAttrString(binascii, "a2b_base64") orelse return false;
    return true;
}

fn isInstance(obj: *c.PyObject, t: *c.PyObject) Raised!bool {
    return switch (c.PyObject_IsInstance(obj, t)) {
        1 => true,
        0 => false,
        else => error.Raised,
    };
}

/// Python objects as yaml.zig's Values, for safe_dump: what safe_load
/// gives back, and nothing else.
const Dumper = struct {
    gpa: std.mem.Allocator,
    sort_keys: bool,
    flow: bool,
    max_depth: usize,

    fn value(d: *const Dumper, obj: *c.PyObject, depth: usize) Raised!yaml.Value {
        if (depth > d.max_depth) return raiseAs(.representer, "the data nests deeper than max_depth, or holds itself", null);
        if (obj == types.none) return .null;
        if (obj == types.true_) return .{ .bool = true };
        if (obj == types.false_) return .{ .bool = false };
        if (try isInstance(obj, types.int)) return d.integer(obj);
        if (try isInstance(obj, types.float)) return .{ .float = c.PyFloat_AsDouble(obj) };
        if (try isInstance(obj, types.str)) return .{ .string = try d.utf8(obj) };
        if (try isInstance(obj, types.dict)) return .{ .mapping = try d.pairs(obj, depth) };
        if (try isInstance(obj, types.list) or try isInstance(obj, types.tuple)) return .{ .sequence = try d.items(obj, depth) };
        // A datetime is a date too: it is told first.
        if (try isInstance(obj, types.datetime)) return d.timestamp(obj, " ");
        if (try isInstance(obj, types.date)) return d.timestamp(obj, null);
        return d.cannotRepresent(obj);
    }

    /// A date or a datetime as PyYAML writes one: its isoformat(), with a
    /// blank between a datetime's date and time, plain, so a YAML 1.1
    /// reader reads it back as a timestamp. (Value's number_string is
    /// written plain as it is, which is all this needs of it.)
    fn timestamp(d: *const Dumper, obj: *c.PyObject, separator: ?[*:0]const u8) Raised!yaml.Value {
        const iso = (if (separator) |sep| c.PyObject_CallMethod(obj, "isoformat", "(s)", sep) else c.PyObject_CallMethod(obj, "isoformat", null)) orelse return error.Raised;
        defer c.Py_DecRef(iso);
        const text = try d.utf8(iso);
        // In flow style a `:` cannot be plain, and quoted, a time would
        // read back as a string. (PyYAML tags it; Value has no tags.)
        if (d.flow and std.mem.findScalar(u8, text, ':') != null) {
            return raiseAs(.representer, "a datetime cannot be written in flow style, where it would read back as a string: write it in block style", null);
        }
        return .{ .number_string = text };
    }

    fn integer(d: *const Dumper, obj: *c.PyObject) Raised!yaml.Value {
        var overflow: c_int = 0;
        const n = c.PyLong_AsLongLongAndOverflow(obj, &overflow);
        if (overflow == 0) {
            if (n == -1 and c.PyErr_Occurred() != null) return error.Raised;
            return .{ .integer = n };
        }
        // Past 64 bits: its decimal digits, which YAML reads back as one.
        const text = c.PyObject_Str(obj) orelse return error.Raised;
        defer c.Py_DecRef(text);
        return .{ .number_string = try d.utf8(text) };
    }

    /// A str's UTF-8, copied into the arena.
    fn utf8(d: *const Dumper, obj: *c.PyObject) Raised![]const u8 {
        const bytes = c.PyUnicode_AsUTF8String(obj) orelse return error.Raised;
        defer c.Py_DecRef(bytes);
        var ptr: [*c]u8 = undefined;
        var len: c.Py_ssize_t = 0;
        if (c.PyBytes_AsStringAndSize(bytes, &ptr, &len) != 0) return error.Raised;
        return d.gpa.dupe(u8, ptr[0..@intCast(len)]) catch noMemory();
    }

    fn pairs(d: *const Dumper, dict: *c.PyObject, depth: usize) Raised![]yaml.Value.Pair {
        const keys = c.PyDict_Keys(dict) orelse return error.Raised;
        defer c.Py_DecRef(keys);
        // Sorted, as PyYAML's safe_dump sorts them unless told not to; keys
        // that cannot be compared (an int and a str) stay in the dict's
        // order, as PyYAML leaves them.
        if (d.sort_keys and c.PyList_Sort(keys) != 0) c.PyErr_Clear();
        const n: usize = @intCast(c.PyList_Size(keys));
        const out = d.gpa.alloc(yaml.Value.Pair, n) catch return noMemory();
        for (out, 0..) |*pair, i| {
            const key = c.PyList_GetItem(keys, @intCast(i)) orelse return error.Raised;
            const val = c.PyDict_GetItem(dict, key) orelse return error.Raised;
            pair.* = .{ .key = try d.value(key, depth + 1), .value = try d.value(val, depth + 1) };
        }
        return out;
    }

    fn items(d: *const Dumper, seq: *c.PyObject, depth: usize) Raised![]yaml.Value {
        const n = c.PySequence_Size(seq);
        if (n < 0) return error.Raised;
        const out = d.gpa.alloc(yaml.Value, @intCast(n)) catch return noMemory();
        for (out, 0..) |*v, i| {
            const item = c.PySequence_GetItem(seq, @intCast(i)) orelse return error.Raised;
            defer c.Py_DecRef(item);
            v.* = try d.value(item, depth + 1);
        }
        return out;
    }

    fn cannotRepresent(d: *const Dumper, obj: *c.PyObject) Raised {
        const t = c.PyObject_Type(obj) orelse return error.Raised;
        defer c.Py_DecRef(t);
        const name = c.PyObject_GetAttrString(t, "__name__") orelse return error.Raised;
        defer c.Py_DecRef(name);
        const text = try d.utf8(name);
        const message = std.fmt.allocPrint(d.gpa, "cannot represent an object of type {s}: pyyaml-zig writes dict, list, tuple, str, int, float, bool, None, date and datetime", .{text}) catch return noMemory();
        return raiseAs(.representer, message, null);
    }
};

/// `_dump(data, flow, indent, width, sort_keys, max_depth)`: `data` as one
/// YAML document's text.
fn dump(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var obj: ?*c.PyObject = null;
    var flow: c_int = 0;
    var indent: c.Py_ssize_t = 2;
    var width: c.Py_ssize_t = 80;
    var sort_keys: c_int = 1;
    var max_depth: c.Py_ssize_t = 256;
    if (c.PyArg_ParseTuple(args, "Opnnpn", &obj, &flow, &indent, &width, &sort_keys, &max_depth) == 0) return null;
    return dumpValue(obj.?, flow != 0, @intCast(std.math.clamp(indent, 2, 8)), @intCast(@max(width, 1)), sort_keys != 0, @intCast(@max(max_depth, 0))) catch null;
}

fn dumpValue(obj: *c.PyObject, flow: bool, indent: u8, width: usize, sort_keys: bool, max_depth: usize) Raised!*c.PyObject {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const dumper: Dumper = .{ .gpa = gpa, .sort_keys = sort_keys, .flow = flow, .max_depth = max_depth };
    const value = try dumper.value(obj, 0);
    var out: std.Io.Writer.Allocating = .init(gpa);
    // Writing is yaml.zig's alone: the GIL is let go while it runs.
    const state = c.PyEval_SaveThread();
    const written = yaml.stringify(gpa, value, .{ .style = if (flow) .flow else .block, .indent = indent, .width = width }, &out.writer);
    c.PyEval_RestoreThread(state);
    written catch |err| return switch (err) {
        error.InvalidUtf8 => raiseAs(.representer, "a string is not UTF-8", null),
        error.OutOfMemory, error.WriteFailed => noMemory(),
    };
    const text = out.written();
    return c.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len)) orelse error.Raised;
}

var methods = [_]c.PyMethodDef{
    .{ .ml_name = "_load", .ml_meth = @ptrCast(&load), .ml_flags = c.METH_VARARGS, .ml_doc = "_load(text, all, merge_keys, max_depth, schema, keep_duplicates)" },
    .{ .ml_name = "_dump", .ml_meth = @ptrCast(&dump), .ml_flags = c.METH_VARARGS, .ml_doc = "_dump(data, flow, indent, width, sort_keys, max_depth)" },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var module_def = c.PyModuleDef{
    .m_base = std.mem.zeroes(c.PyModuleDef_Base),
    .m_name = "pyyaml_zig._yaml",
    .m_doc = "yaml.zig, read into Python objects: pyyaml_zig's extension.",
    .m_size = -1,
    .m_methods = &methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

export fn PyInit__yaml() ?*c.PyObject {
    if (!initTypes()) return null;
    const module = c.PyModule_Create2(&module_def, c.PYTHON_ABI_VERSION) orelse return null;
    error_type = c.PyErr_NewException("pyyaml_zig._yaml.Error", null, null) orelse {
        c.Py_DecRef(module);
        return null;
    };
    c.Py_IncRef(error_type.?);
    if (c.PyModule_AddObject(module, "Error", error_type) != 0) {
        c.Py_DecRef(error_type.?);
        c.Py_DecRef(module);
        return null;
    }
    const version = build_options.version ++ "\x00";
    if (c.PyModule_AddStringConstant(module, "__version__", version) != 0) {
        c.Py_DecRef(module);
        return null;
    }
    return module;
}
