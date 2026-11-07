"""pyyaml_zig's YAML 1.1 reading held to PyYAML's own, input by input.
Skipped when PyYAML is not installed.

- Scalars: 20,000 plain scalars, generated from a fixed seed in the forms
  YAML 1.1 types (numbers in every base, sexagesimal, dates and times,
  booleans) and as random strings of the characters those forms use, each
  read by safe_load(schema="yaml11") and by PyYAML's SafeLoader.
- The yaml-test-suite: every input, with load_all(Loader=SafeLoader)
  against PyYAML's, when YAML_TEST_SUITE names the suite's data (a
  directory of cases, each with in.yaml).

    PYTHONPATH=zig-out/python python3 -m unittest discover python/tests
"""

import math
import os
import random
import unittest

import pyyaml_zig as yaml

try:
    import yaml as pyyaml

    LOADER = getattr(pyyaml, "CSafeLoader", pyyaml.SafeLoader)
except ImportError:
    pyyaml = None

# Where the two differ, and why each is right here.
SCALARS_PYYAML_FAILS_ON = {
    "=": "a value key, which PyYAML's SafeLoader cannot build",
    "<<": "a merge key as a value, which PyYAML refuses",
}
# Cases where PyYAML departs from YAML 1.2, which the suite holds.
SUITE_DIFFERENCES = {
    "652Z": "`?foo` in a flow mapping is a plain scalar",
    "S4JQ": "`! 12` is a string: the non-specific tag",
    "Y2GN": "an anchor's name may hold `:`",
}


def same(x, y):
    if type(x) is not type(y):
        return False
    if isinstance(x, float) and math.isnan(x):
        return math.isnan(y)
    if isinstance(x, dict):
        return len(x) == len(y) and all(k in y and same(x[k], y[k]) for k in x)
    if isinstance(x, (list, tuple)):
        return len(x) == len(y) and all(same(a, b) for a, b in zip(x, y))
    if hasattr(x, "utcoffset"):
        return x == y and x.utcoffset() == y.utcoffset()
    return x == y


def read(load, text):
    try:
        return "ok", load(text)
    except Exception as e:  # noqa: BLE001  PyYAML's own crashes count as failing
        return "error", type(e).__name__


def scalar(rng):
    d = lambda n: "".join(rng.choice("0123456789") for _ in range(n))  # noqa: E731
    u = lambda s: "".join(c + ("_" if rng.random() < 0.15 else "") for c in s)  # noqa: E731
    sign = rng.choice(["", "", "-", "+"])
    forms = [
        lambda: sign + u(d(rng.randint(1, 8))),
        lambda: sign + "0" + u("".join(rng.choice("01234567") for _ in range(rng.randint(1, 6)))),
        lambda: sign + "0b" + u("".join(rng.choice("01") for _ in range(rng.randint(1, 8)))),
        lambda: sign + "0x" + u("".join(rng.choice("0123456789abcdefABCDEF") for _ in range(rng.randint(1, 6)))),
        lambda: sign + u(d(rng.randint(1, 3))) + "".join(":" + d(rng.randint(1, 2)) for _ in range(rng.randint(1, 3))),
        lambda: sign + u(d(rng.randint(1, 4))) + "." + u(d(rng.randint(0, 4))) + rng.choice(["", "e+" + d(2), "E-" + d(1), "e3"]),
        lambda: sign + "." + d(rng.randint(0, 3)) + rng.choice(["", "e+1"]),
        lambda: sign + u(d(rng.randint(1, 2))) + ":" + d(rng.randint(1, 2)) + "." + d(rng.randint(0, 3)),
        lambda: rng.choice(["", "-", "+"]) + rng.choice([".inf", ".Inf", ".INF", ".nan", ".NaN", ".NAN", ".iNf"]),
        lambda: d(4) + "-" + d(rng.randint(1, 2)) + "-" + d(rng.randint(1, 2)),
        lambda: d(4) + "-" + d(rng.randint(1, 2)) + "-" + d(rng.randint(1, 2)) + rng.choice(["T", "t", " ", "\t"])
        + d(rng.randint(1, 2)) + ":" + d(2) + ":" + d(2) + rng.choice(["", "." + d(rng.randint(0, 9))])
        + rng.choice(["", "Z", " Z", "+" + d(rng.randint(1, 2)), "-" + d(rng.randint(1, 2)) + ":" + d(2), " -5", "z"]),
        lambda: rng.choice(["y", "n", "yes", "Yes", "YES", "yEs", "no", "NO", "on", "On", "off", "OFF", "true",
                            "False", "null", "Null", "~", "nULL", "=", "<<"]),
        lambda: "".join(rng.choice("0123456789_:.-+eEbxoTZ ") for _ in range(rng.randint(1, 12))).strip(),
    ]
    return rng.choice(forms)()


@unittest.skipIf(pyyaml is None, "PyYAML is not installed")
class AgainstPyYAML(unittest.TestCase):
    def test_scalars(self):
        rng = random.Random(1)
        differ = []
        for _ in range(20000):
            s = scalar(rng)
            if not s or s[0] in "-?:" and (len(s) == 1 or s[1] == " "):
                continue
            text = "k: " + s + "\n"
            ours = read(lambda t: yaml.safe_load(t, schema="yaml11"), text)
            theirs = read(lambda t: pyyaml.load(t, Loader=LOADER), text)
            if ours[0] == theirs[0] == "error" or ours[0] == theirs[0] == "ok" and same(ours[1], theirs[1]):
                continue
            # Where PyYAML fails on a form it resolves (`0b_`, `=`), the
            # scalar here is the string it is written as.
            if theirs[0] == "error" and ours == ("ok", {"k": s}):
                continue
            differ.append((s, ours, theirs))
        self.assertEqual(differ[:10], [])

    @unittest.skipUnless(os.environ.get("YAML_TEST_SUITE"), "YAML_TEST_SUITE names no suite data")
    def test_the_suite(self):
        root = os.environ["YAML_TEST_SUITE"]
        same_count = 0
        differ = []
        for case in sorted(os.listdir(root)):
            path = os.path.join(root, case, "in.yaml")
            if not os.path.exists(path):
                continue
            with open(path, encoding="utf-8") as f:
                text = f.read()
            ours = read(lambda t: list(yaml.load_all(t, Loader=yaml.SafeLoader)), text)
            theirs = read(lambda t: list(pyyaml.load_all(t, Loader=pyyaml.SafeLoader)), text)
            if ours[0] == "ok" and theirs[0] == "ok":
                if same(ours[1], theirs[1]):
                    same_count += 1
                elif case not in SUITE_DIFFERENCES:
                    differ.append(case)
            elif ours[0] == "error" and theirs[0] == "ok" and not os.path.exists(os.path.join(root, case, "error")):
                differ.append(case)  # valid YAML PyYAML reads and this does not
        self.assertEqual(differ, [])
        self.assertGreater(same_count, 180)


if __name__ == "__main__":
    unittest.main()
