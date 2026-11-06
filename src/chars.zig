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
