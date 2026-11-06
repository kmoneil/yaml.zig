//! The checks the harness runs on the yaml-test-suite's cases, and the
//! skip list that ratchets them.
//!
//! A check either applies to a case or not (the events check, to a case
//! that has `test.event` and is valid YAML; the error check, to one that
//! is not; the json check, to a valid one with `in.json`), and passes or
//! fails. Each parse runs on an allocator that
//! checks for leaks, and a leak fails the check. The skip
//! list (test/suite-skip.txt, one `<check> <case>` a line) names the
//! checks known to fail. A check that fails and is not listed is a
//! regression; one that is listed and passes must come off the list. So a
//! pass can never be lost silently, and each fix shows in the list's diff.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const suite = @import("suite.zig");
const json = @import("json.zig");
const roundtrip = @import("roundtrip.zig");

pub const Check = enum {
    /// `in.yaml` parses to the events `test.event` holds.
    events,
    /// `in.yaml` is not valid YAML, and parsing it ends in a syntax error.
    @"error",
    /// `in.yaml`'s documents, composed under the core schema, are the JSON
    /// documents `in.json` holds (json.zig).
    json,
    /// `in.yaml`'s events, emitted, read back to the same documents
    /// (roundtrip.zig).
    roundtrip,

    pub fn applies(check: Check, case: suite.Case) bool {
        return switch (check) {
            .events => case.has.contains(.event) and !case.has.contains(.@"error"),
            .@"error" => case.has.contains(.@"error"),
            .json => case.has.contains(.json) and !case.has.contains(.@"error"),
            .roundtrip => !case.has.contains(.@"error"),
        };
    }
};

/// What a check found wrong with a case, or null when it passed.
pub fn run(arena: Allocator, io: Io, root: Io.Dir, case: suite.Case, check: Check) !?[]const u8 {
    return switch (check) {
        .events => checkEvents(arena, io, root, case),
        .@"error" => checkError(arena, io, root, case),
        .json => json.compare(
            arena,
            try readCaseFile(arena, io, root, case, "in.yaml"),
            try readCaseFile(arena, io, root, case, "in.json"),
        ),
        .roundtrip => roundtrip.compare(arena, try readCaseFile(arena, io, root, case, "in.yaml")),
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
    const parsed = try parse(input, &got.writer);
    if (parsed.problem()) |problem| return problem;
    if (parsed.rejection) |r| return try r.describe(arena);
    return firstDifference(arena, want, got.written());
}

fn checkError(arena: Allocator, io: Io, root: Io.Dir, case: suite.Case) !?[]const u8 {
    const input = try readCaseFile(arena, io, root, case, "in.yaml");
    var discard: Io.Writer.Discarding = .init(&.{});
    const parsed = try parse(input, &discard.writer);
    if (parsed.problem()) |problem| return problem;
    if (parsed.rejection == null) return "parsed to the end, where the suite has a syntax error";
    return null;
}

/// Where and why parsing stopped short.
pub const Rejection = struct {
    /// The scanner found the error, or the parser did.
    stage: enum { scanner, parser },
    mark: yaml.Scanner.Mark,
    message: []const u8,

    pub fn describe(r: Rejection, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s} error at {d}:{d}: {s}", .{ @tagName(r.stage), r.mark.line + 1, r.mark.column + 1, r.message });
    }
};

/// How parsing an input went.
pub const Parsed = struct {
    /// Null when it parsed to the end of the stream.
    rejection: ?Rejection = null,
    leaked: bool = false,
    /// It gave far more events than its length allows: a parser that has
    /// stopped moving.
    runaway: bool = false,

    /// What went wrong besides a syntax error, if anything.
    pub fn problem(p: Parsed) ?[]const u8 {
        if (p.runaway) return "gave more events than the input can hold: the parser is not moving";
        if (p.leaked) return "leaked memory (the allocator printed where it was allocated)";
        return null;
    }
};

/// Parses `input`, writing its events in the suite's notation, on an
/// allocator of its own that checks for leaks.
pub fn parse(input: []const u8, w: *Io.Writer) !Parsed {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    var parsed: Parsed = .{};
    {
        var parser: yaml.Parser = .init(debug.allocator(), input);
        defer parser.deinit();
        parsed.rejection = try parseInto(&parser, input.len, w, &parsed.runaway);
    }
    parsed.leaked = debug.deinit() == .leak;
    return parsed;
}

fn parseInto(parser: *yaml.Parser, len: usize, w: *Io.Writer, runaway: *bool) !?Rejection {
    // Each event takes at least a byte, but for a few around each node.
    const most = 8 * len + 64;
    var count: usize = 0;
    while (count < most) : (count += 1) {
        const event = parser.next() catch |err| switch (err) {
            error.SyntaxError => return rejection(parser),
            else => return err,
        };
        try yaml.Parser.writeTestEvent(w, event);
        if (event.data == .stream_end) return null;
    }
    runaway.* = true;
    return null;
}

fn rejection(parser: *const yaml.Parser) Rejection {
    // The scanner cannot go on after an error, so one it found is the one.
    const by_scanner = parser.scanner.diagnostic.message.len > 0;
    return .{
        .stage = if (by_scanner) .scanner else .parser,
        .mark = parser.diagnostic.mark,
        .message = parser.diagnostic.message,
    };
}

/// For `zig build suite -- errors`: each invalid case, where this library
/// rejects it, and whether the events before that are the suite's.
pub fn writeRejections(arena: Allocator, io: Io, root: Io.Dir, cases: []const suite.Case, w: *Io.Writer) !void {
    var same: usize = 0;
    var count: usize = 0;
    for (cases) |case| {
        if (!case.has.contains(.@"error")) continue;
        count += 1;
        const input = try readCaseFile(arena, io, root, case, "in.yaml");
        var got: Io.Writer.Allocating = .init(arena);
        const parsed = try parse(input, &got.writer);
        const want = if (case.has.contains(.event)) try readCaseFile(arena, io, root, case, "test.event") else "";
        const prefix_same = std.mem.eql(u8, want, got.written());
        if (prefix_same) same += 1;
        const what = if (parsed.rejection) |r| try r.describe(arena) else "NOT REJECTED";
        try w.print("{s:<7} {s:<14} {s}\n", .{ case.name, if (prefix_same) "events same" else "events differ", what });
    }
    try w.print("{d} invalid cases; the events before the error are the suite's in {d}\n", .{ count, same });
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
    /// Cases each check applies to.
    applied: std.EnumArray(Check, usize) = .initFill(0),
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
    tally.applied.getPtr(finding.check).* += 1;
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

test "parse: a rejection's stage and place, and a clean parse" {
    var discard: Io.Writer.Discarding = .init(&.{});
    const by_scanner = (try parse("\"open", &discard.writer)).rejection.?;
    try testing.expectEqual(.scanner, by_scanner.stage);
    try testing.expectEqual(0, by_scanner.mark.column);
    const by_parser = (try parse("[a] b", &discard.writer)).rejection.?;
    try testing.expectEqual(.parser, by_parser.stage);
    try testing.expectEqual(4, by_parser.mark.column);
    const clean = try parse("a: b", &discard.writer);
    try testing.expectEqual(null, clean.rejection);
    try testing.expect(!clean.leaked and !clean.runaway);
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
