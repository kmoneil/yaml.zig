---
title: The guide
nav_order: 3
---

# yaml.zig guide

The [README](https://github.com/kmoneil/yaml.zig#readme) covers everyday
use. This page covers the rest: types that parse themselves, the stages
under `parseFromSlice`, and exactly what yaml.zig reads.

## A type that reads itself

A type can take over its own parsing, the way `jsonParse` works in
std.json. Give it `pub fn yamlParse(c: yaml.Construction)
yaml.ParseError!@This()`. It gets the node it is built from, and can
build parts of it as other types with `c.build`, `c.buildNamed` and
`c.buildIndexed`, or fail with `c.fail` and `c.failExpected`. Paths,
limits and error messages work as usual.

Here a command is either a line for the shell or a program with its
arguments:

<!-- example: examples/hook.zig -->
```zig
const std = @import("std");
const yaml = @import("yaml");

const Exec = struct { argv: []const []const u8, cwd: ?[]const u8 = null };

/// A command: a line for the shell, or a program and its arguments.
const Run = union(enum) {
    shell: []const u8,
    exec: Exec,

    /// Either shape, by the kind of node it is written as.
    pub fn yamlParse(c: yaml.Construction) yaml.ParseError!Run {
        return switch (c.node.data) {
            .scalar => .{ .shell = try c.build([]const u8, c.node) },
            .mapping => .{ .exec = try c.build(Exec, c.node) },
            else => c.failExpected(c.node, "a command, a string or a mapping"),
        };
    }

    /// Written as the shape it is read from.
    pub fn yamlStringify(r: Run, s: *yaml.Stringification) yaml.StringifyError!void {
        switch (r) {
            .shell => |line| try s.write(line),
            .exec => |exec| try s.write(exec),
        }
    }
};

test "a type that reads itself: yamlParse" {
    const Job = struct { steps: []const Run };
    const text =
        \\steps:
        \\- make test
        \\- {argv: [python, train.py], cwd: src}
        \\
    ;
    const parsed = try yaml.parseFromSlice(Job, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("make test", parsed.value.steps[0].shell);
    try std.testing.expectEqualStrings("train.py", parsed.value.steps[1].exec.argv[1]);

    // And written so it reads back the same.
    const written = try yaml.stringifyAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(written);
    const again = try yaml.parseFromSlice(Job, std.testing.allocator, written, .{});
    defer again.deinit();
    try std.testing.expectEqualDeep(parsed.value, again.value);
}
```

`pub fn yamlStringify(self: @This(), s: *yaml.Stringification)
yaml.StringifyError!void` does the same for writing: call `s.write`
with any value `stringify` can write.

## The stages

`parseFromSlice` runs a pipeline you can also use step by step:

- `yaml.Scanner` turns text into tokens.
- `yaml.Parser` turns tokens into events.
- `yaml.Composer` turns events into a graph of nodes, one document at a
  time, with each tag resolved and each alias pointing at its anchored
  node.
- `yaml.Emitter` turns events back into YAML text.

A stream of documents, with an anchor:

<!-- example: examples/documents.zig -->
```zig
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
```

Events in, YAML out: reformatting a file. The emitter keeps each
scalar's style where it can, and quotes where it must.

<!-- example: examples/events.zig -->
```zig
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
```

## What it reads

- YAML 1.2.2, all of it: block and flow collections, all five scalar
  styles, anchors and aliases, tags with `%TAG` shorthands, `%YAML`,
  and streams of documents.
- UTF-8, UTF-16 and UTF-32, either byte order, with or without a byte
  order mark. `parseFromSlice` decodes them; `yaml.encoding.toUtf8`
  does it for the lower stages.
- Four schemas, chosen with `ParseOptions.schema`: core (the default:
  `null`, `~`, `true`, `0x1F`, `.inf` and so on), JSON (anything else
  unquoted is an error), failsafe (everything is a string), and yaml11
  (YAML 1.1's types, as PyYAML reads them; see below).
- Keys compare by value: `1` and `0x1` are the same key. A mapping with
  two equal keys is an error unless you set `duplicate_keys = .keep`,
  and then a struct field takes the last one.
- Merge keys (`<<: *base`) when you set `merge_keys`. The mapping's own
  keys win, then the merged mappings in order.

## YAML 1.2 and YAML 1.1

Many tools still read YAML 1.1 (PyYAML and other older libraries).
There, `yes`, `no`, `on` and `off` are booleans, `0777` is octal, `1:20`
is the number 80, and `2001-12-14` is a date. yaml.zig reads YAML 1.2,
where all of those are strings.

To read a file written for those tools as they read it, choose the
yaml11 schema: `.schema = .yaml11`, or `--schema yaml11` on the
command line. It types plain scalars as PyYAML's resolver does, form for
form:

- `yes`, `no`, `on`, `off`, `true` and `false`, in lower, title or upper
  case, are booleans. `y` and `n` are strings, as in PyYAML, though
  yaml.org's type page lists them.
- Integers may be binary (`0b101`), octal with a leading `0` (`0755`),
  hex (`0x1F`), have `_` among their digits (`1_000`), or be
  sexagesimal (`1:20` is 80), each with a sign. `0o17` is a string.
- A float needs a point, and an exponent a sign: `1.5`, `1.`, `.5`,
  `6.8e+5`, `1_000.5`, `1:20.5`. `1e3` is a string.
- `2001-12-14`, and a date with a time (`2001-12-14t21:59:43.10-05:00`,
  `2001-12-14 21:59:43.10 -5`), are timestamps. A string field or a
  `Value` gets the text; `yaml.schema.parseTimestamp` gives its parts.

Keys compare by these values, so `0755` and `493` are one key.
`Schema.int`, `Schema.float` and `Schema.boolean` read a scalar's value
under any schema.

When it writes, yaml.zig quotes any string a YAML 1.1 reader would take
for something else, so the files it writes read the same everywhere.

## Stack use

Only construction recurses on the input's depth, once per nesting
level, and it stops at `max_depth` (256 by default). A level takes about
1.9 KiB of stack in a Debug build and 0.75 KiB in a release build, so
the default needs under 512 KiB in Debug (a thread's default stack on
macOS) and 200 KiB in release. On a smaller stack, lower `max_depth`.

Those figures are for builds through LLVM. Zig's own x86_64 backend,
which a Debug build on Linux uses unless told otherwise, needs more
stack per level: build with `-fllvm` (`use_llvm = true` in `build.zig`)
or give the thread more stack.
