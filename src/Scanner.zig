//! The scanner: YAML text to tokens, the first stage of YAML 1.2.2's
//! pipeline. The parser pulls tokens with `next`.
//!
//! A token can need tokens before it that only something later shows:
//! `a: b` is a key only once the `:` is read, and the first key of a
//! block mapping opens the mapping. So the scanner keeps a queue, and a
//! "simple key" (an implicit key: one line, at most 1024 characters)
//! records where a key may begin until a `:` makes it one, when a `key`
//! token, and in a block a `block_mapping_start`, are put in the queue
//! before it. Block structure is a stack of indentation columns: a line
//! less indented than the current block ends it (`block_end`).
//!
//! The input is UTF-8 (other encodings are decoded before this), whole in
//! memory. A scalar's value is a slice of the input when it is written
//! as it reads (one line, no escapes); otherwise it is built in the
//! scanner's arena, so it lives until `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @This();

/// A place in the input. Lines and columns count from 0, and a column
/// counts characters (code points), not bytes.
pub const Mark = struct {
    offset: usize = 0,
    line: usize = 0,
    column: usize = 0,
};

pub const ScalarStyle = enum { plain, single_quoted, double_quoted, literal, folded };

pub const Token = struct {
    start: Mark,
    end: Mark,
    data: Data,

    pub const Data = union(enum) {
        stream_start,
        stream_end,
        version_directive: Version,
        tag_directive: TagDirective,
        /// `---`
        document_start,
        /// `...`
        document_end,
        block_sequence_start,
        block_mapping_start,
        block_end,
        flow_sequence_start,
        flow_sequence_end,
        flow_mapping_start,
        flow_mapping_end,
        /// `-` in a block sequence.
        block_entry,
        /// `,` between flow entries.
        flow_entry,
        /// What follows is a key: an explicit `?`, or put before a simple
        /// key once its `:` is read.
        key,
        /// `:`
        value,
        alias: []const u8,
        anchor: []const u8,
        tag: Tag,
        scalar: Scalar,
    };

    pub const Version = struct { major: u16, minor: u16 };
    pub const TagDirective = struct { handle: []const u8, prefix: []const u8 };
    pub const Tag = struct { handle: []const u8, suffix: []const u8 };
    pub const Scalar = struct { value: []const u8, style: ScalarStyle };
};

/// Why the last `next` failed with `error.SyntaxError`, and where.
pub const Diagnostic = struct {
    mark: Mark = .{},
    message: []const u8 = "",
};

pub const Error = error{ SyntaxError, OutOfMemory };

/// Where a simple key may begin, one for each flow level.
const SimpleKey = struct {
    possible: bool = false,
    /// A key at the block's indentation must be one: `a` alone on a line
    /// in a mapping is an error, not a scalar.
    required: bool = false,
    /// The key's place in the token stream, counted from the first token.
    token_number: usize = 0,
    mark: Mark = .{},
    /// A tab came before it on its line, so it cannot open a block mapping.
    after_tab: bool = false,
};

/// The longest an implicit key may be, in characters (YAML 1.2.2, 7.4.2).
const max_simple_key_length = 1024;

gpa: Allocator,
input: []const u8,
/// Where the next character is read.
mark: Mark = .{},
/// Scalar values that are not slices of `input`.
arena: std.heap.ArenaAllocator,
/// Tokens scanned and not yet handed out start at `head`.
tokens: std.ArrayList(Token) = .empty,
head: usize = 0,
/// How many tokens `next` has handed out.
tokens_parsed: usize = 0,
stream_start_produced: bool = false,
stream_end_produced: bool = false,
/// The indentation column of the innermost block collection: -1 before
/// the first one.
indent: isize = -1,
indents: std.ArrayList(isize) = .empty,
/// Whether a simple key may begin where the next token does.
simple_key_allowed: bool = false,
/// One for the block context and one for each flow collection open.
simple_keys: std.ArrayList(SimpleKey) = .empty,
flow_level: usize = 0,
/// A tab was in the whitespace just before the next token, on its line.
tab_before: bool = false,
diagnostic: Diagnostic = .{},

pub fn init(gpa: Allocator, input: []const u8) Scanner {
    return .{ .gpa = gpa, .input = input, .arena = .init(gpa) };
}

pub fn deinit(s: *Scanner) void {
    s.tokens.deinit(s.gpa);
    s.indents.deinit(s.gpa);
    s.simple_keys.deinit(s.gpa);
    s.arena.deinit();
    s.* = undefined;
}

/// The next token. After `stream_end`, `stream_end` again. On
/// `error.SyntaxError`, `diagnostic` says what and where; the scanner
/// cannot go on after one.
pub fn next(s: *Scanner) Error!Token {
    if (s.stream_end_produced) return .{ .start = s.mark, .end = s.mark, .data = .stream_end };
    try s.fetchMoreTokens();
    const token = s.tokens.items[s.head];
    s.head += 1;
    s.tokens_parsed += 1;
    if (s.head == s.tokens.items.len) {
        s.tokens.clearRetainingCapacity();
        s.head = 0;
    }
    if (token.data == .stream_end) s.stream_end_produced = true;
    return token;
}

/// Fetches until the token at the head of the queue is settled: there is
/// one, and no possible simple key begins at it.
fn fetchMoreTokens(s: *Scanner) Error!void {
    while (s.head == s.tokens.items.len or try s.keyMayBeginAtHead()) {
        try s.fetchNextToken();
    }
}

fn keyMayBeginAtHead(s: *Scanner) Error!bool {
    try s.staleSimpleKeys();
    for (s.simple_keys.items) |key| {
        if (key.possible and key.token_number == s.tokens_parsed) return true;
    }
    return false;
}

fn fetchNextToken(s: *Scanner) Error!void {
    if (!s.stream_start_produced) return s.fetchStreamStart();
    try s.scanToNextToken();
    try s.staleSimpleKeys();
    try s.unrollIndent(@intCast(s.mark.column));
    if (s.mark.offset >= s.input.len) return s.fetchStreamEnd();
    if (s.mark.column == 0 and try s.fetchLineStartToken()) return;
    return s.fetchByFirstCharacter(s.ch(0));
}

/// Fetches a token only a line's first column can hold: a directive or
/// a document marker. False when there is none.
fn fetchLineStartToken(s: *Scanner) Error!bool {
    if (s.ch(0) == '%') {
        try s.fetchDirective();
    } else if (s.atDocumentMarker("---")) {
        try s.fetchDocumentIndicator(.document_start);
    } else if (s.atDocumentMarker("...")) {
        try s.fetchDocumentIndicator(.document_end);
    } else return false;
    return true;
}

fn fetchByFirstCharacter(s: *Scanner, c: u8) Error!void {
    return switch (c) {
        '[' => s.fetchFlowCollectionStart(.flow_sequence_start),
        '{' => s.fetchFlowCollectionStart(.flow_mapping_start),
        ']' => s.fetchFlowCollectionEnd(.flow_sequence_end),
        '}' => s.fetchFlowCollectionEnd(.flow_mapping_end),
        ',' => s.fetchFlowEntry(),
        '*', '&', '!' => s.fail(s.mark, "anchors, aliases and tags are not supported yet"),
        '|', '>' => s.fetchBlockScalar(),
        '\'', '"' => s.fail(s.mark, "quoted scalars are not supported yet"),
        '-', '?', ':' => s.fetchIndicatorOrPlain(c),
        '#', '@', '`', '%' => s.fail(s.mark, "found a character that cannot start any token"),
        else => s.fetchPlainOrInvalid(),
    };
}

/// `-`, `?` or `:` alone is an indicator; with more after it, the start
/// of a plain scalar.
fn fetchIndicatorOrPlain(s: *Scanner, c: u8) Error!void {
    if (!s.indicatorEnds()) return s.fetchPlainScalar();
    return switch (c) {
        '-' => s.fetchBlockEntry(),
        '?' => s.fetchKey(),
        else => s.fetchValue(),
    };
}

fn fetchPlainOrInvalid(s: *Scanner) Error!void {
    if (!isPrintable(s.input, s.mark.offset)) return s.fail(s.mark, "found a character that is not allowed in YAML");
    return s.fetchPlainScalar();
}

fn fetchBlockScalar(s: *Scanner) Error!void {
    if (s.flow_level > 0) return s.fail(s.mark, "found a character that cannot start any token");
    return s.fail(s.mark, "block scalars are not supported yet");
}

/// Whether the indicator at the next character stands alone: a blank,
/// a line break or the end follows it, or in a flow collection a flow
/// indicator does. Otherwise `-`, `?` and `:` start a plain scalar.
fn indicatorEnds(s: *const Scanner) bool {
    const c = s.ch(1);
    return isBlankOrBreakOrEnd(c) or (s.flow_level > 0 and isFlowIndicator(c));
}

// Tokens

fn fetchStreamStart(s: *Scanner) Error!void {
    s.indent = -1;
    s.simple_key_allowed = true;
    s.stream_start_produced = true;
    try s.simple_keys.append(s.gpa, .{});
    // A byte order mark may open the stream (YAML 1.2.2, 5.2).
    if (std.mem.startsWith(u8, s.input, "\xEF\xBB\xBF")) s.mark.offset = 3;
    try s.append(.stream_start, s.mark, s.mark);
}

fn fetchStreamEnd(s: *Scanner) Error!void {
    // The end ends every open block, and a last line with no line break.
    if (s.mark.column != 0) {
        s.mark.column = 0;
        s.mark.line += 1;
    }
    try s.unrollIndent(-1);
    try s.removeSimpleKey();
    s.simple_key_allowed = false;
    try s.append(.stream_end, s.mark, s.mark);
}

fn fetchDirective(s: *Scanner) Error!void {
    return s.fail(s.mark, "directives are not supported yet");
}

fn fetchDocumentIndicator(s: *Scanner, data: Token.Data) Error!void {
    try s.unrollIndent(-1);
    try s.removeSimpleKey();
    s.simple_key_allowed = false;
    const start = s.mark;
    s.skipN(3);
    try s.append(data, start, s.mark);
}

fn fetchFlowCollectionStart(s: *Scanner, data: Token.Data) Error!void {
    // The collection may be a simple key: `[a, b]: c`.
    try s.saveSimpleKey();
    try s.simple_keys.append(s.gpa, .{});
    s.flow_level += 1;
    s.simple_key_allowed = true;
    try s.appendIndicator(data);
}

fn fetchFlowCollectionEnd(s: *Scanner, data: Token.Data) Error!void {
    try s.removeSimpleKey();
    if (s.flow_level > 0) {
        s.flow_level -= 1;
        _ = s.simple_keys.pop();
    }
    s.simple_key_allowed = false;
    try s.appendIndicator(data);
}

fn fetchFlowEntry(s: *Scanner) Error!void {
    try s.removeSimpleKey();
    s.simple_key_allowed = true;
    try s.appendIndicator(.flow_entry);
}

fn fetchBlockEntry(s: *Scanner) Error!void {
    if (s.flow_level == 0) {
        if (!s.simple_key_allowed) return s.fail(s.mark, "a block sequence entry is not allowed here");
        try s.rollIndent(s.mark.column, null, .block_sequence_start, s.mark, s.tab_before);
    }
    // In a flow collection the parser reports the `-`.
    try s.removeSimpleKey();
    s.simple_key_allowed = true;
    try s.appendIndicator(.block_entry);
}

fn fetchKey(s: *Scanner) Error!void {
    if (s.flow_level == 0) {
        if (!s.simple_key_allowed) return s.fail(s.mark, "a mapping key is not allowed here");
        try s.rollIndent(s.mark.column, null, .block_mapping_start, s.mark, s.tab_before);
    }
    try s.removeSimpleKey();
    s.simple_key_allowed = s.flow_level == 0;
    try s.appendIndicator(.key);
}

fn fetchValue(s: *Scanner) Error!void {
    const key = &s.simple_keys.items[s.simple_keys.items.len - 1];
    if (key.possible) {
        // What began at the key's mark is a key: put `key` before it, and
        // open a block mapping if this is its first.
        try s.insert(key.token_number - s.tokens_parsed, .{ .start = key.mark, .end = key.mark, .data = .key });
        try s.rollIndent(key.mark.column, key.token_number, .block_mapping_start, key.mark, key.after_tab);
        key.possible = false;
        s.simple_key_allowed = false;
    } else {
        // A value with no key before it, as after `? a` on the line above.
        if (s.flow_level == 0) {
            if (!s.simple_key_allowed) return s.fail(s.mark, "a mapping value is not allowed here");
            try s.rollIndent(s.mark.column, null, .block_mapping_start, s.mark, s.tab_before);
        }
        s.simple_key_allowed = s.flow_level == 0;
    }
    try s.appendIndicator(.value);
}

fn fetchPlainScalar(s: *Scanner) Error!void {
    try s.saveSimpleKey();
    s.simple_key_allowed = false;
    const token = try s.scanPlainScalar();
    try s.tokens.append(s.gpa, token);
}

/// Appends a one-character indicator token and moves past it.
fn appendIndicator(s: *Scanner, data: Token.Data) Error!void {
    const start = s.mark;
    s.skip();
    try s.append(data, start, s.mark);
}

fn append(s: *Scanner, data: Token.Data, start: Mark, end: Mark) Error!void {
    try s.tokens.append(s.gpa, .{ .start = start, .end = end, .data = data });
}

/// Puts `token` `ahead` places after the head of the queue.
fn insert(s: *Scanner, ahead: usize, token: Token) Error!void {
    try s.tokens.insert(s.gpa, s.head + ahead, token);
}

// Indentation

/// Opens a block collection at `column` if it is deeper than the current
/// one: pushes the indentation and puts `data` at token `number` (or at
/// the end of the queue). A tab before the collection's first token would
/// be indentation, which YAML allows only spaces for.
fn rollIndent(s: *Scanner, column: usize, number: ?usize, data: Token.Data, mark: Mark, after_tab: bool) Error!void {
    if (s.flow_level > 0) return;
    const col: isize = @intCast(column);
    if (s.indent >= col) return;
    if (after_tab) return s.fail(mark, "a tab character cannot indent a block collection");
    try s.indents.append(s.gpa, s.indent);
    s.indent = col;
    const token: Token = .{ .start = mark, .end = mark, .data = data };
    if (number) |n| {
        try s.insert(n - s.tokens_parsed, token);
    } else {
        try s.tokens.append(s.gpa, token);
    }
}

/// Ends each block collection more indented than `column`.
fn unrollIndent(s: *Scanner, column: isize) Error!void {
    if (s.flow_level > 0) return;
    while (s.indent > column) {
        try s.append(.block_end, s.mark, s.mark);
        s.indent = s.indents.pop() orelse -1;
    }
}

// Simple keys

/// Records that a simple key may begin at the next token.
fn saveSimpleKey(s: *Scanner) Error!void {
    if (!s.simple_key_allowed) return;
    try s.removeSimpleKey();
    s.simple_keys.items[s.simple_keys.items.len - 1] = .{
        .possible = true,
        .required = s.flow_level == 0 and s.indent == @as(isize, @intCast(s.mark.column)),
        .token_number = s.tokens_parsed + s.tokens.items.len - s.head,
        .mark = s.mark,
        .after_tab = s.tab_before,
    };
}

/// Drops the possible simple key of the current flow level: what comes
/// next cannot be its `:`.
fn removeSimpleKey(s: *Scanner) Error!void {
    const key = &s.simple_keys.items[s.simple_keys.items.len - 1];
    if (key.possible and key.required) return s.fail(key.mark, "could not find the ':' this key needs");
    key.possible = false;
}

/// Drops each possible simple key the next token can no longer end: one
/// on an earlier line, or more than 1024 characters back.
fn staleSimpleKeys(s: *Scanner) Error!void {
    for (s.simple_keys.items) |*key| {
        if (!key.possible) continue;
        if (key.mark.line == s.mark.line and s.mark.column - key.mark.column <= max_simple_key_length) continue;
        if (key.required) return s.fail(key.mark, "could not find the ':' this key needs");
        key.possible = false;
    }
}

// Whitespace and comments

/// Moves past the blanks, comments and line breaks before the next token.
fn scanToNextToken(s: *Scanner) Error!void {
    while (true) {
        try s.skipSeparation();
        if (s.ch(0) == '#') try s.skipComment();
        if (!isBreak(s.ch(0))) return;
        s.skipBreak();
        if (s.flow_level == 0) s.simple_key_allowed = true;
    }
}

/// Skips spaces and tabs, noting a tab in `tab_before`. A tab separates
/// tokens anywhere, but in a block it cannot stand in a line's
/// indentation: before the spaces reach past the current block's column,
/// a tab may lead only a line that holds nothing but a comment.
fn skipSeparation(s: *Scanner) Error!void {
    const line_start = s.mark.column == 0;
    s.tab_before = false;
    while (s.ch(0) == ' ') s.skip();
    if (s.ch(0) != '\t') return;
    const spaces: isize = @intCast(s.mark.column);
    s.tab_before = true;
    while (isBlank(s.ch(0))) s.skip();
    if (!line_start or s.flow_level > 0 or spaces > s.indent) return;
    const c = s.ch(0);
    if (isBreakOrEnd(c) or c == '#') return;
    // A flow collection may follow: it opens no block.
    if (c == '[' or c == '{') return;
    return s.fail(s.mark, "a tab character cannot indent a block");
}

/// Skips a comment to its line break. A comment needs whitespace before
/// it: `a#b` is a plain scalar, and `"a"#b` is an error.
fn skipComment(s: *Scanner) Error!void {
    if (s.mark.offset > 0 and !isBlankOrBreak(s.input[s.mark.offset - 1])) {
        return s.fail(s.mark, "a comment must be separated from what comes before it by whitespace");
    }
    while (!isBreakOrEnd(s.ch(0))) s.skip();
}

// Plain scalars

/// Scans a plain scalar: its lines folded into one value, a single line
/// break between two lines read as a space and each further one kept.
/// In a block, a line less indented than the block's content ends it.
fn scanPlainScalar(s: *Scanner) Error!Token {
    const start = s.mark;
    var end = s.mark;
    var folded: std.ArrayList(u8) = .empty;
    const arena = s.arena.allocator();
    var breaks: usize = 0;
    var line_start = s.mark.offset;
    s.scanPlainLine(&end);
    const first_line = s.input[start.offset..end.offset];
    while (true) {
        if (breaks > 0) {
            s.scanPlainLine(&end);
            try appendFolded(arena, &folded, first_line, breaks, s.input[line_start..end.offset]);
        }
        breaks = try s.skipPlainBreaks(&line_start);
        if (breaks == 0 or !s.plainContinues()) break;
    }
    if (breaks > 0) s.simple_key_allowed = true;
    const value = if (folded.items.len > 0) folded.items else first_line;
    return .{ .start = start, .end = end, .data = .{ .scalar = .{ .value = value, .style = .plain } } };
}

/// Moves over one line of a plain scalar, its words and the blanks
/// between them, and sets `end` after its last word.
fn scanPlainLine(s: *Scanner, end: *Mark) void {
    while (true) {
        while (!isBlankOrBreakOrEnd(s.ch(0)) and !s.plainEndsHere()) s.skip();
        end.* = s.mark;
        while (isBlank(s.ch(0))) s.skip();
        // A blank and then `#` starts a comment.
        if (isBreakOrEnd(s.ch(0)) or s.ch(0) == '#' or s.plainEndsHere()) return;
    }
}

/// Whether the next character ends a plain scalar within its line: a `:`
/// a value follows, or in a flow collection a flow indicator.
fn plainEndsHere(s: *const Scanner) bool {
    const c = s.ch(0);
    if (c == ':') return s.indicatorEnds();
    return s.flow_level > 0 and isFlowIndicator(c);
}

/// Skips the line breaks after a plain scalar's line and the
/// indentation after each, and returns how many; `line_start` is where
/// the next line's content begins. Zero when the line did not end in a
/// break.
fn skipPlainBreaks(s: *Scanner, line_start: *usize) Error!usize {
    var breaks: usize = 0;
    while (isBreak(s.ch(0))) {
        s.skipBreak();
        breaks += 1;
        while (s.ch(0) == ' ') s.skip();
        try s.skipTabInIndentation();
        while (isBlank(s.ch(0))) s.skip();
    }
    line_start.* = s.mark.offset;
    return breaks;
}

/// Skips the blanks from a tab in a block's indentation, where only an
/// empty line or a comment may follow one.
fn skipTabInIndentation(s: *Scanner) Error!void {
    if (s.ch(0) != '\t' or s.flow_level > 0) return;
    if (@as(isize, @intCast(s.mark.column)) > s.indent) return;
    while (isBlank(s.ch(0))) s.skip();
    if (isBreakOrEnd(s.ch(0)) or s.ch(0) == '#') return;
    return s.fail(s.mark, "a tab character cannot indent a block");
}

/// Whether the line the scanner is at continues a plain scalar.
fn plainContinues(s: *const Scanner) bool {
    if (s.mark.offset >= s.input.len or s.ch(0) == '#') return false;
    if (s.mark.column == 0 and (s.atDocumentMarker("---") or s.atDocumentMarker("..."))) return false;
    if (s.flow_level == 0 and @as(isize, @intCast(s.mark.column)) <= s.indent) return false;
    return !s.plainEndsHere();
}

/// Appends a plain scalar's next line to its value, the line breaks
/// before it folded: one is a space, and each after the first a line
/// feed. `first` is the value's first line, copied in if `folded` is
/// still empty.
fn appendFolded(arena: Allocator, folded: *std.ArrayList(u8), first: []const u8, breaks: usize, line: []const u8) Error!void {
    if (folded.items.len == 0) try folded.appendSlice(arena, first);
    if (breaks == 1) {
        try folded.append(arena, ' ');
    } else {
        try folded.appendNTimes(arena, '\n', breaks - 1);
    }
    try folded.appendSlice(arena, line);
}

// Reading

/// The byte `ahead` places past the next one, or 0 past the end.
fn ch(s: *const Scanner, ahead: usize) u8 {
    const i = s.mark.offset + ahead;
    return if (i < s.input.len) s.input[i] else 0;
}

/// Whether a document marker (`---` or `...`) begins here, a blank, line
/// break or the end after it.
fn atDocumentMarker(s: *const Scanner, marker: []const u8) bool {
    if (!std.mem.startsWith(u8, s.input[s.mark.offset..], marker)) return false;
    return isBlankOrBreakOrEnd(s.ch(3));
}

/// Moves past one character (not a line break).
fn skip(s: *Scanner) void {
    s.mark.offset = @min(s.mark.offset + utf8Length(s.ch(0)), s.input.len);
    s.mark.column += 1;
}

fn skipN(s: *Scanner, n: usize) void {
    for (0..n) |_| s.skip();
}

/// Moves past a line break: `\r\n`, `\n` or `\r`.
fn skipBreak(s: *Scanner) void {
    s.mark.offset += if (s.ch(0) == '\r' and s.ch(1) == '\n') 2 else 1;
    s.mark.line += 1;
    s.mark.column = 0;
}

fn fail(s: *Scanner, mark: Mark, message: []const u8) error{SyntaxError} {
    s.diagnostic = .{ .mark = mark, .message = message };
    return error.SyntaxError;
}

// Characters

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isBreak(c: u8) bool {
    return c == '\n' or c == '\r';
}

/// 0 stands for the end of the input.
fn isBreakOrEnd(c: u8) bool {
    return isBreak(c) or c == 0;
}

fn isBlankOrBreak(c: u8) bool {
    return isBlank(c) or isBreak(c);
}

fn isBlankOrBreakOrEnd(c: u8) bool {
    return isBlankOrBreak(c) or c == 0;
}

fn isFlowIndicator(c: u8) bool {
    return switch (c) {
        ',', '[', ']', '{', '}' => true,
        else => false,
    };
}

/// How many bytes the UTF-8 sequence starting with `c` takes; 1 for a
/// byte that cannot start one, so the scanner always moves.
fn utf8Length(c: u8) usize {
    return std.unicode.utf8ByteSequenceLength(c) catch 1;
}

/// Whether the character at `offset` is printable as YAML has it
/// (c-printable, 5.1): tab, line breaks and the printable ASCII, and
/// past ASCII all but the surrogates and U+FFFE, U+FFFF.
pub fn isPrintable(input: []const u8, offset: usize) bool {
    const c = input[offset];
    if (c < 0x80) return c == '\t' or c == '\n' or c == '\r' or (c >= 0x20 and c != 0x7F);
    const len = std.unicode.utf8ByteSequenceLength(c) catch return false;
    if (offset + len > input.len) return false;
    const cp = std.unicode.utf8Decode(input[offset..][0..len]) catch return false;
    return switch (cp) {
        0x80...0x84, 0x86...0x9F, 0xD800...0xDFFF, 0xFFFE, 0xFFFF => false,
        else => true,
    };
}
