//! A map from strings to values, for a mapping whose keys a program does
//! not know when it is compiled (a config's environment variables, say),
//! after std.json.ArrayHashMap. As a field of a type `parseFromSlice`
//! builds, it takes any mapping whose keys are scalars, in the
//! document's order, building each value as a `T`; `stringify` writes it
//! back as a mapping in the same order.
//!
//! Its keys come from the input, so it hashes them with a seed: one from
//! a hash of the input when construction builds it (kb/t7), so keys made
//! to collide under a fixed seed cost what any keys do.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Hashes a map's keys with a seed.
pub const Context = struct {
    seed: u64 = 0,

    pub fn hash(ctx: Context, key: []const u8) u32 {
        return @truncate(std.hash.Wyhash.hash(ctx.seed, key));
    }

    pub fn eql(_: Context, a: []const u8, b: []const u8, _: usize) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// A map from strings to `T`s that keeps the order its keys came in.
pub fn ArrayHashMap(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The map underneath; pass `context` to its calls that take one.
        pub const Map = std.array_hash_map.Custom([]const u8, T, Context, true);
        /// What typed construction builds each value as.
        pub const yaml_map_value = T;

        map: Map = .empty,
        context: Context = .{},

        /// The value of `key`, if the map has it.
        pub fn get(self: Self, key: []const u8) ?T {
            return self.map.getContext(key, self.context);
        }

        /// Sets `key`'s value; a key already there keeps its place.
        pub fn put(self: *Self, gpa: Allocator, key: []const u8, value: T) Allocator.Error!void {
            try self.map.putContext(gpa, key, value, self.context);
        }

        /// How many keys the map has.
        pub fn count(self: Self) usize {
            return self.map.count();
        }

        /// The keys, in order.
        pub fn keys(self: Self) [][]const u8 {
            return self.map.keys();
        }

        /// The values, in the keys' order.
        pub fn values(self: Self) []T {
            return self.map.values();
        }

        /// Frees the map's storage (not the keys or values it points at).
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.map.deinit(gpa);
        }
    };
}
