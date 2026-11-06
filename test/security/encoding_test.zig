//! Bytes that are not the text they claim to be.

const std = @import("std");
const yaml = @import("yaml");
const testing = std.testing;
const gpa = testing.allocator;

fn expectError(err: anyerror, text: []const u8) !void {
    errdefer std.debug.print("input: {any}\n", .{text});
    try testing.expectError(err, yaml.parseFromSlice(yaml.Value, gpa, text, .{}));
}

test "security: CWE-176 invalid UTF-8 is refused, not repaired" {
    try expectError(error.InvalidEncoding, "a: \xC0\xAF\n"); // an overlong `/`
    try expectError(error.InvalidEncoding, "a: \xED\xA0\x80\n"); // a surrogate
    try expectError(error.InvalidEncoding, "a: \xF4\x90\x80\x80\n"); // past U+10FFFF
    try expectError(error.InvalidEncoding, "a: \xE2\x82\n"); // cut short
    try expectError(error.InvalidEncoding, "a: \xFF\n");
}

test "security: CWE-176 UTF-16 and UTF-32 that are not text are refused" {
    try expectError(error.InvalidEncoding, "\xFF\xFEa\x00:\x00 \x00\x00\xD8"); // an unpaired surrogate
    try expectError(error.InvalidEncoding, "\xFF\xFEa\x00:"); // half a code unit
    try expectError(error.InvalidEncoding, "\xFF\xFE\x00\x00a\x00\x00\x00\x00\x00\x11\x00"); // past U+10FFFF
    try expectError(error.InvalidEncoding, "\xFF\xFE\x00\x00a\x00\x00\x00\x00\xD8\x00\x00"); // a surrogate
}

test "security: CWE-20 control characters and a byte order mark inside a document are refused" {
    try expectError(error.SyntaxError, "a: b\x01c\n");
    try expectError(error.SyntaxError, "a: b\x7Fc\n");
    try expectError(error.SyntaxError, "a: b\xC2\x80c\n"); // a C1 control
    try expectError(error.SyntaxError, "a: \"b\x1Bc\"\n"); // raw, not escaped
    try expectError(error.SyntaxError, "a: b\x00c\n");
    try expectError(error.SyntaxError, "a: b\xEF\xBB\xBFc\n");
    // Escaped in a double-quoted scalar, a control character is data.
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, "a: \"b\\x1Bc\"\n", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("b\x1Bc", parsed.value.get("a").?.string);
}
