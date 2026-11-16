# The spec suite

Cases written for YAML 1.2.2 itself, each naming the productions it
exercises and quoting the text that decides it (karte t88). The
yaml-test-suite covers much of the spec, but not all of it, and the YAML
reference parser that generated it reads some inputs otherwise than the
spec's text: here the text decides. `zig build test` runs these;
`zig build spec` runs them alone, and `zig build spec -- coverage` lists
the productions no case exercises yet, the spec's boundaries first (a
lookahead, a "not followed by" note, a condition), each to be crossed
from both sides.

## A case

A file per section and topic, such as `8-block/8.2.2-block-mappings.yaml`,
holds a list of cases in the yaml-test-suite's own source format, with a
`spec` of ours:

```yaml
- name: After an explicit key, a ':' with no blank after it is no indicator
  spec:
    productions: [191, 126]
    quotes:
    - "[191] c-mapping-value # ':' (not followed by non-ws char)"
    - "7.3.3: However, the “:”, “?” and “-” indicators may be used as the first character if followed by a non-space “safe” character, as this causes no ambiguity."
  note: The YAML reference parser reads {a: {b: c}} (karte t87).
  yaml: |
    ? a
    :b: c
  tree: |
    +STR
     +DOC
      +MAP
       =VAL :a
       =VAL :
       =VAL ::b
       =VAL :c
      -MAP
     -DOC
    -STR
```

- `productions`: the numbers of the productions the case exercises, as
  the published spec numbers them (https://yaml.org/spec/1.2.2/). Each
  must be quoted, if only by its name (`"[134] s-ns-plain-next-line"`), so
  a wrong number fails.
- `quotes`: the text that decides the case, word for word: `[N] ...` from
  production N, which `productions` must name, or `S.S.S: ...` from that
  section's prose. The harness holds each to the spec's text and fails a
  case whose quote is not there.
- `yaml`: the input. As in the yaml-test-suite, `—»` (or `»`, with any
  dashes) is a tab, `␣` a space where one would not show, `←` a carriage
  return, `⇔` a byte order mark, `↵` marks a line break on a line that
  is otherwise empty, and `∎` at the end means no final line break.
- `tree`: the events, in the yaml-test-suite's notation, indented as you
  like, `␣` for a trailing space. Or `fail: true` for an input that is no
  YAML; the events before the error are the reader's own, which the spec
  does not decide, and are not held.
- `json`: what the documents compose to, with the core schema, as JSON,
  one value after another as in the yaml-test-suite's `in.json`; a
  mapping's order is not held. For what the events cannot show, such as
  which node an alias refers to. A key that is no string has no JSON.
- `compose_fail: true`: the events read, to `tree`, but compose no
  representation, such as an alias to no anchor before it.
- `encoding`: `utf16le`, `utf16be`, `utf32le` or `utf32be` writes the
  input in that encoding (5.2), which the library must tell and decode.
- A character the block text cannot hold, a control or one past the
  printable set, goes in a double-quoted `yaml` (and `tree`) as its
  escape: `yaml: "a\x7Fb\n"`.
- A plain `name` or `note` must not hold ` #` (the rest would be a
  comment) or `: `: quote it.
- `note`: what else is worth knowing: what the YAML reference parser or
  libfyaml does if it differs, where the spec is silent or ambiguous and
  whose call the reading is.

## The rule

A case's reading comes from the quoted text, not from what any reader
does, this one included. Where yaml.zig reads otherwise, the case stands
and yaml.zig is fixed. Where the spec is silent, ambiguous, or at odds with
itself (a production against its own prose, or an example against its
productions), the case follows the yaml-test-suite, and its `note` says
so: the text that conflicts, quoted or cited, the suite's case that
decides it, and whose call it was.

## The spec's text

`yaml-1.2.2.md` is yaml/yaml-spec's `spec/1.2.2/spec.md` at
1b1a1be43bd6e0cfec45caf0e40af3b5d2bb7f8a, as it is: "This document may be
freely copied, provided it is not modified." The harness numbers its
productions in order and its sections as the published spec does.
