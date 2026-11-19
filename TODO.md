# TODO

## Release 1.0 (see PLAN.md phases)
- [x] Phase 1: machine core + Verilator sim, SG-1000 carts boot (2026-11-18: 16/17 homebrew, 9/10 commercial; `make test` 26/26)
  - [ ] GUI build (ImGui), `--trace` first instruction, tv80 build
  - [ ] MAME trace diff (needs MAME with its debugger window)
  - [x] PSG noise LFSR: SN76489AN (MAME sn76489a: 0x10000, taps 0x04/0x08) instead of jt89's SMS one.
        Audio compared with MAME 0.283 (BASIC III program OUT 127,...: 440 Hz tone, white noise /512 and
        /1024, periodic /512; noise bits decoded from the WAVs): white noise fits b[n]=b[n-14]^b[n-15]
        on every bit in both, periodic repeats every 15 in both, tone 440.3 vs 440.5 Hz. jt89's output
        is inverted relative to MAME (inaudible). Hardware (mister126, build l, KVMS recording 48 kHz):
        tone 440.3 Hz (MAME 440.3), white /512 and /1024 fit b[n]=b[n-14]^b[n-15] on every bit,
        periodic repeats every 15 with 7% ones as MAME, periodic level half of white as MAME, tone and
        white noise the same level as MAME. Files: hwtest/audio/, tools/audio/ (lfsr.py WAV T0 T1 DIV)
  - [ ] SN76489 READY -> Z80 /WAIT? (schematic)
- [ ] Phase 2: SC-3000 keyboard, BASIC Level III boots
  - [x] BASIC Level II and III boot, typed program runs (sim matrix input)
  - [x] PS/2 -> SK-1100 matrix for hardware (SMS_MiSTer rtl/keyboard.sv)
  - [x] keyboard queue 64 -> 1024 entries (block RAM, one write port): a KVMS paste of a 7-line
        program overflowed the 64-entry queue and garbled it (build i). Unit test: 504-char paste.
        Build k: no more drops, but digits came out shifted: keys that follow the PC Shift took it
        when applied, and KVMS holds Shift for the next capital meanwhile. Now the Shift is stored
        with the key when queued (test: Shift held while the queue drains). Build l (md5 2dd285aa…,
        35% ALMs, 50% RAM, +7.8 ns): the 7-line program pasted through KVMS arrives exactly
- [ ] Phase 3: cartridge mappers (MAME sega8 list)
  - [x] rom, level3, castle, othello; auto-detect (CRC table + MAME string rules)
  - [x] terebi, dahjee A/B, music_editor, multicart (2 MB), megacart (4 MB): sim boots all, multicart/megacart
        bank into BASIC IIIB; megacart on hardware (SDRAM path); 24-bit ROM addressing, 64 KB carts in BRAM
  - [ ] Terebi Oekaki: tablet position verified in sim (cursor follows), drawing a line not yet seen (MAME check needed)
- [ ] Phase 4: cassette (tape-standard)
  - [x] `rtl/sc3000_tape.sv`: WAV (8/16-bit, any rate, chunk walk) and MAME .bit from SDRAM ch1
  - [x] virtual motor (`sc3000_tape_motor.sv`: plays while PB7 is polled); Voltron loads under BASIC III in sim
  - [x] OSD: Tape (F2), Rewind tape, Tape audio
  - [x] turbo 4x (sc3000_clocks.sv, VDP pacing as SVI, PSG on its own enable): Voltron 47 s -> 12 s on
        hardware, game runs normally after; keyboard-scan windows don't start the motor
  - [x] status bar (sc3000_tape_overlay.sv: SVI renderer + new WAV/.bit status; 'x4' glyph added)
  - [-] quick start: not applicable. The SC-3000 has no firmware boot path (every program starts
        from a cartridge; tapes load from BASIC's typed LOAD), the case tape-standard "Other machines"
        rules out ("no quick start; turbo only"; auto-type is a separate feature). Corpus header
        decode (throwaway decoder, 2026-11-18): Voltron, Keyboard Demo, D.B.C. are BASIC (key 16h)
        headers; Crocky doesn't decode with the standard format (custom loader?)
  - [ ] next-step hint (optional): would say LOAD / RUN, which every BASIC user knows; low value
  - [x] tape save: `sc3000_tape_rec.sv` decodes PC4 into a MAME .bit file on an hps_io VD (OSD "Tape save", S1);
        blank tape = file of spaces (releases/blank_tape_15min.bit). Round trip in sim
        (tests/tape_save_roundtrip.sh) and on hardware (build h md5 d8b85e8c...: SAVE "HWTEST" -> LOAD -> RUN)
- [ ] Phase 5: MiSTer top, OSD, video standard, Quartus build
  - [x] SC3000.sv, sys/ = Template_MiSTer e901a9f, OSD per osd-standard, video per video-standard
  - [x] Quartus 17.0.2 builds: 20261118a (25% ALMs), 20261118b with tape + SF-7000 (27% ALMs, 35% RAM blocks,
        core clock slack +8.1 ns), releases/SC3000_20261118b.rbf md5 d0a4a534...
  - [x] first tests on mister126 (2026-11-18, build c md5 c27bd40b..., misterkvms-cli; MGLs in
        _Development/sc3k_*.mgl, files in games/SC3000/, screenshots in hwtest/):
        Che-Man, The Castle (+ music), BASIC III typed program, SF-7000 Disk BASIC (Auto) + FILES,
        Voltron LOAD from WAV + RUN
  - [x] keyboard: PC layout (symbols as printed, Shift+letter = capital) + SC-3000 layout (P3),
        40 ms queue so fast typing isn't lost (unit test verilator/tests/kbd)
  - [x] build d (md5 04540804..., on mister126 _Development/, MGLs point to it): 320 ms pause after
        RETURN; a pasted 3-line BASIC session at KVMS default speed types and runs correctly
  - [x] OSD on hardware (build g md5 720f9cc1...): top page, Machine, Video pages; Changes pending; Apply and
        reset; PAL (1920x1048 at 1080p) and back to NTSC; extension lists fixed (3-char fields)
  - [ ] joysticks on hardware (KVMS can't press pad buttons), border, aspect/scale modes
  - [x] PSG noise: jt89_noise.v patched to the SN76489AN 17-bit LFSR (MAME sn76489a); not yet compared by ear
- [ ] Phase 6: SF-7000 (IPL, 64 KB RAM, u765, .sf7) - required for 1.0
  - [x] `rtl/sf7000.sv` (64 KB RAM, IPL paging on PC6, PPI, 300 rpm index pulse) + `rtl/sf7000_fdc.sv`
        (own uPD765A subset for raw .sf7; MiSTer's u765 is DSK-only)
  - [x] sim: Disk BASIC 1.0p boots (18669 bytes free = MAME), FILES, SAVE + LOAD round trip
  - [x] OSD: SF-7000 disk (S0), Load ROM = IPL (boot0.rom), SF-7000 Auto/On/Off
  - [ ] 8251 USART (stub now), Centronics printer, FORMAT tested, other disks (basic11, logo, games)
- [ ] Phase 7: hardware test (user go-ahead)

## After 1.0
- [x] Othello Multivision model (FG-2000, MAME omv2000): Model row value 3 (O[26:25], O[12] retired),
      BIOS = boot1.rom (index 40h) or Load ROM while Model = OMV, 2 KB RAM, C0-C3 keypad
      (rtl/omv_keypad.sv), C4/C5 joysticks. Sim: --omv / --pad; regress omv_title, omv_move
      (S2 manual, D 3 S1 plays D3: B=4 W=1). Hardware, build i (md5 491e6eb2…, 36% ALMs, 50% RAM, +7.7 ns):
      title, keypad 1 starts the game; S-1/S-2 untested (KVMS has no pad buttons)
