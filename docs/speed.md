---
title: Speed and safety
nav_order: 6
---

# Speed and safety

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
- Times vary by up to 10% between runs.
  [`tools/compare/run.sh`](https://github.com/kmoneil/yaml.zig/tree/main/tools/compare)
  builds every library at a pinned version and prints this table again.

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
[security catalog](https://github.com/kmoneil/yaml.zig/blob/main/test/security/CATALOG.md) lists every known attack on
YAML libraries (alias expansion, deep nesting, hash flooding, hangs,
code execution through tags, type confusion, encodings, injection) and
the test that shows yaml.zig holds up. `zig build security` runs them.

