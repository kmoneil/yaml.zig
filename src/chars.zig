//! The characters YAML's syntax turns on (YAML 1.2.2, chapter 5), for
//! the scanner and the emitter alike. Not part of the package's API.

const std = @import("std");

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn isBreak(c: u8) bool {
    return c == '\n' or c == '\r';
}

pub fn isBlankOrBreak(c: u8) bool {
    return isBlank(c) or isBreak(c);
}

/// `,`, `[`, `]`, `{` and `}`, which end a plain scalar, an anchor's name
/// or a tag in a flow collection.
pub fn isFlowIndicator(c: u8) bool {
    return switch (c) {
        ',', '[', ']', '{', '}' => true,
        else => false,
    };
}

/// Whether the character at `offset` is one YAML allows in text (nb-char
/// and the line breaks, 5.1 and 5.4): tab, line breaks and the printable
/// ASCII, and past ASCII all but the C1 controls but NEL, the
/// surrogates, U+FFFE, U+FFFF, and the byte order mark U+FEFF, which
/// only a document's start may hold.
pub fn isPrintable(input: []const u8, offset: usize) bool {
    const c = input[offset];
    if (c < 0x80) return c == '\t' or c == '\n' or c == '\r' or (c >= 0x20 and c != 0x7F);
    const len = std.unicode.utf8ByteSequenceLength(c) catch return false;
    if (offset + len > input.len) return false;
    const cp = std.unicode.utf8Decode(input[offset..][0..len]) catch return false;
    return switch (cp) {
        0x80...0x84, 0x86...0x9F, 0xD800...0xDFFF, 0xFEFF, 0xFFFE, 0xFFFF => false,
        else => true,
    };
}

/// 16 bytes at once: NEON on arm64, SSE2 on x86_64.
pub const Block = @Vector(16, u8);

/// The index of the first byte from `start` that is one of `stops`, or
/// `text.len` (t75).
pub fn findAnyOf(text: []const u8, start: usize, comptime stops: []const u8) usize {
    const S = struct {
        const table = stopTable(stops, false);
        fn inBlock(block: Block) @Vector(16, bool) {
            var hit: @Vector(16, bool) = @splat(false);
            inline for (stops) |s| hit = hit | (block == @as(Block, @splat(s)));
            return hit;
        }
    };
    return findStop(text, start, S.table, S.inBlock);
}

/// The index of the first byte from `start` that is not printable ASCII
/// (a control, DEL, or past ASCII) or is one of `stops`, or `text.len`
/// (t75).
pub fn findOutsideAscii(text: []const u8, start: usize, comptime stops: []const u8) usize {
    const S = struct {
        const table = stopTable(stops, true);
        fn inBlock(block: Block) @Vector(16, bool) {
            var hit = (block < @as(Block, @splat(0x20))) | (block >= @as(Block, @splat(0x7F)));
            inline for (stops) |s| hit = hit | (block == @as(Block, @splat(s)));
            return hit;
        }
    };
    return findStop(text, start, S.table, S.inBlock);
}

/// The first index from `start` of a byte `stop` holds, or `text.len`: a
/// block of 16 at once by `inBlock` while 16 are left, the rest a byte at
/// a time.
fn findStop(text: []const u8, start: usize, comptime stop: [256]bool, comptime inBlock: fn (Block) @Vector(16, bool)) usize {
    var i = start;
    while (i + 16 <= text.len) : (i += 16) {
        if (std.simd.firstTrue(inBlock(text[i..][0..16].*))) |k| return i + k;
    }
    while (i < text.len and !stop[text[i]]) i += 1;
    return i;
}

/// Which bytes stop a search: `stops`, and if `outside_ascii` the
/// controls, DEL and every byte past ASCII.
fn stopTable(comptime stops: []const u8, comptime outside_ascii: bool) [256]bool {
    var table: [256]bool = @splat(false);
    if (outside_ascii) {
        for (0..0x20) |c| table[c] = true;
        for (0x7F..0x100) |c| table[c] = true;
    }
    for (stops) |c| table[c] = true;
    return table;
}

/// The code points in `text`, which is UTF-8: its bytes but the
/// continuation bytes. A loop the compiler turns into vector code.
pub fn pointCount(text: []const u8) usize {
    var n: usize = text.len;
    for (text) |c| n -= @intFromBool(c & 0xC0 == 0x80);
    return n;
}
