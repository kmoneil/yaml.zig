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

__all__ = ["safe_load", "safe_load_all", "YAMLError", "Mark", "__version__"]

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
