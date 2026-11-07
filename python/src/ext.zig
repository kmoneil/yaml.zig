//! pyyaml_zig._yaml: the CPython extension under pyyaml-zig (karte t63).
//!
//! It reads YAML with yaml.zig and builds Python objects straight from
//! the composer's node graph: dict, list, str, int, float, bool and None,
//! as PyYAML's safe_load builds them for YAML 1.2's core schema. An alias
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
const gpa = std.heap.c_allocator;

/// The exception the extension raises for input it cannot load: args
/// (message, line, column), line and column from 0, or -1 when no place
/// is known. pyyaml_zig turns it into YAMLError.
var error_type: ?*c.PyObject = null;

/// A Python exception is set: the caller returns null to Python.
const Raised = error{Raised};

fn raise(message: []const u8, mark: ?Mark) Raised {
    const line: c.Py_ssize_t = if (mark) |m| @intCast(m.line) else -1;
    const column: c.Py_ssize_t = if (mark) |m| @intCast(m.column) else -1;
    const args = c.Py_BuildValue("(s#nn)", message.ptr, @as(c.Py_ssize_t, @intCast(message.len)), line, column) orelse return error.Raised;
    defer c.Py_DecRef(args);
    c.PyErr_SetObject(error_type, args);
    return error.Raised;
}

fn noMemory() Raised {
    _ = c.PyErr_NoMemory();
    return error.Raised;
}

fn none() *c.PyObject {
    const obj: *c.PyObject = @ptrCast(&c._Py_NoneStruct);
    c.Py_IncRef(obj);
    return obj;
}

fn boolean(v: bool) *c.PyObject {
    const obj: *c.PyObject = if (v) @ptrCast(@alignCast(&c._Py_TrueStruct)) else @ptrCast(@alignCast(&c._Py_FalseStruct));
    c.Py_IncRef(obj);
    return obj;
}

/// Builds the objects of one document, its anchored nodes' objects kept
/// so each alias is the object its anchor names.
const Builder = struct {
    composer: *yaml.Composer,
    merge_keys: bool,
    max_depth: usize,
    /// Each anchored node's object, a borrowed reference: its container,
    /// or the result, holds it while the document is built.
    anchored: std.AutoHashMapUnmanaged(*const Node, *c.PyObject) = .empty,

    fn deinit(b: *Builder) void {
        b.anchored.deinit(gpa);
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
        b.anchored.put(gpa, node, obj) catch return noMemory();
    }

    fn scalar(b: *Builder, node: *const Node, text: []const u8, style: yaml.Composer.ScalarStyle) Raised!*c.PyObject {
        _ = b;
        _ = style;
        const tag = node.tag orelse "";
        const core = yaml.schema.core(tag) orelse return raise("could not determine a constructor for the tag", node.start);
        if (!yaml.schema.fitsTag(tag, text)) return raise("the scalar's text is not what its tag says", node.start);
        return switch (core) {
            .null => none(),
            .bool => boolean(yaml.schema.parseBool(text).?),
            .int => integer(text, node),
            .float => c.PyFloat_FromDouble(yaml.schema.parseFloat(text).?) orelse error.Raised,
            .str => c.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len)) orelse error.Raised,
            .seq, .map => raise("a scalar cannot be tagged as a collection", node.start),
        };
    }

    fn sequence(b: *Builder, node: *const Node, items: []const *Node, depth: usize) Raised!*c.PyObject {
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

    fn mapping(b: *Builder, node: *const Node, depth: usize) Raised!*c.PyObject {
        const dict = c.PyDict_New() orelse return error.Raised;
        errdefer c.Py_DecRef(dict);
        try b.remember(node, dict);
        if (!b.merge_keys) {
            for (node.data.mapping.pairs) |pair| try b.put(dict, pair.key, pair.value, depth);
            return dict;
        }
        var pairs = yaml.merge.Pairs.init(gpa, node, b.composer, b.max_depth) catch return noMemory();
        defer pairs.deinit();
        while (true) {
            const pair = (pairs.next() catch |err| return mergeFailed(err, pairs.failed_at)) orelse break;
            try b.put(dict, pair.key, pair.value, depth);
        }
        return dict;
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

/// A core-schema integer: an int, of any size, from its text (decimal,
/// 0o octal or 0x hexadecimal, with a sign).
fn integer(text: []const u8, node: *const Node) Raised!*c.PyObject {
    if (yaml.schema.parseInt(text)) |n| {
        if (std.math.cast(c_longlong, n)) |small| return c.PyLong_FromLongLong(small) orelse error.Raised;
    }
    // Past 64 bits: Python reads the digits, in the base the prefix says.
    var digits = text;
    var negative = false;
    if (digits.len > 0 and (digits[0] == '-' or digits[0] == '+')) {
        negative = digits[0] == '-';
        digits = digits[1..];
    }
    var base: c_int = 10;
    if (std.mem.startsWith(u8, digits, "0x")) {
        base = 16;
        digits = digits[2..];
    } else if (std.mem.startsWith(u8, digits, "0o")) {
        base = 8;
        digits = digits[2..];
    }
    const z = std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ if (negative) "-" else "", digits }, 0) catch return noMemory();
    defer gpa.free(z);
    _ = node;
    return c.PyLong_FromString(z.ptr, null, base) orelse error.Raised;
}

/// What composing gave, read with the GIL released: the documents' roots,
/// or why the stream is not YAML.
const Composed = struct {
    roots: std.ArrayList(*Node) = .empty,
    /// The start of a second document, where one was asked for.
    extra: ?Mark = null,
    failure: ?yaml.Composer.Diagnostic = null,
    out_of_memory: bool = false,
};

fn compose(composer: *yaml.Composer, all: bool) Composed {
    var out: Composed = .{};
    while (true) {
        const document = composer.next() catch |err| {
            if (err == error.OutOfMemory) out.out_of_memory = true else out.failure = composer.diagnostic;
            return out;
        } orelse return out;
        out.roots.append(gpa, document.root) catch {
            out.out_of_memory = true;
            return out;
        };
        if (all) continue;
        // One document asked for: another after it is an error, as in PyYAML.
        const start = composer.beginDocument() catch |err| {
            if (err == error.OutOfMemory) out.out_of_memory = true else out.failure = composer.diagnostic;
            return out;
        };
        out.extra = start;
        return out;
    }
}

/// `_load(text, all, merge_keys, max_depth)`: the document of `text` (str
/// or UTF-8, UTF-16 or UTF-32 bytes), None for an empty stream; with
/// `all`, a list of every document.
fn load(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var ptr: [*c]const u8 = undefined;
    var len: c.Py_ssize_t = 0;
    var all: c_int = 0;
    var merge_keys: c_int = 0;
    var max_depth: c.Py_ssize_t = 0;
    if (c.PyArg_ParseTuple(args, "s#ppn", &ptr, &len, &all, &merge_keys, &max_depth) == 0) return null;
    return loadText(ptr[0..@intCast(len)], all != 0, merge_keys != 0, @intCast(@max(max_depth, 0))) catch null;
}

fn loadText(bytes: []const u8, all: bool, merge_keys: bool, max_depth: usize) Raised!*c.PyObject {
    var diagnostic: yaml.Diagnostic = .{};
    const text = yaml.encoding.toUtf8(gpa, bytes, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return noMemory(),
        else => return raise(diagnostic.message, diagnostic.mark),
    };
    defer if (text.ptr != bytes.ptr) gpa.free(text);

    var composer: yaml.Composer = .init(gpa, text, .{ .max_depth = max_depth });
    defer composer.deinit();
    const state = c.PyEval_SaveThread();
    var composed = compose(&composer, all);
    c.PyEval_RestoreThread(state);
    defer composed.roots.deinit(gpa);
    if (composed.out_of_memory) return noMemory();
    if (composed.failure) |d| return raise(d.message, d.mark);
    if (composed.extra) |start| return raise("expected a single document in the stream, but found another document", start);

    var builder: Builder = .{ .composer = &composer, .merge_keys = merge_keys, .max_depth = max_depth };
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

var methods = [_]c.PyMethodDef{
    .{ .ml_name = "_load", .ml_meth = @ptrCast(&load), .ml_flags = c.METH_VARARGS, .ml_doc = "_load(text, all, merge_keys, max_depth)" },
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
