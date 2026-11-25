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
| SF-7000 | 64 KB RAM, IPL ROM, uPD765A floppy controller, 3" drive (160 KB), 8251 RS-232 (MiSTer UART), Centronics printer (to a file) |

## Files

| Where | What |
|---|---|
| `games/SC3000/boot0.rom` | SF-7000 IPL ROM, 8 KB (MAME `sf7000.zip`: `ipl.rom`, CRC32 d76810b8). Only needed for the SF-7000. |
| `games/SC3000/boot1.rom` | Othello Multivision BIOS, 16 KB (MAME `omv2000.zip`: `omvbios.bin`, CRC32 c5a67b95). Only needed for the Othello Multivision. |
| `games/SC3000/` | cartridges (`.sg`, `.sc`, `.bin`, `.rom`), tapes (`.wav`, `.bit`), disks (`.sf7`) |

The SC-3000 and SG-1000 have no ROM of their own: everything starts from a
cartridge. BASIC is a cartridge too (BASIC Level III is the usual one).

## OSD

Top page: **Cartridge**, **Tape**, **Tape save**, **SF-7000 disk**, **SF-7000 printer**, **Load ROM** (the
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

Disk BASIC 1.0p and 1.1p and their demo programs run. `UTILITY` starts the
IPL's utility program: `F` formats a disk (put the new disk in when it asks;
an image of any 160 KB file works), `C` copies one, `B` boots again.

### Printer

The SF-7000's Centronics port prints into a file. Mount a blank file in
**SF-7000 printer** (a file of spaces, e.g. `releases/sf7000_printer_256k.prn`;
the core can't make the file bigger), then in Disk BASIC choose the
Centronics printer with `CONSOLE ,,,,2` (`,,,,1` is the SC-3000's own serial
printer, the default) and use `LPRINT` / `LLIST`. The file gets exactly what
BASIC sends, printer control codes included (it starts with `ESC Q P ESC e`);
it is written out half a second after printing stops. Remounting starts the
file over. With no file mounted the printer is "online" and the output is
dropped, so programs that print never hang.

### RS-232

The 8251 is connected to the MiSTer UART. Pick the connection and the baud
rate (9600, the default, down to 300) in MiSTer's UART menu; the core sets
the SF-7000's baud jumper to match. Main shows the Baud row only for a
connection other than None; the speed picked there (and saved) still applies
with None. With the connection "None", Linux's `/dev/ttyS1` is the other end, e.g. `stty -F /dev/ttyS1 9600 cs8 parenb
-parodd cstopb raw -echo clocal` then `cat /dev/ttyS1` while BASIC does
`COMSAVE`. Disk BASIC: `COMSET 8,E`
(length 5-8, parity N / E / O; 2 stop bits), `COMSAVE` sends the program as
text, `COMLOAD` receives one (it ends on an empty line). Disk BASIC 1.0p has a
bug: `COMSET` doesn't reset the 8251 before writing the new mode, so after a
`COMSET` the 8251 stops sending and `COMSAVE` hangs (MAME does the same). It is
fixed in 1.1p. With 1.0p, don't use `COMSET`: the format after boot is 8
bits, even parity, 2 stop bits (or use 1.1p).

## Not done yet

- SF-7000 RS-232: CTS is ignored (the transmitter never waits for it); 8251 synchronous mode isn't there
- The SK-1100 / SC-3000 printer port
- Tape quick start: the SC-3000 has no ROM that boots a tape; tapes load
  from BASIC's `LOAD` command, so there is no boot path to start a tape
  through (tape-standard.md, "Other machines"). Tape speed 4x is there.

## Development

`verilator/` has a Verilator simulator of the same RTL (`make`, `make full`,
`make test`); see `verilator/README.md`. `PLAN.md` and `TODO.md` track the work.
