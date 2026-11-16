//! The spec suite (karte t88): cases written for YAML 1.2.2 itself, each
//! naming the productions it exercises and quoting the text that decides
//! its reading, held to that text and run against this library.
//!
//!     spec <cases-dir> <spec.md> [check | coverage]
//!
//! A case file (test/spec/<chapter>/<section>-<topic>.yaml) is a list of
//! cases in the yaml-test-suite's own source format (`name`, `yaml`,
//! `tree`, `fail`), with its markers for what cannot be seen: `—»` (or
//! `»`, with any dashes) a tab, `␣` a trailing space, `←` a carriage
//! return, `⇔` a byte order mark, `↵` a line break shown, and `∎` at the
//! end for no final line break. Ours is `spec`: `productions`, the
//! numbers of those the case exercises, and `quotes`, the text that
//! decides it, word for word as the published spec has it, each
//! `[N] ...` from production N or `S.S.S: ...` from that section's prose.
//! `note` says what else is worth knowing, such as what other readers do.
//!
//! `check` holds every case's citation to spec.md (yaml/yaml-spec's
//! source of 1.2.2: its productions numbered in order and its sections as
//! the published spec numbers them), then the case to this library: one
//! marked `fail` must be refused, any other read to `tree`'s events, and
//! the reader must agree with the parser. It exits 1 if any does not.
//! `coverage` lists the productions no case exercises, those with a
//! lookahead, a "followed by" note or a condition first: the spec's
//! boundaries, each to be crossed from both sides.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const check = @import("check.zig");

const Command = enum { check, coverage };

const Case = struct {
    name: []const u8,
    spec: Citation,
    yaml: []const u8,
    tree: ?[]const u8 = null,
    fail: bool = false,
    note: ?[]const u8 = null,
};

const Citation = struct {
    productions: []const u16,
    quotes: []const []const u8,
};

/// A file's cases, and where it is.
const File = struct {
    path: []const u8,
    cases: []const Case,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = it.skip();
    const cases_dir = it.next() orelse return usage();
    const spec_path = it.next() orelse return usage();
    const command = std.meta.stringToEnum(Command, it.next() orelse "check") orelse return usage();

    const spec = try Spec.read(arena, try Io.Dir.cwd().readFileAlloc(io, spec_path, arena, .limited(1 << 22)));
    const files = try readCases(arena, io, cases_dir);

    var buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    switch (command) {
        .check => {
            var count: usize = 0;
            var failed: usize = 0;
            for (files) |file| for (file.cases, 0..) |case, i| {
                count += 1;
                const cited = try spec.cite(arena, case);
                const problem = if (cited) |why| why else try run(arena, case);
                if (problem) |why| {
                    failed += 1;
                    try out.print("{s}: case {d}, {s}: {s}\n", .{ file.path, i + 1, case.name, why });
                }
            };
            try out.print("spec: {d} cases in {d} files, {d} not as the spec says\n", .{ count, files.len, failed });
            if (failed > 0) {
                try out.flush();
                std.process.exit(1);
            }
        },
        .coverage => try writeCoverage(arena, out, spec, files),
    }
}

fn usage() noreturn {
    std.debug.print("usage: spec <cases-dir> <spec.md> [check | coverage]\n", .{});
    std.process.exit(2);
}

/// Every `.yaml` file under `path`, in order of its path, its cases read.
fn readCases(arena: Allocator, io: Io, path: []const u8) ![]const File {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".yaml")) try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    const files = try arena.alloc(File, paths.items.len);
    for (paths.items, files) |p, *file| {
        const text = try dir.readFileAlloc(io, p, arena, .limited(1 << 20));
        if (cutShort(text)) |line| {
            std.debug.print("spec: {s}/{s}:{d}: a plain `name` or `note` holding ` #` loses the rest as a comment: quote it\n", .{ path, p, line });
            return error.CaseCutShort;
        }
        var diagnostic: yaml.Diagnostic = .{};
        const cases = yaml.parseFromSliceLeaky([]const Case, arena, text, .{ .diagnostic = &diagnostic }) catch |err| {
            std.debug.print("spec: {s}/{s}: {f}\n", .{ path, p, &diagnostic });
            return err;
        };
        file.* = .{ .path = try std.fs.path.join(arena, &.{ path, p }), .cases = cases };
    }
    return files;
}

/// The number of the first line whose `name` or `note`, a plain scalar,
/// holds ` #`: the rest of it is a comment, and the value cut short
/// with no error. Null with none.
fn cutShort(text: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const field = std.mem.trimStart(u8, std.mem.trimStart(u8, line, " "), "- ");
        const value = if (std.mem.startsWith(u8, field, "name: ")) field["name: ".len..] else if (std.mem.startsWith(u8, field, "note: ")) field["note: ".len..] else continue;
        if (value.len == 0 or std.mem.findScalar(u8, "\"'>|", value[0]) != null) continue;
        if (std.mem.find(u8, value, " #") != null) return number;
    }
    return null;
}

test "a plain name or note holding ' #' is found" {
    try std.testing.expectEqual(2, cutShort("- name: a\n  note: b ` # c` d\n"));
    try std.testing.expectEqual(null, cutShort("- name: a\n  note: \"b ` # c` d\"\n  yaml: |\n    a # c\n"));
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A case run against this library: why it does not read as it says, or
/// null.
fn run(arena: Allocator, case: Case) !?[]const u8 {
    const input = try decodeMarkers(arena, case.yaml);
    var got: Io.Writer.Allocating = .init(arena);
    const parsed = try check.parse(input, &got.writer);
    if (parsed.problem()) |problem| return problem;
    if (case.fail) {
        if (parsed.rejection == null) return "read to the end, where the spec says it is no YAML";
    } else {
        if (parsed.rejection) |r| return try r.describe(arena);
        const tree = case.tree orelse return "a case that reads needs its `tree`";
        // A tree may show a trailing space as `␣`, as a case's input does.
        if (try check.firstDifference(arena, try treeEvents(arena, try decodeMarkers(arena, tree)), got.written())) |difference| return difference;
    }
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const compared = try yaml.Reader.compare(safe.allocator(), arena, input);
    if (safe.deinit() > 0) return "the reader leaked memory (the allocator printed where it was allocated)";
    return compared.problem;
}

/// A case's `yaml` with the source format's markers made the characters
/// they stand for.
fn decodeMarkers(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "␣")) {
            try out.append(arena, ' ');
            i += "␣".len;
        } else if (std.mem.startsWith(u8, rest, "—") or std.mem.startsWith(u8, rest, "»")) {
            var j = i;
            while (std.mem.startsWith(u8, text[j..], "—")) j += "—".len;
            if (!std.mem.startsWith(u8, text[j..], "»")) {
                try out.appendSlice(arena, text[i..j]);
                i = j;
                continue;
            }
            try out.append(arena, '\t');
            i = j + "»".len;
        } else if (std.mem.startsWith(u8, rest, "↵")) {
            i += "↵".len;
        } else if (std.mem.startsWith(u8, rest, "←")) {
            try out.append(arena, '\r');
            i += "←".len;
        } else if (std.mem.startsWith(u8, rest, "⇔")) {
            try out.appendSlice(arena, "\xEF\xBB\xBF");
            i += "⇔".len;
        } else if (std.mem.startsWith(u8, rest, "∎")) {
            // No final line break: the marker, and the break after it.
            i += "∎".len;
            if (i < text.len and text[i] == '\n') i += 1;
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.items;
}

/// `tree`'s events, one a line as the parser writes them: the source
/// format indents them by depth.
fn treeEvents(arena: Allocator, tree: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        const event = std.mem.trimStart(u8, line, " ");
        if (event.len == 0) continue;
        try out.appendSlice(arena, event);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// YAML 1.2.2 as spec.md writes it: its productions in order, and the
/// prose of each numbered section, both normalized (`normalize`).
const Spec = struct {
    productions: []const Production,
    sections: std.StringArrayHashMapUnmanaged([]const u8),

    const Production = struct {
        name: []const u8,
        section: []const u8,
        text: []const u8,
    };

    /// Reads spec.md. Its headings number themselves as `#.`, a chapter's
    /// `# Chapter #.`; a fenced block beginning `[#]` is a production.
    fn read(arena: Allocator, md: []const u8) !Spec {
        var productions: std.ArrayList(Production) = .empty;
        var sections: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var numbers: [4]u16 = @splat(0);
        var section: []const u8 = "";
        var prose: std.ArrayList(u8) = .empty;
        var block: std.ArrayList(u8) = .empty;
        var in_fence = false;
        var lines = std.mem.splitScalar(u8, md, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "```")) {
                // A block of productions may hold several, each from its
                // `[#]` to the next; a production defined by cases, as
                // `s-indent(0)` and `s-indent(n+1)`, has `[#]` alone on
                // the line before them.
                const rules_text = try std.mem.replaceOwned(u8, arena, block.items, "[#]\n", "[#] ");
                if (in_fence and std.mem.startsWith(u8, rules_text, "[#] ")) {
                    var rules = std.mem.splitSequence(u8, rules_text["[#] ".len..], "\n[#] ");
                    while (rules.next()) |body| {
                        const name_end = std.mem.findAny(u8, body, "( ") orelse body.len;
                        try productions.append(arena, .{ .name = try arena.dupe(u8, body[0..name_end]), .section = section, .text = try normalize(arena, body) });
                    }
                }
                in_fence = !in_fence;
                block.clearRetainingCapacity();
                continue;
            }
            if (in_fence) {
                try block.appendSlice(arena, line);
                try block.append(arena, '\n');
                continue;
            }
            if (headingDepth(line)) |depth| {
                if (section.len > 0) try sections.put(arena, section, try normalize(arena, prose.items));
                prose.clearRetainingCapacity();
                section = "";
                if (depth == 0) continue;
                numbers[depth - 1] += 1;
                for (numbers[depth..]) |*n| n.* = 0;
                var name: std.ArrayList(u8) = .empty;
                for (numbers[0..depth], 0..) |n, k| try name.print(arena, "{s}{d}", .{ if (k > 0) "." else "", n });
                section = name.items;
                continue;
            }
            try prose.appendSlice(arena, line);
            try prose.append(arena, '\n');
        }
        if (section.len > 0) try sections.put(arena, section, try normalize(arena, prose.items));
        return .{ .productions = productions.items, .sections = sections };
    }

    /// A numbered heading's depth (a chapter 1), 0 for a heading with no
    /// number, null for no heading.
    fn headingDepth(line: []const u8) ?usize {
        if (std.mem.startsWith(u8, line, "# Chapter #. ")) return 1;
        const prefixes = [_][]const u8{ "## #. ", "### #. ", "#### #. " };
        for (prefixes, 2..) |prefix, depth| {
            if (std.mem.startsWith(u8, line, prefix)) return depth;
        }
        if (std.mem.startsWith(u8, line, "# ") or std.mem.startsWith(u8, line, "## ") or std.mem.startsWith(u8, line, "### ")) return 0;
        return null;
    }

    /// Why `case`'s citation does not hold, or null: it names
    /// productions there are, and each quote is in the text it names.
    fn cite(spec: Spec, arena: Allocator, case: Case) !?[]const u8 {
        if (case.spec.productions.len == 0) return "its `spec` names no production";
        if (case.spec.quotes.len == 0) return "its `spec` quotes nothing";
        for (case.spec.productions) |n| {
            if (n == 0 or n > spec.productions.len) return try arena.print("there is no production [{d}]", .{n});
        }
        for (case.spec.quotes) |quote| {
            if (try spec.quoteProblem(arena, case, quote)) |why| return why;
        }
        return null;
    }

    fn quoteProblem(spec: Spec, arena: Allocator, case: Case, quote: []const u8) !?[]const u8 {
        if (std.mem.startsWith(u8, quote, "[")) {
            const close = std.mem.findScalar(u8, quote, ']') orelse return try arena.print("a quote's `[N]` is not closed: {s}", .{quote});
            const n = std.fmt.parseInt(u16, quote[1..close], 10) catch return try arena.print("a quote's `[N]` is no number: {s}", .{quote});
            if (std.mem.findScalar(u16, case.spec.productions, n) == null) return try arena.print("it quotes [{d}] but does not name it in `productions`", .{n});
            if (n == 0 or n > spec.productions.len) return try arena.print("there is no production [{d}]", .{n});
            const p = spec.productions[n - 1];
            if (std.mem.find(u8, p.text, try normalize(arena, quote[close + 1 ..])) == null) return try arena.print("production [{d}] {s} has no `{s}`", .{ n, p.name, std.mem.trim(u8, quote[close + 1 ..], " ") });
            return null;
        }
        const colon = std.mem.find(u8, quote, ": ") orelse return try arena.print("a quote begins `[N]` or a section's number and `: `: {s}", .{quote});
        const prose = spec.sections.get(quote[0..colon]) orelse return try arena.print("there is no section {s}", .{quote[0..colon]});
        if (std.mem.find(u8, prose, try normalize(arena, quote[colon + 2 ..])) == null) return try arena.print("section {s} has no `{s}`", .{ quote[0..colon], quote[colon + 2 ..] });
        return null;
    }
};

/// Text as spec.md writes it and as the published spec shows it, made
/// alike: Markdown's links (`[text]`, `[text][ref]`, `[text](url)`) their
/// text, backticks and emphasis (`*`, `_`) gone, curly quotes straight,
/// and each run of white space one space. No production's name holds a
/// `_`.
fn normalize(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var space = true;
    while (i < text.len) {
        const c = text[i];
        const rest = text[i..];
        if (c == ']') {
            i += 1;
            // A link's reference or target goes with its brackets.
            if (i < text.len and (text[i] == '[' or text[i] == '(')) {
                const close: u8 = if (text[i] == '[') ']' else ')';
                if (std.mem.findScalarPos(u8, text, i, close)) |end| i = end + 1;
            }
            continue;
        }
        if (c == '[' or c == '`' or c == '*' or c == '_') {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (!space) try out.append(arena, ' ');
            space = true;
            i += 1;
            continue;
        }
        space = false;
        if (std.mem.startsWith(u8, rest, "“") or std.mem.startsWith(u8, rest, "”")) {
            try out.append(arena, '"');
            i += "“".len;
        } else if (std.mem.startsWith(u8, rest, "‘") or std.mem.startsWith(u8, rest, "’")) {
            try out.append(arena, '\'');
            i += "‘".len;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

/// Prints each production no case exercises, the spec's boundaries (a
/// lookahead, a "followed by" note, a condition) first, then how many are.
fn writeCoverage(arena: Allocator, out: *Io.Writer, spec: Spec, files: []const File) !void {
    const count = try arena.alloc(usize, spec.productions.len);
    @memset(count, 0);
    for (files) |file| for (file.cases) |case| for (case.spec.productions) |n| {
        if (n >= 1 and n <= count.len) count[n - 1] += 1;
    };
    try out.print("Boundaries (a lookahead, a \"followed by\" note, a condition), each to cross from both sides:\n", .{});
    for (spec.productions, count, 1..) |p, c, n| {
        if (!isBoundary(p.text)) continue;
        try out.print("  [{d}] {s} ({s}): {d} cases\n", .{ n, p.name, p.section, c });
    }
    var covered: usize = 0;
    try out.print("Productions no case exercises:\n", .{});
    for (spec.productions, count, 1..) |p, c, n| {
        if (c > 0) {
            covered += 1;
            continue;
        }
        try out.print("  [{d}] {s} ({s})\n", .{ n, p.name, p.section });
    }
    try out.print("spec: {d} of {d} productions exercised\n", .{ covered, spec.productions.len });
}

/// Whether a production's text (normalized, so its `/* */` have lost
/// their `*`) holds a lookahead, a "followed by" note, or a condition: a
/// limit (`At most`), an exclusion, or a case (`When n≥1`).
fn isBoundary(text: []const u8) bool {
    const marks = [_][]const u8{ "lookahead", "followed by", "At most", "Excluding", "When " };
    for (marks) |mark| {
        if (std.mem.find(u8, text, mark) != null) return true;
    }
    return false;
}

test "markers are the characters they stand for" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("a:\tb \r\n\xEF\xBB\xBFc", try decodeMarkers(a.allocator(), "a:———»b␣←↵\n⇔c∎\n"));
    try std.testing.expectEqualStrings("\tx\n", try decodeMarkers(a.allocator(), "»x\n"));
    try std.testing.expectEqualStrings("a—b\n", try decodeMarkers(a.allocator(), "a—b\n"));
}

test "a citation holds only when its quotes are in the text it names" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const md =
        \\# Chapter #. One
        \\## #. Two
        \\A plain [scalar] may begin with "`:`" if a "safe" one follows.
        \\
        \\```
        \\[#] a(n) ::=
        \\  b              # ':' (not followed by non-ws char)
        \\
        \\[#]
        \\c(0) ::=
        \\  <empty>
        \\```
        \\
    ;
    const spec = try Spec.read(arena, md);
    try std.testing.expectEqual(2, spec.productions.len);
    try std.testing.expectEqualStrings("c", spec.productions[1].name);
    try std.testing.expectEqualStrings("1.1", spec.productions[0].section);
    const good: Case = .{ .name = "", .yaml = "", .spec = .{ .productions = &.{ 1, 2 }, .quotes = &.{ "[1] b # ':' (not followed by non-ws char)", "1.1: may begin with “:” if a “safe” one follows." } } };
    try std.testing.expectEqual(null, try spec.cite(arena, good));
    const misquoted: Case = .{ .name = "", .yaml = "", .spec = .{ .productions = &.{1}, .quotes = &.{"[1] b # ':' (not followed by a char)"} } };
    try std.testing.expect(try spec.cite(arena, misquoted) != null);
    const unnamed: Case = .{ .name = "", .yaml = "", .spec = .{ .productions = &.{2}, .quotes = &.{"[1] b"} } };
    try std.testing.expect(try spec.cite(arena, unnamed) != null);
    const beyond: Case = .{ .name = "", .yaml = "", .spec = .{ .productions = &.{3}, .quotes = &.{"1.1: A plain"} } };
    try std.testing.expect(try spec.cite(arena, beyond) != null);
    const elsewhere: Case = .{ .name = "", .yaml = "", .spec = .{ .productions = &.{1}, .quotes = &.{"1.2: A plain"} } };
    try std.testing.expect(try spec.cite(arena, elsewhere) != null);
}

test "spec.md's text and the published spec's are made alike" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const md = try normalize(a.allocator(), "character if followed by a non-[space] \"safe\" character,\n  as [keys][key] and [x](#y) and `?`");
    const html = try normalize(a.allocator(), "character if followed by a non-space “safe” character, as keys and x and ?");
    try std.testing.expectEqualStrings(html, md);
}
