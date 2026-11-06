const std = @import("std");
const yaml = @import("yaml");

test "a stream of documents, with anchors and aliases" {
    const text =
        \\--- &base
        \\image: alpine
        \\retries: 3
        \\--- [a, b]
        \\
    ;
    var composer: yaml.Composer = .init(std.testing.allocator, text, .{});
    defer composer.deinit();

    // Each document is a graph of nodes, tags resolved by the schema.
    const first = (try composer.next()).?;
    try std.testing.expectEqualStrings("base", first.root.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:int", first.root.data.mapping.pairs[1].value.tag.?);

    const second = (try composer.next()).?;
    try std.testing.expectEqual(2, second.root.data.sequence.items.len);
    try std.testing.expectEqual(null, try composer.next());
}
