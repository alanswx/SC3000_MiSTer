# SC-3000 Verilator simulator

Headless simulator of the machine in `../rtl/` (the same files the MiSTer build
will use). Design notes: `DESIGN.md`. Needs Verilator 5 and zlib.

```
make                      # obj_dir/Vsc3000_sim (t80sv, the hardware CPU)
make test                 # tests/regress.tsv, one sim per core
./obj_dir/Vsc3000_sim --help
```

Examples:

```
# boot a cartridge, picture at frame 600 (mapper detected automatically)
./obj_dir/Vsc3000_sim --cart ../software/homebrew/smspower_CheMan-SG/_extracted/che_man_ntsc.sg --frames 600 --png out/cheman.png

# BASIC Level III: type a program, run it, print the screen as text
./obj_dir/Vsc3000_sim --cart ../software/INCOMING/basic3/basic3e/basic3e.bin --frames 800 \
    --type '10 FOR I=1 TO 5:PRINT I*I;:NEXT\nRUN\n@400' --text-end

# CPU trace in MAME tracelog format (frames 0-2)
./obj_dir/Vsc3000_sim --cart game.sg --frames 3 --trace out/game.tr:0:2
```

Speed: about 13 frames/s on an M-series Mac (0.22x real time), 10.7 MHz sim clock.

## What is modelled (2026-11-18)

| Block | Source | State |
|---|---|---|
| Z80 | `rtl/t80sv` (ColecoAdam, Rodimus 571b6e9) | as hardware |
| VDP | `rtl/vdp18v` (SVI-328 copy: pal_i, border window, vsync fixes) | NTSC/PAL |
| PSG | `rtl/jt89` (jotego) | noise LFSR is the SMS one, not SN76489AN (TODO) |
| PPI | `rtl/jt8255.v` | keyboard rows 0-6, joysticks row 7, PB7 tape in, PC4 tape out |
| RAM | 2 KB (SG-1000 1 KB) mirrored at C000-FFFF | cart pin B3 override |
| Cart | `rtl/sc3000_cart.sv`: rom, level3, castle, othello | others detected, not built |
| Detect | `rtl/sc3000_detect.sv`: CRC32 table from MAME lists + MAME's string rules | |

Keyboard: `--type` drives the matrix directly (MAME `sk1100.cpp` layout); 6
frames per key, 30 after RETURN. Lower case types as capitals; `\` types the yen key.

## Compared with MAME 0.283

`~/Downloads/mame0283-arm64/mame` runs headless:

```
mame sc3000 -cart FILE -video none -sound none -nothrottle -seconds_to_run 11 \
     -autoboot_script snap.lua      # snapshot at given frames (scratchpad copy)
```

BASIC Level III at frame 400 matches (banner, "26620 Bytes free", Ready).
MAME's instruction trace does not run headless (`-debugger none` turns
tracing off; `gdbstub` waits for a client), so trace diffs need a MAME run
with the macOS debugger window.

## Tape and SF-7000

```
# BASIC Level III, LOAD from a WAV (the deck plays while the program polls PB7)
./obj_dir/Vsc3000_sim --cart BASIC3.sg --tape game.wav --tape-log --type 'LOAD\n@400' --frames 3300 --text-end

# SF-7000: IPL ROM + Disk BASIC disk; --disk-out writes the image back
./obj_dir/Vsc3000_sim --sf7000 ipl.rom --disk basic.sf7 --type 'FILES\n@1000' --frames 1300 --text-end
```

SF-7000 printer, RS-232 and disk swaps:

```
# Centronics printer into a blank file (CONSOLE ,,,,2 picks it in Disk BASIC)
./obj_dir/Vsc3000_sim --sf7000 ipl.rom --disk basic.sf7 --printer prn.txt --frames 1600 \
  --type 'CONSOLE ,,,,2:CLS\n@1000' --type 'LPRINT "HI"\n@1300'

# RS-232: --serial-in sends to the 8251, what it sends is printed at the end
# (--serial-out FILE too); --serial-fmt is the far end's format, --baud the jumper (0 = 9600)
./obj_dir/Vsc3000_sim --sf7000 ipl.rom --disk basic.sf7 --frames 1900 --type 'COMLOAD\n@1000' \
  --serial-in '10 PRINT "HELLO"\n\n@1150' --type 'LIST\n@1650' --text-end

# --swap FILE@F changes the disk at frame F ('blank' = empty 160 KB, '-' = eject);
# tests/sf7000_io.sh formats a disk with the IPL utility this way
```

Othello Multivision: `--omv omvbios.bin` (BIOS, no cartridge), `--pad KEYS@FRAME[:N]`
presses keypad keys (1-9, 0, A-H):

```
# title, S2 = two players, then D 3 S1 plays D3
./obj_dir/Vsc3000_sim --omv omvbios.bin --pad 1@320:5 --joy b@500:5 --pad D@700:5 --pad 3@760:5 --joy a@820:5 --frames 1000 --png omv.png
```

`make fdclog` builds `obj_log/` with every FDC command and result printed.

## Known gaps

- The first instruction after reset (0000) is missing from `--trace`.
- No GUI build yet (ImGui: copy ColecoAdam `verilator/sim/`).
- No tv80 build.
