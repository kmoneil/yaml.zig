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
  takes 1.3 seconds with its C loader and 6 seconds without it.
- **The API you know.** `safe_load`, `safe_load_all` and `YAMLError` work
  like PyYAML's, so switching is usually a one-line change.
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

Loading the same 4.9 MB file of config records, with identical results:

| Loader | Time |
| --- | ---: |
| **pyyaml-zig** | **35 ms** |
| PyYAML with libyaml (`CSafeLoader`) | 1,266 ms |
| PyYAML, pure Python (`SafeLoader`) | 5,994 ms |
| `json.loads`, the same data as JSON | 16 ms |

PyYAML builds each value one Python call at a time. pyyaml-zig parses in
Zig and builds the Python objects directly.

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

Aliases work as in PyYAML: an alias is the same object as its anchor,
and an alias inside its own anchor makes a cycle. Merge keys
(`<<: *defaults`) are applied, as PyYAML applies them.

Options:

- `merge_keys=False` reads `<<` as an ordinary key.
- `max_depth=256` is how deep a document may nest.

## How it differs from PyYAML

- **YAML 1.2.** `yes`, `no`, `on` and `off` are strings. `0777` is the
  number 777, not octal; write `0o777`. Dates stay strings.
- **Duplicate keys are an error.** PyYAML keeps the last one.
- **Core tags only.** `!!binary`, `!!timestamp`, `!!set` and custom tags
  are refused for now.
- **No writing yet.** `safe_dump` is on its way.

## License

MIT. Built on [yaml.zig](https://github.com/kmoneil/yaml.zig).
