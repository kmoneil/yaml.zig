"""PyYAML's dumper names, for `dump(data, Dumper=...)`.

Each writes as safe_dump does: dict, list, tuple, str, int, float, bool,
None, date and datetime, and a RepresenterError for anything else. None
writes `!!python/` tags. The C names are the same dumpers.
"""

from __future__ import annotations

from typing import Any, NoReturn

from .loader import _not_supported

__all__ = ["BaseDumper", "SafeDumper", "Dumper", "CBaseDumper", "CSafeDumper", "CDumper"]


class BaseDumper:
    """Writes as safe_dump does."""

    def __init__(self, *args: Any, **kwds: Any) -> None:
        raise TypeError("pyyaml-zig's dumpers are names to pass as Dumper=, not objects to make")

    @classmethod
    def add_representer(cls, data_type: Any, representer: Any) -> NoReturn:
        _not_supported("add_representer")

    @classmethod
    def add_multi_representer(cls, data_type: Any, multi_representer: Any) -> NoReturn:
        _not_supported("add_multi_representer")

    @classmethod
    def add_implicit_resolver(cls, tag: str, regexp: Any, first: Any) -> NoReturn:
        _not_supported("add_implicit_resolver")

    @classmethod
    def add_path_resolver(cls, tag: str, path: Any, kind: Any = None) -> NoReturn:
        _not_supported("add_path_resolver")


class SafeDumper(BaseDumper):
    pass


class Dumper(SafeDumper):
    """SafeDumper: no object is written with a `!!python/` tag."""


class CBaseDumper(BaseDumper):
    pass


class CSafeDumper(SafeDumper):
    pass


class CDumper(Dumper):
    pass
