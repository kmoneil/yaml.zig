//! The schemas' tests, over YAML 1.2.2's examples of tag resolution
//! (10.8 for JSON, 10.9 for core), yaml.org's YAML 1.1 type pages for
//! yaml11, and the edges of each pattern.

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

test "yaml11: the 1.1 type pages, as PyYAML resolves them" {
    try expectResolves(.yaml11, tag.null, &.{ "", "~", "null", "Null", "NULL" });
    try expectResolves(.yaml11, tag.bool, &.{ "yes", "Yes", "YES", "no", "No", "NO", "true", "True", "TRUE", "false", "False", "FALSE", "on", "On", "ON", "off", "Off", "OFF" });
    try expectResolves(.yaml11, tag.int, &.{
        "685230", "+685_230", "02472256", "0x_0A_74_AE", "0b1010_0111_0100_1010_1110", "190:20:30",
        "0",      "-0",       "00",       "0_",          "1_000_",                     "-0x1F",
        "+0b1",   "1:5:9",    "12:30",
    });
    try expectResolves(.yaml11, tag.float, &.{
        "6.8523015e+5", "685.230_15e+03", "685_230.15", "190:20:30.15", "-.inf", ".NaN", "+.INF", "1.",
        ".5",           "1.e+3",          "0:30.5",     "-1_.__",
    });
    try expectResolves(.yaml11, tag.timestamp, &.{
        "2001-12-15T02:59:43.1Z", "2001-12-14t21:59:43.10-05:00", "2001-12-14 21:59:43.10 -5", "2001-12-15 2:59:43.10", "2002-12-14",
        "2001-1-2T3:04:05",       "2001-12-14\t21:59:43 Z",       "2001-02-30",
    });
    try expectResolves(.yaml11, tag.str, &.{
        // y and n: on yaml.org's page, not PyYAML's; `1e3` and `-.5`:
        // no point, and a sign before a lone point.
        "y",         "n",           "Y",           "N",                "yEs",                   "nULL",                 "1e3",  "-.5",  "+.nan", "1.5e3", "1.2.3",
        "0o17",      "08",          "0b",          "0b_",              "0x_",                   "0b2",                  "1:60", "0:30", "1:2:",  "=",     "<<",
        "2002-1-14", "2002-12-14 ", "2002-12-14T", "2001-12-14 1:2:3", "2001-12-14T21:59:43 +", "2001-12-14T21:59:43z", "text",
    });
}

test "yaml11: values as PyYAML reads them" {
    const s: schema.Schema = .yaml11;
    for ([_][]const u8{ "685230", "+685_230", "02472256", "0x_0A_74_AE", "0b1010_0111_0100_1010_1110", "190:20:30" }) |text| {
        try testing.expectEqual(685230, s.int(i64, text).?);
    }
    try testing.expectEqual(-31, s.int(i64, "-0x1F").?);
    try testing.expectEqual(15, s.int(i64, "0o17").?);
    try testing.expectEqual(0, s.int(u8, "-0").?);
    try testing.expectEqual(-128, s.int(i8, "-0b1000_0000").?);
    try testing.expectEqual(null, s.int(i8, "0b1000_0000"));
    try testing.expectEqual(null, s.int(u8, "-1"));
    const ones = "1111111111111111111111111111111111111111111111111111111111111111";
    try testing.expectEqual(null, s.int(i128, "0b" ++ ones ++ ones));
    try testing.expectEqual(std.math.maxInt(u128), s.int(u128, "0b" ++ ones ++ ones).?);
    try testing.expectEqual(777, schema.Schema.core.int(i64, "0777").?);
    for ([_][]const u8{ "6.8523015e+5", "685.230_15e+03", "685_230.15", "190:20:30.15" }) |text| {
        try testing.expectEqual(685230.15, s.float(text).?);
    }
    try testing.expectEqual(1000, s.float("1e3").?);
    try testing.expectEqual(-std.math.inf(f64), s.float("-.inf").?);
    try testing.expect(std.math.isNan(s.float(".NaN").?));
    try testing.expectEqual(true, s.boolean("ON").?);
    try testing.expectEqual(false, s.boolean("no").?);
    try testing.expectEqual(null, s.boolean("y"));
    try testing.expect(s.fits(tag.int, "0o17") and s.fits(tag.float, "1e3") and !s.fits(tag.bool, "y"));
    try testing.expect(!schema.Schema.core.fits(tag.int, "0777_"));
    // Equal under yaml11, not under core.
    try testing.expect(s.equal(tag.int, "0777", "511") and !schema.Schema.core.equal(tag.int, "0777", "511"));
    try testing.expect(s.equal(tag.bool, "yes", "On") and s.equal(tag.float, "1:30.0", "90."));
    var a: std.hash.Wyhash = .init(7);
    var b: std.hash.Wyhash = .init(7);
    s.hash(&a, tag.int, "0x_FF");
    s.hash(&b, tag.int, "255");
    try testing.expectEqual(a.final(), b.final());
}

test "yaml11: timestamps, and the ones that name no real day" {
    const t = schema.parseTimestamp("2001-12-14t21:59:43.123456789987-05:30").?;
    try testing.expectEqual(2001, t.year);
    try testing.expectEqual(12, t.month);
    try testing.expectEqual(14, t.day);
    const time = t.time.?;
    try testing.expectEqual(21, time.hour);
    try testing.expectEqual(59, time.minute);
    try testing.expectEqual(43, time.second);
    try testing.expectEqual(123456789, time.nanosecond);
    try testing.expectEqual(-330, time.offset.?);
    try testing.expectEqual(null, schema.parseTimestamp("2002-12-14").?.time);
    try testing.expectEqual(0, schema.parseTimestamp("2001-12-15T02:59:43.1Z").?.time.?.offset.?);
    try testing.expectEqual(100_000_000, schema.parseTimestamp("2001-12-15T02:59:43.1Z").?.time.?.nanosecond);
    try testing.expectEqual(null, schema.parseTimestamp("2001-12-15 2:59:43").?.time.?.offset);
    try testing.expectEqual(29, schema.parseTimestamp("2000-02-29").?.day);
    for ([_][]const u8{ "2001-02-29", "1900-02-29", "2001-13-01", "2001-00-10", "2001-04-31", "2001-12-14 24:00:00", "2001-12-14 23:60:00", "2001-12-14 23:59:60", "2001-12-14 1:00:00 +24", "2001-12-14 1:00:00 -23:60", "text" }) |text| {
        errdefer std.debug.print("`{s}`\n", .{text});
        try testing.expectEqual(null, schema.parseTimestamp(text));
    }
    try testing.expectEqual(23 * 60 + 59, schema.parseTimestamp("2001-12-14 1:00:00 +23:59").?.time.?.offset.?);
}

test "yaml11: whatever it types, writing quotes" {
    // Each of these yaml11 reads as no string: written plain, it would
    // read back as something else.
    for ([_][]const u8{ "-0x1F", "+0x_1F", "0x_1F", "=", "-1_.__", "1.e+3", "2001-12-14\t21:59:43 Z" }) |text| {
        errdefer std.debug.print("`{s}`\n", .{text});
        try testing.expect(schema.yaml11Typed(text));
    }
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
