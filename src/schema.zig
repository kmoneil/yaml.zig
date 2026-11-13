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
//! - yaml11: YAML 1.1's types as PyYAML resolves them, for files written
//!   for 1.1 readers. `yes`, `no`, `on` and `off`, in the same three
//!   cases, are booleans too; integers may be binary (`0b101`), octal
//!   with a leading `0` (`0777` is 511), have `_` among their digits
//!   (`1_000`) or be sexagesimal (`1:20` is 80); a float needs its point,
//!   and an exponent its sign (`1.5`, `1_000.5`, `6.8e+5`, `1:20.5`); and
//!   a date, `2001-12-14`, or a date and time is a timestamp. `y` and `n`
//!   stay strings, as PyYAML reads them, and `1e3` is a string.
//!
//! The same rules give a scalar's value: `Schema.int`, `Schema.float`,
//! `Schema.boolean`, `parseTimestamp`, and equality by value for keys (`1`
//! and `0x1` are one key). `parseInt`, `parseFloat` and `parseBool` are
//! the core schema's, which hold the JSON schema's.

const std = @import("std");

/// The schemas YAML 1.2.2 defines (chapter 10), and YAML 1.1's.
pub const Schema = enum {
    failsafe,
    json,
    core,
    /// YAML 1.1's types as PyYAML resolves them.
    yaml11,

    /// The value of a scalar this schema reads as an integer, as a `T`;
    /// null when it is not one, or does not fit a `T`. Under yaml11 a
    /// 1.1 form is read as 1.1 reads it (`0777` is 511), and a 1.2 one
    /// as 1.2 does (`!!int 0o17` is 15), as PyYAML reads both.
    pub fn int(s: Schema, comptime T: type, value: []const u8) ?T {
        if (s == .yaml11 and isInt11(value)) return parseInt11(T, value);
        return parseIntAs(T, value);
    }

    /// The value of a scalar this schema reads as a float; null when it
    /// is not one.
    pub fn float(s: Schema, value: []const u8) ?f64 {
        if (s == .yaml11 and isFloat11(value)) return parseFloat11(value);
        return parseFloat(value);
    }

    /// The value of a scalar this schema reads as a boolean.
    pub fn boolean(s: Schema, value: []const u8) ?bool {
        if (s == .yaml11) return parseBool11(value);
        return parseCoreBool(value);
    }

    /// Whether `value` is what the tag `scalar_tag` says it is (`fitsTag`),
    /// under yaml11 in a 1.1 form or a 1.2 one.
    pub fn fits(s: Schema, scalar_tag: []const u8, value: []const u8) bool {
        if (s != .yaml11) return fitsTag(scalar_tag, value);
        return switch (core(scalar_tag) orelse return true) {
            .null => isCoreNull(value),
            .bool => parseBool11(value) != null,
            .int => isInt11(value) or isCoreInt(value),
            .float => isFloat11(value) or isCoreFloat(value),
            .str, .seq, .map => true,
        };
    }

    /// Whether two scalars with the same tag have the same value: by
    /// number for an integer or a float, by truth for a boolean, always
    /// for null, and by text for anything else.
    pub fn equal(s: Schema, scalar_tag: []const u8, a: []const u8, b: []const u8) bool {
        return switch (core(scalar_tag) orelse .str) {
            .null => true,
            .bool => sameOrText(s.boolean(a), s.boolean(b), a, b),
            .int => sameOrText(s.int(i128, a), s.int(i128, b), a, b),
            .float => {
                const x = s.float(a) orelse return std.mem.eql(u8, a, b);
                const y = s.float(b) orelse return false;
                return x == y;
            },
            .str, .seq, .map => std.mem.eql(u8, a, b),
        };
    }

    /// Feeds `hasher` a scalar's value as `equal` sees it, so equal
    /// values hash the same.
    pub fn hash(s: Schema, hasher: *std.hash.Wyhash, scalar_tag: []const u8, value: []const u8) void {
        switch (core(scalar_tag) orelse .str) {
            .null => return,
            .bool => if (s.boolean(value)) |b| return hasher.update(&.{@intFromBool(b)}),
            .int => if (s.int(i128, value)) |n| return hasher.update(std.mem.asBytes(&n)),
            // 0.0 and -0.0 are equal; NaN equals nothing, so any hash will do.
            .float => if (s.float(value)) |x| {
                const v: f64 = if (x == 0) 0 else x;
                return hasher.update(std.mem.asBytes(&v));
            },
            .str, .seq, .map => {},
        }
        hasher.update(value);
    }
};

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
    /// YAML 1.1's date and time, which the yaml11 schema resolves dates
    /// to (`parseTimestamp`).
    pub const timestamp = core_prefix ++ "timestamp";
};

/// The core schema's tags as values, to tell a tag without its text.
pub const Core = enum { null, bool, int, float, str, seq, map };

/// The core tag `t` is, if it is one. The composer gives each node with
/// one these constants' own text, so comparing pointers finds it; any
/// other text is compared as text. Comparing tags as text was a tenth
/// of construction's time (t46).
pub fn core(t: []const u8) ?Core {
    inline for (@typeInfo(Core).@"enum".field_names) |name| {
        const s: []const u8 = @field(tag, name);
        if (t.ptr == s.ptr and t.len == s.len) return @field(Core, name);
    }
    if (!std.mem.startsWith(u8, t, core_prefix)) return null;
    return std.meta.stringToEnum(Core, t[core_prefix.len..]);
}

/// The text of the core tag `c`: one of `tag`'s constants.
pub fn tagOf(c: Core) []const u8 {
    return switch (c) {
        inline else => |which| @field(tag, @tagName(which)),
    };
}

/// Whether YAML 1.1's tag resolution, as PyYAML and other 1.1 readers
/// apply it, reads the plain scalar `text` as something other than a
/// string: a boolean (`y`, `yes`, `on`, `off` and the rest, in their
/// cases), an integer in binary (`0b101`), with `_` (`1_000`) or
/// sexagesimal (`1:20`), a float with `_` or sexagesimal, a date or a
/// timestamp (`2001-12-14`), the merge key `<<`, or `=`, which PyYAML
/// reads as a value key it then cannot build. For text the core schema
/// reads as a string, writing it plain is right for YAML 1.2 and wrong
/// for those readers: the "Norway problem", `no` read as false. It holds
/// everything the yaml11 schema types, and more forms other 1.1 readers
/// take: `y` and `n`, and looser numbers and dates.
pub fn yaml11Typed(text: []const u8) bool {
    // Each form begins with one of a few characters, as in resolveYaml11:
    // text beginning with any other is a string, known without comparing
    // it to the forms one by one, which was a tenth of stringify's time
    // (t75). The empty text is null.
    if (text.len > 0 and !yaml11_first[text[0]]) return false;
    return yaml11Forms(text);
}

/// The first bytes of what `yaml11Forms` types: of `<<` and `=`, the
/// booleans, numbers, dates and what resolveYaml11 types.
const yaml11_first: [256]bool = blk: {
    var first: [256]bool = @splat(false);
    for ("<=~nNyYtTfFoO0123456789+-.") |c| first[c] = true;
    break :blk first;
};

fn yaml11Forms(text: []const u8) bool {
    if (std.mem.eql(u8, text, "<<") or std.mem.eql(u8, text, "=")) return true;
    for (yaml11_booleans) |word| {
        if (std.mem.eql(u8, text, word)) return true;
    }
    if (yaml11Number(text) or yaml11Date(text)) return true;
    return resolveYaml11(text).ptr != tag.str.ptr;
}

test "yaml11Typed: what yaml11_first leaves out, no form types" {
    // Every first byte, before tails that make each form.
    const tails = [_][]const u8{ "", "<", "es", "ES", "rue", "alse", "n", "ff", "FF", "ull", "0", "1", "b1", "x1F", "o17", ":20", "_000", ".5", ".5e3", "inf", "nan", "001-12-14", "-12-14", "2-14", " 21:59:43" };
    for (0..256) |c| for (tails) |tail| {
        var buf: [16]u8 = undefined;
        buf[0] = @intCast(c);
        @memcpy(buf[1..][0..tail.len], tail);
        const text = buf[0 .. 1 + tail.len];
        try std.testing.expectEqual(yaml11Forms(text), yaml11Typed(text));
    };
    try std.testing.expect(yaml11Typed(""));
}

const yaml11_booleans = [_][]const u8{
    "y",    "Y",    "yes",  "Yes",   "YES",   "n",     "N",  "no", "No", "NO",
    "true", "True", "TRUE", "false", "False", "FALSE", "on", "On", "ON", "off",
    "Off",  "OFF",
};

/// An integer or float in a form YAML 1.1 has and 1.2's core schema has
/// not: binary, with `_`, or sexagesimal (`1:20`, `1:20.5`).
fn yaml11Number(text: []const u8) bool {
    const digits = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    if (std.mem.startsWith(u8, digits, "0b")) return digits.len > 2 and allIn(digits[2..], "01_");
    if (digits.len == 0 or !std.ascii.isDigit(digits[0]) or !allIn(digits, "0123456789_:.")) return false;
    if (std.mem.findScalar(u8, digits, '_') != null) return std.mem.count(u8, digits, ".") <= 1;
    return sexagesimal(digits);
}

/// Whether every byte of `text` is one of `set`.
fn allIn(text: []const u8, set: []const u8) bool {
    for (text) |c| {
        if (std.mem.findScalar(u8, set, c) == null) return false;
    }
    return true;
}

/// Whether `digits`, of digits, `:` and `.`, is sexagesimal: a `:`, each
/// part after one one or two digits below 60, and at most one `.`, after
/// the last.
fn sexagesimal(digits: []const u8) bool {
    const last_colon = std.mem.findScalarLast(u8, digits, ':') orelse return false;
    const dot = std.mem.findScalar(u8, digits, '.') orelse digits.len;
    if (dot < last_colon or std.mem.count(u8, digits, ".") > 1) return false;
    var parts = std.mem.splitScalar(u8, digits[0..dot], ':');
    _ = parts.next();
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 2) return false;
        const n = std.fmt.parseInt(u8, part, 10) catch return false;
        if (n >= 60) return false;
    }
    return true;
}

/// A date or timestamp YAML 1.1 reads, `2001-12-14` or with a time after
/// a `T` or blanks: four digits, `-`, one or two, `-`, one or two.
fn yaml11Date(text: []const u8) bool {
    if (text.len < 8 or !allIn(text[0..4], "0123456789")) return false;
    var i: usize = 4;
    if (!datePart(text, &i) or !datePart(text, &i)) return false;
    return i == text.len or std.mem.findScalar(u8, "Tt \t", text[i]) != null;
}

/// A `-` and one or two digits at `i.*`, `i.*` left after them.
fn datePart(text: []const u8, i: *usize) bool {
    if (i.* >= text.len or text[i.*] != '-') return false;
    i.* += 1;
    const start = i.*;
    while (i.* < text.len and i.* - start < 2 and std.ascii.isDigit(text[i.*])) i.* += 1;
    return i.* > start;
}

/// The tag a plain scalar with no tag resolves to, or null when the
/// schema has none for it (the JSON schema's error).
pub fn resolvePlain(schema: Schema, value: []const u8) ?[]const u8 {
    return switch (schema) {
        .failsafe => tag.str,
        .json => resolveJson(value),
        .core => resolveCore(value),
        .yaml11 => resolveYaml11(value),
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
    // Each form but the empty null begins with one of a few characters:
    // any other first character is a string's, known without comparing
    // the forms one by one (t46).
    if (value.len == 0) return tag.null;
    switch (value[0]) {
        'n', 'N', '~' => if (isCoreNull(value)) return tag.null,
        't', 'T', 'f', 'F' => if (parseCoreBool(value) != null) return tag.bool,
        '0'...'9', '+', '-', '.' => {
            if (isCoreInt(value)) return tag.int;
            if (isCoreFloat(value)) return tag.float;
        },
        else => {},
    }
    return tag.str;
}

/// YAML 1.1's resolution, PyYAML's form for form: null as in the core
/// schema, then a boolean, a float, an integer or a timestamp, each in
/// the forms below; anything else a string.
fn resolveYaml11(value: []const u8) []const u8 {
    if (value.len == 0) return tag.null;
    // As in resolveCore, the first character rules out most forms.
    return switch (value[0]) {
        '~', 'n', 'N', 'y', 'Y', 't', 'T', 'f', 'F', 'o', 'O' => resolveWord11(value),
        '0'...'9', '+', '-', '.' => resolveNumber11(value),
        else => tag.str,
    };
}

fn resolveWord11(value: []const u8) []const u8 {
    if (isCoreNull(value)) return tag.null;
    if (parseBool11(value) != null) return tag.bool;
    return tag.str;
}

fn resolveNumber11(value: []const u8) []const u8 {
    if (isFloat11(value)) return tag.float;
    if (isInt11(value)) return tag.int;
    if (timestampParts(value) != null) return tag.timestamp;
    return tag.str;
}

/// `yes`, `no`, `true`, `false`, `on` and `off`, each in lower, title or
/// upper case. YAML 1.1's type page has `y` and `n` too; PyYAML does not.
fn parseBool11(value: []const u8) ?bool {
    if (isAny(value, &.{ "yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON" })) return true;
    if (isAny(value, &.{ "no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF" })) return false;
    return null;
}

const decimal_digits = "0123456789_";

/// PyYAML's integers, each with an optional sign: `0b` and binary digits,
/// `0` and octal ones, decimal, `0x` and hex, and sexagesimal, a decimal
/// not starting with `0` and `:` parts (`190:20:30`). `_` may come among
/// the digits. (PyYAML takes `0b_` and `0x_`, no digit but `_`, and then
/// fails to read them: here they are strings.)
fn isInt11(value: []const u8) bool {
    const digits = withoutSign(value, "-+");
    if (std.mem.startsWith(u8, digits, "0b")) return someDigits(digits[2..], "01");
    if (std.mem.startsWith(u8, digits, "0x")) return someDigits(digits[2..], "0123456789abcdefABCDEF");
    if (digits.len == 0 or !std.ascii.isDigit(digits[0])) return false;
    if (digits[0] == '0') return allIn(digits[1..], "01234567_");
    const colon = std.mem.findScalar(u8, digits, ':') orelse return allIn(digits, decimal_digits);
    return allIn(digits[0..colon], decimal_digits) and sexagesimalParts(digits[colon..]);
}

/// Whether `text` is of `digits` and `_`, with one digit at least.
fn someDigits(text: []const u8, comptime digits: []const u8) bool {
    return allIn(text, digits ++ "_") and std.mem.findNone(u8, text, "_") != null;
}

/// Whether `text` is one or more `:`, each followed by one digit or two
/// below 60: a sexagesimal number's parts after the first.
fn sexagesimalParts(text: []const u8) bool {
    if (text.len == 0 or text[0] != ':') return false;
    var parts = std.mem.splitScalar(u8, text[1..], ':');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 2 or !allIn(part, "0123456789")) return false;
        if (part.len == 2 and part[0] > '5') return false;
    }
    return true;
}

/// PyYAML's floats: digits, a point, maybe more digits, and maybe an
/// exponent with its sign (`1.`, `1_000.5`, `6.8523015e+5`), any of it
/// signed; a point and digits, unsigned (`.5`); sexagesimal with a point
/// (`190:20:30.15`); `.inf` with any sign and `.nan`, in three cases
/// each. `1e3`, with no point, and `-.5` are strings.
fn isFloat11(value: []const u8) bool {
    if (isNan(value) or isInf(withoutSign(value, "-+"))) return true;
    if (value.len > 1 and value[0] == '.') return std.ascii.isDigit(value[1]) and isFraction11(value[2..]);
    const unsigned = withoutSign(value, "-+");
    if (unsigned.len == 0 or !std.ascii.isDigit(unsigned[0])) return false;
    const point = std.mem.findScalar(u8, unsigned, '.') orelse return false;
    return isPointed11(unsigned[0..point], unsigned[point + 1 ..]);
}

fn isNan(value: []const u8) bool {
    return isAny(value, &.{ ".nan", ".NaN", ".NAN" });
}

fn isInf(unsigned: []const u8) bool {
    return isAny(unsigned, &.{ ".inf", ".Inf", ".INF" });
}

/// A 1.1 float's digits before its point, `whole`, decimal or
/// sexagesimal, and after it, `rest`, which only a decimal one may end
/// with an exponent.
fn isPointed11(whole: []const u8, rest: []const u8) bool {
    const colon = std.mem.findScalar(u8, whole, ':') orelse return allIn(whole, decimal_digits) and isFraction11(rest);
    return allIn(whole[0..colon], decimal_digits) and sexagesimalParts(whole[colon..]) and allIn(rest, decimal_digits);
}

/// A 1.1 float after its point: digits and `_`, then maybe `e` or `E`, a
/// sign and digits.
fn isFraction11(text: []const u8) bool {
    const e = std.mem.findAny(u8, text, "eE") orelse return allIn(text, decimal_digits);
    const exponent = text[e + 1 ..];
    return allIn(text[0..e], decimal_digits) and exponent.len > 1 and
        (exponent[0] == '-' or exponent[0] == '+') and allDigits(exponent[1..], 10);
}

/// A 1.1 integer's value as PyYAML reads it, as a `T`: `_` dropped, the
/// base by the prefix, `0` and more digits octal, and each sexagesimal
/// part 60 times the one after it. Null when it does not fit a `T`.
fn parseInt11(comptime T: type, value: []const u8) ?T {
    // Wide enough for any `T`'s magnitude, the most negative's too.
    const M = @Int(.unsigned, @max(@bitSizeOf(T), 64));
    const digits = withoutSign(value, "-+");
    const magnitude = if (std.mem.startsWith(u8, digits, "0b"))
        accumulate(M, digits[2..], 2)
    else if (std.mem.startsWith(u8, digits, "0x"))
        accumulate(M, digits[2..], 16)
    else if (std.mem.findScalar(u8, digits, ':') != null)
        sexagesimalValue(M, digits)
    else if (digits.len > 1 and digits[0] == '0')
        accumulate(M, digits, 8)
    else
        accumulate(M, digits, 10);
    return withSign(T, M, value.len > 0 and value[0] == '-', magnitude orelse return null);
}

/// The number `digits` writes in `base`, `_` skipped; null past an `M`,
/// or with no digit.
fn accumulate(comptime M: type, digits: []const u8, base: u8) ?M {
    var n: M = 0;
    var any = false;
    for (digits) |ch| {
        if (ch == '_') continue;
        const d = std.fmt.charToDigit(ch, base) catch return null;
        n = std.math.add(M, std.math.mul(M, n, base) catch return null, d) catch return null;
        any = true;
    }
    return if (any) n else null;
}

/// A sexagesimal integer's magnitude, `190:20:30`.
fn sexagesimalValue(comptime M: type, digits: []const u8) ?M {
    var parts = std.mem.splitScalar(u8, digits, ':');
    var n = accumulate(M, parts.first(), 10) orelse return null;
    while (parts.next()) |part| {
        const p = accumulate(M, part, 10) orelse return null;
        n = std.math.add(M, std.math.mul(M, n, 60) catch return null, p) catch return null;
    }
    return n;
}

/// `magnitude`, negated if `negative`, as a `T`; null if it does not fit.
fn withSign(comptime T: type, comptime M: type, negative: bool, magnitude: M) ?T {
    if (!negative or magnitude == 0) return std.math.cast(T, magnitude);
    if (@typeInfo(T).int.signedness == .unsigned) {
        return null;
    } else {
        const most = @as(M, std.math.maxInt(T)) + 1;
        if (magnitude > most) return null;
        if (magnitude == most) return std.math.minInt(T);
        return -@as(T, @intCast(magnitude));
    }
}

/// A 1.1 float's value as PyYAML reads it: `_` dropped, and sexagesimal
/// parts summed from the last, each 60 times the one after it, in the
/// order PyYAML sums them, so the result is the same to the bit. Null
/// for a float with `_` over 1,024 bytes long once they are dropped.
fn parseFloat11(value: []const u8) ?f64 {
    if (isNan(value)) return std.math.nan(f64);
    const unsigned = withoutSign(value, "-+");
    const sign: f64 = if (value[0] == '-') -1 else 1;
    if (isInf(unsigned)) return sign * std.math.inf(f64);
    var buf: [1024]u8 = undefined;
    var x: f64 = 0;
    var base: f64 = 1;
    var parts = std.mem.splitBackwardsScalar(u8, unsigned, ':');
    while (parts.next()) |part| {
        const text = withoutUnderscores(&buf, part) orelse return null;
        x += (std.fmt.parseFloat(f64, text) catch return null) * base;
        base *= 60;
    }
    return sign * x;
}

/// `text` with its `_` dropped, in `buf` if it has any; null if what is
/// left does not fit `buf`.
fn withoutUnderscores(buf: []u8, text: []const u8) ?[]const u8 {
    if (std.mem.findScalar(u8, text, '_') == null) return text;
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '_') continue;
        if (n == buf.len) return null;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
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
    if (value.len > 0 and std.mem.findScalar(u8, signs, value[0]) != null) return value[1..];
    return value;
}

/// `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`, or an infinity
/// or a NaN in one of its three spellings.
fn isCoreFloat(value: []const u8) bool {
    if (isAny(value, &.{ ".nan", ".NaN", ".NAN" })) return true;
    const unsigned = withoutSign(value, "-+");
    if (isAny(unsigned, &.{ ".inf", ".Inf", ".INF" })) return true;
    const mantissa_end = std.mem.findAny(u8, unsigned, "eE") orelse unsigned.len;
    if (!isCoreMantissa(unsigned[0..mantissa_end])) return false;
    return mantissa_end == unsigned.len or isExponent(unsigned[mantissa_end + 1 ..]);
}

/// `\.[0-9]+` or `[0-9]+(\.[0-9]*)?`.
fn isCoreMantissa(text: []const u8) bool {
    const point = std.mem.findScalar(u8, text, '.') orelse return allDigits(text, 10);
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
    const mantissa_end = std.mem.findAny(u8, unsigned, "eE") orelse unsigned.len;
    const mantissa = unsigned[0..mantissa_end];
    const point = std.mem.findScalar(u8, mantissa, '.') orelse mantissa.len;
    if (!isJsonInt(mantissa[0..point])) return false;
    if (point < mantissa.len and point + 1 < mantissa.len and !allDigits(mantissa[point + 1 ..], 10)) return false;
    return mantissa_end == unsigned.len or isExponent(unsigned[mantissa_end + 1 ..]);
}

// Timestamps

/// A YAML 1.1 timestamp (yaml.org/type/timestamp): a date, `2001-12-14`,
/// or a date and a time, `2001-12-14t21:59:43.10-05:00`.
pub const Timestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    /// Null for a date alone.
    time: ?Time,

    pub const Time = struct {
        hour: u8,
        minute: u8,
        second: u8,
        /// The fraction of the second in nanoseconds; digits past the
        /// ninth are dropped.
        nanosecond: u32,
        /// Minutes east of UTC, `Z` being 0; null when no zone is given.
        offset: ?i16,
    };
};

/// The timestamp `text` writes, in a form the yaml11 schema resolves to
/// one, when it names a real day and time: a month of 1 to 12, a day the
/// month has, an hour below 24, a minute and a second below 60, and an
/// offset under a day. Null for any other text, `2001-02-30` among it.
pub fn parseTimestamp(text: []const u8) ?Timestamp {
    const t = timestampParts(text) orelse return null;
    return if (isReal(t)) t else null;
}

/// A timestamp's parts, in PyYAML's form, their ranges not checked: four
/// digits, `-`, two and `-`, two for a date alone; with a time, a month
/// and a day of one or two digits, then `T`, `t` or blanks, `h:mm:ss`
/// with an hour of one or two, maybe a point and a fraction, and maybe
/// blanks and a zone, `Z` or a sign, an hour of one or two digits and
/// maybe `:mm`.
fn timestampParts(text: []const u8) ?Timestamp {
    var r: Cursor = .{ .text = text };
    var t = r.date() orelse return null;
    if (r.done()) return if (r.i == "2001-12-14".len) t else null;
    t.time = r.time() orelse return null;
    return if (r.done()) t else null;
}

fn isReal(t: Timestamp) bool {
    if (t.month < 1 or t.month > 12 or t.day < 1 or t.day > daysIn(t.year, t.month)) return false;
    const time = t.time orelse return true;
    if (time.hour > 23 or time.minute > 59 or time.second > 59) return false;
    return @abs(time.offset orelse 0) < 24 * 60;
}

fn daysIn(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Reads a timestamp's text from `i`.
const Cursor = struct {
    text: []const u8,
    i: usize = 0,

    fn done(r: Cursor) bool {
        return r.i == r.text.len;
    }

    fn take(r: *Cursor, ch: u8) bool {
        if (r.i == r.text.len or r.text[r.i] != ch) return false;
        r.i += 1;
        return true;
    }

    /// `ch`, then the number `min` to `max` digits write.
    fn after(r: *Cursor, ch: u8, min: usize, max: usize) ?u32 {
        if (!r.take(ch)) return null;
        return r.digits(min, max);
    }

    /// `yyyy-m-d`, the month and day of one digit or two.
    fn date(r: *Cursor) ?Timestamp {
        const year = r.digits(4, 4) orelse return null;
        const month = r.after('-', 1, 2) orelse return null;
        const day = r.after('-', 1, 2) orelse return null;
        return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day), .time = null };
    }

    /// A time after its date, to the end of the text, a zone and all.
    fn time(r: *Cursor) ?Timestamp.Time {
        if (!r.take('T') and !r.take('t') and r.blanks() == 0) return null;
        const hour = r.digits(1, 2) orelse return null;
        const minute = r.after(':', 2, 2) orelse return null;
        const second = r.after(':', 2, 2) orelse return null;
        const nanosecond = if (r.take('.')) r.fraction() else 0;
        var t: Timestamp.Time = .{ .hour = @intCast(hour), .minute = @intCast(minute), .second = @intCast(second), .nanosecond = nanosecond, .offset = null };
        if (r.done()) return t;
        _ = r.blanks();
        t.offset = r.zone() orelse return null;
        return t;
    }

    /// The number `min` to `max` digits write, as many as there are.
    fn digits(r: *Cursor, min: usize, max: usize) ?u32 {
        const start = r.i;
        var n: u32 = 0;
        while (r.i < r.text.len and r.i - start < max and std.ascii.isDigit(r.text[r.i])) : (r.i += 1) {
            n = n * 10 + (r.text[r.i] - '0');
        }
        return if (r.i - start >= min) n else null;
    }

    fn blanks(r: *Cursor) usize {
        const start = r.i;
        while (r.i < r.text.len and (r.text[r.i] == ' ' or r.text[r.i] == '\t')) r.i += 1;
        return r.i - start;
    }

    /// A fraction's digits as nanoseconds.
    fn fraction(r: *Cursor) u32 {
        var n: u32 = 0;
        var places: usize = 0;
        while (r.i < r.text.len and std.ascii.isDigit(r.text[r.i])) : (r.i += 1) {
            if (places == 9) continue;
            n = n * 10 + (r.text[r.i] - '0');
            places += 1;
        }
        while (places < 9) : (places += 1) n *= 10;
        return n;
    }

    /// A zone's offset in minutes: `Z`, or a sign, an hour and maybe `:mm`.
    fn zone(r: *Cursor) ?i16 {
        if (r.take('Z')) return 0;
        const sign: i16 = if (r.take('+')) 1 else if (r.take('-')) -1 else return null;
        const hours = r.digits(1, 2) orelse return null;
        const minutes = if (r.take(':')) r.digits(2, 2) orelse return null else 0;
        return sign * @as(i16, @intCast(hours * 60 + minutes));
    }
};

// Values

/// The value of a scalar the core or JSON schema reads as an integer; null
/// when it is not one, or does not fit an i128. (`Schema.int` for any
/// schema.)
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
    return switch (core(scalar_tag) orelse return true) {
        .null => isCoreNull(value),
        .bool => parseCoreBool(value) != null,
        .int => isCoreInt(value),
        .float => isCoreFloat(value),
        .str, .seq, .map => true,
    };
}

/// Whether two scalars with the same tag have the same value under the
/// core schema (`Schema.equal`).
pub fn equalValues(scalar_tag: []const u8, a: []const u8, b: []const u8) bool {
    return Schema.core.equal(scalar_tag, a, b);
}

fn sameOrText(x: anytype, y: @TypeOf(x), a: []const u8, b: []const u8) bool {
    if (x == null or y == null) return std.mem.eql(u8, a, b);
    return x.? == y.?;
}

/// Feeds `hasher` a scalar's value as `equalValues` sees it, so equal
/// values hash the same.
pub fn hashValue(hasher: *std.hash.Wyhash, scalar_tag: []const u8, value: []const u8) void {
    Schema.core.hash(hasher, scalar_tag, value);
}
