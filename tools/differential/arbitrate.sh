#!/bin/sh
# arbitrate.sh DIR: settles each disagreement between yaml.zig and
# libfyaml recorded in DIR (SEED.yaml, SEED.ours, SEED.theirs, as
# `YAML_DIFFERENTIAL_DIR=DIR zig build differential -Ddifferential --fuzz`
# or `differential-suite dump N DIR` writes them) by the YAML reference
# parser, generated from the spec's productions, whose events the
# yaml-test-suite's are: whichever reader it agrees with read the spec.
#
# It needs node, `timeout`, and the reference parser:
#   git clone https://github.com/yaml/yaml-reference-parser
#   git -C yaml-reference-parser checkout d58347b997eea4d7e5ba33b36871535dad6db081
#   npm install --prefix DEPS --no-save --ignore-scripts ingy-prelude@0.0.4
#   export NODE_PATH=DEPS/node_modules
#   export YAML_REFERENCE_PARSER=yaml-reference-parser/parser-1.2/javascript/bin/yaml-parser
# At that commit it reads all 402 suite inputs as the suite says.
#
# One line a case, `SEED VERDICT | yaml.zig's word | libfyaml's word`,
# the reference's events left in SEED.ref. VERDICT is one of
#   libfyaml          it is the one wrong: it read what the spec refuses,
#                     refused what the spec reads, or read it otherwise;
#   yaml.zig          the same of ours: a bug;
#   neither:read-OT   the reference read it; O and T say whether yaml.zig
#                     and libfyaml read it (1) or refused it (0), and any
#                     that read it read it otherwise;
#   neither:both-read the reference refused what both read, differently;
#   refused:O/T       all three refuse it, so the readers agree with the
#                     spec, and differ only in the events before their
#                     errors, which the spec leaves to them. O and T say
#                     how each reader's stand to what the reference
#                     committed: same, prefix or off. Not a verdict;
#   slow              the reference took more than 20 s.
set -u
dir=${1:?usage: arbitrate.sh DIR}
ref=${YAML_REFERENCE_PARSER:?set YAML_REFERENCE_PARSER to the path of the reference parser bin/yaml-parser}
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT

# against A B: same, prefix (one's lines begin the other's) or off.
against() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    while ((getline x < a) > 0) l[++n] = x
    while ((getline y < b) > 0) r[++m] = y
    k = n < m ? n : m
    for (i = 1; i <= k; i++) if (l[i] != r[i]) { print "off"; exit }
    print (n == m) ? "same" : "prefix"
  }'
}

for y in "$dir"/*.yaml; do
  s=${y%.yaml}; seed=$(basename "$s")
  timeout 20 node "$ref" --events < "$y" > "$s.ref" 2>/dev/null; rs=$?
  head -1 "$s.ours" > "$work/ow"; tail -n +2 "$s.ours" > "$work/oe"
  head -1 "$s.theirs" > "$work/tw"; tail -n +2 "$s.theirs" > "$work/te"
  ours_read=0; grep -q '^read$' "$work/ow" && ours_read=1
  theirs_read=0; grep -q '^read$' "$work/tw" && theirs_read=1
  if [ $rs -eq 124 ]; then v=slow
  elif [ $rs -eq 0 ]; then
    if [ $ours_read = 1 ] && cmp -s "$work/oe" "$s.ref"; then v=libfyaml
    elif [ $theirs_read = 1 ] && cmp -s "$work/te" "$s.ref"; then v=yaml.zig
    else v=neither:read-$ours_read$theirs_read; fi
  elif [ $ours_read = 0 ] && [ $theirs_read = 1 ]; then v=libfyaml
  elif [ $ours_read = 1 ] && [ $theirs_read = 0 ]; then v=yaml.zig
  elif [ $ours_read = 1 ]; then v=neither:both-read
  else
    # All three refuse it. The reference, a backtracking parser, prints
    # only what it committed, then closes what was open: its closing
    # events are dropped, and each reader's events before its error are
    # told against what is left.
    awk '{l[NR]=$0}END{n=NR;while(n>0&&l[n]~/^-(MAP|SEQ|DOC|STR)$/)n--;for(i=1;i<=n;i++)print l[i]}' "$s.ref" > "$work/rp"
    v=refused:$(against "$work/rp" "$work/oe")/$(against "$work/rp" "$work/te")
  fi
  echo "$seed $v | $(cat "$work/ow") | $(cat "$work/tw")"
done
