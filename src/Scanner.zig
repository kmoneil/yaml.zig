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
    /// `%TAG handle prefix`; the prefix with its `%` escapes decoded.
    pub const TagDirective = struct { handle: []const u8, prefix: []const u8 };
    /// A node's tag, its `%` escapes decoded: `!` and an empty suffix is
    /// the non-specific tag; an empty handle is a verbatim one, `!<...>`,
    /// whose suffix is the whole tag.
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
        '&' => s.fetchAnchor(.anchor),
        '*' => s.fetchAnchor(.alias),
        '!' => s.fetchTag(),
        '|', '>' => s.fetchBlockScalar(),
        '\'' => s.fetchQuotedScalar(.single_quoted),
        '"' => s.fetchQuotedScalar(.double_quoted),
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
    try s.removeSimpleKey();
    s.simple_key_allowed = true;
    const token = try s.scanBlockScalar(if (s.ch(0) == '|') .literal else .folded);
    try s.tokens.append(s.gpa, token);
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

/// Fetches a directive: `%YAML`, `%TAG`, or one YAML reserves, which is
/// skipped (YAML 1.2.2, 6.8).
fn fetchDirective(s: *Scanner) Error!void {
    try s.unrollIndent(-1);
    try s.removeSimpleKey();
    s.simple_key_allowed = false;
    const start = s.mark;
    s.skip();
    const name_start = s.mark.offset;
    while (!isBlankOrBreakOrEnd(s.ch(0))) s.skip();
    const name = s.input[name_start..s.mark.offset];
    if (name.len == 0) return s.fail(start, "a directive needs a name after its %");
    const data: Token.Data = if (std.mem.eql(u8, name, "YAML"))
        .{ .version_directive = try s.scanVersion() }
    else if (std.mem.eql(u8, name, "TAG"))
        .{ .tag_directive = try s.scanTagDirective() }
    else {
        while (!isBreakOrEnd(s.ch(0))) s.skip();
        return;
    };
    const end = s.mark;
    try s.skipDirectiveEnd();
    try s.append(data, start, end);
}

/// After a directive's last parameter, only blanks and a comment.
fn skipDirectiveEnd(s: *Scanner) Error!void {
    while (isBlank(s.ch(0))) s.skip();
    if (s.ch(0) == '#') try s.skipComment();
    if (!isBreakOrEnd(s.ch(0))) return s.fail(s.mark, "a directive's line holds more than its parameters and a comment");
}

/// `%YAML`'s parameter: blanks, then a major and a minor number.
fn scanVersion(s: *Scanner) Error!Token.Version {
    try s.skipDirectiveSeparation();
    const major = try s.scanVersionNumber();
    if (s.ch(0) != '.') return s.fail(s.mark, "a YAML version needs a '.' between its numbers");
    s.skip();
    return .{ .major = major, .minor = try s.scanVersionNumber() };
}

fn scanVersionNumber(s: *Scanner) Error!u16 {
    const start = s.mark;
    var n: u16 = 0;
    while (std.ascii.isDigit(s.ch(0))) {
        n = std.math.mul(u16, n, 10) catch return s.fail(start, "a YAML version number is too long");
        n += s.ch(0) - '0';
        s.skip();
    }
    if (s.mark.offset == start.offset) return s.fail(start, "a YAML version needs a number here");
    return n;
}

/// `%TAG`'s parameters: a handle and the prefix it stands for.
fn scanTagDirective(s: *Scanner) Error!Token.TagDirective {
    try s.skipDirectiveSeparation();
    const handle_start = s.mark;
    if (s.ch(0) != '!') return s.fail(s.mark, "a %TAG directive needs a handle, as ! or !! or !name!");
    s.skip();
    s.skipTagHandleRest();
    const handle = s.input[handle_start.offset..s.mark.offset];
    if (handle.len > 1 and handle[handle.len - 1] != '!') return s.fail(handle_start, "a %TAG directive needs a handle, as ! or !! or !name!");
    try s.skipDirectiveSeparation();
    // A prefix is a local tag's `!...`, or a URI, which cannot start with
    // a flow indicator.
    const prefix_start = s.mark;
    if (isFlowIndicator(s.ch(0))) return s.fail(s.mark, "a %TAG prefix cannot start with a flow indicator");
    const prefix = try s.scanUri(.uri);
    if (prefix.len == 0) return s.fail(prefix_start, "a %TAG directive needs a prefix after its handle");
    return .{ .handle = handle, .prefix = prefix };
}

fn skipDirectiveSeparation(s: *Scanner) Error!void {
    if (!isBlank(s.ch(0))) return s.fail(s.mark, "a directive's parameters must be separated by blanks");
    while (isBlank(s.ch(0))) s.skip();
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

const AnchorKind = enum { anchor, alias };

/// Fetches `&name` or `*name`. A name runs to a blank, a line break or a
/// flow indicator, so `&a:` is named `a:` (YAML 1.2.2, 6.9.2).
fn fetchAnchor(s: *Scanner, kind: AnchorKind) Error!void {
    try s.saveSimpleKey();
    s.simple_key_allowed = false;
    const start = s.mark;
    s.skip();
    const name_start = s.mark.offset;
    while (s.atAnchorCharacter()) s.skip();
    const name = s.input[name_start..s.mark.offset];
    if (name.len == 0) return s.fail(start, "an anchor or alias needs a name");
    try s.expectPropertyEnd();
    try s.append(switch (kind) {
        .anchor => .{ .anchor = name },
        .alias => .{ .alias = name },
    }, start, s.mark);
}

fn atAnchorCharacter(s: *const Scanner) bool {
    const c = s.ch(0);
    if (isBlankOrBreakOrEnd(c) or isFlowIndicator(c)) return false;
    return isPrintable(s.input, s.mark.offset);
}

/// A node's property (an anchor or a tag) or an alias ends at a blank, a
/// line break or the end, or in a flow collection a flow indicator.
fn expectPropertyEnd(s: *Scanner) Error!void {
    const c = s.ch(0);
    if (isBlankOrBreakOrEnd(c) or (s.flow_level > 0 and isFlowIndicator(c))) return;
    return s.fail(s.mark, "an anchor, alias or tag must be followed by whitespace");
}

/// Fetches a tag (YAML 1.2.2, 6.9.1): verbatim `!<uri>`, a shorthand
/// `!suffix`, `!!suffix` or `!name!suffix`, or the non-specific `!`.
fn fetchTag(s: *Scanner) Error!void {
    try s.saveSimpleKey();
    s.simple_key_allowed = false;
    const start = s.mark;
    const tag = if (s.ch(1) == '<') try s.scanVerbatimTag() else try s.scanShorthandTag();
    try s.expectPropertyEnd();
    try s.append(.{ .tag = tag }, start, s.mark);
}

fn scanVerbatimTag(s: *Scanner) Error!Token.Tag {
    const start = s.mark;
    s.skipN(2);
    const uri = try s.scanUri(.uri);
    if (uri.len == 0 or s.ch(0) != '>') return s.fail(start, "a verbatim tag needs a URI and a '>' after it");
    s.skip();
    return .{ .handle = "", .suffix = uri };
}

fn scanShorthandTag(s: *Scanner) Error!Token.Tag {
    const start = s.mark;
    s.skip();
    if (s.atPropertyEnd()) return .{ .handle = "!", .suffix = "" };
    s.skipTagHandleRest();
    var handle = s.input[start.offset..s.mark.offset];
    if (handle.len > 1 and handle[handle.len - 1] != '!') {
        // `!word` with no `!` after it: the primary handle and a suffix.
        s.mark = start;
        s.skip();
        handle = "!";
    }
    const suffix = try s.scanUri(.tag_suffix);
    if (suffix.len == 0) return s.fail(start, "a tag needs a suffix after its handle");
    return .{ .handle = handle, .suffix = suffix };
}

/// Whether a blank, a line break, the end, or in a flow a flow indicator
/// comes next.
fn atPropertyEnd(s: *const Scanner) bool {
    const c = s.ch(0);
    return isBlankOrBreakOrEnd(c) or (s.flow_level > 0 and isFlowIndicator(c));
}

/// Skips what follows a tag handle's first `!`: a second `!`, or a word
/// and the `!` after it. Without that `!`, skips the word alone.
fn skipTagHandleRest(s: *Scanner) void {
    if (s.ch(0) == '!') return s.skip();
    while (std.ascii.isAlphanumeric(s.ch(0)) or s.ch(0) == '-') s.skip();
    if (s.ch(0) == '!') s.skip();
}

const UriKind = enum {
    /// A tag shorthand's suffix: no `!` and no flow indicator.
    tag_suffix,
    uri,
};

/// Scans URI characters, decoding `%` escapes; the value is a slice of
/// the input when there are none. Stops at the first other character.
fn scanUri(s: *Scanner, kind: UriKind) Error![]const u8 {
    const start = s.mark.offset;
    var escapes = false;
    while (true) {
        const c = s.ch(0);
        if (c == '%') {
            if (!std.ascii.isHex(s.ch(1)) or !std.ascii.isHex(s.ch(2))) return s.fail(s.mark, "a % in a tag needs two hex digits after it");
            escapes = true;
            s.skipN(3);
        } else if (isUriCharacter(c) and !(kind == .tag_suffix and (c == '!' or isFlowIndicator(c)))) {
            s.skip();
        } else break;
    }
    const text = s.input[start..s.mark.offset];
    return if (escapes) s.decodeUri(text) else text;
}

/// `text` with each `%` escape replaced by its byte, in the arena.
fn decodeUri(s: *Scanner, text: []const u8) Error![]const u8 {
    const decoded = try s.arena.allocator().alloc(u8, text.len);
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (len += 1) {
        if (text[i] == '%') {
            // scanUri checked the two hex digits.
            decoded[len] = @intCast(parseHex(text[i + 1 ..][0..2]) orelse unreachable);
            i += 3;
        } else {
            decoded[len] = text[i];
            i += 1;
        }
    }
    if (!std.unicode.utf8ValidateSlice(decoded[0..len])) return s.fail(s.mark, "a tag's % escapes do not spell UTF-8");
    return decoded[0..len];
}

/// ns-uri-char (YAML 1.2.2, 5.6), but for `%`, which `scanUri` reads.
fn isUriCharacter(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return std.mem.indexOfScalar(u8, "-#;/?:@&=+$,_.!~*'()[]", c) != null;
}

fn fetchQuotedScalar(s: *Scanner, style: ScalarStyle) Error!void {
    try s.saveSimpleKey();
    s.simple_key_allowed = false;
    const token = try s.scanQuotedScalar(style);
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
    if (s.atDocumentMarkerLine()) return false;
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

// Quoted scalars

/// How a quoted scalar's run of text ended.
const TextEnd = enum { quote, blank, escaped_break };

/// Scans a single- or double-quoted scalar (YAML 1.2.2, 7.3). Between
/// lines it folds as a plain scalar does, dropping the blanks around
/// each break; in a double-quoted one an escape is read, and a `\` at
/// the end of a line joins it to the next with nothing between.
fn scanQuotedScalar(s: *Scanner, style: ScalarStyle) Error!Token {
    const start = s.mark;
    const quote = s.ch(0);
    s.skip();
    const value: []const u8 = if (s.quotedAsWritten(quote)) |len| as_written: {
        const text = s.input[s.mark.offset..][0..len];
        s.mark.offset += len;
        s.mark.column += std.unicode.utf8CountCodepoints(text) catch unreachable;
        break :as_written text;
    } else try s.scanQuotedValue(quote, start);
    s.skip();
    return .{ .start = start, .end = s.mark, .data = .{ .scalar = .{ .value = value, .style = style } } };
}

/// How many bytes lie between the opening quote and the closing one when
/// the value is them as written: one line, valid UTF-8, no escape and no
/// control character. Null when the value must be built.
fn quotedAsWritten(s: *const Scanner, quote: u8) ?usize {
    const rest = s.input[s.mark.offset..];
    const len = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
    const text = rest[0..len];
    if (quote == '\'' and len + 1 < rest.len and rest[len + 1] == '\'') return null;
    if (quote == '"' and std.mem.indexOfScalar(u8, text, '\\') != null) return null;
    if (hasControl(text) or !std.unicode.utf8ValidateSlice(text)) return null;
    return len;
}

/// Whether `text` holds a control character other than a tab; a line
/// break is one.
fn hasControl(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 and c != '\t') return true;
    }
    return false;
}

/// Builds a quoted scalar's value in the arena, up to its closing quote.
fn scanQuotedValue(s: *Scanner, quote: u8, start: Mark) Error![]const u8 {
    const arena = s.arena.allocator();
    var value: std.ArrayList(u8) = .empty;
    while (true) {
        const ending = try s.scanQuotedText(arena, &value, quote, start);
        if (ending == .quote) return value.items;
        try s.scanQuotedBlanks(arena, &value, ending == .escaped_break, start);
    }
}

/// Scans a quoted scalar's text up to a blank, a line break or the
/// closing quote, unescaping as it goes.
fn scanQuotedText(s: *Scanner, arena: Allocator, value: *std.ArrayList(u8), quote: u8, start: Mark) Error!TextEnd {
    while (true) {
        if (s.mark.offset >= s.input.len) return s.fail(start, "found the end of the input inside a quoted scalar");
        const c = s.ch(0);
        if (isBlankOrBreak(c)) return .blank;
        // In a single-quoted scalar, '' is a quote and not the end.
        if (c == quote and !(quote == '\'' and s.ch(1) == '\'')) return .quote;
        if (c == '\\' and quote == '"' and isBreak(s.ch(1))) {
            s.skip();
            return .escaped_break;
        }
        try s.scanQuotedCharacter(arena, value, quote);
    }
}

/// Appends the value of the character, escape or `''` at the next
/// character.
fn scanQuotedCharacter(s: *Scanner, arena: Allocator, value: *std.ArrayList(u8), quote: u8) Error!void {
    if (s.ch(0) == '\'' and quote == '\'') {
        try value.append(arena, '\'');
        s.skipN(2);
    } else if (s.ch(0) == '\\' and quote == '"') {
        try s.scanEscape(arena, value);
    } else {
        try s.appendQuotedCharacter(arena, value);
    }
}

/// Appends the next character, which must be one JSON allows in a string:
/// a tab, or any from the space on.
fn appendQuotedCharacter(s: *Scanner, arena: Allocator, value: *std.ArrayList(u8)) Error!void {
    const at = s.mark.offset;
    const len = utf8Length(s.input[at]);
    const ok = s.input[at] >= 0x20 and at + len <= s.input.len and std.unicode.utf8ValidateSlice(s.input[at..][0..len]);
    if (!ok) return s.fail(s.mark, "found a character that is not allowed in a quoted scalar");
    try value.appendSlice(arena, s.input[at..][0..len]);
    s.skip();
}

/// Reads an escape at the next character, a `\`, and appends what it
/// stands for.
fn scanEscape(s: *Scanner, arena: Allocator, value: *std.ArrayList(u8)) Error!void {
    const mark = s.mark;
    const c = s.ch(1);
    if (escaped(c)) |bytes| {
        try value.appendSlice(arena, bytes);
        s.skipN(2);
        return;
    }
    const digits: usize = switch (c) {
        'x' => 2,
        'u' => 4,
        'U' => 8,
        else => return s.fail(mark, "found an unknown escape in a double-quoted scalar"),
    };
    s.skipN(2);
    const hex = s.input[s.mark.offset..][0..@min(digits, s.input.len - s.mark.offset)];
    const code = parseHex(hex) orelse return s.fail(mark, "an escape needs as many hex digits as its letter says");
    if (hex.len < digits) return s.fail(mark, "an escape needs as many hex digits as its letter says");
    const point = std.math.cast(u21, code) orelse return s.fail(mark, "an escape names no Unicode character");
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(point, &buf) catch return s.fail(mark, "an escape names no Unicode character");
    try value.appendSlice(arena, buf[0..len]);
    s.skipN(digits);
}

/// The number `hex` spells in hex digits alone (no sign, no `_`).
fn parseHex(hex: []const u8) ?u32 {
    var code: u32 = 0;
    for (hex) |c| code = code * 16 + (std.fmt.charToDigit(c, 16) catch return null);
    return code;
}

/// What an escape of one letter after `\` stands for (YAML 1.2.2, 5.7).
fn escaped(c: u8) ?[]const u8 {
    return switch (c) {
        '0' => "\x00",
        'a' => "\x07",
        'b' => "\x08",
        't', '\t' => "\t",
        'n' => "\n",
        'v' => "\x0B",
        'f' => "\x0C",
        'r' => "\r",
        'e' => "\x1B",
        ' ' => " ",
        '"' => "\"",
        '/' => "/",
        '\\' => "\\",
        'N' => "\u{85}",
        '_' => "\u{A0}",
        'L' => "\u{2028}",
        'P' => "\u{2029}",
        else => null,
    };
}

/// Scans the blanks after a quoted scalar's run of text. Blanks within a
/// line are part of the value. Line breaks fold, the blanks around them
/// dropped: one break is a space, and each after the first a line feed;
/// after an escaped break, each is a line feed.
fn scanQuotedBlanks(s: *Scanner, arena: Allocator, value: *std.ArrayList(u8), escaped_break: bool, start: Mark) Error!void {
    const blanks_start = s.mark.offset;
    while (isBlank(s.ch(0))) s.skip();
    if (!isBreak(s.ch(0))) return value.appendSlice(arena, s.input[blanks_start..s.mark.offset]);
    var breaks: usize = 0;
    while (isBreak(s.ch(0))) {
        s.skipBreak();
        breaks += 1;
        try s.skipQuotedIndentation(start);
    }
    if (breaks == 1 and !escaped_break) {
        try value.append(arena, ' ');
    } else {
        try value.appendNTimes(arena, '\n', breaks - 1);
    }
}

/// Skips the blanks that begin a quoted scalar's next line. No document
/// marker may begin it, and in a block a line with anything on it must be
/// indented past the block, with spaces.
fn skipQuotedIndentation(s: *Scanner, start: Mark) Error!void {
    if (s.atDocumentMarkerLine()) return s.fail(s.mark, "a document marker cannot be inside a quoted scalar");
    while (s.ch(0) == ' ') s.skip();
    const spaces: isize = @intCast(s.mark.column);
    while (isBlank(s.ch(0))) s.skip();
    if (isBreak(s.ch(0)) or s.flow_level > 0 or spaces > s.indent) return;
    if (s.mark.offset >= s.input.len) return s.fail(start, "found the end of the input inside a quoted scalar");
    return s.fail(s.mark, "a quoted scalar's lines must be indented past its block's, with spaces");
}

// Block scalars

const Chomping = enum { strip, clip, keep };

/// A block scalar's header: `|` or `>`, then a chomping indicator and an
/// indentation indicator, each optional, in either order.
const BlockHeader = struct {
    chomping: ?Chomping = null,
    /// How many columns the content is indented past the block's.
    increment: ?usize = null,
};

/// A block scalar being read.
const BlockScalar = struct {
    literal: bool,
    /// The content's indentation column, once known.
    indent: ?usize,
    value: std.ArrayList(u8) = .empty,
    /// A content line has been read: its line break, or the one the
    /// input's end implies, is pending.
    leading_break: bool = false,
    /// How many empty lines came since the last content line.
    trailing_breaks: usize = 0,
    /// The last content line began with a blank after the indentation.
    leading_blank: bool = false,
};

/// Scans a literal (`|`) or folded (`>`) scalar (YAML 1.2.2, 8.1): its
/// header, then the lines indented to its content's column, given by the
/// header or found on its first line that is not empty. A folded scalar
/// joins two lines with a space, except around a line that begins with
/// a blank. The chomping indicator says what of the last line break and
/// the empty lines after it stays: none (`-`), the break (no indicator),
/// or all (`+`).
fn scanBlockScalar(s: *Scanner, style: ScalarStyle) Error!Token {
    const start = s.mark;
    s.skip();
    const header = try s.scanBlockHeader();
    try s.skipBlockHeaderEnd();
    var block: BlockScalar = .{
        .literal = style == .literal,
        .indent = if (header.increment) |m| @intCast(s.indent + @as(isize, @intCast(m))) else null,
    };
    try s.scanBlockBreaks(&block);
    while (s.atBlockContent(&block)) {
        try s.scanBlockLine(&block);
        try s.scanBlockBreaks(&block);
    }
    const arena = s.arena.allocator();
    const chomping = header.chomping orelse .clip;
    if (chomping != .strip and block.leading_break) try block.value.append(arena, '\n');
    if (chomping == .keep) try block.value.appendNTimes(arena, '\n', block.trailing_breaks);
    return .{ .start = start, .end = s.mark, .data = .{ .scalar = .{ .value = block.value.items, .style = style } } };
}

fn scanBlockHeader(s: *Scanner) Error!BlockHeader {
    var header: BlockHeader = .{};
    for (0..2) |_| {
        const c = s.ch(0);
        if ((c == '+' or c == '-') and header.chomping == null) {
            header.chomping = if (c == '+') .keep else .strip;
        } else if (c >= '1' and c <= '9' and header.increment == null) {
            header.increment = c - '0';
        } else if (c == '0') {
            return s.fail(s.mark, "a block scalar's indentation indicator cannot be 0");
        } else break;
        s.skip();
    }
    return header;
}

/// Skips the rest of a block scalar's header line: blanks, a comment,
/// and the line break.
fn skipBlockHeaderEnd(s: *Scanner) Error!void {
    while (isBlank(s.ch(0))) s.skip();
    if (s.ch(0) == '#') try s.skipComment();
    if (!isBreakOrEnd(s.ch(0))) return s.fail(s.mark, "a block scalar's header must end its line, but for a comment");
    if (isBreak(s.ch(0))) s.skipBreak();
}

/// Whether the scanner is at a block scalar's next content line: at its
/// indentation, and not at the end or a document marker.
fn atBlockContent(s: *const Scanner, block: *const BlockScalar) bool {
    if (s.mark.offset >= s.input.len or s.mark.column != block.indent.?) return false;
    return !s.atDocumentMarkerLine();
}

/// Skips a block scalar's empty lines and the indentation of the line
/// after them, counting them in `trailing_breaks`; on the first line
/// that is not empty, finds the content's indentation if the header did
/// not give it. A last line of blanks with no line break is an empty
/// line: the input's end implies its break.
fn scanBlockBreaks(s: *Scanner, block: *BlockScalar) Error!void {
    var widest_empty: usize = 0;
    while (!s.atDocumentMarkerLine()) {
        const line_start = s.mark.offset;
        try s.skipBlockIndentation(block);
        const at_end = s.mark.offset >= s.input.len;
        if (!isBreak(s.ch(0)) and !(at_end and s.mark.offset > line_start)) break;
        widest_empty = @max(widest_empty, s.mark.column);
        block.trailing_breaks += 1;
        if (at_end) break;
        s.skipBreak();
    }
    if (block.indent == null) try s.findBlockIndent(block, widest_empty);
}

/// Skips a block scalar line's indentation: its spaces up to the
/// content's column, or all of them while that is not known. A tab may
/// follow the indentation, as content, but not stand in it.
fn skipBlockIndentation(s: *Scanner, block: *const BlockScalar) Error!void {
    while (s.ch(0) == ' ' and s.inBlockIndentation(block)) s.skip();
    if (s.ch(0) != '\t' or !s.inBlockIndentation(block)) return;
    // With the column not known, a tab past the block's starts content.
    if (block.indent == null and s.pastBlock()) return;
    return s.fail(s.mark, "a tab character cannot indent a block scalar");
}

fn inBlockIndentation(s: *const Scanner, block: *const BlockScalar) bool {
    return block.indent == null or s.mark.column < block.indent.?;
}

/// Sets a block scalar's indentation to that of its first line that is
/// not empty, the scanner at its first character. A line not indented
/// past the block holds none of it, and the scalar is empty.
fn findBlockIndent(s: *Scanner, block: *BlockScalar, widest_empty: usize) Error!void {
    const at_content = s.mark.offset < s.input.len and s.pastBlock();
    if (at_content and widest_empty > s.mark.column) {
        return s.fail(s.mark, "a block scalar's leading empty line has more spaces than its first line");
    }
    const past: usize = @intCast(s.indent + 1);
    block.indent = if (at_content) s.mark.column else @max(widest_empty, past);
}

/// Whether the scanner's column is past the current block's indentation.
fn pastBlock(s: *const Scanner) bool {
    return @as(isize, @intCast(s.mark.column)) > s.indent;
}

/// Reads one content line of a block scalar, from its indentation through
/// its line break, folding or keeping the breaks before it.
fn scanBlockLine(s: *Scanner, block: *BlockScalar) Error!void {
    const arena = s.arena.allocator();
    const blank = isBlank(s.ch(0));
    if (!block.literal and block.leading_break and !block.leading_blank and !blank) {
        // Two lines of text: one break between them is a space.
        if (block.trailing_breaks == 0) try block.value.append(arena, ' ');
    } else if (block.leading_break) {
        try block.value.append(arena, '\n');
    }
    try block.value.appendNTimes(arena, '\n', block.trailing_breaks);
    block.trailing_breaks = 0;
    block.leading_blank = blank;
    const line_start = s.mark.offset;
    while (!isBreakOrEnd(s.ch(0))) {
        if (!isPrintable(s.input, s.mark.offset)) return s.fail(s.mark, "found a character that is not allowed in YAML");
        s.skip();
    }
    try block.value.appendSlice(arena, s.input[line_start..s.mark.offset]);
    // The line is not empty, so the input's end implies its break.
    block.leading_break = true;
    if (isBreak(s.ch(0))) s.skipBreak();
}

// Reading

/// The byte `ahead` places past the next one, or 0 past the end.
fn ch(s: *const Scanner, ahead: usize) u8 {
    const i = s.mark.offset + ahead;
    return if (i < s.input.len) s.input[i] else 0;
}

/// Whether a line begins here with a document marker.
fn atDocumentMarkerLine(s: *const Scanner) bool {
    return s.mark.column == 0 and (s.atDocumentMarker("---") or s.atDocumentMarker("..."));
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
