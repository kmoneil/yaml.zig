---
name: yaml
description: Check YAML files for errors with the line and column of each, read one value out of a YAML file by path, and convert YAML to JSON and back, with the `yaml` command (yaml.zig). Use before committing or deploying YAML, when a YAML file will not load and you need where and why, to read a config value without writing a script, and to turn YAML into JSON for jq or a test.
---

# yaml: check, read and convert YAML

`yaml` reads YAML 1.2.2 with the yaml.zig library, which reads the
whole yaml-test-suite as the spec says. It is fast (a 5 MB file checked
in a tenth of a second), so run it on every file you write or change.
`yaml --help` gives every option.

## Check files

Run it on the files you changed, or on all of a project's YAML. Silence
and exit 0 mean every document of every file is YAML:

```console
$ yaml check good.yaml stream.yaml
```

Each file that is not says where, from 1, and what is wrong, then the
line and a caret under the column:

```console
$ yaml check good.yaml dup.yaml tab.yaml
dup.yaml:2:1: a mapping cannot have two equal keys
a: 2
^
tab.yaml:2:2: a tab character cannot indent a block
	b: 1
	^
```

Read the message, fix the line, and check again until it is silent. A
file stops at its first error: fix that one and run again to see the
next. The errors seen most:

- `a mapping cannot have two equal keys`: a key is written twice in one
  mapping, often after a merge or a copy. Remove one, or merge them.
  Values equal under the schema are one key: `1` and `0x1`.
- `a tab character cannot indent a block`: YAML indents with spaces
  only. Replace the tabs.
- `could not find the ':' this key needs`: a line at a mapping's column
  that is not a `key: value`, often a value that lost its indentation.
- `a flow sequence's entries need a ',' between them, and a ']' after`,
  or the same for `{`: a `[` or `{` not closed, or two entries with no
  comma.
- `a mapping value is not allowed here`: a second `: ` on one line, as
  in `a: b: c`. Quote the value: `a: "b: c"`.

For a tool or a CI step, `--format json` writes the findings as a JSON
array, `[]` when there are none:

```console
$ yaml check --format json dup.yaml
[
{"file":"dup.yaml","line":2,"column":1,"message":"a mapping cannot have two equal keys"}
]
```

A file named `-` is read from standard input. UTF-16 and UTF-32 files
are read too.

## Read a value

`yaml get PATH FILE` prints the value at a path: `.` for the whole
document, then steps in any order, `.key`, `.["a key"]` for a key that
is not a plain word, `[n]` for a sequence's item from 0. Quote the path
for the shell. A value is printed as YAML, or as JSON with `--json`:

```console
$ yaml get '.servers[1].name' good.yaml
b
$ yaml get '.servers[1]' good.yaml
name: b
port: 443
$ yaml get --json .flags good.yaml
{"debug":true,"ratio":0.5}
$ yaml get '.["a key"][0]' good.yaml
1
```

Aliases are followed: a value read through `*name` is the anchored one.
A path with nothing at it says at which step, and exits 1:

```console
$ yaml get '.servers[5]' good.yaml
yaml: good.yaml: no value at `.servers[5]`: nothing at step 2 of it
```

A file of more than one document (`---` between them) needs
`--document N`, from 0:

```console
$ yaml get . stream.yaml
yaml: stream.yaml: the stream holds 3 documents: choose one with --document <n>, from 0
$ yaml get --document 1 '[0]' stream.yaml
x
```

## Convert

`yaml json FILE` prints each document as JSON, one a line, ready for
`jq`; `--indent 2` indents it. A key that is not a string becomes its
text, and a value JSON cannot hold (`.nan`, a key that is a collection,
an alias that makes a cycle) is an error:

```console
$ yaml json stream.yaml
{"a":1}
["x","y"]
null
```

`yaml from-json FILE` prints a JSON file as YAML, quoting a string only
where a reader would read it as something else, a YAML 1.1 reader too:

```console
$ yaml from-json data.json
name: x
'on': 'yes'
'n':
- 1
- 2.5
- null
- true
```

## YAML 1.2, not 1.1

`yaml` reads YAML 1.2: only `true` and `false` are booleans, and `yes`,
`no`, `on`, `off`, `y`, `n` are strings. Tools that read YAML 1.1
(PyYAML, older libraries) read those as booleans, `1:20` as 80, `1_000`
as 1000 and `2001-12-14` as a date. `yaml` writes them quoted, as above,
so either reads a string; in a file you write by hand, quote them too
when such a tool may read it.

## Exit status

0 when every file is YAML and the command did what it was asked; 1 when
a file is not YAML or JSON, a path has no value, or a value cannot be
written as JSON; 2 on a usage error or a file that could not be read.
What went wrong is on standard error, but for `check`'s findings, which
are its output.

## How a file reads

`yaml events FILE` prints the events a file parses to, in the
yaml-test-suite's notation, one a line: `+MAP` and `-MAP` around a
mapping, `=VAL :text` for a plain scalar, `&anchor`, `*alias`. Use it
to see how a confusing file is read:

```console
$ yaml events alias.yaml
+STR
+DOC
+MAP
=VAL :base
+MAP {} &b
=VAL :k
=VAL :v
-MAP
=VAL :use
=ALI *b
-MAP
-DOC
-STR
```
