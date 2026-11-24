#!/bin/sh
# SF-7000 printer, RS-232 and FORMAT tests (Disk BASIC 1.0p / 1.1p), in parallel.
#   sf7000_lprint     CONSOLE ,,,,2 (Centronics), LPRINT + LLIST -> printer file
#   sf7000_comsave    1.1p: COMSET 7,O then COMSAVE: the program arrives as 7O2
#   sf7000_comload    1.0p: COMLOAD of a 3-line program sent at 8E2, then LIST
#   sf7000_comset10   1.0p: COMSET writes the mode without resetting the 8251
#                     (fixed in 1.1p), so COMSAVE sends 1 byte and hangs, as on an 8251
#   sf7000_format     UTILITY F formats a blank disk; BASIC then SAVEs, LOADs, RUNs on it
#   sf7000_demo11     1.1p: RUN "DEMO #2.BAS" (character set table)
cd "$(dirname "$0")/.." || exit 1
IPL=../software/INCOMING/sf7000/ipl.rom
B10=../software/INCOMING/sf7basic10.sf7
B11="../software/INCOMING/sf7disk/basic/basic11/sega sc-3000 disk basic v1.1p (1984)(mitec).sf7"
for f in "$IPL" "$B10" "$B11"; do [ -f "$f" ] || { echo "SKIP    sf7000_io (no $f)"; exit 0; }; done
O=tests/out
mkdir -p $O
SIM=./obj_dir/Vsc3000_sim

$SIM --sf7000 $IPL --disk $B10 --printer $O/prn.txt --frames 2300 \
  --type 'CONSOLE ,,,,2:CLS\n@1000' --type 'LPRINT "HELLO PRINTER";1+2\n@1300' \
  --type '10 PRINT "LINE TEN"\n@1600' --type '20 GOTO 10\n@1800' --type 'LLIST\n@2000' > $O/lprint.log 2>&1 &
$SIM --sf7000 $IPL --disk "$B11" --frames 1900 --serial-fmt 7O2 \
  --type '10 PRINT "LINE TEN"\n@1000' --type '20 GOTO 10\n@1150' --type 'COMSET 7,O\n@1300' \
  --type 'COMSAVE\n@1450' > $O/comsave.log 2>&1 &
$SIM --sf7000 $IPL --disk $B10 --frames 1900 --type 'COMLOAD\n@1000' \
  --serial-in '10 PRINT "HELLO"\n20 PRINT 6*7\n30 GOTO 10\n\n@1150' --type 'LIST\n@1650' --text-end > $O/comload.log 2>&1 &
$SIM --sf7000 $IPL --disk $B10 --frames 1900 --serial-fmt 7O2 \
  --type '10 PRINT "LINE TEN"\n@1000' --type 'COMSET 7,O\n@1300' --type 'COMSAVE\n@1450' --io-log > $O/comset10.log 2>&1 &
$SIM --sf7000 $IPL --disk $B10 --disk-out $O/fmt.sf7 --frames 4300 \
  --type 'UTILITY\n@1000' --type 'F@1150' --key enter@1200:10 --swap blank@1250 --key space@1300:10 \
  --type 'B@1500' --key enter@1550:10 --swap $B10@1700 --key space@1720:10 --swap $O/fmt.sf7.f1700@2700 \
  --type 'FILES\n@2750' --type '10 PRINT "FORMATTED OK"\n@2900' --type 'SAVE "NEWDISK"\n@3150' \
  --type 'NEW\n@3400' --type 'LOAD "NEWDISK"\n@3500' --type 'RUN\n@3800' --text-end > $O/format.log 2>&1 &
$SIM --sf7000 $IPL --disk "$B11" --frames 2600 --type 'RUN "DEMO #2.BAS"\n@1000' --text-end > $O/demo11.log 2>&1 &
wait

rc=0
check() { if [ "$2" = 0 ]; then echo "PASS    $1"; else echo "FAIL    $1 ($3)"; rc=1; fi; }
screen() { sed -n '/^--- screen/,$p' "$1"; }

printf '\033QP\033e\000\024HELLO PRINTER 3\r\n\r\n10 PRINT "LINE TEN"\r\n20 GOTO 10\r\n' > $O/prn.want
cmp -s $O/prn.txt $O/prn.want; check sf7000_lprint $? "$O/prn.txt differs from $O/prn.want"

grep -qF 'serial out: 35 bytes, 0 errors: 10 PRINT "LINE TEN"\r\n20 GOTO 10\r\n\r\n' $O/comsave.log
check sf7000_comsave $? "$O/comsave.log"

screen $O/comload.log | grep -q "Receive end" && screen $O/comload.log | grep -q '^|  20 PRINT 6\*7' \
  && screen $O/comload.log | grep -q '^|  30 GOTO 10'
check sf7000_comload $? "$O/comload.log"

[ "$(grep -c 'io W E8' $O/comset10.log)" = 1 ] && grep -q 'io W E9 <- DA' $O/comset10.log
check sf7000_comset10 $? "$O/comset10.log"

screen $O/format.log | grep -q '156K Bytes free' && screen $O/format.log | grep -q '^| *FORMATTED OK'
check sf7000_format $? "$O/format.log"

screen $O/demo11.log | grep -q 'CHARACTER SET'
check sf7000_demo11 $? "$O/demo11.log"
exit $rc
