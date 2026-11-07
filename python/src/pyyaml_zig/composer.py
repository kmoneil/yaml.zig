"""PyYAML's yaml.composer, for code that names its error class: ComposerError."""

from .error import ComposerError, MarkedYAMLError, YAMLError  # noqa: F401

__all__ = ["ComposerError"]
