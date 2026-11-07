"""PyYAML's error classes, as pyyaml_zig raises them.

Every error is a YAMLError. One found in the input is a MarkedYAMLError,
with `problem` (what) and `problem_mark` (where): a ReaderError for its
encoding, a ScannerError or ParserError for its syntax, a ComposerError
for an undefined alias or a second document where one was asked for, a
ConstructorError for a tag, a key or a merge it cannot build. Writing
raises a RepresenterError.

yaml.zig does not tell a scanner's errors from a parser's, so a syntax
error is a YAMLSyntaxError, which is both: `except ScannerError` and
`except ParserError` each catch it.
"""

from __future__ import annotations

__all__ = [
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
]


class Mark:
    """A place in the input: `line` and `column` count from 0, as PyYAML's
    marks do, and `name` is the input's, `"<unicode string>"`, `"<byte
    string>"` or a file's name. `index`, `buffer` and `pointer` are None:
    pyyaml_zig keeps no copy of the input to show."""

    def __init__(self, name: str, line: int, column: int) -> None:
        self.name = name
        self.index = None
        self.line = line
        self.column = column
        self.buffer = None
        self.pointer = None

    def get_snippet(self, indent: int = 4, max_length: int = 75) -> None:
        return None

    def __str__(self) -> str:
        return '  in "%s", line %d, column %d' % (self.name, self.line + 1, self.column + 1)

    def __repr__(self) -> str:
        return "Mark(name=%r, line=%d, column=%d)" % (self.name, self.line, self.column)


class YAMLError(Exception):
    """Any error pyyaml_zig raises."""


class MarkedYAMLError(YAMLError):
    """An error in the input, at a mark: written as PyYAML writes one."""

    def __init__(
        self,
        context: str | None = None,
        context_mark: Mark | None = None,
        problem: str | None = None,
        problem_mark: Mark | None = None,
        note: str | None = None,
    ) -> None:
        super().__init__(context, context_mark, problem, problem_mark, note)
        self.context = context
        self.context_mark = context_mark
        self.problem = problem
        self.problem_mark = problem_mark
        self.note = note

    def __str__(self) -> str:
        lines = [str(x) for x in (self.context, self.context_mark, self.problem, self.problem_mark, self.note) if x is not None]
        return "\n".join(lines)


class ReaderError(MarkedYAMLError):
    """The input is not in an encoding YAML is written in."""


class ScannerError(MarkedYAMLError):
    pass


class ParserError(MarkedYAMLError):
    pass


class YAMLSyntaxError(ScannerError, ParserError):
    """The input is not YAML: a scanner's error or a parser's, which
    yaml.zig does not tell apart."""


class ComposerError(MarkedYAMLError):
    pass


class ConstructorError(MarkedYAMLError):
    pass


class RepresenterError(YAMLError):
    """Data that cannot be written. `problem` says why; `problem_mark` is
    None, there being no input."""

    def __init__(self, problem: str) -> None:
        super().__init__(problem)
        self.problem = problem
        self.problem_mark = None

    def __str__(self) -> str:
        return self.problem


class EmitterError(YAMLError):
    """Never raised: PyYAML's name, for code that catches it."""


class SerializerError(YAMLError):
    """Never raised: PyYAML's name, for code that catches it."""


_KINDS = {
    "reader": ReaderError,
    "syntax": YAMLSyntaxError,
    "composer": ComposerError,
    "constructor": ConstructorError,
}


def _from_extension(args: tuple, name: str) -> YAMLError:
    """The error for the extension's: args (message, line, column, kind)."""
    problem, line, column, kind = args
    if kind == "representer":
        return RepresenterError(problem)
    mark = Mark(name, line, column) if line >= 0 else None
    return _KINDS[kind](problem=problem, problem_mark=mark)
