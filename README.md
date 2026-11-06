# yaml.zig

A YAML 1.2.2 library for Zig, built to pass the whole
[yaml-test-suite](https://github.com/yaml/yaml-test-suite): scanner,
event parser, composer, typed construction and an emitter, each stage
the spec describes.

Early: the scaffold is in place and none of the pipeline is written
yet.

Private, not open-sourced. Work is tracked on the `yaml.zig` karte
board.

## Build

Needs Zig 0.17.1, and zigvet and gnarl on the PATH
(github.com/kmoneil/zigvet, github.com/kmoneil/gnarl; the gnarl
release is the one `complexity.zon` names).

- `zig build test`: tests, zigvet lint, gnarl complexity check.
- `zig build lint`: zigvet alone.
- `zig build complexity`: gnarl alone.
- `zig build fmt`: format.
