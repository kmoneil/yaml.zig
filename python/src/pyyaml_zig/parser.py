"""PyYAML's yaml.parser, for code that names its error class: ParserError."""

from .error import ParserError, MarkedYAMLError, YAMLError  # noqa: F401

__all__ = ["ParserError"]
