"""YAML for Python on yaml.zig: PyYAML's API, much faster.

    import pyyaml_zig as yaml

    with open("config.yaml") as f:
        config = yaml.safe_load(f)

safe_load reads YAML 1.2 with the core schema: `yes`, `no`, `on` and `off`
are strings, and only `true` and `false` are booleans. With
schema="yaml11" it reads YAML 1.1 as PyYAML does: `yes` is True, `0777` is
511, and `2001-12-14` is a date. Merge keys (`<<: *defaults`) are applied,
as PyYAML applies them. A mapping with two equal keys is an error, and
alias bombs and deep nesting are capped.

For code written for PyYAML, load(stream, Loader=SafeLoader) and the rest
of PyYAML's names read as PyYAML does: YAML 1.1, a mapping's later equal
key winning. Every loader is safe (loader.py): no tag builds a Python
object. dump writes as safe_dump does, which is what PyYAML's SafeDumper
writes.
"""

from __future__ import annotations

import math
from typing import IO, Any, Iterable, Iterator, Optional, Type, Union

from . import _yaml
from . import composer, constructor, parser, reader, representer, scanner  # noqa: F401  PyYAML's modules
from .dumper import BaseDumper, CBaseDumper, CDumper, CSafeDumper, Dumper, SafeDumper
from .error import (
    ComposerError,
    ConstructorError,
    EmitterError,
    Mark,
    MarkedYAMLError,
    ParserError,
    ReaderError,
    RepresenterError,
    ScannerError,
    SerializerError,
    YAMLError,
    YAMLSyntaxError,
    _from_extension,
)
from .loader import (
    BaseLoader,
    CBaseLoader,
    CFullLoader,
    CLoader,
    CSafeLoader,
    CUnsafeLoader,
    FullLoader,
    Loader,
    SafeLoader,
    UnsafeLoader,
    _not_supported,
)

__all__ = [
    "safe_load",
    "safe_load_all",
    "safe_dump",
    "safe_dump_all",
    "load",
    "load_all",
    "full_load",
    "full_load_all",
    "unsafe_load",
    "unsafe_load_all",
    "dump",
    "dump_all",
    "BaseLoader",
    "SafeLoader",
    "FullLoader",
    "UnsafeLoader",
    "Loader",
    "CBaseLoader",
    "CSafeLoader",
    "CFullLoader",
    "CUnsafeLoader",
    "CLoader",
    "BaseDumper",
    "SafeDumper",
    "Dumper",
    "CBaseDumper",
    "CSafeDumper",
    "CDumper",
    "Mark",
    "YAMLError",
    "MarkedYAMLError",
    "ReaderError",
    "ScannerError",
    "ParserError",
    "YAMLSyntaxError",
    "ComposerError",
    "ConstructorError",
    "RepresenterError",
    "EmitterError",
    "SerializerError",
    "__version__",
]

__version__: str = _yaml.__version__

#: PyYAML says whether it has libyaml. pyyaml-zig has yaml.zig instead;
#: its C names (CSafeLoader and the rest) are there all the same.
__with_libyaml__ = False

Stream = Union[str, bytes, IO[str], IO[bytes]]

SCHEMAS = ("core", "yaml11", "json", "failsafe")


def _read(stream: Stream) -> tuple:
    """The text of `stream` and its name for marks, as PyYAML names it."""
    if isinstance(stream, str):
        return stream, "<unicode string>"
    if isinstance(stream, (bytes, bytearray, memoryview)):
        return bytes(stream), "<byte string>"
    return stream.read(), getattr(stream, "name", "<file>")


def _load(stream: Stream, all: bool, schema: str, merge_keys: bool, max_depth: int, keep_duplicates: bool) -> Any:
    if schema not in SCHEMAS:
        raise ValueError("schema is one of " + ", ".join(SCHEMAS))
    text, name = _read(stream)
    try:
        return _yaml._load(text, all, merge_keys, max_depth, schema, keep_duplicates)
    except _yaml.Error as e:
        raise _from_extension(e.args, name) from None


def safe_load(stream: Stream, *, schema: str = "core", merge_keys: bool = True, max_depth: int = 256) -> Any:
    """The one document in `stream` (a str, bytes, or a file open for
    reading) as Python objects; None for an empty stream. More than one
    document is an error: use safe_load_all.

    `schema` says how unquoted scalars are typed: "core", YAML 1.2's;
    "yaml11", YAML 1.1's as PyYAML types them (`yes` True, `0777` octal,
    dates and times as datetime's); "json", where any other word is an
    error; or "failsafe", where every scalar is a str."""
    return _load(stream, False, schema, merge_keys, max_depth, False)


def safe_load_all(
    stream: Stream, *, schema: str = "core", merge_keys: bool = True, max_depth: int = 256
) -> Iterator[Any]:
    """Every document in `stream`, in order."""
    return iter(_load(stream, True, schema, merge_keys, max_depth, False))


def _loader_options(loader: Any) -> tuple:
    if not (isinstance(loader, type) and issubclass(loader, BaseLoader)):
        raise TypeError("Loader is one of pyyaml_zig's loaders, such as pyyaml_zig.SafeLoader, not %r" % (loader,))
    return loader._schema, loader._merge_keys


def load(stream: Stream, Loader: Type[BaseLoader]) -> Any:
    """The one document in `stream`, read as PyYAML's `Loader` reads it:
    with SafeLoader (FullLoader, Loader, ...), YAML 1.1, merge keys
    applied and a mapping's later equal key winning; with BaseLoader,
    every scalar a str. No loader builds Python objects from tags."""
    schema, merge_keys = _loader_options(Loader)
    return _load(stream, False, schema, merge_keys, 256, True)


def load_all(stream: Stream, Loader: Type[BaseLoader]) -> Iterator[Any]:
    """Every document in `stream`, read as `load` reads one."""
    schema, merge_keys = _loader_options(Loader)
    return iter(_load(stream, True, schema, merge_keys, 256, True))


def full_load(stream: Stream) -> Any:
    """load(stream, FullLoader): safe, as every loader here is."""
    return load(stream, FullLoader)


def full_load_all(stream: Stream) -> Iterator[Any]:
    return load_all(stream, FullLoader)


def unsafe_load(stream: Stream) -> Any:
    """load(stream, UnsafeLoader): safe all the same. No loader here
    builds Python objects from tags."""
    return load(stream, UnsafeLoader)


def unsafe_load_all(stream: Stream) -> Iterator[Any]:
    return load_all(stream, UnsafeLoader)


def dump_all(
    documents: Iterable[Any],
    stream: Optional[IO[Any]] = None,
    Dumper: Type[BaseDumper] = Dumper,
    *,
    default_style: Optional[str] = None,
    default_flow_style: Optional[bool] = False,
    canonical: Optional[bool] = None,
    indent: Optional[int] = None,
    width: Optional[float] = None,
    allow_unicode: Optional[bool] = None,
    line_break: Optional[str] = None,
    encoding: Optional[str] = None,
    explicit_start: Optional[bool] = None,
    explicit_end: Optional[bool] = None,
    version: Optional[tuple] = None,
    tags: Optional[dict] = None,
    sort_keys: bool = True,
    max_depth: int = 256,
) -> Any:
    """Each of `documents` written as a YAML document, `---` before each
    after the first (before the first too with `explicit_start`):
    returned as a str (bytes with `encoding`), or written to `stream`,
    which is returned None.

    It writes dict, list, tuple, str, int, float, bool, None, date and
    datetime, as PyYAML's SafeDumper does, and quotes a string any reader,
    YAML 1.1 ones too, would read as something else. Keys are sorted
    unless `sort_keys=False`. Text is UTF-8 as it is, as with
    `allow_unicode=True` (which is accepted either way). The options
    PyYAML has that change more than layout, `default_style`,
    `canonical`, `line_break`, `version` and `tags`, are refused unless
    left as they are; `default_flow_style=None` is block style."""
    if not (isinstance(Dumper, type) and issubclass(Dumper, BaseDumper)):
        raise TypeError("Dumper is one of pyyaml_zig's dumpers, such as pyyaml_zig.SafeDumper, not %r" % (Dumper,))
    for name, value in (("default_style", default_style), ("version", version), ("tags", tags)):
        if value is not None:
            raise ValueError("pyyaml-zig does not support %s" % name)
    if canonical:
        raise ValueError("pyyaml-zig does not support canonical")
    if line_break not in (None, "\n"):
        raise ValueError("pyyaml-zig writes \\n line breaks only")
    # As PyYAML takes them: an indent outside 2 to 9, or a width not past
    # two indents, is the default.
    columns = indent if indent is not None and 1 < indent < 10 else 2
    if columns > 8:
        raise ValueError("pyyaml-zig indents 2 to 8 columns")
    if width is None or not width > columns * 2:
        width = 80
    line = 1 << 30 if width == math.inf or width > 1 << 30 else int(width)
    parts = []
    open_ended = False
    for i, doc in enumerate(documents):
        try:
            text = _yaml._dump(doc, bool(default_flow_style), columns, line, sort_keys, max_depth)
        except _yaml.Error as e:
            raise _from_extension(e.args, "<data>") from None
        # As PyYAML writes them: a block collection starts the line after
        # `---`, anything else is on it, and a stream that ends with a
        # plain scalar ends with `...`.
        collection = isinstance(doc, (dict, list, tuple))
        if explicit_start or i > 0:
            text = ("---\n" if collection and doc and not default_flow_style else "--- ") + text
        if explicit_end:
            text += "...\n"
        parts.append(text)
        open_ended = not explicit_end and not collection and text.lstrip("- ")[:1] not in ("'", '"', "|", ">")
    if open_ended:
        parts.append("...\n")
    out = "".join(parts)
    data = out.encode(encoding) if encoding is not None else out
    if stream is None:
        return data
    stream.write(data)
    return None


def dump(data: Any, stream: Optional[IO[Any]] = None, Dumper: Type[BaseDumper] = Dumper, **kwds: Any) -> Any:
    """`data` written as one YAML document, as dump_all writes each."""
    return dump_all([data], stream, Dumper=Dumper, **kwds)


def safe_dump_all(documents: Iterable[Any], stream: Optional[IO[Any]] = None, **kwds: Any) -> Any:
    """dump_all with SafeDumper, which every dumper here is."""
    return dump_all(documents, stream, Dumper=SafeDumper, **kwds)


def safe_dump(data: Any, stream: Optional[IO[Any]] = None, **kwds: Any) -> Any:
    """`data` written as YAML: returned as a str (bytes with `encoding`),
    or written to `stream`. See dump_all for what it writes and how."""
    return dump_all([data], stream, Dumper=SafeDumper, **kwds)


# PyYAML's ways to extend it, which pyyaml-zig has not: each says so.


def add_constructor(tag: str, constructor: Any, Loader: Any = None) -> None:
    _not_supported("add_constructor")


def add_multi_constructor(tag_prefix: str, multi_constructor: Any, Loader: Any = None) -> None:
    _not_supported("add_multi_constructor")


def add_implicit_resolver(tag: str, regexp: Any, first: Any = None, Loader: Any = None, Dumper: Any = None) -> None:
    _not_supported("add_implicit_resolver")


def add_path_resolver(tag: str, path: Any, kind: Any = None, Loader: Any = None, Dumper: Any = None) -> None:
    _not_supported("add_path_resolver")


def add_representer(data_type: Any, representer: Any, Dumper: Any = None) -> None:
    _not_supported("add_representer")


def add_multi_representer(data_type: Any, multi_representer: Any, Dumper: Any = None) -> None:
    _not_supported("add_multi_representer")
