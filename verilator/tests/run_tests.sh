#!/bin/sh
# Regression runner: one headless sim per line of tests/regress.tsv, in parallel.
# PASS / FAIL (wrong picture or text) / RUNERR (sim exited non-zero) / SKIP (no ROM).
# In the args column '_' stands for a space.
cd "$(dirname "$0")/.." || exit 1
SIM=./obj_dir/Vsc3000_sim
OUT=tests/out
mkdir -p "$OUT"
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}

grep -v '^#' tests/regress.tsv | grep -v '^$' > "$OUT/list.tsv"

run_one() {
  IFS='	' read -r name cart args frames expect <<LINE
$1
LINE
  if [ "$cart" != "-" ] && [ ! -f "$cart" ]; then echo "SKIP    $name (no $cart)"; return; fi
  set --
  [ "$args" = "-" ] && args=
  for a in $args; do set -- "$@" "$(printf '%s' "$a" | tr '_' ' ')"; done
  for a in "$@"; do case "$a" in ../*) [ -e "$a" ] || { echo "SKIP    $name (no $a)"; return; } ;; esac; done
  if [ "$cart" != "-" ]; then set -- --cart "$cart" "$@"; fi
  sim="$SIM"; case " $args " in *" --turbo "*) sim=./obj_full/Vsc3000_sim ;; esac
  "$sim" --frames "$frames" --png "$OUT/$name.png" --text-end "$@" > "$OUT/$name.log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then echo "RUNERR  $name (exit $rc, $OUT/$name.log)"; return; fi
  case "$expect" in
    crc:*) want=${expect#crc:}
           got=$(grep " shot $OUT/$name.png " "$OUT/$name.log" | awk '{print $NF}')
           if [ "$got" = "$want" ]; then echo "PASS    $name"; else echo "FAIL    $name (crc $got, want $want)"; fi ;;
    text:*) want=${expect#text:}
           if sed -n '/^--- screen/,$p' "$OUT/$name.log" | grep -qF -- "$want"; then echo "PASS    $name"
           else echo "FAIL    $name (\"$want\" not on screen)"; fi ;;
  esac
}
export -f run_one 2>/dev/null
export SIM OUT

tr '\n' '\0' < "$OUT/list.tsv" | xargs -0 -P "$JOBS" -n 1 sh -c "$(typeset -f run_one 2>/dev/null || declare -f run_one); run_one \"\$0\"" | sort -k2 > "$OUT/results.txt"
cat "$OUT/results.txt"
echo "----"
for s in PASS FAIL RUNERR SKIP; do printf '%s %d  ' $s "$(grep -c "^$s" "$OUT/results.txt")"; done; echo
! grep -q '^\(FAIL\|RUNERR\)' "$OUT/results.txt"
