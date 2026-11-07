"""Packs pyyaml-zig's wheel from zig-out/python/pyyaml_zig, which `zig build
python` writes: the package's Python files and this platform's extension.
The extension is built against CPython's stable ABI, so the wheel is tagged
cp39-abi3: one wheel serves CPython 3.9 and later on its platform. The
version is build.zig.zon's. The wheel is written byte for byte the same on
every run, into zig-out/wheels/.

    python3 -I tools/python_wheel.py PLATFORM_TAG

PLATFORM_TAG is the wheel's platform, such as macosx_11_0_arm64,
manylinux_2_17_x86_64.manylinux2014_x86_64.musllinux_1_1_x86_64 or
win_amd64. (After dateparsa's tools/python_wheels.py.)
"""

import base64
import hashlib
import io
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "zig-out", "python", "pyyaml_zig")
OUT = os.path.join(ROOT, "zig-out", "wheels")

SUMMARY = "Fast, safe YAML for Python: a drop-in for PyYAML, on yaml.zig."


def version() -> str:
    with open(os.path.join(ROOT, "build.zig.zon"), encoding="utf-8") as f:
        m = re.search(r'^\s*\.version = "([^"]+)",$', f.read(), re.M)
    if not m:
        sys.exit("build.zig.zon has no .version line")
    return m.group(1)


def metadata(v: str) -> str:
    with open(os.path.join(ROOT, "python", "README.md"), encoding="utf-8") as f:
        readme = f.read()
    headers = [
        "Metadata-Version: 2.1",
        "Name: pyyaml-zig",
        "Version: " + v,
        "Summary: " + SUMMARY,
        "Author: Kevin O'Neil",
        "License: MIT",
        "Project-URL: Source, https://github.com/kmoneil/yaml.zig",
        "Project-URL: Documentation, https://github.com/kmoneil/yaml.zig/tree/main/python",
        "Keywords: yaml,pyyaml,parser,yaml-1.2,fast,safe",
        "Classifier: Development Status :: 4 - Beta",
        "Classifier: Intended Audience :: Developers",
        "Classifier: License :: OSI Approved :: MIT License",
        "Classifier: Operating System :: MacOS",
        "Classifier: Operating System :: Microsoft :: Windows",
        "Classifier: Operating System :: POSIX :: Linux",
        "Classifier: Programming Language :: Python :: 3",
        "Classifier: Programming Language :: Python :: Implementation :: CPython",
        "Classifier: Topic :: Text Processing :: Markup",
        "Classifier: Typing :: Typed",
        "Requires-Python: >=3.9",
        "Description-Content-Type: text/markdown",
    ]
    return "\n".join(headers) + "\n\n" + readme


def wheel(tags: str) -> str:
    lines = ["Wheel-Version: 1.0", "Generator: yaml.zig tools/python_wheel.py", "Root-Is-Purelib: false"]
    lines += ["Tag: cp39-abi3-" + t for t in tags.split(".")]
    return "\n".join(lines) + "\n"


def record_hash(data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return "sha256=" + digest.decode()


def build(tags: str) -> str:
    v = version()
    info = "pyyaml_zig-%s.dist-info" % v
    files = []
    extensions = 0
    for name in sorted(os.listdir(PACKAGE)):
        path = os.path.join(PACKAGE, name)
        if name.endswith(".py") or name == "py.typed":
            mode = 0o644
        elif name in ("_yaml.abi3.so", "_yaml.pyd"):
            mode = 0o755
            extensions += 1
        else:
            continue
        with open(path, "rb") as f:
            files.append(("pyyaml_zig/" + name, f.read(), mode))
    if extensions != 1:
        sys.exit("zig-out/python/pyyaml_zig holds %d extensions, not 1: run zig build python first" % extensions)
    with open(os.path.join(ROOT, "LICENSE"), "rb") as f:
        files.append((info + "/LICENSE", f.read(), 0o644))
    files.append((info + "/METADATA", metadata(v).encode(), 0o644))
    files.append((info + "/WHEEL", wheel(tags).encode(), 0o644))
    record = "".join("%s,%s,%d\n" % (p, record_hash(d), len(d)) for p, d, _ in files)
    record += info + "/RECORD,,\n"
    files.append((info + "/RECORD", record.encode(), 0o644))

    name = "pyyaml_zig-%s-cp39-abi3-%s.whl" % (v, tags)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for path, data, mode in files:
            zi = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100000 | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(buf.getvalue())
    return name


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    print(build(sys.argv[1]))
    return 0


sys.exit(main())
