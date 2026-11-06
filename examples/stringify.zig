const std = @import("std");
const yaml = @import("yaml");

test "write a value as YAML, and read it back" {
    const Release = struct {
        version: []const u8,
        stable: bool,
        notes: []const []const u8,
    };
    const release: Release = .{
        .version = "1.10", // would read back as a number if written plain
        .stable = true,
        .notes = &.{ "faster", "yes" }, // and so would yes, to YAML 1.1 readers
    };

    const text = try yaml.stringifyAlloc(std.testing.allocator, release, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\version: '1.10'
        \\stable: true
        \\notes:
        \\- faster
        \\- 'yes'
        \\
    , text);

    const again = try yaml.parseFromSlice(Release, std.testing.allocator, text, .{});
    defer again.deinit();
    try std.testing.expectEqualDeep(release, again.value);
}
