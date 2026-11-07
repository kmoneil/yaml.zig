//! `yaml`: checks YAML files, reads a value out of one, converts between
//! YAML and JSON, and shows how a file reads, with the yaml.zig library
//! (t58).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const yaml = @import("yaml");
const tree = @import("tree.zig");
const json = @import("json.zig");

const usage =
    \\Usage: yaml check [--format text|json] [options] <file>...
    \\       yaml get [--document <n>] [--json [--indent <n>]] [options] <path> <file>
    \\       yaml json [--indent <n>] [options] <file>
    \\       yaml from-json <file>
    \\       yaml events <file>
    \\       yaml skill [--install <dir>]
    \\       yaml --help
    \\
    \\check reads every document of each file, and reports each file that
    \\is not YAML: file:line:column: what is wrong, then the line and a
    \\caret under the column. --format json writes the findings as a JSON
    \\array instead, each {"file", "line", "column", "message"}, lines and
    \\columns from 1.
    \\
    \\get prints the value at <path> in a file of one document, or in the
    \\document --document picks (from 0), as YAML, or as JSON with --json.
    \\A path is `.` for the whole document, or steps in any order: `.key`,
    \\`.["a key"]`, `[n]` for a sequence's item: `.servers[0].name`.
    \\
    \\json prints each document of a file as JSON, one a line, or indented
    \\with --indent. from-json prints a JSON file as YAML. events prints
    \\the events a file reads to, in the yaml-test-suite's notation.
    \\
    \\skill prints what an AI agent needs to work with yaml: each command
    \\with an example, the errors seen most and how to fix them, the exit
    \\status. --install <dir> writes <dir>/yaml/SKILL.md, a stub that has
    \\the agent run `yaml skill`, so it is never out of date.
    \\
    \\A file named - is read from standard input. UTF-16 and UTF-32 are
    \\read too, by their byte order mark or their first bytes.
    \\
    \\Options:
    \\  --schema core|json|failsafe   How a plain scalar with no tag is typed
    \\                                (default core).
    \\  --duplicate-keys refuse|keep  A mapping's second equal key: an error
    \\                                (the default), or kept.
    \\  --max-depth <n>               The most collections open at once
    \\                                (default 256).
    \\  --merge-keys                  get and json: apply YAML 1.1's merge
    \\                                key, `<<: *base`, as most readers do.
    \\  --indent <n>                  JSON's indentation: 0 (one line, the
    \\                                default), 1, 2, 3, 4 or 8.
    \\
    \\Exit status: 0 on success; 1 when a file is not YAML (or JSON), or
    \\get finds no value at the path or one JSON cannot hold; 2 on a usage
    \\error or a file that could not be read.
    \\
;

/// The most a file may hold: a mark counts in 32 bits.
const max_bytes = yaml.Scanner.max_input;

const Command = enum { check, get, json, @"from-json", events, skill };

const commands = "check, get, json, from-json, events or skill";

/// The agent skill: `yaml skill` prints it (t59).
const skill_text = @embedFile("skill.md");

/// What `yaml skill --install` writes: the skill's frontmatter, so an
/// agent knows when to load it, and a line that hands over to `yaml
/// skill`, so it never needs updating (as karte's does).
const skill_stub = skill_text[0 .. (std.mem.find(u8, skill_text[4..], "\n---\n") orelse unreachable) + 4 + "\n---\n".len] ++
    \\
    \\Run `yaml skill` and follow what it prints: it is the guide to the yaml installed on this machine, current for its version.
    \\
;

const Options = struct {
    format: enum { text, json } = .text,
    composer: yaml.Composer.Options = .{ .max_depth = 256 },
    document: ?usize = null,
    as_json: bool = false,
    /// get and json: apply merge keys (yaml.merge).
    merge_keys: bool = false,
    indent: u8 = 0,
    /// skill: the directory to write yaml/SKILL.md under.
    install: ?[]const u8 = null,
};

const Args = struct {
    command: Command,
    options: Options,
    operands: []const []const u8,
};

/// What `parseArgs` gives: a command to run, the help, or what is wrong.
const Parsed = union(enum) {
    run: Args,
    help,
    usage_error: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    const argv = (try init.minimal.args.toSlice(arena))[1..];
    const status: u8 = switch (try parseArgs(arena, argv)) {
        .help => help: {
            try out.writeAll(usage);
            break :help 0;
        },
        .usage_error => |why| bad: {
            std.debug.print("yaml: {s}\nRun `yaml --help` for the usage.\n", .{why});
            break :bad 2;
        },
        .run => |args| try run(gpa, io, out, args),
    };
    try out.flush();
    return status;
}

fn parseArgs(arena: Allocator, argv: []const []const u8) Allocator.Error!Parsed {
    if (argv.len == 0) return .{ .usage_error = "a command is needed: " ++ commands };
    if (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) return .help;
    const command = std.meta.stringToEnum(Command, argv[0]) orelse
        return .{ .usage_error = try std.fmt.allocPrint(arena, "no command `{s}`: " ++ commands, .{argv[0]}) };
    var options: Options = .{};
    var operands: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len < 2 or !std.mem.startsWith(u8, arg, "--")) {
            try operands.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            options.as_json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--merge-keys")) {
            options.merge_keys = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return .help;
        i += 1;
        if (i == argv.len) return .{ .usage_error = try std.fmt.allocPrint(arena, "{s} needs a value", .{arg}) };
        if (try setOption(arena, &options, arg, argv[i])) |why| return .{ .usage_error = why };
    }
    if (try wrongOperands(arena, command, operands.items.len)) |why| return .{ .usage_error = why };
    return .{ .run = .{ .command = command, .options = options, .operands = operands.items } };
}

/// What is wrong with `n` operands for `command`, if anything.
fn wrongOperands(arena: Allocator, command: Command, n: usize) Allocator.Error!?[]const u8 {
    const want: struct { usize, usize, []const u8 } = switch (command) {
        .check => .{ 1, std.math.maxInt(usize), "one file or more" },
        .get => .{ 2, 2, "a path and a file" },
        .json, .@"from-json", .events => .{ 1, 1, "one file" },
        .skill => .{ 0, 0, "no file" },
    };
    if (n >= want[0] and n <= want[1]) return null;
    return try std.fmt.allocPrint(arena, "{t} takes {s}", .{ command, want[2] });
}

/// Sets the option `name` to `value`; what is wrong with them if they do
/// not make one.
fn setOption(arena: Allocator, options: *Options, name: []const u8, value: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, name, "--format")) {
        options.format = std.meta.stringToEnum(@FieldType(Options, "format"), value) orelse return "--format is text or json";
    } else if (std.mem.eql(u8, name, "--schema")) {
        options.composer.schema = std.meta.stringToEnum(yaml.schema.Schema, value) orelse return "--schema is core, json or failsafe";
    } else if (std.mem.eql(u8, name, "--duplicate-keys")) {
        options.composer.duplicate_keys = std.meta.stringToEnum(@FieldType(yaml.Composer.Options, "duplicate_keys"), value) orelse return "--duplicate-keys is refuse or keep";
    } else if (std.mem.eql(u8, name, "--max-depth")) {
        options.composer.max_depth = std.fmt.parseInt(usize, value, 10) catch return "--max-depth is a number";
    } else if (std.mem.eql(u8, name, "--document")) {
        options.document = std.fmt.parseInt(usize, value, 10) catch return "--document is a number, from 0";
    } else if (std.mem.eql(u8, name, "--install")) {
        options.install = value;
    } else if (std.mem.eql(u8, name, "--indent")) {
        options.indent = std.fmt.parseInt(u8, value, 10) catch return "--indent is 0, 1, 2, 3, 4 or 8";
        if (json.whitespace(options.indent) == null) return "--indent is 0, 1, 2, 3, 4 or 8";
    } else {
        return try std.fmt.allocPrint(arena, "no option {s}", .{name});
    }
    return null;
}

fn run(gpa: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (args.command) {
        .check => check(arena, io, out, args),
        .get => get(arena, io, out, args),
        .json => toJson(arena, io, out, args),
        .@"from-json" => fromJson(arena, io, out, args),
        .events => events(arena, io, out, args),
        .skill => skill(arena, io, out, args),
    };
}

// Reading files

/// A file's bytes, `-` standard input's; null, the reason said, when it
/// cannot be read.
fn readFile(arena: Allocator, io: Io, path: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [4096]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(io, &buffer);
        return reader.interface.allocRemaining(arena, .limited(max_bytes)) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("yaml: -: {t}\n", .{err});
                return null;
            },
        };
    }
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            std.debug.print("yaml: {s}: {t}\n", .{ path, err });
            return null;
        },
    };
}

/// What reading a file's YAML found wrong, and where.
const Finding = struct {
    path: []const u8,
    /// The text read, decoded to UTF-8, that the mark is in.
    text: []const u8,
    diagnostic: yaml.Diagnostic,
};

/// A file's text as UTF-8, or the finding that it is not.
fn decode(arena: Allocator, path: []const u8, bytes: []const u8, finding: *Finding) Allocator.Error!?[]const u8 {
    var diagnostic: yaml.Diagnostic = .{};
    return yaml.encoding.toUtf8(arena, bytes, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            finding.* = .{ .path = path, .text = "", .diagnostic = diagnostic };
            return null;
        },
    };
}

/// Reads every document of `text` a node at a time, as the composer's
/// steps give them (the checks of composing all made: syntax, equal keys,
/// aliases, the schema's tags) without holding a document's graph: only
/// what an alias may name, and a mapping's keys while it is open. False,
/// the finding set, when it is not YAML.
fn validate(arena: Allocator, path: []const u8, text: []const u8, options: Options, finding: *Finding) Allocator.Error!bool {
    var c: yaml.Composer = .init(arena, text, options.composer);
    defer c.deinit();
    readSteps(&c) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            finding.* = .{ .path = path, .text = text, .diagnostic = c.diagnostic };
            return false;
        },
    };
    return true;
}

fn readSteps(c: *yaml.Composer) yaml.Composer.Error!void {
    var slot: yaml.Composer.Node = undefined;
    while (try c.beginDocument()) |_| {
        // The root; a collection begun, its steps to its end.
        var open: usize = @intFromBool(try c.stepInto(&slot) == .begin);
        while (open > 0) switch (try c.stepInto(&slot)) {
            .begin => open += 1,
            .end => open -= 1,
            .scalar, .node => {},
        };
        try c.endDocument();
    }
}

/// A file's documents: their roots, and the composer they live in.
const Documents = struct {
    roots: []const *yaml.Composer.Node,
    composer: *yaml.Composer,

    /// The merges `--merge-keys` asks for, over these documents.
    fn merges(d: Documents, options: Options) ?tree.Merges {
        if (!options.merge_keys) return null;
        return .{ .composer = d.composer, .max_depth = options.composer.max_depth };
    }
};

/// Composes every document of `text`; null, the finding set, when it is
/// not YAML.
fn compose(arena: Allocator, path: []const u8, text: []const u8, options: Options, finding: *Finding) Allocator.Error!?Documents {
    const c = try arena.create(yaml.Composer);
    c.* = .init(arena, text, options.composer);
    var roots: std.ArrayList(*yaml.Composer.Node) = .empty;
    while (true) {
        const document = c.next() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                finding.* = .{ .path = path, .text = text, .diagnostic = c.diagnostic };
                return null;
            },
        } orelse return .{ .roots = roots.items, .composer = c };
        try roots.append(arena, document.root);
    }
}

// Findings

/// `path:line:column: message`, then the line and a caret under the
/// column, when the mark is in a line of the text.
fn writeFinding(w: *Io.Writer, f: Finding) Io.Writer.Error!void {
    const mark = f.diagnostic.mark;
    try w.print("{s}:{d}:{d}: {s}\n", .{ f.path, mark.line + 1, mark.column + 1, f.diagnostic.detail() });
    if (mark.offset > f.text.len) return;
    var start: usize = mark.offset;
    while (start > 0 and f.text[start - 1] != '\n' and f.text[start - 1] != '\r') start -= 1;
    var end: usize = mark.offset;
    while (end < f.text.len and f.text[end] != '\n' and f.text[end] != '\r') end += 1;
    if (start == end) return;
    // A control character in the line is shown as `?`, so the input
    // cannot write to the terminal (CWE-150); one character for one, so
    // the caret still lines up.
    for (f.text[start..end]) |c| try w.writeByte(if ((c < 0x20 and c != '\t') or c == 0x7F) '?' else c);
    try w.writeByte('\n');
    for (f.text[start..mark.offset]) |c| {
        if (c == '\t') try w.writeByte('\t') else if (c & 0xC0 != 0x80) try w.writeByte(' ');
    }
    try w.writeAll("^\n");
}

fn writeFindingJson(w: *Io.Writer, f: Finding) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("file");
    try s.write(f.path);
    try s.objectField("line");
    try s.write(f.diagnostic.mark.line + 1);
    try s.objectField("column");
    try s.write(f.diagnostic.mark.column + 1);
    try s.objectField("message");
    try s.write(f.diagnostic.detail());
    try s.endObject();
}

/// A finding on standard error, for the commands that read one file.
fn reportFinding(f: Finding) void {
    var buffer: [512]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    writeFinding(&stderr.file_writer.interface, f) catch {};
}

// Commands

fn check(arena: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    var unreadable = false;
    var findings: usize = 0;
    if (args.options.format == .json) try out.writeAll("[");
    for (args.operands) |path| {
        const bytes = try readFile(arena, io, path) orelse {
            unreadable = true;
            continue;
        };
        var finding: Finding = undefined;
        const clean = if (try decode(arena, path, bytes, &finding)) |text| try validate(arena, path, text, args.options, &finding) else false;
        if (clean) continue;
        switch (args.options.format) {
            .text => try writeFinding(out, finding),
            .json => {
                try out.writeAll(if (findings == 0) "\n" else ",\n");
                try writeFindingJson(out, finding);
            },
        }
        findings += 1;
    }
    if (args.options.format == .json) try out.writeAll(if (findings == 0) "]\n" else "\n]\n");
    if (unreadable) return 2;
    return @intFromBool(findings > 0);
}

/// The documents of the one file a command reads: null, said, when it
/// cannot be read (2) or is not YAML (1).
fn readDocuments(arena: Allocator, io: Io, path: []const u8, options: Options, status: *u8) Allocator.Error!?Documents {
    const bytes = try readFile(arena, io, path) orelse {
        status.* = 2;
        return null;
    };
    var finding: Finding = undefined;
    const text = try decode(arena, path, bytes, &finding) orelse {
        reportFinding(finding);
        status.* = 1;
        return null;
    };
    return try compose(arena, path, text, options, &finding) orelse {
        reportFinding(finding);
        status.* = 1;
        return null;
    };
}

fn get(arena: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    const path_text = args.operands[0];
    const file = args.operands[1];
    const path = tree.parsePath(arena, path_text) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.BadPath => {
            std.debug.print("yaml: `{s}` is no path: `.` for the whole document, or steps such as `.key`, `.[\"a key\"]`, `[0]`\n", .{path_text});
            return 2;
        },
    };
    var status: u8 = 0;
    const docs = try readDocuments(arena, io, file, args.options, &status) orelse return status;
    const roots = docs.roots;
    const at = args.options.document orelse 0;
    if (args.options.document == null and roots.len != 1 or at >= roots.len) {
        std.debug.print("yaml: {s}: the stream holds {d} document{s}: choose one with --document <n>, from 0\n", .{ file, roots.len, if (roots.len == 1) "" else "s" });
        return 1;
    }
    const merges = docs.merges(args.options);
    const node = switch (try tree.find(arena, roots[at], path, merges)) {
        .node => |n| n,
        .missing => |step| {
            std.debug.print("yaml: {s}: no value at `{s}`: nothing at step {d} of it\n", .{ file, path_text, step + 1 });
            return 1;
        },
        .merge_failed => |f| return reportMerge(file, f),
    };
    return writeValue(arena, out, file, node, args.options, merges);
}

/// Says why a merge failed, at its place in `file`: 1.
fn reportMerge(file: []const u8, f: tree.MergeFailure) u8 {
    const why = switch (f.err) {
        error.NotMergeable => "a merge key's value is not a mapping or a sequence of mappings",
        error.Cycle => "a merge names a mapping it is merged into, which a value cannot hold",
        error.DepthLimit => "merges go deeper than --max-depth",
        error.OutOfMemory => "out of memory",
    };
    if (f.at) |n| {
        std.debug.print("yaml: {s}:{d}:{d}: {s}\n", .{ file, n.start.line + 1, n.start.column + 1, why });
    } else {
        std.debug.print("yaml: {s}: {s}\n", .{ file, why });
    }
    return 1;
}

/// Writes what `node` holds as YAML or JSON: 1, said, when it cannot be.
fn writeValue(arena: Allocator, out: *Io.Writer, file: []const u8, node: *const yaml.Composer.Node, options: Options, merges: ?tree.Merges) !u8 {
    var failure: tree.MergeFailure = undefined;
    const value = tree.valueOf(arena, node, merges, &failure) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.MergeFailed => return reportMerge(file, failure),
        error.Cycle => {
            std.debug.print("yaml: {s}: an alias leads back into a collection it is in, which a value cannot hold\n", .{file});
            return 1;
        },
        error.TooLarge => {
            std.debug.print("yaml: {s}: its aliases make more than {d} values\n", .{ file, tree.max_values });
            return 1;
        },
    };
    if (!options.as_json) {
        try yaml.stringify(arena, value, .{}, out);
        return 0;
    }
    json.write(arena, out, value, options.indent) catch |err| switch (err) {
        error.NotJson => {
            std.debug.print("yaml: {s}: a value JSON cannot hold (a float not a number, or a key that is a collection)\n", .{file});
            return 1;
        },
        else => |e| return e,
    };
    try out.writeByte('\n');
    return 0;
}

fn toJson(arena: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    var status: u8 = 0;
    const docs = try readDocuments(arena, io, args.operands[0], args.options, &status) orelse return status;
    var options = args.options;
    options.as_json = true;
    for (docs.roots) |root| {
        const written = try writeValue(arena, out, args.operands[0], root, options, docs.merges(options));
        if (written != 0) return written;
    }
    return 0;
}

fn fromJson(arena: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    const file = args.operands[0];
    const bytes = try readFile(arena, io, file) orelse return 2;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            std.debug.print("yaml: {s}: not JSON: {t}\n", .{ file, err });
            return 1;
        },
    };
    try yaml.stringify(arena, try json.fromJson(arena, parsed), .{}, out);
    return 0;
}

fn events(arena: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    const file = args.operands[0];
    const bytes = try readFile(arena, io, file) orelse return 2;
    var finding: Finding = undefined;
    const text = try decode(arena, file, bytes, &finding) orelse {
        reportFinding(finding);
        return 1;
    };
    var parser: yaml.Parser = .init(arena, text);
    parser.scanner.max_depth = args.options.composer.max_depth;
    while (true) {
        const event = parser.next() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                reportFinding(.{ .path = file, .text = text, .diagnostic = parser.diagnostic });
                return 1;
            },
        };
        try yaml.Parser.writeTestEvent(out, event);
        if (event.data == .stream_end) return 0;
    }
}

/// Prints the skill, or with --install writes its stub, and says where.
fn skill(arena: Allocator, io: Io, out: *Io.Writer, args: Args) !u8 {
    const dir = args.options.install orelse {
        try out.writeAll(skill_text);
        return 0;
    };
    const sub = try std.fs.path.join(arena, &.{ dir, "yaml" });
    const path = try std.fs.path.join(arena, &.{ sub, "SKILL.md" });
    Io.Dir.cwd().createDirPath(io, sub) catch |err| {
        std.debug.print("yaml: {s}: {t}\n", .{ sub, err });
        return 2;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = skill_stub }) catch |err| {
        std.debug.print("yaml: {s}: {t}\n", .{ path, err });
        return 2;
    };
    try out.print("wrote {s}\n", .{path});
    return 0;
}

test {
    _ = tree;
}

test "the skill's stub is its frontmatter and a hand-over" {
    try std.testing.expect(std.mem.startsWith(u8, skill_stub, "---\nname: yaml\ndescription: "));
    try std.testing.expect(std.mem.endsWith(u8, skill_stub, "---\n\nRun `yaml skill` and follow what it prints: it is the guide to the yaml installed on this machine, current for its version.\n"));
}
