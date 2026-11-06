//! The checks the harness runs on the yaml-test-suite's cases, and the
//! skip list that ratchets them.
//!
//! A check either applies to a case or not (the events check, to a case
//! that has `test.event` and is valid YAML), and passes or fails. The skip
//! list (test/suite-skip.txt, one `<check> <case>` a line) names the
//! checks known to fail. A check that fails and is not listed is a
//! regression; one that is listed and passes must come off the list. So a
//! pass can never be lost silently, and each fix shows in the list's diff.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const suite = @import("suite.zig");

pub const Check = enum {
    /// `in.yaml` parses to the events `test.event` holds.
    events,

    pub fn applies(check: Check, case: suite.Case) bool {
        return switch (check) {
            .events => case.has.contains(.event) and !case.has.contains(.@"error"),
        };
    }
};

/// What a check found wrong with a case, or null when it passed.
pub fn run(arena: Allocator, io: Io, root: Io.Dir, case: suite.Case, check: Check) !?[]const u8 {
    return switch (check) {
        .events => checkEvents(arena, io, root, case),
    };
}

pub fn readCaseFile(arena: Allocator, io: Io, root: Io.Dir, case: suite.Case, file: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case.name, file });
    return root.readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
}

fn checkEvents(arena: Allocator, io: Io, root: Io.Dir, case: suite.Case) !?[]const u8 {
    const input = try readCaseFile(arena, io, root, case, "in.yaml");
    const want = try readCaseFile(arena, io, root, case, "test.event");
    var got: Io.Writer.Allocating = .init(arena);
    if (try writeEvents(arena, input, &got.writer)) |problem| return problem;
    return firstDifference(arena, want, got.written());
}

/// Writes the events `input` parses to, in the suite's notation, and
/// returns null; or stops at a syntax error and returns where and what.
pub fn writeEvents(arena: Allocator, input: []const u8, w: *Io.Writer) !?[]const u8 {
    var parser: yaml.Parser = .init(arena, input);
    defer parser.deinit();
    while (true) {
        const event = parser.next() catch |err| switch (err) {
            error.SyntaxError => {
                const d = parser.diagnostic;
                return try std.fmt.allocPrint(arena, "error at {d}:{d}: {s}", .{ d.mark.line + 1, d.mark.column + 1, d.message });
            },
            else => return err,
        };
        try yaml.Parser.writeTestEvent(w, event);
        if (event.data == .stream_end) return null;
    }
}

/// Null when `want` and `got` are the same; otherwise the first line
/// where they differ, both ways.
pub fn firstDifference(arena: Allocator, want: []const u8, got: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, want, got)) return null;
    var want_lines = std.mem.splitScalar(u8, want, '\n');
    var got_lines = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const w = want_lines.next();
        const g = got_lines.next();
        if (w != null and g != null and std.mem.eql(u8, w.?, g.?)) continue;
        return try std.fmt.allocPrint(arena, "line {d}: want `{s}`, got `{s}`", .{ line, w orelse "(the end)", g orelse "(the end)" });
    }
}

/// The checks known to fail: `<check> <case>` a line, `#` to the line's
/// end a comment.
pub const SkipList = struct {
    entries: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub const ParseError = error{BadSkipLine} || Allocator.Error;

    /// Reads `text`. On `error.BadSkipLine`, `bad_line` is its number.
    pub fn parse(arena: Allocator, text: []const u8, bad_line: *usize) ParseError!SkipList {
        var list: SkipList = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trim(u8, std.mem.sliceTo(raw, '#'), " \t\r");
            if (line.len == 0) continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const check_name = words.next().?;
            const case_name = words.next() orelse "";
            if (std.meta.stringToEnum(Check, check_name) == null or case_name.len == 0 or words.next() != null) {
                bad_line.* = number;
                return error.BadSkipLine;
            }
            try list.entries.put(arena, try key(arena, std.meta.stringToEnum(Check, check_name).?, case_name), {});
        }
        return list;
    }

    pub fn contains(list: SkipList, arena: Allocator, check: Check, case: []const u8) !bool {
        return list.entries.contains(try key(arena, check, case));
    }

    fn key(arena: Allocator, check: Check, case: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ @tagName(check), case });
    }
};

/// One check of one case that does not go as the skip list says.
pub const Finding = struct {
    check: Check,
    case: suite.Case,
    /// What failed; null when the check passed but was listed to fail.
    problem: ?[]const u8,
};

pub const Tally = struct {
    passed: std.EnumArray(Check, usize) = .initFill(0),
    skipped: std.EnumArray(Check, usize) = .initFill(0),
    regressions: std.ArrayList(Finding) = .empty,
    fixed: std.ArrayList(Finding) = .empty,
    /// Skip entries that name no case the check applies to.
    stale: std.ArrayList([]const u8) = .empty,

    pub fn ok(t: Tally) bool {
        return t.regressions.items.len == 0 and t.fixed.items.len == 0 and t.stale.items.len == 0;
    }
};

/// Runs every check on every case it applies to, against the skip list.
pub fn runAll(arena: Allocator, io: Io, root: Io.Dir, cases: []const suite.Case, skips: SkipList) !Tally {
    var tally: Tally = .{};
    var used: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (cases) |case| {
        for (std.enums.values(Check)) |check| {
            if (!check.applies(case)) continue;
            const listed = try skips.contains(arena, check, case.name);
            if (listed) try used.put(arena, try SkipList.key(arena, check, case.name), {});
            const problem = try run(arena, io, root, case, check);
            try tallyOne(arena, &tally, .{ .check = check, .case = case, .problem = problem }, listed);
        }
    }
    for (skips.entries.keys()) |entry| {
        if (!used.contains(entry)) try tally.stale.append(arena, entry);
    }
    return tally;
}

fn tallyOne(arena: Allocator, tally: *Tally, finding: Finding, listed: bool) !void {
    if (finding.problem == null and !listed) {
        tally.passed.getPtr(finding.check).* += 1;
    } else if (finding.problem != null and listed) {
        tally.skipped.getPtr(finding.check).* += 1;
    } else if (listed) {
        try tally.fixed.append(arena, finding);
    } else {
        try tally.regressions.append(arena, finding);
    }
}

pub fn writeTally(w: *Io.Writer, tally: Tally) Io.Writer.Error!void {
    for (std.enums.values(Check)) |check| {
        try w.print("{s}: {d} pass, {d} skipped as known to fail\n", .{ @tagName(check), tally.passed.get(check), tally.skipped.get(check) });
    }
    for (tally.regressions.items) |f| {
        try w.print("FAIL {s} {s} ({s}): {s}\n", .{ @tagName(f.check), f.case.name, f.case.title, f.problem.? });
    }
    for (tally.fixed.items) |f| {
        try w.print("PASS {s} {s} ({s}), listed to fail: take it off test/suite-skip.txt\n", .{ @tagName(f.check), f.case.name, f.case.title });
    }
    for (tally.stale.items) |entry| {
        try w.print("STALE test/suite-skip.txt names `{s}`, which is no check of a case\n", .{entry});
    }
    if (tally.regressions.items.len > 0) try w.writeAll("`zig build suite -- show <case>` prints a case's input and both event streams.\n");
}

const testing = std.testing;

test "firstDifference: none, a changed line, a missing one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try firstDifference(a, "+STR\n-STR\n", "+STR\n-STR\n"));
    try testing.expectEqualStrings("line 2: want `=VAL :a`, got `=VAL :b`", (try firstDifference(a, "+STR\n=VAL :a\n", "+STR\n=VAL :b\n")).?);
    try testing.expectEqualStrings("line 2: want `-STR`, got ``", (try firstDifference(a, "+STR\n-STR\n", "+STR\n")).?);
}

test "SkipList: entries, comments, and a bad line named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: usize = 0;
    const list = try SkipList.parse(a, "# known failures\nevents 229Q  # why\n\nevents 3RLN/00\n", &bad);
    try testing.expect(try list.contains(a, .events, "229Q"));
    try testing.expect(try list.contains(a, .events, "3RLN/00"));
    try testing.expect(!try list.contains(a, .events, "2JQS"));
    try testing.expectError(error.BadSkipLine, SkipList.parse(a, "events 229Q\nevent 2JQS\n", &bad));
    try testing.expectEqual(2, bad);
    try testing.expectError(error.BadSkipLine, SkipList.parse(a, "events\n", &bad));
    try testing.expectError(error.BadSkipLine, SkipList.parse(a, "events a b\n", &bad));
}

test "tallyOne: each way a check can go against the list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tally: Tally = .{};
    const case: suite.Case = .{ .name = "229Q", .title = "t", .has = .empty };
    try tallyOne(a, &tally, .{ .check = .events, .case = case, .problem = null }, false);
    try tallyOne(a, &tally, .{ .check = .events, .case = case, .problem = "x" }, true);
    try testing.expect(tally.ok());
    try tallyOne(a, &tally, .{ .check = .events, .case = case, .problem = null }, true);
    try tallyOne(a, &tally, .{ .check = .events, .case = case, .problem = "x" }, false);
    try testing.expect(!tally.ok());
    try testing.expectEqual(1, tally.passed.get(.events));
    try testing.expectEqual(1, tally.skipped.get(.events));
    try testing.expectEqual(1, tally.fixed.items.len);
    try testing.expectEqual(1, tally.regressions.items.len);
}
