# yaml.zig

[![ci](https://github.com/kmoneil/yaml.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/kmoneil/yaml.zig/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/kmoneil/yaml.zig)](https://github.com/kmoneil/yaml.zig/releases/latest)
[![zig](https://img.shields.io/badge/zig-0.17.1-f7a41d)](https://ziglang.org/download/)
[![PyPI](https://img.shields.io/pypi/v/pyyaml-zig)](https://pypi.org/p/pyyaml-zig)
[![docs](https://img.shields.io/badge/docs-kmoneil.github.io%2Fyaml.zig-blue)](https://kmoneil.github.io/yaml.zig/)
[![license](https://img.shields.io/github/license/kmoneil/yaml.zig)](LICENSE)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%99%A5-f5a623?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/kmoneil)

YAML for Zig. Read it into your structs, write your values back out,
and check files from the command line.

- **Complete.** All of YAML 1.2.2. It passes the whole
  [yaml-test-suite](https://github.com/yaml/yaml-test-suite): every
  valid file read correctly, every invalid file refused. Beyond the
  suite, it is fuzzed against libfyaml, another reader, with the YAML
  reference parser settling wherever the two differ.
- **Fast.** A little faster than rapidyaml (C++) at building a document
  tree, and three to four times faster than serde_yaml, saphyr and
  js-yaml at reading into values. [Numbers below.](#speed)
- **Safe on files you did not write.** Alias bombs, deep nesting, hash
  flooding and merge fan-out are all capped, and no tag can run code.
  Every known attack on YAML libraries is in the
  [security catalog](test/security/CATALOG.md), with the test that
  covers it or why it does not apply.
- **Clear errors.** Line, column, the path to the value, and a hint:
  `4:3: server: unknown field "tag"; expected one of: hosts, tags, tls,
  root (did you mean "tags"?)`.
- **A command-line tool.** `yaml check`, `yaml lint`, `yaml get`,
  `yaml json`.
- **Python too.** [pyyaml-zig](#python) is a drop-in for PyYAML on this
  parser. It loads YAML 37 times faster than PyYAML and writes it 13
  times faster.

<!-- suite -->
| check | cases | passing |
| --- | ---: | ---: |
| events: the events each valid input parses to | 308 | 308 |
| error: each invalid input refused | 94 | 94 |
| json: each valid input's documents against its in.json | 279 | 279 |
| roundtrip: each valid input emitted and read back the same | 308 | 308 |
| reader: the reader's events are the parser's, as far as it reads | 402 | 402 |
| whole: each valid input the reader reads to its end | 308 | 308 |

(yaml-test-suite data-2022-01-17; written by `zig build suite -- readme`.)
<!-- /suite -->

## Install

Zig 0.17.1. Add the package to your `build.zig.zon`:

```sh
zig fetch --save=yaml git+https://github.com/kmoneil/yaml.zig
```

Put `#v0.2.0` (or another release tag) after the URL to pin a release.
Then in `build.zig`:

```zig
const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("yaml", yaml.module("yaml"));
```

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

## A stream of documents

`parseDocuments` reads every document in a stream, as Kubernetes
manifests or a log of records come, into a slice; `parseFromSlice`
reads one. `parseDocumentsConcurrently` reads the same on the threads
of a `std.Io`: the stream is cut where a `---` or `...` line stands,
which no scalar can hold, and the pieces are read side by side, a
stream of 20,000 documents several times as fast. Its values are
`parseDocuments`'s, and so are its errors: on one it reads the stream
again in order, and gives that error.

<!-- example: examples/streams.zig -->
```zig
const std = @import("std");
const yaml = @import("yaml");

const Manifest = struct { kind: []const u8, name: []const u8 };

test "a stream of documents, in order or side by side" {
    const text =
        \\kind: Service
        \\name: web
        \\---
        \\kind: Deployment
        \\name: web
        \\
    ;
    const all = try yaml.parseDocuments(Manifest, std.testing.allocator, text, .{});
    defer all.deinit();
    try std.testing.expectEqual(2, all.value.len);
    try std.testing.expectEqualStrings("Deployment", all.value[1].kind);

    // The same documents, read side by side on an Io's threads. Its
    // allocator must be threadsafe, as the testing allocator is.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const again = try yaml.parseDocumentsConcurrently(Manifest, threaded.io(), std.testing.allocator, text, .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("web", again.value[0].name);
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

## More

The [site](https://kmoneil.github.io/yaml.zig/) has all of this, and the
[guide](docs/guide.md) covers types that parse themselves, the
scanner, parser, composer and emitter under `parseFromSlice`, encodings
and schemas, and how YAML 1.2 differs from the YAML 1.1 that PyYAML
reads.

## The yaml command

Install it with Homebrew on macOS or Linux:

```sh
brew install kmoneil/tap/yaml
```

Each [release](https://github.com/kmoneil/yaml.zig/releases) also has
the binary for Windows, and `zig build -Doptimize=ReleaseSafe` builds it
from source into `zig-out/bin/yaml`.

```console
$ yaml check config.yaml deploy.yaml
deploy.yaml:2:1: a mapping cannot have two equal keys
a: 2
^
$ yaml get '.servers[0].name' config.yaml
web
$ yaml get --json .flags config.yaml
{"debug":true,"ratio":0.5}
$ yaml json --merge-keys compose.yaml | jq .services
```

- `yaml check FILE...` reports each file that is not valid YAML, with
  the line, the column and a caret. `--format json` is for tools and CI.
- `yaml lint FILE...` checks too, then warns of what YAML 1.1 tools such
  as PyYAML read differently (`yes`, `0755`, `1e3`), tabs in the
  indentation, trailing blanks, long lines, unused anchors, and keys
  that differ only in case. `--allow RULE,...` turns rules off.
- `yaml get PATH FILE` prints one value, as YAML or with `--json` as
  JSON. A path looks like `.servers[0].name` or `.["a key"]`.
- `yaml json FILE` converts YAML to JSON, and `yaml from-json FILE`
  converts back.
- `yaml events FILE` shows how a file parses.
- `--merge-keys`, `--schema`, `--duplicate-keys keep` and `--max-depth`
  set the library's options. A file named `-` is standard input.
- `yaml skill` prints a guide for AI coding agents, every example in it
  tested; `yaml skill --install DIR` installs it.

The exit status is 0 on success, 1 when a file is not YAML, lint warns,
or a path has no value, and 2 for a usage error. `yaml --help` lists
everything.

## Python

pyyaml-zig puts yaml.zig behind PyYAML's API, so switching is a
one-line change:

```sh
pip install pyyaml-zig
```

```python
import pyyaml_zig as yaml

with open("config.yaml") as f:
    config = yaml.safe_load(f)

with open("out.yaml", "w") as f:
    yaml.safe_dump(config, f)
```

On the 4.9 MB file from the speed table below, loaded and then written
back, with identical results:

| | Load | Write |
| --- | ---: | ---: |
| **pyyaml-zig** | **35 ms** | **56 ms** |
| PyYAML with libyaml (`CSafeLoader`, `CSafeDumper`) | 1,266 ms | 753 ms |
| PyYAML, pure Python (`SafeLoader`, `SafeDumper`) | 5,994 ms | 2,626 ms |
| `json`, the same data as JSON | 16 ms | 15 ms |

Like the Zig library, it reads YAML 1.2, refuses duplicate keys and caps
alias bombs; it applies merge keys, as PyYAML does, and parses outside
Python's global interpreter lock. Code written for PyYAML runs
unchanged: `load(f, Loader=yaml.SafeLoader)` and PyYAML's other loaders
read YAML 1.1 exactly as PyYAML does, checked against PyYAML on the YAML
test suite. Wheels for Linux, macOS and Windows, x86_64 and arm64, need
no compiler; the source is in [python/](python/README.md).

## Speed

Reading a 4.9 MB file of config records, each library in its release
build, on an M-series Mac:

| Built | Library | ms | MB/s | 1st run ms | Peak MB |
| --- | --- | ---: | ---: | ---: | ---: |
| events | **yaml.zig** | 21.8 | 223 | 22.0 | 3.8 |
| events | libyaml 0.2.5 | 46.1 | 105 | 46.9 | 0.3 |
| events | saphyr-parser 0.3.3 | 60.6 | 80 | 62.0 | 0.5 |
| node tree | **yaml.zig** | 15.9 | 305 | 18.4 | 55.6 |
| node tree | rapidyaml 0.16.0 | 16.9 | 287 | 23.4 | 146.7 |
| node tree | libyaml 0.2.5 | 63.4 | 77 | 66.4 | 137.7 |
| node tree | go-yaml v3.0.1 (yaml.Node) | 136.6 | 36 | 141.0 | 148.1 |
| dynamic value | **yaml.zig** (Value) | 24.9 | 195 | 26.8 | 20.9 |
| dynamic value | saphyr 0.3.3 | 87.7 | 55 | 98.4 | 80.2 |
| dynamic value | js-yaml 5.5.0 | 98.6 | 49 | 130.1 | 296.5 |
| dynamic value | go-yaml v3.0.1 (any) | 207.4 | 23 | 204.9 | 237.1 |
| typed | **yaml.zig** | 25.1 | 193 | 27.1 | 23.7 |
| typed | serde_yaml 0.9.34 | 81.7 | 59 | 84.0 | 82.9 |
| typed | serde-saphyr 2.1.1 | 180.6 | 27 | 172.0 | 19.7 |
| typed | go-yaml v3.0.1 | 174.6 | 28 | 174.8 | 146.9 |

- **ms** is the median of 11 runs after a warm-up. **1st run ms** is a
  fresh process that parses once, as a command-line tool does. **Peak
  MB** is the most memory a parse holds.
- Every library allocates through malloc (or its runtime's garbage
  collector), yaml.zig included.
- rapidyaml's tree leaves scalars untyped and doesn't check for
  duplicate keys; yaml.zig's does both.
- Times vary by up to 10% between runs. `tools/compare/run.sh` builds
  every library at a pinned version and prints this table again.

## Safety

| Limit | Default | Option |
| --- | ---: | --- |
| Nodes built through aliases or merge keys | 1,000,000 | `ParseOptions.max_alias_nodes` |
| Nesting depth | 256 | `ParseOptions.max_depth` |
| Collections open at once in the scanner | 10,000 | `Scanner.max_depth`, `Composer.Options.max_depth` |
| `%TAG` directives in a document | 64 | `ParseOptions.max_tag_directives` |
| A document whose aliases form a cycle, read into a value | refused | `error.Cycle` |

Keys and anchor names go into hash maps seeded from a hash of the
input, so keys crafted to collide cost no more than any others. The
[security catalog](test/security/CATALOG.md) lists every known attack on
YAML libraries (alias expansion, deep nesting, hash flooding, hangs,
code execution through tags, type confusion, encodings, injection) and
the test that shows yaml.zig holds up. `zig build security` runs them.

## Development

- `zig build test`: the unit tests, the examples in this README and the
  guide, the yaml-test-suite, the `yaml` command end to end, the fuzz
  targets' seeds, and the [zigvet](https://github.com/kmoneil/zigvet)
  and [gnarl](https://github.com/kmoneil/gnarl) checks (install both
  from their releases; gnarl at the version `complexity.zon` names).
- `zig build test-release`: the tests again, in ReleaseSafe and
  ReleaseFast.
- `zig build security`: the security tests and their catalog.
- `zig build suite`: the yaml-test-suite's counts; `-- show <case>` for
  one case.
- `zig build fuzz --fuzz`: fuzz.
- `zig build differential -Ddifferential`: the parser's events held to
  [libfyaml](https://github.com/pantoniou/libfyaml)'s on every suite
  input (fetches libfyaml, which Zig compiles). With `--fuzz` it fuzzes
  the two against each other; set `YAML_DIFFERENTIAL_DIR` to record
  where they differ, and `tools/differential/arbitrate.sh` has the YAML
  reference parser settle each one.
- `zig build docs`: the API reference, in `zig-out/docs`.
- `zig build doc-examples -- --fix`: copy `examples/` into this README
  and the guide.
- `tools/compare/run.sh`: rerun the speed table (needs a C and C++
  compiler, Go, Rust and Node).

## License

MIT: see [LICENSE](LICENSE).
