"""pyyaml_zig's tests: what safe_load builds, what it refuses, and where it
says it failed. Run with the package built (zig build python):

    PYTHONPATH=zig-out/python python3 -m unittest discover python/tests
"""

import io
import math
import unittest

import pyyaml_zig as yaml


class Scalars(unittest.TestCase):
    def test_core_schema(self):
        doc = yaml.safe_load(
            "int: 42\nneg: -7\nhex: 0x1F\noct: 0o17\nfloat: 2.5\nexp: 1e3\n"
            "inf: .inf\nninf: -.inf\nyes: true\nno: false\nnothing: ~\nempty:\n"
            "str: hello\nquoted: '1.10'\n"
        )
        self.assertEqual(doc["int"], 42)
        self.assertEqual(doc["neg"], -7)
        self.assertEqual(doc["hex"], 31)
        self.assertEqual(doc["oct"], 15)
        self.assertEqual(doc["float"], 2.5)
        self.assertEqual(doc["exp"], 1000.0)
        self.assertEqual(doc["inf"], math.inf)
        self.assertEqual(doc["ninf"], -math.inf)
        self.assertIs(doc["yes"], True)
        self.assertIs(doc["no"], False)
        self.assertIsNone(doc["nothing"])
        self.assertIsNone(doc["empty"])
        self.assertEqual(doc["str"], "hello")
        self.assertEqual(doc["quoted"], "1.10")

    def test_yaml_1_1_words_are_strings(self):
        # YAML 1.2: only true and false are booleans.
        self.assertEqual(yaml.safe_load("[yes, no, on, off]"), ["yes", "no", "on", "off"])

    def test_nan(self):
        self.assertTrue(math.isnan(yaml.safe_load(".nan")))

    def test_integers_past_64_bits(self):
        self.assertEqual(yaml.safe_load("123456789012345678901234567890"), 123456789012345678901234567890)
        self.assertEqual(yaml.safe_load("0x1000000000000000000"), 16**18)
        # The core schema signs only decimal integers: this is a string.
        self.assertEqual(yaml.safe_load("-0x10"), "-0x10")
        self.assertEqual(yaml.safe_load("0o7777777777777777777777"), int("7777777777777777777777", 8))

    def test_keys_are_typed_too(self):
        self.assertEqual(yaml.safe_load("1: a\n2: b\nnull: c\n"), {1: "a", 2: "b", None: "c"})


class Collections(unittest.TestCase):
    def test_nested(self):
        doc = yaml.safe_load("a:\n  - {b: [1, 2]}\n  - c\n")
        self.assertEqual(doc, {"a": [{"b": [1, 2]}, "c"]})

    def test_an_alias_is_the_anchored_object(self):
        doc = yaml.safe_load("x: &a [1, 2]\ny: *a\n")
        self.assertIs(doc["x"], doc["y"])

    def test_an_alias_inside_its_anchor_is_a_cycle(self):
        r = yaml.safe_load("&r [1, *r]")
        self.assertIs(r[1], r)

    def test_merge_keys(self):
        text = "base: &b {x: 1, y: 2}\nchild:\n  <<: *b\n  y: 3\n"
        self.assertEqual(yaml.safe_load(text)["child"], {"x": 1, "y": 3})
        self.assertEqual(yaml.safe_load(text, merge_keys=False)["child"], {"<<": {"x": 1, "y": 2}, "y": 3})


class Streams(unittest.TestCase):
    def test_inputs(self):
        self.assertEqual(yaml.safe_load(b"a: 1\n"), {"a": 1})
        self.assertEqual(yaml.safe_load(io.StringIO("a: 1\n")), {"a": 1})
        self.assertEqual(yaml.safe_load(io.BytesIO(b"a: 1\n")), {"a": 1})
        # UTF-16, by its byte order mark.
        self.assertEqual(yaml.safe_load("a: é\n".encode("utf-16")), {"a": "é"})

    def test_empty_stream(self):
        self.assertIsNone(yaml.safe_load(""))
        self.assertEqual(list(yaml.safe_load_all("")), [])

    def test_documents(self):
        self.assertEqual(list(yaml.safe_load_all("--- 1\n--- [a]\n--- ~\n")), [1, ["a"], None])

    def test_one_document_asked_for(self):
        with self.assertRaises(yaml.YAMLError) as caught:
            yaml.safe_load("--- 1\n--- 2\n")
        self.assertIn("expected a single document", caught.exception.problem)
        self.assertEqual(caught.exception.problem_mark.line, 1)


class Errors(unittest.TestCase):
    def assert_refused(self, text, problem, line, column, **options):
        with self.assertRaises(yaml.YAMLError) as caught:
            yaml.safe_load(text, **options)
        e = caught.exception
        self.assertIn(problem, e.problem)
        self.assertEqual((e.problem_mark.line, e.problem_mark.column), (line, column))

    def test_not_yaml(self):
        self.assert_refused("list: [1, 2\nnext: 3\n", "flow", 1, 0)

    def test_duplicate_key(self):
        self.assert_refused("a: 1\na: 2\n", "two equal keys", 1, 0)

    def test_unhashable_key(self):
        self.assert_refused("? [a]\n: 1\n", "unhashable key", 0, 2)

    def test_tags(self):
        self.assert_refused("!!int foo", "not what its tag says", 0, 0)
        self.assert_refused("!custom x", "could not determine a constructor", 0, 0)

    def test_depth(self):
        # The fifth collection open at once, past four.
        self.assert_refused("[" * 20 + "]" * 20, "deeper than max_depth", 0, 4, max_depth=4)

    def test_merge_of_a_scalar(self):
        self.assert_refused("m: {<<: 3}\n", "merge key's value", 0, 8)

    def test_message(self):
        try:
            yaml.safe_load("a: 1\na: 2\n")
        except yaml.YAMLError as e:
            self.assertEqual(str(e), 'a mapping cannot have two equal keys\n  in "<unicode string>", line 2, column 1')


class SameAsPyYAML(unittest.TestCase):
    """Where YAML 1.1 and 1.2 agree, the same objects as PyYAML's
    safe_load. Skipped when PyYAML is not installed."""

    documents = [
        "name: web\nports: [80, 443]\nratio: 0.75\nowner: ~\n",
        "- {a: 1, b: [x, y]}\n- 'quoted'\n- \"esc\\tape\"\n- |\n  literal\n  block\n- >\n  folded\n  text\n",
        "defaults: &d {image: alpine}\nweb:\n  <<: *d\n  port: 8080\n",
        "? complex\n: key\nlist:\n- - nested\n  - seq\n",
    ]

    def test_documents(self):
        try:
            import yaml as pyyaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        for text in self.documents:
            with self.subTest(text=text):
                self.assertEqual(yaml.safe_load(text), pyyaml.safe_load(text))


if __name__ == "__main__":
    unittest.main()
