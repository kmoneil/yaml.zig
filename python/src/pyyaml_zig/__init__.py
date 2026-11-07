"""YAML for Python on yaml.zig: PyYAML's safe API, much faster.

    import pyyaml_zig as yaml

    with open("config.yaml") as f:
        config = yaml.safe_load(f)

It reads YAML 1.2 with the core schema: `yes`, `no`, `on` and `off` are
strings, and only `true` and `false` are booleans. Merge keys (`<<:
*defaults`) are applied, as PyYAML applies them. A mapping with two equal
keys is an error, and alias bombs and deep nesting are capped.
"""

from __future__ import annotations

from typing import IO, Any, Iterator, Union

from . import _yaml

__all__ = ["safe_load", "safe_load_all", "safe_dump", "safe_dump_all", "YAMLError", "Mark", "__version__"]

__version__: str = _yaml.__version__

Stream = Union[str, bytes, IO[str], IO[bytes]]


class Mark:
    """A place in the input: `line` and `column` count from 0, as
    PyYAML's marks do."""

    def __init__(self, line: int, column: int) -> None:
        self.line = line
        self.column = column

    def __str__(self) -> str:
        return f"line {self.line + 1}, column {self.column + 1}"

    def __repr__(self) -> str:
        return f"Mark(line={self.line}, column={self.column})"


class YAMLError(Exception):
    """The input is not YAML, or not something safe_load builds. `problem`
    says what, and `problem_mark` where, or None."""

    def __init__(self, problem: str, problem_mark: Mark | None = None) -> None:
        super().__init__(problem, problem_mark)
        self.problem = problem
        self.problem_mark = problem_mark

    def __str__(self) -> str:
        if self.problem_mark is None:
            return self.problem
        return f"{self.problem}\n  in {self.problem_mark}"


def _text(stream: Stream) -> str | bytes:
    read = getattr(stream, "read", None)
    return read() if read is not None else stream


def _load(stream: Stream, all: bool, merge_keys: bool, max_depth: int) -> Any:
    try:
        return _yaml._load(_text(stream), all, merge_keys, max_depth)
    except _yaml.Error as e:
        problem, line, column = e.args
        mark = Mark(line, column) if line >= 0 else None
        raise YAMLError(problem, mark) from None


def safe_load(stream: Stream, *, merge_keys: bool = True, max_depth: int = 256) -> Any:
    """The one document in `stream` (a str, bytes, or a file open for
    reading) as Python objects; None for an empty stream. More than one
    document is an error: use safe_load_all."""
    return _load(stream, False, merge_keys, max_depth)


def safe_load_all(stream: Stream, *, merge_keys: bool = True, max_depth: int = 256) -> Iterator[Any]:
    """Every document in `stream`, in order."""
    return iter(_load(stream, True, merge_keys, max_depth))


def safe_dump(
    data: Any,
    stream: IO[Any] | None = None,
    *,
    default_flow_style: bool | None = False,
    indent: int = 2,
    width: int = 80,
    sort_keys: bool = True,
    explicit_start: bool = False,
    explicit_end: bool = False,
    encoding: str | None = None,
    allow_unicode: bool = True,
    max_depth: int = 256,
) -> Any:
    """`data` written as YAML: returned as a str (bytes with `encoding`),
    or written to `stream`, which is returned None. It writes dict, list,
    tuple, str, int, float, bool and None, what safe_load gives back; a
    string any reader, YAML 1.1 ones too, would read as something else is
    quoted. Keys are sorted unless `sort_keys=False`. Text is UTF-8 as it
    is, as with `allow_unicode=True` (accepted, and ignored)."""
    return safe_dump_all(
        [data],
        stream,
        default_flow_style=default_flow_style,
        indent=indent,
        width=width,
        sort_keys=sort_keys,
        explicit_start=explicit_start,
        explicit_end=explicit_end,
        encoding=encoding,
        allow_unicode=allow_unicode,
        max_depth=max_depth,
    )


def safe_dump_all(
    documents: Any,
    stream: IO[Any] | None = None,
    *,
    default_flow_style: bool | None = False,
    indent: int = 2,
    width: int = 80,
    sort_keys: bool = True,
    explicit_start: bool = False,
    explicit_end: bool = False,
    encoding: str | None = None,
    allow_unicode: bool = True,
    max_depth: int = 256,
) -> Any:
    """Each of `documents` written as a YAML document, `---` before each
    after the first (before the first too with `explicit_start`)."""
    if not 2 <= indent <= 8:
        raise ValueError("indent is 2 to 8")
    parts = []
    for i, doc in enumerate(documents):
        try:
            text = _yaml._dump(doc, bool(default_flow_style), indent, width, sort_keys, max_depth)
        except _yaml.Error as e:
            raise YAMLError(e.args[0]) from None
        if explicit_start or i > 0:
            text = "---\n" + text
        if explicit_end:
            text += "...\n"
        parts.append(text)
    out = "".join(parts)
    data = out.encode(encoding) if encoding is not None else out
    if stream is None:
        return data
    stream.write(data)
    return None
