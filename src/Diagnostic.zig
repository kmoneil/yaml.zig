//! Where reading YAML failed, and why: a mark in the input, a message
//! fixed for each kind of error, and from typed construction the path to
//! the value and a detail naming what the message is about. Its text is
//! in buffers of its own, so it owns nothing and copies as a value. Each
//! stage keeps one, and `ParseOptions.diagnostic` takes one to fill.

const std = @import("std");

const Diagnostic = @This();

/// A place in the input. Lines and columns count from 0, and a column
/// counts characters (code points), not bytes. 32 bits each, as the
/// scanner refuses an input past 4 GiB: a node holds two, and a token
/// and an event two, so their size is the library's memory (t46).
pub const Mark = struct {
    offset: u32 = 0,
    line: u32 = 0,
    column: u32 = 0,
};

mark: Mark = .{},
/// What went wrong, in words fixed for each kind of error.
message: []const u8 = "",
/// Where in the document construction was, as `path` gives it.
path_buffer: [256]u8 = undefined,
path_len: usize = 0,
/// The message with what it is about filled in, as `detail` gives it.
detail_buffer: [512]u8 = undefined,
detail_len: usize = 0,

/// Where in the document typed construction failed, from its root:
/// `machine.types[2]`, a map's key quoted when it is not a plain word.
/// Empty at the root, and for errors before construction.
pub fn path(d: *const Diagnostic) []const u8 {
    return d.path_buffer[0..d.path_len];
}

/// The message with what it names filled in, where construction knows
/// more than the message says: the key no field has and the fields
/// there are, the field missing, what was found where something else was
/// expected. Otherwise the message. It may quote the input, a key and up
/// to 40 bytes of a value found where something else was expected, its
/// control characters escaped: where values may be secret, log `message`
/// and `path`, which quote no value.
pub fn detail(d: *const Diagnostic) []const u8 {
    return if (d.detail_len > 0) d.detail_buffer[0..d.detail_len] else d.message;
}

/// Sets the path, cut short (ending `...`) if it does not fit. Typed
/// construction sets it, and the detail.
pub fn setPath(d: *Diagnostic, comptime format_text: []const u8, args: anytype) void {
    d.path_len = writeCut(&d.path_buffer, format_text, args);
}

/// Sets the detail, cut short (ending `...`) if it does not fit.
pub fn setDetail(d: *Diagnostic, comptime format_text: []const u8, args: anytype) void {
    d.detail_len = writeCut(&d.detail_buffer, format_text, args);
}

/// Writes `line:column: path: detail`, the line and column from 1 and
/// the path left out when empty: a file's name before it makes the line
/// a compiler would print.
pub fn format(d: *const Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d}:{d}: ", .{ d.mark.line + 1, d.mark.column + 1 });
    if (d.path_len > 0) try w.print("{s}: ", .{d.path()});
    try w.writeAll(d.detail());
}

/// Formats into `buffer`, one of the diagnostic's own, ending the text
/// `...` where a character begins when it does not fit; returns its
/// length.
fn writeCut(buffer: []u8, comptime format_text: []const u8, args: anytype) usize {
    var w: std.Io.Writer = .fixed(buffer);
    w.print(format_text, args) catch {
        // Back over the rest of a character the `...` would split.
        var end = buffer.len - 3;
        while (end > 0 and buffer[end] & 0xC0 == 0x80) end -= 1;
        @memcpy(buffer[end..][0..3], "...");
        return end + 3;
    };
    return w.end;
}
