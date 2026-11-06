# Security catalog

Every known attack on a YAML library, and where yaml.zig stands on it:
a test that proves the defence (covered), a card that will add it (gap
when the surface exists today, later when the evidence is still to
come), or the reason it does not apply (n/a). `zig build test` checks
this file against the code (tools/security_catalog.zig): a covered row
whose test is gone fails the build, and so does a test in test/security
that no row names. After ekur's catalog (ekur t65); this one is karte
t44.

Sources: the CWE entries that reach a parser and a serializer, OWASP's
Deserialization Cheat Sheet, and the advisory history of YAML libraries
by class: libyaml, libfyaml, PyYAML, SnakeYAML, go-yaml, js-yaml, the
npm `yaml` package, yaml-rust and serde_yaml, Ruby on Rails, and
Kubernetes. Each id was checked against NVD, GitHub's advisory database
or RustSec on 2026-11-06.

Test cells read `path: test name`, several joined by ` ; `. The tests
under test/security use the public API only, as an attacker reaches it,
and run with `zig build test` and, in ReleaseSafe and ReleaseFast, `zig
build test-release`; a row may cite a test in src/ where the defence is
internal. Status is `covered`, `gap tNN`, `later tNN` or `n/a: why`.

Found and fixed in the run that made this catalog (t44): an unknown
field's name, an enum's and a tag's text went into a diagnostic's detail
raw, so a key holding an escape sequence or a line break reached the
terminal or log reading it as it was (now escaped, OUT-04); the scanner
read on after an error from the state the error left (now it gives the
error again, API-01); and nothing bounded an input's length against the
isize the scanner compares columns in (now refused, NUM-02). Fixed
earlier the same day, by the code review and the first fuzz campaign
(t28 to t43): a float into a wide integer was undefined behaviour, %TAG
lookup was quadratic, the composer called after an error reached
`unreachable`, the default depth overflowed a 512 KiB stack in Debug,
and a NUL byte in a block scalar looped forever.

## Expansion and exhaustion

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| RES-01 | Alias expansion ("billion laughs"): a few aliases name a node built many times over | CWE-776, CWE-400; CVE-2019-11253 (Kubernetes), CVE-2017-18640 (SnakeYAML), CVE-2021-4235 and CVE-2022-3064 (go-yaml v2) | Construction counts each node built through an alias against ParseOptions.max_alias_nodes (1,000,000); the composer's graph holds each node once | test/security/resources_test.zig: security: CWE-776 alias expansion (billion laughs) ; src/construct_test.zig: limits: a cycle, an alias bomb, depth | covered |
| RES-02 | A self-referencing alias, followed forever | CWE-674, CWE-835; RUSTSEC-2018-0005 (serde_yaml) | An alias to a collection being built is error.Cycle: the graph may hold the cycle, construction refuses it | test/security/resources_test.zig: security: CWE-674 an alias inside the node it names is a cycle, not followed | covered |
| RES-03 | Merge-key fan-out: one alias merged many times over | CWE-407; CVE-2026-53550 (js-yaml) | No `<<` merges, which are YAML 1.1's: `<<` is a key like any other | test/security/types_test.zig: security: CWE-1321 merge keys and __proto__ are keys like any other | covered |
| RES-04 | Memory a document makes the library hold, out of proportion to its length | CWE-770 | Linear in the input, which the caller holds whole: the scanner's tokens and text, the composer's nodes (each document's, until deinit), construction's values; only aliases multiply, and RES-01 bounds them | - | n/a: nothing but aliases (RES-01) multiplies memory; a caller bounds the input it reads |
| RES-05 | A large block scalar grows the stack | CWE-121, CWE-770; CVE-2026-88359 (libfyaml) | A scalar's text is built in the scanner's arena, on the heap | test/security/resources_test.zig: security: CWE-121 a block scalar of megabytes is built on the heap | covered |

## Recursion

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| REC-01 | Nesting deep enough to overflow the stack | CWE-674; CVE-2022-25857, CVE-2022-38749, CVE-2022-38750, CVE-2022-38751, CVE-2022-38752 and CVE-2022-41854 (SnakeYAML); RUSTSEC-2018-0006 (yaml-rust); CVE-2026-33532 (npm yaml) | The scanner, parser, composer and emitter loop over stacks of their own; the scanner refuses past max_depth collections open; construction counts its depth, through aliases too, against ParseOptions.max_depth (256) | test/security/resources_test.zig: security: CWE-674 nesting too deep for a stack is refused ; src/Composer_test.zig: a deep document composes without recursion ; src/Scanner_test.zig: depth: flow and block collections count toward max_depth | covered |
| REC-02 | The defaults' deepest document overflows a thread's stack | CWE-674 | max_depth is 256 so construction and stringify, which recurse, fit 512 KiB in a Debug build (t34) | test/security/resources_test.zig: security: CWE-674 the deepest document the defaults take is read and written on a 512 KiB stack ; src/construct_test.zig: limits: the deepest documents the defaults take build on a 512 KiB stack | covered |
| REC-03 | Comparing or hashing deep or cyclic keys | CWE-674, CWE-407 | Key equality and hashing give up after node_budget (256) nodes | src/Composer_test.zig: a cyclic key costs no more than the budget | covered |

## Algorithmic complexity

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| CPX-01 | Keys and anchor names built to collide in a hash map (hash flooding) | CWE-407; kb/t7 | Every map keyed by input text is seeded from a hash of the input: the composer's anchors and key sets, and an ArrayHashMap construction builds | src/Composer.zig: keys and anchors built to collide under a fixed seed spread under the composer's ; test/security/resources_test.zig: security: CWE-407 keys built to collide under a fixed seed spread in an ArrayHashMap | covered |
| CPX-02 | Many %TAG directives, each tag resolved by a scan of them | CWE-407 | ParseOptions.max_tag_directives, 64 a document (t29) | test/security/resources_test.zig: security: CWE-407 %TAG directives past max_tag_directives are refused ; src/Parser_test.zig: a document may have max_tag_directives %TAG directives, and no more | covered |
| CPX-03 | A large mapping's check for duplicate keys | CWE-407 | Past 8 keys, a seeded hash set | src/Composer_test.zig: duplicate keys in a mapping big enough to use the key set, and keeping them | covered |
| CPX-04 | Implicit keys held open across a long line | CWE-400, CWE-407 | An implicit key is one line and at most 1024 characters (YAML 1.2.2, 7.4.2) | src/Scanner_test.zig: an implicit key is one line and at most 1024 characters | covered |
| CPX-05 | Crafted input that burns CPU (found by fuzzing in others) | CWE-407; CVE-2019-11254 (Kubernetes, fixed by go-yaml v2.2.8) | Fuzz targets seeded in zig build test; longer runs with `zig build fuzz --fuzz` | src/fuzz_test.zig: fuzz: parse: any input, events that nest, no leak | later t26 |

## Hangs

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| HANG-01 | Input that makes the scanner loop forever | CWE-835 | Each loop moves or refuses; found so far: a NUL byte in a block scalar (t43, by fuzzing), a flow mapping open at the input's end (t20) | test/security/resources_test.zig: security: CWE-835 inputs that once looped forever end ; src/Scanner_test.zig: a flow mapping left open ends at the input's end (found by fuzzing) ; src/Scanner_test.zig: block scalar errors (suite 2G84, 5LLU, S98Z, W9L4, Y79Y/000) | covered |
| HANG-02 | Hangs, crashes and leaks not found yet | CWE-835, CWE-400, CWE-401 | Four fuzz targets, seeded in zig build test in all three modes; longer runs with `zig build fuzz --fuzz` | src/fuzz_test.zig: fuzz: parse: any input, events that nest, no leak ; src/fuzz_test.zig: fuzz: construct: a Value built is stringified and read back the same ; src/fuzz_test.zig: fuzz: typed: a struct of every kind of field built, stringified and read back the same ; src/fuzz_test.zig: fuzz: emit: what parses, emitted, reads back the same | later t26 |

## Deserialization and types

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| DES-01 | A tag picks the type built: code execution through a loader's constructors | CWE-502; OWASP Deserialization Cheat Sheet; CVE-2017-18342, CVE-2019-20477, CVE-2020-1747 and CVE-2020-14343 (PyYAML); CVE-2022-1471 (SnakeYAML); CVE-2013-4660 and GHSA-8j8c-7jfh-h6hx (js-yaml); CVE-2013-0156 (Rails) | No tag names a type: a Value holds data, typed construction builds the caller's type, and a yamlParse hook is the caller's own code | test/security/types_test.zig: security: CWE-502 a tag never chooses what is built | covered |
| DES-02 | Prototype pollution through `__proto__` or a merge key | CWE-1321; CVE-2025-64718 (js-yaml) | No prototypes and no merges: both are keys | test/security/types_test.zig: security: CWE-1321 merge keys and __proto__ are keys like any other | covered |
| DES-03 | YAML 1.1's types: yes/no/on/off (the Norway problem), octal 0777, sexagesimal 1:20 | CWE-704 | The YAML 1.2.2 core schema, where they are strings and decimal | test/security/types_test.zig: security: CWE-704 YAML 1.1's booleans, octals and sexagesimals do not change type | covered |
| DES-04 | A scalar tagged as what its text is not (`!!int foo`) | CWE-704, CWE-20 | Refused wherever it is built (t33) | src/construct_test.zig: a scalar whose text is not what its tag says is refused, wherever it is built | covered |
| DES-05 | Duplicate keys: one parser reads the first, another the last | CWE-694 | Keys equal by value are refused unless duplicate_keys is .keep, which takes the last | test/security/types_test.zig: security: CWE-694 duplicate keys, equal by value, are refused | covered |
| DES-06 | Keys a type has no field for, accepted and dropped | CWE-915 | error.UnknownField unless ignore_unknown_fields | test/security/types_test.zig: security: CWE-915 a key no field has is refused, not dropped | covered |

## Numbers

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| NUM-01 | A number past its type: wrapped, saturated, or undefined behaviour in an unchecked build | CWE-190, CWE-681 | Every conversion is bounded and refused past the type with error.Overflow (t28, t35, t40) | test/security/types_test.zig: security: CWE-190 numbers past their type are refused, in every optimize mode ; src/construct_test.zig: a float into an integer: up to the type's edge, and not past it ; src/construct_test.zig: an integer into a u128, past an i128 too ; src/construct_test.zig: an integer wider than 128 bits, from integer text and from a float | covered |
| NUM-02 | An input longer than a signed size: column and indentation compares overflow on a 32-bit target | CWE-190 | The scanner refuses an input longer than maxInt(isize) | test/security/api_test.zig: security: CWE-190 an input longer than a signed size holds is refused | covered |

## Encoding

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| ENC-01 | Invalid UTF-8: overlong forms, surrogates, past U+10FFFF, cut short | CWE-176, CWE-20 | Refused whole before scanning (encoding.toUtf8) | test/security/encoding_test.zig: security: CWE-176 invalid UTF-8 is refused, not repaired ; src/encoding_test.zig: invalid input in each encoding, with the offset | covered |
| ENC-02 | UTF-16 and UTF-32 that are not text | CWE-176 | Decoded strictly: surrogates paired, code points in range, whole code units | test/security/encoding_test.zig: security: CWE-176 UTF-16 and UTF-32 that are not text are refused | covered |
| ENC-03 | Control characters, NUL, C1 controls, and a byte order mark inside a document | CWE-20 | Only YAML's characters (5.1); a byte order mark only where a document begins | test/security/encoding_test.zig: security: CWE-20 control characters and a byte order mark inside a document are refused ; src/encoding_test.zig: byte order marks: at the stream's start and each document's, nowhere else | covered |
| ENC-04 | Line endings read two ways (CR, CRLF) | CWE-436 | CRLF and CR read as LF everywhere | src/Scanner_test.zig: line breaks: CRLF and CR read as LF | covered |

## Memory safety

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| MEM-01 | A tag's % escapes overflow a buffer | CWE-119, CWE-787; CVE-2013-6393 (libyaml, an incorrect cast), CVE-2014-2525 (libyaml) | Each % needs two hex digits; decoding writes no more bytes than it read; the decoded bytes must be UTF-8 | src/Scanner_test.zig: tag errors (suite U99R, LHL4) ; src/Scanner_test.zig: tags: each form, escapes decoded | covered |
| MEM-02 | An assertion or `unreachable` on input: an abort, or undefined behaviour unchecked | CWE-617; CVE-2014-9130 (libyaml), CVE-2022-28948 (go-yaml v3) | No assertion on input; the tests and fuzz targets run in Debug, ReleaseSafe and ReleaseFast (zig build test-release, t36) | src/fuzz_test.zig: fuzz: typed: a struct of every kind of field built, stringified and read back the same ; src/Composer_test.zig: after an error, each next gives it again | covered |

## Output

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| OUT-01 | Text written as YAML that reads back as structure (injection) | CWE-74, CWE-116 | stringify quotes or escapes text that would read as anything else | test/security/output_test.zig: security: CWE-74 text stringify writes reads back as the same text, not structure ; src/stringify_test.zig: round trip: strings that read as other things when plain ; src/Emitter_test.zig: every awkward text, in every style, in a block, a flow and a key, reads back | covered |
| OUT-02 | Anchors, aliases, tags and %TAG directives that cannot be written as given | CWE-116 | emit refuses them (t32), and escapes a %TAG prefix again (t31) | src/Emitter_test.zig: errors: anchors, aliases, tags and %TAG directives YAML cannot write ; src/Emitter_test.zig: a %TAG prefix is escaped again, and may be long | covered |
| OUT-03 | A type's yamlStringify writing other than one value | CWE-670 | A panic in every optimize mode (Stringification.write) | - | n/a: a hook is the caller's code and its misuse a panic in every mode; a panic cannot be tested in-process |
| OUT-04 | Input in a diagnostic writes into a terminal or forges a log line | CWE-117, CWE-150 | Text from the input in a detail or a path is escaped: controls, line breaks of any kind, bytes that are not UTF-8 | test/security/output_test.zig: security: CWE-117 input in a diagnostic cannot write to a terminal or forge a log line | covered |
| OUT-05 | A secret value quoted in an error | CWE-209, CWE-532 | Diagnostic.detail may quote up to 40 bytes of a value, and its doc says so; message and path quote no value | - | n/a: the detail names what was found so a person can fix the file; a caller reading secrets logs message and path |
| OUT-06 | A detail cut inside a character | CWE-176 | Cut where a character begins | src/construct_test.zig: diagnostics: a detail too long for its buffer is cut where a character begins | covered |

## The API

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| API-01 | A stage called again after an error reads on from the state the error left | CWE-372 | The scanner, parser and composer give their first error again | test/security/api_test.zig: security: CWE-372 each stage gives its first error again after it | covered |
| API-02 | Memory leaked on an error path, running out of memory included | CWE-401 | Every allocation freed on every path; std.testing.allocator in every test, and every allocation failing in turn | src/construct_test.zig: every allocation may fail, and nothing leaks when one does ; src/stringify_test.zig: every allocation may fail, and nothing leaks when one does | covered |
| API-03 | parseFromSliceLeaky given an allocator that is not an arena | CWE-401 | Its doc says to pass an arena, as std.json's does | - | n/a: a contract of the caller's, documented |

## Supply chain

| ID | Attack | Source | Defense | Test | Status |
|---|---|---|---|---|---|
| SUP-01 | A dependency fetched by a consumer's build | CWE-1357 | One dependency, the yaml-test-suite's data: lazy, pinned by hash, fetched by this repository's own build only | - | n/a: a consumer fetches nothing but this package |
