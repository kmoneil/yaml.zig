//! Typed construction's tests: each kind of type, Value, the errors and
//! their diagnostics, the limits, and a sweep of allocation failures.

const std = @import("std");
const testing = std.testing;
const yaml = @import("root.zig");

const Level = enum { debug, info, warn };

const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    debug: bool = false,
    ratio: f64,
    level: Level,
    tags: []const []const u8,
    limits: [2]u8,
    owner: ?[]const u8 = null,
    backup: ?*const Config = null,
    pair: struct { u8, []const u8 },
    mode: union(enum) { off, every: u32 },
};

const config_text =
    \\name: web
    \\debug: true
    \\ratio: 0.5
    \\level: warn
    \\tags: [a, "b", 3]
    \\limits: [1, 0x2]
    \\backup:
    \\  name: spare
    \\  ratio: 1
    \\  level: debug
    \\  tags: []
    \\  limits: [0, 0]
    \\  pair: [0, x]
    \\  mode: off
    \\pair: [7, seven]
    \\mode: {every: 30}
    \\
;

test "a struct of every kind of field, defaults filled" {
    const parsed = try yaml.parseFromSlice(Config, testing.allocator, config_text, .{});
    defer parsed.deinit();
    const c = parsed.value;
    try testing.expectEqualStrings("web", c.name);
    try testing.expectEqual(8080, c.port);
    try testing.expect(c.debug);
    try testing.expectEqual(0.5, c.ratio);
    try testing.expectEqual(.warn, c.level);
    try testing.expectEqual(3, c.tags.len);
    try testing.expectEqualStrings("3", c.tags[2]);
    try testing.expectEqual([2]u8{ 1, 2 }, c.limits);
    try testing.expectEqual(null, c.owner);
    try testing.expectEqualStrings("spare", c.backup.?.name);
    try testing.expectEqual(1.0, c.backup.?.ratio);
    try testing.expectEqual(.off, c.backup.?.mode);
    try testing.expectEqual(7, c.pair[0]);
    try testing.expectEqualStrings("seven", c.pair[1]);
    try testing.expectEqual(30, c.mode.every);
}

test "Value: any document, keys of any kind, big integers as text" {
    const parsed = try yaml.parseFromSlice(yaml.Value, testing.allocator, "a: [1, 2.5, true, ~, x]\n? [k]\n: v\nbig: 99999999999999999999\nref: &r {x: 1}\nagain: *r\n", .{});
    defer parsed.deinit();
    const v = parsed.value;
    const a = v.get("a").?.sequence;
    try testing.expectEqual(1, a[0].integer);
    try testing.expectEqual(2.5, a[1].float);
    try testing.expect(a[2].bool);
    try testing.expectEqual(.null, std.meta.activeTag(a[3]));
    try testing.expectEqualStrings("x", a[4].string);
    try testing.expectEqualStrings("k", v.mapping[1].key.sequence[0].string);
    try testing.expectEqualStrings("99999999999999999999", v.get("big").?.number_string);
    try testing.expectEqual(1, v.get("again").?.get("x").?.integer);
    try testing.expectEqual(null, v.get("missing"));
}

test "an empty stream is a null document" {
    try testing.expectEqual(null, try yaml.parseFromSliceLeaky(?u8, testing.allocator, "# nothing\n", .{}));
    try testing.expectEqual(.null, std.meta.activeTag(try yaml.parseFromSliceLeaky(yaml.Value, testing.allocator, "", .{})));
}

fn expectFailure(comptime T: type, input: []const u8, options: yaml.ParseOptions, err: anyerror, line: usize, column: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: yaml.Diagnostic = .{};
    var with = options;
    with.diagnostic = &diagnostic;
    errdefer std.debug.print("input: {s}\ndiagnostic: {d}:{d} {s}\n", .{ input, diagnostic.mark.line + 1, diagnostic.mark.column + 1, diagnostic.message });
    try testing.expectError(err, yaml.parseFromSliceLeaky(T, arena.allocator(), input, with));
    try testing.expectEqual(line, diagnostic.mark.line + 1);
    try testing.expectEqual(column, diagnostic.mark.column + 1);
}

test "errors, each with where it is" {
    const S = struct { a: u8, b: bool = false };
    try expectFailure(S, "a: 1\nb: yes\n", .{}, error.UnexpectedType, 2, 4);
    try expectFailure(S, "a: 300\n", .{}, error.Overflow, 1, 4);
    try expectFailure(S, "a: 1.5\n", .{}, error.UnexpectedType, 1, 4);
    try expectFailure(S, "b: true\n", .{}, error.MissingField, 1, 1);
    try expectFailure(S, "a: 1\nc: 2\n", .{}, error.UnknownField, 2, 1);
    try expectFailure(S, "a: 1\na: 2\n", .{}, error.DuplicateKey, 2, 1);
    try expectFailure(S, "a: [1\n", .{}, error.SyntaxError, 2, 1);
    try expectFailure(S, "--- {a: 1}\n--- {a: 2}\n", .{}, error.MultipleDocuments, 2, 1);
    try expectFailure([]const u8, "~", .{}, error.UnexpectedType, 1, 1);
    try expectFailure([2]u8, "[1, 2, 3]", .{}, error.UnexpectedType, 1, 1);
    try expectFailure(Level, "loud", .{}, error.UnexpectedType, 1, 1);
    try expectFailure(u8, "a: *nowhere", .{}, error.UndefinedAlias, 1, 4);
    try expectFailure(u8, "[x, y]", .{ .schema = .json }, error.NotInSchema, 1, 2);
}

test "a float into an integer: up to the type's edge, and not past it" {
    // As f64s, maxInt(i64) and maxInt(u64) round up to 2^63 and 2^64,
    // which do not fit: the edge is the largest f64 below them.
    try testing.expectEqual(9223372036854774784, try yaml.parseFromSliceLeaky(i64, testing.allocator, "9223372036854774784.0", .{}));
    try testing.expectEqual(-9223372036854775808, try yaml.parseFromSliceLeaky(i64, testing.allocator, "-9223372036854775808.0", .{}));
    try testing.expectEqual(18446744073709549568, try yaml.parseFromSliceLeaky(u64, testing.allocator, "1.8446744073709549568e19", .{}));
    try testing.expectEqual(255, try yaml.parseFromSliceLeaky(u8, testing.allocator, "255.0", .{}));
    try testing.expectEqual(-128, try yaml.parseFromSliceLeaky(i8, testing.allocator, "-128.0", .{}));
    try testing.expectEqual(0, try yaml.parseFromSliceLeaky(u0, testing.allocator, "0.0", .{}));
    // 2^63, the next f64 below -2^63, 2^64, 2^127, 2^128.
    try expectFailure(i64, "9223372036854775808.0", .{}, error.Overflow, 1, 1);
    try expectFailure(i64, "-9223372036854777856.0", .{}, error.Overflow, 1, 1);
    try expectFailure(u64, "1.8446744073709552e19", .{}, error.Overflow, 1, 1);
    try expectFailure(i128, "1.7014118346046923e38", .{}, error.Overflow, 1, 1);
    try expectFailure(u128, "3.402823669209385e38", .{}, error.Overflow, 1, 1);
    try expectFailure(u8, "256.0", .{}, error.Overflow, 1, 1);
    try expectFailure(i8, "-129.0", .{}, error.Overflow, 1, 1);
    try expectFailure(u64, "-1.0", .{}, error.Overflow, 1, 1);
    try expectFailure(u0, "1.0", .{}, error.Overflow, 1, 1);
}

test "an integer wider than 128 bits, from integer text and from a float" {
    const gpa = testing.allocator;
    try testing.expectEqual(std.math.maxInt(u256), try yaml.parseFromSliceLeaky(u256, gpa, "115792089237316195423570985008687907853269984665640564039457584007913129639935", .{}));
    try testing.expectEqual(std.math.minInt(i256), try yaml.parseFromSliceLeaky(i256, gpa, "-57896044618658097711785492504343953926634992332820282019728792003956564819968", .{}));
    // Floats written as Zig writes them, so each reads back the f64 it
    // was: the largest below 2^256, -2^255, and past each edge.
    var buf: [64]u8 = undefined;
    const below = std.math.ldexp(@as(f64, (1 << 53) - 1), 203);
    try testing.expectEqual(@as(u256, (1 << 53) - 1) << 203, try yaml.parseFromSliceLeaky(u256, gpa, try std.fmt.bufPrint(&buf, "{e}", .{below}), .{}));
    try testing.expectEqual(std.math.minInt(i256), try yaml.parseFromSliceLeaky(i256, gpa, try std.fmt.bufPrint(&buf, "{e}", .{-std.math.ldexp(@as(f64, 1), 255)}), .{}));
    try testing.expectEqual(-3, try yaml.parseFromSliceLeaky(i256, gpa, "-3.0", .{}));
    try testing.expectEqual(0, try yaml.parseFromSliceLeaky(u256, gpa, "-0.0", .{}));
    try expectFailure(u256, try std.fmt.bufPrint(&buf, "{e}", .{std.math.ldexp(@as(f64, 1), 256)}), .{}, error.Overflow, 1, 1);
    try expectFailure(i256, try std.fmt.bufPrint(&buf, "{e}", .{std.math.ldexp(@as(f64, 1), 255)}), .{}, error.Overflow, 1, 1);
    try expectFailure(u256, "1.5", .{}, error.UnexpectedType, 1, 1);
}

test "an integer into a u128, past an i128 too" {
    try testing.expectEqual(std.math.maxInt(u128), try yaml.parseFromSliceLeaky(u128, testing.allocator, "340282366920938463463374607431768211455", .{}));
    try testing.expectEqual(std.math.maxInt(u128), try yaml.parseFromSliceLeaky(u128, testing.allocator, "0xffffffffffffffffffffffffffffffff", .{}));
    try expectFailure(u128, "340282366920938463463374607431768211456", .{}, error.Overflow, 1, 1);
    try expectFailure(u8, "-1", .{}, error.Overflow, 1, 1);
}

test "a scalar whose text is not what its tag says is refused, wherever it is built" {
    for ([_][]const u8{ "!!int foo", "!!int 1.5", "!!float foo", "!!bool yes", "!!null foo" }) |text| {
        try expectFailure(yaml.Value, text, .{}, error.UnexpectedType, 1, 1);
        try expectFailure([]const u8, text, .{}, error.UnexpectedType, 1, 1);
        try expectFailure(?u8, text, .{}, error.UnexpectedType, 1, 1);
    }
    try expectFailure(i32, "!!int foo", .{}, error.UnexpectedType, 1, 1);
    try expectFailure(f64, "!!float foo", .{}, error.UnexpectedType, 1, 1);
    try expectFailure(bool, "!!bool yes", .{}, error.UnexpectedType, 1, 1);
    try expectFailure(Level, "!!int warn", .{}, error.UnexpectedType, 1, 1);
    // As a key: a struct's, a union's, a map's.
    try expectFailure(struct { a: u8 }, "!!int a: 1", .{}, error.UnexpectedType, 1, 1);
    try expectFailure(union(enum) { a: u8 }, "{!!bool a: 1}", .{}, error.UnexpectedType, 1, 2);
    try expectFailure(yaml.ArrayHashMap(u8), "!!float k: 1", .{}, error.UnexpectedType, 1, 1);

    var diagnostic: yaml.Diagnostic = .{};
    try testing.expectError(error.UnexpectedType, yaml.parseFromSlice(struct { n: i32 }, testing.allocator, "n: !!int foo", .{ .diagnostic = &diagnostic }));
    try testing.expectEqualStrings("n", diagnostic.path());
    try testing.expectEqualStrings("the scalar \"foo\" is tagged !!int but is not an integer", diagnostic.detail());

    // Written as one, each tag reads.
    try testing.expectEqual(31, try yaml.parseFromSliceLeaky(u8, testing.allocator, "!!int 0x1F", .{}));
    try testing.expectEqual(1.0, try yaml.parseFromSliceLeaky(f64, testing.allocator, "!!float 1", .{}));
    try testing.expectEqual(null, try yaml.parseFromSliceLeaky(?u8, testing.allocator, "!!null ~", .{}));
    try testing.expect(try yaml.parseFromSliceLeaky(bool, testing.allocator, "!!bool True", .{}));
}

test "options: unknown fields skipped, duplicate keys keep the last" {
    const S = struct { a: u8 };
    try testing.expectEqual(1, (try yaml.parseFromSliceLeaky(S, testing.allocator, "a: 1\nz: [deep, {x: y}]\n", .{ .ignore_unknown_fields = true })).a);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(2, (try yaml.parseFromSliceLeaky(S, arena.allocator(), "a: 1\na: 2\n", .{ .duplicate_keys = .keep })).a);
    try testing.expectEqualStrings("1", try yaml.parseFromSliceLeaky([]const u8, arena.allocator(), "1", .{ .schema = .failsafe }));
}

test "limits: a cycle, an alias bomb, depth" {
    const Node = struct { next: ?*const @This() = null };
    try expectFailure(Node, "&a {next: *a}", .{}, error.Cycle, 1, 11);
    try expectFailure(yaml.Value, "&a [x, *a]", .{}, error.Cycle, 1, 8);
    // Nine levels of ten aliases each: a billion strings from 250 bytes.
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
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.AliasLimit, yaml.parseFromSliceLeaky(yaml.Value, arena.allocator(), bomb, .{}));
    // Aliases used a few times are fine.
    const reused = try yaml.parseFromSliceLeaky(yaml.Value, arena.allocator(), "a: &x [1, 2]\nb: *x\nc: *x\n", .{ .max_alias_nodes = 6 });
    try testing.expectEqual(2, reused.get("c").?.sequence.len);
    // The scanner stops the fourth collection.
    try expectFailure(yaml.Value, "[[[[[[1]]]]]]", .{ .max_depth = 3 }, error.DepthLimit, 1, 4);
    // Aliases nest deeper than the text: construction stops them.
    try expectFailure(yaml.Value, "a: &a [[1]]\nb: [[*a]]\n", .{ .max_depth = 4 }, error.DepthLimit, 1, 9);
}

fn parseAndFree(allocator: std.mem.Allocator) !void {
    const parsed = try yaml.parseFromSlice(Config, allocator, config_text, .{});
    defer parsed.deinit();
    const job = try yaml.parseFromSlice(Job, allocator, "run: {argv: [a, b], cwd: c}\n", .{});
    defer job.deinit();
    const value = try yaml.parseFromSlice(yaml.Value, allocator, config_text, .{});
    defer value.deinit();
}

const Exec = struct { argv: []const []const u8, cwd: ?[]const u8 = null };

/// A command that reads itself: a line for the shell, or a program and
/// its arguments.
const Run = union(enum) {
    shell: []const u8,
    exec: Exec,

    pub fn yamlParse(c: yaml.Construction) yaml.ParseError!Run {
        return switch (c.node.data) {
            .scalar => .{ .shell = try c.build([]const u8, c.node) },
            .mapping => .{ .exec = try c.build(Exec, c.node) },
            else => c.failExpected(c.node, "a command, a string or a mapping"),
        };
    }
};

const Job = struct { name: []const u8 = "", run: Run };

test "a type's own yamlParse: a string or a mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shell = try yaml.parseFromSliceLeaky(Job, a, "run: python train.py\n", .{});
    try testing.expectEqualStrings("python train.py", shell.run.shell);
    const exec = try yaml.parseFromSliceLeaky(Job, a, "run: {argv: [python, train.py], cwd: src}\n", .{});
    try testing.expectEqualStrings("train.py", exec.run.exec.argv[1]);
    try testing.expectEqualStrings("src", exec.run.exec.cwd.?);
    // As a sequence's items, one through an alias.
    const many = try yaml.parseFromSliceLeaky([]const Run, a, "- &x {argv: [a]}\n- *x\n- b c\n", .{});
    try testing.expectEqual(3, many.len);
    try testing.expectEqualStrings("a", many[1].exec.argv[0]);
    try testing.expectEqualStrings("b c", many[2].shell);
}

test "a type's own yamlParse: errors keep their path, its own are at its node" {
    try expectLine(Job, "run: {argv: [python, {x: 1}]}\n", "1:22: run.argv[1]: expected a string, found a mapping");
    try expectLine(Job, "name: j\nrun: [a, b]\n", "2:6: run: expected a command, a string or a mapping, found a sequence");
    try expectFailure(Job, "run: &r {argv: [*r]}\n", .{}, error.Cycle, 1, 17);
    try expectFailure(Job, "run: !!int x\n", .{}, error.UnexpectedType, 1, 6);
}

test "limits: %TAG directives, through ParseOptions" {
    try expectFailure(u8, "%TAG !a! x:\n%TAG !b! y:\n--- 1\n", .{ .max_tag_directives = 1 }, error.TagDirectiveLimit, 2, 1);
    try testing.expectEqual(1, try yaml.parseFromSliceLeaky(u8, testing.allocator, "%TAG !a! x:\n--- 1\n", .{ .max_tag_directives = 1 }));
}

const Chain = struct { next: ?*const @This() = null };

/// Builds the deepest documents the default options take: collections
/// nested max_depth deep, and a struct through pointers, where each
/// level is two (the field, and the pointer).
fn buildDeepest(gpa: std.mem.Allocator) !void {
    const depth = (yaml.ParseOptions{}).max_depth;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, '[', depth);
    try text.append(gpa, '1');
    try text.appendNTimes(gpa, ']', depth);
    const value = try yaml.parseFromSlice(yaml.Value, gpa, text.items, .{});
    value.deinit();

    text.clearRetainingCapacity();
    for (0..depth / 2) |_| try text.appendSlice(gpa, "{next: ");
    try text.appendNTimes(gpa, '}', depth / 2);
    const chain = try yaml.parseFromSlice(Chain, gpa, text.items, .{});
    chain.deinit();
}

fn runBuildDeepest(result: *anyerror!void) void {
    result.* = buildDeepest(testing.allocator);
}

test "limits: the deepest documents the defaults take build on a 512 KiB stack" {
    // As ParseOptions.max_depth and README say. A level's frame grown
    // past what they say crashes here, in a Debug build first.
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runBuildDeepest, .{&result});
    thread.join();
    try result;
}

test "every allocation may fail, and nothing leaks when one does" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{});
}

/// The line a tool prints for a failed read: `line:column: path: detail`.
fn expectLine(comptime T: type, input: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: yaml.Diagnostic = .{};
    if (yaml.parseFromSliceLeaky(T, arena.allocator(), input, .{ .diagnostic = &diagnostic })) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{diagnostic});
    try testing.expectEqualStrings(expected, w.buffered());
}

const Machine = struct {
    types: []const []const u8,
    zones: []const []const u8 = &.{},
    spot: bool = false,
    image: []const u8 = "debian",
};
const JobSpec = struct { name: []const u8, machine: Machine, env: yaml.ArrayHashMap(u16) = .{} };

test "diagnostics: a detail too long for its buffer is cut where a character begins" {
    const S = struct { a: u8 };
    // An odd and an even number of bytes before the key's é's, so one of
    // the two cuts would land inside one.
    for ([_][]const u8{ "", "a" }) |lead| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try text.appendSlice(testing.allocator, lead);
        for (0..300) |_| try text.appendSlice(testing.allocator, "é");
        try text.appendSlice(testing.allocator, ": 1\n");
        var diagnostic: yaml.Diagnostic = .{};
        try testing.expectError(error.UnknownField, yaml.parseFromSlice(S, testing.allocator, text.items, .{ .diagnostic = &diagnostic }));
        try testing.expect(std.mem.endsWith(u8, diagnostic.detail(), "..."));
        try testing.expect(std.unicode.utf8ValidateSlice(diagnostic.detail()));
    }
}

test "diagnostics: an unknown field named, the fields listed, the near one suggested" {
    try expectLine(JobSpec, "name: x\nmachine:\n  types: [e2]\n  zone: a\n",
        \\4:3: machine: unknown field "zone"; expected one of: types, zones, spot, image (did you mean "zones"?)
    );
    try expectLine(JobSpec, "name: x\nmachine:\n  types: [e2]\n  colour: red\n",
        \\4:3: machine: unknown field "colour"; expected one of: types, zones, spot, image
    );
}

test "diagnostics: a missing field named, at the mapping without it" {
    try expectLine(JobSpec, "name: x\nmachine:\n  spot: true\n",
        \\3:3: machine: missing field "types"
    );
    try expectLine(JobSpec, "machine: {types: []}\n",
        \\1:1: missing field "name"
    );
}

test "diagnostics: a wrong type three levels deep, a sequence index in the path" {
    try expectLine(JobSpec, "name: x\nmachine:\n  types:\n  - e2\n  - n2\n  - {big: yes}\n",
        \\6:5: machine.types[2]: expected a string, found a mapping
    );
    try expectLine(JobSpec, "name: x\nmachine: {types: [a], spot: maybe}\n",
        \\2:29: machine.spot: expected a boolean, found the string "maybe"
    );
    try expectLine(JobSpec, "name: x\nmachine: {types: [a]}\nenv: {\"PORT NUMBER\": 70000}\n",
        \\3:22: env."PORT NUMBER": the integer 70000 does not fit a u16
    );
}

test "diagnostics: an enum's names, and errors before construction print plainly" {
    const S = struct { level: enum { debug, info, warn } };
    try expectLine(S, "level: wran\n",
        \\1:8: level: no value is named "wran"; expected one of: debug, info, warn (did you mean "warn"?)
    );
    try expectLine(S, "level: [debug\n",
        \\2:1: a flow sequence's entries need a ',' between them, and a ']' after
    );
}
