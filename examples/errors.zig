const std = @import("std");
const yaml = @import("yaml");

test "an error says where and why" {
    const Limits = struct { cpu: u8, memory: u32 };
    const text =
        \\cpu: 300
        \\memory: 512
        \\
    ;

    var diagnostic: yaml.Diagnostic = .{};
    const result = yaml.parseFromSlice(Limits, std.testing.allocator, text, .{ .diagnostic = &diagnostic });
    try std.testing.expectError(error.Overflow, result);

    // Lines and columns count from 0.
    try std.testing.expectEqual(0, diagnostic.mark.line);
    try std.testing.expectEqual(5, diagnostic.mark.column);
    try std.testing.expectEqualStrings("the integer does not fit the type asked for", diagnostic.message);

    // Printed, from 1, with the path to the value and what it is: put a
    // file's name before it and it reads as a compiler's error does.
    var buf: [256]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buf);
    try line.print("{f}", .{diagnostic});
    try std.testing.expectEqualStrings("1:6: cpu: the integer 300 does not fit a u8", line.buffered());
}
