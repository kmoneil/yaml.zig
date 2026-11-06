# yaml.zig

A YAML 1.2.2 library for Zig: read YAML into Zig types or a dynamic
`Value`, write Zig values as YAML, and work at any stage between, the
tokens, the events, or the node graph. It passes the whole
[yaml-test-suite](https://github.com/yaml/yaml-test-suite), held there
by `zig build test`:

<!-- suite -->
| check | cases | passing |
| --- | ---: | ---: |
| events: the events each valid input parses to | 308 | 308 |
| error: each invalid input refused | 94 | 94 |
| json: each valid input's documents against its in.json | 279 | 279 |
| roundtrip: each valid input emitted and read back the same | 308 | 308 |

(yaml-test-suite data-2022-01-17; written by `zig build suite -- readme`.)
<!-- /suite -->

Private, not open-sourced. Work is tracked on the `yaml.zig` karte
board.

## Use

Zig 0.17.1. Add the package (a tarball or `git+https` URL of this
repository) with `zig fetch --save=yaml <url>`, then in `build.zig`:

```zig
const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("yaml", yaml.module("yaml"));
```

### Read a document into a struct

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

A node fits a type by the tag the schema gives it: a boolean for
`bool`, an integer for an integer type, a number for a float, null for
an optional's null, a sequence for a slice, array or tuple, a mapping
for a struct (by field name, defaults filled) or a tagged union (one
key, the field), and a string for a string or an enum's name. A scalar
tagged `!!null`, `!!bool`, `!!int` or `!!float` must be written as one:
`!!int foo` is refused, whatever it is read into. A
mapping whose keys are not known at compile time (environment
variables, say) goes in a `yaml.ArrayHashMap(T)`, which keeps their
order. `parseFromSliceLeaky` builds into an allocator you free as a
whole.

### A document of any shape

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

### Write a value as YAML

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
        .notes = &.{ "faster", "yes" }, // and yes stays a string too
    };

    const text = try yaml.stringifyAlloc(std.testing.allocator, release, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\version: '1.10'
        \\stable: true
        \\notes:
        \\- faster
        \\- yes
        \\
    , text);

    const again = try yaml.parseFromSlice(Release, std.testing.allocator, text, .{});
    defer again.deinit();
    try std.testing.expectEqualDeep(release, again.value);
}
```

`stringify` writes to any `*std.Io.Writer`; options choose block or
flow style, indentation, line width, and whether a struct's null
optional fields are written.

### A field of more than one shape

A type can read itself, as std.json's `jsonParse` lets one: its `pub fn
yamlParse(c: yaml.Construction) yaml.ParseError!@This()` gets the node
it is built from, and builds the node's parts as other types with the
path, limits and errors kept (`c.build`, `c.buildNamed`,
`c.buildIndexed`, `c.fail`, `c.failExpected`). Here a command is a line
for the shell or a program and its arguments:

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

Its `pub fn yamlStringify(self: @This(), s: *yaml.Stringification)
yaml.StringifyError!void` writes it back: one value in its place, any
that `stringify` writes (`s.write`).

### Errors say where, and why

An error names the path to the value and what it found: `machine:
unknown field "zone"; expected one of: types, zones, spot, image (did
you mean "zones"?)`, `machine.types[2]: expected a string, found a
mapping`, `machine: missing field "types"`.

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

### The stages: tokens, events, nodes

`yaml.Scanner` gives tokens, `yaml.Parser` events, and `yaml.Composer`
a graph of nodes a document at a time, each tag resolved and each
alias pointing at its anchor's node:

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

`yaml.Emitter` writes events back as YAML, keeping each scalar's style
where its text allows and quoting where not:

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

- YAML 1.2.2, all of it: block and flow collections, the five scalar
  styles, anchors and aliases, tags with `%TAG` shorthands, `%YAML`,
  streams of documents, YAML 1.2's JSON-like flow rules.
- UTF-8, UTF-16 and UTF-32, either byte order, with or without a byte
  order mark (`parseFromSlice` decodes them; `yaml.encoding.toUtf8` for
  the lower stages).
- Schemas: core (the default: `null`, `~`, `true`, `0x1F`, `.inf` and
  so on), JSON (strict: anything else plain is an error), and failsafe
  (all strings). `ParseOptions.schema` chooses.
- Keys are equal by value under the schema (`1` and `0x1` are one key),
  and a mapping with two equal keys is refused unless
  `duplicate_keys = .keep` (a struct field then takes the last).

## Limits for untrusted input

| Limit | Default | Where |
| --- | ---: | --- |
| Nodes built through aliases (a "billion laughs" document) | 1,000,000 | `ParseOptions.max_alias_nodes` |
| Depth construction goes into a document | 256 | `ParseOptions.max_depth` |
| Collections open at once in the scanner | 10,000 | `Scanner.max_depth`, `Composer.Options.max_depth` |
| %TAG directives in a document | 64 | `ParseOptions.max_tag_directives`, `Composer.Options.max_tag_directives`, `Parser.max_tag_directives` |
| A cyclic document built into a value | refused | `error.Cycle` |

Mapping keys and anchor names, which come from the input, are kept in
hash maps seeded from a hash of the input, so keys built to collide
cost what any keys do. A tag is resolved by looking through its
document's %TAG directives, so their number is held too.

Every known attack on a YAML library, and where this one stands on it
(a test that proves the defence, a card, or why it does not apply), is
a row of [test/security/CATALOG.md](test/security/CATALOG.md): alias
expansion, depth, hash flooding, hangs, code execution through tags,
type confusion, numbers, encodings, injection into what is written, and
input in diagnostics. `zig build security` runs its tests and checks it.

Nothing recurses on the input's depth but construction, which is held
to `max_depth`. Each level, a collection or a pointer followed, takes
about 1.9 KiB of stack in a Debug build and 0.75 KiB in a release one,
so the default needs under 512 KiB in Debug (a thread's default stack
on macOS) and 200 KiB in release. On a smaller stack, lower
`max_depth`.

## Build

- `zig build test`: unit tests, the examples above, the yaml-test-suite
  checks with their ratchet (`test/suite-skip.txt`), seeded runs of the
  fuzz targets, zigvet and gnarl. zigvet and gnarl come from the PATH
  (github.com/kmoneil/zigvet, github.com/kmoneil/gnarl; gnarl at the
  release `complexity.zon` names).
- `zig build test-release`: the unit tests, the examples and the suite
  with the library built ReleaseSafe and ReleaseFast, where a panic in
  Debug is one or undefined behaviour; `zig build test test-release`
  runs all three modes.
- `zig build security`: the security suite (test/security) and its
  catalog, every row's test there and every test in a row; `zig build
  test` runs both too.
- `zig build suite`: the suite's counts; `-- show <case>`,
  `-- show-emit <case>`, `-- errors`, `-- list [--all]`, `-- readme`.
- `zig build fuzz`: the fuzz targets' seeded runs, `--fuzz` to fuzz.
- `zig build docs`: the API reference into `zig-out/docs`.
- `zig build doc-examples`: check this README's examples against
  `examples/` (`-- --fix` to rewrite them).
- `zig build fmt`: format.
