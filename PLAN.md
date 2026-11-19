# PLAN: SC3000_MiSTer (Sega SC-3000 / SC-3000H, SG-1000 compatible, SF-7000)

Started 2026-11-18. Same conventions as the other cores in `~/dev2`:
`sys/` is an unmodified Template_MiSTer copy (`../sys-standard.md`), OSD per
`../osd-standard.md`, video per `../video-standard.md`, tape per
`../tape-standard.md`. `refs/` and `software/` stay local (`.git/info/exclude`).
Never run downloaded code; don't commit/push unless asked; Quartus builds go to
misterubuntu, not this Mac.

Items marked **(verify)** come from memory and must be checked against the
schematics / MAME before RTL depends on them.

## 1. The machine

| Part | SC-3000 | Notes |
|---|---|---|
| CPU | Z80A, 3.579545 MHz (NTSC) | PAL: ~3.58 MHz from a separate ceramic resonator (service manual p5) |
| VDP | TMS9918A (NTSC) / TMS9929A (PAL), 16 KB VRAM | ports BE (data) / BF (ctrl) |
| PSG | SN76489AN | port 7F (write only) |
| PPI | 8255 | ports DC-DF: keyboard matrix rows/cols, joysticks, cassette in/out, printer |
| RAM | 2 KB at C000-FFFF, mirrored every 2 KB; cart pin B3 disables it | SG-1000 Mk I: 1 KB. BASIC carts add RAM |
| ROM | none in the console: everything is on cartridge | SG-1000 carts run as-is |
| Reset key | Z80 NMI via MITEC-2, not in the key matrix (confirmed) | SG-1000 Pause also NMI |
| Cassette | 1200 baud, 1200/2400 Hz; out = PPI PC4, in = PB7 | `.wav` / MAME `.bit` / `.sc`; format in `refs/docs/cassette/` |
| I/O decode | PSG A7=0, VDP A6=0 (A0 data/ctrl), PPI A5=0 (A1:0 reg); overlapping selects | confirmed from schematic; must model overlaps like MAME |

SG-1000 differs: no 8255 in the console (joysticks read directly at DC/DD);
the PPI, cassette and printer port live in the SK-1100 keyboard.
SF-7000: PPI PC6 maps the 8 KB IPL at 0000-3FFF (writes always go to RAM);
ports E0/E1 FDC, E4-E7 PPI, E8/E9 USART (exact decode unconfirmed).

Expansions / variants:
- **SC-3000H**: same electronics, hard keyboard.
- **SG-1000 + SK-1100** keyboard: same matrix, so the core covers SG-1000 too.
- **SF-7000**: IPL ROM, 64 KB RAM, uPD765 FDC (3" 160 KB disks), 8255 (FDC
  control + Centronics), 8251 USART. Disk BASIC and CP/M-like OS on disk.
- **Cartridge mappers**: plain 8/16/32/48 KB; BASIC Level II/IIIA/IIIB (RAM in
  cart); The Castle / Othello (+8 KB RAM); Terebi Oekaki (graphic board);
  Taiwanese/Korean multicarts; MSX-style "4 x 8 KB" Korean ports **(verify list
  against MAME bus/sega8 slot types)**.

## 2. Reuse (don't rewrite what we already have)

| Need | Source | Status |
|---|---|---|
| Z80 | `t80sv` (`../t80sv_fixes_20261117`, `../ColecoAdam_MiSTer/rtl/t80sv`) or fixed tv80 (`../SVI328_MiSTer/verilator/rtl_sv/tv80`) | Hardware keeps T80; sim may use either |
| TMS9918A/29A | `../ColecoAdam_MiSTer/rtl/vdp18v` (SV), border-window fix from SVI328 | PAL port from SVI328 |
| SN76489 | `../ColecoAdam_MiSTer/rtl/sn76489` | |
| 8255 | `../SVI328_MiSTer/rtl/jt8255.v` | |
| Tape player, turbo, overlay | `../SVI328_MiSTer/rtl/cassette.v`, `tape_overlay.sv` | new 1200 baud encoder |
| SDRAM | `sdram.sv` from SVI328 | carts up to 1 MB; BRAM for small ones |
| uPD765 | MiSTer `u765` (Amstrad/Spectrum cores) | SF-7000 phase |
| Verilator harness | `../SVI328_MiSTer/verilator`, `../ColecoAdam_MiSTer/verilator` | see section 4 |
| sys/ | Template_MiSTer latest | `refs/framework/` |

The inventory of exact files is in `refs/REUSE.md` (written by the
framework agent).

## 3. Phases

0. **Kit** (this session): refs, emulator sources, MAME driver + hash lists,
   test software, user's ROM list -> `refs/INDEX.md`, `software/INDEX.md`.
1. **Sim-first SG-1000 mode**: `rtl/sc3000.sv` (CPU, VDP, PSG, PPI, 2 KB RAM,
   cart in BRAM), Verilator harness boots a homebrew SG-1000 cart. Golden
   compare: MAME `-debug` traces / frame dumps at fixed frames.
2. **Keyboard + BASIC**: SC-3000 matrix from PS/2 (layout from MAME
   `sk1100` + manual), BASIC Level III boots to `Ready`, typed program runs.
3. **Cartridge mappers** per MAME `bus/sega8`; detection by size/hash list,
   OSD override.
4. **Cassette** per tape-standard: load `.wav`/`.bit`, 1200 baud, turbo,
   status bar, save to SD.
5. **MiSTer top** `SC3000.sv`: hps_io, CONF_STR per osd-standard, video
   per video-standard (TMS9918 aspect values reused from SVI328), joysticks,
   PAL/NTSC, model (SC-3000 / SG-1000). Quartus build on misterubuntu.
6. **SF-7000**: IPL ROM, 64 KB RAM paging, u765 + `.sf7` disk images,
   Centronics/RS-232 stubs. Disk BASIC boots in sim.
7. Hardware test on a MiSTer (only with the user's go-ahead), release notes.

## 4. Verilator simulation (required from phase 1)

Directory `verilator/`, modelled on SVI328's:
- `sc3000_sim.sv` wraps the machine core without `sys/` (clocks as CE
  strobes, cart/tape/disk loaded via ioctl-style ports like hps_io).
- `sim_main.cpp`: SDL2 + Dear ImGui window (reuse ColecoAdam/SVI328 code),
  headless mode with `--frames N --png out.png`, `--cart`, `--tape`,
  `--disk`, `--keys "string"` (auto-type), `--trace` (Z80 PC trace in MAME
  `trace` format for diff), `--vcd from:to`.
- `Makefile`: `make` (T80 or tv80 netlist), `make run`, `make test`.
- `tests/`: regression list (ROM, frame, expected PNG hash) run by
  `make test`; CPU tests (ZEXDOC/ZEXALL) reused from SVI328 cpu_tests.
- Compare tool: run same input in MAME and the sim, diff PC traces and
  frame PNGs.

## 4b. Findings from the reference sweep (2026-11-18)

- MAME machines: `sg1000`, `sg1000m2`, `sc3000`, `sc3000pal`, `omv1000`,
  `omv2000`. No `sc3000h`. The SF-7000 is a sega8 cart device
  (`sc3000 -cart sf7000`, `refs/mame/src/devices/bus/sega8/sf7000.cpp`);
  `ipl.rom` CRC d76810b8 is in `software/INCOMING/sf7000/` and matches.
- SMS_MiSTer already has an SC-3000 mode (SMS VDP, no tape, no SF-7000):
  reuse its SK-1100 keyboard (`rtl/keyboard.sv`) and multicart logic, but
  keep this a separate core with a real TMS9918.
- GearSF7000-devel (AGPL-3) is the best software reference for SF-7000 + tape.
- Open points: I/O decode (MAME A7/A6/A5 separate selects vs A7:A6 split);
  tape out = PPI PC4 (MAME, GearSF7000); M1 wait state unknown; no tape
  motor line (turbo trigger needs a new rule); `u765` must be fetched.

## 5. Decisions (user, 2026-11-18)

- **Default model: SC-3000, NTSC.** The SC-3000 runs every SG-1000 cartridge
  plus the keyboard/BASIC/tape/disk software, so it covers the most software;
  Japanese NTSC machines were the most common. SG-1000 mode and PAL stay as
  OSD options.
- **SF-7000 disk support is in the first release.** Phase 6 is required
  before 1.0. It can still be built after phases 1-5, but the release waits
  for it. Proposed: the SF-7000 is an OSD option, off by
  default, because its IPL ROM pages over the cart slot. Revisit this if the
  IPL falls through to the cartridge when no disk is present; then it could
  default on.

## 6. Local tools and software already on this Mac (found 2026-11-18)

- **Common Source Code Project eSC-3000** (Takeda): source
  `~/dev2/common_source_code/src/vm/sc3000/` (sc3000.cpp, memory.cpp,
  keyboard.cpp; shares `vm/tms9918a`, `sn76489an`, `i8255`, `upd765a`,
  `datarec`), built app `~/dev2/common_source_code/build/sc3000.app`
  (CLI notes: `common_source_code/CLI.md`). It does SC-3000 + SF-7000 + tape,
  so it is a second golden reference beside MAME. Note: it wires keyboard PPI
  **PC3 = tape REMOTE (motor)**, PC4 = MIC; check against the service manual
  schematic. If PC3 really is a remote line, that gives the tape-turbo trigger.
- **MAME 0.283** binary: `~/Downloads/mame0283-arm64/mame` (not on PATH).
- **Software lists (MAME 0.289, merged)**:
  `~/Downloads/MAME 0.289 Software List ROMs (merged)/{sc3000_cart,sg1000,sc3000_cass,sf7000}/`
  (20 / 96 / 31 / 23 sets). Merged, so clones live in the parent zip:
  `basic3.zip` holds basic3e + basic3v10, `sf7000/basic.zip` holds basicf +
  basic11. `sf7000.zip` (IPL) in `~/Downloads`.
- Usage: read zips in place or unpack into `software/INCOMING/<set>/`; never
  copy them into the repo.
