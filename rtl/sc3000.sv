//-----------------------------------------------------------------------------
// Sega SC-3000 / SG-1000 machine (shared by the MiSTer top and the Verilator sim)
//
//   Z80A    t80sv_T80pa, 3.579545 MHz (CE from the top: ce_cpu_p / ce_cpu_n)
//   VDP     TMS9918A / TMS9929A (vdp18v, pal_i at run time), 16 KB VRAM outside
//   PSG     SN76489AN (jt89), clocked like the CPU
//   PPI     8255 (jt8255): keyboard matrix, joysticks (row 7), cassette, printer
//   RAM     SC-3000 2 KB at C000 mirrored to FFFF, SG-1000 1 KB (model_sg1000)
//   OMV     Othello Multivision FG-2000 (model_omv, MAME omv_map / omv_io_map):
//           SG-1000 I/O map, 2 KB RAM, 16 KB BIOS at 0000-3FFF (4000-BFFF read
//           00) when no cartridge is in; C0-C3 keypad, C4/C5 = SG-1000 DC/DD
//
// Memory map (MAME sg1000.cpp sc3000_map / sg1000_map):
//   0000-BFFF cartridge (cart_* bus)
//   C000-FFFF internal RAM, unless the cartridge claims it (cart_ram_sel_i =
//             cartridge pin B3 /RAMDIS: BASIC Level III, Dahjee ...)
//
// I/O (SC-3000, service manual p5 / MAME sc3000_io_r/w), M1_n high only:
//   A7=0 PSG write, A6=0 VDP (A0 = data/ctrl), A5=0 PPI (A1:0 = register).
//   The selects overlap: a write to 1Fh reaches all three; reads AND together.
//   The cartridge sees every I/O cycle too (ext_io_*: SF-7000 etc.).
// I/O (SG-1000, MAME sg1000_io_map): 40-7F PSG, 80-BF VDP, DC/DD joysticks.
//
// PPI wiring (MAME bus/sg1000_exp/sk1100.cpp, service manual):
//   PA7:0 keys of the selected row, PB3:0 keys, PB4 /CONT (1), PB5 printer
//   /FAULT, PB6 printer BUSY, PB7 cassette in; PC2:0 row select (row 7 =
//   joysticks), PC3 n.c., PC4 cassette out, PC5-7 printer DATA /RESET /FEED.
// Joysticks (row 7 and SG-1000 DC/DD), active low:
//   PA = {j2 down, j2 up, j1 TR, j1 TL, j1 right, j1 left, j1 down, j1 up}
//   PB[3:0] = {j2 TR, j2 TL, j2 right, j2 left}
//
// The board itself adds no wait states (no M1 wait; MAME models none either);
// wait_n is for the MiSTer's SDRAM cartridge and expansion devices.
// TODO(verify): SN76489 READY -> Z80 /WAIT on the schematic.
//-----------------------------------------------------------------------------

module sc3000 (
  input               clk,
  input               reset,          // active high, synchronous to clk
  input               ce_10m7,        // VDP master clock enable (10.738635 MHz)
  input               ce_cpu_p,       // Z80 T-state, rising phase
  input               ce_cpu_n,       // Z80 T-state, falling phase
  input               ce_psg,         // SN76489 clock enable (3.579545 MHz, not turbo)

  input               model_sg1000,   // 1 = SG-1000 (1 KB RAM, SG-1000 I/O map, no PPI)
  input               model_omv,      // 1 = Othello Multivision (overrides model_sg1000)
  input               sk1100,         // SG-1000 with the SK-1100 keyboard: the PPI at DC-DF
  input               cart_in,        // a cartridge is in the slot (OMV: else the BIOS)
  input               bios_wr,        // OMV BIOS download (16 KB)
  input        [13:0] bios_addr,
  input        [7:0]  bios_data,
  input        [17:0] omv_keys,       // OMV keypad, 1 = pressed (omv_keypad.sv)
  input               pal,            // 1 = TMS9929A timing
  input               border,

  // cartridge bus (0000-BFFF and, with cart_ram_sel_i, C000-FFFF)
  output       [15:0] cart_a,
  output              cart_rd,        // memory read cycle, any address
  output              cart_wr,        // memory write strobe, any address
  output       [7:0]  cart_do,
  input        [7:0]  cart_di,
  input               cart_ram_sel_i, // cartridge drives C000-FFFF (internal RAM off)
  input               wait_n,         // cartridge / SDRAM not ready (Z80 /WAIT)
  input               turbo,          // CPU runs 4x (tape turbo): pace VDP accesses
  output              cart_m1,        // opcode fetch (for mappers that care)

  // cartridge I/O (SF-7000 and friends): every I/O cycle with M1_n high
  output              ext_iorq,
  output              ext_io_rd,
  output              ext_io_wr,
  input               ext_io_en,      // the cartridge answers this read
  input        [7:0]  ext_io_di,

  // keyboard: the row the PPI selects and the 12 keys of that row (active low)
  output       [2:0]  kbd_row,
  input        [7:0]  kbd_pa,
  input        [3:0]  kbd_pb,
  // joysticks, active low {TR, TL, right, left, down, up}
  input        [5:0]  joy1_n,
  input        [5:0]  joy2_n,
  input               nmi_key,        // SC-3000 RESET key / SG-1000 PAUSE, 1 = pressed

  input               tape_in,
  output              tape_out,
  output              tape_poll,      // pulse: the CPU read PPI port B (PB7 = tape in)
  output              ppi_wr,         // pulse: the CPU wrote the PPI (keyboard row select)
  input               printer_busy,
  input               printer_fault_n,

  // VRAM (16 KB, registered read)
  output       [13:0] vram_a,
  output              vram_we,
  output       [7:0]  vram_do,
  input        [7:0]  vram_di,

  output       [7:0]  rgb_r,
  output       [7:0]  rgb_g,
  output       [7:0]  rgb_b,
  output              hsync_n,
  output              vsync_n,
  output              hblank,
  output              vblank,

  output signed [10:0] audio,

  // debug taps
  output       [15:0] dbg_a,
  output       [7:0]  dbg_di,
  output       [7:0]  dbg_do,
  output              dbg_m1_n,
  output              dbg_mreq_n,
  output              dbg_iorq_n,
  output              dbg_rd_n,
  output              dbg_wr_n,
  output              dbg_rfsh_n,
  output              dbg_halt_n,
  output              dbg_int_n,
  output       [7:0]  dbg_ppi_pc,
  output       [211:0] dbg_reg
);

  wire        reset_n = ~reset;

  // CPU ---------------------------------------------------------------------
  wire [15:0] a;
  wire [7:0]  d_from_cpu;
  logic [7:0] d_to_cpu;
  wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
  wire        vdp_int_n;
  wire        nmi_n = ~nmi_key;

`ifndef SIM_TV80
  t80sv_T80pa #(.Mode(0)) cpu (
    .RESET_n(reset_n), .CLK(clk), .CEN_p(ce_cpu_p), .CEN_n(ce_cpu_n),
    .WAIT_n(wait_n & vdp_wait_n), .INT_n(vdp_int_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
    .OUT0(1'b0), .DI(d_to_cpu), .R800_mode(1'b0), .DIRSet(1'b0), .DIR(212'd0),
    .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
    .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(), .A(a), .DO(d_from_cpu), .REG(dbg_reg));
`else
  tv80e cpu (
    .reset_n(reset_n), .clk(clk), .cen(ce_cpu_p),
    .wait_n(wait_n & vdp_wait_n), .int_n(vdp_int_n), .nmi_n(nmi_n), .busrq_n(1'b1),
    .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
    .rfsh_n(rfsh_n), .halt_n(halt_n), .busak_n(),
    .A(a), .di(d_to_cpu), .dout(d_from_cpu));
  assign dbg_reg = '0;
`endif

  // Decode ------------------------------------------------------------------
  wire mem   = ~mreq_n & rfsh_n;
  wire bios_on;
  wire io    = ~iorq_n & m1_n;
  wire hi    = a[15:14] == 2'b11;            // C000-FFFF
  wire iram  = mem & hi & (~cart_ram_sel_i | bios_on);   // internal RAM

  wire sg_io = model_sg1000 | model_omv;
  wire psg_sel, vdp_sel, ppi_sel, joy_sel, omv_sel;
  assign psg_sel = io & (sg_io ? (a[7:6] == 2'b01) : ~a[7]);
  assign vdp_sel = io & (sg_io ? (a[7:6] == 2'b10) : ~a[6]);
  wire   sk_on   = sk1100 & model_sg1000 & ~model_omv;
  assign ppi_sel = io & (sg_io ? (sk_on & (a[7:2] == 6'b110111)) : ~a[5]);     // SK-1100: DC-DF
  assign joy_sel = io &  model_sg1000 & ~model_omv & ~sk_on & (a[7:2] == 6'b110111);   // DC-DF
  assign omv_sel = io &  model_omv & (a[7:6] == 2'b11);                       // C0-FF

  // Internal RAM: 2 KB (SG-1000: 1 KB), mirrored over C000-FFFF -------------
  reg  [7:0] ram [0:2047];
  reg  [7:0] ram_q;
  wire [10:0] ram_a = {a[10] & (~model_sg1000 | model_omv), a[9:0]};

  // OMV BIOS: read in place of the cartridge while none is in ---------------
  reg  [7:0] bios [0:16383];
  reg  [7:0] bios_q;
  assign bios_on = model_omv & ~cart_in;
  always @(posedge clk) begin
    if (bios_wr) bios[bios_addr] <= bios_data;
    bios_q <= bios[a[13:0]];
  end
  always @(posedge clk) begin
    if (iram & ~wr_n) ram[ram_a] <= d_from_cpu;
    ram_q <= ram[ram_a];
  end

  assign cart_a   = a;
  assign cart_rd  = mem & ~rd_n;
  assign cart_wr  = mem & ~wr_n;
  assign cart_do  = d_from_cpu;
  assign cart_m1  = ~m1_n;

  assign ext_iorq  = io;
  assign ext_io_rd = io & ~rd_n;
  assign ext_io_wr = io & ~wr_n;

  // VDP ---------------------------------------------------------------------
  // Under turbo the Z80 would hit the VDP faster than it can take the bytes:
  // each access waits until the VDP's previous VRAM transfer is done and is
  // held for one 10.7 MHz clock (SVI328_MiSTer cv_console vdp_pace).
  wire       vdp_busy;
  reg        vdp_pass_q = 1'b0, vdp_seen_q = 1'b0;
  wire       vdp_acc    = vdp_sel & (~rd_n | ~wr_n);
  wire       vdp_hold   = turbo & ~vdp_pass_q;
  wire       vdp_wait_n = ~(turbo & vdp_acc & ~vdp_seen_q);
  always @(posedge clk) begin
    if (reset | ~vdp_acc) begin vdp_pass_q <= 1'b0; vdp_seen_q <= 1'b0; end
    else begin
      if (~vdp_busy) vdp_pass_q <= 1'b1;
      if (vdp_pass_q & ce_10m7) vdp_seen_q <= 1'b1;
    end
  end
  wire [7:0] vdp_q;
  vdp18_core #(.is_pal_g(0), .compat_rgb_g(0)) vdp (
    .clk_i(clk), .pal_i(pal), .clk_en_10m7_i(ce_10m7), .reset_n_i(reset_n),
    .csr_n_i(~(vdp_sel & ~rd_n) | vdp_hold), .csw_n_i(~(vdp_sel & ~wr_n) | vdp_hold), .mode_i(a[0]),
    .int_n_o(vdp_int_n),
    .cd_i(d_from_cpu), .cd_o(vdp_q), .cpu_busy_o(vdp_busy),
    .vram_we_o(vram_we), .vram_a_o(vram_a), .vram_d_o(vram_do), .vram_d_i(vram_di),
    .border_i(border), .col_o(),
    .rgb_r_o(rgb_r), .rgb_g_o(rgb_g), .rgb_b_o(rgb_b),
    .hsync_n_o(hsync_n), .vsync_n_o(vsync_n), .blank_n_o(),
    .hblank_o(hblank), .vblank_o(vblank), .comp_sync_n_o());

  // PSG ---------------------------------------------------------------------
  jt89 psg (
    .rst(reset), .clk(clk), .clk_en(ce_psg),
    .wr_n(~(psg_sel & ~wr_n)), .cs_n(~psg_sel), .din(d_from_cpu),
    .sound(audio), .ready());

  // PPI ---------------------------------------------------------------------
  wire [7:0] ppi_q, ppi_pc;
  wire [2:0] row = ppi_pc[2:0];
  wire       row_joy = row == 3'd7;
  wire [7:0] joy_pa = {joy2_n[1], joy2_n[0], joy1_n[5:0]};
  wire [3:0] joy_pb = {joy2_n[5:2]};
  jt8255 ppi (
    .rst(reset), .clk(clk),
    .addr(a[1:0]), .din(d_from_cpu), .dout(ppi_q),
    .rdn(rd_n), .wrn(wr_n), .csn(~ppi_sel),
    .porta_din(row_joy ? joy_pa : kbd_pa),
    .portb_din({tape_in, printer_busy, printer_fault_n, 1'b1, row_joy ? joy_pb : kbd_pb}),
    .portc_din(8'hFF),
    .porta_dout(), .portb_dout(), .portc_dout(ppi_pc));

  assign kbd_row  = row;
  assign tape_out = ppi_pc[4];

  reg pb_rd_q = 1'b0;
  wire pb_rd = ppi_sel & ~rd_n & (a[1:0] == 2'b01);
  always @(posedge clk) pb_rd_q <= pb_rd;
  assign tape_poll = pb_rd & ~pb_rd_q;
  reg ppi_wr_q = 1'b0;
  wire ppi_w = ppi_sel & ~wr_n;
  always @(posedge clk) ppi_wr_q <= ppi_w;
  assign ppi_wr = ppi_w & ~ppi_wr_q;

  // SG-1000 joystick ports (no PPI): DC = PA layout, DD = {1111, PB layout}
  wire [7:0] joy_q = a[0] ? {4'hF, joy_pb} : joy_pa;
  // OMV: C0-C3 keypad (mirror 38h), C4/C5 joysticks as DC/DD (mirror 3Ah)
  logic [7:0] omv_q;
  always_comb begin
    if (a[2]) omv_q = joy_q;
    else case (a[1:0])
      2'd0: omv_q = {2'b11, ~omv_keys[5:0]};
      2'd1: omv_q = {4'hF,  ~omv_keys[9:6]};
      2'd2: omv_q = {2'b11, ~omv_keys[15:10]};
      default: omv_q = {6'h3F, ~omv_keys[17:16]};
    endcase
  end

  // Data to the CPU: AND of everything selected, idle bus = FF ---------------
  always_comb begin
    d_to_cpu = 8'hFF;
    if (mem) d_to_cpu = iram ? ram_q : ~bios_on ? cart_di : (a[15:14] == 2'b00) ? bios_q : 8'h00;
    if (io) begin
      if (vdp_sel)   d_to_cpu = d_to_cpu & vdp_q;
      if (ppi_sel)   d_to_cpu = d_to_cpu & ppi_q;
      if (joy_sel)   d_to_cpu = d_to_cpu & joy_q;
      if (omv_sel)   d_to_cpu = d_to_cpu & omv_q;
      if (ext_io_en) d_to_cpu = d_to_cpu & ext_io_di;
    end
  end

  assign dbg_a      = a;
  assign dbg_di     = d_to_cpu;
  assign dbg_do     = d_from_cpu;
  assign dbg_m1_n   = m1_n;
  assign dbg_mreq_n = mreq_n;
  assign dbg_iorq_n = iorq_n;
  assign dbg_rd_n   = rd_n;
  assign dbg_wr_n   = wr_n;
  assign dbg_rfsh_n = rfsh_n;
  assign dbg_halt_n = halt_n;
  assign dbg_int_n  = vdp_int_n;
  assign dbg_ppi_pc = ppi_pc;

endmodule
