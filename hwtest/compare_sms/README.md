# SC3000 core vs the SMS core (SG-1000 / SC-3000 mode), 2026-11-19

Screenshots and recordings from mister126 (MiSTer KVMS capture), with MAME 0.283
as the reference where one helps. SC3000 core: build m (`releases/SC3000_20261119m.rbf`).
SMS core: `SMS_20260823.rbf`, the current release, default settings.

| Panel | Result |
|---|---|
| 01_menu | SC3000: Cartridge, Tape, Tape save, SF-7000 disk, Load ROM. SMS: one cartridge slot and Game Gear. |
| 02_basic3 | BASIC Level III boots with 26620 bytes free on both. |
| 03_tape | SC3000 loads Voltron.wav (LOAD, 4x). SMS has no tape: LOAD waits at "Loading start". |
| 04_sf7000 | SC3000 boots SF-7000 Disk BASIC 1.1p. SMS has no SF-7000. |
| 05_multicolor | TMS9918 multicolor mode from BASIC: SC3000 = MAME (pixel-identical in the simulator); SMS draws character patterns. |
| 06_terebi | Terebi Oekaki: SC3000 = MAME; SMS black screen. |
| 07_music | Music Editor: SC3000 runs (title, then menu); SMS blank. |
| 08_basic2 | BASIC Level II: SC3000 2043 bytes free = MAME with its software list; SMS 515 (no cartridge RAM). |
| 09_othello_multivision | SC3000 runs the Othello Multivision BIOS game; SMS has no OMV. |
| 10_paste | Pasting a 5-line program at 30 ms per key: SC3000 exact; SMS drops keys. At 80 ms per key both are fine. |
| 11_sound_noise | PSG white noise decoded bit by bit: SC3000 = MAME (SN76489AN, 15-bit recurrence b[n-14]^b[n-15]); SMS uses the SMS PSG's 16-bit one (b[n-13]^b[n-16]); periodic noise repeats every 15 (SC3000, MAME) vs 16 (SMS). |

Same on both (not shown): SG-1000 cartridges such as Flicky, Yingzi Chuanshuo (Dahjee A).
The SMS core has things this core does not: save states, cheats, Mega Drive pads, light guns.

Rebuild the panels: `tools/compare_panels.py SPEC.json OUTDIR`, `tools/audio/noise_panel.py`.
