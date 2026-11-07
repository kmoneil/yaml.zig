/* Python's C API as pyyaml-zig's extension uses it: the stable ABI of
   CPython 3.9 (abi3), so one build serves every CPython from 3.9 on.
   build.zig translates it to Zig (addTranslateC). */
#define Py_LIMITED_API 0x03090000
#define PY_SSIZE_T_CLEAN 1
#include <Python.h>
