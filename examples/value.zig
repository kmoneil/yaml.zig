const std = @import("std");
const yaml = @import("yaml");

test "a document of any shape: Value" {
    const text =
        \\server:
        \\  host: example.com
        \\  ports: [80, 443]
        \\  ratio: 0.75
        \\  owner: ~
        \\
    ;
    const parsed = try yaml.parseFromSlice(yaml.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();

    // Scalars are typed by the core schema: 80 is an integer, ~ is null.
    const server = parsed.value.get("server").?;
    try std.testing.expectEqualStrings("example.com", server.get("host").?.string);
    try std.testing.expectEqual(443, server.get("ports").?.sequence[1].integer);
    try std.testing.expectEqual(0.75, server.get("ratio").?.float);
    try std.testing.expect(server.get("owner").? == .null);
}
