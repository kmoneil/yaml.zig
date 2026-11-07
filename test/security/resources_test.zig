//! Input built to exhaust memory, the stack or time.

const std = @import("std");
const yaml = @import("yaml");
const testing = std.testing;
const gpa = testing.allocator;

/// Fails unless reading `text` as a Value fails, whatever the error.
fn expectRefused(text: []const u8, options: yaml.ParseOptions) !void {
    if (yaml.parseFromSlice(yaml.Value, gpa, text, options)) |parsed| {
        parsed.deinit();
        std.debug.print("read, and should not have been: {s}\n", .{text});
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "security: CWE-776 alias expansion (billion laughs)" {
    // Nine levels of nine aliases: 387,420,489 strings from 250 bytes.
    const bomb =
        \\a: &a ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]
        \\b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        \\c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        \\d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
        \\e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
        \\f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
        \\g: &g [*f,*f,*f,*f,*f,*f,*f,*f,*f]
        \\h: &h [*g,*g,*g,*g,*g,*g,*g,*g,*g]
        \\i: &i [*h,*h,*h,*h,*h,*h,*h,*h,*h]
        \\
    ;
    try testing.expectError(error.AliasLimit, yaml.parseFromSlice(yaml.Value, gpa, bomb, .{}));
    // Each node an alias builds counts, against a bound the caller sets.
    try testing.expectError(error.AliasLimit, yaml.parseFromSlice(yaml.Value, gpa, "a: &a [x, x]\nb: [*a, *a, *a]\n", .{ .max_alias_nodes = 5 }));
    // The node graph alone holds each node once: composing it is cheap.
    var composer: yaml.Composer = .init(gpa, bomb, .{});
    defer composer.deinit();
    _ = (try composer.next()).?;
}

test "security: CWE-407 merge-key fan-out is held to max_alias_nodes, and a mapping is merged once" {
    // With merge keys on, a mapping of 1,000 keys merged into each of
    // 2,000 mappings is two million pairs from 31 KB: a merged node counts
    // as an alias's does, and the defaults stop it.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "base: &b {");
    for (0..1000) |i| try text.print(gpa, "k{d}: v, ", .{i});
    try text.appendSlice(gpa, "}\nall:\n");
    for (0..2000) |_| try text.appendSlice(gpa, "- {<<: *b}\n");
    try testing.expectError(error.AliasLimit, yaml.parseFromSlice(yaml.Value, gpa, text.items, .{ .merge_keys = true }));
    // Merges that name a mapping twice at each of 30 levels: merged each
    // time it is named, 2^30 pairs; merged once, 30.
    text.clearRetainingCapacity();
    try text.appendSlice(gpa, "l0: &l0 {k0: 0}\n");
    for (1..30) |i| try text.print(gpa, "l{d}: &l{d} {{<<: [*l{d}, *l{d}], k{d}: {d}}}\n", .{ i, i, i - 1, i - 1, i, i });
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, text.items, .{ .merge_keys = true });
    defer parsed.deinit();
    try testing.expectEqual(30, parsed.value.get("l29").?.mapping.len);
}

test "security: CWE-674 an alias inside the node it names is a cycle, not followed" {
    try testing.expectError(error.Cycle, yaml.parseFromSlice(yaml.Value, gpa, "&a [x, *a]", .{}));
    try testing.expectError(error.Cycle, yaml.parseFromSlice(yaml.Value, gpa, "&a {k: *a}", .{}));
    const Chain = struct { next: ?*const @This() = null };
    try testing.expectError(error.Cycle, yaml.parseFromSlice(Chain, gpa, "&a {next: *a}", .{}));
}

test "security: CWE-674 nesting too deep for a stack is refused" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    // 100,000 open flow collections: the scanner stops at max_depth.
    try text.appendNTimes(gpa, '[', 100_000);
    try testing.expectError(error.DepthLimit, yaml.parseFromSlice(yaml.Value, gpa, text.items, .{}));
    // As many block sequences, one in each.
    text.clearRetainingCapacity();
    for (0..100_000) |_| try text.appendSlice(gpa, "- ");
    try text.appendSlice(gpa, "x\n");
    try testing.expectError(error.DepthLimit, yaml.parseFromSlice(yaml.Value, gpa, text.items, .{}));
    // Aliases add depth the text does not show: construction counts it.
    try testing.expectError(error.DepthLimit, yaml.parseFromSlice(yaml.Value, gpa, "a: &a [[[1]]]\nb: [[[*a]]]\n", .{ .max_depth = 5 }));
}

var deepest_result: anyerror!void = {};

fn readAndWriteDeepest() void {
    deepest_result = readAndWriteDeepestOrFail();
}

fn readAndWriteDeepestOrFail() !void {
    const depth = (yaml.ParseOptions{}).max_depth;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, '[', depth);
    try text.append(gpa, '1');
    try text.appendNTimes(gpa, ']', depth);
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, text.items, .{});
    defer parsed.deinit();
    for ([_]@FieldType(yaml.StringifyOptions, "style"){ .block, .flow }) |style| {
        const written = try yaml.stringifyAlloc(gpa, parsed.value, .{ .style = style });
        gpa.free(written);
    }
}

test "security: CWE-674 the deepest document the defaults take is read and written on a 512 KiB stack" {
    // Construction and stringify recurse; the scanner, parser, composer
    // and emitter do not. A frame grown past what ParseOptions.max_depth
    // says crashes here, in a Debug build first.
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, readAndWriteDeepest, .{});
    thread.join();
    try deepest_result;
}

test "security: CWE-407 %TAG directives past max_tag_directives are refused" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..100_000) |i| try text.print(gpa, "%TAG !h{d}! p:\n", .{i});
    try text.appendSlice(gpa, "--- x\n");
    var diagnostic: yaml.Diagnostic = .{};
    try testing.expectError(error.TagDirectiveLimit, yaml.parseFromSlice(yaml.Value, gpa, text.items, .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(64, diagnostic.mark.line);
}

test "security: CWE-835 inputs that once looped forever end" {
    // A NUL byte after a block scalar's header (t43, found by fuzzing).
    try expectRefused("-1.5e3-!!str - a\n--- |\x00\n  b\n...\n# c\n", .{});
    try expectRefused("a: >\n  b\n  \x00\n", .{});
    // A flow mapping left open at the input's end (t20).
    try expectRefused("{a: 1, b", .{});
    try expectRefused("[{a: [b, {c", .{});
}

test "security: CWE-407 keys built to collide under a fixed seed spread in an ArrayHashMap" {
    // 400 keys whose hashes under the map's default seed fall in one of
    // 1,024 buckets, as an attacker who knew the seed would choose them.
    const Map = yaml.ArrayHashMap(u8);
    const fixed: @FieldType(Map, "context") = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (keys.items.len < 400) : (i += 1) {
        const key = try a.print("k{d}", .{i});
        if (fixed.hash(key) & 1023 != 0) continue;
        try keys.append(a, key);
        try text.print(a, "{s}: 1\n", .{key});
    }
    const parsed = try yaml.parseFromSlice(Map, gpa, text.items, .{});
    defer parsed.deinit();
    try testing.expectEqual(400, parsed.value.count());
    // Under the seed construction gave the map, they spread: 400 random
    // hashes fill about 330 of 1,024 buckets; the fixed seed, one.
    var buckets: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (keys.items) |key| try buckets.put(a, parsed.value.context.hash(key) & 1023, {});
    try testing.expect(buckets.count() > 250);
}

var block_result: anyerror!void = {};

fn readBlockScalars() void {
    block_result = readBlockScalarsOrFail();
}

fn readBlockScalarsOrFail() !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for ([_][]const u8{ "a: |\n", "b: >\n" }) |head| {
        try text.appendSlice(gpa, head);
        for (0..100_000) |_| try text.appendSlice(gpa, "  a line of the scalar\n");
    }
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, text.items, .{});
    defer parsed.deinit();
    try testing.expectEqual(100_000 * "a line of the scalar\n".len, parsed.value.get("a").?.string.len);
}

test "security: CWE-121 a block scalar of megabytes is built on the heap" {
    // Two of 2.3 MB each, on a 256 KiB stack: a scalar's text grows in
    // the scanner's arena, never on the stack.
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readBlockScalars, .{});
    thread.join();
    try block_result;
}
