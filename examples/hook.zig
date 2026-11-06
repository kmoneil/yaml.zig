const std = @import("std");
const yaml = @import("yaml");

const Exec = struct { argv: []const []const u8, cwd: ?[]const u8 = null };

/// A command: a line for the shell, or a program and its arguments.
const Run = union(enum) {
    shell: []const u8,
    exec: Exec,

    /// Either shape, by the kind of node it is written as.
    pub fn yamlParse(c: yaml.Construction) yaml.ParseError!Run {
        return switch (c.node.data) {
            .scalar => .{ .shell = try c.build([]const u8, c.node) },
            .mapping => .{ .exec = try c.build(Exec, c.node) },
            else => c.failExpected(c.node, "a command, a string or a mapping"),
        };
    }

    /// Written as the shape it is read from.
    pub fn yamlStringify(r: Run, s: *yaml.Stringification) yaml.StringifyError!void {
        switch (r) {
            .shell => |line| try s.write(line),
            .exec => |exec| try s.write(exec),
        }
    }
};

test "a type that reads itself: yamlParse" {
    const Job = struct { steps: []const Run };
    const text =
        \\steps:
        \\- make test
        \\- {argv: [python, train.py], cwd: src}
        \\
    ;
    const parsed = try yaml.parseFromSlice(Job, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("make test", parsed.value.steps[0].shell);
    try std.testing.expectEqualStrings("train.py", parsed.value.steps[1].exec.argv[1]);

    // And written so it reads back the same.
    const written = try yaml.stringifyAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(written);
    const again = try yaml.parseFromSlice(Job, std.testing.allocator, written, .{});
    defer again.deinit();
    try std.testing.expectEqualDeep(parsed.value, again.value);
}
