---
title: The yaml command
nav_order: 4
---

# The yaml command

`yaml` checks YAML files, lints them, reads a value out of one, and
converts between YAML and JSON. It is fast (a 5 MB file checked in a
tenth of a second), so run it on every file you write or change.

```sh
brew install kmoneil/tap/yaml
```

Each [release](https://github.com/kmoneil/yaml.zig/releases) also has
the binary for Linux, macOS and Windows on x86_64 and arm64, and
`zig build -Doptimize=ReleaseSafe` builds it from source into
`zig-out/bin/yaml`. `yaml --help` lists every option.

## Check files

Silence and exit 0 mean every document of every file is YAML. Each file
that is not says where, from 1, and what is wrong, then the line and a
caret under the column:

```console
$ yaml check good.yaml dup.yaml tab.yaml
dup.yaml:2:1: a mapping cannot have two equal keys
a: 2
^
tab.yaml:2:2: a tab character cannot indent a block
	b: 1
	^
```

A file stops at its first error: fix it and run again to see the next.
For a tool or a CI step, `--format json` writes the findings as a JSON
array, `[]` when there are none:

```console
$ yaml check --format json dup.yaml
[
{"file":"dup.yaml","line":2,"column":1,"message":"a mapping cannot have two equal keys"}
]
```

## Lint files

`yaml lint` checks as `check` does, then warns of YAML that is valid but
reads one way here and another in YAML 1.1 tools such as PyYAML, or is
likely a mistake. Each warning says how to fix it:

```console
$ yaml lint lint.yaml
lint.yaml:1:10: warning: `yes` is a string in YAML 1.2 but a boolean in YAML 1.1 (PyYAML): quote it, 'yes', if it is a string
enabled: yes
         ^
lint.yaml:2:7: warning: `0755` is 755 in YAML 1.2 but 493 in YAML 1.1 (PyYAML), which reads a leading 0 as octal: write 755 or 493, as meant
mode: 0755
      ^
lint.yaml:4:8: warning: the anchor &s is never used: no alias names it
spare: &s {z: 2}
       ^
lint.yaml:7:1: warning: the key `name` differs from `Name`, on line 6, only in case, which some readers ignore: rename one
name: b
^
```

| Rule | Warns of |
|---|---|
| `yaml11` | a plain value YAML 1.1 reads otherwise: `yes`, `on`, `y`, `0755`, `1:20`, `1e3`, `2001-12-14` |
| `tab` | a tab in a line's indentation |
| `trailing-space` | blanks at the end of a line |
| `line-length` | a line longer than `--max-line <n>` |
| `unused-anchor` | an anchor no alias names |
| `key-case` | keys of one mapping that differ only in case or trailing blanks |

`--allow trailing-space,line-length` turns rules off; `--fail-on yaml11`
exits 1 for that rule's warnings only. With `--format json` each finding
has a `"severity"`, and each warning its `"rule"`. A GitHub Actions
workflow's `on:` key is a `yaml11` warning, rightly, as PyYAML reads it
as `true`; GitHub reads a string, so quote it or lint workflows with
`--allow yaml11`.

## Read a value

`yaml get` prints the value at a path, as YAML, or as JSON with `--json`.
A path is `.` for the whole document, or steps: `.key`, `.["a key"]`,
`[n]` for a sequence's item.

```console
$ yaml get '.servers[0].name' config.yaml
web
$ yaml get --json .flags config.yaml
{"debug":true,"ratio":0.5}
```

In a file of several documents, `--document <n>` (from 0) picks one.

## Convert

`yaml json` prints each document as JSON, one a line, or indented with
`--indent <n>`; `yaml from-json` prints JSON as YAML, quoting any string
a YAML reader would take for something else.

```console
$ yaml json --merge-keys compose.yaml | jq .services
```

`yaml events` prints the events a file reads to, in the yaml-test-suite's
notation, to see exactly how it parses.

## Options

| Option | What it does |
|---|---|
| `--schema core\|yaml11\|json\|failsafe` | How a plain value with no tag is typed. `core` (YAML 1.2) by default; `yaml11` types it as PyYAML does |
| `--merge-keys` | `get` and `json`: apply `<<: *base`, as most readers do |
| `--duplicate-keys keep` | Keep a mapping's second equal key instead of refusing it |
| `--max-depth <n>` | The most collections open at once (256) |

A file named `-` is standard input. UTF-16 and UTF-32 files are read
too.

## Exit status

0 when every file is YAML and the command did what it was asked; 1 when
a file is not YAML or JSON, `lint` warns, a path has no value, or a
value cannot be written as JSON; 2 on a usage error or a file that could
not be read.

## For AI agents

`yaml skill` prints a guide for coding agents: each command with an
example, the errors seen most and how to fix them. Every example in it
is tested. `yaml skill --install DIR` writes `DIR/yaml/SKILL.md`, which
tells the agent to run `yaml skill`, so it is never out of date.
