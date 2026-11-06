//! `zig build bench [-- records [runs]]` (karte t46): how fast each stage
//! reads a document of typical config records, and what it allocates.
//!
//! Each stage runs `runs` times (7 by default) over one document it
//! generates (20,000 records, about 4.9 MB, by default): the scanner's
//! tokens, the parser's events, the composer's nodes, a Value, a typed
//! slice of records, and stringify writing that slice back. It prints
//! each stage's median time and throughput, and from its first run the
//! allocator's calls, the bytes asked for and the most held at once, as
//! a counting allocator over smp_allocator saw them. The library is
//! built ReleaseFast, as a consumer would ship it.
//!
//! A change claimed faster or leaner cites this step's numbers before and
//! after. Allocations, bytes and peak are exact, the same every run. The
//! times are not: over five runs of this step (2026-11-06, an M-series
//! Mac at a load of about 5) each stage's median moved by 4 to 10%, so a
//! time that moves less than 10% is no result.

const std = @import("std");
const yaml = @import("yaml");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// An allocator that counts what passes through it to `child`: calls,
/// bytes asked for, and the most held at once.
const Counting = struct {
    child: Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    bytes: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(c: *Counting, old: usize, new: usize) void {
        if (new > old) {
            c.bytes += new - old;
            c.live += new - old;
            c.peak = @max(c.peak, c.live);
        } else {
            c.live -= old - new;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, alignment, ret) orelse return null;
        c.allocs += 1;
        c.grew(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(memory, alignment, len, ret)) return false;
        c.resizes += 1;
        c.grew(memory.len, len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(memory, alignment, len, ret) orelse return null;
        c.resizes += 1;
        c.grew(memory.len, len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ret);
        c.live -= memory.len;
    }
};

const Record = struct {
    name: []const u8,
    id: u32,
    ratio: f64,
    enabled: bool,
    tags: []const []const u8,
    owner: ?[]const u8,
    description: []const u8,
    ports: []const u16,
    env: yaml.ArrayHashMap([]const u8),
};

/// `records` config records, each holding the shapes configs do: plain
/// strings and numbers, a null, a flow sequence with a quoted item, a
/// folded scalar, a block sequence and a flow mapping.
fn document(gpa: Allocator, records: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (0..records) |i| try text.print(gpa,
        \\- name: service-{d}
        \\  id: {d}
        \\  ratio: 0.{d}
        \\  enabled: true
        \\  tags: [alpha, beta, "gamma {d}"]
        \\  owner: ~
        \\  description: >
        \\    A folded description of service {d}
        \\    across two lines.
        \\  ports:
        \\    - 80
        \\    - 443
        \\  env: {{A: "x", B: 'y'}}
        \\
    , .{ i, i, i % 100, i, i });
    return text.toOwnedSlice(gpa);
}

const Stage = enum { scan, parse, compose, value, typed, stringify };

/// Runs `stage` over `text` once; what it returns keeps the work from
/// being optimized away.
fn run(stage: Stage, gpa: Allocator, text: []const u8, records: []const Record) !usize {
    switch (stage) {
        .scan => {
            var s: yaml.Scanner = .init(gpa, text);
            defer s.deinit();
            var n: usize = 0;
            while ((try s.next()).data != .stream_end) n += 1;
            return n;
        },
        .parse => {
            var p: yaml.Parser = .init(gpa, text);
            defer p.deinit();
            var n: usize = 0;
            while ((try p.next()).data != .stream_end) n += 1;
            return n;
        },
        .compose => {
            var c: yaml.Composer = .init(gpa, text, .{});
            defer c.deinit();
            return (try c.next()).?.root.data.sequence.items.len;
        },
        .value => {
            const v = try yaml.parseFromSlice(yaml.Value, gpa, text, .{});
            defer v.deinit();
            return v.value.sequence.len;
        },
        .typed => {
            const v = try yaml.parseFromSlice([]const Record, gpa, text, .{});
            defer v.deinit();
            return v.value.len;
        },
        .stringify => {
            const out = try yaml.stringifyAlloc(gpa, records, .{});
            defer gpa.free(out);
            return out.len;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const records = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 20_000;
    const runs = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 7;
    if (runs == 0) return error.NoRuns;

    const base = std.heap.smp_allocator;
    const text = try document(base, records);
    defer base.free(text);
    const typed = try yaml.parseFromSlice([]const Record, base, text, .{});
    defer typed.deinit();

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;
    try w.print("{d} records, {d} bytes; the median of {d} runs, ReleaseFast\n", .{ records, text.len, runs });
    try w.print("{s:<10} {s:>9} {s:>8} {s:>9} {s:>8} {s:>12} {s:>12}\n", .{ "stage", "ms", "MB/s", "allocs", "resizes", "bytes", "peak" });
    const times = try init.arena.allocator().alloc(i96, runs);
    for (std.enums.values(Stage)) |stage| {
        var first: Counting = .{ .child = base };
        for (times, 0..) |*t, i| {
            var counting: Counting = .{ .child = base };
            const start = Io.Clock.awake.now(io);
            std.mem.doNotOptimizeAway(try run(stage, counting.allocator(), text, typed.value));
            t.* = start.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
            if (i == 0) first = counting;
        }
        std.mem.sort(i96, times, {}, std.sort.asc(i96));
        const ms = @as(f64, @floatFromInt(times[times.len / 2])) / 1e6;
        const mbs = @as(f64, @floatFromInt(text.len)) / 1e3 / ms;
        try w.print("{s:<10} {d:>9.1} {d:>8.1} {d:>9} {d:>8} {d:>12} {d:>12}\n", .{ @tagName(stage), ms, mbs, first.allocs, first.resizes, first.bytes, first.peak });
    }
    try w.flush();
}
