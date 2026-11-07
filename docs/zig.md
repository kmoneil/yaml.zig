---
title: The library
nav_order: 2
---

# The library

Add the package as [Install](index.md#install) shows, then `@import("yaml")`.
Every example here is a test that `zig build test` runs.

## Read YAML into a struct

<!-- example: examples/quick_start.zig -->
```zig
const std = @import("std");
const yaml = @import("yaml");

test "quick start: read a document into a struct" {
    const Config = struct {
        name: []const u8,
        port: u16 = 8080,
        tags: []const []const u8 = &.{},
        debug: bool = false,
    };
    const text =
        \\name: web
        \\tags: [blue, green]
        \\debug: true
        \\
    ;

    // The result owns an arena holding everything it points at.
    const parsed = try yaml.parseFromSlice(Config, std.testing.allocator, text, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("web", parsed.value.name);
    try std.testing.expectEqual(8080, parsed.value.port); // not in the text: the default
    try std.testing.expectEqualStrings("green", parsed.value.tags[1]);
    try std.testing.expect(parsed.value.debug);
}
```

Fields you leave out of the file take their defaults. Booleans,
integers, floats, strings, enums, optionals, slices, arrays, nested
structs and tagged unions all work. For keys you don't know ahead of
time, such as environment variables, use `yaml.ArrayHashMap(T)`: it
keeps them in order.

## Read YAML of any shape

When you don't have a type for it, read a `yaml.Value`:

<!-- example: examples/value.zig -->
```zig
const std = @import("std");
const yaml = @import("yaml");

test "a document of any shape: Value" {
    const text =
        \\server:
        \\  host: example.com
        \\  ports: [80, 443]
        \\  ratio: 0.75
        \\  owner: ~
        \\
    ;
    const parsed = try yaml.parseFromSlice(yaml.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();

    // Scalars are typed by the core schema: 80 is an integer, ~ is null.
    const server = parsed.value.get("server").?;
    try std.testing.expectEqualStrings("example.com", server.get("host").?.string);
    try std.testing.expectEqual(443, server.get("ports").?.sequence[1].integer);
    try std.testing.expectEqual(0.75, server.get("ratio").?.float);
    try std.testing.expect(server.get("owner").? == .null);
}
```

## Write YAML

<!-- example: examples/stringify.zig -->
```zig
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
```

Strings that would read back as something else get quoted: `1.10`
would become a number, and `yes` a boolean to older YAML readers.
`stringify` writes to any `*std.Io.Writer`, in block or flow style,
with the indentation and line width you choose.

## Errors

Pass a `yaml.Diagnostic` to find out where and why parsing failed:

<!-- example: examples/errors.zig -->
```zig
const std = @import("std");
const yaml = @import("yaml");

test "an error says where and why" {
    const Limits = struct { cpu: u8, memory: u32 };
    const text =
        \\cpu: 300
        \\memory: 512
        \\
    ;

    var diagnostic: yaml.Diagnostic = .{};
    const result = yaml.parseFromSlice(Limits, std.testing.allocator, text, .{ .diagnostic = &diagnostic });
    try std.testing.expectError(error.Overflow, result);

    // Lines and columns count from 0.
    try std.testing.expectEqual(0, diagnostic.mark.line);
    try std.testing.expectEqual(5, diagnostic.mark.column);
    try std.testing.expectEqualStrings("the integer does not fit the type asked for", diagnostic.message);

    // Printed, from 1, with the path to the value and what it is: put a
    // file's name before it and it reads as a compiler's error does.
    var buf: [256]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buf);
    try line.print("{f}", .{diagnostic});
    try std.testing.expectEqualStrings("1:6: cpu: the integer 300 does not fit a u8", line.buffered());
}
```

Put the file name in front and it reads like a compiler error. Unknown
fields list the fields there are and suggest the nearest; a missing
field names the mapping that lacks it.

## Merge keys

Docker Compose files, GitLab CI files and many others share settings
with `<<: *defaults`. YAML 1.2 dropped this, so it is off by default;
turn it on with `merge_keys`:

<!-- example: examples/merge_keys.zig -->
```zig
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
```

## YAML 1.1 files

A file written for PyYAML or another YAML 1.1 tool can mean something
else under YAML 1.2. There `country: no` is false and `mode: 0755` is
493; here they are the string `"no"` and 755. To read such a file the
way those tools do, set `.schema = .yaml11`, or pass `--schema yaml11`
to the `yaml` command. Then `yes`, `no`, `on` and `off` are booleans,
`0755` is octal, `1:20` is 80, and `2001-12-14` is a timestamp, which a
string field takes as its text and `yaml.schema.parseTimestamp` takes
apart. It follows PyYAML form for form, checked against PyYAML itself on
half a million scalars.

The [guide](guide.md) goes further: types that parse themselves, the
scanner, parser, composer and emitter under `parseFromSlice`, encodings
and schemas.
