# t80sv (Z80 CPU)

`t80sv_all.sv` is t80sv by Rodimus: a SystemVerilog translation of the T80 Z80 core (T80 0250,
MiSTer-devel lineage), cycle-identical to the VHDL, with drop-in tops that keep the VHDL ports.
This core uses `t80sv_T80pa` with `Mode(0)` in `rtl/cv_console.sv`, driven by `CEN_p` / `CEN_n`
(both phases of the 3.58 MHz enable), as the SVI-328 core does.

Source: https://github.com/RodimusFVC/Rodimus_Chips_MiSTer `t80sv/rtl/t80sv_all.sv` at commit
571b6e9 (2026-11-17), unmodified. That repository's PR #1 merged four fixes made in the SVI-328 core
(the SVI repo's `rtl/t80sv/t80sv_fixes.patch`; the same fixes went into the VHDL T80 0250):

1. `DD/FD INC DE`, `DEC DE`: changed BC instead of DE.
2. Q register: flag bits 5 / 3 after `SCF` / `CCF`.
3. MEMPTR (WZ) for about 60 opcodes (`LD A,(rr)`, `LD A,(nn)`, `LD (nn),rr`, `RET`,
   `OUT (n),A`, `RLD` / `RRD`, `CPI` / `CPD`).
4. Repeating block instructions: flag bits 5 / 3 from PC, H and P/V of `INIR` / `OTIR` /
   `INDR` / `OTDR`.

571b6e9 then shares one adder between all the WZ +1 / -1 updates (the author's yosys equivalence
proof; -48 ALMs). Re-checked here: all SingleStepTests/z80 cases still pass with results identical
to the previous copy, and the simulator's frames and VRAM are byte-identical.

With the fixes it passes all 1,604,000 SingleStepTests/z80 cases (registers, WZ, Q, flags, memory,
I/O, T-states, bus cycle order, strobe positions), every interrupt acknowledge timing case with
and without the SVI M1 wait state, and ZEXDOC / ZEXALL (the SVI-328 repo's `verilator/cpu_tests`,
`results/t80sv/`). Fixes 2 and 4 are gated to Z80 modes; 8080 and GB modes are unchanged.

License: T80's BSD-style terms (Daniel Wallner and the other T80 authors) and Rodimus, in
`LICENSE` and at the top of `t80sv_all.sv`.
