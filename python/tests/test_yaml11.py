"""safe_load's schemas: YAML 1.1 read as PyYAML reads it (schema="yaml11"),
yaml.org's type pages first; and the JSON and failsafe schemas.

    PYTHONPATH=zig-out/python python3 -m unittest discover python/tests
"""

import datetime
import math
import unittest

import pyyaml_zig as yaml

UTC = datetime.timezone.utc

# yaml.org/type: bool, int, float, timestamp and null, as written there.
PAGES = {
    "bool": "canonical: y\nanswer: NO\nlogical: True\noption: on\n",
    "int": "canonical: 685230\ndecimal: +685_230\noctal: 02472256\nhexadecimal: 0x_0A_74_AE\n"
    "binary: 0b1010_0111_0100_1010_1110\nsexagesimal: 190:20:30\n",
    "float": "canonical: 6.8523015e+5\nexponential: 685.230_15e+03\nfixed: 685_230.15\n"
    "sexagesimal: 190:20:30.15\nnegative infinity: -.inf\nnot a number: .NaN\n",
    "timestamp": "canonical: 2001-12-15T02:59:43.1Z\nvalid iso8601: 2001-12-14t21:59:43.10-05:00\n"
    "space separated: 2001-12-14 21:59:43.10 -5\nno time zone (Z): 2001-12-15 2:59:43.10\n"
    "date (00:00:00Z): 2002-12-14\n",
    "null": "empty:\ncanonical: ~\nenglish: null\n~: null key\n",
}


def load11(text):
    return yaml.safe_load(text, schema="yaml11")


class TypePages(unittest.TestCase):
    def test_bool(self):
        # y is a string: on the type page, not in PyYAML.
        self.assertEqual(load11(PAGES["bool"]), {"canonical": "y", "answer": False, "logical": True, "option": True})

    def test_int(self):
        self.assertEqual(set(load11(PAGES["int"]).values()), {685230})

    def test_float(self):
        doc = load11(PAGES["float"])
        self.assertEqual({doc[k] for k in ("canonical", "exponential", "fixed", "sexagesimal")}, {685230.15})
        self.assertEqual(doc["negative infinity"], -math.inf)
        self.assertTrue(math.isnan(doc["not a number"]))

    def test_timestamp(self):
        doc = load11(PAGES["timestamp"])
        moment = datetime.datetime(2001, 12, 15, 2, 59, 43, 100000, tzinfo=UTC)
        self.assertEqual(doc["canonical"], moment)
        self.assertIs(doc["canonical"].tzinfo, UTC)
        self.assertEqual(doc["valid iso8601"], moment)
        self.assertEqual(doc["valid iso8601"].utcoffset(), datetime.timedelta(hours=-5))
        self.assertEqual(doc["space separated"], moment)
        naive = doc["no time zone (Z)"]
        self.assertEqual(naive, datetime.datetime(2001, 12, 15, 2, 59, 43, 100000))
        self.assertIsNone(naive.tzinfo)
        self.assertIs(type(doc["date (00:00:00Z)"]), datetime.date)
        self.assertEqual(doc["date (00:00:00Z)"], datetime.date(2002, 12, 14))

    def test_null(self):
        self.assertEqual(load11(PAGES["null"]), {"empty": None, "canonical": None, "english": None, None: "null key"})


class Yaml11(unittest.TestCase):
    def test_against_core(self):
        text = "[yes, 0777, 1:20, 2001-12-14, 1_000, 1e3, 0o17]"
        self.assertEqual(yaml.safe_load(text), ["yes", 777, "1:20", "2001-12-14", "1_000", 1000.0, 15])
        self.assertEqual(load11(text), [True, 511, 80, datetime.date(2001, 12, 14), 1000, "1e3", "0o17"])

    def test_keys(self):
        self.assertEqual(load11("on: 1\n0x1F: 2\n"), {True: 1, 31: 2})
        with self.assertRaises(yaml.YAMLError) as caught:
            load11("0777: a\n511: b\n")
        self.assertIn("two equal keys", caught.exception.problem)

    def test_integers_past_64_bits(self):
        self.assertEqual(load11("0b" + "1" * 70), 2**70 - 1)
        self.assertEqual(load11("-0" + "7" * 30), -int("7" * 30, 8))
        self.assertEqual(load11("1_000_000_000_000_000_000_000"), 10**21)
        self.assertEqual(load11("-0x_FFFF_FFFF_FFFF_FFFF_FFFF"), -(16**20 - 1))
        self.assertEqual(load11("9999999999999999999:59"), 9999999999999999999 * 60 + 59)

    def test_explicit_tags(self):
        self.assertEqual(load11("[!!int 0o17, !!float 1e3, !!bool yes]"), [15, 1000.0, True])
        # A timestamp tag builds a date under any schema.
        self.assertEqual(yaml.safe_load("!!timestamp 2001-12-14"), datetime.date(2001, 12, 14))

    def test_timestamps_that_name_no_real_day(self):
        for text, problem in [
            ("2001-02-30", "not a real date and time"),
            ("2001-12-14 24:00:00", "not a real date and time"),
            ("0000-01-01", "out of Python's range"),
        ]:
            with self.subTest(text=text):
                with self.assertRaises(yaml.YAMLError) as caught:
                    load11("a: " + text)
                self.assertIn(problem, caught.exception.problem)
                self.assertEqual((caught.exception.problem_mark.line, caught.exception.problem_mark.column), (0, 3))

    def test_same_as_pyyaml(self):
        try:
            import yaml as pyyaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        for name, text in PAGES.items():
            if name == "float":
                continue  # NaN equals nothing; test_float checks it
            with self.subTest(page=name):
                self.assertEqual(load11(text), pyyaml.safe_load(text))
        text = "a: [yes, No, 0777, 0x_1F, 1:20, 1:20.5, .5, 1., 2001-12-14, ~, '0777']\nb: {on: off}\n"
        self.assertEqual(load11(text), pyyaml.safe_load(text))


class OtherSchemas(unittest.TestCase):
    def test_failsafe(self):
        self.assertEqual(yaml.safe_load("[1, true, null, ~]", schema="failsafe"), ["1", "true", "null", "~"])

    def test_json(self):
        self.assertEqual(yaml.safe_load("[1, true, null]", schema="json"), [1, True, None])
        with self.assertRaises(yaml.YAMLError):
            yaml.safe_load("[word]", schema="json")

    def test_unknown(self):
        with self.assertRaises(ValueError):
            yaml.safe_load("a", schema="yaml12")


if __name__ == "__main__":
    unittest.main()
