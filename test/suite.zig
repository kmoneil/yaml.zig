//! The yaml-test-suite's cases, as its data tree lays them out (the
//! data-* tags of github.com/yaml/yaml-test-suite): one directory per
//! test id, holding `===` (the title), `in.yaml`, and some of
//! `test.event`, `in.json`, `out.yaml`, `emit.yaml` and `error`. A test
//! with variants holds none of these itself but numbered directories
//! (`00`, `01`, ...), each a case laid out the same way. The tree's
//! `name` and `tags` directories index the tests by other keys and are
//! not read. main.zig is the harness that runs them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A file a case may hold besides `===` and `in.yaml`, which every case
/// holds.
pub const File = enum {
    /// The events `in.yaml` parses to, in the suite's notation.
    event,
    /// The JSON `in.yaml` loads to.
    json,
    /// `in.yaml` written out again in a normal form.
    out_yaml,
    /// What an emitter writes from the events.
    emit_yaml,
    /// `in.yaml` is not valid YAML; `test.event` then holds the events
    /// before the error.
    @"error",

    pub fn fileName(file: File) []const u8 {
        return switch (file) {
            .event => "test.event",
            .json => "in.json",
            .out_yaml => "out.yaml",
            .emit_yaml => "emit.yaml",
            .@"error" => "error",
        };
    }
};

pub const Case = struct {
    /// The test id, with the variant after a slash: `229Q`, `3RLN/03`.
    /// Also the case's directory under the suite's root.
    name: []const u8,
    /// The first line of `===`.
    title: []const u8,
    has: std.EnumSet(File),
};

/// What `collect` found that the suite's layout does not allow.
pub const Problem = struct {
    /// The directory, from the suite's root.
    path: []const u8 = "",
    why: []const u8 = "",
};

/// Every case under `root` (open with `iterate`), sorted by name. All of
/// it is allocated in `arena`. On `error.BadLayout`, `problem` says
/// where and why.
pub fn collect(arena: Allocator, io: Io, root: Io.Dir, problem: *Problem) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !isTestId(entry.name)) continue;
        const id = try arena.dupe(u8, entry.name);
        if (try holds(io, root, id, "in.yaml")) {
            try cases.append(arena, try readCase(arena, io, root, id));
            continue;
        }
        const before = cases.items.len;
        try collectVariants(arena, io, root, id, &cases);
        if (cases.items.len == before) {
            problem.* = .{ .path = id, .why = "holds neither in.yaml nor a numbered variant" };
            return error.BadLayout;
        }
    }
    std.mem.sort(Case, cases.items, {}, byName);
    return cases.items;
}

/// Appends the cases in `id`'s numbered directories.
fn collectVariants(arena: Allocator, io: Io, root: Io.Dir, id: []const u8, cases: *std.ArrayList(Case)) !void {
    var dir = try root.openDir(io, id, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !isVariant(entry.name)) continue;
        const name = try arena.print("{s}/{s}", .{ id, entry.name });
        try cases.append(arena, try readCase(arena, io, root, name));
    }
}

fn readCase(arena: Allocator, io: Io, root: Io.Dir, name: []const u8) !Case {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);
    const title_file = try dir.readFileAlloc(io, "===", arena, .limited(4096));
    var has: std.EnumSet(File) = .empty;
    for (std.enums.values(File)) |file| {
        if (try holds(io, dir, ".", file.fileName())) has.insert(file);
    }
    return .{
        .name = name,
        .title = std.mem.sliceTo(title_file, '\n'),
        .has = has,
    };
}

/// Whether `dir`'s `sub` directory holds a file named `file`.
fn holds(io: Io, dir: Io.Dir, sub: []const u8, file: []const u8) !bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ sub, file });
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// A test id: four characters, each a digit or an upper-case letter.
fn isTestId(name: []const u8) bool {
    if (name.len != 4) return false;
    for (name) |c| {
        if (!std.ascii.isDigit(c) and !std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// A variant directory: digits only.
fn isVariant(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn byName(_: void, a: Case, b: Case) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// How many tests `cases` come from, and how many of those have variants.
pub const Counts = struct {
    tests: usize = 0,
    with_variants: usize = 0,
    has: std.EnumArray(File, usize) = .initFill(0),

    pub fn of(cases: []const Case) Counts {
        var counts: Counts = .{};
        var last_id: []const u8 = "";
        for (cases) |case| {
            const id = case.name[0..4];
            if (!std.mem.eql(u8, id, last_id)) {
                counts.tests += 1;
                if (case.name.len > 4) counts.with_variants += 1;
                last_id = id;
            }
            var it = case.has.iterator();
            while (it.next()) |file| counts.has.getPtr(file).* += 1;
        }
        return counts;
    }
};

pub fn writeSummary(w: *Io.Writer, cases: []const Case) Io.Writer.Error!void {
    const counts: Counts = .of(cases);
    try w.print("{d} cases in {d} tests ({d} with variants); cases holding", .{ cases.len, counts.tests, counts.with_variants });
    for (std.enums.values(File), 0..) |file, i| {
        try w.print("{s} {s} {d}", .{ if (i == 0) "" else ",", file.fileName(), counts.has.get(file) });
    }
    try w.writeAll("\n");
}

pub fn writeCase(w: *Io.Writer, case: Case) Io.Writer.Error!void {
    try w.print("{s:<7}", .{case.name});
    for (std.enums.values(File)) |file| {
        try w.print(" {s:<10}", .{if (case.has.contains(file)) file.fileName() else "-"});
    }
    try w.print("  {s}\n", .{case.title});
}

const testing = std.testing;

test "collect: plain tests, variants, and the index directories left out" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const files = [_][2][]const u8{
        .{ "229Q/===", "Spec Example 2.1. Sequence of Scalars\n" },
        .{ "229Q/in.yaml", "- a\n" },
        .{ "229Q/test.event", "+STR\n" },
        .{ "229Q/in.json", "[\"a\"]\n" },
        .{ "3RLN/01/===", "Leading tabs in double quoted\n" },
        .{ "3RLN/01/in.yaml", "\"1 \\\t\"\n" },
        .{ "3RLN/00/===", "Leading tabs in double quoted\n" },
        .{ "3RLN/00/in.yaml", "\"1\"\n" },
        .{ "3RLN/00/error", "" },
        .{ "name/spec-example-2-1/===", "an index, not a test\n" },
        .{ "tags/flow/===", "an index, not a test\n" },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |dir| try tmp.dir.createDirPath(io, dir);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    const cases = try collect(arena.allocator(), io, tmp.dir, &problem);

    try testing.expectEqual(3, cases.len);
    try testing.expectEqualStrings("229Q", cases[0].name);
    try testing.expectEqualStrings("Spec Example 2.1. Sequence of Scalars", cases[0].title);
    try testing.expect(cases[0].has.contains(.event));
    try testing.expect(cases[0].has.contains(.json));
    try testing.expect(!cases[0].has.contains(.@"error"));
    try testing.expectEqualStrings("3RLN/00", cases[1].name);
    try testing.expect(cases[1].has.contains(.@"error"));
    try testing.expectEqualStrings("3RLN/01", cases[2].name);
    try testing.expectEqual(0, cases[2].has.count());

    const counts: Counts = .of(cases);
    try testing.expectEqual(2, counts.tests);
    try testing.expectEqual(1, counts.with_variants);
    try testing.expectEqual(1, counts.has.get(.@"error"));
}

test "collect: a test directory with no case in it is a problem named" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "ZZ99/notes");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    try testing.expectError(error.BadLayout, collect(arena.allocator(), io, tmp.dir, &problem));
    try testing.expectEqualStrings("ZZ99", problem.path);
}

test "writeCase: a line per case, the files it holds in columns" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var has: std.EnumSet(File) = .empty;
    has.insert(.event);
    has.insert(.@"error");
    try writeCase(&w, .{ .name = "3RLN/00", .title = "Leading tabs", .has = has });
    try testing.expectEqualStrings(
        "3RLN/00 test.event -          -          -          error       Leading tabs\n",
        w.buffered(),
    );
}
