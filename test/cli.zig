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
    // json and from-json
    .{ .argv = &.{ "json", "stream.yaml" }, .exit = 0, .stdout = "{\"a\":1}\n[\"x\",\"y\"]\nnull\n" },
    .{ .argv = &.{ "json", "--indent", "2", "alias.yaml" }, .exit = 0, .stdout = "{\n  \"base\": {\n    \"k\": \"v\"\n  },\n  \"use\": {\n    \"k\": \"v\"\n  }\n}\n" },
    .{ .argv = &.{ "from-json", "data.json" }, .exit = 0, .stdout = "name: x\non: yes\nn:\n- 1\n- 2.5\n- null\n- true\n" },
    // events
    .{ .argv = &.{ "events", "alias.yaml" }, .exit = 0, .stdout = "+STR\n+DOC\n+MAP\n=VAL :base\n+MAP {} &b\n=VAL :k\n=VAL :v\n-MAP\n=VAL :use\n=ALI *b\n-MAP\n-DOC\n-STR\n" },
    .{ .argv = &.{ "events", "bad.yaml" }, .exit = 1, .stdout = "+STR\n+DOC\n+MAP\n=VAL :list\n+SEQ []\n=VAL :1\n", .stderr = "bad.yaml:2:1: a flow collection's lines must be indented past its block's, with spaces\nnext: 3\n^\n" },
    // usage
    .{ .argv = &.{}, .exit = 2, .stderr = "yaml: a command is needed: check, get, json, from-json or events\nRun `yaml --help` for the usage.\n" },
    .{ .argv = &.{ "lint", "good.yaml" }, .exit = 2, .stderr = "yaml: no command `lint`: check, get, json, from-json or events\nRun `yaml --help` for the usage.\n" },
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
