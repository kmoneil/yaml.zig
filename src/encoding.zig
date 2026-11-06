//! A YAML stream's encoding (YAML 1.2.2, 5.2): UTF-8, UTF-16 or UTF-32,
//! either byte order, told by a byte order mark or, without one, by where
//! the first character's zero bytes fall (YAML text starts with an ASCII
//! character). The scanner reads UTF-8; `toUtf8` gives it that.
//! `parseFromSlice` calls it; a caller of the scanner, parser or composer
//! calls it first for input that may be in another encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("Scanner.zig").Diagnostic;

/// The encodings a YAML stream may be in.
pub const Encoding = enum { utf8, utf16le, utf16be, utf32le, utf32be };

/// The encoding the first bytes show (the table in YAML 1.2.2, 5.2): a
/// byte order mark, or the zero bytes of an ASCII first character, `x`
/// in the patterns below. Rows are tried in order.
pub fn detect(bytes: []const u8) Encoding {
    for (table) |row| {
        if (matches(bytes, row.pattern)) return row.encoding;
    }
    return .utf8;
}

const Row = struct { pattern: []const u8, encoding: Encoding };

const table = [_]Row{
    .{ .pattern = "\x00\x00\xFE\xFF", .encoding = .utf32be },
    .{ .pattern = "\xFF\xFE\x00\x00", .encoding = .utf32le },
    .{ .pattern = "\xFE\xFF", .encoding = .utf16be },
    .{ .pattern = "\xFF\xFE", .encoding = .utf16le },
    .{ .pattern = "\x00\x00\x00x", .encoding = .utf32be },
    .{ .pattern = "x\x00\x00\x00", .encoding = .utf32le },
    .{ .pattern = "\x00x", .encoding = .utf16be },
    .{ .pattern = "x\x00", .encoding = .utf16le },
};

/// Whether `bytes` begins as `pattern` does, an `x` in it any byte.
fn matches(bytes: []const u8, pattern: []const u8) bool {
    if (bytes.len < pattern.len) return false;
    for (pattern, bytes[0..pattern.len]) |p, b| {
        if (p != 'x' and p != b) return false;
    }
    return true;
}

/// Decoding's errors.
pub const Error = error{
    /// The bytes are not valid in their encoding: a bad UTF-8 sequence, an
    /// unpaired surrogate, a code point past U+10FFFF, or a length that is
    /// not a whole number of code units.
    InvalidEncoding,
    OutOfMemory,
};

/// The stream as UTF-8: `bytes` itself when it is UTF-8 already, or else
/// decoded into `allocator`, a byte order mark kept as UTF-8's. On
/// `error.InvalidEncoding`, `diagnostic` has the offset of the bad bytes.
pub fn toUtf8(allocator: Allocator, bytes: []const u8, diagnostic: ?*Diagnostic) Error![]const u8 {
    const encoding = detect(bytes);
    return switch (encoding) {
        .utf8 => validateUtf8(bytes, diagnostic),
        .utf16le, .utf16be => decodeUtf16(allocator, bytes, encoding == .utf16be, diagnostic),
        .utf32le, .utf32be => decodeUtf32(allocator, bytes, encoding == .utf32be, diagnostic),
    };
}

fn invalid(diagnostic: ?*Diagnostic, offset: usize, message: []const u8) Error {
    if (diagnostic) |d| d.* = .{ .mark = .{ .offset = offset }, .message = message };
    return error.InvalidEncoding;
}

fn validateUtf8(bytes: []const u8, diagnostic: ?*Diagnostic) Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch break;
        if (i + len > bytes.len) break;
        _ = std.unicode.utf8Decode(bytes[i..][0..len]) catch break;
        i += len;
    }
    return invalid(diagnostic, i, "this is not valid UTF-8");
}

fn decodeUtf16(allocator: Allocator, bytes: []const u8, big: bool, diagnostic: ?*Diagnostic) Error![]const u8 {
    if (bytes.len % 2 != 0) return invalid(diagnostic, bytes.len - 1, "UTF-16 takes two bytes a code unit, and this ends with one");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const unit = unit16(bytes, i, big);
        var point: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF and i + 4 <= bytes.len) {
            const low = unit16(bytes, i + 2, big);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                point = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low - 0xDC00);
                i += 2;
            }
        }
        if (point >= 0xD800 and point <= 0xDFFF) return invalid(diagnostic, i, "an unpaired UTF-16 surrogate");
        try appendPoint(allocator, &out, point);
        i += 2;
    }
    return out.toOwnedSlice(allocator);
}

fn unit16(bytes: []const u8, i: usize, big: bool) u16 {
    return std.mem.readInt(u16, bytes[i..][0..2], if (big) .big else .little);
}

fn decodeUtf32(allocator: Allocator, bytes: []const u8, big: bool, diagnostic: ?*Diagnostic) Error![]const u8 {
    if (bytes.len % 4 != 0) return invalid(diagnostic, bytes.len - bytes.len % 4, "UTF-32 takes four bytes a character, and this ends with fewer");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len / 2);
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        const raw = std.mem.readInt(u32, bytes[i..][0..4], if (big) .big else .little);
        const point = std.math.cast(u21, raw) orelse return invalid(diagnostic, i, "a UTF-32 code point past U+10FFFF");
        if (point > 0x10FFFF or (point >= 0xD800 and point <= 0xDFFF)) return invalid(diagnostic, i, "a UTF-32 code point that is a surrogate or past U+10FFFF");
        try appendPoint(allocator, &out, point);
    }
    return out.toOwnedSlice(allocator);
}

fn appendPoint(allocator: Allocator, out: *std.ArrayList(u8), point: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(point, &buf) catch unreachable;
    try out.appendSlice(allocator, buf[0..len]);
}
