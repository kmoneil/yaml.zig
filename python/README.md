# pyyaml-zig

Fast, safe YAML for Python, with PyYAML's API.

```sh
pip install pyyaml-zig
```

```python
import pyyaml_zig as yaml

with open("config.yaml") as f:
    config = yaml.safe_load(f)
```

## Why use it

- **37 times faster than PyYAML.** A 5 MB file loads in 35 ms. PyYAML
  takes 1.3 seconds with its C loader and 6 seconds without it. Writing
  is 13 times faster.
- **The API you know.** `safe_load`, `safe_dump`, their `_all` forms and
  `YAMLError` work like PyYAML's, so switching is usually a one-line
  change.
- **Correct.** It runs on [yaml.zig](https://github.com/kmoneil/yaml.zig),
  which passes the whole official YAML test suite.
- **Safe by default.** No tag can run code or build arbitrary objects.
  Alias bombs and deep nesting are capped. A mapping with the same key
  twice is an error, not a value silently thrown away.
- **No YAML 1.1 surprises.** `country: no` stays the string `"no"`. Only
  `true` and `false` are booleans.
- **Other threads keep running.** Parsing happens outside Python's global
  interpreter lock.
- **Nothing to compile.** Wheels for Linux, macOS and Windows, on x86_64
  and arm64, for Python 3.9 and later.

## Speed

A 4.9 MB file of config records, loaded, then the data written back,
with identical results:

| | Load | Write |
| --- | ---: | ---: |
| **pyyaml-zig** | **35 ms** | **56 ms** |
| PyYAML with libyaml (`CSafeLoader`, `CSafeDumper`) | 1,266 ms | 753 ms |
| PyYAML, pure Python (`SafeLoader`, `SafeDumper`) | 5,994 ms | 2,626 ms |
| `json`, the same data as JSON | 16 ms | 15 ms |

PyYAML handles each value one Python call at a time. pyyaml-zig parses
and writes in Zig, and builds or reads the Python objects directly.

## Use

```python
import pyyaml_zig as yaml

doc = yaml.safe_load("name: web\nports: [80, 443]\n")
# {'name': 'web', 'ports': [80, 443]}

for doc in yaml.safe_load_all(open("stream.yaml")):
    ...

try:
    yaml.safe_load("a: 1\na: 2\n")
except yaml.YAMLError as e:
    print(e)                    # a mapping cannot have two equal keys
                                #   in line 2, column 1
    print(e.problem_mark.line)  # 1 (from 0, as in PyYAML)
```

`safe_load` takes a string, bytes (UTF-8, UTF-16 or UTF-32), or an open
file. An empty stream is `None`.

Writing:

```python
print(yaml.safe_dump({"name": "web", "ports": [80, 443], "enabled": "yes"}))
# enabled: 'yes'
# name: web
# ports:
# - 80
# - 443

with open("out.yaml", "w") as f:
    yaml.safe_dump(config, f)
```

`safe_dump` quotes any string a reader would take for something else, so
`'yes'` stays a string even for YAML 1.1 readers like PyYAML. Keys are
sorted, as in PyYAML; `sort_keys=False` keeps your order.
`default_flow_style`, `indent`, `width`, `explicit_start` and `encoding`
work as in PyYAML. Text is written as UTF-8, as with
`allow_unicode=True`.

Aliases work as in PyYAML: an alias is the same object as its anchor,
and an alias inside its own anchor makes a cycle. Merge keys
(`<<: *defaults`) are applied, as PyYAML applies them.

Options:

- `merge_keys=False` reads `<<` as an ordinary key.
- `max_depth=256` is how deep a document may nest, or data be written.

## How it differs from PyYAML

- **YAML 1.2.** `yes`, `no`, `on` and `off` are strings. `0777` is the
  number 777, not octal; write `0o777`. Dates stay strings.
- **Duplicate keys are an error.** PyYAML keeps the last one.
- **Core tags only.** `!!binary`, `!!timestamp`, `!!set` and custom tags
  are refused for now. `safe_dump` writes dict, list, tuple, str, int,
  float, bool and None, which is what `safe_load` gives back.
- **No anchors when writing.** An object that appears twice is written
  twice, and data that contains itself is an error.

## License

MIT. Built on [yaml.zig](https://github.com/kmoneil/yaml.zig).
