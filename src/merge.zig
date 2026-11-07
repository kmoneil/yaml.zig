//! YAML 1.1's merge key, `<<` (yaml.org/type/merge.html): the pairs of
//! another mapping, or of each mapping in a sequence, merged into the
//! mapping that has `<<` as a key. YAML 1.2 dropped it from its schemas,
//! and most YAML readers still apply it (PyYAML, ruamel.yaml, go-yaml,
//! js-yaml), so configs lean on it: `<<: *defaults`. Here it is applied
//! only when asked for (`ParseOptions.merge_keys`, the CLI's
//! `--merge-keys`), to whole nodes, as construction reads them.
//!
//! A mapping's own keys win over merged ones, wherever the `<<` stands;
//! of a sequence of mappings merged, the earlier wins; a merged mapping's
//! own merges are applied under its own keys. Only a plain `<<` is a merge
//! key: a quoted one is a string as any other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Composer = @import("Composer.zig");
const schema = @import("schema.zig");
const Node = Composer.Node;

/// The merge key's own tag, `!!merge`, which YAML 1.1 resolves a plain
/// `<<` to.
pub const tag = schema.core_prefix ++ "merge";

pub const Error = error{
    OutOfMemory,
    /// A merge key's value is not a mapping or a sequence of mappings:
    /// `failed_at` says which.
    NotMergeable,
    /// A mapping merges a mapping it is merged into, itself through
    /// aliases: `failed_at` is the value that closes the cycle.
    Cycle,
    /// Merges go deeper than `max_depth` mappings.
    DepthLimit,
};

/// Whether `key` is a merge key: a plain `<<`, its tag the one the schema
/// gives a plain scalar (a string) or `!!merge`.
pub fn isKey(key: *const Node) bool {
    const k = key.target();
    if (k.data != .scalar) return false;
    const s = k.data.scalar;
    if (s.style != .plain or !std.mem.eql(u8, s.value, "<<")) return false;
    const t = k.tag orelse return false;
    return t.ptr == schema.tag.str.ptr or std.mem.eql(u8, t, tag);
}

/// A pair `Pairs` gives: a key and its value, and whether a merge brought
/// it in.
pub const Pair = struct { key: *const Node, value: *const Node, merged: bool };

/// A mapping's pairs with its merges applied: its own first, in their
/// order, none skipped (two equal keys there are the composer's to refuse
/// or keep); then each merged mapping's, in the order the merges name
/// them, each mapping's own before its merges, a pair skipped when its key
/// is one already given. Each mapping is merged once at most, so merges
/// that name a mapping many times over cost what naming it once does.
pub const Pairs = struct {
    gpa: Allocator,
    /// Whose hash seed a set of many keys takes (`Composer.hashSeed`),
    /// asked for only then: it hashes the whole input.
    composer: *Composer,
    max_depth: usize,
    /// The mappings and merge lists being read, the innermost last.
    frames: std.ArrayList(Frame) = .empty,
    /// The keys given, to skip a merged pair whose key is one of them:
    /// searched one by one up to `linear_keys`, past it in `set`.
    given: std.ArrayList(*const Node) = .empty,
    set: std.HashMapUnmanaged(*const Node, void, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    /// The mappings merged so far.
    merged: std.AutoHashMapUnmanaged(*const Node, void) = .empty,
    /// Where `next` failed, for NotMergeable and Cycle.
    failed_at: ?*const Node = null,

    const linear_keys = 16;

    const Frame = union(enum) {
        /// A mapping: its own pairs from `index`, then (`merging`) its
        /// merge keys' values from `index` again.
        mapping: struct { node: *const Node, index: usize = 0, merging: bool = false },
        /// A merge key's sequence of mappings, from `index`.
        list: struct { items: []const *Node, index: usize = 0 },
    };

    const KeyContext = struct {
        seed: u64,
        schema: schema.Schema,
        pub fn hash(ctx: KeyContext, key: *const Node) u64 {
            return Composer.hashNode(ctx.schema, key, ctx.seed);
        }
        pub fn eql(ctx: KeyContext, a: *const Node, b: *const Node) bool {
            return Composer.equal(ctx.schema, a, b);
        }
    };

    /// The pairs of `mapping`, a mapping node, whole, from `composer`'s
    /// document, merges at most `max_depth` deep.
    pub fn init(gpa: Allocator, mapping: *const Node, composer: *Composer, max_depth: usize) Error!Pairs {
        var p: Pairs = .{ .gpa = gpa, .composer = composer, .max_depth = max_depth };
        errdefer p.deinit();
        try p.frames.append(gpa, .{ .mapping = .{ .node = mapping.target() } });
        return p;
    }

    pub fn deinit(p: *Pairs) void {
        p.frames.deinit(p.gpa);
        p.given.deinit(p.gpa);
        p.set.deinit(p.gpa);
        p.merged.deinit(p.gpa);
    }

    /// The next pair, or null after the last.
    pub fn next(p: *Pairs) Error!?Pair {
        while (p.frames.items.len > 0) {
            const top = p.frames.items.len - 1;
            const pair = switch (p.frames.items[top]) {
                .mapping => try p.stepMapping(top),
                .list => try p.stepList(top),
            };
            if (pair) |given| return given;
        }
        return null;
    }

    /// A step through the mapping at `top`: a pair to give, or null when
    /// the step gives none (a key given already, a merge begun, the
    /// mapping's end).
    fn stepMapping(p: *Pairs, top: usize) Error!?Pair {
        const m = &p.frames.items[top].mapping;
        const pairs = m.node.data.mapping.pairs;
        if (m.index == pairs.len) {
            if (m.merging) {
                _ = p.frames.pop();
            } else {
                m.merging = true;
                m.index = 0;
            }
            return null;
        }
        const pair = pairs[m.index];
        m.index += 1;
        const is_merge = isKey(pair.key);
        if (m.merging) {
            if (is_merge) try p.mergeValue(pair.value);
            return null;
        }
        if (is_merge) return null;
        // The first mapping's own pairs are all given.
        const own = top == 0;
        if (!try p.give(pair.key, own)) return null;
        return .{ .key = pair.key, .value = pair.value, .merged = !own };
    }

    /// A step through the merge list at `top`: its next mapping begun.
    fn stepList(p: *Pairs, top: usize) Error!?Pair {
        const l = &p.frames.items[top].list;
        if (l.index == l.items.len) {
            _ = p.frames.pop();
            return null;
        }
        const item = l.items[l.index];
        l.index += 1;
        const mapping = item.target();
        if (mapping.data != .mapping) return p.fail(item, error.NotMergeable);
        try p.pushMapping(item, mapping);
        return null;
    }

    /// A merge key's value: a mapping, merged, or a sequence, each of its
    /// mappings merged in turn.
    fn mergeValue(p: *Pairs, value: *const Node) Error!void {
        const v = value.target();
        switch (v.data) {
            .mapping => try p.pushMapping(value, v),
            .sequence => |s| {
                if (p.frames.items.len >= p.max_depth) return p.fail(value, error.DepthLimit);
                try p.frames.append(p.gpa, .{ .list = .{ .items = s.items } });
            },
            else => return p.fail(value, error.NotMergeable),
        }
    }

    /// Begins merging `mapping`, named at `at`: not one being merged now
    /// (a cycle), and skipped if merged already.
    fn pushMapping(p: *Pairs, at: *const Node, mapping: *const Node) Error!void {
        for (p.frames.items) |f| {
            if (f == .mapping and f.mapping.node == mapping) return p.fail(at, error.Cycle);
        }
        if (p.frames.items.len >= p.max_depth) return p.fail(at, error.DepthLimit);
        const entry = try p.merged.getOrPut(p.gpa, mapping);
        if (entry.found_existing) return;
        try p.frames.append(p.gpa, .{ .mapping = .{ .node = mapping } });
    }

    /// Records `key` as given; false when a merged key is one given
    /// already (an own key is given whatever came before it).
    fn give(p: *Pairs, key: *const Node, own: bool) Error!bool {
        if (!own and p.isGiven(key)) return false;
        if (p.given.items.len < linear_keys) {
            try p.given.append(p.gpa, key);
            return true;
        }
        const ctx = p.keyContext();
        if (p.set.count() == 0) {
            for (p.given.items) |k| try p.set.putContext(p.gpa, k, {}, ctx);
        }
        try p.set.putContext(p.gpa, key, {}, ctx);
        return true;
    }

    fn keyContext(p: *Pairs) KeyContext {
        return .{ .seed = p.composer.hashSeed(), .schema = p.composer.options.schema };
    }

    fn isGiven(p: *Pairs, key: *const Node) bool {
        if (p.set.count() > 0) return p.set.containsContext(key, p.keyContext());
        for (p.given.items) |k| {
            if (Composer.equal(p.composer.options.schema, k, key)) return true;
        }
        return false;
    }

    fn fail(p: *Pairs, at: *const Node, err: Error) Error {
        p.failed_at = at;
        return err;
    }
};
