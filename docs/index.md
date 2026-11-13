---
title: Home
nav_order: 1
permalink: /
---

# yaml.zig

**YAML for Zig: read it into your structs, write your values back, and
check files from the command line. For Python, a drop-in for PyYAML.**
{: .fs-6 .fw-300 }

[Install](#install){: .btn .btn-primary .mr-2 }
[The library](zig.md){: .btn .mr-2 }
[GitHub](https://github.com/kmoneil/yaml.zig){: .btn }

- **Complete.** All of YAML 1.2.2. It passes the whole
  [yaml-test-suite](https://github.com/yaml/yaml-test-suite): every
  valid file read correctly, every invalid file refused. Beyond the
  suite, it is fuzzed against libfyaml, another reader, with the YAML
  reference parser settling wherever the two differ.
- **Fast.** A little faster than rapidyaml (C++) at building a document
  tree, and three to four times faster than serde_yaml, saphyr and
  js-yaml at reading into values. [The numbers](speed.md).
- **Safe on files you did not write.** Alias bombs, deep nesting, hash
  flooding and merge fan-out are all capped, and no tag can run code.
- **Clear errors.** Line, column, the path to the value, and a hint:
  `4:3: server: unknown field "tag"; expected one of: hosts, tags, tls,
  root (did you mean "tags"?)`.
- **A command-line tool.** [`yaml check`, `yaml lint`, `yaml get`,
  `yaml json`](cli.md).
- **Python too.** [pyyaml-zig](python.md) is a drop-in for PyYAML on
  this parser, 37 times faster at loading.

## A quick look

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

```console
$ yaml check config.yaml deploy.yaml
deploy.yaml:2:1: a mapping cannot have two equal keys
a: 2
^
```

```python
import pyyaml_zig as yaml  # was: import yaml

with open("config.yaml") as f:
    config = yaml.safe_load(f)
```

## Install

| For | How |
|---|---|
| Zig 0.17.1 | `zig fetch --save=yaml git+https://github.com/kmoneil/yaml.zig`, then add the import in `build.zig` (below) |
| The `yaml` command | `brew install kmoneil/tap/yaml` on macOS and Linux, or a binary from the [latest release](https://github.com/kmoneil/yaml.zig/releases/latest) for Linux, macOS and Windows on x86_64 and arm64 |
| Python 3.9 and later | `pip install pyyaml-zig`: wheels for Linux, macOS and Windows, x86_64 and arm64, with nothing to compile |

```zig
const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("yaml", yaml.module("yaml"));
```

Put `#v0.2.0` (or another release tag) after the fetch URL to pin a
release. Every release file comes with `SHA256SUMS` and a
build-provenance attestation.

## Where next

- [The library](zig.md): read into structs or any shape, write, errors,
  merge keys, and files written for YAML 1.1.
- [The guide](guide.md): types that parse themselves, the stages under
  `parseFromSlice`, and exactly what yaml.zig reads.
- [The yaml command](cli.md): check, lint, get, json and the rest.
- [Python](python.md): pyyaml-zig, and switching from PyYAML.
- [Speed and safety](speed.md): the comparison, and the limits that keep
  hostile files cheap.
