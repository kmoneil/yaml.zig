"""PyYAML's loader names, for `load(stream, Loader=...)`.

Each is a set of reading options, not a parser to extend, and every one
of them is safe: none builds a Python object from a tag, `!!python/...`
being refused with a ConstructorError as PyYAML's SafeLoader refuses it.

- SafeLoader, FullLoader, UnsafeLoader and Loader read YAML 1.1 as
  PyYAML's SafeLoader does: `yes` is True, `0777` is 511, dates are
  datetime's, merge keys are applied, and a mapping's later equal key
  wins. (FullLoader, UnsafeLoader and Loader differ from SafeLoader only
  on `!!python/` tags.)
- BaseLoader reads every scalar as a str, as PyYAML's does.

The C names, CSafeLoader and the rest, are the same loaders.
"""

from __future__ import annotations

from typing import Any, NoReturn

__all__ = [
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
]


def _not_supported(what: str) -> NoReturn:
    raise NotImplementedError(
        "pyyaml-zig has no %s: it builds no Python objects from tags, and reads only the "
        "core tags and timestamps. Use PyYAML for custom tags." % what
    )


class BaseLoader:
    """Every scalar a str, no merge keys: PyYAML's BaseLoader."""

    _schema = "failsafe"
    _merge_keys = False

    def __init__(self, stream: Any) -> None:
        self._stream = stream

    def get_single_data(self) -> Any:
        from . import load

        return load(self._stream, type(self))

    def dispose(self) -> None:
        pass

    @classmethod
    def add_constructor(cls, tag: str, constructor: Any) -> NoReturn:
        _not_supported("add_constructor")

    @classmethod
    def add_multi_constructor(cls, tag_prefix: str, multi_constructor: Any) -> NoReturn:
        _not_supported("add_multi_constructor")

    @classmethod
    def add_implicit_resolver(cls, tag: str, regexp: Any, first: Any) -> NoReturn:
        _not_supported("add_implicit_resolver")

    @classmethod
    def add_path_resolver(cls, tag: str, path: Any, kind: Any = None) -> NoReturn:
        _not_supported("add_path_resolver")


class SafeLoader(BaseLoader):
    """YAML 1.1 as PyYAML's SafeLoader reads it."""

    _schema = "yaml11"
    _merge_keys = True


class FullLoader(SafeLoader):
    """SafeLoader: no tag builds a Python object."""


class UnsafeLoader(SafeLoader):
    """SafeLoader: no tag builds a Python object."""


class Loader(SafeLoader):
    """SafeLoader: no tag builds a Python object."""


class CBaseLoader(BaseLoader):
    pass


class CSafeLoader(SafeLoader):
    pass


class CFullLoader(FullLoader):
    pass


class CUnsafeLoader(UnsafeLoader):
    pass


class CLoader(Loader):
    pass
