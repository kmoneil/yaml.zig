"""pyyaml_zig as a drop-in for PyYAML: code written for PyYAML, run
unchanged with `import pyyaml_zig as yaml`, and its results checked
against PyYAML's own where PyYAML is installed.

    PYTHONPATH=zig-out/python python3 -m unittest discover python/tests
"""

import datetime
import io
import os
import tempfile
import unittest

import pyyaml_zig as yaml

try:
    import yaml as pyyaml
except ImportError:
    pyyaml = None

# A file written for PyYAML: YAML 1.1's booleans, octal, sexagesimal and
# dates, a merge key, and a key given twice.
LEGACY = """\
defaults: &defaults
  adapter: postgres
  host: localhost
  ssl: on
development:
  <<: *defaults
  database: dev
  port: 05432
  retries: 1_000
schedule:
  window: 1:30
  since: 2001-12-14
  at: 2001-12-14 21:59:43.10 -5
countries: [NO, SE, FI]
mode: 0755
ratio: 1.5
debug: no
empty:
tilde: ~
dup: 1
dup: 2
"""

LOADERS = ["SafeLoader", "FullLoader", "Loader", "UnsafeLoader", "BaseLoader", "CSafeLoader", "CLoader", "CBaseLoader"]


def needs_pyyaml(test):
    return unittest.skipIf(pyyaml is None, "PyYAML is not installed")(test)


class Loading(unittest.TestCase):
    def test_safe_loader_reads_as_pyyaml(self):
        doc = yaml.load(LEGACY, Loader=yaml.SafeLoader)
        self.assertEqual(doc["development"], {"adapter": "postgres", "host": "localhost", "ssl": True,
                                              "database": "dev", "port": 0o5432, "retries": 1000})
        self.assertEqual(doc["schedule"]["window"], 90)
        self.assertEqual(doc["schedule"]["since"], datetime.date(2001, 12, 14))
        self.assertEqual(doc["countries"], [False, "SE", "FI"])
        self.assertEqual((doc["mode"], doc["debug"], doc["empty"], doc["dup"]), (0o755, False, None, 2))

    @needs_pyyaml
    def test_every_loader_as_pyyamls(self):
        for name in LOADERS:
            theirs = getattr(pyyaml, name, None)
            if theirs is None:
                continue  # a C loader, where PyYAML has no libyaml
            with self.subTest(loader=name):
                self.assertEqual(yaml.load(LEGACY, Loader=getattr(yaml, name)), pyyaml.load(LEGACY, Loader=theirs))

    @needs_pyyaml
    def test_load_all_and_the_shorthands(self):
        text = "--- {a: yes}\n--- [0x10, 1:00]\n--- ~\n"
        want = list(pyyaml.load_all(text, Loader=pyyaml.SafeLoader))
        self.assertEqual(list(yaml.load_all(text, Loader=yaml.SafeLoader)), want)
        self.assertEqual(list(yaml.full_load_all(text)), want)
        self.assertEqual(list(yaml.unsafe_load_all(text)), want)
        self.assertEqual(yaml.full_load("a: on"), {"a": True})
        self.assertEqual(yaml.unsafe_load("a: off"), {"a": False})

    def test_safe_load_stays_yaml_1_2(self):
        with self.assertRaises(yaml.constructor.ConstructorError):
            yaml.safe_load(LEGACY)  # dup: given twice
        self.assertEqual(yaml.safe_load("debug: no\nmode: 0755\n"), {"debug": "no", "mode": 755})

    def test_the_c_loader_fallback(self):
        try:
            from pyyaml_zig import CSafeLoader as FastLoader
        except ImportError:
            from pyyaml_zig import SafeLoader as FastLoader
        self.assertEqual(yaml.load("a: [1, 2]", Loader=FastLoader), {"a": [1, 2]})
        self.assertFalse(yaml.__with_libyaml__)

    def test_a_loader_made_and_used(self):
        loader = yaml.SafeLoader(io.StringIO("a: yes\n"))
        try:
            self.assertEqual(loader.get_single_data(), {"a": True})
        finally:
            loader.dispose()

    def test_a_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "config.yaml")
            with open(path, "w") as f:
                f.write("a: 1\nb: [\n")
            with open(path) as f:
                with self.assertRaises(yaml.YAMLError) as caught:
                    yaml.load(f, Loader=yaml.FullLoader)
            self.assertEqual(caught.exception.problem_mark.name, path)

    def test_no_tag_builds_an_object(self):
        for name in ["SafeLoader", "FullLoader", "Loader", "UnsafeLoader"]:
            with self.subTest(loader=name):
                with self.assertRaises(yaml.constructor.ConstructorError):
                    yaml.load("!!python/object/apply:os.system ['echo hi']", Loader=getattr(yaml, name))

    def test_the_other_types_pyyamls_safe_loader_builds(self):
        text = "set: !!set {a, b}\nbytes: !!binary aGVs\n  bG8=\nomap: !!omap [a: 1, b: 2]\npairs: !!pairs [{a: 1}, {a: 2}]\n"
        doc = yaml.load(text, Loader=yaml.SafeLoader)
        self.assertEqual(doc, {"set": {"a", "b"}, "bytes": b"hello", "omap": [("a", 1), ("b", 2)], "pairs": [("a", 1), ("a", 2)]})
        if pyyaml is not None:
            self.assertEqual(doc, pyyaml.load(text, Loader=pyyaml.SafeLoader))
        # Explicitly tagged, they are built under any schema.
        self.assertEqual(yaml.safe_load(text), doc)
        for bad in ["!!omap [a, b]", "!!omap [{a: 1, b: 2}]", "!!binary é", "!!set [a]", "!!seq {a: 1}"]:
            with self.subTest(text=bad):
                with self.assertRaises(yaml.constructor.ConstructorError):
                    yaml.load(bad, Loader=yaml.SafeLoader)

    def test_a_loader_is_required(self):
        with self.assertRaises(TypeError):
            yaml.load("a: 1")  # as PyYAML 6
        with self.assertRaises(TypeError):
            yaml.load("a: 1", Loader=dict)


class Errors(unittest.TestCase):
    # Each input and the error class PyYAML's SafeLoader raises for it.
    CASES = [
        ("a: [1, 2\nb: 3\n", "ParserError"),
        ("a: b: c\n", "ScannerError"),
        ("a: *nowhere\n", "ComposerError"),
        ("--- 1\n--- 2\n", "ComposerError"),
        ("? [a]\n: 1\n", "ConstructorError"),
        ("!!python/name:os.system ''\n", "ConstructorError"),
        ("m: {<<: 3}\n", "ConstructorError"),
    ]

    def test_classes(self):
        for text, name in self.CASES:
            with self.subTest(text=text):
                with self.assertRaises(getattr(yaml, name)) as caught:
                    yaml.load(text, Loader=yaml.SafeLoader)
                self.assertIsInstance(caught.exception, yaml.MarkedYAMLError)
                self.assertIsInstance(caught.exception, yaml.YAMLError)

    @needs_pyyaml
    def test_classes_are_pyyamls(self):
        for text, name in self.CASES:
            with self.subTest(text=text):
                with self.assertRaises(pyyaml.YAMLError) as theirs:
                    pyyaml.load(text, Loader=pyyaml.SafeLoader)
                self.assertEqual(type(theirs.exception).__name__, name)

    def test_the_usual_handler(self):
        # As PyYAML's documentation handles an error.
        try:
            yaml.load("a: [1, 2\nb: 3\n", Loader=yaml.SafeLoader)
        except yaml.YAMLError as exc:
            self.assertTrue(hasattr(exc, "problem_mark"))
            mark = exc.problem_mark
            # Where a syntax error is found is each parser's own: PyYAML
            # says column 2.
            self.assertEqual((mark.line + 1, mark.column + 1), (2, 1))
            self.assertIn('in "<unicode string>", line 2, column 1', str(exc))
        else:
            self.fail("no error")

    def test_modules(self):
        self.assertIs(yaml.scanner.ScannerError, yaml.ScannerError)
        self.assertIs(yaml.parser.ParserError, yaml.ParserError)
        self.assertIs(yaml.composer.ComposerError, yaml.ComposerError)
        self.assertIs(yaml.constructor.ConstructorError, yaml.ConstructorError)
        self.assertIs(yaml.representer.RepresenterError, yaml.RepresenterError)
        self.assertIs(yaml.reader.ReaderError, yaml.ReaderError)
        from pyyaml_zig.scanner import ScannerError

        with self.assertRaises(ScannerError):
            yaml.safe_load("a: b: c\n")


DATA = {
    "name": "web",
    "ports": [80, 443],
    "ratio": 0.75,
    "owner": None,
    "debug": True,
    "nested": {"list": [{"a": 1}, {"b": [2, 3]}], "empty": {}, "none": []},
    "words": ["yes", "no", "on", "1.0", "0777", "2001-12-14", "plain text"],
    "since": datetime.date(2001, 12, 14),
    "at": datetime.datetime(2001, 12, 14, 21, 59, 43, 100000, tzinfo=datetime.timezone(datetime.timedelta(hours=-5))),
    "naive": datetime.datetime(2001, 12, 15, 2, 59, 43),
}


class Dumping(unittest.TestCase):
    def test_round_trip_through_safe_loader(self):
        self.assertEqual(yaml.load(yaml.dump(DATA), Loader=yaml.SafeLoader), DATA)

    @needs_pyyaml
    def test_pyyaml_reads_it_the_same(self):
        flowing = {k: v for k, v in DATA.items() if not isinstance(v, datetime.datetime)}
        for data, options in [(DATA, {}), (flowing, {"default_flow_style": True}), (DATA, {"sort_keys": False, "indent": 4})]:
            with self.subTest(options=options):
                self.assertEqual(pyyaml.load(yaml.dump(data, **options), Loader=pyyaml.SafeLoader), data)

    @needs_pyyaml
    def test_documents_marked_as_pyyaml_marks_them(self):
        for docs, options in [([1, 2], {}), ([1, {"a": 1}, [], "x"], {"explicit_start": True}), (["yes"], {}),
                              ([None], {}), ([{"a": 1}], {"explicit_end": True}), ([[1]], {}), (["multi\nline"], {})]:
            with self.subTest(docs=docs, options=options):
                self.assertEqual(yaml.dump_all(docs, **options), pyyaml.dump_all(docs, **options))

    @needs_pyyaml
    def test_written_as_pyyaml_writes_it(self):
        config = {"name": "web", "ports": [80, 443], "env": {"DEBUG": "no", "LEVEL": 3}, "since": DATA["since"], "at": DATA["at"]}
        for options in [{}, {"sort_keys": False}, {"explicit_start": True}]:
            with self.subTest(options=options):
                self.assertEqual(yaml.dump(config, **options), pyyaml.dump(config, **options))

    def test_the_usual_calls(self):
        out = io.StringIO()
        self.assertIsNone(yaml.dump(DATA, out, default_flow_style=False, sort_keys=False))
        self.assertEqual(yaml.load(out.getvalue(), Loader=yaml.SafeLoader), DATA)
        self.assertEqual(yaml.safe_dump({"a": "é"}, allow_unicode=True, encoding="utf-8"), "a: é\n".encode())
        self.assertEqual(yaml.dump({"a": "x " * 60}, width=float("inf")), "a: '" + "x " * 59 + "x '\n")
        self.assertEqual(yaml.dump({"a": 1}, Dumper=yaml.SafeDumper), "a: 1\n")
        self.assertEqual(yaml.dump_all([1, 2], explicit_start=True), "--- 1\n--- 2\n...\n")

    def test_what_it_refuses(self):
        with self.assertRaises(yaml.representer.RepresenterError):
            yaml.dump(object())
        # Quoted in flow style, a time would read back as a string.
        with self.assertRaises(yaml.RepresenterError):
            yaml.dump({"at": DATA["at"]}, default_flow_style=True)
        self.assertEqual(yaml.dump({"on": DATA["since"]}, default_flow_style=True), "{'on': 2001-12-14}\n")
        for option in [{"default_style": '"'}, {"canonical": True}, {"line_break": "\r\n"}, {"version": (1, 1)}]:
            with self.subTest(option=option):
                with self.assertRaises(ValueError):
                    yaml.dump({"a": 1}, **option)


class ExtensionPoints(unittest.TestCase):
    def test_each_says_it_is_not_there(self):
        calls = [
            lambda: yaml.add_constructor("!env", lambda loader, node: None),
            lambda: yaml.add_constructor("!env", lambda loader, node: None, Loader=yaml.SafeLoader),
            lambda: yaml.SafeLoader.add_constructor("!env", lambda loader, node: None),
            lambda: yaml.add_representer(set, lambda dumper, data: None),
            lambda: yaml.SafeDumper.add_representer(set, lambda dumper, data: None),
            lambda: yaml.add_implicit_resolver("!env", None),
        ]
        for call in calls:
            with self.assertRaises(NotImplementedError) as caught:
                call()
            self.assertIn("pyyaml-zig has no", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
