//! ArrayHashMap's tests: as a field parseFromSlice builds and stringify
//! writes, in order, with duplicate keys, bad keys, and allocation
//! failures.

const std = @import("std");
const testing = std.testing;
const yaml = @import("root.zig");

const Job = struct {
    image: []const u8,
    env: yaml.ArrayHashMap([]const u8) = .{},
    limits: yaml.ArrayHashMap(u32) = .{},
};

test "a map field takes a mapping's keys in the document's order" {
    const text =
        \\image: alpine
        \\env:
        \\  NAME: web
        \\  OTHER: "x y"
        \\  EMPTY: ''
        \\limits: {B: 2, A: 1}
        \\
    ;
    const parsed = try yaml.parseFromSlice(Job, testing.allocator, text, .{});
    defer parsed.deinit();
    const job = parsed.value;
    try testing.expectEqual(3, job.env.count());
    try testing.expectEqualStrings("NAME", job.env.keys()[0]);
    try testing.expectEqualStrings("EMPTY", job.env.keys()[2]);
    try testing.expectEqualStrings("x y", job.env.get("OTHER").?);
    try testing.expectEqual(null, job.env.get("MISSING"));
    try testing.expectEqualStrings("B", job.limits.keys()[0]);
    try testing.expectEqual(1, job.limits.get("A").?);
    // Hashed with a seed from the input, not a fixed one.
    try testing.expect(job.env.context.seed != 0);
}

test "keys are any scalar's text; a missing map is its default, empty" {
    const parsed = try yaml.parseFromSlice(yaml.ArrayHashMap(bool), testing.allocator, "1: true\n~: false\n'q': true\n", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("1", parsed.value.keys()[0]);
    try testing.expectEqualStrings("~", parsed.value.keys()[1]);
    try testing.expect(parsed.value.get("q").?);
    const bare = try yaml.parseFromSlice(Job, testing.allocator, "image: x\n", .{});
    defer bare.deinit();
    try testing.expectEqual(0, bare.value.env.count());
}

test "duplicate keys: refused, or kept with the last value in the first place" {
    const text = "env: {A: 1, B: 2, A: 3}\nimage: x\n";
    var diagnostic: yaml.Diagnostic = .{};
    try testing.expectError(error.DuplicateKey, yaml.parseFromSlice(Job, testing.allocator, text, .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(18, diagnostic.mark.column);
    const M = struct { env: yaml.ArrayHashMap(u8) };
    const kept = try yaml.parseFromSlice(M, testing.allocator, text[0 .. text.len - "image: x\n".len], .{ .duplicate_keys = .keep });
    defer kept.deinit();
    try testing.expectEqual(2, kept.value.env.count());
    try testing.expectEqualStrings("A", kept.value.env.keys()[0]);
    try testing.expectEqual(3, kept.value.env.get("A").?);
}

test "a key that is a collection fails at the key" {
    var diagnostic: yaml.Diagnostic = .{};
    const text = "image: x\nenv:\n  A: 1\n  [b]: 2\n";
    try testing.expectError(error.UnexpectedType, yaml.parseFromSlice(Job, testing.allocator, text, .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(3, diagnostic.mark.line);
    try testing.expectEqual(2, diagnostic.mark.column);
    // So does a value of the wrong type, at the value.
    try testing.expectError(error.UnexpectedType, yaml.parseFromSlice(Job, testing.allocator, "image: x\nlimits: {A: big}\n", .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(12, diagnostic.mark.column);
}

test "stringify writes a map back in its order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var job: Job = .{ .image = "alpine" };
    try job.env.put(a, "Z", "last letter");
    try job.env.put(a, "A", "true");
    const text = try yaml.stringifyAlloc(a, job, .{});
    try testing.expectEqualStrings("image: alpine\nenv:\n  Z: last letter\n  A: 'true'\nlimits: {}\n", text);
    const again = try yaml.parseFromSliceLeaky(Job, a, text, .{});
    try testing.expectEqualStrings("Z", again.env.keys()[0]);
    try testing.expectEqualStrings("true", again.env.get("A").?);
}

fn parseAndFree(gpa: std.mem.Allocator) !void {
    const parsed = try yaml.parseFromSlice(Job, gpa, "image: x\nenv: {A: a, B: b, C: c}\nlimits:\n  X: 1\n", .{});
    parsed.deinit();
}

test "every allocation may fail, and nothing leaks when one does" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{});
}
