#!/bin/sh
# Build a private tester package: tools/make_tester.sh RBF DATE
# -> ../SC3000_tester_DATE/ and ../SC3000_tester_DATE.zip (contains Sega ROMs: private, not for release)
set -e
cd "$(dirname "$0")/.."
RBF=$1; DATE=$2
OUT=../SC3000_tester_$DATE
SW=software
rm -rf "$OUT"; mkdir -p "$OUT/_Computer" "$OUT/games/SC3000/carts" "$OUT/games/SC3000/homebrew" "$OUT/games/SC3000/tests" "$OUT/games/SC3000/tapes" "$OUT/games/SC3000/disks"
G=$OUT/games/SC3000
cp "$RBF" "$OUT/_Computer/SC3000_$DATE.rbf"
cp $SW/INCOMING/sf7000/ipl.rom $G/boot0.rom
cp $SW/INCOMING/omv/omvbios.bin $G/boot1.rom
c() { cp "$1" "$G/$2"; }
c "$SW/INCOMING/basic3/basic3e/basic3e.bin"          "carts/BASIC Level III (export).sc"
c "$SW/INCOMING/basic3/basic sk iii (japan).sg"      "carts/BASIC Level III (Japan).sc"
c "$SW/INCOMING/basic2/basic2.bin"                   "carts/BASIC Level II.sc"
c "$SW/INCOMING/castle/mpr-10159.ic1"                "carts/The Castle.sg"
c "$SW/INCOMING/othello/othello (japan).bin"         "carts/Othello.sg"
c "$SW/INCOMING/terebioe/terebi oekaki (japan).bin"  "carts/Terebi Oekaki.sg"
c "$SW/INCOMING/music/music.bin"                     "carts/Music Editor.sc"
c "$SW/INCOMING/congo/congo bongo [v1].bin"          "carts/Congo Bongo.sg"
c "$SW/INCOMING/flicky/flicky [v1].bin"              "carts/Flicky.sg"
c "$SW/INCOMING/homemj/home mahjong (japan) (v1.1).bin" "carts/Home Mahjong.sg"
c "$SW/INCOMING/bordrlin/borderline (japan, europe).bin" "carts/Borderline.sg"
c "$SW/INCOMING/champtns/mpr-5439.ic1"               "carts/Champion Tennis.sg"
c "$SW/INCOMING/bombmnsp/bomberman special (tw).bin" "carts/Bomberman Special (TW).sg"
c "$SW/INCOMING/yingchua/legend of kage, the [dahjee] (tw).bin" "carts/Yingzi Chuanshuo (Dahjee, TW).sg"
c "$SW/INCOMING/multcart/SC3000SurvivorsMkIIMulticart_v2_31.bin" "carts/SC-3000 Survivors Multicart v2.31.sc"
c "$SW/INCOMING/megacart/SC3000SurvivorsMegacart_v2_31.bin"     "carts/SC-3000 Survivors Megacart v2.31.sc"
c "$SW/INCOMING/m2cp/sg-1000 m2 check program.bin"  "tests/SG-1000 M2 Check Program.sg"
for f in $(find $SW/homebrew -path '*_extracted/*' -maxdepth 3 \( -name '*.sg' -o -name '*.sc' \) | grep -v -i '_pal\.s' | tr ' ' '?'); do
  f=$(echo "$f" | tr '?' ' '); cp "$f" "$G/homebrew/"; done
for f in $SW/tests/*/_extracted/*.sg; do case "$f" in *PAL*) ;; *) cp "$f" "$G/tests/";; esac; done
c "$SW/INCOMING/cass/voltron/Voltron.wav"                     "tapes/Voltron.wav"
c "$SW/INCOMING/cass/crocky/Crocky.wav"                       "tapes/Crocky.wav"
c "$SW/INCOMING/cass/dungeons/DungeonsBeneathCairo.wav"       "tapes/Dungeons Beneath Cairo.wav"
c "$SW/INCOMING/cass/keyboard/Keyboard_Learning_Program.wav"  "tapes/Keyboard Learning Program.wav"
c "$SW/homebrew/smspower_Palikat-SC/_extracted/PALIKAT-NTSC.wav" "tapes/Palikat (homebrew).wav"
c "releases/blank_tape_15min.bit"                             "tapes/blank_tape_15min.bit"
c "$SW/INCOMING/sf7disk/basic/sega disk basic v1.0p (sf-7000).sf7" "disks/Disk BASIC 1.0p.sf7"
c "$SW/INCOMING/sf7disk/basic/basic11/sega sc-3000 disk basic v1.1p (1984)(mitec).sf7" "disks/Disk BASIC 1.1p.sf7"
c "$SW/INCOMING/sf7disk/basic/basicf/sega disk basic v1.0p with yeno demo (sf-7000).sf7" "disks/Disk BASIC 1.0p with Yeno demo.sf7"
# MGLs: paths are relative to games/SC3000
mgl() { name=$1; shift; { printf '<mistergamedescription>\n<rbf>_Computer/SC3000</rbf>\n'; for x in "$@"; do printf '%s\n' "$x"; done; printf '</mistergamedescription>\n'; } > "$OUT/_Computer/$name.mgl"; }
cart() { echo "<file delay=\"2\" type=\"f\" index=\"1\" path=\"carts/$1\"/>"; }
mgl "SC-3000 BASIC Level III"            "$(cart 'BASIC Level III (export).sc')"
mgl "SC-3000 Voltron (tape)"             "$(cart 'BASIC Level III (export).sc')" '<file delay="2" type="f" index="2" path="tapes/Voltron.wav"/>'
mgl "SC-3000 Dungeons Beneath Cairo (tape)" "$(cart 'BASIC Level III (export).sc')" '<file delay="2" type="f" index="2" path="tapes/Dungeons Beneath Cairo.wav"/>'
mgl "SC-3000 Crocky (tape)"              "$(cart 'BASIC Level III (export).sc')" '<file delay="2" type="f" index="2" path="tapes/Crocky.wav"/>'
mgl "SC-3000 Tape save"                  "$(cart 'BASIC Level III (export).sc')" '<file delay="2" type="s" index="1" path="tapes/blank_tape_15min.bit"/>'
mgl "SF-7000 Disk BASIC 1.0p"            '<file delay="2" type="s" index="0" path="disks/Disk BASIC 1.0p.sf7"/>'
mgl "SF-7000 Disk BASIC 1.1p"            '<file delay="2" type="s" index="0" path="disks/Disk BASIC 1.1p.sf7"/>'
mgl "SF-7000 Yeno demo"                  '<file delay="2" type="s" index="0" path="disks/Disk BASIC 1.0p with Yeno demo.sf7"/>'
mgl "SG-1000 Flicky"                     "$(cart 'Flicky.sg')"
mgl "SG-1000 The Castle"                 "$(cart 'The Castle.sg')"
mgl "SG-1000 Congo Bongo"                "$(cart 'Congo Bongo.sg')"
mgl "SG-1000 Terebi Oekaki"              "$(cart 'Terebi Oekaki.sg')"
mgl "SC-3000 Survivors Megacart"         "$(cart 'SC-3000 Survivors Megacart v2.31.sc')"
cp tools/tester_README.txt "$OUT/README.txt"
( cd "$OUT" && shasum -a 256 _Computer/SC3000_$DATE.rbf ) > "$OUT/SHA256.txt"
find "$OUT" -name .DS_Store -delete
rm -f "$OUT.zip"; ( cd .. && zip -qr "SC3000_tester_$DATE.zip" "SC3000_tester_$DATE" )
ls -la "$OUT.zip"
