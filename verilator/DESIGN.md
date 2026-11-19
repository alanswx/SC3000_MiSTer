# SC-3000 Verilator simulator: design

Written 2026-11-18. Design only; no sim code exists yet. Modelled on
`/Users/alans/dev2/SVI328_MiSTer/verilator/` (headless CLI, PNG, `dl_*` preload,
fast/full clocking, tv80 build) and `/Users/alans/dev2/ColecoAdam_MiSTer/verilator/`
(SDL2 + Dear ImGui GUI, `--record/--replay`, `.vdp` dumps, compare tools). Source
files to copy are inventoried in `../refs/REUSE.md`.

## 1. Goals (PLAN.md section 4, phase 1 first)

1. Boot an SG-1000 cartridge headless and write PNGs at given frames.
2. Same binary opens an ImGui window when `--headless` is not given.
3. Z80 instruction trace diffable against MAME's debugger `trace` output.
4. `make test` regression: ROM + frame -> expected PNG hash, plus CPU tests.
5. Later phases plug in without restructuring: keyboard (2), mappers (3), tape (4),
   SF-7000 disk (6).

## 2. Toolchain (checked 2026-11-18)

| Need | Status |
|---|---|
| Verilator | 5.044 `/opt/homebrew/bin/verilator` - OK |
| SDL2 | 2.32.x, `sdl2-config` -> `/opt/homebrew` - OK |
| Dear ImGui | not installed system-wide; **bundled** in `/Users/alans/dev2/ColecoAdam_MiSTer/verilator/sim/imgui/` (1.87 WIP, 4.8 MB incl. ImGuiFileDialog, implot, memory editor). Copy into `verilator/sim/imgui/`. A test compile of imgui + `imgui_impl_sdl` + `imgui_impl_opengl2` + SDL2 + OpenGL framework linked and ran (Apple clang 21; warnings only) |
| zlib / libpng | zlib 1.2.12 (SDK), libpng 1.6.58 (homebrew). SVI's PNG writer needs only zlib - use that, no libpng dependency |
| python3 + Pillow | 3.x, PIL 13.0 - OK for compare scripts |
| GHDL, gtkwave | present (`/opt/homebrew/bin`) |
| **MAME** | **not installed** (`mame` not on PATH, no /Applications bundle). Needed for golden traces / frames. Do not `brew install`; ask the user (`brew install mame` or their own build) or have them produce the trace files |
| Z80 assembler | none (no sjasmplus/pasmo/z80asm/sdcc); `z80dasm` present. Test ROMs must be prebuilt, or ask for an assembler |

Sibling Makefile assumptions: ColecoAdam's adds `-L/usr/local/lib -L/opt/local/lib
-I/usr/local/include -I/opt/local/include` (harmless, non-existent here) and relies on
`sdl2-config`; imgui path is relative (`../sim/imgui` from `obj_dir`). SVI's needs only
Verilator + zlib. Both use `--no-timing` (tv80 `<= #1`). Don't `--threads` (slower).

## 3. Directory layout

```
verilator/
  DESIGN.md                this file
  README.md                usage (written with the code)
  Makefile                 make / make tv80 / make full / make gui-less / make run / make test / make clean
  sim.vlt                  public_flat_rd for VDP regs, VRAM, RAM; lint_off as SVI
  sc3000_sim.sv            sim top (section 4)
  sim_main.cpp             CLI, main loop, headless + GUI
  sim_trace.cpp/.h         --trace (MAME-format PC/register trace)
  sim_png.cpp/.h           zlib PNG writer (from SVI sim_main.cpp write_png)
  sim_keys.cpp/.h          --keys text -> SC-3000 matrix scheduler (phase 2)
  sim_tape.cpp/.h          .wav/.bit -> 1-bit level stream (phase 1/2, before the RTL player)
  sim/                     copy of ColecoAdam verilator/sim/ (video, audio, input, console, imgui/)
  rtl_sv/tv80/             only for make tv80 (fixed tv80, TV80_REFRESH in-file)
  tests/
    regress.tsv            one line per case (section 8)
    run_tests.sh           make test driver
    golden/                expected PNGs (small, committed) + .sha256
    roms/ -> ../../software/tests   symlink; ROMs never committed
    mame/                  scripts for producing golden traces/frames with MAME
  compare/
    mame_trace.cmd         debugger script template
    tracediff.py           align + diff sim vs MAME traces
    framediff.py           PNG diff by TMS9918 colour index (port of ColEm cmpframes idea)
  cpu_tests -> /Users/alans/dev2/SVI328_MiSTer/verilator/cpu_tests (referenced, not copied: 2.1 GB vectors)
```

Machine RTL lives in `../rtl/` and is shared with the hardware build (one source,
unlike SVI where sim and hardware differ): `rtl/sc3000.sv` (machine), `rtl/vdp18v/`,
`rtl/t80sv/`, `rtl/sn76489/`, `rtl/jt8255.v`, `rtl/cv_clock.sv`, `rtl/cv_por.sv`,
later `rtl/sc3000_cart.sv` (mappers), `rtl/sc3000_tape.sv`, `rtl/sf7000.sv`.

## 4. `sc3000_sim.sv` - sim top

Wraps `rtl/sc3000.sv` the way `SC3000.sv` (the `emu` top) will, minus `hps_io`,
`sys/`, `video_mixer`, SDRAM. Two clockings, as SVI:

- **fast (default, `FULL=0`)**: sim clock = 10.738635 MHz rate, `ce_10m7 = 1`, Z80/PSG
  CEN_p/CEN_n from `cv_clock` (/3). ColecoAdam verified this frame-identical.
- **full (`make full`, `FULL=1`)**: sim clock = clk_sys 42.954545 MHz with the top's
  enables (needed for turbo and SDRAM-latency checks).

```systemverilog
module sc3000_sim #(parameter FULL = 0, parameter CART_AW = 20, parameter TAPE_AW = 22) (
  input         clk,
  input         reset,          // = emu reset: RESET | status[0] | download in progress

  // ioctl-style preload, held in reset while dl_busy (as hps_io)
  input         dl_busy,
  input         dl_wr,
  input  [7:0]  dl_index,       // CONF_STR index: 1 cart (F1), 2 tape (F2), 3 SF-7000 IPL (later)
  input  [24:0] dl_addr,
  input  [7:0]  dl_data,
  input  [24:0] dl_size,        // latched at end of download: cart size -> mapper autodetect
  input  [4:0]  cart_type,      // OSD mapper override, 0 = auto (phase 3)

  // OSD settings (same meaning as status bits in SC3000.sv)
  input         model_sg1000,   // 1 SG-1000 (1 KB RAM, 40/80/DC decode), 0 SC-3000 (2 KB, partial decode)
  input         pal,            // VDP pal_i (TMS9929A timing)
  input         border,
  input         sf7000,         // phase 6

  // input
  input  [10:0] ps2_key,        // hps_io format; sim_keys drives it (phase 2)
  input  [63:0] key_matrix,     // alternative: direct 8x12 matrix override from --keys, 1 = pressed
  input         key_matrix_en,
  input  [31:0] joy0, joy1,     // hps order {.., fire2[5], fire1[4], up, down, left, right}
  input         nmi_key,        // SC-3000 RESET key / SG-1000 PAUSE -> Z80 NMI

  // tape (phase 1-2: level from C++; phase 4: RTL player fed by dl_index 2)
  input         tape_in_ext,    // 1-bit level from sim_tape.cpp
  input         tape_ext_en,
  output        tape_out,       // PPI PC4 (CSAVE)

  // SD block device for SF-7000 disks (phase 6), hps_io shape as SVI svi_sim.sv
  input         img_mounted, input img_readonly, input [31:0] img_size,
  output [31:0] sd_lba, output sd_rd, output sd_wr, input sd_ack,
  input  [8:0]  sd_buff_addr, input [7:0] sd_buff_dout, output [7:0] sd_buff_din, input sd_buff_wr,

  // video / audio
  output [7:0]  R, G, B,
  output        HSync, VSync, HBlank, VBlank, ce_pix,
  output [15:0] audio,

  // debug taps (for --trace, --io-log, GUI)
  output [15:0] cpu_a,
  output [7:0]  cpu_di, cpu_do,
  output        cpu_m1_n, cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n, cpu_halt_n,
  output        cpu_cen_p,      // T-state strobe for sampling
  output [211:0] cpu_reg,       // t80sv REG (zeros in the tv80 build: trace falls back to PC only)
  output        vdp_int_n,
  output [7:0]  ppi_pc
);
```

Memories inside the sim top as plain arrays with registered read (`sim.vlt`
`public_flat_rd` so C++ can peek/dump them): `cart[1<<CART_AW]` (1 MB), `wram[2048]`,
`vram[16384]`, later `tape[1<<TAPE_AW]`, `sf7_ram[65536]`. On hardware the cart goes to
SDRAM (ColecoAdam two-channel `sdram.sv`); the sim models it as zero-latency first, then
a `make full` variant with the SDRAM rd/ready latency as SVI did for the tape.

## 5. Loading media

| Option | Path into the core | Notes |
|---|---|---|
| `--cart FILE` | `dl_index=1`, bytes at `dl_addr` 0.., reset held, `dl_size` latched | `.sg`, `.sc`, `.bin`, `.rom`. Mapper autodetect from size (+ hash list later, MAME `refs/mame/hash/sg1000.xml`, `sc3000_cart.xml` `slot` feature); `--mapper NAME` = OSD override (MAME names: rom, level3, castle, othello, terebi, 4pak, korean, korean_nb, multicart, megacart, ...) |
| `--basic` | shortcut for `--cart software/.../BASIC Level III*.sc` + `--model sc3000` | ROM path from `software/INDEX.md` |
| `--tape FILE` | phase 1-2: `sim_tape.cpp` decodes `.wav` (any rate, threshold + hysteresis) or `.bit` (ASCII 0/1/space at 1200 baud: 0 = one 1200 Hz cycle, 1 = two 2400 Hz cycles, space = 1/1200 s silence; MAME `sc3000_bit.cpp`) into a level at sim time and drives `tape_in_ext` -> PPI PB7. Phase 4: `dl_index=2` into the RTL player, `tape_ext_en=0` | `--tape-start FRAME` (no motor line on SC-3000: playback starts at a frame or on `--tape-auto` = first PB7 poll) |
| `--disk FILE` | phase 6: hps_io-style 256/512-byte blocks via `sd_*`, writes kept in memory (`--disk-write` to write back to a copy) | `.sf7` 40 x 16 x 256 (MAME `sf7000_dsk.cpp`) |
| `--ipl FILE` | phase 6: `dl_index=3` SF-7000 IPL ROM | |

All downloads happen with reset held, then reset releases on frame 0 so frame numbers
are comparable between runs and with MAME (section 7).

## 6. CLI

Kept compatible with SVI/ColecoAdam names where they exist.

```
--headless               no window (default when --frames is given and no DISPLAY wanted)
--frames N               stop after N frames (frame = VDP vsync falling edge)
--png FILE               write the last frame as FILE (single-shot form PLAN.md asks for)
--shots F1,F2,..         write OUTDIR/frame_NNNNN.png (+ frame_NNNNN.vdp: 8 regs + 16 KB VRAM, ColecoAdam format, so vdpref.py works)
--every K                a shot every K frames
--outdir DIR
--cart FILE  --mapper NAME  --basic
--model sc3000|sg1000    --pal | --ntsc    --border
--tape FILE  --tape-start F  --tape-auto
--disk FILE  --ipl FILE                     (phase 6)
--keys "TEXT"            auto-type: '\n' = RETURN, '{F1}'-style names for specials, '@F' sets
                         the frame for what follows (SVI --type syntax: 'LOAD\n@600');
                         drives the matrix directly (key_matrix), holds each key 3 frames,
                         releases 3 frames, shifts as needed; table from MAME sk1100.cpp
--key NAME@F[:N]         one matrix key (incl. RESET -> NMI)
--joy SPEC@F[:N]         joystick (SVI syntax: u,d,l,r,1,2)
--until TEXT             stop when TEXT is in the VDP name table (checked every 10 frames)
--text F,..              print the name table as text at frames (BASIC screen reading)
--trace FILE[:FROM[:TO]] Z80 trace in MAME format (section 7); FROM/TO in frames or 'pc=XXXX'
--trace-regs             add the register prefix (needs the t80sv build)
--vcd FILE[:FROM:TO]     Verilator FST/VCD for frames FROM..TO (build with make trace: --trace-fst)
--io-log                 every IN/OUT: frame, PC, port, data
--peek [v:]ADDR[:N]@F    print RAM/VRAM bytes
--dump-ram FILE@F        wram + cart RAM
--wav FILE               audio out (PSG)
--record FILE / --replay FILE   input recording (ColecoAdam)
--profile N              PC sampling histogram
```

Exit status: 0 OK, 2 `--until` not reached, 3 bad arguments/files. `--headless` runs
print one line per shot with the PNG's SHA-256 so `run_tests.sh` can parse it.

## 7. `--trace`: comparable with MAME

MAME side (golden; run by the user or once MAME is available):

```
mame sc3000 -cart game.sc -debug -debugscript tests/mame/trace.cmd -nothrottle -seconds_to_run S
# tests/mame/trace.cmd
trace /tmp/game_mame.tr,maincpu,noloop,{tracelog "AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X ",af,bc,de,hl,ix,iy,sp}
go
```

`noloop` stops MAME collapsing loops into "(loops for N instructions)". Each line is
`<tracelog prefix><PC>: <disassembly>`. (Verify: whether `-debugger none` / `-video none`
still run the debugscript, so it can run headless.)

Sim side: `sim_trace.cpp` watches the bus each `cpu_cen_p`:
- An instruction starts at an M1 opcode fetch (`M1_n=0, MREQ_n=0, RD_n=0`) that is not
  a prefix continuation: track the previous fetched byte; after `CB`/`ED` the next M1 is
  part of the same instruction, after `DD`/`FD` too (and `DD CB d op` has only two M1s).
  Interrupt acknowledge M1 (`IORQ_n=0`) is not an instruction and MAME does not log it: skip it, but mark
  `; INT` / `; NMI` in a side column for the diff tool).
- Registers: sample `cpu_reg` at T3 of that M1 (after the previous instruction's late
  flag writes, t80sv README) - that is the "before executing" state MAME's `tracelog`
  prints. Format exactly as the MAME prefix; PC as `%04X: `; then the raw opcode bytes
  instead of a disassembly (`; ED B0`). The diff tool compares the prefix and PC only.
- tv80 build: PC only (no REG port); `--trace-regs` errors out.

`compare/tracediff.py sim.tr mame.tr`: strips disassembly, aligns on the first
instruction after reset (both start at 0000h) and reports the first divergence with 20
lines of context and the frame/T-state of the sim line. Timing divergence (where an
interrupt lands) shows as an INT at a different instruction index: report it separately
from a register mismatch. Frames: compare `--shots` PNGs with MAME `-snapshot` at the
same frame via `framediff.py` (map both to the 16-colour TMS index first; MAME's palette
differs from vdp18v's).

## 8. Regression tests (`make test`)

`tests/regress.tsv`, tab-separated, `#` comments:

```
# name        rom                                   args                         frame  sha256-of-png | 'text:READY'
sg_boot_hb    homebrew/<cart>.sg                     --model sg1000               300    <hash>
sc_basic3     <BASIC Level III>.sc                   --model sc3000               200    text:Ready
sc_basic_typ  <BASIC Level III>.sc                   --keys 'PRINT 1+1\n@200'     260    text:2
pal_border    homebrew/<cart>.sg                     --pal --border               300    <hash>
```

- `run_tests.sh` runs each line headless in parallel (`xargs -P`, one sim per core),
  writes `tests/out/NAME.png`, compares hash or `--until`-style text, prints
  PASS/FAIL/RUNERR (non-zero exit is RUNERR, never a FAIL - ColecoAdam lesson) and
  a summary; `make test-update NAME=...` rewrites a golden after a reviewed change.
- `make cputest`: builds the T80pa bench from `cpu_tests/` (or
  `/Users/alans/dev2/t80sv_fixes_20261117/bench/`) against our `rtl/t80sv/t80sv_all.sv`
  and runs ZEXDOC (about 3 h; only on CPU changes) and an SST subset (`make sst-one`).
- Golden PNGs only for homebrew / redistributable ROMs; commercial ROMs are listed by
  MAME hash name, tested locally from `software/`, never committed.
- MAME traces for the first N instructions of each regression ROM go in
  `tests/mame/*.tr.gz` (local, not committed if derived from commercial ROMs).

## 9. ImGui panels (GUI mode)

Start from ColecoAdam's `sim_main.cpp` GUI loop and `sim/`:

| Panel | Content |
|---|---|
| Simulation control | reset, run/stop, single/multi step, batch size, model/PAL/border toggles, Load cart/tape (ImGuiFileDialog), NMI (RESET key) button, frame counter, speed |
| Video | VDP output texture (320x240 incl. border), capture keys `[` start / `]` stop / `\` grab (writes PNG + `.vdp`) |
| VDP | the 8 registers decoded (mode, name/colour/pattern/sprite table bases), status, last 5th-sprite; hex view of VRAM (`imgui_memory_editor`) |
| CPU | registers from `cpu_reg`, last 64 PCs, breakpoint on PC, IFF/IM |
| Memory | work RAM, cartridge (+ mapper banks), VRAM editors |
| I/O | last N IN/OUT with PC; PPI ports A/B/C, keyboard row latch |
| Keyboard | on-screen SC-3000 matrix (click to press), PC keyboard mapped like the hardware PS/2 table |
| Tape | position, level, PB7/PC4 activity, start/stop |
| Audio | PSG channel periods/volumes, implot waveform (ColecoAdam audio window) |
| Debug log | `console` (ColecoAdam) |

## 10. Build targets

```
make            obj_dir/Vsc3000_sim, t80sv, fast clocking, GUI compiled in (SDL2+ImGui)
make headless   obj_hl/  -DNO_GUI: no SDL/ImGui, for test servers and parallel sweeps
make tv80       obj_tv80/ +define+SIM_TV80, rtl_sv/tv80
make full       obj_full/ FULL=1 clk_sys rate
make trace      obj_trace/ --trace-fst for --vcd
make test / cputest / clean
```

Flags (from SVI): `--cc --exe --build -j 0 --no-timing -Wno-fatal -Wno-lint -Wno-style
--x-assign fast --x-initial fast --noassert -O3 -CFLAGS "-O2 -std=c++17"`; LDFLAGS
`-lz` plus `$(sdl2-config --libs) -framework OpenGL` in GUI builds.

## 11. Start-from list

1. `/Users/alans/dev2/SVI328_MiSTer/verilator/Makefile`, `sim.vlt` -> Makefile skeleton.
2. `/Users/alans/dev2/SVI328_MiSTer/verilator/svi_sim.sv` -> `sc3000_sim.sv` (strip mapper/tape/disk/806, keep dl_* and FULL).
3. `/Users/alans/dev2/SVI328_MiSTer/verilator/sim_main.cpp` -> headless core of `sim_main.cpp` (CLI, PNG, `--type`, `--text`, `--until`, `--profile`, `--wav`).
4. `/Users/alans/dev2/ColecoAdam_MiSTer/verilator/sim/` (whole dir incl. `imgui/`) and the GUI loop / record / replay / `.vdp` dump from `/Users/alans/dev2/ColecoAdam_MiSTer/verilator/sim_main.cpp`.
5. `/Users/alans/dev2/SVI328_MiSTer/verilator/rtl_sv/svi_console.sv` -> shape of `rtl/sc3000.sv` (CPU ifdef, debug taps), with AY/mapper replaced by SN76489 + SC-3000 decode.
6. `/Users/alans/dev2/ColecoAdam_MiSTer/verilator/compare/tools/vdpref.py`, `vdpdiff.py`, `ppm2png.py`, `cmpframes.cpp` -> `compare/`.

## 12. Order of work

1. `rtl/sc3000.sv` + `sc3000_sim.sv` + headless `sim_main.cpp` (`--cart --frames --png --shots`), boot one SG-1000 homebrew cart.
2. `--trace` + `tracediff.py`; get a MAME trace for that cart (needs MAME).
3. `tests/` + `make test` with that cart's golden.
4. GUI build. 5. `--keys` + BASIC Level III (phase 2). 6. `--tape` level feed.

## 13. Risks / open points

- MAME not installed: no golden traces/frames until the user provides MAME or traces.
- No Z80 assembler for homebrew test ROMs.
- M1 wait state on SC-3000 unknown; it changes trace timing vs MAME (which has none).
- SN76489 noise LFSR differs from MAME's SN76489A; audio diffs expected.
- SC-3000 has no tape motor line: auto-start/turbo needs another trigger.
- vdp18v with SVI's additions has not been through Quartus yet (SVI hardware uses the VHDL vdp18).
- Disk is nearly full (about 14 GB): reference `cpu_tests/vectors` (2.1 GB) in place; keep `obj_*` dirs few.
