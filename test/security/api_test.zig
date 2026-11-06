//! A program's use of the API in ways input can bring about.

const std = @import("std");
const yaml = @import("yaml");
const testing = std.testing;
const gpa = testing.allocator;

test "security: CWE-372 each stage gives its first error again after it" {
    // Called again after an error, a stage whose state the error left
    // half-changed would read on from it: each gives the error instead.
    var scanner: yaml.Scanner = .init(gpa, "a: \"open\n");
    defer scanner.deinit();
    while (true) {
        _ = scanner.next() catch |err| {
            for (0..3) |_| try testing.expectError(err, scanner.next());
            break;
        };
    }
    var parser: yaml.Parser = .init(gpa, "a: [b, c\n");
    defer parser.deinit();
    while (true) {
        _ = parser.next() catch |err| {
            for (0..3) |_| try testing.expectError(err, parser.next());
            break;
        };
    }
    var composer: yaml.Composer = .init(gpa, "{a: 1, a: 2, b: [x]}\n", .{});
    defer composer.deinit();
    try testing.expectError(error.DuplicateKey, composer.next());
    for (0..3) |_| try testing.expectError(error.DuplicateKey, composer.next());
}

test "security: CWE-190 an input longer than a signed size holds is refused" {
    // Columns are compared as isizes. A slice as long as that, made from
    // four real bytes: the scanner must refuse it before it reads past
    // them (2 GiB on a 32-bit target).
    const bytes: [4]u8 = "a: b".*;
    // Its length known only at run time, so the slice is no array type.
    var len: usize = std.math.maxInt(isize);
    len += 1;
    const huge = @as([*]const u8, &bytes)[0..len];
    var scanner: yaml.Scanner = .init(gpa, huge);
    defer scanner.deinit();
    try testing.expectError(error.SyntaxError, scanner.next());
    try testing.expectEqualStrings("the input is longer than this target can count in a signed size", scanner.diagnostic.message);
}
