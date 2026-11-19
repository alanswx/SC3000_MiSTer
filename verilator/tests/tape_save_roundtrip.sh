#!/bin/sh
# Tape save round trip: BASIC III SAVEs a program into a blank .bit (Tape save
# recorder), then a second run LOADs that file and runs the program.
cd "$(dirname "$0")/.." || exit 1
CART=../software/INCOMING/basic3/basic3e/basic3e.bin
[ -f "$CART" ] || { echo "SKIP    tape_save_roundtrip (no $CART)"; exit 0; }
mkdir -p tests/out
./obj_dir/Vsc3000_sim --cart "$CART" --rec tests/out/saved.bit --frames 2800 \
  --type '10 PRINT "SAVED TO TAPE"\n@400' --type 'SAVE "TAPETEST"\n@700' > tests/out/save.log 2>&1 || { echo "RUNERR  tape_save_roundtrip (save)"; exit 1; }
./obj_dir/Vsc3000_sim --cart "$CART" --tape tests/out/saved.bit --frames 2400 \
  --type 'LOAD\n@400' --type 'RUN\n@1900' --text-end > tests/out/load.log 2>&1 || { echo "RUNERR  tape_save_roundtrip (load)"; exit 1; }
if sed -n '/^--- screen/,$p' tests/out/load.log | grep -q "^| *SAVED TO TAPE"; then echo "PASS    tape_save_roundtrip"
else echo "FAIL    tape_save_roundtrip (see tests/out/load.log)"; exit 1; fi
