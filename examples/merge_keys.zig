const std = @import("std");
const yaml = @import("yaml");

test "merge keys: shared settings, as compose files write them" {
    const text =
        \\defaults: &defaults
        \\  image: alpine
        \\  restart: always
        \\services:
        \\  web:
        \\    <<: *defaults
        \\    port: 8080
        \\  worker:
        \\    <<: *defaults
        \\    restart: on-failure
        \\
    ;
    const Service = struct { image: []const u8, restart: []const u8, port: ?u16 = null };
    const Compose = struct { defaults: Service, services: yaml.ArrayHashMap(Service) };

    // YAML 1.2 dropped `<<`, but most tools still apply it: turn it on.
    const parsed = try yaml.parseFromSlice(Compose, std.testing.allocator, text, .{ .merge_keys = true });
    defer parsed.deinit();

    const worker = parsed.value.services.get("worker").?;
    try std.testing.expectEqualStrings("alpine", worker.image); // merged in
    try std.testing.expectEqualStrings("on-failure", worker.restart); // its own key wins
    try std.testing.expectEqual(8080, parsed.value.services.get("web").?.port);
}
