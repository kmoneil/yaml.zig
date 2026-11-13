//! `zig build bench [-- records [runs]]` (karte t46): how fast each stage
//! reads a document of typical config records, and what it allocates.
//! `zig build bench -- text [records [runs]]`: the reading stages over a
//! document of long text instead (`textDocument`, 4,000 records by
//! default), where a change to how text is scanned shows (t50).
//! `zig build bench -- rss STAGE [records]`: the memory one stage holds
//! resident, in a process of its own.
//! `zig build bench -- write PATH [records]`: the document, to a file.
//! `zig build bench -- file STAGE RUNS PATH`: one stage over a file, one
//! run to warm up and then RUNS, the median in ms on a line; with RUNS 0,
//! one run alone, its time, as a process that parses once sees it; `read`
//! only reads the file. Its memory comes from malloc, as the other
//! libraries' does. The interface of tools/compare's harnesses for other
//! libraries (t54).
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
//! The counter's peak is address space asked for: an arena's last
//! buffer, grown by half again, is counted whole, and where its growth
//! lands moves the peak by more than a small saving. What a stage holds
//! resident is `rss`'s: the process's peak resident memory after the
//! stage less before it, the stage run once in a fresh process, as only
//! a process's peak can be read.
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
/// folded scalar, a block sequence and a flow mapping. Measured first and
/// written once at its length, so no growth leaves a peak behind for
/// `rss` to count against a stage.
fn document(gpa: Allocator, records: usize) ![]u8 {
    var counting: Io.Writer.Discarding = .init(&.{});
    for (0..records) |i| try writeRecord(&counting.writer, i);
    const text = try gpa.alloc(u8, @intCast(counting.fullCount()));
    errdefer gpa.free(text);
    var w: Io.Writer = .fixed(text);
    for (0..records) |i| try writeRecord(&w, i);
    return text;
}

/// A document of `records` records of long text, about 4.1 MB for
/// 4,000 (`zig build bench -- text`): a comment, a plain summary past
/// the width, a literal script and folded notes, their words drawn by a
/// seeded generator, so their lengths vary as prose's do and the
/// branches that read them cannot learn one record's shape, as they do
/// the config records'. Written once at its length, as `document` is.
fn textDocument(gpa: Allocator, records: usize) ![]u8 {
    var counting: Io.Writer.Discarding = .init(&.{});
    var prng: std.Random.DefaultPrng = .init(50);
    for (0..records) |i| try writeTextRecord(&counting.writer, prng.random(), i);
    const text = try gpa.alloc(u8, @intCast(counting.fullCount()));
    errdefer gpa.free(text);
    var w: Io.Writer = .fixed(text);
    prng = .init(50);
    for (0..records) |i| try writeTextRecord(&w, prng.random(), i);
    return text;
}

fn writeTextRecord(w: *Io.Writer, r: std.Random, i: usize) Io.Writer.Error!void {
    try w.print("- name: service-{d}\n  # ", .{i});
    try writeWords(w, r, 8, 24);
    try w.writeAll("\n  summary: ");
    try writeWords(w, r, 10, 30);
    try w.writeAll("\n  script: |\n");
    for (0..r.intRangeAtMost(usize, 2, 8)) |_| {
        try w.writeAll("    ");
        try writeWords(w, r, 6, 18);
        try w.writeByte('\n');
    }
    try w.writeAll("  notes: >\n");
    for (0..r.intRangeAtMost(usize, 1, 4)) |_| {
        try w.writeAll("    ");
        try writeWords(w, r, 6, 18);
        try w.writeByte('\n');
    }
}

/// From `least` to `most` words of 1 to 12 lowercase letters.
fn writeWords(w: *Io.Writer, r: std.Random, least: usize, most: usize) Io.Writer.Error!void {
    for (0..r.intRangeAtMost(usize, least, most)) |k| {
        if (k > 0) try w.writeByte(' ');
        for (0..r.intRangeAtMost(usize, 1, 12)) |_| try w.writeByte('a' + r.uintLessThan(u8, 26));
    }
}

fn writeRecord(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    try w.print(
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
}

/// The records `document` writes, built in memory, for stringify's `rss`:
/// reading them would leave reading's peak behind it.
fn built(gpa: Allocator, count: usize) ![]Record {
    const out = try gpa.alloc(Record, count);
    for (out, 0..) |*r, i| {
        var env: yaml.ArrayHashMap([]const u8) = .{};
        try env.put(gpa, "A", "x");
        try env.put(gpa, "B", "y");
        r.* = .{
            .name = try std.fmt.allocPrint(gpa, "service-{d}", .{i}),
            .id = @intCast(i),
            .ratio = @as(f64, @floatFromInt(i % 100)) / 100,
            .enabled = true,
            .tags = &.{ "alpha", "beta", "gamma" },
            .owner = null,
            .description = "A folded description of a service across two lines.\n",
            .ports = &.{ 80, 443 },
            .env = env,
        };
    }
    return out;
}

/// The process's peak resident memory so far, in bytes.
fn peakResident() usize {
    const rusage = std.posix.getrusage(std.posix.rusage.SELF);
    const max: usize = @intCast(rusage.maxrss);
    // Linux counts KiB, macOS bytes.
    return if (@import("builtin").os.tag == .linux) max * 1024 else max;
}

/// `rss STAGE [records]`: one run of the stage, and the resident memory
/// it added to the process's peak. The process ends after; nothing is
/// freed, as nothing more is read.
fn resident(io: Io, args: []const []const u8) !void {
    const stage = std.meta.stringToEnum(Stage, args[2]) orelse return error.UnknownStage;
    const count = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 20_000;
    const gpa = std.heap.smp_allocator;
    const text = try document(gpa, count);
    const records = if (stage == .stringify) try built(gpa, count) else &.{};
    const before = peakResident();
    std.mem.doNotOptimizeAway(try run(stage, gpa, text, records));
    const added = peakResident() - before;
    var buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    try stdout.interface.print("{s}: {d} records, {d} bytes; {d} bytes resident ({d:.1} times the input)\n", .{ @tagName(stage), count, text.len, added, @as(f64, @floatFromInt(added)) / @as(f64, @floatFromInt(text.len)) });
    try stdout.interface.flush();
}

/// `write PATH [records]`: the document `document` generates, to a file.
fn write(io: Io, args: []const []const u8) !void {
    const count = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 20_000;
    const text = try document(std.heap.smp_allocator, count);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = text });
}

/// `file STAGE RUNS PATH`: `stage` over the file's text, a run to warm up
/// and then RUNS, the median in ms; with RUNS 0, one run and no warm-up;
/// `read` stops once the file is read.
///
/// On malloc, as every other library's harness is (or a garbage
/// collector): what a run frees, the next is given again. On
/// smp_allocator, which gives large blocks back to the system, each run
/// had fresh pages to fault in, about 3,500 for compose (2026-11-07,
/// t56), a cost the others pay on their first run only.
fn timeFile(io: Io, args: []const []const u8) !void {
    const gpa = std.heap.c_allocator;
    const runs = try std.fmt.parseInt(usize, args[3], 10);
    const text = try Io.Dir.cwd().readFileAlloc(io, args[4], gpa, .unlimited);
    if (std.mem.eql(u8, args[2], "read")) return;
    const stage = std.meta.stringToEnum(Stage, args[2]) orelse return error.UnknownStage;
    if (stage == .stringify or runs > 64) return error.Usage;
    if (runs > 0) std.mem.doNotOptimizeAway(try run(stage, gpa, text, &.{}));
    var times: [64]u64 = undefined;
    for (times[0..@max(runs, 1)]) |*t| {
        const start = Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(try run(stage, gpa, text, &.{}));
        t.* = @intCast(start.durationTo(Io.Clock.awake.now(io)).nanoseconds);
    }
    const timed = times[0..@max(runs, 1)];
    std.mem.sort(u64, timed, {}, std.sort.asc(u64));
    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    try stdout.interface.print("{d:.1}\n", .{@as(f64, @floatFromInt(timed[timed.len / 2])) / 1e6});
    try stdout.interface.flush();
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
    if (args.len > 2 and std.mem.eql(u8, args[1], "rss")) return resident(io, args);
    if (args.len > 2 and std.mem.eql(u8, args[1], "write")) return write(io, args);
    if (args.len > 4 and std.mem.eql(u8, args[1], "file")) return timeFile(io, args);
    const long = args.len > 1 and std.mem.eql(u8, args[1], "text");
    const numbers = if (long) args[2..] else args[1..];
    const records: usize = if (numbers.len > 0) try std.fmt.parseInt(usize, numbers[0], 10) else if (long) 4_000 else 20_000;
    const runs = if (numbers.len > 1) try std.fmt.parseInt(usize, numbers[1], 10) else 7;
    if (runs == 0) return error.NoRuns;

    const base = std.heap.smp_allocator;
    const text = try if (long) textDocument(base, records) else document(base, records);
    defer base.free(text);
    // The text records are not Records: their stages are the reading ones.
    const typed: ?yaml.Parsed([]const Record) = if (long) null else try yaml.parseFromSlice([]const Record, base, text, .{});
    defer if (typed) |t| t.deinit();
    const stages: []const Stage = if (long) &.{ .scan, .parse, .compose, .value } else std.enums.values(Stage);
    const built_records: []const Record = if (typed) |p| p.value else &.{};

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;
    try w.print("{d} {s}records, {d} bytes; the median of {d} runs, ReleaseFast\n", .{ records, if (long) "text " else "", text.len, runs });
    try w.print("{s:<10} {s:>9} {s:>8} {s:>9} {s:>8} {s:>12} {s:>12}\n", .{ "stage", "ms", "MB/s", "allocs", "resizes", "bytes", "peak" });
    const times = try init.arena.allocator().alloc(i96, runs);
    for (stages) |stage| {
        var first: Counting = .{ .child = base };
        for (times, 0..) |*t, i| {
            var counting: Counting = .{ .child = base };
            const start = Io.Clock.awake.now(io);
            std.mem.doNotOptimizeAway(try run(stage, counting.allocator(), text, built_records));
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
