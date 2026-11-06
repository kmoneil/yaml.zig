//! The yaml-test-suite harness.
//!
//!     suite <suite-dir> --skip <file> [check] [--quiet]
//!     suite <suite-dir> --skip <file> list [--all]
//!     suite <suite-dir> --skip <file> show <case>
//!
//! `check` runs every check on every case it applies to against the skip
//! list (check.zig), prints how many pass and what does not go as the
//! list says, and exits 1 on a regression, a listed check that now
//! passes, or a list entry that names nothing. `--quiet` prints only
//! that. `list` counts the cases and what they hold, `--all` each case
//! too. `show` prints one case: its input, its events, and this
//! library's.

const std = @import("std");
const Io = std.Io;
const suite = @import("suite.zig");
const check = @import("check.zig");

const Command = enum { check, list, show };

const Options = struct {
    root: []const u8,
    skip: []const u8,
    command: Command = .check,
    quiet: bool = false,
    all: bool = false,
    case: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const options = parseArgs(init.minimal.args) catch return usage();
    var root = try Io.Dir.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root.close(io);

    var problem: suite.Problem = .{};
    const cases = suite.collect(arena, io, root, &problem) catch |err| switch (err) {
        error.BadLayout => fatal("suite: {s}: {s}\n", .{ problem.path, problem.why }),
        else => return err,
    };

    var buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    switch (options.command) {
        .list => {
            if (options.all) for (cases) |case| try suite.writeCase(out, case);
            try suite.writeSummary(out, cases);
        },
        .show => try show(arena, io, root, cases, options.case.?, out),
        .check => {
            const tally = try runCheck(arena, io, root, cases, options.skip);
            if (!tally.ok() or !options.quiet) try check.writeTally(out, tally);
            if (!tally.ok()) {
                try out.flush();
                std.process.exit(1);
            }
        },
    }
}

fn parseArgs(args: std.process.Args) error{Usage}!Options {
    var it: std.process.Args.Iterator = .init(args);
    _ = it.skip();
    const root = it.next() orelse return error.Usage;
    if (!std.mem.eql(u8, it.next() orelse "", "--skip")) return error.Usage;
    var options: Options = .{ .root = root, .skip = it.next() orelse return error.Usage };
    while (it.next()) |arg| {
        if (std.meta.stringToEnum(Command, arg)) |command| {
            options.command = command;
            if (command == .show) options.case = it.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.all = true;
        } else return error.Usage;
    }
    return options;
}

fn runCheck(arena: std.mem.Allocator, io: Io, root: Io.Dir, cases: []const suite.Case, skip_path: []const u8) !check.Tally {
    const text = try Io.Dir.cwd().readFileAlloc(io, skip_path, arena, .limited(1024 * 1024));
    var bad_line: usize = 0;
    const skips = check.SkipList.parse(arena, text, &bad_line) catch |err| switch (err) {
        error.BadSkipLine => fatal("suite: {s}:{d}: a line is `<check> <case>`, the check one of: events\n", .{ skip_path, bad_line }),
        else => return err,
    };
    return check.runAll(arena, io, root, cases, skips);
}

fn show(arena: std.mem.Allocator, io: Io, root: Io.Dir, cases: []const suite.Case, name: []const u8, out: *Io.Writer) !void {
    const case = for (cases) |case| {
        if (std.mem.eql(u8, case.name, name)) break case;
    } else fatal("suite: no case is named {s}\n", .{name});
    const input = try check.readCaseFile(arena, io, root, case, "in.yaml");
    try out.print("=== {s}: {s}\n--- in.yaml\n{s}\n", .{ case.name, case.title, input });
    if (case.has.contains(.@"error")) try out.writeAll("--- (the suite has this input fail)\n");
    if (case.has.contains(.event)) try out.print("--- test.event\n{s}", .{try check.readCaseFile(arena, io, root, case, "test.event")});
    try out.writeAll("--- events from this library\n");
    if (try check.writeEvents(arena, input, out)) |problem| try out.print("{s}\n", .{problem});
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn usage() error{Usage} {
    std.debug.print(
        \\usage: suite <suite-dir> --skip <file> [check] [--quiet]
        \\       suite <suite-dir> --skip <file> list [--all]
        \\       suite <suite-dir> --skip <file> show <case>
        \\
    , .{});
    return error.Usage;
}

test {
    _ = suite;
    _ = check;
}
