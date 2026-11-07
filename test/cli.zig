//! The `yaml` command run end to end: each case the files it reads, its
//! arguments, and the output and exit status it must give (t58).

const std = @import("std");
const Io = std.Io;
const test_options = @import("test_options");

const files = [_]struct { []const u8, []const u8 }{
    .{ "good.yaml", "servers:\n- name: a\n  port: 80\n- name: b\n  port: 443\nflags: {debug: true, ratio: 0.5}\n\"a key\": [1, 2]\n" },
    .{ "dup.yaml", "a: 1\na: 2\n" },
    .{ "bad.yaml", "list: [1, 2\nnext: 3\n" },
    .{ "stream.yaml", "--- {a: 1}\n--- [x, y]\n--- ~\n" },
    .{ "alias.yaml", "base: &b {k: v}\nuse: *b\n" },
    .{ "cycle.yaml", "&a [*a]\n" },
    .{ "data.json", "{\"name\": \"x\", \"on\": \"yes\", \"n\": [1, 2.5, null, true]}\n" },
    .{ "tab.yaml", "a:\n\tb: 1\n" },
    .{ "late.yaml", "--- a\n--- {b: 1, b: 2}\n" },
    .{ "merge.yaml", "base: &b {x: 1, y: 2}\nchild:\n  <<: *b\n  y: 3\n" },
    .{ "badmerge.yaml", "m: {<<: 3}\n" },
    .{ "legacy.yaml", "on: yes\nmode: 0755\nat: 2001-12-14\nbig: 0777777777777777777777777\n" },
    .{ "lint.yaml", "enabled: yes\nmode: 0755\nbase: &b {x: 1}\nspare: &s {z: 2}\nuse: *b\nName: a\nname: b\nport: 8080  \n" },
    .{ "tabbed.yaml", "text: |\n  \tindented by a tab\nratio: 1e3\n" },
};

const Case = struct {
    argv: []const []const u8,
    exit: u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

const cases = [_]Case{
    // check
    .{ .argv = &.{ "check", "good.yaml", "stream.yaml", "alias.yaml" }, .exit = 0 },
    .{ .argv = &.{ "check", "dup.yaml" }, .exit = 1, .stdout = "dup.yaml:2:1: a mapping cannot have two equal keys\na: 2\n^\n" },
    .{ .argv = &.{ "check", "--duplicate-keys", "keep", "dup.yaml" }, .exit = 0 },
    .{ .argv = &.{ "check", "late.yaml" }, .exit = 1, .stdout = "late.yaml:2:12: a mapping cannot have two equal keys\n--- {b: 1, b: 2}\n           ^\n" },
    .{ .argv = &.{ "check", "good.yaml", "tab.yaml", "dup.yaml" }, .exit = 1, .stdout = "tab.yaml:2:2: a tab character cannot indent a block\n\tb: 1\n\t^\ndup.yaml:2:1: a mapping cannot have two equal keys\na: 2\n^\n" },
    .{ .argv = &.{ "check", "--format", "json", "good.yaml" }, .exit = 0, .stdout = "[]\n" },
    .{ .argv = &.{ "check", "--format", "json", "dup.yaml", "good.yaml" }, .exit = 1, .stdout = "[\n{\"file\":\"dup.yaml\",\"line\":2,\"column\":1,\"message\":\"a mapping cannot have two equal keys\"}\n]\n" },
    .{ .argv = &.{ "check", "missing.yaml", "good.yaml" }, .exit = 2, .stderr = "yaml: missing.yaml: FileNotFound\n" },
    // get
    .{ .argv = &.{ "get", ".servers[1].name", "good.yaml" }, .exit = 0, .stdout = "b\n" },
    .{ .argv = &.{ "get", ".[\"a key\"]", "good.yaml" }, .exit = 0, .stdout = "- 1\n- 2\n" },
    .{ .argv = &.{ "get", "--json", ".flags", "good.yaml" }, .exit = 0, .stdout = "{\"debug\":true,\"ratio\":0.5}\n" },
    .{ .argv = &.{ "get", ".use.k", "alias.yaml" }, .exit = 0, .stdout = "v\n" },
    .{ .argv = &.{ "get", ".servers[2]", "good.yaml" }, .exit = 1, .stderr = "yaml: good.yaml: no value at `.servers[2]`: nothing at step 2 of it\n" },
    .{ .argv = &.{ "get", ".", "stream.yaml" }, .exit = 1, .stderr = "yaml: stream.yaml: the stream holds 3 documents: choose one with --document <n>, from 0\n" },
    .{ .argv = &.{ "get", "--document", "1", "[0]", "stream.yaml" }, .exit = 0, .stdout = "x\n" },
    .{ .argv = &.{ "get", ".", "cycle.yaml" }, .exit = 1, .stderr = "yaml: cycle.yaml: an alias leads back into a collection it is in, which a value cannot hold\n" },
    .{ .argv = &.{ "get", "servers", "good.yaml" }, .exit = 2, .stderr = "yaml: `servers` is no path: `.` for the whole document, or steps such as `.key`, `.[\"a key\"]`, `[0]`\n" },
    // merge keys: off by default, `<<` a key; with --merge-keys merged,
    // the mapping's own keys first and winning
    .{ .argv = &.{ "json", "merge.yaml" }, .exit = 0, .stdout = "{\"base\":{\"x\":1,\"y\":2},\"child\":{\"<<\":{\"x\":1,\"y\":2},\"y\":3}}\n" },
    .{ .argv = &.{ "json", "--merge-keys", "merge.yaml" }, .exit = 0, .stdout = "{\"base\":{\"x\":1,\"y\":2},\"child\":{\"y\":3,\"x\":1}}\n" },
    .{ .argv = &.{ "get", "--merge-keys", ".child.x", "merge.yaml" }, .exit = 0, .stdout = "1\n" },
    .{ .argv = &.{ "get", ".child.x", "merge.yaml" }, .exit = 1, .stderr = "yaml: merge.yaml: no value at `.child.x`: nothing at step 2 of it\n" },
    .{ .argv = &.{ "json", "--merge-keys", "badmerge.yaml" }, .exit = 1, .stderr = "yaml: badmerge.yaml:1:9: a merge key's value is not a mapping or a sequence of mappings\n" },
    // the yaml11 schema: as PyYAML reads a file
    .{ .argv = &.{ "json", "legacy.yaml" }, .exit = 0, .stdout = "{\"on\":\"yes\",\"mode\":755,\"at\":\"2001-12-14\",\"big\":\"0777777777777777777777777\"}\n" },
    .{ .argv = &.{ "json", "--schema", "yaml11", "legacy.yaml" }, .exit = 0, .stdout = "{\"true\":true,\"mode\":493,\"at\":\"2001-12-14\",\"big\":\"0777777777777777777777777\"}\n" },
    .{ .argv = &.{ "check", "--schema", "yaml12", "legacy.yaml" }, .exit = 2, .stderr = "yaml: --schema is core, yaml11, json or failsafe\nRun `yaml --help` for the usage.\n" },
    // lint: clean, an error as check reports it, each rule, and the options
    .{ .argv = &.{ "lint", "good.yaml", "alias.yaml" }, .exit = 0 },
    .{ .argv = &.{ "lint", "dup.yaml", "good.yaml" }, .exit = 1, .stdout = "dup.yaml:2:1: a mapping cannot have two equal keys\na: 2\n^\n" },
    .{ .argv = &.{ "lint", "tabbed.yaml" }, .exit = 1, .stdout = "tabbed.yaml:2:3: warning: a tab in the indentation: indent with spaces, as YAML's blocks must be\n  \tindented by a tab\n  ^\ntabbed.yaml:3:8: warning: `1e3` is a float in YAML 1.2 but a string in YAML 1.1 (PyYAML): write it with a point, and a sign on any exponent: 1.0e+3\nratio: 1e3\n       ^\n" },
    .{ .argv = &.{ "lint", "--allow", "yaml11,key-case", "--allow", "unused-anchor,trailing-space", "lint.yaml" }, .exit = 0 },
    .{ .argv = &.{ "lint", "--fail-on", "tab", "--allow", "yaml11,key-case,trailing-space", "lint.yaml" }, .exit = 0, .stdout = "lint.yaml:4:8: warning: the anchor &s is never used: no alias names it\nspare: &s {z: 2}\n       ^\n" },
    .{ .argv = &.{ "lint", "--max-line", "12", "--allow", "yaml11,key-case,trailing-space,unused-anchor", "lint.yaml" }, .exit = 1, .stdout = "lint.yaml:3:13: warning: the line is 15 characters long, past --max-line 12\nbase: &b {x: 1}\n            ^\nlint.yaml:4:13: warning: the line is 16 characters long, past --max-line 12\nspare: &s {z: 2}\n            ^\n" },
    .{ .argv = &.{ "lint", "--format", "json", "--allow", "yaml11,key-case,unused-anchor", "lint.yaml", "dup.yaml" }, .exit = 1, .stdout = "[\n{\"file\":\"lint.yaml\",\"line\":8,\"column\":11,\"severity\":\"warning\",\"rule\":\"trailing-space\",\"message\":\"blanks at the end of the line\"},\n{\"file\":\"dup.yaml\",\"line\":2,\"column\":1,\"severity\":\"error\",\"message\":\"a mapping cannot have two equal keys\"}\n]\n" },
    .{ .argv = &.{ "lint", "--allow", "tabs", "lint.yaml" }, .exit = 2, .stderr = "yaml: --allow takes rules, with commas between: yaml11, tab, trailing-space, line-length, unused-anchor or key-case\nRun `yaml --help` for the usage.\n" },
    // json and from-json
    .{ .argv = &.{ "json", "stream.yaml" }, .exit = 0, .stdout = "{\"a\":1}\n[\"x\",\"y\"]\nnull\n" },
    .{ .argv = &.{ "json", "--indent", "2", "alias.yaml" }, .exit = 0, .stdout = "{\n  \"base\": {\n    \"k\": \"v\"\n  },\n  \"use\": {\n    \"k\": \"v\"\n  }\n}\n" },
    .{ .argv = &.{ "from-json", "data.json" }, .exit = 0, .stdout = "name: x\n'on': 'yes'\n'n':\n- 1\n- 2.5\n- null\n- true\n" },
    // events
    .{ .argv = &.{ "events", "alias.yaml" }, .exit = 0, .stdout = "+STR\n+DOC\n+MAP\n=VAL :base\n+MAP {} &b\n=VAL :k\n=VAL :v\n-MAP\n=VAL :use\n=ALI *b\n-MAP\n-DOC\n-STR\n" },
    .{ .argv = &.{ "events", "bad.yaml" }, .exit = 1, .stdout = "+STR\n+DOC\n+MAP\n=VAL :list\n+SEQ []\n=VAL :1\n", .stderr = "bad.yaml:2:1: a flow collection's lines must be indented past its block's, with spaces\nnext: 3\n^\n" },
    // usage
    .{ .argv = &.{}, .exit = 2, .stderr = "yaml: a command is needed: check, lint, get, json, from-json, events or skill\nRun `yaml --help` for the usage.\n" },
    .{ .argv = &.{ "format", "good.yaml" }, .exit = 2, .stderr = "yaml: no command `format`: check, lint, get, json, from-json, events or skill\nRun `yaml --help` for the usage.\n" },
    .{ .argv = &.{ "skill", "good.yaml" }, .exit = 2, .stderr = "yaml: skill takes no file\nRun `yaml --help` for the usage.\n" },
    .{ .argv = &.{ "skill", "--install", "agents" }, .exit = 0, .stdout = "wrote agents/yaml/SKILL.md\n" },
    .{ .argv = &.{ "get", ".a" }, .exit = 2, .stderr = "yaml: get takes a path and a file\nRun `yaml --help` for the usage.\n" },
    .{ .argv = &.{ "json", "--indent", "5", "good.yaml" }, .exit = 2, .stderr = "yaml: --indent is 0, 1, 2, 3, 4 or 8\nRun `yaml --help` for the usage.\n" },
};

test "yaml, each command end to end" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.yaml_exe, gpa);
    defer gpa.free(exe);
    for (cases) |case| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, exe);
        try argv.appendSlice(gpa, case.argv);
        const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = tmp.dir } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        errdefer {
            std.debug.print("yaml", .{});
            for (case.argv) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print("\n--- stdout\n{s}--- stderr\n{s}", .{ result.stdout, result.stderr });
        }
        try std.testing.expectEqualStrings(case.stdout, result.stdout);
        try std.testing.expectEqualStrings(case.stderr, result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case.exit }, result.term);
    }
}

/// Runs the binary in `dir` with `args`, its stdout and then its stderr.
fn runIn(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, exe: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, exe);
    try argv.appendSlice(gpa, args);
    const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = dir } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return std.mem.concat(gpa, u8, &.{ result.stdout, result.stderr });
}

/// A command line's words, split at spaces, a word in single quotes kept
/// whole.
fn words(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ') {
            i += 1;
            continue;
        }
        const quoted = line[i] == '\'';
        const start = if (quoted) i + 1 else i;
        const end = std.mem.findScalarPos(u8, line, start, if (quoted) '\'' else ' ') orelse line.len;
        try out.append(gpa, line[start..end]);
        i = if (quoted) end + 1 else end;
    }
    return out.toOwnedSlice(gpa);
}

test "the skill's examples print what it shows" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.yaml_exe, gpa);
    defer gpa.free(exe);
    const skill = try runIn(gpa, io, tmp.dir, exe, &.{"skill"});
    defer gpa.free(skill);
    var examples: usize = 0;
    var blocks = std.mem.splitSequence(u8, skill, "```console\n");
    _ = blocks.next();
    while (blocks.next()) |rest| {
        const block = rest[0 .. std.mem.find(u8, rest, "```\n") orelse return error.UnclosedBlock];
        // Each `$ yaml` line, and the lines after it up to the next, what
        // it prints, its stdout and then its stderr.
        var lines = std.mem.splitScalar(u8, block, '\n');
        var command: ?[]const u8 = lines.next();
        while (command) |line| {
            if (!std.mem.startsWith(u8, line, "$ yaml ")) return error.NoCommand;
            var shown: std.ArrayList(u8) = .empty;
            defer shown.deinit(gpa);
            command = null;
            while (lines.next()) |next| {
                if (std.mem.startsWith(u8, next, "$ ")) {
                    command = next;
                    break;
                }
                // The block's last line break ends a line, and makes none.
                if (next.len == 0 and lines.peek() == null) break;
                try shown.appendSlice(gpa, next);
                try shown.append(gpa, '\n');
            }
            const args = try words(gpa, line["$ yaml ".len..]);
            defer gpa.free(args);
            const got = try runIn(gpa, io, tmp.dir, exe, args);
            defer gpa.free(got);
            errdefer std.debug.print("in the skill: {s}\n", .{line});
            try std.testing.expectEqualStrings(shown.items, got);
            examples += 1;
        }
    }
    try std.testing.expect(examples >= 10);
}

test "yaml --version prints build.zig.zon's version" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.yaml_exe, gpa);
    defer gpa.free(exe);
    const result = try std.process.run(gpa, io, .{ .argv = &.{ exe, "--version" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings("yaml " ++ test_options.version ++ "\n", result.stdout);
}

test "yaml --help prints the usage" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.yaml_exe, gpa);
    defer gpa.free(exe);
    const result = try std.process.run(gpa, io, .{ .argv = &.{ exe, "--help" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "Usage: yaml check"));
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}
