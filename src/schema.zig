//! Schemas: how a node with no specific tag gets one (YAML 1.2.2,
//! chapter 10). A collection is a sequence or a mapping, a scalar that is
//! quoted or a block scalar is a string, and so is any scalar with the
//! non-specific tag `!`. A plain scalar is read by the schema:
//!
//! - failsafe: a string, always.
//! - json: `null`, `true` and `false`, and JSON's numbers; anything else
//!   is an error.
//! - core (the default): `null`, `Null`, `NULL`, `~` and the empty scalar
//!   are null; `true`, `True`, `TRUE` and their `false` forms booleans;
//!   integers in decimal (signed), `0o` octal and `0x` hex; floats with a
//!   point or an exponent, `.inf` and `.nan` in three cases each; and
//!   anything else a string.
//!
//! The same rules give a scalar's value: `parseInt`, `parseFloat`,
//! `parseBool`, and equality by value for keys (`1` and `0x1` are one key).

const std = @import("std");

/// The schemas YAML 1.2.2 defines (chapter 10).
pub const Schema = enum { failsafe, json, core };

/// The prefix of every tag the schemas resolve to, which the `!!` handle
/// stands for.
pub const core_prefix = "tag:yaml.org,2002:";

/// The tags the schemas resolve to, in full.
pub const tag = struct {
    pub const @"null" = core_prefix ++ "null";
    pub const @"bool" = core_prefix ++ "bool";
    pub const int = core_prefix ++ "int";
    pub const float = core_prefix ++ "float";
    pub const str = core_prefix ++ "str";
    pub const seq = core_prefix ++ "seq";
    pub const map = core_prefix ++ "map";
};

/// The tag a plain scalar with no tag resolves to, or null when the
/// schema has none for it (the JSON schema's error).
pub fn resolvePlain(schema: Schema, value: []const u8) ?[]const u8 {
    return switch (schema) {
        .failsafe => tag.str,
        .json => resolveJson(value),
        .core => resolveCore(value),
    };
}

fn resolveJson(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "null")) return tag.null;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return tag.bool;
    if (isJsonInt(value)) return tag.int;
    if (isJsonFloat(value)) return tag.float;
    return null;
}

fn resolveCore(value: []const u8) []const u8 {
    if (isCoreNull(value)) return tag.null;
    if (parseCoreBool(value) != null) return tag.bool;
    if (isCoreInt(value)) return tag.int;
    if (isCoreFloat(value)) return tag.float;
    return tag.str;
}

fn isAny(value: []const u8, comptime forms: []const []const u8) bool {
    inline for (forms) |form| {
        if (std.mem.eql(u8, value, form)) return true;
    }
    return false;
}

fn isCoreNull(value: []const u8) bool {
    return isAny(value, &.{ "", "null", "Null", "NULL", "~" });
}

fn parseCoreBool(value: []const u8) ?bool {
    if (isAny(value, &.{ "true", "True", "TRUE" })) return true;
    if (isAny(value, &.{ "false", "False", "FALSE" })) return false;
    return null;
}

fn allDigits(text: []const u8, base: u8) bool {
    if (text.len == 0) return false;
    for (text) |c| _ = std.fmt.charToDigit(c, base) catch return false;
    return true;
}

/// `[-+]?[0-9]+`, `0o[0-7]+` or `0x[0-9a-fA-F]+`.
fn isCoreInt(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "0o")) return allDigits(value[2..], 8);
    if (std.mem.startsWith(u8, value, "0x")) return allDigits(value[2..], 16);
    return allDigits(withoutSign(value, "-+"), 10);
}

/// `-?(0|[1-9][0-9]*)`.
fn isJsonInt(value: []const u8) bool {
    const digits = withoutSign(value, "-");
    return allDigits(digits, 10) and (digits.len == 1 or digits[0] != '0');
}

fn withoutSign(value: []const u8, signs: []const u8) []const u8 {
    if (value.len > 0 and std.mem.indexOfScalar(u8, signs, value[0]) != null) return value[1..];
    return value;
}

/// `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`, or an infinity
/// or a NaN in one of its three spellings.
fn isCoreFloat(value: []const u8) bool {
    if (isAny(value, &.{ ".nan", ".NaN", ".NAN" })) return true;
    const unsigned = withoutSign(value, "-+");
    if (isAny(unsigned, &.{ ".inf", ".Inf", ".INF" })) return true;
    const mantissa_end = std.mem.indexOfAny(u8, unsigned, "eE") orelse unsigned.len;
    if (!isCoreMantissa(unsigned[0..mantissa_end])) return false;
    return mantissa_end == unsigned.len or isExponent(unsigned[mantissa_end + 1 ..]);
}

/// `\.[0-9]+` or `[0-9]+(\.[0-9]*)?`.
fn isCoreMantissa(text: []const u8) bool {
    const point = std.mem.indexOfScalar(u8, text, '.') orelse return allDigits(text, 10);
    if (point == 0) return allDigits(text[1..], 10);
    return allDigits(text[0..point], 10) and (point + 1 == text.len or allDigits(text[point + 1 ..], 10));
}

/// `[-+]?[0-9]+`, after the `e`.
fn isExponent(text: []const u8) bool {
    return allDigits(withoutSign(text, "-+"), 10);
}

/// `-?(0|[1-9][0-9]*)(\.[0-9]*)?([eE][-+]?[0-9]+)?`.
fn isJsonFloat(value: []const u8) bool {
    const unsigned = withoutSign(value, "-");
    const mantissa_end = std.mem.indexOfAny(u8, unsigned, "eE") orelse unsigned.len;
    const mantissa = unsigned[0..mantissa_end];
    const point = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    if (!isJsonInt(mantissa[0..point])) return false;
    if (point < mantissa.len and point + 1 < mantissa.len and !allDigits(mantissa[point + 1 ..], 10)) return false;
    return mantissa_end == unsigned.len or isExponent(unsigned[mantissa_end + 1 ..]);
}

// Values

/// The value of a scalar the core or JSON schema reads as an integer; null
/// when it is not one, or does not fit an i128.
pub fn parseInt(value: []const u8) ?i128 {
    return parseIntAs(i128, value);
}

/// `parseInt` into any integer type `T`: null when the scalar is not an
/// integer, or does not fit a `T`.
pub fn parseIntAs(comptime T: type, value: []const u8) ?T {
    if (!isCoreInt(value)) return null;
    if (std.mem.startsWith(u8, value, "0o")) return std.fmt.parseInt(T, value[2..], 8) catch null;
    if (std.mem.startsWith(u8, value, "0x")) return std.fmt.parseInt(T, value[2..], 16) catch null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

/// The value of a scalar the core or JSON schema reads as a float; null
/// when it is not one.
pub fn parseFloat(value: []const u8) ?f64 {
    if (!isCoreFloat(value)) return null;
    if (isAny(value, &.{ ".nan", ".NaN", ".NAN" })) return std.math.nan(f64);
    if (isAny(withoutSign(value, "-+"), &.{ ".inf", ".Inf", ".INF" })) {
        return if (value[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    }
    return std.fmt.parseFloat(f64, value) catch null;
}

/// The value of a scalar the core schema reads as a boolean.
pub fn parseBool(value: []const u8) ?bool {
    return parseCoreBool(value);
}

/// Whether `value` is what the tag `scalar_tag` says it is: for null, a
/// boolean, an integer or a float, one of the core schema's forms of it
/// (which hold the JSON schema's); for any other tag, any text.
pub fn fitsTag(scalar_tag: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, scalar_tag, tag.null)) return isCoreNull(value);
    if (std.mem.eql(u8, scalar_tag, tag.bool)) return parseCoreBool(value) != null;
    if (std.mem.eql(u8, scalar_tag, tag.int)) return isCoreInt(value);
    if (std.mem.eql(u8, scalar_tag, tag.float)) return isCoreFloat(value);
    return true;
}

/// Whether two scalars with the same tag have the same value: by number
/// for an integer or a float, by truth for a boolean, always for null,
/// and by text for anything else.
pub fn equalValues(scalar_tag: []const u8, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, scalar_tag, tag.null)) return true;
    if (std.mem.eql(u8, scalar_tag, tag.bool)) return sameOrText(parseBool(a), parseBool(b), a, b);
    if (std.mem.eql(u8, scalar_tag, tag.int)) return sameOrText(parseInt(a), parseInt(b), a, b);
    if (std.mem.eql(u8, scalar_tag, tag.float)) {
        const x = parseFloat(a) orelse return std.mem.eql(u8, a, b);
        const y = parseFloat(b) orelse return false;
        return x == y;
    }
    return std.mem.eql(u8, a, b);
}

fn sameOrText(x: anytype, y: @TypeOf(x), a: []const u8, b: []const u8) bool {
    if (x == null or y == null) return std.mem.eql(u8, a, b);
    return x.? == y.?;
}

/// Feeds `hasher` a scalar's value as `equalValues` sees it, so equal
/// values hash the same.
pub fn hashValue(hasher: *std.hash.Wyhash, scalar_tag: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, scalar_tag, tag.null)) return;
    if (std.mem.eql(u8, scalar_tag, tag.bool)) {
        if (parseBool(value)) |b| return hasher.update(&.{@intFromBool(b)});
    } else if (std.mem.eql(u8, scalar_tag, tag.int)) {
        if (parseInt(value)) |n| return hasher.update(std.mem.asBytes(&n));
    } else if (std.mem.eql(u8, scalar_tag, tag.float)) {
        // 0.0 and -0.0 are equal; NaN equals nothing, so any hash will do.
        if (parseFloat(value)) |x| {
            const v: f64 = if (x == 0) 0 else x;
            return hasher.update(std.mem.asBytes(&v));
        }
    }
    hasher.update(value);
}
