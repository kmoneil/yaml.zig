# pyyaml-zig

Fast, safe YAML for Python. A drop-in for PyYAML.

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
- **A drop-in for PyYAML.** Change the import and code written for
  PyYAML runs: `load(f, Loader=yaml.SafeLoader)`, `safe_load`, `dump`,
  the loader and dumper names, and PyYAML's error classes. Its loaders
  read YAML 1.1 exactly as PyYAML does.
- **Correct.** It runs on [yaml.zig](https://github.com/kmoneil/yaml.zig),
  which passes the whole official YAML test suite.
- **Safe by default.** No tag can run code or build arbitrary objects.
  Alias bombs and deep nesting are capped. A mapping with the same key
  twice is an error, not a value silently thrown away.
- **No YAML 1.1 surprises in new code.** `safe_load` reads YAML 1.2:
  `country: no` stays the string `"no"`, and only `true` and `false` are
  booleans.
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
                                #   in "<unicode string>", line 2, column 1
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

Dates and datetimes are written as PyYAML writes them, plain:
`2001-12-14`, `2001-12-14 21:59:43.100000-05:00`.

Aliases work as in PyYAML: an alias is the same object as its anchor,
and an alias inside its own anchor makes a cycle. Merge keys
(`<<: *defaults`) are applied, as PyYAML applies them.

Options:

- `schema="yaml11"` reads YAML 1.1 as PyYAML does: `yes` is True, `0755`
  is 493, and `2001-12-14` is a `datetime.date`. Use it for files
  written for PyYAML. `"json"` and `"failsafe"` (every scalar a str) are
  there too; the default is `"core"`, YAML 1.2.
- `merge_keys=False` reads `<<` as an ordinary key.
- `max_depth=256` is how deep a document may nest, or data be written.

## Switching from PyYAML

Change the import and leave the rest:

```python
import pyyaml_zig as yaml  # was: import yaml

with open("config.yaml") as f:
    config = yaml.load(f, Loader=yaml.SafeLoader)  # or CSafeLoader, FullLoader

try:
    data = yaml.safe_load(text)
except yaml.scanner.ScannerError as e:
    print(e.problem_mark.line)
```

`load` with any of PyYAML's loaders reads as PyYAML does: YAML 1.1
(`yes` is True, `0755` is 493, dates are `datetime`), merge keys applied,
and a key given twice keeping its last value. `!!set`, `!!binary`,
`!!omap` and `!!pairs` build what PyYAML builds. The tests hold it to
PyYAML's own results on the YAML test suite and on 20,000 generated
scalars; where they differ, PyYAML departs from the YAML spec.

`dump` writes as PyYAML's SafeDumper does, document markers and all.
Errors are PyYAML's classes, `yaml.scanner.ScannerError`,
`yaml.constructor.ConstructorError` and the rest, each with its
`problem_mark`. A syntax error is both a ScannerError and a ParserError,
so code catching either catches it.

Every loader is safe. `FullLoader`, `UnsafeLoader` and `Loader` read as
`SafeLoader` does: a `!!python/...` tag is a ConstructorError, never an
object.

## How it differs from PyYAML

- **`safe_load` reads YAML 1.2.** `yes`, `no`, `on` and `off` are
  strings, `0777` is the number 777 (write `0o777`), and dates stay
  strings. `schema="yaml11"`, or `load` with a PyYAML loader, reads them
  as PyYAML does.
- **`safe_load` refuses duplicate keys.** PyYAML keeps the last one, and
  so does `load`.
- **No custom tags.** `add_constructor`, `add_representer` and the rest
  raise NotImplementedError, and a tag with no constructor is a
  ConstructorError.
- **Writing** takes dict, list, tuple, str, int, float, bool, None, date
  and datetime. Sets and bytes, which PyYAML writes with `!!set` and
  `!!binary`, are a RepresenterError, as is a datetime in flow style.
  `default_style`, `canonical`, `version` and `tags` are not supported.
- **No anchors when writing.** An object that appears twice is written
  twice, and data that contains itself is an error.
- **Merged keys come last.** With merge keys, a mapping's own keys come
  first in the dict, then the merged ones; PyYAML puts the merged ones
  first. The values are the same.
- **No lower layers.** `scan`, `parse`, `compose` and `emit` are not
  there.

## License

MIT. Built on [yaml.zig](https://github.com/kmoneil/yaml.zig).
