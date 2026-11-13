//! yaml.zig's events held to libfyaml's, another reader that passes the
//! whole yaml-test-suite (karte t68): the suite shows the two agree on
//! what it covers, this target asks on what a fuzzer makes. Built only
//! with `-Ddifferential`, which fetches libfyaml: `zig build
//! differential -Ddifferential` replays the target's seeded draws and
//! checks every suite input, `--fuzz` fuzzes.
//!
//! libfyaml's events are written by its own fy-tool's printer
//! (dump_testsuite_event, into memory: tools/differential/shim.c), so
//! both sides are in the suite's notation, ours by
//! `Parser.writeTestEvent`. They agree when both read the stream and give
//! the same events, or both refuse it, the events each gave before its
//! error the same as far as the shorter goes. An input our detection
//! takes for UTF-16 or UTF-32 is skipped (decoding is not the grammar),
//! and so is one that is not UTF-8, which libfyaml's printer aborts on,
//! or holds a character YAML does not allow (`compared`).

const std = @import("std");
const yaml = @import("root.zig");
const fuzzing = @import("testing/fuzzing.zig");
const inputs = @import("testing/inputs.zig");

const Draw = fuzzing.Draw;
const testing = std.testing;

extern fn fy_shim_events(data: [*]const u8, len: usize, out: *?[*]u8, out_len: *usize) c_int;
extern fn fy_shim_diagnostic() [*:0]const u8;

/// What a reader made of an input: its events in the suite's notation,
/// and whether it refused the stream.
const Outcome = struct {
    events: []const u8,
    refused: bool,
    /// Why it refused: yaml.zig's message, or libfyaml's first
    /// diagnostic.
    message: []const u8 = "",
    at: usize = 0,
};

/// libfyaml's reading, its events copied into `arena`.
fn theirs(arena: std.mem.Allocator, input: []const u8) !Outcome {
    var out: ?[*]u8 = null;
    var len: usize = 0;
    const rc = fy_shim_events(input.ptr, input.len, &out, &len);
    defer std.c.free(out);
    if (rc < 0) return error.LibfyamlFailed;
    const events = try arena.dupe(u8, if (out) |o| o[0..len] else "");
    return .{ .events = events, .refused = rc == 1, .message = if (rc == 1) try arena.dupe(u8, diagnosticReason(std.mem.span(fy_shim_diagnostic()))) else "" };
}

/// libfyaml's diagnostic's words: past `<input>:line:column: error: `, to
/// the line's end.
fn diagnosticReason(text: []const u8) []const u8 {
    const line = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    const at = std.mem.find(u8, line, ": error: ") orelse return line;
    return line[at + ": error: ".len ..];
}

/// yaml.zig's, as `yaml events` reads a file: decoded, then parsed.
fn ours(arena: std.mem.Allocator, input: []const u8) !Outcome {
    const text = yaml.encoding.toUtf8(arena, input, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .events = "", .refused = true },
    };
    var parser: yaml.Parser = .init(arena, text);
    defer parser.deinit();
    var out: std.Io.Writer.Allocating = .init(arena);
    // Each event takes at least a byte, but for a few around each node.
    for (0..8 * text.len + 64) |_| {
        const event = parser.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .events = out.written(), .refused = true, .message = parser.diagnostic.message, .at = parser.diagnostic.mark.offset },
        };
        try yaml.Parser.writeTestEvent(&out.writer, event);
        if (event.data == .stream_end) break;
    }
    return .{ .events = out.written(), .refused = false };
}

/// A disagreement read against the spec and found libfyaml's (t68):
/// yaml.zig refuses where libfyaml reads, as the spec says, known by
/// yaml.zig's message and the byte its mark is at, and why.
const Lenient = struct { message: []const u8, at: u8, why: []const u8 };

const libfyaml_lenient = [_]Lenient{
    .{
        .message = "an anchor, alias or tag must be followed by whitespace",
        .at = '!',
        .why = "a shorthand tag's suffix holds no `!` (ns-tag-char, 6.8.2.2): libfyaml reads `!*a!b` as a local tag",
    },
};

/// The known disagreement `a` (yaml.zig's) and `b` (libfyaml's) are, if
/// they are one.
fn known(input: []const u8, a: Outcome, b: Outcome) ?Lenient {
    if (!a.refused or b.refused or a.at >= input.len) return null;
    for (libfyaml_lenient) |k| {
        if (std.mem.eql(u8, a.message, k.message) and input[a.at] == k.at) return k;
    }
    return null;
}

/// Whether the two readings agree (the file's comment says how).
fn agree(a: Outcome, b: Outcome) bool {
    if (a.refused != b.refused) return false;
    if (!a.refused) return std.mem.eql(u8, a.events, b.events);
    const shorter = if (a.events.len <= b.events.len) a.events else b.events;
    const longer = if (a.events.len <= b.events.len) b.events else a.events;
    return std.mem.startsWith(u8, longer, shorter);
}

/// Whether the target reads `input`: UTF-8, not taken for another
/// encoding, and every character one YAML allows (c-printable, 5.1), a
/// byte order mark only first. libfyaml reads some it does not allow (a
/// NUL ends a tag, and what follows it on the line goes), which yaml.zig
/// refuses as the spec says; its own tests hold it to that (t68).
fn compared(input: []const u8) bool {
    if (yaml.encoding.detect(input) != .utf8) return false;
    const view = std.unicode.Utf8View.init(input) catch return false;
    var it = view.iterator();
    var first = true;
    while (it.nextCodepoint()) |c| : (first = false) {
        const allowed = switch (c) {
            '\t', '\n', '\r', 0x20...0x7E, 0x85, 0xA0...0xD7FF, 0xE000...0xFEFE, 0xFF00...0xFFFD, 0x10000...0x10FFFF => true,
            0xFEFF => first,
            else => false,
        };
        if (!allowed) return false;
    }
    return true;
}

fn expectAgree(arena: std.mem.Allocator, input: []const u8) !void {
    const a = try ours(arena, input);
    const b = try theirs(arena, input);
    if (agree(a, b) or known(input, a, b) != null) return;
    std.debug.print("input: \"{f}\"\nyaml.zig ({s}):\n{s}libfyaml ({s}):\n{s}", .{
        std.zig.fmtString(input),             if (a.refused) "refused" else "read", a.events,
        if (b.refused) "refused" else "read", b.events,
    });
    return error.TestReadersDisagree;
}

test "fuzz: differential: yaml.zig's events are libfyaml's" {
    try fuzzing.run({}, fuzzDifferential, 400);
}

fn fuzzDifferential(_: void, d: *Draw) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try inputs.draw(d, arena);
    if (!compared(input)) return;
    try expectAgree(arena, input);
}

/// `differential-suite triage N`: the target's first N seeded draws, each
/// kind of disagreement not yet known (yaml.zig's message, or that it
/// read, and libfyaml's word) printed once with its first input, and
/// how many each had: what is left to sort against the spec.
fn triage(gpa: std.mem.Allocator, n: usize) !void {
    var kinds: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer kinds.deinit(gpa);
    var keys: std.heap.ArenaAllocator = .init(gpa);
    defer keys.deinit();
    var compared_count: usize = 0;
    for (0..n) |seed| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var d: Draw = .{ .prng = .init(seed) };
        const input = try inputs.draw(&d, arena);
        if (!compared(input)) continue;
        compared_count += 1;
        const a = try ours(arena, input);
        const b = try theirs(arena, input);
        if (agree(a, b) or known(input, a, b) != null) continue;
        const key = try std.fmt.allocPrint(keys.allocator(), "yaml.zig {s}{s}; libfyaml {s}{s}", .{ if (a.refused) "refused: " else "read", a.message, if (b.refused) "refused: " else "read", b.message });
        const entry = try kinds.getOrPut(gpa, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
            std.debug.print("== {s}\nseed {d}, input: \"{f}\"\nyaml.zig:\n{s}libfyaml:\n{s}\n", .{ key, seed, std.zig.fmtString(input), a.events, b.events });
        }
        entry.value_ptr.* += 1;
    }
    std.debug.print("{d} draws, {d} compared; disagreements by kind:\n", .{ n, compared_count });
    for (kinds.keys(), kinds.values()) |k, v| std.debug.print("{d:>6}  {s}\n", .{ v, k });
}

/// `differential-suite SUITE_DIR`, which `zig build differential`
/// runs: every yaml-test-suite input, libfyaml's events through the shim
/// the suite's (as fy-tool's are), and ours libfyaml's.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (std.mem.eql(u8, args[1], "triage")) return triage(init.gpa, try std.fmt.parseInt(usize, args[2], 10));
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(init.gpa);
    defer walker.deinit();
    var count: usize = 0;
    var problems: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "in.yaml")) continue;
        count += 1;
        const case = std.fs.path.dirname(entry.path) orelse ".";
        const input = try dir.readFileAlloc(io, entry.path, arena, .limited(1 << 20));
        const b = try theirs(arena, input);
        const invalid = if (dir.statFile(io, try std.fs.path.join(arena, &.{ case, "error" }), .{})) |_| true else |_| false;
        const as_suite = if (invalid) b.refused else !b.refused and std.mem.eql(u8, b.events, try dir.readFileAlloc(io, try std.fs.path.join(arena, &.{ case, "test.event" }), arena, .limited(1 << 20)));
        if (!as_suite) {
            problems += 1;
            std.debug.print("{s}: libfyaml through the shim is not the suite\n", .{case});
        }
        expectAgree(arena, input) catch |err| {
            if (err != error.TestReadersDisagree) return err;
            problems += 1;
            std.debug.print("{s}: yaml.zig and libfyaml disagree\n", .{case});
        };
    }
    std.debug.print("differential: {d} suite inputs, {d} problems\n", .{ count, problems });
    if (problems > 0 or count != 402) std.process.exit(1);
}
