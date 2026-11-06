#!/bin/sh
# tools/compare/run.sh [RUNS]: yaml.zig against other YAML libraries on
# one document, the bench's 20,000 config records (4.9 MB) (karte t54).
#
# Builds each library at a pinned version, apart from the repository (in
# $YAML_COMPARE_DIR, by default $TMPDIR/yaml-compare): libyaml 0.2.5 and
# rapidyaml 0.16.0 fetched and checked by their SHA-256, go-yaml v3, the
# Rust crates and js-yaml as their lock files say. A library whose
# toolchain is missing (cc, c++, go, cargo, node) is left out, and said.
#
# Each harness reads the file once, runs its stage once to warm up and
# then RUNS times (11 by default), and prints the median in ms. Memory is
# the peak resident size of one run less that of a run that only reads
# the file. Times move by up to 10% from run to run on a busy machine.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${YAML_COMPARE_DIR:-${TMPDIR:-/tmp}/yaml-compare}
runs=${1:-11}
mkdir -p "$work/dl" "$work/bin"
doc="$work/doc.yaml"

have() { command -v "$1" >/dev/null 2>&1; }
note() { echo "compare: $*" >&2; }

# fetch URL FILE SHA256: the file, downloaded once, its checksum checked.
fetch() {
  [ -f "$2" ] || curl -fsSL -o "$2" "$1"
  sum=$( (shasum -a 256 "$2" 2>/dev/null || sha256sum "$2") | cut -d' ' -f1)
  if [ "$sum" != "$3" ]; then note "$2: SHA-256 $sum, not $3"; exit 1; fi
}

# The document, and yaml.zig built ReleaseFast as a consumer ships it.
(cd "$root" && zig build bench -- write "$doc")
(cd "$work" && zig build-exe -O ReleaseFast --dep yaml -Mroot="$root/tools/bench.zig" -Myaml="$root/src/root.zig" -femit-bin="$work/bin/yaml-zig")

if have cc; then
  fetch https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz "$work/dl/libyaml.tar.gz" c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
  l="$work/dl/libyaml"
  mkdir -p "$l" && tar -xzf "$work/dl/libyaml.tar.gz" -C "$l" --strip-components 1
  cc -O2 -w -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2 -DYAML_VERSION_PATCH=5 '-DYAML_VERSION_STRING="0.2.5"' \
    -I"$l/include" -I"$l/src" "$here/libyaml.c" "$l/src/api.c" "$l/src/loader.c" "$l/src/parser.c" "$l/src/reader.c" "$l/src/scanner.c" \
    -o "$work/bin/libyaml"
else note "no cc: libyaml left out"; fi

if have c++; then
  mkdir -p "$work/dl/ryml"
  fetch https://github.com/biojppm/rapidyaml/releases/download/v0.16.0/rapidyaml.v0.16.0.singlehdr.hpp "$work/dl/ryml/ryml.hpp" 0d0b8076174cf62f034406b03529fda542ebc9a17506d3bd6d949aedc4bfa6ab
  c++ -O3 -std=c++17 -DNDEBUG -w -I"$work/dl/ryml" "$here/ryml.cpp" -o "$work/bin/ryml"
else note "no c++: rapidyaml left out"; fi

if have go; then
  (cd "$here/go" && go build -o "$work/bin/go-yaml" .)
else note "no go: go-yaml left out"; fi

if have cargo; then
  cargo build -q --release --locked --manifest-path "$here/rust/Cargo.toml" --target-dir "$work/rust"
  cp "$work/rust/release/yaml-compare" "$work/bin/rust"
else note "no cargo: saphyr, serde_yaml and serde-saphyr left out"; fi

if have node && have npm; then
  mkdir -p "$work/node"
  cp "$here/node/package.json" "$here/node/package-lock.json" "$here/node/bench.mjs" "$work/node/"
  (cd "$work/node" && npm ci --silent)
else note "no node: js-yaml left out"; fi

# The peak resident bytes of `$@` reading the file, as the system's time
# reports them (bytes on macOS, KiB on Linux).
peak() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident set size/ {print $1}'
  else
    /usr/bin/time -v "$@" 2>&1 >/dev/null | awk -F: '/Maximum resident set size/ {print $2 * 1024}'
  fi
}

size=$(wc -c < "$doc" | tr -d ' ')
# row STAGE LIBRARY MODE COMMAND...: the harness run as `COMMAND MODE
# RUNS FILE`, a table row of its median, throughput and memory.
row() {
  stage=$1 library=$2 mode=$3
  shift 3
  ms=$("$@" "$mode" "$runs" "$doc")
  base=$(peak "$@" read 1 "$doc")
  top=$(peak "$@" "$mode" 1 "$doc")
  awk -v s="$stage" -v l="$library" -v ms="$ms" -v n="$size" -v p="$top" -v b="$base" \
    'BEGIN { printf "| %s | %s | %.1f | %.0f | %.1f |\n", s, l, ms, n / ms / 1e3, (p - b) / 1048576 }'
}

b=$work/bin
z="$b/yaml-zig file"
echo "$size bytes, the median of $runs runs; $(uname -sm), $(date -u +%Y-%m-%d)"
echo
echo "| Built | Library | ms | MB/s | Peak MB |"
echo "| --- | --- | ---: | ---: | ---: |"
row events "**yaml.zig**" parse $z
[ ! -x "$b/libyaml" ] || row events "libyaml 0.2.5" events "$b/libyaml"
[ ! -x "$b/rust" ] || row events "saphyr-parser 0.3.3" events "$b/rust"
row "node tree" "**yaml.zig**" compose $z
[ ! -x "$b/ryml" ] || row "node tree" "rapidyaml 0.16.0" tree "$b/ryml"
[ ! -x "$b/libyaml" ] || row "node tree" "libyaml 0.2.5" load "$b/libyaml"
[ ! -x "$b/go-yaml" ] || row "node tree" "go-yaml v3.0.1 (yaml.Node)" node "$b/go-yaml"
row "dynamic value" "**yaml.zig** (Value)" value $z
[ ! -x "$b/rust" ] || row "dynamic value" "saphyr 0.3.3" value "$b/rust"
[ ! -f "$work/node/bench.mjs" ] || row "dynamic value" "js-yaml 5.5.0" load node "$work/node/bench.mjs"
[ ! -x "$b/go-yaml" ] || row "dynamic value" "go-yaml v3.0.1 (any)" any "$b/go-yaml"
row typed "**yaml.zig**" typed $z
[ ! -x "$b/rust" ] || row typed "serde_yaml 0.9.34" typed "$b/rust"
[ ! -x "$b/rust" ] || row typed "serde-saphyr 2.1.1" typed-saphyr "$b/rust"
[ ! -x "$b/go-yaml" ] || row typed "go-yaml v3.0.1" typed "$b/go-yaml"
