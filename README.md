# Sega SC-3000 / SG-1000 for MiSTer

The Sega SC-3000 home computer (1983), with its SF-7000 disk unit, the
SG-1000 console it is compatible with, and Tsukuda Original's Othello
Multivision (an SG-1000 clone with Othello built in). It runs SG-1000 and
SC-3000 cartridges, BASIC Level II / III, cassette software (WAV) and
SF-7000 disks.

## Hardware emulated

| Part | |
|---|---|
| CPU | Z80A, 3.58 MHz (t80sv) |
| Video | TMS9918A (NTSC) / TMS9929A (PAL), 16 KB VRAM |
| Sound | SN76489AN (jt89, with the SN76489AN noise generator) |
| I/O | 8255 PPI: keyboard, joysticks, cassette, printer port |
| RAM | 2 KB (SG-1000: 1 KB), plus what the cartridge brings |
| SF-7000 | 64 KB RAM, IPL ROM, uPD765A floppy controller, 3" drive (160 KB) |

## Files

| Where | What |
|---|---|
| `games/SC3000/boot0.rom` | SF-7000 IPL ROM, 8 KB (MAME `sf7000.zip`: `ipl.rom`, CRC32 d76810b8). Only needed for the SF-7000. |
| `games/SC3000/boot1.rom` | Othello Multivision BIOS, 16 KB (MAME `omv2000.zip`: `omvbios.bin`, CRC32 c5a67b95). Only needed for the Othello Multivision. |
| `games/SC3000/` | cartridges (`.sg`, `.sc`, `.bin`, `.rom`), tapes (`.wav`, `.bit`), disks (`.sf7`) |

The SC-3000 and SG-1000 have no ROM of their own: everything starts from a
cartridge. BASIC is a cartridge too (BASIC Level III is the usual one).

## OSD

Top page: **Cartridge**, **Tape**, **Tape save**, **SF-7000 disk**, **Load ROM** (the
ROM of the model chosen: the SF-7000 IPL, or the Othello Multivision BIOS), then the Machine, Video, Input and Audio pages. Settings that change
the machine wait for **Apply and reset** ("Changes pending" shows until then);
video, input and audio settings act at once.

| Page | Row | |
|---|---|---|
| Machine | Model | SC-3000 (default), SG-1000 or Othello Multivision |
| | Mapper | Auto (default) or a fixed cartridge type |
| | SF-7000 | Auto: attached when a disk is mounted (default) / On / Off |
| | Tape speed | 4x (default) or Normal |
| | Rewind tape, Eject cartridge | buttons |
| Video | Video standard | NTSC (default) / PAL |
| | Border, Aspect ratio, Scale, Scandoubler Fx | |
| | Tape overlay | the tape status bar, On / Off |
| Input | Keyboard | PC (default) / SC-3000 |
| | Joysticks swap | |
| Audio | Tape audio | hear the tape while it plays |

## Keyboard

**PC** layout (default): keys type what is printed on a PC keyboard. The
SC-3000 puts many symbols elsewhere (`=` is Shift + `-`, `:` has its own key,
`@` too); the core presses the right SC-3000 keys for you. Shift + letter
gives a capital, as on a PC. **SC-3000** layout: keys by position, as the
real machine (a plain letter is a capital, Shift gives lower case).

| SC-3000 key | PC key |
|---|---|
| RESET (NMI; SG-1000 PAUSE) | F10, or a joypad's Start |
| BREAK | Esc |
| GRAPH | Alt |
| ENG DIER'S / KANA | Caps Lock |
| FUNC | Tab or F1 |
| CLR/HOME | Home or Backspace |
| INS/DEL | Insert / Delete |
| ¥ | `\` |

Typed text is queued and fed to the machine at a pace BASIC can follow, so
pasting a program works.

## Cartridges

The mapper is picked automatically: known dumps by CRC32 (MAME's software
lists), others by the same signature checks MAME uses. Supported: plain ROM
(up to 48 KB), BASIC Level II / III, The Castle, Othello, Terebi Oekaki
(the tablet is the mouse; left button = pen), Dahjee type A / B (Taiwanese
RAM carts), Music Editor, and the SC-3000 Survivors Multicart (2 MB) and
Megacart (4 MB).

## Tape

Mount a `.wav` (8 or 16-bit, any rate) or MAME `.bit` file, then type
`LOAD` (BASIC) and press Return. The SC-3000 has no motor control, so the
core plays the tape while the program reads the cassette input, and pauses
when it stops. With Tape speed 4x the machine and the tape both run 4x
while the tape plays (a 47 s tape loads in about 12 s); the status bar shows
the time, the length and the progress.

### Saving to tape

Mount a `.bit` file in **Tape save** (a blank tape is a file of spaces:
`releases/blank_tape_15min.bit`, 1 MB, 15 minutes) and type `SAVE "name"`.
The core records what BASIC writes into the file, in MAME's `.bit` format;
mount the same file as **Tape** to load it back. The core can't make a file
bigger, so the blank tape sets the length.

## Othello Multivision

Model = Othello Multivision (FG-2000): with no cartridge in, the machine
starts the Othello game in its BIOS (`boot1.rom`); with one, it runs the
cartridge (SG-1000 cartridges and the OMV's own). The keypad is on the PC
keyboard: `1`-`8` and `A`-`H` (rows and columns of the board), `9`/`#`
and `0`/`*`. The joystick is the controller; S-1 is Button 1, S-2 Button 2.
In Othello, S-1 plays the computer (AUTO), S-2 a person (MANUAL), and a
move is a letter, a digit, then S-1.

## SF-7000

Put the IPL in `games/SC3000/boot0.rom` and mount a `.sf7` disk: with
SF-7000 = Auto the machine restarts with the disk unit attached and boots
the disk (Disk BASIC: `FILES`, `LOAD "name"`, `SAVE "name"`). Writes go back
to the image on the SD card.

## Not done yet

- SF-7000 RS-232 and printer ports (the USART is a stub)
- The SK-1100 / SC-3000 printer port
- Tape quick start: the SC-3000 has no ROM that boots a tape; tapes load
  from BASIC's `LOAD` command, so there is no boot path to start a tape
  through (tape-standard.md, "Other machines"). Tape speed 4x is there.

## Development

`verilator/` has a Verilator simulator of the same RTL (`make`, `make full`,
`make test`); see `verilator/README.md`. `PLAN.md` and `TODO.md` track the work.
