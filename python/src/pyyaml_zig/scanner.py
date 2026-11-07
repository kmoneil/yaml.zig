"""PyYAML's yaml.scanner, for code that names its error class: ScannerError."""

from .error import ScannerError, MarkedYAMLError, YAMLError  # noqa: F401

__all__ = ["ScannerError"]
