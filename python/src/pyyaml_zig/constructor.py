"""PyYAML's yaml.constructor, for code that names its error class: ConstructorError."""

from .error import ConstructorError, MarkedYAMLError, YAMLError  # noqa: F401

__all__ = ["ConstructorError"]
