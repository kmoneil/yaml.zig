"""safe_dump's tests: what it writes reads back the same, here and in
PyYAML; what it quotes; its options; what it refuses.

    PYTHONPATH=zig-out/python python3 -m unittest discover python/tests
"""

import io
import math
import unittest

import pyyaml_zig as yaml

DATA = [
    {"name": "web", "ports": [80, 443], "ratio": 0.75, "owner": None, "debug": True},
    [1, -2, 2**70, -(2**80), 0.5, -1e300, "", "text", "héllo wörld", "multi\nline\n"],
    {"nested": {"deep": [{"x": [1, [2, [3]]]}]}, "empty": {}, "none": []},
    {1: "int key", None: "null key", 2.5: "float key", True: "bool key"},
    "a plain document",
    42,
    None,
]

# Strings a YAML 1.1 reader (PyYAML) would read as something else if they
# were written plain.
AMBIGUOUS = ["yes", "No", "on", "OFF", "y", "n", "true", "null", "~", "1:20", "0777", "1_000", "0b101",
             "2001-12-14", "<<", "1.10", "0x1F", ".inf", "-.nan", "", " lead", "trail ", "#hash", "a: b", "- dash"]


class RoundTrip(unittest.TestCase):
    def test_reads_back_the_same(self):
        for data in DATA:
            with self.subTest(data=data):
                back = yaml.safe_load(yaml.safe_dump(data))
                self.assertEqual(back, _lists(data))

    def test_floats(self):
        back = yaml.safe_load(yaml.safe_dump([math.inf, -math.inf, math.nan, 1e-300]))
        self.assertEqual(back[:2], [math.inf, -math.inf])
        self.assertTrue(math.isnan(back[2]))
        self.assertEqual(back[3], 1e-300)

    def test_ambiguous_strings_stay_strings(self):
        text = yaml.safe_dump(AMBIGUOUS)
        self.assertEqual(yaml.safe_load(text), AMBIGUOUS)

    def test_pyyaml_reads_it_the_same(self):
        try:
            import yaml as pyyaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        for data in DATA + [AMBIGUOUS]:
            with self.subTest(data=data):
                self.assertEqual(pyyaml.safe_load(yaml.safe_dump(data)), _lists(data))


class Options(unittest.TestCase):
    def test_keys_sorted_unless_asked(self):
        self.assertEqual(yaml.safe_dump({"b": 1, "a": 2}), "a: 2\nb: 1\n")
        self.assertEqual(yaml.safe_dump({"b": 1, "a": 2}, sort_keys=False), "b: 1\na: 2\n")

    def test_keys_that_cannot_be_sorted_keep_their_order(self):
        self.assertEqual(yaml.safe_dump({"b": 1, 2: "x"}), "b: 1\n2: x\n")

    def test_flow_style(self):
        self.assertEqual(yaml.safe_dump({"a": [1, 2]}, default_flow_style=True), "{a: [1, 2]}\n")

    def test_documents(self):
        self.assertEqual(yaml.safe_dump_all([1, {"a": 1}]), "1\n---\na: 1\n")
        self.assertEqual(yaml.safe_dump({"a": 1}, explicit_start=True, explicit_end=True), "---\na: 1\n...\n")
        self.assertEqual(list(yaml.safe_load_all(yaml.safe_dump_all([1, [2], {"c": 3}]))), [1, [2], {"c": 3}])

    def test_stream_and_encoding(self):
        out = io.StringIO()
        self.assertIsNone(yaml.safe_dump({"a": 1}, out))
        self.assertEqual(out.getvalue(), "a: 1\n")
        self.assertEqual(yaml.safe_dump({"a": "é"}, encoding="utf-8"), "a: é\n".encode())

    def test_indent(self):
        self.assertEqual(yaml.safe_dump({"a": {"b": 1}}, indent=4), "a:\n    b: 1\n")
        # An indent PyYAML ignores is the default, as there; 9 it takes
        # and pyyaml-zig cannot.
        self.assertEqual(yaml.safe_dump({"a": {"b": 1}}, indent=1), "a:\n  b: 1\n")
        with self.assertRaises(ValueError):
            yaml.safe_dump({}, indent=9)


class Refused(unittest.TestCase):
    def test_types_safe_load_does_not_give(self):
        for data in [{1, 2}, object(), b"bytes", 1j]:
            with self.subTest(data=data):
                with self.assertRaises(yaml.YAMLError) as caught:
                    yaml.safe_dump(data)
                self.assertIn("cannot represent an object of type", caught.exception.problem)

    def test_data_that_holds_itself(self):
        a = []
        a.append(a)
        with self.assertRaises(yaml.YAMLError) as caught:
            yaml.safe_dump(a)
        self.assertIn("holds itself", caught.exception.problem)


def _lists(data):
    """`data` as it reads back: a tuple is a list. (A tuple key would read
    back as a list, which no dict takes: safe_load refuses it, as PyYAML's
    does, so the data here has none.)"""
    if isinstance(data, (list, tuple)):
        return [_lists(x) for x in data]
    if isinstance(data, dict):
        return {k: _lists(v) for k, v in data.items()}
    return data


if __name__ == "__main__":
    unittest.main()
