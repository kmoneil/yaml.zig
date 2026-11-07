---
title: Python
nav_order: 5
---

# pyyaml-zig

**Fast, safe YAML for Python. A drop-in for PyYAML.**
{: .fs-6 .fw-300 }

```sh
pip install pyyaml-zig
```

```python
import pyyaml_zig as yaml

with open("config.yaml") as f:
    config = yaml.safe_load(f)
```

- **37 times faster than PyYAML.** A 5 MB file loads in 35 ms. PyYAML
  takes 1.3 seconds with its C loader and 6 seconds without it. Writing
  is 13 times faster.
- **A drop-in for PyYAML.** Change the import and code written for
  PyYAML runs: `load(f, Loader=yaml.SafeLoader)`, `safe_load`, `dump`,
  the loader and dumper names, and PyYAML's error classes. Its loaders
  read YAML 1.1 exactly as PyYAML does.
- **Correct.** It runs on yaml.zig, which passes the whole official YAML
  test suite.
- **Safe by default.** No tag can run code or build arbitrary objects.
  Alias bombs and deep nesting are capped.
- **No YAML 1.1 surprises in new code.** `safe_load` reads YAML 1.2:
  `country: no` stays the string `"no"`.
- **Other threads keep running.** Parsing happens outside Python's
  global interpreter lock.
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

print(yaml.safe_dump({"name": "web", "ports": [80, 443], "enabled": "yes"}))
# enabled: 'yes'
# name: web
# ports:
# - 80
# - 443
```

`safe_load` takes a string, bytes (UTF-8, UTF-16 or UTF-32), or an open
file. `safe_dump` quotes any string a reader would take for something
else, so `'yes'` stays a string even for PyYAML. Keys are sorted, as in
PyYAML; `sort_keys=False` keeps your order.

Options to `safe_load`:

- `schema="yaml11"` reads YAML 1.1 as PyYAML does: `yes` is True, `0755`
  is 493, and `2001-12-14` is a `datetime.date`. `"json"` and
  `"failsafe"` (every value a str) are there too; the default is
  `"core"`, YAML 1.2.
- `merge_keys=False` reads `<<` as an ordinary key.
- `max_depth=256` is how deep a document may nest.

## Switching from PyYAML

Change the import and leave the rest:

```python
import pyyaml_zig as yaml  # was: import yaml

with open("config.yaml") as f:
    config = yaml.load(f, Loader=yaml.SafeLoader)  # or CSafeLoader, FullLoader
```

`load` with any of PyYAML's loaders reads as PyYAML does: YAML 1.1,
merge keys applied, and a key given twice keeping its last value.
`!!set`, `!!binary`, `!!omap` and `!!pairs` build what PyYAML builds.
The tests hold it to PyYAML's own results on the YAML test suite and on
20,000 generated values; where they differ, PyYAML departs from the
YAML spec.

`dump` writes as PyYAML's SafeDumper does. Errors are PyYAML's classes,
`yaml.scanner.ScannerError`, `yaml.constructor.ConstructorError` and the
rest, each with its `problem_mark`. Every loader is safe: `FullLoader`,
`UnsafeLoader` and `Loader` read as `SafeLoader` does, and a
`!!python/...` tag is a ConstructorError, never an object.

## How it differs from PyYAML

- **`safe_load` reads YAML 1.2** and refuses duplicate keys.
  `schema="yaml11"`, or `load` with a PyYAML loader, reads as PyYAML
  does.
- **No custom tags.** `add_constructor`, `add_representer` and the rest
  raise NotImplementedError.
- **Writing** takes dict, list, tuple, str, int, float, bool, None, date
  and datetime. Sets and bytes are a RepresenterError, as is a datetime
  in flow style. Objects that appear twice are written twice.
- **Merged keys come last** in the dict; PyYAML puts them first. The
  values are the same.
- **No lower layers:** `scan`, `parse`, `compose` and `emit` are not
  there.

The full list is on [PyPI](https://pypi.org/p/pyyaml-zig), and the
source in
[python/](https://github.com/kmoneil/yaml.zig/tree/main/python).
