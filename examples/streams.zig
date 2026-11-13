const std = @import("std");
const yaml = @import("yaml");

const Manifest = struct { kind: []const u8, name: []const u8 };

test "a stream of documents, in order or side by side" {
    const text =
        \\kind: Service
        \\name: web
        \\---
        \\kind: Deployment
        \\name: web
        \\
    ;
    const all = try yaml.parseDocuments(Manifest, std.testing.allocator, text, .{});
    defer all.deinit();
    try std.testing.expectEqual(2, all.value.len);
    try std.testing.expectEqualStrings("Deployment", all.value[1].kind);

    // The same documents, read side by side on an Io's threads. Its
    // allocator must be threadsafe, as the testing allocator is.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const again = try yaml.parseDocumentsConcurrently(Manifest, threaded.io(), std.testing.allocator, text, .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("web", again.value[0].name);
}
