const std = @import("std");
const yaml = @import("yaml");

test "quick start: read a document into a struct" {
    const Config = struct {
        name: []const u8,
        port: u16 = 8080,
        tags: []const []const u8 = &.{},
        debug: bool = false,
    };
    const text =
        \\name: web
        \\tags: [blue, green]
        \\debug: true
        \\
    ;

    // The result owns an arena holding everything it points at.
    const parsed = try yaml.parseFromSlice(Config, std.testing.allocator, text, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("web", parsed.value.name);
    try std.testing.expectEqual(8080, parsed.value.port); // not in the text: the default
    try std.testing.expectEqualStrings("green", parsed.value.tags[1]);
    try std.testing.expect(parsed.value.debug);
}
