#!/bin/zsh
# Adapters over GPP against in-process MLXServeEngine (AB-T-0381): a seeded Qwen-Image Flash run with two stacked
# adapters (peter-chan-s-concept-art in the diffusers-peft dialect, and dott4k in kohya's, a NOASSERTION candidate),
# called on the signed bundle the way Gaea calls it (gaea-plugin-check: launch under the launch requirement,
# configure, prepare, run with run.adapters built from the manifest's adapters_meta), and through qwen-inproc with the
# same AdapterRefs on this package's dependency resolution: byte for byte, and pixel for pixel when the bytes differ.
# A no-adapter control proves the adapters changed the image.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh and `swift build -c release --product qwen-inproc`)
#
# The adapters (about 1.2 GB) are fetched into the models root (adapters/<sha256>/) by the first run that names them:
# the GPP run, so the worker's fetch is what's checked.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/qwen-image.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
BIN=$(xcrun swift build -c release --show-bin-path)
CHECK=$BIN/gaea-plugin-check; INPROC=$BIN/qwen-inproc
PIXDIFF=$OUT/pixdiff; swiftc -O -o $PIXDIFF $ROOT/scripts/pixdiff.swift
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }

PROMPT="a lighthouse on a rocky coast at dusk, concept art, painterly, a point-and-click adventure game scene"
A1=qwen-image:peter-chan-s-concept-art; A2=qwen-image:dott4k
say "# Qwen-Image Flash adapter golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"

$CHECK $B --operation image.generate --model qwen-image-flash --lane int8 --params '{"size":{"width":1024,"height":1024},"count":1}' \
  --seed 42 --text "prompt=$PROMPT" --adapter "$A1=0.8" --adapter "$A2=0.6" \
  --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/flash.gpp > $OUT/flash-gpp.log 2>&1
file=$(grep -o '"path":"[^"]*"' $OUT/flash-gpp.log | head -1 | sed 's/"path":"//; s/"$//; s/\\\//\//g')
[[ -n $file && -f $file ]] && cp $file $OUT/flash-gpp.png
$INPROC --model qwen-image-flash --prompt "$PROMPT" --width 1024 --height 1024 --steps 4 --seed 42 --runs 1 \
  --adapter "$A1=0.8" --adapter "$A2=0.6" --models-root "$MODELS" --out $OUT/flash-inproc.png > $OUT/flash-inproc.json 2>> $LOG
$INPROC --model qwen-image-flash --prompt "$PROMPT" --width 1024 --height 1024 --steps 4 --seed 42 --runs 1 \
  --models-root "$MODELS" --out $OUT/flash-control.png > $OUT/flash-control.json 2>> $LOG

if [[ ! -f $OUT/flash-gpp.png ]]; then fail=$((fail+1)); say "FAIL  flash: no output over GPP ($(grep -E 'FAIL|error' $OUT/flash-gpp.log | tail -1))"
elif [[ ! -f $OUT/flash-inproc.png ]]; then fail=$((fail+1)); say "FAIL  flash: no in-process output"
else
  a=$(shasum -a 256 $OUT/flash-gpp.png | cut -c1-16); b=$(shasum -a 256 $OUT/flash-inproc.png | cut -c1-16)
  ran=$(grep -o 'ran in [0-9.]* s' $OUT/flash-gpp.log | head -1)
  if [[ $a == $b ]]; then pass=$((pass+1)); say "PASS  flash (qwen-image-flash int8, $A1 0.8 + $A2 0.6): byte-identical, sha256 $a…; over GPP $ran; in-process $(cat $OUT/flash-inproc.json)"
  elif $PIXDIFF $OUT/flash-gpp.png $OUT/flash-inproc.png >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  flash: pixel-identical (bytes $a… / $b…)"
  else fail=$((fail+1)); say "FAIL  flash: differs ($a… / $b…): $(tail -1 $LOG)"; fi
  c=$(shasum -a 256 $OUT/flash-control.png 2>/dev/null | cut -c1-16)
  if [[ -n $c && $c != $b ]]; then pass=$((pass+1)); say "PASS  control: without the adapters the image differs (sha256 $c…)"
  else fail=$((fail+1)); say "FAIL  control: the no-adapter run is the same image ($c…), so the adapters did nothing"; fi
fi
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
