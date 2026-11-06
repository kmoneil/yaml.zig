//! What the library writes: YAML from a program's values, and the text
//! of its diagnostics.

const std = @import("std");
const yaml = @import("yaml");
const testing = std.testing;
const gpa = testing.allocator;

test "security: CWE-74 text stringify writes reads back as the same text, not structure" {
    const Record = struct { note: []const u8, admin: bool = false };
    const hostile = [_][]const u8{
        "x\nadmin: true", "x\n  admin: true", "- x",       "key: value", "# comment", "x # y",
        "---",            "...",              "--- !!str", "*a",         "&a x",      "!!bool true",
        "!x y",           "{admin: true}",    "[a]",       "'q'",        "\"d\"",     " lead",
        "trail ",         "a\tb",             "%TAG ! x",  "@x",         "`x",        "|",
        ">-",             "? k",              ": v",       "",           "~",         "null",
        "true",           "0x1F",             ".inf",      "1e3",        "a\r\nb",    "a\u{2028}b",
        "a\x00b",         "a\x1B[2Jb",        "\u{FEFF}x",
    };
    for (hostile) |note| {
        for ([_]@FieldType(yaml.StringifyOptions, "style"){ .block, .flow }) |style| {
            errdefer std.debug.print("note: {any} ({t})\n", .{ note, style });
            const text = try yaml.stringifyAlloc(gpa, Record{ .note = note }, .{ .style = style });
            defer gpa.free(text);
            const again = try yaml.parseFromSlice(Record, gpa, text, .{});
            defer again.deinit();
            try testing.expectEqualStrings(note, again.value.note);
            try testing.expect(!again.value.admin);
        }
    }
}

/// The line `{f}` prints for the diagnostic of reading `text` as a `T`,
/// which must fail.
fn diagnosticLine(comptime T: type, text: []const u8, buf: []u8) ![]const u8 {
    var diagnostic: yaml.Diagnostic = .{};
    if (yaml.parseFromSlice(T, gpa, text, .{ .diagnostic = &diagnostic })) |parsed| {
        parsed.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{f}", .{diagnostic});
    return w.buffered();
}

/// Whether `line` holds nothing a terminal or a log acts on: no control
/// character, and no NEL, U+2028 or U+2029.
fn inert(line: []const u8) bool {
    for (line) |c| if (c < 0x20 or c == 0x7F) return false;
    return std.mem.find(u8, line, "\u{85}") == null and std.mem.find(u8, line, "\u{2028}") == null and std.mem.find(u8, line, "\u{2029}") == null;
}

test "security: CWE-117 input in a diagnostic cannot write to a terminal or forge a log line" {
    var buf: [1024]u8 = undefined;
    // A key no field has, holding a clear-screen and a forged log line.
    const key = try diagnosticLine(struct { a: u8 }, "\"\\e[2J\\nERROR all is well\": 1\n", &buf);
    try testing.expect(inert(key));
    try testing.expectEqualStrings("1:1: unknown field \"\\x1B[2J\\nERROR all is well\"; expected one of: a", key);
    const cases = .{
        // An enum's name.
        .{ enum { a }, "\"\\e]0;title\\a\"" },
        // A string found where a number was expected.
        .{ struct { n: u8 }, "n: \"\\L1\\N2\\P3\\r4\"" },
        // A key on the path.
        .{ struct { m: yaml.ArrayHashMap(u8) }, "m: {\"a\\nb\": x}" },
        // A tag, its % escapes decoded.
        .{ u8, "!x%1B%5B2J 1" },
    };
    inline for (cases) |case| {
        const line = try diagnosticLine(case[0], case[1], &buf);
        errdefer std.debug.print("line: {s}\n", .{line});
        try testing.expect(inert(line));
    }
    // Text in any script is shown as it is.
    const named = try diagnosticLine(struct { a: u8 }, "größe: 1\n", &buf);
    try testing.expectEqualStrings("1:1: unknown field \"größe\"; expected one of: a", named);
}
