Sega SC-3000 / SG-1000 / SF-7000 / Othello Multivision core for MiSTer
tester build 2026-11-19
========================================================================
PRIVATE TEST BUILD - please do not redistribute (contains Sega ROMs and
commercial software).

First tester build of a new core. It runs SG-1000 and SC-3000 cartridges,
BASIC, cassette tapes (WAV), the SF-7000 disk unit, and the Othello
Multivision. RBF SHA-256: see SHA256.txt.

INSTALL
-------
Copy _Computer/ and games/ to the root of the SD card (/media/fat).
  _Computer/SC3000_20261119.rbf   the core
  _Computer/*.mgl                 ready-made starts (cartridge / tape / disk)
  games/SC3000/boot0.rom          SF-7000 IPL (MAME sf7000.zip ipl.rom)
  games/SC3000/boot1.rom          Othello Multivision BIOS (MAME omvbios.bin)
  games/SC3000/carts, homebrew, tests, tapes, disks

The SC-3000 and SG-1000 have no ROM of their own: everything starts from a
cartridge, BASIC included. With no cartridge the screen stays black.

OSD
---
Top page: Cartridge, Tape, Tape save, SF-7000 disk, Load ROM; then Machine,
Video, Input, Audio. Machine settings (Model, Mapper, SF-7000) wait for
"Apply and reset" ("Changes pending" shows until then).
  Machine: Model SC-3000 / SG-1000 / Othello Multivision; Mapper (Auto is
           right for everything here); SF-7000 Auto/On/Off; Tape speed 4x
           / Normal; Rewind tape; Eject cartridge
  Video:   NTSC / PAL, Border, Aspect ratio, Scale, Scandoubler Fx, Tape overlay
  Input:   Keyboard PC / SC-3000 layout, Joysticks swap
  Audio:   Tape audio

KEYBOARD
--------
PC layout (default): type what is printed on your keyboard; the core
presses the right SC-3000 keys (= is Shift + -, : has its own key...).
Pasting a program works.
  F10 (or a pad's Start) = the SC-3000's RESET key (Z80 NMI; on the
                           SG-1000 it is the PAUSE button)
  Esc = BREAK    Alt = GRAPH    Caps Lock = ENG DIER'S/KANA
  Tab or F1 = FUNC    Home / Backspace = CLR/HOME    Ins / Del = INS/DEL

WHAT TO TRY
-----------
1. Cartridges (Cartridge, or the MGLs): carts/, homebrew/, tests/.
   Joysticks: button 1 / button 2. Joysticks have NOT been tested on real
   hardware yet - this is the most useful thing to check.
2. BASIC Level III: "SC-3000 BASIC Level III" MGL. PRINT, a small program,
   SOUND, graphics (SCREEN 2 ...).
3. Tapes: "SC-3000 Voltron (tape)" etc. At the BASIC prompt type LOAD and
   Return; the tape plays by itself (bar at the bottom: time, x4). When
   "Ready" comes back, type RUN. Voltron loads in about 12 s at 4x.
   Dungeons Beneath Cairo: RUN the first program, it loads the rest.
   Crocky: not checked yet - please tell us what happens.
4. Saving to tape: "SC-3000 Tape save" mounts a blank .bit tape in Tape
   save. Type a program, SAVE "NAME"; then mount the same file as Tape
   and LOAD "NAME". (Keep a copy of blank_tape_15min.bit - saving writes
   into the file.)
5. SF-7000: the "SF-7000 ..." MGLs boot Disk BASIC. FILES, SAVE "x",
   LOAD "x". Writes go back to the .sf7 on the SD card (keep copies).
   Disk BASIC 1.1p boots (18669 bytes free); the Yeno demo has not been
   tried yet.
6. Othello Multivision: Machine > Model = Othello Multivision, Apply and
   reset, with no cartridge (Eject cartridge if needed). Any key starts.
   Keypad = PC keys 1-8 (rows) and A-H (columns); S-1 = button 1,
   S-2 = button 2. S-2 = two players; a move is letter, digit, S-1.
   Put Model back to SC-3000 afterwards.
7. Video: PAL, Border, the aspect ratio and scale modes.
8. Sound: compared with MAME on our MiSTer (tone and noise match);
   reports from real hardware are welcome.

KNOWN LIMITS
------------
- No printer, no SF-7000 RS-232 (stub).
- Terebi Oekaki: the pen is the mouse (left button = pen down); the
  cursor follows, drawing is not confirmed yet.
- Tapes load through BASIC's LOAD (the SC-3000 can't boot a tape), so
  there is no quick start, only 4x speed.
- Multicart/Megacart: a 4x tape load from inside them may not work.

REPORTING
---------
Title, Model / settings, what you saw (photo or screenshot helps), and
whether it matches a real SC-3000 / SG-1000 or an emulator. Joystick,
sound, tape and disk reports are especially useful.
