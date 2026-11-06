const std = @import("std");
const yaml = @import("yaml");

test "events in, YAML out: reformat a stream" {
    const gpa = std.testing.allocator;
    const text = "{name: web,   ports: [80,443]}\n";

    var parser: yaml.Parser = .init(gpa, text);
    defer parser.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var emitter: yaml.Emitter = .init(gpa, &out.writer, .{});
    defer emitter.deinit();

    // Pass each event on, a flow collection made block on the way.
    while (true) {
        var event = try parser.next();
        switch (event.data) {
            .mapping_start, .sequence_start => |*c| c.flow = false,
            else => {},
        }
        try emitter.emit(event);
        if (event.data == .stream_end) break;
    }
    try std.testing.expectEqualStrings(
        \\name: web
        \\ports:
        \\- 80
        \\- 443
        \\
    , out.written());
}
