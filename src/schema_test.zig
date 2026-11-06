//! The schemas' tests, over YAML 1.2.2's examples of tag resolution
//! (10.8 for JSON, 10.9 for core) and the edges of each pattern.

const std = @import("std");
const testing = std.testing;
const schema = @import("schema.zig");
const tag = schema.tag;

fn expectResolves(s: schema.Schema, want: ?[]const u8, values: []const []const u8) !void {
    for (values) |value| {
        errdefer std.debug.print("schema {s}, value `{s}`\n", .{ @tagName(s), value });
        const got = schema.resolvePlain(s, value);
        if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expectEqual(null, got);
    }
}

test "core: example 10.9 and the edges" {
    try expectResolves(.core, tag.null, &.{ "null", "Null", "NULL", "~", "" });
    try expectResolves(.core, tag.bool, &.{ "true", "True", "TRUE", "false", "False", "FALSE" });
    try expectResolves(.core, tag.int, &.{ "0", "0o7", "0x3A", "-19", "+12", "007", "0xff", "0o0" });
    try expectResolves(.core, tag.float, &.{ "0.", "-0.0", ".5", "+12e03", "-2E+05", ".inf", "-.Inf", "+.INF", ".NAN", ".nan", ".NaN", "1e5", "1.5e-3" });
    try expectResolves(.core, tag.str, &.{
        "nULL",      "tRUE",  "yes", "no",    "on",  "0o8", "0x",    "0xg", "0b101", "1_000", "1e", "1e+", ".", "+", "-", "+.nan",
        ".infinity", "1.2.3", "e5",  "0x1p3", "inf", "nan", "12:30", "- 1", " 1",    "text",
    });
}

test "json: example 10.8 and the edges" {
    try expectResolves(.json, tag.null, &.{"null"});
    try expectResolves(.json, tag.bool, &.{ "true", "false" });
    try expectResolves(.json, tag.int, &.{ "0", "-0", "3", "-19" });
    try expectResolves(.json, tag.float, &.{ "0.", "-0.0", "12e03", "-2E+05", "1.5", "0.5e-3" });
    try expectResolves(.json, null, &.{ "True", "Null", "0o7", "0x3A", "+12.3", "", "~", "01", ".5", "1.5.5", "text", "-", "1e" });
}

test "failsafe: everything a string" {
    try expectResolves(.failsafe, tag.str, &.{ "null", "true", "1", "1.5", "", "text" });
}

test "values: integers, floats, booleans" {
    try testing.expectEqual(58, schema.parseInt("0x3A").?);
    try testing.expectEqual(7, schema.parseInt("0o7").?);
    try testing.expectEqual(-19, schema.parseInt("-19").?);
    try testing.expectEqual(12, schema.parseInt("+12").?);
    try testing.expectEqual(null, schema.parseInt("1_000"));
    try testing.expectEqual(null, schema.parseInt("99999999999999999999999999999999999999999999"));
    try testing.expectEqual(12000, schema.parseFloat("+12e03").?);
    try testing.expectEqual(0.5, schema.parseFloat(".5").?);
    try testing.expectEqual(-std.math.inf(f64), schema.parseFloat("-.Inf").?);
    try testing.expect(std.math.isNan(schema.parseFloat(".NAN").?));
    try testing.expectEqual(1, schema.parseFloat("1").?);
    try testing.expectEqual(null, schema.parseFloat("1_0.5"));
    try testing.expectEqual(null, schema.parseFloat("0x1p3"));
    try testing.expectEqual(true, schema.parseBool("TRUE").?);
    try testing.expectEqual(null, schema.parseBool("yes"));
}

test "equal values hash the same" {
    const pairs = [_]struct { []const u8, []const u8, []const u8 }{
        .{ tag.int, "1", "0x1" },
        .{ tag.int, "+8", "0o10" },
        .{ tag.float, "0.0", "-0.0" },
        .{ tag.float, "1.5", "15e-1" },
        .{ tag.bool, "true", "TRUE" },
        .{ tag.null, "~", "" },
        .{ tag.str, "a", "a" },
    };
    for (pairs) |p| {
        try testing.expect(schema.equalValues(p[0], p[1], p[2]));
        var a: std.hash.Wyhash = .init(7);
        var b: std.hash.Wyhash = .init(7);
        schema.hashValue(&a, p[0], p[1]);
        schema.hashValue(&b, p[0], p[2]);
        try testing.expectEqual(a.final(), b.final());
    }
    try testing.expect(!schema.equalValues(tag.float, ".nan", ".nan"));
    try testing.expect(!schema.equalValues(tag.str, "1", "0x1"));
}
