//! Fuzz targets run two ways, as the other Zig repos here do. `zig build
//! test --fuzz` (or `zig build fuzz --fuzz`) hands each target to zig's
//! fuzzer, which runs it until stopped. A plain `zig build test` gives a
//! target only one empty input, and a `Smith` fed bytes it did not write
//! decodes nearly every value as its minimum, so targets draw through
//! `Draw` instead: the fuzzer's Smith when fuzzing, else a generator
//! seeded per run. Every test run explores `seeded` inputs, the same
//! ones each time, so a failure there reproduces.

const std = @import("std");
const builtin = @import("builtin");
const Smith = std.testing.Smith;

pub const Draw = struct {
    smith: ?*Smith = null,
    prng: std.Random.DefaultPrng = .init(0),

    /// The caller's site, as Smith keys its own calls: the fuzzer tells
    /// one decision from another by it.
    inline fn site(return_address: usize) u32 {
        return @truncate(std.hash.int(return_address));
    }

    /// A number below `len`, which must not be 0.
    pub noinline fn index(d: *Draw, len: usize) usize {
        if (d.smith) |s| return s.indexWithHash(len, site(@returnAddress()));
        return d.prng.random().uintLessThan(usize, len);
    }

    pub noinline fn atMost(d: *Draw, comptime T: type, at_least: T, at_most: T) T {
        if (d.smith) |s| return s.valueRangeAtMostWithHash(T, at_least, at_most, site(@returnAddress()));
        return d.prng.random().intRangeAtMost(T, at_least, at_most);
    }

    pub noinline fn boolean(d: *Draw) bool {
        if (d.smith) |s| return s.valueWithHash(bool, site(@returnAddress()));
        return d.prng.random().boolean();
    }

    /// Some bytes, any length up to `buf.len`.
    pub noinline fn bytes(d: *Draw, buf: []u8) []u8 {
        if (d.smith) |s| return buf[0..s.sliceWithHash(buf, site(@returnAddress()))];
        const len = d.prng.random().uintAtMost(usize, buf.len);
        d.prng.random().bytes(buf[0..len]);
        return buf[0..len];
    }

    /// One of `items`.
    pub fn pick(d: *Draw, comptime T: type, items: []const T) T {
        return items[d.index(items.len)];
    }
};

pub fn run(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), draw: *Draw) anyerror!void,
    seeded: usize,
) anyerror!void {
    const Context = @TypeOf(context);
    try std.testing.fuzz(context, struct {
        fn one(ctx: Context, smith: *Smith) anyerror!void {
            var draw: Draw = .{ .smith = smith };
            try testOne(ctx, &draw);
        }
    }.one, .{});
    if (builtin.fuzz) return;
    for (0..seeded) |seed| {
        var draw: Draw = .{ .prng = .init(seed) };
        errdefer std.debug.print("seeded run {d} of {d} failed; Draw{{ .prng = .init({d}) }} replays it\n", .{ seed, seeded, seed });
        try testOne(context, &draw);
    }
}
